import Foundation
@testable import MacrophoneKit
import XCTest

final class SoundDefaultTests: XCTestCase {
    /// Sameer, Oct 19 2026: Mac sound is OFF unless the person turned it on — a fresh install, an
    /// update, any value that isn't a stored true.
    func testSoundIsOffByDefault() {
        let d = UserDefaults(suiteName: "sound-default-\(UUID().uuidString)")!
        XCTAssertFalse(SoundSetting.defaultOn)
        XCTAssertFalse(SoundSetting.isOn(in: d), "a fresh install")
        d.set("yes", forKey: SoundSetting.key)
        XCTAssertFalse(SoundSetting.isOn(in: d), "anything but a stored true")
        d.removeObject(forKey: SoundSetting.key)
        // An older key (another build's) never turns it on.
        d.set(true, forKey: "watch.sound")
        XCTAssertFalse(SoundSetting.isOn(in: d), "after an update")
        SoundSetting.set(true, in: d)
        XCTAssertTrue(SoundSetting.isOn(in: d), "the toggle")
        SoundSetting.set(false, in: d)
        XCTAssertFalse(SoundSetting.isOn(in: d))
        XCTAssertNil(d.object(forKey: SoundSetting.key))
    }

    /// The Mac sends sound only to a phone that named the feature and turned Sound on itself.
    func testTheMacSendsOnlyWhenThatPhoneTurnedItOn() {
        XCTAssertFalse(MacSound.sends(phoneFeatures: [MacSound.feature], turnedOn: nil))
        XCTAssertFalse(MacSound.sends(phoneFeatures: [MacSound.feature], turnedOn: false))
        XCTAssertFalse(MacSound.sends(phoneFeatures: [WatchVideo.feature], turnedOn: true))
        XCTAssertFalse(MacSound.sends(phoneFeatures: [], turnedOn: nil))
        XCTAssertTrue(MacSound.sends(phoneFeatures: [MacSound.feature, WatchVideo.feature], turnedOn: true))
    }
}

final class AudioWireTests: XCTestCase {
    func testPacketsRoundTrip() throws {
        let p = MacAudioPacket(seq: 7, stream: 42, sampleTime: 6720, codec: .opus, packets: [Data([1, 2, 3])], config: Data([9, 9]),
                               sentAt: 1_800_000_000.25, macDelay: 0.031, bitrate: 96_000)
        let data = try WireCoding.encoder.encode(Message.macAudio(p))
        guard case let .macAudio(back) = try WireCoding.decoder.decode(Message.self, from: data) else { return XCTFail() }
        XCTAssertEqual(back, p)
        // About 50 a second: small on the wire.
        XCTAssertLessThan(data.count, 400)
        for on in [true, false] {
            let d = try WireCoding.encoder.encode(Message.watchSound(on: on))
            guard case let .watchSound(b) = try WireCoding.decoder.decode(Message.self, from: d) else { return XCTFail() }
            XCTAssertEqual(b, on)
        }
        let codec = try JSONDecoder().decode(MacSound.Codec.self, from: Data(#""aac-eld""#.utf8))
        XCTAssertEqual(codec, .aacELD)
    }

    func testTheSetUpGoesWithTheFirstPacketAndEverySecond() {
        XCTAssertTrue(MacAudioPacket.carriesConfig(seq: 1))
        XCTAssertFalse(MacAudioPacket.carriesConfig(seq: 2))
        XCTAssertTrue(MacAudioPacket.carriesConfig(seq: 1 + MacSound.configEvery))
        XCTAssertEqual((1...500).filter(MacAudioPacket.carriesConfig).count, 10)
    }

    func testAwayFromHomeIsLowerAndHoldsMore() {
        XCTAssertLessThan(MacSound.bitrate(remote: true), MacSound.bitrate(remote: false))
        XCTAssertGreaterThan(MacSound.targetFrames(remote: true), MacSound.targetFrames(remote: false))
        // 60–120 ms held before playing.
        XCTAssertTrue((60...120).contains(MacSound.targetFrames(remote: false) * 1000 / MacSound.sampleRate))
        XCTAssertTrue((60...120).contains(MacSound.targetFrames(remote: true) * 1000 / MacSound.sampleRate))
    }
}

final class AudioCodecTests: XCTestCase {
    private func roundTrip(_ codec: MacSound.Codec) throws {
        let enc = try MacAudioEncoder(codec: codec, bitrate: 96_000)
        let dec = try MacAudioDecoder(codec: codec, config: enc.cookie)
        var tone = TestTone()
        var packets: [Data] = []
        // A second of tone, in the odd sizes a capture hands over.
        var left = MacSound.sampleRate
        while left > 0 {
            let n = min(left, 1024)
            packets += enc.encode(tone.next(frames: n))
            left -= n
        }
        XCTAssertGreaterThanOrEqual(packets.count, MacSound.sampleRate / codec.framesPerPacket - 2)
        let bytes = packets.reduce(0) { $0 + $1.count }
        XCTAssertLessThan(bytes * 8, 140_000, "about the bitrate asked for")
        var out: [Float] = []
        for p in packets { out += try XCTUnwrap(dec.decode(p)) }
        XCTAssertGreaterThan(out.count / 2, MacSound.sampleRate * 9 / 10)
        // The tone is on half the time at 0.25: its RMS is about 0.125.
        let rms = sqrt(out.reduce(0) { $0 + $1 * $1 } / Float(out.count))
        XCTAssertEqual(rms, 0.125, accuracy: 0.03)
    }

    func testOpusRoundTrip() throws { try roundTrip(.opus) }
    func testAACELDRoundTrip() throws { try roundTrip(.aacELD) }

    func testTheSenderNumbersPacketsAndMarksGaps() throws {
        let sender = try MacAudioSender(remote: false)
        var tone = TestTone()
        var all: [MacAudioPacket] = []
        var pos: Int64 = 0
        for _ in 0..<20 {
            all += sender.packets(tone.next(frames: 1024), at: pos, capturedAt: 100, now: 100.05)
            pos += 1024
        }
        XCTAssertEqual(all.map(\.seq), Array(1...all.count))
        XCTAssertTrue(all.allSatisfy { $0.stream == sender.stream })
        XCTAssertNotNil(all.first?.config)
        XCTAssertNil(all.dropFirst().first?.config)
        // Each packet sits one packet after the one before.
        for (a, b) in zip(all, all.dropFirst()) { XCTAssertEqual(b.sampleTime - a.sampleTime, Int64(sender.encoder.framesPerPacket)) }
        // Nothing for two seconds (nothing played): the next packets say where they are.
        let before = all.last!.sampleTime
        let after = sender.packets(tone.next(frames: 4096), at: pos + 96_000, capturedAt: 102, now: 102.05)
        XCTAssertEqual(sender.gaps, 1)
        XCTAssertGreaterThan(try XCTUnwrap(after.first).sampleTime, before + 90_000)
    }
}

final class SoundJitterTests: XCTestCase {
    private let fpp = MacSound.framesPerPacket
    private func packet(_ value: Float = 0.5) -> [Float] { [Float](repeating: value, count: fpp * 2) }
    private func pull(_ j: inout SoundJitter, _ frames: Int) -> (Int, [Float]) {
        var out = [Float](repeating: 9, count: frames * 2)
        let n = out.withUnsafeMutableBufferPointer { j.pull(into: $0.baseAddress!, frames: frames) }
        return (n, out)
    }

    func testItHoldsToTheTargetThenPlays() {
        var j = SoundJitter(target: 3 * fpp, ceiling: 6 * fpp)
        j.push(packet(), seq: 1, stream: 1, sampleTime: 0)
        j.push(packet(), seq: 2, stream: 1, sampleTime: Int64(fpp))
        let (n0, silent) = pull(&j, 256)
        XCTAssertEqual(n0, 0)
        XCTAssertTrue(silent.allSatisfy { $0 == 0 })
        j.push(packet(), seq: 3, stream: 1, sampleTime: Int64(2 * fpp))
        XCTAssertTrue(j.playing)
        let (n, out) = pull(&j, 256)
        XCTAssertEqual(n, 256)
        XCTAssertTrue(out.allSatisfy { $0 == 0.5 })
        XCTAssertEqual(j.buffered, 3 * fpp - 256)
    }

    func testRunningDryIsAnUnderrunThenItRefills() {
        var j = SoundJitter(target: fpp, ceiling: 4 * fpp)
        j.push(packet(), seq: 1, stream: 1, sampleTime: 0)
        let (n, out) = pull(&j, fpp + 100)
        XCTAssertEqual(n, fpp)
        XCTAssertTrue(out.suffix(200).allSatisfy { $0 == 0 }, "silence after")
        XCTAssertEqual(j.stats.underruns, 1)
        XCTAssertFalse(j.playing)
        j.push(packet(), seq: 2, stream: 1, sampleTime: Int64(fpp))
        XCTAssertTrue(j.playing)
        XCTAssertEqual(j.stats.underruns, 1)
    }

    func testRunningDryInAGapTheMacMarkedIsNoUnderrun() {
        var j = SoundJitter(target: fpp, ceiling: 4 * fpp)
        j.push(packet(), seq: 1, stream: 1, sampleTime: 0)
        _ = pull(&j, 2 * fpp)
        XCTAssertEqual(j.stats.underruns, 1)
        // The next one is two seconds on: the Mac had nothing to send.
        j.push(packet(), seq: 2, stream: 1, sampleTime: 96_000)
        XCTAssertEqual(j.stats.gaps, 1)
        XCTAssertEqual(j.stats.underruns, 0)
    }

    func testABurstDropsTheOldestInsteadOfDrifting() {
        var j = SoundJitter(target: 2 * fpp, ceiling: 4 * fpp)
        for s in 1...10 { j.push(packet(Float(s) / 10), seq: s, stream: 1, sampleTime: Int64((s - 1) * fpp)) }
        XCTAssertLessThanOrEqual(j.buffered, 4 * fpp)
        XCTAssertGreaterThan(j.stats.trimmedFrames, 0)
        // What plays is the newest: packet 10's value is at the end, the first ones are gone.
        let (_, out) = pull(&j, j.buffered)
        XCTAssertEqual(out.last, 1.0)
        XCTAssertFalse(out.contains(0.1))
    }

    func testLateAndOldPacketsAreDropped() {
        var j = SoundJitter(target: fpp, ceiling: 4 * fpp)
        XCTAssertEqual(j.push(packet(), seq: 1, stream: 1, sampleTime: 0), .restarted)
        XCTAssertEqual(j.push(packet(), seq: 3, stream: 1, sampleTime: Int64(2 * fpp)), .accepted)
        XCTAssertEqual(j.push(packet(), seq: 2, stream: 1, sampleTime: Int64(fpp)), .late)
        XCTAssertEqual(j.push(packet(), seq: 3, stream: 1, sampleTime: Int64(2 * fpp)), .late)
        XCTAssertEqual(j.stats.late, 2)
    }

    func testANewStreamStartsOver() {
        var j = SoundJitter(target: fpp, ceiling: 4 * fpp)
        j.push(packet(), seq: 1, stream: 1, sampleTime: 0)
        j.push(packet(), seq: 2, stream: 1, sampleTime: Int64(fpp))
        XCTAssertEqual(j.push(packet(), seq: 1, stream: 2, sampleTime: 0), .restarted)
        XCTAssertEqual(j.buffered, fpp)
        XCTAssertEqual(j.stats.resyncs, 1)
        j.reset()
        XCTAssertEqual(j.buffered, 0)
        XCTAssertFalse(j.playing)
    }

    func testTheRingWrapsWithoutLosingOrder() {
        var j = SoundJitter(target: fpp, ceiling: 3 * fpp)
        var next: Float = 0
        var heard: [Float] = []
        for s in 1...200 {
            var p = [Float](repeating: 0, count: fpp * 2)
            for i in 0..<fpp { p[i * 2] = next; p[i * 2 + 1] = next; next += 1 }
            j.push(p, seq: s, stream: 1, sampleTime: Int64((s - 1) * fpp))
            let (_, out) = pull(&j, fpp)
            heard += stride(from: 0, to: out.count, by: 2).map { out[$0] }
        }
        let played = heard.drop { $0 == 0 }
        XCTAssertTrue(zip(played, played.dropFirst()).allSatisfy { $1 == $0 + 1 }, "in order across the wrap")
        XCTAssertEqual(j.stats.underruns, 0)
    }

    func testLatencySummary() {
        var l = SoundLatency()
        XCTAssertEqual(l.summary, "no packets")
        for i in 0..<10 { l.add(.init(mac: 0.03, wire: SoundLatency.wire(sentAt: 10, arrivedAt: 10.004), buffer: 0.06 + Double(i) / 1000, output: 0.01)) }
        XCTAssertEqual(l.medianMilliseconds, 109)
        XCTAssertTrue(l.summary.hasPrefix("median 109 ms"))
        XCTAssertNil(SoundLatency.wire(sentAt: 10, arrivedAt: 13))
    }
}
