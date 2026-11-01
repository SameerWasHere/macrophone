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
                        ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.doneButtonStyle() }
                    }
            }
            .tint(Light.cyan)
        }
    }

    private var content: some View {
        PairingPanel(onDone: { dismiss() })
            .navigationTitle(model.isPaired ? "Pair Another Mac" : "Pair Your Mac")
            .navigationBarTitleDisplayMode(.inline)
            .onDisappear {
                if case .paired = model.pairing { model.resetPairing() }
                if case .failed = model.pairing { model.resetPairing() }
            }
    }
}

/// QR first, a six-digit code as the fallback, and every outcome in plain words — each phase a
/// Setup Assistant page (Nov 1 2026): the title and what to do at the top, the camera or the code
/// in the middle, the one button pinned at the foot.
struct PairingPanel: View {
    @EnvironmentObject var model: AppModel
    var onDone: () -> Void
    /// An SE-class height (setup on a small phone): a smaller camera and title.
    var compact = false
    /// The success screen's button: "Continue" in setup, "Start Dictating" from the sheet.
    var doneTitle = "Start Dictating"
    @State private var useCode = false
    @State private var deviceName = ""
    @State private var pairedShown = false
    @FocusState private var nameFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
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
        SetupPage(title: "Scan the code on your Mac",
                  message: "On your Mac, open Macrophone and choose Pair iPhone, then point this camera at the code it shows. The camera is used only for this.",
                  compact: compact) {
            EmptyView()
        } content: {
            VStack(spacing: 16) {
                QRScanner { code in
                    guard let invite = PairingInvite(string: code) else { return }
                    Task { await model.pair(invite) }
                }
                .frame(height: compact ? 250 : 300)
                networkNote
                macAppNote
            }
        } buttons: {
            Button("Use a Code Instead") { useCode = true }
                .setupSecondary()
        }
    }

    // MARK: Code

    private var codePicker: some View {
        SetupPage(title: "Pick your Mac",
                  message: "Make sure Macrophone is open on your Mac. You'll both see the same six digits.",
                  compact: compact) {
            SetupSymbol(name: "laptopcomputer", style: Light.cyan, compact: compact)
        } content: {
            VStack(spacing: 16) {
                VStack(spacing: 0) {
                    if model.discoveredMacs.isEmpty {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Looking for Macs on this network…").foregroundStyle(Ink.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .frame(minHeight: 52)
                    } else {
                        ForEach(Array(model.discoveredMacs.enumerated()), id: \.element.id) { i, mac in
                            if i > 0 { Divider().padding(.leading, 59) }
                            Button {
                                Task { await model.pairWithCode(mac) }
                            } label: {
                                HStack(spacing: 14) {
                                    SettingsIcon(symbol: MacGlyph.symbol(for: mac.name), color: Light.cyan)
                                    Text(mac.name).foregroundStyle(Ink.ink).multilineTextAlignment(.leading)
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Ink.tertiary)
                                        .accessibilityHidden(true)
                                }
                                .padding(.horizontal, 16)
                                .frame(minHeight: 52)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: Radius.large, style: .continuous).fill(Color(uiColor: .secondarySystemBackground)))
                networkNote
            }
        } buttons: {
            Button("Scan the QR Code Instead") { useCode = false }
                .setupSecondary()
        }
    }

    private func codeDisplay(_ code: String, mac: String) -> some View {
        let spaced = code.count == 6 ? "\(code.prefix(3))\u{00A0}\(code.suffix(3))" : code
        return SetupPage(title: "Compare with your Mac",
                         message: "Check that \(mac) shows \(spaced), then click Match on the Mac.",
                         compact: compact) {
            SetupSymbol(name: "lock.laptopcomputer", style: Light.cyan, compact: compact)
        } content: {
            VStack(spacing: 18) {
                Text(spaced)
                    .font(.system(size: 56, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Ink.ink)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: Radius.large, style: .continuous).fill(Color(uiColor: .secondarySystemBackground)))
                    .accessibilityLabel(code.map(String.init).joined(separator: " "))
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Waiting for your Mac").font(.subheadline).foregroundStyle(Ink.secondary)
                }
            }
        }
    }

    // MARK: Outcomes

    private func progress(_ text: String) -> some View {
        SetupPage(title: text, compact: compact) {
            ProgressView().controlSize(.large).frame(height: compact ? 76 : 108)
        }
    }

    /// Paired — and, since iOS only tells apps "iPhone", the one question worth asking here:
    /// what the Mac should call this phone.
    private func success(_ name: String) -> some View {
        let suggestion = DeviceNameSuggestion.from(macName: name)
        return SetupPage(title: "Paired with \(name)",
                         message: model.pairedMacs.count > 1
                            ? "It's the active Mac now. Swipe up or down on its name at the top to switch between your Macs."
                            : "What you say on this iPhone now lands on that Mac.",
                         compact: compact) {
            // Apple's done: a white check on a solid green disc.
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: compact ? 60 : 84, weight: .regular))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Light.mint)
                .symbolEffect(.bounce, value: pairedShown)
                .frame(height: compact ? 76 : 108)
                .accessibilityHidden(true)
                .onAppear { pairedShown = true }
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                Text("What should your Mac call this iPhone?")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Ink.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                TextField("iPhone", text: $deviceName)
                    .font(.body)
                    .foregroundStyle(Ink.ink)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($nameFocused)
                    .onSubmit { nameFocused = false }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 50)
                    .background(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous).fill(Color(uiColor: .secondarySystemBackground)))
                    .overlay(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                        .strokeBorder(Light.cyan.opacity(nameFocused ? 0.7 : 0), lineWidth: 1.5))
                    .accessibilityLabel("This iPhone's name")
                    .accessibilityIdentifier("device-name")
                if let suggestion, suggestion != deviceName {
                    Button { withAnimation(Motion.snap) { deviceName = suggestion } } label: {
                        Label("Use “\(suggestion)”", systemImage: "sparkles")
                    }
                    .font(.subheadline.weight(.medium))
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .tint(Light.cyan)
                    .accessibilityLabel("Use “\(suggestion)”")
                    .accessibilityHint("Fills in the name.")
                }
                Text("It shows next to each dictation on your Mac. You can change it later in Settings.")
                    .font(.footnote).foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.easeInOut(duration: 0.2), value: nameFocused)
        } buttons: {
            SetupButton(doneTitle) {
                nameFocused = false
                model.renameDevice(deviceName)
                model.resetPairing()
                onDone()
            }
        }
        .onAppear { if deviceName.isEmpty { deviceName = model.settings.deviceName } }
    }

    private func failure(_ message: String) -> some View {
        let network = model.pairingMayNeedLocalNetwork || model.localNetworkDenied
        return SetupPage(title: "Couldn't pair", message: message, compact: compact) {
            SetupSymbol(name: "exclamationmark.triangle.fill", style: Light.gold, compact: compact, rendering: .multicolor)
        } content: {
            if network {
                Text(model.localNetworkDenied
                     ? "Local Network is off for Macrophone, so it can't reach your Mac. Turn it on in Settings."
                     : "Still stuck? Make sure Local Network is on for Macrophone.")
                    .font(.footnote).foregroundStyle(Ink.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } buttons: {
            SetupButton("Try Again") { model.resetPairing() }
            if network {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .setupSecondary()
            }
        }
    }

    private var macAppNote: some View {
        Link(destination: Product.website) {
            (Text("No Mac app yet? It's free at ") + Text(Product.macDownloadDisplay).foregroundColor(Light.cyan))
                .font(.footnote)
                .foregroundStyle(Ink.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("No Mac app yet? Get Macrophone for Mac, free, on the website")
    }

    private var networkNote: some View {
        Text("Your iPhone and Mac talk directly over this network. Nothing goes to the internet.")
            .font(.footnote)
            .foregroundStyle(Ink.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }
}
