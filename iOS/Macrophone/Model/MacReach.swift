import Foundation
import MacrophoneKit
import SwiftUI

/// "Control the Mac entirely from the iPhone" (Oct 19 2026), the phone's side: the Mac's displays
/// (a Whole Screen per display when there are two or more), Mac Controls (volume, brightness,
/// media — the keyboard's top row) and Wake Your Mac. Each only with a Mac whose welcome names it.
@MainActor
final class MacReach: ObservableObject {
    static let shared = MacReach()

    /// The connected Mac's displays, as it last said.
    @Published private(set) var displays: [MacDisplay] = []
    /// A wake was just sent: the button says so, and the phone keeps looking.
    @Published private(set) var waking = false
    /// The wake info changed (kept with the pairing) — the wake button reads it again.
    @Published private(set) var wakeVersion = 0

    private var wakeTask: Task<Void, Never>?
    private static let displayKey = "watch.display"

    private init() {
        #if DEBUG
        // MACROPHONE_FAKE_DISPLAYS=1: two displays without a Mac that has them.
        if DebugHooks.env["MACROPHONE_FAKE_DISPLAYS"] == "1" {
            displays = [MacDisplay(id: "fake-built-in", name: "Built-in Retina Display", x: 0, y: 0, width: 1512, height: 982, isMain: true),
                        MacDisplay(id: "fake-studio", name: "Studio Display", x: -2560, y: -300, width: 2560, height: 1440, isMain: false)]
        }
        #endif
    }

    func set(_ list: [MacDisplay]) { displays = Displays.ordered(list) }

    /// Picking one per display makes sense (two or more).
    var several: Bool { displays.count > 1 }

    /// The display picked last, while the Mac still has it.
    var lastDisplay: MacDisplay? {
        guard several else { return nil }
        return Displays.resolve(UserDefaults.standard.string(forKey: Self.displayKey), in: displays)
    }

    func remember(_ d: MacDisplay) { UserDefaults.standard.set(d.id, forKey: Self.displayKey) }

    /// The Whole Screen place to open: the last display picked (or the main one) when there are
    /// two or more; the one Whole Screen otherwise.
    var wholeScreenTarget: TargetRef {
        guard several, let d = lastDisplay else { return DesktopWatch.target }
        return Displays.target(for: d, among: displays)
    }

    func target(for d: MacDisplay) -> TargetRef { Displays.target(for: d, among: displays) }

    func wakeInfoChanged() { wakeVersion &+= 1 }

    // MARK: Wake

    /// Sends the magic packet, then keeps looking for the Mac for a while.
    func wake(_ info: WakeInfo, model: AppModel) {
        guard !waking else { return }
        waking = true
        Haptics.tick()
        model.explain("Waking your Mac — on this Wi-Fi only. A closed laptop on battery may not wake.", for: 6)
        wakeTask?.cancel()
        wakeTask = Task { [weak self, weak model] in
            var extra: UInt16?
            #if DEBUG
            // MACROPHONE_WAKE_PORT=<n>: also to this port (the demo Mac counts what reaches it).
            extra = DebugHooks.env["MACROPHONE_WAKE_PORT"].flatMap(UInt16.init)
            #endif
            let sent = await WakeOnLAN.wake(info, extraPort: extra)
            model?.log.add("wake: \(sent.sent) packets sent, \(sent.failed) not sent")
            // Keep looking: a Mac takes a few seconds to wake and come back on the network.
            for _ in 0..<12 {
                guard let model, !Task.isCancelled, !model.isConnected else { break }
                model.client.ensureConnected()
                try? await Task.sleep(nanoseconds: 2_500_000_000)
            }
            guard let self else { return }
            self.waking = false
            if let model, !model.isConnected {
                model.explain("\(model.macName) didn't wake. Check it's on this Wi-Fi with Wake for network access on, or open the lid.", for: 6)
            }
        }
    }
}

extension AppModel {
    var reach: MacReach { MacReach.shared }

    /// The Mac shows one display's whole screen (and it's remembered for next time).
    func watchWholeScreen(_ display: MacDisplay) {
        guard isConnected, watcher.canWatchDesktop else { return }
        Haptics.tick()
        reach.remember(display)
        if settings.selection.target != .frontApp { pick(.frontApp) }
        watcher.open(reach.target(for: display))
    }

    /// The Mac presses its volume, brightness or media key.
    var canMacControls: Bool { isConnected && client.macFeatures.contains(MacControl.feature) }

    func press(_ control: MacControl) {
        guard canMacControls else { return }
        Haptics.tick()
        if !client.macControl(control) { explain("Connect to your Mac first") }
    }

    /// The wake info for the paired Mac, when waking it could work from here: paired, not
    /// connected, and this phone on a network the Mac was on.
    var wakeInfoHere: WakeInfo? {
        _ = reach.wakeVersion
        guard isPaired, !isConnected, let info = WakeOnLAN.info(for: pairedMac?.id), !info.interfaces.isEmpty,
              WakeOnLAN.onSameNetwork(as: info) else { return nil }
        if case .connecting = linkState { return nil }
        return info
    }

    func wakeMac() {
        guard let info = WakeOnLAN.info(for: pairedMac?.id) else { return }
        reach.wake(info, model: self)
    }

    // MARK: The link

    func linkClient(_ client: LinkClient, displays: [MacDisplay]) {
        guard client === self.client else { return }
        reach.set(displays)
        log.add("the Mac has \(displays.count) display(s)")
    }

    func linkClient(_ client: LinkClient, wakeInfo: WakeInfo, macID: UUID) {
        guard client === self.client else { return }
        WakeOnLAN.save(wakeInfo, for: macID)
        reach.wakeInfoChanged()
        log.add("wake info: \(wakeInfo.interfaces.count) interface(s), wake for network \(wakeInfo.wakeForNetwork.map { $0 ? "on" : "off" } ?? "unknown")")
    }

    func linkClient(_ client: LinkClient, macControlDone result: MacControlResult) {
        guard client === self.client else { return }
        if !result.ok { Haptics.warning() }
        explain(result.detail, for: result.ok ? 1.6 : 4)
    }
}

#if DEBUG
extension MacReach {
    /// MACROPHONE_REACH (DebugHooks): the three features driven headlessly.
    static func debugHooks(_ model: AppModel) {
        guard let steps = DebugHooks.env["MACROPHONE_REACH"]?.split(separator: ",").map(String.init), !steps.isEmpty else { return }
        Task { @MainActor in
            let waitForMac = steps.contains { $0 != "wake" }
            if waitForMac { for _ in 0..<60 where !model.isConnected { try? await Task.sleep(nanoseconds: 250_000_000) } }
            for s in steps {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if s == "whole" {
                    model.watchWholeScreen()
                } else if s.hasPrefix("whole@") {
                    let id = String(s.dropFirst(6))
                    if let d = shared.displays.first(where: { $0.id == id }) { model.watchWholeScreen(d) }
                } else if s.hasPrefix("control@"), let c = MacControl(rawValue: String(s.dropFirst(8))) {
                    model.press(c)
                } else if s == "wake" {
                    if let info = WakeOnLAN.info(for: model.pairedMac?.id) { shared.wake(info, model: model) }
                    else { model.log.add("wake: no wake info kept") }
                }
            }
        }
    }
}
#endif

