import AppKit
import MacrophoneKit
import SwiftUI

@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

enum Pane: String, CaseIterable, Identifiable {
    case history, dictation, agents, keepAwake, devices, developer, general
    var id: String { rawValue }
    var title: String {
        switch self {
        case .history: return "History"
        case .dictation: return "Dictation"
        case .agents: return "Agents"
        case .keepAwake: return "Keep Awake"
        case .devices: return "Devices"
        case .developer: return "Developer"
        case .general: return "General"
        }
    }
    var symbol: String {
        switch self {
        case .history: return "clock.arrow.circlepath"
        case .dictation: return "mic"
        case .agents: return "sparkles"
        case .keepAwake: return "cup.and.heat.waves"
        case .devices: return "iphone"
        case .developer: return "chevron.left.forwardslash.chevron.right"
        case .general: return "gearshape"
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) weak var shared: AppDelegate?

    let model = AppModel()
    let updater = Updater()
    private var statusItem: StatusItemController!
    private var mainWindow: MainWindowController?
    private var setupWindow: SetupWindowController?
    private var diagnosticsWindow: NSWindow?

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        Notifier.shared.setUp()
        statusItem = StatusItemController(model: model, updater: updater)
        model.popup.statusItemFrame = { [weak self] in self?.statusItem.visibleFrame }
        model.flashStatusItem = { [weak self] in self?.statusItem.flashReceived() }
        model.statusItemCue = { [weak self] in self?.statusItem.cue($0) }
        model.start()
        updater.start()
        // A way in when the menu bar icon is hidden (a crowded or notched menu bar).
        HotkeyCenter.shared.action = { [weak self] in self?.openMainWindow() }
        HotkeyCenter.shared.apply(model.settings.hotkey)
        // The icon is hidden (crowded menu bar / notch): say how to reach the app, once.
        model.onMenuBarIconHidden = { [weak self] in self?.iconWentMissing() }

        #if DEBUG
        if DebugHooks.run(self) { return }
        #endif

        firstLaunch()
    }

    /// The first launch shows the setup — but never the pairing code once a phone is paired (a
    /// reinstall that kept its pairings, a first run closed after pairing): then only what's
    /// still missing, and nothing at all when it's all there already (Nov 7 2026).
    func firstLaunch() {
        let settings = model.settings
        guard !settings.hasCompletedSetup else { return }
        if model.peers.isEmpty {
            openSetup(.firstRun)
            return
        }
        let granted = model.permissions.accessibility && model.permissions.screenRecording
        if granted && model.launchAtLogin {
            settings.hasCompletedSetup = true
            model.log.add("setup: a phone was already paired and nothing's missing — no setup window")
        } else {
            model.log.add("setup: a phone was already paired — the setup starts after pairing")
            openSetup(.firstRun)
        }
    }

    private func iconWentMissing() {
        let d = UserDefaults.standard
        guard model.settings.hasCompletedSetup, !model.settings.toldAboutHiddenIcon, !d.bool(forKey: "openedForHiddenIcon") else { return }
        #if DEBUG
        if DebugHooks.env["MACROPHONE_SHOW"] != nil { return }
        #endif
        let anyOpen = [mainWindow?.window, setupWindow?.window, diagnosticsWindow].compactMap { $0 }.contains(where: \.isVisible)
        d.set(true, forKey: "openedForHiddenIcon")
        if !anyOpen { openMainWindow() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openMainWindow()
        return true
    }

    // MARK: Windows

    func openMainWindow(pane: Pane? = nil) {
        if mainWindow == nil {
            mainWindow = MainWindowController(model: model, updater: updater)
            mainWindow?.onClose = { [weak self] in self?.windowClosed() }
        }
        if let pane { mainWindow?.select(pane) }
        model.setWindowOpen(true)
        becomeRegular()
        if let w = mainWindow?.window { present(w) }
    }

    func openSetup(_ mode: SetupMode) {
        if setupWindow == nil {
            setupWindow = SetupWindowController(model: model)
            setupWindow?.onClose = { [weak self] in
                self?.model.endPairing()
                self?.setupWindow = nil
                self?.windowClosed()
            }
        }
        setupWindow?.start(mode)
        model.setWindowOpen(true)
        becomeRegular()
        if let w = setupWindow?.window {
            if !w.isVisible { w.center() }
            present(w)
        }
    }

    /// Shows a window in front. macOS 14+ may refuse activation for an app that wasn't clicked (a
    /// login item, a launch from Terminal); the window still has to be seen.
    private func present(_ w: NSWindow) {
        #if DEBUG
        // Behind everything, never key: screencapture -l still reads it.
        if DebugHooks.quietWindows { w.orderBack(nil); return }
        #endif
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()
    }

    func closeSetup() {
        setupWindow?.close()
    }

    /// A phone wants to pair by code: the setup window shows the code to compare.
    func showCodeApproval() {
        if let w = setupWindow?.window {
            becomeRegular()
            present(w)
        } else {
            openSetup(model.peers.isEmpty && !model.settings.hasCompletedSetup ? .firstRun : .pair)
        }
        NSApp.requestUserAttention(.criticalRequest)
    }

    func showDiagnostics() {
        if let w = diagnosticsWindow { becomeRegular(); w.makeKeyAndOrderFront(nil); return }
        let view = DiagnosticsView(model: model, close: { [weak self] in self?.diagnosticsWindow?.close() })
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
                         styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = "Share Diagnostics"
        w.titlebarAppearsTransparent = true
        // The page carries its own serif title; don't say it twice.
        w.titleVisibility = .hidden
        w.minSize = NSSize(width: 520, height: 420)
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = Ink.groundNS
        w.contentView = NSHostingView(rootView: view)
        w.isReleasedWhenClosed = false
        w.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.diagnosticsWindow = nil
                self?.windowClosed()
            }
        }
        diagnosticsWindow = w
        becomeRegular()
        present(w)
    }

    /// A Dock icon while a window is open; back to the menu bar only when the last one closes.
    private func becomeRegular() {
        #if DEBUG
        // Screenshots while someone uses this Mac: no Dock icon, no activation; nothing takes the keyboard.
        if DebugHooks.quietWindows || DebugHooks.env["MACROPHONE_NO_ACTIVATE"] == "1" { return }
        #endif
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        NSApp.activate(ignoringOtherApps: true)
        if #available(macOS 14.0, *) { NSApp.activate() }
    }

    private func windowClosed() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let open = [self.mainWindow?.window, self.setupWindow?.window, self.diagnosticsWindow].compactMap { $0 }.filter(\.isVisible)
            if open.isEmpty { NSApp.setActivationPolicy(.accessory) }
            let targetsShown = [self.mainWindow?.window, self.setupWindow?.window].compactMap { $0 }.contains(where: \.isVisible)
            self.model.setWindowOpen(targetsShown)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// A window sized for a phone (Aa) goes back to its own size before the app is gone.
    func applicationWillTerminate(_ notification: Notification) { model.watch.stopAll() }

    var debugMainWindow: NSWindow? { mainWindow?.window }

    #if DEBUG
    /// The window on screen without taking the keyboard from whatever app is in front
    /// (MACROPHONE_SHOW=quiet-<pane>: frames while someone uses this Mac).
    func debugShowQuietly(_ pane: Pane) {
        if mainWindow == nil { mainWindow = MainWindowController(model: model, updater: updater) }
        mainWindow?.select(pane)
        model.setWindowOpen(true)
        mainWindow?.window?.orderFrontRegardless()
    }
    #endif
    var debugSetupWindow: NSWindow? { setupWindow?.window }
    var debugDiagnosticsWindow: NSWindow? { diagnosticsWindow }
    var debugStatusItem: StatusItemController { statusItem }
    var setupNavForDebug: SetupNav? { setupWindow?.nav }
}
