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
        case .app: return "app"
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
        }
    }
}

/// Send to in the window's toolbar, above every pane (Nov 7 2026; the card above each pane is
/// gone): the pick's icon and "Send to Claude" as a menu — the places, a check on the current one,
/// and Send after pasting — beside a paper plane that turns Send after pasting on and off. The
/// line that says what will happen is each control's help.
struct SendToToolbar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: Settings

    private var sel: SendSelection { settings.selection }
    private var canSend: Bool { sel.target.canSend }
    private var sending: Bool { sel.send && canSend }
    private var name: String { SendToWords.name(sel.target, in: model) }

    var body: some View {
        Menu {
            SendToPicker(model: model, settings: settings)
                .pickerStyle(.inline)
            Divider()
            Toggle(SendToWords.sendAfterPasting, isOn: Binding(get: { sending }, set: { model.setSend($0) }))
                .disabled(!canSend)
        } label: {
            Label {
                Text("\(SendToWords.title) \(name)")
            } icon: {
                icon
            }
            .labelStyle(.titleAndIcon)
        }
        .menuIndicator(.visible)
        .fixedSize()
        .frame(maxWidth: 300)
        .help("\(SendToWords.title) — shared with your iPhone. \(SendToWords.line(sel, model: model))")
        .accessibilityLabel(SendToWords.title)
        .accessibilityValue(name)

        Toggle(isOn: Binding(get: { sending }, set: { model.setSend($0) })) {
            Label(SendToWords.sendAfterPasting, systemImage: sending ? "paperplane.fill" : "paperplane")
        }
        .toggleStyle(.button)
        .labelStyle(.iconOnly)
        .disabled(!canSend)
        .help(canSend ? (sending ? "Send after pasting is on: the app's send key is pressed after a 2.5-second countdown you can cancel."
                                 : "Send after pasting is off: the words are pasted and you press send.")
                      : "Pick an app or Where I'm typing to send after pasting.")
        .accessibilityLabel(SendToWords.sendAfterPasting)
    }

    @ViewBuilder private var icon: some View {
        if case let .app(bid, _, _) = sel.target, let i = TargetIcons.image(bundleID: bid) {
            Image(nsImage: i)
        } else {
            Image(systemName: TargetIcons.symbol(for: sel.target))
        }
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
                ForEach(model.targets.filter(\.typeable)) { t in row(t.ref, bundleID: t.bundleID) }
                if isUnlistedApp, case let .app(bid, _, _) = settings.selection.target {
                    row(settings.selection.target, bundleID: bid)
                }
            }
            // Every other open app: the words go where he tapped into a text box there.
            let others = model.targets.filter { !$0.typeable }
            if !others.isEmpty {
                Divider()
                ForEach(others) { t in row(t.ref, bundleID: t.bundleID) }
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
