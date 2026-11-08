import MacrophoneKit
import SwiftUI

// Away from home, guided (Nov 7 2026, Sameer: "we need to stick with Tailscale … the Mac app and
// iOS app should guide users through the setup clearly"). What the phone can tell for itself:
// whether the Mac shared a Tailscale address, whether this iPhone is on Tailscale, and — by a test
// dial — whether the Mac answers over it. The one-time offer after the first pairing, and the way
// into the guide from anywhere.

extension AppModel {
    /// What the active Mac last said about being reached from away.
    var macAway: MacAwayReadiness {
        #if DEBUG
        switch ProcessInfo.processInfo.environment["MACROPHONE_FAKE_AWAY"] {
        case "tailscale"?: return .ready
        case "remote"?: return .noTailscale
        case "off"?: return .off
        default: break
        }
        #endif
        let told = macToldAddresses
        if told.contains(where: \.isTailscale) { return .ready }
        return told.isEmpty ? .off : .noTailscale
    }

    /// The Mac's Tailscale address as it shared it (for the guide to show; never logged).
    var macTailscaleAddress: String? {
        #if DEBUG
        if ProcessInfo.processInfo.environment["MACROPHONE_FAKE_AWAY"] == "tailscale" { return "100.101.2.3:47821" }
        #endif
        return macToldAddresses.first(where: { RemoteAddressRule.isTailscale($0.host) })?.display
            ?? macToldAddresses.first(where: \.isTailscale)?.display
    }

    /// Everything's in place on both ends, as far as the phone can tell without dialling.
    var awayReady: Bool { macAway == .ready && TailscaleHere.isOn }

    /// The guide's Test it: dial the Mac's Tailscale address now and say what happened.
    func testAway() async -> AwayProbeResult {
        #if DEBUG
        if let fake = ProcessInfo.processInfo.environment["MACROPHONE_FAKE_AWAY_TEST"] {
            try? await Task.sleep(for: .milliseconds(900))
            switch fake {
            case "works": return .works
            case "remoteOff": return .remoteOff
            case "notThisMac": return .notThisMac
            case "noAddress": return .noAddress
            default: return .unreachable
            }
        }
        #endif
        log.add("away test asked (this iPhone on Tailscale: \(TailscaleHere.isOn ? "yes" : "no"))")
        #if DEBUG
        // MACROPHONE_AWAY_TEST_ADDRESS=host:port: the real test, dialled at this address instead of
        // the Mac's Tailscale one (a Mac can't reach its own Tailscale address, so the simulator
        // proves the path on loopback against `mpctl serve --remote`).
        if let a = ProcessInfo.processInfo.environment["MACROPHONE_AWAY_TEST_ADDRESS"].flatMap({ RemoteAddressRule.parse($0) }) {
            return await client.probeAway(addresses: [a])
        }
        #endif
        return await client.probeAway()
    }

    // MARK: The way in

    /// Opens Settings at the away guide (from the offer, the desktop's empty state).
    func openAwayGuide() {
        let open = { [weak self] in
            guard let self else { return }
            self.settingsOpenPath = [.connection, .awaySetup]
            self.sheet = .settings
        }
        if sheet == nil { open(); return }
        // A sheet is up (the offer itself): let it go first, then rise.
        sheet = nil
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(650))
            open()
        }
    }

    // MARK: The offer, once

    private static let offeredKey = "away.offered"

    /// Set Up or Not Now was answered (or there was nothing to set up): never asked again.
    var awayOffered: Bool {
        get { UserDefaults.standard.bool(forKey: Self.offeredKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.offeredKey) }
    }

    /// After a Mac is paired (setup finished, or the pairing sheet closed): "Use it away from
    /// home?" — once ever, and only with nothing else on screen.
    func offerAwayIfDue(after delay: Double = 0.7) {
        guard isPaired, !awayOffered else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard isPaired, !awayOffered, !showOnboarding, sheet == nil else { return }
            if awayReady { awayOffered = true; return }   // already set up: nothing to offer
            log.add("away from home offered")
            sheet = .awayOffer
        }
    }
}

/// What the desktop's "Can't find ‹Mac›" offers when this iPhone isn't on a network the Mac was
/// on (Nov 7 2026): set Tailscale up, turn it on here, or check the path — never Wake, which only
/// works on the Mac's own Wi-Fi.
enum AwayHelp: Equatable {
    /// The Mac has never shared a Tailscale address: set up away from home.
    case setUp
    /// The Mac is ready; this iPhone isn't on Tailscale.
    case turnOnTailscale
    /// Both ends look ready and the Mac still didn't answer: test the path.
    case check
}

extension AppModel {
    /// Nil at home (a network the Mac was on — Wake Your Mac's place) or with no Mac paired.
    var awayHelp: AwayHelp? {
        guard isPaired, wakeInfoHere == nil else { return nil }
        if macAway != .ready { return .setUp }
        return TailscaleHere.isOn ? .check : .turnOnTailscale
    }
}
