import CoreGraphics
import Foundation

// Watching (Oct 14 2026): after a dictation lands, the phone can show the picked app's window,
// live, with a few one-tap actions (scroll, Return, Esc). Only that one window, never the whole
// screen; frames go over the same encrypted link and only while the phone is looking.

/// One picture of the watched window. Sent only when it changed.
public struct WatchFrame: Codable, Sendable {
    public var seq: Int
    /// JPEG, at most ~1500 px wide.
    public var jpeg: Data
    public var width: Int
    public var height: Int
    public var appName: String
    /// The app's bundle id (the phone names its buttons by it — "Approve" in a terminal).
    public var bundleID: String?
    /// Where the place to type is, as a fraction of the window (0…1, top-left origin) — the
    /// phone centres its view on that column (Cursor's chat on the right, Claude's in the middle).
    public var focus: CGRect?
    /// A question the window is asking, read off this picture (the phone shows its answers as
    /// buttons). Nil when there's none — or from a Mac that doesn't read them.
    public var prompt: WatchPrompt?

    public init(seq: Int, jpeg: Data, width: Int, height: Int, appName: String, bundleID: String?, focus: CGRect?, prompt: WatchPrompt? = nil) {
        self.seq = seq
        self.jpeg = jpeg
        self.width = width
        self.height = height
        self.appName = appName
        self.bundleID = bundleID
        self.focus = focus
        self.prompt = prompt
    }
}

public extension WatchFrame {
    /// Whether a picture should replace the one on screen. Pictures are decoded off the main
    /// thread, so an older one can finish after a newer one: only a newer sequence number shows.
    /// A watch the Mac started over begins again at 1, and that first picture always shows.
    static func shouldShow(seq: Int, newest: Int) -> Bool {
        seq == 1 || seq > newest
    }

    /// Whether the place to type moved enough for the phone to re-centre its view. The Mac re-reads
    /// the composer's frame every few seconds and it jitters by a pixel or two as the window
    /// redraws; re-centring on every jitter made the picture jump under the finger.
    static func focusMoved(from old: CGRect?, to new: CGRect?) -> Bool {
        switch (old, new) {
        case (nil, nil): return false
        case (nil, _), (_, nil): return true
        case let (a?, b?):
            return abs(a.midX - b.midX) > 0.02 || abs(a.width - b.width) > 0.05 || abs(a.midY - b.midY) > 0.05
        }
    }
}

/// How watching is going, from the Mac's side.
public enum WatchState: Codable, Sendable, Equatable {
    /// Frames are coming.
    case live(appName: String)
    /// Screen Recording is off for Macrophone on the Mac.
    case needsPermission
    /// Nothing to show right now, in one plain sentence ("Claude isn't open on your Mac",
    /// "Claude's window is minimized").
    case unavailable(String, canReveal: Bool)
    /// The Mac stopped (asked to, or the phone went away).
    case stopped
}

/// A one-tap action on the watched window. Each brings the window forward first.
/// The phone's key row is Esc · ↑ · ↓ · Return (Oct 14 2026): the same keys in every app — move
/// through a menu, confirm, back out.
public enum WatchAction: String, Codable, Sendable, CaseIterable {
    case scrollUp
    case scrollDown
    case arrowUp
    case arrowDown
    /// Return — picks the highlighted choice in Claude Code, sends in most chat apps.
    case returnKey
    /// Esc — backs out, or stops Claude Code.
    case escape
    /// Bring the window forward (it was minimized or on another desktop).
    case reveal
    /// Open Privacy & Security › Screen Recording on the Mac.
    case openScreenRecordingSettings
}

/// How often a changed window is worth a picture (Oct 16 2026). A blinking caret or a spinner
/// changes a sliver of the window a few times a second; sending every one of those cost the
/// phone a picture, a decode and the radio every second of a "still" window. The more of the
/// window changed since the last picture, the sooner the next one goes.
public enum WatchPacing {
    /// A change this small (share of the window) is a caret or a spinner.
    public static let sliver = 0.001
    /// Under this, a line or a highlight moved.
    public static let small = 0.02
    /// A single change under this (share of the window) can't have changed the question the
    /// window asks: a caret, a spinner's glyph. A highlight moving a row is several times more.
    public static let unreadable = 0.0002

    /// The least time since the last picture before this change (the share of the window that
    /// changed since then) earns the next one. At the quick pace (video, or pictures over the home
    /// network) a real change earns one at the window stream's own rate — new output and scrolling
    /// as fast as the window moves (thirty a second for video; the stream itself gives no more,
    /// and a wait as long as its period lost every other frame to the one arriving as it ended, so
    /// the wait is half of it); a line or a highlight moving still waits, and a caret or a spinner
    /// every few seconds.
    public static func minimumInterval(changed: Double, quick: Bool = false, rate: Int = 10) -> TimeInterval {
        if changed <= 0 { return .infinity }
        if changed < sliver { return 3 }
        if changed < small { return quick ? 0.5 : 1 }
        return quick ? 0.5 / Double(max(1, rate)) : 0.3
    }
}

/// A cheap "did the window change?" for one-shot pictures (the alert lookout): a grid sample of
/// the pixels, compared with a tolerance, so a caret or a spinner doesn't count as a change.
public enum WatchChange {
    /// Every `step`th pixel on every `step`th row, as packed colour values.
    public static func sample(_ image: CGImage, step: Int = 4) -> [UInt32] {
        guard let data = image.dataProvider?.data, let base = CFDataGetBytePtr(data) else { return [] }
        let bpr = image.bytesPerRow, bpp = max(1, image.bitsPerPixel / 8)
        guard bpp >= 3, CFDataGetLength(data) >= bpr * image.height else { return [] }
        return sample(base: UnsafeRawPointer(base), width: image.width, height: image.height, bytesPerRow: bpr, bytesPerPixel: bpp, step: step)
    }

    /// The same, straight from a pixel buffer's bytes (no copy): 8-bit channels, 3 or 4 a pixel —
    /// or 1, the brightness plane of a video stream's frame (the chip encodes from it as it is).
    /// Plain loops over raw pointers: this runs for every picture the window gives, thirty a second.
    public static func sample(base: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int, bytesPerPixel: Int, step: Int = 4) -> [UInt32] {
        guard bytesPerPixel == 1 || bytesPerPixel >= 3, width > 0, height > 0, step > 0 else { return [] }
        let columns = (width + step - 1) / step, rows = (height + step - 1) / step
        let gray = bytesPerPixel == 1
        return [UInt32](unsafeUninitializedCapacity: columns * rows) { out, filled in
            var i = 0, y = 0
            while y < height {
                let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
                var x = 0
                while x < width {
                    let p = row + x * bytesPerPixel
                    out[i] = gray ? UInt32(p[0]) : UInt32(p[0]) | UInt32(p[1]) << 8 | UInt32(p[2]) << 16
                    i += 1
                    x += step
                }
                y += step
            }
            filled = i
        }
    }

    /// The share of samples that differ by more than a little in any channel (1 when the two
    /// can't be compared).
    public static func changedShare(_ a: [UInt32], _ b: [UInt32], tolerance: Int = 16) -> Double {
        guard !a.isEmpty, a.count == b.count else { return 1 }
        let t = UInt32(max(0, tolerance))
        var n = 0
        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                var i = 0
                let count = pa.count
                while i < count {
                    let x = pa[i], y = pb[i]
                    if x != y {
                        let r = x & 0xFF, g = x >> 8 & 0xFF, bl = x >> 16 & 0xFF
                        let r2 = y & 0xFF, g2 = y >> 8 & 0xFF, b2 = y >> 16 & 0xFF
                        if (r > r2 ? r - r2 : r2 - r) > t || (g > g2 ? g - g2 : g2 - g) > t || (bl > b2 ? bl - b2 : b2 - bl) > t { n += 1 }
                    }
                    i += 1
                }
            }
        }
        return Double(n) / Double(a.count)
    }
}

/// Right-click on the watched window (Oct 17 2026): a press and hold, or a two-finger tap, like
/// remote-desktop apps (Sill's long press). Only to a Mac whose welcome names the feature.
public enum WatchRightClick {
    public static let feature = "rightClick"
}

/// The Window menu (Oct 17 2026, Sameer: "a user needs to be able to resize a Mac window ... from
/// their phone"): sizes picked from a list — a drag on a phone is fiddly — laid out against the
/// edges of the screen the window is on, and the window's own minimize and close. Like Sill's
/// window lights. Only to a Mac whose welcome names the feature.
public enum WatchWindowCommand: String, Codable, Sendable, CaseIterable {
    case fill, leftHalf, rightHalf, middle, restore, minimize, close

    public static let feature = "windowCommands"

    public var title: String {
        switch self {
        case .fill: return "Fill the Screen"
        case .leftHalf: return "Left Half"
        case .rightHalf: return "Right Half"
        case .middle: return "Middle of the Screen"
        case .restore: return "Back to How It Was"
        case .minimize: return "Minimize"
        case .close: return "Close Window"
        }
    }

    public var symbol: String {
        switch self {
        case .fill: return "rectangle.inset.filled"
        case .leftHalf: return "rectangle.lefthalf.inset.filled"
        case .rightHalf: return "rectangle.righthalf.inset.filled"
        case .middle: return "rectangle.center.inset.filled"
        case .restore: return "arrow.uturn.backward"
        case .minimize: return "minus.rectangle"
        case .close: return "xmark.rectangle"
        }
    }

    /// Where a size puts the window in the screen's visible area (under the menu bar, above the
    /// Dock; top-left origin). Nil for the others.
    public func frame(in area: CGRect) -> CGRect? {
        switch self {
        case .fill: return area
        case .leftHalf: return CGRect(x: area.minX, y: area.minY, width: (area.width / 2).rounded(), height: area.height)
        case .rightHalf:
            let w = (area.width / 2).rounded()
            return CGRect(x: area.maxX - w, y: area.minY, width: w, height: area.height)
        case .middle:
            let w = (area.width * 0.66).rounded(), h = (area.height * 0.8).rounded()
            return CGRect(x: (area.midX - w / 2).rounded(), y: (area.midY - h / 2).rounded(), width: w, height: h)
        case .restore, .minimize, .close: return nil
        }
    }
}

/// Fit to iPhone (Oct 17 2026, Sameer: "an auto optimize window button that resizes the window to
/// be large and fit better in the iPhone view box"): the window takes the exact shape of the
/// phone's view of it, as tall as the screen allows, so the whole window fills the phone with
/// nothing wasted and nothing to pan to. Only to a Mac whose welcome names the feature.
public enum WatchShape {
    public static let feature = "fitPhone"

    /// The window's new frame: `aspect` (width ÷ height, the phone's view) at the full height of
    /// `area` (the screen's visible frame, top-left origin), or its full width when that's what
    /// limits it; kept centered where the window is now, inside the area.
    public static func frame(aspect: CGFloat, window now: CGRect, in area: CGRect) -> CGRect? {
        guard aspect > 0.2, aspect < 5, area.width > 0, area.height > 0 else { return nil }
        var h = area.height
        var w = (h * aspect).rounded()
        if w > area.width { w = area.width; h = (w / aspect).rounded() }
        let x = min(max(now.midX - w / 2, area.minX), area.maxX - w).rounded()
        let y = (area.minY + (area.height - h) / 2).rounded()
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
