import MacrophoneKit
import SwiftUI

@main
struct MacrophoneApp: App {
    @Environment(\.scenePhase) private var scenePhase
    /// Where the screen may turn (the Duo's inner screen every way; every other screen upright).
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        #if DEBUG
        DebugHooks.early()
        #endif
    }

    private var model: AppModel { AppModel.shared }

    var body: some Scene {
        WindowGroup {
            RootView(recorder: model.recorder, settings: model.settings)
                .environmentObject(model)
                .onOpenURL { model.handleURL($0) }
                .onChange(of: scenePhase, initial: true) { _, phase in model.scenePhaseChanged(phase) }
                .task {
                    #if DEBUG
                    DebugHooks.apply(model)
                    #endif
                }
                .onAppear { model.log.add("first frame \(LaunchClock.millisecondsSinceProcessStart) ms after launch") }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var recorder: Recorder
    @ObservedObject var settings: Settings
    /// The main view has its size: until then nothing of it shows but the ground, the launch
    /// screen's own colour (Nov 4 2026, Sameer: "stuttery … as you open the app" — its first
    /// frames were laid out at almost no size, everything drawn small in the corner).
    @State private var hasSize = false
    /// The first moments: the layout lands as it is, never animated into (the settle spring had
    /// grown the window, the Dock and the mic out of that corner into place).
    @State private var settled = false
    #if DEBUG
    @State private var settingsPath: [SettingsRoute] = DebugHooks.settingsPath
    #else
    @State private var settingsPath: [SettingsRoute] = []
    #endif

    var body: some View {
        ZStack {
            Ink.ground.ignoresSafeArea()
            mainView
                .opacity(model.showOnboarding || !hasSize ? 0 : 1)
                .transaction { if !settled { $0.animation = nil; $0.disablesAnimations = true } }
                .onGeometryChange(for: Bool.self) { $0.size.width > 100 && $0.size.height > 100 } action: { ok in
                    guard ok, !hasSize else { return }
                    // The frame after the first real one: whatever was measured at no size has
                    // been laid out again by then.
                    Task { @MainActor in
                        hasSize = true
                        try? await Task.sleep(for: .milliseconds(700))
                        settled = true
                    }
                }
            if model.showOnboarding {
                // Modal: VoiceOver (and the audit) skip the faded main view under it.
                OnboardingView(recorder: recorder)
                    .accessibilityAddTraits(.isModal)
                    .transition(.opacity)
            }
        }
        .sheet(item: $model.sheet) { sheet in
            Group {
                switch sheet {
                case .history: HistoryView()
                case .settings: SettingsView(settings: model.settings, initialPath: settingsPath)
                        .onDisappear { settingsPath = [] }
                case .pairing: PairingView()
                case .macs: MacsSheet()
                case .customCleanup: CustomCleanupSheet()
                case .openApp: OpenAppSheet()
                case .macControls:
                    // The Mac's own Control Center, a compact panel: the window stays in sight
                    // behind it (sizes itself to its contents).
                    MacControlCenter()
                }
            }
            .environmentObject(model)
            .preferredColorScheme(settings.appearance.scheme)
            .presentationDragIndicator(.visible)
            // The Duo's inner screen: Settings and History take the screen (Nov 1 2026, two
            // columns each); the short sheets are a form in the middle; the Mac Controls panel
            // takes only the room its controls need.
            .modifier(InnerScreenSheet(posture: Posture.shared, size: InnerScreenSheet.size(for: sheet)))
        }
    }

    @ViewBuilder private var mainView: some View {
        // The Duo's pose is read round the main view (the hinge, the fold's region, the size).
        let main = MainView(recorder: recorder, watcher: model.watcher)
            .modifier(PostureReader(posture: Posture.shared))
        #if DEBUG
        // MACROPHONE_TYPE: the app at that Dynamic Type size.
        let sized = main.transformEnvironment(\.dynamicTypeSize) { if let t = DebugHooks.typeSize { $0 = t } }
        if let size = DebugHooks.frame {
            // Another screen's shape on this simulator: a smaller phone's (an SE), or the Duo's
            // inner screen (951 × 669, 669 × 951 — bigger than the cover, so drawn to scale).
            GeometryReader { geo in
                let scale = min(1, geo.size.width / size.width, geo.size.height / size.height)
                // The frame's own bars (the Duo's vertical bar, its status bar and home
                // indicator), so the scene inside is the size his phone reports.
                sized.modifier(DebugFrameInsets(watcher: model.watcher))
                    .frame(width: size.width, height: size.height)
                    // MACROPHONE_FAKE_KEYBOARD: a stand-in keyboard at the frame's own scale on
                    // the keyboard page (the cover's real one rises over the frame at 1:1).
                    .overlay(alignment: .bottom) {
                        if let h = DebugHooks.fakeKeyboard { DebugKeyboard(watcher: model.watcher, height: h) }
                    }
                    .border(Ink.line)
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: size.width * scale, height: size.height * scale, alignment: .topLeading)
                    .clipped()
                    // The UI tests read the frame's place on the screen off this element.
                    .overlay(alignment: .topLeading) {
                        Color.clear
                            .frame(width: size.width * scale, height: size.height * scale)
                            .allowsHitTesting(false)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("The inner screen's frame")
                            .accessibilityIdentifier("duo-frame")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // The cover's own keyboard rises at 1:1 over the scaled frame: it is no part of the
            // simulation, so the frame never moves for it (MACROPHONE_FAKE_KEYBOARD draws one to
            // scale). Without this a field in the scaled frame lost the keyboard a moment after
            // taking it (the third pass).
            .ignoresSafeArea(.keyboard)
        } else {
            sized
        }
        #else
        main
        #endif
    }
}

/// A sheet on the iPhone Duo's inner screen. Every other iPhone's sheets are untouched.
/// - `screen`: Settings and History, nearly the whole screen (`InnerScreenFill`) — on a form
///   card in the middle of the big screen they were a phone's list to scroll through (Nov 1
///   2026, Sameer: "I shouldn't have to scroll that much"); they lay out in two columns there.
/// - `form`: the short ones (Your Macs, Open an App, Custom Cleanup, pairing), as on any wide
///   screen.
/// - `fitted`: the Mac Controls panel, to its contents.
struct InnerScreenSheet: ViewModifier {
    enum Size { case screen, form, fitted }

    @ObservedObject var posture: Posture
    var size: Size = .form

    static func size(for sheet: AppSheet) -> Size {
        switch sheet {
        case .settings, .history: return .screen
        case .macControls: return .fitted
        case .pairing, .macs, .customCleanup, .openApp: return .form
        }
    }

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *), posture.pose.isInner {
            switch size {
            case .fitted: content.presentationSizing(.fitted)
            case .form: content.presentationSizing(.form)
            // Read again on every pose change (this modifier observes the posture), so turning
            // the phone re-sizes an open sheet to the new shape.
            case .screen: content.presentationSizing(InnerScreenFill(room: InnerScreenFill.room()))
            }
        } else {
            content
        }
    }
}

/// The screen less a small margin all round: what Settings and History are given on the Duo's
/// inner screen. `PresentationSizingContext` names no container size, so the room is read off
/// the window — its bounds inside the safe area (the vertical bar on its side, the status bar
/// and home indicator upright), less `margin` each side. On his phone that's 835 × 603 on its
/// side (867 × 635 usable) and 637 × 803 upright (669 × 835). The system still caps a sheet at
/// its container, so a wrong reading never draws one off the screen.
@available(iOS 18.0, *)
struct InnerScreenFill: PresentationSizing {
    var room: CGSize?
    static let margin: CGFloat = 16

    func proposedSize(for root: PresentationSizingRoot, context: PresentationSizingContext) -> ProposedViewSize {
        guard let room else {
            let page: PagePresentationSizing = .page
            return page.proposedSize(for: root, context: context)
        }
        return ProposedViewSize(room)
    }

    @MainActor static func room() -> CGSize? {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        guard let window = windows.first(where: \.isKeyWindow) ?? windows.first else { return nil }
        let usable = window.bounds.inset(by: window.safeAreaInsets)
        guard usable.width > 200, usable.height > 200 else { return nil }
        return CGSize(width: usable.width - margin * 2, height: usable.height - margin * 2)
    }
}

#if DEBUG
/// The frame's bars as insets (`DebugHooks.frameInsets`). The laptop (folded or flat) with a
/// window in hand hides the status bar, and the frame gives the top back then, as a screen with
/// no cutout at that edge would (whether the Duo's does needs a real Duo).
private struct DebugFrameInsets: ViewModifier {
    @ObservedObject var watcher: Watcher
    @ObservedObject private var posture = Posture.shared

    func body(content: Content) -> some View {
        var insets = DebugHooks.frameInsets ?? EdgeInsets()
        if posture.pose.foldAcross, watcher.isShowing { insets.top = 0 }
        // A pose with a vertical bar sits in a NavigationStack, which — inside a frame that
        // stops short of the screen's trailing edge — draws its own vertical bar at its trailing
        // edge, ~82 pt wide with the items in it: that stands in for the system's (the same
        // width), so only a sliver of padding there, enough to keep the stack off the edge
        // (flush with it, the stack drew no bar and the items went nowhere). Plain padding, not
        // `safeAreaPadding`, which the stack's content took back.
        if posture.pose.hasVerticalBar { insets.trailing = 20 }
        return content.padding(insets)
    }
}

/// `MACROPHONE_FAKE_KEYBOARD=<height>`: what the keyboard page looks like inside a to-scale
/// frame — the Mac's bar over a plate of keys of that height, rising when the page is up.
private struct DebugKeyboard: View {
    @ObservedObject var watcher: Watcher
    @ObservedObject private var input: MacInput
    var height: CGFloat

    init(watcher: Watcher, height: CGFloat) {
        self.watcher = watcher
        self.height = height
        _input = ObservedObject(wrappedValue: watcher.input)
    }

    var body: some View {
        if input.page == .keyboard {
            VStack(spacing: 0) {
                MacKeyboardBar(input: input, watcher: watcher)
                    .background(Color(white: 0.13))
                VStack(spacing: 10) {
                    ForEach(["qwertyuiop", "asdfghjkl", "zxcvbnm"], id: \.self) { row in
                        HStack(spacing: 6) {
                            ForEach(Array(row), id: \.self) { c in
                                RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.3))
                                    .overlay(Text(String(c)).font(.title3).foregroundStyle(.white))
                                    .frame(maxWidth: .infinity)
                            }
                        }
                    }
                    RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.3)).frame(maxWidth: .infinity).padding(.horizontal, 90)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 10)
                .frame(height: height)
                .background(Color(white: 0.13))
            }
            .transition(.move(edge: .bottom))
        }
    }
}
#endif

/// How long the app took to put its first frame up (a number for the diagnostics log).
enum LaunchClock {
    static var millisecondsSinceProcessStart: Int {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return 0 }
        let start = info.kp_proc.p_starttime
        let started = Double(start.tv_sec) + Double(start.tv_usec) / 1e6
        return Int((Date().timeIntervalSince1970 - started) * 1000)
    }
}
