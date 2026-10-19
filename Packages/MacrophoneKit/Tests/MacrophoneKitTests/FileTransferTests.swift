import Foundation
@testable import MacrophoneKit
import XCTest

final class SaveToDownloadsTests: XCTestCase {
    func testPiecesCarryTheFlagAndPutBackTheBytes() throws {
        let data = Data((0..<(AttachmentChunk.chunkSize * 2 + 123)).map { UInt8($0 % 251) })
        let chunks = AttachmentChunk.chunks(of: data, filename: "report.pdf", kind: "file", target: .clipboard, downloads: true)
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(Set(chunks.map(\.id)).count, 1)
        XCTAssertEqual(chunks.map(\.index), [0, 1, 2])
        XCTAssertTrue(chunks.allSatisfy { $0.count == 3 && $0.downloads == true })
        XCTAssertTrue(chunks.allSatisfy { $0.data.count <= AttachmentChunk.chunkSize })
        XCTAssertEqual(chunks.reduce(Data()) { $0 + $1.data }, data)
        // An empty file is still one piece.
        XCTAssertEqual(AttachmentChunk.chunks(of: Data(), filename: "a", kind: "file", target: .clipboard).count, 1)
    }

    func testFlagRoundTripsAndAnOlderPieceDecodes() throws {
        let c = AttachmentChunk(id: UUID(), index: 0, count: 1, filename: "a.png", kind: "image", target: .clipboard, data: Data([1, 2]), downloads: true)
        let back = try WireCoding.decoder.decode(Message.self, from: WireCoding.encoder.encode(Message.attachment(c)))
        guard case let .attachment(d) = back else { return XCTFail() }
        XCTAssertEqual(d.downloads, true)
        // A phone from before sends no flag: into the chat, as always.
        let old = AttachmentChunk(id: UUID(), index: 0, count: 1, filename: "a.png", kind: "image", target: .clipboard, data: Data([1]))
        var json = try JSONSerialization.jsonObject(with: WireCoding.encoder.encode(old)) as! [String: Any]
        json.removeValue(forKey: "downloads")
        let decoded = try WireCoding.decoder.decode(AttachmentChunk.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.downloads)
    }

    func testCapIsTwentyPieces() {
        let over = Data(count: AttachmentChunk.chunkSize * AttachmentChunk.maxChunks + 1)
        XCTAssertGreaterThan(AttachmentChunk.chunks(of: over, filename: "big.mov", kind: "file", target: .clipboard).count, AttachmentChunk.maxChunks)
        let at = Data(count: AttachmentChunk.chunkSize * AttachmentChunk.maxChunks)
        XCTAssertEqual(AttachmentChunk.chunks(of: at, filename: "ok.mov", kind: "file", target: .clipboard).count, AttachmentChunk.maxChunks)
    }

    func testDefaultPlaces() {
        XCTAssertTrue(SaveToDownloads.isDefault(for: .clipboard))
        XCTAssertTrue(SaveToDownloads.isDefault(for: .app(bundleID: "com.apple.finder", windowKey: "3", name: "Finder")))
        XCTAssertTrue(SaveToDownloads.isDefault(for: DesktopWatch.target))
        XCTAssertFalse(SaveToDownloads.isDefault(for: .frontApp))
        XCTAssertFalse(SaveToDownloads.isDefault(for: .app(bundleID: "com.anthropic.claudefordesktop", windowKey: nil, name: "Claude")))
    }

    func testNamesAreSafeAndNeverReplaceOne() {
        let dir = URL(fileURLWithPath: "/tmp/d")
        XCTAssertEqual(AttachmentChunk.safeName("../../etc/passwd"), "-..-etc-passwd")
        XCTAssertEqual(AttachmentChunk.safeName("  "), "file")
        XCTAssertEqual(SaveToDownloads.freeURL(in: dir, for: "a/b.txt", exists: { _ in false }).lastPathComponent, "a-b.txt")
        var taken: Set<String> = ["Photo.jpg", "Photo 2.jpg"]
        XCTAssertEqual(SaveToDownloads.freeURL(in: dir, for: "Photo.jpg", exists: { taken.contains($0.lastPathComponent) }).lastPathComponent, "Photo 3.jpg")
        taken = ["notes"]
        XCTAssertEqual(SaveToDownloads.freeURL(in: dir, for: "notes", exists: { taken.contains($0.lastPathComponent) }).lastPathComponent, "notes 2")
        XCTAssertEqual(SaveToDownloads.freeURL(in: dir, for: "x.txt", exists: { _ in false }).deletingLastPathComponent().path, "/tmp/d")
    }
}
