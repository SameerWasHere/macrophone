import AppKit
import MacrophoneKit
import SwiftUI

/// Icons for Send to's rows (the app's own icon; a symbol for the rest).
@MainActor
enum TargetIcons {
    private static var cache: [String: NSImage] = [:]

    static func image(bundleID: String, size: CGFloat = 16) -> NSImage? {
        let key = "\(bundleID)@\(size)"
        if let i = cache[key] { return i }
        guard let base = InstalledApp.icon(for: bundleID), let copy = base.copy() as? NSImage else { return nil }
        copy.size = NSSize(width: size, height: size)
        cache[key] = copy
        return copy
    }

    static func symbol(for ref: TargetRef) -> String {
        switch ref {
        case .clipboard: return "doc.on.clipboard"
        case .frontApp: return "text.cursor"
        case .app, .automation: return "app"
        }
    }
}

/// The words Send to uses, the same on the iPhone and the Mac.
enum SendToWords {
    static let title = "Send to"
    static let sendAfterPasting = "Send after pasting"

    /// "Claude", "Terminal — claude", "Claude (not open)".
    @MainActor static func name(_ ref: TargetRef, in model: AppModel) -> String {
        if case let .app(bid, _, _) = ref, model.targetsKnown, model.liveTarget(for: ref) == nil {
            let running = !NSRunningApplication.runningApplications(withBundleIdentifier: bid).isEmpty
            return "\(ref.displayName) (\(running ? "no window open" : "not open"))"
        }
        return ref.displayName
    }

    /// One line under the control: what will happen.
    @MainActor static func line(_ sel: SendSelection, model: AppModel) -> String {
        switch sel.target {
        case .clipboard:
            return "Dictations are copied to this Mac's clipboard. Paste them anywhere with ⌘V."
        case .frontApp:
            return sel.send
                ? "Pasted wherever your cursor is, then sent with the app's send key — after a 2.5-second countdown you can cancel."
                : "Pasted wherever your cursor is, after a 2.5-second countdown you can cancel."
        case let .app(_, _, name):
            let app = Paster.appName(fromTitle: name)
            if model.targetsKnown, model.liveTarget(for: sel.target) == nil, case let .app(bid, key, _) = sel.target {
                if NSRunningApplication.runningApplications(withBundleIdentifier: bid).isEmpty {
                    return "\(app) isn't open right now — dictations will be copied instead until it is."
                }
                if key != nil { return "That \(app) window isn't open — dictations will be copied instead. Pick another one." }
                return "\(app) has no window open — Macrophone will ask it to open one."
            }
            if case let .app(bid, _, _) = sel.target, AppQuirks.isTerminal(bid) {
                return sel.send
                    ? "Typed into \(app), then Return runs it — after a 2.5-second countdown you can cancel."
                    : "Typed into \(app) after a 2.5-second countdown. You press Return."
            }
            return sel.send
                ? "Pasted into \(app)'s message box and sent — after a 2.5-second countdown you can cancel."
                : "Pasted into \(app)'s message box after a 2.5-second countdown. You press send."
        case .automation:
            return "Dictations are copied to this Mac's clipboard. Paste them anywhere with ⌘V."
        }
    }
}

/// "Send to [Claude ▾]   Send after pasting [on]" — the shared choice, on this Mac.
struct SendToCard: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: Settings
    /// Setup: no "shared with your iPhone" line (the page says so).
    /// No vertical fixedSize on the lines: the card sits outside the panes' scroll view, where a
    /// fixed-height text makes the window's minimum size enormous and SwiftUI draws nothing.
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "paperplane")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Light.cyan)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                Text(SendToWords.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Ink.ink)
                    .fixedSize()
                SendToPicker(model: model, settings: settings)
                    .frame(maxWidth: 300, alignment: .leading)
                Spacer(minLength: 12)
                Toggle(SendToWords.sendAfterPasting, isOn: Binding(get: { settings.selection.send && settings.selection.target.canSend },
                                                                  set: { model.setSend($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.system(size: 12.5))
                    .foregroundStyle(settings.selection.target.canSend ? Ink.ink : Ink.tertiary)
                    .fixedSize()
                    .disabled(!settings.selection.target.canSend)
                    .help(settings.selection.target.canSend ? "Presses the app's send key after pasting, after a 2.5-second countdown you can cancel."
                          : "Pick an app or Where I'm typing to send after pasting.")
            }
            Text(SendToWords.line(settings.selection, model: model))
                .font(.system(size: 12)).foregroundStyle(Ink.secondary)
                .padding(.leading, 32)
            if !compact {
                Text("Shared with your iPhone — change it on either and the other follows.")
                    .font(.system(size: 11.5)).foregroundStyle(Ink.tertiary)
                        .padding(.leading, 32)
            }
            if !model.accessibilityGranted && settings.selection.target.canSend {
                HStack(spacing: 10) {
                    Label("Pasting needs Accessibility. Until it's on, dictations are copied.", systemImage: "hand.raised")
                        .font(.system(size: 11.5)).foregroundStyle(Light.ochre)
                            Spacer(minLength: 8)
                    Button("Open System Settings") {
                        Paster.requestTrust()
                        NSWorkspace.shared.open(Paster.accessibilitySettingsURL)
                    }
                    .buttonStyle(PillButtonStyle(tint: Ink.ink, filled: false))
                }
                .padding(.leading, 32)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Light.cyan.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Light.cyan.opacity(0.24), lineWidth: 1))
    }
}

/// The pop-up menu: Clipboard, Where I'm typing, then every open app with somewhere to type.
struct SendToPicker: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: Settings

    var body: some View {
        Picker(SendToWords.title, selection: Binding(get: { settings.selection.target },
                                                     set: { model.choose(SendSelection(target: $0, send: settings.selection.send)) })) {
            row(.clipboard)
            row(.frontApp)
            if !model.targets.isEmpty || isUnlistedApp {
                Divider()
                ForEach(model.targets) { t in row(t.ref, bundleID: t.bundleID) }
                if isUnlistedApp, case let .app(bid, _, _) = settings.selection.target {
                    row(settings.selection.target, bundleID: bid)
                }
            }
        }
        .labelsHidden()
        .accessibilityLabel(SendToWords.title)
    }

    private var isUnlistedApp: Bool {
        if case .app = settings.selection.target { return model.liveTarget(for: settings.selection.target) == nil }
        return false
    }

    @ViewBuilder private func row(_ ref: TargetRef, bundleID: String? = nil) -> some View {
        let name = SendToWords.name(ref, in: model)
        if let bundleID, let icon = TargetIcons.image(bundleID: bundleID) {
            Label { Text(name) } icon: { Image(nsImage: icon) }.tag(ref)
        } else {
            Label(name, systemImage: TargetIcons.symbol(for: ref)).tag(ref)
        }
    }
}
