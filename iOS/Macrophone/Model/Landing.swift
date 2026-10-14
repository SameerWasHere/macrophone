import Foundation
import MacrophoneKit

/// Where a dictation finally landed on the Mac, after its countdown and the paste — the Mac's
/// `landed` message, in the words the phone shows (Oct 13 2026). The Mac's ack only says it got
/// the words; this says whether they reached the app they were meant for.
struct Landing: Equatable {
    var result: LandingResult
    /// The Mac's own line: "Sent to Claude", "Claude isn't open — copied instead",
    /// "The message box in Claude wasn't found".
    var detail: String
    /// Where it was meant to go (nil for the oldest dictations: the clipboard).
    var target: TargetRef?
    var to: RouteNote?
    /// It came through the offline queue.
    var late = false

    /// The place, by name: "Claude", "Where I'm typing", "Clipboard".
    var name: String { to?.name ?? target?.displayName ?? "your Mac" }

    private var toClipboard: Bool {
        guard let target else { return true }
        if case .clipboard = target { return true }
        return false
    }

    /// It went where it was meant to: sent or pasted into the app, or onto the clipboard when
    /// that was the place.
    var isSuccess: Bool {
        switch result {
        case .sent, .pasted: return true
        case .copied: return toClipboard
        case .cancelled, .failed: return false
        }
    }

    /// Copied to the Mac's clipboard instead of the app it was meant for (ochre, not rose).
    var copiedInstead: Bool { result == .copied && !toClipboard }

    private var macLine: String {
        var d = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        while d.hasSuffix(".") { d.removeLast() }
        return d
    }

    /// The status line under the mic: what happened and, when it didn't land, what to do.
    var sentence: String {
        var s: String
        switch result {
        case .sent:
            s = "In \(name) — sent"
        case .pasted:
            // The Mac's line says more when there's more ("Pasted into Claude — still in the message box").
            s = macLine.hasPrefix("Pasted into") ? macLine : "Pasted into \(name)"
        case .copied where toClipboard:
            s = "On your Mac's clipboard"
        case .copied:
            let why = macLine.isEmpty ? "Didn't land in \(name) — copied instead" : macLine
            s = "\(why). Press ⌘V on your Mac where you want it"
        case .cancelled:
            s = "Cancelled on your Mac — nothing was pasted"
        case .failed:
            s = Self.didntLand(name, macLine)
            if !macLine.localizedCaseInsensitiveContains("clipboard") { s += ". It's on your Mac's clipboard" }
        }
        if isSuccess, let spoken = to?.spoken { s += " — you said “\(spoken)” first" }
        if late, isSuccess { s += " · delayed" }
        return s
    }

    /// "Didn't land in Claude — the message box wasn't found", unless the Mac already said so.
    static func didntLand(_ name: String, _ line: String) -> String {
        if line.isEmpty { return "Didn't land in \(name)" }
        let lower = line.lowercased()
        if lower.hasPrefix("didn't") || lower.hasPrefix("not ") || lower.hasPrefix("nothing") { return line }
        // "The message box in Claude wasn't found" → "the message box wasn't found".
        var rest = line.replacingOccurrences(of: " in \(name) ", with: " ")
        if let first = rest.split(separator: " ").first, ["The", "That", "Nowhere", "No"].contains(String(first)) {
            rest = rest.prefix(1).lowercased() + rest.dropFirst()
        }
        return "Didn't land in \(name) — \(rest)"
    }

    /// The history row's chip: "Sent to Claude", "Pasted into Claude", "On your Mac's clipboard",
    /// "Didn't land: …".
    var chip: String {
        switch result {
        case .sent: return "Sent to \(name)"
        case .pasted: return macLine.hasPrefix("Pasted into") ? macLine : "Pasted into \(name)"
        case .copied where toClipboard: return "On your Mac's clipboard"
        case .copied: return "Didn't land: \(macLine.isEmpty ? "copied instead" : macLine)"
        case .cancelled: return "Didn't land: cancelled on your Mac"
        case .failed: return "Didn't land: \(macLine.isEmpty ? "not pasted" : macLine)"
        }
    }
}
