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
            RootView(recorder: model.recorder)
                .environmentObject(model)
                .preferredColorScheme(.dark)
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
    #if DEBUG
    @State private var settingsPath: [SettingsRoute] = DebugHooks.settingsPath
    #else
    @State private var settingsPath: [SettingsRoute] = []
    #endif

    var body: some View {
        ZStack {
            Ink.ground.ignoresSafeArea()
            mainView
                .opacity(model.showOnboarding ? 0 : 1)
            if model.showOnboarding {
                OnboardingView(recorder: recorder)
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
                    // A compact panel, not a page: the window stays in sight behind it.
                    MacControlsPanel() // sizes itself to its contents
                }
            }
            .environmentObject(model)
            .preferredColorScheme(.dark)
            .presentationBackground(Ink.ground)
            .presentationDragIndicator(.visible)
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
                sized.safeAreaPadding(.top, scale < 1 ? 0 : 20)
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
        } else {
            sized
        }
        #else
        main
        #endif
    }
}

#if DEBUG
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
