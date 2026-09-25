import AppKit
import Combine
import WorkflowCore

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var catalog = Catalog()
    @Published private(set) var session = Session()
    @Published var query = "" { didSet { search() } }
    @Published private(set) var results: [SearchResult] = []
    @Published var selectedWorkflowID: String?
    @Published var selectedStepID: String?
    @Published var folder: URL?
    @Published var message: String?
    @Published var updatedWorkflowID: String?
    @Published var scanning = false
    @Published var copying = false
    @Published var copiedStepID: String?
    @Published var shortcutError: String?
    @Published var quickDetail = false
    var showBrowser: (() -> Void)?
    var showSettings: (() -> Void)?
    var closePopover: (() -> Void)?
    var checkForUpdates: (() -> Void)?
    private var access: URL?
    private var generation = 0
    private var searchGeneration = 0
    private var index = SearchIndex([])
    private let watcher = FolderWatcher()
    private var debounce: Task<Void, Never>?
    var workflow: Workflow? { catalog.workflows.first { $0.id == selectedWorkflowID } }
    init() {
        watcher.changed = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.scanning = true
                self.debounce?.cancel()
                self.debounce = Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled else { return }
                    self.reload()
                }
            }
        }
        if let data = UserDefaults.standard.data(forKey: "workflowFolder") {
            do {
                var stale = false
                let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], bookmarkDataIsStale: &stale)
                guard url.startAccessingSecurityScopedResource() else { throw CocoaError(.fileReadNoPermission) }
                access = url; folder = url
                if stale { try persist(url) }
                watcher.start(url.path); reload()
            } catch { message = "Folder access expired or the drive is unavailable. Choose Workflow Folder to reconnect." }
        }
    }
    private func persist(_ url: URL) throws {
        let data = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(data, forKey: "workflowFolder")
    }
    func chooseFolder() {
        closePopover?()
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.prompt = "Choose Workflow Folder"; panel.message = "Kakashi reads .workflow.yaml and .workflow.yml files in this folder."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let started = url.startAccessingSecurityScopedResource()
        do {
            try persist(url)
            access?.stopAccessingSecurityScopedResource(); access = started ? url : nil
            folder = url; message = nil; catalog = Catalog(); session.reconcile([])
            selectedWorkflowID = nil; selectedStepID = nil; index = SearchIndex([]); query = ""; results = []
            watcher.start(url.path); reload(); showBrowser?()
        } catch { if started { url.stopAccessingSecurityScopedResource() }; message = error.localizedDescription }
    }
    func reload() {
        guard let folder else { return }
        generation += 1; let ticket = generation; scanning = true
        Task {
            let next = await Task.detached(priority: .userInitiated) { CatalogReader.scan(folder) }.value
            guard ticket == generation else { return }
            apply(next); scanning = false
        }
    }
    private func apply(_ next: Catalog) {
        if let old = workflow, let new = next.workflows.first(where: { $0.id == old.id }), old != new { updatedWorkflowID = old.id }
        catalog = next; session.reconcile(next.workflows)
        if workflow == nil { selectedWorkflowID = nil; selectedStepID = nil }
        else if !workflow!.steps.contains(where: { $0.id == selectedStepID }) { selectedStepID = workflow!.steps.first?.id }
        let workflows = next.workflows
        let ticket = generation
        Task {
            let nextIndex = await Task.detached { SearchIndex(workflows) }.value
            guard ticket == generation else { return }
            index = nextIndex; search()
        }
    }
    private func search() {
        searchGeneration += 1; let ticket = searchGeneration; let index = index; let query = query
        Task {
            let found = await Task.detached { index.search(query) }.value
            guard ticket == searchGeneration else { return }; results = found
        }
    }
    func select(_ result: SearchResult) {
        selectedWorkflowID = result.workflowID
        selectedStepID = result.stepID ?? workflow?.steps.first?.id
        copiedStepID = nil
    }
    func value(_ input: Input, workflow: Workflow) -> String { session.values[workflow.id]?[input.id] ?? input.defaultValue ?? "" }
    func set(_ value: String, input: Input, workflow: Workflow) { session.set(value, workflow: workflow.id, input: input.id); copiedStepID = nil }
    /// Previews mask secret inputs; only Copy renders the real value.
    func rendered(_ step: Step, workflow: Workflow) -> Result<String, Error> { Result { try Template.render(step, workflow: workflow, values: session.values[workflow.id] ?? [:], masked: true) } }
    func copy(_ step: Step, workflow: Workflow) {
        guard let folder, !copying, !scanning else { return }
        copying = true
        Task {
            let next = await Task.detached(priority: .userInitiated) { CatalogReader.scan(folder) }.value
            defer { copying = false }
            guard self.folder == folder else { return }
            generation += 1; apply(next); scanning = false
            guard let current = next.workflows.first(where: { $0.id == workflow.id }), current == workflow,
                  let currentStep = current.steps.first(where: { $0.id == step.id }) else {
                message = "Workflow changed or became invalid. Review the refreshed preview before copying."; return
            }
            do {
                let text = try Template.render(currentStep, workflow: current, values: session.values[current.id] ?? [:])
                let secret = Template.usesSecret(currentStep, workflow: current)
                guard write(text, secret: secret) else { message = "Could not write to the clipboard."; return }
                copiedStepID = current.id + ":" + currentStep.id
                Task { try? await Task.sleep(for: .seconds(2)); if copiedStepID == current.id + ":" + currentStep.id { copiedStepID = nil } }
            } catch { message = String(describing: error) }
        }
    }
    // Secret commands are marked so clipboard managers skip them, then cleared if still on the clipboard.
    private func write(_ text: String, secret: Bool) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return false }
        guard secret else { return true }
        for marker in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"] { pasteboard.setString("", forType: NSPasteboard.PasteboardType(marker)) }
        let change = pasteboard.changeCount
        Task { try? await Task.sleep(for: .seconds(60)); if pasteboard.changeCount == change { pasteboard.clearContents() } }
        return true
    }
    func installExamples() {
        guard let folder else { chooseFolder(); return }
        do {
            guard let urls = Bundle.main.urls(forResourcesWithExtension: "yaml", subdirectory: nil), !urls.isEmpty else { message = "Bundled examples are unavailable."; return }
            var count = 0
            for source in urls where source.lastPathComponent.hasSuffix(".workflow.yaml") {
                let destination = folder.appendingPathComponent(source.lastPathComponent)
                if FileManager.default.fileExists(atPath: destination.path) { continue }
                // copyItem fails if the destination appears concurrently; it never overwrites.
                try FileManager.default.copyItem(at: source, to: destination); count += 1
            }
            message = count == 0 ? "Examples are already in this folder. Existing files were kept." : "Added \(count) example \(count == 1 ? "workflow" : "workflows"). Existing files were kept."; reload()
        } catch { message = "Could not install examples: \(error.localizedDescription)" }
    }
}
