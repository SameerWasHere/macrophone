import AppKit
import MacrophoneKit

/// The Mac's grants on the link (Oct 19 2026): a phone that names `MacPermissions.feature` hears
/// them after its welcome and whenever one changes, and can ask for the permissions page to come
/// forward here ("Open Macrophone on my Mac").
extension AppModel: LinkServerPermissionsDelegate {
    func watchPermissions() {
        permissions.onChange = { [weak self] p in
            guard let self else { return }
            self.log.add("permissions: Accessibility \(p.accessibility ? "on" : "off") · Screen Recording \(p.screenRecording ? "on" : "off")")
            self.refreshAccessibility()
            self.server.broadcastPermissions(p)
        }
    }

    func macPermissions(_ server: LinkServer) -> MacPermissions? {
        permissions.refresh()
        return permissions.current
    }

    func linkServerShowPermissions(_ server: LinkServer, from peerID: UUID) {
        log.add("a phone asked to see the permissions")
        AppDelegate.shared?.openSetup(.permissions)
    }
}
