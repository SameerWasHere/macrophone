import MacrophoneKit
import SwiftUI

/// What the connected Mac is allowed to do (Oct 19 2026), as it last said (`.macPermissions`,
/// only from a Mac whose welcome names `MacPermissions.feature`; nil from one that doesn't).
@MainActor
final class MacPermissionsState: ObservableObject {
    static let shared = MacPermissionsState()

    @Published var permissions: MacPermissions?
    /// Brings Macrophone's permissions page forward on the Mac; false when the Mac can't.
    var showOnMac: () -> Bool = { false }
    /// The connected Mac can bring that page forward.
    var canShowOnMac: () -> Bool = { false }
    /// Asked the Mac to show it a moment ago (the button then says where to look).
    @Published private(set) var asked = false

    private init() {
        #if DEBUG
        // MACROPHONE_FAKE_PERMISSIONS=accessibility|screen|both: that one is off (screenshots, tests).
        switch DebugHooks.env["MACROPHONE_FAKE_PERMISSIONS"] {
        case "accessibility": permissions = MacPermissions(accessibility: false, screenRecording: true)
        case "screen": permissions = MacPermissions(accessibility: true, screenRecording: false)
        case "both": permissions = MacPermissions(accessibility: false, screenRecording: false)
        default: break
        }
        #endif
    }

    /// Open Macrophone on the Mac at its permissions; false when the Mac can't (the caller falls
    /// back to opening the setting itself).
    @discardableResult
    func openOnMac() -> Bool {
        guard showOnMac() else { return false }
        asked = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            self.asked = false
        }
        return true
    }
}

extension AppModel: LinkClientPermissionsDelegate {
    func linkClient(_ client: LinkClient, macPermissions: MacPermissions) {
        if MacPermissionsState.shared.permissions != macPermissions {
            MacPermissionsState.shared.permissions = macPermissions
            log.add("Mac permissions: Accessibility \(macPermissions.accessibility ? "on" : "off") · Screen Recording \(macPermissions.screenRecording ? "on" : "off")")
        }
    }
}

/// Over a live window when the Mac can't take taps or keys (Accessibility off): one line saying
/// so, and the way to fix it — open Macrophone on the Mac. Screen Recording off is the window's
/// own note (`Watcher.Phase.needsPermission`); this is only the half that still shows a picture.
struct MacPermissionBanner: View {
    @ObservedObject var watcher: Watcher
    @ObservedObject private var state = MacPermissionsState.shared
    /// Put away for this window (it comes back for the next one, or when the grant changes).
    @State private var hidden = false

    var body: some View {
        Group { banner }
            .onChange(of: watcher.windowSeq) { _, _ in hidden = false }
            .onChange(of: state.permissions) { _, _ in hidden = false }
    }

    @ViewBuilder private var banner: some View {
        if watcher.phase == .live, let p = state.permissions, !p.accessibility, !hidden {
            // Compact: it sits over the picture, and on a small phone the window is short.
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "hand.raised")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Light.ochre)
                        .accessibilityHidden(true)
                    Text(state.asked ? "Macrophone is open on your Mac — turn on Accessibility there." : (p.missingLine ?? ""))
                        .font(.footnote.weight(.semibold)).foregroundStyle(Ink.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { withAnimation(.easeOut(duration: 0.2)) { hidden = true } } label: {
                        Image(systemName: "xmark").font(.caption.weight(.semibold)).foregroundStyle(Ink.secondary)
                            .frame(width: 28, height: 28).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Hide")
                }
                if !state.asked, state.canShowOnMac() {
                    Button { state.openOnMac() } label: {
                        Text("Open Macrophone on my Mac").font(.footnote.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(Light.cyan)
                    .padding(.leading, 22)
                    .accessibilityIdentifier("watch-open-mac-permissions")
                }
            }
            .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 8)
            .watchGlass(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
            .accessibilityElement(children: .contain)
            .accessibilityHint(p.missingDetail ?? "")
        }
    }
}
