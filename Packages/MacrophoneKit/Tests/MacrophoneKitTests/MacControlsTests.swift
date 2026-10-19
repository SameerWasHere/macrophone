import CoreGraphics
import Foundation
import Testing
@testable import MacrophoneKit

// Pick a display, Mac Controls and Wake the Mac (Oct 19 2026): the pure parts.

@Suite struct DisplaysTests {
    let builtIn = MacDisplay(id: "B", name: "Built-in Retina Display", x: 0, y: 0, width: 1512, height: 982, isMain: true)
    let studio = MacDisplay(id: "S", name: "Studio Display", x: -2560, y: -458, width: 2560, height: 1440, isMain: false)
    let above = MacDisplay(id: "A", name: "Studio Display", x: 0, y: -1440, width: 2560, height: 1440, isMain: false)

    @Test func targetCarriesTheDisplay() {
        let t = Displays.target(for: studio, among: [builtIn, studio])
        #expect(DesktopWatch.isDesktop(t))
        #expect(Displays.key(of: t) == "S")
        #expect(t.displayName == "Whole Screen — Studio Display")
        // One display: the plain name; nil: the old place (a Mac from before shows the main one).
        #expect(Displays.target(for: builtIn, among: [builtIn]).displayName == "Whole Screen")
        #expect(Displays.target(for: nil) == DesktopWatch.target)
        #expect(Displays.key(of: DesktopWatch.target) == nil)
        #expect(Displays.key(of: .app(bundleID: "com.apple.Terminal", windowKey: "display:S", name: "x")) == nil)
    }

    @Test func resolveFallsBackToMain() {
        let all = [studio, builtIn]
        #expect(Displays.resolve("S", in: all)?.id == "S")
        #expect(Displays.resolve("gone", in: all)?.id == "B")
        #expect(Displays.resolve(nil, in: all)?.id == "B")
        #expect(Displays.resolve("S", in: []) == nil)
    }

    @Test func orderAndNames() {
        let all = [above, studio, builtIn]
        #expect(Displays.ordered(all).map(\.id) == ["B", "S", "A"])
        #expect(Displays.name(for: studio, among: all) == "Studio Display")
        #expect(Displays.name(for: above, among: all) == "Studio Display 2")
        #expect(Displays.title(for: above, among: all) == "Whole Screen — Studio Display 2")
    }

    @Test func pointsMapIntoGlobalCoordinates() {
        // A display to the left and above the main one: negative origins.
        let p = Displays.point(CGPoint(x: 0.5, y: 0.25), in: studio.bounds)
        #expect(p == CGPoint(x: -1280, y: -98))
        #expect(Displays.point(CGPoint(x: 0, y: 0), in: above.bounds) == CGPoint(x: 0, y: -1440))
        #expect(Displays.point(CGPoint(x: 1, y: 1), in: builtIn.bounds) == CGPoint(x: 1512, y: 982))
        // Out of range clamps to the display.
        #expect(Displays.point(CGPoint(x: 2, y: -1), in: builtIn.bounds) == CGPoint(x: 1512, y: 0))
    }

    @Test func wireRoundTrip() throws {
        let m = Message.displays([builtIn, studio])
        let d = try WireCoding.encoder.encode(m)
        guard case let .displays(list) = try WireCoding.decoder.decode(Message.self, from: d) else { Issue.record("wrong case"); return }
        #expect(list == [builtIn, studio])
        #expect(Displays.clean([MacDisplay(id: "", name: "x", x: 0, y: 0, width: 1, height: 1, isMain: false), builtIn]) == [builtIn])
    }
}

@Suite struct MacControlTests {
    @Test func mediaKeyEvents() {
        #expect(MacControl.volumeUp.keyType == 0)
        #expect(MacControl.mute.keyType == 7)
        #expect(MacControl.playPause.keyType == 16)
        #expect(MacControl.volumeUp.data1(down: true) == 0x0A00)
        #expect(MacControl.volumeUp.data1(down: false) == 0x0B00)
        #expect(MacControl.playPause.data1(down: true) == 0x10_0A00)
        #expect(MacControl.next.data1(down: false) == 0x11_0B00)
        #expect(Set(MacControl.volume + MacControl.brightness + MacControl.media) == Set(MacControl.allCases))
    }

    @Test func volumeLine() {
        #expect(MacControlResult.volumeLine(0.4, muted: false) == "Volume 40%")
        #expect(MacControlResult.volumeLine(0.4, muted: true) == "Muted")
        #expect(MacControlResult.volumeLine(nil, muted: nil) == nil)
        #expect(MacControlResult.volumeLine(1.3, muted: nil) == "Volume 100%")
    }
}

@Suite struct WakeTests {
    @Test func magicPacketBytes() throws {
        let mac = try #require(MagicPacket.hardware("A4-83-e7:12:34:56"))
        #expect(mac == [0xA4, 0x83, 0xE7, 0x12, 0x34, 0x56])
        #expect(MagicPacket.format(mac) == "a4:83:e7:12:34:56")
        let p = try #require(MagicPacket.bytes(for: mac))
        #expect(p.count == 102)
        #expect(Array(p.prefix(6)) == [UInt8](repeating: 0xFF, count: 6))
        for i in 0..<16 { #expect(Array(p[(6 + i * 6)..<(12 + i * 6)]) == mac) }
        #expect(MagicPacket.target(of: p) == mac)
        var broken = p; broken[50] ^= 1
        #expect(MagicPacket.target(of: broken) == nil)
        #expect(MagicPacket.bytes(for: [1, 2, 3]) == nil)
    }

    @Test func hardwareAddressesRejectJunk() {
        #expect(MagicPacket.hardware("00:00:00:00:00:00") == nil)
        #expect(MagicPacket.hardware("ff:ff:ff:ff:ff:ff") == nil)
        #expect(MagicPacket.hardware("a4:83:e7:12:34") == nil)
        #expect(MagicPacket.hardware("a4:83:e7:12:34:5g") == nil)
        #expect(MagicPacket.hardware("a4:83:e7:12:34:567") == nil)
    }

    @Test func networks() {
        #expect(WakeRule.broadcast(address: "192.168.4.22", netmask: "255.255.255.0") == "192.168.4.255")
        #expect(WakeRule.broadcast(address: "10.0.1.9", netmask: "255.255.252.0") == "10.0.3.255")
        #expect(WakeRule.ipv4("192.168.4") == nil)
        #expect(WakeRule.ipv4("192.168.4.256") == nil)
        let info = WakeInfo(interfaces: [WakeInterface(hardware: "a4:83:e7:12:34:56", address: "192.168.4.22", netmask: "255.255.255.0", broadcast: "192.168.4.255")], wakeForNetwork: true)
        #expect(WakeRule.sameNetwork(phone: [("192.168.4.31", "255.255.255.0")], as: info))
        #expect(!WakeRule.sameNetwork(phone: [("192.168.7.31", "255.255.255.0")], as: info))
        #expect(!WakeRule.sameNetwork(phone: [("100.101.1.2", "255.192.0.0")], as: info))
        #expect(WakeRule.destinations(for: info.interfaces[0]) == ["192.168.4.255", "255.255.255.255", "192.168.4.22"])
    }

    @Test func pmset() {
        let on = """
        System-wide power settings:
        Currently in use:
         standby              1
         Sleep On Power Button 1
         womp                 1
         hibernatemode        3
        """
        #expect(WakeRule.wakeForNetwork(pmset: on) == true)
        #expect(WakeRule.wakeForNetwork(pmset: on.replacingOccurrences(of: "womp                 1", with: "womp\t0")) == false)
        #expect(WakeRule.wakeForNetwork(pmset: "Currently in use:\n sleep 1\n") == nil)
    }

    @Test func cleanedKeepsOnlyUsable() {
        let info = WakeInfo(interfaces: [
            WakeInterface(hardware: "a4:83:e7:12:34:56", address: "192.168.4.22", netmask: "255.255.255.0", broadcast: "192.168.4.255"),
            WakeInterface(hardware: "nope", address: "192.168.4.23", netmask: "255.255.255.0", broadcast: ""),
            WakeInterface(hardware: "a4:83:e7:12:34:57", address: "", netmask: "255.255.255.0", broadcast: ""),
        ], wakeForNetwork: nil)
        #expect(info.cleaned().interfaces.count == 1)
    }
}
