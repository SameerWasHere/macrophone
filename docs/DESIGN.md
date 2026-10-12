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
- **The Filament** is the waveform: a tapered luminous line across the screen that moves with
  the voice (height and brightness follow mic level; attack fast, release slow; calm when silent).
  Gradient through the lights: cyan `#58B9DE` → teal `#5CD3C3` → mint `#5ED6A2` → gold `#E8C06C`
  → ember `#E9714F` → violet `#9A86E6`. Idle/ready = a calm, dim, still line. Recording = full
  spectrum, alive. Sending = light flows along it. Delivered = it settles flat in mint and a ✓
  pops in (ease-out-back). Error = rose `#E66E7E`, broken into dashes. Queued = ochre `#C99D68`.
- **Meaning colours:** mint = delivered, ochre = queued/caution, rose = failure, ember = the mic
  is live / your action, cyan = connected Mac.
- **Type:** chrome in SF. The transcript in **New York serif** (`.serif` design) — the words are
  the hero. Status kickers and timers in **SF Mono**, small caps tracking ~1.2. No emojis.
- **Motion:** springs — settle (0.4, 0.85), snap (0.25, 0.7), arrive (0.35, 0.85),
  depart (0.45, 0.86). Everything respects Reduce Motion (fades, a still filament).
- **Haptics (phone):** `light` on record start, `soft` on stop, `success` on delivered,
  `warning` on queued, `error` on failure. Nothing on ordinary taps.
- **Glass:** panels are `.ultraThinMaterial` over the ground with a 1pt hairline and a soft
  shadow; radii 14 / 18 / 22.

## Voice of the words

Plain, short, sentence case, no jargon, never cut with "…" (wrap instead). Status lines say
what happened and what to do: "Mac not found — saved, it'll send when your Mac is back."
Delivered: "Delivered to Sameer's MacBook Pro · Copied". No internal names on screen.

## App icon

A dark ink rounded square with the Filament crossing it as a single luminous stroke that
swells in the middle like a voice peak — the spectrum gradient above. Same mark on both apps;
the Mac icon follows the macOS squircle grid with a subtle depth. The menu bar icon is a
monochrome template version (a short filament with a peak), with a dot state when connected.
