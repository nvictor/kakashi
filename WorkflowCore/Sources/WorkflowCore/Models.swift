import Foundation

public struct Workflow: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var description: String
    public var tags: [String]
    public var inputs: [Input]
    public var steps: [Step]
    public var source: URL
    public var presets: [Preset] = []
}
/// A named set of input values that fills several inputs at once.
public struct Preset: Equatable, Sendable, Identifiable {
    public var name: String
    public var values: [String: String]
    public var id: String { name }
}
public struct Input: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case string, path, choice, secret }
    public var id: String
    public var label: String
    public var type: Kind
    public var description: String
    public var required: Bool
    public var defaultValue: String?
    public var options: [String]
}
public struct Step: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var description: String
    public var command: String
}
public struct Diagnostic: Codable, Equatable, Sendable, Error {
    public var file: String
    public var field: String
    public var code: String
    public var message: String
    public var line: Int?
    public var column: Int?
    public init(file: String, field: String = "$", code: String, message: String, line: Int? = nil, column: Int? = nil) {
        self.file = file; self.field = field; self.code = code; self.message = message; self.line = line; self.column = column
    }
}
public struct Catalog: Sendable {
    public var workflows: [Workflow] = []
    public var diagnostics: [Diagnostic] = []
    public var filesChecked = 0
    public var ioFailure = false
    public var valid: Bool { diagnostics.isEmpty }
    public init() {}
}
/// Input values per workflow. Values survive reconciliation only while their input definition is unchanged.
public struct Session: Codable, Sendable {
    public private(set) var values: [String: [String: String]] = [:]
    private var definitions: [String: [Input]] = [:]
    public init() {}
    /// A copy safe to save to disk: secret values are dropped.
    public var persistable: Session {
        var copy = self
        for (workflow, inputs) in definitions {
            for input in inputs where input.type == .secret { copy.values[workflow]?[input.id] = nil }
        }
        return copy
    }
    public mutating func reconcile(_ workflows: [Workflow]) {
        var next: [String: [String: String]] = [:]
        for workflow in workflows {
            for input in workflow.inputs {
                let unchanged = definitions[workflow.id]?.first(where: { $0.id == input.id }) == input
                next[workflow.id, default: [:]][input.id] = unchanged ? (values[workflow.id]?[input.id] ?? input.defaultValue ?? "") : (input.defaultValue ?? "")
            }
        }
        values = next; definitions = Dictionary(uniqueKeysWithValues: workflows.map { ($0.id, $0.inputs) })
    }
    public mutating func set(_ value: String, workflow: String, input: String) { values[workflow, default: [:]][input] = value }
    public mutating func apply(_ preset: Preset, workflow: String) {
        for (input, value) in preset.values { set(value, workflow: workflow, input: input) }
    }
    /// The first preset whose values all match the current values, if any.
    public func matchingPreset(_ workflow: Workflow) -> Preset? {
        workflow.presets.first { $0.values.allSatisfy { values[workflow.id]?[$0.key] == $0.value } }
    }
}
