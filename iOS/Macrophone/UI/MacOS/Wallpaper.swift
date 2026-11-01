import SwiftUI

// The desktop behind everything (Nov 1 2026): the Mac's own wallpaper when it sends it, else a
// soft Tahoe-like field — pale sky and lilac in light, deep indigo in dark. The state's light
// (orange while the mic listens, green when the words land) washes in faintly from the foot, so
// the whole desktop answers the mic the way the old sky did.

struct DesktopWallpaper: View {
    /// The Mac's own desktop picture, when it sent one.
    var image: UIImage?
    /// The state's light; clear at rest.
    var glow: Color = .clear
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    // Glass and text read over any picture: a veil in the appearance's own ground.
                    .overlay(Ink.ground.opacity(reduceTransparency ? 0.75 : (scheme == .dark ? 0.38 : 0.30)))
                    .transition(.opacity)
            } else {
                field
            }
            RadialGradient(colors: [glow.opacity(scheme == .dark ? 0.30 : 0.22), .clear],
                           center: UnitPoint(x: 0.5, y: 1.05), startRadius: 0, endRadius: 520)
                .animation(.easeInOut(duration: 0.7), value: glow)
        }
        .animation(.easeInOut(duration: 0.5), value: image != nil)
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    @ViewBuilder private var field: some View {
        let c = scheme == .dark ? Self.dark : Self.light
        if #available(iOS 18.0, *) {
            MeshGradient(width: 3, height: 3, points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.48], [0.58, 0.42], [1, 0.55],
                [0, 1], [0.45, 1], [1, 1],
            ], colors: c)
        } else {
            LinearGradient(colors: [c[1], c[4], c[7]], startPoint: .top, endPoint: .bottom)
        }
    }

    /// Nine points of a 3 × 3 mesh, top row first.
    static let light: [Color] = [
        Color(red: 0.80, green: 0.88, blue: 1.00), Color(red: 0.86, green: 0.90, blue: 1.00), Color(red: 0.91, green: 0.86, blue: 1.00),
        Color(red: 0.74, green: 0.85, blue: 0.99), Color(red: 0.90, green: 0.88, blue: 0.99), Color(red: 0.95, green: 0.86, blue: 0.96),
        Color(red: 0.93, green: 0.94, blue: 0.99), Color(red: 0.96, green: 0.94, blue: 0.98), Color(red: 0.98, green: 0.94, blue: 0.95),
    ]
    static let dark: [Color] = [
        Color(red: 0.06, green: 0.10, blue: 0.24), Color(red: 0.08, green: 0.09, blue: 0.27), Color(red: 0.16, green: 0.08, blue: 0.30),
        Color(red: 0.04, green: 0.12, blue: 0.30), Color(red: 0.10, green: 0.08, blue: 0.26), Color(red: 0.20, green: 0.07, blue: 0.27),
        Color(red: 0.02, green: 0.03, blue: 0.08), Color(red: 0.03, green: 0.03, blue: 0.09), Color(red: 0.05, green: 0.03, blue: 0.09),
    ]
}

/// Siri's signal (Nov 1 2026): while the mic listens, the screen's edge glows in Apple
/// Intelligence's colours, breathing with the voice. It turns at 30 frames a second only while
/// the mic is open (paused otherwise, so it costs nothing at rest). Reduce Motion: a still glow.
struct EdgeGlow: View {
    var active: Bool
    /// The voice's smoothed level, 0…1.
    var level: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayCornerRadius) private var corner

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !active || reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let angle = Angle.degrees(reduceMotion ? 0 : (t * 40).truncatingRemainder(dividingBy: 360))
            let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
            let width = 3 + 9 * level
            ZStack {
                shape.strokeBorder(AngularGradient(colors: MacOSLook.intelligence, center: .center, angle: angle), lineWidth: width + 10)
                    .blur(radius: 18)
                    .opacity(0.75)
                shape.strokeBorder(AngularGradient(colors: MacOSLook.intelligence, center: .center, angle: angle), lineWidth: width)
                    .blur(radius: 4)
            }
        }
        .opacity(active ? 1 : 0)
        .animation(.easeInOut(duration: active ? 0.35 : 0.6), value: active)
        .animation(.easeOut(duration: 0.12), value: level)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct DisplayCornerRadiusKey: EnvironmentKey {
    static let defaultValue: CGFloat = 55
}

extension EnvironmentValues {
    /// The screen's own corner (the edge glow follows it); the phones of 2026 are near 55 pt.
    var displayCornerRadius: CGFloat {
        get { self[DisplayCornerRadiusKey.self] }
        set { self[DisplayCornerRadiusKey.self] = newValue }
    }
}
