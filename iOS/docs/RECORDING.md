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

`Cleaner.clean` with the level (profile's level wins when it sets one), prewarmed on record
start. English only; unavailable → the dial is disabled with its one-line explanation and the
app behaves as Off. A deadline (12 s + 1 s per 250 characters, ≤ 40 s) sends the raw words if
the model is slow — the first run on the simulator took ~15 s.

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
`MACROPHONE_FAKE_PAIRED`, `MACROPHONE_STATUS`, `MACROPHONE_OPEN_URL`, `MACROPHONE_PAIR_CODE`,
`MACROPHONE_UNPAIR`, `MACROPHONE_RESEND_LATEST`, `MACROPHONE_RECORD`, `MACROPHONE_RESET`.

## Build and test

```
cd iOS && xcodegen generate
xcodebuild -project Macrophone.xcodeproj -scheme Macrophone -sdk iphonesimulator \
  -destination 'id=<your simulator>' -derivedDataPath build build
# UI tests (pairing test needs a fresh invite from `mpctl serve --auto-approve`):
TEST_RUNNER_MACROPHONE_PAIR_URL='macrophone://pair?…' xcodebuild test -project Macrophone.xcodeproj \
  -scheme Macrophone -destination 'id=<your simulator>' -derivedDataPath build
swift scripts/render-icon.swift   # re-renders the app icon
```
