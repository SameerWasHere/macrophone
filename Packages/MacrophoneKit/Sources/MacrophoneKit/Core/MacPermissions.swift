import Foundation

// What the Mac is allowed to do (Oct 19 2026). Without Accessibility a tap, a key or a paste never
// reaches an app; without Screen Recording the window can't be shown. The Mac only ever reads its
// own grants (AXIsProcessTrusted, CGPreflightScreenCaptureAccess) and never changes them; it tells
// a phone that names the feature, so the phone can say "Your Mac needs to allow Screen Recording —
// open Macrophone on your Mac" instead of showing a dark window or a tap that does nothing.
//
// The wire: `.macPermissions` (Mac → phone, after the welcome and whenever a grant changes) only to
// a phone whose hello names `MacPermissions.feature`; `.showPermissions` (phone → Mac: bring
// Macrophone's permissions page forward on the Mac) only to a Mac whose welcome names it. An older
// peer never sees either (an unknown message ends a session).

/// The Mac's two grants, as it last read them.
public struct MacPermissions: Codable, Sendable, Equatable {
    public static let feature = "permissions"

    /// Clicks, keys, pasting and pressing send (and listing what has somewhere to type).
    public var accessibility: Bool
    /// Showing the window on the phone.
    public var screenRecording: Bool

    public init(accessibility: Bool, screenRecording: Bool) {
        self.accessibility = accessibility
        self.screenRecording = screenRecording
    }

    public var allGranted: Bool { accessibility && screenRecording }

    /// The one line a phone shows when something is missing (nil when both are on). Screen
    /// Recording first: without it there's nothing to look at at all.
    public var missingLine: String? {
        switch (accessibility, screenRecording) {
        case (true, true): return nil
        case (_, false) where !accessibility: return "Your Mac needs to allow Accessibility and Screen Recording — open Macrophone on your Mac"
        case (_, false): return "Your Mac needs to allow Screen Recording — open Macrophone on your Mac"
        default: return "Your Mac needs to allow Accessibility — open Macrophone on your Mac"
        }
    }

    /// What's missing costs, in a few plain words (for under the line).
    public var missingDetail: String? {
        switch (accessibility, screenRecording) {
        case (true, true): return nil
        case (_, false) where !accessibility: return "Until then your Mac can't show its windows here, and taps and keys don't reach it."
        case (_, false): return "Until then your Mac can't show its windows here. It only ever shows the app you pick."
        default: return "Until then taps, keys and pasting don't reach your Mac's apps."
        }
    }
}
