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
- **The mic button (phone, Oct 18 2026, the polish pass — `UI/MicButton.swift`):** every state
  reads on the button itself. Ready = ink glass, a specular rim, the spectrum ring. Pressed = the
  disc sinks to 0.93 on the frame the finger lands (snap). Mic open = ember, the stop square, one
  ring of light leaving; round it a lit rim, a soft bloom and a thin ring that breathes with the
  voice through `VoiceDriver` — Core Animation, a display link only while the mic is open, nothing
  at rest. Finishing (words settling) = a teal arc in the glyph's place. Then the ring takes the
  meaning colour — teal sending, mint landed (a ring arrives into the button), ochre queued, rose
  failed — for as long as the Thread shows it. Microphone off = dim, `mic.slash`, disabled until
  Settings. Reduce Motion: no rings travel, a calm fixed glow; Reduce Transparency: a solid disc;
  Increase Contrast: a firm 2pt ring. The hit target is the ring (104pt). Haptics unchanged.

- **Watching (phone, Oct 14 2026; what it is now — the header cluster, the Window menu, Text, the tips — is the map at the top of `CLAUDE.md`, Oct 18 2026):** the picked app's window, live, in the area above the Thread
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
  Paused to save battery (two idle minutes; Resume — leaving the app pauses too, and it picks up by
  itself when the app comes back), Stopped from your Mac (its menu's Stop; Resume), Mac not connected,
  Screen Recording needed (one button opens the setting on the Mac), unavailable with why
  ("Claude's window is minimized or on another desktop" + Show it on my Mac).
  **Video (Oct 17 2026):** the window arrives as video from a Mac that can, drawn by the system
  (`VideoCanvas`, an `AVSampleBufferDisplayLayer`) inside the same zooming viewer, so new output
  and scrolling move at the window's own pace — thirty frames a second while it scrolls — and the
  text is sharper; nothing on the screen changes, and the first picture is still a still, so the
  window appears as fast as before. **Scroll feels like a trackpad:** one finger in Scroll moves
  the Mac's window as it moves, and a flick keeps it going after the finger lifts, slowing down as
  a Mac's own does; the Mac's apps see one gesture, so they rubber-band at an edge. **Aa** (superseded Oct 18 2026: now "Text size on this iPhone" in the Window menu) sat by Done
  in the watch header (cyan while it's on): a menu of Normal · Larger · Largest with one line
  saying what it does ("Narrows Claude's window so its text reads larger here" — short, a menu
  cuts a long line with "…"); a pick shows a sentence over the window for a moment ("Claude's window
  is narrower, so its text reads larger here"), the same words as the Pan | Scroll note. Remembered
  per app. Only with a Mac that can do it; never for Clipboard.

## Voice of the words

Plain, short, sentence case, no jargon, never cut with "…" (wrap instead). Status lines say
what happened and what to do: "Mac not found — saved, it'll send when your Mac is back."
Delivered: "Delivered to Sameer's MacBook Pro · Copied". No internal names on screen.

## App icon

SameerOS's icon in Macrophone's colours (Oct 18 2026, Sameer: "look at the SameerOS app icon and
model it after that with the colors we use in the app — I think it looks better"): one luminous
thread — an S with tapered tips, a white-hot core, a wide soft glow — on a night sky with a
scatter of stars. `scripts/render-sky-icon.swift` (run `scripts/sky-icon.sh`) is a port of
SameerOS's `scripts/render-app-icon.swift`: the same composition, strand, glow, core, grain,
stars (the same seeded field) and sky-gradient technique. What is ours: the thread's spectrum is
the Filament at rest (violet · cyan · mint — cool where SameerOS runs to gold and coral), and the
sky is Theme.swift's Ink and Light — Ink.ground lifted toward Light.violet at the top, a fuller
violet in the middle, Light.cyan at the horizon and Light.teal at the foot, never SameerOS's
terracotta. Light is the lighter sky, dark the deeper one, tinted the white thread on near black.
Both live in the Icon Composer bundles (`iOS/Macrophone/AppIcon.icon`, `Mac/Resources/AppIcon.icon`
— three groups: the thread as glass, the light and stars, the sky; light and dark images faded by
appearance) with the classic PNG sets as the fallback; the sheet against SameerOS's icon is
`docs/icon/sky/sheet.png`. The earlier Thread-braid icon stays as a record in
`scripts/render-thread-icon.swift` and `docs/icon/thread/`. The menu bar icon is a monochrome
template version (a short filament with a peak), with a dot state when connected.
