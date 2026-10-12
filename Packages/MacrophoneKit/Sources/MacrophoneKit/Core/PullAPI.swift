import Foundation

/// One dictation as the Mac's local pull API returns it (`GET /v1/latest`, `/v1/history`,
/// `/v1/next`). The CLI and MCP server read the same shape. JSON keys are snake_case.
public struct PulledDictation: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    /// What was delivered: cleaned when there is one, else raw (template not applied).
    public var text: String
    public var raw: String
    public var cleaned: String?
    public var cleanupLevel: CleanupLevel
    public var language: String
    public var profile: String?
    public var createdAt: Date
    public var receivedAt: Date
    public var delayed: Bool
    public var stoppedEarly: Bool
    public var sourceDevice: String

    public init(_ d: Dictation, receivedAt: Date, delayed: Bool) {
        id = d.id
        text = d.text
        raw = d.raw
        cleaned = d.cleaned
        cleanupLevel = d.cleanupLevel
        language = d.language
        profile = d.profileName
        createdAt = d.createdAt
        self.receivedAt = receivedAt
        self.delayed = delayed
        stoppedEarly = d.stoppedEarly
        sourceDevice = d.sourceDevice
    }

    enum CodingKeys: String, CodingKey {
        case id, text, raw, cleaned, language, profile, delayed
        case cleanupLevel = "cleanup_level"
        case createdAt = "created_at"
        case receivedAt = "received_at"
        case stoppedEarly = "stopped_early"
        case sourceDevice = "source_device"
    }

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

#if os(macOS)
/// Where the Mac app tells local tools how to reach its API. Written by the app (0600),
/// read by the CLI and MCP server so nobody has to copy the token by hand.
public struct APIConfig: Codable, Sendable {
    public var port: UInt16
    public var token: String

    public init(port: UInt16, token: String) {
        self.port = port
        self.token = token
    }

    public static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(Product.name)/api.json")
    }

    public static func load() -> APIConfig? {
        guard let d = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(APIConfig.self, from: d)
    }

    public func save() throws {
        let url = Self.fileURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let d = try JSONEncoder().encode(self)
        FileManager.default.createFile(atPath: url.path, contents: d, attributes: [.posixPermissions: 0o600])
    }

    public static func newToken() -> String {
        "mp_" + LinkCrypto.randomBytes(24).base64URL
    }
}
#endif
