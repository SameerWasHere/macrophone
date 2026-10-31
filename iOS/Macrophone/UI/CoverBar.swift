import SwiftUI
import UIKit

// The iPhone Duo's cover screen (Oct 30 2026, Sameer: "None of the controls have been put in the
// side bar"). The cover turns the status bar into a column on the camera side — Apple's "vertical
// bar", an 84 pt safe-area inset — and puts a screen's toolbar items in it, under the clock, so
// the content keeps the whole height. Only real toolbar items go there (a drawn top bar never
// does), so on the cover the main screen sits in a NavigationStack and its buttons are toolbar
// items: History and Settings at rest; Done, then Sound, Mac Controls, zoom out and Window while a
// window shows. Every other screen and iPhone keeps its drawn bars.

/// Whether the system places a vertical bar here (`UITraitCollection.verticalBarEdge`, iOS 27.1):
/// read from UIKit, since SwiftUI has no environment value for it.
struct VerticalBarProbe: UIViewRepresentable {
    @Binding var present: Bool

    func makeUIView(context: Context) -> UIView {
        if #available(iOS 27.1, *) {
            let v = Probe()
            v.onChange = { on in if present != on { present = on } }
            return v
        }
        return UIView()
    }

    func updateUIView(_ view: UIView, context: Context) {}

    @available(iOS 27.1, *)
    final class Probe: UIView {
        var onChange: (Bool) -> Void = { _ in }

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            registerForTraitChanges(UITraitCollection.systemTraitsAffectingVerticalBarEdge) { (v: Probe, _: UITraitCollection) in v.report() }
        }

        required init?(coder: NSCoder) { fatalError() }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            report()
        }

        private func report() {
            guard window != nil else { return }
            let on = traitCollection.verticalBarEdge != .unspecified
            DispatchQueue.main.async { self.onChange(on) }
        }
    }
}

extension View {
    /// The cover's stack draws nothing of its own (the sky shows through), and its toolbar items
    /// keep their place in the vertical bar first. The cover is iOS 27.1 only.
    @ViewBuilder func coverBarStyle() -> some View {
        if #available(iOS 27.1, *) {
            toolbarBackgroundVisibility(.hidden, for: .navigationBar)
                .toolbarVerticalCompressionBehavior(.prefersToolbarItems)
                .containerBackground(.clear, for: .navigation)
        } else { self }
    }
}

/// Sound in the cover's bar: the Mac's sound here, on or off.
struct CoverSoundItem: View {
    @ObservedObject var player: MacAudioPlayer

    var body: some View {
        Button { player.toggle() } label: {
            Label("Sound", systemImage: !player.isOn ? "speaker" : player.playing ? "speaker.wave.2.fill" : "speaker.fill")
        }
        .tint(player.isOn ? Light.cyan : nil)
        .accessibilityValue(player.isOn ? "On" : "Off")
        .accessibilityHint(player.isOn ? "Stops playing your Mac's sound here." : "Plays your Mac's sound here while the window shows.")
        .accessibilityIdentifier("watch-sound")
    }
}

/// Whole Screen in the cover's bar: one display a tap, several a menu of them.
struct CoverWholeScreenItem: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var watcher: Watcher
    @ObservedObject private var reach = MacReach.shared

    var body: some View {
        Group {
            if reach.several {
                Menu { WholeScreenItems(watcher: watcher) } label: { Label("Whole Screen", systemImage: "display.2") }
            } else {
                Button { model.watchWholeScreen() } label: { Label("Whole Screen", systemImage: "display") }
            }
        }
        .accessibilityHint(reach.several ? "Pick a display to see and use, live." : "See and use your Mac's whole screen, live.")
        .accessibilityIdentifier("whole-screen")
    }
}

/// The Mac in the cover's bar: its light in the glyph; a tap is the Mac pill's (the Macs list with
/// several, Settings with one, pairing with none).
struct CoverMacItem: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Button {
            model.sheet = model.pairedMacs.count > 1 ? .macs : model.isPaired ? .settings : .pairing
        } label: {
            Label(model.pairedMac?.name ?? "Mac", systemImage: "laptopcomputer")
        }
        .tint(model.isConnected ? Light.cyan : nil)
        .accessibilityLabel("Mac: \(model.pairedMac?.name ?? "not paired")")
        .accessibilityValue(model.isConnected ? "Connected" : "Not connected")
        .accessibilityIdentifier("cover-mac")
    }
}
