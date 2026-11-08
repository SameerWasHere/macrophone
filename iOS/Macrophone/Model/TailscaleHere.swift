import Darwin
import MacrophoneKit
import UIKit

/// Whether this iPhone is on a Tailscale network right now (Oct 17 2026): Tailscale gives each
/// device an address in 100.64.0.0/10 while its VPN is on and signed in, so one on any interface
/// says yes. Read when asked (Settings, the away guide, the desktop's empty state), nothing kept.
enum TailscaleHere {
    static var isOn: Bool {
        #if DEBUG
        switch ProcessInfo.processInfo.environment["MACROPHONE_FAKE_TAILSCALE"] {
        case "on"?: return true
        case "off"?: return false
        default: break
        }
        #endif
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

    /// Tailscale's app answers its own link (`tailscale://`, listed in LSApplicationQueriesSchemes).
    /// Only ever read as a yes: a no may just mean the app doesn't take that link, so nothing is
    /// claimed from it (the guide then offers the App Store and lets being on Tailscale say done).
    @MainActor static var appAnswers: Bool {
        #if DEBUG
        switch ProcessInfo.processInfo.environment["MACROPHONE_FAKE_TAILSCALE_APP"] {
        case "1"?: return true
        case "0"?: return false
        default: break
        }
        #endif
        return UIApplication.shared.canOpenURL(appLink)
    }

    static let appLink = URL(string: "tailscale://")!
    /// Tailscale on the App Store (free).
    static let appStore = URL(string: "https://apps.apple.com/app/tailscale/id1470499037")!
    /// Tailscale for the Mac, to send to it.
    static let macDownload = URL(string: "https://tailscale.com/download/mac")!

    /// Opens Tailscale's app when it answers, else its App Store page.
    @MainActor static func open() {
        UIApplication.shared.open(appAnswers ? appLink : appStore)
    }
}

/// How far the active Mac is with being reached from away, by what it last told this phone.
enum MacAwayReadiness: Equatable {
    /// It shared a Tailscale address: Tailscale and Away from home are both on there.
    case ready
    /// Away from home is on (it shared addresses) but none is a Tailscale one.
    case noTailscale
    /// It shared nothing: Away from home is off (or it hasn't been connected since it was turned on).
    case off
}
