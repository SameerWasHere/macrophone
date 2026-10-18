import AppKit

/// The menu's first row: the phone glyph in its meaning colour, who's connected on the first
/// line and how on the second. Both lines wrap rather than cut off. Static — nothing moves.
final class MenuHeaderView: NSView {
    /// The menu's content width: the header sets it, every row follows.
    static let width: CGFloat = 320
    /// Where the words start — the rows' title column (their check mark sits in the 14…21pt
    /// strip on the left, so the glyph goes there too).
    static let textX: CGFloat = 30
    static let inset: CGFloat = 14
    /// The check-mark strip's centre.
    static let markX: CGFloat = 17.5

    init(_ h: MenuWords.Header) {
        let textW = Self.width - Self.textX - Self.inset
        let t = NSTextField(wrappingLabelWithString: h.title)
        t.font = .systemFont(ofSize: 13, weight: .semibold)
        t.textColor = .labelColor
        t.preferredMaxLayoutWidth = textW
        let tH = ceil(t.fittingSize.height)
        var d: NSTextField?
        var dH: CGFloat = 0
        if let detail = h.detail {
            let f = NSTextField(wrappingLabelWithString: detail)
            f.font = .systemFont(ofSize: 11.5)
            f.textColor = h.tone == .warning ? MenuTone.warning : .secondaryLabelColor
            f.preferredMaxLayoutWidth = textW
            dH = ceil(f.fittingSize.height)
            d = f
        }
        let height = max(44, 9 + tH + (d == nil ? 0 : 2 + dH) + 9)
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: height))
        let top = (height - (tH + (d == nil ? 0 : 2 + dH))) / 2
        // A label draws its text 2pt in from its frame: land the words on the column itself.
        t.frame = NSRect(x: Self.textX - 2, y: height - top - tH, width: textW, height: tH)
        addSubview(t)
        if let d {
            d.frame = NSRect(x: Self.textX - 2, y: height - top - tH - 2 - dH, width: textW, height: dH)
            addSubview(d)
        }

        // The glyph: one symbol in the check-mark strip, tinted by meaning, centred on the
        // title line.
        let glyph = NSImageView(frame: NSRect(x: Self.markX - 10, y: height - top - tH - 4, width: 20, height: tH + 8))
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        glyph.image = NSImage(systemSymbolName: h.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        glyph.contentTintColor = MenuTone.color(h.tone)
        glyph.imageScaling = .scaleNone
        glyph.imageAlignment = .alignCenter
        addSubview(glyph)

        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel([h.title, h.detail].compactMap { $0 }.joined(separator: ". "))
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// The menu's meaning colours (NSColor; the SwiftUI tokens are in Theme.swift).
enum MenuTone {
    /// A connected phone — the same cyan as the window's.
    static let connected = NSColor(srgbRed: 0.345, green: 0.725, blue: 0.871, alpha: 1)
    static let warning = NSColor.systemOrange
    /// The highlight a native row gets: the person's accent colour.
    /// Under the default "multicolor" setting an app's own accent (ours is teal) stands in for
    /// controlAccentColor, but a menu never wears it — the system's blue does.
    static var selection: NSColor {
        let chosen = UserDefaults.standard.object(forKey: "AppleAccentColor") != nil
        return (chosen ? NSColor.controlAccentColor : NSColor.systemBlue)
    }

    static func color(_ tone: MenuWords.Tone) -> NSColor {
        switch tone {
        case .connected: return connected
        case .waiting: return .tertiaryLabelColor
        case .warning: return warning
        }
    }
}
