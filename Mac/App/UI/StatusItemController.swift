import AppKit
import Carbon.HIToolbox
import Combine
import MacrophoneKit

/// The menu bar presence: a template Filament (with a dot when a phone is connected) and its
/// menu. The menu is rebuilt each time it opens, so nothing ticks while it's closed.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let model: AppModel
    private let updater: Updater
    private var bag: Set<AnyCancellable> = []
    private var flashWork: DispatchWorkItem?
    private var flashing = false
    private var visibilityWork: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []
    private var visibleKVO: NSKeyValueObservation?

    init(model: AppModel, updater: Updater) {
        self.model = model
        self.updater = updater
        super.init()
        item.autosaveName = "MacrophoneStatusItem"
        item.behavior = []
        if let b = item.button {
            b.image = Self.image("MenuBarIcon")
            b.imagePosition = .imageOnly
            b.setAccessibilityLabel("Macrophone")
            b.toolTip = "Macrophone"
        }
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        model.$connected.combineLatest(model.$peers, model.$watching).receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in self?.refreshIcon() }.store(in: &bag)
        // A scan finishing, or the phone changing Send to, while the menu is open shows up in
        // its rows straight away.
        model.$targets.map { _ in () }.merge(with: model.settings.$selection.map { _ in () })
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.refreshSendTo() }.store(in: &bag)
        watchVisibility()
    }

    // MARK: Is the icon on screen?

    /// A crowded menu bar hides items behind the notch (or past the left edge), and macOS lets
    /// people turn an app's item off. Watch for it with notifications only — nothing polls.
    private func watchVisibility() {
        let nc = NotificationCenter.default
        let recheck: @Sendable (Notification) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.scheduleVisibilityCheck() } }
        observers.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main, using: recheck))
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                                           object: nil, queue: .main, using: recheck))
        if let w = item.button?.window {
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMoveNotification, NSWindow.didChangeScreenNotification] {
                observers.append(nc.addObserver(forName: name, object: w, queue: .main, using: recheck))
            }
        }
        visibleKVO = item.observe(\.isVisible, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.scheduleVisibilityCheck() }
        }
        // The menu bar lays the item out a moment after launch.
        scheduleVisibilityCheck(after: 2.0)
    }

    private func scheduleVisibilityCheck(after delay: TimeInterval = 0.8) {
        visibilityWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // A full-screen app or an auto-hiding menu bar hides every item; that's not crowding.
            if self.item.isVisible && !NSMenu.menuBarVisible() { return }
            self.model.setMenuBarIconHidden(self.visibleFrame == nil)
        }
        visibilityWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    private static func image(_ name: String) -> NSImage? {
        let i = NSImage(named: name)
        i?.isTemplate = true
        return i
    }

    private func refreshIcon() {
        guard !flashing, let b = item.button else { return }
        let on = model.connectedPeer != nil
        // The dot becomes a ring while a phone is looking at a window here: a glance at the menu
        // bar says this Mac is being shown somewhere, the way the camera light does.
        let watched = model.watching.values.sorted().first
        b.image = Self.image(watched != nil ? "MenuBarIconWatching" : on ? "MenuBarIconConnected" : "MenuBarIcon")
        let line = watched.map { "\(model.statusLine) · watching \($0)" } ?? model.statusLine
        b.setAccessibilityLabel(on ? "Macrophone — \(line)" : "Macrophone")
        b.toolTip = line
    }

    /// A tick on the icon for two seconds (silent copies).
    func flashReceived() {
        flashing = true
        item.button?.image = Self.image("MenuBarIconReceived")
        flashWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            self?.flashing = false
            self?.refreshIcon()
        }
        flashWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: w)
    }

    /// The icon's frame on screen, or nil when the menu bar has hidden it (crowded / notch).
    var visibleFrame: NSRect? {
        guard item.isVisible, let w = item.button?.window else { return nil }
        let f = w.frame
        guard f.width > 0, let screen = NSScreen.screens.first(where: { $0.frame.intersects(f) }) else { return nil }
        if !w.occlusionState.contains(.visible) { return nil }
        // On a notched display the bar is only the two areas either side of the notch; an item
        // pushed into the middle sits behind the camera housing.
        if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let mid = NSPoint(x: f.midX, y: f.midY)
            let inBar = [left, right].contains { area in
                let a = area.intersects(screen.frame) ? area : area.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
                return a.insetBy(dx: 0, dy: -4).contains(mid) && f.minX >= a.minX - 1 && f.maxX <= a.maxX + 1
            }
            if !inBar { return nil }
        }
        return f
    }

    // MARK: Menu

    #if DEBUG
    func openMenu() { item.button?.performClick(nil) }
    /// Stands in for a crowded / notched menu bar that has hidden the icon.
    func debugHide() {
        item.isVisible = false
        // Don't let the hidden state stick in this build's defaults for later runs.
        UserDefaults.standard.removeObject(forKey: "NSStatusItem VisibleCC MacrophoneStatusItem")
    }
    /// MACROPHONE_FAKE_MENU=route:tailscale,watching:Claude — stand-ins for what the stand-in
    /// phones can't say (how they're connected, a window they're watching), for screenshots.
    private var staged: [String: String] {
        guard let spec = ProcessInfo.processInfo.environment["MACROPHONE_FAKE_MENU"] else { return [:] }
        var out: [String: String] = [:]
        for part in spec.split(separator: ",") {
            let kv = part.split(separator: ":", maxSplits: 1).map(String.init)
            if kv.count == 2 { out[kv[0]] = kv[1] }
        }
        return out
    }
    #endif

    func menuWillOpen(_ menu: NSMenu) {
        // The list of open apps is only kept up to date while someone could look at it.
        if menu === item.menu { menuOpen = true; model.setMenuOpen(true) }
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === item.menu { menuOpen = false; model.setMenuOpen(false) }
    }

    /// The menu, top to bottom: who's connected and how · the way in · Send to (the shared
    /// choice, a check on the current one) · Recent (click copies) · the rarely needed · Quit.
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === moreAppsMenu { fillMoreApps(menu); return }
        guard menu === item.menu else { return }
        menu.removeAllItems()
        sendToItems = []
        moreAppsMenu = nil

        // 1. Status.
        let failed: Bool = { if case .failed = model.listenerState { return true } else { return false } }()
        menu.addItem(headerItem(failed: failed))
        for (peerID, appName) in watchingNow.sorted(by: { $0.value < $1.value }) {
            let who = model.peers.first { $0.id == peerID }.map(model.displayName) ?? "Your iPhone"
            let w = MenuWords.stopWatching(app: appName, phone: who)
            let mi = action(w.title, #selector(stopWatching(_:)), symbol: "eye.slash", detail: w.detail)
            mi.representedObject = peerID.uuidString
            menu.addItem(mi)
        }
        menu.addItem(.separator())

        // 2. The way in, and the one setup step still open (if any). With nothing paired yet,
        // pairing is the one thing to do, so it comes first.
        if !failed, model.peers.isEmpty { menu.addItem(action("Pair Your iPhone…", #selector(pair), symbol: "qrcode.viewfinder")) }
        let open = action("Open Macrophone", #selector(openWindow), key: ",", symbol: "macwindow")
        let hk = model.settings.hotkey
        let keyName = Hotkey.keyName(hk.keyCode)
        if hk.enabled, keyName.count == 1 {
            open.keyEquivalent = keyName.lowercased()
            var m: NSEvent.ModifierFlags = []
            if hk.modifiers & UInt32(cmdKey) != 0 { m.insert(.command) }
            if hk.modifiers & UInt32(optionKey) != 0 { m.insert(.option) }
            if hk.modifiers & UInt32(controlKey) != 0 { m.insert(.control) }
            if hk.modifiers & UInt32(shiftKey) != 0 { m.insert(.shift) }
            open.keyEquivalentModifierMask = m
        }
        menu.addItem(open)
        if failed {
            menu.addItem(action("Open Local Network Settings…", #selector(openLocalNetwork), symbol: "network"))
        } else if !model.peers.isEmpty, AgentSetup.claude == .notConnected {
            let mi = action("Connect Claude Code…", #selector(openAgents), symbol: "sparkles")
            mi.toolTip = "So your iPhone knows the moment Claude Code needs you."
            menu.addItem(mi)
        }
        menu.addItem(.separator())

        // 3. Send to — the choice the iPhone and this Mac share, picked in place.
        menu.addItem(NSMenuItem.sectionHeader(title: SendToWords.title))
        fillSendTo(menu)

        // 4. Recent — the three newest, click (or Return) copies; History has the rest.
        let recent = Array(model.history.prefix(3))
        if !recent.isEmpty {
            menu.addItem(.separator())
            menu.addItem(NSMenuItem.sectionHeader(title: "Recent"))
            for h in recent {
                // A short title: the row draws the words, and a long title would widen the menu.
                let mi = NSMenuItem(title: "Copy", action: #selector(copyRecent(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = h.dictation.text
                mi.view = RecentRowView(item: h)
                mi.toolTip = "Click to copy"
                menu.addItem(mi)
            }
            menu.addItem(action("Show All History…", #selector(openHistory), symbol: "clock.arrow.circlepath"))
        }

        // 5. Rarely, then Quit.
        menu.addItem(.separator())
        if !model.peers.isEmpty { menu.addItem(action("Pair Another iPhone…", #selector(pair), symbol: "qrcode.viewfinder")) }
        menu.addItem(action("Check for Updates…", #selector(checkUpdates), symbol: "arrow.down.circle"))
        if model.peers.count == 1, let p = model.peers.first {
            let mi = action("Forget \(model.displayName(p))…", #selector(forget(_:)), symbol: "iphone.slash")
            mi.representedObject = p.id.uuidString
            menu.addItem(mi)
        } else if model.peers.count > 1 {
            let forgetItem = NSMenuItem(title: "Forget an iPhone", action: nil, keyEquivalent: "")
            forgetItem.image = symbolImage("iphone.slash")
            let sub = NSMenu(title: "Forget an iPhone")
            for p in model.peers {
                let mi = action("\(model.displayName(p))…", #selector(forget(_:)))
                mi.representedObject = p.id.uuidString
                sub.addItem(mi)
            }
            forgetItem.submenu = sub
            menu.addItem(forgetItem)
        }
        menu.addItem(.separator())
        menu.addItem(action("Quit Macrophone", #selector(quit), key: "q"))
    }

    /// Phone → the app it's watching (a staged one in a DEBUG run).
    private var watchingNow: [UUID: String] {
        #if DEBUG
        if let app = staged["watching"], let p = model.connectedPeer ?? model.peers.first { return [p.id: app] }
        #endif
        return model.watching
    }

    private func headerItem(failed: Bool) -> NSMenuItem {
        #if DEBUG
        let stagedRoute = staged["route"].flatMap(LinkRoute.init(rawValue:))
        #else
        let stagedRoute: LinkRoute? = nil
        #endif
        let phones = model.peers.map { p in
            let on = model.connected.contains(p.id)
            return MenuWords.Phone(name: model.displayName(p), connected: on,
                                   route: on ? (model.peerRoutes[p.id] ?? stagedRoute) : nil, lastSeen: p.lastSeen)
        }
        let mi = NSMenuItem()
        mi.view = MenuHeaderView(MenuWords.header(phones: phones, listenerFailed: failed))
        mi.isEnabled = false
        return mi
    }

    private func symbolImage(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    private func action(_ title: String, _ sel: Selector, key: String = "", symbol: String? = nil, detail: String? = nil) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        mi.target = self
        if let symbol { mi.image = symbolImage(symbol) }
        if let detail {
            if #available(macOS 14.4, *) { mi.subtitle = detail } else { mi.toolTip = detail }
        }
        return mi
    }

    @objc private func stopWatching(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? String, let id = UUID(uuidString: s) else { return }
        model.stopWatching(id)
    }

    @objc private func copyRecent(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        Clipboard.copyPlain(text)
        flashReceived()
    }

    // MARK: Send to

    /// The rows under the Send to header, Send after pasting included (so a scan finishing
    /// while the menu is open can swap them in place).
    private var sendToItems: [NSMenuItem] = []
    private weak var moreAppsMenu: NSMenu?
    private var menuOpen = false

    /// Send to changed (the phone, a scan): redraw its rows while the menu is open.
    private func refreshSendTo() {
        guard menuOpen, let menu = item.menu, let first = sendToItems.first else { return }
        let at = menu.index(of: first)
        guard at >= 0 else { return }
        for mi in sendToItems { menu.removeItem(mi) }
        fillSendTo(menu, at: at)
    }

    private func targetRow(_ ref: TargetRef, bundleID: String? = nil) -> NSMenuItem {
        let mi = NSMenuItem(title: SendToWords.name(ref, in: model), action: #selector(pickTarget(_:)), keyEquivalent: "")
        mi.target = self
        mi.representedObject = SelectionBox(ref)
        mi.state = ref == model.selection.target ? .on : .off
        if let bundleID, let icon = TargetIcons.image(bundleID: bundleID) {
            mi.image = icon
        } else {
            mi.image = symbolImage(TargetIcons.symbol(for: ref))
        }
        return mi
    }

    /// The open apps and windows, newest first, split into the few the menu shows and the rest
    /// under More Apps. The chosen one is always in the menu, even when it's far down the list.
    private func arrangedTargets() -> (inline: [LiveTarget], more: [LiveTarget]) {
        var apps = model.targets
        let current = model.selection.target
        if let i = apps.firstIndex(where: { current.matches($0) }), i >= MenuWords.inlineApps {
            apps.insert(apps.remove(at: i), at: MenuWords.inlineApps - 1)
        }
        return (Array(apps.prefix(MenuWords.inlineApps)), Array(apps.dropFirst(MenuWords.inlineApps)))
    }

    /// Clipboard · Where I'm typing · the open apps and windows — the first few in the menu,
    /// the rest under More Apps — then Send after pasting.
    private func fillSendTo(_ menu: NSMenu, at index: Int? = nil) {
        var rows: [NSMenuItem] = [targetRow(.clipboard), targetRow(.frontApp)]
        let current = model.selection.target
        var unlisted: TargetRef?
        if case .app = current, model.liveTarget(for: current) == nil { unlisted = current }
        let (inline, more) = arrangedTargets()
        if !inline.isEmpty || unlisted != nil {
            for t in inline { rows.append(targetRow(t.ref, bundleID: t.bundleID)) }
            if let unlisted { rows.append(targetRow(unlisted, bundleID: unlisted.bundleID)) }
        } else {
            // Before the first scan finishes nothing can be said of the open apps.
            let none = NSMenuItem(title: model.targetsKnown ? "No open app has somewhere to type" : "Looking for open apps…",
                                  action: nil, keyEquivalent: "")
            none.isEnabled = false
            rows.append(none)
        }
        if !more.isEmpty {
            let mi = NSMenuItem(title: "More Apps", action: nil, keyEquivalent: "")
            mi.image = symbolImage("square.grid.2x2")
            let sub = NSMenu(title: "More Apps")
            sub.delegate = self
            sub.autoenablesItems = false
            fillMoreApps(sub)
            mi.submenu = sub
            moreAppsMenu = sub
            rows.append(mi)
        }
        // Send after pasting, on its own: a toggle, not another place.
        rows.append(.separator())
        rows.append(sendAfterPastingItem())
        if let index {
            for (i, mi) in rows.enumerated() { menu.insertItem(mi, at: index + i) }
        } else {
            for mi in rows { menu.addItem(mi) }
        }
        sendToItems = rows
    }

    private func fillMoreApps(_ menu: NSMenu) {
        menu.removeAllItems()
        for t in arrangedTargets().more { menu.addItem(targetRow(t.ref, bundleID: t.bundleID)) }
    }

    private func sendAfterPastingItem() -> NSMenuItem {
        let target = model.selection.target
        let terminal = target.bundleID.map(AppQuirks.isTerminal) ?? false
        let send = action(SendToWords.sendAfterPasting, #selector(toggleSend),
                          detail: MenuWords.sendAfterPastingDetail(canSend: target.canSend, terminal: terminal))
        send.state = model.selection.send && target.canSend ? .on : .off
        send.isEnabled = target.canSend
        return send
    }

    @objc private func pickTarget(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? SelectionBox else { return }
        model.choose(SendSelection(target: box.ref, send: model.selection.send))
    }

    @objc private func toggleSend() {
        model.setSend(!model.selection.send)
    }

    @objc private func pair() { AppDelegate.shared?.openSetup(.pair) }
    @objc private func openLocalNetwork() { NSWorkspace.shared.open(DevicesPane.localNetworkSettings) }
    @objc private func openWindow() { AppDelegate.shared?.openMainWindow() }
    @objc private func openHistory() { AppDelegate.shared?.openMainWindow(pane: .history) }
    @objc private func openAgents() { AppDelegate.shared?.openMainWindow(pane: .agents) }
    @objc private func checkUpdates() { updater.checkForUpdates() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func forget(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? String, let id = UUID(uuidString: s),
              let peer = model.peers.first(where: { $0.id == id }) else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Forget \(model.displayName(peer))?"
        alert.informativeText = "It won't be able to send to this Mac until you pair it again. Use this if the phone is lost."
        alert.addButton(withTitle: "Forget")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn { model.forget(peer) }
    }
}

/// A TargetRef in a menu item's representedObject.
final class SelectionBox: NSObject {
    let ref: TargetRef
    init(_ ref: TargetRef) { self.ref = ref }
}
