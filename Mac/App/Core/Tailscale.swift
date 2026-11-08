import AppKit
import Combine
import MacrophoneKit

/// What this Mac's Tailscale is doing, as far as Macrophone can see without its CLI (Nov 7 2026):
/// the app installed (either the Mac App Store's or the standalone one), running, and connected —
/// an address in 100.64.0.0/10 on one of this Mac's interfaces — plus its MagicDNS name.
struct TailscaleState: Equatable {
    var installed = false
    var running = false
    /// This Mac's Tailscale address (100.x.y.z) while it's connected.
    var address: String?
    /// "sameers-macbook-pro.tail1234.ts.net", read by a reverse lookup of the address.
    var name: String?

    var connected: Bool { address != nil }
}

/// Looks at Tailscale every two seconds while a page showing it is open (the setup's Away page,
/// Devices › Away from home), and when the network changes otherwise. It only ever looks: it never
/// starts, stops or signs in to Tailscale.
@MainActor
final class TailscaleMonitor: ObservableObject {
    /// The standalone download's id first, then the Mac App Store's.
    static let bundleIDs = ["io.tailscale.ipn.macsys", "io.tailscale.ipn.macos"]
    /// Tailscale in the Mac App Store, and its page for the iPhone (the QR code on the guide).
    static let macAppStore = URL(string: "macappstore://apps.apple.com/app/id1475387142")!
    static let iPhoneAppStore = URL(string: "https://apps.apple.com/app/tailscale/id1470499037")!

    @Published private(set) var state = TailscaleState()
    /// Called whenever the state changes (AppModel turns Remote access on).
    var onChange: ((TailscaleState) -> Void)?

    private var viewers = 0
    private var timer: Timer?
    private var names: [String: String] = [:]
    private var lookingUp: String?

    /// A page showing Tailscale appeared (or went): look every two seconds while any is up.
    func viewerAppeared() {
        viewers += 1
        refresh()
        guard timer == nil else { return }
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        t.tolerance = 0.3
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func viewerGone() {
        viewers = max(0, viewers - 1)
        if viewers == 0 { timer?.invalidate(); timer = nil }
    }

    func refresh() {
        let address = NetworkAddresses.current().first(where: \.isTailscale)?.host
        let running = Self.bundleIDs.contains { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
        // A Tailscale address means it's there, whatever app (or command-line daemon) put it there.
        var s = TailscaleState(installed: Self.appURL != nil || address != nil, running: running || address != nil,
                               address: address, name: address.flatMap { names[$0] })
        #if DEBUG
        if let fake = Self.fake { s = fake }
        #endif
        if let a = s.address, s.name == nil, names[a] == nil, lookingUp != a { lookUpName(a) }
        guard s != state else { return }
        state = s
        onChange?(s)
    }

    private func lookUpName(_ address: String) {
        lookingUp = address
        Task { [weak self] in
            let name = await NetworkAddresses.tailscaleName(for: address)
            guard let self else { return }
            self.lookingUp = nil
            guard let name else { return }
            self.names[address] = name
            self.refresh()
        }
    }

    /// Where Tailscale is installed, if it is.
    static var appURL: URL? {
        for id in bundleIDs {
            if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return u }
        }
        let path = "/Applications/Tailscale.app"
        return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    /// Get Tailscale: its page in the Mac App Store.
    func getTailscale() { NSWorkspace.shared.open(Self.macAppStore) }

    /// Sign in: opens Tailscale (its window or its menu bar icon is where you sign in).
    func openTailscale() {
        guard let url = Self.appURL else { getTailscale(); return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    #if DEBUG
    /// MACROPHONE_FAKE_TAILSCALE=missing | installed | running | connected — a stand-in for the
    /// screenshots (this Mac's real Tailscale is left alone).
    static var fake: TailscaleState? {
        switch ProcessInfo.processInfo.environment["MACROPHONE_FAKE_TAILSCALE"] {
        case "missing": return TailscaleState()
        case "installed": return TailscaleState(installed: true)
        case "running", "stopped": return TailscaleState(installed: true, running: true)
        case "connected": return TailscaleState(installed: true, running: true, address: "100.101.2.3", name: "sameers-macbook-pro.tail4c2e.ts.net")
        default: return nil
        }
    }
    #endif
}
