import MacrophoneKit
import SwiftUI

/// Away from home with Tailscale, as five steps that check themselves (Nov 7 2026): get it, sign
/// in, Remote access (on by itself once Tailscale is connected), Tailscale on the iPhone, and the
/// proof — a paired iPhone reaching this Mac from away. One button per step; each turns into a
/// green check as it's done, looked at every two seconds while the guide shows. Used by the
/// setup's Away page (native look) and Devices › Away from home (the window's plates).
struct AwayGuide: View {
    @ObservedObject var model: AppModel
    @ObservedObject var tailscale: TailscaleMonitor
    @ObservedObject var settings: Settings

    init(model: AppModel) {
        self.model = model
        tailscale = model.tailscale
        settings = model.settings
    }

    private var ts: TailscaleState { tailscale.state }
    private var reached: Date? { model.lastReachedAway }

    private var done: [Bool] {
        [ts.installed, ts.connected, settings.remoteAccess, reached != nil, reached != nil]
    }
    /// The first step not done yet (lit).
    private var next: Int { done.firstIndex(of: false) ?? -1 }

    var body: some View {
        CheckList {
            CheckRow(number: 1, title: "Get Tailscale", detail: getDetail, done: done[0], next: next == 0) {
                if !done[0] { GuideButton("Get Tailscale", prominent: next == 0, help: "Opens Tailscale in the Mac App Store", action: tailscale.getTailscale) }
            }
            CheckDivider()
            CheckRow(number: 2, title: "Sign in to Tailscale", detail: signInDetail, done: done[1], next: next == 1) {
                if !done[1], ts.installed {
                    GuideButton("Open Tailscale", prominent: next == 1, action: tailscale.openTailscale)
                }
            }
            CheckDivider()
            CheckRow(number: 3, title: "Turn on Remote access", detail: remoteDetail, done: done[2], next: next == 2) {
                Toggle("", isOn: Binding(get: { settings.remoteAccess }, set: { settings.chooseRemoteAccess($0) }))
                    .toggleStyle(.switch).labelsHidden()
                    .accessibilityLabel("Remote access")
            }
            CheckDivider()
            CheckRow(number: 4, title: "Get Tailscale on your iPhone",
                     detail: done[3] ? "Signed in with the same account." : "Scan this with your iPhone's camera, then sign in with the same account as on this Mac.",
                     done: done[3], next: next == 3) {
                if !done[3] {
                    QRCodeView(text: TailscaleMonitor.iPhoneAppStore.absoluteString)
                        .padding(5)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white))
                        .frame(width: 70, height: 70)
                        .accessibilityLabel("Code for Tailscale in the App Store. Scan it with your iPhone's camera.")
                }
            }
            CheckDivider()
            CheckRow(number: 5, title: reached != nil ? "Your iPhone can reach this Mac away from home" : "Try it away from home",
                     detail: proofDetail, done: done[4], next: next == 4)
        }
        .onAppear { tailscale.viewerAppeared() }
        .onDisappear { tailscale.viewerGone() }
    }

    // MARK: Words

    private var getDetail: String {
        ts.installed ? "Installed on this Mac." : "Free in the Mac App Store. It links your iPhone and this Mac privately — there's still no server of ours."
    }

    private var signInDetail: String {
        if let name = ts.name { return "Connected as \(name)." }
        if let a = ts.address { return "Connected · \(a)." }
        if ts.running { return "Tailscale is open but not connected. Sign in, or switch it on from its icon in the menu bar." }
        if ts.installed { return "Open Tailscale and sign in." }
        return "After it's installed, open it and sign in."
    }

    private var remoteDetail: String {
        if settings.remoteAccess { return "On. Only iPhones paired with this Mac can use it, encrypted the same way as at home." }
        if settings.remoteAccessChosen { return "Off. Turn it on so your iPhone can reach this Mac through Tailscale." }
        return "Comes on by itself once Tailscale is connected."
    }

    private var proofDetail: String {
        if let reached { return "It connected from away \(reached.relativeShort)." }
        if model.peers.isEmpty { return "Pair your iPhone first." }
        if ts.connected, settings.remoteAccess, model.connectedPeer != nil {
            return "Your iPhone has this Mac's address now. To try it, turn off Wi-Fi on your iPhone and open Macrophone."
        }
        return "Open Macrophone on your iPhone once while you're home. It learns this Mac's address, then works from anywhere."
    }
}
