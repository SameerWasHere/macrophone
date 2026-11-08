import Combine
import MacrophoneKit
import UIKit

// The app icon's long press (Nov 5 2026): Home Screen quick actions, kept up to date with the
// Send to pick, the Mac's open apps and the windows watched lately. Each one goes the way its
// counterpart already does — Dictate the way Start Dictation (a Shortcut, the control) does,
// Watch the way the Watch widget's link does, Whole Screen the way the menu bar's button does —
// so a cold launch waits for the Mac just as those do.

/// What the long press offers, and how it reads one back.
enum QuickActions {
    enum Kind: String {
        /// Opens with the mic on for a place ("target": a `TargetEntity` id).
        case dictate = "com.sameer.macrophone.dictate"
        /// Opens a window live ("target": "app:<bundleID>#<windowKey>").
        case watch = "com.sameer.macrophone.watch"
        /// Opens the Mac's whole screen live.
        case screen = "com.sameer.macrophone.screen"
        /// Opens the window in front on the Mac live (Model/FrontWindowHere.swift).
        case front = "com.sameer.macrophone.front"
    }

    /// The Home Screen shows four.
    static let limit = 4
    /// The windows watched lately, per Mac (newest first, at most `recentLimit`).
    static let recentLimit = 2
    private static func recentKey(_ mac: UUID) -> String { "quick.watched.\(mac.uuidString)" }

    @MainActor private static var bag = Set<AnyCancellable>()

    /// Keeps the items current: the pick, the open apps, the Mac, the link (the Mac says whether
    /// it can show its whole screen once connected) and every window watched.
    @MainActor static func install(_ model: AppModel) {
        model.watcher.$target
            .compactMap { $0 }
            .sink { [weak model] t in model?.noteWatched(t) }
            .store(in: &bag)
        let changes: [AnyPublisher<Void, Never>] = [
            model.settings.$selection.map { _ in () }.eraseToAnyPublisher(),
            model.$liveTargets.map { _ in () }.eraseToAnyPublisher(),
            model.$pairedMac.map { _ in () }.eraseToAnyPublisher(),
            model.$linkState.map { _ in () }.eraseToAnyPublisher(),
            model.watcher.$target.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(changes)
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak model] in model?.refreshQuickActions() }
            .store(in: &bag)
    }

    static func recent(mac: UUID?) -> [CachedTarget] {
        guard let mac, let d = UserDefaults.standard.data(forKey: recentKey(mac)) else { return [] }
        return (try? JSONDecoder().decode([CachedTarget].self, from: d)) ?? []
    }

    static func saveRecent(_ list: [CachedTarget], mac: UUID) {
        guard let d = try? JSONEncoder().encode(list) else { return }
        UserDefaults.standard.set(d, forKey: recentKey(mac))
    }

    static func forget(mac: UUID) { UserDefaults.standard.removeObject(forKey: recentKey(mac)) }

    static func id(for ref: TargetRef) -> String {
        switch ref {
        case .clipboard: return TargetEntity.clipboardID
        case .frontApp: return TargetEntity.frontID
        case let .app(bid, key, _): return "app:\(bid)#\(key ?? "")"
        }
    }

    static func item(_ kind: Kind, _ title: String, subtitle: String?, symbol: String, target: String? = nil) -> UIApplicationShortcutItem {
        UIApplicationShortcutItem(type: kind.rawValue, localizedTitle: title, localizedSubtitle: subtitle,
                                  icon: UIApplicationShortcutIcon(systemImageName: symbol),
                                  userInfo: target.map { ["target": $0 as NSString] })
    }
}

extension AppModel {
    /// A window was opened (or switched to): it's the newest of the ones watched lately. The
    /// whole screen has its own item.
    func noteWatched(_ ref: TargetRef) {
        guard case .app = ref, !DesktopWatch.isDesktop(ref), let mac = pairedMac?.id else { return }
        let entry = CachedTarget(id: QuickActions.id(for: ref), name: liveTarget(for: ref)?.appName ?? ref.displayName)
        var list = QuickActions.recent(mac: mac).filter { $0.id != entry.id }
        list.insert(entry, at: 0)
        QuickActions.saveRecent(Array(list.prefix(QuickActions.recentLimit)), mac: mac)
    }

    /// "Claude" for a window of Claude ("Terminal — claude ~/app" → "Terminal"; its window
    /// under it), "Clipboard", "Where I'm typing".
    private func quickName(_ ref: TargetRef) -> (title: String, window: String?) {
        guard case .app = ref else { return (ref.displayName, nil) }
        if let live = liveTarget(for: ref) { return (live.appName, live.windowTitle) }
        let parts = ref.displayName.components(separatedBy: " — ")
        return (parts[0], parts.count > 1 ? parts.dropFirst().joined(separator: " — ") : nil)
    }

    /// The long press's items: Dictate to the pick, Watch What's in Front, the last window
    /// watched, the whole screen when the Mac offers it, and Dictate to Where I'm typing — four at
    /// most, in that order of use (a second watched window before Where I'm typing).
    func refreshQuickActions() {
        var items: [UIApplicationShortcutItem] = []
        let pick = settings.selection.target
        let name = quickName(pick)
        items.append(QuickActions.item(.dictate, "Dictate to \(name.title)",
                                       subtitle: isPaired ? (name.window ?? macName) : "Copies it on this iPhone",
                                       symbol: "mic", target: QuickActions.id(for: pick)))
        if isPaired {
            // What's in front on the Mac, whatever it is: second, under the thumb.
            items.append(QuickActions.item(.front, "Watch What's in Front", subtitle: "Live on \(macName)", symbol: "macwindow.on.rectangle"))
            // Only windows of apps still open (when the Mac's list is known).
            let open = Set(liveTargets.map(\.bundleID))
            let watched = QuickActions.recent(mac: pairedMac?.id).filter { w in
                let (bid, _) = TargetQuery.parts(w.id)
                return liveTargets.isEmpty || open.contains(bid)
            }
            func watchItem(_ w: CachedTarget) -> UIApplicationShortcutItem {
                let window = intentSelection(w.id, name: w.name).flatMap { liveTarget(for: $0.target)?.windowTitle }
                return QuickActions.item(.watch, "Watch \(w.name)", subtitle: window ?? "Live on \(macName)",
                                         symbol: "eye", target: w.id)
            }
            if let w = watched.first { items.append(watchItem(w)) }
            // What the Mac offered when last connected (the bar keeps its button the same way).
            if watcher.canWatchDesktop || (!isConnected && UserDefaults.standard.bool(forKey: "bar.had.wholeScreen")) {
                items.append(QuickActions.item(.screen, "Whole Screen", subtitle: "Live on \(macName)", symbol: "display"))
            }
            if watched.count > 1 { items.append(watchItem(watched[1])) }
            if pick != .frontApp {
                items.append(QuickActions.item(.dictate, "Dictate to Where I'm typing", subtitle: macName,
                                               symbol: "text.cursor", target: TargetEntity.frontID))
            }
        }
        let shown = Array(items.prefix(QuickActions.limit))
        let now = UIApplication.shared.shortcutItems ?? []
        // Only on a change (each write goes to SpringBoard).
        guard shown.map(\.type) != now.map(\.type) || shown.map(\.localizedTitle) != now.map(\.localizedTitle)
                || shown.map({ $0.localizedSubtitle ?? "" }) != now.map({ $0.localizedSubtitle ?? "" })
                || shown.map({ $0.userInfo?["target"] as? String ?? "" }) != now.map({ $0.userInfo?["target"] as? String ?? "" })
        else { return }
        UIApplication.shared.shortcutItems = shown
        log.add("quick actions: \(shown.count)")
    }

    /// A long-press item was chosen. Cold or warm, the same as its counterpart: Dictate waits
    /// for the scene to be active (Start Dictation's way), Watch opens at once and goes live
    /// when the Mac connects (the widget's way), Whole Screen waits for the Mac to say it can.
    @discardableResult
    func runQuickAction(_ item: UIApplicationShortcutItem) -> Bool {
        guard let kind = QuickActions.Kind(rawValue: item.type) else { return false }
        let target = item.userInfo?["target"] as? String
        log.add("quick action: \(kind)")
        switch kind {
        case .dictate:
            Task { await startFromIntent(targetID: target) }
        case .watch:
            guard let target else { return false }
            watchFromIntent(targetID: target, name: nil)
        case .screen:
            watchFromIntent(targetID: TargetEntity.screenID, name: nil)
        case .front:
            watchWhatsInFront()
        }
        return true
    }

    /// Watch (a Shortcut, Siri, a quick action): an open app's window, or the whole screen (for
    /// the Clipboard and Where I'm typing too — there's no window of theirs). Nothing named: the
    /// Send to pick's, as the Duo's inner screen opens it.
    func watchFromIntent(targetID: String?, name: String?) {
        guard isPaired, !showOnboarding else { return }
        sheet = nil
        let id = targetID ?? QuickActions.id(for: settings.selection.target)
        if id.hasPrefix("app:"), let sel = intentSelection(id, name: name) {
            log.add("intent: watching an app")
            openAttention(sel.target)
        } else {
            watchWholeScreenWhenReady()
        }
    }

    /// The whole screen now, or once the Mac is connected (only then does it say it can show it).
    func watchWholeScreenWhenReady() {
        guard isConnected else { waitingWholeScreen = true; return }
        guard watcher.canWatchDesktop else { log.add("intent: this Mac can't show its whole screen"); return }
        watchWholeScreen()
    }
}

/// Where the long press comes in. A cold launch hands its item to the scene's configuration
/// (`AppDelegate`), a warm one to the scene's delegate.
final class QuickActionSceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        completionHandler(AppModel.shared.runQuickAction(shortcutItem))
    }
}

extension AppDelegate {
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = QuickActionSceneDelegate.self
        if let item = options.shortcutItem {
            // Opened from the long press: once the model is up (a moment after the scene is).
            Task { @MainActor in AppModel.shared.runQuickAction(item) }
        }
        return config
    }
}
