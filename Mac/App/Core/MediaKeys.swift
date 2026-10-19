import AppKit
import AudioToolbox
import CoreAudio
import Foundation
import MacrophoneKit

/// Mac Controls (Oct 19 2026): the keyboard's top row, pressed for the phone. Each is the same
/// system-defined event the Mac's own keys send (subtype 8, NX_KEYTYPE_* in data1), so the Mac
/// does exactly what its keys do — the volume HUD, the player that has the media keys, the
/// display's brightness. Posting events needs Accessibility, which pasting already does.
///
/// Brightness keys reach a built-in display and Apple's own displays; any other display keeps its
/// brightness on its own buttons — the answer says so instead of pretending.
enum MediaKeys {
    /// Presses `control` (down, then up) and answers with what it did: for a volume key, the output
    /// volume read back from Core Audio a moment later.
    @MainActor static func press(_ control: MacControl) async -> MacControlResult {
        guard Paster.isTrusted else {
            return MacControlResult(control: control, ok: false, detail: "Macrophone needs Accessibility on your Mac to press keys")
        }
        #if DEBUG
        // MACROPHONE_FAKE_MEDIA_KEYS=1: nothing is pressed (testing next to someone using the Mac).
        if ProcessInfo.processInfo.environment["MACROPHONE_FAKE_MEDIA_KEYS"] == "1" {
            return MacControlResult(control: control, ok: true, detail: "\(control.title) (not pressed — a test)")
        }
        #endif
        post(control, down: true)
        post(control, down: false)
        if control.isVolume {
            // The system takes a beat to apply the key.
            try? await Task.sleep(nanoseconds: 120_000_000)
            let v = Volume.read()
            let line = MacControlResult.volumeLine(v.volume, muted: v.muted) ?? control.title
            return MacControlResult(control: control, ok: true, volume: v.volume, muted: v.muted, detail: line)
        }
        if control.isBrightness, !MacDisplays.brightnessKeysWork {
            return MacControlResult(control: control, ok: false,
                                    detail: "Brightness keys change only a built-in or Apple display — use this display's own buttons")
        }
        return MacControlResult(control: control, ok: true, detail: control.title)
    }

    private static func post(_ control: MacControl, down: Bool) {
        let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
        let e = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0,
                                   windowNumber: 0, context: nil, subtype: 8, data1: control.data1(down: down), data2: -1)
        e?.cgEvent?.post(tap: .cghidEventTap)
    }

    /// The default output's volume and mute, read the cheap way (two property reads).
    enum Volume {
        static func read() -> (volume: Double?, muted: Bool?) {
            var device = AudioObjectID(0)
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                  mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr, device != 0 else { return (nil, nil) }
            var volume: Float32 = 0
            size = UInt32(MemoryLayout<Float32>.size)
            addr = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                              mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            let v: Double? = AudioObjectHasProperty(device, &addr) && AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &volume) == noErr ? Double(volume) : nil
            var mute: UInt32 = 0
            size = UInt32(MemoryLayout<UInt32>.size)
            addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                              mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            let m: Bool? = AudioObjectHasProperty(device, &addr) && AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &mute) == noErr ? mute != 0 : nil
            return (v, m)
        }
    }
}
