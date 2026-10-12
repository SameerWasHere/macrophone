import AppKit
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
        model.$connected.combineLatest(model.$peers).receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.refreshIcon() }.store(in: &bag)
    }

    private static func image(_ name: String) -> NSImage? {
        let i = NSImage(named: name)
        i?.isTemplate = true
        return i
    }

    private func refreshIcon() {
        guard !flashing, let b = item.button else { return }
        let on = model.connectedPeer != nil
        b.image = Self.image(on ? "MenuBarIconConnected" : "MenuBarIcon")
        b.setAccessibilityLabel(on ? "Macrophone — \(model.statusLine)" : "Macrophone")
        b.toolTip = model.statusLine
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
        guard f.width > 0, NSScreen.screens.contains(where: { $0.frame.intersects(f) }) else { return nil }
        if !w.occlusionState.contains(.visible) { return nil }
        return f
    }

    // MARK: Menu

    #if DEBUG
    func openMenu() { item.button?.performClick(nil) }
    /// Stands in for a crowded / notched menu bar that has hidden the icon.
    func debugHide() { item.isVisible = false }
    #endif

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // Status: who's connected, when the last dictation came in.
        menu.addItem(statusHeader())

        // The three most recent dictations; click copies.
        let recent = Array(model.history.prefix(3))
        if !recent.isEmpty {
            menu.addItem(.separator())
            menu.addItem(sectionHeader("Recent"))
            for h in recent {
                let mi = NSMenuItem()
                let view = RecentItemView(item: h) { [weak self, weak menu] in
                    Clipboard.copyPlain(h.dictation.text)
                    menu?.cancelTracking()
                    self?.flashReceived()
                }
                mi.view = view
                mi.toolTip = "Click to copy"
                menu.addItem(mi)
            }
        }

        menu.addItem(.separator())
        let modeItem = NSMenuItem(title: "Delivery", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for m in DeliveryMode.allCases {
            let mi = NSMenuItem(title: m.title, action: #selector(pickMode(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = m.rawValue
            mi.state = model.settings.deliveryMode == m ? .on : .off
            sub.addItem(mi)
        }
        modeItem.submenu = sub
        menu.addItem(modeItem)

        menu.addItem(action("Pair iPhone…", #selector(pair)))
        menu.addItem(action("Open Macrophone…", #selector(openWindow), key: ","))
        menu.addItem(action("Check for Updates…", #selector(checkUpdates)))

        if !model.peers.isEmpty {
            menu.addItem(.separator())
            for p in model.peers {
                let mi = action(model.peers.count == 1 ? "Forget This iPhone…" : "Forget \(p.name)…", #selector(forget(_:)))
                mi.representedObject = p.id.uuidString
                menu.addItem(mi)
            }
        }

        menu.addItem(.separator())
        menu.addItem(action("Quit Macrophone", #selector(quit), key: "q"))
    }

    private func statusHeader() -> NSMenuItem {
        let mi = NSMenuItem()
        let on = model.connectedPeer != nil
        var second: String?
        if let last = model.lastReceived {
            second = "Last received \(last.relativeShort)"
        } else if !model.peers.isEmpty {
            second = "Nothing received yet"
        }
        if case .failed = model.listenerState { second = "Can't listen on the network — check Local Network in System Settings" }
        mi.view = StatusHeaderView(title: model.statusLine, detail: second, connected: on)
        return mi
    }

    private func sectionHeader(_ s: String) -> NSMenuItem {
        if #available(macOS 14.0, *) { return NSMenuItem.sectionHeader(title: s) }
        let mi = NSMenuItem(title: s, action: nil, keyEquivalent: "")
        mi.isEnabled = false
        return mi
    }

    private func action(_ title: String, _ sel: Selector, key: String = "", symbol: String? = nil) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        mi.target = self
        if let symbol { mi.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return mi
    }

    @objc private func pickMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let m = DeliveryMode(rawValue: raw) else { return }
        if m == .autoPaste && !Paster.isTrusted {
            // Ask for Accessibility only when the person turns pasting on.
            Paster.requestTrust()
        }
        model.settings.deliveryMode = m
    }

    @objc private func pair() { AppDelegate.shared?.openSetup(.pair) }
    @objc private func openWindow() { AppDelegate.shared?.openMainWindow() }
    @objc private func checkUpdates() { updater.checkForUpdates() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func forget(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? String, let id = UUID(uuidString: s),
              let peer = model.peers.first(where: { $0.id == id }) else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Forget \(peer.name)?"
        alert.informativeText = "It won't be able to send to this Mac until you pair it again. Use this if the phone is lost."
        alert.addButton(withTitle: "Forget")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn { model.forget(peer) }
    }
}

/// A recent dictation in the menu: time and profile on top, the words under them, a fade
/// instead of "…" when they run long. Click copies.
final class RecentItemView: NSView {
    private let item: HistoryItem
    private let onClick: () -> Void
    private var tracking: NSTrackingArea?
    private var hovered = false { didSet { needsDisplay = true } }

    init(item: HistoryItem, onClick: @escaping () -> Void) {
        self.item = item
        self.onClick = onClick
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 52))
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel("Copy: \(item.dictation.text)")
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseUp(with event: NSEvent) { onClick() }

    override func draw(_ dirtyRect: NSRect) {
        let highlighted = hovered || (enclosingMenuItem?.isHighlighted ?? false)
        if highlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 5, yRadius: 5).fill()
        }
        let primary = highlighted ? NSColor.white : NSColor.labelColor
        let secondary = highlighted ? NSColor.white.withAlphaComponent(0.8) : NSColor.secondaryLabelColor
        let inset: CGFloat = 16
        let width = bounds.width - inset * 2

        var meta = item.receivedAt.relativeShort
        if item.delayed { meta += " · delayed" }
        meta += " · " + item.profileName
        (meta as NSString).draw(in: NSRect(x: inset, y: bounds.height - 18, width: width, height: 14),
                                withAttributes: [.font: NSFont.systemFont(ofSize: 10.5, weight: .medium), .foregroundColor: secondary])

        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byClipping
        para.baseWritingDirection = TextDirection.isRTL(item.dictation.text) ? .rightToLeft : .natural
        para.alignment = TextDirection.isRTL(item.dictation.text) ? .right : .natural
        let text = item.dictation.text.replacingOccurrences(of: "\n", with: " ")
        let font = NSFont(descriptor: NSFont.systemFont(ofSize: 13).fontDescriptor.withDesign(.serif) ?? NSFont.systemFont(ofSize: 13).fontDescriptor, size: 13)
            ?? NSFont.systemFont(ofSize: 13)
        let textRect = NSRect(x: inset, y: 8, width: width, height: 18)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: textRect).addClip()
        (text as NSString).draw(in: textRect, withAttributes: [.font: font, .foregroundColor: primary, .paragraphStyle: para])
        NSGraphicsContext.restoreGraphicsState()
        // Fade the trailing edge rather than cut with "…".
        let size = (text as NSString).size(withAttributes: [.font: font])
        if size.width > width, let ctx = NSGraphicsContext.current {
            let rtl = TextDirection.isRTL(text)
            let fadeW: CGFloat = 40
            let fadeRect = NSRect(x: rtl ? textRect.minX : textRect.maxX - fadeW, y: textRect.minY - 2, width: fadeW, height: textRect.height + 4)
            ctx.saveGraphicsState()
            ctx.compositingOperation = .destinationOut
            let g = NSGradient(colors: [NSColor.black.withAlphaComponent(0), NSColor.black])
            g?.draw(in: fadeRect, angle: rtl ? 180 : 0)
            ctx.restoreGraphicsState()
            if highlighted {
                // destinationOut also cut the highlight; paint it back under the fade.
                ctx.saveGraphicsState()
                ctx.compositingOperation = .destinationOver
                NSColor.selectedContentBackgroundColor.setFill()
                NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 5, yRadius: 5).fill()
                ctx.restoreGraphicsState()
            }
        }
    }
}

/// The menu's first row: a status dot, who's connected, when the last dictation came in.
final class StatusHeaderView: NSView {
    init(title: String, detail: String?, connected: Bool) {
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: detail == nil ? 30 : 46))
        let dot = NSView(frame: NSRect(x: 16, y: bounds.height - 19, width: 8, height: 8))
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.layer?.backgroundColor = (connected ? NSColor(srgbRed: 0.345, green: 0.725, blue: 0.871, alpha: 1) : NSColor.tertiaryLabelColor).cgColor
        addSubview(dot)
        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 13, weight: .semibold)
        t.textColor = .labelColor
        t.frame = NSRect(x: 32, y: bounds.height - 24, width: 256, height: 18)
        addSubview(t)
        if let detail {
            let d = NSTextField(labelWithString: detail)
            d.font = .systemFont(ofSize: 11.5)
            d.textColor = .secondaryLabelColor
            d.frame = NSRect(x: 32, y: 6, width: 256, height: 16)
            d.lineBreakMode = .byWordWrapping
            addSubview(d)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel([title, detail].compactMap { $0 }.joined(separator: ". "))
    }
    required init?(coder: NSCoder) { fatalError() }
}
