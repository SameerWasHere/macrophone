# iPhone app — recording, delivery, and how it's tested

## Recording engine (`Macrophone/Recording/Recorder.swift`)

- `SFSpeechRecognizer` everywhere (iOS 17+). Every request sets `requiresOnDeviceRecognition`,
  `addsPunctuation`, `taskHint = .dictation`, and `contextualStrings` = the dictionary (≤ 50).
  The language picker lists only locales whose recognizer reports `supportsOnDeviceRecognition`.
  `SpeechAnalyzer` (iOS 26+) is not used yet: SFSpeechRecognizer with segmenting covers long-form,
  and one path is easier to make solid.
- **Segments.** The `AVAudioEngine` tap never stops; it feeds whichever request is current.
  Every 45 s, at the first pause (≥ 0.35 s under the quiet line), or at 55 s regardless, a fresh
  request takes over and the old one is ended. Segments are stitched in order with a space. If
  the live segment ends by itself (an error, an early final), a new one starts at once; four
  fast failures in a row stop the recording as "stopped early" with a plain error.
- **Limits chosen.** Soft cap at **5:00** (status: "Recording will stop at 10:00", a warning
  haptic, the timer turns ochre). Hard stop at **10:00** (sent normally, status says so).
  Why: the on-device recognizer has no documented per-request limit but degrades on very long
  requests; segmenting removes that limit, so the cap is about the person and about cleanup
  time, which grows with length (10 minutes is roughly 9,000 characters, cleaned in chunks).
- **Silence auto-stop** (off by default, 2–8 s): counts from the last time the recognizer
  produced new words, so silence before the first word never stops it.
- **Taps:** touch-down opens the mic (a hold never loses its first word). Released after ≥ 0.3 s
  = hold-to-talk, it sends. Released sooner = tap mode, a second tap sends. A recording with no
  words under 0.4 s is dropped silently; longer with no words says "Didn't catch anything".
- **Interruptions** — a call or Siri (`interruptionNotification`), headphones in/out
  (`routeChangeNotification`), the engine resetting (`AVAudioEngineConfigurationChange`,
  media services reset), the app leaving the screen or the screen locking (scene → background):
  the mic stops, the recognizer gets up to 2 s to finish the last words, and the text is
  cleaned, saved and sent with `stoppedEarly = true`. A background task covers the finish and
  the send; no `audio` background mode is used. No audio is ever written anywhere.

## Cleanup

`Cleaner.clean(_:level:dictionary:language:deadline:)` with the level (an automation's level wins
when it sets one), prewarmed on record start (the prewarmed session is reused when the level
and dictionary match). English only; unavailable → the dial is disabled with its one-line
explanation and the app behaves as Off.

**Budget: 8 s + 1 s per 120 characters, at most 60 s** (`AppModel.cleanupBudget`). The model
does ~150–220 characters a second per level and a short dictation takes ~1.1 s, so a normal
prompt has several times the time it needs, and a 10-minute dictation (~9,000 characters,
~60 s budget) mostly cleans. `Cleaner` works chunk by chunk and never starts a chunk it can't
finish before the deadline: finished chunks come back cleaned and the rest as spoken
(`skipped == "partial"`). The phone marks that item "Partly cleaned" (history chip, last
dictation card); the Raw toggle still holds the whole transcript. A hard stop 5 s past the
deadline sends the words as spoken if a model call hangs.

## Send to: the Mac's open apps (Oct 13 2026)

Sameer's simplification: no configured targets, no Automatic, no per-app rules. The Mac lists
every open app (or window) with somewhere to type (`LiveTarget`: icon, name, newest first) and
the phone picks one. Before/after screens: `docs/screens/targets/`.

**The picker** (`UI/SendTo.swift`, `SendToList`): **Clipboard**, **Where I'm typing** (the app in
front on the Mac), then **Open on <Mac>** — the apps the Mac reports, windows as their own rows
("Terminal — claude"), the Mac's icons — then **Automations** (the Mac's profiles, which are now
only automations: notes, reminders, tmux, Ask Claude, scripts…). Opening it asks the Mac to look
again (`refreshTargets()`). A picked app that's no longer open stays picked and shows "Not open on
your Mac — it'll be copied instead" (the chip gets an ochre edge and says so to VoiceOver). The
list is cached (`targets.json`; names only for Shortcuts and the control) so it works while the
Mac is away.

**One shared choice** (`SendSelection` in `Settings.selection`, a fresh install = Clipboard):
`client.selectionProvider` reads it (without the main actor) and the link sends it after every
welcome, so on reconnect **the phone's choice wins**; any change on the phone calls
`client.setSelection`; a change made on the Mac (`selectionChanged`) is applied without being sent
back, its app name swapped for the phone's own listing. Paste or Paste & send is remembered per
target (`settings.sendByTarget`, keyed by `TargetRef.storageKey`) and only offered for apps and
Where I'm typing.

**The quick controls by the mic** (Sameer: the level of correction, which app, paste or paste
and send — "all those should be quick taps"): one tap each, applied to the next dictation (or the
one being recorded — the route is read when it's processed) and synced to the Mac at once.
1. **Where** — the chip: icon + name ("SEND TO" kicker, "SAID" in ember while a spoken name is
   heard); tap → the picker. Long names step down a ladder (kicker off → smaller → two lines),
   never "…".
2. **Paste | Paste & send** — a two-way switch, no sheet; disabled with its reason ("Clipboard
   can't send", "Automations can't send", "Pair your Mac to send"). While recording with an app
   said first, it shows and sets that app's own setting.
3. **Cleanup** — a menu chip ("Medium cleanup ⌄"): the four levels each with their one-line
   summary, the current one ticked; unavailable → "Cleanup off" and the reason on tap. A menu,
   not tap-to-cycle: each level says what it does before you pick it, and any level is one tap
   from the menu instead of up to three taps around a cycle. An automation with its own level
   says so in the menu.
While recording the row stays, quieter (60%), and still works. Settings › Send to has the same
choice and switch; Settings › Cleanup the dial.

**Routing one dictation** (`AppModel.route(for:)`): an open app's name said first
(`SpokenTarget.match`, before cleanup: "Messages, tell Sam I'm late" → Messages, sent "Tell Sam
I'm late", with that app's Paste/Send setting, `targetSpoken = true`) > an automation's lead-in
(`VoicePrefix.match`) > a Shortcut's pick for this recording > the shared choice. Raw history keeps
exactly what was heard. **Every dictation carries `target` and `send`**; `profileID`,
`profileName` and `profileSource` only for automations.

**Status lines** use the Mac's ack detail: "Pasted into Claude", "Sent to Claude", "Claude isn't
open on your Mac — copied instead"; said first → "Sent to Messages — you said “Messages” first".

**Shortcuts, Siri, the Action Button, Control Center:** Start Dictation's "Send To"
(`TargetEntity`, ids `clipboard` / `front` / `app:<bundleID>#<windowKey>` / `auto:<UUID>`) offers
Clipboard, Where I'm typing, the cached open apps and the automations; a closed app still resolves
(the Mac copies). The control's title follows ("Dictate to Messages"). Phrases: "Dictate to / Send
to / Dictate into <place> with Macrophone".

**Verified against `mpctl serve --commands`** (iPhone 17 Pro simulator): the picker lists its three
apps; picking Messages then Paste & send printed `SELECTION Messages` / `SELECTION Messages + send`;
typing `select com.anthropic.claudefordesktop` into mpctl turned the open app's chip to Claude
(`testLiveSyncWithMac`, run with `TEST_RUNNER_MACROPHONE_LIVE=1`); with the app killed, `select
com.apple.Terminal send` on the "Mac", then relaunched → mpctl printed `SELECTION Claude` (the
phone's). **Against `scripts/route-sink`** (prints target/send/said/level): "Messages, tell Sam I'm
late" → `target=app(com.apple.MobileSMS, Messages) send=true said=true level=medium`, sent "Tell
Sam I'm late."; Where I'm typing + send at Light → `target=front send=true level=light`.

## The mic never moves (Oct 13 2026)

Sameer: holding the button, it shifted down under his finger. The page is now fixed slots
(`MainView`, `FixedSlot`): the quick controls, the mic, the status line and the bottom (last
dictation + History) each take the size of a **hidden worst-case template** — a two-line target
name over the paste/cleanup line; two lines of status (three at accessibility sizes); the card
with a two-line kicker, the toggle, text at its cap, Copy and Resend — and the real content is laid
over it (an overlay never sizes its parent). Only the words area above flexes; idle and live
words share it. Recording fades the card to 22% instead of removing it. Long statuses step down a
font size to fit; an Open Settings problem makes the whole line the button. The Mac-app nudge
lives in the chip's line when unpaired. SE-class heights drop the bottom History button (the top
bar has it) and shorten the card and Filament. `testMicButtonNeverMoves` checks idle, recording
with a spoken app, a send change mid-recording, sending, delivered, a hold, queued, failed,
problem, not open, Clipboard, Where I'm typing, an automation, a very long window name, cleanup
off/heavy, no history, unpaired and the nudge — passing on iPhone SE (3rd gen), 17 Pro and 17 Pro
Max; `testMicButtonNeverMovesAtAccessibilitySizes` at AX M and AX XXXL.
`testQuickControlsChangeTheNextDictation` drives each control and reads the route
(`MACROPHONE_ROUTE_PROBE`).

## Delivery

One `LinkClient` (Keychain store, Application Support). Started on foreground once the local
network prompt has been explained (onboarding, or the pairing screen); stopped in the
background once nothing is in flight. Not paired → copied to the iPhone clipboard. Paired →
sent; on any failure the dictation goes to the on-disk queue (`queue.json`, text only) and is
retried oldest-first with `delayed: true` whenever the link connects. Same id every time, so
the Mac answers `duplicate` to a resend ("Already on your Mac").

## Verified on the simulator (iPhone 17 Pro, iOS 27.0) against `mpctl serve`

- QR pairing through the real `onOpenURL` path, including the "Open in Macrophone?" alert
  (UI test `testPairingLinkFromCamera`), and expired-invite error text.
- Code pairing: digits match mpctl's; approve pairs, decline shows "Pairing was declined on the Mac."
- Delivery ("RECEIVED"), resend → `duplicate`, unpair → mpctl prints "UNPAIRED by phone".
- Offline queue: Mac gone → "queued"; app relaunched with the Mac back → delivered once, delayed;
  Mac gone and back while the app stays open → delivered once, delayed, ~2 s after it returns.
- Tap-to-talk and hold-to-talk on the real button (UI tests; a stand-in recognizer, see below).
- Not paired → text on the iPhone clipboard (`simctl pbpaste`).

**Not verifiable on the simulator:** real speech. Both the iOS 27.0 and 26.5 simulators fail to
initialise the recognizer (`kLSRErrorDomain 300` / `isAvailable == false`), even with server
recognition allowed. The engine, permissions and the failure path were exercised; transcription
quality, segment stitching on real audio, and the 5/10-minute caps need the device.

## Debug hooks (DEBUG builds only, `SIMCTL_CHILD_<NAME>=…`)

See `Macrophone/App/DebugHooks.swift`: `MACROPHONE_SCREEN`, `MACROPHONE_ONBOARDING_STEP`,
`MACROPHONE_FAKE_TRANSCRIPT` (+ `_EARLY`, `_DELAY`), `MACROPHONE_FAKE_RECORDING`,
`MACROPHONE_SIM_RECORD` (stand-in recognizer for the real button), `MACROPHONE_FAKE_HISTORY`,
`MACROPHONE_FAKE_PAIRED`, `MACROPHONE_FAKE_PROFILES` (automations), `MACROPHONE_FAKE_TARGETS` (open apps:
`default|long|none`), `MACROPHONE_SEND_TO` (`clipboard|front|<name>`), `MACROPHONE_SEND`, `MACROPHONE_CLEANUP`,
`MACROPHONE_CLEANUP_AVAILABLE`, `MACROPHONE_ROUTE_PROBE`, `MACROPHONE_INTENT_TARGET`,
`MACROPHONE_STATUS`, `MACROPHONE_OPEN_URL`, `MACROPHONE_PAIR_CODE`,
`MACROPHONE_UNPAIR`, `MACROPHONE_RESEND_LATEST`, `MACROPHONE_RECORD`, `MACROPHONE_RESET`,
`MACROPHONE_PAIRING` (`connecting|code|paired|failed|expired`: the pairing panel in that phase).

## Polish rules (Oct 12 2026, before/after in `docs/screens/polish/`)

- **This iPhone's name.** iOS gives apps only "iPhone", so pairing ends on "What should your Mac
  call this iPhone?" — prefilled with the current name, with a one-tap suggestion read off the Mac's
  name ("Sameer's MacBook Pro" → "Sameer's iPhone", `DeviceNameSuggestion`). Settings › Mac offers the
  same suggestion. A rename reconnects with the new name in `hello`; every dictation also carries it
  (`sourceDevice`), which the Mac's history uses.
- **No Mac yet.** The first dictations say "Copied on iPhone — paste it anywhere", and under the card
  a quiet "Want it on your Mac?" row shares the download link (closed for good with its ×).
- **Never "…" as a cut or a stand-in for words.** A voice prefix reads "Sent to Claude — you said
  “Claude” first"; the picker's hint is "Say “Claude” first". Progress ellipses ("Listening…") stay.
- **Cleaned / Raw** (the Mac's words) only when cleanup changed the words; taking a spoken target off
  the front alone isn't a version — Copy Raw (long-press) still has exactly what was heard.
- **"Delayed"** is the Mac's word for a dictation that waited in the queue: a status suffix and its
  own history chip (no more "Delivered late" / "sent late").
- **Errors end in what to do:** "Not delivered — <the Mac's reason>. Fix that on your Mac, then tap
  Resend."; pairing that can't reach the Mac says to keep it open on the same Wi-Fi and, if still
  stuck, offers Settings for Local Network; a denied mic/speech shows an Open Settings button (main
  screen and setup), and setup carries on by itself when the person comes back with it allowed.
- **Small screens (< 700pt tall):** a shorter stage and Filament, the hint gives way to the last
  dictation, so Copy/Resend are on screen on an iPhone SE. Setup's pictures shrink under 620pt.
- **Huge Dynamic Type:** chrome caps its size (the Mac's name and Send to at AX2/AX3, the Cleaned/Raw
  toggle at AX2, the live words at AX3, each with the Large Content Viewer where fixed) and re-lays
  out instead of breaking words: the top bar stacks, the Send-to chip puts its kicker over the name,
  the cleanup dial shows only the picked stop, history chips wrap inside the row.
- **Increase Contrast:** glass and chip edges go firm. **Reduce Motion:** the last-dictation card and
  setup steps fade instead of sliding. **Low Power Mode:** the Filament draws at 30 fps (60 otherwise,
  paused whenever it's still).
- `testAccessibilityAudit` runs Xcode's audit (element detection, hit regions, descriptions, clipped
  text, traits) on main, history, settings, Send to, pairing, dictionary and setup. Contrast and
  Dynamic Type checks are left out: the contrast check fails the system's own toolbar buttons and
  white-on-ink text in this dark-only app, and the capped chrome above is by design.

## Build and test

```
cd iOS && xcodegen generate
xcodebuild -project Macrophone.xcodeproj -scheme Macrophone -sdk iphonesimulator \
  -destination 'id=<your simulator>' -derivedDataPath build build
# UI tests (pairing test needs a fresh invite from `mpctl serve --auto-approve`):
TEST_RUNNER_MACROPHONE_PAIR_URL='macrophone://pair?…' xcodebuild test -project Macrophone.xcodeproj \
  -scheme Macrophone -destination 'id=<your simulator>' -derivedDataPath build
swift scripts/render-icon.swift   # re-renders the app icon
cd scripts/route-sink && swift run route-sink --state /tmp/mp-route-sink   # a Mac with open apps + automations
scripts/capture-store-shots.sh && swift scripts/render-store-shots.swift  # App Store screenshots
```
