import Foundation

// Keep Awake on the wire (Core/KeepAwake.swift has the shapes). Its own delegate protocols, like
// the volume's (VolumeLink.swift), so the two big delegates stay as they are.

/// The Mac app's side: Keep Awake as it is, and a phone asking for a change.
@MainActor
public protocol LinkServerKeepAwakeDelegate: AnyObject {
    /// For the welcome (nil: say nothing).
    func keepAwakeStatus(_ server: LinkServer) -> KeepAwakeStatus?
    func linkServer(_ server: LinkServer, keepAwake request: KeepAwakeRequest, from peerID: UUID)
}

/// The phone's side: Keep Awake on the Mac it came from.
@MainActor
public protocol LinkClientKeepAwakeDelegate: AnyObject {
    func linkClient(_ client: LinkClient, keepAwake: KeepAwakeStatus, macID: UUID)
}

extension LinkServer {
    @MainActor func keepAwakeOnMain() -> KeepAwakeStatus? {
        (delegate as? LinkServerKeepAwakeDelegate)?.keepAwakeStatus(self)
    }

    func handleKeepAwake(_ request: KeepAwakeRequest, from peerID: UUID) {
        Task { @MainActor [weak self] in
            guard let self, let d = self.delegate as? LinkServerKeepAwakeDelegate else { return }
            d.linkServer(self, keepAwake: request, from: peerID)
        }
    }

    /// Keep Awake changed: every phone that shows it hears (never one that didn't name it).
    public func broadcastKeepAwake(_ status: KeepAwakeStatus) {
        for id in phones(with: KeepAwakeStatus.feature) { Task { await self.send(.keepAwake(status), to: id) } }
    }
}

extension LinkClient {
    /// The connected Mac has Keep Awake (its welcome names it).
    public var macCanKeepAwake: Bool { macFeatures.contains(KeepAwakeStatus.feature) }

    /// Asks the Mac to turn Keep Awake on or off, the displays, the timer. False when it can't be asked.
    @discardableResult
    public func keepAwake(_ request: KeepAwakeRequest) -> Bool {
        guard macCanKeepAwake, request.isValid, let s = currentSession else { return false }
        Task { try? await s.send(.keepAwakeSet(request)) }
        return true
    }

    func deliverKeepAwake(_ k: KeepAwakeStatus, macID: UUID) {
        Task { @MainActor [weak self] in
            guard let self, let d = self.delegate as? LinkClientKeepAwakeDelegate else { return }
            d.linkClient(self, keepAwake: k, macID: macID)
        }
    }
}
