import MacrophoneKit
import SwiftUI

/// Cleaned / Raw — the Mac's words for the same two versions. Shown only when cleanup changed
/// the words (taking a spoken "Claude," off the front alone isn't worth a toggle; Copy Raw has it).
struct VersionToggle: View {
    @Binding var cleaned: Bool

    var body: some View {
        HStack(spacing: 2) {
            option("Cleaned", on: cleaned) { cleaned = true }
            option("Raw", on: !cleaned) { cleaned = false }
        }
        .padding(3)
        .frame(minHeight: 44)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .background(Capsule().fill(Ink.ink.opacity(0.06)).padding(.vertical, 3.5))
        .overlay(Capsule().strokeBorder(Ink.line, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Version")
    }

    private func option(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: { withAnimation(Motion.snap) { action() } }) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(minHeight: 32)
                .foregroundStyle(on ? Ink.ground : Ink.secondary)
                .background(Capsule().fill(on ? Ink.ink : .clear))
                .contentShape(Capsule().inset(by: -6))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityHint(title == "Raw" ? "Shows exactly what was heard." : "Shows what was sent.")
    }
}

/// Measures a view's natural height without letting it take part in layout.
private struct NaturalHeight<Content: View>: View {
    var content: Content
    @Binding var height: CGFloat
    var body: some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .hidden()
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            .accessibilityHidden(true)
    }
}

/// Text that shows whole when it fits and otherwise scrolls in place under a fade —
/// never cut with "…".
struct FittedText: View {
    var text: String
    var font: Font
    var maxHeight: CGFloat
    var color: Color = Ink.ink
    @State private var natural: CGFloat = 0

    var body: some View {
        Group {
            if natural > maxHeight + 1 {
                ScrollView(.vertical) { label.padding(.bottom, 18) }
                    .scrollIndicators(.visible)
                    .frame(height: maxHeight)
                    .edgeFade(bottom: 22)
            } else {
                label
            }
        }
        .background(alignment: .top) { NaturalHeight(content: label, height: $natural) }
    }

    private var label: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .lineSpacing(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

/// Text that shows whole when short, else the top under a fade with "Show all".
struct ExpandableText: View {
    var text: String
    var font: Font
    var collapsedHeight: CGFloat = 128
    @State private var expanded = false
    @State private var natural: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if expanded || natural <= collapsedHeight + 1 {
                label
            } else {
                label.frame(height: collapsedHeight, alignment: .top).clipped().edgeFade(bottom: 40)
            }
            if natural > collapsedHeight + 1 {
                Button(expanded ? "Show less" : "Show all") { withAnimation(Motion.settle) { expanded.toggle() } }
                    .font(.footnote.weight(.semibold)).foregroundStyle(Light.cyan)
                    .buttonStyle(.plain)
                    .frame(minHeight: 32)
            }
        }
        .background(alignment: .top) { NaturalHeight(content: label, height: $natural) }
    }

    private var label: some View {
        Text(text)
            .font(font)
            .foregroundStyle(Ink.ink)
            .lineSpacing(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Icon + title for chip buttons. Not a `Label`: inside a List row (History) iOS 27 laid a
/// Label out icon-only in a tall sliver.
struct ChipLabel: View {
    var title: String
    var systemImage: String
    init(_ title: String, systemImage: String) { self.title = title; self.systemImage = systemImage }
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).contentTransition(.symbolEffect(.replace))
                .accessibilityHidden(true)
            Text(title)
        }
        .fixedSize()
    }
}

/// Copy, with a brief "Copied" in place.
struct CopyButton: View {
    var action: () -> Void
    @State private var copied = false

    var body: some View {
        Button {
            action()
            copied = true
            Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copied = false }
        } label: {
            ChipLabel(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(ChipButtonStyle(tint: copied ? Light.mint : Ink.secondary))
        .accessibilityLabel(copied ? "Copied" : "Copy text")
    }
}

/// The last dictation, under the mic.
struct LastDictationCard: View {
    var item: HistoryItem
    var onCopy: (Bool) -> Void
    var onResend: () -> Void
    var maxTextHeight: CGFloat = 132
    /// Unpaired, there's nowhere to resend to — Copy is the action.
    var canResend = true
    @State private var showCleaned = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center) {
                    Kicker(kicker).fixedSize()
                    Spacer(minLength: 8)
                    if item.showsVersionToggle { VersionToggle(cleaned: $showCleaned).fixedSize() }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Kicker(kicker)
                    if item.showsVersionToggle { VersionToggle(cleaned: $showCleaned).fixedSize() }
                }
            }
            FittedText(text: item.text(cleaned: showCleaned), font: .serif(.body), maxHeight: maxTextHeight)
                .id(showCleaned)
                .accessibilityLabel(item.text(cleaned: showCleaned))
            FlowRow(spacing: 8) {
                CopyButton { onCopy(showCleaned) }
                if canResend {
                    Button(action: onResend) { ChipLabel("Resend", systemImage: "arrow.clockwise") }
                        .buttonStyle(ChipButtonStyle())
                            .accessibilityHint("Sends it to your Mac again. Your Mac ignores it if it already has it.")
                }
                if item.dictation.stoppedEarly {
                    Kicker("Stopped early", color: Light.ochre).frame(minHeight: 44)
                }
                if item.partialCleanup == true {
                    Kicker("Partly cleaned", color: Light.ochre).frame(minHeight: 44)
                        .accessibilityLabel("Partly cleaned: cleanup ran out of time, the rest was sent as spoken")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .glass(Radius.large)
        .contextMenu {
            Button { onCopy(showCleaned) } label: { Label("Copy", systemImage: "doc.on.doc") }
            if item.hasCleaned {
                Button { onCopy(false) } label: { Label("Copy Raw", systemImage: "text.quote") }
            }
            if canResend { Button(action: onResend) { Label("Resend", systemImage: "arrow.clockwise") } }
        }
    }

    private var kicker: String {
        var parts = [item.targetName.map { "→ \($0)" } ?? "Last dictation"]
        parts.append(item.dictation.createdAt.formatted(date: .omitted, time: .shortened))
        return parts.joined(separator: " · ")
    }
}

/// "00:12" — minutes and seconds in mono.
func timerString(_ t: TimeInterval) -> String {
    let s = max(0, Int(t))
    return String(format: "%02d:%02d", s / 60, s % 60)
}

extension HistoryItem {
    /// Cleaned / Raw only when cleanup changed the words, not just a spoken target taken off the front.
    var showsVersionToggle: Bool { hasCleaned && !onlyPrefixRemoved }
}
