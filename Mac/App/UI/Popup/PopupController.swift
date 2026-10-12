import AppKit
import Combine
import SwiftUI

/// A panel that never becomes key or main, so a paste always lands in the app the person is
/// using — never in Macrophone.
final class PopupPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Hosts the SwiftUI stack; tracks the pointer even though the app is never active (hover
/// pauses countdowns) and takes the first click (Cancel must work on the first try).
final class PopupHostingView<Content: View>: NSHostingView<Content> {
    var onHover: (Bool) -> Void = { _ in }
    /// The cards' area, measured from the top (the rest of the panel is shadow room).
    var cardArea: () -> (inset: CGFloat, height: CGFloat) = { (0, 0) }
    private var area: NSTrackingArea?
    private var inside = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(a)
        area = a
    }

    private func track(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let fromTop = isFlipped ? p.y : bounds.height - p.y
        let (inset, height) = cardArea()
        let now = p.x >= inset && p.x <= bounds.width - inset && fromTop >= 0 && fromTop <= height
        if now != inside { inside = now; onHover(now) }
    }

    override func mouseEntered(with event: NSEvent) { super.mouseEntered(with: event); track(event) }
    override func mouseMoved(with event: NSEvent) { super.mouseMoved(with: event); track(event) }
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if inside { inside = false; onHover(false) }
    }
}

/// Places, shows and retires the popup. Nothing runs while it's hidden: the countdown timer
/// only exists while a countdown is on screen, and the panel's view tree is torn down when it
/// retracts.
@MainActor
final class PopupController {
    let model = PopupModel()
    /// Where the status item is (screen coordinates), or nil when it's hidden.
    var statusItemFrame: () -> NSRect? = { nil }

    private var panel: PopupPanel?
    private var host: PopupHostingView<PopupRoot>?
    private var tick: Timer?
    private var lastTick = Date()
    private var expiry: [UUID: Date] = [:]
    private var retractWork: DispatchWorkItem?
    private var bag: Set<AnyCancellable> = []

    init() {
        model.$contentHeight.removeDuplicates().sink { [weak self] h in self?.fit(h) }.store(in: &bag)
    }

    // MARK: Cards

    func show(_ card: PopupCard) {
        retractWork?.cancel()
        ensurePanel()
        model.reduceMotion = Motion.reduceMotion
        position()
        if !model.shown {
            panel?.alphaValue = 1
            panel?.orderFrontRegardless()
            // Next runloop so the grow-in animates from the icon.
            DispatchQueue.main.async { [weak self] in self?.model.shown = true }
        }
        model.cards.insert(card, at: 0)
        refresh(card)
        DispatchQueue.main.async { [weak self] in self?.fit(self?.model.contentHeight ?? 0) }
    }

    /// Call after changing a card's phase: restarts its clock, starts or stops the ticker.
    func refresh(_ card: PopupCard) {
        if card.isBusy {
            expiry[card.id] = nil
        } else {
            expiry[card.id] = Date().addingTimeInterval(card.lifetime)
        }
        updateTicker()
    }

    func dismiss(_ card: PopupCard) {
        if card.phase == .countdown { card.onCancel() }
        remove(card)
    }

    private func remove(_ card: PopupCard) {
        expiry[card.id] = nil
        model.cards.removeAll { $0.id == card.id }
        if model.cards.isEmpty { retract() }
        updateTicker()
    }

    func dismissAll() {
        for c in model.cards where c.phase == .countdown { c.onCancel() }
        model.cards.removeAll()
        expiry.removeAll()
        retract()
    }

    // MARK: Clock — counts down, expires cards, pauses on hover

    private func updateTicker() {
        let needs = !model.cards.isEmpty && !model.frozen
        if needs && tick == nil {
            lastTick = Date()
            let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.step() }
            }
            RunLoop.main.add(t, forMode: .common)
            tick = t
        } else if !needs {
            tick?.invalidate()
            tick = nil
        }
    }

    private func step() {
        let now = Date()
        let dt = now.timeIntervalSince(lastTick)
        lastTick = now
        let paused = model.hovering
        for card in model.cards {
            if card.phase == .countdown {
                card.paused = paused
                if !paused {
                    card.remaining = max(0, card.remaining - dt / card.countdownSeconds)
                    if card.remaining <= 0 { card.onFire() }
                }
            }
        }
        if paused {
            // Hover holds everything: push every expiry forward.
            for (id, at) in expiry { expiry[id] = at.addingTimeInterval(dt) }
        } else {
            for card in model.cards where !card.isBusy {
                if let at = expiry[card.id], at <= now { remove(card) }
            }
        }
        // Only countdowns need 60 fps; otherwise a slow tick is plenty for expiry.
        let counting = model.cards.contains { $0.phase == .countdown }
        if !counting, let t = tick, t.timeInterval < 0.2 {
            t.invalidate(); tick = nil
            let slow = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.step() } }
            RunLoop.main.add(slow, forMode: .common)
            tick = slow
        } else if counting, let t = tick, t.timeInterval > 0.2 {
            t.invalidate(); tick = nil
            updateTicker()
        }
        if model.cards.isEmpty { tick?.invalidate(); tick = nil }
    }

    // MARK: Panel

    private func ensurePanel() {
        guard panel == nil else { return }
        let p = PopupPanel(contentRect: NSRect(x: 0, y: 0, width: PopupRoot.cardWidth + PopupRoot.margin * 2, height: max(120, model.contentHeight)),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.becomesKeyOnlyIfNeeded = true
        p.isMovable = false
        p.isReleasedWhenClosed = false
        p.appearance = NSAppearance(named: .darkAqua)
        p.animationBehavior = .none
        p.title = "Macrophone"
        let root = PopupRoot(model: model, dismiss: { [weak self] card in self?.dismiss(card) })
        let h = PopupHostingView(rootView: root)
        h.onHover = { [weak self] inside in
            guard let self else { return }
            if self.model.hovering != inside { self.model.hovering = inside }
        }
        h.sizingOptions = []
        h.cardArea = { [weak self] in
            guard let self else { return (0, 0) }
            return (PopupRoot.margin, max(0, self.model.contentHeight - PopupRoot.margin - 8))
        }
        p.contentView = h
        panel = p
        host = h
    }

    private func retract() {
        model.shown = false
        model.hovering = false
        tick?.invalidate(); tick = nil
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.model.shown else { return }
            self.panel?.orderOut(nil)
            // Tear the view tree down: nothing left to redraw while hidden.
            self.panel?.contentView = nil
            self.panel = nil
            self.host = nil
        }
        retractWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (model.reduceMotion ? 0.25 : 0.45), execute: work)
    }

    /// The panel hangs under the icon on the display the person is using; falls back to the
    /// top-right corner when the icon is hidden (a crowded or notched menu bar).
    private func position() {
        guard let panel else { return }
        let width = PopupRoot.cardWidth + PopupRoot.margin * 2
        let height = panel.frame.height
        let active = Self.activeScreen()
        var anchorX: CGFloat
        var top: CGFloat
        let menuBarBottom = active.visibleFrame.maxY
        if let item = statusItemFrame(), let itemScreen = NSScreen.screens.first(where: { $0.frame.intersects(item) }) {
            if itemScreen == active {
                anchorX = item.midX
            } else {
                // Same spot on this display's menu bar.
                anchorX = active.frame.maxX - (itemScreen.frame.maxX - item.midX)
            }
            top = min(item.minY, menuBarBottom) + 2
        } else {
            anchorX = active.visibleFrame.maxX - PopupRoot.cardWidth / 2 - 14
            top = menuBarBottom - 4
        }
        var x = anchorX - width / 2
        x = min(max(x, active.frame.minX + 2), active.frame.maxX - width - 2)
        panel.setFrame(NSRect(x: x, y: top - height, width: width, height: height), display: false)
        model.anchorX = Double(max(0.08, min(0.92, (anchorX - x) / width)))
    }

    private var shrinkWork: DispatchWorkItem?

    /// Fit the panel to the stack, top edge fixed. Grows at once; shrinks after the cards'
    /// own animation has finished so nothing is clipped mid-flight.
    private func fit(_ h: CGFloat) {
        guard let panel, h > 1 else { return }
        let target = min(h, Self.activeScreen().visibleFrame.height - 20)
        let apply = { [weak self] in
            guard let self, let panel = self.panel else { return }
            let height = min(self.model.contentHeight, Self.activeScreen().visibleFrame.height - 20)
            guard height > 1 else { return }
            var f = panel.frame
            let top = f.maxY
            f.size.height = height
            f.origin.y = top - height
            panel.setFrame(f, display: true)
        }
        shrinkWork?.cancel()
        if target >= panel.frame.height - 0.5 {
            apply()
        } else {
            let w = DispatchWorkItem(block: apply)
            shrinkWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
        }
    }

    /// The display with the frontmost window (where the person is working).
    static func activeScreen() -> NSScreen {
        if let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            for w in list {
                guard (w[kCGWindowOwnerPID as String] as? pid_t) == front,
                      (w[kCGWindowLayer as String] as? Int) == 0,
                      let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                      let x = b["X"], let y = b["Y"], let wd = b["Width"], let ht = b["Height"], wd > 50, ht > 50 else { continue }
                // CG bounds are top-left based; flip against the primary display.
                let primary = NSScreen.screens.first?.frame.height ?? 0
                let rect = NSRect(x: x, y: primary - y - ht, width: wd, height: ht)
                let center = NSPoint(x: rect.midX, y: rect.midY)
                if let s = NSScreen.screens.first(where: { $0.frame.contains(center) }) { return s }
            }
        }
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main ?? NSScreen.screens[0]
    }

    // MARK: Debug

    func freeze() {
        model.frozen = true
        tick?.invalidate(); tick = nil
        expiry.removeAll()
    }

    var panelWindowNumber: Int? { panel?.windowNumber }
    var panelFrame: NSRect? { panel?.frame }
}
