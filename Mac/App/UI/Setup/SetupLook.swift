import AppKit
import SwiftUI

// The setup's pages as macOS's own Setup Assistant draws them (Nov 7 2026): the system's
// window background in light and dark, a symbol over a bold title and a sentence, the page's
// content, and the buttons along the foot — Back on the left, the one thing to do on the right.

/// Which look a checklist wears: the setup's native one (system colours and buttons, light or
/// dark), or the main window's dark plates (Devices › Away from home).
enum GuideLook { case native, pane }

private struct GuideLookKey: EnvironmentKey { static let defaultValue = GuideLook.native }

extension EnvironmentValues {
    var guideLook: GuideLook {
        get { self[GuideLookKey.self] }
        set { self[GuideLookKey.self] = newValue }
    }
}

/// The system's light or dark (the app forces dark on its other windows, so the setup reads the
/// setting itself and follows it as it changes).
@MainActor
enum SystemAppearance {
    static var isDark: Bool {
        #if DEBUG
        // MACROPHONE_APPEARANCE=light | dark: the setup in either, whatever this Mac is set to.
        if let a = ProcessInfo.processInfo.environment["MACROPHONE_APPEARANCE"] { return a == "dark" }
        #endif
        return UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    static var appearance: NSAppearance? { NSAppearance(named: isDark ? .darkAqua : .aqua) }

    /// Calls `changed` whenever the person switches between light and dark.
    static func observe(_ changed: @escaping @MainActor () -> Void) -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
                                                            object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { changed() }
        }
    }
}

/// One Setup Assistant page.
struct SetupPage<Content: View, Footer: View>: View {
    var symbol: String?
    var symbolColor: Color = .accentColor
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 50, weight: .regular))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(symbolColor)
                        .frame(height: 62)
                        .padding(.bottom, 14)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.system(size: 26, weight: .bold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 440)
                        .padding(.top, 8)
                }
                content.padding(.top, 22)
            }
            .padding(.top, symbol == nil ? 58 : 46)
            .padding(.horizontal, 44)
            Spacer(minLength: 12)
            HStack(spacing: 10) { footer }
                .controlSize(.large)
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A quiet line under a page's content.
struct SetupFootnote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 440)
    }
}

/// The rows of a checklist in a box: the system's own control background in the setup, the
/// window's plate in a pane.
struct CheckList<Content: View>: View {
    @Environment(\.guideLook) private var look
    @ViewBuilder var content: Content

    var body: some View {
        switch look {
        case .pane:
            Plate { content }
        case .native:
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
        }
    }
}

/// The hairline between checklist rows, lined up with the words.
struct CheckDivider: View {
    @Environment(\.guideLook) private var look
    var body: some View {
        Rectangle()
            .fill(look == .pane ? Ink.line : Color(nsColor: .separatorColor))
            .frame(height: look == .pane ? 1 : 0.5)
            .padding(.leading, 14 + 24 + 12)
            .accessibilityHidden(true)
    }
}

/// One step: a green check once it's done (a number, lit while it's the next one, before), its
/// title and one or two lines, and what to do on the right.
struct CheckRow<Trailing: View>: View {
    @Environment(\.guideLook) private var look
    var number: Int?
    var symbol: String?
    let title: String
    var detail: String?
    var detailIsWarning = false
    let done: Bool
    /// The first step not done yet: its number is lit.
    var next = false
    @ViewBuilder var trailing: Trailing

    private var green: Color { look == .pane ? Light.mint : .green }
    private var accent: Color { look == .pane ? Light.cyan : .accentColor }
    private var warning: Color { look == .pane ? Light.ochre : .orange }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            badge.frame(width: 24, height: 24).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(look == .pane ? Ink.ink : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(detailIsWarning ? warning : (look == .pane ? Ink.tertiary : Color.secondary))
                        .lineSpacing(1.5)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(minHeight: 52)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(done ? "\(title), done" : title)
        .animation(Motion.reduceMotion ? .easeInOut(duration: 0.2) : Motion.settle, value: done)
    }

    @ViewBuilder private var badge: some View {
        if done {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white, green)
                .transition(.scale.combined(with: .opacity))
        } else if let number {
            ZStack {
                Circle().fill(next ? accent : Color.clear)
                Circle().strokeBorder(next ? accent : (look == .pane ? Ink.lineHeavy : Color.secondary.opacity(0.5)), lineWidth: 1.2)
                Text("\(number)")
                    .font(.system(size: 11.5, weight: .bold, design: .rounded))
                    .foregroundStyle(next ? Color.white : (look == .pane ? Ink.tertiary : Color.secondary))
            }
            .frame(width: 20, height: 20)
        } else if let symbol {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(next ? accent : (look == .pane ? Ink.secondary : Color.secondary))
        }
    }
}

extension CheckRow where Trailing == EmptyView {
    init(number: Int? = nil, symbol: String? = nil, title: String, detail: String? = nil, detailIsWarning: Bool = false, done: Bool, next: Bool = false) {
        self.init(number: number, symbol: symbol, title: title, detail: detail, detailIsWarning: detailIsWarning, done: done, next: next) { EmptyView() }
    }
}

/// A checklist row's button: the system's bordered button in the setup (prominent for the next
/// step), the window's pill in a pane.
struct GuideButton: View {
    @Environment(\.guideLook) private var look
    let title: String
    var prominent = false
    var help: String?
    let action: () -> Void

    init(_ title: String, prominent: Bool = false, help: String? = nil, action: @escaping () -> Void) {
        self.title = title; self.prominent = prominent; self.help = help; self.action = action
    }

    var body: some View {
        switch look {
        case .pane:
            Button(title, action: action)
                .buttonStyle(PillButtonStyle(tint: Ink.ink, filled: prominent))
                .help(help ?? "")
        case .native:
            if prominent {
                Button(title, action: action).buttonStyle(.borderedProminent).controlSize(.regular).help(help ?? "")
            } else {
                Button(title, action: action).buttonStyle(.bordered).controlSize(.regular).help(help ?? "")
            }
        }
    }
}
