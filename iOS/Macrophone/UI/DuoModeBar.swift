import SwiftUI

/// The laptop deck's modes — Trackpad · Mic · Keyboard — as a segmented control of their own at
/// the deck's foot, under the thumb (Nov 7 2026). They had been three bare glyphs in a glass
/// cluster laid over the trackpad's corner: unnamed, a finger's width each, and over the plate
/// they switch away from. Each segment is a glyph and a word, 44 pt tall; the lit one is a plate
/// of the accent that slides to the next. One adjustable element for VoiceOver, as the cluster was.
struct DuoModeBar: View {
    @ObservedObject var input: MacInput
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var plate

    static let height: CGFloat = 44

    /// The order on the deck: the trackpad first (where the hands are), then the mic, then the
    /// keyboard — the pages the Mac offers.
    private var modes: [MacInput.Page] {
        [.trackpad, .mic, .keyboard].filter { input.pages.contains($0) }
    }

    /// What the bar lights: the keyboard while it's up, else the page.
    private var lit: MacInput.Page { input.page }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(modes) { mode in
                segment(mode)
            }
        }
        .padding(3)
        .frame(height: Self.height)
        .watchGlass(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Input")
        .accessibilityValue(lit.title)
        .accessibilityHint("Swipe up or down for \(modes.map { $0.title.lowercased() }.joined(separator: ", ")).")
        .accessibilityAdjustableAction { direction in
            guard let i = modes.firstIndex(of: lit) else { return }
            let j = i + (direction == .increment ? 1 : -1)
            guard modes.indices.contains(j) else { return }
            pick(modes[j])
        }
        .accessibilityIdentifier("input-pages")
    }

    private func segment(_ mode: MacInput.Page) -> some View {
        let on = mode == lit
        return Button { pick(mode) } label: {
            HStack(spacing: 6) {
                Image(systemName: mode.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 22)
                Text(mode.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(on ? Ink.onTint : Ink.ink)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 12)
            .background {
                if on {
                    Capsule().fill(Light.cyan)
                        .matchedGeometryEffect(id: "plate", in: plate)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("input-mode-\(mode.rawValue)")
    }

    private func pick(_ mode: MacInput.Page) {
        guard mode != input.page else { return }
        withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.85)) {
            input.show(mode)
        }
    }
}
