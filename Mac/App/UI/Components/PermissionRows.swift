import MacrophoneKit
import SwiftUI

/// Accessibility and Screen Recording, live (Oct 19 2026): what each unlocks in plain words, a
/// green check once it's on, else a button that opens that exact pane of System Settings. Used by
/// the setup's Permissions step and General › Permissions; while one is on screen the monitor
/// looks every second, so the check lands the moment the switch is flipped.
struct PermissionRows: View {
    @ObservedObject var monitor: PermissionsMonitor
    /// Which grants: the phone's (Accessibility, Screen Recording — the setup and General), or
    /// dictation at the desk's (Accessibility, the microphone, and Input Monitoring only when
    /// macOS refused the key without it). Nov 7 2026.
    var desk = false
    var needsInputMonitoring = false
    /// The wake word is on: the microphone row says it listens for this phrase too.
    var wakePhrase: String?

    var body: some View {
        Plate {
            PermissionRow(title: "Accessibility",
                          unlocks: desk
                            ? "To hear the key you hold and paste the words where you're typing."
                            : "To click, type and paste for you — the taps and keys from your iPhone, and dictations landing in the app you picked.",
                          missing: desk
                            ? "Until it's on, the key isn't heard and the words are only copied."
                            : "Until it's on, taps and keys from your iPhone don't reach your Mac, and dictations are only copied.",
                          symbol: "hand.raised",
                          granted: monitor.accessibility,
                          open: monitor.openAccessibility)
            PlateDivider()
            if desk {
                PermissionRow(title: "Microphone",
                              unlocks: wakePhrase.map { "To hear you while you hold the key, and to listen for “\($0)”. What you say stays on this Mac." }
                                ?? "To hear you while you hold the key — only then. What you say stays on this Mac.",
                              missing: monitor.microphone == .notDetermined
                                ? "macOS asks once."
                                : "Until it's on, holding the key does nothing.",
                              symbol: "mic",
                              granted: monitor.microphone == .authorized,
                              button: monitor.microphone == .notDetermined ? "Allow Microphone" : "Open System Settings",
                              open: monitor.openMicrophone)
                if needsInputMonitoring {
                    PlateDivider()
                    PermissionRow(title: "Input Monitoring",
                                  unlocks: "macOS wants this too before Macrophone can hear the key you hold.",
                                  missing: "Turn it on, then come back here.",
                                  symbol: "keyboard",
                                  granted: monitor.inputMonitoring,
                                  open: monitor.openInputMonitoring)
                }
            } else {
                screenRecording
            }
        }
        .onAppear { monitor.viewerAppeared() }
        .onDisappear { monitor.viewerGone() }
    }

    private var screenRecording: some View {
            PermissionRow(title: "Screen Recording",
                          unlocks: "To show your Mac on your iPhone — only the window you pick, only while you watch it.",
                          missing: monitor.screenRecordingAsked
                            ? "Turned it on and it still says off? Quit Macrophone and open it again — macOS needs that once."
                            : "Until it's on, your iPhone can't show your Mac's windows.",
                          symbol: "rectangle.dashed.badge.record",
                          granted: monitor.screenRecording,
                          open: monitor.openScreenRecording)
    }
}

private struct PermissionRow: View {
    let title: String
    let unlocks: String
    let missing: String
    let symbol: String
    let granted: Bool
    var button = "Open System Settings"
    let open: () -> Void

    var body: some View {
        PlateRow(title: title,
                 subtitle: granted ? unlocks : "\(unlocks) \(missing)",
                 subtitleColor: granted ? Ink.tertiary : Light.ochre,
                 icon: granted ? "checkmark.circle.fill" : symbol,
                 iconColor: granted ? Light.mint : Light.ochre) {
            if granted {
                Label("Allowed", systemImage: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Light.mint)
                    .labelStyle(.titleAndIcon)
                    .accessibilityLabel("\(title) is allowed")
            } else {
                Button(button, action: open)
                    .buttonStyle(PillButtonStyle(tint: Ink.ink, filled: true))
                    .accessibilityHint("Opens Privacy & Security › \(title). Turn on Macrophone there.")
            }
        }
        .animation(Motion.reduceMotion ? .easeInOut(duration: 0.2) : Motion.settle, value: granted)
    }
}
