import SwiftUI

/// What a window view shows while its window is being fitted to it (Nov 9 2026, Sameer: "a
/// beautiful and elegant loading visual as the window selected is resized to fill the space rather
/// then render the window as it resizes and glitches its way in", then "make the load screen looks
/// much nicer and visually interesting"). A Mac window taking shape: a pane of glass the room's
/// size with the three lights in its corner, an aurora of the Intelligence colours drifting behind
/// the glass, the app's icon in a turning halo with its name, a sheen crossing the pane and a
/// light travelling round its edge. `Watcher.arranging` says when; `WatchWindow` puts it up.
struct ArrangingCover: View {
    var icon: Data?
    var name: String
    var corner: CGFloat
    /// Reduce Motion: nothing moves.
    var still: Bool
    @State private var turn = false
    @State private var breathe = false
    @State private var drift = false
    @State private var sweep = false
    @Environment(\.colorScheme) private var scheme

    private static let colors = MacOSLook.intelligence

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: max(corner, 14), style: .continuous)
        GeometryReader { g in
            let w = g.size.width, h = g.size.height, side = min(w, h)
            ZStack {
                // The aurora: three soft lights drifting behind the glass.
                ZStack {
                    blob(Self.colors[0], side * 0.9).offset(x: (drift ? -0.22 : -0.34) * w, y: (drift ? -0.10 : -0.30) * h)
                    blob(Self.colors[1], side * 0.8).offset(x: (drift ? 0.30 : 0.18) * w, y: (drift ? -0.26 : -0.06) * h)
                    blob(Self.colors[2], side * 0.7).offset(x: (drift ? 0.08 : 0.26) * w, y: (drift ? 0.30 : 0.18) * h)
                    blob(Self.colors[3], side * 0.6).offset(x: (drift ? -0.28 : -0.10) * w, y: (drift ? 0.22 : 0.34) * h)
                }
                .opacity(scheme == .dark ? 0.55 : 0.5)
                Rectangle().fill(.ultraThinMaterial)
                // The sheen: one band of light crossing the pane.
                if !still {
                    LinearGradient(colors: [.clear, .white.opacity(scheme == .dark ? 0.10 : 0.35), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: w * 0.45)
                        .rotationEffect(.degrees(18))
                        .offset(x: (sweep ? 0.9 : -0.9) * w)
                        .blendMode(.plusLighter)
                }
                // The window's three lights, where a Mac window has them.
                HStack(spacing: 7) {
                    ForEach([MacOSLook.close, MacOSLook.minimize, MacOSLook.zoom], id: \.self) { c in
                        Circle().fill(c).frame(width: 11, height: 11)
                    }
                }
                .opacity(0.9)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.leading, 16).padding(.top, 15)
                // The app, in a turning halo.
                VStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(MacOSLook.intelligenceAngular)
                            .frame(width: 104, height: 104)
                            .rotationEffect(.degrees(turn ? 360 : 0))
                            .blur(radius: 22)
                            .opacity(breathe ? 0.75 : 0.45)
                        Group {
                            if let icon, let img = UIImage(data: icon) {
                                Image(uiImage: img).resizable().interpolation(.high).scaledToFit()
                            } else {
                                Image(systemName: "macwindow").resizable().scaledToFit().foregroundStyle(.primary.opacity(0.7)).padding(10)
                            }
                        }
                        .frame(width: 68, height: 68)
                        .shadow(color: .black.opacity(0.22), radius: 10, y: 5)
                        .scaleEffect(still ? 1 : breathe ? 1.05 : 0.97)
                    }
                    if !name.isEmpty {
                        Text(name).font(.headline).foregroundStyle(.primary.opacity(0.85)).lineLimit(1)
                    }
                }
                .padding(16)
                // The light round the edge: the gradient turning behind the hairline's own shape
                // (masked, never a gradient stroke — that draws on the CPU).
                MacOSLook.intelligenceAngular
                    .frame(width: max(w, h) * 1.5, height: max(w, h) * 1.5)
                    .rotationEffect(.degrees(turn ? 360 : 0))
                    .frame(width: w, height: h)
                    .mask(shape.strokeBorder(lineWidth: 2))
                    .opacity(0.9)
            }
            .frame(width: w, height: h)
            .clipShape(shape)
            .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
        }
        .accessibilityElement()
        .accessibilityLabel(name.isEmpty ? "Fitting the window to this screen" : "Fitting \(name) to this screen")
        .onAppear {
            guard !still else { return }
            withAnimation(.linear(duration: 3.6).repeatForever(autoreverses: false)) { turn = true }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { breathe = true }
            withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true)) { drift = true }
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: false)) { sweep = true }
        }
    }

    private func blob(_ c: Color, _ d: CGFloat) -> some View {
        Circle().fill(c).frame(width: d, height: d).blur(radius: d * 0.28)
    }
}
