#if DEBUG
import AppKit
import MacrophoneKit
import SwiftUI

/// Staging hooks for screenshots and headless checks. DEBUG builds only.
///
///   MACROPHONE_FRESH=1              start as a first launch (setup not done)
///   MACROPHONE_SEED_HISTORY=1       sample history (English, Arabic, Hebrew, Japanese, delayed, failed)
///   MACROPHONE_SHOW=<what>          popup-toast | popup-countdown | popup-error | popup-stack | popup-delayed |
///                                   popup-automation | popup-rtl | window-<pane> | setup | setup-paired |
///                                   setup-login | setup-modes | code-approval | diagnostics | profile-editor
///   MACROPHONE_BACKDROP=1           a neutral backdrop under the popup (screenshots never show a real desktop)
///   MACROPHONE_WINDOW_IDS_FILE=path writes {"main":id,"setup":id,"popup":id,"popupFrame":[x,y,w,h]} (top-left points)
///   MACROPHONE_CODE_ANSWER=match|nomatch  answers a code-pairing request after 3 s through the same call the buttons make
///   MACROPHONE_PAIR_URL_FILE=path   writes the live pairing URL (AppModel.beginPairing)
///   MACROPHONE_FORGET=<name>        forgets matching phones (Devices › Forget's call)
///   MACROPHONE_HIDE_ICON=1          hide the menu bar icon (the popup falls back to the top-right corner)
///   MACROPHONE_INSTALL_CLI=1        runs the CLI install at launch
///   MACROPHONE_CLI_DIR=path         install the CLI links there instead of /usr/local/bin
@MainActor
enum DebugHooks {
    static let env = ProcessInfo.processInfo.environment
    private static var backdrop: NSWindow?
    private static var bag: [Any] = []

    /// Returns true when it took over the launch (no default first-run flow).
    static func run(_ app: AppDelegate) -> Bool {
        let model = app.model
        if env["MACROPHONE_FRESH"] == "1" { model.settings.hasCompletedSetup = false }
        if env["MACROPHONE_SEED_HISTORY"] == "1" { seed(model) }
        if let name = env["MACROPHONE_FORGET"] {
            // The same call the Devices pane's Forget button makes.
            for p in model.peers where p.name.contains(name) { model.forget(p) }
        }
        if let answer = env["MACROPHONE_CODE_ANSWER"] {
            let c = model.$codeRequest.sink { req in
                guard req != nil else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { model.answerCode(answer == "match") }
            }
            bag.append(c)
        }
        if let file = env["MACROPHONE_WINDOW_IDS_FILE"] {
            let t = Timer(timeInterval: 0.5, repeats: true) { _ in MainActor.assumeIsolated { writeIDs(app, to: file) } }
            RunLoop.main.add(t, forMode: .common)
            bag.append(t)
        }
        if env["MACROPHONE_INSTALL_CLI"] == "1" {
            // Developer › Install's call (point MACROPHONE_CLI_DIR somewhere harmless).
            print("CLI install: \(CLIInstaller.install() ?? "ok") → \(CLIInstaller.status)")
            fflush(stdout)
        }
        if env["MACROPHONE_HIDE_ICON"] == "1" { app.debugStatusItem.debugHide() }
        guard let show = env["MACROPHONE_SHOW"] else { return false }
        if env["MACROPHONE_BACKDROP"] == "1" { showBackdrop() }

        if show.hasPrefix("window-"), let pane = Pane(rawValue: String(show.dropFirst(7))) {
            app.openMainWindow(pane: pane)
            return true
        }
        switch show {
        case "setup": app.openSetup(.pair)
        case "setup-paired":
            app.openSetup(.pair)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { app.setupNavForDebug?.step = .paired }
        case "setup-login":
            app.openSetup(.pair)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { app.setupNavForDebug?.step = .login }
        case "setup-modes":
            app.openSetup(.pair)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { app.setupNavForDebug?.step = .modes }
        case "code-approval":
            app.openSetup(.pair)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { model.codeRequest = CodeRequest(code: "482 913", phoneName: "Sameer's iPhone") }
        case "diagnostics": app.showDiagnostics()
        case "menu":
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { app.debugStatusItem.openMenu() }
        case "profile-editor":
            app.openMainWindow(pane: .profiles)
        default:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { stagePopup(show, model: model) }
        }
        return true
    }

    // MARK: Popup staging

    static let english = "Refactor the history store so it trims to fifty items on write, and add a test that proves a resend never shows up twice."
    static let short = "Remind me to send Priya the deck before the 3pm sync."

    private static func card(_ text: String, phase: PopupCard.Phase, status: String, delayed: Bool = false) -> PopupCard {
        PopupCard(text: text, source: "Sameer's iPhone", delayed: delayed, phase: phase, status: status)
    }

    static func stagePopup(_ what: String, model: AppModel) {
        let popup = model.popup
        switch what {
        case "popup-toast":
            popup.show(card(short, phase: .copied, status: "Copied"))
        case "popup-countdown":
            let c = card(english, phase: .countdown, status: "Sending to Claude")
            c.note = "Pastes, then presses Return."
            c.remaining = 0.62
            c.onCancel = { c.phase = .cancelled; c.status = "Not pasted"; popup.refresh(c) }
            popup.show(c)
        case "popup-error":
            let c = card(short, phase: .failed, status: "Copied, not pasted")
            let f = PasteFailure.accessibilityMissing
            c.headline = f.title; c.note = f.detail; c.showsSettingsButton = true; c.canRetry = true
            popup.show(c)
        case "popup-secure":
            let c = card(short, phase: .failed, status: "Not pasted")
            let f = PasteFailure.secureField(app: "Safari")
            c.headline = f.title; c.note = f.detail; c.canRetry = true
            popup.show(c)
        case "popup-delayed":
            popup.show(card(english, phase: .copied, status: "Copied · delayed", delayed: true))
        case "popup-automation":
            let c = card(short, phase: .copied, status: "Copied · Log to notes")
            c.automations = [.init(name: "Webhook", state: .ok), .init(name: "Script", state: .running)]
            popup.show(c)
        case "popup-rtl":
            popup.show(card("مرحبا، هذا اختبار للإملاء من الهاتف إلى الماك. يجب أن يظهر النص من اليمين إلى اليسار.", phase: .copied, status: "Copied"))
        case "popup-stack":
            popup.show(card("今日の会議のメモを共有してください。", phase: .copied, status: "Copied"))
            let d = card(short, phase: .done, status: "Pasted into Notes")
            popup.show(d)
            let c = card(english, phase: .countdown, status: "Pasting into Claude")
            c.remaining = 0.4
            popup.show(c)
        default:
            popup.show(card(short, phase: .copied, status: "Copied"))
        }
        // Hold still for the screenshot.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { popup.freeze() }
    }

    // MARK: Backdrop

    private static func showBackdrop() {
        let screen = PopupController.activeScreen()
        let f = NSRect(x: screen.visibleFrame.maxX - 980, y: screen.visibleFrame.maxY - 720, width: 980, height: 720)
        let w = NSWindow(contentRect: f, styleMask: [.borderless], backing: .buffered, defer: false)
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .stationary]
        w.ignoresMouseEvents = true
        w.contentView = NSHostingView(rootView: Backdrop())
        w.orderFrontRegardless()
        backdrop = w
    }

    private struct Backdrop: View {
        var body: some View {
            ZStack {
                LinearGradient(colors: [Color(hex: 0x2B3A67), Color(hex: 0x4E3C78), Color(hex: 0x1F5C6E)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [Color(hex: 0xE9714F, opacity: 0.35), .clear], center: .init(x: 0.8, y: 0.9), startRadius: 0, endRadius: 500)
                // A stand-in document window, so the glass has something to blur.
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 7) { ForEach(0..<3) { _ in Circle().fill(Color.white.opacity(0.35)).frame(width: 11, height: 11) } }
                    ForEach(0..<14) { i in
                        RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.25))
                            .frame(width: CGFloat([520, 470, 560, 300, 510, 420, 540, 380, 500, 260, 530, 450, 410, 330][i]), height: 9)
                    }
                }
                .padding(22)
                .frame(width: 640, height: 420, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: 0xEDEBF2)))
                .offset(x: -120, y: 80)
            }
        }
    }

    // MARK: Seed

    private static func seed(_ model: AppModel) {
        guard model.history.isEmpty else { return }
        let now = Date()
        let samples: [(String, String?, String, Bool, HistoryItem.Outcome, String, TimeInterval, String)] = [
            ("um so refactor the the history store so it trims to fifty items on write and uh add a test that proves a resend never shows up twice",
             english, "Claude prompt", false, .pasted, "Pasted into Claude and sent", 120, "en-US"),
            ("remind me to send priya the deck before the three pm sync", short, "Clipboard", false, .copied, "Copied to clipboard", 900, "en-US"),
            ("مرحبا، هذا اختبار للإملاء من الهاتف إلى الماك.", nil, "Clipboard", false, .copied, "Copied to clipboard", 3600, "ar-SA"),
            ("שלום, זו בדיקה של הכתבה מהאייפון למק.", nil, "Clipboard", true, .copied, "Copied — delayed items are never pasted automatically", 7200, "he-IL"),
            ("今日の会議のメモを共有してください。", nil, "Quick note", false, .copied, "Copied to clipboard", 20000, "ja-JP"),
            ("write a function that sorts a list of users by last name", "Write a function that sorts a list of users by last name.",
             "Claude prompt", false, .failed, "Not pasted — a password field is active", 90000, "en-US"),
        ]
        for s in samples.reversed() {
            let d = Dictation(createdAt: now.addingTimeInterval(-s.6 - 4), raw: s.0, cleaned: s.1, cleanupLevel: s.1 == nil ? .off : .medium,
                              language: s.7, profileName: s.2, sourceDevice: "Sameer's iPhone")
            model.record(HistoryItem(dictation: d, receivedAt: now.addingTimeInterval(-s.6), delayed: s.3, profileName: s.2,
                                     outcome: s.4, detail: s.5))
        }
    }

    // MARK: Window ids

    private static func writeIDs(_ app: AppDelegate, to file: String) {
        var out: [String: Any] = [:]
        if let w = app.debugMainWindow, w.isVisible { out["main"] = w.windowNumber }
        if let w = app.debugSetupWindow, w.isVisible { out["setup"] = w.windowNumber }
        if let w = app.debugDiagnosticsWindow, w.isVisible { out["diagnostics"] = w.windowNumber }
        if let n = app.model.popup.panelWindowNumber, let f = app.model.popup.panelFrame {
            out["popup"] = n
            let primary = NSScreen.screens.first?.frame.height ?? 0
            out["popupFrame"] = [f.minX, primary - f.maxY, f.width, f.height]
        }
        if let f = app.debugStatusItem.visibleFrame {
            let primary = NSScreen.screens.first?.frame.height ?? 0
            out["statusItem"] = [f.minX, primary - f.maxY, f.width, f.height]
        } else {
            out["statusItem"] = "hidden"
        }
        if let d = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]) {
            try? d.write(to: URL(fileURLWithPath: file))
        }
    }
}
#endif
