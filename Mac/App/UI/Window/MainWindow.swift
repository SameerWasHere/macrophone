import AppKit
import MacrophoneKit
import SwiftUI

/// Which section the window shows. Remembered across opens, like System Settings.
final class MainNav: ObservableObject {
    @Published var pane: Pane? {
        didSet { if let pane { AppPaths.defaults.set(pane.rawValue, forKey: Self.key) } }
    }
    private static let key = "window.pane"

    init() {
        pane = AppPaths.defaults.string(forKey: Self.key).flatMap(Pane.init(rawValue:)) ?? .history
    }
}

/// The standard menus, built the first time a window opens (the app has no storyboard).
/// Without them ⌘C, ⌘V and ⌘A do nothing in a text field, and ⌘W / ⌘Q do nothing at all.
/// The menu bar app's own menu is untouched; this is the menu across the top of the screen
/// while a window is open.
@MainActor
enum AppMenu {
    static func installIfNeeded() {
        guard NSApp.mainMenu == nil else { return }
        let main = NSMenu()

        let appItem = NSMenuItem()
        let app = NSMenu(title: "Macrophone")
        app.addItem(withTitle: "About Macrophone", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Macrophone", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Macrophone", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowItem.submenu = window
        main.addItem(windowItem)

        NSApp.mainMenu = main
        NSApp.windowsMenu = window
    }
}

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    let nav = MainNav()
    var onClose: () -> Void = {}

    init(model: AppModel, updater: Updater) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 660),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "Macrophone"
        w.minSize = NSSize(width: 780, height: 520)
        w.isReleasedWhenClosed = false
        w.setFrameAutosaveName("MacrophoneMainWindow")
        // System Settings' window: one unified toolbar over the sidebar and the pane (Nov 7 2026).
        w.toolbarStyle = .unified
        super.init(window: w)
        AppMenu.installIfNeeded()
        let root = MainView(model: model, updater: updater, nav: nav)
        let host = NSHostingController(rootView: root)
        // The pane's title and Send to live in the window's own toolbar.
        host.sceneBridgingOptions = [.toolbars, .title]
        // The window keeps the size it's given (and remembered); SwiftUI doesn't resize it to its content.
        host.sizingOptions = []
        w.contentViewController = host
        // The keyboard starts in SwiftUI's own default focus (the sidebar), not AppKit's first text view.
        w.initialFirstResponder = host.view
        w.setContentSize(NSSize(width: 940, height: 660))
        if !w.setFrameUsingName("MacrophoneMainWindow") { w.center() }
        w.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func select(_ pane: Pane) { nav.pane = pane }

    func windowWillClose(_ notification: Notification) { onClose() }
}

/// The window as macOS Settings draws one (Nov 7 2026): a glass sidebar of coloured icon tiles,
/// the pane as a grouped form, and Send to — the choice the iPhone and this Mac share — in the
/// toolbar above every pane.
struct MainView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updater: Updater
    @ObservedObject var nav: MainNav

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model, nav: nav)
                .navigationSplitViewColumnWidth(min: 220, ideal: 230, max: 320)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            VStack(spacing: 0) {
                PaneNotices(model: model, settings: model.settings)
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle((nav.pane ?? .history).title)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    SendToToolbar(model: model, settings: model.settings)
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 780, minHeight: 520)
    }

    @ViewBuilder private var detail: some View {
        switch nav.pane ?? .history {
        case .history: HistoryPane(model: model, settings: model.settings)
        case .dictation: DictationPane(model: model, settings: model.settings, desk: model.desk, wake: model.wake!, permissions: model.permissions)
        case .agents: AgentsPane(model: model, settings: model.settings)
        case .keepAwake: KeepAwakePane(keepAwake: model.keepAwake)
        case .devices: DevicesPane(model: model)
        case .developer: DeveloperPane(model: model, settings: model.settings)
        case .general: GeneralPane(model: model, settings: model.settings, updater: updater, notifier: Notifier.shared)
        }
    }
}

/// The notices above every pane, each only while it matters: the menu bar is hiding the icon
/// (once), or pasting can't happen because Accessibility is off.
struct PaneNotices: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: Settings

    private var hiddenIcon: Bool { model.menuBarIconHidden && !settings.toldAboutHiddenIcon }
    private var noAccessibility: Bool { !model.accessibilityGranted && settings.selection.target.canSend }

    var body: some View {
        if hiddenIcon || noAccessibility {
            VStack(spacing: 8) {
                if hiddenIcon { HiddenIconNotice(settings: settings) }
                if noAccessibility {
                    PaneBanner(symbol: "hand.raised.fill", title: "Pasting needs Accessibility",
                               detail: "Until it's on, dictations are copied instead of pasted.") {
                        Button("Open System Settings") {
                            Paster.requestTrust()
                            NSWorkspace.shared.open(Paster.accessibilitySettingsURL)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .frame(maxWidth: .infinity)
            .layoutPriority(1)
        }
    }
}

/// Shown once when the menu bar is hiding Macrophone's icon: how to reach the app without it.
struct HiddenIconNotice: View {
    @ObservedObject var settings: Settings

    var body: some View {
        PaneBanner(symbol: "menubar.dock.rectangle", tint: Light.cyan,
                   title: "Your menu bar is hiding Macrophone's icon", detail: detail) {
            Button("Got It") { settings.toldAboutHiddenIcon = true }
        }
    }

    private var detail: String {
        let how = settings.hotkey.enabled
            ? "To open Macrophone, press \(settings.hotkey.display) anywhere, or open it from Spotlight or Finder."
            : "To open Macrophone, open it from Spotlight or Finder — or set a shortcut in General."
        return "There isn't room for it (often the notch covers it). Dictations still arrive and the popup shows at the top right of your screen. " + how
    }
}

/// System Settings' sidebar: the connected iPhone at the top like the account card, then every
/// section with its coloured tile. Built from `Pane.allCases`, so a new pane is a new case.
struct Sidebar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var nav: MainNav
    /// The sidebar has the keyboard when the window opens, as System Settings' does (a pane's first
    /// text box — Dictation's Try it — took it and scrolled the form down to it).
    @FocusState private var focused: Bool

    var body: some View {
        List(selection: $nav.pane) {
            Section {
                PhoneCard(model: model)
                    .contentShape(Rectangle())
                    .onTapGesture { nav.pane = .devices }
                    .listRowSeparator(.hidden)
            }
            Section {
                ForEach(Pane.allCases) { p in
                    Label {
                        Text(p.title)
                    } icon: {
                        SettingsIcon(p.symbol, color: p.tint, size: 20)
                    }
                    .tag(p)
                    .help("\(p.title)  ⌘\(p.ordinal)")
                    .accessibilityLabel(p.title)
                }
            }
        }
        .listStyle(.sidebar)
        // The column takes the width its content asks for on macOS 26+ (navigationSplitViewColumnWidth
        // alone left it 144 pt and the phone's name cut short).
        .frame(minWidth: 220, idealWidth: 230)
        .focused($focused)
        .defaultFocus($focused, true)
        .accessibilityLabel("Sections")
        // ⌘1 … ⌘6 pick a section, as in Mail and Xcode. The buttons draw nothing.
        .background(
            ForEach(Pane.allCases) { p in
                Button("") { nav.pane = p }
                    .keyboardShortcut(KeyEquivalent(Character(String(p.ordinal))), modifiers: .command)
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        )
    }
}

/// The sidebar's top: who's connected, as System Settings shows your account — a round glyph,
/// the phone's name, and how it stands. A click opens Devices.
struct PhoneCard: View {
    @ObservedObject var model: AppModel

    private var on: PairedPeer? { model.connectedPeer }

    private var title: String {
        if let on { return model.displayName(on) }
        if let first = model.peers.first, model.peers.count == 1 { return model.displayName(first) }
        if model.peers.isEmpty { return "Pair your iPhone" }
        return "Your iPhones"
    }

    private var line: String {
        if on != nil {
            if let last = model.lastReceived { return "Connected · last received \(last.relativeShort)" }
            let s = model.statusLine
            if let r = s.range(of: " · ") { return "Connected · " + s[r.upperBound...] }
            return "Connected"
        }
        if model.peers.isEmpty { return "To dictate from it" }
        return "Not connected"
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "iphone.gen3")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill((on != nil ? MacTint.blue : MacTint.gray).gradient))
                Circle().fill(on != nil ? Light.mint : Color.clear)
                    .frame(width: 10, height: 10)
                    .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: on != nil ? 2 : 0))
                    .offset(x: 2, y: 2)
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(line).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(on != nil ? "\(title), connected" : "\(title). \(model.statusLine)")
        .accessibilityHint("Opens Devices")
        .accessibilityAddTraits(.isButton)
    }
}

extension Pane {
    /// Its ⌘ number in the sidebar's order.
    var ordinal: Int { (Pane.allCases.firstIndex(of: self) ?? 0) + 1 }
}
