import SwiftUI

// The iPhone Duo's inner screen (Oct 25 2026, the fourth pass): a grid for things of one size that
// wraps to as many rows as it takes — the places in Send to, the answers floating over a window's
// foot — and keeps the fold's line clear when asked.

/// Cells of one size in rows that wrap, left to right — and, given a gutter, none across the
/// band in the middle of the width (the Duo's fold): a cell that would straddle it starts on
/// its far side. The rows read as one grid; the crease reads as the gap between two columns.
struct FoldFlow: Layout {
    var spacing: CGFloat = 8
    var rowSpacing: CGFloat = 8
    var gutter: CGFloat? = nil

    struct Cache { var frames: [CGRect] = []; var size: CGSize = .zero; var width: CGFloat = -1 }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    private func lay(_ subviews: Subviews, width: CGFloat, cache: inout Cache) {
        guard cache.width != width || cache.frames.count != subviews.count else { return }
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        // The band no cell may cross: only when there's room for a cell each side of it.
        let band: ClosedRange<CGFloat>? = gutter.flatMap { g in
            let lo = width / 2 - g / 2, hi = width / 2 + g / 2
            return lo > 40 && width - hi > 40 ? lo...hi : nil
        }
        for s in subviews {
            var size = s.sizeThatFits(.unspecified)
            // Wider than the row (a long answer): it takes the row's width and wraps its words.
            if size.width > width { size = s.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
            if let band, x < band.upperBound, x + size.width > band.lowerBound { x = band.upperBound }
            if x + size.width > width, x > 0 {
                x = 0; y += rowHeight + rowSpacing; rowHeight = 0
                if let band, x + size.width > band.lowerBound { x = band.upperBound }
            }
            frames.append(CGRect(x: x, y: y, width: size.width, height: size.height))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
        cache.frames = frames
        cache.width = width
        cache.size = CGSize(width: width, height: frames.isEmpty ? 0 : y + rowHeight)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = proposal.width ?? subviews.reduce(0) { $0 + $1.sizeThatFits(.unspecified).width + spacing }
        lay(subviews, width: max(1, width), cache: &cache)
        return cache.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        lay(subviews, width: max(1, bounds.width), cache: &cache)
        for (s, f) in zip(subviews, cache.frames) {
            s.place(at: CGPoint(x: bounds.minX + f.minX, y: bounds.minY + f.minY), proposal: ProposedViewSize(f.size))
        }
    }
}
