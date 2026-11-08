import AppKit
import Combine
import CoreImage
import CoreImage.CIFilterBuiltins
import MacrophoneKit
import SwiftUI

/// What the setup window was opened for (Nov 7 2026).
enum SetupMode: Equatable {
    /// The first launch: pair · permissions · away from home · all set — each skipped when it's
    /// already done (a phone paired before, the grants already on), so it never asks twice.
    case firstRun
    /// Pair Your iPhone… / Pair Another iPhone… (the menu, Devices): just the code, then Done.
    case pair
    /// A phone asked to see the Mac's permissions ("Open Macrophone on my Mac").
    case permissions
    /// Devices or the setup's own page: Tailscale, step by step.
    case away
}

/// The pages. "Paired" follows "pair" when a phone pairs; "done" ends a first run.
enum SetupStep: Equatable { case pair, paired, permissions, away, done }

final class SetupNav: ObservableObject {
    @Published var mode: SetupMode = .firstRun
    @Published var step: SetupStep = .pair
    /// The pages behind this one, for Back (pairing is never one of them — it's done or skipped).
    @Published var history: [SetupStep] = []
    var firstRun: Bool { mode == .firstRun }
}

@MainActor
final class SetupWindowController: NSWindowController, NSWindowDelegate {
    let nav = SetupNav()
    var onClose: () -> Void = {}
    private let model: AppModel
    private var bag: Set<AnyCancellable> = []

    static let size = NSSize(width: 620, height: 680)

    init(model: AppModel) {
        self.model = model
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = "Set Up Macrophone"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        // Like Setup Assistant: light or dark as the app is (General › Appearance, else the system's).
        w.backgroundColor = .windowBackgroundColor
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        super.init(window: w)
        AppMenu.installIfNeeded()
        w.contentView = NSHostingView(rootView: SetupView(model: model, nav: nav, settings: model.settings, controller: self))
        w.delegate = self
        // The code is open only while it's on screen.
        nav.$step.removeDuplicates().dropFirst().sink { [weak self] step in
            guard let self else { return }
            if step != .pair, step != .paired { self.model.endPairing() }
        }.store(in: &bag)
    }

    required init?(coder: NSCoder) { fatalError() }


    /// Starts the window over for `mode`, on its first page that still needs doing.
    func start(_ mode: SetupMode) {
        nav.mode = mode
        nav.history = []
        let first: SetupStep
        switch mode {
        case .firstRun: first = model.peers.isEmpty ? .pair : nextStep(after: .pair)
        case .pair: first = .pair
        case .permissions: first = .permissions
        case .away: first = .away
        }
        show(first)
    }

    private func show(_ step: SetupStep) {
        nav.step = step
        if step == .pair { model.beginPairing() }
    }

    /// The first-run order, skipping what's already done. "done" is always the last page.
    private func nextStep(after step: SetupStep) -> SetupStep {
        let order: [SetupStep] = [.pair, .permissions, .away, .done]
        let from = step == .paired ? .pair : step
        guard let i = order.firstIndex(of: from) else { return .done }
        return order.dropFirst(i + 1).first { !isDone($0) } ?? .done
    }

    private func isDone(_ step: SetupStep) -> Bool {
        switch step {
        case .pair, .paired: return !model.peers.isEmpty
        case .permissions: return model.permissions.accessibility && model.permissions.screenRecording
        case .away: return model.settings.remoteAccess && model.tailscale.state.connected
        case .done: return false
        }
    }

    /// Continue: the next page of a first run; any other run ends here.
    func next() {
        guard nav.firstRun, nav.step != .done else { return finish() }
        if nav.step != .pair, nav.step != .paired { nav.history.append(nav.step) }
        show(nextStep(after: nav.step))
    }

    func back() {
        guard let previous = nav.history.popLast() else { return }
        show(previous)
    }

    func finish() { close() }

    /// Done, Set Up Later or the close button: the first run is over either way — the window
    /// never opens by itself again (the menu and Devices pair another phone; General sets up again).
    func windowWillClose(_ notification: Notification) {
        model.settings.hasCompletedSetup = true
        onClose()
    }
}

struct SetupView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var nav: SetupNav
    @ObservedObject var settings: Settings
    let controller: SetupWindowController

    var body: some View {
        ZStack {
            Group {
                switch nav.step {
                case .pair: PairPage(model: model, nav: nav, controller: controller)
                case .paired: PairedPage(model: model, nav: nav, controller: controller)
                case .permissions: PermissionsPage(monitor: model.permissions, nav: nav, controller: controller)
                case .away: AwayPage(model: model, tailscale: model.tailscale, settings: settings, nav: nav, controller: controller)
                case .done: AllSetPage(model: model, settings: settings, nav: nav, controller: controller)
                }
            }
            .transition(Motion.reduceMotion ? .opacity
                        : .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
        }
        .frame(width: SetupWindowController.size.width, height: SetupWindowController.size.height)
        .animation(Motion.reduceMotion ? .easeInOut(duration: 0.2) : Motion.settle, value: nav.step)
        .onChange(of: model.justPaired) { _, p in
            if p != nil { nav.step = .paired }
        }
        .sheet(item: Binding(get: { model.codeRequest }, set: { if $0 == nil, model.codeRequest != nil { model.answerCode(false) } })) { req in
            CodeApproval(request: req, answer: { model.answerCode($0) })
        }
    }
}

/// Back, when there's a page behind this one.
private struct BackButton: View {
    @ObservedObject var nav: SetupNav
    let controller: SetupWindowController
    var body: some View {
        if !nav.history.isEmpty {
            Button("Back") { controller.back() }
                .keyboardShortcut(.cancelAction)
        }
    }
}

// MARK: Pair

struct PairPage: View {
    @ObservedObject var model: AppModel
    @ObservedObject var nav: SetupNav
    let controller: SetupWindowController

    /// Another phone, or the first one: the words say which.
    private var another: Bool { !model.peers.isEmpty }

    var body: some View {
        SetupPage(title: another ? "Pair another iPhone" : "Pair your iPhone",
                  subtitle: "Open Macrophone on your iPhone and scan this code.") {
            VStack(spacing: 18) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.white)
                        .shadow(color: .black.opacity(0.12), radius: 14, y: 4)
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5)
                    if let invite = model.invite {
                        QRCodeView(text: invite.url.absoluteString)
                            .padding(16)
                            .accessibilityLabel("Pairing code. Scan it with Macrophone on your iPhone.")
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(width: 236, height: 236)
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for your iPhone…").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                SetupFootnote("No camera? On your iPhone, tap “Use a code instead” and compare the numbers this Mac shows.")
                    .padding(.top, 4)
            }
        } footer: {
            if !another {
                Text("Macrophone for iPhone is free on the App Store.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            if nav.firstRun {
                Button("Set Up Later") { controller.next() }
            } else {
                Button("Cancel") { controller.finish() }.keyboardShortcut(.cancelAction)
            }
        }
    }
}

struct PairedPage: View {
    @ObservedObject var model: AppModel
    @ObservedObject var nav: SetupNav
    let controller: SetupWindowController
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    /// iOS hides device names, so a phone often says just "iPhone": offer to name it here.
    private var askForName: Bool { model.justPaired.map { AppModel.isGenericName($0.name) } ?? false }

    var body: some View {
        SetupPage(symbol: "checkmark.circle.fill", symbolColor: .green, title: "Paired",
                  subtitle: askForName ? "Your iPhone can now send to this Mac."
                                       : "\(model.justPaired.map(model.displayName) ?? "Your iPhone") can now send to this Mac.") {
            if askForName {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Name this iPhone").font(.system(size: 13, weight: .semibold))
                    TextField("Name", text: $name, prompt: Text(AppModel.suggestedPhoneName))
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.large)
                        .focused($nameFocused)
                        .onSubmit(done)
                        .accessibilityLabel("Name this iPhone")
                    Text("iOS only tells this Mac “iPhone”. The name shows in the menu and in History.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: 340)
                .onAppear {
                    name = AppModel.suggestedPhoneName
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { nameFocused = true }
                }
            }
        } footer: {
            Spacer()
            Button(nav.firstRun ? "Continue" : "Done", action: done)
                .keyboardShortcut(.defaultAction)
        }
    }

    private func done() {
        if askForName, let p = model.justPaired { model.rename(p, to: name) }
        controller.next()
    }
}

// MARK: Permissions

/// What Macrophone needs to be allowed to do, live: each check lands the moment it's switched on
/// in System Settings (the monitor looks every second while this is up).
struct PermissionsPage: View {
    @ObservedObject var monitor: PermissionsMonitor
    @ObservedObject var nav: SetupNav
    let controller: SetupWindowController

    private var both: Bool { monitor.accessibility && monitor.screenRecording }

    var body: some View {
        SetupPage(symbol: both ? "checkmark.shield.fill" : "lock.shield", symbolColor: both ? .green : .accentColor,
                  title: "Allow Macrophone to work your Mac",
                  subtitle: "Your iPhone clicks, types and shows windows here, so macOS asks you to allow it. Each button opens the right place in System Settings.") {
            VStack(spacing: 14) {
                CheckList {
                    CheckRow(symbol: "hand.raised", title: "Accessibility",
                             detail: monitor.accessibility ? "Allowed. Dictations paste into the app you pick, and your taps and keys reach this Mac."
                                                           : "To paste dictations into the app you pick, and to pass on your taps and keys.",
                             done: monitor.accessibility, next: !monitor.accessibility) {
                        if !monitor.accessibility {
                            GuideButton("Open Settings", prominent: true, help: "Opens Privacy & Security › Accessibility. Turn on Macrophone there.",
                                        action: monitor.openAccessibility)
                        }
                    }
                    CheckDivider()
                    CheckRow(symbol: "rectangle.dashed.badge.record", title: "Screen Recording",
                             detail: screenDetail, detailIsWarning: monitor.screenRecordingAsked && !monitor.screenRecording,
                             done: monitor.screenRecording, next: monitor.accessibility && !monitor.screenRecording) {
                        if !monitor.screenRecording {
                            GuideButton("Open Settings", prominent: monitor.accessibility, help: "Opens Privacy & Security › Screen Recording. Turn on Macrophone there.",
                                        action: monitor.openScreenRecording)
                        }
                    }
                }
                .onAppear { monitor.viewerAppeared() }
                .onDisappear { monitor.viewerGone() }
                SetupFootnote(both ? "You can change these any time in General › Permissions."
                                   : "You can do this later in General › Permissions. Until then, dictations are copied to the clipboard.")
            }
        } footer: {
            BackButton(nav: nav, controller: controller)
            Spacer()
            Button(nav.firstRun ? "Continue" : "Done") { controller.next() }
                .keyboardShortcut(.defaultAction)
        }
    }

    private var screenDetail: String {
        if monitor.screenRecording { return "Allowed. Your iPhone can show the window you pick, only while you watch it." }
        if monitor.screenRecordingAsked { return "Turned it on and it still says off? Quit Macrophone and open it again — macOS needs that once." }
        return "To show a window on your iPhone — only the one you pick, only while you watch it."
    }
}

// MARK: Away from home

struct AwayPage: View {
    @ObservedObject var model: AppModel
    @ObservedObject var tailscale: TailscaleMonitor
    @ObservedObject var settings: Settings
    @ObservedObject var nav: SetupNav
    let controller: SetupWindowController
    /// Set Up was pressed (or something's already under way): the steps show.
    @State private var settingUp = false

    private var showSteps: Bool { settingUp || !nav.firstRun || tailscale.state.installed || settings.remoteAccess }

    var body: some View {
        SetupPage(symbol: "globe", title: "Use it away from home",
                  subtitle: showSteps ? "With Tailscale, your iPhone reaches this Mac from anywhere. Each step checks itself."
                                      : "Tailscale links your iPhone and this Mac wherever you are, not just on your Wi-Fi.") {
            if showSteps {
                AwayGuide(model: model)
                    .transition(.opacity)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    feature("antenna.radiowaves.left.and.right", "From anywhere",
                            "Dictate and see your Mac on cellular, at work or on any Wi-Fi.")
                    feature("lock", "Private",
                            "Through your own Tailscale account. Macrophone has no server, and only iPhones paired here can connect.")
                    feature("checkmark.seal", "Free",
                            "Tailscale is free for personal use. This page walks you through it, one step at a time.")
                }
                .frame(width: 400, alignment: .leading)
                .padding(.top, 6)
            }
        } footer: {
            BackButton(nav: nav, controller: controller)
            Spacer()
            if showSteps {
                Button(nav.firstRun ? "Continue" : "Done") { controller.next() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Not Now") { controller.next() }
                Button("Set Up") { withAnimation(Motion.reduceMotion ? nil : Motion.settle) { settingUp = true } }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear { tailscale.refresh() }
    }

    private func feature(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: All set

struct AllSetPage: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: Settings
    @ObservedObject var nav: SetupNav
    let controller: SetupWindowController
    @State private var openAtLogin = true

    var body: some View {
        SetupPage(symbol: "checkmark.circle.fill", symbolColor: .green, title: "You're all set",
                  subtitle: "Dictate on your iPhone and the words land on this Mac. Pick where they go on your iPhone, under Send to.") {
            VStack(alignment: .leading, spacing: 16) {
                Toggle(isOn: $openAtLogin) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Open Macrophone when I log in").font(.system(size: 13))
                        Text("It can only receive while it's running.").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: model.menuBarIconHidden ? "menubar.dock.rectangle" : "menubar.arrow.up.rectangle")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 18)
                        .accessibilityHidden(true)
                    Text(menuBarLine)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: 380, alignment: .leading)
            .onAppear { openAtLogin = settings.hasCompletedSetup ? model.launchAtLogin : true }
            .onDisappear { if model.menuBarIconHidden { settings.toldAboutHiddenIcon = true } }
        } footer: {
            BackButton(nav: nav, controller: controller)
            Spacer()
            Button("Done") {
                if openAtLogin != model.launchAtLogin { model.setLaunchAtLogin(openAtLogin) }
                controller.finish()
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    private var menuBarLine: String {
        let key = settings.hotkey
        if model.menuBarIconHidden {
            return key.enabled
                ? "Your menu bar is full, so Macrophone's icon is hidden. Press \(key.display) anywhere to open it, or open it from Spotlight."
                : "Your menu bar is full, so Macrophone's icon is hidden. Open it from Spotlight or Finder."
        }
        return key.enabled
            ? "Macrophone lives in your menu bar. Press \(key.display) anywhere to open its window."
            : "Macrophone lives in your menu bar. Click its icon for Send to, Recent and Settings."
    }
}

// MARK: Pairing by code

/// "Does your iPhone show 482 913?" — a sheet over the setup window.
struct CodeApproval: View {
    let request: CodeRequest
    var answer: (Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                .font(.system(size: 36))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text(AppModel.isGenericName(request.phoneName) ? "Does your iPhone show this code?" : "Does “\(request.phoneName)” show this code?")
                .font(.system(size: 17, weight: .bold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
            Text(request.code)
                .font(.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit())
                .tracking(3)
                .padding(.top, 12)
                .accessibilityLabel(request.code.map { String($0) }.joined(separator: " "))
            Text("Only pair if the numbers are exactly the same.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .padding(.top, 8)
            HStack(spacing: 10) {
                Button("Don't Pair") { answer(false) }
                    .keyboardShortcut(.cancelAction)
                    .frame(maxWidth: .infinity)
                Button("Pair") { answer(true) }
                    .keyboardShortcut(.defaultAction)
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .padding(.top, 22)
        }
        .padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 20)
        .frame(width: 340)
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
            "inputColor1": CIColor(red: 1, green: 1, blue: 1),
        ])
        return CIContext().createCGImage(tinted, from: tinted.extent)
    }
}
