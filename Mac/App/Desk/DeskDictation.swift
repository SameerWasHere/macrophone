import AppKit
import AVFoundation
import Combine
import Foundation
import MacrophoneKit

/// Dictation at the desk (Nov 7 2026, Sameer: "hold a key on the Mac, talk, and the same cleanup
/// pastes wherever you're typing"). No phone: hold the key (🌐 by default), talk, let go — the
/// words go through this Mac's own cleanup level and are pasted where the cursor is (Paster's
/// `.front`, never sent). Two taps keep it listening hands-free until the key is tapped again;
/// Esc cancels. The listening pill (ListeningPill) shows the words as they come. History keeps it
/// like a phone's dictation, from "This Mac". Diagnostics carry numbers only.
@MainActor
final class DeskDictation: ObservableObject {
    enum Phase: Equatable {
        case idle
        case listening(handsFree: Bool)
        /// Let go: the last words settling, cleanup, the paste.
        case finishing(String)
        /// A moment's word on the pill ("Didn't catch that", "Copied — nowhere to type").
        case note(String)
    }

    /// The source a desk dictation carries in History.
    static let source = "This Mac"

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var settled = ""
    @Published private(set) var pending = ""
    @Published private(set) var level: Float = 0
    /// macOS refused the key tap: Input Monitoring is needed too.
    @Published private(set) var tapRefused = false
    /// What macOS itself does with 🌐 (the page warns when it fires alongside a hold).
    @Published private(set) var fnUsage: FnKeyUsage = .doNothing
    /// The page's "Try it" box: while it has the keyboard and Macrophone is in front, the words
    /// go there (Macrophone never pastes into itself).
    @Published var tryText = ""
    var tryBoxFocused = false

    private unowned let app: AppModel
    private let mic = DeskMic()
    private let tap = DeskKeyTap()
    private lazy var pill = ListeningPill(desk: self)
    private var session: Session?
    private var levelTimer: Timer?
    private var noteTask: Task<Void, Never>?
    private var pasteChain: Task<Void, Never>?
    private var bag = Set<AnyCancellable>()

    private final class Session {
        let id = UUID()
        let pressedAt = Date()
        var speech: AnyObject?
        var starting: Task<AnyObject?, Never>?
        var cancelled = false
    }
    /// The dictation whose words and state the pill shows (through its paste).
    private var liveID: UUID?
    /// The microphone hasn't been asked about: a hold let go asks.
    private var askOnRelease = false

    init(app: AppModel) {
        self.app = app
        tap.onEffect = { [weak self] in self?.effect($0) }
    }

    private var settings: Settings { app.settings }
    private var log: DiagnosticLog { app.log }

    /// The Mac's language, as speech wants it ("en-US").
    static var language: String { Locale.current.identifier(.bcp47) }

    /// Whether this macOS has the speech engine at all.
    static var engineAvailable: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    /// "Hold 🌐 to dictate" — for the menu, nil when off.
    var hint: String? {
        guard settings.deskDictation, settings.deskKey != .off, tap.isRunning else { return nil }
        return "Hold \(settings.deskKey.short) to dictate"
    }

    var isListening: Bool { if case .listening = phase { return true }; return false }

    /// The key in a sentence ("🌐", "right ⌥").
    var keyShort: String { settings.deskKey.short }

    // MARK: On and off

    func start() {
        readFnUsage()
        #if DEBUG
        // A debug test copy never listens for the key unless asked: it would dictate beside the
        // real app (and ask for the microphone) whenever the person at this Mac holds 🌐.
        if AppPaths.instance != nil, ProcessInfo.processInfo.environment["MACROPHONE_DESK_LIVE"] != "1" {
            log.add("desk: key not listened for in a test copy (MACROPHONE_DESK_LIVE=1 to)")
            return
        }
        #endif
        Publishers.CombineLatest3(settings.$deskDictation, settings.$deskKey, app.permissions.$microphone)
            .combineLatest(app.permissions.$accessibility, app.permissions.$inputMonitoring)
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.apply() }
            .store(in: &bag)
        settings.$deskCleanup.dropFirst().sink { [weak self] level in
            self?.log.add("desk: cleanup \(level.rawValue)")
        }.store(in: &bag)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.readFnUsage() }
            .store(in: &bag)
    }

    /// The tap runs while it's on, a key is picked and the microphone isn't refused. Not yet
    /// asked counts as allowed here: the first real hold asks (a quick tap never does).
    private func apply() {
        let s = settings
        let mic = app.permissions.microphone
        let wanted = s.deskDictation && s.deskKey != .off && Self.engineAvailable && mic != .denied && mic != .restricted
        guard wanted else {
            if tap.isRunning { tap.stop(); log.add("desk: key off") }
            if isListening { cancel(quietly: true) }
            tapRefused = false
            return
        }
        let wasRunning = tap.isRunning
        let ok = tap.start(s.deskKey)
        tapRefused = !ok
        if ok, !wasRunning { log.add("desk: listening for \(s.deskKey.rawValue)") }
        if !ok { log.add("desk: key tap refused (Accessibility \(app.permissions.accessibility ? "on" : "off"), Input Monitoring \(app.permissions.inputMonitoring ? "on" : "off"))") }
        if ok, mic == .authorized { warm() }
    }

    func readFnUsage() {
        let v = CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, "com.apple.HIToolbox" as CFString) as? Int
        let usage = v.flatMap(FnKeyUsage.init(rawValue:)) ?? .doNothing
        if usage != fnUsage { fnUsage = usage }
    }

    static let keyboardSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!

    /// The next dictation's analyzer, made now so the press only starts the stream.
    private func warm() {
        guard #available(macOS 26.0, *) else { return }
        let language = Self.language
        Task.detached(priority: .utility) { await DeskSpeech.warm(language: language) }
    }

    // MARK: The key

    private func effect(_ e: DeskHotkey.Effect) {
        switch e {
        case .openMic: openMic()
        case .showPill: showPill(handsFree: false)
        case .handsFree: showPill(handsFree: true)
        case .finish: finish()
        case .cancel(let quiet): cancel(quietly: quiet)
        }
    }

    /// The press: only the mic opens (what it hears is held). The recognizer joins once it's a
    /// hold (`startSpeech`), so a quick tap or a shortcut never spends the analyzer made ahead.
    private func openMic() {
        guard DeskMic.authorization == .authorized, Self.engineAvailable else { return }
        noteTask?.cancel()
        let s = Session()
        session = s
        liveID = s.id
        settled = ""
        pending = ""
        let pressed = s.pressedAt
        let log = self.log
        mic.open { ms in
            if let ms { log.add("desk: mic open \(Int(Date().timeIntervalSince(pressed) * 1000)) ms after the press (engine \(ms) ms)") }
            else { log.add("desk: the mic didn't open") }
        }
        startLevel()
    }

    /// The recognizer for this dictation, on the analyzer made ahead; the held audio goes in first.
    private func startSpeech(_ s: Session) {
        guard s.starting == nil, #available(macOS 26.0, *) else { return }
        let language = Self.language
        let id = s.id
        let pressed = s.pressedAt
        s.starting = Task { [weak self] in
            let r = await DeskSpeech.start(language: language) { settled, pending in
                Task { @MainActor [weak self] in
                    guard let self, self.liveID == id else { return }
                    self.settled = settled
                    self.pending = pending
                }
            }
            guard let self else { r?.0.cancel(); return nil }
            guard let (speech, warm) = r else {
                self.log.add("desk: speech engine didn't start")
                return nil
            }
            guard !s.cancelled else { speech.cancel(); return nil }
            let held = self.mic.heldSeconds
            self.mic.attach(speech.sink.feed)
            s.speech = speech
            self.log.add("desk: SpeechAnalyzer \(warm ? "made ahead" : "made now"), listening \(Int(Date().timeIntervalSince(pressed) * 1000)) ms after the press, \(String(format: "%.2f", held)) s held for it")
            return speech
        }
        let level = settings.deskCleanup
        if level != .off, Cleaner.availability(language: language).isAvailable { Cleaner.prewarm(level: level, dictionary: []) }
    }

    private func showPill(handsFree: Bool) {
        let auth = DeskMic.authorization
        guard auth == .authorized else {
            if auth == .notDetermined {
                // Asked when this hold is let go past a tap — a 🌐 tap for emoji never asks.
                askOnRelease = true
            } else {
                tap.reset()
                note("The microphone is off for Macrophone")
            }
            return
        }
        guard let s = session else {
            tap.reset()
            note("Dictation needs macOS 26 or later")
            return
        }
        startSpeech(s)
        phase = .listening(handsFree: handsFree)
        pill.show()
    }

    func cancel(quietly: Bool) {
        askOnRelease = false
        guard let s = session else {
            if isListening { phase = .idle; pill.hide() }
            return
        }
        session = nil
        s.cancelled = true
        liveID = nil
        stopLevel()
        mic.close()
        if #available(macOS 26.0, *) {
            if let sp = s.speech as? DeskSpeech { sp.cancel() }
            else if let starting = s.starting { Task { (await starting.value as? DeskSpeech)?.cancel() } }
        }
        if !quietly { log.add("desk: cancelled") }
        if isListening {
            settled = ""
            pending = ""
            phase = .idle
            pill.hide()
        }
        if s.starting != nil { warm() }
    }

    private func finish() {
        if askOnRelease, session == nil {
            askOnRelease = false
            log.add("desk: asking for the microphone")
            note("Allow the microphone, then hold \(settings.deskKey.short) again")
            Task { @MainActor in
                _ = await DeskMic.requestAccess()
                self.app.permissions.refresh()
            }
            return
        }
        guard let s = session, #available(macOS 26.0, *) else { cancel(quietly: true); return }
        session = nil
        stopLevel()
        let heldFor = Date().timeIntervalSince(s.pressedAt)
        phase = .finishing("")
        pill.show()
        // A release the tick never saw as a hold: the recognizer starts now, on the held audio.
        startSpeech(s)
        mic.close(keepHeld: true)
        let level = settings.deskCleanup
        let language = Self.language
        Task { @MainActor in
            let t0 = Date()
            var speech = s.speech as? DeskSpeech
            if speech == nil { speech = await s.starting?.value as? DeskSpeech }
            guard let speech else {
                self.note("Speech isn't ready on this Mac yet", for: s.id)
                self.warm()
                return
            }
            let raw = await speech.finish(timeout: 1.5).trimmingCharacters(in: .whitespacesAndNewlines)
            let words = raw.split(whereSeparator: \.isWhitespace).count
            self.log.add("desk: \(words) words in \(String(format: "%.1f", heldFor)) s, settled in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
            self.warm()
            guard !raw.isEmpty else { self.note("Didn't catch that", for: s.id); return }
            if self.liveID == s.id {
                self.settled = raw
                self.pending = ""
            }
            let cleaned = await self.clean(raw, level: level, language: language, id: s.id)
            self.deliver(raw: raw, cleaned: cleaned, level: level, language: language, id: s.id, duration: heldFor)
        }
    }

    /// The pill's status line for this dictation, while it's still the one on the pill.
    private func status(_ words: String, for id: UUID) {
        guard liveID == id, session == nil else { return }
        phase = .finishing(words)
    }

    /// This Mac's cleanup level, with a budget (a long dictation's tail goes as spoken).
    private func clean(_ raw: String, level: CleanupLevel, language: String, id: UUID) async -> String? {
        guard level != .off else { return nil }
        guard Cleaner.availability(language: language).isAvailable else {
            log.add("desk: cleanup unavailable")
            return nil
        }
        status("Cleaning up…", for: id)
        let t0 = Date()
        let r = await Cleaner.clean(raw, level: level, dictionary: [], language: language, deadline: Date().addingTimeInterval(8))
        log.add("desk: cleanup \(Int(Date().timeIntervalSince(t0) * 1000)) ms (\(level.rawValue)\(r.skipped.map { ", \($0)" } ?? ""))")
        return r.cleaned
    }

    // MARK: The paste

    private func deliver(raw: String, cleaned: String?, level: CleanupLevel, language: String, id: UUID, duration: TimeInterval) {
        let d = Dictation(id: id, raw: raw, cleaned: cleaned, cleanupLevel: level, language: language,
                          profileName: TargetRef.frontApp.displayName, target: .frontApp, send: false,
                          duration: duration, sourceDevice: Self.source)
        let text = d.text
        #if DEBUG
        if let dryRun { dryRun(raw, cleaned); done(for: id); return }
        #endif
        // The page's Try it box, with Macrophone in front: straight into it.
        if tryBoxFocused, NSApp.isActive {
            tryText += (tryText.isEmpty || tryText.hasSuffix(" ") || tryText.hasSuffix("\n") ? "" : " ") + text
            app.record(HistoryItem(dictation: d, receivedAt: Date(), delayed: false, profileName: "Try it", outcome: .pasted, detail: "Typed into Try it"))
            log.add("desk: into Try it")
            done(for: id)
            return
        }
        app.record(HistoryItem(dictation: d, receivedAt: Date(), delayed: false, profileName: TargetRef.frontApp.displayName, outcome: .pending, detail: ""))
        app.statusItemCue(.arriving(id))
        status("Pasting…", for: id)
        let previous = pasteChain
        let scanner = app.scanner
        pasteChain = Task { @MainActor in
            await previous?.value
            if StayAwake.isLocked { self.failed(.macLocked, text: text, id: id); return }
            do {
                let r = try await Paster.deliver(Paster.Request(text: text, target: .front, send: false), scanner: scanner)
                self.app.updateOutcome(id, .pasted, "Pasted into \(r.appName)")
                self.app.statusItemCue(.landed(id))
                self.log.add("desk: pasted\(r.landed == true ? ", landed" : (r.landed == nil ? ", not readable" : ""))")
                self.done(for: id)
            } catch let f as PasteFailure {
                self.failed(f, text: text, id: id)
            } catch {
                self.app.statusItemCue(.settled(id))
                self.done(for: id)
            }
        }
    }

    private func failed(_ f: PasteFailure, text: String, id: UUID) {
        Paster.copy(text)
        app.updateOutcome(id, f.copiedInstead ? .copied : .failed, f.title)
        app.statusItemCue(.failed(id))
        log.add("desk: paste failed: \(String(describing: f).prefix(40))")
        note(Self.shortWords(f), for: id)
    }

    /// The pill's few words for a paste that didn't happen (the text is on the clipboard).
    static func shortWords(_ f: PasteFailure) -> String {
        switch f {
        case .accessibilityMissing: return "Copied — Macrophone needs Accessibility to paste"
        case .secureField: return "Not pasted into a password field — copied"
        case .nowhereToType: return "Copied — nowhere to type here. Press ⌘V"
        case .macLocked: return "Copied — your Mac is locked"
        default: return "Copied — press ⌘V where you want it"
        }
    }

    /// This dictation is over: the pill goes — unless another one has the pill by now.
    private func done(for id: UUID?) {
        guard id == nil || liveID == id else { return }
        liveID = nil
        settled = ""
        pending = ""
        phase = .idle
        pill.hide()
    }

    /// A moment's word on the pill. For a dictation (`id`), only while it still has the pill;
    /// without one, only while nothing is listening.
    private func note(_ words: String, for id: UUID? = nil) {
        if let id { guard liveID == id else { return } } else { guard session == nil else { return } }
        noteTask?.cancel()
        liveID = nil
        phase = .note(words)
        pill.show()
        noteTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard !Task.isCancelled, case .note = self.phase else { return }
            self.done(for: nil)
        }
    }

    // MARK: The level

    private func startLevel() {
        levelTimer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let v = self.mic.currentLevel
                if abs(v - self.level) > 0.01 { self.level = v }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        levelTimer = t
    }

    private func stopLevel() {
        levelTimer?.invalidate()
        levelTimer = nil
        level = 0
    }

    // MARK: Debug

    #if DEBUG
    /// Shows the pill as it looks mid-dictation (screenshots): the words, the level.
    func debugStage(_ words: String, handsFree: Bool = false, finishing: String? = nil) {
        settled = words
        pending = ""
        level = 0.55
        phase = finishing.map { .finishing($0) } ?? .listening(handsFree: handsFree)
        pill.show()
    }

    var debugPillWindow: Int? { pill.windowNumber }

    /// Set: a finished dictation goes here instead of History and the paste.
    var dryRun: ((_ raw: String, _ cleaned: String?) -> Void)?

    /// MACROPHONE_DESK_SIMULATE: the whole path — the key's presses through the state machine,
    /// the mic (an audio file in its place), held audio, the recognizer joining at the hold,
    /// cleanup — with the result handed to `dryRun`. `taps`: hands-free by a double tap.
    func debugSimulate(file: URL, hold: TimeInterval, handsFree: Bool) {
        DeskMic.debugFile = file
        let steps: [(TimeInterval, DeskHotkey.Event)] = handsFree
            ? [(0, .down), (0.08, .up), (0.2, .down), (0.3, .up), (hold, .down), (hold + 0.1, .up)]
            : [(0, .down), (hold, .up)]
        for (at, e) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + at) { self.tap.feed(e) }
        }
    }
    var debugPillFrame: NSRect? { pill.frame }
    #endif
}

/// One desk dictation from an audio file (DEBUG hook `MACROPHONE_DESK_AUDIO`): the same speech
/// and cleanup, the result printed instead of pasted.
@available(macOS 26.0, *)
enum DeskFileRun {
    static func run(path: String, level: CleanupLevel, language: String) async -> (raw: String, cleaned: String?, speechMs: Int, cleanupMs: Int)? {
        let url = URL(fileURLWithPath: path)
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let t0 = Date()
        guard let (speech, _) = await DeskSpeech.start(language: language, onText: { _, _ in }) else { return nil }
        // Fed as the mic would, in 1024-frame buffers.
        let format = file.processingFormat
        while file.framePosition < file.length {
            guard let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024) else { break }
            do { try file.read(into: b, frameCount: 1024) } catch { break }
            if b.frameLength == 0 { break }
            speech.sink.feed(b)
        }
        let raw = await speech.finish(timeout: 5).trimmingCharacters(in: .whitespacesAndNewlines)
        let speechMs = Int(Date().timeIntervalSince(t0) * 1000)
        let t1 = Date()
        var cleaned: String?
        if level != .off, Cleaner.availability(language: language).isAvailable, !raw.isEmpty {
            cleaned = await Cleaner.clean(raw, level: level, dictionary: [], language: language, deadline: Date().addingTimeInterval(8)).cleaned
        }
        return (raw, cleaned, speechMs, Int(Date().timeIntervalSince(t1) * 1000))
    }
}
