import XCTest
@testable import MacrophoneKit

final class MacAlertsTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    static let n = 10_000

    /// A picture whose samples `from..<to` (out of 10,000) are lit with `tone`.
    private func pic(_ from: Int = 0, _ to: Int = 0, tone: UInt32 = 0xFFFFFF) -> [UInt32] {
        var a = [UInt32](repeating: 0, count: Self.n)
        for i in from..<to { a[i] = tone }
        return a
    }

    /// Looks every three seconds from t0 with these pictures; the events, by look.
    private func run(_ d: inout WindowChangeDetector, _ pics: [[UInt32]], start: TimeInterval = 0, working: Bool = false) -> [WindowChangeDetector.Event?] {
        pics.enumerated().map { i, p in d.look(p, working: working, at: t0 + start + Double(i) * 3) }
    }

    func testAStillWindowNeverAlerts() {
        var d = WindowChangeDetector(at: t0)
        XCTAssertTrue(run(&d, Array(repeating: pic(), count: 20)).allSatisfy { $0 == nil })
    }

    func testACaretNeverAlerts() {
        var d = WindowChangeDetector(at: t0)
        // Two samples blinking: 0.0002 of the picture.
        let pics = (0..<20).map { $0 % 2 == 0 ? pic() : pic(0, 2) }
        XCTAssertTrue(run(&d, pics).allSatisfy { $0 == nil })
    }

    func testAJobThatRunsThenStopsAlertsOnceWhenItSettles() {
        var d = WindowChangeDetector(at: t0)
        // 40 s of output growing, then still.
        var pics = [pic()]
        for i in 1...13 { pics.append(pic(0, i * 100)) }
        let done = pic(0, 1300)
        pics += Array(repeating: done, count: 10)
        let events = run(&d, pics)
        let fired = events.compactMap { $0 }
        XCTAssertEqual(fired.count, 1)
        guard case .settled(let ran, let changed)? = fired.first else { return XCTFail() }
        XCTAssertGreaterThanOrEqual(ran, WindowChangeDetector.longRun)
        XCTAssertEqual(changed, 0.13, accuracy: 0.001)
        // Not before 8 s of stillness.
        let firstStill = 14
        let at = events.firstIndex { $0 != nil }!
        XCTAssertGreaterThanOrEqual(Double(at - (firstStill - 1)) * 3, WindowChangeDetector.settleMin)
    }

    func testASpinnerThatComesAndGoesIsNotNews() {
        var d = WindowChangeDetector(at: t0)
        // A small spinner turns for a while, then the window is exactly as before.
        let pics = [pic()] + (0..<6).map { pic($0 * 3, $0 * 3 + 3) } + Array(repeating: pic(), count: 8)
        XCTAssertTrue(run(&d, pics).allSatisfy { $0 == nil })
    }

    func testWorkingKeepsItBusy() {
        var d = WindowChangeDetector(at: t0)
        _ = run(&d, [pic(), pic(0, 500)])
        // Still picture, but it says it's working: no alert.
        XCTAssertTrue(run(&d, Array(repeating: pic(0, 500), count: 10), start: 6, working: true).allSatisfy { $0 == nil })
        // Then it stops saying so: it settles.
        XCTAssertNotNil(run(&d, Array(repeating: pic(0, 500), count: 12), start: 36).compactMap { $0 }.first)
    }

    func testADialogAlertsAtOnce() {
        var d = WindowChangeDetector(at: t0)
        XCTAssertNil(d.look(pic(), at: t0))
        XCTAssertEqual(d.look(pic(0, 2000), dialog: true, at: t0 + 3), .dialog)
        // Still up: not again.
        XCTAssertNil(d.look(pic(0, 2000), dialog: true, at: t0 + 6))
    }

    func testAChattyWindowCalmsDown() {
        var d = WindowChangeDetector(at: t0)
        var t: TimeInterval = 0
        var fired = 0
        var tone: UInt32 = 1
        // A burst every ~20 s: a line of output, then quiet.
        for _ in 0..<12 {
            tone += 40
            let p = pic(0, 300, tone: tone << 8)
            if d.look(p, at: t0 + t) != nil { fired += 1 }
            t += 3
            for _ in 0..<5 {
                if d.look(p, at: t0 + t) != nil { fired += 1 }
                t += 3
            }
        }
        XCTAssertTrue(d.calm)
        XCTAssertTrue(d.becameCalm)
        // Four alerts (the fourth says it's calm now), then quiet until two still minutes.
        XCTAssertEqual(fired, WindowChangeDetector.burst + 1)
    }

    func testLookingClearsWhatsThere() {
        var d = WindowChangeDetector(at: t0)
        _ = run(&d, [pic(), pic(0, 400), pic(0, 800)])
        d.seen()
        XCTAssertTrue(run(&d, Array(repeating: pic(0, 800), count: 10), start: 9).allSatisfy { $0 == nil })
    }

    func testNewLinesAndWords() {
        let new = AlertWords.newLines(before: ["$ npm run build", "compiling…"], now: ["$ npm run build", "compiling…", "error TS2304: Cannot find name 'x'", "Build failed"])
        XCTAssertEqual(new, ["error TS2304: Cannot find name 'x'", "Build failed"])
        XCTAssertEqual(AlertWords.headline(.finished, app: "Terminal", newLines: new), "Build failed")
        XCTAssertEqual(AlertWords.headline(.updated, app: "Terminal", newLines: ["Upload complete: report.pdf (2.1 MB)"]), "Upload complete")
        XCTAssertEqual(AlertWords.headline(.finished, app: "Terminal", newLines: ["src/a.ts(4,2): error TS1005: ';' expected and a long tail of words"]), "Terminal: something went wrong")
        XCTAssertEqual(AlertWords.headline(.finished, app: "Terminal", newLines: ["Done in 4.2s"]), "Terminal finished")
        XCTAssertEqual(AlertWords.detail(new), "Build failed")
    }

    func testTheWireCarriesAnUnknownKind() throws {
        var a = MacAlert(ref: .app(bundleID: "com.apple.Terminal", windowKey: "12", name: "Terminal"), appName: "Terminal", title: "build", kind: .finished, headline: "Build finished")
        a.kind = "somethingNewer"
        let data = try JSONEncoder().encode(Message.macAlert(a))
        guard case .macAlert(let back) = try JSONDecoder().decode(Message.self, from: data) else { return XCTFail() }
        XCTAssertEqual(back.knownKind, .updated)
        XCTAssertNil(back.attention)
        var q = back
        q.kind = MacAlert.Kind.asking.rawValue
        q.detail = "Allow edit?"
        XCTAssertEqual(q.attention?.question, "Allow edit?")
    }

    func testTheCloudRecordRoundTrips() {
        let a = MacAlert(ref: .app(bundleID: "com.apple.Terminal", windowKey: "12", name: "Terminal"), appName: "Terminal", title: "npm run build",
                         kind: .finished, headline: "Build finished", detail: "Done in 4.2s", jpeg: Data(repeating: 7, count: 120_000))
        let f = CloudAlertRecord.fields(a)!
        XCTAssertEqual(f["line"], "Build finished")
        XCTAssertEqual(CloudAlertRecord.name(a), "alert-" + MacAlert.windowKey(a.ref))
        let back = CloudAlertRecord.alert(line: f["line"], window: f["window"], ref: f["ref"], payload: f["promptID"])
        XCTAssertEqual(back, a)
        // Comfortably under a record's 1 MB.
        XCTAssertLessThan(f.values.reduce(0) { $0 + $1.utf8.count }, 200_000)
        // A question from a Mac from before: its promptID is a plain id.
        XCTAssertNil(CloudAlertRecord.alert(line: "x", window: "y", ref: f["ref"], payload: "agent-1f"))
    }

    func testALongRunThatEndsAsItBeganStillAlerts() {
        var d = WindowChangeDetector(at: t0)
        // The window shows the last run's output; the rerun clears it, runs 30 s, ends the same.
        let done = pic(0, 1300)
        var pics = [done, pic()]
        for i in 1...10 { pics.append(pic(0, i * 130)) }
        pics += Array(repeating: done, count: 6)
        let fired = run(&d, pics).compactMap { $0 }
        XCTAssertEqual(fired.count, 1)
    }

    func testTheLineSaysHowItWent() {
        let tail = ["  compiling module 22 of 22 (88 files)", "src/AuthView.tsx(42,7): error TS2304: Cannot find name 'token'.",
                    "Build failed with 1 error in 23.4s", "sameerbhutani@Sameers-Macbook-Pro ~ %"]
        XCTAssertEqual(AlertWords.detail(tail), "Build failed with 1 error in 23.4s")
        XCTAssertEqual(AlertWords.detail(["Exporting…", "Export complete: movie.mov", "❯"]), "Export complete: movie.mov")
        XCTAssertEqual(AlertWords.detail(["New message from Alex", "See you at 6"]), "See you at 6")
    }

    func testAReadingThatWobblesIsntNew() {
        let before = ["compiling module 20 of 22 (80 files)", "Build failed with 1 error in 23.4s", "compiling module 4 of 22 (16 files)"]
        let now = ["compiling module 20 of 22", "Build failed with l error in 23.4s.", "compiling module 4 of 22 (16 fi1es)", "Upload complete: report.pdf"]
        XCTAssertEqual(AlertWords.newLines(before: before, now: now), ["Upload complete: report.pdf"])
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, iOS 26.0, *)
    func testAHeadlineSticksToTheWindowsWords() {
        let text = "Upload complete: report.pdf (2.1 MB)"
        XCTAssertFalse(AlertReading.Writer.grounded("Build completed", in: text))
        XCTAssertTrue(AlertReading.Writer.grounded("Upload complete", in: text))
        XCTAssertFalse(AlertReading.Writer.grounded("Build failed: 3 errors", in: "Build failed with 1 error"))
        XCTAssertTrue(AlertReading.Writer.grounded("Build failed", in: "Build failed with 1 error"))
    }
    #endif
}
