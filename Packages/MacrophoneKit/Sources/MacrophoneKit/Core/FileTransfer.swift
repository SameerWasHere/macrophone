import Foundation

// Save to Mac's Downloads (Oct 19 2026, part of "control the Mac entirely from the iPhone"): a
// photo or file from the phone can land in the Mac's Downloads, shown in Finder, instead of in a
// chat. It rides the same pieces as a photo for the chat (`AttachmentChunk`, `downloads: true`),
// sent that way only to a Mac whose welcome names `SaveToDownloads.feature` — an older Mac would
// paste it into the chat instead. It's what a photo or file does when the place you send to has no
// chat to paste into (the clipboard, Finder, the whole screen), and an option everywhere else.
// (Files the other way, Mac → iPhone, were set aside the same day: "Sending clipboard is good for now.")

public enum SaveToDownloads {
    public static let feature = "downloads"

    /// The places with no message box for a photo or file: there it's saved to Downloads.
    public static func isDefault(for target: TargetRef) -> Bool {
        switch target {
        case .clipboard: return true
        case .frontApp: return false
        case let .app(bid, _, _): return bid == "com.apple.finder" || bid == DesktopWatch.bundleID
        }
    }

    /// Where a file named `name` can go in `dir` without replacing one: "name.ext", then
    /// "name 2.ext", "name 3.ext", …
    public static func freeURL(in dir: URL, for name: String,
                               exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let safe = AttachmentChunk.safeName(name)
        let base = (safe as NSString).deletingPathExtension, ext = (safe as NSString).pathExtension
        var url = dir.appendingPathComponent(safe)
        var n = 2
        while exists(url), n < 10_000 {
            url = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return url
    }
}
