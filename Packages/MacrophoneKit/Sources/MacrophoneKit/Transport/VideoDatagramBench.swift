import Foundation

/// A load-free comparison of the TCP video lane and video datagrams (Nov 10 2026), in simulated
/// time, so a busy Mac can't skew it (`mpctl dgram-sim`). Both carry the same frames over the same
/// link model as `mpctl relay`: half the round trip each way, each packet lost on its own with the
/// same chance.
/// - The lane: `mpctl relay`'s TCP rule — a lost 1448-byte segment arrives one round trip late and
///   every byte behind it waits. Kind to TCP: no lost resends, no shrinking window, no timeouts.
/// - Datagrams: the real `DatagramSender` and `FrameReassembler`; the phone ticks every 10 ms and
///   reports every 100 ms; NACKs, reports and resends are lost at the same rate. A frame given up
///   breaks the chain: the phone's decoder drops frames until a keyframe, asked at most once a
///   second (as `Watcher.askKeyframe`), which the Mac makes from the next frame after the ask lands.
public enum VideoDatagramBench {
    public struct Result: Sendable {
        public var frames = 0
        /// Frames shown (decoded in order).
        public var shown = 0
        /// Frames given up by the transport.
        public var givenUp = 0
        public var keyframesAsked = 0
        /// Time from the frame's encoding to the phone handing it to the decoder, shown frames only (ms).
        public var p50 = 0.0, p95 = 0.0, p99 = 0.0, max = 0.0
        /// Bytes on the wire beyond the messages (headers, parity, resends, reports), as a share.
        public var overhead = 0.0
        public var recovered = 0, nacks = 0, resent = 0
    }

    public static func run(datagrams: Bool, loss: Double, rtt: TimeInterval = 0.08, fps: Double = 19, frames: Int = 1140,
                           bytes: Int = 30_000, seed: UInt64 = 1) -> Result {
        var rng = seed &* 0x9E37_79B9_7F4A_7C15 | 1
        func unit() -> Double { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return Double(rng % 1_000_000) / 1_000_000 }
        func lost() -> Bool { unit() < loss }
        let sizes = (0..<frames).map { _ in bytes + Int(Double(bytes) * (unit() - 0.5) / 3.5) }
        let total = sizes.reduce(0, +)
        let sentAt = (0..<frames).map { Double($0) / fps }
        var times: [Double] = []
        var r = Result()
        r.frames = frames
        guard datagrams else {
            var lastDue = 0.0, wire = 0
            for i in 0..<frames {
                let segments = (sizes[i] + 20 + 1447) / 1448
                var due = 0.0
                for _ in 0..<segments {
                    due = Swift.max(sentAt[i] + rtt / 2 + (lost() ? rtt : 0), lastDue)
                    lastDue = due
                }
                wire += sizes[i] + 20 + segments * 52
                times.append((due - sentAt[i]) * 1000)
            }
            r.shown = frames
            r.overhead = Double(wire - total) / Double(total)
            return finish(r, times)
        }
        var sender = DatagramSender()
        var phone = FrameReassembler()
        phone.rtt = rtt
        var toPhone: [(TimeInterval, DatagramPiece)] = []
        var toMac: [(TimeInterval, DatagramMessage)] = []
        var made = 0, wire = 0
        // The decoder: the newest frame shown, waiting for a keyframe, when one was last asked for,
        // and when the Mac learns of the ask (its next frame is a keyframe).
        var newest = 0, waiting = false, askedAt = -10.0
        var keyDueAt: Double?
        var now = 0.0, nextTick = 0.0, nextReport = 0.0
        let end = sentAt.last! + 2
        func send(_ pieces: [DatagramPiece]) {
            for p in pieces {
                wire += p.data.count + 42
                if !lost() { toPhone.append((now + rtt / 2, p)) }
            }
        }
        func handOn(_ list: [Data]) {
            for d in list {
                let seq = Int(d.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
                let key = d[4] == 1
                if key || (!waiting && seq == newest + 1) {
                    newest = seq; waiting = false
                    r.shown += 1
                    times.append((now - sentAt[seq - 1]) * 1000)
                } else {
                    waiting = true
                    if now - askedAt >= 1 { askedAt = now; r.keyframesAsked += 1; keyDueAt = now + rtt / 2 }
                }
            }
        }
        while now < end {
            if made < frames, now >= sentAt[made] {
                var m = Data(count: sizes[made])
                let key = made == 0 || (keyDueAt.map { now >= $0 } ?? false)
                if key, made > 0 { keyDueAt = nil }
                m.withUnsafeMutableBytes { $0.storeBytes(of: UInt32(made + 1), as: UInt32.self) }
                m[4] = key ? 1 : 0
                send(sender.frame(m, keyframe: key, now: now))
                made += 1
            }
            toPhone.sort { $0.0 < $1.0 }
            while let f = toPhone.first, f.0 <= now { toPhone.removeFirst(); handOn(phone.receive(f.1, now: now)) }
            if now >= nextTick {
                nextTick = now + 0.01
                let t = phone.tick(now: now)
                handOn(t.deliver)
                if !t.nacks.isEmpty {
                    wire += 60
                    if !lost() { toMac.append((now + rtt / 2, .nack(t.nacks))) }
                }
                if now >= nextReport {
                    nextReport = now + 0.1
                    wire += 60
                    let rep = DatagramReport(time: 0, resolved: phone.next - 1, seen: phone.seen, received: 0,
                                             lossPermille: UInt16(phone.takeLoss()), rttMillis: UInt16(rtt * 1000))
                    if !lost() { toMac.append((now + rtt / 2, .report(rep))) }
                }
            }
            toMac.sort { $0.0 < $1.0 }
            while let m = toMac.first, m.0 <= now {
                toMac.removeFirst()
                if case let .nack(list) = m.1 { send(sender.nack(list)) }
                if case let .report(rep) = m.1 { send(sender.report(rep, now: now)) }
            }
            now += 0.001
        }
        r.givenUp = phone.stats.skipped
        r.recovered = phone.stats.recovered
        r.nacks = phone.stats.nacked
        r.resent = sender.resentPieces
        r.overhead = Double(wire - total) / Double(total)
        return finish(r, times)
    }

    private static func finish(_ r: Result, _ t: [Double]) -> Result {
        var r = r
        let times = t.sorted()
        func pct(_ p: Double) -> Double { times.isEmpty ? -1 : times[Swift.min(times.count - 1, Int(Double(times.count) * p))] }
        r.p50 = pct(0.5); r.p95 = pct(0.95); r.p99 = pct(0.99); r.max = times.last ?? -1
        return r
    }
}
