import AppKit
import Carbon.HIToolbox
import MacrophoneKit

/// Keep Awake's rows in the menu bar menu (Nov 7 2026): one "Keep Awake" toggle (its shortcut
/// shown), and while it's on "Displays off · idle 3m" (a click switches them) and "Back at desk
/// in…". When the Mac is set never to sleep with Keep Awake off, a "Restore Normal Sleep" row
/// comes first — one click, never a Mac that can't sleep without saying so.
@MainActor
final class KeepAwakeMenu: NSObject {
    static let shared = KeepAwakeMenu()
    private var keepAwake: KeepAwakeService? { AppDelegate.shared?.model.keepAwake }

    func items() -> [NSMenuItem] {
        guard let k = keepAwake else { return [] }
        let s = k.status
        var out: [NSMenuItem] = []
        if s.sleepStillOff, !s.on {
            out.append(item("Restore Normal Sleep", #selector(restore), symbol: "moon.zzz", detail: "Your Mac is set never to sleep"))
        }
        let main = item(s.busy ? (s.on ? "Turning Off Keep Awake…" : "Turning On Keep Awake…") : "Keep Awake", #selector(toggle),
                        symbol: s.on ? "cup.and.heat.waves.fill" : "cup.and.heat.waves",
                        detail: s.on ? lineWithoutOn(k) : s.blocked)
        main.state = s.on ? .on : .off
        main.isEnabled = !s.busy && (s.on || s.blocked == nil)
        shortcut(main, k.toggleKey)
        out.append(main)
        guard s.on else { return out }
        if s.hasDisplays {
            let d = item(k.displaysLine, #selector(toggleDisplays), symbol: "display",
                         detail: s.displaysOff ? "Click to turn them on" : "Click to turn them off now")
            shortcut(d, k.displaysKey)
            out.append(d)
        }
        let timer = NSMenuItem(title: s.backAt.map { KeepAwakeWords.countdown(to: $0, now: Date()) } ?? "Back at desk in…", action: nil, keyEquivalent: "")
        timer.image = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)
        let sub = NSMenu(title: "Back at desk in…")
        for m in KeepAwakeWords.timerChoices {
            let mi = item(KeepAwakeWords.choice(minutes: m), #selector(setTimer(_:)))
            mi.tag = m
            sub.addItem(mi)
        }
        if s.backAt != nil {
            sub.addItem(.separator())
            let cancel = item("Don't Turn Off Automatically", #selector(setTimer(_:)))
            cancel.tag = 0
            sub.addItem(cancel)
        }
        timer.submenu = sub
        out.append(timer)
        if let p = k.problem {
            out.append(item(p.fix.replacingOccurrences(of: "…", with: "") + "…", #selector(fix), symbol: "exclamationmark.triangle", detail: p.text))
        }
        return out
    }

    /// "lid can close · back at desk at 5:00" — the row's title already says Keep Awake is on.
    private func lineWithoutOn(_ k: KeepAwakeService) -> String {
        let l = k.macLine
        return l.hasPrefix("On · ") ? String(l.dropFirst(5)).prefix(1).uppercased() + String(l.dropFirst(6)) : l
    }

    private func item(_ title: String, _ sel: Selector, symbol: String? = nil, detail: String? = nil) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        mi.target = self
        if let symbol { mi.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        if let detail, !detail.isEmpty {
            if #available(macOS 14.4, *) { mi.subtitle = detail } else { mi.toolTip = detail }
        }
        return mi
    }

    /// Shows a global shortcut beside the row (it works whether or not the menu is open).
    private func shortcut(_ mi: NSMenuItem, _ key: Hotkey) {
        let name = Hotkey.keyName(key.keyCode)
        guard key.enabled, name.count == 1 else { return }
        mi.keyEquivalent = name.lowercased()
        var m: NSEvent.ModifierFlags = []
        if key.modifiers & UInt32(cmdKey) != 0 { m.insert(.command) }
        if key.modifiers & UInt32(optionKey) != 0 { m.insert(.option) }
        if key.modifiers & UInt32(controlKey) != 0 { m.insert(.control) }
        if key.modifiers & UInt32(shiftKey) != 0 { m.insert(.shift) }
        mi.keyEquivalentModifierMask = m
    }

    @objc private func toggle() { keepAwake?.toggle() }
    @objc private func toggleDisplays() { keepAwake?.toggleDisplays() }
    @objc private func restore() { keepAwake?.restoreNormalSleep() }
    @objc private func setTimer(_ sender: NSMenuItem) { keepAwake?.setTimer(minutes: sender.tag == 0 ? nil : sender.tag) }
    @objc private func fix() {
        guard let k = keepAwake, let p = k.problem else { return }
        if p == .needsHelper || p == .helperGone { AppDelegate.shared?.openMainWindow(pane: .keepAwake) }
        k.fix(p)
    }
}
