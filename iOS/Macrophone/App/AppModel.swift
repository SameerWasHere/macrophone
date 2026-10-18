import AVFoundation
import Combine
import Foundation
import MacrophoneKit
import SwiftUI
import WidgetKit
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
    /// The Mac has the words; waiting to hear where they landed (its countdown, then the paste).
    case landing(mac: String, to: RouteNote?)
    /// Where they landed: in the app (a mint ✓), or not — and why (rose; ochre when copied instead).
    case landed(Landing)
    /// The Mac took the words but never said where they landed.
    case unconfirmed(mac: String)
    case nothingHeard
    case notice(String)
    case problem(String, openSettings: Bool)
}

/// Which target a dictation went to, for the status line: "Sent to Messages — you said “Messages” first".
struct RouteNote: Equatable {
    var name: String
    /// The lead-in as heard, when saying it picked the target.
    var spoken: String?
    /// Paste & send was on for it.
    var send = false
}

/// How one dictation is routed: where, paste or send, and the words to clean and send.
struct Route: Equatable {
    var target: TargetRef
    var send: Bool
    /// The transcript with any spoken name taken off.
    var body: String
    /// The name as heard ("Messages", "Claude"), when saying it picked the target.
    var spoken: String?
    /// An open app's name said first ("Messages, …") picked it.
    var spokenTarget = false
}

enum AppSheet: String, Identifiable {
    case history, settings, pairing, customCleanup, openApp
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
    /// The picked app's window, live (Watching).
    let watcher = Watcher()
    let queue = DeliveryQueue(url: AppFiles.queue)
    let log = DiagnosticLog(url: AppFiles.log)
    private let history: HistoryStore<HistoryItem>
    private let pairingStore = KeychainPairingStore(service: "com.sameer.macrophone.pairing", directory: AppFiles.directory)
    private(set) var client: LinkClient

    // Published state the screens read.
    @Published var status: DeliveryStatus = .ready {
        didSet { if status != oldValue, note != nil { note = nil } }
    }
    /// A control just changed: the status line says what it now does, for a few seconds.
    @Published private(set) var note: String?
    private var noteTask: Task<Void, Never>?
    @Published private(set) var latest: HistoryItem?
    @Published private(set) var historyItems: [HistoryItem] = []
    @Published private(set) var linkState: LinkClient.State = .notPaired
    /// Connected over an address the Mac gave for away (or one typed here), not Bonjour: the
    /// status line says "away from home" (Oct 17 2026).
    @Published private(set) var isRemote = false
    /// How it's connected to the Mac: home network, nearby (direct Wi-Fi), Tailscale, internet.
    @Published private(set) var linkRoute: LinkRoute?
    /// Where the paired Mac can be reached from away, in the order they'd be dialled — what it
    /// told this iPhone at home (with Remote access on), plus the one address typed in Settings.
    @Published private(set) var remoteAddresses: [RemoteAddress] = []
    @Published private(set) var discoveredMacs: [DiscoveredMac] = []
    /// iOS is blocking the local network for this app — nothing can be found until it's on.
    @Published private(set) var localNetworkDenied = false
    /// The Mac's open apps/windows with somewhere to type, newest first (cached while it's away).
    @Published private(set) var liveTargets: [LiveTarget] = []
    /// Reader: the watched window's words, as the Mac last read them.
    @Published private(set) var readerPage: ReaderPage?
    /// A photo or file on its way (its words for the status line).
    @Published private(set) var sendingAttachment: String?
    /// Asks the Mac for Reader's words while it shows.
    private var readerTask: Task<Void, Never>?

    /// The chats you're in that answered you: their apps wear a mark in Send to.
    @Published private(set) var needsYou: [NeedsYou] = []
    /// The Mac sent its list since the link last connected (so "Not open on your Mac" is current).
    @Published private(set) var targetsCurrent = false
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
    private var recordingOverride: SendSelection?
    private var textWaiters: [CheckedContinuation<String?, Never>] = []
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var statusReset: Task<Void, Never>?
    /// The dictation whose landing the status line is waiting on, and the wait itself.
    private var awaitingLanding: (id: UUID, mac: String, late: Bool, ackDetail: String?)?
    private var landingWait: Task<Void, Never>?
    /// How long after the Mac's ack to wait for where it landed (its 2.5 s countdown included).
    static let landingTimeout: TimeInterval = 12

    private init() {
        let t0 = LaunchClock.millisecondsSinceProcessStart
        history = HistoryStore(url: AppFiles.history, capacity: 50, enabled: UserDefaults.standard.object(forKey: Settings.K.history) as? Bool ?? true)
        client = Self.makeClient(store: pairingStore, name: settings.deviceName, log: log)
        showOnboarding = !UserDefaults.standard.bool(forKey: "onboarding.done")
        client.delegate = self
        linkState = client.state
        pairedMac = client.activeMac
        remoteAddresses = client.remoteAddresses
        recorder.log = log
        watcher.log = log
        watcher.sendWatch = { [weak self] t in self?.client.watch(t) ?? false }
        watcher.sendAction = { [weak self] a in self?.client.watchAction(a) }
        watcher.sendClick = { [weak self] p in self?.client.watchClick(p) }
        watcher.sendRightClick = { [weak self] p in self?.client.watchRightClick(p) ?? false }
        watcher.sendWindow = { [weak self] c in self?.client.watchWindow(c) ?? false }
        watcher.sendKey = { [weak self] k in self?.client.watchKey(k) ?? false }
        watcher.sendShape = { [weak self] s in self?.client.watchShape(s) ?? false }
        watcher.sendScroll = { [weak self] p, d in self?.client.watchScroll(at: p, by: d) }
        watcher.sendScrollPhase = { [weak self] phase, p in self?.client.watchScrollPhase(phase, at: p) }
        watcher.sendChoose = { [weak self] p, i in self?.client.watchChoose(p, index: i) }
        watcher.sendKeyframe = { [weak self] in self?.client.watchKeyframe() ?? false }
        watcher.sendFit = { [weak self] f in self?.client.watchFit(f) ?? false }
        watcher.macFeatures = { [weak self] in self?.client.macFeatures ?? [] }
        AgentAlerts.shared.install(self)
        // Reader asks the Mac for the window's words every few seconds while it shows.
        Publishers.CombineLatest3(watcher.$reading, watcher.$isOpen, watcher.$target)
            .sink { [weak self] reading, open, _ in self?.readerFollows(reading && open) }
            .store(in: &bag)
        // Looking at a chat that answered settles its mark.
        watcher.$target.compactMap { $0 }.sink { [weak self] t in self?.clearNeeds(for: t) }.store(in: &bag)
        Task { await AgentAlerts.shared.subscribeInCloud() }
        // Notifications are asked for the first time a window is watched — the moment they make sense.
        watcher.$isOpen.filter { $0 }.first().sink { [weak self] _ in
            guard self?.settings.agentAlerts == true else { return }
            Task { await AgentAlerts.shared.askIfNeeded() }
        }.store(in: &bag)
        recorder.onFinish = { [weak self] outcome in self?.recordingFinished(outcome) }
        recorder.$phase.sink { [weak self] in self?.recorderPhase = $0 }.store(in: &bag)
        recorder.$softCapReached.filter { $0 }.sink { [weak self] _ in
            Haptics.warning()
            self?.objectWillChange.send()
        }.store(in: &bag)
        if pairedMac != nil { liveTargets = Self.loadTargets() }
        refreshHistory()
        refreshAvailability()
        // One line (each write rewrites the log file) and no keychain read: launch stays light.
        log.add("app launched, version \(Bundle.main.shortVersion) (\(Bundle.main.buildNumber)), \(queue.count) queued; "
                + "language \(settings.language); cleanup \(cleanupAvailability.isAvailable ? "available" : "unavailable"); open apps cached: \(liveTargets.count); "
                + "model ready \(LaunchClock.millisecondsSinceProcessStart) ms after launch (its own setup \(LaunchClock.millisecondsSinceProcessStart - t0) ms)")
    }

    private static func makeClient(store: KeychainPairingStore, name: String, log: DiagnosticLog) -> LinkClient {
        let c = LinkClient(identity: DeviceIdentity.load(name: name), store: store,
                           appVersion: Bundle.main.shortVersion, osDescription: "iOS \(UIDevice.current.systemVersion)")
        c.log = log
        // The phone's choice goes to the Mac after every welcome, so on reconnect the phone's wins.
        c.selectionProvider = { Settings.storedSelection() }
        // A Mac that reads questions off windows tells this phone when one asks (AgentAlerts);
        // one with remote access on tells it where it can be reached from away; one that can sends
        // the watched window as video (Watcher decodes it).
        c.features = [Attention.feature, RemoteAccess.feature, WatchVideo.feature, NeedsYou.feature,
                      ReaderPage.feature, ClipboardItem.feature, AttachmentChunk.feature] + (AgentAlerts.cloudReady ? [Attention.cloudFeature] : [])
        #if DEBUG
        // MACROPHONE_VIDEO=0: a phone from before video (pictures), to compare the two.
        if DebugHooks.env["MACROPHONE_VIDEO"] == "0" { c.features.removeAll { $0 == WatchVideo.feature } }
        #endif
        return c
    }

    private static func loadTargets() -> [LiveTarget] {
        guard let d = try? Data(contentsOf: AppFiles.targets) else { return [] }
        return (try? JSONDecoder().decode([LiveTarget].self, from: d)) ?? []
    }

    private func saveTargets(_ list: [LiveTarget]) {
        if let d = try? JSONEncoder().encode(list) { try? d.write(to: AppFiles.targets, options: .atomic) }
        CachedTarget.save(list.map { CachedTarget(id: "app:\($0.bundleID)#\($0.windowKey ?? "")", name: $0.title) })
        publishWidget()
    }

    /// The Watch widget's four apps: the newest window of each of the four apps used most
    /// recently, with its icon and the ember mark when a chat there answered you. The widget
    /// reloads only when that changes.
    func publishWidget() {
        var seen = Set<String>()
        let apps = liveTargets.filter { seen.insert($0.bundleID).inserted }.prefix(WidgetApp.limit).map { t in
            WidgetApp(id: "app:\(t.bundleID)#\(t.windowKey ?? "")", name: t.appName, icon: t.icon,
                      needsYou: needsYou.contains { $0.bundleID == t.bundleID })
        }
        if WidgetApp.save(Array(apps)) { WidgetCenter.shared.reloadTimelines(ofKind: WidgetApp.kind) }
    }

    // MARK: Derived

    var isPaired: Bool { pairedMac != nil }
    var isConnected: Bool { if case .connected = linkState { return true }; return false }
    var macName: String { pairedMac?.name ?? "your Mac" }

    /// Where the next dictation goes (a Shortcut's pick wins while it records).
    var selection: SendSelection { recordingOverride ?? settings.selection }

    /// The open app a target names, if it's open on the Mac right now.
    func liveTarget(for ref: TargetRef) -> LiveTarget? { liveTargets.first { ref.matches($0) } }

    /// A remembered app that isn't open on the Mac (it'll copy instead).
    func isNotOpen(_ ref: TargetRef) -> Bool {
        guard case let .app(bid, _, _) = ref, targetsCurrent || !liveTargets.isEmpty else { return false }
        // Just opened from here: its window may take a moment to show up.
        if isOpening(bid) { return false }
        return liveTarget(for: ref) == nil
    }

    /// The level cleanup will run at, after availability (and the language: English only).
    var effectiveCleanupLevel: CleanupLevel {
        guard cleanupAvailability.isAvailable, settings.isEnglish else { return .off }
        return settings.cleanupLevel
    }

    /// Paste or Paste & send for a target: the current choice's own setting, else what was last
    /// used with it.
    func sendSetting(for ref: TargetRef) -> Bool {
        guard ref.canSend else { return false }
        if ref == settings.selection.target { return settings.selection.send }
        return settings.rememberedSend(for: ref)
    }

    /// Picks the target for one transcript: an open app's name said first ("Messages, …") >
    /// a Shortcut's pick > the Send-to choice.
    func route(for raw: String) -> Route {
        if isPaired, !liveTargets.isEmpty, let m = SpokenTarget.match(raw, targets: liveTargets) {
            let ref = m.target.ref
            return Route(target: ref, send: sendSetting(for: ref), body: m.text, spoken: m.target.appName, spokenTarget: true)
        }
        let sel = selection
        return Route(target: sel.target, send: sendSetting(for: sel.target), body: raw)
    }

    /// Where this one goes while the words come in: a spoken name shows up the moment it's heard.
    func liveRoute(_ transcript: String) -> (target: TargetRef, send: Bool, byVoice: Bool) {
        let r = route(for: transcript)
        return (r.target, r.send, r.spoken != nil)
    }

    func routeNote(_ id: UUID) -> RouteNote? {
        guard let item = historyItems.first(where: { $0.id == id }) ?? (latest?.id == id ? latest : nil),
              let name = item.targetName else { return nil }
        return RouteNote(name: name, spoken: item.spokenPrefix, send: item.dictation.send == true)
    }

    func refreshAvailability() {
        cleanupAvailability = Cleaner.availability(language: settings.language)
        // The mic and the newer speech engine, made ready ahead of the tap (the model fetched when
        // it isn't on the phone yet).
        recorder.ready(language: settings.language, contextualStrings: settings.dictionary)
        #if DEBUG
        if DebugHooks.env["MACROPHONE_CLEANUP_AVAILABLE"] == "1" { cleanupAvailability = .available }
        #endif
    }

    // MARK: Lifecycle

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            sceneActive = true
            endBackgroundTask()
            refreshAvailability()
            if networkExplained || isPaired { client.start() }
            // A window that was being watched comes back by itself (the link reconnects first).
            watcher.sceneBecameActive()
            if pendingStart { pendingStart = false; Task { await startRecording(override: recordingOverride) } }
        case .background:
            sceneActive = false
            watcher.pause(.leftScreen)
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

    func startRecording(override: SendSelection? = nil) async {
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
        #if DEBUG
        if Recorder.audioFile != nil {
            // A test file stood in for the mic: show what was heard, send nothing.
            log.add("test file heard: \(raw.split(separator: " ").count) words")
            status = .notice(raw)
            return
        }
        #endif
        processing = true
        Task { await finish(raw: raw, outcome: o) }
    }

    private func finish(raw: String, outcome o: Recorder.Outcome) async {
        processing = true
        inFlight += 1
        defer { processing = false; inFlight -= 1 }
        let route = route(for: raw)
        let level = effectiveCleanupLevel
        recordingOverride = nil
        log.add("target: \(Self.kind(route.target))\(route.send ? " + send" : "")\(route.spoken != nil ? " (said)" : "")")
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
        // Every dictation carries where it goes, so the Mac routes each one exactly (a sync race
        // can't misroute it).
        let d = Dictation(raw: raw, cleaned: cleaned, cleanupLevel: cleanupRan ? level : .off, language: o.language,
                          target: route.target, send: route.send, targetSpoken: route.spokenTarget ? true : nil,
                          stoppedEarly: o.reason.isEarly, duration: o.duration, sourceDevice: settings.deviceName)
        #if DEBUG
        routeProbe = "target=\(route.target.storageKey) send=\(route.send ? 1 : 0) cleanup=\(level.rawValue) said=\(route.spokenTarget ? 1 : 0) text=\(d.text)"
            + (level == .custom ? " | instructions=\(CleanupPrompts.customInstructions.prefix(80).replacingOccurrences(of: "\n", with: " "))" : "")
        #endif
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
        #if DEBUG
        // The simulator may not have Apple's model: a stand-in that reports what the real one was told.
        if DebugHooks.env["MACROPHONE_FAKE_CLEANUP"] == "1" { return DebugHooks.fakeClean(raw, level: level, dictionary: dictionary) }
        #endif
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
            // The ack only says the Mac has it: the ✓ waits for where it landed.
            if isLatest || !late {
                if item(id)?.landing != nil { showLanding(id, late: late) }
                else { awaitLanding(id, mac: macName, late: late, ackDetail: ack.detail) }
            }
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

    // MARK: Where it landed

    private func item(_ id: UUID) -> HistoryItem? {
        historyItems.first(where: { $0.id == id }) ?? (latest?.id == id ? latest : nil)
    }

    /// "Sending to Claude…" until the Mac says where it landed, or the wait runs out.
    private func awaitLanding(_ id: UUID, mac: String, late: Bool, ackDetail: String?) {
        landingWait?.cancel()
        awaitingLanding = (id, mac, late, ackDetail)
        status = .landing(mac: mac, to: routeNote(id))
        landingWait = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.landingTimeout * 1e9))
            guard !Task.isCancelled, let self, let w = self.awaitingLanding, w.id == id else { return }
            self.awaitingLanding = nil
            if self.macReportsLandings {
                self.updateItem(id) { $0.landingUnconfirmed = true }
                if !self.recorder.isActive { self.status = .unconfirmed(mac: mac); Haptics.warning() }
                self.log.add("no landing within \(Int(Self.landingTimeout))s")
            } else if !self.recorder.isActive {
                // A Mac that never reports landings (an older version): the ack's own words, as before.
                self.status = .delivered(mac: mac, detail: ackDetail, late: late, to: self.routeNote(id))
                Haptics.success()
            }
            self.bumpPulse()
        }
    }

    /// The landing on record for this dictation, on the status line.
    private func showLanding(_ id: UUID, late: Bool) {
        guard let it = item(id), let result = it.landing else { return }
        landingWait?.cancel()
        awaitingLanding = nil
        let l = Landing(result: result, detail: it.landingDetail ?? "", target: it.dictation.target, to: routeNote(id), late: late)
        guard !recorder.isActive else { return }   // the next one is being spoken: History has it
        status = .landed(l)
        if l.isSuccess { Haptics.success() } else { Haptics.error() }
        bumpPulse()
        // Sent into an app: show its window, so the answer can be read (and approved) from here.
        if result == .sent, settings.watchAfterSending, let t = it.dictation.target, t != .clipboard, sceneActive {
            watcher.follow(t)
        }
    }

    /// This Mac has told the phone where a dictation landed before (so silence means something).
    private var macReportsLandings: Bool {
        guard let mac = client.activeMac else { return false }
        #if DEBUG
        if DebugHooks.env["MACROPHONE_LANDINGS"] == "ignore-old" { return false }
        #endif
        return UserDefaults.standard.bool(forKey: "landing.reports.\(mac.id.uuidString)")
    }

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
        // The Watch widget: macrophone://watch?target=app:<bundleID>#<window> watches that app's
        // window (and sends there); macrophone://open just opens the app.
        if url.scheme == "macrophone", url.host == "open" { return }
        if url.scheme == "macrophone", url.host == "watch" {
            let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "target" }?.value
            guard let id, let sel = intentSelection(id, name: nil) else { return }
            sheet = nil
            log.add("widget: watching an app")
            openAttention(sel.target)
            return
        }
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

    /// Settings › Away from home: keep one typed address for the paired Mac (empty clears it).
    /// False when the words aren't an address.
    @discardableResult
    func setTypedAddress(_ text: String) -> Bool {
        guard let mac = client.activeMac else { return false }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty {
            client.setTypedAddress(nil, for: mac.id)
        } else {
            guard let a = RemoteAddressRule.parse(t) else { return false }
            client.setTypedAddress(a, for: mac.id)
        }
        remoteAddresses = client.remoteAddresses
        pairedMac = client.activeMac
        return true
    }

    /// The one address typed here, if any.
    var typedAddress: RemoteAddress? { remoteAddresses.first { $0.source == .typed } }
    /// What the Mac itself said (its Tailscale address first).
    var macToldAddresses: [RemoteAddress] { remoteAddresses.filter { $0.source == .mac } }

    private func forgetMac() {
        pairedMac = client.activeMac
        remoteAddresses = []
        isRemote = false
        linkRoute = nil
        liveTargets = []
        targetsCurrent = false
        saveTargets([])
        settings.selection = .default
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

    /// Picks where dictations go (Paste or Paste & send as last used there). Applies to the next
    /// dictation — or the one being recorded — and goes to the Mac at once.
    // MARK: Open an app

    /// The apps installed on the Mac (Open an app), newest answer from the Mac.
    @Published private(set) var macApps: [MacApp] = []
    @Published private(set) var macAppsLoaded = false
    /// Apps opened from here in the last moments (they count as open until their window shows).
    private var justOpened: [String: Date] = [:]

    /// Opened from here moments ago and not in the list yet.
    func isOpening(_ bundleID: String) -> Bool {
        guard let t = justOpened[bundleID] else { return false }
        return Date().timeIntervalSince(t) < 20
    }

    /// Ask the Mac for its apps (the sheet opened).
    func requestMacApps() {
        if !client.listApps() { macAppsLoaded = true }
    }

    /// Open an app on the Mac, bring it forward, and send there from now on.
    func openOnMac(_ app: MacApp) {
        guard client.openApp(app.bundleID) else {
            explain("Your Mac isn't connected — open \(app.name) when it is")
            Haptics.warning()
            return
        }
        Haptics.tick()
        justOpened[app.bundleID] = Date()
        pick(.app(bundleID: app.bundleID, windowKey: nil, name: app.name))
        explain("Opening \(app.name) on your Mac", for: 6)
        log.add("asked the Mac to open an app")
    }

    /// The Mac can quit apps (a Mac from before Oct 17 2026 can't; the button doesn't show).
    var canQuitApps: Bool { client.canQuitApps }
    /// Asked to quit and not answered yet.
    @Published private(set) var quitting: Set<String> = []

    /// Quit an app on the Mac, the way ⌘Q does — it may ask on the Mac first.
    func quitOnMac(_ app: MacApp) {
        guard client.quitApp(app.bundleID) else {
            explain("Your Mac isn't connected — quit \(app.name) when it is")
            Haptics.warning()
            return
        }
        Haptics.tick()
        quitting.insert(app.bundleID)
        explain("Quitting \(app.name) on your Mac", for: 6)
        log.add("asked the Mac to quit an app")
    }

    // MARK: Watching — flipping between windows (Oct 16 2026)

    /// Every window the Mac can show, in a steady order (the Mac's own list re-sorts by use, which
    /// would move the next one while flipping).
    var watchSessions: [LiveTarget] {
        liveTargets.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Watch that window, and send there too — the window on screen is where the words go.
    @discardableResult
    func watchSession(_ t: LiveTarget) -> Bool {
        guard !(watcher.target?.matches(t) ?? false) else { return false }
        Haptics.tick()
        pick(t.ref)
        watcher.open(t.ref)
        return true
    }

    /// The next (1) or previous (-1) window, wrapping round. Returns the one it went to.
    @discardableResult
    func watchStep(_ step: Int) -> LiveTarget? {
        let list = watchSessions
        guard list.count > 1 else { return nil }
        let at = watcher.target.flatMap { t in list.firstIndex { t.matches($0) } }
        let t = list[at.map { ($0 + step + list.count) % list.count } ?? 0]
        return watchSession(t) ? t : nil
    }

    func pick(_ target: TargetRef) {
        setSelection(SendSelection(target: target, send: settings.rememberedSend(for: target)))
    }

    /// Paste only, or paste and press send. Remembered for this target.
    func setSend(_ on: Bool) { setSend(on, for: settings.selection.target) }

    /// For the choice it syncs with the Mac; for an app said first mid-recording it's remembered
    /// for that app and applies to the words being spoken.
    func setSend(_ on: Bool, for target: TargetRef) {
        guard target.canSend else { return }
        if target == settings.selection.target {
            setSelection(SendSelection(target: target, send: on))
        } else {
            objectWillChange.send()
            settings.rememberSend(on, for: target)
        }
    }

    func setSelection(_ s: SendSelection) {
        recordingOverride = nil   // a change made now wins over a Shortcut's pick for this recording
        guard s != settings.selection else { return }
        settings.selection = s
        client.setSelection(s)
        log.add("send to: \(Self.kind(s.target))\(s.send ? " + send" : "")")
    }

    func setCleanupLevel(_ level: CleanupLevel) {
        settings.cleanupLevel = level
        log.add("cleanup: \(level.rawValue)")
    }

    /// The Custom level's instructions, as the person types them (empty = the default, Medium's).
    func setCustomInstructions(_ text: String) {
        guard text != settings.customInstructions else { return }
        settings.customInstructions = text
        // Rebuild the prewarmed session if he's editing while Custom is about to run.
        if recorder.isActive, effectiveCleanupLevel == .custom { Cleaner.prewarm(level: .custom, dictionary: settings.dictionary) }
    }

    /// The instructions Custom will follow (the default until edited).
    var customInstructionsEdited: Bool {
        let t = settings.customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && t != CleanupPrompts.defaultCustomInstructions
    }

    /// For the log: the kind of target, never an app's or window's name.
    static func kind(_ t: TargetRef) -> String {
        switch t {
        case .clipboard: return "clipboard"
        case .frontApp: return "where I'm typing"
        case .app: return "an open app"
        }
    }

    /// Says in the status line what a control change does ("Pastes into Claude, then sends").
    func explain(_ sentence: String, for seconds: Double = 3.2) {
        note = sentence
        noteTask?.cancel()
        noteTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
            guard !Task.isCancelled else { return }
            self?.note = nil
        }
    }

    /// The picker opened: ask the Mac to look again.
    func refreshTargets() { client.refreshTargets() }

    // MARK: Intents

    /// Opens already recording (Action Button, Siri, Control Center, Shortcuts).
    func startFromIntent(targetID: String?, name: String? = nil) async {
        // A Shortcut / control that names a place sends there this once; empty uses the app's choice.
        let override = targetID.flatMap { intentSelection($0, name: name) }
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
    /// "clipboard", "front", "app:<bundleID>#<windowKey>" → a one-recording choice. (A control set
    /// to one of the Mac's former automations — "auto:<UUID>" — uses the app's own choice.)
    func intentSelection(_ id: String, name: String?) -> SendSelection? {
        let target: TargetRef
        switch id {
        case TargetEntity.clipboardID: target = .clipboard
        case TargetEntity.frontID: target = .frontApp
        default:
            if id.hasPrefix("app:") {
                let parts = id.dropFirst(4).split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                let bid = parts.first ?? ""
                let key = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
                let live = liveTargets.first { $0.bundleID == bid && $0.windowKey == key }
                target = .app(bundleID: bid, windowKey: key, name: live?.title ?? name ?? bid)
            } else {
                return nil
            }
        }
        return SendSelection(target: target, send: sendSetting(for: target))
    }

    func dictateForIntent() async -> String? {
        await startFromIntent(targetID: nil)
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
        case .connected: connection = isRemote ? "connected (away from home)" : "connected"
        case .unreachable: connection = "Mac not found"
        }
        return log.export(header: [
            ("App version", "\(Bundle.main.shortVersion) (\(Bundle.main.buildNumber))"),
            ("iOS", UIDevice.current.systemVersion),
            ("Device model", model),
            ("Paired Macs", "\(client.pairedMacs.count)"),
            ("Connection", connection),
            ("Macs seen on the network", "\(discoveredMacs.count)"),
            ("Addresses for away", "\(macToldAddresses.count) from the Mac\(typedAddress != nil ? ", 1 typed" : "")"),
            ("Queued dictations", "\(queue.count)"),
            ("Language", settings.language),
            ("Cleanup", "\(settings.cleanupLevel.title)\(settings.cleanupLevel == .custom ? (customInstructionsEdited ? " (edited, \(settings.customInstructions.count) characters)" : " (default)") : "") · \(cleanupAvailability.isAvailable ? "available" : String(describing: cleanupAvailability))"),
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
    /// The last dictation's route, for UI tests (`MACROPHONE_ROUTE_PROBE`).
    @Published var routeProbe = ""

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
        struct Seed { var raw: String; var cleaned: String?; var level: CleanupLevel; var target: TargetRef; var send = false
                      var spoken: String? = nil; var detail: String?; var ago: Double; var late = false }
        let claude = TargetRef.app(bundleID: "com.anthropic.claudefordesktop", windowKey: nil, name: "Claude")
        let seeds: [Seed] = [
            Seed(raw: "Claude, so um the thing I want to try is, uh, make the retry logic in the uploader back off exponentially, starting at one second and capping at thirty, and log every retry with the attempt number",
                 cleaned: "Make the retry logic in the uploader back off exponentially, starting at one second and capping at 30, and log every retry with the attempt number.",
                 level: .medium, target: claude, send: true, spoken: "Claude", detail: "Sent to Claude", ago: 120),
            Seed(raw: "look at the failing snapshot test in the settings screen and tell me why the toggle renders twice, I think it's the, the on appear firing again",
                 cleaned: "Look at the failing snapshot test in the settings screen and tell me why the toggle renders twice. I think it's the onAppear firing again.",
                 level: .medium, target: .app(bundleID: "com.apple.Terminal", windowKey: "41", name: "Terminal — claude"), send: true,
                 detail: "Sent to Terminal — claude", ago: 1_500),
            Seed(raw: "hey Sam the build is green again I'll cut the release after lunch",
                 cleaned: "Hey Sam, the build is green again. I'll cut the release after lunch.",
                 level: .light, target: .frontApp, detail: "Pasted into Slack", ago: 4_000),
            Seed(raw: "compare SQLite and Postgres for an offline first iOS app with sync, keep it to a table",
                 cleaned: "Compare SQLite and Postgres for an offline-first iOS app with sync. Keep it to a table.",
                 level: .medium, target: claude, send: true, detail: "Sent to Claude", ago: 9_000, late: true),
            Seed(raw: "rename fetch user to load user everywhere and update the tests",
                 cleaned: "Rename fetchUser to loadUser everywhere and update the tests.",
                 level: .medium, target: .clipboard, detail: "Copied to clipboard", ago: 90_000),
        ]
        for s in seeds.reversed() {
            let d = Dictation(createdAt: Date().addingTimeInterval(-s.ago), raw: s.raw, cleaned: s.cleaned, cleanupLevel: s.level,
                              language: "en-US", target: s.target, send: s.send, targetSpoken: s.spoken != nil ? true : nil,
                              duration: Double(s.raw.count) / 14, sourceDevice: settings.deviceName)
            history.add(HistoryItem(dictation: d, delivery: .delivered, detail: s.detail, macName: "Sameer's MacBook Pro",
                                    wasDelayed: s.late, deliveredAt: Date(), spokenPrefix: s.spoken))
        }
        refreshHistory()
    }

    /// Stands in for the Mac's open apps.
    func debugFakeTargets(_ list: [LiveTarget]) {
        debugTargetsLocked = true
        liveTargets = list
        targetsCurrent = true
        saveTargets(list)
    }

    func debugSetStatus(_ s: DeliveryStatus) { status = s; bumpPulse() }

    func debugFailPairing() { pairingFailed(LinkError.macNotFound) }

    var debugTargetsLocked = false

    var debugPairingLocked = false

    /// Claude and Terminal answered (MACROPHONE_FAKE_NEEDS=1, after the fake targets).
    func debugFakeNeeds() {
        needsYou = liveTargets.filter { ["Claude", "Terminal"].contains($0.appName) }.map {
            NeedsYou(bundleID: $0.bundleID, windowKey: $0.windowKey ?? "1", since: Date(), asking: $0.appName == "Terminal")
        }
    }

    func debugFakePairing(mac: String) {
        debugPairingLocked = true
        pairedMac = PairedPeer(id: UUID(), name: mac)
        linkState = .connected(mac)
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
        isRemote = client.isRemote
        linkRoute = client.route
        if case .connected = state { flushQueue() } else { targetsCurrent = false }
        // Another Mac, or none: its agents aren't this one's.
        if case .notPaired = state { needsYou = [] }
        if case .connected = state { watcher.linkChanged(connected: true) } else { watcher.linkChanged(connected: false) }
    }

    func linkClient(_ client: LinkClient, discovered macs: [DiscoveredMac]) {
        guard client === self.client else { return }
        discoveredMacs = macs
    }

    /// An older Mac still sends its automations; the phone no longer offers them.

    func linkClient(_ client: LinkClient, targets: [LiveTarget], macID: UUID) {
        guard client === self.client else { return }
        #if DEBUG
        if debugTargetsLocked { return }
        #endif
        liveTargets = targets
        targetsCurrent = true
        saveTargets(targets)
        log.add("open apps on the Mac: \(targets.count)")
        MacrophoneShortcuts.updateAppShortcutParameters()
    }

    /// Changed on the Mac: apply it here, and don't send it back.
    func linkClient(_ client: LinkClient, selectionChanged selection: SendSelection, macID: UUID) {
        guard client === self.client else { return }
        recordingOverride = nil
        var selection = selection
        // Show the app the way the phone lists it ("Terminal — claude"), whatever name the Mac sent.
        if case .app = selection.target, let live = liveTarget(for: selection.target) {
            selection = SendSelection(target: live.ref, send: selection.send)
        }
        settings.selection = selection
        log.add("send to changed on the Mac: \(Self.kind(selection.target))\(selection.send ? " + send" : "")")
    }

    /// Where a dictation finally landed on the Mac. A retry from the Mac's popup reports again:
    /// the latest result wins.
    func linkClient(_ client: LinkClient, landed id: UUID, result: LandingResult, detail: String) {
        guard client === self.client else { return }
        #if DEBUG
        // Tests: a Mac that never confirms (ignore), or an older one that never could (ignore-old).
        if ["ignore", "ignore-old"].contains(DebugHooks.env["MACROPHONE_LANDINGS"] ?? "") { return }
        #endif
        if let mac = client.activeMac { UserDefaults.standard.set(true, forKey: "landing.reports.\(mac.id.uuidString)") }
        updateItem(id) { $0.landing = result; $0.landingDetail = detail; $0.landingUnconfirmed = nil }
        log.add("landed: \(result.rawValue)")
        let waiting = awaitingLanding?.id == id
        // The one on screen (or the newest, after a retry on the Mac) shows it; older ones go to History.
        guard waiting || latest?.id == id else { return }
        switch status {
        case .landing, .landed, .unconfirmed, .delivered, .ready: break
        default: if !waiting { return }
        }
        showLanding(id, late: awaitingLanding?.late ?? (item(id)?.wasDelayed ?? false))
    }

    func linkClient(_ client: LinkClient, installedApps: [MacApp]) {
        guard client === self.client else { return }
        macApps = installedApps
        macAppsLoaded = true
    }

    func linkClient(_ client: LinkClient, appQuit bundleID: String, ok: Bool, detail: String) {
        guard client === self.client else { return }
        quitting.remove(bundleID)
        if ok { Haptics.success() } else { Haptics.warning() }
        explain(detail)
        // The lists follow: its row says it's closed, and it leaves Send to.
        _ = client.listApps()
        client.refreshTargets()
    }

    func linkClient(_ client: LinkClient, appOpened bundleID: String, ok: Bool, detail: String) {
        guard client === self.client else { return }
        if ok {
            Haptics.success()
            explain("\(detail) — it's where you send now")
            // Its window shows up a moment after launch.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                self?.client.refreshTargets()
            }
        } else {
            justOpened[bundleID] = nil
            Haptics.error()
            explain(detail)
        }
    }

    func linkClient(_ client: LinkClient, watchState: WatchState) {
        guard client === self.client else { return }
        watcher.received(watchState)
    }

    func linkClient(_ client: LinkClient, watchFrame: WatchFrame) {
        guard client === self.client else { return }
        watcher.received(watchFrame)
    }

    func linkClient(_ client: LinkClient, watchVideo: WatchVideoFrame) {
        guard client === self.client else { return }
        watcher.received(watchVideo)
    }

    func linkClient(_ client: LinkClient, attention: Attention) {
        guard client === self.client, settings.agentAlerts else { return }
        // Already looking at that window: its answers are on screen.
        if sceneActive, watcher.isOpen, watcher.target == attention.ref, !watcher.phase.isPaused { return }
        AgentAlerts.shared.post(attention)
        log.add("attention: \(attention.appName) is asking")
    }

    // MARK: Reader, the clipboard, photos and files (Oct 18 2026)

    var canRead: Bool { client.canRead }
    var canShareClipboard: Bool { client.canShareClipboard }
    var canAttach: Bool { client.canAttach }

    /// Ask the Mac for the watched window's words (Reader asks every few seconds while it shows).
    func requestReader() { client.requestReader() }
    func clearReader() { readerPage = nil }

    /// While Reader shows: the words now, then every 2.5 seconds (the Mac reads only on asking).
    private func readerFollows(_ on: Bool) {
        readerTask?.cancel()
        readerTask = nil
        readerPage = nil
        guard on else { return }
        readerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            while !Task.isCancelled {
                guard let self else { return }
                if self.watcher.phase == .live { self.client.requestReader() }
                try? await Task.sleep(nanoseconds: 2_500_000_000)
            }
        }
    }

    func linkClient(_ client: LinkClient, reader: ReaderPage) {
        guard client === self.client, watcher.isOpen else { return }
        if readerPage != reader { readerPage = reader }
    }

    /// The Mac's clipboard onto this iPhone's.
    func copyMacClipboard() {
        guard client.requestClipboard() else { explain("Update Macrophone on your Mac to share its clipboard"); return }
        Haptics.tick()
        explain("Asking your Mac for its clipboard…")
    }

    /// This iPhone's clipboard onto the Mac's (iOS asks first, the first time).
    func sendClipboardToMac() {
        let pb = UIPasteboard.general
        var item = ClipboardItem()
        if pb.hasStrings, let s = pb.string { item.text = s }
        else if pb.hasImages, let img = pb.image { item.image = Self.jpeg(img, maxBytes: ClipboardItem.maxImage) }
        guard !item.isEmpty else { explain("Your iPhone's clipboard is empty"); return }
        guard client.sendClipboard(item) else {
            explain(item.text.map { $0.utf8.count > ClipboardItem.maxText } == true ? "That's too long to send" : "Update Macrophone on your Mac to share the clipboard")
            return
        }
        Haptics.tick()
        log.add("clipboard: sent the phone's")
    }

    func linkClient(_ client: LinkClient, clipboard: ClipboardItem?, detail: String) {
        guard client === self.client else { return }
        if let clipboard {
            if let t = clipboard.text { UIPasteboard.general.string = t }
            else if let d = clipboard.image, let img = UIImage(data: d) { UIPasteboard.general.image = img }
            Haptics.success()
            log.add("clipboard: the Mac's is on the phone")
        }
        explain(detail)
    }

    /// A photo into the chat you send to (or the window you watch): at most 2,400 pixels across.
    func sendPhoto(_ image: UIImage) {
        guard let data = Self.jpeg(image, maxBytes: 8_000_000, side: 2400) else { explain("Couldn't read that photo"); return }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        sendAttachment(data, filename: "Photo \(f.string(from: Date())).jpg", kind: "image")
    }

    func sendFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { explain("Couldn't read that file"); return }
        let image = ["png", "jpg", "jpeg", "heic", "gif", "webp", "tiff"].contains(url.pathExtension.lowercased())
        sendAttachment(data, filename: url.lastPathComponent, kind: image ? "image" : "file")
    }

    private func sendAttachment(_ data: Data, filename: String, kind: String) {
        guard data.count <= AttachmentChunk.chunkSize * AttachmentChunk.maxChunks else { explain("That's over 20 MB — too big to send"); return }
        let target = watcher.isOpen ? (watcher.target ?? selection.target) : selection.target
        guard client.sendAttachment(data, filename: filename, kind: kind, target: target) != nil else {
            explain(isConnected ? "Update Macrophone on your Mac to send photos and files" : "Your Mac isn't connected")
            return
        }
        Haptics.tick()
        let what = kind == "image" ? "the photo" : "the file"
        sendingAttachment = "Sending \(what) to \(Places.appName(target, in: self))…"
        explain(sendingAttachment ?? "", for: 30)
        log.add("attachment: sending (\(kind))")
    }

    func linkClient(_ client: LinkClient, attachmentLanded id: UUID, ok: Bool, detail: String) {
        guard client === self.client else { return }
        sendingAttachment = nil
        if ok { Haptics.success() } else { Haptics.error() }
        explain(detail, for: 4)
    }

    /// JPEG at most `maxBytes`, the long side at most `side` pixels.
    static func jpeg(_ image: UIImage, maxBytes: Int, side: CGFloat = 2400) -> Data? {
        let long = max(image.size.width, image.size.height) * image.scale
        let k = min(1, side / max(long, 1))
        let size = CGSize(width: image.size.width * image.scale * k, height: image.size.height * image.scale * k)
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1
        let scaled = UIGraphicsImageRenderer(size: size, format: fmt).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        for q in [0.85, 0.7, 0.5] as [CGFloat] {
            if let d = scaled.jpegData(compressionQuality: q), d.count <= maxBytes { return d }
        }
        return nil
    }

    func linkClient(_ client: LinkClient, needsYou: [NeedsYou]) {
        guard client === self.client else { return }
        if self.needsYou != needsYou { self.needsYou = needsYou; publishWidget() }
    }

    /// The mark for one window or app, if it answered you.
    func needs(_ t: LiveTarget) -> NeedsYou? { needsYou.first { $0.concerns(t) } }

    /// The mark for an app's button: any of its windows that answered you.
    func needs(_ place: PlaceOption) -> NeedsYou? {
        needsYou.first { n in place.windows.contains { n.concerns($0) } }
    }

    /// Looking at it settles it (the Mac agrees within seconds).
    func clearNeeds(for ref: TargetRef) {
        guard case let .app(bid, key, _) = ref else { return }
        needsYou.removeAll { $0.bundleID == bid && (key == nil || $0.windowKey == key) }
        publishWidget()
    }

    /// Alerts through iCloud are set up: say so in the next hello (the Mac then keeps looking
    /// while this app is closed).
    func alertsReadyInCloud() {
        guard !client.features.contains(Attention.cloudFeature) else { return }
        client.features.append(Attention.cloudFeature)
    }

    /// A tapped alert: watch that window (and send there), where its answers wait.
    func openAttention(_ ref: TargetRef) {
        if case .app = ref, ref != settings.selection.target { pick(ref) }
        watcher.open(ref)
    }

    func linkClient(_ client: LinkClient, localNetworkDenied: Bool) {
        guard client === self.client else { return }
        self.localNetworkDenied = localNetworkDenied
    }

    func linkClient(_ client: LinkClient, remoteAddresses: [RemoteAddress], macID: UUID) {
        guard client === self.client else { return }
        self.remoteAddresses = client.remoteAddresses
        pairedMac = client.activeMac
    }

    func linkClient(_ client: LinkClient, pathChanged remote: Bool) {
        guard client === self.client else { return }
        isRemote = remote
        linkRoute = client.route
        log.add("link now \(client.route?.rawValue ?? "unknown")")
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
    @MainActor static func startRecording(targetID: String?, name: String?) async {
        await AppModel.shared.startFromIntent(targetID: targetID, name: name)
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
