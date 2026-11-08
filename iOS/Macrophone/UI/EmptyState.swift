import MacrophoneKit
import SwiftUI
import UIKit

// Empty and error states, as Apple's own (Nov 5 2026): a centred symbol, a short title in
// sentence case with no full stop, one sentence, and at most one button — the one that fixes it.
// Every one is a `ContentUnavailableView`, in a sheet, on the phone's desktop and on the Duo's
// glance alike, so they read as the system's.

/// One empty state: the symbol, the title, the sentence and the button that fixes it.
struct EmptyState<Action: View>: View {
    var symbol: String
    var title: String
    var message: String?
    @ViewBuilder var action: Action

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            if let message { Text(message) }
        } actions: {
            action
        }
    }
}

extension EmptyState where Action == EmptyView {
    init(symbol: String, title: String, message: String? = nil) {
        self.init(symbol: symbol, title: title, message: message) { EmptyView() }
    }
}

extension View {
    /// An empty state's one button: the accent, filled (Liquid Glass on iOS 26+).
    @ViewBuilder func emptyStateButton() -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glassProminent).tint(Light.cyan).foregroundStyle(Ink.onTint).fontWeight(.semibold)
        } else {
            buttonStyle(.borderedProminent).tint(Light.cyan).foregroundStyle(Ink.onTint).fontWeight(.semibold)
        }
    }
}

/// Opens Macrophone's page in the iPhone's Settings (where the microphone, speech recognition and
/// Local Network are switched on).
@MainActor func openAppSettings() {
    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
}

/// Wake Your Mac, as an empty state's button — only when waking could work from here (the same
/// rule as the menu bar's: paired, not found, and on a network the Mac was on).
struct WakeMacAction: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var reach = MacReach.shared

    var body: some View {
        if model.wakeInfoHere != nil || reach.waking {
            Button { model.wakeMac() } label: {
                Label(reach.waking ? "Waking…" : "Wake Your Mac", systemImage: "power")
            }
            .emptyStateButton()
            .disabled(reach.waking)
            .accessibilityHint("Sends your Mac a wake-up signal over this Wi-Fi. A closed laptop on battery may not wake.")
            .accessibilityIdentifier("empty-wake-mac")
        }
    }
}

/// What stands between the mic and the Mac, said once on the phone's desktop (the empty room
/// between the menu bar and the Dock — the cover's, between its pill and Send to). Nothing when
/// all is well. The status line under the mic stays quiet about it meanwhile (`StatusLine
/// .desktopSays`), and the menu bar's Wake Your Mac steps aside for this one.
enum DesktopTrouble: Equatable {
    /// The microphone (or speech recognition) is off for Macrophone in Settings.
    case micOff(speech: Bool)
    case unpaired
    /// Local Network is off, so the Mac can't be found on this Wi-Fi.
    case localNetwork
    /// Paired, and the Mac wasn't found (never in the moment after launch while it connects).
    case notFound

    @MainActor static func current(_ model: AppModel, micOff: Bool) -> DesktopTrouble? {
        if micOff { return .micOff(speech: model.startError == .speechDenied) }
        if !model.isPaired { return .unpaired }
        guard !model.settling, !model.reconnecting, !model.returning, model.isUnreachable else { return nil }
        return model.localNetworkDenied ? .localNetwork : .notFound
    }
}

/// The desktop's empty state for a `DesktopTrouble`. In a short room (an SE, the accessibility
/// sizes) it sheds its sentence, then its symbol; the button always stays.
struct DesktopEmptyState: View {
    @EnvironmentObject var model: AppModel
    var trouble: DesktopTrouble

    var body: some View {
        ViewThatFits(in: .vertical) {
            full
            EmptyState(symbol: symbol, title: title) { action }
            VStack(spacing: 10) {
                Text(title).font(.headline).foregroundStyle(Ink.ink).multilineTextAlignment(.center)
                action
            }
            .padding(.horizontal, Space.margin)
        }
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // As the status line under the mic: past this, the button alone outgrew the room.
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
        .transition(.opacity)
    }

    private var full: some View {
        EmptyState(symbol: symbol, title: title, message: message) { action }
    }

    private var symbol: String {
        switch trouble {
        case .micOff(let speech): return speech ? "waveform.badge.exclamationmark" : "mic.slash"
        case .unpaired: return "macbook.and.iphone"
        case .localNetwork: return "network.slash"
        case .notFound: return "laptopcomputer.slash"
        }
    }

    private var title: String {
        switch trouble {
        case .micOff(let speech): return speech ? "Speech recognition is off" : "The microphone is off"
        case .unpaired: return "Pair your Mac"
        case .localNetwork: return "Local Network is off"
        case .notFound: return "Can't find \(model.macName)"
        }
    }

    private var message: String {
        switch trouble {
        case .micOff(let speech):
            return speech ? "Turn it on in Settings so Macrophone can turn your voice into words."
                          : "Turn it on in Settings so Macrophone can hear you."
        case .unpaired: return "What you say goes into any app on your Mac — until then, it's copied on this iPhone."
        case .localNetwork: return "Turn it on in Settings so Macrophone can find \(model.macName) on this Wi-Fi."
        case .notFound:
            switch model.awayHelp {
            case .setUp?: return "Away from home? Set up Tailscale once and your iPhone reaches it from anywhere. What you say waits for it."
            case .turnOnTailscale?: return "Turn on Tailscale on this iPhone to reach it from here. What you say waits for it."
            case .check?: return "Make sure it's awake, with Tailscale and Macrophone open. What you say waits for it."
            case nil: return "Make sure it's awake with Macrophone open — what you say waits for it."
            }
        }
    }

    @ViewBuilder private var action: some View {
        switch trouble {
        case .micOff, .localNetwork:
            Button("Open Settings") { openAppSettings() }
                .emptyStateButton()
                .accessibilityIdentifier("empty-open-settings")
        case .unpaired:
            Button { model.sheet = .pairing } label: { Label("Pair a Mac", systemImage: "qrcode.viewfinder") }
                .emptyStateButton()
                .accessibilityIdentifier("empty-pair")
        case .notFound:
            MacNotFoundAction()
        }
    }
}

/// "Can't find ‹Mac›"'s one button (the phone's desktop, the Duo's glance): Wake Your Mac on its
/// own Wi-Fi; away from it, the Tailscale step that's missing (Nov 7 2026).
struct MacNotFoundAction: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        switch model.awayHelp {
        case .setUp?:
            Button { model.openAwayGuide() } label: { Label("Set Up Away from Home", systemImage: "network.badge.shield.half.filled") }
                .emptyStateButton()
                .accessibilityIdentifier("empty-away-setup")
        case .turnOnTailscale?:
            Button { TailscaleHere.open() } label: { Label("Turn On Tailscale", systemImage: "network.badge.shield.half.filled") }
                .emptyStateButton()
                .accessibilityIdentifier("empty-turn-on-tailscale")
        case .check?:
            Button { model.openAwayGuide() } label: { Label("Test the Connection", systemImage: "checkmark.shield") }
                .emptyStateButton()
                .accessibilityIdentifier("empty-away-test")
        case nil:
            WakeMacAction()
        }
    }
}
