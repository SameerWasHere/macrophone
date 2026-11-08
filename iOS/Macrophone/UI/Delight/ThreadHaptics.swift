import CoreHaptics
import UIKit

/// The Thread under a finger (Delight, Nov 8 2026): pulled, a faint tension that firms as it
/// stretches; let go, a twang — a sharp transient, then a buzz that dies away with the string's
/// own decay, so the hand feels what the eye sees. Core Haptics, because a decaying buzz is a
/// curve, not a tap; the engine is made on the first touch and shuts itself down when idle
/// (`isAutoShutdownEnabled`), so it costs nothing at rest. Where Core Haptics isn't there, one
/// soft tap from the app's vocabulary (`Haptics.grab`).
@MainActor
final class ThreadHaptics {
    static let shared = ThreadHaptics()

    private let supported = CHHapticEngine.capabilitiesForHardware().supportsHaptics
    private var engine: CHHapticEngine?
    private var tension: CHHapticAdvancedPatternPlayer?

    private func ready() -> CHHapticEngine? {
        guard supported else { return nil }
        if let engine { return engine }
        guard let e = try? CHHapticEngine() else { return nil }
        e.playsHapticsOnly = true
        e.isAutoShutdownEnabled = true
        e.resetHandler = { [weak e] in try? e?.start() }
        e.stoppedHandler = { _ in }
        engine = e
        return e
    }

    /// A finger took the Thread: a faint tension starts, firmed by `stretch`.
    func grab() {
        guard let e = ready() else { return }
        stopTension()
        let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.35),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.12),
        ], relativeTime: 0, duration: 12)
        do {
            try e.start()
            let p = try e.makeAdvancedPlayer(with: CHHapticPattern(events: [event], parameters: [
                CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: 0, relativeTime: 0),
            ]))
            try p.start(atTime: CHHapticTimeImmediate)
            tension = p
        } catch {
            tension = nil
        }
    }

    /// How far it's pulled, 0…1.
    func stretch(_ x: Double) {
        guard let tension else { return }
        let v = Float(min(1, max(0, x)))
        try? tension.sendParameters([
            CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: v * v * 0.9, relativeTime: 0),
        ], atTime: CHHapticTimeImmediate)
    }

    /// Let go: the twang. `strength` 0…1; `decay` the seconds the string takes to settle.
    func pluck(strength: Double, decay: Double) {
        stopTension()
        guard let e = ready() else { Haptics.grab(); return }
        let s = Float(min(1, max(0.25, strength)))
        let d = max(0.3, decay)
        let events = [
            CHHapticEvent(eventType: .hapticTransient, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.55 + 0.45 * s),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.8),
            ], relativeTime: 0),
            CHHapticEvent(eventType: .hapticContinuous, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.75 * s),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.4),
            ], relativeTime: 0.01, duration: d),
        ]
        // The buzz dies as the string does (exponential, ~5% at the end).
        let points = (0...8).map { i -> CHHapticParameterCurve.ControlPoint in
            let t = d * Double(i) / 8
            return .init(relativeTime: t, value: Float(exp(-3 * t / d)))
        }
        let curve = CHHapticParameterCurve(parameterID: .hapticIntensityControl, controlPoints: points, relativeTime: 0.01)
        do {
            try e.start()
            let p = try e.makePlayer(with: CHHapticPattern(events: events, parameterCurves: [curve]))
            try p.start(atTime: CHHapticTimeImmediate)
        } catch {}
    }

    /// The finger left without plucking (the Thread went away under it).
    func release() { stopTension() }

    private func stopTension() {
        try? tension?.stop(atTime: CHHapticTimeImmediate)
        tension = nil
    }
}
