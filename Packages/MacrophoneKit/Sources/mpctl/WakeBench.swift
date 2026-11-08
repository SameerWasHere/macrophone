import AVFoundation
import Darwin
import Foundation
import MacrophoneKit

// The wake word's test set and bench (Nov 7 2026).
//   mpctl wake-testset <dir>                  # `say` voices: the phrase alone, inside sentences, with
//                                             # endings and places, near-misses ("hey max"), talk without
//                                             # it, singing and music, speech over music — manifest.json + WAVs
//   mpctl wake-bench <dir> [--phrase "Hey Mac"] [--sensitivity normal] [--speed 1] [--no-classifier]
//                    [--only kind,kind] [--voices N]  # every clip through the real WakeListener; what woke,
//                                             # what it heard, CPU and memory; nothing pastes
//   mpctl wake-soak [--minutes 30] [--set <dir>] [--noise -62] [--no-classifier]
//                                             # room tone (and the set's clips now and then) for a long time:
//                                             # CPU per minute and memory, flat or not
// Audio stays on this Mac; the bench prints counts and the words it heard after the phrase (they're
// the test set's own sentences).

struct WakeClip: Codable {
    var file: String
    var kind: String
    var voice: String
    var text: String
    /// The phrase it contains, if any.
    var phrase: String?
    var command: String?
    var action: String?
    var place: String?
}

enum WakeBench {
    // MARK: The test set

    static let voices = ["Samantha", "Daniel", "Karen", "Moira", "Rishi", "Fred", "Reed (English (US))",
                         "Flo (English (US))", "Tara", "Eddy (English (US))"]

    struct Line { var kind: String; var text: String; var phrase: String?; var command: String?; var action: String?; var place: String?; var music: Bool = false }

    static func lines() -> [Line] {
        var l: [Line] = []
        func pos(_ p: String, _ t: String, _ c: String, _ a: String = "paste", _ place: String? = nil, music: Bool = false) {
            l.append(Line(kind: music ? "positive+music" : "positive", text: t, phrase: p, command: c, action: a, place: place, music: music))
        }
        // Hey Mac: the phrase, endings, places, mid-sentence, a pause after it.
        pos("Hey Mac", "Hey Mac, write a note to buy milk.", "Write a note to buy milk")
        pos("Hey Mac", "Hey Mac, run the tests and tell me what broke, send it.", "Run the tests and tell me what broke", "send")
        pos("Hey Mac", "Hey Mac, add eggs to the shopping list, paste it in Notes.", "Add eggs to the shopping list", "paste", "Notes")
        pos("Hey Mac", "Hey Mac, summarize this thread in three bullets, send to Claude.", "Summarize this thread in three bullets", "send", "Claude")
        pos("Hey Mac", "Hey Mac, never mind.", "", "cancel")
        pos("Hey Mac", "Okay so, hey Mac, remind me to call mom at five.", "Remind me to call mom at five")
        pos("Hey Mac", "Hey Mac. [[slnc 1400]] Open the quarterly report and fix the totals.", "Open the quarterly report and fix the totals")
        return l
    }

    static let nearMisses = [
        "Hey Max, are you coming tonight?", "Hey man, how is it going?", "Hey Mike, pass me that cable.",
        "Hey Mark, did you see the game last night?", "Hey Matt, the build is green again.",
        "I bought a new Mac yesterday and it is really fast.", "Mac, Windows and Linux are all supported.",
        "My Mac keeps waking up in the middle of the night.",
    ]

    static let talk = [
        "Welcome back to the show. Today we're talking about laptops, and whether the new Mac lineup is worth the upgrade for people who mostly write and browse. The short answer is probably not, unless your machine is five years old.",
        "So I asked Claude to help me plan the trip, and honestly it did a better job than I expected. It found the train times, it suggested a hotel near the station, and it even reminded me about the museum closing early on Mondays.",
        "The meeting is moved to Thursday at three. Please bring the draft budget, the slides from last quarter, and any questions about the hiring plan. If you can't make it, send your notes to the team before noon.",
        "In other news, the city council approved the new bike lanes downtown. Construction starts next month and should take about six weeks. Drivers are asked to use the side streets while the work is going on.",
        "Okay, so first preheat the oven to two hundred degrees. Then mix the flour, the butter and a pinch of salt until it looks like breadcrumbs. Add a little cold water, bring it together, and let it rest in the fridge.",
        "My computer has been slow all week. I think it's the new update, or maybe it's just too many browser tabs. Either way, I'm going to restart it tonight and see if that helps before I call support.",
    ]

    /// Original words to sing (no song's lyrics).
    static let songs = [
        "Sing along with the morning light, hey hey, all through the night, we are rolling down the road tonight.",
        "Oh the river runs and the river bends, la la la, until the summer ends.",
        "Hey there, hey there, dancing in the rain, hey there, hey there, here we go again.",
        "Make a little noise, make a little sound, spin the record round and round.",
    ]
    static let singers = ["Cellos", "Organ", "Bells", "Good News"]

    static let claude: [(String, String, String, String?)] = [
        ("Hey Claude, check my calendar for tomorrow.", "Check my calendar for tomorrow", "paste", nil),
        ("Hey Claude, draft a reply to Sam, send it.", "Draft a reply to Sam", "send", nil),
    ]
    static let claudeMisses = ["I asked Claude about it yesterday.", "Hey Clyde, wait up for me.", "Hey, cloud storage is almost full.", "A clod of dirt hit the window."]
    static let computer: [(String, String)] = [("Computer, what's on my schedule today?", "What's on my schedule today?")]
    static let computerMisses = ["My computer is slow today.", "Computers, phones and tablets are on sale.", "Okay computer is a great album."]

    static func generate(dir: String) async -> Int32 {
        let out = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var clips: [WakeClip] = []
        var n = 0
        func make(_ text: String, voice: String, kind: String, phrase: String? = nil, command: String? = nil,
                  action: String? = nil, place: String? = nil, music: Bool = false) {
            n += 1
            let name = String(format: "%03d-%@.wav", n, kind.replacingOccurrences(of: "+", with: "-"))
            if render(text: text, voice: voice, music: music, to: out.appendingPathComponent(name)) {
                clips.append(WakeClip(file: name, kind: kind, voice: voice,
                                      text: text.replacingOccurrences(of: "[[slnc 1400]] ", with: ""),
                                      phrase: phrase, command: command, action: action, place: place))
            } else {
                stdout("couldn't make \(name) (\(voice))")
            }
        }
        for v in voices {
            for line in lines() {
                make(line.text, voice: v, kind: line.kind, phrase: line.phrase, command: line.command, action: line.action, place: line.place)
            }
        }
        // The phrase over music (the first two lines), five voices.
        for v in voices.prefix(5) {
            for line in lines().prefix(2) {
                make(line.text, voice: v, kind: "positive+music", phrase: line.phrase, command: line.command, action: line.action, place: line.place, music: true)
            }
        }
        for (i, t) in nearMisses.enumerated() {
            for v in voices.prefix(5) { _ = i; make(t, voice: v, kind: "near-miss") }
        }
        for (i, t) in talk.enumerated() {
            for v in [voices[i % voices.count], voices[(i + 3) % voices.count], voices[(i + 6) % voices.count]] {
                make(t, voice: v, kind: "talk")
            }
            make(t, voice: voices[(i + 1) % voices.count], kind: "talk+music", music: true)
        }
        for (i, t) in songs.enumerated() { make(t, voice: singers[i % singers.count], kind: "singing") }
        for i in 0..<3 {
            n += 1
            let name = String(format: "%03d-music.wav", n)
            if writeMusic(seconds: 14, seed: i, to: out.appendingPathComponent(name)) {
                clips.append(WakeClip(file: name, kind: "music", voice: "-", text: "(music \(i + 1))"))
            }
        }
        for v in voices.prefix(5) {
            for (t, c, a, p) in claude { make(t, voice: v, kind: "positive-claude", phrase: "Hey Claude", command: c, action: a, place: p) }
            for (t, c) in computer { make(t, voice: v, kind: "positive-computer", phrase: "Computer", command: c, action: "paste") }
        }
        for t in claudeMisses { for v in voices.prefix(3) { make(t, voice: v, kind: "near-miss-claude") } }
        for t in computerMisses { for v in voices.prefix(3) { make(t, voice: v, kind: "near-miss-computer") } }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(clips).write(to: out.appendingPathComponent("manifest.json"))
        let seconds = clips.compactMap { try? AVAudioFile(forReading: out.appendingPathComponent($0.file)) }
            .reduce(0.0) { $0 + Double($1.length) / $1.processingFormat.sampleRate }
        stdout("TESTSET \(clips.count) clips, \(Int(seconds / 60)) min \(Int(seconds) % 60) s of audio in \(out.path)")
        return 0
    }

    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!

    /// `say` into a file, converted to 48 kHz mono, a little silence each side, music under it if asked.
    static func render(text: String, voice: String, music: Bool, to url: URL) -> Bool {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("wake-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-v", voice, "-o", tmp.path, text]
        do { try p.run(); p.waitUntilExit() } catch { return false }
        guard p.terminationStatus == 0, let speech = read(tmp) else { return false }
        let pad = Int(0.3 * format.sampleRate)
        var samples = [Float](repeating: 0, count: pad) + speech + [Float](repeating: 0, count: pad)
        if music {
            let bed = musicSamples(count: samples.count, seed: text.count)
            for i in samples.indices { samples[i] += bed[i] * 0.35 }
        }
        return write(samples, to: url)
    }

    static func read(_ url: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url),
              let conv = AVAudioConverter(from: file.processingFormat, to: format) else { return nil }
        var out: [Float] = []
        while true {
            guard let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else { return nil }
            var err: NSError?
            conv.convert(to: b, error: &err) { n, status in
                guard let inb = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: n),
                      (try? file.read(into: inb, frameCount: n)) != nil, inb.frameLength > 0 else { status.pointee = .endOfStream; return nil }
                status.pointee = .haveData
                return inb
            }
            guard b.frameLength > 0, let d = b.floatChannelData else { break }
            out.append(contentsOf: UnsafeBufferPointer(start: d[0], count: Int(b.frameLength)))
            if b.frameLength < 8192 { break }
        }
        return out
    }

    static func write(_ samples: [Float], to url: URL) -> Bool {
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
                                       AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false]
        guard let file = try? AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false),
              let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return false }
        b.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { b.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        return (try? file.write(from: b)) != nil
    }

    /// A little band: chords on soft saws, a bass, a kick and hats — music-like sound for the gate.
    static func musicSamples(count: Int, seed: Int) -> [Float] {
        let sr = 48_000.0
        let chords: [[Double]] = [[261.6, 329.6, 392.0], [220.0, 261.6, 329.6], [174.6, 220.0, 261.6], [196.0, 246.9, 293.7]]
        let shift = Double(seed % 5) * 0.06 + 1
        var out = [Float](repeating: 0, count: count)
        var rng = UInt32(truncatingIfNeeded: seed &* 2_654_435_761 &+ 1)
        for i in 0..<count {
            let t = Double(i) / sr
            let beat = t * 2.0   // 120 bpm
            let chord = chords[Int(beat / 4) % chords.count]
            var v = 0.0
            for f in chord { let ph = (t * f * shift).truncatingRemainder(dividingBy: 1); v += (2 * ph - 1) * 0.06 }
            let bass = sin(2 * .pi * chord[0] / 2 * shift * t) * 0.12
            let inBeat = beat.truncatingRemainder(dividingBy: 1)
            let kick = inBeat < 0.12 ? sin(2 * .pi * (60 + 80 * (0.12 - inBeat)) * t) * (0.12 - inBeat) * 3 : 0
            rng = rng &* 1_664_525 &+ 1_013_904_223
            let noise = Double(Int32(bitPattern: rng)) / Double(Int32.max)
            let hat = (beat * 2).truncatingRemainder(dividingBy: 1) < 0.05 ? noise * 0.08 : 0
            out[i] = Float((v + bass + kick + hat) * 0.8)
        }
        return out
    }

    static func writeMusic(seconds: Double, seed: Int, to url: URL) -> Bool {
        write(musicSamples(count: Int(seconds * 48_000), seed: seed * 7 + 3), to: url)
    }

    // MARK: Measuring

    static func cpuSeconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec) / 1e6 + Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec) / 1e6
    }

    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    /// CPU seconds so far of the system's speech and sound-analysis daemons (where the model may
    /// run out of process) — `ps`'s TIME, summed.
    static func daemonCPU() -> [String: Double] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-A", "-o", "time=,comm="]
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        var out: [String: Double] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = (String(parts[1]) as NSString).lastPathComponent
            let lower = name.lowercased()
            guard lower.contains("speech") || lower.contains("soundanaly") || lower.contains("corespeech")
                || lower.contains("asr") || lower.contains("dictation") || lower.contains("modelmanager") || lower.contains("mlmodel") else { continue }
            out[name, default: 0] += parseTime(String(parts[0]))
        }
        return out
    }

    static func parseTime(_ s: String) -> Double {
        // [[dd-]hh:]mm:ss.ss
        var rest = s
        var days = 0.0
        if let dash = rest.firstIndex(of: "-") { days = Double(rest[..<dash]) ?? 0; rest = String(rest[rest.index(after: dash)...]) }
        let parts = rest.split(separator: ":").map { Double($0) ?? 0 }
        var secs = 0.0
        for p in parts { secs = secs * 60 + p }
        return days * 86400 + secs
    }

    static func diff(_ a: [String: Double], _ b: [String: Double]) -> [(String, Double)] {
        b.map { ($0.key, $0.value - (a[$0.key] ?? 0)) }.filter { $0.1 > 0.05 }.sorted { $0.1 > $1.1 }
    }

    // MARK: The bench

    /// Lets the main run loop turn (timers, the main queue) from the bench's loop.
    static func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(seconds))
    }

    @available(macOS 26.0, *)
    final class Box: @unchecked Sendable {
        var current = -1
        var ended = false
        var events: [(Int, WakeListener.Event)] = []
    }

    @MainActor
    @available(macOS 26.0, *)
    static func bench(dir: String) async -> Int32 {
        
        let root = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
        guard let data = try? Data(contentsOf: root.appendingPathComponent("manifest.json")),
              var clips = try? JSONDecoder().decode([WakeClip].self, from: data) else { stdout("no manifest.json in \(root.path) — run mpctl wake-testset first"); return 2 }
        if let only = flag("--only") {
            let kinds = Set(only.split(separator: ",").map(String.init))
            clips = clips.filter { kinds.contains($0.kind) }
        }
        if let v = flag("--voices").flatMap(Int.init) {
            let keep = Set(voices.prefix(v) + singers + ["-"])
            clips = clips.filter { keep.contains($0.voice) }
        }
        var settings = WakeListener.Settings()
        settings.phrase = flag("--phrase") ?? "Hey Mac"
        settings.sensitivity = flag("--sensitivity").flatMap(WakeSensitivity.init) ?? .normal
        settings.classifier = !has("--no-classifier")
        settings.endSilence = flag("--end").flatMap(Double.init) ?? 2.0
        let speed = flag("--speed").flatMap(Double.init) ?? 1
        let source = WakeFileSource(files: clips.map { root.appendingPathComponent($0.file) }, loop: false, gap: 3.5, speed: speed)
        let box = Box()
        source.onFile = { i, _ in DispatchQueue.main.async { box.current = i } }
        source.onEnd = { DispatchQueue.main.async { box.ended = true } }
        let listener = WakeListener(source: source)
        var woke: [UUID: Int] = [:]
        listener.onEvent = { e in
            switch e {
            case .woke(let id): woke[id] = box.current; box.events.append((box.current, e))
            case .words: break
            case .withdrawn(let id), .cancelled(let id), .nothingSaid(let id): box.events.append((woke[id] ?? box.current, e))
            case .finished(let id, _, _, _): box.events.append((woke[id] ?? box.current, e))
            }
        }
        if has("--verbose") { listener.log = { stdout("  · \($0)") } }
        let cpu0 = cpuSeconds(), wall0 = Date(), d0 = daemonCPU()
        do { try listener.start(settings) } catch { stdout("couldn't start: \(error)"); return 1 }
        stdout("BENCH \(clips.count) clips · “\(settings.phrase)” · \(settings.sensitivity.rawValue) · classifier \(settings.classifier ? "on" : "off") · speed \(speed)×")
        while !box.ended { pump(0.1) }
        let tail = Date().addingTimeInterval(4)
        while Date() < tail { pump(0.1) }
        let wall = Date().timeIntervalSince(wall0), cpu = cpuSeconds() - cpu0
        let daemons = diff(d0, daemonCPU())
        listener.stop()

        // Score each clip.
        struct Score { var n = 0, woke = 0, right = 0 }
        var byKind: [String: Score] = [:]
        var commandWords = 0, commandRight = 0, actionsRight = 0, actionsAll = 0, placesRight = 0, placesAll = 0
        var withdrawnCount = 0
        for (i, clip) in clips.enumerated() {
            let ev = box.events.filter { $0.0 == i }.map(\.1)
            let didWake = ev.contains { if case .woke = $0 { return true }; return false }
            let finished = ev.compactMap { e -> (String, WakeOutcome)? in if case .finished(_, let r, let o, _) = e { return (r, o) }; return nil }.first
            let withdrawn = ev.contains { if case .withdrawn = $0 { return true }; return false }
            if withdrawn { withdrawnCount += 1 }
            let expect = clip.phrase == settings.phrase
            // A wake that was withdrawn pasted nothing: it isn't a false trigger, nor a hit.
            let landed = didWake && (finished != nil || ev.contains { if case .nothingSaid = $0 { return true }; return false })
            var s = byKind[clip.kind] ?? Score()
            s.n += 1
            if landed { s.woke += 1 }
            if landed == expect { s.right += 1 }
            byKind[clip.kind] = s
            var line = "\(expect ? (landed ? "HIT " : "MISS") : (landed ? "FALSE" : "ok  "))  \(clip.file)  [\(clip.voice.prefix(8))] \(clip.text.prefix(70))"
            if let (raw, o) = finished {
                line += "\n        → \(o.action.rawValue)\(o.place.map { " → \($0)" } ?? ""): “\(o.text)”"
                _ = raw
                if expect, let want = clip.command {
                    let w = Set(words(want)), got = Set(words(o.text))
                    commandWords += max(1, w.count)
                    commandRight += w.intersection(got).count
                    actionsAll += 1
                    if o.action.rawValue == (clip.action ?? "paste") { actionsRight += 1 }
                    if clip.place != nil || o.place != nil {
                        placesAll += 1
                        if o.place?.lowercased().hasPrefix(clip.place?.lowercased() ?? "∅") == true { placesRight += 1 }
                    }
                }
            } else if withdrawn {
                line += "\n        → withdrawn (nothing pasted)"
            }
            if !has("--quiet") || landed != expect { stdout(line) }
        }
        stdout("")
        for (k, s) in byKind.sorted(by: { $0.key < $1.key }) {
            stdout(String(format: "%-20@ %3d clips  woke %3d  right %3d (%.0f%%)", k as NSString, s.n, s.woke, s.right, Double(s.right) / Double(max(1, s.n)) * 100))
        }
        let positives = clips.filter { $0.phrase == settings.phrase }.count
        let hits = byKind.filter { $0.key.hasPrefix("positive") }.reduce(0) { r, kv in r + (clips.contains { $0.kind == kv.key && $0.phrase == settings.phrase } ? kv.value.woke : 0) }
        let negatives = clips.count - positives
        let falseTriggers = clips.enumerated().filter { i, c in
            c.phrase != settings.phrase && box.events.contains { $0.0 == i && { if case .finished = $0.1 { return true }; if case .nothingSaid = $0.1 { return true }; return false }($0) }
        }.count
        let negativeMinutes = clips.filter { $0.phrase != settings.phrase }.compactMap { try? AVAudioFile(forReading: root.appendingPathComponent($0.file)) }
            .reduce(0.0) { $0 + Double($1.length) / $1.processingFormat.sampleRate } / 60
        stdout(String(format: "\nWAKE  hits %d/%d (%.0f%%)  false triggers %d/%d clips (%.2f per hour of talk/music)  withdrawn %d",
                      hits, positives, Double(hits) / Double(max(1, positives)) * 100, falseTriggers, negatives,
                      Double(falseTriggers) / max(0.01, negativeMinutes) * 60, withdrawnCount))
        if actionsAll > 0 {
            stdout(String(format: "WORDS after the phrase %.0f%% of the expected words · action right %d/%d · place right %d/%d",
                          Double(commandRight) / Double(max(1, commandWords)) * 100, actionsRight, actionsAll, placesRight, placesAll))
        }
        let st = listener.stats
        stdout(String(format: "COST  %.0f s wall · this process %.1f%% CPU · scans %d (%.0f s, %.0f%% of the time) · classifier %.0f s · voice triggers %d · recycled %d · memory %.0f MB",
                      wall, cpu / wall * 100, st.scans, st.scanSeconds, st.scanSeconds / max(1, wall * speed) * 100, listener.classifierSeconds,
                      st.voiceTriggers, st.recycled, footprintMB()))
        if !daemons.isEmpty {
            stdout("      daemons: " + daemons.map { String(format: "%@ %.1f s (%.1f%%)", $0.0 as NSString, $0.1, $0.1 / wall * 100) }.joined(separator: " · "))
        }
        return 0
    }

    static func words(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map(String.init)
    }

    // MARK: The soak

    @MainActor
    @available(macOS 26.0, *)
    static func soak() async -> Int32 {
        
        let minutes = flag("--minutes").flatMap(Double.init) ?? 30
        var files: [URL] = []
        if let set = flag("--set") {
            let root = URL(fileURLWithPath: (set as NSString).expandingTildeInPath)
            if let data = try? Data(contentsOf: root.appendingPathComponent("manifest.json")),
               let clips = try? JSONDecoder().decode([WakeClip].self, from: data) {
                files = clips.map { root.appendingPathComponent($0.file) }.shuffled()
            }
        }
        let noise = flag("--noise").flatMap(Float.init) ?? -62
        // Quiet room tone, with a clip (speech, the phrase, music) every `--every` seconds.
        let every = flag("--every").flatMap(Double.init) ?? 60
        let source = WakeFileSource(files: files, loop: true, gap: files.isEmpty ? 5 : every, speed: 1, noiseDB: noise)
        var settings = WakeListener.Settings()
        settings.phrase = flag("--phrase") ?? "Hey Mac"
        settings.classifier = !has("--no-classifier") && !has("--ungated")
        settings.ungated = has("--ungated")
        let listener = WakeListener(source: source)
        var wakes = 0, finished = 0
        listener.onEvent = { e in
            if case .woke = e { wakes += 1 }
            if case .finished = e { finished += 1 }
        }
        do { try listener.start(settings) } catch { stdout("couldn't start: \(error)"); return 1 }
        stdout(String(format: "SOAK %.0f min · room tone %.0f dBFS%@ · classifier %@%@", minutes, noise,
                      files.isEmpty ? "" : " · a clip every \(Int(every)) s", settings.classifier ? "on" : "off", settings.ungated ? " · UNGATED (a session all the time — the baseline)" : ""))
        let start = Date()
        var lastCPU = cpuSeconds(), lastWall = Date(), lastD = daemonCPU()
        let firstMB = footprintMB()
        var peakMB = firstMB
        var minute = 0
        while Date().timeIntervalSince(start) < minutes * 60 {
            pump(0.2)
            peakMB = max(peakMB, footprintMB())
            if Date().timeIntervalSince(lastWall) >= 60 {
                minute += 1
                let c = cpuSeconds(), w = Date(), d = daemonCPU()
                let dd = diff(lastD, d).reduce(0) { $0 + $1.1 }
                let st = listener.stats
                stdout(String(format: "  %3d min  CPU %.2f%% (+daemons %.2f%%)  memory %.1f MB  scans %d  wakes %d  landed %d  restarts %d",
                              minute, (c - lastCPU) / w.timeIntervalSince(lastWall) * 100, dd / w.timeIntervalSince(lastWall) * 100,
                              footprintMB(), st.scans, wakes, finished, st.restarts))
                lastCPU = c; lastWall = w; lastD = d
            }
        }
        listener.stop()
        stdout(String(format: "SOAK done · memory %.1f MB at the start, %.1f MB at the end, %.1f MB peak", firstMB, footprintMB(), peakMB))
        return 0
    }
}
