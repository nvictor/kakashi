import SwiftUI
import AppKit
import Carbon

@main
struct KakashiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                CommandGroup(after: .appInfo) {
                    Button("Check for Updates…") { delegate.updater.checkForUpdates() }
                }
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") { delegate.openSettings() }.keyboardShortcut(",")
                }
                CommandGroup(after: .newItem) {
                    Button("Open Browser") { delegate.openBrowser() }.keyboardShortcut("b")
                    Button("Show Quick Search") { delegate.toggle() }
                }
            }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    let updater = AppUpdater()
    private var status: NSStatusItem!
    private let popover = NSPopover()
    private var browser: NSWindow?
    private var settings: NSWindow?
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var escapeMonitor: Any?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "Kakashi workflows")
        status.button?.image?.isTemplate = true
        status.button?.target = self; status.button?.action = #selector(toggle)
        status.button?.toolTip = "Kakashi"
        popover.behavior = .transient; popover.contentSize = NSSize(width: 490, height: 650)
        model.showBrowser = { [weak self] in self?.openBrowser() }
        model.showSettings = { [weak self] in self?.openSettings() }
        model.closePopover = { [weak self] in self?.popover.performClose(nil) }
        model.checkForUpdates = { [weak self] in self?.popover.performClose(nil); self?.updater.checkForUpdates() }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, pointer in
            guard let pointer else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated { Unmanaged<AppDelegate>.fromOpaque(pointer).takeUnretainedValue().toggle() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        registerShortcut()
        // Escape works even when no control in the popover has focus: back to search, then close.
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == UInt16(kVK_Escape), self.popover.isShown else { return event }
            if self.model.quickDetail {
                self.popover.contentViewController?.view.window?.makeKey()
                self.model.quickDetail = false
            } else { self.popover.performClose(nil) }
            return nil
        }
        if model.folder == nil { openBrowser() }
    }
    func applicationDidBecomeActive(_ notification: Notification) { model.reload() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { openBrowser(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    @objc func toggle() {
        if popover.isShown { popover.performClose(nil); return }
        guard let button = status.button else { return }
        // A new root gives search focus on every opening while the shared model retains inputs.
        model.quickDetail = false
        popover.contentViewController = NSHostingController(rootView: QuickView().environmentObject(model))
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
    func openBrowser() {
        popover.performClose(nil)
        if browser == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.contentViewController = NSHostingController(rootView: BrowserView().environmentObject(model))
            // The sidebar extends under a unified toolbar; the title and actions sit over the detail column.
            window.title = "Kakashi"; window.toolbarStyle = .unified
            window.setContentSize(NSSize(width: 1040, height: 760))
            window.isReleasedWhenClosed = false; window.center(); browser = window
        }
        NSApp.activate(ignoringOtherApps: true); browser?.makeKeyAndOrderFront(nil)
    }
    func openSettings() {
        popover.performClose(nil)
        if settings == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 460), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Kakashi Settings"
            window.contentViewController = NSHostingController(rootView: PreferencesView(register: { [weak self] in self?.registerShortcut() }).environmentObject(model))
            window.isReleasedWhenClosed = false; window.center(); settings = window
        }
        NSApp.activate(ignoringOtherApps: true); settings?.makeKeyAndOrderFront(nil)
    }
    func registerShortcut() {
        if let hotKey { UnregisterEventHotKey(hotKey) }; hotKey = nil
        let defaults = UserDefaults.standard
        let key = defaults.object(forKey: "shortcutKey") == nil ? UInt32(kVK_Space) : UInt32(defaults.integer(forKey: "shortcutKey"))
        let modifiers = defaults.object(forKey: "shortcutModifiers") == nil ? UInt32(optionKey | shiftKey) : UInt32(defaults.integer(forKey: "shortcutModifiers"))
        let result = RegisterEventHotKey(key, modifiers, EventHotKeyID(signature: 0x4B414B41, id: 1), GetApplicationEventTarget(), 0, &hotKey)
        model.shortcutError = result == noErr ? nil : "Shortcut unavailable (\(result)). Choose another combination in Settings."
    }
}
