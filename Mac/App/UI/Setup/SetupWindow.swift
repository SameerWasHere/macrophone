import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import MacrophoneKit
import SwiftUI

enum SetupStep: Equatable { case pair, paired, login, modes }

final class SetupNav: ObservableObject {
    @Published var step: SetupStep = .pair
    /// First run walks through login + modes after pairing; "Pair iPhone…" just pairs.
    @Published var firstRun = false
}

@MainActor
final class SetupWindowController: NSWindowController, NSWindowDelegate {
    let nav = SetupNav()
    var onClose: () -> Void = {}
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 660),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = "Set Up Macrophone"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = Ink.groundNS
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        super.init(window: w)
        nav.firstRun = !model.settings.hasCompletedSetup
        w.contentView = NSHostingView(rootView: SetupView(model: model, nav: nav, settings: model.settings,
                                                          finish: { [weak self] in self?.finish() }))
        w.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func go(_ step: SetupStep) {
        nav.step = step
        if step == .pair { model.beginPairing() }
    }

    private func finish() {
        model.settings.hasCompletedSetup = true
        close()
    }

    func windowWillClose(_ notification: Notification) { onClose() }
}

struct SetupView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var nav: SetupNav
    @ObservedObject var settings: Settings
    var finish: () -> Void
    @State private var openAtLogin = true

    var body: some View {
        ZStack {
            Ink.ground.ignoresSafeArea()
            // A low glow behind the page, like the light a filament throws.
            RadialGradient(colors: [Light.teal.opacity(0.10), .clear], center: .init(x: 0.5, y: 0.18), startRadius: 0, endRadius: 360)
                .ignoresSafeArea()
            Group {
                switch nav.step {
                case .pair: PairStep(model: model, skip: skip)
                case .paired: PairedStep(model: model, next: { nav.firstRun ? (nav.step = .login) : finish() }, firstRun: nav.firstRun)
                case .login: LoginStep(openAtLogin: $openAtLogin, next: {
                    model.setLaunchAtLogin(openAtLogin)
                    nav.step = .modes
                })
                case .modes: ModesStep(model: model, settings: settings, done: finish)
                }
            }
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))

            if let req = model.codeRequest {
                Color.black.opacity(0.55).ignoresSafeArea().transition(.opacity)
                CodeApproval(request: req, answer: { model.answerCode($0) })
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
            }
        }
        .frame(width: 560, height: 660)
        .preferredColorScheme(.dark)
        .animation(Motion.reduceMotion ? .easeInOut(duration: 0.2) : Motion.settle, value: nav.step)
        .animation(Motion.reduceMotion ? .easeInOut(duration: 0.2) : Motion.snap, value: model.codeRequest)
        .onChange(of: model.justPaired) { _, p in
            if p != nil { nav.step = .paired }
        }
    }

    private func skip() {
        if nav.firstRun { nav.step = .login } else { finish() }
    }
}

// MARK: Steps

struct PairStep: View {
    @ObservedObject var model: AppModel
    var skip: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 40)
            Text("Pair your iPhone").font(Typeface.serif(30)).foregroundStyle(Ink.ink)
            Text("Open Macrophone on your iPhone and scan this code.")
                .font(.system(size: 13.5)).foregroundStyle(Ink.secondary)
                .padding(.top, 8)

            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Ink.ink)
                    .shadow(color: Light.teal.opacity(0.25), radius: 30)
                if let invite = model.invite {
                    QRCodeView(text: invite.url.absoluteString)
                        .padding(18)
                        .accessibilityLabel("Pairing code. Scan it with Macrophone on your iPhone.")
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 252, height: 252)
            .padding(.top, 30)

            VStack(spacing: 12) {
                FilamentView(peak: 0.32, thick: 1.6, glow: 0.55)
                    .frame(width: 180, height: 22)
                HStack(spacing: 6) {
                    PulseDot(color: NSColor(srgbRed: 0.345, green: 0.725, blue: 0.871, alpha: 1))
                        .frame(width: 21, height: 21)
                    Kicker("Waiting for your iPhone", color: Light.cyan, size: 11)
                }
            }
            .padding(.top, 26)

            Text("No camera handy? On your iPhone, tap “Use a code instead” — this Mac will show a code to compare.")
                .font(.system(size: 12)).foregroundStyle(Ink.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)
                .padding(.top, 22)

            Spacer(minLength: 20)
            HStack {
                Text("Need the iPhone app? It's free on the App Store — search for Macrophone.")
                    .font(.system(size: 11.5)).foregroundStyle(Ink.tertiary)
                Spacer()
                Button("Set Up Later", action: skip).buttonStyle(.borderless).foregroundStyle(Ink.secondary)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 22)
        }
    }
}

struct PairedStep: View {
    @ObservedObject var model: AppModel
    var next: () -> Void
    var firstRun: Bool
    @State private var tick = false
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    /// iOS hides device names, so a phone often says just "iPhone": offer to name it here.
    private var askForName: Bool { model.justPaired.map { AppModel.isGenericName($0.name) } ?? false }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            ZStack {
                Circle().fill(Light.mint.opacity(0.14)).frame(width: 92, height: 92)
                Circle().strokeBorder(Light.mint.opacity(0.5), lineWidth: 1.5).frame(width: 92, height: 92)
                Image(systemName: "checkmark").font(.system(size: 36, weight: .semibold)).foregroundStyle(Light.mint)
                    .scaleEffect(tick ? 1 : 0.2).opacity(tick ? 1 : 0)
            }
            .accessibilityHidden(true)
            .onAppear { withAnimation(Motion.reduceMotion ? .easeOut(duration: 0.2) : Motion.pop.delay(0.1)) { tick = true } }
            Text("Paired").font(Typeface.serif(30)).foregroundStyle(Ink.ink).padding(.top, 26)
            Text(askForName ? "Your iPhone can now send to this Mac. Try a dictation — it'll land on your clipboard."
                            : "\(model.justPaired.map(model.displayName) ?? "Your iPhone") can now send to this Mac. Try a dictation — it'll land on your clipboard.")
                .font(.system(size: 13.5)).foregroundStyle(Ink.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)
                .padding(.top, 8)
            if askForName {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Name this iPhone").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Ink.secondary)
                    TextField("Name", text: $name, prompt: Text(AppModel.suggestedPhoneName))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13))
                        .focused($nameFocused)
                        .onSubmit(done)
                        .accessibilityLabel("Name this iPhone")
                    Text("iOS only tells this Mac “iPhone”. The name shows in the menu, the popup and History.")
                        .font(.system(size: 11.5)).foregroundStyle(Ink.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: 320)
                .padding(.top, 26)
                .onAppear {
                    name = AppModel.suggestedPhoneName
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { nameFocused = true }
                }
            }
            Spacer()
            Button(firstRun ? "Continue" : "Done", action: done)
                .buttonStyle(PillButtonStyle(tint: Ink.ink, filled: true))
                .keyboardShortcut(.defaultAction)
                .padding(.bottom, 32)
        }
    }

    private func done() {
        if askForName, let p = model.justPaired { model.rename(p, to: name) }
        next()
    }
}

struct LoginStep: View {
    @Binding var openAtLogin: Bool
    var next: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(systemName: "power").font(.system(size: 34, weight: .light)).foregroundStyle(Light.cyan)
            Text("Open at login?").font(Typeface.serif(30)).foregroundStyle(Ink.ink).padding(.top, 22)
            Text("Macrophone lives in your menu bar and can only receive while it's running.")
                .font(.system(size: 13.5)).foregroundStyle(Ink.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 380).padding(.top, 8)
            Toggle("Open Macrophone when I log in", isOn: $openAtLogin)
                .toggleStyle(.switch)
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 18).padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Ink.raised))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Ink.line, lineWidth: 1))
                .padding(.top, 28)
            Spacer()
            Button("Continue", action: next)
                .buttonStyle(PillButtonStyle(tint: Ink.ink, filled: true))
                .keyboardShortcut(.defaultAction)
                .padding(.bottom, 32)
        }
    }
}

struct ModesStep: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: Settings
    var done: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text("How dictations arrive").font(Typeface.serif(28)).foregroundStyle(Ink.ink).padding(.top, 52)
            Text("Pick one. Change it any time from the menu bar or in Delivery.")
                .font(.system(size: 13.5)).foregroundStyle(Ink.secondary).padding(.top, 8)
            VStack(spacing: 10) {
                ForEach(DeliveryMode.allCases) { m in
                    ModeCard(mode: m, selected: settings.deliveryMode == m) {
                        if m == .autoPaste && !Paster.isTrusted { Paster.requestTrust() }
                        settings.deliveryMode = m
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 26)
            Text("Profiles send straight into an app — Claude, ChatGPT, Cursor, or the Terminal tab running Claude Code — and press Return for you. Pick one on your iPhone, or add more in Profiles.")
                .font(.system(size: 12)).foregroundStyle(Ink.tertiary)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 18)
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: model.menuBarIconHidden ? "menubar.dock.rectangle" : "keyboard")
                    .foregroundStyle(Light.cyan)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text(hotkeyLine)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Light.cyan.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Light.cyan.opacity(0.2), lineWidth: 1))
            .padding(.horizontal, 32)
            .padding(.top, 14)
            .onDisappear { if model.menuBarIconHidden { settings.toldAboutHiddenIcon = true } }
            Spacer()
            Button("Done", action: done)
                .buttonStyle(PillButtonStyle(tint: Ink.ink, filled: true))
                .keyboardShortcut(.defaultAction)
                .padding(.bottom, 32)
        }
    }
}

extension ModesStep {
    private var hotkeyLine: String {
        let key = settings.hotkey
        if model.menuBarIconHidden {
            return key.enabled
                ? "Your menu bar is full, so Macrophone's icon is hidden. Press \(key.display) anywhere to open Macrophone, or open it from Spotlight."
                : "Your menu bar is full, so Macrophone's icon is hidden. Open Macrophone from Spotlight or Finder."
        }
        return key.enabled
            ? "Macrophone lives in your menu bar. If the icon is ever hidden, press \(key.display) anywhere to open it."
            : "Macrophone lives in your menu bar. If the icon is ever hidden, open it from Spotlight or Finder."
    }
}

/// "Does your iPhone show 482 913?"
struct CodeApproval: View {
    let request: CodeRequest
    var answer: (Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Kicker("Pairing request", color: Light.cyan, size: 11)
            Text(AppModel.isGenericName(request.phoneName) ? "Does your iPhone show this code?" : "Does “\(request.phoneName)” show this code?")
                .font(Typeface.serif(22)).foregroundStyle(Ink.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
            Text(request.code)
                .font(.system(size: 46, weight: .semibold, design: .monospaced))
                .tracking(4)
                .foregroundStyle(Ink.ink)
                .padding(.top, 14)
                .accessibilityLabel(request.code.map { String($0) }.joined(separator: " "))
            Text("Only approve if the numbers are exactly the same.")
                .font(.system(size: 12)).foregroundStyle(Ink.tertiary)
                .padding(.top, 10)
            HStack(spacing: 12) {
                Button("Don't Match") { answer(false) }
                    .buttonStyle(PillButtonStyle(tint: Light.rose, filled: false))
                    .keyboardShortcut(.cancelAction)
                Button("They Match") { answer(true) }
                    .buttonStyle(PillButtonStyle(tint: Ink.ink, filled: true))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 24)
        }
        .padding(.horizontal, 34).padding(.vertical, 30)
        .frame(width: 400)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Ink.raised))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Ink.lineStrong, lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 30, y: 14)
    }
}

/// A QR code drawn module-for-module, so it's crisp at any size.
struct QRCodeView: View {
    let text: String
    var body: some View {
        if let cg = Self.render(text) {
            Image(decorative: cg, scale: 1)
                .interpolation(.none)
                .resizable()
                .aspectRatio(1, contentMode: .fit)
        }
    }

    static func render(_ text: String) -> CGImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage else { return nil }
        // Dark modules on the light plate (phone cameras read this way best).
        let tinted = out.applyingFilter("CIFalseColor", parameters: [
            "inputColor0": CIColor(red: 0.02, green: 0.024, blue: 0.051),
            "inputColor1": CIColor(red: 0.957, green: 0.949, blue: 0.98),
        ])
        return CIContext().createCGImage(tinted, from: tinted.extent)
    }
}
