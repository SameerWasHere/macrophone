import MacrophoneKit
import SwiftUI

struct DevicesPane: View {
    @ObservedObject var model: AppModel
    @State private var forgetting: PairedPeer?

    var body: some View {
        PanePage {
            HStack(alignment: .bottom) {
                PaneHeader(title: "Devices", subtitle: "iPhones paired with this Mac. They talk directly over your network — no account, no server.")
                Button { AppDelegate.shared?.openSetup(.pair) } label: { Label("Pair iPhone…", systemImage: "qrcode") }
                    .buttonStyle(PillButtonStyle(tint: Ink.ink, filled: model.peers.isEmpty))
                    .padding(.bottom, 2)
            }

            if model.peers.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "iphone.gen3").font(.system(size: 34, weight: .light)).foregroundStyle(Ink.tertiary)
                    Text("No iPhone yet").font(Typeface.serif(18)).foregroundStyle(Ink.secondary)
                    Text("Get Macrophone for iPhone from the App Store, then choose Pair iPhone.")
                        .font(.system(size: 12.5)).foregroundStyle(Ink.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 48)
            } else {
                Plate {
                    ForEach(Array(model.peers.enumerated()), id: \.element.id) { i, p in
                        if i > 0 { PlateDivider(inset: 62) }
                        phoneRow(p)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("This Mac")
                Plate {
                    PlateRow(title: AppPaths.computerName, subtitle: listenerLine, icon: "laptopcomputer",
                             iconColor: listenerOK ? Light.cyan : Light.ochre)
                }
                Text("The name comes from System Settings › General › Sharing.")
                    .font(.system(size: 11.5)).foregroundStyle(Ink.tertiary).padding(.leading, 4)
            }
        }
        .confirmationDialog("Forget \(forgetting?.name ?? "this iPhone")?", isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } })) {
            Button("Forget", role: .destructive) { if let p = forgetting { model.forget(p) }; forgetting = nil }
        } message: {
            Text("It won't be able to send to this Mac until you pair it again. Use this if the phone is lost.")
        }
    }

    private var listenerOK: Bool { if case .ready = model.listenerState { return true }; return false }

    private var listenerLine: String {
        switch model.listenerState {
        case .ready: return "Visible to your iPhone on this network and nearby (peer-to-peer)."
        case .starting: return "Starting…"
        case .failed: return "Can't listen on the network. Check System Settings › Privacy & Security › Local Network."
        }
    }

    private func phoneRow(_ p: PairedPeer) -> some View {
        let on = model.connected.contains(p.id)
        return HStack(spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "iphone.gen3")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(Ink.secondary)
                    .frame(width: 32, height: 32)
                Circle().fill(on ? Light.cyan : Ink.tertiary.opacity(0.5)).frame(width: 8, height: 8)
                    .overlay(Circle().strokeBorder(Ink.raised, lineWidth: 1.5))
                    .shadow(color: on ? Light.cyan.opacity(0.9) : .clear, radius: 3)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(p.name).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Ink.ink)
                Text(line(p, on: on)).font(.system(size: 11.5)).foregroundStyle(on ? Light.cyan : Ink.tertiary)
            }
            Spacer()
            Button("Forget…") { forgetting = p }
                .buttonStyle(PillButtonStyle(tint: Light.rose, filled: false))
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func line(_ p: PairedPeer, on: Bool) -> String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMM d, yyyy")
        let paired = "paired \(f.string(from: p.pairedAt))"
        if on { return "Connected · \(paired)" }
        if let s = p.lastSeen { return "Last seen \(s.relativeShort) · \(paired)" }
        return "Not seen yet · \(paired)"
    }
}

struct GeneralPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updater: Updater

    var body: some View {
        PanePage {
            PaneHeader(title: "General", subtitle: "Macrophone \(AppPaths.appVersion) (\(AppPaths.buildNumber))")

            Plate {
                PlateRow(title: "Open at login", subtitle: "Macrophone can only receive while it's running.", icon: "power") {
                    Toggle("", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                        .toggleStyle(.switch).labelsHidden()
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Updates")
                Plate {
                    PlateRow(title: "Check for updates automatically", subtitle: updateLine, icon: "arrow.triangle.2.circlepath") {
                        Toggle("", isOn: $updater.automaticallyChecks).toggleStyle(.switch).labelsHidden()
                    }
                    PlateDivider(inset: 50)
                    HStack {
                        Spacer()
                        Button("Check for Updates…") { updater.checkForUpdates() }
                            .buttonStyle(PillButtonStyle(tint: Ink.ink, filled: false))
                            .disabled(!updater.canCheck)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Help")
                Plate {
                    PlateRow(title: "Share diagnostics", subtitle: "A plain-text log of connections and deliveries to send with a bug report. Never what you dictated.", icon: "stethoscope") {
                        Button("Share Diagnostics…") { AppDelegate.shared?.showDiagnostics() }
                            .buttonStyle(PillButtonStyle(tint: Ink.ink, filled: false))
                    }
                    PlateDivider(inset: 50)
                    PlateRow(title: "Show the welcome again", subtitle: "Walk through pairing and the delivery modes.", icon: "sparkle") {
                        Button("Show") { AppDelegate.shared?.openSetup(.pair) }
                            .buttonStyle(PillButtonStyle(tint: Ink.ink, filled: false))
                    }
                    PlateDivider(inset: 50)
                    PlateRow(title: "Macrophone on the web", subtitle: Product.macDownloadDisplay, icon: "safari") {
                        Link("Open", destination: Product.website).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Light.teal)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Privacy").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Ink.secondary)
                Text("Speech is transcribed on your iPhone. No audio is kept, there's no account, and nothing leaves your devices unless you add a webhook or script to a profile. Macrophone collects no analytics.")
                    .font(.system(size: 12)).foregroundStyle(Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 6)

            HStack {
                Spacer()
                Button("Quit Macrophone") { NSApp.terminate(nil) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Ink.tertiary)
            }
        }
    }

    private var updateLine: String {
        if let d = updater.lastCheck { return "Last checked \(d.relativeShort)." }
        return "Signed updates from sameer.us. Checked once a day."
    }
}
