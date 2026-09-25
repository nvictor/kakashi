import Foundation
import Yams

public enum WorkflowParser {
    public static func parse(_ text: String, source: URL) throws -> Workflow {
        guard text.utf8.count <= 1_048_576 else { throw Diagnostic(file: source.path, code: "file-size", message: "Maximum file size is 1 MiB.") }
        let reader = Reader(file: source.path)
        let root: Node
        do {
            let parser = try Yams.Parser(yaml: text, encoding: .utf8)
            guard let node = try parser.singleRoot() else { throw reader.error(nil, "$", "empty", "Expected one workflow.") }
            try withExtendedLifetime(parser) { try reader.inspect(node, "$", depth: 0) }
            root = node
        } catch let error as Diagnostic { throw error }
        catch let error as YamlError {
            switch error {
            case .scanner(_, let problem, let mark, _), .parser(_, let problem, let mark, _), .composer(_, let problem, let mark, _):
                throw Diagnostic(file: source.path, code: "yaml", message: problem, line: mark.line, column: mark.column)
            case .duplicatedKeysInMapping(let duplicates, let context):
                throw Diagnostic(file: source.path, code: "duplicate-key", message: "Duplicate YAML keys: " + duplicates.joined(separator: ", "), line: context.mark.line, column: context.mark.column)
            default: throw reader.error(nil, "$", "yaml", String(describing: error))
            }
        } catch { throw reader.error(nil, "$", "yaml", String(describing: error)) }
        let fields = try reader.map(root, "$", allowed: ["schema_version", "id", "title", "description", "tags", "shell", "inputs", "steps"])
        guard let version = fields["schema_version"], version.tag == Tag(.int), version.scalar?.string == "1" else { throw reader.error(fields["schema_version"], "schema_version", "version", "Expected integer schema_version: 1.") }
        guard try reader.string(fields["shell"], "shell") == "posix" else { throw reader.error(fields["shell"], "shell", "shell", "Only posix is supported.") }
        let id = try reader.id(fields["id"], "id")
        let title = try reader.string(fields["title"], "title", nonempty: true)
        let description = try reader.optionalString(fields["description"], "description")
        let tags = try reader.strings(fields["tags"], "tags", optional: true)
        var inputs: [Input] = []
        for (index, node) in try reader.array(fields["inputs"], "inputs", optional: true).enumerated() {
            let path = "inputs[\(index)]"
            let f = try reader.map(node, path, allowed: ["id", "label", "type", "description", "required", "default", "options"])
            guard let kind = Input.Kind(rawValue: try reader.string(f["type"], path + ".type")) else { throw reader.error(f["type"], path + ".type", "input-type", "Use string, path, choice, or secret.") }
            let options = try reader.strings(f["options"], path + ".options", optional: true)
            if kind == .choice {
                guard !options.isEmpty, options.allSatisfy({ !$0.isEmpty }), Set(options).count == options.count else { throw reader.error(f["options"], path + ".options", "options", "Choice options must be nonempty, unique strings.") }
            } else if f["options"] != nil { throw reader.error(f["options"], path + ".options", "options", "Only choice inputs accept options.") }
            var required = true
            if let value = f["required"] {
                guard value.tag == Tag(.bool), ["true", "false"].contains(value.scalar?.string ?? "") else { throw reader.error(value, path + ".required", "type", "Expected true or false.") }
                required = value.scalar?.string == "true"
            }
            if kind == .secret, let node = f["default"] { throw reader.error(node, path + ".default", "default", "Secret inputs cannot have defaults. Keep credentials out of workflow files.") }
            let defaultValue = try f["default"].map { try reader.string($0, path + ".default") }
            if let defaultValue {
                guard Template.validValue(defaultValue), kind != .choice || options.contains(defaultValue) else { throw reader.error(f["default"], path + ".default", "default", "Default must be a valid single-line value and belong to the choice options.") }
            }
            guard options.allSatisfy(Template.validValue) else { throw reader.error(f["options"], path + ".options", "options", "Options cannot contain NUL or line breaks.") }
            inputs.append(Input(id: try reader.id(f["id"], path + ".id"), label: try reader.string(f["label"], path + ".label", nonempty: true), type: kind, description: try reader.optionalString(f["description"], path + ".description"), required: required, defaultValue: defaultValue, options: options))
        }
        guard Set(inputs.map(\.id)).count == inputs.count else { throw reader.error(fields["inputs"], "inputs", "duplicate-id", "Input IDs must be unique.") }
        var steps: [Step] = []
        for (index, node) in try reader.array(fields["steps"], "steps").enumerated() {
            let path = "steps[\(index)]"
            let f = try reader.map(node, path, allowed: ["id", "title", "description", "command"])
            var command = try reader.string(f["command"], path + ".command", nonempty: true)
            while command.last == "\n" { command.removeLast() }
            do { _ = try Template.references(command, known: Set(inputs.map(\.id))) }
            catch { throw reader.error(f["command"], path + ".command", "template", String(describing: error)) }
            steps.append(Step(id: try reader.id(f["id"], path + ".id"), title: try reader.string(f["title"], path + ".title", nonempty: true), description: try reader.optionalString(f["description"], path + ".description"), command: command))
        }
        guard !steps.isEmpty else { throw reader.error(fields["steps"], "steps", "empty", "At least one step is required.") }
        guard Set(steps.map(\.id)).count == steps.count else { throw reader.error(fields["steps"], "steps", "duplicate-id", "Step IDs must be unique.") }
        return Workflow(id: id, title: title, description: description, tags: tags, inputs: inputs, steps: steps, source: source)
    }
}

private struct Reader {
    let file: String
    func error(_ node: Node?, _ field: String, _ code: String, _ message: String) -> Diagnostic {
        Diagnostic(file: file, field: field, code: code, message: message, line: node?.mark.map { $0.line }, column: node?.mark.map { $0.column })
    }
    func inspect(_ node: Node, _ path: String, depth: Int) throws {
        guard depth < 32 else { throw error(node, path, "depth", "YAML nesting exceeds 32 levels.") }
        guard node.anchor == nil else { throw error(node, path, "anchor", "YAML anchors and aliases are unsupported.") }
        switch node {
        case .alias: throw error(node, path, "alias", "YAML aliases are unsupported.")
        case .mapping(let mapping):
            guard node.tag == Tag(.map) else { throw error(node, path, "tag", "Custom YAML tags are unsupported.") }
            var seen: Set<String> = []
            for (key, value) in mapping {
                try inspect(key, path, depth: depth + 1)
                let name = try string(key, path)
                guard seen.insert(name).inserted else { throw error(key, path + "." + name, "duplicate-key", "Duplicate YAML key: \(name).") }
                try inspect(value, path + "." + name, depth: depth + 1)
            }
        case .sequence(let sequence):
            guard node.tag == Tag(.seq) else { throw error(node, path, "tag", "Custom YAML tags are unsupported.") }
            for (i, value) in sequence.enumerated() { try inspect(value, path + "[\(i)]", depth: depth + 1) }
        case .scalar:
            guard [Tag.Name.str, .int, .bool, .null, .float, .timestamp].map({ Tag($0) }).contains(node.tag) else { throw error(node, path, "tag", "Custom YAML tags are unsupported.") }
        }
    }
    func map(_ node: Node, _ path: String, allowed: Set<String>) throws -> [String: Node] {
        guard case .mapping(let mapping) = node else { throw error(node, path, "type", "Expected a mapping.") }
        var result: [String: Node] = [:]
        for (key, value) in mapping {
            let name = try string(key, path)
            guard allowed.contains(name) else { throw error(key, path + "." + name, "unknown-field", "Unknown field: \(name).") }
            result[name] = value
        }
        return result
    }
    func string(_ node: Node?, _ path: String, nonempty: Bool = false) throws -> String {
        guard let node, case .scalar(let value) = node, node.tag == Tag(.str) else { throw error(node, path, "type", "Expected a string. Quote numeric or boolean-looking values.") }
        guard !nonempty || !value.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw error(node, path, "empty", "Value cannot be empty.") }
        return value.string
    }
    func optionalString(_ node: Node?, _ path: String) throws -> String { try node.map { try string($0, path) } ?? "" }
    func id(_ node: Node?, _ path: String) throws -> String {
        let value = try string(node, path)
        guard value.range(of: "^[a-z][a-z0-9-]*$", options: .regularExpression) != nil else { throw error(node, path, "id", "IDs must match [a-z][a-z0-9-]*.") }
        return value
    }
    func array(_ node: Node?, _ path: String, optional: Bool = false) throws -> [Node] {
        if node == nil && optional { return [] }
        guard let node, case .sequence(let values) = node else { throw error(node, path, "type", "Expected an array.") }
        return Array(values)
    }
    func strings(_ node: Node?, _ path: String, optional: Bool = false) throws -> [String] { try array(node, path, optional: optional).enumerated().map { try string($0.element, path + "[\($0.offset)]") } }
}
