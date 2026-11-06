import MacrophoneKit
import SwiftUI

/// Your Macs (Oct 19 2026): the paired Macs, one of them active — a tap makes another the active
/// one. The menu bar's Mac opens it (its swipe up or down is the shortcut to the same switch);
/// below the list, Pair Another Mac and Settings. A native sheet and list since Nov 1 2026.
struct MacsSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if model.pairedMacs.isEmpty {
                    // The last one forgot this iPhone while the list was open.
                    EmptyState(symbol: "macbook.and.iphone", title: "No Macs paired",
                               message: "Pair a Mac to send what you say into its apps.") {
                        Button { open(.pairing) } label: { Label("Pair a Mac", systemImage: "qrcode.viewfinder") }
                            .emptyStateButton()
                    }
                } else {
                    list
                }
            }
            .navigationTitle("Your Macs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.doneButtonStyle() }
            }
        }
        .tint(Light.cyan)
        .presentationDetents([.medium, .large])
    }

    private var list: some View {
        List {
            Section {
                ForEach(model.pairedMacs) { mac in
                    MacRow(mac: mac, active: mac.id == model.pairedMac?.id, standing: model.standing(of: mac)) {
                        model.switchMac(to: mac.id)
                        dismiss()
                    }
                }
            } footer: {
                Text("Swipe up or down on the Mac's name at the top to switch. What you say goes to the active Mac.")
            }
            Section {
                Button { open(.pairing) } label: {
                    Label("Pair Another Mac…", systemImage: "plus")
                }
                .accessibilityIdentifier("pair-another-mac")
                Button { open(.settings) } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
    }

    /// Another sheet in this one's place: this one goes first, so the two never fight.
    private func open(_ sheet: AppSheet) {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { model.sheet = sheet }
    }
}

/// One paired Mac, as a list row: its glyph on a Settings tile (blue for the active one), its name,
/// how it stands under it (connected and how · looking · not found, or, for one that isn't active,
/// whether it's on this network), and a check on the active one.
struct MacRow: View {
    var mac: PairedPeer
    var active: Bool
    var standing: MacStanding
    var onPick: () -> Void

    var body: some View {
        Button(action: onPick) {
            HStack(spacing: 14) {
                SettingsIcon(symbol: MacGlyph.symbol(for: mac.name), color: active ? Light.cyan : Color(uiColor: .systemGray))
                VStack(alignment: .leading, spacing: 2) {
                    Text(mac.name).foregroundStyle(Ink.ink).multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(standing.words)
                        .font(.footnote).foregroundStyle(standing == .notFound ? Light.ochre : Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Light.cyan)
                    .opacity(active ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(mac.name)
        .accessibilityValue(active ? "Active, \(standing.words.lowercased())" : standing.words)
        .accessibilityHint(active ? "The active Mac." : "Makes it the active Mac.")
        .accessibilityAddTraits(active ? .isSelected : [])
        .accessibilityIdentifier("mac-row-\(mac.name)")
    }
}
