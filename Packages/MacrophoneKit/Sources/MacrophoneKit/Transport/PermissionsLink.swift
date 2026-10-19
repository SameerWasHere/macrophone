import Foundation

// The Mac's permissions on the wire (Core/MacPermissions.swift has the rule). Its own delegate
// protocols, so the two big delegates stay as they are: the Mac app's delegate and the phone's
// adopt these as well, and an object that doesn't simply never hears of them.

/// The Mac app's side: what it's allowed to do, and the phone asking to see the page.
@MainActor
public protocol LinkServerPermissionsDelegate: AnyObject {
    /// The Mac's grants as they are now (nil: don't say).
    func macPermissions(_ server: LinkServer) -> MacPermissions?
    /// A phone asked to bring Macrophone's permissions page forward on the Mac.
    func linkServerShowPermissions(_ server: LinkServer, from peerID: UUID)
}

/// The phone's side: the connected Mac's grants, when it names them.
@MainActor
public protocol LinkClientPermissionsDelegate: AnyObject {
    func linkClient(_ client: LinkClient, macPermissions: MacPermissions)
}

extension LinkServer {
    @MainActor func permissionsOnMain() -> MacPermissions? {
        (delegate as? LinkServerPermissionsDelegate)?.macPermissions(self)
    }

    func notifyPermissions(_ body: @escaping @MainActor (LinkServerPermissionsDelegate) -> Void) {
        Task { @MainActor [weak self] in
            guard let d = self?.delegate as? LinkServerPermissionsDelegate else { return }
            body(d)
        }
    }

    /// A grant changed on the Mac: tell every phone that understands it.
    public func broadcastPermissions(_ permissions: MacPermissions) {
        for id in phones(with: MacPermissions.feature) { Task { await self.send(.macPermissions(permissions), to: id) } }
    }
}

extension LinkClient {
    /// The connected Mac can bring its permissions page forward when asked.
    public var canShowMacPermissions: Bool { currentSession != nil && macFeatures.contains(MacPermissions.feature) }

    /// Ask the Mac to open Macrophone at its permissions (only a Mac that can). False when it can't.
    @discardableResult
    public func showPermissionsOnMac() -> Bool {
        guard macFeatures.contains(MacPermissions.feature), let s = currentSession else { return false }
        Task { try? await s.send(.showPermissions) }
        return true
    }

    func deliverPermissions(_ p: MacPermissions) {
        Task { @MainActor [weak self] in
            guard let self, let d = self.delegate as? LinkClientPermissionsDelegate else { return }
            d.linkClient(self, macPermissions: p)
        }
    }
}
