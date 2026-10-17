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

## Speech (Oct 14 2026)

The iPhone uses Apple's newest on-device speech model — SpeechAnalyzer + SpeechTranscriber
(`iOS/Macrophone/Recording/ModernSpeech.swift`, iOS 26+) — whenever the language's model is
installed: one continuous analysis, words settle ~0.1 s after the mic stops (measured on the
phone: 125 ms). Otherwise SFSpeechRecognizer (on-device) runs that recording and the model is
fetched in the background (`Recorder.prepare`, at launch). The simulator has no SpeechTranscriber;
test on a phone with `MACROPHONE_AUDIO_FILE=<file in the app's Documents>` (a Debug build;
devicectl copies the file in and launches with the variable; the result shows on screen and is
never sent). Cleanup already gets the newest Foundation model the OS ships (iOS 27 picks the
variant itself) and is prewarmed when the mic opens.

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
- Demo: `mpctl serve` draws a window per place, reads its prompt with the same reader, answers
  `watchChoose`, and sends one alert for its codex window (`--attention-after <s>`,
  `--no-attention`). Phone hooks: `MACROPHONE_WATCH_ACTIONS=pan,scroll,answer@N,keys,next,prev,attend@<bundle>@<window>`.

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

## Checks

```
cd Packages/MacrophoneKit && swift test
swift build && .build/debug/mpctl serve --auto-approve   # then mpctl pair '<url>' / pair-code / send
.build/debug/mpctl cleanup-eval                           # cleanup test set on the real on-device model
.build/debug/mpctl serve --remote --port 47899 --auto-approve   # then: mpctl pair '<url>' (at home), and
.build/debug/mpctl roam --no-bonjour --bonjour-after 3 --expect home   # away by the stored address, then back home
```

## Rules

- Never upload to App Store Connect / TestFlight unless Sameer explicitly asks to submit.
- The apps collect nothing. Diagnostics never contain dictation text or keys.
- Primary users are developers dictating long prompts; when in doubt, optimize for them.
- Testing on Sameer's Mac (he uses it while you work): stop only processes you started, by PID
  or exact path. Never `pkill -f`/`killall` with a short pattern — on Oct 13 2026
  `pkill -f "cat"` matched "/Applications" and closed every app he had open. Never auto-send
  into Messages, Mail, Slack, Muse or anything that reaches a person.
