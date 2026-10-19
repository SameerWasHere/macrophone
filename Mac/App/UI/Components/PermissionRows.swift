import MacrophoneKit
import SwiftUI

/// Accessibility and Screen Recording, live (Oct 19 2026): what each unlocks in plain words, a
/// green check once it's on, else a button that opens that exact pane of System Settings. Used by
/// the setup's Permissions step and General › Permissions; while one is on screen the monitor
/// looks every second, so the check lands the moment the switch is flipped.
struct PermissionRows: View {
    @ObservedObject var monitor: PermissionsMonitor

    var body: some View {
        Plate {
            PermissionRow(title: "Accessibility",
                          unlocks: "To click, type and paste for you — the taps and keys from your iPhone, and dictations landing in the app you picked.",
                          missing: "Until it's on, taps and keys from your iPhone don't reach your Mac, and dictations are only copied.",
                          symbol: "hand.raised",
                          granted: monitor.accessibility,
                          open: monitor.openAccessibility)
            PlateDivider()
            PermissionRow(title: "Screen Recording",
                          unlocks: "To show your Mac on your iPhone — only the window you pick, only while you watch it.",
                          missing: monitor.screenRecordingAsked
                            ? "Turned it on and it still says off? Quit Macrophone and open it again — macOS needs that once."
                            : "Until it's on, your iPhone can't show your Mac's windows.",
                          symbol: "rectangle.dashed.badge.record",
                          granted: monitor.screenRecording,
                          open: monitor.openScreenRecording)
        }
        .onAppear { monitor.viewerAppeared() }
        .onDisappear { monitor.viewerGone() }
    }
}

private struct PermissionRow: View {
    let title: String
    let unlocks: String
    let missing: String
    let symbol: String
    let granted: Bool
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
                Button("Open System Settings", action: open)
                    .buttonStyle(PillButtonStyle(tint: Ink.ink, filled: true))
                    .accessibilityHint("Opens Privacy & Security › \(title). Turn on Macrophone there.")
            }
        }
        .animation(Motion.reduceMotion ? .easeInOut(duration: 0.2) : Motion.settle, value: granted)
    }
}
