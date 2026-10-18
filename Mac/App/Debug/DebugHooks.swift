#if DEBUG
import AppKit
import MacrophoneKit
import SwiftUI

/// Staging hooks for screenshots and headless checks. DEBUG builds only.
///
///   MACROPHONE_FRESH=1              start as a first launch (setup not done)
///   MACROPHONE_SEED_HISTORY=1       sample history (English, Arabic, Hebrew, Japanese, delayed, failed)
///   MACROPHONE_SHOW=<what>          popup-toast | popup-countdown | popup-error | popup-secure | popup-stack |
///                                   popup-delayed | popup-rtl | popup-sent | popup-not-sent | popup-not-open |
///                                   popup-window-gone | popup-nowhere | popup-composer | popup-prefix |
///                                   window-<pane> | setup | setup-paired | setup-paired-generic | setup-login |
///                                   setup-modes | code-approval | diagnostics | menu
///   MACROPHONE_WINDOW_SIZE=WxH      the main window's content size (window-<pane> only)
///   MACROPHONE_POPUP_ON_ICON=1      the popup hangs under the icon on its own display (not the display in use)
///   MACROPHONE_BACKDROP=1           a neutral backdrop under the popup (screenshots never show a real desktop)
///   MACROPHONE_WINDOW_IDS_FILE=path writes {"main":id,"setup":id,"popup":id,"popupFrame":[x,y,w,h]} (top-left points)
///   MACROPHONE_CODE_ANSWER=match|nomatch  answers a code-pairing request after 3 s through the same call the buttons make
///   MACROPHONE_PAIR_URL_FILE=path   writes the live pairing URL (AppModel.beginPairing)
///   MACROPHONE_PAIR_HEADLESS=1      opens pairing at launch with no window (for mpctl)
///   MACROPHONE_FORGET=<name>        forgets matching phones (Devices › Forget's call)
///   MACROPHONE_HIDE_ICON=1          hide the menu bar icon (the popup falls back to the top-right corner)
///   MACROPHONE_FAKE_PEERS=a|b*|c>d  stand-in phones for screenshots: * = connected, "iPhone>Sameer's iPhone" = a
///                                   phone that calls itself "iPhone", renamed on this Mac. Empty = never paired.
///   MACROPHONE_FAKE_LISTENER=failed the network listener failed (Local Network blocked)
///   MACROPHONE_INSTALL_CLI=1        runs the CLI install at launch
///   MACROPHONE_CLI_DIR=path         install the CLI links there instead of /usr/local/bin
///   MACROPHONE_INSTANCE=<name>      a debug copy with its own settings, folder, pairing keys and identity (AppPaths)
///   Distributed notification "com.sameer.macrophone.debug.openMenu" opens the menu bar menu.
///   MACROPHONE_TARGETS_DEBUG=1      print every target scan (timing, what was found) to stdout
///   MACROPHONE_WATCH_TIMING=1       print each watched picture's or video frame's stages in milliseconds (WatchService)
///   Simulated dictations (the same call the phone link makes): post the distributed notification
///   "com.sameer.macrophone.debug.dictate" with object = JSON {"text", "target"?: "clipboard|front|<bundle id>",
///   "window"?: "<window key>", "send"?: bool, "delayed"?: bool, "level"?: "off|light|medium|heavy|custom"}.
///   No target = this Mac's Send to.
///   "com.sameer.macrophone.debug.choose" with object = JSON {"target": "clipboard|front|<bundle id>", "window"?, "send"?}
///   changes Send to on this Mac through AppModel.choose — the call the menu and the window make.
@MainActor
enum DebugHooks {
    static let env = ProcessInfo.processInfo.environment
    private static var backdrop: NSWindow?
    private static var bag: [Any] = []

    /// Returns true when it took over the launch (no default first-run flow).
    static func run(_ app: AppDelegate) -> Bool {
        let model = app.model
        listenForSimulatedDictations(model)
        // Make an app's front window a chat waiting for its answer, as a dictation sent there does —
        // without typing anything (ReplyWatcher's live test). The notification's object: a bundle id.
        bag.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.sameer.macrophone.debug.engage"),
                                                                       object: nil, queue: .main) { n in
            guard let bid = n.object as? String,
                  let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first?.processIdentifier,
                  let w = WindowServer.appWindows().filter({ $0.pid == pid }).min(by: { $0.z < $1.z }) else { return }
            MainActor.assumeIsolated { model.replies.engaged(windowID: w.id, bundleID: bid) }
            model.log.add("debug: engaged \(bid)#\(w.id)")
        })
        // Open the menu bar menu, as a click on the icon does (screenshots; keyboard drives it).
        bag.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.sameer.macrophone.debug.openMenu"),
                                                                       object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { app.debugStatusItem.openMenu() }
        })
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
        if let spec = env["MACROPHONE_FAKE_PEERS"] { stagePeers(spec, model: model) }
        if env["MACROPHONE_FAKE_LISTENER"] == "failed" { model.debugListenerFailed() }
        // Pair a stand-in phone (mpctl) without opening any window: the URL goes to
        // MACROPHONE_PAIR_URL_FILE.
        if env["MACROPHONE_PAIR_HEADLESS"] == "1" { model.beginPairing() }
        guard let show = env["MACROPHONE_SHOW"] else { return false }
        if env["MACROPHONE_BACKDROP"] == "1" { showBackdrop() }

        if show.hasPrefix("window-"), let pane = Pane(rawValue: String(show.dropFirst(7))) {
            app.openMainWindow(pane: pane)
            // MACROPHONE_WINDOW_SIZE=780x520: check a pane at the window's smallest size.
            if let size = env["MACROPHONE_WINDOW_SIZE"]?.split(separator: "x").compactMap({ Double($0) }), size.count == 2,
               let w = app.debugMainWindow {
                w.setContentSize(NSSize(width: size[0], height: size[1]))
            }
            return true
        }
        switch show {
        case "setup": app.openSetup(.pair)
        case "setup-paired":
            app.openSetup(.pair)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { app.setupNavForDebug?.step = .paired }
        case "setup-paired-generic":
            app.openSetup(.pair)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                app.setupNavForDebug?.firstRun = true
                model.debugJustPaired(PairedPeer(id: UUID(), name: "iPhone"))
            }
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
        case "popup-rtl":
            popup.show(card("مرحبا، هذا اختبار للإملاء من الهاتف إلى الماك. يجب أن يظهر النص من اليمين إلى اليسار.", phase: .copied, status: "Copied"))
        case "popup-stack":
            popup.show(card("今日の会議のメモを共有してください。", phase: .copied, status: "Copied"))
            let d = card(short, phase: .done, status: "Pasted into Notes")
            popup.show(d)
            let c = card(english, phase: .countdown, status: "Pasting into Claude")
            c.remaining = 0.4
            popup.show(c)
        case "popup-sent":
            let c = card("Add exponential backoff to the upload client's retries, and write a test that covers the timeout case.",
                         phase: .done, status: "Sent to Claude")
            popup.show(c)
        case "popup-not-sent":
            let c = card(english, phase: .done, status: "Pasted into Claude")
            c.caution = true
            c.note = "Pressed Return, but it's still in the message box — Claude may still be answering. Press Return when it's ready."
            popup.show(c)
        case "popup-not-open", "popup-window-missing":
            let c = card(english, phase: .failed, status: "Copied instead")
            let f = PasteFailure.appNotOpen(name: "Claude")
            c.headline = f.title; c.note = f.detail; c.canRetry = true
            popup.show(c)
        case "popup-window-gone":
            let c = card(english, phase: .failed, status: "Copied instead")
            let f = PasteFailure.windowGone(app: "Terminal", window: "claude ~/app")
            c.headline = f.title; c.note = f.detail; c.canRetry = true
            popup.show(c)
        case "popup-nowhere":
            let c = card(short, phase: .failed, status: "Copied instead")
            let f = PasteFailure.nowhereToType(app: "Finder")
            c.headline = f.title; c.note = f.detail; c.canRetry = true
            popup.show(c)
        case "popup-composer":
            let c = card(english, phase: .failed, status: "Not sent")
            let f = PasteFailure.notLanded(app: "Claude")
            c.headline = f.title; c.note = f.detail; c.canRetry = true
            popup.show(c)
        case "popup-prefix":
            let c = card("Fix the flaky upload test and run the suite again.", phase: .countdown, status: "Sending to Terminal — claude")
            c.note = "Pastes, then presses Return."
            c.remaining = 0.55
            popup.show(c)
        default:
            popup.show(card(short, phase: .copied, status: "Copied"))
        }
        // Hold still for the screenshot.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { popup.freeze() }
    }

    // MARK: Stand-in phones

    private static func stagePeers(_ spec: String, model: AppModel) {
        var peers: [PairedPeer] = []
        var connected: Set<UUID> = []
        let now = Date()
        for (i, raw) in spec.split(separator: "|").map(String.init).enumerated() where !raw.isEmpty {
            var name = raw
            let on = name.hasSuffix("*")
            if on { name.removeLast() }
            var rename: String?
            if let r = name.range(of: ">") { rename = String(name[r.upperBound...]); name = String(name[..<r.lowerBound]) }
            let id = UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", i + 1))!
            let p = PairedPeer(id: id, name: name, pairedAt: now.addingTimeInterval(-86_400 * Double(12 + i * 9)),
                               lastSeen: on ? now : (i == 2 ? nil : now.addingTimeInterval(-3600 * Double(3 + i * 20))))
            peers.append(p)
            if on { connected.insert(id) }
            model.settings.deviceNames[id.uuidString] = rename
        }
        // Wait for the real link server's first peer read, then stand in.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { model.debugStage(peers: peers, connected: connected) }
    }

    // MARK: Simulated dictations

    private static func listenForSimulatedDictations(_ model: AppModel) {
        let o = DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.sameer.macrophone.debug.dictate"),
                                                                   object: nil, queue: .main) { note in
            guard let json = note.object as? String, let data = json.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = obj["text"] as? String else { return }
            MainActor.assumeIsolated {
                var target: TargetRef?
                switch obj["target"] as? String {
                case nil: target = nil
                case "clipboard": target = .clipboard
                case "front": target = .frontApp
                case let bid?: target = .app(bundleID: bid, windowKey: obj["window"] as? String,
                                             name: model.targets.first { $0.bundleID == bid && $0.windowKey == obj["window"] as? String }?.title ?? bid)
                }
                let level = (obj["level"] as? String).flatMap(CleanupLevel.init(rawValue:)) ?? .medium
                let d = Dictation(raw: obj["raw"] as? String ?? text, cleaned: level == .off ? nil : text, cleanupLevel: level, target: target,
                                  send: obj["send"] as? Bool, sourceDevice: "Simulated iPhone")
                let peer = PairedPeer(id: UUID(), name: "Simulated iPhone")
                let (_, ack) = model.delivery.handle(d, delayed: obj["delayed"] as? Bool ?? false, from: peer)
                print("simulated dictation → \(ack ?? "")")
                fflush(stdout)
            }
        }
        bag.append(o)
        let choose = DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.sameer.macrophone.debug.choose"),
                                                                        object: nil, queue: .main) { note in
            guard let json = note.object as? String, let data = json.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let t = obj["target"] as? String else { return }
            MainActor.assumeIsolated {
                let ref: TargetRef
                switch t {
                case "clipboard": ref = .clipboard
                case "front": ref = .frontApp
                default:
                    let key = obj["window"] as? String
                    ref = model.targets.first { $0.bundleID == t && $0.windowKey == key }?.ref ?? .app(bundleID: t, windowKey: key, name: t)
                }
                model.choose(SendSelection(target: ref, send: obj["send"] as? Bool ?? false))
                print("chose on the Mac → \(ref.displayName)")
                fflush(stdout)
            }
        }
        bag.append(choose)
    }

    // MARK: Backdrop

    private static func showBackdrop() {
        var screen = PopupController.activeScreen()
        if env["MACROPHONE_POPUP_ON_ICON"] == "1", let main = NSScreen.screens.first { screen = main }
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
        let samples: [(String, String?, String, Bool, HistoryItem.Outcome, String, TimeInterval, String, CleanupLevel)] = [
            ("um so refactor the the history store so it trims to fifty items on write and uh add a test that proves a resend never shows up twice",
             english, "Claude", false, .pasted, "Sent to Claude", 120, "en-US", .medium),
            ("remind me to send priya the deck before the three pm sync", "- Send Priya the deck before the 3pm sync",
             "Clipboard", false, .copied, "Copied to clipboard", 900, "en-US", .custom),
            ("fix the flaky upload test and run the suite again", "Fix the flaky upload test and run the suite again.",
             "Terminal — claude ~/app", false, .pasted, "Sent to Terminal", 1800, "en-US", .light),
            ("مرحبا، هذا اختبار للإملاء من الهاتف إلى الماك.", nil, "Clipboard", false, .copied, "Copied to clipboard", 3600, "ar-SA", .off),
            ("שלום, זו בדיקה של הכתבה מהאייפון למק.", nil, "Clipboard", true, .copied, "Copied — delayed dictations are never pasted automatically", 7200, "he-IL", .off),
            ("今日の会議のメモを共有してください。", nil, "Messages", false, .pasted, "Pasted into Messages", 20000, "ja-JP", .off),
            ("write a function that sorts a list of users by last name", "Write a function that sorts a list of users by last name.",
             "Where I'm typing", false, .failed, "Not pasted — a password field is active", 90000, "en-US", .heavy),
        ]
        for s in samples.reversed() {
            let d = Dictation(createdAt: now.addingTimeInterval(-s.6 - 4), raw: s.0, cleaned: s.1, cleanupLevel: s.8,
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
        if let w = app.debugMainWindow, let s = w.attachedSheet ?? w.sheets.first {
            out["sheet"] = s.windowNumber
            let primary = NSScreen.screens.first?.frame.height ?? 0
            out["sheetFrame"] = [s.frame.minX, primary - s.frame.maxY, s.frame.width, s.frame.height]
            if let inner = s.attachedSheet ?? s.sheets.first {
                out["sheet2"] = inner.windowNumber
            }
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
