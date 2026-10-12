import SwiftUI
import UIKit

/// The delivery line under the mic: a dot in the meaning colour and one plain sentence.
struct StatusLine: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var recorder: Recorder
    var holding: Bool

    var body: some View {
        let (text, color) = content
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Spacer(minLength: 0)
            Circle().fill(color).frame(width: 7, height: 7)
                .shadow(color: color.opacity(0.7), radius: 4)
                .alignmentGuide(.firstTextBaseline) { d in d[.bottom] - 1 }
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Ink.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if case .problem(_, true) = model.status {
                Button("Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Light.cyan)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
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
                s = "Sent to \(to.name) — you said “\(spoken), …”"
            } else if let to, detail?.isEmpty ?? true {
                s = "Sent to \(to.name) on \(mac)"
            } else {
                s = "Delivered to \(mac)"
                if let detail, !detail.isEmpty { s += " · \(detail)" }
            }
            if late { s += " · sent late" }
            return (s, Light.mint)
        case .duplicate: return ("Already on your Mac", Light.mint)
        case .queued: return ("Mac not found — queued, it'll send when your Mac is back", Light.ochre)
        case .copiedOnPhone: return ("Copied on iPhone", Light.mint)
        case .failed(let mac, let detail):
            return ("\(mac) couldn't deliver it\(detail.map { " — \($0)" } ?? ""). It's in your history.", Light.rose)
        case .nothingHeard: return ("Didn't catch anything — try again", Ink.tertiary)
        case .notice(let s): return (s, Light.ochre)
        case .problem(let s, _): return (s, Light.rose)
        }
    }
}
