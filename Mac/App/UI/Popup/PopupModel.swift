import AppKit
import SwiftUI

/// One dictation's card in the popup. The delivery engine drives its phase; the popup draws it.
@MainActor
final class PopupCard: ObservableObject, Identifiable {
    enum Phase: Equatable {
        /// Copied: the toast with a ✓.
        case copied
        /// About to paste: the countdown line runs; Cancel / Paste now.
        case countdown
        /// The keystrokes are going out (or an app is coming to the front).
        case working
        /// Pasted: the ✓ settles in mint.
        case done
        /// The person cancelled the paste.
        case cancelled
        /// Something went wrong: rose, with what to do.
        case failed
    }

    let id = UUID()
    let text: String
    let source: String
    let receivedAt: Date
    let delayed: Bool
    let isRTL: Bool

    @Published var phase: Phase
    /// The mono status line, e.g. "Pasting into Claude".
    @Published var status: String
    /// Errors: the headline. Other phases: unused.
    @Published var headline: String?
    /// A plain line under the words ("Pastes, then presses Return.", what to do on an error).
    @Published var note: String?
    /// 1 → 0 while counting down.
    @Published var remaining: Double = 1
    @Published var paused = false
    @Published var showsSettingsButton = false
    @Published var canRetry = false
    /// It landed but didn't fully happen (pasted, not sent): ochre instead of mint.
    @Published var caution = false
    var countdownSeconds: Double = 2.5
    /// Called when the countdown runs out or the person taps "Paste now".
    var onFire: () -> Void = {}
    var onCancel: () -> Void = {}
    var onRetry: () -> Void = {}

    init(text: String, source: String, receivedAt: Date = Date(), delayed: Bool, phase: Phase, status: String) {
        self.text = text
        self.source = source
        self.receivedAt = receivedAt
        self.delayed = delayed
        self.phase = phase
        self.status = status
        self.isRTL = TextDirection.isRTL(text)
    }

    /// How long the card stays once it has nothing left to do.
    var lifetime: TimeInterval {
        switch phase {
        case .copied: return 3.0
        case .done: return 2.4
        case .cancelled: return 2.6
        case .failed: return 9.0
        case .countdown, .working: return .infinity
        }
    }

    var isBusy: Bool { phase == .countdown || phase == .working }
}

/// The popup's state: the stack of cards and the panel's look.
@MainActor
final class PopupModel: ObservableObject {
    @Published var cards: [PopupCard] = []
    @Published var shown = false
    @Published var hovering = false
    /// Where the icon is, 0…1 across the panel (the stack grows out of it).
    @Published var anchorX: Double = 0.5
    @Published var reduceMotion = false
    /// The stack's height as SwiftUI laid it out (the panel is sized to it).
    @Published var contentHeight: CGFloat = 0
    /// Debug screenshots: hold everything still.
    var frozen = false

    static let maxVisible = 3
}

/// Right-to-left detection: the first strongly-directional character decides.
enum TextDirection {
    static func isRTL(_ s: String) -> Bool {
        for scalar in s.unicodeScalars {
            let v = scalar.value
            switch v {
            case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF, 0x10800...0x10FFF, 0x1E800...0x1EFFF:
                return true
            default:
                if scalar.properties.isAlphabetic { return false }
            }
        }
        return false
    }
}
