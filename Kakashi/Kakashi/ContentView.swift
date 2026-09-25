import SwiftUI
import AppKit
import Carbon
import WorkflowCore

struct QuickView: View {
    @EnvironmentObject var model: AppModel
    @State private var selection: String?
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if model.quickDetail { Button { model.quickDetail = false } label: { Label("Back", systemImage: "chevron.left") }.help("Back to search (Escape)") }
                Image(systemName: "terminal").foregroundStyle(.secondary)
                Text("Kakashi").font(.headline)
                Spacer()
                if model.scanning { ProgressView().controlSize(.small) }
                Button { model.showBrowser?() } label: { Image(systemName: "macwindow") }.accessibilityLabel("Open browser window").help("Open browser window")
                Menu { AppActions() } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.button).menuIndicator(.hidden).fixedSize().help("More actions").accessibilityLabel("More actions")
            }.buttonStyle(.borderless).imageScale(.large).padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            if model.quickDetail, let workflow = model.workflow {
                WorkflowDetail(workflow: workflow, compact: true).id(workflow.id)
            } else if model.folder == nil {
                WelcomeView()
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    SearchField(text: $model.query, placeholder: "Search workflows and steps", onSubmit: openSelected, onMove: move)
                    if !model.query.isEmpty {
                        Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear search")
                    }
                }.padding(12).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10)).padding(12)
                if model.results.isEmpty {
                    LibraryEmptyView()
                } else {
                    ScrollViewReader { proxy in
                        List(selection: $selection) {
                            ForEach(model.results) { result in
                                ResultRow(result: result).tag(result.id).id(result.id).listRowSeparator(.hidden)
                                    .contentShape(Rectangle()).onTapGesture { selection = result.id; openSelected() }
                            }
                        }.listStyle(.plain).scrollContentBackground(.hidden)
                            .onKeyPress(.return) { openSelected(); return .handled }
                            .onChange(of: selection) { _, id in if let id { proxy.scrollTo(id) } }
                    }
                }
            }
            StatusView()
            Divider()
            HStack(spacing: 12) {
                if model.quickDetail { Label("Copy, then paste in your terminal", systemImage: "terminal") }
                else { Text("↑ ↓ Select"); Text("↵ Open") }
                Spacer()
                Text(model.quickDetail ? "esc Back" : "esc Close")
            }.font(.caption).foregroundStyle(.secondary).padding(12)
        }.frame(width: 490, height: 650).background(Color(nsColor: .windowBackgroundColor))
            .onAppear { selection = model.results.first?.id }
            .onChange(of: model.results) { _, results in if !results.contains(where: { $0.id == selection }) { selection = results.first?.id } }
            .onChange(of: model.selectedWorkflowID) { _, id in if id == nil { model.quickDetail = false } }
    }
    private func move(_ offset: Int) {
        guard !model.results.isEmpty else { return }
        let index = model.results.firstIndex { $0.id == selection } ?? (offset > 0 ? -1 : model.results.count)
        selection = model.results[min(max(index + offset, 0), model.results.count - 1)].id
    }
    private func openSelected() {
        guard let result = model.results.first(where: { $0.id == selection }) ?? model.results.first else { return }
        model.select(result); model.quickDetail = true
    }
}

/// SwiftUI drops focus requests made before a new field is in a window, so the field
/// takes first responder itself when AppKit attaches it (popover opening or returning from detail).
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onSubmit: () -> Void
    let onMove: (Int) -> Void
    final class Field: NSTextField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.makeFirstResponder(self)
        }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchField
        init(_ parent: SearchField) { self.parent = parent }
        func controlTextDidChange(_ note: Notification) {
            if let field = note.object as? NSTextField { parent.text = field.stringValue }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1)
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1)
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit()
            default: return false
            }
            return true
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.isBordered = false; field.drawsBackground = false; field.focusRingType = .none
        field.font = .preferredFont(forTextStyle: .body); field.placeholderString = placeholder
        field.cell?.isScrollable = true; field.cell?.wraps = false
        field.setAccessibilityLabel(placeholder); field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }
    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }
}

struct BrowserView: View {
    @EnvironmentObject var model: AppModel
    @State private var selection: String?
    var body: some View {
        NavigationSplitView {
            List(selection: $selection) { ForEach(model.results) { result in ResultRow(result: result).tag(result.id) } }
                .listStyle(.sidebar)
                .overlay {
                    if model.results.isEmpty, model.folder != nil {
                        VStack(spacing: 8) {
                            Image(systemName: "magnifyingglass").font(.title2)
                            Text(model.scanning ? "Reading workflows…" : model.query.isEmpty ? "No workflows yet" : "No results").font(.callout)
                            if !model.query.isEmpty { Button("Clear Search") { model.query = "" }.buttonStyle(.borderless) }
                        }.foregroundStyle(.secondary).padding()
                    }
                }
                .searchable(text: $model.query, placement: .sidebar, prompt: "Search workflows and steps")
                .onChange(of: selection) { _, id in if let result = model.results.first(where: { $0.id == id }) { model.select(result) } }
                .safeAreaInset(edge: .bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Divider()
                        HStack {
                            Text("\(model.catalog.workflows.count) workflows").font(.caption)
                            Spacer()
                            if model.scanning { ProgressView().controlSize(.mini) }
                        }.foregroundStyle(.secondary)
                        Button(action: model.chooseFolder) {
                            Label(model.folder?.lastPathComponent ?? "Choose Folder…", systemImage: "folder").lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.borderless).foregroundStyle(.secondary)
                            .help(model.folder.map { "Workflow folder: \($0.path). Click to choose another." } ?? "Choose a workflow folder")
                    }.padding(12)
                }
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 380)
        } detail: {
            VStack(spacing: 0) {
                if let workflow = model.workflow { WorkflowDetail(workflow: workflow, compact: false).id(workflow.id) }
                else if model.folder == nil { WelcomeView() }
                else if model.catalog.workflows.isEmpty { LibraryEmptyView() }
                else {
                    ContentUnavailableView("Choose a workflow", systemImage: "square.stack.3d.up", description: Text("Select a task from the sidebar to prepare your commands."))
                }
                StatusView()
            }
            .navigationTitle("Kakashi")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { model.reload() } label: { Label("Reload", systemImage: "arrow.clockwise") }.disabled(model.folder == nil || model.scanning).help("Reload workflows")
                    Button { model.showSettings?() } label: { Label("Settings", systemImage: "gearshape") }.help("Settings")
                }
            }
        }
        // The hosting controller derives the window's minimum from SwiftUI, so the limit lives here.
        .frame(minWidth: 760, minHeight: 520)
        .onChange(of: model.selectedWorkflowID) { _, id in
            if selection?.hasPrefix((id ?? "") + ":") != true { selection = id.map { $0 + ":" } }
        }
        .onAppear { selection = model.selectedWorkflowID.map { $0 + ":" } }
    }
}
struct ResultRow: View {
    let result: SearchResult
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: result.stepID == nil ? "square.stack.3d.up" : "terminal")
                .font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary).frame(width: 22).padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                Text(result.title).font(.body.weight(.medium)).lineLimit(2)
                Text(result.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }.padding(.vertical, 7).accessibilityElement(children: .combine)
    }
}
struct WorkflowDetail: View {
    @EnvironmentObject var model: AppModel
    let workflow: Workflow
    let compact: Bool
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: compact ? 20 : 26) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("WORKFLOW", systemImage: "square.stack.3d.up").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Spacer()
                            Menu {
                                Button("Open Source") { NSWorkspace.shared.open(workflow.source) }
                                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([workflow.source]) }
                            } label: { Image(systemName: "doc.text") }
                                .menuStyle(.borderlessButton).fixedSize().help("Workflow source").accessibilityLabel("Workflow source")
                        }
                        Text(workflow.title).font(compact ? .title2.bold() : .system(size: 28, weight: .bold)).fixedSize(horizontal: false, vertical: true)
                        if !workflow.description.isEmpty { Text(workflow.description).foregroundStyle(.secondary).textSelection(.enabled) }
                        if !workflow.tags.isEmpty {
                            Text(workflow.tags.joined(separator: "  ·  ")).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        }
                        if model.updatedWorkflowID == workflow.id { Label("Workflow updated. Review the refreshed commands.", systemImage: "arrow.triangle.2.circlepath").font(.callout).foregroundStyle(.orange) }
                    }
                    .id("workflow-top")
                    if !workflow.inputs.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("Shared inputs", systemImage: "slider.horizontal.3").font(.headline)
                                Text("Fill in once. Used across the steps below.").font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(workflow.inputs) { input in InputField(input: input, workflow: workflow).id(workflow.id + ":" + input.id) }
                        }.padding(16).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        HStack { Text("Steps").font(.headline); Spacer(); Text("\(workflow.steps.count) total").font(.caption).foregroundStyle(.secondary) }
                        if compact && workflow.steps.count > 1 { StepNavigation(workflow: workflow) }
                        ForEach(Array(workflow.steps.enumerated()), id: \.element.id) { i, step in
                            if !compact || step.id == (model.selectedStepID ?? workflow.steps[0].id) { StepCard(step: step, workflow: workflow, number: i + 1).id(step.id) }
                        }
                    }
                    if !compact {
                        Label("Commands are copied, never run.", systemImage: "terminal").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(compact ? 18 : 28).frame(maxWidth: 820, alignment: .leading).frame(maxWidth: .infinity)
            }
            .onAppear {
                if !compact, let id = model.selectedStepID, id != workflow.steps.first?.id { proxy.scrollTo(id, anchor: .top) }
            }
            .onChange(of: model.selectedStepID) { _, id in
                if !compact, let id { proxy.scrollTo(id == workflow.steps.first?.id ? "workflow-top" : id, anchor: .top) }
            }
        }
    }
}
struct InputField: View {
    @EnvironmentObject var model: AppModel
    let input: Input
    let workflow: Workflow
    var value: Binding<String> { Binding(get: { model.value(input, workflow: workflow) }, set: { model.set($0, input: input, workflow: workflow) }) }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack { Text(input.label).font(.callout.weight(.medium)); Text(input.required ? "Required" : "Optional").font(.caption).foregroundStyle(.secondary) }
            if input.type == .choice {
                Picker(input.label, selection: value) { Text("Choose…").tag(""); ForEach(input.options, id: \.self) { Text($0).tag($0) } }.labelsHidden().accessibilityLabel(input.label)
            } else if input.type == .secret {
                SecureField("Enter a secret", text: value).textFieldStyle(.roundedBorder).accessibilityLabel(input.label)
                Text("Hidden in previews. Kept in memory only and cleared from the clipboard after 60 seconds.").font(.caption).foregroundStyle(.secondary)
            } else { TextField(input.type == .path ? "/absolute/path" : "Enter a value", text: value).textFieldStyle(.roundedBorder).accessibilityLabel(input.label) }
            if !input.description.isEmpty { Text(input.description).font(.caption).foregroundStyle(.secondary) }
            if input.type == .path { Text("Use an absolute path. ~, variables, and wildcards stay literal.").font(.caption).foregroundStyle(.secondary) }
            if !value.wrappedValue.isEmpty, let error = Template.inputError(input, value: value.wrappedValue) {
                Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red)
            }
        }
    }
}
struct LibraryEmptyView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 14) {
            if model.scanning {
                ProgressView()
                Text("Reading workflows…").foregroundStyle(.secondary)
            } else {
                Image(systemName: symbol).font(.system(size: 32, weight: .light)).foregroundStyle(.secondary)
                Text(title).font(.title3.weight(.semibold))
                Text(description).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if model.catalog.ioFailure {
                    Button("Choose Folder…", action: model.chooseFolder).buttonStyle(.borderedProminent)
                } else if model.catalog.workflows.isEmpty && model.catalog.diagnostics.isEmpty {
                    Button("Install Examples", action: model.installExamples).buttonStyle(.borderedProminent)
                    Button("Choose Another Folder…", action: model.chooseFolder).buttonStyle(.borderless)
                } else if !model.query.isEmpty {
                    Button("Clear Search") { model.query = "" }.buttonStyle(.bordered)
                }
            }
        }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var symbol: String { model.catalog.ioFailure ? "folder.badge.questionmark" : model.catalog.workflows.isEmpty ? "folder" : "magnifyingglass" }
    private var title: String {
        if model.catalog.ioFailure { return "Reconnect your folder" }
        if model.catalog.workflows.isEmpty { return model.catalog.diagnostics.isEmpty ? "Your first workflow starts here" : "Workflows need attention" }
        return "No matching workflows"
    }
    private var description: String {
        if model.catalog.ioFailure { return "Choose your workflow folder again to restore access." }
        if model.catalog.workflows.isEmpty {
            return model.catalog.diagnostics.isEmpty
                ? "Add workflow files to this folder, or start with three editable examples."
                : "Open the source problems below to see which files need fixing."
        }
        return "Try a task name, tag, or command."
    }
}

struct StepNavigation: View {
    @EnvironmentObject var model: AppModel
    let workflow: Workflow
    private var index: Int { workflow.steps.firstIndex { $0.id == model.selectedStepID } ?? 0 }
    var body: some View {
        HStack(spacing: 8) {
            Button { model.selectedStepID = workflow.steps[index - 1].id } label: { Image(systemName: "chevron.left") }
                .disabled(index == 0).accessibilityLabel("Previous step").help("Previous step")
            Picker("Step", selection: Binding(get: { workflow.steps[index].id }, set: { model.selectedStepID = $0 })) {
                ForEach(Array(workflow.steps.enumerated()), id: \.element.id) { i, step in Text("\(i + 1). \(step.title)").tag(step.id) }
            }.labelsHidden().frame(maxWidth: .infinity).accessibilityLabel("Choose a step")
            Button { model.selectedStepID = workflow.steps[index + 1].id } label: { Image(systemName: "chevron.right") }
                .disabled(index == workflow.steps.count - 1).accessibilityLabel("Next step").help("Next step")
        }
    }
}

struct StepCard: View {
    @EnvironmentObject var model: AppModel
    let step: Step
    let workflow: Workflow
    let number: Int
    @FocusState private var previewFocused: Bool
    var body: some View {
        let result = model.rendered(step, workflow: workflow)
        let copied = model.copiedStepID == workflow.id + ":" + step.id
        let missing = missingInputs
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Text(String(format: "%02d", number))
                    .font(.system(.caption, design: .monospaced).weight(.medium)).foregroundStyle(.secondary)
                    .frame(width: 28, height: 28).background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 5) {
                    Text(step.title).font(.headline)
                    if !step.description.isEmpty { Text(step.description).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }.padding(.top, 3)
                Spacer(minLength: 0)
                Button { model.copy(step, workflow: workflow) } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc").frame(minWidth: 62)
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .tint((try? result.get()) == nil ? Color.secondary : Color.accentColor)
                .disabled((try? result.get()) == nil || model.scanning || model.copying)
                .accessibilityLabel(copied ? "Copied \(step.title)" : "Copy \(step.title)")
                .help(missing.isEmpty ? "Copy command to the clipboard" : "Fill in \(missing.joined(separator: ", ")) to copy")
            }
            switch result {
            case .success(let command):
                commandPreview(command, ready: true)
                    .focusable().focused($previewFocused)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(previewFocused ? Color.accentColor : .clear, lineWidth: 2))
                    .accessibilityLabel("Command preview: \(command)")
                    .onKeyPress(keys: ["c"], phases: .down) { press in
                        guard previewFocused, press.modifiers == .command else { return .ignored }
                        model.copy(step, workflow: workflow); return .handled
                    }
                if Template.usesSecret(step, workflow: workflow) {
                    Label("Secret hidden. The copied command includes its value.", systemImage: "lock").font(.caption).foregroundStyle(.secondary)
                }
            case .failure(let error):
                commandPreview(step.command.trimmingCharacters(in: .newlines), ready: false)
                if !missing.isEmpty {
                    Label("Fill in \(missing.joined(separator: ", ")) above to prepare this command.", systemImage: "slider.horizontal.3")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Label(String(describing: error), systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
                }
            }
        }.padding(16).background(.background, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(copied ? Color.accentColor.opacity(0.6) : Color(nsColor: .separatorColor).opacity(0.5)))
    }
    private var missingInputs: [String] {
        let references = (try? Template.references(step.command, known: Set(workflow.inputs.map(\.id)))) ?? []
        return workflow.inputs.filter { references.contains($0.id) && $0.required && model.value($0, workflow: workflow).isEmpty }.map(\.label)
    }
    private func commandPreview(_ text: String, ready: Bool) -> some View {
        ScrollView(.horizontal) {
            Text(text).font(.system(.callout, design: .monospaced)).lineSpacing(4)
                .foregroundStyle(ready ? .primary : .secondary).textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: true).padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct StatusView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message = model.message { HStack(alignment: .top) { Text(message).font(.callout); Spacer(); Button { model.message = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).accessibilityLabel("Dismiss message").help("Dismiss") } }
            if let error = model.shortcutError { Text(error).font(.caption).foregroundStyle(.orange) }
            if !model.catalog.diagnostics.isEmpty {
                DisclosureGroup("\(model.catalog.diagnostics.count) source \(model.catalog.diagnostics.count == 1 ? "problem" : "problems")") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(model.catalog.diagnostics.enumerated()), id: \.offset) { _, d in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(d.file + (d.line.map { ":\($0):\(d.column ?? 1)" } ?? "")).font(.caption.monospaced()).textSelection(.enabled)
                                    Text("\(d.field): \(d.message)").font(.caption).textSelection(.enabled)
                                    Button("Reveal Source") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: d.file)]) }.controlSize(.small).help("Show this file in Finder")
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 150)
                }.foregroundStyle(.orange)
            }
        }.padding(model.message != nil || !model.catalog.diagnostics.isEmpty || model.shortcutError != nil ? 12 : 0)
    }
}
struct WelcomeView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 72, height: 72)
                    .accessibilityHidden(true)
                Text("Your next command,\nready to copy.").font(.largeTitle.bold())
                Text("Keep task recipes in a local folder. Kakashi helps you find the steps, fill in shared inputs, and copy each command.").foregroundStyle(.secondary)
                Button("Choose Workflow Folder", action: model.chooseFolder).buttonStyle(.borderedProminent).controlSize(.large)
                VStack(alignment: .leading, spacing: 12) {
                    Label("EXAMPLE WORKFLOW", systemImage: "terminal").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text("Inspect a listening port").font(.headline)
                    Text("See which process is listening on a local TCP port.").font(.callout).foregroundStyle(.secondary)
                    Text("lsof -nP -iTCP:8080 -sTCP:LISTEN").font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                }.padding(16).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                Text("New to workflows? Choose an empty folder, then install the examples to get started.").font(.caption).foregroundStyle(.secondary)
                Label("Local files. Commands are copied, never run.", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
            }.padding(28).frame(maxWidth: 620, alignment: .leading)
        }
    }
}
struct AppActions: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Section {
            Button("Choose Workflow Folder…", systemImage: "folder", action: model.chooseFolder)
            Button("Install Examples", systemImage: "square.and.arrow.down", action: model.installExamples).disabled(model.folder == nil)
            Button("Reload", systemImage: "arrow.clockwise", action: model.reload).disabled(model.folder == nil)
        }
        Section {
            Button("Settings…", systemImage: "gearshape") { model.showSettings?() }
            Button("Check for Updates…", systemImage: "arrow.down.circle") { model.checkForUpdates?() }
        }
        Section {
            Button("Quit Kakashi", systemImage: "power") { NSApp.terminate(nil) }.keyboardShortcut("q")
        }
    }
}
struct PreferencesView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("shortcutKey") var key = Int(kVK_Space)
    @AppStorage("shortcutModifiers") var modifiers = Int(optionKey | shiftKey)
    let register: () -> Void
    var body: some View {
        Form {
            Section("Workflow folder") {
                Text(model.folder?.path ?? "No folder selected").textSelection(.enabled).font(.callout)
                HStack { Button("Choose Folder…", action: model.chooseFolder).help("Choose the folder Kakashi reads"); Button("Install Examples", action: model.installExamples).disabled(model.folder == nil).help("Copy three example workflows into the folder. Existing files are kept.") }
            }
            Section("Global shortcut") {
                Picker("Modifiers", selection: $modifiers) {
                    Text("Option + Shift").tag(Int(optionKey | shiftKey))
                    Text("Control + Option").tag(Int(controlKey | optionKey))
                    Text("Command + Shift").tag(Int(cmdKey | shiftKey))
                    Text("Control + Option + Shift").tag(Int(controlKey | optionKey | shiftKey))
                }
                Picker("Key", selection: $key) { Text("Space").tag(Int(kVK_Space)); Text("K").tag(Int(kVK_ANSI_K)); Text("J").tag(Int(kVK_ANSI_J)) }
                if let error = model.shortcutError { Text(error).foregroundStyle(.red) }
            }
            Section("Updates") {
                Button("Check for Updates…") { model.checkForUpdates?() }
            }
            Section("Privacy") {
                Text("Input values stay in memory until you quit. Use secret inputs for tokens and passwords: they are hidden in previews, never allowed as defaults, and cleared from the clipboard after 60 seconds.").font(.callout).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).frame(width: 500, height: 460)
            .onChange(of: key) { _, _ in register() }.onChange(of: modifiers) { _, _ in register() }
    }
}
