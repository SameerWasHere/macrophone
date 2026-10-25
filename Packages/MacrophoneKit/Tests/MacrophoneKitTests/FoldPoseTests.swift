import CoreGraphics
import Foundation
@testable import MacrophoneKit
import XCTest

/// The iPhone Duo's poses (Oct 25 2026), from what the phone reads: the hinge, the fold's region,
/// the scene's size.
final class FoldPoseTests: XCTestCase {
    let cover = CGSize(width: 466, height: 678)
    let innerUp = CGSize(width: 669, height: 951)
    let innerSide = CGSize(width: 951, height: 669)
    let pro = CGSize(width: 402, height: 874)

    func testTheHingeDecides() {
        XCTAssertEqual(FoldPose.derive(FoldReading(hinge: .closed, angle: 0, size: cover)), .closed)
        XCTAssertEqual(FoldPose.derive(FoldReading(hinge: .fullyOpen, angle: 180, size: innerUp)), .open(landscape: false))
        XCTAssertEqual(FoldPose.derive(FoldReading(hinge: .fullyOpen, angle: 180, size: innerSide)), .open(landscape: true))
    }

    func testPartlyOpenFollowsTheFoldsDirection() {
        // The laptop: the hinge runs across the scene (a band wider than it is tall).
        let across = FoldDivision(frame: CGRect(x: 0, y: 320, width: 951, height: 28), isActive: true)
        XCTAssertEqual(FoldPose.derive(FoldReading(hinge: .partiallyOpen, angle: 110, size: innerSide, division: across)), .laptop)
        // The book: the hinge runs up and down.
        let upDown = FoldDivision(frame: CGRect(x: 320, y: 0, width: 28, height: 951), isActive: true)
        XCTAssertEqual(FoldPose.derive(FoldReading(hinge: .partiallyOpen, angle: 110, size: innerUp, division: upDown)), .book)
        // No region to read: the scene's shape stands in.
        XCTAssertEqual(FoldPose.derive(FoldReading(hinge: .partiallyOpen, angle: 110, size: innerSide)), .laptop)
        XCTAssertEqual(FoldPose.derive(FoldReading(hinge: .partiallyOpen, angle: 110, size: innerUp)), .book)
    }

    func testNoHingeIsARegularPhoneUnlessTheSceneIsTheInnerScreen() {
        XCTAssertEqual(FoldPose.derive(FoldReading(hinge: nil, angle: 180, size: pro)), .closed)
        XCTAssertEqual(FoldPose.derive(FoldReading(hinge: nil, angle: 180, size: cover)), .closed)
        XCTAssertEqual(FoldPose.derive(FoldReading(hinge: nil, angle: 180, size: .zero)), .closed)
        XCTAssertEqual(FoldPose.derive(FoldReading(hinge: nil, angle: 180, size: innerUp)), .open(landscape: false))
        XCTAssertEqual(FoldPose.derive(FoldReading(hinge: nil, angle: 180, size: innerSide)), .open(landscape: true))
    }

    func testTheHalvesSplitAtTheFold() {
        let across = FoldDivision(frame: CGRect(x: 0, y: 320, width: 951, height: 28), isActive: true)
        let h = FoldHalves.split(innerSide, pose: .laptop, division: across)!
        XCTAssertEqual(h.mac, CGRect(x: 0, y: 0, width: 951, height: 320))
        XCTAssertEqual(h.deck, CGRect(x: 0, y: 348, width: 951, height: 321))
        let upDown = FoldDivision(frame: CGRect(x: 320, y: 0, width: 28, height: 951), isActive: true)
        let b = FoldHalves.split(innerUp, pose: .book, division: upDown)!
        XCTAssertEqual(b.mac, CGRect(x: 0, y: 0, width: 320, height: 951))
        XCTAssertEqual(b.deck, CGRect(x: 348, y: 0, width: 321, height: 951))
        // Without a region: a band in the middle.
        let m = FoldHalves.split(innerSide, pose: .laptop, division: nil)!
        XCTAssertEqual(m.mac.maxY, (669 - FoldHalves.defaultFold) / 2)
        XCTAssertEqual(m.deck.minY, (669 + FoldHalves.defaultFold) / 2)
        // A region past the scene's edge is held inside it.
        let off = FoldDivision(frame: CGRect(x: 0, y: 660, width: 951, height: 40), isActive: true)
        let o = FoldHalves.split(innerSide, pose: .laptop, division: off)!
        XCTAssertEqual(o.mac.height, 660)
        XCTAssertEqual(o.deck.height, 0)
        // Flat or closed: no halves.
        XCTAssertNil(FoldHalves.split(innerSide, pose: .open(landscape: true), division: across))
        XCTAssertNil(FoldHalves.split(cover, pose: .closed, division: nil))
    }

    func testTheDeckRisesAsTheHingeFolds() {
        XCTAssertEqual(FoldPose.deckRise(angle: 180), 0)
        XCTAssertEqual(FoldPose.deckRise(angle: 165), 0)
        XCTAssertEqual(FoldPose.deckRise(angle: 142.5), 0.5, accuracy: 0.001)
        XCTAssertEqual(FoldPose.deckRise(angle: 120), 1)
        XCTAssertEqual(FoldPose.deckRise(angle: 90), 1)
    }

    func testWords() {
        XCTAssertEqual(FoldPose.closed.name, "closed")
        XCTAssertEqual(FoldPose.open(landscape: false).name, "portrait")
        XCTAssertEqual(FoldPose.open(landscape: true).name, "landscape")
        XCTAssertEqual(FoldPose.laptop.name, "laptop")
        XCTAssertEqual(FoldPose.book.name, "book")
        XCTAssertTrue(FoldPose.laptop.isFolded && FoldPose.book.isFolded)
        XCTAssertFalse(FoldPose.open(landscape: true).isFolded)
        XCTAssertTrue(FoldPose.open(landscape: true).isInner)
        XCTAssertFalse(FoldPose.closed.isInner)
    }
}
