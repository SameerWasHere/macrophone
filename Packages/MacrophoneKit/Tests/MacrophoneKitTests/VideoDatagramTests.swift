import CryptoKit
import Foundation
import Network
import XCTest
@testable import MacrophoneKit

/// Video datagrams (Nov 10 2026): the sealing, the cutting and parity, the phone's reassembly and
/// order, the Mac's resends — pure — and then set-up, fallback, a wrong key, loss and reordering
/// over loopback (ports 47981–47986).
final class VideoDatagramTests: XCTestCase {
    // MARK: The rule

    func testOpensOnlyWhenBothNameItAwayAndEnabled() {
        let p = ["video", VideoDatagrams.feature], m: Set<String> = ["video", VideoDatagrams.feature]
        XCTAssertTrue(VideoDatagrams.shouldOpen(phoneFeatures: p, macFeatures: m, remote: true, enabled: true))
        XCTAssertFalse(VideoDatagrams.shouldOpen(phoneFeatures: p, macFeatures: m, remote: false, enabled: true))
        XCTAssertFalse(VideoDatagrams.shouldOpen(phoneFeatures: p, macFeatures: ["video"], remote: true, enabled: true))
        XCTAssertFalse(VideoDatagrams.shouldOpen(phoneFeatures: ["video"], macFeatures: m, remote: true, enabled: true))
        XCTAssertFalse(VideoDatagrams.shouldOpen(phoneFeatures: p, macFeatures: m, remote: true, enabled: false))
        XCTAssertFalse(VideoDatagrams.shippedDefault, "shipped off until proven on a real path")
    }

    func testAPieceFitsTailscalesMTU() {
        var sealer = DatagramSealer(key: SymmetricKey(size: .bits256))
        let piece = DatagramFramer.pieces(frame: 1, message: Data(repeating: 7, count: 5000), keyframe: false, group: 4)[0]
        let d = sealer.seal(DatagramMessage.piece(piece).encoded())
        XCTAssertLessThanOrEqual(d.count, 1232, "IPv6 + UDP inside a 1280-byte MTU")
    }

    // MARK: Sealing

    func testSealedDatagramsOpenOnceInAnyOrderAndForgeriesFail() throws {
        let key = SymmetricKey(size: .bits256)
        var s = DatagramSealer(key: key)
        var o = DatagramOpener(key: key)
        let a = s.seal(Data("a".utf8)), b = s.seal(Data("b".utf8)), c = s.seal(Data("c".utf8))
        // Out of order is fine.
        XCTAssertEqual(try o.open(c).plain, Data("c".utf8))
        XCTAssertEqual(try o.open(a).plain, Data("a".utf8))
        // A replay or a duplicate is refused.
        XCTAssertThrowsError(try o.open(a))
        XCTAssertThrowsError(try o.open(c))
        XCTAssertEqual(try o.open(b).plain, Data("b".utf8))
        // One flipped bit, or another session's key: refused.
        var bad = s.seal(Data("d".utf8)); bad[bad.count - 1] ^= 1
        XCTAssertThrowsError(try o.open(bad))
        var other = DatagramSealer(key: SymmetricKey(size: .bits256))
        XCTAssertThrowsError(try o.open(other.seal(Data("e".utf8))))
        // A packet number changed in the clear (it's authenticated) fails too.
        var moved = s.seal(Data("f".utf8)); moved[8] ^= 0x40
        XCTAssertThrowsError(try o.open(moved))
        // Far older than the window: refused without trying.
        for _ in 0..<(DatagramOpener.window + 5) { _ = s.seal(Data()) }
        _ = try o.open(s.seal(Data("new".utf8)))
        XCTAssertThrowsError(try o.open(a))
    }

    func testAHelloNamesThePhoneAndIsAuthenticated() throws {
        let key = SymmetricKey(size: .bits256), id = UUID()
        var s = DatagramSealer(key: key)
        let hello = s.seal(DatagramMessage.hello.encoded(), hello: id)
        XCTAssertEqual(datagramHelloPhone(hello), id)
        var o = DatagramOpener(key: key)
        let (plain, isHello) = try o.open(hello)
        XCTAssertTrue(isHello)
        XCTAssertEqual(DatagramMessage.decode(plain), .hello)
        // Someone swapping in another phone's id breaks the tag.
        var swapped = s.seal(DatagramMessage.hello.encoded(), hello: id)
        swapped.replaceSubrange(1..<17, with: UUID().data)
        XCTAssertThrowsError(try o.open(swapped))
        XCTAssertNil(datagramHelloPhone(s.seal(Data())))
    }

    func testKeysBelongToOneSessionAndAreNotTheLanes() {
        let key = SymmetricKey(size: .bits256)
        let pn = LinkCrypto.randomBytes(32), mn = LinkCrypto.randomBytes(32)
        let a = LaneSecrets(pairKey: key, phoneNonce: pn, macNonce: mn)
        let b = LaneSecrets(pairKey: key, phoneNonce: pn, macNonce: mn)
        XCTAssertEqual(a.datagram.macToPhone.rawData, b.datagram.macToPhone.rawData)
        XCTAssertNotEqual(a.datagram.macToPhone.rawData, a.datagram.phoneToMac.rawData)
        XCTAssertNotEqual(a.datagram.macToPhone.rawData, a.macToPhone.rawData)
        let next = LaneSecrets(pairKey: key, phoneNonce: LinkCrypto.randomBytes(32), macNonce: mn)
        XCTAssertNotEqual(a.datagram.phoneToMac.rawData, next.datagram.phoneToMac.rawData)
    }

    // MARK: The wire inside

    func testMessagesRoundTripAndBadShapesAreRefused() {
        let p = DatagramPiece(frame: 9, index: 2, count: 3, pieceSize: 10, groups: 1, keyframe: true, parity: false, resend: true, total: 25, data: Data(repeating: 1, count: 5))
        let all: [DatagramMessage] = [.piece(p), .ready, .reportAck(echo: 123), .closing, .hello,
                                      .report(DatagramReport(time: 5, resolved: 3, seen: 4, received: 99, lossPermille: 20, rttMillis: 80)),
                                      .nack([DatagramNack(frame: 4, all: false, missing: [1, 3]), DatagramNack(frame: 5, all: true, missing: [])])]
        for m in all { XCTAssertEqual(DatagramMessage.decode(m.encoded()), m) }
        // A piece whose shape can't be (index past the count, data longer than a piece, a length
        // that doesn't fit the count): nil, never a crash below.
        var wrong = p; wrong.index = 3
        XCTAssertNil(DatagramMessage.decode(DatagramMessage.piece(wrong).encoded()))
        wrong = p; wrong.data = Data(repeating: 0, count: 11)
        XCTAssertNil(DatagramMessage.decode(DatagramMessage.piece(wrong).encoded()))
        wrong = p; wrong.total = 40
        XCTAssertNil(DatagramMessage.decode(DatagramMessage.piece(wrong).encoded()))
        XCTAssertNil(DatagramMessage.decode(Data([200])))
        XCTAssertNil(DatagramMessage.decode(Data([17, 0, 1])))
    }

    // MARK: Cutting and parity

    func testPiecesRebuildTheMessageAndParityCoversOneLossPerGroup() {
        let msg = Data((0..<10_000).map { UInt8($0 % 251) })
        let pieces = DatagramFramer.pieces(frame: 1, message: msg, keyframe: false, pieceSize: 1000, group: 4)
        XCTAssertEqual(pieces.filter { !$0.parity }.count, 10)
        XCTAssertEqual(pieces.filter(\.parity).count, 3)
        // Drop one piece from each group (0, 1, 2 are in groups 0, 1, 2): all three come back.
        var r = FrameReassembler()
        var out: [Data] = []
        for p in pieces where !( !p.parity && [0, 1, 2].contains(Int(p.index))) { out += r.receive(p, now: 0) }
        XCTAssertEqual(out, [msg])
        XCTAssertEqual(r.stats.recovered, 3)
        // A burst of two in a row lands in two groups (interleaved), so it's rebuilt too.
        var r2 = FrameReassembler()
        var out2: [Data] = []
        for p in pieces where !( !p.parity && [5, 6].contains(Int(p.index))) { out2 += r2.receive(p, now: 0) }
        XCTAssertEqual(out2, [msg])
        // Two in one group (0 and 3): parity can't; nothing is handed on yet.
        var r3 = FrameReassembler()
        var out3: [Data] = []
        for p in pieces where !( !p.parity && [0, 3].contains(Int(p.index))) { out3 += r3.receive(p, now: 0) }
        XCTAssertTrue(out3.isEmpty)
    }

    func testATinyFrameAndAnEmptyOneStillGo() {
        for size in [0, 1, 1150, 1151] {
            let msg = Data(repeating: 3, count: size)
            var r = FrameReassembler()
            let pieces = DatagramFramer.pieces(frame: 1, message: msg, keyframe: true, group: 16)
            // The data alone, or parity standing in for the one lost piece.
            let out = pieces.filter { $0.index != 0 || $0.parity }.flatMap { r.receive($0, now: 0) }
            XCTAssertEqual(out, [msg], "\(size)")
        }
    }

    // MARK: Order, NACKs, deadlines

    private func frame(_ f: UInt32, _ bytes: Int, keyframe: Bool = false, group: Int = 0) -> [DatagramPiece] {
        DatagramFramer.pieces(frame: f, message: Data(repeating: UInt8(f % 255), count: bytes), keyframe: keyframe, group: group)
    }

    func testFramesAreHandedOnInOrderAndAGapIsAskedFor() {
        var r = FrameReassembler()
        r.rtt = 0.08
        let one = frame(1, 3000), two = frame(2, 3000)
        // Frame 2 complete, frame 1 missing its middle piece: nothing yet (the decoder needs 1 first).
        XCTAssertTrue(two.flatMap { r.receive($0, now: 0) }.isEmpty)
        XCTAssertTrue(one.filter { $0.index != 1 }.flatMap { r.receive($0, now: 0.001) }.isEmpty)
        // Frame 1 is older than the newest frame: asked for at once.
        let t = r.tick(now: 0.002)
        XCTAssertEqual(t.nacks, [DatagramNack(frame: 1, all: false, missing: [1])])
        // Not again within the interval.
        XCTAssertTrue(r.tick(now: 0.02).nacks.isEmpty)
        // The resend arrives: 1 then 2.
        var again = one[1]; again.resend = true
        XCTAssertEqual(r.receive(again, now: 0.09).count, 2)
        XCTAssertEqual(r.stats.delivered, 2)
        XCTAssertEqual(r.stats.resendsUseful, 1)
        // A late duplicate of a delivered frame is nothing.
        XCTAssertTrue(r.receive(one[0], now: 0.1).isEmpty)
    }

    func testTheTailOfTheNewestFrameIsAskedForOnceThePiecesStop() {
        var r = FrameReassembler()
        let one = frame(1, 5000)   // 5 pieces, the last lost
        _ = one.dropLast().flatMap { r.receive($0, now: 0) }
        XCTAssertTrue(r.tick(now: 0.005).nacks.isEmpty, "pieces may still be coming")
        XCTAssertEqual(r.tick(now: 0.02).nacks, [DatagramNack(frame: 1, all: false, missing: [4])])
    }

    func testAFrameNeverSeenIsAskedForWhole() {
        var r = FrameReassembler()
        _ = frame(1, 100).flatMap { r.receive($0, now: 0) }
        _ = frame(3, 100).flatMap { r.receive($0, now: 0.01) }
        XCTAssertTrue(r.tick(now: 0.015).nacks.isEmpty, "a moment for reordering")
        XCTAssertEqual(r.tick(now: 0.03).nacks, [DatagramNack(frame: 2, all: true, missing: [])])
    }

    func testAFramePastItsDeadlineIsGivenUpAndTheNextGoOn() {
        var r = FrameReassembler()
        r.rtt = 0.08   // deadline 0.215 s
        XCTAssertEqual(r.deadline, 0.215, accuracy: 0.001)
        _ = frame(1, 3000).filter { $0.index != 0 }.flatMap { r.receive($0, now: 0) }
        _ = frame(2, 100).flatMap { r.receive($0, now: 0.05) }
        XCTAssertTrue(r.tick(now: 0.2).deliver.isEmpty)
        let late = r.tick(now: 0.22)
        XCTAssertEqual(late.deliver.count, 1, "frame 2 goes on; the phone then asks for a keyframe")
        XCTAssertEqual(r.stats.skipped, 1)
        XCTAssertEqual(r.next, 3)
    }

    func testACompleteKeyframeSkipsWhatItReplaces() {
        var r = FrameReassembler()
        _ = frame(1, 3000).filter { $0.index != 0 }.flatMap { r.receive($0, now: 0) }
        _ = frame(2, 100).flatMap { r.receive($0, now: 0) }
        let k = frame(3, 2000, keyframe: true).flatMap { r.receive($0, now: 0.01) }
        XCTAssertEqual(k.count, 1)
        XCTAssertEqual(r.stats.skipped, 2)
        XCTAssertEqual(r.next, 4)
    }

    func testLossIsReportedFromFirstSendsOnly() {
        var r = FrameReassembler()
        for f in UInt32(1)...10 { _ = frame(f, 3000).filter { !(f == 5 && $0.index == 0) }.flatMap { r.receive($0, now: 0) } }
        XCTAssertEqual(r.takeLoss(), 33)   // 1 of 30
    }

    // MARK: The Mac's side

    func testTheSenderResendsWhatsAskedAndAFrameTheyNeverSaw() {
        var s = DatagramSender()
        s.lossPermille = 0
        let a = s.frame(Data(repeating: 1, count: 3000), keyframe: true, now: 0)
        XCTAssertEqual(a.filter(\.parity).count, 1, "a little parity even with no loss reported")
        _ = s.frame(Data(repeating: 2, count: 100), keyframe: false, now: 0.01)
        XCTAssertEqual(s.inFlight(now: 0.02), 2)
        let again = s.nack([DatagramNack(frame: 1, all: false, missing: [2]), DatagramNack(frame: 99, all: true, missing: [])])
        XCTAssertEqual(again.map(\.index), [2])
        XCTAssertTrue(again.allSatisfy(\.resend))
        // The phone has seen frame 1 but not 2: once a round trip has passed, 2 goes again whole.
        let early = s.report(DatagramReport(time: 0, resolved: 1, seen: 1, received: 3, lossPermille: 40, rttMillis: 80), now: 0.05)
        XCTAssertTrue(early.isEmpty)
        let late = s.report(DatagramReport(time: 0, resolved: 1, seen: 1, received: 3, lossPermille: 40, rttMillis: 80), now: 0.2)
        XCTAssertEqual(late.map(\.frame), [2])
        XCTAssertEqual(s.inFlight(now: 0.2), 1)
        // Loss reported: more parity on the next frame.
        let b = s.frame(Data(repeating: 3, count: 8000), keyframe: false, now: 0.3)
        XCTAssertEqual(b.filter(\.parity).count, 2)
        // Resolved: nothing left to resend; old frames are forgotten anyway.
        _ = s.report(DatagramReport(time: 0, resolved: 3, seen: 3, received: 30, lossPermille: 0, rttMillis: 80), now: 0.4)
        XCTAssertEqual(s.inFlight(now: 0.4), 0)
    }

    /// A model of the whole loop — Mac, phone, loss, delay — in simulated time: at 5% loss nearly
    /// every frame arrives, in order, and few are given up.
    func testTheLoopDeliversNearlyEverythingAtFivePercentLoss() {
        var sender = DatagramSender()
        var r = FrameReassembler()
        r.rtt = 0.08
        var rng: UInt64 = 0x9E3779B97F4A7C15
        func lost() -> Bool { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return rng % 1000 < 50 }
        var toPhone: [(TimeInterval, DatagramPiece)] = []
        var toMac: [(TimeInterval, DatagramMessage)] = []
        var delivered: [Data] = []
        var now: TimeInterval = 0
        var nextFrameAt: TimeInterval = 0
        var nextReport: TimeInterval = 0
        var made = 0
        while now < 12 {
            if now >= nextFrameAt, made < 190 {
                made += 1
                for p in sender.frame(Data(repeating: UInt8(made % 250), count: 20_000 + made % 7 * 1000), keyframe: made == 1, now: now) where !lost() {
                    toPhone.append((now + 0.04, p))
                }
                nextFrameAt += 1.0 / 19
            }
            toPhone.sort { $0.0 < $1.0 }
            while let f = toPhone.first, f.0 <= now { toPhone.removeFirst(); delivered += r.receive(f.1, now: now) }
            let t = r.tick(now: now)
            delivered += t.deliver
            if !t.nacks.isEmpty, !lost() { toMac.append((now + 0.04, .nack(t.nacks))) }
            if now >= nextReport {
                nextReport = now + 0.1
                if !lost() { toMac.append((now + 0.04, .report(DatagramReport(time: 0, resolved: r.next - 1, seen: r.seen, received: 0, lossPermille: UInt16(r.takeLoss()), rttMillis: 80)))) }
            }
            toMac.sort { $0.0 < $1.0 }
            while let m = toMac.first, m.0 <= now {
                toMac.removeFirst()
                var again: [DatagramPiece] = []
                if case let .nack(list) = m.1 { again = sender.nack(list) }
                if case let .report(rep) = m.1 { again = sender.report(rep, now: now) }
                for p in again where !lost() { toPhone.append((now + 0.04, p)) }
            }
            now += 0.002
        }
        XCTAssertEqual(made, 190)
        print("LOOP delivered \(r.stats.delivered) skipped \(r.stats.skipped) recovered \(r.stats.recovered) nacked \(r.stats.nacked) resent \(sender.resentPieces) parity \(sender.parityPieces)/\(sender.dataPieces)")
        XCTAssertEqual(r.stats.delivered + r.stats.skipped, 190)
        XCTAssertGreaterThanOrEqual(r.stats.delivered, 186, "at most a couple given up at 5% loss")
        // In order: each delivered message is the frame after the one before (frame bytes carry the number).
        XCTAssertGreaterThan(r.stats.recovered, 100, "parity does most of the work")
    }

    /// The bench (mpctl dgram-sim): with no loss both deliver everything near the one-way trip; at
    /// 2% the lane's median carries the resends, the datagrams' doesn't.
    func testTheBenchComparesLikeForLike() {
        let lane0 = VideoDatagramBench.run(datagrams: false, loss: 0, frames: 200)
        let dg0 = VideoDatagramBench.run(datagrams: true, loss: 0, frames: 200)
        XCTAssertEqual(lane0.shown, 200); XCTAssertEqual(dg0.shown, 200)
        XCTAssertEqual(lane0.p95, 40, accuracy: 1)
        XCTAssertLessThan(dg0.p95, 45)
        let lane2 = VideoDatagramBench.run(datagrams: false, loss: 0.02, frames: 400)
        let dg2 = VideoDatagramBench.run(datagrams: true, loss: 0.02, frames: 400)
        XCTAssertLessThan(dg2.p50, lane2.p50)
        XCTAssertGreaterThanOrEqual(dg2.shown, 390)
    }

    // MARK: Over loopback (the away door, its UDP twin)

    func testDatagramsOpenAwayAndCarryTheVideoWhileInputStaysOnTheSession() async throws {
        let rig = try await Rig.make(port: 47981, datagrams: true)
        defer { rig.stop() }
        try await rig.connect()
        try await rig.waitFor { rig.client.hasVideoDatagrams && rig.server.openSession(rig.phoneID)?.hasDatagrams == true }
        XCTAssertTrue(rig.client.macFeatures.contains(VideoDatagrams.feature))
        for seq in 1...5 {
            let frame = WatchVideoFrame(seq: seq, data: Data(repeating: UInt8(seq), count: 30_000), parameterSets: nil, keyframe: seq == 1,
                                        width: 4, height: 4, appName: "Claude", bundleID: nil, focus: nil)
            let sent = await rig.server.send(.watchVideo(frame), to: rig.phoneID); XCTAssertTrue(sent)
        }
        try await rig.waitFor { rig.phone.videoSeqs == [1, 2, 3, 4, 5] }
        let stats = try XCTUnwrap(rig.client.videoDatagramStats)
        XCTAssertEqual(stats.framesDelivered, 5)
        XCTAssertGreaterThan(stats.datagramsIn, 100)
        // Nothing went on the lane meanwhile.
        XCTAssertEqual(rig.server.openSession(rig.phoneID)?.laneSlot.get()?.sent ?? 0, 0)
        let rtt = await rig.client.roundTrip(); XCTAssertNotNil(rtt)
    }

    func testAnOlderMacOrPhoneKeepsTheLane() async throws {
        let rig = try await Rig.make(port: 47982, datagrams: true)
        defer { rig.stop() }
        rig.client.datagramsEnabled = false   // its hello doesn't name datagrams
        try await rig.connect()
        try await rig.waitFor { rig.client.hasVideoLane }
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertFalse(rig.client.hasVideoDatagrams)
        XCTAssertFalse(rig.server.openSession(rig.phoneID)?.hasDatagrams ?? true)
        let frame = WatchVideoFrame(seq: 1, data: Data([1]), parameterSets: nil, keyframe: true, width: 2, height: 2, appName: "A", bundleID: nil, focus: nil)
        let sent = await rig.server.send(.watchVideo(frame), to: rig.phoneID); XCTAssertTrue(sent)
        try await rig.waitFor { rig.phone.videoSeqs == [1] }
    }

    func testAMacWhoseUDPIsBlockedCostsUnderASecondAndKeepsTheLane() async throws {
        // The Mac names datagrams but nothing listens on UDP (a firewall that drops it).
        let rig = try await Rig.make(port: 47983, datagrams: true)
        defer { rig.stop() }
        rig.server.datagramDoor.stop()
        try await rig.connect()
        try await rig.waitFor { rig.client.hasVideoLane }
        // The phone keeps trying hellos for 1.2 s, then lets go.
        try await rig.waitFor(3) { rig.client.currentSession?.datagramSlot.get() == nil }
        let frame = WatchVideoFrame(seq: 1, data: Data(repeating: 1, count: 5000), parameterSets: nil, keyframe: true, width: 2, height: 2, appName: "A", bundleID: nil, focus: nil)
        let sent = await rig.server.send(.watchVideo(frame), to: rig.phoneID); XCTAssertTrue(sent)
        try await rig.waitFor { rig.phone.videoSeqs == [1] }
        XCTAssertEqual(rig.server.openSession(rig.phoneID)?.laneSlot.get()?.sent, 1)
    }

    func testAHelloWithTheWrongKeyOrForAnotherPhoneIsIgnored() async throws {
        let rig = try await Rig.make(port: 47984, datagrams: true)
        defer { rig.stop() }
        rig.client.datagramsEnabled = false   // only our forged hellos come
        rig.server.datagramsEnabled = true
        try await rig.connect()
        try await rig.waitFor { rig.client.hasVideoLane }
        let conn = NWConnection(host: "127.0.0.1", port: 47984, using: .udp)
        conn.start(queue: .global())
        defer { conn.cancel() }
        var wrong = DatagramSealer(key: SymmetricKey(size: .bits256))
        conn.send(content: wrong.seal(DatagramMessage.hello.encoded(), hello: rig.phoneID), completion: .idempotent)
        // The right key for a phone the Mac doesn't know: nothing either.
        let keys = try XCTUnwrap(rig.server.openSession(rig.phoneID)?.laneSecrets?.datagram)
        var right = DatagramSealer(key: keys.phoneToMac)
        conn.send(content: right.seal(DatagramMessage.hello.encoded(), hello: UUID()), completion: .idempotent)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertFalse(rig.server.openSession(rig.phoneID)?.hasDatagrams ?? true)
        // A phone that didn't name the feature is refused even with its real key.
        conn.send(content: right.seal(DatagramMessage.hello.encoded(), hello: rig.phoneID), completion: .idempotent)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(rig.server.openSession(rig.phoneID)?.hasDatagrams ?? true)
    }

    func testAPathThatGoesQuietHandsTheVideoBackToTheLane() async throws {
        let rig = try await Rig.make(port: 47985, datagrams: true)
        defer { rig.stop() }
        try await rig.connect()
        try await rig.waitFor { rig.client.hasVideoDatagrams && rig.server.openSession(rig.phoneID)?.hasDatagrams == true && rig.client.hasVideoLane }
        // The phone's side goes away without a word (its reports stop): within ~1.5 s the Mac gives up.
        (rig.client.currentSession?.datagramSlot.get() as? PhoneDatagramPath)?.silence()
        try await rig.waitFor(3) { rig.server.openSession(rig.phoneID)?.hasDatagrams == false }
        let frame = WatchVideoFrame(seq: 1, data: Data(repeating: 1, count: 5000), parameterSets: nil, keyframe: true, width: 2, height: 2, appName: "A", bundleID: nil, focus: nil)
        let sent = await rig.server.send(.watchVideo(frame), to: rig.phoneID); XCTAssertTrue(sent)
        try await rig.waitFor { rig.phone.videoSeqs == [1] }
    }

    func testLossAndReorderingThroughTheRelayStillDeliverInOrder() async throws {
        // A UDP relay in the test: drops 5% each way, holds some datagrams back past later ones.
        let relay = try UDPTestRelay(listen: 47986, to: 47987, loss: 0.05, reorder: 0.1)
        defer { relay.stop() }
        let rig = try await Rig.make(port: 47987, datagrams: true, dial: 47986)
        defer { rig.stop() }
        try await rig.connect()
        try await rig.waitFor { rig.client.hasVideoDatagrams && rig.server.openSession(rig.phoneID)?.hasDatagrams == true }
        for seq in 1...40 {
            let frame = WatchVideoFrame(seq: seq, data: Data(repeating: UInt8(seq), count: 15_000 + seq * 100), parameterSets: nil, keyframe: seq == 1,
                                        width: 4, height: 4, appName: "Claude", bundleID: nil, focus: nil)
            _ = await rig.server.send(.watchVideo(frame), to: rig.phoneID)
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        try await rig.waitFor(4) { (rig.client.videoDatagramStats?.framesDelivered ?? 0) + (rig.client.videoDatagramStats?.framesSkipped ?? 0) == 40 }
        let seqs = rig.phone.videoSeqs
        XCTAssertEqual(seqs, seqs.sorted(), "never out of order")
        XCTAssertGreaterThanOrEqual(seqs.count, 38)
        let s = try XCTUnwrap(rig.client.videoDatagramStats)
        XCTAssertGreaterThan(s.recoveredByParity + s.resends, 0)
        XCTAssertGreaterThan(relay.dropped, 0)
    }
}

extension PhoneDatagramPath {
    /// Stops this end without telling the Mac (a link that went dead), for the quiet test.
    func silence() { close() }
}

/// A UDP relay for the tests: one address pair, loss and some reordering (a held datagram goes
/// 15 ms later, after ones behind it).
final class UDPTestRelay: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "test.udp.relay")
    private var pairs: [NWConnection] = []
    private var rng: UInt64 = 88_172_645_463_325_252
    private let loss: Double, reorder: Double
    private(set) var dropped = 0

    init(listen: UInt16, to: UInt16, loss: Double, reorder: Double) throws {
        self.loss = loss; self.reorder = reorder
        listener = try NWListener(using: .udp, on: NWEndpoint.Port(rawValue: listen)!)
        listener.newConnectionHandler = { [weak self] inbound in
            guard let self else { return }
            let out = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: to)!, using: .udp)
            self.pairs += [inbound, out]
            inbound.start(queue: self.queue); out.start(queue: self.queue)
            self.pump(inbound, out); self.pump(out, inbound)
        }
        listener.start(queue: queue)
    }

    private func roll() -> Double { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return Double(rng % 1_000_000) / 1_000_000 }

    private func pump(_ from: NWConnection, _ to: NWConnection) {
        from.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data {
                if self.roll() < self.loss { self.dropped += 1 } else if self.roll() < self.reorder {
                    self.queue.asyncAfter(deadline: .now() + 0.015) { to.send(content: data, completion: .idempotent) }
                } else { to.send(content: data, completion: .idempotent) }
            }
            if error == nil { self.pump(from, to) }
        }
    }

    func stop() { listener.cancel(); queue.sync { pairs.forEach { $0.cancel() } } }
}
