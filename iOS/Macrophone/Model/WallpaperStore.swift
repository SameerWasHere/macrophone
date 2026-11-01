import Combine
import Foundation
import MacrophoneKit
import UIKit

/// The connected Mac's desktop picture (Nov 1 2026, Sameer: "imagine if Apple built a Mac
/// controller for the iPhone"): the phone is drawn as a little macOS desktop, and behind it goes
/// the Mac's own wallpaper. The Mac sends it after every welcome and whenever it changes
/// (MacrophoneKit Core/MacWallpaper.swift: the whole picture, at most 2,400 px on its long side —
/// fill the screen with it, the slice is the screen's to choose).
///
/// Each Mac's last picture is kept on disk (`wallpaper-<mac>.jpg`, and its id and darkness beside it
/// in `wallpaper-<mac>.json`), so it's there at launch before any Mac answers, and a switch to
/// another Mac brings that Mac's back at once. The screens read `model.wallpaper.image` — nil
/// until the active Mac has sent one (draw the app's own ground then).
@MainActor
final class WallpaperStore: ObservableObject {
    /// The active Mac's desktop picture, decoded and ready to draw (nil: none from it yet).
    @Published private(set) var image: UIImage?
    /// That picture is mostly dark, as the Mac measured it (nil: not known).
    @Published private(set) var isDark: Bool?
    /// The Mac whose picture shows.
    private(set) var macID: UUID?
    /// The id (a hash of its bytes) of the picture kept for each Mac, as far as this run knows.
    private var kept: [UUID: String] = [:]
    /// Bumped on every change of Mac or picture: a decode that finishes late never lands.
    private var generation = 0
    /// MACROPHONE_FAKE_WALLPAPER=1: the drawn demo picture, whatever the Macs send.
    private var fake = false

    /// What's kept beside each picture.
    private struct Info: Codable { var id: String; var width: Int; var height: Int; var isDark: Bool? }

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["MACROPHONE_FAKE_WALLPAPER"] == "1" {
            fake = true
            let gen = generation
            Task.detached(priority: .userInitiated) {
                guard let w = MacWallpaper.demo(), let ui = Self.decode(w.jpeg) else { return }
                await self.show(ui, isDark: w.isDark, generation: gen)
            }
        }
        #endif
    }

    /// The active Mac changed (at launch too): its kept picture, or none.
    func useMac(_ id: UUID?) {
        guard id != macID else { return }
        macID = id
        guard !fake else { return }
        generation += 1
        let gen = generation
        guard let id else { image = nil; isDark = nil; return }
        Task.detached(priority: .userInitiated) {
            let (ui, info) = Self.load(id)
            await self.restored(ui, info: info, for: id, generation: gen)
        }
    }

    /// A picture from a Mac: kept for it, and shown if it's the active one (the same one again is
    /// left as it is).
    func received(_ w: MacWallpaper, from mac: UUID) {
        guard kept[mac] != w.id else { return }
        kept[mac] = w.id
        let active = mac == macID && !fake
        if active { generation += 1 }
        let gen = generation
        Task.detached(priority: .userInitiated) {
            Self.save(w, for: mac)
            guard active, let ui = Self.decode(w.jpeg) else { return }
            await self.show(ui, isDark: w.isDark, generation: gen)
        }
    }

    /// A Mac was unpaired: its picture goes too.
    nonisolated static func forget(_ mac: UUID) {
        try? FileManager.default.removeItem(at: jpegURL(mac))
        try? FileManager.default.removeItem(at: infoURL(mac))
    }

    private func restored(_ ui: UIImage?, info: Info?, for mac: UUID, generation gen: Int) {
        guard gen == generation, mac == macID else { return }
        if let info { kept[mac] = info.id }
        image = ui
        isDark = ui == nil ? nil : info?.isDark
    }

    private func show(_ ui: UIImage, isDark dark: Bool?, generation gen: Int) {
        guard gen == generation else { return }
        image = ui
        isDark = dark
    }

    // MARK: On disk (off the main thread)

    nonisolated private static func jpegURL(_ mac: UUID) -> URL { AppFiles.directory.appendingPathComponent("wallpaper-\(mac.uuidString).jpg") }
    nonisolated private static func infoURL(_ mac: UUID) -> URL { AppFiles.directory.appendingPathComponent("wallpaper-\(mac.uuidString).json") }

    nonisolated private static func save(_ w: MacWallpaper, for mac: UUID) {
        try? w.jpeg.write(to: jpegURL(mac), options: .atomic)
        if let d = try? JSONEncoder().encode(Info(id: w.id, width: w.width, height: w.height, isDark: w.isDark)) {
            try? d.write(to: infoURL(mac), options: .atomic)
        }
    }

    nonisolated private static func load(_ mac: UUID) -> (UIImage?, Info?) {
        guard let jpeg = try? Data(contentsOf: jpegURL(mac)) else { return (nil, nil) }
        let info = (try? Data(contentsOf: infoURL(mac))).flatMap { try? JSONDecoder().decode(Info.self, from: $0) }
        return (decode(jpeg), info)
    }

    /// Decoded here, so the first time it's drawn costs the main thread nothing.
    nonisolated private static func decode(_ jpeg: Data) -> UIImage? {
        guard let ui = UIImage(data: jpeg) else { return nil }
        return ui.preparingForDisplay() ?? ui
    }
}

extension AppModel: LinkClientWallpaperDelegate {
    func linkClient(_ client: LinkClient, macWallpaper w: MacWallpaper, macID: UUID) {
        log.add("wallpaper: \(w.jpeg.count / 1024) KB, \(w.width)×\(w.height)")
        wallpaper.received(w, from: macID)
    }
}
