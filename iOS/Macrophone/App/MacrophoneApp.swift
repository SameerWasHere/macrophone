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
                    .border(Ink.line)
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: size.width * scale, height: size.height * scale, alignment: .topLeading)
                    .clipped()
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
