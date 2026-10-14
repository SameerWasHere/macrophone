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

`Cleaner.clean(_:level:dictionary:language:deadline:)` with the level picked by the mic (Off ·
Light · Medium · Heavy · Custom), prewarmed on record start (the prewarmed session is reused when
the level, dictionary and — at Custom — instructions match). English only; unavailable → the
steps are disabled with their one-line explanation and the app behaves as Off.

**Custom (Oct 13 2026).** Sameer: "a fourth setting that's custom cleanup that has a default prompt
in there that the user can edit. The default prompt should be the same as whatever Medium is."
The Custom step follows `CleanupPrompts.customInstructions`; `Settings.customInstructions` holds
his text (`settings.customInstructions`, nothing stored while it's the default or empty) and hands
it to `CleanupPrompts.setCustomInstructions` at launch and on every keystroke. Unedited, Custom is
Medium exactly (same instructions, same worked examples); edited, the package keeps only the
never-answer examples and the guard's safety rules. The dictionary terms are still added. The
editor (`UI/Settings/CustomCleanupView.swift`) is full screen: the one-line explanation, the
instructions prefilled with the default, a character count, "Default · same as Medium" / "Your own
· saved as you type", Reset to Default (confirmed), and "Use Custom" when another level is picked.
Emptied, Custom follows the default. Reached from Settings › Cleanup › Custom instructions, and
by the mic: the picked Custom step wears a pencil — tap it again (or long-press any time, or
VoiceOver's "Edit instructions") and the editor opens as a sheet. While recording, the second tap
says "Edit your instructions once this one's sent" instead of covering the mic.

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

**The core, nothing else (Oct 13 2026, later).** Sameer: "I can select any app that's running, it
will paste or paste and send the text in that app based on what I select, and I can select the
level of cleanup … All the other excessive features — the automations, the snippets — kill." The
Mac's automations are gone from the phone: no Automations section in the list or on the dock, no
automation lead-ins (`VoicePrefix`), no `profileID` / `profileName` / `profileSource` on a
dictation, no cached profiles (the `profiles.cache` default and its shared-keychain copy are
deleted on launch), no "Show the tap-or-hold hint" toggle (the hint shows until the first
dictation). A picked automation becomes Clipboard; an older Mac that still sends its automations
or picks one is ignored (the phone re-sends its own choice). Screens: `docs/screens/simple/`.

**The picker** (`UI/SendTo.swift`, `SendToList`): **Clipboard**, **Where I'm typing** (the app in
front on the Mac), then **Open on <Mac>** — the apps the Mac reports, windows as their own rows
("Terminal — claude"), the Mac's icons. Opening it asks the Mac to look again (`refreshTargets()`). A picked app that's no longer open stays picked and shows "Not open on
your Mac — it'll be copied instead" (on the dock it stays, greyed with a moon and an ochre bar, the
line reads "Claude · closed", the status line says it'll be copied, and VoiceOver says so). The
list is cached (`targets.json`; names only for Shortcuts and the control) so it works while the
Mac is away.

**One shared choice** (`SendSelection` in `Settings.selection`, a fresh install = Clipboard):
`client.selectionProvider` reads it (without the main actor) and the link sends it after every
welcome, so on reconnect **the phone's choice wins**; any change on the phone calls
`client.setSelection`; a change made on the Mac (`selectionChanged`) is applied without being sent
back, its app name swapped for the phone's own listing. Paste or Paste & send is remembered per
target (`settings.sendByTarget`, keyed by `TargetRef.storageKey`) and only offered for apps and
Where I'm typing.

**The controls by the mic** (Oct 13 2026, the elegance pass; `UI/QuickControls.swift`). Sameer:
"The selecting where it goes and other toggles can be way better and more intuitive." Each is
glanceable and one tap, with no sheet for the common case, applied to the next dictation (or the one
being recorded — the route is read when it's processed) and synced to the Mac at once. Every change
plays a selection tick and the status line says for ~3 s what the next dictation will do ("Pastes
into Messages, then sends", "Light cleanup — Removes filler and repeats, fixes punctuation").
1. **Where — the dock** (`PlaceDock`): Clipboard, Where I'm typing, then the Mac's open apps by
   their own icons, newest first, one icon per app. The pick is lifted, lit and has a bar under it
   (cyan; ember while an app said first is heard; ochre when it closed). A tap picks; a few places
   sit centred, many scroll with the pick kept in view. An app with several windows wears a count;
   its long-press lists the windows (and "All places"). A picked app that closed stays on the dock,
   greyed with a moon. The dashed end-cap and the **Send to <place>** line under the dock open the
   full list (every window). Unpaired, the
   dock is one plate: "Copies on this iPhone · Pair your Mac to send to its apps".
2. **Send after pasting** (`SendSwitch`): a paper plane that lights when on; remembered per place
   (`settings.sendByTarget`), synced (`SendSelection`). Clipboard shows why it can't ("Clipboard
   can't send"), and a tap explains. While recording with an app said first, it
   shows and sets that app's own setting.
3. **Cleanup** (`CleanupSteps`): Off · Light · Medium · Heavy · Custom, all visible, the pick
   sliding; Custom wears a pencil when picked (see Cleanup above). Five words fit on an iPhone SE: a
   `ViewThatFits` ladder drops the "Cleanup" word, then the wand, then a size — never a word cut.
   Unavailable, a tap says why. Settings › Cleanup uses the same control.
While recording the controls stay, quieter (72%), and still work. All of it sits in a fixed slot
sized by `QuickControlsTemplate`, so nothing here can move the mic; SE-class heights get a smaller
dock and tighter rows.

**Routing one dictation** (`AppModel.route(for:)`): an open app's name said first
(`SpokenTarget.match`, before cleanup: "Messages, tell Sam I'm late" → Messages, sent "Tell Sam
I'm late", with that app's Paste/Send setting, `targetSpoken = true`) > a Shortcut's pick for this
recording > the shared choice. Raw history keeps exactly what was heard. **Every dictation carries
`target`, `send` and its cleanup level** (`[custom]` at Custom).

**Status lines** use the Mac's ack detail: "Pasted into Claude", "Sent to Claude", "Claude isn't
open on your Mac — copied instead"; said first → "Sent to Messages — you said “Messages” first".

**Shortcuts, Siri, the Action Button, Control Center:** Start Dictation's "Send To"
(`TargetEntity`, ids `clipboard` / `front` / `app:<bundleID>#<windowKey>`) offers Clipboard, Where
I'm typing and the cached open apps; a closed app still resolves (the Mac copies). A control still
set to a former automation (`auto:<UUID>`) uses the app's own choice. The control's title follows ("Dictate to Messages"). Phrases: "Dictate to / Send
to / Dictate into <place> with Macrophone".

**Verified against `mpctl serve --commands`** (iPhone 17 Pro simulator): the picker lists its three
apps; picking Messages then Paste & send printed `SELECTION Messages` / `SELECTION Messages + send`;
typing `select com.anthropic.claudefordesktop` into mpctl turned the open app's chip to Claude
(`testLiveSyncWithMac`, run with `TEST_RUNNER_MACROPHONE_LIVE=1`); with the app killed, `select
com.apple.Terminal send` on the "Mac", then relaunched → mpctl printed `SELECTION Claude` (the
phone's).

## The mic never moves (Oct 13 2026)

Sameer: holding the button, it shifted down under his finger. The page is now fixed slots
(`MainView`, `FixedSlot`): the quick controls, the mic, the status line and the bottom (last
dictation + History) each take the size of a **hidden worst-case template** — the dock, a two-line
place name beside Send after pasting, the cleanup steps; two lines of status (three at accessibility sizes); the card
with a two-line kicker, the toggle, text at its cap, Copy and Resend — and the real content is laid
over it (an overlay never sizes its parent). Only the words area above flexes; idle and live
words share it. Recording fades the card to 22% instead of removing it. Long statuses step down a
font size to fit; an Open Settings problem makes the whole line the button. The Mac-app nudge
takes the dock's place when unpaired. SE-class heights drop the bottom History button (the top
bar has it) and shorten the card and Filament. `testMicButtonNeverMoves` checks idle, recording
with a spoken app, a send change, a cleanup change and a place picked mid-recording, sending, delivered, a hold, queued, failed,
problem, not open, Clipboard, Where I'm typing, a very long window name, cleanup
off/heavy/custom/unavailable, Custom picked and tapped again mid-recording, Custom's explanation, an app that closed, no open apps, a long control explanation, no history,
unpaired and the nudge — passing on iPhone SE (3rd gen), 17 Pro and 17 Pro
Max; `testMicButtonNeverMovesAtAccessibilitySizes` at AX M and AX XXXL (with Custom picked, its
pencil the widest step).
`testQuickControlsChangeTheNextDictation` drives each control and reads the route
(`MACROPHONE_ROUTE_PROBE`, with `MACROPHONE_FAKE_CLEANUP`'s stand-in cleaner, since the simulator
may not have the model): at Custom the probe carries the instructions the cleaner was given —
Medium's unedited, his words after an edit in the editor, the default again once emptied;
`testCustomInstructionsInSettings` (prefilled, Use Custom, saved as typed, Reset to Default);
`testDockPlacesAndWindows` (windows counted and listed on a long-press, the end-cap, a closed pick
kept) and `testControlsExplainThemselves` (what a control that can't apply says, each cleanup step's
sentence, Custom's "tap again").

## The Filament follows the voice (Oct 13 2026)

Sameer: on his iPhone the waveform didn't visibly move when he talked. Two causes, both fixed:
- **The level.** The session runs in `.measurement` mode (no automatic gain), so speech can sit
  anywhere from about −50 to −20 dBFS. The old meter mapped a fixed −52…−12 dB line, then smoothed
  it twice (per buffer and per frame) with a slow release — a quiet or distant voice barely left the
  bottom. On the simulator's mic a voice peaking 12–13 dB over the room read about 0.15. Now
  `LevelScale` measures against the room: the floor is the 10th percentile of the last ~6 s
  (clamped −75…−28 dB, so a voice can't drag it up and a mic ramping up isn't a room), 4 dB over it
  is the first movement and 28 dB over it full scale, on a gentle curve; the mic's first half second
  only learns the room. The Filament does the only smoothing (Hey Claude's `VoiceDriver`).
- **The drawing.** The old single Canvas ribbon's voice swell was smaller than its resting S, so
  even a good level read as a slight wobble. `UI/Filament.swift` is now the Hey Claude Thread in
  Core Animation (`ThreadView`): three braided strands whose weave opens and swells with each
  syllable, a CADisplayLink only while something moves (0.0% CPU idle on the simulator; ~8–10% of a
  core while recording, SwiftUI's live words and halo included).

**Proof against a real voice** (simulator: the recognizer can't run there, the mic can):
`MACROPHONE_MIC_ONLY=1` records from the Mac's microphone without the recognizer,
`MACROPHONE_MIC_WORDS=<text>` reveals those words as voice comes in, and once a second the log
writes `mic level 0.42 (room -58 dB, voice -46 dB)` (numbers only). With `say` playing quietly from
the Mac's speakers: levels 0.13–0.42 while it spoke, 0.00–0.06 in the pauses; the recording and
frame grabs are `docs/screens/elegance/thread-real-voice*`. A real phone held to the mouth is
20–30 dB over the room, near full scale.

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
`MACROPHONE_FAKE_PAIRED`, `MACROPHONE_FAKE_TARGETS` (open apps:
`default|long|none|many`), `MACROPHONE_SEND_TO` (`clipboard|front|<name>`), `MACROPHONE_SEND`, `MACROPHONE_CLEANUP`
(`…|custom`), `MACROPHONE_CUSTOM_INSTRUCTIONS` (`<text>|default`), `MACROPHONE_CLEANUP_AVAILABLE`,
`MACROPHONE_FAKE_CLEANUP` (stand-in cleaner), `MACROPHONE_ROUTE_PROBE`, `MACROPHONE_INTENT_TARGET`,
`MACROPHONE_STATUS`, `MACROPHONE_OPEN_URL`, `MACROPHONE_PAIR_CODE`,
`MACROPHONE_UNPAIR`, `MACROPHONE_RESEND_LATEST`, `MACROPHONE_RECORD`, `MACROPHONE_RESET`,
`MACROPHONE_PAIRING` (`connecting|code|paired|failed|expired`: the pairing panel in that phase),
`MACROPHONE_SCREEN=custom|settings-custom` (the Custom editor from the mic / from Settings),
`MACROPHONE_EXPLAIN` (the status line's control explanation, held), `MACROPHONE_MIC_ONLY` / `MACROPHONE_MIC_WORDS`
(the real mic on the simulator, no recognizer).

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
  the cleanup steps cap their size, history chips wrap inside the row.
- **Increase Contrast:** glass and chip edges go firm. **Reduce Motion:** the last-dictation card and
  setup steps fade instead of sliding. **Low Power Mode:** the Filament draws at 30 fps (60 otherwise,
  no display link at all whenever it's still).
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
# a stand-in Mac with three open apps; prints RECEIVED … → target [level]:
(cd ../Packages/MacrophoneKit && swift build && .build/debug/mpctl serve --name "Test Mac" --state /tmp/mp-ios5/mac --auto-approve --commands)
scripts/capture-store-shots.sh && swift scripts/render-store-shots.swift  # App Store screenshots
```
