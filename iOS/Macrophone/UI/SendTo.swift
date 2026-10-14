import MacrophoneKit
import SwiftUI
import UIKit

// Where dictations go: the glyphs and icons for places, and the full list of them (the sheet behind
// the dock's name line and its "All places" end-cap — every window lives there). The controls by
// the mic are in QuickControls.swift.

enum TargetGlyph {
    static func symbol(for t: TargetRef) -> String {
        switch t {
        case .clipboard: return "doc.on.clipboard"
        case .frontApp: return "cursorarrow.rays"
        case let .app(bid, _, name): return appSymbol(bundleID: bid, name: name)
        case .automation: return "doc.on.clipboard"
        }
    }

    static func appSymbol(bundleID: String, name: String) -> String {
        let b = bundleID.lowercased(), n = name.lowercased()
        if ["com.apple.terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.warp-stable"].contains(b) || n.contains("terminal") { return "terminal" }
        if n.contains("message") || n.contains("slack") || n.contains("mail") { return "bubble.left" }
        if n.contains("note") { return "note.text" }
        if n.contains("cursor") || n.contains("code") || n.contains("xcode") { return "chevron.left.forwardslash.chevron.right" }
        return "macwindow"
    }
}

/// App icons the Mac sends (small PNGs), decoded once.
@MainActor
enum IconCache {
    private static var images: [Data: UIImage] = [:]
    static func image(_ data: Data?) -> UIImage? {
        guard let data else { return nil }
        if let i = images[data] { return i }
        let i = UIImage(data: data)
        images[data] = i
        return i
    }
}

/// The app's own icon when the Mac sent one, else a glyph on a tinted plate.
struct TargetIcon: View {
    var target: TargetRef
    var icon: Data?
    var size: CGFloat = 20

    var body: some View {
        if let img = IconCache.image(icon) {
            Image(uiImage: img).resizable().interpolation(.high).scaledToFit()
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            let tint = Self.tint(target)
            Image(systemName: TargetGlyph.symbol(for: target))
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).fill(tint.opacity(0.16)))
                .overlay(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).strokeBorder(tint.opacity(0.3), lineWidth: 1))
                .accessibilityHidden(true)
        }
    }

    static func tint(_ t: TargetRef) -> Color {
        switch t {
        case .clipboard, .automation: return Light.teal
        case .frontApp: return Light.violet
        case .app: return Light.cyan
        }
    }
}

// MARK: The picker

/// Clipboard, Where I'm typing, then the Mac's open apps (newest first) and their windows.
struct SendToList: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var settings: Settings
    var onPick: () -> Void = {}

    var body: some View {
        List {
            Section {
                row(.clipboard, icon: nil, subtitle: "Copies it on your Mac, to paste yourself")
                row(.frontApp, icon: nil, subtitle: "Pastes into whatever app is in front on your Mac")
            }
            .listRowBackground(Ink.raised)

            Section {
                if let missing = missingPick {
                    row(missing, icon: nil, subtitle: "Not open on your Mac — it'll be copied instead", dim: true)
                }
                if model.liveTargets.isEmpty {
                    Text(model.isConnected
                         ? "Nothing with a place to type is open on \(model.macName) right now."
                         : "Open apps show here when \(model.macName) is connected.")
                        .font(.subheadline)
                        .foregroundStyle(Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 6)
                }
                ForEach(model.liveTargets) { t in
                    row(t.ref, icon: t.icon, subtitle: t.windowTitle == nil ? sendNote(t.ref) : "A window of \(t.appName)" + (sendNote(t.ref).map { " · \($0)" } ?? ""))
                }
            } header: {
                Text("Open on \(model.macName)")
            } footer: {
                Text(openFooter).padding(.top, 4)
            }
            .listRowBackground(Ink.raised)

            if settings.selection.target.canSend {
                Section {
                    Toggle(isOn: Binding(get: { settings.selection.send }, set: { model.setSend($0) })) {
                        HStack(spacing: 10) {
                    Image(systemName: settings.selection.send ? "paperplane.fill" : "paperplane").foregroundStyle(Light.cyan)
                        .accessibilityHidden(true)
                    Text("Send after pasting").fixedSize(horizontal: false, vertical: true)
                }
                    }
                    .accessibilityIdentifier("picker-send")
                } header: {
                    Text("For \(settings.selection.target.displayName)")
                } footer: {
                    Text("Your Mac presses the app's send key after pasting, after a short countdown you can cancel. Remembered for each place.")
                }
                .listRowBackground(Ink.raised)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Ink.ground.ignoresSafeArea())
        .tint(Light.cyan)
        .onAppear { model.refreshTargets() }
    }

    /// The picked app, when it's no longer open on the Mac — shown rather than vanishing.
    private var missingPick: TargetRef? {
        let t = settings.selection.target
        guard case .app = t, model.liveTarget(for: t) == nil else { return nil }
        return t
    }

    private func sendNote(_ t: TargetRef) -> String? { settings.rememberedSend(for: t) ? "Sends after pasting" : nil }

    private var openFooter: String {
        var s = "Apps and windows on your Mac with somewhere to type, most recent first. Say an app's name first to send just that one there: “Messages, tell Sam I'm late.”"
        if model.isPaired, !model.isConnected { s += " \(model.macName) isn't connected right now, so this is the list it sent last." }
        return s
    }

    private func row(_ target: TargetRef, icon: Data?, subtitle: String?, dim: Bool = false) -> some View {
        let selected = settings.selection.target == target
        return Button {
            model.pick(target)
            onPick()
        } label: {
            HStack(spacing: 14) {
                TargetIcon(target: target, icon: icon, size: 34)
                    .opacity(dim ? 0.55 : 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(target.displayName).font(.body.weight(.semibold)).foregroundStyle(dim ? Ink.secondary : Ink.ink)
                    if let subtitle {
                        Text(subtitle).font(.footnote).foregroundStyle(dim ? Light.ochre : Ink.tertiary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Light.cyan)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The picker as a sheet from the chip.
struct SendToSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SendToList(settings: model.settings) { dismiss() }
                .navigationTitle("Send To")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.fontWeight(.semibold) }
                }
        }
        .tint(Light.cyan)
    }
}
