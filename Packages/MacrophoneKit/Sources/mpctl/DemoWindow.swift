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
    /// An earlier exchange above the live one, so there's a page to scroll back through (a swipe
    /// on the phone shows it, line by line).
    private var lines: [String] = (1...40).map { i in
        switch i % 8 {
        case 1: return "› earlier question \(i / 8 + 1): where is the session kept?"
        case 2: return ""
        case 3: return "The session lives in SessionStore.swift, keyed by"
        case 4: return "the account id, and is refreshed on launch."
        case 5: return "● Read(SessionStore.swift)"
        case 6: return "  ⎿ 80 lines"
        default: return ""
        }
    } + [
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
    /// The window's size: narrower when the phone asked for readable text (Aa), as the Mac would
    /// resize a real one; the lines wrap to the columns that fit, like a terminal's.
    private(set) var width = 1400
    let height = 900
    /// Bumped by every change to what the window shows (`mpctl serve` draws a frame when it moved),
    /// and by one that could change the question it asks (a scroll or a click can't).
    private(set) var version = 0
    private(set) var wordsVersion = 0

    /// Readable text: the window narrower (the Mac app resizes the real window through Accessibility).
    func fit(_ f: WatchFit) {
        lock.sync {
            switch f {
            case .normal: width = 1400
            case .larger: width = 760
            case .largest: width = 540
            }
            version += 1
        }
    }

    /// One more line of the answer (until the prompt is up).
    func tick() { lock.sync { if next < script.count { lines.append(script[next]); next += 1; version += 1; wordsVersion += 1 } } }

    func apply(_ action: WatchAction) {
        lock.sync {
            version += 1
            wordsVersion += 1
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

    func click(_ p: CGPoint) { lock.sync { lastClick = p; version += 1 } }

    /// `mpctl serve --busy`: the column scrolls a few pixels every frame, like output streaming
    /// past — a window that changes all the time, for the lossy-link proof.
    private var drift = 0
    func driftStep(_ px: Int = 6) { lock.sync { drift += px; version += 1 } }
    /// The pointer (Oct 19 2026): where the phone's trackpad put it, drawn as an arrow while it's
    /// shown; a drag's path as a line; typed characters as a count in the title bar (never the
    /// words); a held key as a chip.
    private var pointerAt: CGPoint?
    private var pointerShown = false
    private var dragFrom: CGPoint?
    private var typedCount = 0
    private var heldKeys: [String] = []
    func pointer(_ p: CGPoint, shown: Bool? = nil) {
        lock.sync {
            pointerAt = p
            if let shown { pointerShown = shown }
            version += 1
        }
    }
    func drag(from: CGPoint?, to: CGPoint?) { lock.sync { dragFrom = from; if let to { pointerAt = to }; version += 1 } }
    func typed(_ t: WatchTyping) { lock.sync { typedCount = max(0, typedCount - t.delete) + t.text.count; version += 1; wordsVersion += 1 } }
    func held(_ key: String, down: Bool) {
        lock.sync {
            if down { if !heldKeys.contains(key) { heldKeys.append(key) } } else { heldKeys.removeAll { $0 == key } }
            version += 1
        }
    }

    /// A swipe: content follows the finger (dy > 0 shows earlier lines), a line at a time with the
    /// rest carried into the next step.
    private var scrollRemainder = 0.0
    func scrollBy(_ dy: Double) {
        lock.sync {
            scrollRemainder += dy * Double(height) / 38
            let whole = Int(scrollRemainder.rounded(.towardZero))
            scrollRemainder -= Double(whole)
            let was = scroll
            scroll = min(max(scroll + whole, 0), max(0, lines.count - 6))
            if scroll != was { version += 1 }
        }
    }

    /// The chat column, as a fraction of the window (the whole width once the window is narrow).
    var focus: CGRect {
        lock.sync { width < 1000 ? CGRect(x: 0.04, y: 0.1, width: 0.92, height: 0.85) : CGRect(x: 0.22, y: 0.1, width: 0.56, height: 0.85) }
    }

    /// The whole answer, up to the question (for the App Store hero's Mac screen).
    func finish() { lock.sync { while next < script.count { lines.append(script[next]); next += 1 }; version += 1; wordsVersion += 1 } }

    func png() -> Data? { image().flatMap { encode($0, type: UTType.png.identifier, quality: 1) } }
    func jpeg() -> Data? { image().flatMap { encode($0, type: UTType.jpeg.identifier, quality: 0.55) } }

    /// The window as a picture (what the Mac would capture).
    func image() -> CGImage? {
        let (shown, offset, clicked, app, title, w, drift) = lock.sync { () -> ([String], Int, CGPoint?, String, String, Int, Int) in
            var l = lines
            if asking {
                l += answers.enumerated().map { i, a in (i == highlighted ? "❯ " : "  ") + "\(i + 1). \(a)" }
            }
            if drift > 0 { l = script + l }
            return (l, scroll, lastClick, self.app, self.title, width, self.drift)
        }
        let (pointer, pointerOn, dragStart, typedN, heldNames) = lock.sync { (pointerAt, pointerShown, dragFrom, typedCount, heldKeys) }
        let h = height
        // The columns that fit (Menlo 24 is ~14.5 px a character); a longer line wraps.
        let columns = max(10, Int((Double(w) - focus.minX * Double(w) - 34) / 14.5))
        let all = shown.flatMap { line -> [String] in
            var rest = Substring(line), out: [String] = []
            repeat { out.append(String(rest.prefix(columns))); rest = rest.dropFirst(columns) } while !rest.isEmpty
            return out
        }
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
        text(title, w / 2 - 100, 36, size: 22, CGColor(gray: 0.7, alpha: 1), mono: false)
        // The column the focus rect names.
        let x0 = Int(focus.minX * Double(w)) + 10
        let lineH = 38
        let composerY = h - 130
        let visible = (composerY - 90) / lineH
        let end = all.count - offset
        let start = max(0, end - visible)
        if drift > 0, !all.isEmpty {
            // Busy: the whole window is text moving up by `drift` pixels a frame, cycling through
            // the script in three columns — a big window full of output scrolling past.
            let small = 26, rows = (h - 90) / small
            let first = drift / small, shift = drift % small
            for i in 0...rows {
                for col in 0..<3 {
                    let l = all[(first + i * 3 + col) % all.count]
                    text(String(l.prefix(40)), 16 + col * (w / 3), 80 + i * small + 20 - shift, size: 17, CGColor(gray: 0.92, alpha: 1))
                }
            }
        } else {
        for (i, l) in all[start..<end].enumerated() {
            let warm = l.hasPrefix("Do you") || l.hasPrefix("❯")
            let dim = l.hasPrefix("›") || l.hasPrefix("  ⎿") || l.hasPrefix("⎿")
            let c = warm ? CGColor(red: 0.91, green: 0.75, blue: 0.42, alpha: 1)
                : dim ? CGColor(gray: 0.6, alpha: 1) : CGColor(gray: 0.92, alpha: 1)
            text(l, x0, 100 + i * lineH + 24, size: 24, c)
        }
        }
        rect(x0 - 10, composerY, Int(focus.width * Double(w)), 80, CGColor(gray: 0.2, alpha: 1), radius: 14)
        text("Reply to \(app)…", x0 + 14, composerY + 48, size: 24, CGColor(gray: 0.45, alpha: 1), mono: false)
        if let c = clicked {
            ctx.setStrokeColor(CGColor(red: 0.35, green: 0.73, blue: 0.87, alpha: 1))
            ctx.setLineWidth(4)
            ctx.strokeEllipse(in: CGRect(x: c.x * Double(w) - 18, y: Double(h) - c.y * Double(h) - 18, width: 36, height: 36))
        }
        if typedN > 0 { text("typed \(typedN)", w - 220, 36, size: 20, CGColor(gray: 0.7, alpha: 1), mono: false) }
        if !heldNames.isEmpty { text("held: " + heldNames.joined(separator: " "), w - 420, 36, size: 20, CGColor(red: 0.91, green: 0.75, blue: 0.42, alpha: 1), mono: false) }
        if let from = dragStart, let to = pointer {
            ctx.setStrokeColor(CGColor(red: 0.37, green: 0.84, blue: 0.64, alpha: 1))
            ctx.setLineWidth(3)
            ctx.move(to: CGPoint(x: from.x * Double(w), y: Double(h) - from.y * Double(h)))
            ctx.addLine(to: CGPoint(x: to.x * Double(w), y: Double(h) - to.y * Double(h)))
            ctx.strokePath()
        }
        if pointerOn, let p = pointer {
            // An arrow, as the Mac's own pointer would be drawn into the picture.
            let x = p.x * Double(w), y = Double(h) - p.y * Double(h)
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
            ctx.setLineWidth(2)
            ctx.move(to: CGPoint(x: x, y: y))
            ctx.addLine(to: CGPoint(x: x, y: y - 28))
            ctx.addLine(to: CGPoint(x: x + 7, y: y - 21))
            ctx.addLine(to: CGPoint(x: x + 12, y: y - 32))
            ctx.addLine(to: CGPoint(x: x + 16, y: y - 30))
            ctx.addLine(to: CGPoint(x: x + 11, y: y - 19))
            ctx.addLine(to: CGPoint(x: x + 20, y: y - 19))
            ctx.closePath()
            ctx.drawPath(using: .fillStroke)
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
