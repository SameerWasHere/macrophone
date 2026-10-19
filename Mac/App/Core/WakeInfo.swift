import Combine
import Foundation
import MacrophoneKit
import Network
import SwiftUI

/// Wake the Mac (Oct 19 2026): what a phone needs to wake this Mac from sleep — the hardware
/// address of each network interface it's on (Wi-Fi, Ethernet) with that network's broadcast
/// address — and whether "Wake for network access" is on (`pmset -g`, `womp`). Read here, never
/// changed: the Devices page says how to turn it on when it's off.
@MainActor
final class MacWake: ObservableObject {
    static let shared = MacWake()

    /// "Wake for network access", as last read (nil until read, or on a Mac that doesn't list it).
    @Published private(set) var wakeForNetwork: Bool?
    private(set) var info = WakeInfo(interfaces: [], wakeForNetwork: nil)
    /// Called when what a phone should hear changed.
    var onChange: (WakeInfo) -> Void = { _ in }
    private var monitor: NWPathMonitor?
    private var refreshing: Task<Void, Never>?

    private init() {}

    /// Reads it now, and again whenever the network changes.
    func start() {
        guard monitor == nil else { return }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] _ in Task { @MainActor in self?.refresh() } }
        m.start(queue: DispatchQueue(label: "macrophone.wake.path"))
        monitor = m
        refresh()
    }

    func refresh() {
        refreshing?.cancel()
        refreshing = Task { [weak self] in
            // A network change settles in a moment; pmset takes a few milliseconds off the main thread.
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            let womp = await Task.detached { Self.readWakeForNetwork() }.value
            let next = WakeInfo(interfaces: Self.interfaces(), wakeForNetwork: womp).cleaned()
            guard let self, !Task.isCancelled else { return }
            if self.wakeForNetwork != womp { self.wakeForNetwork = womp }
            guard next != self.info else { return }
            self.info = next
            self.onChange(next)
        }
    }

    /// `pmset -g`'s womp line.
    nonisolated static func readWakeForNetwork() -> Bool? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-g"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return WakeRule.wakeForNetwork(pmset: String(decoding: data, as: UTF8.self))
    }

    /// Each interface that's up, has an IPv4 address on a broadcast network and a hardware
    /// address: Wi-Fi and Ethernet (`en*`), never loopback, Tailscale or other tunnels.
    nonisolated static func interfaces() -> [WakeInterface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var hardware: [String: [UInt8]] = [:]
        var ipv4: [(name: String, address: String, netmask: String, broadcast: String?)] = []
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let a = p {
            defer { p = a.pointee.ifa_next }
            let name = String(cString: a.pointee.ifa_name)
            let flags = Int32(a.pointee.ifa_flags)
            guard name.hasPrefix("en"), flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  let sa = a.pointee.ifa_addr else { continue }
            switch Int32(sa.pointee.sa_family) {
            case AF_LINK:
                sa.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { dl in
                    let len = Int(dl.pointee.sdl_alen), off = Int(dl.pointee.sdl_nlen)
                    guard len == 6 else { return }
                    // sdl_data holds the name, then the address — it can run past the struct's declared
                    // 12 bytes, so it's read from the sockaddr itself.
                    let base = UnsafeRawPointer(dl).advanced(by: MemoryLayout.offset(of: \sockaddr_dl.sdl_data)! + off)
                    hardware[name] = (0..<6).map { base.load(fromByteOffset: $0, as: UInt8.self) }
                }
            case AF_INET:
                guard flags & IFF_BROADCAST != 0, let mask = a.pointee.ifa_netmask else { continue }
                let address = Self.string(sa), netmask = Self.string(mask)
                let broadcast = a.pointee.ifa_dstaddr.map(Self.string)
                ipv4.append((name, address, netmask, broadcast))
            default: continue
            }
        }
        return ipv4.compactMap { i in
            guard let hw = hardware[i.name], MagicPacket.hardware(MagicPacket.format(hw)) != nil else { return nil }
            let b = i.broadcast.flatMap { WakeRule.ipv4($0) != nil ? $0 : nil } ?? WakeRule.broadcast(address: i.address, netmask: i.netmask) ?? ""
            return WakeInterface(hardware: MagicPacket.format(hw), address: i.address, netmask: i.netmask, broadcast: b)
        }
    }

    nonisolated private static func string(_ sa: UnsafeMutablePointer<sockaddr>) -> String {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { return "" }
        return String(cString: host)
    }
}

/// One plain line on the Devices page, only when "Wake for network access" is off.
struct WakeForNetworkNote: View {
    @ObservedObject private var wake = MacWake.shared

    var body: some View {
        if wake.wakeForNetwork == false {
            PaneSection("Waking from your iPhone") {
                Plate {
                    PlateRow(title: "Wake for network access is off",
                             subtitle: "Your iPhone can't wake this Mac from sleep. To let it, turn on “Wake for network access” in System Settings › Battery › Options (Energy on a desktop Mac). It works only on the same network, and a closed laptop on battery may not wake.",
                             subtitleColor: Ink.tertiary, icon: "power", iconColor: Light.ochre) { EmptyView() }
                }
            }
        }
    }
}
