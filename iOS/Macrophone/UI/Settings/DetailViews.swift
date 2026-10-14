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
                        .buttonStyle(.plain)
                        .foregroundStyle(canAdd ? Light.cyan : Ink.tertiary)
                        .disabled(!canAdd)
                        .accessibilityLabel("Add word")
                }
            } footer: {
                Text(full
                     ? "That's all 50. To add another, swipe a word left to remove it."
                     : "Words like “kubectl” or “TPA” that you want heard and written exactly this way. Spelled as you type them.")
            }
            .listRowBackground(Ink.raised)

            Section {
                if settings.dictionary.isEmpty {
                    Text("No words yet.").foregroundStyle(Ink.tertiary)
                } else {
                    ForEach(settings.dictionary, id: \.self) { term in
                        Text(term).font(.body.monospaced()).foregroundStyle(Ink.ink)
                    }
                    .onDelete { settings.dictionary.remove(atOffsets: $0) }
                }
            } header: {
                Text("\(settings.dictionary.count) of \(DictionaryPass.maxTerms)")
                    .font(.mono(.caption, weight: .semibold))
            } footer: {
                if !settings.isEnglish {
                    Text("Your language isn't English, so these only help the recognizer hear them — the fix-up pass is English only.")
                }
            }
            .listRowBackground(Ink.raised)
        }
        .scrollContentBackground(.hidden)
        .background(Ink.ground.ignoresSafeArea())
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
                    Text("This iPhone hasn't downloaded any on-device speech languages yet. Add one in Settings › General › Keyboard › Dictation, then come back.")
                        .foregroundStyle(Ink.secondary)
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
                            if lang.id == settings.language { Image(systemName: "checkmark").foregroundStyle(Light.cyan) }
                        }
                    }
                    .accessibilityAddTraits(lang.id == settings.language ? .isSelected : [])
                }
            } footer: {
                Text("Only languages your iPhone can transcribe on its own are shown, so your voice never leaves it. Cleanup works in English; other languages are sent as heard.")
            }
            .listRowBackground(Ink.raised)
        }
        .scrollContentBackground(.hidden)
        .background(Ink.ground.ignoresSafeArea())
        .navigationTitle("Language")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The diagnostics text, readable before it's shared. Never contains dictation text or keys.
struct DiagnosticsView: View {
    @EnvironmentObject var model: AppModel
    @State private var text = ""

    var body: some View {
        VStack(spacing: 0) {
            Text("This is everything that will be shared. It never includes what you dictated or your pairing keys.")
                .font(.footnote)
                .foregroundStyle(Ink.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(16)
            ScrollView {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Ink.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(14)
            }
            .background(RoundedRectangle(cornerRadius: Radius.small, style: .continuous).fill(Ink.sunk))
            .overlay(RoundedRectangle(cornerRadius: Radius.small, style: .continuous).strokeBorder(Ink.line))
            .padding(.horizontal, 16)
            ShareLink(item: text, subject: Text("Macrophone diagnostics"), preview: SharePreview("Macrophone diagnostics")) {
                Label("Share Diagnostics", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
            }
            .pillStyle(.primary, tint: Ink.ink)
            .padding(16)
        }
        .background(Ink.ground.ignoresSafeArea())
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { text = model.diagnosticsText() }
    }
}
