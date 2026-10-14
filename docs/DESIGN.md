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
- **The controls by the mic (phone):** a dock of the Mac's open apps by their own icons (the pick
  lifted and lit, with a bar under it like the Mac's Dock), "Send to <place>" under it opening
  every place, a **Send after pasting** toggle (a paper plane that lights), and **Off · Light ·
  Medium · Heavy** steps. A change is one tap; the status line then says in a sentence what the
  next dictation will do. A control that can't apply says why when tapped.
- **Glass (Oct 13 2026, the Liquid Glass pass):** on iOS 26+ the phone uses Apple's native
  Liquid Glass; below, the old look (`.ultraThinMaterial` over the ground, a 1pt hairline, a soft
  shadow; radii 14 / 18 / 22). The helpers live in `iOS/Macrophone/UI/Theme.swift` and wrap every
  API in `if #available(iOS 26.0, *)`: `glassPlate(_:lit:interactive:)` (`.glassEffect` with
  `Glass.regular`, `.tint`, `.interactive`), `GlassGroup` (`GlassEffectContainer`), `glassID`
  (`glassEffectID`), `GlassPanel` (`.glass(radius)`), `IconButtonStyle`, `pillStyle` (`.glassProminent`
  / `.glass`) and `doneButtonStyle` (`.glassProminent`, cyan, dark label). Where it's used: the Mac
  pill and the History / Settings buttons are interactive glass; the dock's pick sits on a bubble of
  glass lit in its colour that flows to the next icon (`glassEffectID` in a container); the cleanup
  steps are a glass track whose pick is a bright glass lens that morphs from step to step; Send after
  pasting is the native `Toggle` on a glass capsule lit cyan while on; the mic is a disc of glass,
  ink-dark inside the spectrum ring at rest and ember while it listens (same size, never moves);
  panels, the pill buttons and the sheets' Done are glass too. Rules: glass carries controls, never
  the words (the transcript and the idle line sit on the ground); the label of a lit pick is dark
  ink on a bright lens, never white on a light tint; Reduce Transparency swaps every glass for a
  solid raised plate, Increase Contrast adds a firm 1pt edge.

## Voice of the words

Plain, short, sentence case, no jargon, never cut with "…" (wrap instead). Status lines say
what happened and what to do: "Mac not found — saved, it'll send when your Mac is back."
Delivered: "Delivered to Sameer's MacBook Pro · Copied". No internal names on screen.

## App icon

A dark ink rounded square with the Filament crossing it as a single luminous stroke that
swells in the middle like a voice peak — the spectrum gradient above. Same mark on both apps;
the Mac icon follows the macOS squircle grid with a subtle depth. The menu bar icon is a
monochrome template version (a short filament with a peak), with a dot state when connected.
