import AppKit
import ApplicationServices
import AVFoundation
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
    /// The microphone, for dictation at the desk (Nov 7 2026) — only asked for there.
    @Published private(set) var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    /// Input Monitoring: only needed if macOS refuses desk dictation's key tap with Accessibility alone.
    @Published private(set) var inputMonitoring = CGPreflightListenEventAccess()
    static let microphoneSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
    static let inputMonitoringSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!

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
        #if DEBUG
        refresh()
        #endif
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
        // The desk's two (never told to the phones).
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        if mic != microphone { microphone = mic }
        let listen = CGPreflightListenEventAccess()
        if listen != inputMonitoring { inputMonitoring = listen }
        var ax = AXIsProcessTrusted(), screen = CGPreflightScreenCaptureAccess()
        #if DEBUG
        // MACROPHONE_FAKE_GRANTS=both | none | accessibility | screen — what's allowed, for screenshots.
        if let g = ProcessInfo.processInfo.environment["MACROPHONE_FAKE_GRANTS"] {
            ax = g == "both" || g == "accessibility"
            screen = g == "both" || g == "screen"
        }
        #endif
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

    /// The microphone: macOS's own question the first time, Privacy & Security › Microphone after.
    func openMicrophone() {
        if microphone == .notDetermined {
            Task { @MainActor in
                _ = await AVCaptureDevice.requestAccess(for: .audio)
                self.refresh()
            }
            return
        }
        NSWorkspace.shared.open(Self.microphoneSettingsURL)
    }

    /// Privacy & Security › Input Monitoring. Asking once puts Macrophone in that list.
    func openInputMonitoring() {
        if !inputMonitoring { CGRequestListenEventAccess() }
        NSWorkspace.shared.open(Self.inputMonitoringSettingsURL)
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
