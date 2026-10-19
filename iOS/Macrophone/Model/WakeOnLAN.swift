import Darwin
import Foundation
import MacrophoneKit

/// Wake the Mac (Oct 19 2026): the phone's half of Wake-on-LAN. The Mac's wake info is kept with
/// its pairing (here, by the Mac's id — forgotten with the pairing); the magic packet goes out on a
/// plain UDP socket, broadcast to the Mac's network and to everywhere on this one, and to the Mac's
/// last address (what a router or a Bonjour Sleep Proxy still knows), on ports 9 and 7, a few
/// times. Nothing but the packet is sent; the log gets counts only.
///
/// iOS sends broadcast only from an app with the multicast networking entitlement
/// (com.apple.developer.networking.multicast, granted by Apple on request). Without it the
/// broadcasts fail and only the Mac's own last address is tried — which works while the router
/// still knows the Mac, or with a sleep proxy (an Apple TV or HomePod) on the network.
enum WakeOnLAN {
    // MARK: Kept with the pairing

    private static func key(_ macID: UUID) -> String { "wake.info.\(macID.uuidString)" }

    static func save(_ info: WakeInfo, for macID: UUID) {
        guard !info.interfaces.isEmpty, let d = try? JSONEncoder().encode(info) else { return }
        UserDefaults.standard.set(d, forKey: key(macID))
    }

    static func info(for macID: UUID?) -> WakeInfo? {
        guard let macID, let d = UserDefaults.standard.data(forKey: key(macID)) else { return nil }
        return try? JSONDecoder().decode(WakeInfo.self, from: d)
    }

    static func forget(_ macID: UUID) { UserDefaults.standard.removeObject(forKey: key(macID)) }

    // MARK: Where the phone is

    /// The phone's own IPv4 addresses with their masks (Wi-Fi and Ethernet only).
    static func phoneAddresses() -> [(address: String, netmask: String)] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var out: [(String, String)] = []
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let a = p {
            defer { p = a.pointee.ifa_next }
            let flags = Int32(a.pointee.ifa_flags)
            guard String(cString: a.pointee.ifa_name).hasPrefix("en"), flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let sa = a.pointee.ifa_addr, Int32(sa.pointee.sa_family) == AF_INET, let mask = a.pointee.ifa_netmask else { continue }
            out.append((numeric(sa), numeric(mask)))
        }
        return out
    }

    /// The phone is on a network the Mac was on (so a magic packet can reach it).
    static func onSameNetwork(as info: WakeInfo) -> Bool {
        WakeRule.sameNetwork(phone: phoneAddresses(), as: info)
    }

    private static func numeric(_ sa: UnsafeMutablePointer<sockaddr>) -> String {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { return "" }
        return String(cString: host)
    }

    // MARK: The packet

    struct Sent { var sent = 0; var failed = 0 }

    /// Sends the magic packet for each interface the Mac told, `MagicPacket.repeats` times.
    static func wake(_ info: WakeInfo, extraPort: UInt16? = nil) async -> Sent {
        await Task.detached(priority: .userInitiated) {
            var total = Sent()
            let ports = MagicPacket.ports + (extraPort.map { [$0] } ?? [])
            for round in 0..<MagicPacket.repeats {
                if round > 0 { try? await Task.sleep(nanoseconds: UInt64(MagicPacket.spacing * 1e9)) }
                for i in info.interfaces {
                    guard let hw = MagicPacket.hardware(i.hardware), let packet = MagicPacket.bytes(for: hw) else { continue }
                    for host in WakeRule.destinations(for: i) {
                        for port in ports {
                            if send(packet, to: host, port: port) { total.sent += 1 } else { total.failed += 1 }
                        }
                    }
                }
            }
            return total
        }.value
    }

    /// One UDP datagram, broadcast allowed.
    private static func send(_ data: Data, to host: String, port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return false }
        let n = data.withUnsafeBytes { buf in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        return n == data.count
    }
}
