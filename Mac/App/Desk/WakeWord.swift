import AppKit
import AVFoundation
import Combine
import Foundation
import MacrophoneKit

/// The wake word (Nov 7 2026, moved from SameerOS's "Hey Claude" and made for everyone): say the
/// phrase ("Hey Mac" by default), talk, and the words land where you're typing — the same pill,
/// speech engine, cleanup level, paste and History as holding 🌐 (DeskDictation). Ending words
/// decide what happens ("send it" presses Return, "never mind" drops it) and an app named at the
/// end takes the words there ("… paste in Notes"). Off by default.
///
/// When it listens: switched on, the microphone allowed, the first-time sheet through, not paused
/// from the menu, the Mac unlocked and awake with its screen on, and no other app using a
/// microphone (a call). Paused, the microphone is let go — the orange dot goes. It listens on the
/// default input, or the Mac's own microphone when the default is Bluetooth (AirPods would drop to
/// call quality). The listening itself is MacrophoneKit's `WakeListener`; audio never leaves the
/// Mac, nothing is written to disk, and the log carries numbers only.
@MainActor
final class WakeController: ObservableObject {
    enum Pause: Equatable {
        case user(until: Date)
        case locked
        case asleep
        /// Another app is using a microphone (a call, a recording): its name.
        case micInUse(String)
        case desk
    }

    enum State: Equatable {
        case off
        case listening
        case paused(Pause)
        /// Can't listen: the reason, in a sentence.
        case unavailable(String)
    }

    @Published private(set) var state: State = .off
    /// What it listens with ("MacBook Pro Microphone").
    @Published private(set) var device = ""
    /// The Bluetooth input it stepped around ("AirPods Pro"), if any.
    @Published private(set) var avoided: String?
    /// SameerOS is open with its own "Hey Claude" listening on.
    @Published private(set) var sameerOSListening = false
    /// The first-time sheet is up.
    @Published var introShown = false
    /// The sheet's "Say it now": listening for the phrase only (nothing lands).
    @Published private(set) var testing = false
    @Published private(set) var testHeard = false

    private unowned let app: AppModel
    private var listener: AnyObject?
    private var locked = StayAwake.isLocked
    private var screensAsleep = false
    private var systemAsleep = false
    private var othersUsing: [String] = []
    private var audioWatch: WakeAudioWatch?
    private var resumeAfterCall: DispatchWorkItem?
    private var pauseTimer: Timer?
    private var bag = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []

    init(app: AppModel) { self.app = app }

    private var settings: Settings { app.settings }
    private var log: DiagnosticLog { app.log }

    static var engineAvailable: Bool { DeskDictation.engineAvailable }

    var isListening: Bool { state == .listening }
    var phrase: String { settings.wakePhrase }

    /// "Listening for “Hey Mac”", "Paused for 1 hour" — the menu's line and the page's.
    var statusLine: String? {
        switch state {
        case .off: return nil
        case .listening: return "Listening for “\(phrase)”"
        case .paused(let p):
            switch p {
            case .user(let until): return "Paused until \(Self.timeWords(until))"
            case .locked: return "Paused while your Mac is locked"
            case .asleep: return "Paused while the screen is off"
            case .micInUse(let app): return "Paused — \(app) is using the microphone"
            case .desk: return "Listening for “\(phrase)”"
            }
        case .unavailable(let why): return why
        }
    }

    var pausedByUser: Bool { if case .paused(.user) = state { return true }; return false }

    static func timeWords(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(d) ? "h:mm a" : "EEEE h:mm a"
        return f.string(from: d)
    }

    // MARK: Start

    func start() {
        importDictionaryOnce()
        #if DEBUG
        if AppPaths.instance != nil, ProcessInfo.processInfo.environment["MACROPHONE_WAKE_LIVE"] != "1",
           ProcessInfo.processInfo.environment["MACROPHONE_WAKE_AUDIO"] == nil {
            // A test copy never opens the microphone by itself (it would listen beside the real app).
            log.add("wake: not listening in a test copy (MACROPHONE_WAKE_LIVE=1 to)")
            readSameerOS()
            return
        }
        #endif
        Publishers.CombineLatest4(settings.$wakeOn, settings.$wakePhrase, settings.$wakeSensitivity, settings.$wakeEndSilence)
            .map { _ in () }
            .merge(with: settings.$wakeEndings.map { _ in () }, settings.$dictionary.map { _ in () },
                   settings.$wakePausedUntil.map { _ in () }, settings.$wakeIntroduced.map { _ in () },
                   app.permissions.$microphone.map { _ in () })
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] in self?.apply() }
            .store(in: &bag)
        watchSystem()
        readSameerOS()
    }

    /// What should be true now, made true.
    func apply() {
        readSameerOS()
        // The first-time sheet's Say it now runs the listener itself.
        guard !testing else { return }
        guard settings.wakeOn else { stopListening(); audioWatch?.stop(); audioWatch = nil; set(.off); return }
        guard Self.engineAvailable else { stopListening(); set(.unavailable("The wake word needs macOS 26 or later.")); return }
        if audioWatch == nil {
            audioWatch = WakeAudioDevices.watch { [weak self] in MainActor.assumeIsolated { self?.audioChanged() } }
            othersUsing = Self.othersNow()
        }
        let mic = app.permissions.microphone
        if mic == .denied || mic == .restricted {
            stopListening(); set(.unavailable("The microphone is off for Macrophone — allow it in System Settings."))
            return
        }
        guard settings.wakeIntroduced, mic == .authorized || testingFromFile else {
            stopListening(); set(.unavailable("Finish turning it on — Say it now."))
            return
        }
        pauseTimer?.invalidate()
        if let until = settings.wakePausedUntil {
            if until > Date() {
                stopListening(); set(.paused(.user(until: until)))
                let t = Timer(fire: until, interval: 0, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.settings.wakePausedUntil = nil }
                }
                RunLoop.main.add(t, forMode: .common)
                pauseTimer = t
                return
            }
            settings.wakePausedUntil = nil
        }
        if locked { stopListening(); set(.paused(.locked)); return }
        if screensAsleep || systemAsleep { stopListening(); set(.paused(.asleep)); return }
        if let other = othersUsing.first {
            stopListening(); set(.paused(.micInUse(Self.appName(other))))
            return
        }
        startListening()
    }

    private func set(_ s: State) {
        guard s != state else { return }
        let old = state
        state = s
        switch s {
        case .listening: log.add("wake: listening")
        case .paused(let p): log.add("wake: paused (\(Self.reason(p)))")
        case .unavailable: log.add("wake: unavailable")
        case .off: if old != .off { log.add("wake: off") }
        }
    }

    private static func reason(_ p: Pause) -> String {
        switch p {
        case .user: return "by you"
        case .locked: return "locked"
        case .asleep: return "screen off"
        case .micInUse: return "another app has the microphone"
        case .desk: return "desk key"
        }
    }

    // MARK: The listener

    @available(macOS 26.0, *)
    private var listenerSettings: WakeListener.Settings {
        var s = WakeListener.Settings()
        s.phrase = settings.wakePhrase
        s.sensitivity = settings.wakeSensitivity
        s.endings = settings.wakeEndings
        s.endSilence = settings.wakeEndSilence
        s.language = DeskDictation.language
        s.dictionary = settings.dictionary
        return s
    }

    private func makeListener() -> AnyObject? {
        guard #available(macOS 26.0, *) else { return nil }
        let source: WakeAudioSource
        #if DEBUG
        if let src = debugSource { source = src } else { source = micSource() }
        #else
        source = micSource()
        #endif
        let l = WakeListener(source: source)
        let log = self.log
        l.log = { log.add($0) }
        l.onEvent = { [weak self] e in self?.event(e) }
        l.onFailure = { [weak self] e in self?.failed(e) }
        return l
    }

    private func micSource() -> WakeMicSource {
        let m = WakeMicSource()
        let log = self.log
        m.log = { s in DispatchQueue.main.async { log.add(s) } }
        return m
    }

    private func startListening() {
        guard #available(macOS 26.0, *) else { return }
        if listener == nil { listener = makeListener() }
        guard let l = listener as? WakeListener else { return }
        if l.isRunning {
            l.update(listenerSettings)
            set(.listening)
            return
        }
        do {
            try l.start(listenerSettings)
            if let m = l.micSource {
                device = m.device?.name ?? ""
                avoided = m.avoided?.name
            }
            set(.listening)
        } catch let e as WakeAudioError {
            failed(e)
        } catch {
            set(.unavailable("The microphone didn't start."))
        }
    }

    private func failed(_ e: Error) {
        switch e as? WakeAudioError {
        case .onlyBluetooth(let name)?:
            set(.unavailable("Only \(name) can hear you — listening on it all day would switch it to call quality. Plug in or pick another microphone."))
        case .noMicrophone?:
            set(.unavailable("No microphone found."))
        default:
            set(.unavailable("The microphone didn't start."))
        }
    }

    private func stopListening() {
        guard #available(macOS 26.0, *), let l = listener as? WakeListener else { return }
        if l.isCapturing, let id = l.currentCaptureID { app.desk.wakeEnded(id, note: nil) }
        l.stop()
        Task.detached(priority: .utility) { await DeskWarmAnalyzer.wake.drop() }
    }

    var level: Float {
        guard #available(macOS 26.0, *), let l = listener as? WakeListener else { return 0 }
        return l.level
    }

    var isCapturing: Bool {
        guard #available(macOS 26.0, *), let l = listener as? WakeListener else { return false }
        return l.isCapturing
    }

    // MARK: What it hears

    @available(macOS 26.0, *)
    private func event(_ e: WakeListener.Event) {
        #if DEBUG
        if let debugEvent {
            switch e {
            case .woke: debugEvent("woke")
            case .words: break
            case .withdrawn: debugEvent("withdrawn")
            case .cancelled: debugEvent("cancelled")
            case .nothingSaid: debugEvent("nothing said")
            case .finished(_, _, let o, let s): debugEvent("finished · \(o.action.rawValue)\(o.place.map { " → \($0)" } ?? "") · \(String(format: "%.1f", s)) s")
            }
        }
        #endif
        if testing {
            if case .woke = e {
                testHeard = true
                Chime.wake(settings.wakeChimes)
                log.add("wake: heard in Say it now")
                (listener as? WakeListener)?.cancelCapture()
            }
            return
        }
        let desk = app.desk!
        switch e {
        case .woke(let id):
            Chime.wake(settings.wakeChimes)
            desk.wakeBegan(id)
        case .words(let id, let s, let p):
            desk.wakeWords(id, settled: s, pending: p)
        case .withdrawn(let id):
            desk.wakeEnded(id, note: nil)
        case .cancelled(let id):
            Chime.cancel(settings.wakeChimes)
            desk.wakeEnded(id, note: "Cancelled — nothing pasted")
        case .nothingSaid(let id):
            Chime.cancel(settings.wakeChimes)
            desk.wakeEnded(id, note: "Didn't catch that")
        case .finished(let id, _, let outcome, let seconds):
            land(id, outcome: outcome, seconds: seconds)
        }
    }

    private func land(_ id: UUID, outcome: WakeOutcome, seconds: TimeInterval) {
        log.add("wake: \(outcome.action.rawValue)\(outcome.place != nil ? " to a place" : "") · \(outcome.text.split(whereSeparator: \.isWhitespace).count) words in \(String(format: "%.1f", seconds)) s")
        guard outcome.action != .cancel else {
            Chime.cancel(settings.wakeChimes)
            app.desk.wakeEnded(id, note: "Cancelled — nothing pasted")
            return
        }
        guard !outcome.text.isEmpty else {
            Chime.cancel(settings.wakeChimes)
            app.desk.wakeEnded(id, note: "Didn't catch that")
            return
        }
        var target: Paster.Target = .front
        var missed: String?
        if let place = outcome.place {
            if let c = WakePlaces.match(place, in: placeCandidates()) {
                target = .app(bundleID: c.id, windowKey: nil, name: c.name)
            } else {
                missed = place
            }
        }
        let send = outcome.action == .send && missed == nil
        app.desk.wakeLand(id, text: outcome.text, target: target, send: send, missedPlace: missed, seconds: seconds) { [weak self] in
            guard let self else { return }
            Chime.landed(self.settings.wakeChimes)
        }
    }

    /// The open apps a place can name, newest first: Send to's list, then every other app with a
    /// window (bundle id → name).
    private func placeCandidates() -> [WakePlaceCandidate] {
        var seen = Set<String>()
        var out: [WakePlaceCandidate] = []
        for t in app.targets.sorted(by: { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) })
        where seen.insert(t.bundleID).inserted {
            out.append(WakePlaceCandidate(id: t.bundleID, name: t.appName))
        }
        for r in NSWorkspace.shared.runningApplications where r.activationPolicy == .regular {
            guard let bid = r.bundleIdentifier, bid != Bundle.main.bundleIdentifier, seen.insert(bid).inserted else { continue }
            out.append(WakePlaceCandidate(id: bid, name: r.localizedName ?? bid))
        }
        return out
    }

    // MARK: Esc and the desk key

    /// Esc while a capture runs: dropped. True = Esc was used.
    func escape() -> Bool {
        guard #available(macOS 26.0, *), let l = listener as? WakeListener, l.isCapturing else { return false }
        l.cancelCapture()
        return true
    }

    /// The desk key during a capture: held, let go, tapped.
    func keyHeld(_ held: Bool) {
        guard #available(macOS 26.0, *), let l = listener as? WakeListener else { return }
        l.setHeld(held)
    }

    func finishNow() {
        guard #available(macOS 26.0, *), let l = listener as? WakeListener else { return }
        l.finishCapture()
    }

    /// 🌐 is held for a desk dictation of its own: no scans meanwhile.
    func deskBegan() {
        guard #available(macOS 26.0, *), let l = listener as? WakeListener, l.isRunning else { return }
        l.suspend()
    }

    func deskEnded() {
        guard #available(macOS 26.0, *), let l = listener as? WakeListener, l.isRunning else { return }
        l.resume()
    }

    /// The tap should run for Esc whenever the wake word is on.
    var wantsKeys: Bool { settings.wakeOn }

    // MARK: Pause

    func pause(for seconds: TimeInterval) {
        settings.wakePausedUntil = Date().addingTimeInterval(seconds)
    }

    func pauseUntilTomorrow() {
        let cal = Calendar.current
        let morning = cal.date(bySettingHour: 8, minute: 0, second: 0, of: cal.date(byAdding: .day, value: 1, to: Date()) ?? Date()) ?? Date().addingTimeInterval(12 * 3600)
        settings.wakePausedUntil = morning
    }

    func resumeNow() { settings.wakePausedUntil = nil }

    // MARK: The first-time sheet

    /// Turning it on the first time opens the sheet; the switch only stays on once it's through.
    func turnOn() {
        if settings.wakeIntroduced {
            settings.wakeOn = true
        } else {
            introShown = true
        }
    }

    /// The sheet's Say it now: asks for the microphone if needed, then listens for the phrase.
    func beginTest() {
        #if DEBUG
        // A test copy never opens the real microphone (nor asks for it); a staged sheet keeps its look.
        if debugStaged { return }
        if AppPaths.instance != nil, ProcessInfo.processInfo.environment["MACROPHONE_WAKE_LIVE"] != "1", debugSource == nil {
            testing = true
            return
        }
        #endif
        testHeard = false
        Task { @MainActor in
            if DeskMic.authorization == .notDetermined {
                _ = await DeskMic.requestAccess()
                self.app.permissions.refresh()
            }
            guard DeskMic.authorization == .authorized || self.testingFromFile else { return }
            self.testing = true
            self.startTestListening()
        }
    }

    private func startTestListening() {
        guard #available(macOS 26.0, *) else { return }
        if listener == nil { listener = makeListener() }
        guard let l = listener as? WakeListener else { return }
        do {
            if !l.isRunning { try l.start(listenerSettings) } else { l.update(listenerSettings) }
        } catch {
            failed(error)
            testing = false
        }
    }

    func endTest(keep: Bool) {
        testing = false
        if keep {
            settings.wakeIntroduced = true
            settings.wakeOn = true
        } else if !settings.wakeOn {
            stopListening()
        }
        introShown = false
        apply()
    }

    // MARK: The Mac's own state

    private func watchSystem() {
        let ws = NSWorkspace.shared.notificationCenter
        let dnc = DistributedNotificationCenter.default()
        func on(_ c: NotificationCenter, _ name: Notification.Name, _ f: @escaping @MainActor (WakeController) -> Void) {
            observers.append(c.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { f(self); self.apply() } }
            })
        }
        on(dnc, Notification.Name("com.apple.screenIsLocked")) { $0.locked = true }
        on(dnc, Notification.Name("com.apple.screenIsUnlocked")) { $0.locked = false }
        on(ws, NSWorkspace.sessionDidResignActiveNotification) { $0.locked = true }
        on(ws, NSWorkspace.sessionDidBecomeActiveNotification) { $0.locked = StayAwake.isLocked }
        on(ws, NSWorkspace.screensDidSleepNotification) { $0.screensAsleep = true }
        on(ws, NSWorkspace.screensDidWakeNotification) { $0.screensAsleep = false }
        on(ws, NSWorkspace.willSleepNotification) { $0.systemAsleep = true }
        on(ws, NSWorkspace.didWakeNotification) { $0.systemAsleep = false; $0.locked = StayAwake.isLocked }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.readSameerOS() }
        })
    }

    /// Another app started or stopped using a microphone, or the default input changed. A call
    /// pauses at once; the end of one resumes two seconds later (a call app reopens its mic as it
    /// switches devices).
    private func audioChanged() {
        // The input it should be on changed (AirPods came or went, a USB mic was plugged in):
        // follow it without a restart of the app — a capture going on is let finish first.
        if #available(macOS 26.0, *), isListening, let l = listener as? WakeListener, !l.isCapturing,
           let mic = l.micSource, case .success(let pick) = WakeAudioDevices.pick(), pick.0.id != mic.device?.id {
            log.add("wake: the input changed — following it")
            l.stop()
            startListening()
        }
        let now = Self.othersNow()
        guard now != othersUsing else { return }
        resumeAfterCall?.cancel()
        if !now.isEmpty {
            if othersUsing.isEmpty { log.add("wake: another app is using the microphone (\(now.joined(separator: ", ")))") }
            othersUsing = now
            apply()
        } else {
            let w = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.othersUsing = Self.othersNow()
                self.apply()
            }
            resumeAfterCall = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: w)
        }
    }

    /// SameerOS's own listener uses the mic all day: not a call.
    private static let alwaysOn: Set<String> = ["com.sameer.sameeros-mac"]

    private static func othersNow() -> [String] {
        WakeAudioDevices.othersUsingInput(ignoring: alwaysOn)
    }

    private static func appName(_ bundleID: String) -> String {
        if let r = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first, let n = r.localizedName { return n }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return "Another app"
    }

    // MARK: SameerOS

    /// SameerOS (Sameer's retiring app) is open and listening for "Hey Claude" itself: the page
    /// says so in one line. Its settings are only read, never changed.
    func readSameerOS() {
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.sameer.sameeros-mac").isEmpty
        let on = running && (CFPreferencesCopyAppValue("listeningEnabled" as CFString, "com.sameer.sameeros-mac" as CFString) as? Bool ?? false)
        if on != sameerOSListening { sameerOSListening = on }
    }

    // MARK: The Dictionary

    static let sameerOSVocabulary = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/sameeros/vocabulary.txt")

    /// Once: SameerOS's vocabulary file, if it's there, joins the Dictionary.
    private func importDictionaryOnce() {
        guard !settings.dictionaryImportTried else { return }
        settings.dictionaryImportTried = true
        guard let text = try? String(contentsOf: Self.sameerOSVocabulary, encoding: .utf8) else { return }
        let terms = DictionaryImport.parse(text)
        guard !terms.isEmpty else { return }
        settings.dictionary = DictionaryImport.merge(settings.dictionary, terms)
        log.add("dictionary: \(terms.count) words from SameerOS")
    }

    // MARK: Debug

    private var testingFromFile: Bool {
        #if DEBUG
        return debugSource != nil
        #else
        return false
        #endif
    }

    #if DEBUG
    /// MACROPHONE_WAKE_AUDIO: files in place of the microphone.
    var debugSource: WakeAudioSource?
    var debugEvent: ((String) -> Void)?
    func debugState(_ s: State) { state = s }
    func debugAvoid(device: String, avoided: String) { self.device = device; self.avoided = avoided }
    func debugSameerOS() { sameerOSListening = true }
    private var debugStaged = false
    func debugTest(heard: Bool) { debugStaged = true; testing = true; testHeard = heard; introShown = true }
    #endif
}
