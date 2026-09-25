import Foundation
import WorkflowCore

let args = Array(CommandLine.arguments.dropFirst())
guard (args.count == 2 || args.count == 4), args.first == "validate", args.count != 4 || Array(args.suffix(2)) == ["--format", "json"] else {
    FileHandle.standardError.write(Data("Usage: workflow-validator validate DIRECTORY [--format json]\n".utf8))
    exit(2)
}
let catalog = CatalogReader.scan(URL(fileURLWithPath: args[1], isDirectory: true))
if args.count == 4 {
    struct Report: Encodable { let valid: Bool; let files_checked: Int; let diagnostics: [Diagnostic] }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    do {
        let data = try encoder.encode(Report(valid: catalog.valid, files_checked: catalog.filesChecked, diagnostics: catalog.diagnostics))
        FileHandle.standardOutput.write(data); print("")
    } catch { exit(2) }
} else {
    for d in catalog.diagnostics { print("\(d.file)\(d.line.map { ":\($0):\(d.column ?? 1)" } ?? ""): \(d.field) [\(d.code)] \(d.message)") }
    print("\(catalog.valid ? "Valid" : "Invalid"): \(catalog.filesChecked) file(s), \(catalog.diagnostics.count) diagnostic(s).")
}
exit(catalog.ioFailure ? 2 : catalog.valid ? 0 : 1)
