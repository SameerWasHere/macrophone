import CoreGraphics
import Foundation
@testable import MacrophoneKit
import XCTest

final class WatchCompanionsTests: XCTestCase {
    typealias W = WatchCompanions.Window
    let textEdit: Int32 = 100
    let host = W(id: 500, pid: 100, layer: 0, bounds: CGRect(x: 200, y: 100, width: 800, height: 500), owner: "TextEdit", bundleID: "com.apple.TextEdit", regularApp: true)

    /// TextEdit's Open panel, as the bug had it: the service's window laid over TextEdit's own, the
    /// same size, from a process that isn't an app (made before TextEdit's window — the service is
    /// warmed up — so the known name is what counts).
    func testTheOpenPanelServiceIsACompanion() {
        let panel = W(id: 480, pid: 200, layer: 0, bounds: host.bounds, owner: "Open and Save Panel Service", bundleID: "com.apple.appkit.xpc.openAndSavePanelService", regularApp: false)
        let list = [panel, host]
        XCTAssertEqual(WatchCompanions.select(watched: 500, in: list, hostInFront: false).map(\.id), [480])
        XCTAssertEqual(WatchCompanions.spot(CGPoint(x: 300, y: 300), watched: 500, in: list, hostInFront: true), .companion)
        // Found by its owner name alone too.
        var byName = panel; byName.bundleID = nil
        XCTAssertEqual(WatchCompanions.select(watched: 500, in: [byName, host], hostInFront: false).map(\.id), [480])
    }

    func testMenusSheetsAndPopUpsOfTheSameApp() {
        let contextMenu = W(id: 520, pid: textEdit, layer: 101, bounds: CGRect(x: 600, y: 300, width: 220, height: 400), regularApp: true)
        // Hangs past the window's foot: still the window's.
        let popUp = W(id: 521, pid: textEdit, layer: 101, bounds: CGRect(x: 900, y: 500, width: 200, height: 300), regularApp: true)
        let sheet = W(id: 522, pid: textEdit, layer: 0, bounds: CGRect(x: 350, y: 128, width: 500, height: 300), regularApp: true)
        let tooltip = W(id: 523, pid: textEdit, layer: 1000, bounds: CGRect(x: 400, y: 200, width: 80, height: 20), regularApp: true)
        // Another document window of the same app, beside it: not a companion.
        let otherDoc = W(id: 524, pid: textEdit, layer: 0, bounds: CGRect(x: 700, y: 50, width: 800, height: 600), regularApp: true)
        // The pointer: above every level.
        let cursor = W(id: 525, pid: 418, layer: 2_147_483_630, bounds: CGRect(x: 300, y: 300, width: 28, height: 28), owner: "Window Server", regularApp: false)
        let serverMenu = W(id: 526, pid: 418, layer: 101, bounds: CGRect(x: 250, y: 150, width: 200, height: 200), owner: "Window Server", regularApp: false)
        let menuBar = W(id: 14, pid: 418, layer: 24, bounds: CGRect(x: 0, y: 0, width: 1728, height: 120), owner: "Window Server", regularApp: false)
        let list = [cursor, menuBar, tooltip, contextMenu, popUp, serverMenu, sheet, otherDoc, host]
        XCTAssertEqual(WatchCompanions.select(watched: 500, in: list, hostInFront: true).map(\.id), [523, 520, 521, 526, 522])
    }

    func testStrangersStayOut() {
        // Another app's window over it, Notification Center's full-screen layer, a screen-wide
        // overlay from an accessory app made after it, Macrophone's own popup.
        let dia = W(id: 600, pid: 300, layer: 0, bounds: CGRect(x: 0, y: 33, width: 1728, height: 1084), owner: "Dia", regularApp: true)
        let nc = W(id: 50, pid: 301, layer: 21, bounds: CGRect(x: 0, y: 0, width: 1728, height: 1117), owner: "Notification Center", bundleID: "com.apple.notificationcenterui", regularApp: false)
        let overlay = W(id: 900, pid: 302, layer: 25, bounds: CGRect(x: 0, y: 0, width: 1728, height: 1117), owner: "Dimmer", regularApp: false)
        let mine = W(id: 901, pid: 999, layer: 101, bounds: CGRect(x: 300, y: 200, width: 300, height: 300), owner: "Macrophone", regularApp: false)
        let floating = W(id: 902, pid: 303, layer: 3, bounds: CGRect(x: 300, y: 200, width: 100, height: 100), owner: "Notes", regularApp: true)
        let list = [mine, overlay, nc, floating, dia, host]
        XCTAssertEqual(WatchCompanions.select(watched: 500, in: list, hostInFront: true, me: 999), [])
        // A click under another app's window: covered (raise); under a stranger's floating panel
        // only (another level): the old rule, the watched window counts.
        XCTAssertEqual(WatchCompanions.spot(CGPoint(x: 350, y: 250), watched: 500, in: [floating, host], hostInFront: true), .watched)
        XCTAssertEqual(WatchCompanions.spot(CGPoint(x: 350, y: 250), watched: 500, in: list, hostInFront: true, me: 999), .covered)
        XCTAssertEqual(WatchCompanions.spot(CGPoint(x: 10, y: 10), watched: 500, in: [host], hostInFront: true), .covered)
    }

    /// An unknown remote view (a process that isn't an app, mostly over the window, made after it)
    /// counts only while the watched app is in front.
    func testAnUnknownRemoteViewNeedsTheHostInFront() {
        let after = W(id: 700, pid: 400, layer: 0, bounds: CGRect(x: 400, y: 200, width: 300, height: 200), owner: "AutoFill", regularApp: false)
        let before = W(id: 400, pid: 400, layer: 0, bounds: CGRect(x: 400, y: 200, width: 300, height: 200), owner: "AutoFill", regularApp: false)
        let halfOut = W(id: 701, pid: 400, layer: 0, bounds: CGRect(x: 900, y: 200, width: 300, height: 200), owner: "AutoFill", regularApp: false)
        XCTAssertEqual(WatchCompanions.select(watched: 500, in: [after, host], hostInFront: true).map(\.id), [700])
        XCTAssertEqual(WatchCompanions.select(watched: 500, in: [after, host], hostInFront: false), [])
        XCTAssertEqual(WatchCompanions.select(watched: 500, in: [before, host], hostInFront: true), [])
        XCTAssertEqual(WatchCompanions.select(watched: 500, in: [halfOut, host], hostInFront: true), [])
    }

    func testTheAreaIsTheUnionClippedToTheDisplay() {
        let window = CGRect(x: 200, y: 100, width: 800, height: 500)
        let menu = CGRect(x: 900, y: 500, width: 200.4, height: 300)
        let display = CGRect(x: 0, y: 0, width: 1728, height: 700)
        XCTAssertEqual(WatchCompanions.area(window: window, companions: [], display: display), window)
        XCTAssertEqual(WatchCompanions.area(window: window, companions: [menu], display: nil), CGRect(x: 200, y: 100, width: 901, height: 700))
        XCTAssertEqual(WatchCompanions.area(window: window, companions: [menu], display: display), CGRect(x: 200, y: 100, width: 901, height: 600))
        // A display left of the main one (negative origin).
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(WatchCompanions.area(window: CGRect(x: -500, y: 100, width: 600, height: 400), companions: [CGRect(x: -100, y: 300, width: 300, height: 100)], display: left),
                       CGRect(x: -500, y: 100, width: 500, height: 400))
    }

    func testThePhonesFractionsMapToTheStreamedArea() {
        let area = CGRect(x: 200, y: 100, width: 900, height: 700)
        XCTAssertEqual(WatchCompanions.point(CGPoint(x: 0, y: 0), in: area), CGPoint(x: 200, y: 100))
        XCTAssertEqual(WatchCompanions.point(CGPoint(x: 1, y: 1), in: area), CGPoint(x: 1100, y: 800))
        XCTAssertEqual(WatchCompanions.point(CGPoint(x: 0.5, y: 0.25), in: area), CGPoint(x: 650, y: 275))
        // The place to type, half the window's width at its foot, in the wider picture.
        let window = CGRect(x: 200, y: 100, width: 800, height: 500)
        let f = WatchCompanions.reframe(CGRect(x: 0.25, y: 0.9, width: 0.5, height: 0.1), window: window, in: area)
        XCTAssertEqual(f.minX, 200.0 / 900, accuracy: 1e-9)
        XCTAssertEqual(f.minY, 450.0 / 700, accuracy: 1e-9)
        XCTAssertEqual(f.width, 400.0 / 900, accuracy: 1e-9)
        XCTAssertEqual(f.height, 50.0 / 700, accuracy: 1e-9)
        // The window alone: unchanged.
        XCTAssertEqual(WatchCompanions.reframe(CGRect(x: 0.25, y: 0.9, width: 0.5, height: 0.1), window: window, in: window), CGRect(x: 0.25, y: 0.9, width: 0.5, height: 0.1))
    }

    func testSettleShowsAtOnceAndGoesBackAfterAMoment() {
        var s = WatchCompanions.Settle(settle: 0.4)
        let t = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(s.next(nil, now: t), .none)
        let menu = WatchCompanions.Plan(ids: [520], area: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(s.next(menu, now: t), .show(menu))
        XCTAssertEqual(s.next(menu, now: t.addingTimeInterval(0.25)), .none)
        // A submenu: the set changed — at once.
        let sub = WatchCompanions.Plan(ids: [521, 520], area: CGRect(x: 0, y: 0, width: 150, height: 100))
        XCTAssertEqual(sub.ids, [520, 521])
        XCTAssertEqual(s.next(sub, now: t.addingTimeInterval(0.5)), .show(sub))
        // Gone for a look: not yet. Back: nothing to do. Gone long enough: the window alone.
        XCTAssertEqual(s.next(nil, now: t.addingTimeInterval(0.75)), .none)
        XCTAssertEqual(s.next(sub, now: t.addingTimeInterval(1.0)), .none)
        XCTAssertEqual(s.next(nil, now: t.addingTimeInterval(1.25)), .none)
        XCTAssertEqual(s.next(nil, now: t.addingTimeInterval(1.5)), .none)
        XCTAssertEqual(s.next(nil, now: t.addingTimeInterval(1.7)), .alone)
        XCTAssertNil(s.applied)
        XCTAssertEqual(s.next(nil, now: t.addingTimeInterval(2.0)), .none)
    }
}
