import AppKit
import MacrophoneKit
import SwiftUI

final class MainNav: ObservableObject {
    @Published var pane: Pane? = .history
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
        case .profiles: ProfilesPane(model: model, store: model.profiles, settings: model.settings)
        case .snippets: SnippetsPane(settings: model.settings)
        case .delivery: DeliveryPane(model: model, settings: model.settings, notifier: Notifier.shared)
        case .devices: DevicesPane(model: model)
        case .developer: DeveloperPane(model: model, settings: model.settings)
        case .general: GeneralPane(model: model, updater: updater)
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
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            connection
                .padding(14)
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
        }
    }

    private var connection: some View {
        let on = model.connectedPeer != nil
        return HStack(alignment: .top, spacing: 8) {
            Circle().fill(on ? Light.cyan : Ink.tertiary.opacity(0.6)).frame(width: 7, height: 7)
                .shadow(color: on ? Light.cyan.opacity(0.8) : .clear, radius: 3)
                .padding(.top, 4)
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
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Ink.ink.opacity(0.04)))
    }
}

/// The scrolling page every pane sits on.
struct PanePage<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    content
                    Color.clear.frame(height: 0).id("pane-bottom")
                }
                .padding(.horizontal, 32)
                .padding(.top, 4)
                .padding(.bottom, 36)
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
