import AppKit
import SwiftUI

/// Desk dictation's listening pill (Nov 7 2026): a small glass capsule at the bottom middle of the
/// screen the pointer is on, over everything, on every Space. A borderless non-activating panel
/// that takes no clicks — the app you were typing in stays in front, so the paste lands there.
/// Apple Intelligence's colours ring the mic and breathe with your voice; the words come in as
/// you say them, newest at the end; "Esc to cancel" faint under them. It follows the system's
/// light or dark (the rest of Macrophone's window is dark), and fades — no motion — with Reduce
/// Motion on.
@MainActor
final class ListeningPill {
    private var panel: NSPanel?
    private unowned let desk: DeskDictation
    private var hiding = false
    static let size = NSSize(width: 484, height: 100)

    init(desk: DeskDictation) { self.desk = desk }

    var frame: NSRect? { panel?.frame }
    var windowNumber: Int? { panel?.windowNumber }

    func show() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["MACROPHONE_DESK_NO_PILL"] == "1" { return }
        #endif
        let p = panel ?? make()
        panel = p
        p.appearance = Self.systemAppearance
        if !p.isVisible || hiding {
            hiding = false
            p.setFrame(Self.place(), display: false)
            p.alphaValue = p.isVisible ? p.alphaValue : 0
            p.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { c in
                c.duration = 0.16
                c.timingFunction = CAMediaTimingFunction(name: .easeOut)
                p.animator().alphaValue = 1
            }
        }
    }

    func hide() {
        guard let p = panel, p.isVisible, !hiding else { return }
        hiding = true
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 0.25
            c.timingFunction = CAMediaTimingFunction(name: .easeIn)
            p.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.hiding else { return }
                self.hiding = false
                p.orderOut(nil)
            }
        })
    }

    /// Bottom middle of the screen with the pointer, above the Dock.
    static func place() -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSRect(x: vf.midX - size.width / 2, y: vf.minY + 16, width: size.width, height: size.height)
    }

    /// The system's own light or dark — Macrophone forces dark on its windows (NSApp.appearance).
    static var systemAppearance: NSAppearance? {
        let dark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle")?.lowercased() == "dark"
        #if DEBUG
        if let forced = ProcessInfo.processInfo.environment["MACROPHONE_DESK_APPEARANCE"] {
            return NSAppearance(named: forced == "light" ? .aqua : .darkAqua)
        }
        #endif
        return NSAppearance(named: dark ? .darkAqua : .aqua)
    }

    private func make() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.title = "Macrophone Listening"
        let host = NSHostingView(rootView: PillView(desk: desk))
        host.frame = NSRect(origin: .zero, size: Self.size)
        p.contentView = host
        return p
    }
}

private struct PillView: View {
    @ObservedObject var desk: DeskDictation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 14) {
            LevelRing(level: CGFloat(desk.level), active: desk.isListening, still: reduceMotion)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 3) {
                words
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .opacity(0.7)
                    .lineLimit(1)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 22)
        .frame(width: ListeningPill.size.width - 28, height: ListeningPill.size.height - 28)
        .background(glass)
        .frame(width: ListeningPill.size.width, height: ListeningPill.size.height)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityWords)
    }

    @ViewBuilder private var glass: some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        if #available(macOS 26.0, *) {
            shape.fill(.clear).glassEffect(.regular, in: shape)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
        } else {
            shape.fill(.regularMaterial)
                .overlay(shape.strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.2), radius: 10, y: 3)
        }
    }

    private var words: Text {
        switch desk.phase {
        case .note(let s):
            return Text(s)
        case .finishing where desk.settled.isEmpty && desk.pending.isEmpty:
            return Text("Finishing…").foregroundStyle(.secondary)
        default:
            if desk.settled.isEmpty && desk.pending.isEmpty { return Text("Listening…").foregroundStyle(.secondary) }
            let (s, p) = Self.newest(settled: desk.settled, pending: desk.pending)
            let pend = p.isEmpty ? Text("") : Text((s.isEmpty ? "" : " ") + p).foregroundStyle(.secondary)
            return Text(s) + pend
        }
    }

    /// The newest words that fit two lines, cut at a word with "…" in front — the pill always
    /// ends on what was just said (a head-truncated Text only works on one line). The words still
    /// being decided keep their own, dimmer, part.
    static func newest(settled: String, pending: String, limit: Int = 100) -> (String, String) {
        let sep = (!settled.isEmpty && !pending.isEmpty) ? " " : ""
        let full = settled + sep + pending
        guard full.count > limit else { return (settled, pending) }
        var drop = full.count - limit
        let start = full.index(full.startIndex, offsetBy: drop)
        if let space = full[start...].firstIndex(of: " ") { drop = full.distance(from: full.startIndex, to: space) + 1 }
        let keptSettled = drop < settled.count ? String(settled.dropFirst(drop)) : ""
        let keptPending = String(pending.dropFirst(max(0, drop - settled.count - sep.count)))
        if keptSettled.isEmpty { return ("", "…" + keptPending) }
        return ("…" + keptSettled, keptPending)
    }

    private var hint: String {
        switch desk.phase {
        case .listening(let handsFree):
            return handsFree ? "Hands-free · tap \(keyName) to finish · Esc to cancel" : "Let go to paste · Esc to cancel"
        case .finishing(let s): return s.isEmpty ? "Finishing…" : s
        case .note: return "It's in History"
        case .idle: return ""
        }
    }

    private var keyName: String {
        desk.keyShort
    }

    private var accessibilityWords: String {
        switch desk.phase {
        case .listening: return "Listening. \(desk.settled) \(desk.pending)"
        case .finishing(let s): return s.isEmpty ? "Finishing" : s
        case .note(let s): return s
        case .idle: return ""
        }
    }
}

/// Apple Intelligence's colours round the mic: grows and brightens with the voice, turns slowly
/// while listening (still under Reduce Motion).
private struct LevelRing: View {
    let level: CGFloat
    let active: Bool
    let still: Bool

    private static let colours: [Color] = MacOSIntelligence.colours.map { Color(cgColor: $0) }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: still || !active)) { context in
            let angle = still ? 0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 4) / 4 * 360
            let gradient = AngularGradient(colors: Self.colours, center: .center, angle: .degrees(angle))
            let swell = still ? 1 : 1 + level * 0.18
            ZStack {
                Circle()
                    .strokeBorder(gradient, lineWidth: 6)
                    .blur(radius: 5)
                    .opacity(active ? 0.35 + Double(level) * 0.55 : 0.2)
                    .scaleEffect(swell)
                Circle()
                    .strokeBorder(gradient, lineWidth: 2.5)
                    .opacity(active ? 0.75 + Double(level) * 0.25 : 0.45)
                    .scaleEffect(still ? 1 : 1 + level * 0.08)
                Image(systemName: "mic.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            .animation(still ? nil : .easeOut(duration: 0.12), value: level)
        }
        .accessibilityHidden(true)
    }
}
