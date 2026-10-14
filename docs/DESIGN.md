# Macrophone — design language

The spec asks for the look of SameerOS's **Hey Claude** voice HUD on both the iPhone mic screen
and the Mac popup. Macrophone is a public product, so it borrows that *language* but has its
own name and mark. No SameerOS names, no Thread-as-agent semantics, no "Aurora sky" scenes.

## Reference code (read, don't copy wholesale)

- Hey Claude HUD: `~/claude-projects/SameerOS-Mac/SameerOSMac/Voice/Overlay.swift`,
  `Voice/VoiceThread.swift` (the voice-reactive filament), `Views/ThreadRig.swift` (the CA filament).
- Tokens: `~/claude-projects/SameerOS/SameerOS/Views/Components/Brand.swift`
  (`Brand.Ink`, `Brand.Light`, `Brand.threadStops`, `BrandMotion`).
- iPhone voice sheet: `~/claude-projects/SameerOS/SameerOS/Views/Components/VoiceCapture.swift`.

## The look

- **Ground:** near-black blue ink — `#05060D` ground, `#131520` raised (`0.075,0.082,0.125`),
  hairlines at 8 / 14 / 22% of the ink colour `#F4F2FA`. Text: ink `#F4F2FA`, secondary
  `#C9C8CF`, tertiary `#9E9DA5`. Dark is the identity; both apps force dark appearance.
- **The Filament** is the waveform — on the iPhone, the Hey Claude Thread itself (Oct 13 2026):
  three strands braided into one tapered luminous ribbon (spectrum fills through ribbon masks, a
  soft glow, white-hot cores, a bloom of light behind), drawn in Core Animation. It moves with the
  voice the Hey Claude way (`VoiceDriver`: attack fast, release slow; the weave's height, the
  strands' spread and thickness and the light follow the level; the phase runs faster while he
  speaks and calms in pauses; an onset lifts the cores). The level is loudness against the room's
  own floor, not a fixed dB line. Gradient through the lights: violet `#9A86E6` → cyan `#58B9DE`
  → mint `#5ED6A2` → gold `#E8C06C` → coral `#E9806A`. Ready = a calm, still S in the cool end
  (costs nothing). Listening (mic open, no words yet) = the cool end, a sweep of light, already
  following the voice. Capturing = full spectrum, alive. Sending = beads of light flow along the
  strands. Delivered = it settles flat in mint and a ✓ pops in (ease-out-back). Queued = ochre
  `#C99D68`, flat and dim. Error = rose `#E66E7E`, broken into dashes. The page's sky follows the
  same state (cool, ember while the mic is open, mint when it lands).
- **Meaning colours:** mint = delivered, ochre = queued/caution, rose = failure, ember = the mic
  is live / your action, cyan = connected Mac.
- **Type:** chrome in SF. The transcript in **New York serif** (`.serif` design) — the words are
  the hero. Status kickers and timers in **SF Mono**, small caps tracking ~1.2. No emojis.
- **Motion:** springs — settle (0.4, 0.85), snap (0.25, 0.7), arrive (0.35, 0.85),
  depart (0.45, 0.86). Everything respects Reduce Motion (fades, a still filament).
- **Haptics (phone):** `light` on record start, `soft` on stop, `success` on delivered,
  `warning` on queued, `error` on failure, and a selection `tick` when a control by the mic
  changes (a place, Send after pasting, a cleanup step). Nothing on ordinary navigation taps.
- **The mic screen (phone, Oct 13 2026, the native pass):** top to bottom — the top bar (Mac
  pill, History, Settings), the header ("Speak, and it's on your Mac." in serif + "Tap to talk, tap
  again to send. Or hold, and let go."), flexible space, then **the controls panel in thumb reach**
  just above the Thread, then the mic (never moves) and the status line. While recording the header
  and panel step aside and the transcript fills the area from the top down.
- **The controls panel is Apple's own controls, nothing hand-drawn:** one grouped panel (a rounded
  `.regularMaterial` plate with a hairline — the controls on it are the glass; glass on glass blurs
  twice and merges the buttons into the panel) with inset hairlines between three
  rows. **Send to** — "SEND TO" + the picked place's name, prominent; then a horizontal row of
  native buttons, one per place (Clipboard, Where I'm typing, the Mac's open apps newest first): the
  icon with the short name under it, `.glass` for the others and `.glassProminent` tinted cyan for
  the pick (dark label), so the selection *is* the button (`.bordered` / `.borderedProminent`
  below iOS 26). Long-press an app with several windows → a native context menu of its windows. A
  picked app that closed stays in the row, dimmed, "Not open". No full list sheet, no end-cap.
  **Send after pasting** — a native `Toggle` (cyan) with the full name and one line saying what it
  does for the picked place ("Presses Return in Claude after pasting"; for Clipboard, greyed out:
  "Clipboard only copies — pick an app to send"). **Cleanup** — the label, a native segmented
  `Picker` (Off · Light · Medium · Heavy · Custom), and one line for the picked level ("Medium —
  fixes grammar and false starts"), with an **Edit instructions** `.glass` button beside it for
  Custom; unavailable → the picker disabled and the line says why. A change ticks; the status line
  then says in a sentence what the next dictation will do.
- **Glass:** on iOS 26+ the phone uses Apple's native Liquid Glass through system styles only —
  `.buttonStyle(.glass)` / `.glassProminent` (the Mac pill, History and Settings as circular glass
  buttons, the places, Edit instructions, the sheets' Done via `doneButtonStyle`), the segmented
  picker and switch as the system draws them, `glassEffect` for the other panels (`.glass(radius)`). Below iOS 26: `.bordered` buttons, material panels with a hairline
  (radii 14 / 18 / 22). Rules: glass carries controls, never the words (the transcript and header
  sit on the ground); a tinted pick's label is dark ink; Increase Contrast adds a firm 1pt edge.
  The mic is a disc inside the spectrum ring, ember while it listens (same size, never moves).

- **Watching (phone, Oct 14 2026):** the picked app's window, live, in the area above the Thread
  (the mic, the Thread and the status line don't move). It opens by itself after a dictation is
  *sent* into an app (Settings › Show the app after sending, on by default) or from **Watch** beside
  the Send to name; Done closes it. Top to bottom: a mono kicker ("● LIVE · CLAUDE", cyan dot) with
  Done, the window on a raised plate (radius 14, hairline) — opening on the column you type in
  (the Mac sends the composer's frame as `focus`) at the bottom, staying pinned as pictures arrive
  until you pinch or drag (then a **Newest** button brings it back). **A tap is a click there on
  the Mac** (a cyan ring shows where), so you can switch sessions in Claude's sidebar. Under it, **four keys, the same in every app: Esc · ↑ · ↓ · Return**
  (Sameer: basic keys to move through a menu, confirm or back out — Approve / Stop / Copy were
  removed the same day; a key brings the view back to the newest output). Holding the mic shrinks the window
  to a strip (the bottom of it) above the transcript. States over the dimmed picture: Opening,
  Paused to save battery (two idle minutes or the app left the screen; Resume), Mac not connected,
  Screen Recording needed (one button opens the setting on the Mac), unavailable with why
  ("Claude's window is minimized or on another desktop" + Show it on my Mac).

## Voice of the words

Plain, short, sentence case, no jargon, never cut with "…" (wrap instead). Status lines say
what happened and what to do: "Mac not found — saved, it'll send when your Mac is back."
Delivered: "Delivered to Sameer's MacBook Pro · Copied". No internal names on screen.

## App icon

A dark ink rounded square with the Filament crossing it as a single luminous stroke that
swells in the middle like a voice peak — the spectrum gradient above. Same mark on both apps;
the Mac icon follows the macOS squircle grid with a subtle depth. The menu bar icon is a
monochrome template version (a short filament with a peak), with a dot state when connected.
