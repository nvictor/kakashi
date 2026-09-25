import Foundation

public enum CatalogReader {
    public static func scan(_ directory: URL) -> Catalog {
        var catalog = Catalog()
        let fm = FileManager.default
        do {
            let info = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard info.isDirectory == true, info.isSymbolicLink != true else { throw CocoaError(.fileReadUnsupportedScheme) }
            _ = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        } catch {
            catalog.ioFailure = true
            catalog.diagnostics.append(Diagnostic(file: directory.path, code: "io", message: "Cannot read workflow folder. Choose it again. \(error.localizedDescription)"))
            return catalog
        }
        var enumerationErrors: [Diagnostic] = []
        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles], errorHandler: { url, error in
            enumerationErrors.append(Diagnostic(file: url.path, code: "io", message: error.localizedDescription)); return true
        }) else { catalog.ioFailure = true; catalog.diagnostics = [Diagnostic(file: directory.path, code: "io", message: "Cannot enumerate folder.")]; return catalog }
        for case let url as URL in enumerator {
            do {
                let info = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey])
                if info.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                guard info.isRegularFile == true, url.lastPathComponent.hasSuffix(".workflow.yaml") || url.lastPathComponent.hasSuffix(".workflow.yml") else { continue }
                catalog.filesChecked += 1
                guard (info.fileSize ?? 0) <= 1_048_576 else { throw Diagnostic(file: url.path, code: "file-size", message: "Maximum file size is 1 MiB.") }
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: 1_048_577) ?? Data()
                guard data.count <= 1_048_576 else { throw Diagnostic(file: url.path, code: "file-size", message: "Maximum file size is 1 MiB.") }
                guard let text = String(data: data, encoding: .utf8) else { throw Diagnostic(file: url.path, code: "encoding", message: "Use UTF-8 encoding.") }
                catalog.workflows.append(try WorkflowParser.parse(text, source: url))
            } catch let diagnostic as Diagnostic { catalog.diagnostics.append(diagnostic) }
            catch { catalog.ioFailure = true; catalog.diagnostics.append(Diagnostic(file: url.path, code: "io", message: error.localizedDescription)) }
        }
        if !enumerationErrors.isEmpty { catalog.ioFailure = true; catalog.diagnostics += enumerationErrors }
        let groups = Dictionary(grouping: catalog.workflows, by: \.id)
        let duplicates = Set(groups.filter { $0.value.count > 1 }.keys)
        for workflow in catalog.workflows where duplicates.contains(workflow.id) {
            catalog.diagnostics.append(Diagnostic(file: workflow.source.path, field: "id", code: "duplicate-id", message: "Workflow ID '\(workflow.id)' also appears in another file. Change every conflicting ID."))
        }
        catalog.workflows.removeAll { duplicates.contains($0.id) }
        catalog.workflows.sort { ($0.title.lowercased(), $0.id) < ($1.title.lowercased(), $1.id) }
        catalog.diagnostics.sort { ($0.file, $0.field) < ($1.file, $1.field) }
        return catalog
    }
}
public struct SearchResult: Identifiable, Equatable, Sendable {
    public var workflowID: String
    public var stepID: String?
    public var title: String
    public var subtitle: String
    public var id: String { workflowID + ":" + (stepID ?? "") }
}
public struct SearchIndex: Sendable {
    private struct Entry: Sendable {
        var result: SearchResult
        var title: String
        var text: String
    }
    private var entries: [Entry] = []
    public init(_ workflows: [Workflow]) {
        for w in workflows {
            let context = ([w.title, w.description] + w.tags).joined(separator: " ").lowercased()
            entries.append(Entry(result: SearchResult(workflowID: w.id, title: w.title, subtitle: (["\(w.steps.count) step\(w.steps.count == 1 ? "" : "s")"] + (w.tags.isEmpty ? [] : [w.tags.joined(separator: ", ")])).joined(separator: " · ")), title: w.title.lowercased(), text: context))
            for s in w.steps {
                entries.append(Entry(result: SearchResult(workflowID: w.id, stepID: s.id, title: s.title, subtitle: w.title), title: s.title.lowercased(), text: context + " " + [s.title, s.description, s.command].joined(separator: " ").lowercased()))
            }
        }
    }
    public func search(_ query: String) -> [SearchResult] {
        let tokens = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let normalized = tokens.joined(separator: " ")
        if tokens.isEmpty { return entries.filter { $0.result.stepID == nil }.sorted { ($0.title, $0.result.id) < ($1.title, $1.result.id) }.map(\.result) }
        return entries.filter { e in tokens.allSatisfy { e.text.contains($0) } }.map { e -> (Int, Entry) in
            let score = e.title == normalized ? 0 : e.title.hasPrefix(normalized) ? 1 : tokens.allSatisfy({ e.title.contains($0) }) ? 2 : 3
            return (score, e)
        }.sorted { ($0.0, $0.1.title, $0.1.result.id) < ($1.0, $1.1.title, $1.1.result.id) }.map { $0.1.result }
    }
}
