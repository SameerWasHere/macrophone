import Foundation

// The fitted Whole Screen on the wire (Core/FittedScreen.swift has the rule). Its own delegate
// protocols, like the volume's (VolumeLink.swift), so the two big delegates stay as they are.

/// The Mac app's side: a phone asking for the whole screen at its view's shape, or back.
@MainActor
public protocol LinkServerFittedScreenDelegate: AnyObject {
    func linkServer(_ server: LinkServer, screenFit request: FittedScreenRequest, from peerID: UUID)
}

/// The phone's side: how the fitted screen stands on the Mac it came from.
@MainActor
public protocol LinkClientFittedScreenDelegate: AnyObject {
    func linkClient(_ client: LinkClient, screenFit state: FittedScreenState, macID: UUID)
}

extension LinkServer {
    func handleScreenFit(_ request: FittedScreenRequest, from peerID: UUID) {
        Task { @MainActor [weak self] in
            guard let self, let d = self.delegate as? LinkServerFittedScreenDelegate else { return }
            d.linkServer(self, screenFit: request, from: peerID)
        }
    }

    /// How the fitted screen stands, to this phone — only if its hello named it. False when it
    /// didn't, or isn't connected.
    @discardableResult
    public func sendScreenFit(_ state: FittedScreenState, to peerID: UUID) async -> Bool {
        guard phoneFeatures(peerID).contains(FittedScreen.feature) else { return false }
        return await send(.screenFitState(state), to: peerID)
    }
}

extension LinkClient {
    /// The connected Mac can fit its whole screen to this phone (its welcome names it).
    public var macFitsScreen: Bool { macFeatures.contains(FittedScreen.feature) }

    /// Asks the Mac for its whole screen at this view's shape, or back as it was. False when it
    /// can't be asked (not connected, a Mac from before).
    @discardableResult
    public func screenFit(_ request: FittedScreenRequest) -> Bool {
        guard macFitsScreen, let s = currentSession else { return false }
        s.post(.screenFit(request))
        return true
    }

    func deliverScreenFit(_ state: FittedScreenState, macID: UUID) {
        Task { @MainActor [weak self] in
            guard let self, let d = self.delegate as? LinkClientFittedScreenDelegate else { return }
            d.linkClient(self, screenFit: state, macID: macID)
        }
    }
}
