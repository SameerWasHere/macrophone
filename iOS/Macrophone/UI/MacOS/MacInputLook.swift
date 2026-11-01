import SwiftUI

// The Mac's own input surfaces (Nov 1 2026): a Magic Keyboard's keys and a Force Touch
// trackpad's glass — white keys on silver and a silver pad in light, black keys and a space-black
// pad in dark — so the deck under the window reads as the bottom half of a MacBook.

enum MagicKeyboard {
    /// A key's top.
    static let key = Color.adaptive(light: Color(white: 0.995), dark: Color(red: 0.16, green: 0.16, blue: 0.17))
    /// A key pressed.
    static let keyDown = Color.adaptive(light: Color(white: 0.90), dark: Color(red: 0.24, green: 0.24, blue: 0.25))
    /// The legend printed on a key.
    static let legend = Color.adaptive(light: Color(white: 0.18), dark: Color(white: 0.86))
    /// The keyboard's deck round the keys (silver / space grey).
    static let deck = Color.adaptive(light: Color(red: 0.86, green: 0.87, blue: 0.89), dark: Color(red: 0.09, green: 0.09, blue: 0.10))
    /// The shadow a key casts on the deck.
    static let keyShadow = Color.adaptive(light: Color.black.opacity(0.22), dark: Color.black.opacity(0.7))
}

/// A Magic Keyboard key: a rounded top with the legend printed in SF Pro, a hairline shadow under
/// it on the deck, pressed down a point; a modifier waiting lights its own little lamp, as caps
/// lock does on a Mac.
struct MagicKey<Label: View>: View {
    var width: CGFloat
    var height: CGFloat
    var lit = false
    var pressed = false
    var small = false
    @ViewBuilder var label: () -> Label

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: small ? 5 : 7, style: .continuous)
        label()
            .font(small ? .system(size: 9, weight: .semibold) : .system(size: 14, weight: .medium))
            .foregroundStyle(MagicKeyboard.legend)
            .frame(width: width, height: height)
            .background {
                shape.fill(pressed ? MagicKeyboard.keyDown : MagicKeyboard.key)
                    .shadow(color: MagicKeyboard.keyShadow, radius: pressed ? 0 : 0.5, y: pressed ? 0 : 1)
            }
            .overlay(alignment: .topLeading) {
                // A lamp, as caps lock's: green on a Mac, here the accent.
                if lit {
                    Capsule().fill(Light.cyan).frame(width: 6, height: 3).padding(5)
                        .shadow(color: Light.cyan.opacity(0.8), radius: 3)
                }
            }
            .offset(y: pressed ? 1 : 0)
            .contentShape(shape)
    }
}

/// A Force Touch trackpad's glass: a soft gradient of aluminium (or space black), a hairline edge,
/// the faintest sheen across the top.
struct ForceTouchSurface: View {
    var corner: CGFloat = 16
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        let light = scheme == .light
        shape
            .fill(LinearGradient(colors: light ? [Color(white: 0.93), Color(white: 0.88)]
                                                : [Color(red: 0.15, green: 0.15, blue: 0.16), Color(red: 0.11, green: 0.11, blue: 0.12)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(shape.fill(LinearGradient(colors: [Color.white.opacity(light ? 0.5 : 0.06), .clear], startPoint: .top, endPoint: .center)))
            .overlay(shape.strokeBorder(light ? Color.black.opacity(0.10) : Color.white.opacity(0.10), lineWidth: 0.5))
            .shadow(color: .black.opacity(light ? 0.08 : 0.3), radius: 1, y: 1)
    }
}
