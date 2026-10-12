import MacrophoneKit
import SwiftUI

/// A text editor for templates and snippet expansions: variable chips that insert at the end,
/// a live preview with sample values, and a warning for anything that isn't a known variable.
struct TemplateEditor: View {
    @Binding var text: String
    var placeholder: String
    /// The words the preview shows for {{text}} (already formatted).
    var sampleText: String = ContextGatherer.samples["text"]!
    var height: CGFloat = 76
    /// Snippet expansions don't wrap the dictation, so {{text}} isn't offered there.
    var offersText = true
    /// Show the "Preview" block.
    var showsPreview = true

    private var used: Set<String> { TemplateRenderer.variables(in: text) }
    private var unknown: [String] {
        let known = Set(TemplateRenderer.known.map(\.name))
        return used.subtracting(known).sorted()
    }
    /// Unclosed or malformed braces, e.g. "{{url}" or "{{ URL }}".
    private var malformed: Bool {
        let opens = text.components(separatedBy: "{{").count - 1
        let closes = text.components(separatedBy: "}}").count - 1
        let re = try? NSRegularExpression(pattern: "\\{\\{\\s*[a-z_]+\\s*\\}\\}")
        let wellFormed = re?.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) ?? opens
        return opens != closes || opens != wellFormed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $text)
                .font(Typeface.mono(12, .regular))
                .noWritingTools()
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: height)
                .background(RoundedRectangle(cornerRadius: 8).fill(Ink.sunk))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(placeholder)
                            .font(Typeface.mono(12, .regular)).foregroundStyle(Ink.tertiary.opacity(0.7))
                            .padding(.horizontal, 11).padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Ink.line, lineWidth: 1))

            VariableChips(offersText: offersText, used: used) { name in
                let token = "{{\(name)}}"
                if text.isEmpty || text.hasSuffix(" ") || text.hasSuffix("\n") { text += token } else { text += " " + token }
            }

            if !unknown.isEmpty || malformed {
                Label(unknown.isEmpty
                      ? "Check the braces — a variable looks like {{name}}."
                      : "Not a variable Macrophone knows: \(unknown.map { "{{\($0)}}" }.joined(separator: ", ")). It'll be left as typed.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5)).foregroundStyle(Light.ochre)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(permissionNotes, id: \.self) { n in
                Label(n, systemImage: "lock")
                    .font(.system(size: 11.5)).foregroundStyle(Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if showsPreview && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Kicker("Preview · sample values", size: 9.5)
                    Text(preview)
                        .font(Typeface.mono(11.5, .regular))
                        .foregroundStyle(Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Ink.ink.opacity(0.035)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Ink.line, lineWidth: 1))
            }
        }
    }

    private var preview: String {
        offersText
            ? TemplateRenderer.render(template: text, text: sampleText, context: ContextGatherer.samples)
            : TemplateRenderer.fill(text, context: ContextGatherer.samples)
    }

    private var permissionNotes: [String] {
        var n: [String] = []
        if used.contains("url") { n.append("{{url}} reads the front browser tab's address. Each browser asks you once.") }
        if used.contains("selection") || used.contains("window") { n.append("{{selection}} and {{window}} use Accessibility, which pasting already needs.") }
        if used.contains("clipboard") { n.append("{{clipboard}} is what you had copied just before the dictation arrived.") }
        return n
    }
}

/// The variable chips. Hover shows what each one is.
struct VariableChips: View {
    var offersText = true
    var used: Set<String> = []
    var insert: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 5, lineSpacing: 5) {
            ForEach(TemplateRenderer.known.filter { offersText || $0.name != "text" }, id: \.name) { v in
                Button { insert(v.name) } label: {
                    Text("{{\(v.name)}}")
                        .font(Typeface.mono(10.5, .medium))
                        .foregroundStyle(used.contains(v.name) ? Light.teal : Ink.secondary)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill((used.contains(v.name) ? Light.teal : Ink.ink).opacity(0.08)))
                        .overlay(Capsule().strokeBorder((used.contains(v.name) ? Light.teal : Ink.ink).opacity(0.18), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .help(v.summary)
                .accessibilityLabel("Insert \(v.name): \(v.summary)")
            }
        }
    }
}

/// Wraps its children onto as many lines as they need (chips, prefixes).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += lineH + lineSpacing; lineH = 0 }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            lineH = max(lineH, size.height)
        }
        return CGSize(width: proposal.width ?? maxX, height: y + lineH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineH: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { x = bounds.minX; y += lineH + lineSpacing; lineH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineH = max(lineH, size.height)
        }
    }
}

/// Editable word chips: type and press Return to add, × to remove (voice prefixes).
struct ChipField: View {
    @Binding var items: [String]
    /// What's typed but not yet added (the parent saves it too, so nothing typed is lost).
    @Binding var draft: String
    var placeholder: String

    var body: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(items, id: \.self) { item in
                HStack(spacing: 4) {
                    Text(item).font(.system(size: 12, weight: .medium)).foregroundStyle(Ink.ink)
                    Button { items.removeAll { $0 == item } } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Ink.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(item)")
                }
                .padding(.leading, 9).padding(.trailing, 7).padding(.vertical, 4)
                .background(Capsule().fill(Light.cyan.opacity(0.12)))
                .overlay(Capsule().strokeBorder(Light.cyan.opacity(0.3), lineWidth: 0.5))
            }
            TextField(items.isEmpty ? placeholder : "Add another", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .frame(width: 150)
                .padding(.vertical, 4)
                .onSubmit(add)
        }
        .padding(7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Ink.sunk))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Ink.line, lineWidth: 1))
    }

    private func add() {
        let w = draft.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !w.isEmpty else { return }
        if !items.contains(where: { $0.lowercased() == w.lowercased() }) { items.append(w) }
        draft = ""
    }
}
