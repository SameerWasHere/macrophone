import Foundation

// The Mac's desktop picture on the wire (Core/MacWallpaper.swift has the rule). Its own delegate
// protocols, like the permissions' (PermissionsLink.swift), so the two big delegates stay as they
// are: the Mac app's delegate and the phone's adopt these as well, and an object that doesn't
// simply never hears of them.

/// The Mac app's side: its desktop picture, when a phone that shows it connects.
@MainActor
public protocol LinkServerWallpaperDelegate: AnyObject {
    /// The desktop picture as it is now, for this phone (nil: say nothing). It may take a moment
    /// the first time — drawing it belongs off the main thread; the session carries on meanwhile.
    func macWallpaper(_ server: LinkServer, for peerID: UUID) async -> MacWallpaper?
}

/// The phone's side: the desktop picture of the Mac it came from.
@MainActor
public protocol LinkClientWallpaperDelegate: AnyObject {
    func linkClient(_ client: LinkClient, macWallpaper: MacWallpaper, macID: UUID)
}

extension LinkServer {
    /// Right after the welcome, to a phone that named it: asked of the delegate and sent on a task
    /// of its own, so the receive loop never waits for a picture to be drawn.
    func sendWallpaperAfterWelcome(to peerID: UUID, on session: SecureSession) {
        Task { [weak self] in
            guard let self else { return }
            let t0 = Date()
            guard let w = await self.wallpaperOnMain(for: peerID), w.isValid else { return }
            do { try await session.send(.macWallpaper(w)) } catch { return }
            self.logWallpaper(w, since: t0)
        }
    }

    @MainActor func wallpaperOnMain(for peerID: UUID) async -> MacWallpaper? {
        guard let d = delegate as? LinkServerWallpaperDelegate else { return nil }
        return await d.macWallpaper(self, for: peerID)
    }

    /// The desktop picture changed: send it to this phone — only if its hello named it (an older
    /// phone never gets a message it can't read). False when it didn't, or isn't connected.
    @discardableResult
    public func sendWallpaper(_ wallpaper: MacWallpaper, to peerID: UUID) async -> Bool {
        guard wallpaper.isValid, phoneFeatures(peerID).contains(MacWallpaper.feature) else { return false }
        let t0 = Date()
        guard await send(.macWallpaper(wallpaper), to: peerID) else { return false }
        logWallpaper(wallpaper, since: t0)
        return true
    }

    /// The desktop picture changed: tell every phone that shows it.
    public func broadcastWallpaper(_ wallpaper: MacWallpaper) {
        for id in phones(with: MacWallpaper.feature) { Task { await self.sendWallpaper(wallpaper, to: id) } }
    }

    /// Sizes and the time it took, nothing of the picture.
    private func logWallpaper(_ w: MacWallpaper, since t0: Date) {
        log?.add("wallpaper: sent \(w.jpeg.count / 1024) KB, \(w.width)×\(w.height), in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
    }
}

extension LinkClient {
    /// The connected Mac shows its desktop picture to a phone that asks (its welcome names it).
    public var macSendsWallpaper: Bool { macFeatures.contains(MacWallpaper.feature) }

    func deliverWallpaper(_ w: MacWallpaper, macID: UUID) {
        guard w.isValid else { log?.add("wallpaper from the Mac couldn't be used"); return }
        Task { @MainActor [weak self] in
            guard let self, let d = self.delegate as? LinkClientWallpaperDelegate else { return }
            d.linkClient(self, macWallpaper: w, macID: macID)
        }
    }
}
