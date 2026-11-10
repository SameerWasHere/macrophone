import SwiftUI

/// What a window view shows while its window is being fitted to it (Nov 9 2026, Sameer: "a
/// beautiful and elegant loading visual as the window selected is resized to fill the space rather
/// then render the window as it resizes and glitches its way in"): a pane of glass the room's
/// size with the app's icon and name in its middle, and a soft light of the Intelligence colours
/// travelling round its edge. `Watcher.arranging` says when; `WatchWindow` puts it up.
struct ArrangingCover: View {
    var icon: Data?
    var name: String
    var corner: CGFloat
    /// Reduce Motion: nothing moves.
    var still: Bool
    @State private var on = false
    @State private var breathe = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        ZStack {
            shape.fill(.regularMaterial)
            // The light round the edge: the gradient turning behind the hairline's own shape
            // (masked, never a gradient stroke — that draws on the CPU).
            GeometryReader { g in
                let d = max(g.size.width, g.size.height) * 1.5
                MacOSLook.intelligenceAngular
                    .frame(width: d, height: d)
                    .rotationEffect(.degrees(on && !still ? 360 : 0))
                    .position(x: g.size.width / 2, y: g.size.height / 2)
            }
            .mask(shape.strokeBorder(lineWidth: 2))
            .opacity(0.85)
            VStack(spacing: 12) {
                Group {
                    if let icon, let img = UIImage(data: icon) {
                        Image(uiImage: img).resizable().interpolation(.high).scaledToFit()
                    } else {
                        Image(systemName: "macwindow").resizable().scaledToFit().foregroundStyle(.secondary).padding(8)
                    }
                }
                .frame(width: 60, height: 60)
                .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
                .scaleEffect(still ? 1 : breathe ? 1.04 : 0.97)
                if !name.isEmpty {
                    Text(name).font(.subheadline.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(16)
        }
        .clipShape(shape)
        .accessibilityElement()
        .accessibilityLabel(name.isEmpty ? "Fitting the window to this screen" : "Fitting \(name) to this screen")
        .onAppear {
            guard !still else { return }
            withAnimation(.linear(duration: 3.2).repeatForever(autoreverses: false)) { on = true }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { breathe = true }
        }
    }
}
