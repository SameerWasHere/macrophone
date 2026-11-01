import SwiftUI

// Setup Assistant (Nov 1 2026, docs/DESIGN.md "Macrophone, as Apple would make it"): a big
// symbol, a large bold title, a short body, the one prominent button pinned at the foot with a
// quiet text button under it — the way an iPhone sets itself up. Every onboarding step and every
// pairing phase is one of these pages.

struct SetupPage<Hero: View, Content: View, Buttons: View>: View {
    var title: String
    var message: String?
    /// An SE-class height: a smaller hero and title so the buttons stay in view.
    var compact = false
    var hero: Hero
    var content: Content
    var buttons: Buttons

    init(title: String, message: String? = nil, compact: Bool = false,
         @ViewBuilder hero: () -> Hero, @ViewBuilder content: () -> Content = { EmptyView() },
         @ViewBuilder buttons: () -> Buttons = { EmptyView() }) {
        self.title = title
        self.message = message
        self.compact = compact
        self.hero = hero()
        self.content = content()
        self.buttons = buttons()
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                hero
                    .padding(.top, compact ? 8 : 28)
                    .padding(.bottom, compact ? 14 : 24)
                Text(title)
                    .font(compact ? .title.bold() : .largeTitle.bold())
                    .foregroundStyle(Ink.ink)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let message {
                    Text(message)
                        .font(compact ? .callout : .body)
                        .foregroundStyle(Ink.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 12)
                }
                content
                    .padding(.top, compact ? 18 : 28)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .setupFoot {
            VStack(spacing: 4) { buttons }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, compact ? 4 : 10)
        }
    }
}

/// The hero: one SF Symbol, big, in its colour (hierarchical, as Setup Assistant draws them; a
/// warning in its own multicolour yellow).
struct SetupSymbol<S: ShapeStyle>: View {
    var name: String
    var style: S
    var compact = false
    var rendering: SymbolRenderingMode = .hierarchical

    var body: some View {
        Image(systemName: name)
            .font(.system(size: compact ? 60 : 84, weight: .regular))
            .symbolRenderingMode(rendering)
            .foregroundStyle(style)
            .frame(height: compact ? 76 : 108)
            .accessibilityHidden(true)
    }
}

/// The primary button: full width, a capsule in the accent, pinned at the page's foot.
struct SetupButton: View {
    var title: String
    var action: () -> Void
    init(_ title: String, action: @escaping () -> Void) { self.title = title; self.action = action }

    var body: some View {
        Button(action: action) { Text(title).frame(maxWidth: .infinity) }
            .setupPrimary()
    }
}

/// Setup Assistant's Continue before Liquid Glass (iOS 17–25): 52 pt of the accent in a capsule,
/// the label white and semibold; pressed, it dims a little; disabled, it greys.
struct SetupButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorSchemeContrast) private var contrast

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .multilineTextAlignment(.center)
            .foregroundStyle(enabled ? Ink.onTint : Ink.secondary)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .frame(minHeight: 52)
            .background(Capsule().fill(enabled ? Light.cyan : Ink.faint))
            .overlay { if contrast == .increased { Capsule().strokeBorder(Ink.ink.opacity(0.4), lineWidth: 1) } }
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(Motion.snap, value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

extension View {
    /// A button as Setup Assistant's Continue: a prominent capsule in the accent (Liquid Glass on
    /// iOS 26+, `SetupButtonStyle` below), headline type, full width when its label asks for it.
    @ViewBuilder func setupPrimary() -> some View {
        if #available(iOS 26.0, *) {
            font(.headline).buttonStyle(.glassProminent).buttonBorderShape(.capsule).controlSize(.extraLarge).tint(Light.cyan)
        } else {
            buttonStyle(SetupButtonStyle())
        }
    }

    /// The quiet one under it: accent text, no plate.
    func setupSecondary() -> some View {
        font(.body).buttonStyle(.borderless).tint(Light.cyan).frame(minHeight: 44)
    }

    /// Pins buttons to the foot of a scrolling page: a bar the content scrolls under (the system's
    /// edge effect on iOS 26+, the bar material below).
    @ViewBuilder func setupFoot<Foot: View>(@ViewBuilder _ foot: () -> Foot) -> some View {
        let f = foot()
        if #available(iOS 26.0, *) {
            safeAreaBar(edge: .bottom) { f }
        } else {
            safeAreaInset(edge: .bottom) { f.background(.bar) }
        }
    }
}
