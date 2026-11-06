import MacrophoneKit
import SwiftUI

/// Up to 50 words the recognizer should expect and cleanup must keep as written.
struct DictionaryView: View {
    @ObservedObject var settings: Settings
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var full: Bool { settings.dictionary.count >= DictionaryPass.maxTerms }

    var body: some View {
        List {
            Section {
                HStack(spacing: 10) {
                    // Vertical, so a long name wraps at huge text sizes instead of clipping; Return adds it.
                    TextField(full ? "Dictionary full" : "Add a word or name", text: $draft, axis: .vertical)
                        .lineLimit(1...3)
                        .onChange(of: draft) { _, d in if d.contains("\n") { draft = d.replacingOccurrences(of: "\n", with: ""); add() } }
                        .focused($focused)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit(add)
                        .disabled(full)
                    Button(action: add) { Image(systemName: "plus.circle.fill").font(.title2) }
                        .buttonStyle(.borderless)
                        .foregroundStyle(canAdd ? Light.cyan : Ink.tertiary)
                        .disabled(!canAdd)
                        .accessibilityLabel("Add word")
                }
            } footer: {
                Text(full
                     ? "That's all 50. To add another, swipe a word left to remove it."
                     : "Words like “kubectl” or “TPA” that you want heard and written exactly this way. Spelled as you type them.")
            }

            Section {
                if settings.dictionary.isEmpty {
                    EmptyState(symbol: "character.book.closed", title: "No words yet",
                               message: "Names and terms you add show up here.")
                } else {
                    ForEach(settings.dictionary, id: \.self) { term in
                        Text(term).foregroundStyle(Ink.ink)
                    }
                    .onDelete { settings.dictionary.remove(atOffsets: $0) }
                }
            } header: {
                Text("\(settings.dictionary.count) of \(DictionaryPass.maxTerms)").monospacedDigit()
            } footer: {
                if !settings.isEnglish {
                    Text("Your language isn't English, so these only help the recognizer hear them — the fix-up pass is English only.")
                }
            }
        }
        .navigationTitle("Dictionary")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { if !settings.dictionary.isEmpty { EditButton() } }
    }

    private var canAdd: Bool { !full && !draft.trimmingCharacters(in: .whitespaces).isEmpty }

    private func add() {
        guard canAdd else { return }
        settings.dictionary = DictionaryPass.normalize(settings.dictionary + [draft])
        draft = ""
        focused = true
    }
}

/// Only languages this iPhone can transcribe on-device are listed.
struct LanguageView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var settings: Settings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                if Languages.onDevice.isEmpty {
                    EmptyState(symbol: "globe", title: "No speech languages yet",
                               message: "Add a dictation language in Settings › General › Keyboard, then come back.")
                }
                ForEach(Languages.onDevice) { lang in
                    Button {
                        settings.language = lang.id
                        model.refreshAvailability()
                        dismiss()
                    } label: {
                        HStack {
                            Text(lang.name).foregroundStyle(Ink.ink)
                            Spacer()
                            if lang.id == settings.language {
                                Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Light.cyan)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .accessibilityAddTraits(lang.id == settings.language ? .isSelected : [])
                }
            } footer: {
                Text("Only languages your iPhone can transcribe on its own are shown, so your voice never leaves it. Cleanup works in English; other languages are sent as heard.")
            }
        }
        .navigationTitle("Language")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Away from home, step by step (Nov 4 2026: the steps were a fourteen-line footer on the Mac's
/// page). A numbered list, as Apple's own how-tos read, with where to try it at the foot.
struct AwaySetupView: View {
    private static let steps: [(title: String, detail: String?)] = [
        ("Install Tailscale on your Mac and on this iPhone.", "It's free, and nothing goes through a server of ours."),
        ("Sign in to both with the same account.", "The same Google or Apple sign-in. In the iPhone's Tailscale app, your Mac should be in the list of devices."),
        ("Turn Tailscale on here.", "Allow the VPN when iOS asks. On your Mac's page, Tailscale on this iPhone then says On."),
        ("Turn on Remote access on your Mac.", "In Macrophone on your Mac: Devices › Away from home."),
        ("Open Macrophone here once at home.", "Your Mac's address arrives by itself."),
    ]

    var body: some View {
        Form {
            Section {
                ForEach(Array(Self.steps.enumerated()), id: \.offset) { i, step in
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        Image(systemName: "\(i + 1).circle.fill")
                            .font(.title3)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Light.cyan)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(step.title).foregroundStyle(Ink.ink)
                            if let d = step.detail {
                                Text(d).font(.subheadline).foregroundStyle(Ink.secondary)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Step \(i + 1). \(step.title) \(step.detail ?? "")")
                }
            } header: {
                Text("With Tailscale")
            } footer: {
                Text("To try it, turn off Wi-Fi and Bluetooth here — otherwise a nearby iPhone talks to your Mac directly.")
            }
            Section {
                Text("Forward Macrophone's port on your router to your Mac, then type your home's address on your Mac's page.")
                    .foregroundStyle(Ink.ink)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Without Tailscale")
            } footer: {
                Text("The port is in Macrophone on your Mac, under Devices › Away from home.")
            }
        }
        .navigationTitle("Away from Home")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The diagnostics text, readable before it's shared. Never contains dictation text or keys.
struct DiagnosticsView: View {
    @EnvironmentObject var model: AppModel
    @State private var text = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Ink.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: Radius.large, style: .continuous).fill(Ink.raised))
                Text("This is everything that will be shared. It never includes what you dictated or your pairing keys.")
                    .font(.footnote)
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Ink.ground.ignoresSafeArea())
        .setupFoot {
            ShareLink(item: text, subject: Text("Macrophone diagnostics"), preview: SharePreview("Macrophone diagnostics")) {
                Label("Share Diagnostics", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
            }
            .setupPrimary()
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { text = model.diagnosticsText() }
    }
}
