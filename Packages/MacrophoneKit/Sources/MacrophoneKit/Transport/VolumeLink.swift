import Foundation

// The Mac's volume on the wire (Core/MacVolume.swift has the rule). Its own delegate protocols,
// like the wallpaper's (WallpaperLink.swift), so the two big delegates stay as they are.

/// The Mac app's side: its output volume, when a phone that shows it connects.
@MainActor
public protocol LinkServerVolumeDelegate: AnyObject {
    /// The volume and mute as they are now, for this phone (nil: say nothing).
    func macVolume(_ server: LinkServer, for peerID: UUID) -> MacVolume?
}

/// The phone's side: the volume of the Mac it came from.
@MainActor
public protocol LinkClientVolumeDelegate: AnyObject {
    func linkClient(_ client: LinkClient, macVolume: MacVolume, macID: UUID)
}

extension LinkServer {
    /// Right after the welcome, to a phone that named it, on a task of its own.
    func sendVolumeAfterWelcome(to peerID: UUID, on session: SecureSession) {
        Task { [weak self] in
            guard let self, let v = await self.volumeOnMain(for: peerID) else { return }
            try? await session.send(.macVolume(v))
        }
    }

    @MainActor func volumeOnMain(for peerID: UUID) -> MacVolume? {
        (delegate as? LinkServerVolumeDelegate)?.macVolume(self, for: peerID)
    }

    /// The volume changed: send it to this phone — only if its hello named it (an older phone
    /// never gets a message it can't read). False when it didn't, or isn't connected.
    @discardableResult
    public func sendMacVolume(_ volume: MacVolume, to peerID: UUID) async -> Bool {
        guard phoneFeatures(peerID).contains(MacVolume.feature) else { return false }
        return await send(.macVolume(volume), to: peerID)
    }

    /// The volume changed: tell every phone that shows it.
    public func broadcastMacVolume(_ volume: MacVolume) {
        for id in phones(with: MacVolume.feature) { Task { await self.sendMacVolume(volume, to: id) } }
    }
}

extension LinkClient {
    /// The connected Mac says its volume (its welcome names it).
    public var macSendsVolume: Bool { macFeatures.contains(MacVolume.feature) }

    func deliverVolume(_ v: MacVolume, macID: UUID) {
        Task { @MainActor [weak self] in
            guard let self, let d = self.delegate as? LinkClientVolumeDelegate else { return }
            d.linkClient(self, macVolume: v, macID: macID)
        }
    }
}
