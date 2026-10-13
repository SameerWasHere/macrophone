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

`Cleaner.clean(_:level:dictionary:language:deadline:)` with the level (the target's level wins
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

## Send to (targets)

The Mac's profiles are **targets** ("Claude", "Claude Code (Terminal)", "ChatGPT", …). The
phone keeps the last list it was sent (`CachedProfile`: each target's name, cleanup level and
voice prefixes), so the picker, voice prefixes, Shortcuts and the Control Center control work
while the Mac is away. The app keeps it in its defaults and mirrors it to a keychain item in the
shared access group `<team>.com.sameer.macrophone.shared`, which the Controls extension reads to
offer targets ("Dictate to Claude"). Not an App Group: the wildcard team profile this Mac signs
with can't carry one. The app's own keychain group stays first in `keychain-access-groups`, so
the pairing key (stored without an explicit group) stays private to the app; a pairing made
before this entitlement still loads (checked on the simulator).

For each dictation (`AppModel.route(for:)`):

1. **Voice prefix** — `VoicePrefix.match(raw, profiles:)` on the transcript. A match picks that
   target for this one dictation (`profileSource = .prefix`), its cleanup level applies, and the
   prefix is taken off what's cleaned and sent. `raw` keeps exactly what was heard; when
   cleanup is off the stripped words go in `cleaned` (the toggle reads "Sent / Raw"). Status:
   "Sent to Claude — you said “Claude, …”". While recording, the chip flips to "SAID · Claude"
   the moment the prefix is heard.
2. **A Shortcut, Siri, the Action Button or a control** that names a target → `.chosen` for
   that recording (its "Automatic" entity → `.automatic`). It doesn't change the saved choice.
3. **The Send-to chip** by the mic: Automatic (`.automatic`, no profile id — the Mac picks by
   the app in front) or a target (`.chosen`). A fresh install defaults to Automatic; a target
   the Mac drops falls back to Automatic.

Verified against `scripts/route-sink` (a stand-in Mac offering prefixed targets; prints each
dictation's `profileSource`, target, raw and sent text): Automatic → `automatic`, no profile;
"Claude, refactor…" → `prefix` Claude, sent "Refactor…", raw intact; "Claude code: run…" →
the longer prefix wins, at that target's Light cleanup; "Chat GPT. Compare…" → ChatGPT; a
pick → `chosen`; a sentence that only starts like a prefix ("note that…") → the pick; the
Start Dictation intent with a target → `chosen`, with Automatic → `automatic`, overriding the
saved pick.

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
`MACROPHONE_FAKE_PAIRED`, `MACROPHONE_FAKE_PROFILES`, `MACROPHONE_SEND_TO`, `MACROPHONE_INTENT_TARGET`,
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
cd scripts/route-sink && swift run route-sink --state /tmp/mp-route-sink   # a Mac with prefixed targets
scripts/capture-store-shots.sh && swift scripts/render-store-shots.swift  # App Store screenshots
```
