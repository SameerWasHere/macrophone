import CoreGraphics
import CoreText
import Foundation
import ImageIO
import MacrophoneKit
import UniformTypeIdentifiers

/// `mpctl serve`'s stand-in for a watched window: a drawn chat app whose answer grows a line a
/// second and ends on an approval prompt — so the phone's window view can be tried and tested
/// without a real Mac app or Screen Recording.
final class DemoWindow: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = [
        "› fix the login bug where the token expires early",
        "",
        "Looking at AuthView.swift and TokenStore.swift.",
    ]
    private let script = [
        "The token check runs before the refresh",
        "finishes, so a token that expires mid-request",
        "is treated as invalid.",
        "",
        "I'll move the check after the refresh and",
        "add a test for the expired-token case.",
        "",
        "● Update(AuthView.swift)",
        "  ⎿ 12 lines changed",
        "",
        "Do you want to make this edit to AuthView.swift?",
    ]
    /// The answers, drawn under the question until one is picked — the arrows move "❯".
    private let answers = ["Yes", "Yes, and don't ask again this session", "No, and tell Claude what to do instead"]
    private var highlighted = 0
    private var answered = false
    /// What the composer says ("Reply to Claude…") and the title bar.
    var app = "Claude"
    var title = "claude — ~/app"

    /// The question is up and not answered yet.
    private var asking: Bool { next >= script.count && !answered }
    private var next = 0
    private var scroll = 0
    /// Where the phone last clicked (a ring is drawn there, to check the mapping).
    private var lastClick: CGPoint?
    let width = 1400, height = 900

    /// One more line of the answer (until the prompt is up).
    func tick() { lock.sync { if next < script.count { lines.append(script[next]); next += 1 } } }

    func apply(_ action: WatchAction) {
        lock.sync {
            switch action {
            case .scrollUp: scroll = min(scroll + 6, max(0, lines.count - 6))
            case .scrollDown: scroll = max(0, scroll - 6)
            case .returnKey:
                if asking {
                    answered = true
                    lines.append(contentsOf: highlighted == 2
                        ? ["", "⎿ Tell Claude what to do instead"]
                        : ["", "● Approved (\(answers[highlighted])). Running the tests…", "  ⎿ 48 passed"])
                } else { lines.append("") }
            case .escape:
                if asking { answered = true }
                lines.append(contentsOf: ["", "⎿ Interrupted by user"])
            case .arrowUp: if asking { highlighted = max(0, highlighted - 1) }
            case .arrowDown: if asking { highlighted = min(answers.count - 1, highlighted + 1) }
            case .reveal, .openScreenRecordingSettings: break
            }
        }
    }

    func click(_ p: CGPoint) { lock.sync { lastClick = p } }

    /// A swipe: content follows the finger (dy > 0 shows earlier lines).
    private var scrollRemainder = 0.0
    func scrollBy(_ dy: Double) {
        lock.sync {
            scrollRemainder += dy * Double(height) / 38
            let whole = Int(scrollRemainder.rounded(.towardZero))
            scrollRemainder -= Double(whole)
            scroll = min(max(scroll + whole, 0), max(0, lines.count - 6))
        }
    }

    /// The chat column, as a fraction of the window.
    var focus: CGRect { CGRect(x: 0.22, y: 0.1, width: 0.56, height: 0.85) }

    /// The whole answer, up to the question (for the App Store hero's Mac screen).
    func finish() { lock.sync { while next < script.count { lines.append(script[next]); next += 1 } } }

    func png() -> Data? { image().flatMap { encode($0, type: UTType.png.identifier, quality: 1) } }
    func jpeg() -> Data? { image().flatMap { encode($0, type: UTType.jpeg.identifier, quality: 0.55) } }

    /// The window as a picture (what the Mac would capture).
    func image() -> CGImage? {
        let (shown, offset, clicked, app, title) = lock.sync { () -> ([String], Int, CGPoint?, String, String) in
            var l = lines
            if asking {
                l += answers.enumerated().map { i, a in (i == highlighted ? "❯ " : "  ") + "\(i + 1). \(a)" }
            }
            return (l, scroll, lastClick, self.app, self.title)
        }
        let all = shown
        let w = width, h = height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // CoreGraphics' origin is bottom-left; draw top-down by flipping y.
        func rect(_ x: Int, _ y: Int, _ rw: Int, _ rh: Int, _ c: CGColor, radius: CGFloat = 0) {
            let r = CGRect(x: x, y: h - y - rh, width: rw, height: rh)
            ctx.setFillColor(c)
            if radius > 0 { ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)); ctx.fillPath() }
            else { ctx.fill(r) }
        }
        func text(_ s: String, _ x: Int, _ y: Int, size: CGFloat, _ c: CGColor, mono: Bool = true) {
            let font = CTFontCreateWithName((mono ? "Menlo" : "Helvetica Neue") as CFString, size, nil)
            let attr = NSAttributedString(string: s, attributes: [kCTFontAttributeName as NSAttributedString.Key: font,
                                                                  kCTForegroundColorAttributeName as NSAttributedString.Key: c])
            let line = CTLineCreateWithAttributedString(attr)
            ctx.textPosition = CGPoint(x: CGFloat(x), y: CGFloat(h - y))
            CTLineDraw(line, ctx)
        }
        let bg = CGColor(red: 0.12, green: 0.12, blue: 0.13, alpha: 1)
        rect(0, 0, w, h, bg)
        rect(0, 0, w, 56, CGColor(red: 0.17, green: 0.17, blue: 0.18, alpha: 1))
        for (i, c) in [CGColor(red: 1, green: 0.37, blue: 0.34, alpha: 1), CGColor(red: 1, green: 0.74, blue: 0.18, alpha: 1),
                       CGColor(red: 0.16, green: 0.79, blue: 0.25, alpha: 1)].enumerated() {
            rect(24 + i * 34, 18, 22, 22, c, radius: 11)
        }
        text(title, 600, 36, size: 22, CGColor(gray: 0.7, alpha: 1), mono: false)
        // The column the focus rect names.
        let x0 = Int(focus.minX * Double(w)) + 10
        let lineH = 38
        let composerY = h - 130
        let visible = (composerY - 90) / lineH
        let end = all.count - offset
        let start = max(0, end - visible)
        for (i, l) in all[start..<end].enumerated() {
            let warm = l.hasPrefix("Do you") || l.hasPrefix("❯")
            let dim = l.hasPrefix("›") || l.hasPrefix("  ⎿") || l.hasPrefix("⎿")
            let c = warm ? CGColor(red: 0.91, green: 0.75, blue: 0.42, alpha: 1)
                : dim ? CGColor(gray: 0.6, alpha: 1) : CGColor(gray: 0.92, alpha: 1)
            text(l, x0, 100 + i * lineH + 24, size: 24, c)
        }
        rect(x0 - 10, composerY, Int(focus.width * Double(w)), 80, CGColor(gray: 0.2, alpha: 1), radius: 14)
        text("Reply to \(app)…", x0 + 14, composerY + 48, size: 24, CGColor(gray: 0.45, alpha: 1), mono: false)
        if let c = clicked {
            ctx.setStrokeColor(CGColor(red: 0.35, green: 0.73, blue: 0.87, alpha: 1))
            ctx.setLineWidth(4)
            ctx.strokeEllipse(in: CGRect(x: c.x * Double(w) - 18, y: Double(h) - c.y * Double(h) - 18, width: 36, height: 36))
        }
        return ctx.makeImage()
    }

    private func encode(_ image: CGImage, type: String, quality: Double) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
