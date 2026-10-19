import Darwin
import Foundation
import MacrophoneKit

// Pick a display, Mac Controls, Wake the Mac (Oct 19 2026) in the protocol proof. The demo Mac
// has two displays (`--displays 1` for one), presses nothing (it counts the keys and answers with
// a made-up volume), tells a phone a made-up hardware address on this Mac's own network, and with
// `--wake-port N` counts the magic packets for that address that reach port N. Counts only.

enum MacReachDemo {
    static let features = [DesktopWatch.feature, Displays.feature, MacControl.feature, WakeInfo.feature]
    /// A locally administered address: no real network card has it.
    static let hardware = "02:00:5e:10:00:01"

    static func displays() -> [MacDisplay] {
        let n = max(1, min(4, Int(flag("--displays") ?? "2") ?? 2))
        let all = [MacDisplay(id: "demo-built-in", name: "Built-in Retina Display", x: 0, y: 0, width: 1512, height: 982, isMain: true),
                   MacDisplay(id: "demo-studio", name: "Studio Display", x: -2560, y: -458, width: 2560, height: 1440, isMain: false),
                   MacDisplay(id: "demo-above", name: "Studio Display", x: 0, y: -1440, width: 2560, height: 1440, isMain: false),
                   MacDisplay(id: "demo-right", name: "LG UltraFine", x: 1512, y: 0, width: 1920, height: 1080, isMain: false)]
        return Array(all.prefix(n))
    }

    /// This Mac's own network (so a phone beside it is "on the same network"), with the made-up address.
    static func wakeInfo() -> WakeInfo {
        let subnets = NetworkAddresses.ownSubnets().filter { WakeRule.ipv4($0.address) != nil && !RemoteAddressRule.isTailscale($0.address) }
        let interfaces: [WakeInterface] = subnets.prefix(1).compactMap { s in
            let mask = s.prefix == 0 ? 0 : UInt32.max << (32 - UInt32(min(32, s.prefix)))
            let netmask = WakeRule.format(mask)
            guard let b = WakeRule.broadcast(address: s.address, netmask: netmask) else { return nil }
            return WakeInterface(hardware: hardware, address: s.address, netmask: netmask, broadcast: b)
        }
        return WakeInfo(interfaces: interfaces, wakeForNetwork: flag("--womp").map { $0 != "0" } ?? true)
    }

    /// A phone connected: what it named.
    @MainActor static func tell(_ server: LinkServer, _ peer: UUID) {
        if server.phones(with: Displays.feature).contains(peer) {
            let list = displays()
            Task { await server.send(.displays(list), to: peer) }
            stdout("DISPLAYS sent \(list.count)")
        }
        if server.phones(with: WakeInfo.feature).contains(peer) {
            let info = wakeInfo()
            Task { await server.send(.wakeInfo(info), to: peer) }
            stdout("WAKE INFO sent \(info.interfaces.count) interface(s)")
        }
    }

    // MARK: Counting magic packets

    nonisolated(unsafe) static var wakeCount = 0

    /// Listens on UDP `port` (broadcast included) and prints a count for each magic packet for the
    /// made-up address.
    static func listenForWake(port: UInt16) {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { stdout("WAKE listener: no socket"); return }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_ANY)
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard ok == 0 else { stdout("WAKE listener: port \(port) is taken"); close(fd); return }
        stdout("WAKE listening on UDP \(port)")
        let want = MagicPacket.hardware(hardware)
        Thread.detachNewThread {
            var buf = [UInt8](repeating: 0, count: 2048)
            while true {
                let n = recv(fd, &buf, buf.count, 0)
                guard n > 0 else { continue }
                if let mac = MagicPacket.target(of: Data(buf[0..<n])) {
                    wakeCount += 1
                    stdout("WAKE packet #\(wakeCount)\(mac == want ? " for the demo Mac" : " for another address")")
                } else {
                    stdout("WAKE not a magic packet (\(n) bytes)")
                }
            }
        }
    }
}

extension ServeDelegate {
    func linkServer(_ server: LinkServer, macControl control: MacControl, from peerID: UUID) {
        MacReachDemo.controlCounts[control, default: 0] += 1
        let n = MacReachDemo.controlCounts.values.reduce(0, +)
        stdout("MAC CONTROL \(control.rawValue) (#\(n))")
        var result = MacControlResult(control: control, ok: true, detail: control.title)
        switch control {
        case .volumeUp, .volumeDown:
            MacReachDemo.volume = min(1, max(0, MacReachDemo.volume + (control == .volumeUp ? 0.0625 : -0.0625)))
            MacReachDemo.muted = false
            result.volume = MacReachDemo.volume
            result.muted = false
        case .mute:
            MacReachDemo.muted.toggle()
            result.volume = MacReachDemo.volume
            result.muted = MacReachDemo.muted
        default: break
        }
        if control.isVolume { result.detail = MacControlResult.volumeLine(result.volume, muted: result.muted) ?? control.title }
        if control.isBrightness, has("--no-brightness") {
            result.ok = false
            result.detail = "Brightness keys change only a built-in or Apple display — use this display's own buttons"
        }
        let r = result
        Task { await server.send(.macControlDone(r), to: peerID) }
    }
}

extension MacReachDemo {
    nonisolated(unsafe) static var controlCounts: [MacControl: Int] = [:]
    nonisolated(unsafe) static var volume = 0.5
    nonisolated(unsafe) static var muted = false
}

extension PhoneDelegate {
    func linkClient(_ client: LinkClient, displays: [MacDisplay]) {
        stdout("DISPLAYS \(displays.count): " + displays.map { "\(Displays.name(for: $0, among: displays))\($0.isMain ? " (main)" : "") \(Int($0.width))×\(Int($0.height)) at \(Int($0.x)),\(Int($0.y))" }.joined(separator: " | "))
    }
    func linkClient(_ client: LinkClient, wakeInfo: WakeInfo, macID: UUID) {
        stdout("WAKE INFO \(wakeInfo.interfaces.count) interface(s), wake for network \(wakeInfo.wakeForNetwork.map { $0 ? "on" : "off" } ?? "unknown")")
    }
    func linkClient(_ client: LinkClient, macControlDone r: MacControlResult) {
        stdout("MAC CONTROL DONE \(r.control.rawValue) \(r.ok ? "ok" : "not done") — \(r.detail)")
    }
}
