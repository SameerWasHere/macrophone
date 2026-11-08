import Foundation
import IOKit
import IOKit.ps
import MacrophoneKit

/// The machine's power, read (Keep Awake, Nov 7 2026): what kind of Mac it is, the battery, the
/// adapter, the lid, Low Power Mode and how hot it runs. Reads only.
enum MachinePower {
    /// A laptop has an internal battery or a lid (the IOPMrootDomain's clamshell state); an iMac,
    /// a mini, a Studio or a Pro has neither. Intel and Apple silicon report both the same way.
    static let machine: MachineKind = {
        #if DEBUG
        if let k = ProcessInfo.processInfo.environment["MACROPHONE_AWAKE_MACHINE"], let m = MachineKind(rawValue: k) { return m }
        #endif
        return internalBattery() != nil || clamshell() != nil ? .laptop : .desktop
    }()

    static func snapshot() -> PowerSnapshot {
        var s = PowerSnapshot()
        if let b = internalBattery() {
            s.hasBattery = true
            s.battery = b.percent
            s.charging = b.charging
            s.onPower = b.onAC
        } else {
            s.onPower = true
        }
        s.lidClosed = clamshell()
        s.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: s.thermal = .nominal
        case .fair: s.thermal = .fair
        case .serious: s.thermal = .serious
        case .critical: s.thermal = .critical
        @unknown default: s.thermal = .nominal
        }
        #if DEBUG
        // MACROPHONE_AWAKE_POWER=battery:18,ac:0,thermal:2,lpm:1 — stand-ins for a dry-run proof.
        if let spec = ProcessInfo.processInfo.environment["MACROPHONE_AWAKE_POWER"] {
            for part in spec.split(separator: ",") {
                let kv = part.split(separator: ":").map(String.init)
                guard kv.count == 2, let v = Int(kv[1]) else { continue }
                switch kv[0] {
                case "battery": s.hasBattery = true; s.battery = v
                case "ac": s.onPower = v == 1
                case "charging": s.charging = v == 1
                case "thermal": s.thermal = ThermalLevel(rawValue: v) ?? .nominal
                case "lpm": s.lowPowerMode = v == 1
                default: break
                }
            }
        }
        if machine == .desktop { s.hasBattery = false; s.battery = nil; s.onPower = true }
        #endif
        return s
    }

    private struct Battery { var percent: Int; var charging: Bool; var onAC: Bool }

    private static func internalBattery() -> Battery? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  let cap = d[kIOPSCurrentCapacityKey] as? Int else { continue }
            let max = (d[kIOPSMaxCapacityKey] as? Int).flatMap { $0 > 0 ? $0 : nil } ?? 100
            let percent = Int((Double(cap) / Double(max) * 100).rounded())
            return Battery(percent: min(100, Swift.max(0, percent)),
                           charging: (d[kIOPSIsChargingKey] as? Bool) ?? false,
                           onAC: (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue)
        }
        return nil
    }

    /// The lid: closed, open, or nil on a Mac without one.
    static func clamshell() -> Bool? {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        guard let v = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool else { return nil }
        return v
    }

    /// Calls `change` whenever the power source changes (plugged in, unplugged, the level moves).
    static func observe(_ change: @escaping () -> Void) -> CFRunLoopSource? {
        final class Box { let f: () -> Void; init(_ f: @escaping () -> Void) { self.f = f } }
        let box = Unmanaged.passRetained(Box(change)).toOpaque()
        guard let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            Unmanaged<Box>.fromOpaque(ctx).takeUnretainedValue().f()
        }, box)?.takeRetainedValue() else { return nil }
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        return src
    }
}
