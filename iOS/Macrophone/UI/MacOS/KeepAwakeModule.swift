import MacrophoneKit
import SwiftUI

/// Keep Awake in the Mac's Control Center (Nov 7 2026): a toggle module like Focus or Wi-Fi — the
/// round button lit while on, "Keep Awake" and one line under it ("Lid can close · 84%", "Stays
/// awake" on a desktop, the reason when it can't) — and while on, the displays as a second button
/// and the battery. Anything wrong is one plain sentence; the fix lives on the Mac.
struct KeepAwakeModule: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var keepAwake = KeepAwakeModel.shared
    let status: KeepAwakeStatus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var pending: KeepAwakeRequest.Action? { keepAwake.pending }
    /// What the button shows: the tap's result at once, the Mac's answer when it comes.
    private var shownOn: Bool {
        switch pending {
        case .on?, .timer?: return status.blocked == nil
        case .off?: return false
        default: return status.on
        }
    }
    private var shownDisplaysOff: Bool {
        switch pending {
        case .displaysOff?: return true
        case .displaysOn?: return false
        default: return status.displaysOff
        }
    }
    private var enabled: Bool { model.canKeepAwake && (status.on || status.blocked == nil) && !status.busy }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button { model.askKeepAwake(shownOn ? .off : .on) } label: {
                    ZStack {
                        Image(systemName: shownOn ? "cup.and.heat.waves.fill" : "cup.and.heat.waves")
                            .contentTransition(.symbolEffect(.replace))
                            .opacity(pending == .on || pending == .off || status.busy ? 0 : 1)
                        if pending == .on || pending == .off || status.busy { ProgressView().tint(shownOn ? .white : Ink.ink) }
                    }
                }
                .buttonStyle(CCRoundStyle(on: shownOn))
                .disabled(!enabled)
                .accessibilityLabel("Keep Awake")
                .accessibilityValue(shownOn ? "On, \(status.phoneLine)" : status.phoneLine)
                .accessibilityAddTraits(.isToggle)
                .accessibilityHint(shownOn ? "Lets your Mac sleep again." : "Keeps your Mac on so you can use it from here.")
                .accessibilityIdentifier("cc-keep-awake")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep Awake").font(.subheadline.weight(.semibold)).foregroundStyle(Ink.ink)
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(status.blocked != nil && !status.on ? Light.ochre : Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                        .accessibilityIdentifier("cc-keep-awake-line")
                }
                Spacer(minLength: 0)
            }
            if shownOn, status.hasDisplays {
                HStack(spacing: 12) {
                    Button { model.askKeepAwake(shownDisplaysOff ? .displaysOn : .displaysOff) } label: {
                        Image(systemName: shownDisplaysOff ? "display" : "sun.max.fill")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(CCRoundStyle(on: !shownDisplaysOff))
                    .disabled(!model.canKeepAwake)
                    .accessibilityLabel("Displays")
                    .accessibilityValue(shownDisplaysOff ? "Off" : "On")
                    .accessibilityAddTraits(.isToggle)
                    .accessibilityIdentifier("cc-keep-awake-displays")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(shownDisplaysOff ? "Displays off" : "Displays on").font(.subheadline.weight(.semibold)).foregroundStyle(Ink.ink)
                        Text(shownDisplaysOff ? "They turn on with a key or the mouse on your Mac" : "They turn off by themselves when nobody's at your Mac")
                            .font(.caption).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if let note {
                Label(note, systemImage: status.problem != nil || status.sleepStillOff ? "exclamationmark.triangle.fill" : "info.circle")
                    .font(.footnote)
                    .foregroundStyle(Light.ochre)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("cc-keep-awake-note")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: MacOSLook.module, style: .continuous).fill(Ink.ink.opacity(0.06)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Keep Awake")
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: shownOn)
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: shownDisplaysOff)
    }

    /// The line under the name: while a tap waits, what's happening; else the Mac's words.
    private var line: String {
        switch pending {
        case .on?: return "Turning on…"
        case .off?: return "Turning off…"
        default:
            if !model.isConnected { return "Last known · " + status.phoneLine }
            return status.phoneLine
        }
    }

    /// One sentence when something needs him (the fix is on the Mac), or worth knowing.
    private var note: String? {
        if status.sleepStillOff, !status.on { return "Your Mac is set never to sleep. Open Macrophone on your Mac and choose Restore Normal Sleep." }
        if let p = status.problem { return p }
        if let w = status.warning, status.on { return w }
        if let at = status.backAt, status.on {
            return "Turns off at \(at.formatted(date: .omitted, time: .shortened))."
        }
        return nil
    }
}
