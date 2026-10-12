import MacrophoneKit
import SwiftUI

/// The pairing screen as a sheet or pushed from Settings.
struct PairingView: View {
    var embedded = false
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if embedded {
            content
        } else {
            NavigationStack {
                content
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.fontWeight(.semibold) }
                    }
            }
        }
    }

    private var content: some View {
        ScrollView {
            PairingPanel(onDone: { dismiss() })
                .padding(20)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(GroundBackground().ignoresSafeArea())
        .navigationTitle("Pair Your Mac")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            if case .paired = model.pairing { model.resetPairing() }
            if case .failed = model.pairing { model.resetPairing() }
        }
    }
}

/// QR first, a six-digit code as the fallback, and every outcome in plain words.
struct PairingPanel: View {
    @EnvironmentObject var model: AppModel
    var onDone: () -> Void
    var compact = false
    @State private var useCode = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 18) {
            switch model.pairing {
            case .idle:
                if useCode { codePicker } else { scanner }
            case .connecting(let name):
                progress("Pairing with \(name)…")
            case .showingCode(let code, let name):
                codeDisplay(code, mac: name)
            case .paired(let name):
                success(name)
            case .failed(let message):
                failure(message)
            }
        }
        .animation(Motion.pick(Motion.settle, reduce: reduceMotion), value: model.pairing)
        .animation(Motion.pick(Motion.settle, reduce: reduceMotion), value: useCode)
        .onAppear { model.startLink() }
    }

    // MARK: QR

    private var scanner: some View {
        VStack(spacing: 16) {
            if !compact {
                header("Scan the code on your Mac",
                       "On your Mac, open Macrophone and choose Pair iPhone. Point this camera at the code it shows.")
            }
            QRScanner { code in
                guard let invite = PairingInvite(string: code) else { return }
                Task { await model.pair(invite) }
            }
            .frame(height: compact ? 260 : 300)
            Button("Use a code instead") { useCode = true }
                .buttonStyle(PillButtonStyle(kind: .secondary, tint: Light.cyan))
            networkNote
        }
    }

    // MARK: Code

    private var codePicker: some View {
        VStack(spacing: 16) {
            header("Pick your Mac", "Make sure Macrophone is open on your Mac. You'll both see the same six digits.")
            VStack(spacing: 0) {
                if model.discoveredMacs.isEmpty {
                    HStack(spacing: 12) {
                        ProgressView().tint(Ink.secondary)
                        Text("Looking for Macs on this network…").foregroundStyle(Ink.secondary)
                        Spacer()
                    }
                    .padding(16)
                } else {
                    ForEach(Array(model.discoveredMacs.enumerated()), id: \.element.id) { i, mac in
                        if i > 0 { Divider().overlay(Ink.line) }
                        Button {
                            Task { await model.pairWithCode(mac) }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "laptopcomputer").foregroundStyle(Light.cyan)
                                Text(mac.name).foregroundStyle(Ink.ink).multilineTextAlignment(.leading)
                                Spacer()
                                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Ink.tertiary)
                            }
                            .padding(16)
                            .frame(minHeight: 52)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .glass(Radius.medium)
            Button("Scan the QR code instead") { useCode = false }
                .buttonStyle(PillButtonStyle(kind: .quiet, tint: Light.cyan))
            networkNote
        }
    }

    private func codeDisplay(_ code: String, mac: String) -> some View {
        let spaced = code.count == 6 ? "\(code.prefix(3)) \(code.suffix(3))" : code
        return VStack(spacing: 18) {
            Kicker("Compare with your Mac")
            Text(spaced)
                .font(.system(size: 56, weight: .semibold, design: .monospaced))
                .foregroundStyle(Ink.ink)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .accessibilityLabel(code.map(String.init).joined(separator: " "))
            Text("Check that \(mac) shows \(spaced), then click Match on the Mac.")
                .font(.serif(.title3))
                .foregroundStyle(Ink.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                ProgressView().tint(Ink.tertiary)
                Text("Waiting for your Mac").font(.subheadline).foregroundStyle(Ink.tertiary)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .glass(Radius.large)
    }

    // MARK: Outcomes

    private func progress(_ text: String) -> some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large).tint(Light.cyan)
            Text(text).font(.serif(.title3)).foregroundStyle(Ink.ink).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
    }

    private func success(_ name: String) -> some View {
        VStack(spacing: 16) {
            DeliveredCheck(visible: true).scaleEffect(1.6).padding(.bottom, 8)
            Text("Paired with \(name)").font(.serif(.title2)).foregroundStyle(Ink.ink).multilineTextAlignment(.center)
            Text("What you say on this iPhone now lands on that Mac.")
                .font(.subheadline).foregroundStyle(Ink.secondary).multilineTextAlignment(.center)
            Button("Done") { model.resetPairing(); onDone() }
                .buttonStyle(PillButtonStyle(kind: .primary, tint: Ink.ink))
        }
        .frame(maxWidth: .infinity, minHeight: 260)
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 34)).foregroundStyle(Light.rose)
            Text(message).font(.serif(.title3)).foregroundStyle(Ink.ink).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try Again") { model.resetPairing() }
                .buttonStyle(PillButtonStyle(kind: .primary, tint: Ink.ink))
        }
        .frame(maxWidth: .infinity, minHeight: 240)
    }

    private func header(_ title: String, _ body: String) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.serif(.title2)).foregroundStyle(Ink.ink).multilineTextAlignment(.center)
            Text(body).font(.subheadline).foregroundStyle(Ink.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var networkNote: some View {
        Text("Your iPhone and Mac talk directly over this network. Nothing goes to the internet.")
            .font(.footnote)
            .foregroundStyle(Ink.tertiary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }
}
