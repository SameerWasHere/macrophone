import SwiftUI

// No "…" anywhere (Nov 10 2026). Sameer: "The dot dot dot should never happen anywhere in the app."
//
// SwiftUI ends any text that doesn't fit with an ellipsis, and has no switch for it. So nothing in
// the app says `lineLimit` on its own any more:
//
// - words the app writes itself (a status, a caption, a hint) are never limited — they wrap, and
//   their row grows or they're worded to fit;
// - a name that comes from the Mac (an app, a window's title, the Mac's own name) can be any
//   length, so it gets `oneLine()` or `lines(_:)`: whole when it fits, a little smaller when that's
//   all it takes, and past that it runs out under a soft fade at the edge — the way a title runs
//   under the edge of a Mac's tab — never three dots.
//
// (The "…" in "Connecting…", "Listening…" or "Open…" is punctuation the app writes, not a cut.)

extension View {
    /// One line that never ends in "…": whole when it fits, shrunk to `shrink` at most when that
    /// makes it fit, else clipped under a fade at `edge` (the far end by default; `.leading` for
    /// words whose newest end must stay in sight).
    func oneLine(fading edge: HorizontalEdge = .trailing, shrink: CGFloat = 0.85) -> some View {
        modifier(OneLineNoDots(edge: edge, shrink: shrink))
    }

    /// `oneLine()` only when `on`; otherwise as many lines as it takes.
    @ViewBuilder func oneLine(if on: Bool, shrink: CGFloat = 0.85) -> some View {
        if on { oneLine(shrink: shrink) } else { fixedSize(horizontal: false, vertical: true) }
    }

    /// Up to `count` lines that never end in "…": it wraps, and past `count` lines the last one
    /// runs out under a fade.
    func lines(_ count: Int) -> some View {
        modifier(LinesNoDots(count: max(1, count)))
    }
}

private struct OneLineNoDots: ViewModifier {
    var edge: HorizontalEdge
    var shrink: CGFloat
    /// The words' own width, and the room they have.
    @State private var ideal: CGFloat = 0
    @State private var room: CGFloat = 0

    func body(content: Content) -> some View {
        let over = ideal > room + 0.5 && room > 0
        let scale = over ? max(shrink, min(1, room / max(ideal, 1))) : 1
        let cut = over && ideal * scale > room + 0.5
        // The layout is the plain (cut, hidden) line's: as wide as the words or the room,
        // whichever is less. What's drawn is the whole line laid over it.
        content
            .lineLimit(1)
            .hidden()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { room = $0 }
            .overlay(alignment: edge == .trailing ? .leading : .trailing) {
                content
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { ideal = $0 }
                    .scaleEffect(scale, anchor: edge == .trailing ? .leading : .trailing)
            }
            .clipped()
            .mask {
                if cut {
                    LinearGradient(stops: [.init(color: .black, location: 0.8), .init(color: .clear, location: 1)],
                                   startPoint: edge == .trailing ? .leading : .trailing,
                                   endPoint: edge == .trailing ? .trailing : .leading)
                } else {
                    Rectangle()
                }
            }
    }
}

private struct LinesNoDots: ViewModifier {
    var count: Int
    @State private var natural: CGFloat = 0
    @State private var room: CGFloat = 0

    func body(content: Content) -> some View {
        let cut = natural > room + 1 && room > 0
        content
            .lineLimit(count)
            .hidden()
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { room = $0 }
            .overlay(alignment: .top) {
                content
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { natural = $0 }
            }
            .clipped()
            .mask {
                if cut {
                    // Every line but the last whole; the last runs out toward its end.
                    VStack(spacing: 0) {
                        Rectangle().frame(height: room * CGFloat(count - 1) / CGFloat(count))
                        LinearGradient(stops: [.init(color: .black, location: 0.7), .init(color: .clear, location: 1)],
                                       startPoint: .leading, endPoint: .trailing)
                    }
                } else {
                    Rectangle()
                }
            }
    }
}
