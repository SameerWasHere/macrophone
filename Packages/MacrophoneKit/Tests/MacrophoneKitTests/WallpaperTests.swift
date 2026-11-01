import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import MacrophoneKit

/// The Mac's desktop picture on the iPhone (Nov 1 2026): how it's made, its shape on the wire,
/// and that only a phone that named it ever gets it.
final class WallpaperTests: XCTestCase {
    // MARK: Making one

    func testThePictureIsScaledNotCroppedAndNeverEnlarged() throws {
        let big = try XCTUnwrap(MacWallpaper.demoImage(width: 4000, height: 2000))
        let w = try XCTUnwrap(MacWallpaper.make(from: big))
        XCTAssertEqual(w.width, 2400)
        XCTAssertEqual(w.height, 1200)
        let decoded = try XCTUnwrap(Self.decode(w.jpeg))
        XCTAssertEqual(decoded.width, 2400)
        XCTAssertEqual(decoded.height, 1200)
        // Upright pictures keep their shape too.
        let tall = try XCTUnwrap(MacWallpaper.make(from: try XCTUnwrap(MacWallpaper.demoImage(width: 1500, height: 3000))))
        XCTAssertEqual(tall.width, 1200)
        XCTAssertEqual(tall.height, 2400)
        // A small picture goes as it is.
        let small = try XCTUnwrap(MacWallpaper.make(from: try XCTUnwrap(MacWallpaper.demoImage(width: 800, height: 600))))
        XCTAssertEqual(small.width, 800)
        XCTAssertEqual(small.height, 600)
    }

    func testTheDemoIsLightOnTheWireAndDark() throws {
        let w = try XCTUnwrap(MacWallpaper.demo())
        XCTAssertEqual(w.width, 2400)
        XCTAssertEqual(w.height, 1350)
        XCTAssertLessThanOrEqual(w.jpeg.count, MacWallpaper.targetBytes)
        XCTAssertEqual(w.isDark, true)
        XCTAssertTrue(w.isValid)
    }

    func testTheIdIsTheBytesHashAndTheSamePictureKeepsIt() throws {
        let image = try XCTUnwrap(MacWallpaper.demoImage(width: 1200, height: 800))
        let a = try XCTUnwrap(MacWallpaper.make(from: image)), b = try XCTUnwrap(MacWallpaper.make(from: image))
        XCTAssertEqual(a.id, b.id)
        XCTAssertEqual(a.id, MacWallpaper.id(of: a.jpeg))
        XCTAssertEqual(a.id.count, 16)
        let other = try XCTUnwrap(MacWallpaper.make(from: try XCTUnwrap(MacWallpaper.demoImage(width: 1200, height: 801))))
        XCTAssertNotEqual(a.id, other.id)
    }

    func testDarkAndLightAreTold() throws {
        XCTAssertEqual(MacWallpaper.isDark(try XCTUnwrap(Self.solid(gray: 0.08))), true)
        XCTAssertEqual(MacWallpaper.isDark(try XCTUnwrap(Self.solid(gray: 0.92))), false)
        XCTAssertEqual(try XCTUnwrap(MacWallpaper.make(from: try XCTUnwrap(Self.solid(gray: 0.95)))).isDark, false)
    }

    // MARK: The wire

    func testTheMessageRoundTripsAndFitsInAFrame() throws {
        let w = try XCTUnwrap(MacWallpaper.demo())
        let data = try WireCoding.encoder.encode(Message.macWallpaper(w))
        XCTAssertLessThan(data.count, FramedConnection.maxFrame)
        guard case let .macWallpaper(back) = try WireCoding.decoder.decode(Message.self, from: data) else { return XCTFail("not a wallpaper") }
        XCTAssertEqual(back, w)
        // The largest the Mac ever sends still fits, base64 and all.
        let heaviest = MacWallpaper(id: "x", jpeg: Data(repeating: 0xAB, count: MacWallpaper.maxBytes), width: 2400, height: 1350, isDark: nil)
        XCTAssertLessThan(try WireCoding.encoder.encode(Message.macWallpaper(heaviest)).count, FramedConnection.maxFrame)
    }

    func testNotKnowingWhetherItIsDarkIsLeftOut() throws {
        let w = MacWallpaper(id: "abc", jpeg: Data([1, 2, 3]), width: 2, height: 1, isDark: nil)
        let json = String(decoding: try WireCoding.encoder.encode(w), as: UTF8.self)
        XCTAssertFalse(json.contains("isDark"))
        let bare = Data(#"{"id":"abc","jpeg":"AQID","width":2,"height":1}"#.utf8)
        XCTAssertEqual(try WireCoding.decoder.decode(MacWallpaper.self, from: bare), w)
        XCTAssertFalse(MacWallpaper(id: "", jpeg: Data([1]), width: 1, height: 1, isDark: nil).isValid)
        XCTAssertFalse(MacWallpaper(id: "a", jpeg: Data(), width: 1, height: 1, isDark: nil).isValid)
        XCTAssertFalse(MacWallpaper(id: "a", jpeg: Data([1]), width: 0, height: 1, isDark: nil).isValid)
    }

    func testItNeverRidesTheVideoLane() throws {
        XCTAssertFalse(VideoLane.rides(.macWallpaper(MacWallpaper(id: "a", jpeg: Data([1]), width: 1, height: 1, isDark: true))))
    }

    // MARK: Over a real connection (loopback, the away door)

    func testAPhoneThatNamesItGetsThePictureAfterTheWelcomeAndWhenItChanges() async throws {
        let rig = try await Rig.make(port: 47913)
        defer { rig.stop() }
        let first = try XCTUnwrap(MacWallpaper.demo(width: 1600, height: 1000))
        rig.mac.wallpaper = first
        rig.server.macFeatures.append(MacWallpaper.feature)
        rig.client.features.append(MacWallpaper.feature)
        try await rig.connect()
        XCTAssertTrue(rig.client.macSendsWallpaper)
        try await rig.waitFor { rig.phone.wallpapers.count == 1 }
        XCTAssertEqual(rig.phone.wallpapers.first?.0.id, first.id)
        XCTAssertEqual(rig.phone.wallpapers.first?.1, rig.server.identity.id)
        // It changed on the Mac: the new one comes.
        let second = try XCTUnwrap(MacWallpaper.demo(width: 1600, height: 900))
        let sent = await rig.server.sendWallpaper(second, to: rig.phoneID)
        XCTAssertTrue(sent)
        try await rig.waitFor { rig.phone.wallpapers.count == 2 }
        XCTAssertEqual(rig.phone.wallpapers.last?.0.id, second.id)
    }

    func testAnOlderPhoneNeverGetsIt() async throws {
        let rig = try await Rig.make(port: 47912)
        defer { rig.stop() }
        rig.mac.wallpaper = try XCTUnwrap(MacWallpaper.demo(width: 1600, height: 1000))
        rig.server.macFeatures.append(MacWallpaper.feature)
        // The phone's hello doesn't name it.
        try await rig.connect()
        let sent = await rig.server.sendWallpaper(rig.mac.wallpaper!, to: rig.phoneID)
        XCTAssertFalse(sent)
        rig.server.broadcastWallpaper(rig.mac.wallpaper!)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertTrue(rig.phone.wallpapers.isEmpty)
        XCTAssertEqual(rig.mac.wallpaperAsks, 0)
        // The session carries on (an unknown message would have ended it).
        let rtt = await rig.client.roundTrip(); XCTAssertNotNil(rtt)
    }

    // MARK: Helpers

    static func decode(_ jpeg: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func solid(gray: CGFloat) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(srgbRed: gray, green: gray, blue: gray, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
        return ctx.makeImage()
    }
}

extension MacSide: LinkServerWallpaperDelegate {
    func macWallpaper(_ server: LinkServer, for peerID: UUID) async -> MacWallpaper? {
        wallpaperAsks += 1
        return wallpaper
    }
}

extension PhoneSide: LinkClientWallpaperDelegate {
    func linkClient(_ client: LinkClient, macWallpaper: MacWallpaper, macID: UUID) {
        wallpapers.append((macWallpaper, macID))
    }
}
