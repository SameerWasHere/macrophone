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
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = Ink.groundNS
        w.minSize = NSSize(width: 780, height: 520)
        w.isReleasedWhenClosed = false
        w.setFrameAutosaveName("MacrophoneMainWindow")
        w.toolbarStyle = .unified
        super.init(window: w)
        AppMenu.installIfNeeded()
        let root = MainView(model: model, updater: updater, nav: nav)
        w.contentViewController = NSHostingController(rootView: root)
        w.setContentSize(NSSize(width: 940, height: 660))
        if !w.setFrameUsingName("MacrophoneMainWindow") { w.center() }
        w.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func select(_ pane: Pane) { nav.pane = pane }

    func windowWillClose(_ notification: Notification) { onClose() }
}

struct MainView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updater: Updater
    @ObservedObject var nav: MainNav

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model, nav: nav)
                .navigationSplitViewColumnWidth(220)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            ZStack {
                Ink.ground.ignoresSafeArea()
                VStack(spacing: 0) {
                    HiddenIconSlot(model: model, settings: model.settings)
                    // Where dictations go — the choice the iPhone and this Mac share — above
                    // every pane.
                    SendToCard(model: model, settings: model.settings)
                        .padding(.horizontal, 32)
                        .padding(.top, 4)
                        .padding(.bottom, 18)
                        .frame(maxWidth: 760, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    detail
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .preferredColorScheme(.dark)
        .tint(Light.teal)
        .frame(minWidth: 780, minHeight: 520)
    }

    @ViewBuilder private var detail: some View {
        switch nav.pane ?? .history {
        case .history: HistoryPane(model: model, settings: model.settings)
        case .agents: AgentsPane(model: model, settings: model.settings)
        case .devices: DevicesPane(model: model)
        case .developer: DeveloperPane(model: model, settings: model.settings)
        case .general: GeneralPane(model: model, settings: model.settings, updater: updater, notifier: Notifier.shared)
        }
    }
}

/// The notice's place above every pane (empty unless the icon is hidden and it hasn't been seen).
struct HiddenIconSlot: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: Settings

    private var showing: Bool { model.menuBarIconHidden && !settings.toldAboutHiddenIcon }

    var body: some View {
        if showing {
            HiddenIconNotice(settings: settings)
                .padding(.horizontal, 32)
                .padding(.top, 2)
                .padding(.bottom, 14)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
        }
    }
}

/// Shown once when the menu bar is hiding Macrophone's icon: how to reach the app without it.
struct HiddenIconNotice: View {
    @ObservedObject var settings: Settings

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "menubar.dock.rectangle")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(Light.cyan)
                .frame(width: 24)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Your menu bar is hiding Macrophone's icon")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.ink)
                // No fixedSize here: outside the pane's scroll view, a fixed-height text makes
                // the window's minimum size enormous and SwiftUI draws nothing at all.
                Text(body1)
                    .font(.system(size: 12)).foregroundStyle(Ink.secondary)
            }
            Spacer(minLength: 12)
            Button("Got It") { settings.toldAboutHiddenIcon = true }
                .buttonStyle(PillButtonStyle(tint: Ink.ink, filled: true))
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Light.cyan.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Light.cyan.opacity(0.28), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private var body1: String {
        let how = settings.hotkey.enabled
            ? "To open Macrophone, press \(settings.hotkey.display) anywhere, or open it from Spotlight or Finder."
            : "To open Macrophone, open it from Spotlight or Finder — or set a shortcut in General."
        return "There isn't room for it (often the notch covers it). Dictations still arrive and the popup shows at the top right of your screen. " + how
    }
}

struct Sidebar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var nav: MainNav

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: $nav.pane) {
                ForEach(Pane.allCases) { p in
                    Label(p.title, systemImage: p.symbol)
                        .tag(p)
                        .padding(.vertical, 2)
                        .help("\(p.title)  ⌘\(p.ordinal)")
                        .accessibilityLabel(p.title)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .accessibilityLabel("Sections")

            connection
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 9) {
                FilamentView(peak: 1, thick: 1.8, glow: 0.6)
                    .frame(width: 30, height: 18)
                Text("Macrophone").font(Typeface.serif(17, .medium)).foregroundStyle(Ink.ink).lineLimit(1).fixedSize()
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, 6)
            .padding(.bottom, 10)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        }
        // ⌘1 … ⌘5 pick a section, as in Mail and Xcode. The buttons draw nothing.
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

    /// The link's state, at the sidebar's foot: a lit dot while a phone is connected.
    private var connection: some View {
        let on = model.connectedPeer != nil
        return HStack(alignment: .top, spacing: 9) {
            Circle().fill(on ? Light.cyan : Ink.tertiary.opacity(0.55)).frame(width: 7, height: 7)
                .shadow(color: on ? Light.cyan.opacity(0.8) : .clear, radius: 3)
                .padding(.top, 4)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.statusLine).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let last = model.lastReceived {
                    Text("Last received \(last.relativeShort)").font(.system(size: 10.5)).foregroundStyle(Ink.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(Ink.ink.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Ink.line, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(on ? "Connected. \(model.statusLine)" : model.statusLine)
    }
}

extension Pane {
    /// Its ⌘ number in the sidebar's order.
    var ordinal: Int { (Pane.allCases.firstIndex(of: self) ?? 0) + 1 }
}

/// The scrolling page every pane sits on.
struct PanePage<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Space.section) {
                    content
                    Color.clear.frame(height: 0).id("pane-bottom")
                }
                .padding(.horizontal, Space.margin)
                .padding(.top, 4)
                .padding(.bottom, 40)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollContentBackground(.hidden)
            .background(Ink.ground)
            .onAppear {
                #if DEBUG
                // Screenshots of a pane's foot.
                if ProcessInfo.processInfo.environment["MACROPHONE_SCROLL_BOTTOM"] == "1" {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { proxy.scrollTo("pane-bottom", anchor: .bottom) }
                }
                #endif
            }
        }
    }
}
