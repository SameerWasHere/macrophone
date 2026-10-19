import SwiftUI

/// Sound (Oct 19 2026): the Mac's audio with the window — a speaker in the header, its own piece of
/// glass beside the zoom-out and Window cluster. Off by default; a tap turns it on (remembered) and
/// lights it cyan; while the mic is open it shows paused (the mic wins, and it comes back after).
/// Shown only when the connected Mac sends its sound.
struct WatchSoundButton: View {
    @ObservedObject var player: MacAudioPlayer

    private var symbol: String {
        guard player.isOn else { return "speaker.slash" }
        return player.playing ? "speaker.wave.2.fill" : "speaker.fill"
    }

    var body: some View {
        if player.macCanPlay { button }
    }

    private var button: some View {
        Button { player.toggle() } label: {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 20)
        }
        .buttonStyle(WatchCellStyle(width: 42, height: WatchLook.header, tint: player.isOn ? Light.cyan : Ink.ink))
        .watchGlass(Capsule())
        .accessibilityLabel("Sound")
        .accessibilityValue(player.isOn ? "On" : "Off")
        .accessibilityHint(player.isOn ? "Stops playing your Mac's sound here." : "Plays your Mac's sound here while the window shows.")
        .accessibilityAddTraits(player.isOn ? .isSelected : [])
        .accessibilityIdentifier("watch-sound")
    }
}
