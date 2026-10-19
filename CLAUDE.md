# Macrophone

Free iPhone app + companion Mac app: dictate on the phone, pick any app open on the Mac (or the
clipboard, or wherever you're typing), and the text is pasted there — or pasted and sent — at the
cleanup level you choose (Off · Light · Medium · Heavy · Custom). Agents can pull dictations through
a small local API / CLI / MCP. Simplified to that core on Oct 13 2026 (automations, snippets,
templates and the Delivery pane were removed on purpose — don't bring them back unasked).
The original spec is `docs/SPEC.md`. Push to `main`.

## The product, as it stands (Oct 18 2026)

Reader (the window's words as text) was cut the same evening — Sameer: "not that great … focus on making the window view really good". The speed pass (same night): no paste countdown when nobody's at the Mac, no fixed settle waits, the result before the clipboard's restore; the Mac gets the place ready while you speak (`prepare`, feature "prepare" — Paster.prepare); cleanup runs during your pauses (AppModel.cleanAhead); video sends every real change (WatchPacing `live`), 60 fps at home, Retina up to 2,560 px.

Two days of features from several hands, read as one product: every feature has one name, one
glyph and one obvious way in on each app. This map wins over any older section below (the ones it
replaces are marked **superseded**); the sections below keep the mechanics and the numbers.

| Feature | iPhone | Mac |
| --- | --- | --- |
| **Send to** (the shared choice, "Send to" everywhere — never "Send To") | The controls panel by the mic: `SEND TO` kicker, the pick's name, a row of app icons only (a long press lists an app's windows), **+** at the end = Open an App (the only way to open one that isn't open), **⋯** = Send a Photo… · Send a File… · Copy Mac's Clipboard · Send Clipboard to Mac · Refresh Open Apps. Settings › Send to is the full list. `UI/QuickControls.swift`, `UI/SendTo.swift`, `UI/SendToMac.swift` | The menu bar menu's Send to section (a check on the current, the first six apps, More Apps, Send after pasting as its own toggle); the `SendToCard` above every window pane; the first-run step. `UI/StatusItemController.swift`, `UI/Components/SendTo.swift` |
| **Watch** (the window, live, as video) | **Watch** beside the Send to name, or by itself after a send (Settings › Show the app after sending), or the Watch widget; Done ends it. The name at the top is the window menu (page dots, a swipe in from a side edge flips); tap = click, tap twice = double-click, tap then hold-and-move = drag, hold / two fingers = right-click, pinch = zoom; **Pan \| Scroll** under the thumb (Scroll picks itself when the whole window is on screen, and when a window was fitted to the phone); Esc · ↑ · ↓ · ⏎ · **···** (More keys, by section) or the question's answers as buttons; under the Thread the **KEYBOARD · MIC · TRACKPAD** pages (Oct 19 2026). `UI/WatchPanel.swift`, `Model/Watcher.swift`, `UI/InputCarousel.swift` | Streams the one window (`Watch/WatchService.swift`, `VideoPipe`, `WindowStream`), posts clicks, drags, the pointer, typing, keys and trackpad-style scrolls (`InputService.swift`, `ScrollPoster.swift`); the menu bar icon becomes a ring and the menu gets **Stop Showing ‹app›** while a phone watches |
| **The header cluster** by Done: **zoom out** (`arrow.down.right.and.arrow.up.left`, the whole window and back), **Window** (`macwindow`) | One piece of glass; each only when the connected Mac names its feature. `UI/WatchReader.swift` is Text: your text size, selectable, Copy All, follows the newest line, asked every 2.5 s | Reader: a terminal's own text, else recognition over the column you type in (`WindowReader.swift`); `mpctl reader` |
| **The Window menu** (in order of use) | Fit to iPhone · Text size on this iPhone (Normal · Larger · Largest, per app) · Size on your Mac (Fill the Screen `rectangle.inset.filled` · Left Half · Right Half · Middle · Back to How It Was) · Minimize · Close Window (asked first) · the photo / file / clipboard items (the same as Send to's ⋯, here because the panel is away) · Show Tips Again | `WindowFit.swift` resizes through Accessibility and restores on Done / Quit |
| **First-use tips** (`UI/WatchTips.swift`) | Five at most, one card at a time over the window's top, each only when it works with this Mac: Tap to click / hold to right-click · Pinch to zoom, or Fit to iPhone · Swipe in from the side (two windows or more) · Pan or Scroll (auto-Scroll named)· More keys. `watch.tips.seen`; Window › Show Tips Again | — |
| **Photos, files, the clipboard** (`Core/Share.swift`: features `attachments`, `clipboard`) | Send to's ⋯ and the Window menu — the same `MacShareItems`; a photo or file goes into the chat you send to (the watched window while one shows), the clipboard only when asked; the status line says where it landed | `Delivery/Attachments.swift` (kept a week in From iPhone; the image into a chat app, its path into a terminal), `ClipboardShare.swift` (a concealed copy never leaves) |
| **Chats that answered you** (feature `needsYou`) | The ember dot on the app's icon in Send to, "Answered you" / "Asking you" by the pick's name, `circlebadge.fill` in the window menus, the mark on the widget; looking clears it | `Watch/ReplyWatcher.swift`: a window you sent to from the phone, answered by its hook agent or by its picture settling |
| **Agents** (Claude Code, Codex, by their hooks) | Nothing to see: the notification the moment one asks ("Claude Code is asking you something" + the question; a tap watches that window) — Settings › Tell me when an agent asks something. The phone's Agents panel was removed Oct 18 ("not actually a useful section") and the `agents` wire with it | The **Agents** page (its own sidebar section, `AgentsPane`; Connect / Disconnect), the menu bar's **Connect Claude Code…** until it is; `Watch/AgentHub.swift` keeps the sessions for the alert, the Answered you mark and the lookout; `POST /v1/agent`, `mp hook` |
| **Alerts when nobody's looking** (feature `attention`, `attention-cloud`) | The notification; through iCloud when the app is closed (`Model/AgentAlerts.swift`, builds signed for it) | `AttentionWatcher` reads agent windows nobody watches (controls through Accessibility, else Vision); `CloudAlerts` writes the record |
| **The Watch widget** (`iOS/MacrophoneControls/WatchWidget.swift`) | Up to four of the Mac's open apps with their icons and the ember mark; small 2 × 2, medium a row with names; a tap = `macrophone://watch?target=…` (watches, and picks it in Send to); fed through `Shared/WatchWidgetData.swift` | — |
| **How it's connected** (`LinkRoute`) | The Mac pill's glyph (Wi-Fi, direct link, Tailscale shield, globe); the status line "Ready · ‹Mac› · Tailscale"; Settings › Connected now | The menu header "Connected · Tailscale · away from home" (`MenuWords.via` — the route's `short`, the same words as the status line and the phone); Devices › Away from home |
| **Open / quit an app** | **+** at the end of the Send to row → Open an App (search, Quit beside an open one) | `AppCatalog` opens / quits; the menu's More Apps lists only open ones |
| **The Mac window** | — | Sidebar: History · Agents · Devices · Developer · General (⌘1–5); the Send to card above every pane; the menu bar menu is `StatusItemController` + `MenuBar/` (header · Stop Showing · Open Macrophone · Send to · Recent · the rare ones · Quit) |

Glyphs that mean one thing: `eye` = Watch (the button, Settings, the widget's kicker; `eye.slash` =
Stop Showing), `macwindow` = the Window menu (Fill the Screen is
`rectangle.inset.filled`; a flipped-to window's note and the swipe tip wear `arrow.left.and.right`),
`text.cursor` = Where I'm typing and `app` = a nameless app on both apps (`TargetGlyph` /
`TargetIcons`), `paperplane` = Send after pasting, `sparkles` = Claude Code / the Agents page.
Feature flags: a message goes only to a peer that named its feature in hello / welcome
(`LinkClient.features`, `LinkServer.macFeatures`; `mpctl serve` names them all) — App Store
iPhone 1.0 and an older Mac keep working.

## Save to Mac's Downloads (Oct 19 2026)

A photo or file from the phone can go into the Mac's Downloads and show selected in Finder, not
only into a chat. Mac → iPhone files were set aside the same day (Sameer: "Deprioritize sending
files from Mac to phone. Sending clipboard is good for now.") — don't build them unasked.
- **Wire:** the same `AttachmentChunk` pieces (1 MB, 20 at most) with `downloads: true`, sent that
  way only to a Mac whose welcome names `SaveToDownloads.feature` ("downloads",
  `Core/FileTransfer.swift`); an older Mac never sees the flag. Tests: `SaveToDownloadsTests`.
- **Phone** (`UI/SendToMac.swift`, `AppModel.sendAttachment` / `attachTarget`): where Send to (or
  the watched window) has no chat to paste into — Clipboard, Finder, the Whole Screen
  (`SaveToDownloads.isDefault`) — the ⋯ items read "Save a Photo / File to Mac's Downloads…";
  on a chat they stay Send a Photo… / Send a File… (into the chat, as before) with a **Save to
  Mac's Downloads** submenu (A Photo… · A File…). Status: "Saving the file to your Mac's Downloads…".
- **Mac** (`Delivery/FileTransfer.swift`, `DownloadsSaver`, called from `AttachmentInbox`): moved
  from From iPhone into ~/Downloads as "name", "name 2", …; Finder shows it selected (not while the
  Mac is locked); "Saved to Downloads on your Mac — shown in Finder". macOS asks once whether
  Macrophone may use Downloads; if refused, it stays in From iPhone and Finder shows it there.
- Hooks: `MACROPHONE_SEND_FILE=<name in the app's Documents>[@downloads]` (sends once connected);
  `mpctl put-file <path> [--downloads] [--target …]`; `mpctl serve --save-to DIR` writes what
  arrives. UI test `testSaveToDownloadsItems` (with `TEST_RUNNER_MACROPHONE_LIVE=1` and a paired
  `mpctl serve`).

## The polish pass over the five Oct 19 features (Oct 19 2026)

Sameer: "do a polish agent to make sure everything works well together and looks fantastic."
Walked on the simulators against `mpctl serve`; the contact sheet is `docs/screens/polish-oct19/`.
What changed (the mechanics below still hold where not named here):
- **The keyboard's keys fit every phone, in two rows** (`MacKeyboardStrip` + `MacKeyboardBar`,
  `UI/MacKeyboardView.swift`): the carousel's keyboard page is now **esc · ⇥ | ← ↑ ↓ →** with
  "Typing in Claude" / "⌘ next key" / "Tap for next app" beside them when there's room (the
  one-row bar of twelve cells was cut mid-arrow even on a Pro); the keyboard's own accessory bar
  carries **⌘ ⌥ ⌃ ⇧ | fn · hide**. Nothing scrolls. The strip's open room takes the swipe
  right-to-left back to the mic; a held arrow stops repeating if its page slides away.
- **While the keyboard page is up the window's key row steps aside** (`WatchActions.keyboardUp`):
  Esc · ↑ · ↓ · ⏎ · ··· and Pan | Scroll are the bar's keys now, so the window keeps ~46pt; a
  question's answers still show (without the Esc · Keys row).
- **One "Your Mac" list**: the keyboard's fn menu and the window's ··· menu both draw
  `WatchKey.macSection`, same order, same Switch App handling.
- **A sticky modifier never travels unseen**: leaving the keyboard page drops ⌘ ⌥ ⌃ ⇧ (they're
  lit only on its bar); the app switcher's held ⌘ says so over the window on the other pages
  (`Watcher.say`, now internal). Reconnecting with the trackpad page up shows the pointer again.
- **The trackpad moves at the right speed everywhere**: the Mac sends the window's size in
  points (`WatchVideoFrame.points` / `WatchFrame.points`, optional — `VideoPipe.Words.points`
  from `WindowStream.windowSize`) and the phone's `MacInput.windowPoints` takes it, so a 1×
  display or a picture narrowed for a remote link isn't taken for a Retina window at full size;
  a Mac from before still gets pixels ÷ 2.
- Words and glyphs: the Sound button off is a plain `speaker` (a slash read as something wrong);
  the tip is "Swipe beside the mic for a trackpad or keyboard"; with two displays the Whole
  Screen rows say "With the menu bar, live" / "Everything on it, live"; the page row keeps a
  kicker's size at accessibility text sizes. Mac: `MACROPHONE_SHOW=setup-permissions`.
- Left as is, noted: two phones on two displays share the last pick; the Accessibility banner
  sits over the Newest button while it shows (× puts it away); on the simulator Wake Your Mac
  never offers itself (`WakeRule.sameNetwork` skips an address equal to the Mac's own — the
  simulator is the Mac), `MACROPHONE_REACH=wake` shows the button's Waking… state.

## The Mac in hand: a real mouse, a trackpad and a keyboard (Oct 19 2026)

Sameer: "for trackpads a keyboard we should make that available in window view with the mic as the
default. Swiping right to left should show the trackpad and swiping left to right should open a
full iOS keyboard that types in the Mac. They should essentially be a 3 input method carousel."

- **The carousel** (`UI/InputCarousel.swift`, `Model/MacInput.swift`): the area under the Thread,
  where the mic sits, is three pages — KEYBOARD · MIC · TRACKPAD — with a mono row above saying
  where you are (a tap goes there; one VoiceOver element, adjustable). The mic is the default every
  time the window view opens. A swipe **beside** the mic (never on it — a hold there is a dictation)
  slides right-to-left to the trackpad, left-to-right to the keyboard; the trackpad takes every
  finger for the pointer, so its way back is the row or a swipe in from its left edge; the
  keyboard page is a 44pt strip above the iOS keyboard, and the Thread folds away meanwhile so the
  window keeps its room. The mic page is the same view on every page (a hold on it is never lost to
  a page change); recording forces the mic page. A page shows only when the Mac named its
  feature in the welcome — a Mac from before has the mic alone and no row.
- **Gestures on the window** (`ViewerScrollView`, `WatchPanel.swift`) — chosen so today's stay:
  tap = click, hold = right-click, two fingers = right-click, pinch = zoom, swipe = pan/scroll.
  **A second tap within 0.35 s near the first is sent as click 2** (a third as 3) — the first
  tap still goes at once, nothing waits to see whether a second comes; the Mac posts it with
  `clickState` 2, which is how a real double-click is counted. **A tap, then a hold that moves =
  drag** (press at the hold, moves follow, release on lift — select text, move a window, a slider, a
  file); a hold with no tap before it is the right-click, as before. The keyboard page's sticky
  ⌘ ⌥ ⌃ ⇧ go on the next key *or the next click/tap* (⌘-click, ⇧-click).
- **The trackpad** (`UI/TrackpadView.swift`, raw touches): one finger moves a pointer drawn in the
  window as a cyan ring (faster when the finger is — `TrackpadMotion`, 1× slow to 3.4× flicking);
  tap = click, tap-tap = double, tap then hold-and-move = drag (a plain hold that stays also
  starts one), two-finger tap = right-click, two fingers moving = scroll under the pointer (the
  window's `ScrollPoster` path, with the coast). The pointer is the phone's (`TrackpadPointer`, a
  fraction of the window; the Mac is told the place, never a delta, so they never drift), kept in
  view when zoomed in, and the Mac draws its own cursor into the stream while the page is up
  (`WindowStream.setCursor`, `watchMouse` show/hide) and never puts it back after a click there —
  which is what makes hover work.
- **The keyboard** (`UI/MacKeyboardView.swift`): a hidden `UITextView` takes what iOS inserts and
  deletes; the difference from what it held goes as `watchType(delete: N, text:)` (`TypingDiff` —
  autocorrect's "teh " → "the " is 2 deletes and "he "; a delete on an empty field still sends one;
  marked text waits for the composition). The Mac types it as unicode events (`TypingPlan`: ≤20
  UTF-16 units each, never splitting a character; Return and Tab as the keys). No clipboard. The
  keys above the keyboard **[superseded by the polish pass, Oct 19 2026: two rows — the page's
  strip esc · ⇥ | arrows (hold to repeat), the accessory bar ⌘ ⌥ ⌃ ⇧ (sticky, one-shot) | fn
  (F1–F20, Home/End/Page/Forward Delete/Help, and the Mac's own moves) · hide]**.
  Smart quotes and dashes off, no auto-capitals (a terminal), autocorrect on.
- **Every key, and keys held** (`WatchKeyHold`, `watchKeyState`): the Mac maps the whole keyboard
  by name (`KeyCodes` in `Mac/App/Watch/InputService.swift` — letters, digits and signs found on
  the current layout, F1–F20, fn, caps lock, both of every modifier) and holds a key down until
  released (`HeldKeys`; let go by itself after 30 s, on stop, on disconnect). **Switch App** is ⌘
  held, Tab, and ⌘ let go 1.1 s after the last tap (tap again to step on). Spotlight ⌘Space,
  Mission Control ⌃↑, Show Desktop F11, Desktop ←/→ ⌃←/→, Next Window ⌘` are
  `WatchKey.macSection` — in the keyboard's fn menu and the window's ··· menu (last section, only
  with a Mac that holds keys). The ··· menu lost Space and Delete (the keyboard's own).
- **The wire** (`Packages/MacrophoneKit/Core/Input.swift`, tests in `InputTests.swift`): three
  messages, three Mac features — `"mouse"` `watchMouse(WatchMouseEvent)` (kind as words: move ·
  click · down · drag · up · show · hide; count 1–3; modifiers by name; an unknown kind is ignored,
  never a session's end), `"typing"` `watchType(WatchTyping)`, `"keyHold"` `watchKeyState(key,
  down)`. Mouse events ride `LinkServer.watchInput` straight from the receive loop (as swipes do)
  to `InputPoster`, per watch, on its own queue; typing and held keys go through `act` (the window
  brought forward first). Old phones' `watchClick` / `watchRightClick` now take the same poster.
- **Speed.** A click is a move, a down and an up 8 ms apart — the old one slept 40 + 50 + 150 ms.
  The pointer is put back 0.1 s later by a timer, never in the next input's way (and not at all
  while the trackpad is up). A window not on top at the spot (or not its app in front) is raised
  first and the click waits for that — the one wait left, only when needed (the whole screen polls
  the raise up to 0.2 s instead of sleeping 120 ms).
- **Hooks.** `MACROPHONE_WATCH_ACTIONS=page@trackpad,point@80@40,click@2,rclick,drag@60@0,
  tap@0.5@0.5@2,page@keyboard,type@words,mod@command,key@cmd+shift+f5,appswitch,page@mic`
  (env vars reach `simctl launch` as `SIMCTL_CHILD_…`). `mpctl serve` names the features
  (`--no-input` is a Mac from before), prints `WATCH MOUSE click ×2 ⌘ at x, y after N moves`,
  `WATCH TYPE N characters, M deleted` (counts, never the words), `WATCH KEY ⌘ down`, and draws
  the pointer, a drag's line and "typed N" in its demo window. `mpctl watch --double-click x,y |
  --drag x1,y1,x2,y2 | --hover x,y | --type "words" | --key cmd+shift+f5 | --hold command |
  --app-switch` sends each as the phone does — to `serve` or the real Mac app. The UI test
  `InputCarouselUITests` swipes the real pages on the simulator (needs a paired `mpctl serve`).
- **Needs a real-Mac check:** a double-click opening a file in Finder and selecting a word in
  TextEdit; a drag moving a window by its title bar; the trackpad's pointer hovering a toolbar
  tooltip; typing an emoji and an autocorrected word into TextEdit and into Terminal; ⌘Tab
  switching apps; a sticky ⌘ with a tap (⌘-click).

## The window in hand (Oct 18 2026, the third polish pass — iOS only)

Sameer: "make the app exceptional … it should almost feel like the Mac is running in real time
on my phone". What this pass found and changed, all in `UI/WatchPanel.swift` / `Model/Watcher.swift`:
- **A switch keeps the picture.** Flipping windows tore the viewer down to an empty plate and
  rebuilt it on the next frame. Now `Watcher.stale` keeps the last window's picture under a dim
  (`Opening …` only after 450 ms, as before) until the new window's first frame; `windowSeq`
  tells the viewer to start that window's view fresh, and any size change (a switch, Fit to
  iPhone, a text size) lands under a 0.22 s cross-dissolve instead of a jump. The slide's group
  opacity (an offscreen pass over the video) is gone.
- **Input is answered at once.** A finger landing on the window gets a mark the moment it
  touches (`touchDown`, a zero-wait press beside the other gestures — a scroll view never hands
  a tap's touches to the view itself; the tap's ring grows from it, a drag fades it, and it never
  outlives 1.5 s). **Simulator only:** a sublayer removed over the video surface keeps its last
  pixels until that region repaints (proven: the ring's layer gone from the tree, presentation
  opacity 0, still on screen) — the click ring and the mark look stuck there; a device
  recomposites. A key, an answer or a Window command pulses the bezel's rim (`inputSeq`) so
  nothing feels lost while the Mac's next frame is on its way. A pan coasts at the normal rate
  (`.fast` stopped short, like a page).
- **Zoom stops at one point per Mac pixel** (`maximumZoomScale = max(1, fitAll × 2)`): three
  screen pixels to one of the Mac's is as large as Retina text needs; past it a pinch only blurred.
  The video layer draws at the screen's own resolution under the zoom (no double scaling — the
  surface is composited, never rasterised).
- **Measured, simulator, `MACROPHONE_WATCH_TIMING=1`** (new on the phone: the log's closing line
  carries "main thread per frame: median / p95 / max"): the frame path's main-thread cost is
  **median 100–160 µs a frame**, p95 544 µs, one 13.7 ms outlier on a window's first keyframe
  (the decoder's set-up). The busiest-second count is kept as frames arrive (the old close-time
  pass was quadratic over the frame times).
- **Tips wait for room** (`WatchTipCard(room:)`, ≥ 250 pt): with the window's answers up at an
  accessibility size, the card had spilled over them. The recording timer stays a clock at
  accessibility sizes (capped at xLarge — it sat across the Thread). Settings' Send after
  pasting says what the speed pass made true: a moment to cancel only when you're at the Mac.

## The mic button (Oct 18 2026, the polish pass — iOS only)

Sameer: "perfect the mic button on the iPhone. Give it polish and quality." What fell short: the
button carried no state beyond ink/ember (sent, queued, error and sending all looked like Ready),
the live halo was a raw-level SwiftUI gradient re-rendered at 30 fps (jittery, a blurred blob), the
landing showed nothing on the button, there was no finishing or microphone-off look, the hit
target was ~86 pt, and VoiceOver knew two states. Now, in `UI/MicButton.swift` (the mechanics —
touch-down start, tap vs hold decided at release, the 0.3 s threshold, the cancelled-touch reset,
the haptics in `AppModel` — are untouched):
- **The ring carries the meaning** (`mode: FilamentMode`, the same state the Thread and the sky
  read): spectrum at rest, gone while the mic is open, teal sending, mint landed, ochre queued,
  rose failed. `finishing` (the recorder's `.finishing`) shows a teal arc where the glyph was —
  a tap waits for the words. `disabled` (a `.problem` that needs Settings: mic or speech
  permission) dims it to `mic.slash` and `.disabled` — iOS relaunches the app when that
  permission changes, so it never stays stale.
- **The light is Core Animation** (`MicLightView`, the Filament's pattern): a lit rim, a bloom and
  a thin ring that breathes with `VoiceDriver`'s smoothed level; a display link only while the mic
  is open (60 fps, 30 in Low Power Mode), nothing at rest; the ring that leaves as the mic opens
  and the one that arrives as a dictation lands are one-shot `CAAnimationGroup`s. Reduce Motion:
  no link, a fixed glow, no travelling rings. Measured on the simulator with the Mac's mic
  (`MACROPHONE_MIC_ONLY=1 MACROPHONE_RECORD=8 MACROPHONE_MIC_TIMING=1`): 486 frames at 60 fps,
  **37 µs median main-thread per frame, p95 63 µs**, one 3.4 ms outlier (the first frame); the
  whole process while recording read the same before and after (the Thread and the transcript
  dominate it). Before, the halo was a `TimelineView` re-rendering a SwiftUI gradient 30× a second.
- **Accessibility:** a label and hint per state (Start dictation · Stop and send · Finishing
  dictation · Microphone off — the UI tests key on the first two), the activate action, the Large
  Content Viewer, `MACROPHONE_A11Y=motion,transparency,contrast` for the three settings the
  simulator can't flip live (the button alone honours it), `MACROPHONE_TYPE=accessibility3`.
- Hooks: `MACROPHONE_MIC_LOOK=pressed|holding|starting|finishing|sending|sent|queued|error|disabled`
  holds a look (the Thread and sky follow); the SE frame is `MACROPHONE_FRAME=375x667`.

## Layout

| Path | What |
| --- | --- |
| `Packages/MacrophoneKit` | Shared Swift package: wire format, pairing + encryption, Bonjour/peer-to-peer transport (`LinkServer` Mac side, `LinkClient` phone side), history store, diagnostics log, on-device cleanup (`Cleaner`, `CleanupPrompts`, `CleanupGuard`), pull-API item shape. `mpctl` is the command-line protocol proof. |
| `iOS/` | iPhone app (XcodeGen `iOS/project.yml`) + `MacrophoneControls`: the Control Center / Lock Screen control and the Watch widget |
| `Mac/` | Menu bar app (XcodeGen `Mac/project.yml`): Send to (live targets, paste and send), History, Agents, Devices, Developer, General; the `macrophone`/`mp` CLI + MCP server (+ `mp hook`); Sparkle updates, `scripts/release.sh` |
| `docs/` | `TARGETS.md` (Send to and delivery), `API.md` (the local API / CLI / MCP contract), `DESIGN.md`, `CLEANUP.md`, `RELEASING.md`, `APP_STORE.md`, `NAME_CHECK.md` |

The website lives in the sameer.us repo (`sameer-gpt`), static pages under `public/macrophone/`.

The app icon is SameerOS's icon in Macrophone's colours (Oct 18 2026, Sameer: "model it after that with the colors we use in the app"): one glowing thread on a night sky with stars — `sh scripts/sky-icon.sh <work> install` renders it from `scripts/render-sky-icon.swift` (a port of SameerOS's `scripts/render-app-icon.swift`; the thread is the Filament at rest, violet · cyan · mint, the sky Theme.swift's Ink lifted toward violet, cyan and teal) into both `.icon` bundles and the fallback PNG sets; the side-by-side sheet is `docs/icon/sky/sheet.png`. The earlier Thread-braid icon (`scripts/thread-icon.sh`, `docs/icon/thread/`) is kept as a record.

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

## The whole Mac from the phone — displays, Mac Controls, Wake (Oct 19 2026)

Part of "control the Mac entirely from the iPhone". Three features, each named in hello / welcome:
- **Pick a display** (`Displays.feature` "displays", `Core/Displays.swift`): the Mac sends `.displays([MacDisplay])`
  (name from NSScreen, global top-left bounds — negative left of / above main — the display's UUID as `id`,
  `isMain`; mirrors left out) after welcome and on `didChangeScreenParameters` (`Mac/App/Watch/Displays.swift`,
  `Core/MacReach.swift`). With 2+ displays the phone's switcher and Send to's ⋯ list "Whole Screen — Studio
  Display" per display (`WholeScreenItems`, `UI/MacControls.swift`); the place is still DesktopWatch with
  `windowKey` "display:<UUID>" (`Displays.target/key`). The Mac's `resolve` sets `MacDisplays.watch(key:)`;
  `WindowServer.desktopBounds` (stream, clicks, scrolls) follows `MacDisplays.watched` — the picked display while
  connected, else main; a change drops and remakes the stream. The last pick is `watch.display` on the phone. One
  display → unchanged UI; an older Mac ignores the key (main display). Two phones on two displays share the last pick.
- **Mac Controls** (`MacControl.feature` "macControls", `Core/MacControls.swift`): volume down / mute / up,
  dimmer / brighter, previous / play-pause / next. Phone → `.macControl`, Mac posts the NX_SYSDEFINED event
  (subtype 8, data1 = key << 16 | 0xA/0xB << 8; `Mac/App/Core/MediaKeys.swift`), reads the output volume / mute
  back from Core Audio 120 ms later and answers `.macControlDone` ("Volume 56%", "Muted"); brightness on a Mac
  with no built-in or Apple (vendor 0x610) display answers that it can't. Phone: `MacControlsMenu` — a submenu in
  the window view's ··· keys menu (its own section, first — the menu opens upward, so it sits by the thumb) and in Send to's ⋯; a press ticks and keeps the
  menu open (`menuActionDismissBehavior(.disabled)`); the answer shows in the status line.
- **Wake Your Mac** (`WakeInfo.feature` "wake", `Core/Wake.swift`): the Mac sends each `en*` interface's hardware
  address, IPv4 address, mask and broadcast, and `pmset -g` womp (`Mac/App/Core/WakeInfo.swift`, `MacWake`, re-read
  on NWPathMonitor changes). The phone keeps it by Mac id (`Model/WakeOnLAN.swift`, UserDefaults
  `wake.info.<id>`, forgotten on unpair). Paired, not connected/connecting, and on a network the Mac was on →
  **Wake Your Mac** beside the Mac pill (`WakeMacButton`): the 102-byte magic packet to the subnet broadcast,
  255.255.255.255 and the Mac's last address, UDP 9 and 7, three times 0.4 s apart, then `ensureConnected` every
  2.5 s for 30 s; the words say same Wi-Fi only and a closed laptop on battery may not wake. Devices on the Mac shows
  one line ("Wake for network access is off" + where to turn it on) only when womp is 0 — never changes it.
  **iOS sends broadcast only with the multicast entitlement** (com.apple.developer.networking.multicast, requested
  from Apple); without it the broadcasts fail on a device and only the unicast to the Mac's last address goes
  (works while the router still knows the Mac, or with a sleep proxy). The simulator isn't restricted.
- Hooks: phone `MACROPHONE_FAKE_DISPLAYS=1`, `MACROPHONE_REACH=whole@<id>,whole,control@volumeUp,wake`,
  `MACROPHONE_WAKE_PORT=<n>`; Mac `MACROPHONE_FAKE_DISPLAYS=1`, `MACROPHONE_FAKE_MEDIA_KEYS=1` (DEBUG, answers
  without pressing). `mpctl serve [--displays N] [--wake-port N] [--womp 0] [--no-brightness]` (two demo
  displays, counts keys and magic packets, presses nothing); `mpctl control <volumeUp|mute|…>`.
  UI test `MacReachUITests` (`TEST_RUNNER_MACROPHONE_REACH_TEST=1`, a simulator paired with `mpctl serve`).

## Watching, one-handed (Oct 16 2026)

- **Pan | Scroll** ends the key row (under the thumb): one finger moves the picture (the default,
  every time a window opens) or scrolls the Mac's window. Newest sits in the window's corner once
  you've moved away. **[Oct 18 2026: Scroll picks itself when the whole window is on screen, and
  a window fitted to the phone opens in Scroll — see the map above.]**
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
  question; the phone posts a notification, and a tap opens that window. **[superseded Oct 17
  2026: with the app closed, the alert goes through the person's own iCloud — `CloudAlerts` on the
  Mac, `AgentAlerts` on the phone, builds signed with the iCloud profiles
  (`MacrophoneCloudAlerts=YES`); the phone's hello says `attention-cloud` once subscribed.]**
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
- **Aa — readable text (Oct 17 2026). [superseded: there is no Aa — it is "Text size on this
  iPhone" inside the Window menu, under Fit to iPhone; `WatchFitMenu` is gone.]** Normal · Larger ·
  Largest, remembered per app in `watch.fit.<bundle id>`: the Mac resizes the watched
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

## Permissions on the Mac, and the video lane away from home (Oct 19 2026)

**Permissions.** The Mac's setup is pair · paired · login · **permissions** · modes (four dots).
`Mac/App/Core/Permissions.swift` (`PermissionsMonitor`, on `AppModel.permissions`) reads
`AXIsProcessTrusted` / `CGPreflightScreenCaptureAccess` every second while a page showing them is
open, every ten otherwise, and on app activation — it only reads; each row's "Open System
Settings" opens that exact Privacy pane (asking once first, so Macrophone is in the list).
`UI/Components/PermissionRows.swift` is the one view (Accessibility: "to click, type and paste for
you"; Screen Recording: "to show your Mac on your iPhone"; a mint check and "Allowed" once on;
a "quit and reopen" hint if Screen Recording was asked and still reads off) — the setup step and
General › Permissions. Diagnostics' header adds Screen Recording and "Pictures on their own
connection". The wire (`Core/MacPermissions.swift`, `Transport/PermissionsLink.swift`, feature
`permissions`): `.macPermissions` Mac → phone after the welcome and on every change;
`.showPermissions` phone → Mac opens the setup at Permissions (`AppModel+Permissions.swift`).
Separate delegate protocols (`LinkServerPermissionsDelegate`, `LinkClientPermissionsDelegate`), so
the big delegates are untouched. Phone: `UI/MacPermissionNote.swift` — a compact banner over a
live window when Accessibility is off ("Your Mac needs to allow Accessibility — open Macrophone on
your Mac", Open Macrophone on my Mac, ×), and the Screen Recording note now says "Open Macrophone on
your Mac" and its button opens it there (an older Mac: the setting itself, as before).
Hooks: phone `MACROPHONE_FAKE_PERMISSIONS=accessibility|screen|both`; `mpctl serve --permissions
accessibility=off,screen=off`, `mpctl listen --features permissions --show-permissions`.

**The video lane** (`Transport/VideoLane.swift`). Away from home the window's pictures ride a second
TCP connection, so a lost packet of video never holds up a tap, a key, a pong or an answer.
Negotiated: the Mac's welcome names `videoLane` (`LinkServer.laneEnabled`), the phone's hello too
(`LinkClient.laneEnabled`, added by the transport itself); a phone connected **from away** then
dials the same address again with `Handshake.laneHello(phoneID, proof)` — proof = HMAC(pair key,
"lane-phone" ‖ that session's nonces) — the Mac checks it against the open session, answers
`laneReady` (its own proof), and from then `.watchVideo` / `.watchFrame` go on the lane under their
own HKDF key and counter (`LaneSecrets`, `LaneLink`); everything else stays on the session. One
lane per session, refused otherwise; a lane that drops or fails a send puts the pictures back on
the session (the phone asks for a keyframe for any it missed); the session closing closes it.
At home, an older phone or Mac, or a lane that won't open: exactly today's single connection.
**Why not QUIC:** Network.framework's pre-shared key is TLS 1.2 only — adding one pins
`max_version` to 0x0303, and QUIC needs 1.3, so QUIC + the pair key fails
`NO_SUPPORTED_VERSIONS_ENABLED` (-9858; seen in boringssl's log). QUIC with a certificate would mean
making and keeping a signing identity in a keychain on his Mac. Not worth it for what the lane gives.
**Measured** (`mpctl relay`, a link model: 80 ms round trip, a lost 1448-byte segment one round
trip late and everything behind it on that connection waiting — TCP's in-order rule; real packet
loss needs the firewall's shaper, off limits): `mpctl serve --busy` streaming ~19 frames a second
(~29 KB each), `mpctl probe` timing a ping every 0.1 s for 30 s. Before (one connection) → after
(the lane): 0% loss 81 → 81 ms median; 1%: mean 98 → 83 ms, round trips over 120 ms 21.5% → 2.1%,
p95 154 → 81 ms; 2%: mean 108 → 84, over 120 ms 35.4% → 3.6%, p95 159 → 82; 5%: mean 131 → 88,
median 131 → 81, over 120 ms 55.1% → 9.7% (≈ the ping's or pong's own loss, which nothing avoids),
p99 345 → 161, max 720 → 161 ms, and video 16.4 → 19.4 frames a second. The move home (`roam
--bonjour-after 3 --expect home`) and away (`--expect remote`) still pass with the lane.
Hooks: `mpctl serve --busy` / `--no-lane`, any phone command `--no-lane` / `--only-dial` (just the
`--dial` address, not the Mac's list), `mpctl relay --listen P --to host:port --loss 0.02 --rtt 80`,
`mpctl probe --seconds 30 --every 0.1 [--slow 120]`; `LinkClient.roundTrip()` / `hasVideoLane`,
`LinkServer.hasLane(peer)`. Tests: `VideoLaneTests` (the rule, the secrets, both fallbacks, a
wrong proof, a dropped lane, over loopback on ports 47916–47919). Still needs a real phone on
cellular with Tailscale: the lane's log lines ("video lane open in N ms") on both sides.

## Agents tell the Mac themselves (Oct 17 2026)

Sameer picked "know exactly when an agent waits" over reading pictures. Claude Code (hooks) and
Codex (`notify`) run `…/Contents/Helpers/macrophone hook claude|codex`, which posts an
`AgentEvent` to `POST /v1/agent` (silent, exit 0, 1.5 s cap). `Watch/AgentHub.swift` keeps one
`AgentSession` per session (working · waiting · yourTurn), finds its app from the hook's
ancestor pids and its window (kept; the app's only one; a title naming the project; the front
one on a new prompt), sends `.attention` the moment one waits (iCloud when no phone is
connected). The attention watcher skips windows an agent claims. Mac › **Agents** (its own
sidebar page since Oct 18; `AgentsPane`) connects/disconnects (`Core/AgentSetup.swift`; backs the
file up once; never replaces his own Codex `notify`). The phone's Agents panel (Oct 17) was
removed Oct 18 — "takes up too much space ... not actually a useful section" — **and with it the
`agents` message, `AgentSession.feature`, `liveAgents` / `broadcastAgents` and the screen-read
sessions (Oct 18, the integration pass): `AgentSession` is now the Mac's own record.**
Same day: More keys (`WatchKey`, feature "keys": ⌃C, Tab, ⇧Tab, ⌘↩, ⌘Z, Space, ⌫, digits —
by name, so a newer key never breaks an older Mac), Fit to iPhone (`watchShape`, feature
"fitPhone": the window takes the phone's view shape at full screen height), first-use tips
(`UI/WatchTips.swift`, one card at a time over the window's top; Window › Show Tips Again),
the zoom kept per app (`watch.view.<bundleID>`, dropped when the window's shape changes), and a
minimized window stays the watched one so "Show it on my Mac" brings it back.
`mpctl serve` names every new feature. **[The tips set is the map's, six at most.]**

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

## Hear the Mac (Oct 19 2026)

Part of "control the Mac entirely from the iPhone": the Mac's sound plays on the phone while a
window shows. **Off by default — on a fresh install, after an update, whenever it isn't explicitly
on** (Sameer's rule): only a tap on **Sound** (`speaker` / `speaker.wave.2.fill`, its own
glass beside the zoom-out | Window cluster, shown only when the Mac names `sound`) turns it on,
remembered in `watch.sound.on` (`SoundSetting`: anything but a stored true is off; pinned by
`SoundDefaultTests`). The Mac sends nothing to a phone that didn't name `sound` AND send
`watchSound(true)` (`MacSound.sends`).
- **Wire** (`Core/Audio.swift`): phone → Mac `watchSound(on:)`, Mac → phone `macAudio(MacAudioPacket)`
  — seq, stream id, sample time (a jump = a gap the Mac marks), Opus 20 ms (AAC-ELD if a Mac lacks
  Opus), the decoder's cookie on the first packet and every 50th, `sentAt`, `macDelay`. 96 kbps at
  home, 40 away (`MacSound.bitrate`). `MacAudioEncoder` / `MacAudioDecoder` (AudioConverter),
  `MacAudioSender` (numbering, gaps), `SoundJitter` (pure: holds 70 ms — 120 away — before playing,
  plays silence and refills when dry, drops the oldest past +90 ms instead of drifting, drops
  late/out-of-order, starts over on a new stream; an emptying inside a marked gap isn't an
  underrun), `SoundLatency`, `TestTone`. Tests: `AudioTests.swift`.
- **Mac** (`Watch/AudioPipe.swift`): its own ScreenCaptureKit stream of the main display's
  **audio — the whole system mix, Macrophone's own excluded** (`excludesCurrentProcessAudio`;
  48 kHz stereo; a 2×2 picture at 1 fps as the stream's price). So a window watch hears everything
  the Mac plays, not just that app — kept separate from `WindowStream` on purpose: flips, resizes
  and the video→pictures fallback never cut the sound. One capture while any phone listens; per
  phone a sender and one ordered send task (newest 25 kept). Off on `watch(nil)` (also sent on
  disconnect) and `watchSound(false)`. Same Screen Recording permission, nothing new.
- **Phone** (`Model/MacAudioPlayer.swift`, `UI/WatchSound.swift`): plays only while Sound is on, a
  window is live/starting, the app is in front, the mic is closed and the Mac can. The packets go
  from the link's receive queue (`LinkClient.onMacAudio`, no main actor) through the decoder into
  the jitter buffer; an `AVAudioSourceNode` pulls it. Session `.playback` + `.mixWithOthers`, only
  while playing: playback because he turned Sound on (the silent switch muting it would read as
  broken), mixing so it never stops his podcast. The mic wins: `startRecording` stops it before
  the recorder opens (`MicHardware.configure` now resets `.record` if the category changed); it
  resumes 0.4 s after the mic closes. Away from home it restarts at the lower bitrate.
- **Measured** (simulator ↔ `mpctl serve`'s tone, loopback): latency estimate **median 78–88 ms,
  p95 83–94** (Mac 20 — the packet's own 20 ms; wire 1; buffer 54–64; output 3), **0 underruns,
  0 late**, Opus ~48 kbps on the tone, decode ~90 µs a packet; mic open → off, back on after.
  mpctl phone ↔ serve: median 60 ms (no output stage), a 2 s gap marked as a gap, 0 underruns.
- Hooks: phone `MACROPHONE_SOUND=1` (on for a run, not stored), `MACROPHONE_SOUND_TIMING=1` (a
  line a second), `MACROPHONE_WATCH_ACTIONS=…,sound,mic`; Mac `MACROPHONE_SOUND_TONE=1` (DEBUG: the
  tone instead of the capture); `mpctl watch --sound --features video,sound`, `mpctl serve
  --sound-gap 2`. Logs: "sound: N packets, kbps · latency estimate … · underruns · late · trimmed
  · gaps · resyncs" (phone), "sound on/off: N packets, N gaps" (Mac) — numbers only.
- Needs a real check: the capture on Sameer's Mac (does a silent Mac send silence or nothing —
  either works), Bluetooth output latency, a call interrupting it.

## Checks

```
cd Packages/MacrophoneKit && swift test
swift build && .build/debug/mpctl serve --auto-approve   # then mpctl pair '<url>' / pair-code / send
.build/debug/mpctl cleanup-eval                           # cleanup test set on the real on-device model
.build/debug/mpctl watch --target com.anthropic.claudefordesktop --swipe 0.3 --features video   # a swipe as the phone sends it, video back
.build/debug/mpctl watch --sound --features video,sound      # the Mac's sound: serve's tone, latency and underruns printed
.build/debug/mpctl serve --remote --port 47899 --auto-approve   # then: mpctl pair '<url>' (at home), and
.build/debug/mpctl roam --no-bonjour --bonjour-after 3 --expect home   # away by the stored address, then back home
.build/debug/mpctl relay --listen 47915 --to 127.0.0.1:47899 --loss 0.02 --rtt 80   # a lossy link (with serve --remote --busy)
.build/debug/mpctl probe --no-bonjour --dial 127.0.0.1:47915 --only-dial --features video [--no-lane]   # input round trips under it
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
