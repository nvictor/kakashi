import Foundation

public struct Workflow: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var description: String
    public var tags: [String]
    public var inputs: [Input]
    public var steps: [Step]
    public var source: URL
}
public struct Input: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case string, path, choice, secret }
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
public struct Session: Sendable {
    public private(set) var values: [String: [String: String]] = [:]
    private var definitions: [String: [Input]] = [:]
    public init() {}
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
}
