import AppKit
import Combine
import Sparkle

/// In-app updates through Sparkle (EdDSA-signed appcast at sameer.us/macrophone/appcast.xml).
/// A debug build doesn't check on its own; "Check for Updates…" still works.
@MainActor
final class Updater: NSObject, ObservableObject {
    private let controller: SPUStandardUpdaterController
    @Published var canCheck = false
    @Published var automaticallyChecks: Bool = true {
        didSet { if controller.updater.automaticallyChecksForUpdates != automaticallyChecks { controller.updater.automaticallyChecksForUpdates = automaticallyChecks } }
    }
    @Published private(set) var lastCheck: Date?
    private var bag: Set<AnyCancellable> = []

    override init() {
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        super.init()
    }

    func start() {
        #if DEBUG
        // Debug builds have their own bundle id and no real feed to compare against.
        controller.updater.automaticallyChecksForUpdates = false
        #endif
        do { try controller.updater.start() } catch {
            AppDelegate.shared?.model.log.add("updater could not start")
        }
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates
        lastCheck = controller.updater.lastUpdateCheckDate
        controller.updater.publisher(for: \.canCheckForUpdates).receive(on: RunLoop.main)
            .sink { [weak self] in self?.canCheck = $0 }.store(in: &bag)
        controller.updater.publisher(for: \.lastUpdateCheckDate).receive(on: RunLoop.main)
            .sink { [weak self] in self?.lastCheck = $0 }.store(in: &bag)
    }

    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }
}
