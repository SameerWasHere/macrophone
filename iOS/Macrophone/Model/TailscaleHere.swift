import Darwin
import MacrophoneKit

/// Whether this iPhone is on a Tailscale network right now (Oct 17 2026): Tailscale gives each
/// device an address in 100.64.0.0/10 while its VPN is on and signed in, so one on any interface
/// says yes. Read when asked (Settings), nothing kept.
enum TailscaleHere {
    static var isOn: Bool {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return false }
        defer { freeifaddrs(list) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = p {
            if let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0,
                   RemoteAddressRule.isTailscale(String(cString: host)) { return true }
            }
            p = ifa.pointee.ifa_next
        }
        return false
    }
}
