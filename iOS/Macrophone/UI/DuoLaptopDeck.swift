import MacrophoneKit
import SwiftUI

// The iPhone Duo's inner screen as a little MacBook (Oct 30 2026, Sameer: "really want to nail
// the laptop fold view and almost make the duo function like a mini laptop"). While a window
// shows, the deck is a laptop's lower half — everything at once, no pages to swipe between:
//
//   ┌──────────────┬──────────────────────────────┬─────────────────────┐
//   │ SEND TO ⌄    │                              │ esc  ⇥   ⌫   ⌨︎     │
//   │ Terminal     │          the trackpad        │ ⌘   ⌥   ⌃   ⇧      │
//   │              │                              │ return  ⏎           │
//   │   ( mic )    │                              │ fn   ◀  ▲▼  ▶      │
//   │ Ready        │                              │                     │
//   └──────────────┴──────────────────────────────┴─────────────────────┘
//
// — that was the laptop's deck; since Nov 1 2026 the laptop's deck is one mode at a time, each
// the whole half (`DuoDeck.laptopModes`), and this is the column down the book's page and the
// open screen's right page (the keys, the trackpad, Send to and the mic under the thumb). The
// pointer is always live; the keycaps press in the window shown; ⌘ ⌥ ⌃ ⇧ light up and go on the
// next key or click; ⌨︎ brings the whole keyboard up over the deck (hide comes back here); the
// Send to menu picks another app and shows its window, so the grid of places is only there when
// no window is.

enum DeckLook {
    static let key: CGFloat = 46
    static let keyHeight: CGFloat = 40
    static let gap: CGFloat = 6
    static let cap: CGFloat = 10
    /// The keys' block: four across.
    static var block: CGFloat { 4 * key + 3 * gap }
}

struct DuoLaptopDeck: View {
    let main: MainView
    /// Down a column (the book's page, the open screen's right page).
    var vertical = true
    @ObservedObject private var watcher: Watcher
    @ObservedObject private var input: MacInput
    @EnvironmentObject private var model: AppModel

    init(main: MainView, vertical: Bool = true) {
        self.main = main
        self.vertical = vertical
        _watcher = ObservedObject(wrappedValue: main.watcher)
        _input = ObservedObject(wrappedValue: main.watcher.input)
    }

    var body: some View {
        column
        .padding(12)
        // The field that takes the iOS keyboard when ⌨︎ is pressed (a clear point, never seen).
        .background(alignment: .topLeading) { KeyboardPage(input: input, watcher: watcher).frame(width: 1, height: 1) }
        // It arrives with the layout that holds it (the hand-over's fade), never on a beat of its
        // own after — the page beside the window stood empty for a moment (Nov 4 2026).
        .onAppear { keepTrackpad() }
        // The deck's page is the trackpad: the pointer always live (the keyboard is the moment
        // it's up; the mic needs no page here).
        .onChange(of: input.page) { _, _ in keepTrackpad() }
        .onChange(of: input.pages) { _, _ in keepTrackpad() }
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("The deck: trackpad, keys and mic")
    }

    private func keepTrackpad() {
        if input.page == .mic, input.pages.contains(.trackpad) { input.show(.trackpad, quiet: true) }
    }

    // MARK: Layout

    private var column: some View {
        VStack(spacing: 12) {
            GeometryReader { g in
                DeckKeys(input: input, watcher: watcher, width: min(64, (g.size.width - 3 * DeckLook.gap) / 4))
                    .frame(width: g.size.width)
            }
            .frame(height: 4 * DeckLook.keyHeight + 3 * DeckLook.gap)
            pad
            HStack(spacing: 12) {
                DeckSendTo(watcher: watcher).frame(maxWidth: .infinity, alignment: .leading)
                main.micButton(size: 72)
            }
            StatusLine(recorder: main.recorder, holding: main.holding, font: .caption)
                .frame(height: 20)
        }
    }

    @ViewBuilder private var pad: some View {
        // Done puts the pages away as the deck fades: it fades as the trackpad it was, never as
        // the note for a Mac without one (that flashed up on every Done — Nov 4 2026).
        if input.pages.contains(.trackpad) || !watcher.isShowing {
            // The stacks beside it keep their own gap: the plate runs to it (no inset of its own).
            TrackpadPage(input: input, watcher: watcher, big: true, inset: 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            RoundedRectangle(cornerRadius: WatchLook.bezel, style: .continuous)
                .strokeBorder(Ink.line, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .overlay(Text("Your Mac's version has no trackpad yet").font(.footnote).foregroundStyle(Ink.tertiary))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: The keys

/// A MacBook's right hand: esc ⇥ ⌫ ⌨︎, the modifiers, return, fn and the inverted-T arrows.
struct DeckKeys: View {
    @ObservedObject var input: MacInput
    @ObservedObject var watcher: Watcher
    var width: CGFloat

    var body: some View {
        let g = DeckLook.gap, h = DeckLook.keyHeight
        VStack(spacing: g) {
            HStack(spacing: g) {
                cap("esc", key: WatchKey("escape"), name: "Escape")
                cap("⇥", key: WatchKey("tab"), name: "Tab")
                cap(Image(systemName: "delete.left"), key: WatchKey("delete"), name: "Delete", repeats: true)
                Button { input.show(.keyboard) } label: { Image(systemName: "keyboard") }
                    .buttonStyle(KeycapStyle(width: width, tint: Light.cyan))
                    .disabled(!input.pages.contains(.keyboard))
                    .accessibilityLabel("Keyboard")
                    .accessibilityHint("Brings up the keyboard to type into \(watcher.name).")
                    .accessibilityIdentifier("deck-keyboard")
            }
            HStack(spacing: g) {
                ForEach(WatchModifier.allCases, id: \.self) { m in modifier(m) }
            }
            Button { input.press(WatchKey("return")) } label: {
                HStack(spacing: 8) { Text("return"); Image(systemName: "return") }
            }
            .buttonStyle(KeycapStyle(width: 4 * width + 3 * g))
            .accessibilityLabel("Return")
            .accessibilityIdentifier("deck-return")
            HStack(alignment: .bottom, spacing: g) {
                DeckFnKey(input: input, width: width)
                arrow("left", "arrowtriangle.left.fill", "Left arrow", height: h)
                VStack(spacing: 2) {
                    arrow("up", "arrowtriangle.up.fill", "Up arrow", height: (h - 2) / 2)
                    arrow("down", "arrowtriangle.down.fill", "Down arrow", height: (h - 2) / 2)
                }
                arrow("right", "arrowtriangle.right.fill", "Right arrow", height: h)
            }
        }
        .fixedSize()
    }

    private func cap(_ label: String, key: WatchKey, name: String) -> some View {
        Button { input.press(key) } label: { Text(label) }
            .buttonStyle(KeycapStyle(width: width))
            .accessibilityLabel(name)
            .accessibilityIdentifier("deck-\(key.key)")
    }

    private func cap(_ label: Image, key: WatchKey, name: String, repeats: Bool) -> some View {
        RepeatKeycap(label: label, name: name, width: width, height: DeckLook.keyHeight) { input.press(key) }
            .accessibilityIdentifier("deck-\(key.key)")
    }

    private func arrow(_ key: String, _ symbol: String, _ name: String, height: CGFloat) -> some View {
        RepeatKeycap(label: Image(systemName: symbol), name: name, width: width, height: height, small: height < DeckLook.keyHeight) {
            input.press(WatchKey(key))
        }
        .accessibilityIdentifier("deck-\(key)")
    }

    private func modifier(_ m: WatchModifier) -> some View {
        let on = input.modifiers.contains(m) || (m == .command && input.switching)
        return Button { input.toggle(m) } label: { Text(m.glyph) }
            .buttonStyle(KeycapStyle(width: width, lit: on))
            .accessibilityLabel(m.name)
            .accessibilityValue(on ? "on" : "off")
            .accessibilityHint("Goes on the next key or the next click.")
            .accessibilityIdentifier("deck-\(m.rawValue)")
    }
}

/// A keycap: a Magic Keyboard key (white on silver in light, black on space grey in dark, Nov 1
/// 2026) that presses in, lit in the accent when a modifier waits.
struct KeycapStyle: ButtonStyle {
    var width: CGFloat
    var height: CGFloat = DeckLook.keyHeight
    var lit = false
    var tint: Color = MagicKeyboard.legend
    var small = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        Keycap(width: width, height: height, lit: lit, pressed: configuration.isPressed, small: small) {
            configuration.label.foregroundStyle(lit ? Ink.onTint : tint)
        }
        .opacity(enabled ? 1 : 0.4)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct Keycap<Label: View>: View {
    var width: CGFloat
    var height: CGFloat
    var lit: Bool
    var pressed: Bool
    var small = false
    @ViewBuilder var label: () -> Label

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: small ? 7 : DeckLook.cap, style: .continuous)
        label()
            .font(small ? .system(size: 9, weight: .semibold) : .system(size: 15, weight: .medium))
            .frame(width: width, height: height)
            .background {
                ZStack {
                    shape.fill(lit ? AnyShapeStyle(Light.cyan) : AnyShapeStyle(pressed ? MagicKeyboard.keyDown : MagicKeyboard.key))
                    shape.strokeBorder(lit ? Light.cyan.opacity(0.6) : Ink.ink.opacity(0.08), lineWidth: 0.5)
                }
                // The key's own shadow on the deck, gone as it presses in.
                .shadow(color: MagicKeyboard.keyShadow, radius: pressed ? 0 : 0.6, y: pressed ? 0 : 1)
                // A backlight under a lit modifier.
                .shadow(color: lit ? Light.cyan.opacity(0.55) : .clear, radius: 10)
            }
            .scaleEffect(pressed ? 0.94 : 1)
            .offset(y: pressed ? 1 : 0)
            .contentShape(shape)
    }
}

/// A keycap that repeats while held (the arrows, delete): one press on touch-down, then, past
/// 0.4 s, one every 70 ms until the finger lifts.
struct RepeatKeycap: View {
    var label: Image
    var name: String
    var width: CGFloat
    var height: CGFloat
    var small = false
    var press: () -> Void
    @State private var holding = false
    @State private var timer: Timer?

    var body: some View {
        Keycap(width: width, height: height, lit: false, pressed: holding, small: small) { label.foregroundStyle(Ink.ink) }
            .animation(.easeOut(duration: 0.1), value: holding)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !holding else { return }
                    holding = true
                    press()
                    timer?.invalidate()
                    timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { _ in
                        timer = Timer.scheduledTimer(withTimeInterval: 0.07, repeats: true) { _ in press() }
                    }
                }
                .onEnded { _ in stop() })
            .onDisappear { stop() }
            .accessibilityElement()
            .accessibilityLabel(name)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { press() }
    }

    private func stop() {
        holding = false
        timer?.invalidate()
        timer = nil
    }
}

/// fn: F1–F20, Home, End, the pages, and the Mac's own moves — the keyboard bar's menu.
struct DeckFnKey: View {
    @ObservedObject var input: MacInput
    var width: CGFloat

    var body: some View {
        Menu {
            Section(WatchKey.macSection.title) {
                ForEach(WatchKey.macSection.keys) { k in
                    Button { if k == .appSwitcher { input.switchApp() } else { input.press(k) } } label: { Text(k.title); Text(k.glyph) }
                }
            }
            Section("Function keys") {
                ForEach(0..<4, id: \.self) { row in
                    ControlGroup {
                        ForEach(MacKeys.functionKeys[(row * 5)..<min(row * 5 + 5, MacKeys.functionKeys.count)]) { k in
                            Button(k.glyph) { input.press(k) }.accessibilityLabel(k.name)
                        }
                    }
                    .controlGroupStyle(.compactMenu)
                }
            }
            Section("More keys") {
                ForEach(MacKeys.navigation) { k in
                    Button { input.press(k) } label: { Text(k.name); Text(k.glyph) }
                }
            }
        } label: {
            Keycap(width: width, height: DeckLook.keyHeight, lit: false, pressed: false) {
                Text("fn").foregroundStyle(Ink.secondary)
            }
        }
        .accessibilityLabel("Function keys and more")
        .accessibilityIdentifier("deck-fn")
    }
}

// MARK: Send to

/// Where the words go, as a menu: every open app with its icon (a pick shows its window, and the
/// words go there), the whole screen, any app on the Mac.
struct DeckSendTo: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var watcher: Watcher
    /// A narrow column: the icon over the name.
    var compact = false

    var body: some View {
        let current = model.selection.target
        let places = model.placeOptions(current: current).filter { $0.kind != .closed && $0.kind != .opening }
        Menu {
            Section("Show and send to") {
                ForEach(places) { p in
                    Button {
                        Haptics.tick()
                        model.pick(p.target)
                        if p.target == .clipboard { return }
                        watcher.open(p.target)
                    } label: {
                        if let data = p.icon, let img = UIImage(data: data) {
                            Label { Text(p.shortName) } icon: { Image(uiImage: img) }
                        } else {
                            Label(p.shortName, systemImage: p.kind == .clipboard ? "doc.on.clipboard" : p.kind == .front ? "text.cursor" : "app")
                        }
                    }
                }
            }
            Section {
                if watcher.canWatchDesktop {
                    Button { model.watchWholeScreen() } label: { Label("Whole Screen", systemImage: "display") }
                }
                Button { model.sheet = .openApp } label: { Label("Open an App…", systemImage: "plus.app") }
            }
        } label: {
            if compact {
                VStack(spacing: 4) {
                    appIcon(current)
                    HStack(spacing: 3) {
                        Text(Places.appName(current, in: model))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Ink.ink)
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Ink.tertiary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .padding(.horizontal, 6)
                .watchGlass(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .contentShape(Rectangle())
            } else {
            HStack(spacing: 10) {
                appIcon(current)
                VStack(alignment: .leading, spacing: 1) {
                    Kicker("Send to")
                    Text(Places.appName(current, in: model))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Ink.ink)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.bold)).foregroundStyle(Ink.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .watchGlass(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
            }
        }
        .accessibilityLabel("Send to: \(Places.appName(current, in: model))")
        .accessibilityHint("Picks another app on your Mac and shows its window.")
        .accessibilityIdentifier("deck-send-to")
    }

    @ViewBuilder private func appIcon(_ t: TargetRef) -> some View {
        if let data = model.liveTarget(for: t)?.icon, let img = UIImage(data: data) {
            Image(uiImage: img).resizable().frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        } else {
            GlyphPlate(symbol: t == .clipboard ? "doc.on.clipboard" : t == .frontApp ? "text.cursor" : "app", tint: Light.cyan, size: 24)
        }
    }
}
