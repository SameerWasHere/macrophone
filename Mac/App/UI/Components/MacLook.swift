import AppKit
import SwiftUI

// The Mac window as Apple would make it (Nov 7 2026): System Settings' look, in light and dark.
// Every pane is built from these pieces — the old names kept, so a pane written against the old
// dark plates comes out native without a change:
//
//   PanePage { … }                  a grouped Form (`.formStyle(.grouped)`), the pane's scroll
//   PaneHeader(title:subtitle:)     the hero at the top: the pane's icon tile, a bold title, one
//                                   sentence (and room for one button under it)
//   PaneSection("Title", note:) { } a Form Section: the header, its rows, a footer of a sentence
//   Plate { rows }                  inside a PanePage just its rows (the Section draws the box);
//                                   anywhere else a box of its own
//   PlateRow(title:subtitle:icon:iconColor:) { trailing }
//                                   a System Settings row: a coloured icon tile, the title, a line
//                                   of description under it, the control on the right
//   PlateDivider()                  nothing inside a PanePage (the Form draws separators)
//   SettingsIcon(symbol, color)     a white glyph on a coloured rounded square
//   PaneBanner                      a notice above a pane (the icon hidden, Accessibility off)
//   EmptyState                      a ContentUnavailableView-style empty pane
//
// A new pane: add its case to `Pane` (MacrophoneApp.swift; its title and symbol), give it a tint
// in `Pane.tint` below (or leave the default grey), add it to MainView's `detail` switch, and
// write its body as `PanePage { PaneHeader(…); PaneSection(…) { Plate { PlateRow(…) { Toggle… } } } }`.

// MARK: - Appearance

/// General › Appearance: Automatic follows the system; Light and Dark hold it for every window
/// except the popup and the listening pill, which are HUDs.
enum AppAppearance: String, CaseIterable, Identifiable {
    case automatic, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
    var nsAppearance: NSAppearance? {
        switch self {
        case .automatic: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    @MainActor static func apply(_ choice: AppAppearance) {
        #if DEBUG
        // MACROPHONE_APPEARANCE=light | dark: every window in either, whatever this Mac is set to
        // (screenshots never change the system's appearance).
        if let forced = ProcessInfo.processInfo.environment["MACROPHONE_APPEARANCE"], forced == "light" || forced == "dark" {
            NSApp.appearance = NSAppearance(named: forced == "dark" ? .darkAqua : .aqua)
            return
        }
        #endif
        NSApp.appearance = choice.nsAppearance
    }
}

// MARK: - The sidebar's sections

extension Pane {
    /// The colour of its icon tile (System Settings' sidebar). A pane added later gets grey until
    /// it names its own.
    var tint: Color {
        switch self {
        case .history: return MacTint.indigo
        case .dictation: return MacTint.orange
        case .agents: return MacTint.purple
        case .devices: return MacTint.blue
        case .developer: return MacTint.graphite
        case .general: return MacTint.gray
        default: return MacTint.gray
        }
    }

    /// The pane with this title (PaneHeader finds its icon by it).
    static func titled(_ title: String) -> Pane? { allCases.first { $0.title == title } }
}

/// The icon tiles' colours: the system's own.
enum MacTint {
    static let gray = Color(nsColor: .systemGray)
    static let graphite = Color(nsColor: NSColor(name: "MacrophoneGraphite") { a in
        a.isDark ? NSColor(white: 0.36, alpha: 1) : NSColor(white: 0.30, alpha: 1)
    })
    static let blue = Color(nsColor: .systemBlue)
    static let indigo = Color(nsColor: .systemIndigo)
    static let purple = Color(nsColor: .systemPurple)
    static let pink = Color(nsColor: .systemPink)
    static let red = Color(nsColor: .systemRed)
    static let orange = Color(nsColor: .systemOrange)
    static let yellow = Color(nsColor: .systemYellow)
    static let green = Color(nsColor: .systemGreen)
    static let teal = Color(nsColor: .systemTeal)
    static let mint = Color(nsColor: .systemMint)
}

// MARK: - The icon tile

/// A white glyph on a coloured rounded square, as System Settings draws its sidebar and rows.
/// The symbol's filled variant is used when there is one.
struct SettingsIcon: View {
    let symbol: String
    var color: Color = MacTint.gray
    var size: CGFloat = 20

    init(_ symbol: String, color: Color = MacTint.gray, size: CGFloat = 20) {
        self.symbol = symbol; self.color = color; self.size = size
    }

    static func filled(_ s: String) -> String {
        if s.hasSuffix(".fill") { return s }
        let f = s + ".fill"
        return NSImage(systemSymbolName: f, accessibilityDescription: nil) != nil ? f : s
    }

    var body: some View {
        Image(systemName: Self.filled(symbol))
            .font(.system(size: size * 0.55, weight: .semibold))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).fill(color.gradient))
            .overlay(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).strokeBorder(Color.black.opacity(0.06), lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}

// MARK: - The pane's form

private struct InPaneFormKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// Inside a PanePage's grouped Form: Plate and PlateRow leave the box and the padding to it.
    var inPaneForm: Bool {
        get { self[InPaneFormKey.self] }
        set { self[InPaneFormKey.self] = newValue }
    }
}

/// The page every pane sits on: a grouped Form, as System Settings' panes are.
struct PanePage<Content: View>: View {
    /// A pane with a text view in it (Dictation's Try it): the text view shows its caret as it's
    /// made and AppKit scrolls every enclosing scroll view to it, so the page opened at its foot.
    /// This puts it back at its top just after it appears.
    var opensAtTop = false
    var content: Content

    init(opensAtTop: Bool = false, @ViewBuilder content: () -> Content) {
        self.opensAtTop = opensAtTop
        self.content = content()
    }

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                content
                Section {} footer: { Color.clear.frame(height: 1).id("pane-bottom").accessibilityHidden(true) }
            }
            .formStyle(.grouped)
            .environment(\.inPaneForm, true)
            .onAppear {
                if opensAtTop {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { proxy.scrollTo("pane-top", anchor: .top) }
                }
                #if DEBUG
                // Screenshots of a pane's foot.
                if ProcessInfo.processInfo.environment["MACROPHONE_SCROLL_BOTTOM"] == "1" {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { proxy.scrollTo("pane-bottom", anchor: .bottom) }
                }
                #endif
            }
        }
    }
}

/// The hero at a pane's top, as System Settings opens each pane: its icon tile, its name in bold,
/// one sentence of what it's for — and room under it for one button (Devices › Pair Another iPhone).
struct PaneHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    var symbol: String?
    var tint: Color?
    @ViewBuilder var trailing: Trailing
    @Environment(\.inPaneForm) private var inForm

    init(title: String, subtitle: String, symbol: String? = nil, tint: Color? = nil, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title; self.subtitle = subtitle; self.symbol = symbol; self.tint = tint; self.trailing = trailing()
    }

    private var pane: Pane? { Pane.titled(title) }

    var body: some View {
        if inForm {
            Section { hero }.id("pane-top")
        } else {
            hero
        }
    }

    private var hero: some View {
        VStack(spacing: 6) {
            if let s = symbol ?? pane?.symbol {
                SettingsIcon(s, color: tint ?? pane?.tint ?? MacTint.gray, size: 48)
                    .padding(.bottom, 4)
            }
            Text(title)
                .font(.system(size: 20, weight: .bold))
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 440)
            trailing.padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }
}

/// A Form Section: a header, its rows, and a footer of a sentence or two.
struct PaneSection<Content: View>: View {
    var label: String?
    var note: String?
    @ViewBuilder var content: Content
    @Environment(\.inPaneForm) private var inForm
    init(_ label: String? = nil, note: String? = nil, @ViewBuilder content: () -> Content) {
        self.label = label; self.note = note; self.content = content()
    }
    var body: some View {
        if inForm {
            Section {
                content
            } header: {
                if let label { Text(label) }
            } footer: {
                if let note, !note.isEmpty { SectionFooter(note) }
            }
        } else {
            VStack(alignment: .leading, spacing: Space.label) {
                if let label { SectionLabel(label) }
                content
                if let note, !note.isEmpty { PlateNote(note) }
            }
        }
    }
}

/// A section's footer: a sentence or two in the secondary colour, under the box.
struct SectionFooter: View {
    let text: String
    var color: Color = Ink.secondary
    init(_ text: String, color: Color = Ink.secondary) { self.text = text; self.color = color }
    var body: some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A section's header outside a form (inside one, Section draws its own).
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Ink.ink)
            .padding(.leading, 4)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A box of rows. Inside a PanePage the Section is the box, so this is just its rows (each row a
/// row of the form, the separators the form's); anywhere else it draws a grouped box itself.
struct Plate<Content: View>: View {
    var padding: CGFloat = 0
    @ViewBuilder var content: Content
    @Environment(\.inPaneForm) private var inForm
    var body: some View {
        if inForm {
            Group { content }
        } else {
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(padding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Radius.plate, style: .continuous).fill(Ink.raised))
                .overlay(RoundedRectangle(cornerRadius: Radius.plate, style: .continuous).strokeBorder(Ink.line, lineWidth: 0.5))
        }
    }
}

/// One row: a coloured icon tile, the title, a line under it, and a control on the right — as
/// System Settings' rows. `iconColor` is the tile's colour (a grey for the label colours).
struct PlateRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    var subtitleColor: Color = Ink.secondary
    var icon: String?
    var iconColor: Color = Ink.secondary
    @ViewBuilder var trailing: Trailing
    @Environment(\.inPaneForm) private var inForm

    init(title: String, subtitle: String? = nil, subtitleColor: Color = Ink.secondary, icon: String? = nil, iconColor: Color = Ink.secondary,
         @ViewBuilder trailing: () -> Trailing) {
        self.title = title; self.subtitle = subtitle; self.subtitleColor = subtitleColor
        self.icon = icon; self.iconColor = iconColor; self.trailing = trailing()
    }

    /// The label colours read as a grey tile; a meaning colour is the tile's own.
    private var tile: Color {
        [Ink.secondary, Ink.tertiary, Ink.ink, Ink.lineHeavy].contains(iconColor) ? MacTint.gray : iconColor
    }

    private var quiet: Color { subtitleColor == Ink.tertiary ? Ink.secondary : subtitleColor }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if let icon {
                SettingsIcon(icon, color: tile, size: 22)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13)).foregroundStyle(Ink.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(quiet)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: Space.gap)
            trailing
        }
        .padding(.horizontal, inForm ? 0 : Space.inset)
        .padding(.vertical, inForm ? 1 : 9)
        .frame(minHeight: inForm ? 24 : 40)
    }
}

extension PlateRow where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, subtitleColor: Color = Ink.secondary, icon: String? = nil, iconColor: Color = Ink.secondary) {
        self.init(title: title, subtitle: subtitle, subtitleColor: subtitleColor, icon: icon, iconColor: iconColor) { EmptyView() }
    }
}

/// The hairline between rows outside a form (inside one the form draws them). The default inset
/// lines up with a row's words, as System Settings does.
struct PlateDivider: View {
    var inset: CGFloat = PlateDivider.rowInset
    static let rowInset: CGFloat = Space.inset + 22 + 10
    @Environment(\.inPaneForm) private var inForm
    var body: some View {
        if !inForm {
            Rectangle().fill(Ink.line).frame(height: 0.5).padding(.leading, inset).accessibilityHidden(true)
        }
    }
}

/// A quiet line ("Your iPhone sees this name…") — a row of its own inside a form.
struct PlateNote: View {
    let text: String
    var color: Color = Ink.secondary
    init(_ text: String, color: Color = Ink.secondary) { self.text = text; self.color = color == Ink.tertiary ? Ink.secondary : color }
    var body: some View {
        Text(text)
            .font(.system(size: 11.5)).foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// "✓ Allowed" on a row's right: a grant or a connection that's on (green, as System Settings'
/// own checks).
struct AllowedMark: View {
    let name: String
    var word = "Allowed"
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(.white, Light.mint)
            Text(word).font(.system(size: 12)).foregroundStyle(Ink.secondary)
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name): \(word.lowercased())")
    }
}

/// An empty pane, as ContentUnavailableView draws one: a large quiet symbol, a bold line, a
/// sentence of what to do, and at most one button.
struct EmptyState<Mark: View, Action: View>: View {
    let title: String
    let detail: String
    @ViewBuilder var mark: Mark
    @ViewBuilder var action: Action
    init(title: String, detail: String, @ViewBuilder mark: () -> Mark, @ViewBuilder action: () -> Action = { EmptyView() }) {
        self.title = title; self.detail = detail; self.mark = mark(); self.action = action()
    }
    var body: some View {
        VStack(spacing: 8) {
            mark.foregroundStyle(.secondary).padding(.bottom, 4)
            Text(title).font(.system(size: 17, weight: .bold)).foregroundStyle(Ink.ink)
            Text(detail)
                .font(.system(size: 12.5)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360)
            action.padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }
}

/// A notice above a pane: a symbol in its meaning colour, a bold line, a sentence, one button —
/// a box like the form's, lined up with its margins.
struct PaneBanner<Action: View>: View {
    let symbol: String
    var tint: Color = Light.ochre
    let title: String
    let detail: String
    @ViewBuilder var action: Action

    init(symbol: String, tint: Color = Light.ochre, title: String, detail: String, @ViewBuilder action: () -> Action = { EmptyView() }) {
        self.symbol = symbol; self.tint = tint; self.title = title; self.detail = detail; self.action = action()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.ink)
                // No vertical fixedSize: outside the pane's scroll a fixed-height text can make the
                // window's minimum size enormous.
                Text(detail).font(.system(size: 11.5)).foregroundStyle(Ink.secondary)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 10)
            action
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: Radius.plate, style: .continuous).fill(Ink.raised))
        .overlay(RoundedRectangle(cornerRadius: Radius.plate, style: .continuous).strokeBorder(Ink.line, lineWidth: 0.5))
    }
}
