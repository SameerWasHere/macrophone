import AppKit
import ApplicationServices
import QuartzCore

/// Where the words landed, shown on the Mac (Nov 4 2026, Sameer picked "your Mac shows where the
/// words landed"): a ring of Apple Intelligence's colours round the box the words went into —
/// or, round a caret, when the box is a whole document or a terminal — that blooms and fades in
/// under a second. Nothing to click, on every Space, over full-screen apps; nothing when there's
/// no place to point at.
@MainActor
enum LandingGlow {
    private static var panel: NSPanel?
    private static var shown = 0

    /// Looks for the place (off the main thread: Accessibility can be slow) and glows round it.
    static func show(app: AXUIElement, box: AXUIElement?) {
        Task {
            let spot = await Task.detached(priority: .userInitiated) { spot(app: app, box: box) }.value
            if let spot { glow(round: spot) }
        }
    }

    /// The box when it's a box (not most of a window), else the caret, in screen points from the
    /// top left (Accessibility's space).
    nonisolated static func spot(app: AXUIElement, box: AXUIElement?) -> CGRect? {
        if let box {
            let f = AX.frame(box)
            if f.width > 40, f.height > 12, f.width < 1100, f.height < 320 { return f }
        }
        guard let e = AX.focused(in: app) ?? box,
              let range = AX.attr(e, kAXSelectedTextRangeAttribute) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(e, kAXBoundsForRangeParameterizedAttribute as CFString, range, &out) == .success,
              let v = out, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CGRect.zero
        AXValueGetValue(v as! AXValue, .cgRect, &r)
        // An empty selection's bounds is the caret: a sliver. Some apps answer zero or the whole
        // field; neither points anywhere.
        guard r.height > 4, r.height < 120, r.width < 400, r.origin != .zero else { return nil }
        return CGRect(x: r.midX - 1, y: r.minY, width: 2, height: r.height)
    }

    static func glow(round axRect: CGRect) {
        // Accessibility's top-left space to AppKit's bottom-left one (the main display's height).
        guard let main = NSScreen.screens.first else { return }
        let caret = axRect.width < 6
        let target = CGRect(x: axRect.minX, y: main.frame.maxY - axRect.maxY, width: axRect.width, height: axRect.height)
            .insetBy(dx: caret ? -9 : -4, dy: caret ? -3 : -4)
        let pad: CGFloat = 18
        let frame = target.insetBy(dx: -pad, dy: -pad)

        let p = panel ?? makePanel()
        panel = p
        p.setFrame(frame, display: false)
        let view = p.contentView!
        view.layer?.sublayers?.forEach { $0.removeFromSuperlayer() }

        let ring = CGRect(x: pad, y: pad, width: target.width, height: target.height)
        let radius = caret ? ring.width / 2 : min(ring.height / 2, 10)
        let path = CGPath(roundedRect: ring, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let holder = CALayer()
        holder.frame = view.bounds
        // A wide, faint stroke for the bloom; a thin bright one for the edge.
        for (width, alpha) in [(CGFloat(12), Float(0.32)), (5, 0.55), (2, 1)] {
            let colours = CAGradientLayer()
            colours.type = .conic
            colours.colors = MacOSIntelligence.colours
            colours.startPoint = CGPoint(x: 0.5, y: 0.5)
            colours.endPoint = CGPoint(x: 0.5, y: 0)
            let side = max(view.bounds.width, view.bounds.height) * 1.5
            colours.frame = CGRect(x: view.bounds.midX - side / 2, y: view.bounds.midY - side / 2, width: side, height: side)
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -Double.pi
            spin.duration = 0.9
            colours.add(spin, forKey: "spin")
            let mask = CAShapeLayer()
            mask.path = path
            mask.fillColor = nil
            mask.strokeColor = NSColor.white.cgColor
            mask.lineWidth = width
            let stroke = CALayer()
            stroke.frame = view.bounds
            stroke.addSublayer(colours)
            stroke.mask = mask
            stroke.opacity = alpha
            holder.addSublayer(stroke)
        }
        view.layer?.addSublayer(holder)

        // Blooms out from a touch tighter than the box, then fades.
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.94
        grow.toValue = 1
        grow.duration = 0.35
        grow.timingFunction = CAMediaTimingFunction(name: .easeOut)
        holder.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        holder.frame = view.bounds
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.15, 0.45, 1]
        fade.duration = 0.9
        holder.opacity = 0
        holder.add(grow, forKey: "grow")
        holder.add(fade, forKey: "fade")

        p.orderFrontRegardless()
        shown += 1
        let mine = shown
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 950_000_000)
            if mine == shown { p.orderOut(nil) }
        }
    }

    private static func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        p.isReleasedWhenClosed = false
        let v = NSView()
        v.wantsLayer = true
        p.contentView = v
        return p
    }
}

/// Apple Intelligence's colours, the same as the phone's (`MacOSLook.intelligence`) — there and
/// back round the ring, so orange never runs straight into blue (that blend reads as grey).
enum MacOSIntelligence {
    private static let blue = NSColor(srgbRed: 0.271, green: 0.604, blue: 1.000, alpha: 1).cgColor    // #459AFF
    private static let violet = NSColor(srgbRed: 0.737, green: 0.510, blue: 0.953, alpha: 1).cgColor  // #BC82F3
    private static let pink = NSColor(srgbRed: 0.961, green: 0.447, blue: 0.718, alpha: 1).cgColor    // #F572B7
    private static let orange = NSColor(srgbRed: 1.000, green: 0.596, blue: 0.341, alpha: 1).cgColor  // #FF9857
    static let colours: [CGColor] = [blue, violet, pink, orange, pink, violet, blue]
}
