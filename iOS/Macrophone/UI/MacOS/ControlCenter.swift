import MacrophoneKit
import SwiftUI

// Mac Controls as the Mac's own Control Center (Nov 1 2026): modules in rounded glass — Sound
// (a slider you can drag, the speaker to mute), Display (dimmer, brighter), Now Playing (previous,
// play or pause, next) — and, while a window shows and the Mac can, Hear Your Mac. A Mac moves the
// volume in sixteenths, one key at a time, so the slider sends a key per sixteenth it crosses and
// shows the level the Mac reads back. Brightness can't be read back, so its module is two keys.

struct MacControlCenter: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var reach = MacReach.shared
    /// Keep Awake's answers redraw the panel (its tile appears with the first one).
    @ObservedObject private var keepAwake = KeepAwakeModel.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var measured: CGFloat?
    /// Each key's taps: its glyph hops as it's pressed (the slider's steps don't).
    @State private var taps: [MacControl: Int] = [:]

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Control Center").font(.footnote.weight(.semibold)).foregroundStyle(Ink.secondary)
                    Text(model.macName).font(.title2.weight(.bold)).foregroundStyle(Ink.ink).oneLine(shrink: 0.7)
                }
                Spacer(minLength: 8)
                Button("Done") { dismiss() }
                    .doneButtonStyle()
                    .accessibilityIdentifier("mac-controls-done")
            }
            .padding(.bottom, 4)
            if model.watcher.isShowing, model.macAudio.macCanPlay {
                HearYourMacModule(player: model.macAudio)
            }
            // Keep Awake (Nov 7 2026): only with a Mac that has it.
            if let k = model.keepAwakeShown { KeepAwakeModule(status: k) }
            soundModule
            HStack(spacing: 12) {
                displayModule
                nowPlayingModule
            }
            Text(reach.lastControl.map { $0.ok ? "" : $0.detail } ?? "")
                .font(.footnote)
                .foregroundStyle(Light.ochre)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 16)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(reach.lastControl?.ok ?? true)
        }
        .padding(.horizontal, Space.margin)
        .padding(.top, 24)
        .padding(.bottom, 10)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measured = ceil($0) }
        .frame(maxHeight: .infinity, alignment: .top)
        .presentationDetents([.height(measured ?? 440)])
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: reach.lastControl)
    }

    // MARK: Modules

    private var soundModule: some View {
        let known = model.macVolumeShown
        let muted = known?.muted == true
        return CCModule(title: "Sound") {
            HStack(spacing: 12) {
                Button { model.press(.mute) } label: {
                    Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(CCRoundStyle(on: !muted))
                .accessibilityLabel(muted ? "Unmute" : "Mute")
                .accessibilityIdentifier("mac-control-mute")
                // The slider between its two ends, as a Mac's: a tap on an end is one step.
                HStack(spacing: 4) {
                    volumeEnd(.volumeDown, symbol: "speaker.fill")
                    VolumeSlider(level: known?.volume, muted: muted, onStep: { up in model.press(up ? .volumeUp : .volumeDown) })
                    volumeEnd(.volumeUp, symbol: "speaker.wave.3.fill")
                }
            }
        } footer: {
            Text(known?.line ?? "Press + or − to change your Mac's volume")
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: known)
        }
        .onAppear {
            reach.forgetVolumes(except: model.pairedMacs.map(\.id))
            KeepAwakeModel.shared.forget(except: model.pairedMacs.map(\.id))
        }
    }

    private var displayModule: some View {
        CCModule(title: "Display") {
            HStack(spacing: 10) {
                keyButton(.brightnessDown)
                keyButton(.brightnessUp)
            }
        }
    }

    private var nowPlayingModule: some View {
        CCModule(title: "Now Playing") {
            HStack(spacing: 4) {
                ForEach(MacControl.media) { c in
                    Button { tap(c) } label: {
                        Image(systemName: c.symbol).font(.system(size: c == .playPause ? 22 : 17, weight: .semibold))
                            .symbolEffect(.bounce, value: taps[c] ?? 0)
                    }
                        .buttonStyle(CCGlyphStyle())
                        .accessibilityLabel(c.title)
                        .accessibilityIdentifier("mac-control-\(c.rawValue)")
                }
            }
        }
    }

    private func tap(_ c: MacControl) {
        taps[c, default: 0] += 1
        model.press(c)
    }

    private func volumeEnd(_ c: MacControl, symbol: String) -> some View {
        Button { tap(c) } label: {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.secondary)
                .symbolEffect(c == .volumeUp ? .bounce.up : .bounce.down, value: taps[c] ?? 0)
                .frame(width: 30, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(c.title)
        .accessibilityIdentifier("mac-control-\(c.rawValue)")
    }

    private func keyButton(_ c: MacControl) -> some View {
        Button { tap(c) } label: { Image(systemName: c.symbol).symbolEffect(.bounce, value: taps[c] ?? 0) }
            .buttonStyle(CCRoundStyle(on: false))
            .accessibilityLabel(c.title)
            .accessibilityHint("Presses it on your Mac.")
            .accessibilityIdentifier("mac-control-\(c.rawValue)")
    }
}

/// A Control Center module: a rounded glass tile with its name over its controls.
struct CCModule<Content: View, Footer: View>: View {
    var title: String
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Ink.ink)
            content()
            footer().font(.caption).foregroundStyle(Ink.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: MacOSLook.module, style: .continuous).fill(Ink.ink.opacity(0.06)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

extension CCModule where Footer == EmptyView {
    init(title: String, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, content: content, footer: { EmptyView() })
    }
}

/// Control Center's round button: filled with the accent when on, a quiet disc when not.
struct CCRoundStyle: ButtonStyle {
    var on: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(on ? Color.white : Ink.ink)
            .frame(width: 44, height: 44)
            .background(Circle().fill(on ? AnyShapeStyle(Light.cyan) : AnyShapeStyle(Ink.ink.opacity(0.1))))
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(Circle())
    }
}

/// A glyph button in a module (the transport keys): no plate, a press dims it.
struct CCGlyphStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Ink.ink)
            .frame(maxWidth: .infinity, minHeight: 44)
            .opacity(configuration.isPressed ? 0.45 : 1)
            .contentShape(Rectangle())
    }
}

/// The volume as a Mac's Control Center slider: a fat track, filled to the level. A drag crosses
/// sixteenths and each one is a volume key on the Mac, counted from the Mac's real level, so the
/// keys sent match the distance dragged; the fill follows the finger at once and settles to what
/// the Mac reads back. Muted, the fill stays at the level, faded (a key unmutes from there).
/// Unknown (a Mac that hasn't said), it's the bare track: nothing to drag from — the ends and
/// mute still work.
struct VolumeSlider: View {
    /// The Mac's level, 0…1; nil while unknown.
    var level: Double?
    var muted = false
    var onStep: (Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragging: Double?
    @State private var sentFrom: Int?

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Ink.ink.opacity(0.12))
                if let shown = dragging ?? level {
                    Capsule().fill(Ink.ink.opacity(0.85))
                        .frame(width: max(g.size.height, g.size.width * shown))
                        .opacity(muted && dragging == nil ? 0.3 : 1)
                        .transition(.opacity)
                }
            }
            .contentShape(Capsule())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    guard let level else { return }
                    let f = min(1, max(0, v.location.x / max(1, g.size.width)))
                    dragging = f
                    let from = sentFrom ?? MacVolume.step(of: level)
                    let step = MacVolume.step(of: f)
                    if sentFrom == nil { sentFrom = from }
                    guard step != from else { return }
                    for _ in 0..<abs(step - from) { onStep(step > from) }
                    Haptics.pick()
                    sentFrom = step
                }
                .onEnded { _ in
                    sentFrom = nil
                    withAnimation(.easeOut(duration: 0.3)) { dragging = nil }
                })
            .allowsHitTesting(level != nil)
        }
        .frame(height: 28)
        .animation(reduceMotion || dragging != nil ? nil : .easeOut(duration: 0.25), value: level)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: muted)
        .accessibilityElement()
        .accessibilityLabel("Volume")
        .accessibilityValue(accessibilityWords)
        .accessibilityAdjustableAction { d in onStep(d == .increment) }
        .accessibilityIdentifier("mac-volume-slider")
    }

    private var accessibilityWords: String {
        guard let level else { return muted ? "Muted" : "Unknown" }
        let percent = "\(Int((level * 100).rounded())) percent"
        return muted ? "Muted, \(percent)" : percent
    }
}

/// Hear Your Mac — the phone's Sound, while a window shows — as a toggle module.
struct HearYourMacModule: View {
    @ObservedObject var player: MacAudioPlayer

    var body: some View {
        Button { player.toggle() } label: {
            HStack(spacing: 12) {
                Image(systemName: player.isOn ? "speaker.wave.2.fill" : "speaker")
                    .font(.system(size: 17, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(player.isOn ? Color.white : Ink.ink)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(player.isOn ? AnyShapeStyle(Light.cyan) : AnyShapeStyle(Ink.ink.opacity(0.1))))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hear Your Mac").font(.subheadline.weight(.semibold)).foregroundStyle(Ink.ink)
                    Text(player.isOn ? "On — your Mac's sound plays here" : "Off").font(.caption).foregroundStyle(Ink.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: MacOSLook.module, style: .continuous).fill(Ink.ink.opacity(0.06)))
            .contentShape(RoundedRectangle(cornerRadius: MacOSLook.module, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Hear Your Mac")
        .accessibilityValue(player.isOn ? "On" : "Off")
        .accessibilityIdentifier("cc-hear-mac")
    }
}
