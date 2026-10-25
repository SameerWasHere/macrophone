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
    @ScaledMetric(relativeTo: .subheadline) private var dotSize: CGFloat = 7

    init(recorder: Recorder, holding: Bool, font: Font = .subheadline) {
        self.recorder = recorder
        self.words = recorder.words
        self.holding = holding
        self.font = font
    }

    var body: some View {
        let (text, color) = content
        let check = landedWell
        let miss = landedMiss
        Group {
            if text.isEmpty {
                // Nothing to say: the slot stays (the mic never moves), empty.
                Color.clear.accessibilityHidden(true)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, Space.text)
        .animation(.easeInOut(duration: 0.2), value: text)
    }

    private var settingsLink: Bool { if case .problem(_, true) = model.status { return true }; return false }

    /// The line fills its fixed slot (MainView): a long one shrinks to fit whole — never cut.
    private func line(_ text: String, _ color: Color, link: Bool, check: Bool, miss: Bool = false) -> some View {
        // The dot rides in the sentence, so it stays beside the first word however the line wraps.
        // Landed where it was meant to go: a ✓ in its place.
        let mark = check
            ? Text(Image(systemName: "checkmark")).font(.subheadline.weight(.bold)).foregroundColor(color)
            : Text(Image(systemName: "circle.fill")).font(.system(size: dotSize)).foregroundColor(color).baselineOffset(dotSize * 0.2)
        // A landing that missed is set in its own colour too, so it can't be read as a success.
        var t = mark + Text("\u{2002}") + (miss ? Text(text).foregroundColor(color) : Text(text))
        if link { t = t + Text("  Open Settings").foregroundColor(Light.cyan).fontWeight(.semibold) }
        return t
            .font(font)
            .foregroundStyle(Ink.secondary)
            .multilineTextAlignment(.center)
            .minimumScaleFactor(0.6)
            .shadow(color: color.opacity(0.25), radius: 6)
    }

    private var landedWell: Bool {
        if model.note != nil { return false }
        if recorder.phase == .recording || recorder.phase == .starting { return false }
        if case .landed(let l) = model.status { return l.isSuccess }
        return false
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
        case .ready:
            if !model.isPaired { return ("Not paired — your words are copied on this iPhone", Ink.tertiary) }
            switch model.linkState {
            case .connected(let name):
                // The pick closed on the Mac: say so before he talks, not after.
                if model.isNotOpen(model.selection.target) {
                    return ("\(model.selection.target.displayName) isn't open on your Mac — it'll be copied instead", Light.ochre)
                }
                // Ready and connected: nothing to say (Oct 19 2026, Sameer: "the subtext under the
                // mic button doesn't seem that useful. All that info is available on other parts of
                // the page" — the Mac's pill says which Mac and how). The line is for news.
                _ = name
                return ("", Light.cyan)
            case .connecting(let name): return ("Connecting to \(name)", Ink.tertiary)
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
            return (l.sentence, l.isSuccess ? Light.mint : (l.copiedInstead ? Light.ochre : Light.rose))
        case .unconfirmed:
            return ("Your Mac received it but didn't confirm where it landed", Light.ochre)
        case .duplicate: return ("Already on your Mac", Light.mint)
        case .queued:
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

