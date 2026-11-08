import MacrophoneKit
import SwiftUI

/// The Dictation page's wake word (Nov 7 2026): the switch and what it's doing, the phrase,
/// sensitivity, the pause that lands it, chimes, and the ending words. Desk/WakeWord.swift.
struct WakeWordSection: View {
    @ObservedObject var settings: Settings
    @ObservedObject var wake: WakeController
    @State private var customMode = false
    @State private var customText = ""
    @FocusState private var customFocused: Bool

    private static let custom = "custom"

    var body: some View {
        PaneSection("Wake word", note: note) {
            Plate {
                PlateRow(title: "Listen for a wake word", subtitle: statusLine, subtitleColor: statusColor,
                         icon: "waveform", iconColor: wake.isListening ? Light.teal : Ink.tertiary) {
                    Toggle("", isOn: Binding(get: { settings.wakeOn }, set: { on in
                        if on { wake.turnOn() } else { settings.wakeOn = false }
                    }))
                    .toggleStyle(.switch).labelsHidden()
                    .accessibilityLabel("Listen for a wake word")
                }
                PlateDivider()
                PlateRow(title: "Phrase", subtitle: phraseLine, subtitleColor: phraseProblem == nil ? Ink.tertiary : Light.ochre, icon: "quote.bubble") {
                    HStack(spacing: 8) {
                        if customMode {
                            TextField("Hey Jarvis", text: $customText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 150)
                                .focused($customFocused)
                                .onSubmit(commitCustom)
                                .accessibilityLabel("Your phrase")
                        }
                        Picker("", selection: Binding(get: { customMode ? Self.custom : pickerValue },
                                                      set: { pick($0) })) {
                            ForEach(WakePhrase.presets, id: \.self) { Text("“\($0)”").tag($0) }
                            Divider()
                            Text(customMode || !WakePhrase.presets.contains(settings.wakePhrase) ? "Your Own: “\(settings.wakePhrase)”" : "Your Own…")
                                .tag(Self.custom)
                        }
                        .labelsHidden().pickerStyle(.menu).fixedSize()
                        .accessibilityLabel("Wake phrase")
                    }
                }
                PlateDivider()
                PlateRow(title: "Sensitivity", subtitle: settings.wakeSensitivity.summary, icon: "dial.medium") {
                    Picker("", selection: $settings.wakeSensitivity) {
                        ForEach(WakeSensitivity.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).fixedSize()
                    .accessibilityLabel("Sensitivity")
                }
                PlateDivider()
                PlateRow(title: "Finish after a pause of", subtitle: "Or say an ending word — or tap \(DeskKey.fn.short).", icon: "timer") {
                    HStack(spacing: 8) {
                        Slider(value: $settings.wakeEndSilence, in: 0.8...4, step: 0.2).frame(width: 140)
                            .accessibilityLabel("Pause that finishes")
                            .accessibilityValue(String(format: "%.1f seconds", settings.wakeEndSilence))
                        Text(String(format: "%.1f s", settings.wakeEndSilence))
                            .font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(Ink.secondary)
                            .frame(width: 38, alignment: .trailing)
                    }
                }
                PlateDivider()
                PlateRow(title: "Chimes", subtitle: "A soft sound when it hears the phrase and when the words land.", icon: "bell") {
                    Toggle("", isOn: $settings.wakeChimes).toggleStyle(.switch).labelsHidden()
                        .accessibilityLabel("Chimes")
                }
            }
            .disabled(!WakeController.engineAvailable)

            if wake.sameerOSListening, settings.wakeOn {
                HStack(spacing: Space.gap) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(Light.ochre).accessibilityHidden(true)
                    Text("SameerOS is also listening for “Hey Claude” — turn it off there.")
                        .font(.system(size: 12)).foregroundStyle(Light.ochre)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 4)
            }
        }
        .onAppear { wake.readSameerOS() }
        .sheet(isPresented: $wake.introShown) { WakeIntroSheet(settings: settings, wake: wake) }
    }

    private var pickerValue: String {
        WakePhrase.presets.first { $0.caseInsensitiveCompare(settings.wakePhrase) == .orderedSame } ?? Self.custom
    }

    private func pick(_ value: String) {
        if value == Self.custom {
            customMode = true
            customText = WakePhrase.presets.contains(settings.wakePhrase) ? "" : settings.wakePhrase
            customFocused = true
        } else {
            customMode = false
            settings.wakePhrase = value
        }
    }

    private func commitCustom() {
        let p = WakePhrase(customText)
        guard p.problem == nil else { return }
        settings.wakePhrase = p.text
        customMode = false
    }

    private var phraseProblem: String? { customMode && !customText.isEmpty ? WakePhrase(customText).problem : nil }

    private var phraseLine: String {
        if let phraseProblem { return phraseProblem }
        if customMode { return "Two or three words, said the way you'd say them. Return to use it." }
        return WakePhrase(settings.wakePhrase).advice ?? "Say it, then what you want typed."
    }

    private var statusLine: String {
        guard settings.wakeOn else { return "Off — the microphone is only used while you hold \(DeskKey.fn.short)." }
        var line = wake.statusLine ?? "Listening for “\(settings.wakePhrase)”"
        if wake.isListening, let avoided = wake.avoided {
            line += " · on \(wake.device.isEmpty ? "the Mac's microphone" : wake.device), so \(avoided) keeps its sound"
        }
        return line
    }

    private var statusColor: Color {
        switch wake.state {
        case .listening: return Light.teal
        case .unavailable: return Light.ochre
        case .paused: return Ink.secondary
        case .off: return Ink.tertiary
        }
    }

    private var note: String {
        "Say “\(settings.wakePhrase)”, then what you want typed — it lands where you're typing. Name an app at the end to go there instead: “… paste in Notes”, “… send to Claude”. Esc or “never mind” drops it. It pauses while your Mac is locked or asleep and during calls; the menu bar icon pauses it too. Everything stays on this Mac — nothing is recorded."
    }
}

/// What ends a capture: three lists, each a comma-separated line.
struct WakeEndingsSection: View {
    @ObservedObject var settings: Settings
    @State private var send = ""
    @State private var paste = ""
    @State private var cancel = ""

    var body: some View {
        PaneSection("Ending words", note: "Said at the end, they're taken out of the words. A one-word ending only counts after a pause. Empty brings the defaults back.") {
            Plate {
                row("Send", "Paste, then press Return.", icon: "paperplane", text: $send, list: .send)
                PlateDivider()
                row("Paste", "Paste only — the same as just pausing.", icon: "text.cursor", text: $paste, list: .paste)
                PlateDivider()
                row("Cancel", "Nothing is pasted.", icon: "xmark.circle", text: $cancel, list: .cancel)
            }
        }
        .onAppear(perform: load)
        .onChange(of: settings.wakeEndings) { _, _ in load() }
    }

    private func load() {
        send = settings.wakeEndings.send.joined(separator: ", ")
        paste = settings.wakeEndings.paste.joined(separator: ", ")
        cancel = settings.wakeEndings.cancel.joined(separator: ", ")
    }

    private func row(_ title: String, _ subtitle: String, icon: String, text: Binding<String>, list: WakeAction) -> some View {
        PlateRow(title: title, subtitle: subtitle, icon: icon) {
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 250)
                .onSubmit { commit(text.wrappedValue, list) }
                .accessibilityLabel("\(title) words")
        }
    }

    private func commit(_ text: String, _ list: WakeAction) {
        var e = settings.wakeEndings
        e.set(list, text.split(separator: ",").map(String.init))
        settings.wakeEndings = e
        load()
    }
}

/// This Mac's Dictionary: names and words spelled your way.
struct DictionarySection: View {
    @ObservedObject var settings: Settings
    @State private var adding = ""
    @FocusState private var focused: Bool

    var body: some View {
        PaneSection("Dictionary", note: "Speech listens for these and cleanup keeps their spelling — when you hold the key and after the wake word.") {
            Plate {
                VStack(alignment: .leading, spacing: 12) {
                    if settings.dictionary.isEmpty {
                        Text("No words yet — add names, products and jargon you say often.")
                            .font(.system(size: 12)).foregroundStyle(Ink.tertiary)
                    } else {
                        WrapLayout(spacing: 6) {
                            ForEach(settings.dictionary, id: \.self) { w in
                                HStack(spacing: 4) {
                                    Text(w).font(.system(size: 12, weight: .medium)).foregroundStyle(Ink.ink)
                                    Button { settings.dictionary.removeAll { $0 == w } } label: {
                                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Ink.tertiary)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Remove \(w)")
                                }
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .background(Capsule().fill(Ink.ink.opacity(0.07)))
                                .overlay(Capsule().strokeBorder(Ink.line, lineWidth: 1))
                            }
                        }
                    }
                    HStack(spacing: 8) {
                        TextField("Add a word or name", text: $adding)
                            .textFieldStyle(.roundedBorder)
                            .focused($focused)
                            .onSubmit(add)
                            .frame(maxWidth: 260)
                            .accessibilityLabel("Add to the Dictionary")
                        Button("Add", action: add)
                            .buttonStyle(PillButtonStyle(tint: Ink.ink, filled: false))
                            .disabled(adding.trimmingCharacters(in: .whitespaces).isEmpty)
                        Spacer()
                        Text("\(settings.dictionary.count) word\(settings.dictionary.count == 1 ? "" : "s")")
                            .font(.system(size: 11)).foregroundStyle(Ink.tertiary)
                    }
                }
                .padding(Space.inset)
            }
        }
    }

    private func add() {
        let w = adding.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty else { return }
        settings.dictionary = DictionaryImport.merge(settings.dictionary, [w])
        adding = ""
        focused = true
    }
}

/// Words that wrap onto the next line.
struct WrapLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += row + spacing; row = 0 }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            row = max(row, size.height)
        }
        return CGSize(width: min(width, widest), height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}

/// The first time it's turned on: the orange dot, what's heard, and Say it now.
struct WakeIntroSheet: View {
    @ObservedObject var settings: Settings
    @ObservedObject var wake: WakeController

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "waveform.circle.fill").font(.system(size: 34)).foregroundStyle(Light.teal)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Talk to your Mac by name").font(Typeface.serif(22)).foregroundStyle(Ink.ink)
                    Text("Say “\(settings.wakePhrase)”, then what you want typed.").font(.system(size: 13)).foregroundStyle(Ink.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 14) {
                point("circle.fill", Color(hex: 0xF5A623), "The orange dot",
                      "macOS shows an orange dot in the menu bar while an app can hear the microphone. With the wake word on, it stays — that's Macrophone listening.")
                point("lock", Light.cyan, "What it hears stays here",
                      "It listens on this Mac for “\(settings.wakePhrase)”, then for what you say after it, and pastes that where you're typing. Nothing is recorded, kept or sent anywhere.")
                point("pause.circle", Ink.secondary, "When it stops",
                      "It lets go of the microphone while your Mac is locked or asleep, during a call in another app, and when you pause it from the menu bar icon.")
            }
            testBox
            HStack {
                Button("Not Now") { wake.endTest(keep: false) }
                    .buttonStyle(PillButtonStyle(tint: Ink.ink, filled: false))
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Turn On") { wake.endTest(keep: true) }
                    .buttonStyle(PillButtonStyle(tint: Light.teal, filled: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(26)
        .frame(width: 480)
        .background(Ink.ground)
        .onAppear { wake.beginTest() }
    }

    private func point(_ symbol: String, _ color: Color, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(color)
                .frame(width: 20).padding(.top, 2).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.ink)
                Text(text).font(.system(size: 12)).foregroundStyle(Ink.secondary).lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var testBox: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill((wake.testHeard ? Light.mint : Light.teal).opacity(0.16)).frame(width: 46, height: 46)
                Image(systemName: wake.testHeard ? "checkmark" : "mic.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(wake.testHeard ? Light.mint : Light.teal)
            }
            .animation(Motion.reduceMotion ? nil : Motion.pop, value: wake.testHeard)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(wake.testHeard ? "Heard you" : "Say it now")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(wake.testHeard ? Light.mint : Ink.ink)
                Text(testLine).font(.system(size: 12)).foregroundStyle(Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if wake.testHeard {
                Button("Again") { wake.beginTest() }.buttonStyle(PillButtonStyle(tint: Ink.ink, filled: false))
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Radius.plate, style: .continuous).fill(Ink.raised.opacity(0.72)))
        .overlay(RoundedRectangle(cornerRadius: Radius.plate, style: .continuous)
            .strokeBorder(wake.testHeard ? Light.mint.opacity(0.5) : Ink.line, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private var testLine: String {
        if wake.testHeard { return "“\(settings.wakePhrase)” came through. Turn it on, or say it again." }
        switch wake.state {
        case .unavailable(let why) where !why.hasPrefix("Finish"): return why
        default: return wake.testing ? "Say “\(settings.wakePhrase)” out loud — nothing will be typed." : "Allow the microphone when macOS asks."
        }
    }
}
