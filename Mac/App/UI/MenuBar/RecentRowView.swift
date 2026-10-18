import AppKit
import MacrophoneKit

/// A recent dictation in the menu: the words in the serif (a fade instead of "…" when they run
/// long), when and where under them. Highlighted — by the pointer or the arrow keys — the row
/// lights the way a native row does and says what a click does: Copy. The click runs the menu
/// item's own action, so Return does the same.
final class RecentRowView: NSView {
    static let height: CGFloat = 42
    private let words: WordsView

    init(item: HistoryItem) {
        words = WordsView(item: item)
        super.init(frame: NSRect(x: 0, y: 0, width: MenuHeaderView.width, height: Self.height))
        words.frame = bounds
        words.autoresizingMask = [.width, .height]
        addSubview(words)
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel("Copy: \(item.dictation.text)")
        setAccessibilityHelp(MenuWords.recentMeta(item))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseUp(with event: NSEvent) {
        guard let mi = enclosingMenuItem, let menu = mi.menu else { return }
        let i = menu.index(of: mi)
        if i >= 0 { menu.performActionForItem(at: i) }
    }

    /// The menu redraws the view when its item's highlight changes. The highlight is drawn
    /// here, under the words (their own layer), so their fade never cuts into it.
    override func draw(_ dirtyRect: NSRect) {
        let on = enclosingMenuItem?.isHighlighted ?? false
        if words.highlighted != on { words.highlighted = on }
        guard on else { return }
        MenuTone.selection.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 6, yRadius: 6).fill()
    }

    /// The words themselves, drawn by hand (the fade needs a compositing operation).
    private final class WordsView: NSView {
        let item: HistoryItem
        var highlighted = false { didSet { needsDisplay = true } }
        init(item: HistoryItem) {
            self.item = item
            super.init(frame: .zero)
            // Its own layer: the fade's compositing clears these words, not the row under them.
            wantsLayer = true
        }
        required init?(coder: NSCoder) { fatalError() }
        override var isOpaque: Bool { false }

        override func draw(_ dirtyRect: NSRect) {
            let primary = highlighted ? NSColor.selectedMenuItemTextColor : NSColor.labelColor
            let secondary = highlighted ? NSColor.selectedMenuItemTextColor.withAlphaComponent(0.78) : NSColor.secondaryLabelColor
            // The words sit in the rows' title column; the trailing inset matches the leading one.
            let inset = MenuHeaderView.textX
            let width = bounds.width - inset - MenuHeaderView.inset

            // The meta line, with "Copy" on its right while the row is lit.
            let metaFont = NSFont.systemFont(ofSize: 10.5, weight: .medium)
            let metaAttrs: [NSAttributedString.Key: Any] = [.font: metaFont, .foregroundColor: secondary]
            (MenuWords.recentMeta(item) as NSString).draw(in: NSRect(x: inset, y: 6, width: width, height: 13), withAttributes: metaAttrs)
            if highlighted {
                let hint = "Copy" as NSString
                let w = ceil(hint.size(withAttributes: metaAttrs).width)
                hint.draw(in: NSRect(x: bounds.width - MenuHeaderView.inset - w, y: 6, width: w, height: 13), withAttributes: metaAttrs)
            }

            let text = item.dictation.text.replacingOccurrences(of: "\n", with: " ")
            let rtl = TextDirection.isRTL(text)
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byClipping
            para.baseWritingDirection = rtl ? .rightToLeft : .natural
            para.alignment = rtl ? .right : .natural
            let base = NSFont.systemFont(ofSize: 13)
            let font = NSFont(descriptor: base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor, size: 13) ?? base
            let textRect = NSRect(x: inset, y: 20, width: width, height: 18)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: textRect).addClip()
            (text as NSString).draw(in: textRect, withAttributes: [.font: font, .foregroundColor: primary, .paragraphStyle: para])
            NSGraphicsContext.restoreGraphicsState()

            // Fade the trailing edge rather than cut with "…". This view is its own layer, so
            // the fade clears only the words; the highlight under them shows through.
            let size = (text as NSString).size(withAttributes: [.font: font])
            if size.width > width, let ctx = NSGraphicsContext.current {
                let fadeW: CGFloat = 44
                let fadeRect = NSRect(x: rtl ? textRect.minX : textRect.maxX - fadeW, y: textRect.minY - 2, width: fadeW, height: textRect.height + 4)
                ctx.saveGraphicsState()
                ctx.compositingOperation = .destinationOut
                NSGradient(colors: [NSColor.black.withAlphaComponent(0), NSColor.black])?.draw(in: fadeRect, angle: rtl ? 180 : 0)
                ctx.restoreGraphicsState()
            }
        }
    }
}
