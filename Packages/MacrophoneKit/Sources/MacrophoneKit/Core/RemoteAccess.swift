import Foundation
import Network

// Remote access (Oct 17 2026): using Macrophone away from home. At home the phone finds the
// Mac with Bonjour. Away, it dials addresses the Mac told it while they were connected at home
// (its Tailscale address and name, its local addresses) or one the person typed — the same
// paired, encrypted link either way, so nothing here weakens pairing. No server anywhere.

/// One way to reach a Mac from away: a host (an IP or a name) and the fixed remote port.
public struct RemoteAddress: Codable, Hashable, Sendable {
    public enum Source: String, Codable, Sendable {
        /// The Mac told the phone (replaced wholesale by its next list).
        case mac
        /// Typed by the person in the phone's Settings (kept until they clear it).
        case typed
    }

    public var host: String
    public var port: UInt16
    public var source: Source

    public init(host: String, port: UInt16, source: Source = .mac) {
        self.host = host
        self.port = port
        self.source = source
    }

    /// "100.101.2.3:47821", "[fd7a::1]:47821", "mac.tail1234.ts.net:47821".
    public var display: String { RemoteAddressRule.display(host: host, port: port) }

    /// Tailscale's own range: the address works from anywhere both devices are signed in.
    public var isTailscale: Bool { RemoteAddressRule.isTailscale(host) || RemoteAddressRule.isTailscaleName(host) }

    public var endpoint: NWEndpoint { .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 47_821) }
}

/// The pure rules: which addresses are which, how they're typed, in what order they're dialled.
public enum RemoteAddressRule {
    /// The port Macrophone listens on for remote access unless the person changes it.
    public static let defaultPort: UInt16 = 47_821

    // MARK: Ranges

    /// Tailscale hands every device an address in 100.64.0.0/10 (CGNAT space).
    public static func isTailscale(_ host: String) -> Bool {
        guard let b = ipv4Bytes(host) else { return false }
        return b[0] == 100 && (64...127).contains(b[1])
    }

    /// A MagicDNS name ("mac.tail1234.ts.net").
    public static func isTailscaleName(_ host: String) -> Bool {
        host.lowercased().hasSuffix(".ts.net")
    }

    /// Reachable only on the person's own network (or the machine itself): a private range,
    /// link-local (AWDL peer-to-peer arrives as fe80::), loopback. Anything else — a Tailscale
    /// address, a public one — is "from away", which the Mac accepts only with remote access on.
    public static func isLocal(_ host: String) -> Bool {
        let h = stripScope(host).lowercased()
        if h == "localhost" { return true }
        if let b = ipv4Bytes(h) {
            if b[0] == 127 { return true }
            if b[0] == 10 { return true }
            if b[0] == 192 && b[1] == 168 { return true }
            if b[0] == 172 && (16...31).contains(b[1]) { return true }
            if b[0] == 169 && b[1] == 254 { return true }
            return false
        }
        if h == "::1" { return true }
        if h.hasPrefix("fe8") || h.hasPrefix("fe9") || h.hasPrefix("fea") || h.hasPrefix("feb") { return true }  // fe80::/10
        if h.hasPrefix("fc") || h.hasPrefix("fd") { return true }  // unique local fc00::/7
        // An IPv4-mapped IPv6 address ("::ffff:192.168.1.2").
        if h.hasPrefix("::ffff:"), let v4 = h.split(separator: ":").last, ipv4Bytes(String(v4)) != nil { return isLocal(String(v4)) }
        return false
    }

    /// The same, counting a source on one of this machine's own subnets as local too — a home
    /// network with public IPv6, a campus with public IPv4 — so a phone Bonjour found is never
    /// refused while remote access is off. A Tailscale subnet never counts (that IS away).
    public static func isLocal(_ host: String, subnets: [OwnSubnet]) -> Bool {
        if isLocal(host) { return true }
        if isTailscale(host) { return false }
        let h = stripScope(host)
        return subnets.contains { !isTailscale($0.address) && sameSubnet(h, $0) }
    }

    static func sameSubnet(_ host: String, _ s: OwnSubnet) -> Bool {
        guard let a = ipBytes(host), let b = ipBytes(s.address), a.count == b.count else { return false }
        let bits = min(max(s.prefix, 0), a.count * 8)
        for i in 0..<(bits / 8) where a[i] != b[i] { return false }
        let rest = bits % 8
        if rest > 0 {
            let mask = UInt8(0xFF) << UInt8(8 - rest)
            if a[bits / 8] & mask != b[bits / 8] & mask { return false }
        }
        return true
    }

    /// 4 bytes for IPv4, 16 for IPv6, nil for a name.
    static func ipBytes(_ host: String) -> [UInt8]? {
        if let v4 = ipv4Bytes(host) { return v4 }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, stripScope(host), &v6) == 1 else { return nil }
        return withUnsafeBytes(of: &v6) { Array($0) }
    }

    /// The addresses a Mac can be reached at from away, in the order worth trying: Tailscale
    /// first (works from anywhere), then its MagicDNS name, the ones the person typed, and last
    /// the Mac's local addresses (useful on a network that blocks Bonjour but not the Mac).
    public static func ordered(_ list: [RemoteAddress]) -> [RemoteAddress] {
        func rank(_ a: RemoteAddress) -> Int {
            if isTailscale(a.host) { return 0 }
            if isTailscaleName(a.host) { return 1 }
            if a.source == .typed { return 2 }
            return 3
        }
        var seen = Set<String>()
        return list.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
            .filter { seen.insert($0.display.lowercased()).inserted }
    }

    /// The Mac's new list replaces what it said before; what the person typed stays.
    public static func merge(told: [RemoteAddress], into stored: [RemoteAddress]) -> [RemoteAddress] {
        stored.filter { $0.source == .typed } + told.map { RemoteAddress(host: $0.host, port: $0.port, source: .mac) }
    }

    // MARK: Typing

    /// "host", "host:port", "[v6]:port", "v6" — nil when it isn't an address at all.
    public static func parse(_ text: String, defaultPort: UInt16 = defaultPort) -> RemoteAddress? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.count <= 253 else { return nil }
        for prefix in ["macrophone://", "http://", "https://"] where s.lowercased().hasPrefix(prefix) { s = String(s.dropFirst(prefix.count)) }
        if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
        var host = s
        var port = defaultPort
        if s.hasPrefix("[") {
            guard let close = s.firstIndex(of: "]") else { return nil }
            host = String(s[s.index(after: s.startIndex)..<close])
            let rest = s[s.index(after: close)...]
            if rest.hasPrefix(":") { guard let p = UInt16(rest.dropFirst()), p > 0 else { return nil }; port = p }
            else if !rest.isEmpty { return nil }
        } else if s.filter({ $0 == ":" }).count == 1, let colon = s.firstIndex(of: ":") {
            host = String(s[..<colon])
            guard let p = UInt16(s[s.index(after: colon)...]), p > 0 else { return nil }
            port = p
        }
        host = host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, host.count <= 253 else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-:%_"))
        guard host.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        guard host.contains(where: \.isLetter) || ipv4Bytes(host) != nil || host.contains(":") else { return nil }
        return RemoteAddress(host: host, port: port, source: .typed)
    }

    public static func display(host: String, port: UInt16) -> String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    // MARK: Helpers

    static func ipv4Bytes(_ s: String) -> [UInt8]? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var out: [UInt8] = []
        for p in parts {
            guard !p.isEmpty, p.count <= 3, let v = UInt8(p) else { return nil }
            out.append(v)
        }
        return out
    }

    /// "fe80::1%en0" → "fe80::1".
    static func stripScope(_ host: String) -> String {
        if let i = host.firstIndex(of: "%") { return String(host[..<i]) }
        return host
    }

    /// The host part of an endpoint ("192.168.4.22"), nil for a Bonjour service endpoint.
    public static func host(of endpoint: NWEndpoint) -> String? {
        guard case let .hostPort(host, _) = endpoint else { return nil }
        switch host {
        case .ipv4(let a): return "\(a)"
        case .ipv6(let a): return stripScope("\(a)")
        case .name(let n, _): return n
        @unknown default: return nil
        }
    }
}

/// One of this machine's own networks: an address and its prefix length (192.168.4.22/22).
public struct OwnSubnet: Hashable, Sendable {
    public var address: String
    public var prefix: Int
    public init(address: String, prefix: Int) { self.address = address; self.prefix = prefix }
}

/// An address this machine has on one of its interfaces.
public struct InterfaceAddress: Hashable, Sendable {
    public var interface: String
    public var host: String
    public var isTailscale: Bool { RemoteAddressRule.isTailscale(host) }
    public init(interface: String, host: String) { self.interface = interface; self.host = host }
}

/// This machine's own addresses (the Mac's side).
public enum NetworkAddresses {
    /// Every IPv4 address on an up interface except loopback and link-local, Tailscale's first,
    /// then Wi-Fi / Ethernet (en*), then the rest. Nothing here depends on Tailscale's CLI: its
    /// interface is a utun with an address in 100.64.0.0/10.
    public static func current() -> [InterfaceAddress] {
        var list: [InterfaceAddress] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return [] }
        defer { freeifaddrs(ifap) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let i = p {
            defer { p = i.pointee.ifa_next }
            guard let addr = i.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(i.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let host = String(cString: buf)
            let name = String(cString: i.pointee.ifa_name)
            guard !host.hasPrefix("169.254."), !host.hasPrefix("127.") else { continue }
            list.append(InterfaceAddress(interface: name, host: host))
        }
        return order(list)
    }

    /// Every network this machine is on (IPv4 and IPv6, loopback and link-local left out), for
    /// telling a connection from this network apart from one from away.
    public static func ownSubnets() -> [OwnSubnet] {
        var list: [OwnSubnet] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return [] }
        defer { freeifaddrs(ifap) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let i = p {
            defer { p = i.pointee.ifa_next }
            guard let addr = i.pointee.ifa_addr, let mask = i.pointee.ifa_netmask else { continue }
            let family = Int32(addr.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            let flags = Int32(i.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let host = RemoteAddressRule.stripScope(String(cString: buf))
            if host.hasPrefix("169.254.") || host.lowercased().hasPrefix("fe80") { continue }
            // The prefix length is the number of leading one bits in the netmask.
            let maskBytes: [UInt8]
            if family == AF_INET {
                maskBytes = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin_addr) { Array($0) } }
            } else {
                maskBytes = mask.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) } }
            }
            var prefix = 0
            for b in maskBytes { if b == 0xFF { prefix += 8 } else { prefix += (~b).leadingZeroBitCount; break } }
            list.append(OwnSubnet(address: host, prefix: prefix))
        }
        return list
    }

    /// Tailscale first, then en* (Wi-Fi, Ethernet), then anything else (bridges, other VPNs last).
    static func order(_ list: [InterfaceAddress]) -> [InterfaceAddress] {
        func rank(_ a: InterfaceAddress) -> Int {
            if a.isTailscale { return 0 }
            if a.interface.hasPrefix("en") { return 1 }
            if a.interface.hasPrefix("bridge") || a.interface.hasPrefix("utun") || a.interface.hasPrefix("ipsec") { return 3 }
            return 2
        }
        return list.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    /// The Tailscale (MagicDNS) name for one of this machine's Tailscale addresses, if Tailscale
    /// answers a reverse lookup for it ("mac.tail1234.ts.net") — a few hundred ms at most, off
    /// the caller's thread. Nil when Tailscale isn't running or MagicDNS is off.
    public static func tailscaleName(for host: String) async -> String? {
        guard RemoteAddressRule.isTailscale(host) else { return nil }
        return await withCheckedContinuation { c in
            let done = OnceFlag()
            DispatchQueue.global(qos: .utility).async {
                var sa = sockaddr_in()
                sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                sa.sin_family = sa_family_t(AF_INET)
                guard inet_pton(AF_INET, host, &sa.sin_addr) == 1 else { if done.claim() { c.resume(returning: nil) }; return }
                var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let ok = withUnsafePointer(to: &sa) { p in
                    p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size), &buf, socklen_t(buf.count), nil, 0, NI_NAMEREQD) == 0
                    }
                }
                let name = ok ? String(cString: buf).trimmingCharacters(in: CharacterSet(charactersIn: ".")) : nil
                if done.claim() { c.resume(returning: RemoteAddressRule.isTailscaleName(name ?? "") ? name : nil) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if done.claim() { c.resume(returning: nil) } }
        }
    }

    /// The list a Mac tells its phones: each address with the remote port, the Tailscale name
    /// when there is one.
    public static func remoteAddresses(port: UInt16, tailscaleName: String?) -> [RemoteAddress] {
        var out = current().map { RemoteAddress(host: $0.host, port: port, source: .mac) }
        if let n = tailscaleName, let i = out.firstIndex(where: { $0.isTailscale }) {
            out.insert(RemoteAddress(host: n, port: port, source: .mac), at: i + 1)
        }
        return out
    }
}

/// What the Mac's remote access is set to.
public struct RemoteConfig: Equatable, Sendable {
    public var port: UInt16
    public init(port: UInt16 = RemoteAddressRule.defaultPort) { self.port = port }
}

public enum RemoteAccess {
    /// A phone that understands `.remoteAddresses` says so in its hello.
    public static let feature = "remote"
}
