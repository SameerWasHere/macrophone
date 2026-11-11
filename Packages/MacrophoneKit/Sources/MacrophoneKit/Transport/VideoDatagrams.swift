import CryptoKit
import Foundation

// Video datagrams (Nov 10 2026): away from home, the window's video rides UDP datagrams beside the
// TCP video lane (VideoLane.swift), so a lost packet costs only its own recovery — never every
// frame behind it, which is what TCP's in-order rule does to the lane.
//
// The pieces, all pure and tested here (the network glue is VideoDatagramPath.swift):
// - `DatagramSealer` / `DatagramOpener`: each datagram sealed with ChaCha20-Poly1305 under the
//   session's own datagram key, its packet number the nonce (explicit, so loss and reordering
//   don't break it), a window that refuses a replay or a duplicate.
// - `DatagramFramer`: a message (an encoded `.watchVideo`) cut into pieces that fit Tailscale's
//   1280-byte MTU, plus XOR parity over interleaved groups — one lost piece per group is rebuilt
//   with no round trip.
// - `FrameReassembler` (the phone): pieces back into messages, parity recovery, NACKs for what
//   parity can't rebuild, messages handed on **in order** (the decoder needs each frame), and a
//   frame given up after a short deadline (the phone then asks for a keyframe, as it does today).
// - `DatagramSender` (the Mac): keeps each frame's pieces until the phone's report says it's
//   resolved, answers NACKs, resends a frame the phone never saw, limits frames in flight.
//
// Negotiated as `VideoDatagrams.feature` in hello and welcome; an older phone or Mac keeps the TCP
// lane. Off by default (`enabledByDefault`) — see the measurements in the CLAUDE.md notes.

public enum VideoDatagrams {
    public static let feature = "videoDatagrams"

    /// The defaults key that turns it on or off on either app (`defaults write … video.datagrams -bool YES`).
    public static let defaultsKey = "video.datagrams"
    /// Shipped off: proven on loopback through a model of a lossy link only (see CLAUDE.md).
    public static let shippedDefault = false
    public static var enabledByDefault: Bool {
        (UserDefaults.standard.object(forKey: defaultsKey) as? Bool) ?? shippedDefault
    }

    /// Both ends named it, it's enabled here, and the link runs from away.
    public static func shouldOpen(phoneFeatures: [String], macFeatures: Set<String>, remote: Bool, enabled: Bool) -> Bool {
        enabled && remote && phoneFeatures.contains(feature) && macFeatures.contains(feature)
    }

    /// Bytes of message per piece: a sealed datagram is this + 42, 1192 bytes — under Tailscale's
    /// 1280-byte MTU with IPv6 and UDP headers (1232), and any ordinary path.
    public static let pieceSize = 1150

    /// The parity group size for the loss the phone reports (in thousandths): the more loss, the
    /// more parity. 0 = no parity.
    public static func groupSize(lossPermille: Int) -> Int {
        switch lossPermille {
        case ..<3: return 16
        case ..<15: return 8
        case ..<35: return 5
        default: return 4
        }
    }

    /// How long the phone waits for a frame before giving it up (then the next frames go on and the
    /// phone asks for a keyframe): two tries at a resend.
    public static func deadline(rtt: TimeInterval) -> TimeInterval {
        min(0.5, max(0.12, 0.015 + 2.5 * rtt))
    }
}

// MARK: Keys

/// The datagram keys of one session, derived like the lane's (pair key + the session's nonces).
struct DatagramKeys: Sendable {
    let macToPhone: SymmetricKey
    let phoneToMac: SymmetricKey

    init(pairKey: SymmetricKey, phoneNonce: Data, macNonce: Data) {
        let salt = phoneNonce + macNonce
        macToPhone = HKDF<SHA256>.deriveKey(inputKeyMaterial: pairKey, salt: salt, info: Data("m2p-datagram".utf8), outputByteCount: 32)
        phoneToMac = HKDF<SHA256>.deriveKey(inputKeyMaterial: pairKey, salt: salt, info: Data("p2m-datagram".utf8), outputByteCount: 32)
    }
}

// MARK: Sealing

/// What a datagram is on the wire: a hello (phone → Mac, names the phone so the Mac finds its
/// session) or a sealed datagram. Both: kind · [phone id] · packet number (8, big-endian) ·
/// ciphertext · tag. The bytes before the ciphertext are the AEAD's associated data.
enum DatagramKind: UInt8 {
    case hello = 1
    case sealed = 2
}

struct DatagramSealer: Sendable {
    let key: SymmetricKey
    private(set) var next: UInt64 = 1
    init(key: SymmetricKey) { self.key = key }

    static func nonce(_ pn: UInt64) -> ChaChaPoly.Nonce {
        var bytes = Data(count: 4)
        withUnsafeBytes(of: pn.bigEndian) { bytes.append(contentsOf: $0) }
        return try! ChaChaPoly.Nonce(data: bytes)
    }

    mutating func seal(_ plain: Data, hello phoneID: UUID? = nil) -> Data {
        var head = Data([phoneID == nil ? DatagramKind.sealed.rawValue : DatagramKind.hello.rawValue])
        if let phoneID { head.append(phoneID.data) }
        let pn = next
        next += 1
        withUnsafeBytes(of: pn.bigEndian) { head.append(contentsOf: $0) }
        let box = try! ChaChaPoly.seal(plain, using: key, nonce: Self.nonce(pn), authenticating: head)
        return head + box.ciphertext + box.tag
    }
}

/// The phone id a hello names, before anything's opened (to find the session's key).
func datagramHelloPhone(_ datagram: Data) -> UUID? {
    guard datagram.count >= 1 + 16 + 8 + 16, datagram.first == DatagramKind.hello.rawValue else { return nil }
    let b = [UInt8](datagram.dropFirst().prefix(16))
    return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
}

/// Opens one direction's datagrams: a forged one fails the tag, a replayed or duplicated packet
/// number is refused (a window of the last 4096).
struct DatagramOpener: Sendable {
    let key: SymmetricKey
    private var highest: UInt64 = 0
    private var seen = [Bool](repeating: false, count: DatagramOpener.window)
    static let window = 4096
    private(set) var refused = 0

    init(key: SymmetricKey) { self.key = key }

    enum Failure: Error { case malformed, forged, replayed }

    mutating func open(_ datagram: Data) throws -> (plain: Data, hello: Bool) {
        guard let kind = datagram.first.flatMap(DatagramKind.init(rawValue:)) else { refused += 1; throw Failure.malformed }
        let headLength = kind == .hello ? 1 + 16 + 8 : 1 + 8
        guard datagram.count >= headLength + 16 else { refused += 1; throw Failure.malformed }
        let d = Data(datagram)
        let head = d.prefix(headLength)
        let pn = d.subdata(in: headLength - 8..<headLength).withUnsafeBytes { UInt64(bigEndian: $0.loadUnaligned(as: UInt64.self)) }
        guard pn > 0, !isReplay(pn) else { refused += 1; throw Failure.replayed }
        let body = d.dropFirst(headLength)
        let plain: Data
        do {
            let box = try ChaChaPoly.SealedBox(nonce: DatagramSealer.nonce(pn), ciphertext: body.dropLast(16), tag: body.suffix(16))
            plain = try ChaChaPoly.open(box, using: key, authenticating: head)
        } catch { refused += 1; throw Failure.forged }
        mark(pn)
        return (plain, kind == .hello)
    }

    private func isReplay(_ pn: UInt64) -> Bool {
        if pn > highest { return false }
        if highest - pn >= UInt64(Self.window) { return true }
        return seen[Int(pn % UInt64(Self.window))]
    }

    private mutating func mark(_ pn: UInt64) {
        if pn > highest {
            // Clear the slots the window slides past.
            let step = min(pn - highest, UInt64(Self.window))
            var i = highest + 1
            for _ in 0..<step { seen[Int(i % UInt64(Self.window))] = false; i += 1 }
            highest = pn
        }
        seen[Int(pn % UInt64(Self.window))] = true
    }
}

// MARK: What's inside

/// One piece of a frame (a message), or its parity.
struct DatagramPiece: Equatable, Sendable {
    var frame: UInt32
    /// The data piece's index, or the parity group's number.
    var index: UInt16
    /// Data pieces in the frame.
    var count: UInt16
    var pieceSize: UInt16
    /// Parity groups in the frame (0 = none); data piece i is in group i % groups.
    var groups: UInt16
    var keyframe: Bool
    var parity: Bool
    var resend: Bool
    /// The message's length in bytes.
    var total: UInt32
    var data: Data
}

/// The phone's report, every 100 ms (400 ms when nothing's coming): the Mac learns what's resolved
/// and that the path is alive both ways.
struct DatagramReport: Equatable, Sendable {
    /// The phone's clock, echoed back by the Mac (the phone's round-trip estimate).
    var time: UInt64
    /// Every frame up to here has been handed on or given up.
    var resolved: UInt32
    /// The newest frame any piece has arrived for.
    var seen: UInt32
    /// Datagrams received so far (the Mac sees the other direction is alive).
    var received: UInt32
    var lossPermille: UInt16
    var rttMillis: UInt16
}

/// A NACK entry: the data pieces a frame is missing, or all of it (never seen).
struct DatagramNack: Equatable, Sendable {
    var frame: UInt32
    var all: Bool
    var missing: [UInt16]
}

enum DatagramMessage: Equatable, Sendable {
    case piece(DatagramPiece)
    case ready
    case reportAck(echo: UInt64)
    case closing
    case hello
    case report(DatagramReport)
    case nack([DatagramNack])

    private enum Tag: UInt8 { case piece = 1, ready = 2, reportAck = 3, closing = 4, hello = 16, report = 17, nack = 18 }

    func encoded() -> Data {
        var w = ByteWriter()
        switch self {
        case let .piece(p):
            w.u8(Tag.piece.rawValue); w.u32(p.frame); w.u16(p.index); w.u16(p.count); w.u16(p.pieceSize); w.u16(p.groups)
            w.u8((p.keyframe ? 1 : 0) | (p.parity ? 2 : 0) | (p.resend ? 4 : 0)); w.u32(p.total)
            w.bytes.append(p.data)
        case .ready: w.u8(Tag.ready.rawValue)
        case let .reportAck(echo): w.u8(Tag.reportAck.rawValue); w.u64(echo)
        case .closing: w.u8(Tag.closing.rawValue)
        case .hello: w.u8(Tag.hello.rawValue)
        case let .report(r):
            w.u8(Tag.report.rawValue); w.u64(r.time); w.u32(r.resolved); w.u32(r.seen); w.u32(r.received); w.u16(r.lossPermille); w.u16(r.rttMillis)
        case let .nack(list):
            w.u8(Tag.nack.rawValue); w.u16(UInt16(min(list.count, 200)))
            for n in list.prefix(200) {
                w.u32(n.frame); w.u8(n.all ? 1 : 0); w.u16(UInt16(min(n.missing.count, 400)))
                n.missing.prefix(400).forEach { w.u16($0) }
            }
        }
        return w.bytes
    }

    static func decode(_ data: Data) -> DatagramMessage? {
        var r = ByteReader(data)
        guard let t = r.u8().flatMap(Tag.init(rawValue:)) else { return nil }
        switch t {
        case .piece:
            guard let frame = r.u32(), let index = r.u16(), let count = r.u16(), let size = r.u16(), let groups = r.u16(),
                  let flags = r.u8(), let total = r.u32() else { return nil }
            let piece = DatagramPiece(frame: frame, index: index, count: count, pieceSize: size, groups: groups, keyframe: flags & 1 != 0,
                                      parity: flags & 2 != 0, resend: flags & 4 != 0, total: total, data: r.rest())
            // Shapes that can't be: refused here so nothing below has to wonder.
            guard count > 0, size > 0, piece.data.count <= Int(size), Int(total) <= Int(count) * Int(size),
                  Int(total) > (Int(count) - 1) * Int(size),
                  piece.parity ? (groups > 0 && index < groups) : index < count else { return nil }
            return .piece(piece)
        case .ready: return .ready
        case .reportAck: return r.u64().map { .reportAck(echo: $0) }
        case .closing: return .closing
        case .hello: return .hello
        case .report:
            guard let time = r.u64(), let resolved = r.u32(), let seen = r.u32(), let received = r.u32(), let loss = r.u16(), let rtt = r.u16() else { return nil }
            return .report(DatagramReport(time: time, resolved: resolved, seen: seen, received: received, lossPermille: loss, rttMillis: rtt))
        case .nack:
            guard let n = r.u16() else { return nil }
            var list: [DatagramNack] = []
            for _ in 0..<n {
                guard let frame = r.u32(), let all = r.u8(), let m = r.u16() else { return nil }
                var missing: [UInt16] = []
                for _ in 0..<m { guard let i = r.u16() else { return nil }; missing.append(i) }
                list.append(DatagramNack(frame: frame, all: all != 0, missing: missing))
            }
            return .nack(list)
        }
    }
}

struct ByteWriter {
    var bytes = Data()
    mutating func u8(_ v: UInt8) { bytes.append(v) }
    mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.bigEndian) { bytes.append(contentsOf: $0) } }
    mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { bytes.append(contentsOf: $0) } }
    mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.bigEndian) { bytes.append(contentsOf: $0) } }
}

struct ByteReader {
    private let d: Data
    private var i: Int
    init(_ data: Data) { d = Data(data); i = 0 }
    private mutating func take(_ n: Int) -> Data? {
        guard i + n <= d.count else { return nil }
        defer { i += n }
        return d.subdata(in: i..<i + n)
    }
    mutating func u8() -> UInt8? { take(1).map { $0[0] } }
    mutating func u16() -> UInt16? { take(2).map { $0.withUnsafeBytes { UInt16(bigEndian: $0.loadUnaligned(as: UInt16.self)) } } }
    mutating func u32() -> UInt32? { take(4).map { $0.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)) } } }
    mutating func u64() -> UInt64? { take(8).map { $0.withUnsafeBytes { UInt64(bigEndian: $0.loadUnaligned(as: UInt64.self)) } } }
    mutating func rest() -> Data { defer { i = d.count }; return d.subdata(in: i..<d.count) }
}

// MARK: Cutting and parity

enum DatagramFramer {
    /// Cuts a message into data pieces and, with `group` > 0, one XOR parity piece per interleaved
    /// group of about `group` pieces (data piece i is in group i % groups, so a burst of losses
    /// lands in different groups). Data first, then parity.
    static func pieces(frame: UInt32, message: Data, keyframe: Bool, pieceSize: Int = VideoDatagrams.pieceSize, group: Int) -> [DatagramPiece] {
        let m = Data(message)
        let count = max(1, (m.count + pieceSize - 1) / pieceSize)
        let groups = group > 0 ? (count + group - 1) / group : 0
        var out: [DatagramPiece] = []
        out.reserveCapacity(count + groups)
        for i in 0..<count {
            let lo = i * pieceSize, hi = min(m.count, lo + pieceSize)
            out.append(DatagramPiece(frame: frame, index: UInt16(i), count: UInt16(count), pieceSize: UInt16(pieceSize), groups: UInt16(groups),
                                     keyframe: keyframe, parity: false, resend: false, total: UInt32(m.count), data: m.subdata(in: lo..<hi)))
        }
        for g in 0..<groups {
            var x = [UInt8](repeating: 0, count: pieceSize)
            var i = g
            while i < count {
                xor(&x, out[i].data)
                i += groups
            }
            out.append(DatagramPiece(frame: frame, index: UInt16(g), count: UInt16(count), pieceSize: UInt16(pieceSize), groups: UInt16(groups),
                                     keyframe: keyframe, parity: true, resend: false, total: UInt32(m.count), data: Data(x)))
        }
        return out
    }

    static func xor(_ into: inout [UInt8], _ d: Data) {
        d.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
            for j in 0..<min(b.count, into.count) { into[j] ^= b[j] }
        }
    }

    /// The length of data piece `i` of a frame.
    static func length(of i: Int, count: Int, pieceSize: Int, total: Int) -> Int {
        i == count - 1 ? total - (count - 1) * pieceSize : pieceSize
    }
}

// MARK: The phone: reassembly, recovery, order

struct FrameReassembler {
    struct Partial {
        var count: Int
        var pieceSize: Int
        var groups: Int
        var total: Int
        var keyframe: Bool
        var data: [Int: Data] = [:]
        var parity: [Int: Data] = [:]
        var firstAt: TimeInterval
        var lastAt: TimeInterval
        var nackedAt: TimeInterval = -1
        var complete: Bool { data.count == count }
    }

    struct Stats: Equatable, Sendable {
        var delivered = 0
        var skipped = 0
        var recovered = 0
        var nacked = 0
        var duplicates = 0
        var resendsUseful = 0
    }

    /// The next frame to hand on; everything before it is resolved.
    private(set) var next: UInt32 = 1
    private(set) var seen: UInt32 = 0
    private var frames: [UInt32: Partial] = [:]
    /// When a frame newer than one never seen first arrived (an unseen frame's clock).
    private var gapSince: [UInt32: TimeInterval] = [:]
    private(set) var stats = Stats()
    /// Data pieces expected vs arrived as sent (not resends): the loss the phone reports.
    private var expected = 0
    private var arrivedFirstTime = 0

    /// The round trip as the phone measures it (the deadline and the NACK interval follow it).
    var rtt: TimeInterval = 0.08
    /// How long the pieces of a frame may stop before what's missing is asked for.
    var reorderWait: TimeInterval = 0.012

    var deadline: TimeInterval { VideoDatagrams.deadline(rtt: rtt) }

    /// A piece arrived; returns the messages now ready, in order.
    mutating func receive(_ p: DatagramPiece, now: TimeInterval) -> [Data] {
        guard p.frame >= next else { stats.duplicates += 1; return [] }
        // A frame impossibly far ahead is garbage, not video.
        guard p.frame < next &+ 5000 else { return [] }
        if p.frame > seen {
            // Frames skipped over that never showed: their clock starts now.
            var f = max(next, seen &+ 1)
            while f < p.frame { if frames[f] == nil, gapSince[f] == nil { gapSince[f] = now }; f += 1 }
            seen = p.frame
        }
        var part = frames[p.frame] ?? Partial(count: Int(p.count), pieceSize: Int(p.pieceSize), groups: Int(p.groups), total: Int(p.total),
                                              keyframe: p.keyframe, firstAt: now, lastAt: now)
        // Every piece of a frame must agree on its shape.
        guard part.count == Int(p.count), part.pieceSize == Int(p.pieceSize), part.total == Int(p.total), part.groups == Int(p.groups) else { return [] }
        gapSince[p.frame] = nil
        part.lastAt = now
        if p.parity {
            if part.parity[Int(p.index)] != nil { stats.duplicates += 1 } else { part.parity[Int(p.index)] = p.data }
        } else if part.data[Int(p.index)] != nil {
            stats.duplicates += 1
        } else {
            let want = DatagramFramer.length(of: Int(p.index), count: part.count, pieceSize: part.pieceSize, total: part.total)
            guard p.data.count == want else { return [] }
            part.data[Int(p.index)] = p.data
            if p.resend { stats.resendsUseful += 1 }
        }
        if frames[p.frame] == nil, !p.resend { expected += Int(p.count) }
        if !p.parity, !p.resend { arrivedFirstTime += 1 }
        recover(&part)
        frames[p.frame] = part
        return drain(now: now)
    }

    /// Rebuilds a group's one missing data piece from its parity.
    private mutating func recover(_ part: inout Partial) {
        guard part.groups > 0, !part.complete else { return }
        for (g, parity) in part.parity {
            var missing: [Int] = []
            var i = g
            while i < part.count { if part.data[i] == nil { missing.append(i) }; i += part.groups }
            guard missing.count == 1 else { continue }
            var x = [UInt8](parity)
            var j = g
            while j < part.count { if let d = part.data[j] { DatagramFramer.xor(&x, d) }; j += part.groups }
            let k = missing[0]
            let n = DatagramFramer.length(of: k, count: part.count, pieceSize: part.pieceSize, total: part.total)
            part.data[k] = Data(x.prefix(n))
            stats.recovered += 1
        }
    }

    /// Hands on what's complete in order; skips straight to a complete keyframe (nothing before it
    /// is needed any more).
    private mutating func drain(now: TimeInterval) -> [Data] {
        var out: [Data] = []
        if let k = frames.filter({ $0.key > next && $0.value.complete && $0.value.keyframe }).map(\.key).max() {
            while next < k { drop(next); stats.skipped += 1; next += 1 }
        }
        while let part = frames[next], part.complete {
            var m = Data(capacity: part.total)
            for i in 0..<part.count { m.append(part.data[i]!) }
            out.append(m)
            stats.delivered += 1
            drop(next)
            next += 1
        }
        return out
    }

    private mutating func drop(_ f: UInt32) { frames[f] = nil; gapSince[f] = nil }

    /// Every few milliseconds: frames past their deadline are given up (the ones after them go on),
    /// and what's missing is asked for — after the pieces stop for `reorderWait`, or at once when
    /// a newer frame has started; again each round trip.
    mutating func tick(now: TimeInterval) -> (deliver: [Data], nacks: [DatagramNack]) {
        var out: [Data] = []
        // Give up the next frame once it's past its deadline (seen or not), until one isn't.
        while next <= seen {
            let since = frames[next]?.firstAt ?? gapSince[next] ?? now
            guard now - since > deadline else { break }
            drop(next)
            stats.skipped += 1
            next += 1
            out += drain(now: now)
        }
        var nacks: [DatagramNack] = []
        let interval = max(0.03, rtt * 1.2)
        var f = next
        while f <= seen {
            if var part = frames[f] {
                if !part.complete, now - part.nackedAt >= interval, f < seen || now - part.lastAt >= reorderWait {
                    // Parity had its chance (the pieces stopped, or a newer frame started): ask for every gap.
                    let missing = (0..<part.count).filter { part.data[$0] == nil }.map(UInt16.init)
                    nacks.append(DatagramNack(frame: f, all: false, missing: missing))
                    part.nackedAt = now
                    frames[f] = part
                }
            } else if let since = gapSince[f], now - since >= reorderWait {
                // Never seen at all: ask for all of it (once per interval, the clock kept in nackedAt's place).
                let last = unseenNacked[f] ?? -1
                if now - last >= interval {
                    nacks.append(DatagramNack(frame: f, all: true, missing: []))
                    unseenNacked[f] = now
                }
            }
            f += 1
        }
        unseenNacked = unseenNacked.filter { $0.key >= next }
        stats.nacked += nacks.count
        return (out, nacks)
    }
    private var unseenNacked: [UInt32: TimeInterval] = [:]

    /// The loss seen on first sends, in thousandths, and a fresh count from here.
    mutating func takeLoss() -> Int {
        defer { expected = 0; arrivedFirstTime = 0 }
        guard expected >= 20 else { return lastLoss }
        lastLoss = max(0, min(1000, (expected - arrivedFirstTime) * 1000 / expected))
        return lastLoss
    }
    private var lastLoss = 0

    var incomplete: Bool { next <= seen }
}

// MARK: The Mac: what's in flight

struct DatagramSender {
    struct Sent {
        var pieces: [DatagramPiece]
        var at: TimeInterval
        var resentAt: TimeInterval = -1
    }

    private(set) var nextFrame: UInt32 = 1
    private var sent: [UInt32: Sent] = [:]
    /// Everything up to here the phone has resolved.
    private(set) var resolved: UInt32 = 0
    private(set) var seen: UInt32 = 0
    var lossPermille = 0
    var rtt: TimeInterval = 0.08
    private(set) var resentPieces = 0
    private(set) var parityPieces = 0
    private(set) var dataPieces = 0

    /// Frames in flight before a send waits (the phone's reports clock more out, as TCP's acks do).
    static let window = 8
    /// A frame older than this is resolved whatever the phone said (it gave it up by now).
    static let forget: TimeInterval = 1.0

    /// Cuts the next frame; returns its pieces to send now.
    mutating func frame(_ message: Data, keyframe: Bool, now: TimeInterval) -> [DatagramPiece] {
        let f = nextFrame
        nextFrame += 1
        let pieces = DatagramFramer.pieces(frame: f, message: message, keyframe: keyframe, group: VideoDatagrams.groupSize(lossPermille: lossPermille))
        sent[f] = Sent(pieces: pieces, at: now)
        parityPieces += pieces.filter(\.parity).count
        dataPieces += pieces.filter { !$0.parity }.count
        return pieces
    }

    /// Frames sent and not yet resolved (recent ones only).
    func inFlight(now: TimeInterval) -> Int { sent.values.filter { now - $0.at < Self.forget }.count }

    /// The phone's report: drops what it resolved; resends a frame it never saw once a round trip
    /// (and a bit) has passed since it went — the tail of a burst can't be NACKed by the phone.
    mutating func report(_ r: DatagramReport, now: TimeInterval) -> [DatagramPiece] {
        resolved = max(resolved, r.resolved)
        seen = max(seen, r.seen)
        lossPermille = Int(r.lossPermille)
        if r.rttMillis > 0 { rtt = Double(r.rttMillis) / 1000 }
        sent = sent.filter { $0.key > resolved && now - $0.value.at < Self.forget }
        var out: [DatagramPiece] = []
        for f in sent.keys.sorted() where f > seen {
            guard var s = sent[f], now - s.at > rtt * 1.5 + 0.03, now - s.resentAt > rtt * 1.5 + 0.03 else { continue }
            out += s.pieces.filter { !$0.parity }.map { var p = $0; p.resend = true; return p }
            s.resentAt = now
            sent[f] = s
        }
        resentPieces += out.count
        return out
    }

    /// The phone's NACKs: the pieces it asked for, again.
    mutating func nack(_ list: [DatagramNack]) -> [DatagramPiece] {
        var out: [DatagramPiece] = []
        for n in list {
            guard let s = sent[n.frame] else { continue }
            let data = s.pieces.filter { !$0.parity }
            let want = n.all ? data : n.missing.compactMap { i in Int(i) < data.count ? data[Int(i)] : nil }
            out += want.map { var p = $0; p.resend = true; return p }
        }
        resentPieces += out.count
        return out
    }
}
