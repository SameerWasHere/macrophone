import MacrophoneKit
import SwiftUI

/// Your Macs (Oct 19 2026): the paired Macs, one of them active — a tap makes another the active
/// one. The pill at the top opens it (its swipe up or down is the shortcut to the same switch);
/// below the list, Pair Another Mac and Settings.
struct MacsSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
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
                .listRowBackground(Ink.raised)
                Section {
                    Button { open(.pairing) } label: {
                        Label("Pair Another Mac…", systemImage: "qrcode.viewfinder")
                    }
                    .accessibilityIdentifier("pair-another-mac")
                    Button { open(.settings) } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
                .foregroundStyle(Ink.ink)
                .listRowBackground(Ink.raised)
            }
            .scrollContentBackground(.hidden)
            .background(Ink.ground.ignoresSafeArea())
            .navigationTitle("Your Macs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.doneButtonStyle() }
            }
        }
        .tint(Light.cyan)
        .presentationDetents([.medium, .large])
    }

    /// Another sheet in this one's place: this one goes first, so the two never fight.
    private func open(_ sheet: AppSheet) {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { model.sheet = sheet }
    }
}

/// One paired Mac: its light, its name, how it stands (connected and how · looking · not found,
/// or, for one that isn't active, whether it's on this network), and a check on the active one.
struct MacRow: View {
    var mac: PairedPeer
    var active: Bool
    var standing: MacStanding
    var onPick: () -> Void

    var body: some View {
        Button(action: onPick) {
            HStack(spacing: 12) {
                Circle().fill(dot).frame(width: 9, height: 9).shadow(color: dot.opacity(0.7), radius: 3)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(mac.name).foregroundStyle(Ink.ink).multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(active ? "Active · \(standing.words)" : standing.words)
                        .font(.caption).foregroundStyle(active ? dot : Ink.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if case let .connected(route?) = standing {
                    Image(systemName: MacPill.symbol(route))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(route.isAway ? Light.cyan : Ink.tertiary)
                        .accessibilityHidden(true)
                }
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

    private var dot: Color {
        switch standing {
        case .connected: return Light.cyan
        case .notFound: return Light.ochre
        case .looking: return Ink.tertiary
        case .nearby(true): return Light.mint
        case .nearby(false): return Ink.tertiary
        }
    }
}
