import Foundation

// Wake the Mac (Oct 19 2026): Wake-on-LAN. While connected, the Mac tells a phone that asks the
// hardware address of each network interface it's on and that network's broadcast address; the
// phone keeps them with the pairing. Later, on the same network with the Mac asleep, the phone
// sends the standard magic packet (six 0xFF bytes, then the hardware address sixteen times) to
// UDP 9 and 7, broadcast, and keeps looking. It works only on the same network, only with "Wake
// for network access" on, and a closed laptop on battery may sleep through it.

/// One network interface of the Mac's, as the phone needs it to wake it.
public struct WakeInterface: Codable, Sendable, Hashable {
    /// The hardware (MAC) address, "a4:83:e7:12:34:56".
    public var hardware: String
    /// The Mac's IPv4 address on it, its netmask and the network's broadcast address.
    public var address: String
    public var netmask: String
    public var broadcast: String

    public init(hardware: String, address: String, netmask: String, broadcast: String) {
        self.hardware = hardware
        self.address = address
        self.netmask = netmask
        self.broadcast = broadcast
    }
}

public struct WakeInfo: Codable, Sendable, Equatable {
    public var interfaces: [WakeInterface]
    /// "Wake for network access" (`pmset -g` womp), nil when it couldn't be read.
    public var wakeForNetwork: Bool?

    public init(interfaces: [WakeInterface], wakeForNetwork: Bool?) {
        self.interfaces = interfaces
        self.wakeForNetwork = wakeForNetwork
    }

    /// The Mac names it in its welcome (and sends `.wakeInfo`); the phone in its hello.
    public static let feature = "wake"

    /// What a phone keeps: at most 8 interfaces with a hardware address and an IPv4 network.
    public func cleaned() -> WakeInfo {
        WakeInfo(interfaces: Array(interfaces.filter {
            MagicPacket.hardware($0.hardware) != nil && WakeRule.ipv4($0.address) != nil && WakeRule.ipv4($0.netmask) != nil
        }.prefix(8)), wakeForNetwork: wakeForNetwork)
    }
}

public enum MagicPacket {
    /// Where it goes: the discard port, and echo (some routers and NICs listen on 7).
    public static let ports: [UInt16] = [9, 7]
    /// How many times, and how far apart — a packet on Wi-Fi can be lost.
    public static let repeats = 3
    public static let spacing: TimeInterval = 0.4

    /// "a4:83:e7:12:34:56" or "A4-83-E7-12-34-56" as six bytes (nil for anything else, or the
    /// all-zero / broadcast addresses).
    public static func hardware(_ s: String) -> [UInt8]? {
        let parts = s.trimmingCharacters(in: .whitespaces).split(whereSeparator: { $0 == ":" || $0 == "-" })
        guard parts.count == 6 else { return nil }
        var out: [UInt8] = []
        for p in parts {
            guard p.count == 2, let b = UInt8(p, radix: 16) else { return nil }
            out.append(b)
        }
        if out.allSatisfy({ $0 == 0 }) || out.allSatisfy({ $0 == 0xFF }) { return nil }
        return out
    }

    /// Six bytes as "a4:83:e7:12:34:56".
    public static func format(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    /// The packet: 0xFF six times, then the six-byte address sixteen times — 102 bytes.
    public static func bytes(for hardware: [UInt8]) -> Data? {
        guard hardware.count == 6 else { return nil }
        var d = Data(repeating: 0xFF, count: 6)
        for _ in 0..<16 { d.append(contentsOf: hardware) }
        return d
    }

    /// Whether a packet is a magic packet, and for which address (the demo Mac counts them).
    public static func target(of packet: Data) -> [UInt8]? {
        let b = [UInt8](packet)
        guard b.count >= 102, b.prefix(6).allSatisfy({ $0 == 0xFF }) else { return nil }
        let mac = Array(b[6..<12])
        for i in 0..<16 where Array(b[(6 + i * 6)..<(12 + i * 6)]) != mac { return nil }
        return mac
    }
}

public enum WakeRule {
    /// "192.168.4.22" as a number (nil for anything that isn't a dotted IPv4 address).
    public static func ipv4(_ s: String) -> UInt32? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var n: UInt32 = 0
        for p in parts {
            guard !p.isEmpty, p.count <= 3, let b = UInt8(p) else { return nil }
            n = n << 8 | UInt32(b)
        }
        return n
    }

    public static func format(_ n: UInt32) -> String {
        "\(n >> 24 & 0xFF).\(n >> 16 & 0xFF).\(n >> 8 & 0xFF).\(n & 0xFF)"
    }

    /// The network's broadcast address: the address with every host bit set.
    public static func broadcast(address: String, netmask: String) -> String? {
        guard let a = ipv4(address), let m = ipv4(netmask) else { return nil }
        return format(a | ~m)
    }

    /// Whether the phone is on one of the networks the Mac was on: an address of the phone's, under
    /// that network's mask, is in it. `phone` is the phone's own IPv4 addresses with their masks.
    public static func sameNetwork(phone: [(address: String, netmask: String)], as info: WakeInfo) -> Bool {
        for i in info.interfaces {
            guard let a = ipv4(i.address), let m = ipv4(i.netmask), m != 0 else { continue }
            for p in phone {
                guard let pa = ipv4(p.address), pa != a else { continue }
                if pa & m == a & m { return true }
            }
        }
        return false
    }

    /// The places to send the packet for one interface: its network's broadcast address, the
    /// everywhere broadcast, and the Mac's own last address (a router or a sleep proxy that still
    /// knows it passes it on — and it's what's left when broadcast isn't allowed).
    public static func destinations(for i: WakeInterface) -> [String] {
        var out: [String] = []
        if let b = ipv4(i.broadcast).map(format) ?? broadcast(address: i.address, netmask: i.netmask) { out.append(b) }
        out.append("255.255.255.255")
        if ipv4(i.address) != nil { out.append(i.address) }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    /// "Wake for network access" from `pmset -g`: the `womp` line's 1 or 0 (nil when it isn't there
    /// — a Mac that can't wake that way doesn't list it).
    public static func wakeForNetwork(pmset output: String) -> Bool? {
        for line in output.split(whereSeparator: \.isNewline) {
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard words.count >= 2, words[0] == "womp" else { continue }
            if words[1] == "1" { return true }
            if words[1] == "0" { return false }
        }
        return nil
    }
}
