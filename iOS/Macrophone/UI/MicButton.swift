import SwiftUI

/// The one big button. Tap to start / tap to stop, or press and hold to talk (release stops).
/// The mic opens on touch-down so a hold never misses its first word.
struct MicButton: View {
    var recording: Bool
    var busy: Bool
    var meter: LevelMeter
    /// Touch-down. Return value unused; the caller decides start vs. stop.
    var onDown: () -> Void
    /// Touch-up, with how long it was held.
    var onUp: (TimeInterval) -> Void
    var onAccessibilityToggle: () -> Void

    static let holdThreshold: TimeInterval = 0.3
    @State private var pressedAt: Date?
    /// Resets itself if the system cancels the touch (a permission alert, a call banner),
    /// which never reaches onEnded — without it the button would stay "held" forever.
    @GestureState private var touching = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let size: CGFloat = 92

    var body: some View {
        ZStack {
            // The live halo follows the voice.
            if recording {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { _ in
                    let l = CGFloat(meter.level)
                    Circle()
                        .fill(RadialGradient(colors: [Light.ember.opacity(0.45), Light.ember.opacity(0)],
                                             center: .center, startRadius: size * 0.35, endRadius: size * (0.78 + 0.32 * l)))
                        .frame(width: size * 2.2, height: size * 2.2)
                        .opacity(reduceMotion ? 0.5 + 0.5 * Double(l) : 1)
                }
                .transition(.opacity)
            }
            Circle()
                .fill(recording
                      ? AnyShapeStyle(LinearGradient(colors: [Light.ember, Color(red: 0.80, green: 0.32, blue: 0.24)], startPoint: .top, endPoint: .bottom))
                      : AnyShapeStyle(LinearGradient(colors: [Color(red: 0.13, green: 0.14, blue: 0.20), Ink.raised], startPoint: .top, endPoint: .bottom)))
                .overlay(Circle().strokeBorder(recording ? Color.white.opacity(0.25) : Ink.lineStrong, lineWidth: 1))
                .overlay(
                    Circle()
                        .strokeBorder(AngularGradient(colors: [Light.cyan, Light.teal, Light.mint, Light.gold, Light.ember, Light.violet, Light.cyan], center: .center), lineWidth: 1.5)
                        .opacity(recording ? 0 : 0.55)
                        .padding(-6)
                )
                .shadow(color: (recording ? Light.ember : Light.cyan).opacity(recording ? 0.55 : 0.18), radius: recording ? 22 : 16)
                .frame(width: size, height: size)
            Group {
                if recording {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white)
                        .frame(width: 28, height: 28)
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                } else if busy {
                    ProgressView().tint(Ink.ink)
                } else {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(Ink.ink)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
        }
        .frame(width: size * 1.3, height: size * 1.25)
        .scaleEffect(pressedAt != nil ? 0.94 : 1)
        .animation(Motion.pick(Motion.snap, reduce: reduceMotion), value: pressedAt != nil)
        .animation(Motion.pick(Motion.settle, reduce: reduceMotion), value: recording)
        .contentShape(Circle().scale(0.75))
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .updating($touching) { _, state, _ in state = true }
                .onChanged { _ in
                    guard pressedAt == nil else { return }
                    pressedAt = Date()
                    onDown()
                }
                .onEnded { _ in
                    let held = pressedAt.map { Date().timeIntervalSince($0) } ?? 0
                    pressedAt = nil
                    onUp(held)
                }
        )
        .onChange(of: touching) { _, now in
            guard !now else { return }
            // Give onEnded the first word; if it never came, the touch was cancelled.
            DispatchQueue.main.async {
                guard pressedAt != nil else { return }
                pressedAt = nil
                onUp(0)   // treated as a tap: a recording it started keeps going
            }
        }
        .accessibilityElement()
        .accessibilityLabel(recording ? "Stop and send" : "Start dictation")
        .accessibilityHint(recording ? "Stops listening and sends the text to your Mac." : "Starts listening. Double-tap again to stop and send.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onAccessibilityToggle() }
    }
}
