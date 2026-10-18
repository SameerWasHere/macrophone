import XCTest
@testable import MacrophoneKit

final class EveryAppTests: XCTestCase {
    private let list = [
        LiveTarget(bundleID: "com.anthropic.claude", appName: "Claude"),
        LiveTarget(bundleID: "company.thebrowser.dia", appName: "Dia", canType: false),
    ]

    func testAPhoneNamingEveryAppGetsThemAll() {
        XCTAssertEqual(EveryApp.list(list, for: [EveryApp.feature]).map(\.appName), ["Claude", "Dia"])
    }

    func testAnOlderPhoneGetsOnlyThePlacesToType() {
        XCTAssertEqual(EveryApp.list(list, for: []).map(\.appName), ["Claude"])
    }

    func testAnOlderMacsTargetsCountAsTypeable() throws {
        let old = #"{"id":"com.apple.Terminal","bundleID":"com.apple.Terminal","appName":"Terminal"}"#
        let t = try JSONDecoder().decode(LiveTarget.self, from: Data(old.utf8))
        XCTAssertTrue(t.typeable)
        XCTAssertFalse(list[1].typeable)
    }
}
