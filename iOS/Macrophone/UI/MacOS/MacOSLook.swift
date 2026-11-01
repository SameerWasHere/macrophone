import SwiftUI
import UIKit

// The macOS pieces on the iPhone (Nov 1 2026, Sameer: "imagine if Apple built a Mac controller for
// the iPhone and iPhone Duo"): the measures and colours that are the Mac's own — the traffic
// lights, Tahoe's radii, the desktop's wallpaper, Apple Intelligence's light. Everything else is
// the system's (docs/DESIGN.md, the top section).

enum MacOSLook {
    // MARK: Radii (macOS Tahoe)
    /// A window's corners.
    static let window: CGFloat = 16
    /// The Dock's shelf.
    static let dock: CGFloat = 24
    /// A desktop widget.
    static let widget: CGFloat = 22
    /// A Control Center module.
    static let module: CGFloat = 18
    /// An app icon's squircle, as a share of its side (Apple's grid: 22.37%).
    static let iconCorner: CGFloat = 0.2237

    // MARK: The menu bar
    /// The strip's height under the status bar: a Mac's is 24 pt, but a finger needs iOS's 44.
    static let menuBar: CGFloat = 44
    /// A menu extra's glyph.
    static let extraGlyph: CGFloat = 15

    // MARK: The traffic lights
    static let lightSize: CGFloat = 12
    static let lightGap: CGFloat = 8
    static let close = Color(red: 1.000, green: 0.373, blue: 0.341)     // #FF5F57
    static let minimize = Color(red: 0.996, green: 0.737, blue: 0.180)  // #FEBC2E
    static let zoom = Color(red: 0.157, green: 0.784, blue: 0.251)      // #28C840
    /// A light's rim, a shade darker (the Mac draws one so they read on a light title bar).
    static func rim(_ c: Color) -> Color { c.blended(with: .black, 0.18) }

    // MARK: Apple Intelligence
    /// The glow Siri and Writing Tools wear: blue · purple · pink · orange, round and back to blue.
    static let intelligence: [Color] = [
        Color(red: 0.271, green: 0.604, blue: 1.000),  // #459AFF
        Color(red: 0.737, green: 0.510, blue: 0.953),  // #BC82F3
        Color(red: 0.961, green: 0.447, blue: 0.718),  // #F572B7
        Color(red: 1.000, green: 0.596, blue: 0.341),  // #FF9857
        Color(red: 0.271, green: 0.604, blue: 1.000),
    ]
    static var intelligenceAngular: AngularGradient {
        AngularGradient(colors: intelligence, center: .center)
    }
}

extension Color {
    /// This colour toward another (a rim, a pressed shade), in both appearances.
    func blended(with other: Color, _ t: Double) -> Color {
        Color(UIColor { traits in
            let a = UIColor(self).resolvedColor(with: traits), b = UIColor(other).resolvedColor(with: traits)
            var (r1, g1, b1, a1): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
            var (r2, g2, b2, a2): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
            a.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
            b.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
            let k = CGFloat(t)
            return UIColor(red: r1 + (r2 - r1) * k, green: g1 + (g2 - g1) * k, blue: b1 + (b2 - b1) * k, alpha: a1 + (a2 - a1) * k)
        })
    }

    /// One colour in light, another in dark.
    static func adaptive(light: Color, dark: Color) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light) })
    }
}

/// An app icon's shape: Apple's continuous squircle at a given side.
struct AppIconShape: InsettableShape {
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        return RoundedRectangle(cornerRadius: min(r.width, r.height) * MacOSLook.iconCorner, style: .continuous).path(in: r)
    }

    func inset(by amount: CGFloat) -> AppIconShape {
        var s = self
        s.inset += amount
        return s
    }
}
