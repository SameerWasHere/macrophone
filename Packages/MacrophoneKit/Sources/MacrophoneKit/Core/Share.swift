import Foundation

// Oct 18 2026, Sameer: "Build 1, 3, 4" — photos and files into the chat, the clipboard both ways
// (Reader, the window's words as text, came and went the same day: "not that great"). Each is a feature the phone and the Mac name in their hello / welcome; neither sends
// one of these messages to the other unless it named it (an unknown message ends a session).

/// The clipboard, both ways, only when asked: the phone asks for the Mac's (copied to the phone's
/// clipboard), or sends its own (onto the Mac's, to paste with ⌘V). Text, or an image. A copy a
/// password manager marks as concealed never leaves the Mac.
public struct ClipboardItem: Codable, Sendable, Equatable {
    public var text: String?
    /// PNG or JPEG.
    public var image: Data?

    public init(text: String? = nil, image: Data? = nil) {
        self.text = text
        self.image = image
    }

    public var isEmpty: Bool { (text ?? "").isEmpty && (image ?? Data()).isEmpty }

    public static let feature = "clipboard"
    public static let maxText = 256 * 1024
    /// An image bigger than this goes as a photo (Attachments), not on the clipboard.
    public static let maxImage = 1_400_000
}

/// A photo or a file from the phone, into the chat you send to: the Mac keeps it in its own folder
/// and pastes it there — the image itself into a chat app, its path into a terminal (Claude Code
/// and Codex read images from a path). It goes in pieces, so no frame passes the link's limit.
public struct AttachmentChunk: Codable, Sendable {
    public var id: UUID
    public var index: Int
    public var count: Int
    public var filename: String
    /// "image" or "file".
    public var kind: String
    public var target: TargetRef
    public var data: Data

    public init(id: UUID, index: Int, count: Int, filename: String, kind: String, target: TargetRef, data: Data) {
        self.id = id
        self.index = index
        self.count = count
        self.filename = filename
        self.kind = kind
        self.target = target
        self.data = data
    }

    public static let feature = "attachments"
    public static let chunkSize = 1_000_000
    public static let maxChunks = 20

    /// A file's bytes as the pieces that carry it.
    public static func chunks(of data: Data, filename: String, kind: String, target: TargetRef, id: UUID = UUID()) -> [AttachmentChunk] {
        let n = max(1, (data.count + chunkSize - 1) / chunkSize)
        return (0..<n).map { i in
            let lo = data.startIndex + i * chunkSize
            let hi = min(data.endIndex, lo + chunkSize)
            return AttachmentChunk(id: id, index: i, count: n, filename: filename, kind: kind, target: target, data: data[lo..<hi])
        }
    }

    /// A name that's safe as one path component on the Mac.
    public static func safeName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\\0").union(.controlCharacters)
        var t = String(s.unicodeScalars.map { bad.contains($0) ? "-" : Character($0) })
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespaces))
        if t.isEmpty { t = "file" }
        return String(t.prefix(120))
    }
}

/// Ready while you speak (Oct 18 2026, the speed pass): the phone tells the Mac where a dictation
/// is going the moment recording starts, so the app is in front and its place to type found by the
/// time the words arrive. Only to a Mac whose welcome names the feature.
public enum DictationPrepare {
    public static let feature = "prepare"
}

/// The whole screen (Oct 18 2026, Sameer: "I just want them to be able to see their whole Mac
/// screen … this may be needed to interact with certain pop ups"): watched like a window — the
/// main display, live, with taps, right-clicks, scrolls and keys (keys go to whatever is in front).
/// A reserved place no app has, so a Mac that doesn't know it simply says it isn't open; the phone
/// offers it only to a Mac whose welcome names the feature.
public enum DesktopWatch {
    public static let feature = "desktop"
    public static let bundleID = "com.sameer.macrophone.whole-screen"
    public static var target: TargetRef { .app(bundleID: bundleID, windowKey: nil, name: "Whole Screen") }
    public static func isDesktop(_ t: TargetRef?) -> Bool { t?.bundleID == bundleID }
}

/// The app in front on the Mac, named in each frame of the whole screen.
public struct FrontApp: Codable, Sendable, Equatable {
    public var bundleID: String
    public var name: String
    public init(bundleID: String, name: String) { self.bundleID = bundleID; self.name = name }
}
