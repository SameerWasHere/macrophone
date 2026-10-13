import SwiftUI
import UIKit

/// The delivery line under the mic: a dot in the meaning colour and one plain sentence
/// (and, when the fix is in Settings, the button that goes there).
struct StatusLine: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var recorder: Recorder
    var holding: Bool
    @ScaledMetric(relativeTo: .subheadline) private var dotSize: CGFloat = 7

    var body: some View {
        let (text, color) = content
        VStack(spacing: 2) {
            // The dot rides in the sentence, so it stays beside the first word however the line wraps.
            (Text(Image(systemName: "circle.fill")).font(.system(size: dotSize)).foregroundColor(color).baselineOffset(dotSize * 0.2)
             + Text("\u{2002}") + Text(text))
                .font(.subheadline)
                .foregroundStyle(Ink.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .shadow(color: color.opacity(0.25), radius: 6)
                .accessibilityLabel(text)
                .accessibilityAddTraits(.updatesFrequently)
            if case .problem(_, true) = model.status {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Light.cyan)
                .frame(minHeight: 44)
                .padding(.horizontal, 12)
                .contentShape(Rectangle())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .accessibilityElement(children: .contain)
        .animation(.easeInOut(duration: 0.2), value: text)
    }

    private var content: (String, Color) {
        if recorder.phase == .recording || recorder.phase == .starting {
            if recorder.softCapReached { return ("Recording will stop at 10:00", Light.ochre) }
            let live = model.liveRoute(recorder.transcript)
            if live.byVoice, let p = live.profile { return ("Listening — this one goes to \(p.name)", Light.ember) }
            if holding { return ("Listening — let go to send", Light.ember) }
            return ("Listening — tap to send", Light.ember)
        }
        switch model.status {
        case .ready:
            if !model.isPaired { return ("Not paired — your words are copied on this iPhone", Ink.tertiary) }
            switch model.linkState {
            case .connected(let name): return ("Ready · \(name)", Light.cyan)
            case .connecting(let name): return ("Connecting to \(name)", Ink.tertiary)
            case .unreachable(let name): return ("\(name) not found — dictations will wait for it", Light.ochre)
            default: return ("Looking for \(model.macName)", Ink.tertiary)
            }
        case .listening: return ("Listening", Light.ember)
        case .cleaning: return ("Cleaning up", Light.teal)
        case .sending(let mac, let to):
            return (to.map { "Sending to \($0.name) on \(mac)" } ?? "Sending to \(mac)", Light.cyan)
        case .delivered(let mac, let detail, let late, let to):
            var s: String
            if let to, let spoken = to.spoken {
                s = "Sent to \(to.name) — you said “\(spoken)” first"
            } else if let to, detail?.isEmpty ?? true {
                s = "Sent to \(to.name) on \(mac)"
            } else {
                s = "Delivered to \(mac)"
                if let detail, !detail.isEmpty { s += " · \(detail)" }
            }
            if late { s += " · delayed" }
            return (s, Light.mint)
        case .duplicate: return ("Already on your Mac", Light.mint)
        case .queued: return ("Mac not found — queued, it'll send when your Mac is back", Light.ochre)
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

