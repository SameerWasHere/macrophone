import CryptoKit
import Foundation
@testable import MacrophoneKit
import XCTest

/// Several Macs on one phone (Oct 19 2026): the order, the active one, what each remembers, and
/// how a phone from before (one Mac, one set of keys) comes across with nothing to re-pair.
final class MacRosterTests: XCTestCase {
    private func peer(_ name: String, daysAgo: Double) -> PairedPeer {
        PairedPeer(id: UUID(), name: name, pairedAt: Date().addingTimeInterval(-daysAgo * 86_400))
    }

    func testOrderIsTheOrderTheyWerePaired() {
        let a = peer("Studio Mac", daysAgo: 10), b = peer("MacBook Air", daysAgo: 3), c = peer("Mac mini", daysAgo: 1)
        XCTAssertEqual(MacRoster.ordered([c, a, b]).map(\.name), ["Studio Mac", "MacBook Air", "Mac mini"])
        XCTAssertEqual(MacRoster.ordered([]).count, 0)
    }

    func testActiveIsTheChosenElseTheMostRecentlyPaired() {
        let a = peer("Studio Mac", daysAgo: 10), b = peer("MacBook Air", daysAgo: 3)
        // A phone from before: nothing chosen → the most recently paired, v1's rule.
        XCTAssertEqual(MacRoster.active(in: [a, b], chosen: nil)?.id, b.id)
        XCTAssertEqual(MacRoster.active(in: [a, b], chosen: a.id)?.id, a.id)
        // The chosen one was forgotten: back to the rule.
        XCTAssertEqual(MacRoster.active(in: [a, b], chosen: UUID())?.id, b.id)
        XCTAssertNil(MacRoster.active(in: [], chosen: a.id))
    }

    func testStepWrapsRoundAndNeedsTwo() {
        let a = peer("Studio Mac", daysAgo: 10), b = peer("MacBook Air", daysAgo: 3), c = peer("Mac mini", daysAgo: 1)
        let all = [b, c, a]
        XCTAssertEqual(MacRoster.step(1, from: a.id, in: all)?.id, b.id, "a swipe up goes to the next")
        XCTAssertEqual(MacRoster.step(1, from: c.id, in: all)?.id, a.id, "and round from the last")
        XCTAssertEqual(MacRoster.step(-1, from: a.id, in: all)?.id, c.id, "a swipe down goes to the one before, round from the first")
        XCTAssertEqual(MacRoster.step(-1, from: b.id, in: all)?.id, a.id)
        XCTAssertEqual(MacRoster.step(1, from: UUID(), in: all)?.id, a.id, "an unknown start lands on the first")
        XCTAssertNil(MacRoster.step(1, from: a.id, in: [a]), "one Mac: nothing to switch to")
        XCTAssertNil(MacRoster.step(1, from: nil, in: []))
    }

    private func defaults() -> UserDefaults {
        let name = "macroster.test.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        return d
    }

    func testEachMacRemembersItsOwnPick() {
        let d = defaults()
        let p = MacPreferences(defaults: d)
        let a = UUID(), b = UUID()
        let claude = TargetRef.app(bundleID: "com.anthropic.claudefordesktop", windowKey: nil, name: "Claude")
        let messages = TargetRef.app(bundleID: "com.apple.MobileSMS", windowKey: nil, name: "Messages")
        p.setSelection(SendSelection(target: claude, send: true), for: a)
        p.rememberSend(true, for: claude, mac: a)
        p.rememberSend(false, for: messages, mac: a)
        XCTAssertEqual(p.selection(for: a), SendSelection(target: claude, send: true))
        XCTAssertEqual(p.selection(for: b), .default, "a Mac with no pick yet copies to its clipboard")
        XCTAssertTrue(p.rememberedSend(for: claude, mac: a))
        XCTAssertFalse(p.rememberedSend(for: claude, mac: b), "remembered per Mac")
        p.setSelection(SendSelection(target: messages), for: b)
        XCTAssertEqual(p.selection(for: a).target, claude, "b's pick doesn't touch a's")
        p.forget(mac: a)
        XCTAssertEqual(p.selection(for: a), .default)
        XCTAssertFalse(p.rememberedSend(for: claude, mac: a))
        XCTAssertEqual(p.selection(for: b).target, messages)
    }

    func testThePhoneFromBeforeKeepsItsPickForItsOneMac() {
        let d = defaults()
        let claude = TargetRef.app(bundleID: "com.anthropic.claudefordesktop", windowKey: nil, name: "Claude")
        // The one Mac's keys as the app wrote them before Oct 19 2026.
        d.set(try! JSONEncoder().encode(SendSelection(target: claude, send: true)), forKey: MacPreferences.selectionKey)
        d.set([claude.storageKey: true], forKey: MacPreferences.sendByTargetKey)
        let p = MacPreferences(defaults: d)
        let first = UUID(), second = UUID()
        XCTAssertTrue(p.adopt(legacyFor: first))
        XCTAssertEqual(p.selection(for: first), SendSelection(target: claude, send: true), "the pick carries over")
        XCTAssertTrue(p.rememberedSend(for: claude, mac: first))
        XCTAssertNil(d.object(forKey: MacPreferences.selectionKey), "the old keys are gone")
        XCTAssertNil(d.object(forKey: MacPreferences.sendByTargetKey))
        XCTAssertFalse(p.adopt(legacyFor: first), "only once")
        XCTAssertFalse(p.adopt(legacyFor: second), "nothing left for a second Mac")
        XCTAssertEqual(p.selection(for: second), .default, "a second Mac starts fresh")
    }

    func testChosenMacIsKept() {
        let d = defaults()
        let p = MacPreferences(defaults: d)
        XCTAssertNil(p.chosenMac)
        let id = UUID()
        p.chosenMac = id
        XCTAssertEqual(MacPreferences(defaults: d).chosenMac, id)
        p.forget(mac: id)
        XCTAssertNil(p.chosenMac, "forgetting the chosen Mac clears the choice")
    }

    // MARK: The link's side

    private func client(_ d: UserDefaults) -> (LinkClient, FilePairingStore) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("macroster-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let store = FilePairingStore(url: dir.appendingPathComponent("pairings.json"))
        let c = LinkClient(identity: DeviceIdentity(id: UUID(), name: "test phone"), store: store, appVersion: "0", osDescription: "test", defaults: d)
        return (c, store)
    }

    func testClientActiveMacAndSwitching() {
        let d = defaults()
        let (c, store) = client(d)
        XCTAssertEqual(c.state, .notPaired)
        XCTAssertNil(c.activeMac)
        let a = peer("Studio Mac", daysAgo: 10), b = peer("MacBook Air", daysAgo: 3)
        store.save(a, key: SymmetricKey(size: .bits256))
        store.save(b, key: SymmetricKey(size: .bits256))
        XCTAssertEqual(c.pairedMacs.map(\.name), ["Studio Mac", "MacBook Air"])
        XCTAssertEqual(c.activeMac?.id, b.id, "nothing chosen: the most recently paired, as before")
        c.setActiveMac(a.id)
        XCTAssertEqual(c.activeMac?.id, a.id)
        XCTAssertEqual(MacPreferences(defaults: d).chosenMac, a.id, "kept for the next launch")
        c.setActiveMac(UUID())
        XCTAssertEqual(c.activeMac?.id, a.id, "an unknown id changes nothing")
        // A new client on the same phone starts on the chosen Mac.
        let (again, _) = (LinkClient(identity: c.identity, store: store, appVersion: "0", osDescription: "test", defaults: d), ())
        XCTAssertEqual(again.activeMac?.id, a.id)
        XCTAssertEqual(again.state, .searching)
    }

    func testUnpairingTheActiveMacHandsOverToTheNext() async {
        let d = defaults()
        let (c, store) = client(d)
        let a = peer("Studio Mac", daysAgo: 10), b = peer("MacBook Air", daysAgo: 3)
        store.save(a, key: SymmetricKey(size: .bits256))
        store.save(b, key: SymmetricKey(size: .bits256))
        c.setActiveMac(a.id)
        // Forgetting the other one leaves the active alone.
        await c.unpair(b.id)
        XCTAssertEqual(c.activeMac?.id, a.id)
        XCTAssertEqual(c.pairedMacs.count, 1)
        store.save(b, key: SymmetricKey(size: .bits256))
        // Forgetting the active one: the most recently paired takes over, and the choice follows.
        await c.unpair(a.id)
        XCTAssertEqual(c.activeMac?.id, b.id)
        XCTAssertEqual(MacPreferences(defaults: d).chosenMac, b.id)
        await c.unpair(b.id)
        XCTAssertNil(c.activeMac)
        XCTAssertEqual(c.state, .notPaired)
        XCTAssertNil(MacPreferences(defaults: d).chosenMac)
    }

    func testASendForAnotherMacIsRefused() async {
        let d = defaults()
        let (c, store) = client(d)
        let a = peer("Studio Mac", daysAgo: 10), b = peer("MacBook Air", daysAgo: 3)
        store.save(a, key: SymmetricKey(size: .bits256))
        store.save(b, key: SymmetricKey(size: .bits256))
        c.setActiveMac(a.id)
        let dictation = Dictation(raw: "hello")
        do {
            _ = try await c.send(dictation, delayed: false, to: b.id, timeout: 1)
            XCTFail("sent to a Mac that isn't active")
        } catch let e as LinkError {
            if case .anotherMac = e {} else { XCTFail("wrong error: \(e)") }
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}
