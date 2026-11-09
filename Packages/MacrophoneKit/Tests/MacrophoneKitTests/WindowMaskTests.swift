import CoreGraphics
import XCTest
@testable import MacrophoneKit

/// The window's real corners, read off one frame with alpha and sent as a 9-slice mask (Nov 9 2026).
final class WindowMaskTests: XCTestCase {
    /// A window-shaped picture: opaque inside a rounded rect of `radius`, transparent outside.
    private func window(width w: Int, height h: Int, radius r: CGFloat, continuous: Bool = false) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.2, blue: 0.22, alpha: 1))
        ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil))
        ctx.fillPath()
        return ctx.makeImage()!
    }

    func testTheRadiusIsReadOffTheAlpha() throws {
        for r: CGFloat in [10, 26, 52, 80] {
            let m = try XCTUnwrap(WindowMaskReader.make(from: window(width: 1400, height: 900, radius: r)))
            XCTAssertEqual(m.width, 1400)
            XCTAssertEqual(m.height, 900)
            XCTAssertEqual(m.radius, Double(r), accuracy: 2, "radius \(r)")
            XCTAssertNotNil(m.corners)
            XCTAssertTrue(m.isValid)
        }
    }

    /// A Tahoe window's corner is a continuous curve — shallower on the diagonal than a circle (a
    /// real TextEdit window: 9.6 px transparent on the diagonal, the edge opaque from 48 px). The
    /// radius is the edge's, so the mask's quadrant holds the whole arc.
    func testAContinuousCornerIsMeasuredAtItsEdge() throws {
        // A superellipse corner of "radius" 48 (|x|^n + |y|^n = 1 with n = 4) at a 600 × 400
        // window, anti-aliased (each pixel's alpha is its coverage, 8 × 8 samples).
        let r = 48.0, w = 600, h = 400
        func inside(_ px: Double, _ py: Double) -> Bool {
            let cx = min(px, Double(w) - px), cy = min(py, Double(h) - py)
            guard cx < r, cy < r else { return true }
            let u = (r - cx) / r, v = (r - cy) / r
            return pow(u, 4) + pow(v, 4) <= 1
        }
        func coverage(_ x: Int, _ y: Int) -> UInt8 {
            var n = 0
            for i in 0..<8 { for j in 0..<8 where inside(Double(x) + (Double(i) + 0.5) / 8, Double(y) + (Double(j) + 0.5) / 8) { n += 1 } }
            return UInt8(n * 255 / 64)
        }
        let m = try XCTUnwrap(WindowMaskReader.make(width: w, height: h, alpha: coverage))
        // Where the top row turns opaque (within 2%) is what the radius means; near the curve's
        // own 48, and well past what a circle through the diagonal's run would say.
        let opaqueFrom = (0..<Int(r) + 2).first { coverage($0, 0) >= 250 } ?? 0
        XCTAssertEqual(m.radius, Double(opaqueFrom), accuracy: 1)
        XCTAssertGreaterThan(m.radius, 30)
        XCTAssertLessThanOrEqual(m.radius, r)
        let diagonal = (0..<60).first { coverage($0, $0) >= 128 } ?? 60
        let circleGuess = (Double(diagonal) / (1 - 1 / 2.squareRoot())).rounded()
        XCTAssertGreaterThan(m.radius, circleGuess * 1.2, "edge \(m.radius) vs circle-by-diagonal \(circleGuess)")
        // The quadrant reaches past the arc's end on the edge: the PNG covers it all.
        XCTAssertGreaterThan(m.quadrant, opaqueFrom)
        let png = try XCTUnwrap(m.corners)
        let alpha = alphaMap(try XCTUnwrap(WindowMaskReader.image(png)))
        XCTAssertEqual(alpha(0, 0), 0)
        XCTAssertGreaterThanOrEqual(alpha(m.quadrant - 1, 0), 250)
        XCTAssertEqual(alpha(diagonal + 2, diagonal + 2), 255)
    }

    func testTheCornersPNGIsTheRealAlphaNineSliced() throws {
        let m = try XCTUnwrap(WindowMaskReader.make(from: window(width: 600, height: 400, radius: 52)))
        let png = try XCTUnwrap(m.corners)
        XCTAssertLessThan(png.count, 8_000)
        let image = try XCTUnwrap(WindowMaskReader.image(png))
        XCTAssertEqual(image.width, m.side)
        XCTAssertEqual(image.height, m.side)
        XCTAssertEqual(m.side, 2 * m.quadrant + 2)
        // The quadrant holds the whole arc (the radius and the anti-aliased pixel past it).
        XCTAssertGreaterThanOrEqual(Double(m.quadrant), m.radius + 1)
        // Its alpha: transparent at the corners, opaque in the middle and well inside each arc.
        let alpha = alphaMap(image)
        let s = m.side
        XCTAssertEqual(alpha(0, 0), 0)
        XCTAssertEqual(alpha(s - 1, 0), 0)
        XCTAssertEqual(alpha(0, s - 1), 0)
        XCTAssertEqual(alpha(s - 1, s - 1), 0)
        XCTAssertEqual(alpha(s / 2, s / 2), 255)
        XCTAssertEqual(alpha(m.quadrant - 1, m.quadrant - 1), 255)
        XCTAssertEqual(alpha(s / 2, 0), 255)
        // The 9-slice centre is the 2 × 2 cross between the quadrants.
        let c = m.contentsCenter
        XCTAssertEqual(c.minX, CGFloat(m.quadrant) / CGFloat(s), accuracy: 0.0001)
        XCTAssertEqual(c.width, 2 / CGFloat(s), accuracy: 0.0001)
        XCTAssertEqual(c.maxX, CGFloat(s - m.quadrant) / CGFloat(s), accuracy: 0.0001)
    }

    func testSquareCornersAndNoAlphaAndNotAWindow() throws {
        // Square: a mask that says so, with no PNG.
        let square = try XCTUnwrap(WindowMaskReader.make(from: window(width: 300, height: 200, radius: 0)))
        XCTAssertEqual(square.radius, 0)
        XCTAssertNil(square.corners)
        // No alpha channel at all: nothing to read.
        let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        XCTAssertNil(WindowMaskReader.make(from: ctx.makeImage()!))
        // Transparent too far in (not a window): nil, so the phone keeps its own guess.
        XCTAssertNil(WindowMaskReader.make(width: 400, height: 400) { _, _ in 0 })
        // The two top corners disagreeing: square (a window with one straight corner).
        let lopsided = WindowMaskReader.radius(width: 400, height: 400) { x, y in x < 200 && x + y < 20 ? 0 : 255 }
        XCTAssertEqual(lopsided, 0)
    }

    func testTheRadiusScalesWithThePictureAndFitsOnlyItsOwnSize() {
        let m = WatchWindowMask(width: 2000, height: 1200, radius: 52)
        XCTAssertTrue(m.fits(width: 2000, height: 1200))
        XCTAssertFalse(m.fits(width: 1000, height: 600))
        XCTAssertEqual(m.radius(forWidth: 1000), 26)
        XCTAssertEqual(m.radius(forWidth: 2000), 52)
        XCTAssertFalse(WatchWindowMask(width: 10, height: 10, radius: 500).isValid)
        XCTAssertFalse(WatchWindowMask(width: 0, height: 10, radius: 5).isValid)
    }

    func testItRoundTripsOnTheWireAndAnOlderShapeStillReads() throws {
        let m = WatchWindowMask(width: 1192, height: 1084, radius: 53, corners: Data([1, 2, 3]))
        let data = try WireCoding.encoder.encode(Message.watchMask(m))
        guard case let .watchMask(back) = try WireCoding.decoder.decode(Message.self, from: data) else { return XCTFail() }
        XCTAssertEqual(back, m)
        // Without the PNG (square, or the radius alone): still a mask.
        let bare = Data(#"{"width":1192,"height":1084,"radius":0}"#.utf8)
        let b = try WireCoding.decoder.decode(WatchWindowMask.self, from: bare)
        XCTAssertEqual(b.radius, 0)
        XCTAssertNil(b.corners)
        XCTAssertTrue(b.isValid)
    }

    private func alphaMap(_ image: CGImage) -> (Int, Int) -> UInt8 {
        let w = image.width, h = image.height
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self), stride = ctx.bytesPerRow
        // (The context kept alive by the closure: its bitmap is what `p` points into.)
        return { x, y in _ = ctx; return p[y * stride + x * 4 + 3] }
    }
}
