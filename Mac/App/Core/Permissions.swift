import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import MacrophoneKit

/// The two grants Macrophone needs, read live (Oct 19 2026). It only ever looks — it never asks
/// macOS to change a setting; the buttons open the exact pane in System Settings and the person
/// flips the switch. Every second while a page that shows them is open (the setup's Permissions
/// step, General › Permissions), every ten otherwise, and at once when the app comes forward; a
/// change is told to every phone that understands it (`MacPermissions.feature`).
@MainActor
final class PermissionsMonitor: ObservableObject {
    static let accessibilitySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    static let screenRecordingSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    @Published private(set) var accessibility = AXIsProcessTrusted()
    @Published private(set) var screenRecording = CGPreflightScreenCaptureAccess()
    /// Asked for Screen Recording from here and it's still off: macOS often wants Macrophone
    /// reopened before the switch takes (System Settings offers "Quit & Reopen").
    @Published private(set) var screenRecordingAsked = false

    var current: MacPermissions { MacPermissions(accessibility: accessibility, screenRecording: screenRecording) }
    /// Called with the new pair whenever either changes.
    var onChange: ((MacPermissions) -> Void)?

    private var viewers = 0
    private var timer: Timer?
    private var bag = Set<AnyCancellable>()

    init() {
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &bag)
        schedule()
    }

    /// A page showing the grants appeared (or went): poll every second while any is up.
    func viewerAppeared() { viewers += 1; refresh(); schedule() }
    func viewerGone() { viewers = max(0, viewers - 1); schedule() }

    private func schedule() {
        let interval: TimeInterval = viewers > 0 ? 1 : 10
        if let t = timer, t.timeInterval == interval { return }
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        t.tolerance = interval * 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func refresh() {
        let ax = AXIsProcessTrusted(), screen = CGPreflightScreenCaptureAccess()
        guard ax != accessibility || screen != screenRecording else { return }
        accessibility = ax
        screenRecording = screen
        if screen { screenRecordingAsked = false }
        onChange?(current)
    }

    /// Opens Privacy & Security › Accessibility. The first time, macOS's own prompt also puts
    /// Macrophone in that list (so there's a switch to turn on).
    func openAccessibility() {
        if !accessibility { _ = Paster.requestTrust() }
        NSWorkspace.shared.open(Self.accessibilitySettingsURL)
    }

    /// Opens Privacy & Security › Screen Recording. Asking once puts Macrophone in that list.
    func openScreenRecording() {
        if !screenRecording, !screenRecordingAsked {
            screenRecordingAsked = true
            CGRequestScreenCaptureAccess()
        }
        NSWorkspace.shared.open(Self.screenRecordingSettingsURL)
    }
}
