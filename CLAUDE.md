# Macrophone

Free iPhone app + companion Mac app: dictate on the phone, pick any app open on the Mac (or the
clipboard, or wherever you're typing), and the text is pasted there — or pasted and sent — at the
cleanup level you choose (Off · Light · Medium · Heavy · Custom). Agents can pull dictations through
a small local API / CLI / MCP. Simplified to that core on Oct 13 2026 (automations, snippets,
templates and the Delivery pane were removed on purpose — don't bring them back unasked).
The original spec is `docs/SPEC.md`. Push to `main`.

## Layout

| Path | What |
| --- | --- |
| `Packages/MacrophoneKit` | Shared Swift package: wire format, pairing + encryption, Bonjour/peer-to-peer transport (`LinkServer` Mac side, `LinkClient` phone side), history store, diagnostics log, on-device cleanup (`Cleaner`, `CleanupPrompts`, `CleanupGuard`), pull-API item shape. `mpctl` is the command-line protocol proof. |
| `iOS/` | iPhone app (XcodeGen `iOS/project.yml`) + Control Center / Lock Screen control extension |
| `Mac/` | Menu bar app (XcodeGen `Mac/project.yml`): Send to (live targets, paste and send), History, Devices, Developer, General; the `macrophone`/`mp` CLI + MCP server; Sparkle updates, `scripts/release.sh` |
| `docs/` | `TARGETS.md` (Send to and delivery), `API.md` (the local API / CLI / MCP contract), `DESIGN.md`, `CLEANUP.md`, `RELEASING.md`, `APP_STORE.md`, `NAME_CHECK.md` |

The website lives in the sameer.us repo (`sameer-gpt`), static pages under `public/macrophone/`.

## The protocol in one breath

Mac advertises `_macrophone._tcp` (peer-to-peer on). Pairing: QR carries a one-time token + the
Mac's X25519 key (phone proves it scanned it with an HMAC), or a six-digit code both screens show
(commit → key → reveal, approved on the Mac, 5 tries / 10 min). Both store a 32-byte pair key
(Keychain). Every connection: nonce handshake with HMAC proofs both ways → per-direction
ChaCha20-Poly1305 keys with counter nonces. Dictations carry a UUID; the Mac de-duplicates.

## Speech (Oct 14 2026; instant since Oct 17 2026)

The iPhone uses Apple's newest on-device speech model — SpeechAnalyzer + SpeechTranscriber
(`iOS/Macrophone/Recording/ModernSpeech.swift`, iOS 26+) — whenever the language's model is
installed: one continuous analysis, words settle ~0.1 s after the mic stops (measured on the
phone: 125 ms). Otherwise SFSpeechRecognizer (on-device) runs that recording and the model is
fetched in the background. The simulator has no SpeechTranscriber (and its SFSpeechRecognizer
fails with error 300, even `MACROPHONE_SIM_SERVER_SPEECH=1`); test on a phone with
`MACROPHONE_AUDIO_FILE=<file in the app's Documents>` (a Debug build; devicectl copies the file
in and launches with the variable; the result shows on screen and is never sent). Cleanup already
gets the newest Foundation model the OS ships (iOS 27 picks the variant itself) and is prewarmed
when the mic opens.

**The mic opens at the finger (Oct 17 2026).** The button starts on touch-down (a `DragGesture`
with no minimum distance; tap vs hold is decided only at release, so a hold never misses its
first word) and the haptic, the ember and "Listening…" show then. Everything slow is done ahead or
beside the mic, never in series on the main thread: `Recorder.ready` (at launch, when the app
comes back, after every recording) sets the session's category and makes the next analyzer with
the model loaded, the format set and his dictionary as context (`WarmAnalyzer`, one at a time; a
tap during the build waits for it rather than loading the model twice). At the tap `MicHardware`
activates the session and starts the engine on its own queue while `ModernSpeech.start` takes the
warm analyzer and starts its input stream beside it; `AudioFeed` holds what the mic hears until
the recognizer is attached and hands it over in order (copies; ≤ 12 s), so the first syllable is
never lost. Closing the mic (engine stop, session off) is off the main thread too, and the final
words are awaited, not polled. Don't touch `engine.inputNode` before the session is active: it
keeps a zero format and the mic can't open (seen on the simulator). The words are
`LiveTranscript` (`recorder.words`, settled + pending): `LiveWords`, `DestinationLine` and
`StatusLine` observe it, so a partial result redraws those and not the mic screen; pending words
are drawn dimmer (`Ink.secondary`) and settle into ink. Numbers only in the log: "mic open N ms
after the tap (session N ms, engine N ms)", "SpeechAnalyzer, made ahead | made now, listening N ms
after the tap, N s held for it", "first words N ms after the tap, N updates, median gap N ms",
"words settled in N ms", "speech engine ready ahead in N ms". Measured on the simulator (the Mac's
mic, `MACROPHONE_MIC_ONLY=1 MACROPHONE_RECORD=4`): the mic open 137–140 ms after the tap → 78–101
(session 17–29, engine 57–63), the main thread free throughout; the analyzer's cost (hundreds of
ms in series before) is now beside the mic and mostly ahead of the tap. Needs a real-device
check: the analyzer's "made ahead" line, the held seconds, the first-words time and the gap
between volatile results.

## Watching, one-handed (Oct 16 2026)

- **Pan | Scroll** ends the key row (under the thumb): one finger moves the picture (the default,
  every time a window opens) or scrolls the Mac's window. Newest sits in the window's corner once
  you've moved away.
- **The window's question as buttons.** The Mac reads the bottom half of the watched picture with
  Vision (`PromptVision`, *fast* level: accurate hangs on some Macs; the reader forgives fast's
  slips — "l." for "1.", "7" for "?", "AuthView. swift") into a `WatchPrompt` (`PromptReader`:
  the last numbered list near the bottom with a marked answer or a question above it, or a
  "(y/n)"), sent on each `WatchFrame`. The phone shows the answers instead of Esc/↑/↓/Return
  (Esc and Keys stay small); a tap sends `watchChoose(promptID, index)` and the Mac presses the
  keys only if that question is still up (arrows from the highlighted answer, then Return).
- **Flip between windows.** The name at the top is a menu of the Mac's windows, dots say where you
  are, a swipe in from a side edge goes to the next/previous; Send to follows the window shown.
- **Your agent needs you.** A phone puts `features: ["attention"]` in its hello (older peers never
  get a message they can't decode — an unknown message ends a session). While one is connected,
  `AttentionWatcher` looks at agent windows (`AppQuirks.terminals` + `agentApps` + the Send-to
  place) every 5 s, reads a question off any nobody watches and sends `.attention` once per
  question; the phone posts a notification, and a tap opens that window. Only while the phone
  app is connected — **when it's closed, nothing arrives yet.** The next step is the person's own
  iCloud (a CloudKit record the Mac writes, a query subscription on the phone that Apple pushes);
  it needs one-time setup on developer.apple.com — an iCloud container
  `iCloud.com.sameer.macrophone`, iCloud + Push on the App IDs, then the schema deployed to
  Production in the CloudKit Console. Xcode here has no signed-in account and the API key can't
  make containers.
- **The pictures are a stream, paced by what changed (the performance pass, Oct 16 2026).**
  `WindowStream` (an `SCStream` of the one window, at most 6 a second) replaces a screenshot per
  look — a screenshot cost ~150 ms each and ran all the time; a still window now costs nothing.
  `WatchPacing` (MacrophoneKit) decides how soon a change earns a picture from how much of the
  window changed (measured from a pixel sample in place — an Electron app reports its whole window
  dirty for a caret): a caret or spinner (<0.1%) every 3 s, a highlight moving a row (<2%) once a
  second, new output at once (0.3 s); a key or a tap from the phone sends the next picture at once
  (45–77 ms after a Return in TextEdit, loopback). The question is re-read only after a change
  bigger than a caret or a spinner (`WatchPacing.unreadable`) — Vision costs ~115 ms on the
  utility queue — and Vision reads nothing left of the conversation's column. `AttentionWatcher`
  pictures each agent window first and skips the Accessibility walk and Vision when the picture
  hasn't changed (same sample rule), keeps the window list 30 s, and rests up to 10 s between
  looks while nothing changes (a window it can't picture still gets its controls read). Measured on
  the Mac Debug instance: watching a Claude window that only animates 5.4–7.8% CPU (Debug) →
  0.7–3.4% (Debug at -O; 1.6–4.3% at -Onone, where the pixel sample is slow) and a 210 KB picture
  every 0.85 s → every 3.2 s; a TextEdit window with a blinking caret 0.7%; the lookout's 5 s look
  2.7% spikes → 0–0.2%; idle 0%. Hook: `MACROPHONE_WATCH_TIMING=1` prints each
  stage's milliseconds; `mpctl watch` prints "CONNECTED in N ms", "N ms after asking", "+N ms" and
  "N ms after the action" (`--features attention` to be a phone that wants alerts).
- **The window is video, like Sill's (Oct 17 2026, the smooth pass; Sill's source is the reference —
  MIT, github.com/Saffsanity/sill).** A phone that names `video` in its hello gets the window as
  HEVC (`watchVideo`: the NAL data, the parameter sets with each keyframe, a keyframe flag — and
  the question and the place to type, as `watchFrame` carried them; an empty frame is words
  only); any other phone (App Store 1.0) keeps getting `watchFrame` JPEGs, and a new phone sends
  `watchKeyframe` / `watchFit` / `watchScrollPhase` only to a Mac whose welcome named `video` /
  `fit` / `scroll` (`Message.welcome(features:)`, `LinkServer.macFeatures`, `LinkClient.macFeatures`).
  **Video is on by default** (`defaults write com.sameer.macrophone.mac watch.video -bool NO` keeps
  pictures): a busy chip turns a watch to pictures by itself. The Mac: `WindowStream` captures the
  window as the chip takes it (420f planes, the change sampled off the brightness plane at step 8 —
  the window server says the whole window changed on every frame it gives, thirty a second, so the
  sample is the real gate) at **30 a second** (`videoRate`; 12 away from home, `remoteVideoRate`;
  pictures 10 at home, 6 away) and `WatchPacing.minimumInterval(quick:rate:)` waits half the
  stream's period for a real change (a wait of a whole period lost every other frame). **The frame
  path is off the main thread end to end (`VideoPipe`, Mac/App/Watch, after Sill's WindowCapture →
  HEVCEncoder → network):** the stream hands each frame to the pipe's own serial queue, which
  keeps the pacing (a frame that doesn't earn a send yet waits as `pending`, the newest replacing
  it, and goes by a timer there; a still window sends nothing), hands a due frame straight into
  `VideoEncoder`'s mailbox (`submit` returns at once — one frame inside VideoToolbox, a newer one
  replaces a waiting one, `onEncoded` in order with how long each took, a 1.5 s watchdog,
  `PrioritizeEncodingSpeedOverQuality`), holds the newest back while two frames are handed in and
  not yet sent (an encoded frame is never dropped — the decoder needs each — so the holding is
  before the encode), gives each encoded frame its seq and the words it carries (`Words`, set by the
  main-actor side when the name, the place to type or the question change) and sends it from one
  detached task in order. While a swipe is under way (`swiped`, 0.5 s after each step) any change
  bigger than a caret goes at the stream's rate: a chat column scrolling in a big dark window
  changes a small share of it, which read as a highlight moving (one frame a second). The main
  actor only hears the fallbacks (`onFallback`: sustained slow encodes — `EncoderHealth`, most of
  the last eight ≥ 50 ms after four settling ones, or two stalls, or a hang — turns the watch to
  **pictures, never software video**; the BGRA stream is made again), reads the question when the
  window settles (`onSettled`, at most about once a second, off the send path; a change goes back
  as a words-only frame) and the counters at the end (`snapshot`). A video watch's first frame is
  the keyframe (no JPEG first). Pictures (a phone from before, or the fallback) keep the main-actor
  loop. `encode()` (sync) is for a proof or a test.
  The phone: `VideoCanvas`
  (`UI/VideoCanvas.swift`, an `AVSampleBufferDisplayLayer` view — the system decodes in hardware and
  draws, `DisplayImmediately`, nothing per frame through SwiftUI) inside the same zooming
  `ViewerScrollView` (a `canvas` holds the picture with the video over it; `Watcher.video`, one per
  watch, hosted by whichever viewer is on screen — the window or the strip while the mic is open; the
  one it leaves keeps a snapshot for its fade); a frame that can't be shown asks for a keyframe; a
  picture after video (the Mac's chip got busy) clears it. Measured on the Mac Debug instance
  (-Onone), mpctl as the phone, Finder in front, one swipe (10 steps, a 1500 pt/s flick):
  **before** (pictures, bare wheel ticks, everything through the main actor) the first picture
  380 ms after the swipe, 1–6 pictures in the 3 s after it (peak 4–6 a second), 230 KB each, Mac
  CPU 15–20% in the swipe's second; Sameer's installed build with the first video pass (still
  through the main actor): peak 9 a second. **After** (video, a gesture, nothing on main): the
  Claude desktop window (Electron, 1431×1084) **65 frames in the swipe's 3 s, peak 30 a second
  (the stream's own rate: window gave 433, 91 changed, 69 sent), the first 60 ms after the swipe**;
  a TextEdit page 17–20 frames (every changed frame it gives: 432 given, 19 changed, 18 sent),
  first 50–94 ms; 5–60 KB a frame, encode 8–11 ms, sends 0 ms median, the first scroll event
  posted 0–28 ms after its message; Mac CPU 7–9% in the swipe's second, 3–4% on a still window
  (pictures 2–3%; at -O the sample is cheaper).
  The simulator (software decode, 1400×900
  from `mpctl serve`): 4.6% CPU in the swipe's second, 0.1–0.5% still. The log line at the end of a
  watch: "watching: N frames (M video) · median … · peak P a second · S scroll steps in G swipes ·
  window gave N (C changed), held P for pace, W for the wire, sending median S ms" (the phone's:
  "N video frames, KB, peak P a second"). `MACROPHONE_WATCH_TIMING=1` prints each
  stage, "[stream] N frames this second" and a swipe's "scroll began posted N ms after the action" /
  "frame from the window N ms after the action". Needs a real-device check: HEVC hardware decode on
  the iPhone, and a real Claude Code window scrolling.
- **Scrolling like a trackpad (Oct 17 2026, after Sill's InputInjector / InputOverlay).** A swipe
  on the phone is a phased gesture: `watchScrollPhase(began|ended|momentumBegan|momentumEnded, x, y)`
  brackets the `watchScroll` deltas, which go once a display frame (a `CADisplayLink` pinned to 60,
  coalesced), and after a flick the phone runs the coast itself (`ScrollMomentum`, MacrophoneKit
  `Core/Scroll.swift`: decays 0.96 a tick, stops under 0.3 pt, ≈1.6–2.1 s — macOS adds momentum
  below where a posted event enters, so the Mac won't). The Mac posts them off the main thread too
  (`ScrollPoster`, Mac/App/Watch): `LinkServer.watchInput` hands each step and phase straight from
  the receive loop to the watch's poster, whose own serial queue turns them into continuous scroll
  events (`ScrollEvents`, pure, tested) with point deltas and the phase / momentum-phase fields at
  the finger's spot (the event's own location routes it to the window under it, in front or not —
  a posted scroll event also moves the pointer there, so it's put back 0.6 s after the swipe), with
  the window's frame looked up at a swipe's start and once a second, sub-point remainders carried,
  never an end without a beginning, and a swipe gone quiet closed by a timer (2 s for fingers,
  0.5 s for a coast). Only a swipe's start reaches the main actor (`onBegan`): if an on-screen
  window covers the spot (`WindowServer.isOnTop`) the watched one is brought forward — the steps
  don't wait for that.
  To a Mac that doesn't name
  `scroll` the phone sends the deltas alone and one flick delta, as before. `mpctl watch --swipe 0.3
  [--flick 1500]` swipes as the phone does; `mpctl serve` draws a page to scroll back through and
  answers at 30 Hz. Proven on the simulator with a real touch (began · 12 steps · ended · 83 momentum
  steps · momentumEnded on the demo).
- **Aa — readable text (Oct 17 2026).** A menu in the watch header (Normal · Larger · Largest,
  `WatchFitMenu`, remembered per app in `watch.fit.<bundle id>`): the Mac resizes the watched
  window through Accessibility (`WindowFit`, `WatchFit.frame`: the display's full height, 560 or
  420 points wide, never wider than it was) so its text reads larger on the phone, applied once
  the window is found (`Watch.wantedFit`) and sent again on resume; the window goes back to its
  own size and place when the watch ends — Done, another window, the phone gone, the Mac's Stop,
  Quit (`applicationWillTerminate`) — unless it was moved or resized on the Mac meanwhile
  (`WindowFit.restore` compares with the frame it left). Checked on a TextEdit window: 656×422
  → 420×1084 → 656×422. `mpctl serve` narrows its drawn window (`DemoWindow.fit`); `mpctl watch
  --fit larger`; phone hook `MACROPHONE_WATCH_ACTIONS=fit@larger`. Needs a real check on an
  Electron window (Claude desktop): its AX size reads fine; whether it takes a width under its
  minimum is the app's call (the Mac reads back what it took).
- Demo: `mpctl serve` draws a window per place, reads its prompt with the same reader, answers
  `watchChoose`, and sends one alert for its codex window (`--attention-after <s>`,
  `--no-attention`). Phone hooks: `MACROPHONE_WATCH_ACTIONS=pan,scroll,answer@N,keys,next,prev,attend@<bundle>@<window>,fit@larger`.

## Away from home — Remote access (Oct 17 2026)

Modelled on Sill's Remote Access. At home the phone finds the Mac with Bonjour; away, it dials
addresses the Mac gave it. `Core/RemoteAccess.swift` holds the rules: `RemoteAddress` (host, port,
`.mac` told / `.typed`), `RemoteAddressRule` (the Tailscale range 100.64.0.0/10 and `.ts.net`
names, `isLocal` — private, link-local, loopback —, `parse("host[:port]")`, the dial order
Tailscale → MagicDNS name → typed → local, `merge`: the Mac's list replaces its own, the typed one
stays), `NetworkAddresses` (this Mac's addresses off `getifaddrs`, the MagicDNS name by a reverse
lookup — no Tailscale CLI). Unit tests in `RemoteAccessTests`.
- **Mac:** Devices › Away from home — Remote access (off by default; `Settings.remoteAccess`,
  `remotePort`, default 47821). On, `LinkServer.setRemote` listens on the fixed port and takes
  connections from beyond the network; off, a connection from away (`!isLocal(source)`) is closed
  before any handshake. `AppModel.refreshRemoteAddresses` (on listener ready, the setting, an
  `NWPathMonitor` change) publishes the list and `broadcastRemoteAddresses` to phones whose hello
  named `"remote"` (`RemoteAccess.feature`); the pane shows the Tailscale address and name (or Get
  Tailscale), the local addresses with Copy, the port, and two sentences on Tailscale / port
  forwarding. `SecureSession.isRemote`, `LinkServer.isRemote(peer)`, `AppModel.remotePeers` —
  the status line says "· away from home"; `WatchService` sends a remote phone narrower pictures
  (1000 px, quality 0.45, 400 KB ceiling: the only touch in the watch code).
- **Phone:** `.remoteAddresses` lands in `PairedPeer.remoteAddresses` (`PairingStore.update`; a
  list from before still decodes). `LinkClient.route(for:)`: Bonjour has the Mac → its endpoint;
  else after `awayAfter` (3 s) with remote addresses → `raceConnect` (every address at once, the
  first open connection takes the handshake, the rest are cancelled before any handshake, so the
  Mac never sees two sessions); else the by-name dial as before. `updateResults` finding the Mac
  while `isRemote` → `moveHome` (a `replacing` dial: the state never leaves `.connected`, the
  Mac's close of the old session is quiet, `pathChanged` tells the app). `AppModel.isRemote`:
  "Ready · Mac · away from home"; Settings › Away from home shows what the Mac said and takes one
  typed address (`setTypedAddress`); diagnostics count the addresses, never print them.
- **mpctl:** `serve --remote [--port N]`; phone side `--dial host[:port]`, `--no-bonjour` (stands
  in for a network where Bonjour finds nothing), `--away-after`; `mpctl roam [--bonjour-after N]
  [--expect remote|home]` prints `PATH remote (away from home)` / `PATH local (back home)`.
  Proven on one Mac (the LAN IP 192.168.4.22 as the VPN stand-in): away in 5–9 ms, a dictation
  lands, the move home with no "not found" in between. Still needs a real phone on cellular with
  Tailscale on both.

## Agents tell the Mac themselves (Oct 17 2026)

Sameer picked "know exactly when an agent waits" over reading pictures. Claude Code (hooks) and
Codex (`notify`) run `…/Contents/Helpers/macrophone hook claude|codex`, which posts an
`AgentEvent` to `POST /v1/agent` (silent, exit 0, 1.5 s cap). `Watch/AgentHub.swift` keeps one
`AgentSession` per session (working · waiting · yourTurn), finds its app from the hook's
ancestor pids and its window (kept; the app's only one; a title naming the project; the front
one on a new prompt), sends `.attention` the moment one waits (iCloud when no phone is
connected) and `.agents` to phones naming "agents". The attention watcher skips windows an
agent claims and reports the ones it reads asking (`fromScreen`). Mac › General › Agents
connects/disconnects (`Core/AgentSetup.swift`; backs the file up once; never replaces his own
Codex `notify`). The phone's Agents panel (Oct 17) was removed Oct 18 — "takes up too much
space ... not actually a useful section".
Same day: More keys (`WatchKey`, feature "keys": ⌃C, Tab, ⇧Tab, ⌘↩, ⌘Z, Space, ⌫, digits —
by name, so a newer key never breaks an older Mac), Fit to iPhone (`watchShape`, feature
"fitPhone": the window takes the phone's view shape at full screen height), first-use tips
(`UI/WatchTips.swift`, one card at a time over the window's top; Window › Show Tips Again),
the zoom kept per app (`watch.view.<bundleID>`, dropped when the window's shape changes), and a
minimized window stays the watched one so "Show it on my Mac" brings it back.
`mpctl serve` names every new feature.

## Chats that answered you (Oct 18 2026)

Sameer: a mark in Send to when "a chat where the user is currently engaging" — the agent replied
and needs a response. Not Dock badges, not every chat. `Watch/ReplyWatcher.swift`: a window
becomes a chat when a dictation is sent there (`Paster.Result.windowID`, `pressedSend`) or the
phone answers / presses Return in it (`WatchService.act`: returnKey, choose, key-return). Every
3 s (10 s after ten minutes), per chat: a hook agent's state (AgentHub `state(of:)`: done or
asking after you wrote, 2 s grace) — else its picture: content (share ≥ 0.006, after the first
4 s) then 3 still looks = answered; new content takes it back. Watching it on the phone resets
it. `.needsYou([NeedsYou])` to phones naming "needsYou". Phone: an ember dot on the app's Send to
button (a tap picks the window that answered), "Answered you" / "Asking you" by the Send to
name, `circlebadge.fill` in the window menus; looking clears it at once (`clearNeeds`).
Debug: `MACROPHONE_FAKE_NEEDS=1` (with `MACROPHONE_FAKE_PAIRED`).

## Checks

```
cd Packages/MacrophoneKit && swift test
swift build && .build/debug/mpctl serve --auto-approve   # then mpctl pair '<url>' / pair-code / send
.build/debug/mpctl cleanup-eval                           # cleanup test set on the real on-device model
.build/debug/mpctl watch --target com.anthropic.claudefordesktop --swipe 0.3 --features video   # a swipe as the phone sends it, video back
.build/debug/mpctl serve --remote --port 47899 --auto-approve   # then: mpctl pair '<url>' (at home), and
.build/debug/mpctl roam --no-bonjour --bonjour-after 3 --expect home   # away by the stored address, then back home
```

## Rules

- Never upload to App Store Connect / TestFlight unless Sameer explicitly asks to submit.
- The apps collect nothing. Diagnostics never contain dictation text or keys.
- Primary users are developers dictating long prompts; when in doubt, optimize for them.
- The simulator can't store the pairing key from a build made with `CODE_SIGNING_ALLOWED=NO`
  (no entitlements, so no Keychain): it pairs and never connects. Build for the simulator with
  the project's normal signing.
- Testing on Sameer's Mac (he uses it while you work): stop only processes you started, by PID
  or exact path. Run at most one Mac Debug copy (`MACROPHONE_INSTANCE=<name> MACROPHONE_HIDE_ICON=1`),
  only while measuring, and quit it by PID in the same command. Never `pkill -f`/`killall` with a short pattern — on Oct 13 2026
  `pkill -f "cat"` matched "/Applications" and closed every app he had open. Never auto-send
  into Messages, Mail, Slack, Muse or anything that reaches a person.
