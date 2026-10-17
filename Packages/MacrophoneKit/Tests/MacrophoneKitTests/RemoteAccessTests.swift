import CryptoKit
import Foundation
@testable import MacrophoneKit
import XCTest

final class RemoteAddressRuleTests: XCTestCase {
    func testTailscaleRange() {
        // 100.64.0.0/10: 100.64.0.0 … 100.127.255.255.
        XCTAssertTrue(RemoteAddressRule.isTailscale("100.64.0.1"))
        XCTAssertTrue(RemoteAddressRule.isTailscale("100.101.2.3"))
        XCTAssertTrue(RemoteAddressRule.isTailscale("100.127.255.255"))
        XCTAssertFalse(RemoteAddressRule.isTailscale("100.63.255.255"))
        XCTAssertFalse(RemoteAddressRule.isTailscale("100.128.0.0"))
        XCTAssertFalse(RemoteAddressRule.isTailscale("192.168.4.22"))
        XCTAssertFalse(RemoteAddressRule.isTailscale("100.64.0"))
        XCTAssertFalse(RemoteAddressRule.isTailscale("mac.tail1234.ts.net"))
        XCTAssertTrue(RemoteAddressRule.isTailscaleName("mac.tail1234.ts.net"))
        XCTAssertTrue(RemoteAddress(host: "Mac.Tail1234.TS.NET", port: 1).isTailscale)
        XCTAssertFalse(RemoteAddressRule.isTailscaleName("example.com"))
    }

    func testLocalMeansThisNetworkOrNearby() {
        for h in ["127.0.0.1", "localhost", "10.0.0.5", "192.168.4.22", "172.16.0.1", "172.31.255.255", "169.254.3.4",
                  "::1", "fe80::1c2f:7d%en0", "fd7a:115c:a1e0::1", "::ffff:192.168.1.2"] {
            XCTAssertTrue(RemoteAddressRule.isLocal(h), h)
        }
        // From away: Tailscale, the public internet, a stray IPv4-mapped public address.
        for h in ["100.101.2.3", "8.8.8.8", "172.32.0.1", "172.15.0.1", "2001:db8::1", "::ffff:8.8.8.8", "203.0.113.9"] {
            XCTAssertFalse(RemoteAddressRule.isLocal(h), h)
        }
    }

    func testTypedAddresses() throws {
        let a = try XCTUnwrap(RemoteAddressRule.parse("100.101.2.3"))
        XCTAssertEqual(a.host, "100.101.2.3")
        XCTAssertEqual(a.port, RemoteAddressRule.defaultPort)
        XCTAssertEqual(a.source, .typed)
        XCTAssertEqual(RemoteAddressRule.parse(" mac.tail1234.ts.net:5000 ")?.port, 5000)
        XCTAssertEqual(RemoteAddressRule.parse("mac.tail1234.ts.net:5000")?.host, "mac.tail1234.ts.net")
        XCTAssertEqual(RemoteAddressRule.parse("[fd7a::1]:47821")?.host, "fd7a::1")
        XCTAssertEqual(RemoteAddressRule.parse("[fd7a::1]:47821")?.display, "[fd7a::1]:47821")
        XCTAssertEqual(RemoteAddressRule.parse("fd7a::1")?.host, "fd7a::1")
        XCTAssertEqual(RemoteAddressRule.parse("home.example.com")?.display, "home.example.com:47821")
        XCTAssertEqual(RemoteAddressRule.parse("http://home.example.com:4000/")?.port, 4000)
        XCTAssertNil(RemoteAddressRule.parse(""))
        XCTAssertNil(RemoteAddressRule.parse("   "))
        XCTAssertNil(RemoteAddressRule.parse("host:0"))
        XCTAssertNil(RemoteAddressRule.parse("host:99999"))
        XCTAssertNil(RemoteAddressRule.parse("host:abc"))
        XCTAssertNil(RemoteAddressRule.parse("[fd7a::1"))
        XCTAssertNil(RemoteAddressRule.parse("has space.com"))
        XCTAssertNil(RemoteAddressRule.parse("12345"))
        XCTAssertNil(RemoteAddressRule.parse("rm -rf /"))
    }

    func testDialOrderTailscaleThenTypedThenLocal() {
        let lan = RemoteAddress(host: "192.168.4.22", port: 47_821)
        let ts = RemoteAddress(host: "100.101.2.3", port: 47_821)
        let name = RemoteAddress(host: "mac.tail1234.ts.net", port: 47_821)
        let typed = RemoteAddress(host: "home.example.com", port: 5000, source: .typed)
        let ordered = RemoteAddressRule.ordered([lan, typed, name, ts])
        XCTAssertEqual(ordered.map(\.host), ["100.101.2.3", "mac.tail1234.ts.net", "home.example.com", "192.168.4.22"])
        // The same address twice (typed what the Mac already said) is dialled once.
        let dup = RemoteAddress(host: "100.101.2.3", port: 47_821, source: .typed)
        XCTAssertEqual(RemoteAddressRule.ordered([ts, dup, lan]).count, 2)
        XCTAssertTrue(RemoteAddressRule.ordered([]).isEmpty)
    }

    func testMacListReplacesItsOwnKeepsTyped() {
        let typed = RemoteAddress(host: "home.example.com", port: 5000, source: .typed)
        let stored = [RemoteAddress(host: "100.101.2.3", port: 47_821), typed, RemoteAddress(host: "192.168.4.22", port: 47_821)]
        let told = [RemoteAddress(host: "100.101.2.9", port: 47_900, source: .typed)]  // the Mac's are always `.mac`
        let merged = RemoteAddressRule.merge(told: told, into: stored)
        XCTAssertEqual(merged.map(\.host), ["home.example.com", "100.101.2.9"])
        XCTAssertEqual(merged.map(\.source), [.typed, .mac])
        // Remote access turned off on the Mac: its addresses go, the typed one stays.
        XCTAssertEqual(RemoteAddressRule.merge(told: [], into: stored).map(\.host), ["home.example.com"])
    }

    func testOwnAddressesTailscaleFirstThenWiFi() {
        let list = [InterfaceAddress(interface: "bridge0", host: "192.168.64.1"),
                    InterfaceAddress(interface: "en0", host: "192.168.4.22"),
                    InterfaceAddress(interface: "utun4", host: "100.101.2.3"),
                    InterfaceAddress(interface: "utun2", host: "10.8.0.2")]
        XCTAssertEqual(NetworkAddresses.order(list).map(\.host), ["100.101.2.3", "192.168.4.22", "192.168.64.1", "10.8.0.2"])
        let told = NetworkAddresses.remoteAddresses(port: 47_821, tailscaleName: nil)
        XCTAssertTrue(told.allSatisfy { $0.source == .mac && $0.port == 47_821 })
        XCTAssertFalse(told.contains { $0.host.hasPrefix("127.") || $0.host.hasPrefix("169.254.") })
    }

    func testEndpointHost() {
        let e = RemoteAddress(host: "100.101.2.3", port: 47_821).endpoint
        XCTAssertEqual(RemoteAddressRule.host(of: e), "100.101.2.3")
        let v6 = RemoteAddress(host: "fe80::1%en0", port: 1).endpoint
        XCTAssertEqual(RemoteAddressRule.host(of: v6), "fe80::1")
        XCTAssertNil(RemoteAddressRule.host(of: .service(name: "x", type: Product.serviceType, domain: "local.", interface: nil)))
    }
}

final class RemoteAddressStorageTests: XCTestCase {
    /// A paired-devices list written before remote access (no `remoteAddresses` key) still loads.
    func testOldPairingListLoads() throws {
        let json = """
        [{"id":"5B1D2C9A-5E4E-4C7B-8E5C-5F3F0E2A1B2C","name":"Sameer's MacBook Pro","pairedAt":"2026-10-01T10:00:00Z","lastSeen":"2026-10-16T10:00:00Z"}]
        """
        let peers = try WireCoding.decoder.decode([PairedPeer].self, from: Data(json.utf8))
        XCTAssertEqual(peers.count, 1)
        XCTAssertEqual(peers[0].name, "Sameer's MacBook Pro")
        XCTAssertTrue(peers[0].remoteAddresses.isEmpty)
    }

    func testAddressesPersistWithThePairing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mp-remote-\(UUID().uuidString)")
        let store = FilePairingStore(url: dir.appendingPathComponent("pairings.json"))
        let mac = PairedPeer(id: UUID(), name: "Mac")
        store.save(mac, key: SymmetricKey(data: LinkCrypto.randomBytes(32)))
        var peer = try XCTUnwrap(store.peers().first)
        peer.remoteAddresses = [RemoteAddress(host: "100.101.2.3", port: 47_821), RemoteAddress(host: "home.example.com", port: 5000, source: .typed)]
        store.update(peer)
        let back = try XCTUnwrap(store.peers().first)
        XCTAssertEqual(back.remoteAddresses.map(\.host), ["100.101.2.3", "home.example.com"])
        XCTAssertNotNil(store.key(for: mac.id), "an update never touches the key")
        // Forgetting the Mac takes its addresses with it.
        store.remove(mac.id)
        XCTAssertTrue(store.peers().isEmpty)
        try? FileManager.default.removeItem(at: dir)
    }

    /// The new message decodes, and an older message set is unchanged by it.
    func testRemoteAddressesMessageRoundTrip() throws {
        let m: Message = .remoteAddresses([RemoteAddress(host: "100.101.2.3", port: 47_821), RemoteAddress(host: "mac.tail1234.ts.net", port: 47_821)])
        let data = try WireCoding.encoder.encode(m)
        guard case let .remoteAddresses(list) = try WireCoding.decoder.decode(Message.self, from: data) else { return XCTFail("wrong case") }
        XCTAssertEqual(list.map(\.host), ["100.101.2.3", "mac.tail1234.ts.net"])
        XCTAssertEqual(list[0].source, .mac)
        XCTAssertEqual(RemoteAccess.feature, "remote")
    }
}
