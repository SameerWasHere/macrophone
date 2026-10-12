import AVFoundation
import Combine
import Foundation
import MacrophoneKit
import SwiftUI
import UIKit

/// What the status line under the mic says. Four states matter most (listening, sending,
/// delivered, queued); the rest are the honest edges around them.
enum DeliveryStatus: Equatable {
    case ready
    case listening
    case cleaning
    case sending(mac: String)
    case delivered(mac: String, detail: String?, late: Bool)
    case duplicate
    case queued
    case copiedOnPhone
    case failed(mac: String, detail: String?)
    case nothingHeard
    case notice(String)
    case problem(String, openSettings: Bool)
}

enum AppSheet: String, Identifiable {
    case history, settings, pairing
    var id: String { rawValue }
}

enum PairingPhase: Equatable {
    case idle
    case connecting(String)
    /// Code pairing: the six digits to compare, and the Mac's name.
    case showingCode(String, String)
    case paired(String)
    case failed(String)
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let settings = Settings()
    let recorder = Recorder()
    let queue = DeliveryQueue(url: AppFiles.queue)
    let log = DiagnosticLog(url: AppFiles.log)
    private let history: HistoryStore<HistoryItem>
    private let pairingStore = KeychainPairingStore(service: "com.sameer.macrophone.pairing", directory: AppFiles.directory)
    private(set) var client: LinkClient

    // Published state the screens read.
    @Published var status: DeliveryStatus = .ready
    @Published private(set) var latest: HistoryItem?
    @Published private(set) var historyItems: [HistoryItem] = []
    @Published private(set) var linkState: LinkClient.State = .notPaired
    @Published private(set) var discoveredMacs: [DiscoveredMac] = []
    @Published private(set) var profiles: [ProfileSummary] = []
    @Published private(set) var pairedMac: PairedPeer?
    @Published var pairing: PairingPhase = .idle
    @Published var sheet: AppSheet?
    @Published private(set) var cleanupAvailability: CleanupAvailability = .osTooOld
    @Published var showOnboarding: Bool
    @Published private(set) var recorderPhase: Recorder.Phase = .idle
    /// Bumped when the person should notice the Filament (delivered/queued/error).
    @Published private(set) var pulse = 0

    /// The local network prompt is explained in onboarding before the first browse.
    @AppStorage("link.networkExplained") var networkExplained = false
    @AppStorage("onboarding.done") var onboardingDone = false

    private var bag = Set<AnyCancellable>()
    private var flushing = false
    private var sceneActive = false
    private var recordingProfileID: UUID?
    private var textWaiters: [CheckedContinuation<String?, Never>] = []
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var statusReset: Task<Void, Never>?

    private init() {
        history = HistoryStore(url: AppFiles.history, capacity: 50, enabled: UserDefaults.standard.object(forKey: Settings.K.history) as? Bool ?? true)
        client = Self.makeClient(store: pairingStore, name: settings.deviceName, log: log)
        showOnboarding = !UserDefaults.standard.bool(forKey: "onboarding.done")
        client.delegate = self
        linkState = client.state
        pairedMac = client.activeMac
        recorder.log = log
        recorder.onFinish = { [weak self] outcome in self?.recordingFinished(outcome) }
        recorder.$phase.sink { [weak self] in self?.recorderPhase = $0 }.store(in: &bag)
        recorder.$softCapReached.filter { $0 }.sink { [weak self] _ in
            Haptics.warning()
            self?.objectWillChange.send()
        }.store(in: &bag)
        if !CachedProfile.load().isEmpty, pairedMac != nil {
            profiles = CachedProfile.load().map { ProfileSummary(id: $0.id, name: $0.name, cleanupLevel: nil, isDefault: $0.isDefault) }
        }
        refreshHistory()
        refreshAvailability()
        log.add("app launched, version \(Bundle.main.shortVersion) (\(Bundle.main.buildNumber)), \(queue.count) queued")
        log.add("language \(settings.language); cleanup \(cleanupAvailability.isAvailable ? "available" : "unavailable")")
    }

    private static func makeClient(store: KeychainPairingStore, name: String, log: DiagnosticLog) -> LinkClient {
        let c = LinkClient(identity: DeviceIdentity.load(name: name), store: store,
                           appVersion: Bundle.main.shortVersion, osDescription: "iOS \(UIDevice.current.systemVersion)")
        c.log = log
        return c
    }

    // MARK: Derived

    var isPaired: Bool { pairedMac != nil }
    var isConnected: Bool { if case .connected = linkState { return true }; return false }
    var macName: String { pairedMac?.name ?? "your Mac" }

    var selectedProfile: ProfileSummary? {
        let id = recordingProfileID ?? settings.selectedProfileID
        return profiles.first { $0.id == id } ?? profiles.first { $0.isDefault }
    }

    /// The level cleanup will run at, after availability, language and the profile.
    var effectiveCleanupLevel: CleanupLevel {
        guard cleanupAvailability.isAvailable else { return .off }
        return selectedProfile?.cleanupLevel ?? settings.cleanupLevel
    }

    func refreshAvailability() {
        cleanupAvailability = Cleaner.availability(language: settings.language)
    }

    // MARK: Lifecycle

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            sceneActive = true
            endBackgroundTask()
            refreshAvailability()
            if networkExplained || isPaired { client.start() }
            if pendingStart { pendingStart = false; Task { await startRecording(profileID: recordingProfileID) } }
        case .background:
            sceneActive = false
            enterBackground()
        default:
            break
        }
    }

    private var pendingStart = false
    /// Dictations between "stopped" and "the Mac answered" (or queued).
    private var inFlight = 0

    private func enterBackground() {
        beginBackgroundTask()
        if recorder.isActive {
            #if DEBUG
            if debugSimulating { recorder.endSimulation(); debugSimulating = false }
            #endif
            recorder.stop(.interrupted("The app was closed"))
        }
        Task {
            // Finish what's in flight (recognition, cleanup, a send, the queue), then let go.
            let deadline = Date().addingTimeInterval(25)
            while Date() < deadline, !sceneActive, recorder.isActive || processing || inFlight > 0 || (!queue.isEmpty && isConnected) || flushing {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            if !sceneActive {
                client.stop()
                log.add("link paused in background, \(queue.count) queued")
            }
            endBackgroundTask()
        }
    }

    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Finish dictation") { [weak self] in
            MainActor.assumeIsolated { self?.endBackgroundTask() }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// Called once the person has seen what the local network prompt is for.
    func startLink() {
        networkExplained = true
        client.start()
    }

    // MARK: Recording

    @Published private(set) var startError: Recorder.StartError?
    /// True from the moment recording stops until the dictation is in history (cleanup runs here).
    @Published private(set) var processing = false

    func toggleRecording() {
        if recorder.isActive { stopRecording() } else { Task { await startRecording() } }
    }

    func startRecording(profileID: UUID? = nil) async {
        guard !recorder.isActive else { return }
        statusReset?.cancel()
        startError = nil
        recordingProfileID = profileID
        let level = effectiveCleanupLevel
        Haptics.light()
        status = .listening
        do {
            try await recorder.start(language: settings.language,
                                     contextualStrings: settings.dictionary,
                                     autoStopAfter: settings.autoStop ? settings.autoStopDelay : nil)
            if level != .off { Cleaner.prewarm(level: level, dictionary: settings.dictionary) }
        } catch let e as Recorder.StartError {
            startError = e
            status = .problem(e.message, openSettings: e.needsSettings)
            Haptics.error()
            resolveTextWaiters(nil)
        } catch {
            status = .problem("The microphone couldn't start. Try again.", openSettings: false)
            resolveTextWaiters(nil)
        }
    }

    func stopRecording() {
        #if DEBUG
        if debugSimulating {
            debugSimulating = false
            let text = recorder.transcript
            recorder.endSimulation()
            recordingFinished(.init(raw: text, duration: 14, reason: .user, language: settings.language, segments: 1))
            return
        }
        #endif
        guard recorder.isActive else { return }
        Haptics.soft()
        recorder.stop(.user)
    }

    private func recordingFinished(_ o: Recorder.Outcome) {
        let raw = o.raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            if o.reason == .recognizerFailed {
                status = .problem("Speech recognition couldn't start on this iPhone. Try again in a moment.", openSettings: false)
                Haptics.error()
            } else if o.duration < 0.4, !o.reason.isEarly {
                status = .ready   // a brush of the button — ignored, no item
            } else {
                status = o.reason.isEarly ? .notice("Stopped early — nothing was heard") : .nothingHeard
                scheduleStatusReset(after: 4)
            }
            recordingProfileID = nil
            resolveTextWaiters(nil)
            return
        }
        processing = true
        Task { await finish(raw: raw, outcome: o) }
    }

    private func finish(raw: String, outcome o: Recorder.Outcome) async {
        processing = true
        inFlight += 1
        defer { processing = false; inFlight -= 1 }
        let profile = selectedProfile
        let level = effectiveCleanupLevel
        recordingProfileID = nil
        var cleaned: String?
        if level != .off {
            status = .cleaning
            let t0 = Date()
            let result = await Self.cleanWithDeadline(raw, level: level, dictionary: settings.dictionary, language: o.language)
            cleaned = result?.cleaned
            let outcome = result == nil ? "timed out, kept raw" : (cleaned == nil ? "kept raw (\(result?.skipped ?? "unchanged"))" : "applied")
            log.add("cleanup \(level.rawValue): \(outcome) in \(Int(Date().timeIntervalSince(t0) * 1000))ms")
        }
        let d = Dictation(raw: raw, cleaned: cleaned, cleanupLevel: cleaned == nil ? .off : level, language: o.language,
                          profileID: profile?.id, profileName: profile?.name, stoppedEarly: o.reason.isEarly,
                          duration: o.duration, sourceDevice: settings.deviceName)
        history.add(HistoryItem(dictation: d, delivery: .sending))
        refreshHistory()
        processing = false
        resolveTextWaiters(d.text)
        await deliver(d, resend: false)
        if o.reason == .hardCap { status = .notice("Stopped at 10:00, the limit for one dictation — it was sent") }
    }

    /// Cleanup never holds a dictation hostage: past the deadline the raw words go out.
    /// 12 s plus a second per 250 characters, at most 40 s (a 10-minute dictation is ~9,000).
    /// Returns nil when the deadline passed first.
    private static func cleanWithDeadline(_ raw: String, level: CleanupLevel, dictionary: [String], language: String) async -> CleanupResult? {
        let deadline = min(12 + Double(raw.count) / 250, 40)
        // Unstructured on purpose: a task group would wait for a model call that won't cancel.
        return await withCheckedContinuation { (c: CheckedContinuation<CleanupResult?, Never>) in
            let once = ResumeOnce(c)
            Task.detached { once.resume(await Cleaner.clean(raw, level: level, dictionary: dictionary, language: language)) }
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(deadline * 1e9))
                once.resume(nil)
            }
        }
    }

    // MARK: Delivery

    private func deliver(_ d: Dictation, resend: Bool) async {
        guard let mac = client.activeMac else {
            UIPasteboard.general.string = d.text
            updateItem(d.id) { $0.delivery = .copiedOnPhone; $0.deliveredAt = Date() }
            status = .copiedOnPhone
            Haptics.success()
            log.add("not paired: copied on iPhone")
            bumpPulse()
            return
        }
        if !queue.isEmpty {
            // Keep the order: anything spoken earlier goes first.
            queue.append(d, delayed: true)
            updateItem(d.id) { $0.delivery = .queued; $0.wasDelayed = true }
            if isConnected { flushQueue() } else { setQueuedStatus() }
            return
        }
        status = .sending(mac: mac.name)
        updateItem(d.id) { $0.delivery = .sending; $0.macName = mac.name }
        do {
            let ack = try await client.send(d, delayed: false, timeout: client.isConnected ? 8 : 4)
            apply(ack, to: d.id, macName: mac.name, late: false)
        } catch {
            log.add("send failed (\(String(describing: error))), queued")
            queue.append(d, delayed: true)
            updateItem(d.id) { $0.delivery = .queued; $0.wasDelayed = true }
            setQueuedStatus()
        }
    }

    private func setQueuedStatus() {
        status = .queued
        Haptics.warning()
        bumpPulse()
    }

    private func apply(_ ack: LinkClient.Ack, to id: UUID, macName: String, late: Bool) {
        let isLatest = latest?.id == id
        switch ack.outcome {
        case .delivered:
            updateItem(id) { $0.delivery = .delivered; $0.detail = ack.detail; $0.macName = macName; $0.deliveredAt = Date() }
            if isLatest || !late { status = .delivered(mac: macName, detail: ack.detail, late: late); Haptics.success() }
        case .duplicate:
            updateItem(id) { $0.delivery = .duplicate; $0.macName = macName }
            if isLatest || !late { status = .duplicate; Haptics.success() }
        case .failed:
            updateItem(id) { $0.delivery = .failed; $0.detail = ack.detail; $0.macName = macName }
            if isLatest || !late { status = .failed(mac: macName, detail: ack.detail); Haptics.error() }
        }
        log.add("ack \(ack.outcome.rawValue)\(late ? " (from queue)" : "")")
        bumpPulse()
    }

    /// Sends everything queued, oldest first, marked delayed. Stops at the first failure.
    func flushQueue() {
        guard !flushing, !queue.isEmpty, isConnected, let mac = client.activeMac else { return }
        flushing = true
        Task {
            defer { flushing = false }
            log.add("sending \(queue.count) queued")
            while let e = queue.entries.first {
                if latest?.id == e.id { status = .sending(mac: mac.name) }
                updateItem(e.id) { $0.delivery = .sending }
                do {
                    let ack = try await client.send(e.dictation, delayed: true, timeout: 8)
                    queue.remove(e.id)
                    apply(ack, to: e.id, macName: mac.name, late: true)
                } catch {
                    queue.markAttempt(e.id)
                    updateItem(e.id) { $0.delivery = .queued }
                    if latest?.id == e.id { status = .queued }
                    log.add("queued send failed again (\(String(describing: error)))")
                    break
                }
            }
        }
    }

    /// Same id, so the Mac knows it's a resend and answers "duplicate" if it already has it.
    func resend(_ item: HistoryItem) {
        Task {
            if queue.contains(item.id) {
                if isConnected { flushQueue() } else { status = .queued }
                return
            }
            await deliver(item.dictation, resend: true)
        }
    }

    func copy(_ item: HistoryItem, cleaned: Bool) {
        UIPasteboard.general.string = item.text(cleaned: cleaned)
    }

    private func bumpPulse() { pulse &+= 1 }

    private func scheduleStatusReset(after seconds: Double) {
        statusReset?.cancel()
        statusReset = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
            guard !Task.isCancelled, let self, !self.recorder.isActive else { return }
            self.status = .ready
        }
    }

    // MARK: History

    private func updateItem(_ id: UUID, _ change: (inout HistoryItem) -> Void) {
        guard var item = historyItems.first(where: { $0.id == id }) ?? (latest?.id == id ? latest : nil) else { return }
        change(&item)
        history.update(item)
        refreshHistory()
    }

    private func refreshHistory() {
        historyItems = history.all
        latest = history.latest
    }

    func setHistoryEnabled(_ on: Bool) {
        settings.historyEnabled = on
        history.isEnabled = on
        refreshHistory()
        log.add("history \(on ? "on" : "off")")
    }

    func clearHistory() {
        history.clear()
        refreshHistory()
        log.add("history cleared")
    }

    func deleteHistoryItem(_ id: UUID) {
        history.remove(id)
        refreshHistory()
    }

    // MARK: Pairing

    func handleURL(_ url: URL) {
        guard let invite = PairingInvite(url: url) else {
            log.add("ignored a link that isn't a pairing link")
            return
        }
        if !showOnboarding { sheet = .pairing }
        Task { await pair(invite) }
    }

    func pair(_ invite: PairingInvite) async {
        pairing = .connecting(invite.macName)
        networkExplained = true
        log.add("pairing by QR")
        do {
            let peer = try await client.pair(invite: invite)
            pairingSucceeded(peer)
        } catch {
            pairingFailed(error)
        }
    }

    func pairWithCode(_ mac: DiscoveredMac) async {
        pairing = .connecting(mac.name)
        log.add("pairing by code")
        do {
            let peer = try await client.pairWithCode(mac) { [weak self] code in
                self?.pairing = .showingCode(code, mac.name)
            }
            pairingSucceeded(peer)
        } catch {
            pairingFailed(error)
        }
    }

    private func pairingSucceeded(_ peer: PairedPeer) {
        pairedMac = client.activeMac ?? peer
        pairing = .paired(peer.name)
        Haptics.success()
        if !queue.isEmpty { log.add("paired with \(queue.count) waiting") }
    }

    private func pairingFailed(_ error: Error) {
        let message = (error as? LinkError)?.userMessage ?? "Couldn't pair. Make sure Macrophone is open on your Mac."
        pairing = .failed(message)
        log.add("pairing failed: \(String(describing: error))")
        Haptics.error()
    }

    func resetPairing() { pairing = .idle }

    func unpair() async {
        guard let mac = client.activeMac else { return }
        await client.unpair(mac.id)
        forgetMac()
    }

    private func forgetMac() {
        pairedMac = client.activeMac
        profiles = []
        CachedProfile.save([])
        settings.selectedProfileID = nil
        // Anything still waiting can't reach a Mac now; it stays in history with Copy.
        for e in queue.entries { updateItem(e.id) { $0.delivery = .failed; $0.detail = "Unpaired before it was sent" } }
        queue.removeAll()
        status = .ready
    }

    func renameDevice(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != settings.deviceName else { return }
        settings.deviceName = String(trimmed.prefix(40))
        client.stop()
        client = Self.makeClient(store: pairingStore, name: settings.deviceName, log: log)
        client.delegate = self
        if sceneActive, networkExplained || isPaired { client.start() }
        log.add("device renamed")
    }

    func selectProfile(_ id: UUID?) {
        settings.selectedProfileID = id
    }

    // MARK: Intents

    /// Opens already recording (Action Button, Siri, Control Center, Shortcuts).
    func startFromIntent(profileID: UUID?) async {
        sheet = nil
        showOnboarding = false
        guard !recorder.isActive else { return }
        if UIApplication.shared.applicationState == .active {
            await startRecording(profileID: profileID)
        } else {
            recordingProfileID = profileID
            pendingStart = true
            // The scene becomes active a moment after the intent runs; wait for it.
            for _ in 0..<60 where pendingStart {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if pendingStart, UIApplication.shared.applicationState == .active {
                pendingStart = false
                await startRecording(profileID: profileID)
            }
        }
    }

    /// Records until the person stops (or auto-stop / the limit / an interruption), then
    /// returns what was said — cleaned when cleanup is on.
    func dictateForIntent() async -> String? {
        await startFromIntent(profileID: nil)
        // Wait for the start to land (permissions, the mic opening).
        for _ in 0..<50 where recorder.phase == .starting { try? await Task.sleep(nanoseconds: 100_000_000) }
        guard recorder.isActive || pendingStart else { return nil }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in textWaiters.append(c) }
        } onCancel: {
            Task { @MainActor in AppModel.shared.stopRecording() }
        }
    }

    private func resolveTextWaiters(_ text: String?) {
        let waiters = textWaiters
        textWaiters.removeAll()
        waiters.forEach { $0.resume(returning: text) }
    }

    // MARK: Diagnostics

    func diagnosticsText() -> String {
        var sys = utsname()
        uname(&sys)
        let model = withUnsafePointer(to: &sys.machine) { $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) } }
        let connection: String
        switch linkState {
        case .notPaired: connection = "not paired"
        case .searching: connection = "searching"
        case .connecting: connection = "connecting"
        case .connected: connection = "connected"
        case .unreachable: connection = "Mac not found"
        }
        return log.export(header: [
            ("App version", "\(Bundle.main.shortVersion) (\(Bundle.main.buildNumber))"),
            ("iOS", UIDevice.current.systemVersion),
            ("Device model", model),
            ("Paired Macs", "\(client.pairedMacs.count)"),
            ("Connection", connection),
            ("Macs seen on the network", "\(discoveredMacs.count)"),
            ("Queued dictations", "\(queue.count)"),
            ("Language", settings.language),
            ("Cleanup", "\(settings.cleanupLevel.title) · \(cleanupAvailability.isAvailable ? "available" : String(describing: cleanupAvailability))"),
            ("Dictionary words", "\(settings.dictionary.count)"),
            ("Auto-stop", settings.autoStop ? "on, \(Int(settings.autoStopDelay)) s" : "off"),
            ("History", settings.historyEnabled ? "on" : "off"),
            ("Microphone permission", String(describing: Recorder.micStatus.rawValue)),
            ("Speech permission", String(describing: Recorder.speechStatus.rawValue)),
        ])
    }

    // MARK: Debug

    #if DEBUG
    var debugSimulating = false

    func debugInject(_ text: String, stoppedEarly: Bool = false) {
        recorder.debugShow(text)
        recordingFinished(.init(raw: text, duration: Double(text.count) / 14, reason: stoppedEarly ? .interrupted("debug") : .user,
                                language: settings.language, segments: 1))
    }

    func debugSimulateRecording(_ text: String) {
        debugSimulating = true
        status = .listening
        recorder.simulate(text)
    }

    func debugSeedHistory() {
        let samples: [(String, String?, DeliveryState, Bool, Bool, Double)] = [
            ("so um the thing I want to try is, uh, make the retry logic in the uploader back off exponentially, starting at one second and capping at thirty",
             "Make the retry logic in the uploader back off exponentially, starting at one second and capping at 30.", .delivered, false, false, 120),
            ("can you write a function that sorts a list of users by last name and then first name", "Can you write a function that sorts a list of users by last name and then first name?", .delivered, false, true, 3600),
            ("note for the standup we shipped the new onboarding and the crash rate is down", nil, .queued, true, false, 7200),
            ("Hey Sam, running ten minutes late, start without me.", nil, .copiedOnPhone, false, false, 86_400),
        ]
        for s in samples.reversed() {
            var d = Dictation(createdAt: Date().addingTimeInterval(-s.5), raw: s.0, cleaned: s.1, cleanupLevel: s.1 == nil ? .off : .medium,
                              language: "en-US", stoppedEarly: s.3, duration: 18, sourceDevice: settings.deviceName)
            d.profileName = s.4 ? "Claude prompt" : nil
            history.add(HistoryItem(dictation: d, delivery: s.2, detail: s.2 == .delivered ? "Pasted into Claude" : nil,
                                    macName: "Sameer's MacBook Pro", wasDelayed: s.2 == .queued, deliveredAt: Date()))
        }
        refreshHistory()
    }

    func debugSetStatus(_ s: DeliveryStatus) { status = s; bumpPulse() }

    func debugFakePairing(mac: String, profiles names: [String]) {
        pairedMac = PairedPeer(id: UUID(), name: mac)
        linkState = .connected(mac)
        profiles = names.enumerated().map { ProfileSummary(id: UUID(), name: $1, cleanupLevel: $0 == 1 ? .heavy : nil, isDefault: $0 == 0) }
    }
    #endif
}

extension AppModel: LinkClientDelegate {
    func linkClient(_ client: LinkClient, stateChanged state: LinkClient.State) {
        guard client === self.client else { return }
        linkState = state
        pairedMac = client.activeMac
        if case .connected = state { flushQueue() }
    }

    func linkClient(_ client: LinkClient, discovered macs: [DiscoveredMac]) {
        guard client === self.client else { return }
        discoveredMacs = macs
    }

    func linkClient(_ client: LinkClient, profiles: [ProfileSummary], macID: UUID) {
        guard client === self.client else { return }
        self.profiles = profiles
        CachedProfile.save(profiles.map { CachedProfile(id: $0.id, name: $0.name, isDefault: $0.isDefault) })
        if let id = settings.selectedProfileID, !profiles.contains(where: { $0.id == id }) { settings.selectedProfileID = nil }
        MacrophoneShortcuts.updateAppShortcutParameters()
    }

    func linkClient(_ client: LinkClient, unpairedBy macID: UUID) {
        guard client === self.client else { return }
        log.add("the Mac forgot this iPhone")
        forgetMac()
        status = .notice("Your Mac forgot this iPhone. Pair again to send to it.")
    }
}

/// The intents' way in (they're compiled into the extension too, where this doesn't exist).
enum IntentBridge {
    @MainActor static func startRecording(profileID: UUID?) async {
        await AppModel.shared.startFromIntent(profileID: profileID)
    }

    @MainActor static func dictate() async -> String? {
        await AppModel.shared.dictateForIntent()
    }
}

/// Resumes a continuation exactly once, whoever gets there first.
final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    init(_ c: CheckedContinuation<T, Never>) { continuation = c }
    func resume(_ value: T) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: value)
    }
}
