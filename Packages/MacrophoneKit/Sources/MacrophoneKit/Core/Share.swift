import Foundation

// Oct 18 2026, Sameer: "Build 1, 3, 4" — Reader, photos and files into the chat, the clipboard
// both ways. Each is a feature the phone and the Mac name in their hello / welcome; neither sends
// one of these messages to the other unless it named it (an unknown message ends a session).

/// Reader: the watched window's words as text — a terminal's own text, else what text recognition
/// reads off the window's picture (the column you type in, so a sidebar stays out). What's on the
/// window now; scroll the window for more. The phone asks while Reader shows.
public struct ReaderPage: Codable, Sendable, Equatable {
    public var lines: [String]
    /// A terminal's text: set in a monospaced face, lines kept as they are.
    public var monospaced: Bool
    /// Read off the picture, so a word may be misread.
    public var fromPicture: Bool
    public var at: Date

    public init(lines: [String], monospaced: Bool, fromPicture: Bool, at: Date = Date()) {
        self.lines = lines
        self.monospaced = monospaced
        self.fromPicture = fromPicture
        self.at = at
    }

    public static let feature = "reader"
    /// At most this much text in a page (the newest end of it).
    public static let maxCharacters = 60_000
}

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
