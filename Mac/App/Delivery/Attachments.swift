import AppKit
import Carbon.HIToolbox
import Foundation
import MacrophoneKit

/// Photos and files from the phone, into the chat (Oct 18 2026). The pieces are put back together,
/// kept in Macrophone's own folder ("From iPhone", a week), and pasted where they're sent: a chat
/// app gets the image or file itself; a terminal gets its path (Claude Code and Codex read images
/// from a path); Clipboard just puts it on the clipboard. Nothing is sent — you say what it's for.
/// The clipboard is put back as it was afterwards. Names and sizes are never logged.
@MainActor
final class AttachmentInbox {
    private unowned let app: AppModel
    private var pending: [UUID: Pending] = [:]

    private struct Pending {
        var parts: [Int: Data] = [:]
        var count: Int
        var filename: String
        var kind: String
        var target: TargetRef
        var started = Date()
    }

    init(app: AppModel) { self.app = app }

    static var folder: URL { AppPaths.supportDirectory.appendingPathComponent("From iPhone", isDirectory: true) }

    /// One piece; the outcome once the last one is in.
    func receive(_ c: AttachmentChunk) async -> (Bool, String)? {
        // Pieces of a send that stalled a minute ago are let go.
        pending = pending.filter { Date().timeIntervalSince($0.value.started) < 60 }
        var p = pending[c.id] ?? Pending(count: c.count, filename: AttachmentChunk.safeName(c.filename), kind: c.kind, target: c.target)
        guard c.count == p.count else { return nil }
        p.parts[c.index] = c.data
        guard p.parts.count == p.count else { pending[c.id] = p; return nil }
        pending[c.id] = nil
        var data = Data()
        for i in 0..<p.count { guard let d = p.parts[i] else { return (false, "Part of it didn't arrive — send it again") }; data.append(d) }
        guard let url = save(data, name: p.filename) else { return (false, "Couldn't save it on your Mac") }
        app.log.add("attachment received (\(p.kind))")
        return await deliver(url, image: p.kind == "image" ? NSImage(contentsOf: url) : nil, to: p.target)
    }

    private func save(_ data: Data, name: String) -> URL? {
        let fm = FileManager.default
        let dir = Self.folder
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // A week is long enough to come back to it.
        if let old = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for f in old where ((try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantFuture)
                .timeIntervalSinceNow < -7 * 86400 { try? fm.removeItem(at: f) }
        }
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var url = dir.appendingPathComponent(name)
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        do { try data.write(to: url, options: .atomic); return url } catch { return nil }
    }

    private func deliver(_ url: URL, image: NSImage?, to target: TargetRef) async -> (Bool, String) {
        let what = image != nil ? "The photo" : "The file"
        let pb = NSPasteboard.general
        if target == .clipboard {
            pb.clearContents()
            pb.writeObjects(image.map { [url as NSURL, $0] } ?? [url as NSURL])
            return (true, "\(what) is on your Mac's clipboard")
        }
        guard Paster.isTrusted else {
            pb.clearContents()
            pb.writeObjects([url as NSURL])
            return (true, "\(what) is on your Mac's clipboard — Macrophone needs Accessibility to paste it")
        }
        let running: NSRunningApplication
        var windowID: CGWindowID?
        switch target {
        case let .app(bid, key, _):
            guard let r = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first(where: { !$0.isTerminated }) else {
                pb.clearContents(); pb.writeObjects([url as NSURL])
                return (false, "That app isn't open — \(what.lowercased()) is on your Mac's clipboard")
            }
            running = r
            windowID = key.flatMap { CGWindowID($0) }
        default:
            guard let f = NSWorkspace.shared.frontmostApplication else { return (false, "No app is in front on your Mac") }
            running = f
        }
        let name = running.localizedName ?? "the app"
        do {
            _ = try await Paster.bringToFront(running, windowID: windowID, required: false, name: name)
        } catch {
            return (false, "\(name) didn't come forward — \(what.lowercased()) is in Macrophone's From iPhone folder")
        }
        let saved = PasteboardSnapshot(pb)
        pb.clearContents()
        if AppQuirks.isTerminal(running.bundleIdentifier) {
            // A terminal takes the path (spaces escaped, as dropping a file there would type it).
            pb.setString(url.path.replacingOccurrences(of: " ", with: "\\ ") + " ", forType: .string)
        } else if let image {
            pb.writeObjects([url as NSURL, image])
        } else {
            pb.writeObjects([url as NSURL])
        }
        let ours = pb.changeCount
        Keys.press(CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
        // Put the clipboard back once the app has taken the paste.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        if pb.changeCount == ours { saved.restore(to: pb) }
        let how = AppQuirks.isTerminal(running.bundleIdentifier) ? "Its path is in \(name)" : "Added to \(name)"
        return (true, "\(how) — say what it's for")
    }
}
