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
public struct Preset: Codable, Equatable, Sendable, Identifiable {
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
/// Each preset also remembers the inputs it does not list (such as a version), like shell history per preset.
public struct Session: Codable, Sendable {
    public private(set) var values: [String: [String: String]] = [:]
    /// Workflow ID → preset name → input ID → last value typed while that preset was active.
    private var presetValues: [String: [String: [String: String]]] = [:]
    private var definitions: [String: [Input]] = [:]
    private var presets: [String: [Preset]] = [:]
    public init() {}
    /// A copy safe to save to disk: secret values are dropped.
    public var persistable: Session {
        var copy = self
        for (workflow, inputs) in definitions {
            for input in inputs where input.type == .secret {
                copy.values[workflow]?[input.id] = nil
                for name in copy.presetValues[workflow]?.keys.map({ $0 }) ?? [] { copy.presetValues[workflow]?[name]?[input.id] = nil }
            }
        }
        return copy
    }
    public mutating func reconcile(_ workflows: [Workflow]) {
        var next: [String: [String: String]] = [:]
        var nextPresetValues: [String: [String: [String: String]]] = [:]
        for workflow in workflows {
            for input in workflow.inputs {
                let unchanged = definitions[workflow.id]?.first(where: { $0.id == input.id }) == input
                next[workflow.id, default: [:]][input.id] = unchanged ? (values[workflow.id]?[input.id] ?? input.defaultValue ?? "") : (input.defaultValue ?? "")
                guard unchanged else { continue }
                for preset in workflow.presets {
                    if let value = presetValues[workflow.id]?[preset.name]?[input.id] { nextPresetValues[workflow.id, default: [:]][preset.name, default: [:]][input.id] = value }
                }
            }
        }
        values = next; presetValues = nextPresetValues
        definitions = Dictionary(uniqueKeysWithValues: workflows.map { ($0.id, $0.inputs) })
        presets = Dictionary(uniqueKeysWithValues: workflows.map { ($0.id, $0.presets) })
    }
    public mutating func set(_ value: String, workflow: String, input: String) {
        values[workflow, default: [:]][input] = value
        guard let preset = matchingPreset(workflow), preset.values[input] == nil else { return }
        presetValues[workflow, default: [:]][preset.name, default: [:]][input] = value
    }
    /// Fills the preset's values and restores the other inputs as last typed with this preset, or their defaults.
    public mutating func apply(_ preset: Preset, workflow: String) {
        for input in definitions[workflow] ?? [] {
            values[workflow, default: [:]][input.id] = preset.values[input.id] ?? presetValues[workflow]?[preset.name]?[input.id] ?? input.defaultValue ?? ""
        }
    }
    /// The first preset whose values all match the current values, if any.
    public func matchingPreset(_ workflow: Workflow) -> Preset? { matchingPreset(workflow.id) }
    private func matchingPreset(_ workflow: String) -> Preset? {
        presets[workflow]?.first { $0.values.allSatisfy { values[workflow]?[$0.key] == $0.value } }
    }
}
