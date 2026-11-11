import SwiftUI
import UIKit

/// The delivery line under the mic: a dot in the meaning colour and one plain sentence
/// (and, when the fix is in Settings, the button that goes there).
struct StatusLine: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var recorder: Recorder
    /// The live words (a spoken app name changes the line as it's heard).
    @ObservedObject private var words: LiveTranscript
    var holding: Bool
    /// The line's size: the phone's subheadline, or the body on the iPhone Duo's deck (Oct 25
    /// 2026), where it reads from further away.
    var font: Font = .subheadline
    /// One message makes way for the next (the Duo's cover, Nov 4 2026): the old one fades out,
    /// then the new one fades in at its own width — cross-faded, "Cleaning up" and "Sending…" were
    /// drawn over each other, centred at two widths, for a moment.
    var swap = false
    /// The desktop's empty state says what's wrong (no Mac paired, the Mac not found, the
    /// microphone off) and has the fix: the line says nothing about it meanwhile (Nov 5 2026).
    var desktopSays = false
    /// The desktop's empty state has the Open Settings button (the Duo's cover, where it's too
    /// short to say the rest): the line keeps its words without a link of its own.
    var desktopFixes = false
    /// Over the Mac's wallpaper (every place but setup's white page — Nov 8 2026): the words in
    /// the label colour on a halo of the ground, the meaning in the mark alone. Grey and red words
    /// read at 1.6–2 : 1 over the demo's blue and lilac — "Didn't land in Claude" all but vanished.
    var legible = false
    @ScaledMetric(relativeTo: .subheadline) private var dotSize: CGFloat = 7

    init(recorder: Recorder, holding: Bool, font: Font = .subheadline, swap: Bool = false, desktopSays: Bool = false, desktopFixes: Bool = false, legible: Bool = false) {
        self.legible = legible
        self.recorder = recorder
        self.words = recorder.words
        self.holding = holding
        self.font = font
        self.swap = swap
        self.desktopSays = desktopSays
        self.desktopFixes = desktopSays || desktopFixes
    }

    /// Out quickly, then in: never two lines on screen at once.
    private static let swapTransition = AnyTransition.asymmetric(
        insertion: .opacity.animation(.easeOut(duration: 0.18).delay(0.1)),
        removal: .opacity.animation(.easeIn(duration: 0.1)))

    var body: some View {
        let (text, color) = content
        let check = landedWell
        let miss = landedMiss
        ZStack(alignment: .top) {
            Group {
                if text.isEmpty {
                    // Nothing to say: the slot stays (the mic never moves), empty — and no element.
                    EmptyView()
                } else if settingsLink {
                    // The fix is in Settings: the whole line is the way there (no extra row to make room for).
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    } label: { line(text, color, link: true, check: false) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(text)
                    .accessibilityHint("Opens Settings.")
                } else {
                    line(text, color, link: false, check: check, miss: miss)
                        .accessibilityLabel(text)
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }
            .id(swap ? text : "")
            .transition(swap ? Self.swapTransition : .opacity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, Space.text)
        // An empty line is no element at all (an empty slot read as one with no words) — a
        // placeholder of blanks included.
        .accessibilityHidden(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .animation(.easeInOut(duration: 0.2), value: text)
    }

    private var settingsLink: Bool { if !desktopFixes, case .problem(_, true) = model.status { return true }; return false }

    /// The line fills its fixed slot (MainView): a long one shrinks to fit whole — never cut.
    private func line(_ text: String, _ color: Color, link: Bool, check: Bool, miss: Bool = false) -> some View {
        // The dot rides in the sentence, so it stays beside the first word however the line wraps.
        // Landed where it was meant to go: a ✓ in its place.
        let mark: Text
        if check {
            mark = Text(Image(systemName: "checkmark")).font(.subheadline.weight(.bold)).foregroundColor(color)
        } else if miss, legible {
            // Over a wallpaper the words are ink, so a miss says itself in its mark.
            mark = Text(Image(systemName: "exclamationmark.circle.fill")).font(.subheadline.weight(.semibold)).foregroundColor(color)
        } else {
            mark = Text(Image(systemName: "circle.fill")).font(.system(size: dotSize)).foregroundColor(color).baselineOffset(dotSize * 0.2)
        }
        // A landing that missed is set in its own colour too, so it can't be read as a success
        // (on a page; over a wallpaper its mark does that).
        var t = mark + Text("\u{2002}") + (miss && !legible ? Text(text).foregroundColor(color) : Text(text))
        if link { t = t + Text("  Open Settings").foregroundColor(legible ? Ink.ink : Light.cyan).fontWeight(.semibold) }
        let styled = t
            .foregroundStyle(legible ? Ink.ink : Ink.secondary)
            .multilineTextAlignment(.center)
            .shadow(color: legible ? Ink.ground.opacity(0.7) : color.opacity(0.25), radius: legible ? 5 : 6)
        // Never cut with "…" (Nov 10 2026, Sameer: "The dot dot dot should never happen anywhere
        // in the app"): every word shows, on as many lines as it takes. A line too long for its
        // slot steps down a size or two to fit whole; if it still doesn't — or something went
        // wrong, which is read at full size — it grows down out of the slot.
        return Group {
            if trouble {
                styled.font(font).fixedSize(horizontal: false, vertical: true)
            } else {
                ViewThatFits(in: .vertical) {
                    styled.font(font).fixedSize(horizontal: false, vertical: true)
                    styled.font(.caption).fixedSize(horizontal: false, vertical: true)
                    styled.font(.caption2).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var landedWell: Bool {
        if model.note != nil { return false }
        if recorder.phase == .recording || recorder.phase == .starting { return false }
        if case .landed(let l) = model.status { return l.isSuccess }
        return false
    }

    /// A miss, a problem or a caution is showing: never cut short.
    private var trouble: Bool {
        if landedMiss { return true }
        if recorder.phase == .recording || recorder.phase == .starting { return false }
        switch model.status {
        case .problem, .notice: return true
        default: return false
        }
    }

    private var landedMiss: Bool {
        if model.note != nil { return false }
        if recorder.phase == .recording || recorder.phase == .starting { return false }
        if case .landed(let l) = model.status { return !l.isSuccess }
        return false
    }

    private var content: (String, Color) {
        // A control just changed: what it now does, briefly (a problem still wins).
        if let note = model.note {
            switch model.status {
            case .problem, .failed: break
            default: return (note, Light.teal)
            }
        }
        if recorder.phase == .recording || recorder.phase == .starting {
            if recorder.softCapReached { return ("Recording will stop at 10:00", Light.ochre) }
            let live = model.liveRoute(words.text)
            if live.byVoice { return ("Listening — this one goes to \(live.target.displayName)", Light.ember) }
            if holding { return ("Listening — let go to send", Light.ember) }
            return ("Listening — tap to send", Light.ember)
        }
        switch model.status {
        case .problem(_, true) where desktopSays:
            return ("", Ink.tertiary)
        case .ready:
            if !model.isPaired, desktopSays { return ("", Ink.tertiary) }
            if !model.isPaired { return ("Not paired — your words are copied on this iPhone", Ink.tertiary) }
            switch model.linkState {
            // Back from the background with the link on its way (Nov 7 2026): the words it had on
            // leaving, nothing about connecting — `returning` ends before any reconnect begins.
            case .connected, _ where model.returning:
                // The pick closed on the Mac: say so before he talks, not after.
                if model.isNotOpen(model.selection.target) {
                    // A window gone from an app that's still open: the app's name, not the window's
                    // whole title — "Terminal — claude — ~/Projects/…/MacrophoneKit — 120×40 isn't
                    // open" ran to three shrunken lines under the cover's mic (Nov 8 2026).
                    if case let .app(bid, key?, _) = model.selection.target, !key.isEmpty,
                       let app = model.liveTargets.first(where: { $0.bundleID == bid })?.appName {
                        return ("That \(app) window isn't open on your Mac — it'll be copied instead", Light.ochre)
                    }
                    return ("\(model.selection.target.displayName) isn't open on your Mac — it'll be copied instead", Light.ochre)
                }
                // Ready and connected: nothing to say (Oct 19 2026, Sameer: "the subtext under the
                // mic button doesn't seem that useful. All that info is available on other parts of
                // the page" — the Mac's pill says which Mac and how). The line is for news.
                return ("", Light.cyan)
            // The link dropped (Nov 5 2026): one message until it's back, whatever it goes
            // through meanwhile — never "Looking for" → "Connecting to" → "not found" in a blip.
            // Said once (Nov 8 2026, round 3): while a window shows, its own capsule says it.
            case _ where model.reconnecting && model.watcher.isShowing && model.watcher.phase == .reconnecting: return ("", Ink.tertiary)
            case _ where model.reconnecting: return ("Reconnecting to \(model.macName)…", Ink.tertiary)
            case .connecting(let name): return ("Connecting to \(name)", Ink.tertiary)
            // The first moments after the app comes up: one message until it's ready or something's
            // really wrong (Nov 3 2026 — "Looking for" → "Connecting to" → nothing, in a second).
            case _ where model.settling: return ("Connecting to \(model.macName)", Ink.tertiary)
            case .unreachable where desktopSays:
                return ("", Ink.tertiary)
            case .unreachable(let name):
                if model.localNetworkDenied { return ("Local Network is off for Macrophone — turn it on in Settings to reach \(name)", Light.ochre) }
                return ("\(name) not found — dictations will wait for it", Light.ochre)
            default: return ("Looking for \(model.macName)", Ink.tertiary)
            }
        case .listening: return ("Listening", Light.ember)
        case .cleaning: return ("Cleaning up", Light.teal)
        case .sending(let mac, let to):
            return (to.map { "Sending to \($0.name) on \(mac)" } ?? "Sending to \(mac)", Light.cyan)
        case .delivered(let mac, let detail, let late, let to):
            // The Mac's own words lead: "Pasted into Claude", "Sent to Claude",
            // "Claude isn't open on your Mac — copied instead".
            let said = detail.map { $0.hasPrefix("Pasted into") || $0.hasPrefix("Sent to") || $0.hasPrefix("Typed into") } ?? true
            var s: String
            if let to, let spoken = to.spoken, said {
                s = "\(detail.flatMap { $0.isEmpty ? nil : $0 } ?? "\(to.send ? "Sent to" : "Pasted into") \(to.name)") — you said “\(spoken)” first"
            } else if let detail, !detail.isEmpty {
                s = detail
            } else if let to {
                s = "Sent to \(to.name) on \(mac)"
            } else {
                s = "Delivered to \(mac)"
            }
            if late { s += " · delayed" }
            return (s, Light.mint)
        case .landing(_, let to):
            // The Mac has it; its countdown and the paste are under way.
            return (to.map { "Sending to \($0.name)…" } ?? "Sending to your Mac…", Light.cyan)
        case .landed(let l):
            // The pill over the mic says it (Nov 3 2026): the line stays quiet meanwhile.
            // (And after it: it said it — Nov 4 2026.)
            if l.isSuccess, model.landedChip != nil || model.pillSaidIt { return ("", Light.mint) }
            return (l.sentence, l.isSuccess ? Light.mint : (l.copiedInstead ? Light.ochre : Light.rose))
        case .unconfirmed:
            return ("Your Mac received it but didn't confirm where it landed", Light.ochre)
        case .duplicate: return ("Already on your Mac", Light.mint)
        case .queued:
            if model.reconnecting { return ("Queued — it'll send as soon as \(model.macName) is back", Ink.tertiary) }
            if model.localNetworkDenied { return ("Queued — Local Network is off for Macrophone. Turn it on in Settings and it'll send", Light.ochre) }
            return ("Mac not found — queued, it'll send when your Mac is back", Light.ochre)
        case .copiedOnPhone: return ("Copied on iPhone — paste it anywhere", Light.mint)
        case .failed(_, let detail):
            if let detail, !detail.isEmpty {
                return ("Not delivered — \(detail). Fix that on your Mac, then tap Resend.", Light.rose)
            }
            return ("Not delivered. Check Macrophone on your Mac, then tap Resend.", Light.rose)
        case .nothingHeard: return ("Didn't catch anything — try again", Ink.tertiary)
        case .notice(let s): return (s, Light.ochre)
        case .problem(let s, _): return (s, Light.rose)
        }
    }
}

