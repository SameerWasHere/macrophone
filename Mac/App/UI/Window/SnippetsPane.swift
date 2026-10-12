import MacrophoneKit
import SwiftUI

/// Say a trigger, get the expansion — before the profile's format and template.
struct SnippetsPane: View {
    @ObservedObject var settings: Settings
    @State private var editing: Snippet?

    var body: some View {
        PanePage {
            HStack(alignment: .bottom) {
                PaneHeader(title: "Snippets", subtitle: "Say a short phrase, get something longer. “My email” becomes your address; “standup template” becomes your three questions.")
                Button { editing = Snippet(trigger: "", expansion: "") } label: { Label("New Snippet", systemImage: "plus") }
                    .buttonStyle(PillButtonStyle(tint: Ink.ink, filled: true))
                    .padding(.bottom, 2)
            }

            if settings.snippets.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "text.badge.plus").font(.system(size: 30, weight: .light)).foregroundStyle(Ink.tertiary)
                    Text("No snippets yet").font(Typeface.serif(18)).foregroundStyle(Ink.secondary)
                    Text("Try “my address”, or “sig” for an email sign-off with {{date}} in it.")
                        .font(.system(size: 12.5)).foregroundStyle(Ink.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 44)
            } else {
                Plate {
                    ForEach(Array(settings.snippets.enumerated()), id: \.element.id) { i, s in
                        if i > 0 { PlateDivider() }
                        SnippetRow(snippet: s, edit: { editing = s })
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("How they work").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Ink.secondary)
                Text("A trigger matches whole words anywhere in what you say, ignoring capitals and the commas the recognizer adds. Longer triggers win. Expansions can use variables like {{date}} or {{clipboard}}. Snippets apply to every profile, before its format and template.")
                    .font(.system(size: 12)).foregroundStyle(Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(item: $editing) { s in
            SnippetEditor(snippet: s, isNew: !settings.snippets.contains { $0.id == s.id }, settings: settings)
        }
        .onAppear {
            #if DEBUG
            if ProcessInfo.processInfo.environment["MACROPHONE_SHOW"] == "snippet-editor", editing == nil {
                editing = settings.snippets.first ?? Snippet(trigger: "sig", expansion: "Thanks,\nSameer\n{{date}}")
            }
            #endif
        }
    }
}

private struct SnippetRow: View {
    let snippet: Snippet
    var edit: () -> Void
    @State private var hover = false
    private var long: Bool { snippet.expansion.filter { $0 == "\n" }.count >= 3 || snippet.expansion.count > 150 }

    var body: some View {
        Button(action: edit) {
            HStack(alignment: .top, spacing: 14) {
                Text("“\(snippet.trigger)”")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.ink)
                    .frame(width: 170, alignment: .leading)
                Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Ink.tertiary)
                    .padding(.top, 3)
                Text(snippet.expansion)
                    .font(Typeface.mono(12, .regular)).foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, maxHeight: 54, alignment: .topLeading)
                    .clipped()
                    // Long ones fade at the foot instead of being cut with "…".
                    .mask(LinearGradient(stops: [.init(color: .black, location: 0.62),
                                                 .init(color: .black.opacity(long ? 0 : 1), location: 1)],
                                         startPoint: .top, endPoint: .bottom))
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Ink.tertiary)
                    .padding(.top, 3)
            }
            .padding(.horizontal, 16).padding(.vertical, 11)
            .background(hover ? Ink.ink.opacity(0.03) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel("Snippet \(snippet.trigger). Edit")
    }
}

private struct SnippetEditor: View {
    @State var snippet: Snippet
    let isNew: Bool
    @ObservedObject var settings: Settings
    @Environment(\.dismiss) private var dismiss
    @State private var tryIt = "Send it to my email please"

    private var duplicate: Bool {
        let t = snippet.trigger.trimmingCharacters(in: .whitespaces).lowercased()
        return settings.snippets.contains { $0.id != snippet.id && $0.trigger.lowercased() == t }
    }
    private var valid: Bool {
        !snippet.trigger.trimmingCharacters(in: .whitespaces).isEmpty && !snippet.expansion.isEmpty && !duplicate
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(isNew ? "New Snippet" : "Edit Snippet").font(Typeface.serif(24)).foregroundStyle(Ink.ink)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("When you say").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Ink.secondary)
                        TextField("e.g. my email", text: $snippet.trigger).textFieldStyle(.roundedBorder)
                        if duplicate {
                            Text("Another snippet already uses these words.").font(.system(size: 11.5)).foregroundStyle(Light.ochre)
                        } else {
                            Text("Pick words you wouldn't say for any other reason.").font(.system(size: 11.5)).foregroundStyle(Ink.tertiary)
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Put this instead").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Ink.secondary)
                        TemplateEditor(text: $snippet.expansion, placeholder: "sameer@example.com", height: 96, offersText: false)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Try it").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Ink.secondary)
                        TextField("Say something with the trigger in it", text: $tryIt).textFieldStyle(.roundedBorder)
                        Text(SnippetExpander.expand(tryIt, snippets: snippet.trigger.isEmpty ? [] : [snippet], context: ContextGatherer.samples))
                            .font(Typeface.serif(14)).foregroundStyle(Ink.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Ink.ink.opacity(0.035)))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Ink.line, lineWidth: 1))
                    }
                }
                .padding(24)
            }
            Rectangle().fill(Ink.line).frame(height: 1)
            HStack {
                if !isNew {
                    Button("Delete Snippet", role: .destructive) {
                        settings.snippets.removeAll { $0.id == snippet.id }
                        dismiss()
                    }
                    .buttonStyle(PillButtonStyle(tint: Light.rose, filled: false))
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Add Snippet" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!valid)
            }
            .padding(16)
        }
        .frame(width: 520, height: 600)
        .background(Ink.ground)
        .preferredColorScheme(.dark)
        .onAppear {
            if !snippet.trigger.isEmpty { tryIt = "Here it is: \(snippet.trigger)." }
        }
    }

    private func save() {
        snippet.trigger = snippet.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        if let i = settings.snippets.firstIndex(where: { $0.id == snippet.id }) {
            settings.snippets[i] = snippet
        } else {
            settings.snippets.append(snippet)
        }
        dismiss()
    }
}
