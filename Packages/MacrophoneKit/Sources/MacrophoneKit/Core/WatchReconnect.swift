import CoreGraphics
import Foundation

// A dropped connection keeps the picture (Nov 5 2026). When the link to the Mac blips while a
// window shows — a Wi-Fi hiccup, the app away for a moment, the Mac's session starting over, the
// move home or away — the phone does what FaceTime and Screen Sharing do: the last frame stays,
// a shade darker, under one calm word, input held off; when the link is back the same window
// comes back in place (the same zoom, the same spot, the same input page) and its first frame
// takes over with no dissolve. Only a link gone for `limit` says it isn't connected.

public enum WatchReconnect {
    /// How long the last picture holds while the link comes back; after it the window says the
    /// Mac isn't connected (and still comes back the moment it is).
    public static let limit: TimeInterval = 25
    /// The link is back but the Mac hasn't answered the watch: after this the window shows it's
    /// opening, as any watch does.
    public static let answerWait: TimeInterval = 10
    /// A drop shorter than this shows nothing over the picture (a hiccup, a quick return to the
    /// app: the link is made again in ~0.4 s).
    public static let quietFor: TimeInterval = 0.5

    /// The same window at another resolution (home ↔ away the video is 2,560 ↔ 1,600 px wide):
    /// its shape within `tolerance` (the encoder rounds each side to an even number).
    public static func sameShape(_ a: CGSize, _ b: CGSize, tolerance: CGFloat = 0.015) -> Bool {
        guard a.width > 0, a.height > 0, b.width > 0, b.height > 0 else { return false }
        let ra = a.width / a.height, rb = b.width / b.height
        return abs(ra - rb) / ra <= tolerance
    }

    /// The zoom that draws the new picture as large on screen as the old one was at `zoom`: the
    /// view stays where it was, only sharper or softer.
    public static func carriedZoom(_ zoom: CGFloat, from old: CGSize, to new: CGSize) -> CGFloat {
        guard old.width > 0, new.width > 0 else { return zoom }
        return zoom * old.width / new.width
    }
}
