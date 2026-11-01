import AppKit
import Foundation
import ImageIO
import MacrophoneKit

/// The Mac's desktop picture for the phones that show it (Nov 1 2026, Sameer: "imagine if Apple
/// built a Mac controller for the iPhone"): the phone is drawn as a little macOS desktop, and this
/// Mac's own wallpaper goes behind it. A phone that names MacWallpaper.feature gets it after its
/// welcome (LinkServer asks `macWallpaper(_:for:)`) and again whenever it changes — another
/// space, a display plugged in or out, or the file itself (looked at every 30 s while such a phone
/// is connected).
///
/// The main screen's picture (the one with the menu bar), read with ImageIO at 2,400 px on the long
/// side — a dynamic or a rotating wallpaper still names its current file — else whatever
/// `NSImage(contentsOf:)` makes of it; a folder or something unreadable sends nothing. It's drawn
/// off the main thread, once per file and change (the file's place and date are kept here to
/// notice a change, and never leave this Mac). The log gets sizes and times only.
@MainActor
final class WallpaperSource {
    static let shared = WallpaperSource()

    private var server: LinkServer?
    private var log: DiagnosticLog?
    /// The file a picture was made from and when it last changed.
    private struct Source: Equatable { let url: URL; let modified: Date?; let size: Int? }
    private var made: (source: Source, wallpaper: MacWallpaper)?
    /// A file that couldn't be made into a picture (not tried again until it changes).
    private var failed: Source?
    private var making: (source: Source, task: Task<MacWallpaper?, Never>)?
    /// The picture each connected phone last got, so a change goes once, to the phones without it.
    private var sent: [UUID: String] = [:]
    private var poll: Timer?
    private var settle: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    /// Once, at launch.
    func start(server: LinkServer, log: DiagnosticLog) {
        self.server = server
        self.log = log
        guard observers.isEmpty else { return }
        // Each space can have its own picture; displays coming and going can change the main one.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkSoon() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkSoon() }
        })
    }

    /// For a phone that just connected: the picture as it is now (made if the file changed).
    func wallpaper(for peerID: UUID) async -> MacWallpaper? {
        startPolling()
        guard let w = await current() else { return nil }
        sent[peerID] = w.id
        return w
    }

    /// The space or the displays changed: the picture follows a moment later.
    private func checkSoon() {
        settle?.cancel()
        settle = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            self?.check()
        }
    }

    /// If the picture changed, every phone that shows it and hasn't got this one gets it. With no
    /// such phone connected the looking stops (the next phone starts it again).
    func check() {
        guard let server else { return }
        let phones = server.phones(with: MacWallpaper.feature)
        sent = sent.filter { phones.contains($0.key) }
        guard !phones.isEmpty else { stopPolling(); return }
        Task { [weak self] in
            guard let self, let w = await self.current() else { return }
            for id in server.phones(with: MacWallpaper.feature) where self.sent[id] != w.id {
                self.sent[id] = w.id
                Task { await server.sendWallpaper(w, to: id) }
            }
        }
    }

    private func startPolling() {
        guard poll == nil else { return }
        let t = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        t.tolerance = 5
        poll = t
    }

    private func stopPolling() {
        poll?.invalidate()
        poll = nil
    }

    /// The picture for the main screen's file as it is now: the one made already, the one being
    /// made, or made now (off the main thread).
    private func current() async -> MacWallpaper? {
        guard let source = Self.readSource() else { return nil }
        if let made, made.source == source { return made.wallpaper }
        if failed == source { return nil }
        if let making, making.source == source { return await making.task.value }
        let url = source.url
        let t0 = Date()
        let task = Task.detached(priority: .utility) { Self.render(url) }
        making = (source, task)
        let w = await task.value
        if making?.source == source { making = nil }
        if let w {
            made = (source, w)
            failed = nil
            log?.add("wallpaper: made \(w.jpeg.count / 1024) KB, \(w.width)×\(w.height), in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
        } else {
            failed = source
            log?.add("wallpaper: the desktop picture couldn't be read")
        }
        return w
    }

    /// The main screen's desktop picture file, and when it last changed.
    private static func readSource() -> Source? {
        guard let screen = NSScreen.screens.first, let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return Source(url: url, modified: values?.contentModificationDate, size: values?.fileSize)
    }

    /// ImageIO first (it scales a 6K HEIC as it reads it, and takes a dynamic one's main picture),
    /// else what NSImage makes of the file; then drawn and encoded for the wire.
    nonisolated private static func render(_ url: URL) -> MacWallpaper? {
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: MacWallpaper.maxSide] as CFDictionary
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
           let image = CGImageSourceCreateThumbnailAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), options) {
            return MacWallpaper.make(from: image)
        }
        guard let image = NSImage(contentsOf: url), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return MacWallpaper.make(from: cg)
    }
}

extension AppModel: LinkServerWallpaperDelegate {
    /// Once, at launch: the picture follows the spaces, the displays and the file.
    func watchWallpaper() {
        WallpaperSource.shared.start(server: server, log: log)
    }

    func macWallpaper(_ server: LinkServer, for peerID: UUID) async -> MacWallpaper? {
        await WallpaperSource.shared.wallpaper(for: peerID)
    }
}
