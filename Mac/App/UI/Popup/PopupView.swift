import SwiftUI

/// The popup's content: a stack of cards that grows out of the menu bar icon.
struct PopupRoot: View {
    @ObservedObject var model: PopupModel
    var dismiss: (PopupCard) -> Void

    static let cardWidth: CGFloat = 352
    static let margin: CGFloat = 40

    private var visible: [PopupCard] { Array(model.cards.prefix(PopupModel.maxVisible)) }
    private var overflow: Int { max(0, model.cards.count - PopupModel.maxVisible) }

    var body: some View {
        VStack(spacing: 8) {
            ForEach(visible) { card in
                PopupCardView(card: card, hovering: model.hovering, dismiss: { dismiss(card) })
                    .transition(cardTransition)
            }
            if overflow > 0 {
                Text("\(overflow) more in History")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Ink.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(.ultraThinMaterial))
                    .overlay(Capsule().strokeBorder(Ink.lineStrong, lineWidth: 1))
                    .transition(.opacity)
            }
        }
        .frame(width: Self.cardWidth)
        .padding(.horizontal, Self.margin)
        .padding(.top, 8)
        .padding(.bottom, Self.margin + 8)
        .background(GeometryReader { geo in
            Color.clear.preference(key: StackHeightKey.self, value: geo.size.height)
        })
        .onPreferenceChange(StackHeightKey.self) { h in
            if abs(model.contentHeight - h) > 0.5 { model.contentHeight = h }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        // Grow out of the icon; retract back into it.
        .scaleEffect(model.shown || model.reduceMotion ? 1 : 0.35, anchor: UnitPoint(x: model.anchorX, y: 0))
        .opacity(model.shown ? 1 : 0)
        .animation(model.reduceMotion ? .easeInOut(duration: 0.2) : (model.shown ? Motion.arrive : Motion.depart), value: model.shown)
        .animation(model.reduceMotion ? .easeInOut(duration: 0.2) : Motion.settle, value: model.cards.map(\.id))
        .environment(\.colorScheme, .dark)
    }

    private var cardTransition: AnyTransition {
        if model.reduceMotion { return .opacity }
        return .asymmetric(insertion: .scale(scale: 0.86, anchor: .top).combined(with: .opacity),
                           removal: .scale(scale: 0.94, anchor: .top).combined(with: .opacity))
    }
}

private struct StackHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct PopupCardView: View {
    @ObservedObject var card: PopupCard
    var hovering: Bool
    var dismiss: () -> Void
    @State private var tickShown = false
    @State private var cardHover = false

    private var accent: Color {
        switch card.phase {
        case .copied, .done: return card.delayed || card.caution ? Light.ochre : Light.mint
        case .countdown, .working: return Light.cyan
        case .cancelled: return Ink.tertiary
        case .failed: return Light.rose
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 13)
            if card.phase == .failed, let headline = card.headline {
                Text(headline)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Ink.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.top, 9)
            }
            words
                .padding(.horizontal, 16)
                .padding(.top, card.phase == .failed ? 6 : 9)
            notes
                .padding(.horizontal, 16)
                .padding(.top, 8)
            if card.phase == .countdown {
                countdownTrack
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
            }
            if card.phase == .countdown || card.phase == .failed {
                actions
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
            }
            Rectangle()
                .fill(card.phase == .countdown ? Color.clear : accent.opacity(card.phase == .failed ? 0.55 : 0.32))
                .frame(height: 1)
                .padding(.top, 12)
        }
        .frame(width: PopupRoot.cardWidth, alignment: .leading)
        .background(glass)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Ink.lineStrong, lineWidth: 1))
        .overlay(alignment: .topTrailing) { closeButton }
        .shadow(color: .black.opacity(0.38), radius: 18, x: 0, y: 10)
        .shadow(color: .black.opacity(0.25), radius: 3, x: 0, y: 1)
        .onHover { cardHover = $0 }
        .onAppear { popTick() }
        .onChange(of: card.phase) { _, _ in popTick() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(card.phase == .failed ? (card.headline ?? card.status) : card.status)
    }

    // MARK: Pieces

    private var glass: some View {
        ZStack {
            VisualEffect(material: .hudWindow)
            // Reduce Transparency / Increase Contrast: a solid card, nothing showing through.
            Ink.ground.opacity(A11y.reduceTransparency || A11y.increaseContrast ? 0.96 : 0.7)
            // A breath of the card's meaning colour at the top.
            LinearGradient(colors: [accent.opacity(0.13), .clear], startPoint: .top, endPoint: .center)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            StatusGlyph(phase: card.phase, delayed: card.delayed || card.caution, tickShown: tickShown)
                .frame(width: 22, height: 22)
            Kicker(statusLine, color: accent.opacity(card.phase == .cancelled ? 1 : 0.95), size: 10.5)
            Spacer(minLength: 8)
            // The phone's name, whole (names given on the Mac are kept short); the status line
            // beside it wraps instead.
            Text(card.source.isEmpty ? card.receivedAt.clockTime : "\(card.source)")
                .font(.system(size: 10.5))
                .foregroundStyle(Ink.tertiary)
                .fixedSize()
                .opacity(cardHover ? 0 : 1)
                .accessibilityLabel("From \(card.source)")
        }
    }

    private var statusLine: String {
        if card.phase == .countdown && (card.paused || hovering) { return "\(card.status) · paused" }
        return card.status
    }

    private var words: some View {
        // The words in New York; long ones fade out at the foot instead of being cut with "…".
        Text(card.text)
            .font(Typeface.serif(card.phase == .failed ? 13.5 : 15))
            .foregroundStyle(card.phase == .cancelled || card.phase == .failed ? Ink.secondary : Ink.ink)
            .lineSpacing(2.5)
            .multilineTextAlignment(.leading) // leading is the right edge under .rightToLeft
            .environment(\.layoutDirection, card.isRTL ? .rightToLeft : .leftToRight)
            .frame(maxWidth: .infinity, alignment: card.isRTL ? .trailing : .leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxHeight: card.phase == .failed ? 44 : 104, alignment: .top)
            .clipped()
            .mask(FadeFoot(limit: card.phase == .failed ? 44 : 104))
            .textSelection(.disabled)
    }

    @ViewBuilder private var notes: some View {
        VStack(alignment: .leading, spacing: 6) {
            if card.delayed {
                Label("Delayed — sent from your iPhone's queue", systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Light.ochre)
            }
            if let note = card.note, !note.isEmpty {
                Text(note)
                    .font(.system(size: 11.5))
                    .foregroundStyle(card.phase == .failed ? Ink.secondary : Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if card.phase == .countdown {
                Button("Cancel") { card.onCancel() }
                    .buttonStyle(PopupButtonStyle(kind: .secondary))
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(card.status.contains("Sending") ? "Send Now" : "Paste Now") { card.onFire() }
                    .buttonStyle(PopupButtonStyle(kind: .primary))
            } else {
                if card.showsSettingsButton {
                    Button("Open System Settings") {
                        NSWorkspace.shared.open(Paster.accessibilitySettingsURL)
                    }
                    .buttonStyle(PopupButtonStyle(kind: .secondary))
                }
                Spacer()
                if card.canRetry {
                    Button("Try Again") { card.onRetry() }
                        .buttonStyle(PopupButtonStyle(kind: .primary))
                }
            }
        }
    }

    /// The countdown: a thin luminous line that drains toward the leading edge.
    private var countdownTrack: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Ink.ink.opacity(0.08))
                LinearGradient(stops: Light.spectrumStops, startPoint: .leading, endPoint: .trailing)
                    .frame(width: geo.size.width)
                    .mask(alignment: .leading) {
                        Capsule().frame(width: max(2, geo.size.width * card.remaining))
                    }
                    .opacity(card.paused || hovering ? 0.55 : 1)
            }
        }
        .frame(height: 2.5)
        .accessibilityHidden(true)
    }

    private var closeButton: some View {
        Button(action: dismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(Ink.secondary)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Ink.raised))
                .overlay(Circle().strokeBorder(Ink.lineStrong, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .padding(10)
        .opacity(cardHover && card.phase != .countdown ? 1 : 0)
        .help("Dismiss")
        .accessibilityLabel("Dismiss")
    }

    private func popTick() {
        guard card.phase == .copied || card.phase == .done else { tickShown = false; return }
        tickShown = false
        let delay = Motion.reduceMotion ? 0 : 0.12
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            withAnimation(Motion.reduceMotion ? .easeOut(duration: 0.15) : Motion.pop) { tickShown = true }
        }
    }
}

/// The 22pt mark at the head of a card.
struct StatusGlyph: View {
    var phase: PopupCard.Phase
    var delayed: Bool
    var tickShown: Bool

    var body: some View {
        ZStack {
            switch phase {
            case .copied, .done:
                let c = delayed ? Light.ochre : Light.mint
                Circle().fill(c.opacity(0.16))
                Circle().strokeBorder(c.opacity(0.5), lineWidth: 1)
                Image(systemName: "checkmark")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(c)
                    .scaleEffect(tickShown ? 1 : 0.2)
                    .opacity(tickShown ? 1 : 0)
            case .countdown, .working:
                FilamentView(peak: phase == .working ? 1 : 0.7, thick: 1.6)
                    .frame(width: 22, height: 14)
            case .cancelled:
                Circle().strokeBorder(Ink.lineHeavy, lineWidth: 1)
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(Ink.secondary)
            case .failed:
                Circle().strokeBorder(Light.rose.opacity(0.7), style: StrokeStyle(lineWidth: 1.2, dash: [2.5, 2]))
                Image(systemName: "exclamationmark")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(Light.rose)
            }
        }
    }
}

/// A mask that fades the last ~22pt of a clipped block (only when it overflows).
private struct FadeFoot: View {
    var limit: CGFloat
    var body: some View {
        GeometryReader { geo in
            if geo.size.height >= limit - 0.5 {
                LinearGradient(stops: [.init(color: .black, location: 0),
                                       .init(color: .black, location: max(0, 1 - 22 / max(geo.size.height, 1))),
                                       .init(color: .clear, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            } else {
                Color.black
            }
        }
    }
}

/// The popup's two pills: the one thing to do, filled; the way out, outlined. Hover lifts a
/// step (the panel tracks the pointer though it is never key).
struct PopupButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary }
    var kind: Kind
    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, kind: kind)
    }

    private struct PillBody: View {
        let configuration: Configuration
        let kind: Kind
        @State private var hover = false
        var body: some View {
            let pressed = configuration.isPressed
            configuration.label
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(kind == .primary ? Ink.ground : Ink.ink)
                .padding(.horizontal, 13).padding(.vertical, 5.5)
                .background(Capsule().fill(kind == .primary ? Ink.ink.opacity(pressed ? 0.75 : (hover ? 1 : 0.94))
                                                             : Ink.ink.opacity(pressed ? 0.16 : (hover ? 0.11 : 0.07))))
                .overlay(Capsule().strokeBorder(kind == .primary ? Color.clear : Ink.lineHeavy, lineWidth: 1))
                .contentShape(Capsule())
                .contentShape(.focusEffect, Capsule())
                .onHover { hover = $0 }
                .animation(Motion.reduceMotion ? nil : .easeOut(duration: 0.12), value: hover)
        }
    }
}
