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
    case sending(mac: String, to: RouteNote?)
    case delivered(mac: String, detail: String?, late: Bool, to: RouteNote?)
    case duplicate
    case queued
    case copiedOnPhone
    case failed(mac: String, detail: String?)
    case nothingHeard
    case notice(String)
    case problem(String, openSettings: Bool)
}

/// Which target a dictation went to, for the status line: "Sent to Claude — you said “Claude, …”".
struct RouteNote: Equatable {
    var name: String
    /// The lead-in as heard, when a voice prefix picked it.
    var spoken: String?
}

/// How one dictation is routed: the target, why it was picked, and the words to clean and send.
struct Route: Equatable {
    var profile: ProfileSummary?
    var source: ProfileSource?
    /// The transcript with any voice prefix taken off.
    var body: String
    /// The prefix as heard ("Claude"), when one picked the target.
    var spoken: String?
}

enum AppSheet: String, Identifiable {
    case history, settings, pairing, sendTo
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
    /// iOS is blocking the local network for this app — nothing can be found until it's on.
    @Published private(set) var localNetworkDenied = false
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
    /// A Shortcut / control / Siri picked the target for this one recording.
    private var recordingOverride: SendTarget?
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
        if pairedMac != nil {
            profiles = CachedProfile.load().map {
                ProfileSummary(id: $0.id, name: $0.name, cleanupLevel: $0.cleanupLevel.flatMap(CleanupLevel.init(rawValue:)),
                               isDefault: $0.isDefault, voicePrefixes: $0.voicePrefixes)
            }
        }
        refreshHistory()
        refreshAvailability()
        // One line (each write rewrites the log file) and no keychain read: launch stays light.
        log.add("app launched, version \(Bundle.main.shortVersion) (\(Bundle.main.buildNumber)), \(queue.count) queued; "
                + "language \(settings.language); cleanup \(cleanupAvailability.isAvailable ? "available" : "unavailable"); targets cached: \(profiles.count)")
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

    /// The target picked for the next dictation (a Shortcut's pick wins while it records).
    /// Nil = Automatic, or a pick the Mac no longer has.
    var selectedProfile: ProfileSummary? {
        guard let id = (recordingOverride ?? settings.sendTo).profileID else { return nil }
        return profiles.first { $0.id == id }
    }

    /// The level cleanup will run at, after availability, language and the profile.
    var effectiveCleanupLevel: CleanupLevel { cleanupLevel(for: selectedProfile) }

    func cleanupLevel(for profile: ProfileSummary?) -> CleanupLevel {
        guard cleanupAvailability.isAvailable else { return .off }
        return profile?.cleanupLevel ?? settings.cleanupLevel
    }

    /// Picks the target for one transcript: a spoken prefix ("Claude, …") > a Shortcut's pick >
    /// the Send-to choice. The Mac resolves Automatic by the app in front.
    func route(for raw: String) -> Route {
        if !profiles.isEmpty, let m = VoicePrefix.match(raw, profiles: profiles) {
            return Route(profile: m.profile, source: .prefix, body: m.text, spoken: Self.spokenPrefix(raw, of: m.profile))
        }
        if let p = selectedProfile { return Route(profile: p, source: .chosen, body: raw) }
        return Route(profile: nil, source: isPaired ? .automatic : nil, body: raw)
    }

    /// The lead-in exactly as the recognizer wrote it ("Claude", "Claude Code").
    static func spokenPrefix(_ raw: String, of profile: ProfileSummary) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = t.lowercased()
        let match = (profile.voicePrefixes ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).lowercased() }
            .filter { !$0.isEmpty && lower.hasPrefix($0) }
            .max { $0.count < $1.count }
        return match.map { String(t.prefix($0.count)) }
    }

    /// The target while the words come in: a prefix shows up the moment it's heard.
    func liveRoute(_ transcript: String) -> (profile: ProfileSummary?, byVoice: Bool) {
        if !profiles.isEmpty, let m = VoicePrefix.match(transcript, profiles: profiles) { return (m.profile, true) }
        return (selectedProfile, false)
    }

    func routeNote(_ id: UUID) -> RouteNote? {
        guard let item = historyItems.first(where: { $0.id == id }) ?? (latest?.id == id ? latest : nil),
              let name = item.targetName else { return nil }
        return RouteNote(name: name, spoken: item.spokenPrefix)
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
            if pendingStart { pendingStart = false; Task { await startRecording(override: recordingOverride) } }
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

    func startRecording(override: SendTarget? = nil) async {
        guard !recorder.isActive else { return }
        recordingOverride = override
        #if DEBUG
        // UI tests drive the real button and gestures with a stand-in recognizer
        // (the simulator can't load speech assets).
        if let words = DebugHooks.env["MACROPHONE_SIM_RECORD"] {
            Haptics.light()
            debugSimulateRecording(words)
            return
        }
        #endif
        statusReset?.cancel()
        startError = nil
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
            recordingOverride = nil
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
        let route = route(for: raw)
        let profile = route.profile
        let level = cleanupLevel(for: profile)
        recordingOverride = nil
        if let source = route.source { log.add("target: \(profile?.name ?? "Mac picks") (\(source.rawValue))") }
        // The prefix is only for the phone: what's cleaned and sent starts after it.
        var cleaned: String?
        var partial = false
        if level != .off {
            status = .cleaning
            let t0 = Date()
            let result = await Self.cleanWithDeadline(route.body, level: level, dictionary: settings.dictionary, language: o.language)
            cleaned = result?.cleaned
            partial = result?.skipped == "partial"
            let outcome = result == nil ? "timed out, kept raw" : (cleaned == nil ? "kept raw (\(result?.skipped ?? "unchanged"))" : (partial ? "partly applied (deadline)" : "applied"))
            log.add("cleanup \(level.rawValue): \(outcome) in \(Int(Date().timeIntervalSince(t0) * 1000))ms, \(route.body.count) chars")
        }
        let cleanupRan = cleaned != nil
        if cleaned == nil, route.body != raw { cleaned = route.body }
        let d = Dictation(raw: raw, cleaned: cleaned, cleanupLevel: cleanupRan ? level : .off, language: o.language,
                          profileID: profile?.id, profileName: profile?.name, profileSource: route.source,
                          stoppedEarly: o.reason.isEarly, duration: o.duration, sourceDevice: settings.deviceName)
        history.add(HistoryItem(dictation: d, delivery: .sending, partialCleanup: partial ? true : nil, spokenPrefix: route.spoken))
        refreshHistory()
        processing = false
        resolveTextWaiters(d.text)
        await deliver(d, resend: false)
        if o.reason == .hardCap { status = .notice("Stopped at 10:00, the limit for one dictation — it was sent") }
    }

    /// Cleanup never holds a dictation hostage. The budget is 8 s plus a second per 120
    /// characters, at most 60 s (a 10-minute dictation is ~9,000 characters; the model does
    /// ~150–220 a second). `Cleaner` cleans chunk by chunk and never starts one it can't finish
    /// in time, so a long dictation comes back partly cleaned rather than not at all.
    static func cleanupBudget(characters: Int) -> TimeInterval {
        #if DEBUG
        if let b = DebugHooks.env["MACROPHONE_CLEANUP_BUDGET"].flatMap(Double.init) { return b }
        #endif
        return min(8 + Double(characters) / 120, 60)
    }

    /// Returns nil only if the model overran the deadline by the safety margin (a hung call).
    private static func cleanWithDeadline(_ raw: String, level: CleanupLevel, dictionary: [String], language: String) async -> CleanupResult? {
        let budget = cleanupBudget(characters: raw.count)
        let deadline = Date().addingTimeInterval(budget)
        // Unstructured on purpose: a task group would wait for a model call that won't cancel.
        return await withCheckedContinuation { (c: CheckedContinuation<CleanupResult?, Never>) in
            let once = ResumeOnce(c)
            Task.detached { once.resume(await Cleaner.clean(raw, level: level, dictionary: dictionary, language: language, deadline: deadline)) }
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64((budget + 5) * 1e9))
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
        status = .sending(mac: mac.name, to: routeNote(d.id))
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
            if isLatest || !late { status = .delivered(mac: macName, detail: ack.detail, late: late, to: routeNote(id)); Haptics.success() }
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
                if latest?.id == e.id { status = .sending(mac: mac.name, to: routeNote(e.id)) }
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

    /// The last pairing failed for a reason the local network permission could explain.
    @Published private(set) var pairingMayNeedLocalNetwork = false

    private func pairingFailed(_ error: Error) {
        let mac: String
        if case .connecting(let name) = pairing { mac = name } else if case .showingCode(_, let name) = pairing { mac = name } else { mac = "your Mac" }
        let reach = "Couldn't reach \(mac). Keep Macrophone open on your Mac, with both on the same Wi-Fi, then try again."
        let message: String
        switch error as? LinkError {
        case .macNotFound?, .timedOut?, .connectionFailed?:
            message = reach
            pairingMayNeedLocalNetwork = true
        case let e?:
            message = e.userMessage
            pairingMayNeedLocalNetwork = false
        case nil:
            message = reach
            pairingMayNeedLocalNetwork = true
        }
        pairing = .failed(message)
        log.add("pairing failed: \(String(describing: error))")
        Haptics.error()
    }

    func resetPairing() { pairing = .idle; pairingMayNeedLocalNetwork = false }

    func unpair() async {
        guard let mac = client.activeMac else { return }
        await client.unpair(mac.id)
        forgetMac()
    }

    private func forgetMac() {
        pairedMac = client.activeMac
        profiles = []
        CachedProfile.save([])
        settings.sendTo = .automatic
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

    func setSendTo(_ target: SendTarget) {
        settings.sendTo = target
        log.add("send to: \(target == .automatic ? "automatic" : "a chosen target")")
    }

    // MARK: Intents

    /// Opens already recording (Action Button, Siri, Control Center, Shortcuts).
    func startFromIntent(profileID: UUID?) async {
        // A Shortcut / control that names a target sends there this once (`.chosen`);
        // "Automatic" sends on Automatic; empty uses the app's own choice.
        let override: SendTarget? = profileID.map { $0 == ProfileEntity.automaticID ? .automatic : .profile($0) }
        sheet = nil
        showOnboarding = false
        guard !recorder.isActive else { return }
        if UIApplication.shared.applicationState == .active {
            await startRecording(override: override)
        } else {
            recordingOverride = override
            pendingStart = true
            // The scene becomes active a moment after the intent runs; wait for it.
            for _ in 0..<60 where pendingStart {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if pendingStart, UIApplication.shared.applicationState == .active {
                pendingStart = false
                await startRecording(override: override)
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
            ("Microphone permission", { switch Recorder.micStatus { case .granted: return "allowed"; case .denied: return "denied"; default: return "not asked yet" } }()),
            ("Speech permission", { switch Recorder.speechStatus { case .authorized: return "allowed"; case .denied: return "denied"; case .restricted: return "restricted"; default: return "not asked yet" } }()),
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
        struct Seed { var raw: String; var cleaned: String?; var level: CleanupLevel; var target: String?; var source: ProfileSource?
                      var spoken: String?; var delivery: DeliveryState; var detail: String?; var ago: Double; var late = false }
        let seeds: [Seed] = [
            Seed(raw: "Claude, so um the thing I want to try is, uh, make the retry logic in the uploader back off exponentially, starting at one second and capping at thirty, and log every retry with the attempt number",
                 cleaned: "Make the retry logic in the uploader back off exponentially, starting at one second and capping at 30, and log every retry with the attempt number.",
                 level: .medium, target: "Claude", source: .prefix, spoken: "Claude", delivery: .delivered, detail: "Pasted into Claude · Sent", ago: 120),
            Seed(raw: "look at the failing snapshot test in the settings screen and tell me why the toggle renders twice, I think it's the, the on appear firing again",
                 cleaned: "Look at the failing snapshot test in the settings screen and tell me why the toggle renders twice. I think it's the onAppear firing again.",
                 level: .medium, target: "Claude Code (Terminal)", source: .chosen, spoken: nil, delivery: .delivered, detail: "Typed into Terminal · Sent", ago: 1_500),
            Seed(raw: "hey Sam the build is green again I'll cut the release after lunch",
                 cleaned: "Hey Sam, the build is green again. I'll cut the release after lunch.",
                 level: .light, target: nil, source: .automatic, spoken: nil, delivery: .delivered, detail: "Pasted into Slack", ago: 4_000),
            Seed(raw: "ChatGPT, compare SQLite and Postgres for an offline first iOS app with sync, keep it to a table",
                 cleaned: "Compare SQLite and Postgres for an offline-first iOS app with sync. Keep it to a table.",
                 level: .medium, target: "ChatGPT", source: .prefix, spoken: "ChatGPT", delivery: .delivered, detail: "Pasted into ChatGPT · Sent", ago: 9_000, late: true),
            Seed(raw: "rename fetch user to load user everywhere and update the tests",
                 cleaned: "Rename fetchUser to loadUser everywhere and update the tests.",
                 level: .medium, target: "Cursor", source: .chosen, spoken: nil, delivery: .delivered, detail: "Pasted into Cursor", ago: 90_000),
        ]
        for s in seeds.reversed() {
            let d = Dictation(createdAt: Date().addingTimeInterval(-s.ago), raw: s.raw, cleaned: s.cleaned, cleanupLevel: s.level,
                              language: "en-US", profileID: profiles.first { $0.name == s.target }?.id, profileName: s.target,
                              profileSource: s.source, duration: Double(s.raw.count) / 14, sourceDevice: settings.deviceName)
            history.add(HistoryItem(dictation: d, delivery: s.delivery, detail: s.detail, macName: "Sameer's MacBook Pro",
                                    wasDelayed: s.late, deliveredAt: Date(), spokenPrefix: s.spoken))
        }
        refreshHistory()
    }

    func debugSetStatus(_ s: DeliveryStatus) { status = s; bumpPulse() }

    func debugFailPairing() { pairingFailed(LinkError.macNotFound) }

    var debugProfilesLocked = false

    var debugPairingLocked = false

    func debugFakePairing(mac: String) {
        debugPairingLocked = true
        pairedMac = PairedPeer(id: UUID(), name: mac)
        linkState = .connected(mac)
    }

    /// Stands in for the Mac's list; stable ids so a pick survives relaunches.
    func debugFakeProfiles(_ list: [ProfileSummary]) {
        debugProfilesLocked = true
        profiles = list
        CachedProfile.save(list.map {
            CachedProfile(id: $0.id, name: $0.name, isDefault: $0.isDefault, cleanupLevel: $0.cleanupLevel?.rawValue, voicePrefixes: $0.voicePrefixes)
        })
    }
    #endif
}

extension AppModel: LinkClientDelegate {
    func linkClient(_ client: LinkClient, stateChanged state: LinkClient.State) {
        guard client === self.client else { return }
        #if DEBUG
        if debugPairingLocked { return }
        #endif
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
        #if DEBUG
        if debugProfilesLocked { return }
        #endif
        self.profiles = profiles
        CachedProfile.save(profiles.map {
            CachedProfile(id: $0.id, name: $0.name, isDefault: $0.isDefault, cleanupLevel: $0.cleanupLevel?.rawValue, voicePrefixes: $0.voicePrefixes)
        })
        // The Mac no longer has the picked target: fall back to Automatic rather than guess.
        if let id = settings.sendTo.profileID, !profiles.contains(where: { $0.id == id }) { settings.sendTo = .automatic }
        MacrophoneShortcuts.updateAppShortcutParameters()
    }

    func linkClient(_ client: LinkClient, localNetworkDenied: Bool) {
        guard client === self.client else { return }
        self.localNetworkDenied = localNetworkDenied
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
