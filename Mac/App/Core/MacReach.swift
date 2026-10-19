import AppKit
import Foundation
import MacrophoneKit

/// "Control the Mac entirely from the iPhone" (Oct 19 2026), the link's side: the displays and the
/// wake info go to every phone that named them (after welcome, and when they change); a Mac
/// Controls key from a phone is pressed and answered.
extension AppModel {
    /// Once, at launch: listen for displays and the network changing.
    func startMacReach() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.broadcastDisplays() }
        }
        let wake = MacWake.shared
        wake.onChange = { [weak self] info in
            guard let self else { return }
            for id in self.server.phones(with: WakeInfo.feature) { Task { await self.server.send(.wakeInfo(info), to: id) } }
            self.log.add("wake info: \(info.interfaces.count) interface(s), wake for network \(info.wakeForNetwork.map { $0 ? "on" : "off" } ?? "unknown")")
        }
        wake.start()
    }

    /// A phone connected: what it asked to hear.
    func tellMacReach(_ peerID: UUID) {
        let server = self.server
        if server.phones(with: Displays.feature).contains(peerID) {
            let list = MacDisplays.current()
            Task { await server.send(.displays(list), to: peerID) }
        }
        if server.phones(with: WakeInfo.feature).contains(peerID) {
            let info = MacWake.shared.info
            if !info.interfaces.isEmpty { Task { await server.send(.wakeInfo(info), to: peerID) } }
            MacWake.shared.refresh()
        }
    }

    private func broadcastDisplays() {
        let list = MacDisplays.current()
        let phones = server.phones(with: Displays.feature)
        guard !phones.isEmpty else { return }
        log.add("displays changed: \(list.count)")
        for id in phones { Task { await server.send(.displays(list), to: id) } }
    }

    func linkServer(_ server: LinkServer, macControl control: MacControl, from peerID: UUID) {
        Task { @MainActor in
            let result = await MediaKeys.press(control)
            log.add("mac control: \(control.rawValue) \(result.ok ? "pressed" : "not pressed")")
            await server.send(.macControlDone(result), to: peerID)
        }
    }
}
