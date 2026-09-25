import Foundation

public enum Template {
    public struct Problem: Error, CustomStringConvertible, Sendable {
        public let description: String
        init(_ description: String) { self.description = description }
    }
    private struct Slot { let range: Range<String.Index>; let id: String }
    public static func validValue(_ value: String) -> Bool { !value.contains { $0 == "\0" || $0 == "\r" || $0 == "\n" } }
    public static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
    public static func references(_ command: String, known: Set<String>) throws -> Set<String> {
        Set(try slots(command, known: known).map(\.id))
    }
    // Literal commands are opaque. Commands with templates use a deliberately narrow shell subset.
    private static func slots(_ command: String, known: Set<String>) throws -> [Slot] {
        guard command.contains("{{") || command.contains("}}") else { return [] }
        guard !command.contains("\0"), !command.contains("\r") else { throw Problem("Commands with inputs cannot contain NUL or carriage returns.") }
        var result: [Slot] = []
        var i = command.startIndex
        var words = 0
        let reserved: Set<String> = ["if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "function", "select", "!", "time"]
        while i < command.endIndex {
            let c = command[i]
            if c == " " || c == "\t" { i = command.index(after: i); continue }
            if c == "\n" { words = 0; i = command.index(after: i); continue }
            if c == "|" || c == "&" {
                guard words > 0 else { throw Problem("Expected a simple command before a connector.") }
                let first = c; i = command.index(after: i)
                if i < command.endIndex && command[i] == first { i = command.index(after: i) }
                else if first == "&" { throw Problem("Background commands with inputs are unsupported.") }
                words = 0; continue
            }
            if c == "#" {
                let end = command[i...].firstIndex(of: "\n") ?? command.endIndex
                if command[i..<end].contains("{{") || command[i..<end].contains("}}") { throw Problem("Placeholders cannot appear in comments.") }
                i = end; continue
            }
            let start = i
            var quote: Character?
            var escaped = false
            while i < command.endIndex {
                let ch = command[i]
                if escaped { escaped = false; i = command.index(after: i); continue }
                if ch == "\\" && quote != "'" { escaped = true; i = command.index(after: i); continue }
                if let q = quote {
                    if ch == q { quote = nil }
                    i = command.index(after: i); continue
                }
                if ch == "'" || ch == "\"" { quote = ch; i = command.index(after: i); continue }
                if " \t\n|&".contains(ch) { break }
                if ";<>()`".contains(ch) { throw Problem("With inputs, use simple commands joined by newlines, pipes, &&, or ||. Redirections, substitutions and compound commands are unsupported.") }
                i = command.index(after: i)
            }
            guard quote == nil, !escaped else { throw Problem("Unclosed quote or escape in a templated command.") }
            let token = String(command[start..<i])
            // Ban substitutions even inside double quotes, conservatively also in single-quoted literals.
            guard !token.contains("$("), !token.contains("`"), !token.contains("${"), !reserved.contains(token), token.range(of: "^[A-Za-z_][A-Za-z0-9_]*=", options: .regularExpression) == nil else { throw Problem("Assignments, substitutions and shell control syntax are unsupported in templated commands.") }
            if token.contains("{{") || token.contains("}}") {
                guard words > 0, token.hasPrefix("{{"), token.hasSuffix("}}") else { throw Problem("A placeholder must be one complete unquoted argument after a command name.") }
                let id = String(token.dropFirst(2).dropLast(2))
                guard id.range(of: "^[a-z][a-z0-9-]*$", options: .regularExpression) != nil else { throw Problem("Malformed placeholder. Use {{input-id}} as a complete unquoted argument.") }
                guard known.contains(id) else { throw Problem("Unknown input: \(id).") }
                result.append(Slot(range: start..<i, id: id))
            } else if token.contains("{") || token.contains("}") { throw Problem("Brace syntax is unsupported in templated commands.") }
            words += 1
        }
        guard words > 0 || command.last == "\n" else { throw Problem("Expected a command after the connector.") }
        return result
    }
    public static func inputError(_ input: Input, value: String) -> String? {
        if !validValue(value) { return "Use a single line without NUL or carriage returns." }
        if value.isEmpty { return input.required ? "\(input.label) is required." : nil }
        if input.type == .choice && !input.options.contains(value) { return "Choose one of the listed options." }
        return nil
    }
    public static let mask = "••••••"
    /// With `masked`, secret values render as a fixed mask so previews never show credentials.
    public static func render(_ step: Step, workflow: Workflow, values: [String: String], masked: Bool = false) throws -> String {
        let slots = try slots(step.command, known: Set(workflow.inputs.map(\.id)))
        var rendered = step.command
        for slot in slots.reversed() {
            guard let input = workflow.inputs.first(where: { $0.id == slot.id }) else { throw Problem("Unknown input.") }
            let value = values[input.id] ?? input.defaultValue ?? ""
            if let error = inputError(input, value: value) { throw Problem(error) }
            rendered.replaceSubrange(slot.range, with: masked && input.type == .secret && !value.isEmpty ? mask : quote(value))
        }
        while rendered.last == "\n" { rendered.removeLast() }
        return rendered
    }
    public static func usesSecret(_ step: Step, workflow: Workflow) -> Bool {
        let secrets = Set(workflow.inputs.filter { $0.type == .secret }.map(\.id))
        return !secrets.isEmpty && !((try? references(step.command, known: Set(workflow.inputs.map(\.id)))) ?? []).isDisjoint(with: secrets)
    }
}
