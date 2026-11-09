# Macrophone

Free iPhone app + companion Mac app: dictate on the phone, pick any app open on the Mac (or the
clipboard, or wherever you're typing), and the text is pasted there — or pasted and sent — at the
cleanup level you choose (Off · Light · Medium · Heavy · Custom). Agents can pull dictations through
a small local API / CLI / MCP. Simplified to that core on Oct 13 2026 (automations, snippets,
templates and the Delivery pane were removed on purpose — don't bring them back unasked).
The original spec is `docs/SPEC.md`. Push to `main`.


## The window runs edge to edge (Nov 9 2026)

Sameer: "make the UI feel more like a Mac app window running natively on the iPhone." What still read
as a picture being shown was the 10 pt of wallpaper down both sides of the window: an app on an
iPhone runs to the screen's sides.
- **`WatchPanel`: the window has no side margin** (the regular iPhone and the cover); the header, the
  tip strip, the answers and the key row keep `WatchLook.sideMargin`, as a bar's buttons do over
  full-width content. A Pro's window is 402 pt wide (was 382), its text ~5% larger. `WindowZoom
  .estimate` insets nothing. The resize arc is kept on screen at full width, tucked into the wedge
  the window's own rounded corner leaves (`ResizableWindow`, `min(corner.x − 3, room.width − 10)`).
- **The side swipe is the screen's own edge gesture** (`EdgeFlips`: two
  `UIScreenEdgePanGestureRecognizer`s on the app's window while the panel shows, only for touches level
  with it, only with two or more windows; pans under them wait for the edge to fail). The 14 pt
  SwiftUI strips beside the window are gone — nothing lies over the window's sides.
- **A shape that isn't a window's is never sent or remembered** (`Watcher.plausible`: ≥ 150 pt tall,
  0.3–3 wide for its height): once, flat upright on a fresh Duo simulator, the view measured 645×117
  mid-layout and the Mac was asked for a 5.5:1 strip, which was then remembered for the next opens
  (and the round-2 re-arm that used to correct it is gone). Not reproduced in four more tries; the log
  says "a view of W×H isn't a window's shape — not sent" if it comes again.
- Tests: `ResizableWindowUITests.testTheWindowIsEdgeToEdgeAndTheScreenEdgeFlips` (the window's frame
  is the screen's width; a swipe in from the right edge shows the next window, from the left the one
  before), with Resizable (2), InputCarousel (4), FullScreen (3), DesktopWindow and Stability passing.
  Seen on the Duo's cover (full width beside the vertical bar). The inner screen's halves were already
  edge to edge.
- **Needs his phone:** the edge swipe against iOS's own gestures on a real screen; whether a tap on a
  Mac window's close button at the very edge is slower to register (pans wait for the edge, taps don't).

## Alerts that reach a closed app, answered from the notification (Nov 9 2026) — wins over the older alert sections where they differ

Sameer's loop is dictate → pocket the phone → come back for the answer; the second half never
worked with the app closed, and a question needed the app opened to answer.
- **Why no alert ever reached a closed app:** the phone's `CKQuerySubscription` was refused by the
  Production container every time — CKError 12, "attempting to create a subscription in a production
  container" (a query subscription's type has to be made in Development and deployed). Found with a
  one-shot probe in the Mac app (`CloudAlerts.probeIfAsked`, `defaults write
  com.sameer.macrophone.mac cloud.probe -bool YES`, then relaunch; it logs "cloud probe: …" for five
  subscription shapes and removes them): every query shape refused, **zone and database
  subscriptions taken**. Nothing in the CloudKit Console is needed.
- **Now:** alerts live in a private zone `Alerts` (`AlertAnswers.zone`). The Mac writes each record
  there (`CloudAlerts.zoneID`, the zone made on first use); the phone saves a
  `CKRecordZoneSubscription` (`AgentAlerts.subscriptionID` "alerts-zone"; the old "ask" is deleted if
  it ever existed) whose push says a plain line with mutable content; the notification extension
  (`NotificationService`) reads the zone's records (`recordZoneChanges`, no index needed), shows the
  newest — headline, line, picture, buttons — and deletes that one. A push that finds the zone empty
  shows "Your Mac" and the plain line. **Both apps must be on this build** (an older Mac writes to
  the default zone, which nothing pushes).
- **Answer from the notification** (MacrophoneKit `Core/AlertAnswer.swift`, `Transport/AlertAnswerLink.swift`,
  feature `alertAnswer`): `MacAlert.answers` (the question's answers as the window words them; in
  the cloud payload too) → `AlertNotification.category(for:)`: up to three answer buttons ("1. Yes"…,
  cut to ~36 letters) and **Reply…** (a text field; the keyboard's mic dictates) for a question, Reply
  alone for a chat's answer, nothing for anything else. Categories are made per set of buttons
  (`mac-<hash>`) and registered just before the notification shows (`AlertNotification.prepare`, in the
  app and in the extension). A tap (`AgentAlerts.userNotificationCenter(_:didReceive:)`) →
  `AppModel.answerFromNotification`: connects in the background (9 s at most), `.alertAnswer` → the Mac
  (`Watch/AlertAnswerer.swift`) finds the window, reads what it asks **now** (`AXPrompt`, else
  `PromptVision`) and only if it's still that question (`prompt.id`) brings it forward and gives the
  answer — the card's controls, or the same keys as the window view's chips — and marks the window a
  chat so its reply is told. Anything else answers nothing: "‹App› isn't asking that any more". A
  miss posts "Not answered" with why; a tap on it opens the window. Reply →
  `replyFromNotification`: a dictation to that window with send, through `deliver` (queued if the Mac
  can't be reached). Claude Code's hook alerts read their window's answers 0.7 s after it asks
  (`AgentHub.alert`) so they carry buttons, with the window's own prompt id.
- **Proven:** `swift test` 355 (`AlertAnswerTests`: the record and the wire; the category tests are
  iOS-only). Simulator against `mpctl serve --attention-after 3` (it names the feature, puts answers
  on its question and prints `ALERT ANSWER 1 for …`): iOS holds "1. Yes | 2. Yes, and don't ask again
  this sess… | 3. No, and tell Claude what to do ins… | Reply…" for the notification; answer 1 reached
  the Mac; "use the smaller change" was sent into the asking window
  (`AlertNotificationUITests.testAnAnswerAndAReplyFromTheNotification`, `TEST_RUNNER_MACROPHONE_ANSWER_TEST=1`;
  hooks `MACROPHONE_ALERT_ANSWER=<index>`, `MACROPHONE_ALERT_REPLY=<words>` — the simulator's long
  press on a notification turns into a sideways swipe, so the buttons are read from the system's
  registry and the tap's handler is called).
- **Needs his phone and Mac (nothing here could prove these):** a push from the zone subscription
  arriving with the app closed, and the extension filling it; the buttons as iOS draws them on a
  long press; `AlertAnswerer` on a real Claude / Terminal question (the stand-in presses nothing);
  an answer tapped with the phone away from home (the background connect over Tailscale in 9 s).

## The reliability review (Nov 9 2026)

Sameer: "Review this app and make the improvements you think are needed to deliver the value prop."
The screens held up; what didn't was what happens when something goes wrong between the mic and the
Mac. Each proven on a simulator against `mpctl serve` (frozen with `kill -STOP` by PID to stand in
for a dead link).
- **Words never die with the app** (`AppModel.inFlightWords`, a second `DeliveryQueue` at
  `AppFiles.inFlight`): a dictation is written to disk as the mic closes and removed when `deliver`
  returns (acked or queued). Until now it lived only in memory until cleanup finished — up to a
  minute on a long prompt, with the phone usually pocketed and the app suspended ~25 s in — and a
  send cut short stayed "Sending" in History for ever. `recoverInFlightWords()` at launch puts what's
  left into the queue as it was said (uncleaned); the Mac drops one it already has (same id).
  Proven: app killed mid-send → "1 dictation from the last run recovered into the queue" → delivered.
- **A retry moments after a blip pastes and sends as asked** (`flushQueue`, `AppModel.freshFor`
  120 s): everything from the queue used to go `delayed: true`, which the Mac only ever copies — one
  dropped packet away from home turned "send to Claude" into a silent copy. Now `delayed` is for a
  dictation older than two minutes; a fresh one goes where it was sent. **This narrows the Oct rule
  "a delayed item is never pasted"** to items that actually sat. A failed send with the link still up
  retries by itself 6 s later (`retryQueueSoon`), not at the next connect or dictation.
- **A Mac that goes silent is noticed** (`LinkClient.pingEvery` 15 s, `silenceLimit` 10 s): nothing
  from the Mac after a ping ends the session, so the phone stops reading Ready over a dead link and
  looks for the Mac again. Proven: "nothing from the Mac for 10 s after a ping", reconnect, the queued
  dictation landed pasted.
- **What the UI fires reaches the Mac in order** (`SecureSession.post`, one outbox task): every
  key, click, typed character, watch and shape went in a task of its own and could swap on the wire
  (a release before its press, letters out of order). **The Mac runs what the phone asks of a watched
  window one at a time** (`WatchService.actChain`). The Mac app changed: `Mac/App/Watch/WatchService.swift`.
- **The route is decided as the recording ends**, not after cleanup (a second recording started
  meanwhile could take the first one's place); words held for a word's card go when the app leaves or
  a new recording starts; a resize drag the system cancels still ends (`@GestureState`).
- **Dead code out** (665 lines): `DesktopWidget.swift`, `WindowChrome.swift`, the old controls panel
  and helpers nothing used.
- Tests: `swift test` 353; WatchHeader (2), InputCarousel (4), Stability, FullScreen (3), DesktopWindow,
  UndoChip (7), HardwareKeyboard (2), ResizableWindow (2, against `serve --reshape`) pass on an
  iPhone 17 Pro. `VideoLaneTests`-style loopback tests can fail once when the machine is busy building.
- **For Sameer to decide:** a dictation recovered after a kill goes uncleaned (cleaning it at
  launch is possible); an app that isn't open is still "copied instead" rather than opened; the
  resize does nothing visible for a window the Mac can't reshape.

## On its side, the window's name heads the right page (Nov 9 2026)

Sameer: "move these controls in landscape mode to the top of the right screen so that there is more
room on the left for the window". On the inner screen on its side (flat landscape, the book) the
window's header — the app's icon and name menu, the page dots, the paperclip — is the first row of
the right page's deck (`DuoDeck.modes`, `vertical`), above the mode's room; the left page is the
window alone from the page's top (lined up with the deck at `DuoLook.edgeInset`), its answers row
under it. The window's other buttons stay in the vertical bar. Frames checked on a duo-sim open and
folded pose; `DuoUITests` book and open-landscape pass.

## The corner arc on the inner screen too (Nov 9 2026)

Sameer: "The resize arrow should be available on the inner display as well and the window should
still default to be the largest it can be to fill a given space. The only place it is not needed is
laptop mode where it should default to always take half the screen." `DuoMacHalf` wraps its window
in `ResizableWindow` on every inner pose but `.laptop` (`resizable`: not the laptop, not the Whole
Screen, not hidden); flat upright, the side page and the book have the arc, the laptop's half is
the Mac's screen, whole. A pose change (`watcher.input.pose` in `ResizableWindow.opening`) starts the
window at all its room again, as an open or full screen does. Found on the way: the side/book page's
`shortPicture` (a window too short to fill the page sits at the top at its fitted height) applied to
every window, so the page measured the current picture's height and sent that shape back to the Mac
— the window could never grow to fill the page (438×282 on a 438×475 page); it's only for a window
the Mac can't reshape now (the Whole Screen, an older Mac). `ResizableWindowUITests
.testTheInnerScreenResizesExceptTheLaptop` (`TEST_RUNNER_MACROPHONE_DUO_REAL=portrait|side|book|laptop`,
a duo-sim pose) passes on all four.

## The window illusion (Nov 9 2026) — wins over every native-window section below where they differ

Sameer, on his Duo with build 28: "app windows are buggy as hell! It ends up getting scrunched up
and weird in quite a few modes. This doesn't feel like bring[ing] live Mac windows to iPhone", "the
resizing also is not super responsive", "I still see black in the corners too", "Why do you need to
match radius. Can't you just take the window recording and plop that straight in", and the goal:
"It's more of an illusion I'm going after … it should look and feel like we pulled the window of the
app directly from the Mac and ran it on the iPhone. To sell the illusion the window needs no borders
and the resizing needs to be as responsive as possible." Three streams, merged: the rendering rule
(the viewer), the window's real corners (the Mac), live shapes while the corner is dragged (the
wire). Frames: `docs/screens/window-illusion-nov9/` (`before/` build 28's code, `after/`, `real/`
the real pipeline; its README says what each shows). **The Mac app changed** — it needs installing:
`Mac/App/Watch/WatchService.swift`, `Mac/App/Watch/WindowMask.swift` (new), `Mac/App/Watch/VideoPipe.swift`,
`Mac/App/Core/AppModel.swift`, and the kit.
- **The rule, in one sentence** (`ViewerScrollView`, the MARK "One window, one picture, always its
  own shape"): the window on the phone is the Mac's latest frame at its own aspect, fitted whole
  inside the room it has — never stretched, never cropped or "covered" by the app (only his own
  pinch zooms in) — and the shadow, the hairline and the resize arc hug exactly the picture shown.
  `ViewerScrollView.fittedRect(_:in:)` is the one place the fitted rect comes from: the viewer's zoom
  and insets (`configureZoom` + `centerIfSmall`), the arc's corner mid-drag (`ResizableWindow
  .arcCorner`) and the flights (`WindowZoom.fit`, `FullScreenZoom.enter` / `exit`) all read it.
  When the Mac's window changes shape (an open, full screen in or out, a fold, a resize) the phone
  keeps showing the frame it has, fitted, until the frame at the new shape arrives, then shows that
  one fitted in its place under **one 0.15 s cross-fade**: the old frame as a still exactly where it
  was (`makeStill`: aspect-fit in the old canvas rect, clipped to what showed, the window's corners),
  **the canvas hidden under it** (`hold`: `canvas.alpha = 0`) until a frame at the new size has
  displayed (`VideoCanvas.holding` / `release` stand) — so nothing of the old frame is ever drawn at
  the new geometry. That double drawing (the layer's old frame fitted into the *new* canvas under the
  still) was the "double exposure of two windows" of build 28.
- **What went** (the choreography that showed a window at another shape than its own): covering a
  view from its top-left (`otherShape`, `coverScale`, `coverCap`, `fromCorner`, `fitsOtherShapes` on
  `WatchWindow` / `WindowViewer`, `keptOtherShape`), filling a folded half by zoom (`fill` zooms
  nothing now — the laptop's half, the glance and full screen letterbox a window of another shape
  on the veiled wallpaper until the Mac's reshaped frame lands; `fill` still means "edge to edge, no
  shadow, the half's measure"), zooming onto the column you type in at an open (`startScale`'s focus
  rule, `fillCap`), the drag's cover-and-anchor (`keepZoomResizing` fits now, keeping his zoom ratio
  over fit and the top-left when zoomed in), `resizeSettle` (the release fits at once — the Mac has
  taken every size already), `imageView` and every snapshot at `.scaleAspectFill` (all `.scaleAspectFit`).
  `ViewerScrollView.Mode`: `.fit` everywhere, `.foot` for the words' strip (`WatchStrip`: the
  window's width across, its foot at the strip's foot). `opensWhole` is true unless he left the app's
  window zoomed. Full screen's flights (`FullScreenZoom`, `prepare` / `takePrepared`, the windowed
  viewer hidden under the flight) stay — their start is the viewer's shown picture and their end is
  `fit(picture, in: screen | frame)`, which is exactly where the viewer under them opens it, so they
  land pixel-exact; the Dock/card flight (`WindowZoom`) the same (`estimate` fits).
- **The arc on the picture, mid-drag too** (`ResizableWindow.arcCorner`): during the drag the
  fitted rect is computed in the same SwiftUI pass from the picture's aspect, so the arc sits on the
  picture's corner with no frame of lag; a window he had zoomed in (`zoomedAtStart`) covers the
  frame, so the frame's corner then; at rest the viewer's `onPictureShown`.
- **No borders: the window's real corners, from the Mac, once per size** (MacrophoneKit
  `Core/WindowMask.swift`: `WatchWindowMask` — `width`/`height` the picture pixels it was read at,
  `radius` where the arc meets the edge (not a circle fitted to the diagonal: Tahoe's corner reads
  ~10 px transparent on the diagonal and opaque only from 48 px along the edge), `corners` a PNG of
  side 2·(r+1)+2 whose quadrants are the four corners' own alpha with a 2 px opaque cross between
  them; `WindowMaskReader.make` / `radius` pure, `WindowMaskTests`; `Transport/WindowMaskLink.swift`,
  `.watchMask` Mac → phone, feature `windowMask` in hello and welcome — an old phone or Mac keeps
  today's stream and the pixel guess). **Mac** (`Watch/WindowMask.swift`, `WindowMaskCapture`): on
  every change of the stream's pixel size (start, resize, reshape, companions) one BGRA frame with
  alpha — `SCScreenshotManager.captureImage` with `ignoreShadowsSingleWindow` **does** carry alpha on
  macOS 27, for the single window and the display-area filter alike; a one-frame BGRA `SCStream` and
  `CGWindowListCreateImage` are fallbacks never reached — read off the main thread, debounced 150 ms,
  never the same twice, never for the whole screen; log "window mask: 48 px round at 1850×2168,
  read in 121 ms (screenshot(alpha), 1738 bytes, with 2 companions)". **Phone**: `Watcher.mask`
  (cleared on a switch / close; `maskArrived` keeps the last radius when a read mid-reshape found no
  corners — "0 px … radius only" showed square corners for half a second on a live resize),
  `ViewerScrollView.applyClip`: a mask for this picture's size is a 9-slice `CALayer` mask on the
  canvas (`contentsCenter`, one mask pixel per picture pixel, so it zooms with the canvas) and
  `pictureCorner = radius` (the shadow, hairline, arc, stills and flights all take it); a mask for
  another size scales the radius with the width when the shape is the same (a remote-narrowed
  picture), keeps it as read when the shape differs; no mask → the Nov 8 pixel guess, unchanged.
  `mpctl serve --rounded` draws the demo with transparent corners and sends the mask (`WATCH MASK`);
  `--rounded-black` paints them black with no mask (the fallback); `mpctl listen --features windowMask`
  prints `MASK 53 px at 1192×1084`. **Why not HEVC with alpha** (measured, `mpctl alpha-bench`: 60
  frames of the demo at 1400 × 900 BGRA — HEVC 10.1 ms / 11 KB a frame, HEVC-with-alpha 10.0 ms /
  12 KB, "Apple Muxed Alpha" supported): the encoder is free, but it needs BGRA capture at 30 fps
  (4 bytes a pixel against 1.5 for 420f) and a display path on iOS nobody has proven, for four
  corners that change only when the size does. The mask is 1.2–2.2 KB once per size.
- **Resizing: the Mac's window follows the finger** (MacrophoneKit `Core/Messages.swift`
  `.watchShapeLive(width:height:final:)`, feature `WatchShape.liveFeature` = "fitPhoneLive" in the
  Mac's welcome; `WatchShape.liveShapeDue` pure, `LiveShapeTests`; `LinkClient.watchShape(_:live:
  final:)` — to a Mac from before a live shape sends nothing and the final one is today's
  `watchShape`). Phone: `ResizableWindow`'s drag → `Watcher.resizingShape` sends when due (every 90
  ms at most, only when the aspect moved > 1%, the newest pending one on the next tick); the release
  → `resizedHere` sends `final: true` the same way (the Mac's AX reshape is aspect-only, so a drag
  that shrinks both sides alike sends few). Mac (`WatchService.fitToPhoneLive` → `applyLiveShape`):
  applied **at once**, one AX resize per 80 ms with the newest pending, **no `holdForReshape`** (kept
  for the non-interactive `watchShape` path — a pose change, an open), and `stream.resize(to:)`
  straight after the AX set (the loop's `look` is 0.25–1.5 s away), then `hurry` + `wake`; each
  size is a new encoder and a keyframe; log "watch live shape: 925 → 661 px wide, 5 shapes in 1.4 s
  · 2 keyframes, 1008 KB streamed". `mpctl serve --reshape` applies live shapes at once (`WATCH
  SHAPE live 0.55 · RESHAPED 492×900`, `… final … · N shapes this drag`), `--reshape-delay <ms>` for
  the old path (500), `--no-live-shape` a Mac from before; `--busy` no longer overlaps its columns.
- **Measured.** *Shapes per action*: open, full screen in, full screen out — one each (serve
  `WATCH SHAPE` ×3; the real pipeline's log `watch fit to iPhone` ×3: 656×422 → 925×1084,
  → 745×1084, → 925×1084), a fold between the laptop and flat upright none, a flip one (ahead) and
  one restore. Build 28's log had sixteen in a minute. *The drag, real pipeline* (a Debug copy of the
  Mac app, the Duo's cover, XCUITest's slow drag — one event every ~170 ms, a finger gives ~11/s):
  5 shapes in 1.4 s, 2 keyframes, 1008 KB; the first new-size frame on the phone **102 ms** after
  its shape went, the second 817 ms (an AX resize the app took its time over); the Mac copy's CPU
  through the watch and the drag median 4.4%, max 18.1%. *On serve* (the live fork's runs):
  finger → shape → `RESHAPED` → new-size frame 60 / 81 / 106 / 96 / 192 / 270 ms, median ~100; one
  18 KB keyframe per size at 422–596 × 900. *The phone's main thread through the drag* (xctrace Time
  Profiler, 100 ms buckets, the Pro against serve, XCUITest's slow drag): at first 56–95 ms busy
  per 100 ms through the drag, 0.4 s of it at 89–95% (9 buckets ≥ 50 ms over the run); the
  symbolised samples were SwiftUI's own graph (`AG::Graph`, body re-evaluations of MainView,
  WatchPanel, WatchWindow per drag event) and, as the app's own hottest frame,
  `Watcher.viewerMeasured` — every drag frame wrote the pose's view size to UserDefaults and
  re-armed auto-fit. Now `viewerMeasured` skips the drag (`resizingHere`) and the still comes
  through `VideoDecoder.image` (VideoToolbox) instead of a `CIContext` render + `preparingForDisplay`
  on the main thread: 30–63 ms busy per 100 ms through the drag, no bucket over 63 (5 ≥ 50 ms over
  the run, two of them the launch). What's left is SwiftUI laying the frame out per event; a
  device in Release is the real number. *The mask*: 108–197 ms per read on real windows
  (off the main thread), 1187–2190 bytes; a Debug copy watching a still window 30 s: 3.2% → 4.0% CPU
  (the one read; noisy ±2).
- **Tests:** `swift test` (352, `WindowMaskTests` 6, `LiveShapeTests` new); `ResizableWindowUITests`
  (2 — the slow drag counts live shapes then one final; `TEST_RUNNER_MACROPHONE_SEND_TO=<app>` picks
  another window), `FullScreenUITests` (3), `WatchHeaderUITests` (2 — the question test against a
  plain `serve --rounded`, no `--reshape`/`--busy`), `InputCarouselUITests` (4), `StabilityUITests`,
  `DesktopWindowUITests`, `HardwareKeyboardUITests` (2) pass on an iPhone 17 Pro.
- **Seen frame by frame** (10 fps sheets in `docs/screens/window-illusion-nov9/after/`): the Pro,
  the Duo flat upright, the laptop, on its side, the book and the cover — full screen in is one
  flight from the window's picture to the picture fitted in the screen, the reshaped frame a single
  cross-fade in place (one frame at 10 fps shows both), out the same into the window's frame; a
  window in hand through tabletop → flat upright → on its side → tabletop; the laptop's trackpad,
  keyboard (its foot gives way as designed), a flip and back, the mic opening. The real pipeline on
  the cover (`real/cover-fs/`): the same three steps on a TextEdit document, 48 px corners from the Mac.
- **Hooks:** `TEST_RUNNER_MACROPHONE_SEND_TO`; serve `--rounded-black`, `--no-live-shape`,
  `--reshape-delay`; `mpctl alpha-bench [--frames N]`; Mac DEBUG `MACROPHONE_MASK_DUMP=<dir>` (the
  captured frame and its alpha runs). Log lines: "viewer: picture W×H → W×H in W×H — the old one held
  as a still", "watch: a frame at W×H arrived N ms after the shape went", "watching: N shapes went
  during the resize (N s)", "watching: a cornerless read at W×H — keeping N px".
- **Seen and left / needs his phone and Mac:** the first open on a pose with no remembered view size
  still arrives at the Mac's own shape and reshapes ~1 s in (the cover's first open on a fresh sim;
  every later open goes ahead); on the laptop with the keyboard up the window's foot is under the
  keyboard by design (the fix-up pass's rule — not a transition); the real-pipeline drag's second
  size took 817 ms to come back — whether that's TextEdit's reflow or the AX set needs his Mac with a
  finger's event rate; a translucent window (an edge that never reaches alpha 250) falls back to the
  diagonal circle; the window server lists an app's own layer-0 windows as companions during and
  after a reshape ("with 3 companion windows (TextEdit@0 ×3)", "Calculator@0") — the area stays the
  window's, the mask is read off the same filter, but `WatchCompanions` should learn to tell a sheet
  from a sibling document; `pictureCorner` is drawn `.circular` by the shadow, hairline and stills
  (a `.continuous` curve would hug Tahoe's corner closer); the `.scaleAspectFit` kept picture under a
  window whose Mac can't take the shape letterboxes on the wallpaper (the window is the app).
  **A note on the test runs:** three of my recordings against the Debug copy watched his real Claude
  window (the Duo's active Mac had switched to the copy; `TEST_RUNNER_MACROPHONE_SEND_TO` didn't reach
  a `test-without-building` run) — each reshaped it to the phone's shape and put it back
  (`watch window restore`, the 45 s grace); nothing was typed or sent; those recordings were deleted,
  not published.

## The window is the app, round 3 of review (Nov 8 2026) — wins over the three sections below where they differ

A third reviewer walked build 27 (`docs/screens/native-review-r3/`: Pro light/dark/SE/xxxLarge/Reduce
Motion, the Duo in every pose, real touches at 20 fps). Frames: `docs/screens/native-window-nov8/r3/`
(`before/` the reviewer's tiles, `after/` this build's, 10 fps and 20 fps where it mattered). **The
Mac app changed in this round** (`WatchService`, below) — it needs installing.
- **The keyboard that rose into full screen once the keyboard mode had been used** was UIKit's
  own doing: it restores a text view's keyboard by itself — the window's last text input — when the
  responder that took over lets go, and `HardwareKeysView` lets go for the second the layouts swap.
  The log read "taking the keyboard (wants false, page mic, full screen true)" a tenth of a second
  after "full screen on". `KeyboardTextView.canBecomeFirstResponder` (and `becomeFirstResponder`)
  is now `wantsKeyboard && stillWanted()` — the page is the keyboard and not full screen — so no
  restore ever finds it willing. Proven on the laptop (hide → full screen, stay on the keyboard →
  full screen, mic mode → full screen), the cover and flat upright: the log says "refused the
  keyboard" where it used to say "taking", and no keyboard shows.
- **A session that starts again sends the shape again** (`Watcher.start`: the link back, the app
  back on screen — `shapeAhead()` with the watch, else `wantsAutoFit` for the view's measure), so a
  dropped link or a return no longer brings the window back at the Mac's own shape. **The Mac keeps
  a window's sizes through a pause for a grace** (`WatchService.park` / `putBack`, 45 s): every
  stop used to put the window back at once — Done, but also the phone's pause when the app left the
  screen and a link that blipped — and the new watch's record had no `beforeWindowChanges`, so Done
  after a blip never put it back either. Now a stop parks the Aa fit and the frame from before the
  view shaped it; the same window watched again within the grace carries them over; another window,
  the grace running out, or quitting puts it back; the phone's Done still sends `restore` first.
  `mpctl serve` mirrors it (`--restore-grace <s>`, 45; "WATCH WINDOW restored after N s"). The
  status line says nothing while the window's own capsule says "Reconnecting…" (said twice before).
- **Full screen is one grow on every screen**: `Watcher.setFullScreen` reads the flight's start
  before it publishes (`FullScreenZoom.prepare` → `takePrepared`) — by the time the flight was asked
  for, the full-screen viewer was the one on screen on the Duo, so it flew from the screen to the
  screen (a cut); `WindowZoom.viewerPlace` takes a viewer under half the screen's width (the side
  pages: "from nowhere"). Full screen's ground is the Mac's desktop under a dark veil, not black.
- **The way out lands on the page** (`InnerWindowSpot`: the window in hand reports its frame; the
  exit flies to it on the inner screen) and **the deck's mode is restored before the layout
  returns, with no animation** (the mode bar showed Mic sliding to the trackpad as the deck faded in).
- **Show it here keeps the glance's picture** (`ViewerScrollView.adopt`: the holder keeps the
  displayed frame as a real picture; a `snapshotView` of a video layer came out empty).
- **The first open's reshape, found at 60 fps** (`MACROPHONE_FORGET_WINDOWS=1` gives the first
  open's state — no remembered shape, no kept picture — with the pairing kept): the keyframe at
  the new size carries new parameter sets, and `VideoCanvas.apply` flushed the layer and removed the
  picture at once, then drew the new frame in the old canvas — the bare pane with a small copy of
  the picture in it — and the viewer's still of "the old picture" was made of that new frame,
  stretched into the old rect (the double exposure of two layouts). Now a new size with a picture
  up **holds the new frame** (`VideoCanvas.holding` / `release`): the old frame stays on the layer,
  the viewer lays out for the new size and makes its still of the old frame, then lets the new one
  through under it (`ViewerScrollView.update` → `video?.release()`; by itself after 0.5 s if no
  viewer does). The log says "viewer: picture 1400×900 → 596×900 … the old one held as a still".
- **A thawed viewer lays out before it draws** (`WindowViewer`: `frozen` → not frozen runs
  `layoutIfNeeded`), so no frame shows the picture small in a corner at a full-screen landing.
- **The Whole Screen has Full Screen** (`WatchHeaderBar.row`: its button never folds for the
  desktop; the zoom-out cell is what its row gives up at the last stages, so "Whole Screen" reads
  whole), and the status line no longer says it "isn't open" (`AppModel.isNotOpen`).
- **Reduce Motion**: leaving full screen fades the full-screen view out under the window fading in
  (gone at once, a frame showed the window at half opacity over the wallpaper).
- **Seen frame by frame on this build** (an iPhone 17 Pro and a Duo against `mpctl serve --rounded
  --reshape --restore-grace 6`; `after/`): the keyboard — five paths (laptop: hide → full screen,
  stay on the keyboard → full screen, mic mode → full screen; the cover; flat upright) — "refused
  the keyboard" 50 ms after "full screen on" every time, no keyboard in any frame (before: the
  field took it with "wants false" and the keyboard rose ~1 s); the stand-in stopped mid-watch and
  started 6 s later → `WATCH SHAPE 0.66 · RESHAPED (ahead)` with the new watch, the window back at
  the view's shape from its first frame, the capsule alone saying Reconnecting; home for 9 s →
  "restored after 6 s" at the stand-in, back → the shape ahead again, no reshape seen; full screen
  flies "(prepared)" on the Pro (382×576), the laptop (645×434), the cover (362×254), the side page
  (438×475) and the book (before: the side pages "from nowhere", a cut), 0.42 s each way; the way
  out lands on the page in one step (side: 25.0 → 25.1 s; before: a near-full-screen frame then
  the page); Show it here keeps the glance's picture through its 0.2 s fade; the Whole Screen's
  header reads "Whole Screen · Full Screen · Sound | Mac Controls · Done"; the first open with
  nothing remembered: 1400×900 at 1.5× fit from the corner, the view's shape 0.5 s later, the
  reshaped frame 0.65 s in under a still of the old picture that fades in 0.18 s — no pane, no
  thumbnail (60 fps); Reduce Motion's way out is one cross-fade frame, no wash.
- **Left:** the reshape's 0.18 s is a dissolve of two layouts (a reflow can't be animated); the
  window's frame grows from the letterboxed old rect to the room as the new picture lands (the
  still keeps the old rect); the Whole Screen gives up its zoom-out cell on a Pro-width row.
- Hooks: `MACROPHONE_WATCH_ACTIONS=…,hidekeyboard`, `MACROPHONE_FORGET_WINDOWS=1`; DEBUG log
  lines "full screen flight in/out: from …", "viewer: picture W×H → W×H … held as a still / no
  still", "viewer: reset to zoom …", "keyboard field: refused the keyboard".

## The window is the app, round 2 of review (Nov 8 2026) — wins over the two sections below where they differ

A second reviewer walked build 26 at 20 fps (`docs/screens/native-review-r2/`); two round-1 fixes
hadn't held. Frames: `docs/screens/native-window-nov8/r2/` (`before/` the reviewer's tiles,
`after/` 10 fps tiles on this build).
- **The keyboard that popped entering full screen on the Duo — two ways in, both shut.** The
  reviewer's frames show the keyboard *page's* field (its Mac bar over the keys) rising from the
  mic mode a moment after the full-screen picture settled: `KeyboardTextView` now asks again the
  moment it would take the keyboard (`stillWanted`: the page is the keyboard and not full screen —
  there is no keyboard page in full screen), not what the last SwiftUI update said. On a
  simulator with the hardware keyboard attached the other way showed: `HardwareKeysView`'s claim
  a second into full screen (and the moment the mic mode came on the laptop) raised a keyboard
  for *it* — it was a `UIKeyInput`, and iOS raises a keyboard for any key input that becomes
  first responder: with no input view (or a zero-sized one) the system keys (the simulator draws
  them though GCKeyboard says a keyboard is attached); with a 1 pt input view, nothing on the
  cover or flat upright but on the folded laptop the keyboard's backdrop over the whole lower
  half (iOS docks the keyboard's window to the half under the hinge whatever is in it: a white
  sheet over the deck — and so it did for a plain responder that still vended the 1 pt view:
  iOS raises the keyboard's window for any first responder with an input view of its own).
  **It is a plain responder with no input view now** — every press arrives in `pressesBegan`
  either way, so a real keyboard still types; the key-input conformance and the 1 pt view live on
  `HardwareKeysTypingView`, made only under `MACROPHONE_UITEST_KEYS=1` (DEBUG) for XCUITest,
  whose `typeText` reaches nothing but a key input (`HardwareKeyboardUITests` sets it). A DEBUG
  line in `KeyboardTextView.becomeFirstResponder` names the page and full screen whenever the
  field takes the keyboard. Recorded on the laptop, the cover and flat upright (the window opens
  with the simulator's keyboard attached, mic mode → full screen → out): no keyboard, no sheet.
  Round 1's one-second wait stays.
- **The window frozen after full screen on the inner screen: not reproduced** on this build
  (flat upright and the laptop, typing after the exit changed the picture; the side pose
  recorded too). The likeliest mechanism is covered anyway: when the canvas changes viewers
  (`ViewerScrollView.onCanvasAdopted` → `Watcher.canvasMoved`) the renderer a move may have
  failed is reset and a keyframe asked for, so the next frame stands on its own.
- **A size change holds the old picture as a still** (`ViewerScrollView.makeStill` / `hold` /
  `thaw`) **[amended Nov 9 2026: the canvas is hidden under the still until the new-size frame
  displays, the still is aspect-fit, 0.15 s — "The window illusion"]**: the displayed frame (or
  the picture), clipped to what showed, with the window's corners, pinned in the host over the
  viewer while the canvas takes the new size under it. Before: `UIView.transition`'s cross-dissolve
  snapshotted the image view but not the video layer, which was resized to the new canvas and
  aspect-fitted its old frame — a black band and a shifted copy on entry, a thumbnail on exit.
- **[gone Nov 9 2026 — a picture is fitted whole, never covered; `otherShape`, `coverScale`,
  `coverCap` are deleted]** ~~A picture of another shape covers its view from the top-left~~.
- **The shape ahead from memory** (`Watcher.viewSizeKey`): the view's size is kept per pose and
  fill, so the first open after a launch — the card, the Dock, a widget, an alert — sends the
  shape before the first picture ("opens at the view's shape … remembered from last time"); it
  came in at the Mac's own shape and jumped 1.3 s later.
- **The viewer holds while hidden or fading** (`WindowViewer(frozen:)` = `watchWindowHidden`):
  the room collapsing under the panel as the words took it re-fitted a zoomed window to a small
  whole picture for a frame.
- **A flip to a window with no kept picture keeps the last picture, dimmed** (`stale` again,
  only then), frame and key row in place; the flip's chip over the window is gone (it sat on the
  Mac window's own title; the header's name and VoiceOver say it).
- **The deck's mode comes back after full screen** (`pageBeforeFullScreen`: the trackpad).
- **Flat upright gives the Mac the laptop's half** (`laptopBody`: in hand the deck is the rest
  of the screen under `h.mac.height`, never less than the keyboard needs) — Sameer's call on
  round 1's item 14: the window's shape is the same folded or flat, so a fold between them
  reshapes nothing; the keyboard rule from the fix-up pass holds (the window stays whole).
- **Seen frame by frame on this build** (10 fps tiles, 20 fps where it mattered; an iPhone 17
  Pro and a Duo against `mpctl serve --rounded --reshape`): the flip to Messages with no kept
  picture keeps Claude's picture dimmed for 0.2 s, frame and key row where they were, and no chip;
  full screen on the Pro is one grow (0.42 s), the reshaped picture 1.0 s later as a 0.1–0.2 s
  dissolve in place, and the way out lands the window's outline in one step with the reshaped
  picture 1.0 s after; the card's open after a relaunch logs "remembered from last time" and the
  picture is at the view's shape from its first frame; the mic's touch dims the window at its own
  zoom (no small whole picture for a frame); the arc's double tap grows width and height together
  over ~0.3 s; on its side full screen covers from the top-left at 1.3× (the reshaped landscape
  picture 0.75 s later), lands back in one step, and the picture goes on updating after the exit
  ("typed 30" → "typed 40": the frozen window wasn't reproduced on the side pose either); a fold
  between the laptop and flat upright with a window in hand sends no `WATCH SHAPE`.
- **Left:** the keyboard page's room timing and the square cut as the window grows back after
  hide (the clip's corner isn't animated with the frame), the 2-frame ghosts at the Dock open
  and Done's hand-over — noted, not changed. The reshape's 0.1–0.2 s dissolve still shows both
  layouts over each other for those frames (a reflow can't be animated); the demo window
  letterboxes where it can't reshape, as before.

## The window is the app, refined (Nov 8 2026, round 1 of review) — wins over the section below where they differ

A fresh reviewer walked build 25 frame by frame (`docs/screens/native-review-r1/`); what broke the
illusion and what was rough, fixed in this order. Frames: `docs/screens/native-window-nov8/r1/`
(`before/` the reviewer's tiles, `after/` 10 fps tiles of the same transitions on this build).
- **Full screen is one continuous grow** (`FullScreenZoom`, WindowZoom.swift; `MainView
  .fullScreenFlight`): the window's picture flies from the window's frame to the screen (covering
  it from its top-left, as a Mac window's content sits while it zooms) and back (landing whole in
  the frame), 0.42 s on the settle spring, over everything; the two layouts swap under it —
  `DuoFullScreen` arrives under the picture and is removed at once on the way out (no fade of its
  own to double under the shrinking picture), the windowed viewer waits hidden until the flight
  lands (`FullScreenZoom.landing`), the status bar and home indicator stay hidden through the
  flight. The full-screen viewer starts the old picture where the flight ends (cover, top-left:
  `fitsOtherShapes: false`), the windowed viewer opens the full-screen-shaped picture whole, and
  the Mac's reshaped picture is the one 0.22 s dissolve left, in place. Before: a cross-fade of two
  viewers at two zooms with a cropped state between, ~1 s each way, then a second dissolve.
- **[superseded Nov 9 2026: every picture opens fitted whole, everywhere — `fitsOtherShapes` is
  gone; the strip alone is `ViewerScrollView.Mode.foot`]** ~~A picture shaped unlike the view
  opens whole — live too~~.
- **A dictation keeps the watch** (`Watcher.samePlace`, `follow`, `open`): a landing's
  `follow(target)` compared refs by `==`, and the dictation's name carried the window's title
  where the watch had the app's — every landing was a switch: `WATCH WINDOW restore` → a new
  `WATCH TARGET` + `WATCH SHAPE`, the Mac window jumping twice and the phone growing it out of the
  card again. Same app and window (a window-less ref is the showing window) is the same place.
  The words take a window in place (`windowViaDock` off when the words come, whatever started
  them — a hook, Siri, a Shortcut), the header stays through the fade (`bare` waits for
  `panelDormant`), the strip's top fades in over 52 pt. Serve after a landing now: `LANDED` and
  nothing else.
- **The glance's picture after Done** (`ViewerScrollView.adopt(force:)`, `leaving`, the orphan
  check in `layoutSubviews`): the "never steal from a live viewer" rule had the glance refuse the
  canvas from the window in hand at the very moment it was handing it over — the hand-over is
  forced, and a canvas whose holder left the window is taken on the next layout.
- **The corner drag** **[amended Nov 9 2026: the picture is re-fitted in the frame each pass, his
  zoom ratio over fit kept, the top-left kept only when zoomed in; the Mac takes live shapes
  through the drag]** (`keepZoomResizing`). The frame still shrinks round the middle.
- **A flip shows the next window's kept picture at once** (`open`: the old picture goes, `stale`
  is never set) with "Opening …" only in the name; the box with a spinner appears only with no
  picture of any kind. **The shape goes ahead on a flip too** (`shapeAhead` on a switch) — the
  Nov 7 "never reshape a window flipped past" rule gives way: the Mac puts each back as the view
  leaves it, so a pass-through costs the Mac a reshape and a restore and the phone nothing
  (serve on a flip: `WATCH SHAPE 0.66 · RESHAPED 596×900 (ahead)`, no wide first frame).
- **A room still settling re-sends its shape** (`viewerMeasured`, `shapeSentAt`): a measure more
  than a tenth off the shape sent within 3 s re-arms auto-fit (the side page's half-height first
  measure made the Mac window 2:1 until a full-screen round trip).
- **Zoomed or scrolled, the window keeps its rounded corners** (`roundView`: the scroll view
  itself is clipped at `pictureCorner × zoom`, all four corners; the shadow and hairline follow);
  **Newest is the Window menu's first item** ("Scroll to Newest"), nothing over the window.
- **The floating trio starts lower** (y 0.72: under the laptop's fold, above a chat's Send) and
  **dims to 45% after 3 s untouched**; any touch of it, or the mic opening, brings it back — the
  way out stays visible, as Sameer asked, but quiet.
- **The desktop card keeps a window-shaped picture**: `keepPicture` skips full screen and any
  picture more than 15% off the view's shape (the card had a 0.46-aspect sliver after full screen).
- **No keyboard pops on the Duo entering full screen**: `HardwareKeysView` never claims first
  responder for a second after `fullScreen` changes (with the simulator's hardware keyboard
  connected it did, and the keyboard rose over the screen).
- **Stand-in:** `serve --reshape` waits 250 ms before a watch's first frame so the shape ahead
  applies before it, as the Mac app does (`RESHAPED … (ahead)`).
- **Left as found (judged, not fixed):** the keyboard page's room still moves on
  `keyboardWillChangeFrame`'s spring and can lead the keys by a frame or two on the simulator
  (no safe blind change; measure on a device); folding laptop ↔ flat upright in hand still
  reshapes the Mac window (flat upright's 372 pt deck vs the half — making them equal is a layout
  decision for Sameer); flat upright with the keyboard up, the keyboard bar's hide is the way out
  (accepted); the Mac's reshaped picture still lands as a 0.22 s dissolve (the reviewer accepted it
  on its own).
- **Tests:** `ResizableWindowUITests` (2), `FullScreenUITests` (3 on the Pro; the any-screen test
  on the Duo flat upright and on its side), `WatchHeaderUITests` (2, against serve without
  `--reshape`: with it the demo wraps "se ssion" and Vision reads the break — the stand-in),
  `InputCarouselUITests` (4), `StabilityUITests`, `DesktopWindowUITests`.

## The window is the app (Nov 8 2026, the second pass) — wins over "The Mac's window, on your iPhone" where they differ

Sameer, on build 24: "the resize arrow in the corner kinda moves first and the window catches up
later", "the corners of the window still show some black", and the bar for every decision: "This
app lets you run any app on your Mac on your iPhone. And it should feel that way" — the window is
the app, with its own corners and nothing that reads as a feed. Then: "I should be able to launch
full screen takeover of any app in both landscape and portrait in the inner screen … on [the] outer
screen too." Frames: `docs/screens/native-window-nov8/` (`before/` build 24, `after/`; the drag
frame by frame in `slow-drag-frames-*.txt`).
- **The window's own corners, nothing black** (`ViewerScrollView`, "The window's own corners")
  **[Nov 9 2026: the Mac sends the real corners as a mask — `WatchWindowMask`; what follows is the
  fallback for a Mac from before]**: a
  Mac window's rounded corners arrive black (a single-window capture's transparent corners have no
  alpha once they're HEVC or JPEG). The radius is **read off the picture itself** — the two top
  corners' diagonals, counting near-black pixels from the corner (a circle's arc meets the diagonal
  r·(1 − 1/√2) in; the title bar behind is never black, and a Terminal's black page is below it;
  both sides must agree, a run to 40 px is a black window, not a corner) — from the video's
  displayed frame (`displayedPixelBuffer`, luma plane) or the kept / JPEG picture (its top strip
  drawn into a grey bitmap), once per picture, again a moment later until the pixels are there
  (8 tries, 0.35 s apart), and the canvas is clipped to it (`canvas.layer.cornerRadius` in picture
  pixels, so it scales with the zoom; circular, which sits inside the capture's own arc). The
  Whole Screen reads none (`readsCorners`). Log: "viewer: the window's corners read 53 px round
  (594×900, video)". **Nothing from the Mac**: the installed Mac app from before draws the same.
  `mpctl serve --rounded` draws the demo with a Tahoe window's 52 px corners and black outside
  them (it read as 53–55).
- **The shadow and the hairline round with the window** (`ViewerHost`): both paths rounded at the
  corners that are the window's own on screen (`shownPictureEdge`: the picture's corner, not the
  view's edge cutting it), square elsewhere; the hairline is a `CAShapeLayer` stroke now (0.5 pt,
  0.14 dark / 0.18 light); both set in one `CATransaction` with actions off, in the same layout
  pass as the picture. The Dock/card flight's corner at the viewer end is the window's own
  (`WindowZoom.viewerPlace`: `pictureCorner × zoomScale`), the card's 12 pt opening into it.
- **The resize follows the finger** (`ResizableWindow`, `ViewerScrollView.resizing`)
  **[amended Nov 9 2026: the picture is fitted in the frame each pass, the arc on the fitted
  picture's corner, shapes stream to the Mac through the drag (`watchShapeLive`, applied with no
  hold) and the release fits at once — `resizeSettle` is gone; see "The window illusion"]**. At
  rest the arc sits at **the picture's own corner** (`WindowPictureKey` from the viewer's
  `onPictureShown`), so a window smaller than its frame wears the arc on itself, not on the frame.
  `mpctl serve --reshape` makes the demo take the shape (`WATCH RESHAPED 596×900`) and go back on `restore`.
- **Full screen on every screen** (`Watcher.allowsFullScreen` is true for every pose;
  `MainView.inFullScreen` drops the pose check; `DuoFullScreen` as it was — the floating mic trio,
  the hold-for-trackpad, edge to edge, no status bar or home indicator): upright inside (flat
  portrait, the laptop) and on the cover and every other iPhone, for any window and the Whole
  Screen. **Where it's reached:** beside the window's name wherever the header holds the window's
  buttons (`WatchHeaderBar.fullScreenButton` — the regular iPhone's panel, the laptop's / flat
  upright's deck header), and **the vertical bar's item** where the bar holds them (the cover, the
  inner screen on its side: `BarTier.fullScreen`, after `.window` — it folds into ⋯ before Sound
  does; the cover's column takes all nine at rest) — one id, `watch-fullscreen`, never both. In the
  header the row gives way in order — dots, "Paused", zoom out into the Window menu, **Sound into
  it** (a "Hear Your Mac" toggle; off by default, set once), then Full Screen into it
  (`Fit.soundInMenu`, `.fullScreenInMenu`) — before the app's name shrinks: with Full Screen
  beside the name a Pro's row (Terminal · Sound | Mac Controls · zoom out | Window · Done) was one
  cell too many, so on a Pro Sound is the menu's and Full Screen stays a cell
  (`WatchHeaderUITests.testTheNameReadsWhole` had "Terminal" at 62 pt). On the inner screen on its side the status bar is
  the vertical bar: hidden for full screen, iOS 27.1 left the root 84 pt short of the camera's
  edge with a white band there — `StatusBarRoomFix` now pulls the root out sideways too, only
  while the app hides the status bar (`StatusBarHiddenKey` from MainView). The
  window takes the screen's shape in and out (`poseSettled` as before; `shrunkHere` cleared and
  `ResizableWindow`'s share reset on `watcher.fullScreen`, so a window he shrank is all the room
  again on either side). The floating mic is `floatingMicButton` (no matched geometry: the layout's
  own mic stays built under full screen on the phone and the cover, and two sources of one matched
  id put the floating one at the hidden one's place). A fold while in full screen stays in full
  screen (the layout is pose-agnostic) and re-shapes the window. In full screen the window's
  clipped corners sit inside the display's own 55 pt corner — the screen's corners are the app's.
  **The phone's kept panel sleeps under full screen** (`dormant` with `innerAsleep`, and
  `watchWindowHidden` while `inFullScreen`): live, its viewer and the screen's took the one video
  canvas from each other on every update — the first phone full screen showed the picture zoomed
  with a black band beside it. Two rules in `ViewerScrollView.adopt` back it: a viewer that isn't
  live never takes the canvas from a live one on screen, and one leaving the window with it hands
  it to any other that wants it (`wanting`), not only the "newest".
- **[superseded Nov 9 2026: every picture, kept or live, opens fitted whole — `keptOtherShape`
  is gone]** ~~A kept picture shaped unlike the view opens whole~~.
- **Tests:** `ResizableWindowUITests` (the drag, the next open full, the double tap;
  `testASlowDragForTheRecording` drives the measured drag: one `WATCH SHAPE`, sent on release),
  `FullScreenUITests.testFullScreenFromTheWindowOnThisScreen` (any screen: the button or bar item →
  the window the screen's frame, the trio, no Done; exit → all the room again; run on the Pro and
  on a Duo pose with `TEST_RUNNER_MACROPHONE_DUO_REAL=<pose>` for the log).
- **Needs a real Mac and phone:** the corner read on real windows (Tahoe's radius at 2×; a dark
  translucent title bar reading near black — it falls back to square, never a wrong clip; a window
  that goes full screen on the Mac → square); the reshaped picture's arrival time after a release
  on a real Mac (the stand-in's 0.5 s stands in for the pipe's 0.3–0.9 s hold); full screen under
  the Dynamic Island (the title bar runs under it, as a game's does — by design); the cover's bar
  with nine items on a real cover.

## The Mac's window, on your iPhone (Nov 8 2026) — wins over every bezel described below

Sameer: "remove the borders of a window … less like there is a view window that is [showing] an
app or display and more that that window is just viewable on my iPhone and ready to interact
with", then "when an app is opened … [its] window is resized on the Mac to be as big as possible on
the current iPhone display. But the user should have the ability to resize the window as they want
to", and "still be able to zoom in to parts of the window". Frames: `docs/screens/borderless-nov8/`.
- **No bezel anywhere** (`WatchLook.bezelWidth` 0, `screen` 0, `DuoLook.halfBezel` 0): no raised
  plate, no specular rim, no recess line, no state-coloured glow, no cyan ring on coming alive or on
  each key (`cameAlive` keeps its haptic; the key's own press and the click's ring answer input). No
  grey plate under the picture either: round a window smaller than its room is **the Mac's
  wallpaper**; a pane of `.ultraThinMaterial` only while there's no picture at all. `WatchWindow` no
  longer clips (the viewer clips its own picture).
- **A window's shadow and hairline** (`ViewerHost`, WatchPanel.swift — `WindowViewer` returns it,
  the `ViewerScrollView` inside): macOS's soft shadow under, a 0.5 pt edge over (dark in light, light
  in dark), both round *what of the picture shows* (`ViewerScrollView.shownPicture`, moved on every
  zoom / scroll / layout via `onPictureMoved`, the shadow path animated with the viewer's own
  animations). Only where the window floats (`floats: !fill`): a folded Duo half fills edge to edge
  and has none. Off under Reduce Transparency.
- **The header names the app with its icon** (`WatchKicker(icon:)`, from `liveTargets`), not the
  breathing "live" dot; faded while not live; the dot stays for an ochre problem and when no icon came.
- **Every window opens as big as the room** (auto-fit, as before) **and resizes from its corner**
  (`UI/ResizableWindow.swift`): Stage Manager's arc 5 pt outside the bottom-right corner
  (`watch-resize`; touch 20 pt in, 14 pt out); the width round the middle, the height from the top,
  at least 50% × 35% of the room, snapping (a tick) to all of it within 14 pt. While the finger is on
  it the viewer keeps its zoom (`\.watchResizing` → `ViewerScrollView.resizing`); on release
  `Watcher.resizedHere` gives the Mac's window that shape (as auto-fit does: it goes back on Done)
  and the picture settles to fit. Double tap = all the room. **A size lasts while the window is open,
  never into the next open** (`shrunkHere`: the view's measure while shrunk isn't the room's, so the
  next open is shaped to the whole room). Off for the Whole Screen and a bare / hidden panel. The
  window-switching edge strips stop 110 pt short of the foot (the corner). VoiceOver: adjustable,
  "Use all the space". Pinch to zoom is untouched at any size.
- Tests: `ResizableWindowUITests` (drag 382×576 → 262×396, top and middle kept, `WATCH SHAPE` sent;
  the next open full; a double tap full), and `WatchHeaderUITests`, `InputCarouselUITests`,
  `StabilityUITests`, `DesktopWindowUITests` pass (serve restarted between runs: the question test
  needs Terminal's question unanswered).
- **Needs a real Mac and phone:** a real window reshaping to a resized frame (the stand-in's demo
  window can't, so it letterboxes inside the frame and the arc sits off the picture); the shadow's
  cost over live video in Release; a window with a minimum size the shape can't reach.

## Macrophone as Apple would make it (Nov 1 2026) — wins over every look described below

Sameer: "feel like a native apple app … designed by apple … light and dark mode … borrow elements
from macOS … imagine if apple build a Mac controller for the iPhone and iPhone Duo … the main
focus should still be the mic." The plan and the token map are `docs/DESIGN.md`'s top section.
- **Light and dark.** `Theme.swift` keeps the old names but they are Apple's own colours now:
  `Ink.ground` systemGroupedBackground, `Ink.raised` secondarySystemGroupedBackground, `Ink.ink`
  label, `Ink.secondary` secondaryLabel, `Ink.tertiary` a grey that reads over a wallpaper,
  `Ink.line` separator, `Ink.onTint` white (a glyph on a filled accent — never `Ink.ground`
  there); `Light.cyan` systemBlue (the accent), teal/mint/gold/ember/violet/rose the system
  teal/green/yellow/orange/purple/red, `Light.ochre` yellow in dark and amber in light.
  `Font.serif` / `Font.mono` are SF Pro (mono = monospaced digits); `Kicker` is sentence case. No
  uppercase tracked labels anywhere. The forced dark mode is gone (no `UIUserInterfaceStyle`, no
  `preferredColorScheme(.dark)`); `Settings.appearance` (Automatic · Light · Dark) is applied in
  `RootView` and on every sheet. `xcrun simctl ui <udid> appearance light|dark` flips the simulator.
- **The phone at rest is a little Mac desktop** (`UI/MacOS/Desktop.swift`, `PhoneDesktop`): the
  **menu bar** (`PhoneMenuBar`: `MacPill(menuBar: true)` — the bold name, same tap and swipe — and
  menu extras: Whole Screen `display`, Control Center `switch.2`, History `clock`, Settings
  `gearshape`), the **last dictation as a desktop widget** (`LastDictationWidget`: Copy · Send
  Again · History), then in thumb reach **the Dock's options** (`DockOptions`: Send after pasting
  as a real switch, Cleanup's menu, ⋯ = Refresh + the share items **[superseded Nov 7 2026, round 2: `SendToggle` · Cleanup · the paperclip `AttachMenu`; Refresh is in Open an App]**) and **the Dock** (`SendToDock`,
  `UI/MacOS/Dock.swift`: the open apps with running dots, a divider, Clipboard and Where I'm
  typing, + = Open an App; the pick lifted with its name over it — `send-to`; tapped again =
  Watch, the eye badge **[superseded Nov 7 2026, round 4: no eye on the pick; the second tap still watches]**; a long press = its windows; a finger scrubbing along it magnifies and
  picks on lift; the shelf hugs the icons and never runs past the screen — past that they scroll
  inside it). The Thread and the mic are where they always were. Unpaired, the old panel stays.
  The Duo's cover and inner screen keep the tiles (`QuickControls(layout: .tiles)`).
- **The wallpaper** behind everything is the Mac's own (`DesktopBackground` ← `WallpaperStore`,
  merged the same day: the Mac sends its desktop picture, feature `wallpaper`), under a veil of the
  appearance's ground; before it arrives, a Tahoe-like mesh (`DesktopWallpaper`). The state's light
  washes in from the foot (orange listening, green landed; nothing at rest).
- **The mic is Siri's cousin:** a white glass disc in light, dark glass in dark; Apple
  Intelligence's colours (`MacOSLook.intelligence`) on its ring, on the Thread (`RGB.thread`), and
  round the screen's edge while it listens (`ListeningEdge` → `EdgeGlow`, 30 fps only while open).
- **Mac Controls is the Mac's Control Center** (`MacControlCenter`, `UI/MacOS/ControlCenter.swift`):
  Hear Your Mac while a window shows, Sound (mute + a slider that sends a volume key per sixteenth
  crossed, its ends `mac-control-volumeDown` / `-volumeUp`), Display, Now Playing. Same ids.
- **Input surfaces:** the trackpad is a Force Touch trackpad's glass (`ForceTouchSurface`), the
  laptop deck's keys are Magic Keyboard keys (`MagicKeyboard` colours in `KeycapStyle`); the iOS
  keyboard follows the appearance.
- Unused so far, kept for the Duo and the window: `MacWindowFrame` / `TrafficLights`
  (`WindowChrome.swift` — not on the watched window: the stream already carries the Mac's own
  title bar and traffic lights, and taps on them click on the Mac), `MagicKey`, `MacMenuBar` for
  other bars.
- **Settings, History, setup and the sheets, as Apple's own.** Settings is a native inset-grouped
  Form on the system's backgrounds: the active Mac is the banner at the top (`MacBanner`: its glyph
  on a blue disc — `MacGlyph` picks laptop / iMac / mini / Studio / Pro from the name — the name,
  its standing and the route's glyph, `RouteGlyph`); a tap opens the Mac's page
  (`MacConnectionView`: Connected now, Tailscale on this iPhone, the address, and Away from home
  with its steps — moved off the main list **[superseded Nov 7 2026: Connected now and one Away from
  Home row; the rest is in the guide — see "Setup on the iPhone, and Tailscale guided"]**). Every row leads with a Settings icon (`SettingsIcon`,
  `UI/Settings/SettingsLook.swift`; `PlaceIcon` for a place), explanations sit in section footers,
  switches are green (`.toggleStyle(.settings)`), Cleanup comes right after Send to, and
  Appearance (Automatic · Light · Dark) is bound to `settings.appearance`. History is Mail: 
  `.searchable`, the days as sections, a row = the place's icon, the app's name (the window's
  title under it, as Mail's subject — never wrapped beside the time), paper plane if sent, status
  glyph (`HistoryMark`), time and two lines (`PreviewLines` — clipped under a fade, never "…"),
  stacked at accessibility sizes; swipe right Send Again, left Delete / Copy; a tap opens
  `HistoryPage` (Cleaned | Raw in the title, Delete · Copy · Send Again in the bottom bar).
  Onboarding and every pairing phase are Setup Assistant pages (`UI/Onboarding/SetupPage.swift`:
  `SetupPage`, `SetupSymbol`, `SetupButton` pinned at the foot via `safeAreaBar`,
  `setupSecondary`); the last step glows the screen's edge while it listens. Your Macs, Open an
  App (open apps, then Applications), Send to, Custom Cleanup, Dictionary, Language and
  Diagnostics are native lists with no background overrides. "Resend" is "Send Again"
  everywhere. New ids: `settings-mac`, `appearance`, `history-version`. Onboarding is an
  accessibility modal (`.isModal` in `RootView`), so VoiceOver and the audit skip the faded main
  view under it — `accessibilityHidden(false)` there made two blank full-screen nodes. Frames:
  `docs/screens/redesign-nov1/part2/` (before light | after light | before dark | after dark).

## The Mac app as Apple would make it (Nov 7 2026) — wins over every older Mac look below

Sameer: "The Mac app's own redesign … make it look like macOS Settings in light and dark, with
glass in the sidebar. It's the app people see first." The iPhone's Nov 1 redesign, translated to
the Mac. Frames: `docs/screens/mac-redesign-nov7/` (`before/` — dark only, the old window forced
it —, `after/` light and dark, `sheet-*.png`). Shot with quiet windows, so every window is drawn
inactive (grey switches and toolbar); key, they wear the accent.
- **Light and dark, following the system** — no more forced dark (`NSApp.appearance` was
  `darkAqua`, the window `darkAqua` + `Ink.groundNS`, the views `.preferredColorScheme(.dark)`).
  **General › Appearance** (Automatic · Light · Dark, `settings.appearance`, `AppAppearance`
  in `UI/Components/MacLook.swift`) sets `NSApp.appearance` (nil = the system's), live, for every
  window — the setup too (it inherits; `SystemAppearance` is gone). The popup stays a dark HUD
  (`PopupController`, `VisualEffect`); the listening pill follows the system as before.
  `MACROPHONE_APPEARANCE=light|dark` (DEBUG) now forces every window.
- **The token map** (`UI/Components/Theme.swift` — the old names, Apple's colours, as the phone
  did): `Ink.ground` windowBackgroundColor, `Ink.raised` controlBackgroundColor, `Ink.sunk`
  textBackgroundColor, `Ink.ink` labelColor, `Ink.secondary` secondaryLabelColor, `Ink.tertiary`
  45% label (secondaryLabel under Increase Contrast), `Ink.line` separatorColor, `Ink.lineStrong`
  gridColor, `Ink.focus` keyboardFocusIndicatorColor; `Light.cyan` = **the accent**
  (`Color.accentColor`; the AccentColor asset is Apple's blue #007AFF / #0A84FF now — it was teal),
  teal/mint/gold/ember/violet/rose = systemTeal/Green/Yellow/Orange/Purple/Red, `Light.ochre` yellow
  in dark and amber in light; `Light.spectrum` = Apple Intelligence's four (the landing glow's).
  `Typeface.serif` is SF Pro (the New York serif is retired), `Typeface.mono` SF Mono for code,
  `Typeface.digits` monospaced digits; `Kicker` sentence case, semibold, secondary — no uppercase
  tracked labels anywhere. `PillButtonStyle` is a `PrimitiveButtonStyle` that draws the system's
  own buttons (`filled` = bordered prominent, else bordered, a rose tint = destructive). Radii:
  plates 10, controls 6. The menu's `MenuTone.connected` is the accent.
- **The window** (`UI/Window/MainWindow.swift`): `NavigationSplitView`, the system's sidebar
  (`.listStyle(.sidebar)` — Liquid Glass on macOS 26) and a unified toolbar
  (`NSHostingController.sceneBridgingOptions = [.toolbars, .title]`, `sizingOptions = []`: the
  pane's name is the window's title). **The sidebar** is System Settings': at its top **the
  connected iPhone as the account card** (`PhoneCard`: a round phone glyph, blue with a green dot
  while connected; its name; "Connected · last received 2 min ago" / "Not connected" / "Pair your
  iPhone"; a click opens Devices — it replaces the serif "Macrophone" header and the status box at
  the foot), then each pane with **a coloured icon tile** (`SettingsIcon`: History indigo,
  Dictation orange, Agents purple, Devices blue, Developer graphite, General grey). ⌘1–6 kept. The
  sidebar's width comes from its content (`.frame(minWidth: 220)` — `navigationSplitViewColumnWidth`
  alone left it at 144 pt on macOS 27) and it holds the keyboard on opening (`defaultFocus`).
- **Send to is in the toolbar** (`SendToToolbar`, `UI/Components/SendTo.swift`; the heavy
  `SendToCard` above every pane is gone): the pick's own icon and **"Send to Claude ⌄"** as a menu —
  every place (`SendToPicker`, a check on the current) and Send after pasting — beside **a paper
  plane** that turns Send after pasting on (filled) and off, disabled where the pick can't send.
  What will happen ("Pasted into Claude's message box after a 2.5-second countdown…") is the help.
- **Notices above the pane** (`PaneNotices`, `PaneBanner`): the menu bar hiding the icon (once,
  Got It) and **"Pasting needs Accessibility"** (moved out of the card) with Open System Settings.
- **The pieces every pane is built from** (`UI/Components/MacLook.swift`, a header comment says
  it all): `PanePage { }` is a grouped `Form` (`.formStyle(.grouped)`; it sets `\.inPaneForm`);
  `PaneHeader(title:subtitle:)` the **hero** at the top — the pane's tile at 48 pt (found by the
  title in `Pane`, or `symbol:` / `tint:`), its name bold, one sentence, room for one button;
  `PaneSection("Title", note:)` a `Section` with a header and a **footer of a sentence**; `Plate { }`
  inside a form is just its rows (`Group` — each child a row, the separators the form's), outside
  one a grouped box of its own; `PlateRow(title:subtitle:icon:iconColor:) { control }` a System
  Settings row — `iconColor` is **the tile's colour** (a label colour reads as grey; use `MacTint.*`),
  the title 13 pt, the description 11 pt secondary, the control on the right; `PlateDivider()`
  draws nothing inside a form; `PlateNote` a quiet row; `SectionFooter`; `AllowedMark` ("✓ Allowed",
  "✓ Connected", "✓ Installed"); `EmptyState` (ContentUnavailableView's look); `MacTint` (the
  tiles' system colours). **So a pane written against the old dark plates comes out native with
  no change** — that's how Dictation, Permissions and the Away guide were carried over.
  `PanePage(opensAtTop: true)` for a pane with a text view (its caret scrolled the form to the foot
  as it was made — Dictation's Try it).
- **A new pane adopts the look** in four steps: its case in `Pane` (MacrophoneApp.swift — title,
  symbol; the sidebar and ⌘ number follow `allCases`), its tint in `Pane.tint` (MacLook.swift;
  grey by default), its line in MainView's `detail` switch, and a body of
  `PanePage { PaneHeader(title:subtitle:); PaneSection("…", note: "…") { PlateRow(…) { Toggle("", isOn: …).toggleStyle(.switch).labelsHidden() } } }`.
  Native controls only: switches, `Picker` (`.menu` / `.segmented`), buttons with no style (bordered)
  or `.borderedProminent` for the one thing to do.
- **Per pane:** *History* is Mail's message list (`HistoryPane`, a `List(.inset)` by day — Today ·
  Yesterday · the date): a row = the place's own icon (`HistoryPlace`: a live target's, a running
  app's, `/Applications`, else a symbol tile), the app in bold, the time, a paper plane / failure
  mark, the window's title as the subject, two lines of the words; a click opens the row in place
  (every word, where and how it went, Cleaned | Raw, Copy); right click Copy · Copy Raw · Delete,
  swipe left Delete / right Copy, ⌫ deletes the selected; **search in the toolbar** (`.searchable`,
  ⌘F on macOS 15+); a status bar at the foot (Keep history · "7 dictations · kept on this Mac" ·
  Clear All…); empty states are `ContentUnavailableView` (No dictations yet · History is off with
  Turn On History · the search's own). *Dictation*: the same rows as tiles (logic untouched), the
  🌐 conflict a row of its own, Try it a text box in the form with Clear inside it. *Agents*: Claude
  Code (orange) and Codex (graphite) rows, "✓ Connected" + Disconnect, Connect prominent.
  *Devices*: the hero's Pair Another iPhone…, each iPhone a row (a blue tile with the green dot while
  connected, Rename… / Forget…), This Mac, the Away guide as rows, **Without Tailscale** a native
  disclosure row with the addresses and the port. *Developer*: Local API, Token (Show ·
  Regenerate… · the masked well with copy), the command-line tool, Hook it up (the snippets, Read
  the API Docs). *General*: open at login, the shortcut (a recorder drawn as a field), the copy
  notification; **Appearance**; Permissions (Accessibility · Screen Recording · Notifications, each
  green tile + ✓ Allowed or orange + the button); Updates (automatic · Check Now); Help (Share
  diagnostics · Set up again · the web · **Quit** — and the privacy sentence as the footer).
  *Share Diagnostics*: the window's own title, a tile and the sentence, the log in a text well,
  Copy · Close · Save… · Share… as large system buttons.
- **The menu bar menu** was already native NSMenu with SF Symbols and Apple's title case for
  commands; the recent rows' words are SF Pro now (were New York), the header's connected glyph the
  accent.
- Hooks: `MACROPHONE_EMPTY_HISTORY=1` (History's empty state), `MACROPHONE_HISTORY_OPEN=1` (the
  newest row open). `window-<pane>`, `MACROPHONE_FAKE_PEERS`, `MACROPHONE_SEED_HISTORY` as before.
- **Not seen yet:** the window key and in front (every frame is the inactive look), the menu bar
  menu in light (opening it in a test takes the pointer from him), the sidebar's glass over a real
  desktop, VoiceOver through the toolbar's Send to menu.

## Dictation at the desk (Nov 7 2026)

Sameer: "hold a key on the Mac, talk, and the same cleanup pastes wherever you're typing." No
phone: the Mac app dictates by itself. Frames: `docs/screens/desk-dictation-nov7/`.
- **The key** (MacrophoneKit `Core/DeskHotkey.swift`, pure, `DeskHotkeyTests`): `DeskKey` — 🌐 Fn
  (default), Right ⌥, Right ⌘, Off (`settings.deskKey`, `desk.key`). `DeskHotkey` is the state
  machine: hold → the mic opens (at the press for Fn; after `armDelay` 0.18 s for the right keys,
  so ⌘C never lights the mic), the pill after `pillDelay` 0.15 s, let go past `tapLimit` 0.3 s =
  paste; a quick tap = nothing (the mic let go quietly); two taps within `doubleTapGap` 0.35 s =
  hands-free until the next tap (`handsFreeLimit` 10 min); another key while held = a shortcut,
  dropped quietly; Esc while listening = cancel, and that Esc goes no further (the one event
  ever swallowed — modifiers always pass). `Mac/App/Desk/DeskKeyTap.swift`: a session
  `CGEventTap` (keyDown + flagsChanged, the side's device bit — NX_DEVICERALTKEYMASK etc.) on the
  main run loop, feeding the machine and ticking it at `nextDeadline`. An active tap needs
  Accessibility; refused anyway, the page shows an Input Monitoring row.
- **Never a system Fn action from us:** macOS's "Press 🌐 key to" (`com.apple.HIToolbox`
  `AppleFnUsageType`: 0 nothing, 1 input source, 2 emoji — his Mac —, 3 dictation, `FnKeyUsage`) is
  read, never changed; anything but Do Nothing puts one ochre line and Open Keyboard Settings on
  the Dictation page.
- **Speech** (MacrophoneKit `Speech/DeskSpeech.swift` since the wake word, a copy of the phone's `ModernSpeech` for macOS 26+):
  SpeechAnalyzer + SpeechTranscriber on the Mac's language (`Locale.current` BCP-47), an analyzer
  made ahead (`DeskWarmAnalyzer`, after every dictation and when the key starts listening). The
  press opens only the mic (`Desk/DeskMic.swift`, AVAudioEngine on its own queue; what it hears is
  held, ≤ 12 s); the recognizer joins once it's a hold (`startSpeech`) and the held audio goes in
  first — a quick tap or a shortcut never spends the analyzer. No speech-recognition permission
  is asked (SpeechAnalyzer runs without it here); `AssetInventory` says `supported` yet it
  transcribes (a model the system shares) — a fetch is started in the background anyway.
- **Cleanup**: the shared `Cleaner` at this Mac's own level (`settings.deskCleanup`, `desk.cleanup`,
  Medium; Off · Light · Medium · Heavy — the Mac has no custom instructions, so no
  Custom; the Dictionary — the wake word section — is cleanup's list and the recognizer's context), prewarmed at the hold, an 8 s budget.
- **The paste**: `Paster.deliver(.front, send: false)` — no countdown, never sent; the landing
  glow and the menu bar icon's cues come with it (`statusItemCue` arriving / landed / failed). A
  failure copies and says so on the pill ("Copied — nowhere to type here. Press ⌘V"). History:
  a `Dictation` with `sourceDevice` "This Mac" (`DeskDictation.source`, always shown on its row),
  profile "Where I'm typing". The page's Try it box, focused with Macrophone in front, takes the
  words itself (Paster never pastes into Macrophone).
- **The pill** (`Desk/ListeningPill.swift`): a borderless non-activating `NSPanel` (status-bar
  level, every Space, takes no clicks) at the bottom middle of the screen with the pointer; Liquid
  Glass (`glassEffect`, a material before macOS 26) in the system's light or dark (the window
  stays dark **[Nov 7 2026: the window follows General › Appearance now; the pill still follows the system]**); Apple Intelligence's colours (`MacOSIntelligence`) as a ring round the mic that
  swells with the level and turns while listening (still under Reduce Motion); the newest words
  in two lines (cut at a word with "…" in front — `PillView.newest`), the undecided ones dimmer;
  "Let go to paste · Esc to cancel" / "Hands-free · tap 🌐 to finish · Esc to cancel" faint. Fades
  in 0.16 s, out 0.25 s.
- **The window**: sidebar **Dictation** between History and Agents (⌘2; the rest moved down one,
  ⌘1–6) — `UI/Window/DictationPane.swift`: Dictate on this Mac (`settings.deskDictation`, on by
  default), Hold to talk (the key), Cleanup (segmented, its summary or why it can't run), the how
  line, the Fn line, What macOS needs (`PermissionRows(desk: true)`: Accessibility, Microphone,
  Input Monitoring only if the tap was refused), Try it. Menu bar: one disabled line "Hold 🌐 to
  dictate" under the header while the key listens.
- **Permissions**: `NSMicrophoneUsageDescription`, `com.apple.security.device.audio-input` in both
  entitlements files (the hardened runtime blocks the mic without it). `PermissionsMonitor` reads
  `microphone` and `inputMonitoring` too (never told to phones). The key listens while on, a key
  is picked and the mic isn't refused; not yet asked, the first real hold asks (a quick tap never
  does) and the pill says "Allow the microphone, then hold 🌐 again".
- **Diagnostics** (numbers only): "desk: mic open N ms after the press (engine N ms)",
  "SpeechAnalyzer made ahead | made now, listening N ms after the press, N s held for it",
  "N words in N s, settled in N ms", "cleanup N ms (medium)", "pasted, landed" / "paste failed".
- **Hooks** (DEBUG): `MACROPHONE_DESK_AUDIO=<file>` (speech → cleanup on a file, twice — made now,
  then made ahead —, printed, quits; `MACROPHONE_DESK_LEVEL`); `MACROPHONE_DESK_SIMULATE=<file>[@hold
  s][@handsfree]` (the whole controller: the machine's presses, the file as the mic in real time,
  held audio, the recognizer joining at the hold, cleanup; printed instead of pasted);
  `MACROPHONE_DESK_PILL=<words>[|handsfree|finishing:<status>]` + `MACROPHONE_DESK_APPEARANCE`,
  `MACROPHONE_BACKDROP=1`, `MACROPHONE_PILL_RECT_FILE`; `MACROPHONE_DESK_TRY`; `MACROPHONE_DESK_NO_PILL`;
  `MACROPHONE_NO_ACTIVATE=1` (a window shown without taking the keyboard). A `MACROPHONE_INSTANCE`
  copy never listens for the key unless `MACROPHONE_DESK_LIVE=1` (it would dictate beside the real
  app). `say -o x.aiff "…"` makes a test file.
- **Measured** (this Mac, `say`'s voice, 31 words / 8.3 s): speech settles 243 ms after the end on
  an analyzer made ahead (434–513 ms made now); Medium cleanup 1.35 s warm (2.5 s cold).
- **Needs a real check:** a real Fn hold with the real mic (the tap, the mic light, the first
  syllable, the pill over a full-screen app); whether macOS's emoji picker still opens beside a
  hold with "Press 🌐 key to" left on Show Emoji (and whether Apple's "press 🌐 twice" dictation
  shortcut fights the double tap); Right ⌥ / Right ⌘ on an external keyboard; the paste into
  Claude, Terminal, Notes; the microphone prompt's first appearance; Input Monitoring ever being
  needed.

## The wake word (Nov 7 2026)

Sameer: "the hey claude feature set in SameerOS … add that feature set to macrophone Mac app so
that users can use [a] wake word to talk to and send clean text to their Mac", "SameerOS dies and
this feature gets improved and moved", "go deep on how you make the wake word feature … production
ready". Say the phrase ("Hey Mac" by default), talk, and the words land where you're typing — a
second way into desk dictation's pipeline (same pill, speech engine, cleanup level, paste, History
"This Mac"), not a second pipeline. Off by default. Frames: `docs/screens/wake-word-nov7/`.
- **What moved from SameerOS** (`~/claude-projects/SameerOS-Mac/SameerOSMac/Voice/`, read, not
  changed): the three tiers (loudness → Apple's sound classifier → a speech session only while a
  voice is heard; its SoundGate, classifier thresholds, the 3.5 s pre-roll, the room-relative "is
  that still a voice" rule); the *same* session carrying on as the capture (no restart, no lost
  words); short recycled sessions (4 s without new words ends one, recycle at a pause after 10 s,
  45 s at most); the anchored command (the hit nearest where the phrase was; revised away → drop
  that many words); "Hey Claude"'s mis-hearings (claud, clawd, clod, claudie… — "cloud" and "Clyde" now High only: the bench woke on "Hey Clyde, wait up" and "Hey, cloud storage is full") and
  the vocative form ("…, Claude,"); `strip(endingPhrase:)` (whole words at the very end,
  "nevermind" = "never mind"); a noisy room still ends (no new words for the pause + 1.5 s); the
  chimes (synthesized, no files); the 4096-frame tap; the output-rate lesson (below). **Left
  behind:** Dispatch, inbox tasks, notes, Muse, `DispatchLane`, the wake log (it wrote overheard
  speech to `~/Library/Logs` — Macrophone writes nothing and logs numbers only), the 10-minute
  recognizer rebuilds (SFSpeechRecognizer's staleness; SpeechAnalyzer sessions are per scan).
- **What improved:** any phrase, matched by spelling keys (MacrophoneKit `Core/WakeWord.swift`,
  `WakeText.key`: "Mack"/"Mac" are one, "Max"/"Mike" stay apart) with curated hearings for the
  presets and run-together forms ("Heymac"); three sensitivities (Low: the phrase as written and
  it only wakes on settled words with confidence ≥ 0.5; Normal: hearings, confidence ≥ 0.3 once
  settled; High: one letter off for long names, the vocative for any name that isn't an everyday word ("Mac, Windows and Linux…" never wakes), the recognizer's second
  guesses); every wake re-checked when its words settle (SpeechTranscriber's
  `transcriptionConfidence` on the name, `alternativeTranscriptions` at High) and **withdrawn** if
  it doesn't hold — the pill fades, nothing pastes; ending words as editable lists (send · paste ·
  cancel; a one-word ending only after a pause, so "we shouldn't cancel" stays words); **a place by
  name** at the end ("… send to Claude", "… paste it in Notes", with the recognizer's "pasted in" /
  "sent to") looked up fuzzily among open apps (`WakePlaces`); the Bluetooth rule; calls, lock and
  sleep pauses; Pause Listening; the first-time sheet; the Mac's Dictionary.
- **Files:** MacrophoneKit `Core/WakeWord.swift` (pure: `WakePhrase`, `WakeSensitivity`,
  `WakeMatcher`, `WakeEndingWords`, `WakeEndings`, `WakePlaces`, `WakeCapture`; `WakeWordTests`),
  `Core/DictionaryImport.swift`, `Speech/DeskSpeech.swift` (moved from the app, macOS-only: one
  speech engine for desk and wake, two warm slots `DeskWarmAnalyzer.shared` / `.wake`, context
  strings, confidence, alternatives), `Speech/WakeAudio.swift` (`WakeFeed` tiers, `WakeMicSource`,
  `WakeFileSource`, `WakeAudioDevices` + `WakeAudioWatch` — Core Audio, read-only),
  `Speech/WakeListener.swift` (scans, capture, verify, recycle, health, restart);
  Mac `Desk/WakeWord.swift` (`WakeController`: when it listens, events → DeskDictation, places,
  pause, the sheet's test, SameerOS, the Dictionary import), `Desk/Chime.swift`,
  `UI/Window/WakeWordSection.swift` (the section, Ending words, Dictionary, `WakeIntroSheet`),
  DeskDictation's `wakeBegan / wakeWords / wakeEnded / wakeLand` and a general `deliver(target:send:)`,
  DeskKeyTap's `onEscape` / escape-only mode, StatusItemController's mark and menu.
- **When it listens** (`WakeController.apply`): on, macOS 26+, the microphone allowed, the sheet
  through, not paused from the menu (`wake.pausedUntil`: For 1 Hour · Until Tomorrow 8 am · Turn
  Off), unlocked (`com.apple.screenIsLocked`, a session switched away), awake with the screen on
  (`screensDidSleep`, `willSleep`), and **no other app using a microphone** — Core Audio's process
  objects (`kAudioProcessPropertyIsRunningInput`, macOS 14+, per-process listeners, our own pid
  and `com.sameer.sameeros-mac`'s always-on listener left out): a call pauses at once, its end
  resumes 2 s later. Paused, the engine stops — the orange dot goes. The page and the menu say
  which ("Paused — zoom.us is using the microphone").
- **The microphone** (`WakeMicSource`): AVAudioEngine, input only, 4096-frame buffers (~12
  wake-ups a second), mono copied off the first channel. **Not a Bluetooth input**: the default
  input if it's wired/built-in, else the Mac's own microphone (`AUAudioUnit.setDeviceID`) — opening
  AirPods' mic all day flips them to the call (HFP) profile: their sound drops to 16–24 kHz. That
  was SameerOS's "output sample rate restore": its mic moved the output's rate and it set it back.
  Macrophone never sets a device's rate; it reads the output's before and after the start and logs
  a move. Only AirPods to hear with → it doesn't listen and says why. Follows the default input
  without a relaunch (Core Audio's default-input listener, `AVAudioEngineConfigurationChange`, a
  5 s health check that restarts a source quiet for 4 s).
- **The capture** (`WakeCapture`): the pause that lands it (0.8–4 s, 2.0 default, the page's
  slider) from the later of the last new word and the last voice above the room; ending words land
  it after 0.8 s (0.5 alone); the phrase and nothing for 6 s = "Didn't catch that"; 3 min at most.
  Esc (the desk key's tap, escape-only when no key is picked) or "never mind" drops it; nothing
  pastes. **🌐 during a capture joins it** (one dictation): held, only the release lands it; a tap
  lands it now; Esc drops it. 🌐 held with no capture: the wake word stops scanning until it's let
  go (`suspend` / `resume`). The pill: "Listening…", the words, "Pause to paste · “send it” to send
  · Esc to cancel"; a place not open: pasted where you're typing, the pill says "No “Notes” open —
  pasted where you're typing". Chimes (`wake.chimes`): two notes rising on the phrase, falling on
  landing, one low note when dropped.
- **Privacy:** audio never leaves the Mac, nothing is written to disk (no recordings, no wake
  log), the log has counts and seconds only ("wake: send to a place · 9 words in 4.8 s"). The menu
  bar icon gets a small dot at its top right while it listens (`…+ear`, the template's own colour)
  and a line + **Pause Listening** in the menu. The first time it's switched on: `WakeIntroSheet`
  (the orange dot, what's heard, when it stops) with **Say it now** — the listener runs for the
  phrase only and the box goes green ("Heard you"); the switch stays on only through Turn On.
- **The Dictionary** (`settings.dictionary`): words and names, the recognizer's context and
  cleanup's list — for desk dictation too (it passed `[]` before). Once, if
  `~/.config/sameeros/vocabulary.txt` exists, its terms are imported (`Term: sounds like` lines
  keep the term); silently skipped otherwise (`dictionary.sameerOSImport`).
- **SameerOS:** open with its "Hey Claude" on (its `listeningEnabled`, read with CFPreferences,
  never written) → one ochre line on the page: "SameerOS is also listening for “Hey Claude” — turn
  it off there."
- **Hooks** (DEBUG): `MACROPHONE_WAKE_AUDIO=<file|folder>[@loop]` (files as the microphone, the
  whole app path, printed "WAKE woke / finished / LANDED → place · send / RAW / CLEANED", never
  pasted; `MACROPHONE_WAKE_PHRASE`, `MACROPHONE_WAKE_SENSITIVITY`); `MACROPHONE_WAKE_STATE=
  listening|paused-call|paused-user|airpods|unavailable|sameeros`; `MACROPHONE_WAKE_SHEET=listening|heard`;
  `MACROPHONE_WAKE_PILL=<words>[|finishing:<status>|note:<words>]`. A `MACROPHONE_INSTANCE` copy
  never opens the microphone (nor the sheet's test) unless `MACROPHONE_WAKE_LIVE=1`.
  `mpctl wake-testset <dir>` (`say` voices, music beds, room tone → manifest.json + WAVs),
  `mpctl wake-bench <dir> [--phrase --sensitivity --only kinds --voices N --no-classifier]`,
  `mpctl wake-soak [--minutes --set <dir> --every s --noise dB --ungated]` — the same
  `WakeListener` headless, CPU (this process and the speech daemons, `ps` TIME) and memory.
- **Measured** (this Mac, macOS 27, release `mpctl`, real time; the test set is 187 clips / 16.6
  min from `mpctl wake-testset` — ten `say` voices, kept in a scratch folder, regenerate it):
  - *Idle* (quiet room tone, −62 dBFS, 4 min): **0.20% CPU** for the listener's process (the
    file source's own noise synthesis included), **0.00% in the speech daemons**, 7 MB. The
    baseline with no tiers (`--ungated`: a session whenever one can run, 3 min): 1.0–1.4% in-process
    **plus 2.4–3.1% in Apple's `localspeechrecognition`** — the model runs out of process, so
    in-process CPU alone undercounts any always-on transcriber. The tiers are ~20× cheaper at rest.
  - *Soak* (32 min, room tone with a test clip every 60 s): 33 sessions, 9 wakes landed, 0
    restarts; 0.25–0.4% CPU in-process; memory 6 MB until the first session, then 24.2 → 26.3 MB
    over 30 min (about +2 MB: near flat, watch it over a day). Busy bench runs (a voice 70–90% of
    the time): 1.0–1.6% in-process + 2–3.5% `localspeechrecognition`.
  - *"Hey Mac", Normal, all 187 clips:* **0 false triggers in 107 negative clips** (40 near-misses
    — "Hey Max / man / Mike / Mark / Matt", "I bought a new Mac", "Mac, Windows and Linux", "My
    Mac keeps…" —, 24 talk and talk-over-music, singing, music, the other phrases' clips). Hits:
    **40/42 on the six natural voices** (Samantha, Daniel, Karen, Moira, Rishi, Tara), 9/10 over
    music, but **4/28 on the four robotic voices** (Fred, Reed, Flo, Eddy) — SpeechTranscriber
    hears them as "Hey man / Max / Matt", the very near-misses that must not wake (4 wakes were
    withdrawn at settling for that reason). Words after the phrase: 90% of the expected words;
    ending action right 52/53; place right 11/13 (the misses were the recognizer's "pasted in
    notes", now read).
  - *Five voices, positives + near-misses (75 clips):* Low 31/35, 0/40 false · Normal 35/35, 0/40 ·
    High 35/35, 0/40 (after the tuning below; before it High woke 5 times on "Mac, …" and Low
    found 27/35 at a 0.6 bar).
  - *"Hey Claude" 10/10, 0/12 near-misses; "Computer" 5/5, 0/9* (after dropping "cloud"/"Clyde"
    to High and the plural "computers": before, 6 and 3 false wakes).
  - *Context strings don't move SpeechTranscriber* ("Hey Mac" as context changed nothing on the
    robotic voices); DictationTranscriber with context partly does (Reed → "Hey Mac", "Mac" among
    Flo's alternatives) — a lead for High if real voices miss, weighed against it pulling "Max"
    toward "Mac". The app path proven with `MACROPHONE_WAKE_AUDIO`: wake → capture → "send it" →
    Return; "send to Claude" found the open Claude app; "paste it in Notes" with Notes closed fell
    back with the note; "never mind" dropped; a near-miss nothing.
- **Needs a real check with the real microphone** (nothing here opened it for more than a moment):
  real voices and accents (the bench is TTS; "Mac" is short and its neighbours are near-misses —
  try Low/Normal/High and the confidence bars); a room with a TV, a podcast, music and typing
  (the classifier's thresholds are SameerOS's); far-field (across the room) vs at the desk; the
  orange dot coming and going with lock, screen sleep, Pause Listening; a real Zoom / FaceTime /
  Teams / Meet-in-Chrome call pausing it (which process Core Audio names for each) and resuming 2 s
  after; AirPods connecting and leaving mid-listen (it should stay on the built-in mic, the
  AirPods keeping their music quality — check the output rate in Audio MIDI Setup), a USB mic,
  a Mac with only AirPods (it says why it can't listen); the idle CPU and energy with the real HAL
  (Activity Monitor's Energy column over an hour; the file source stood in for coreaudiod); memory
  over a day; 🌐 held during a capture (one dictation) and Esc swallowed only then; the Say it now
  test with the microphone prompt's first appearance; "send to <app>" bringing a real app forward;
  the chimes' volume next to music; SameerOS's line with its listening on (it was off here).

## The product, as it stands (Oct 18 2026)

Reader (the window's words as text) was cut the same evening — Sameer: "not that great … focus on making the window view really good". The speed pass (same night): no paste countdown when nobody's at the Mac, no fixed settle waits, the result before the clipboard's restore; the Mac gets the place ready while you speak (`prepare`, feature "prepare" — Paster.prepare); cleanup runs during your pauses (AppModel.cleanAhead); video sends every real change (WatchPacing `live`), 60 fps at home, Retina up to 2,560 px.

Two days of features from several hands, read as one product: every feature has one name, one
glyph and one obvious way in on each app. This map wins over any older section below (the ones it
replaces are marked **superseded**); the sections below keep the mechanics and the numbers.

| Feature | iPhone | Mac |
| --- | --- | --- |
| **Send to** (the shared choice, "Send to" everywhere — never "Send To") | The controls panel by the mic: `SEND TO` kicker, the pick's name, a row of app icons only (a long press lists an app's windows), **+** at the end = Open an App (the only way to open one that isn't open), **⋯** = Send a Photo… · Send a File… · Copy Mac's Clipboard · Send Clipboard to Mac · Refresh Open Apps **[superseded Nov 7 2026, round 2: one paperclip, `AttachMenu`; Refresh in Open an App]**. Settings › Send to is the full list. `UI/QuickControls.swift`, `UI/SendTo.swift`, `UI/SendToMac.swift` | The menu bar menu's Send to section (a check on the current, the first six apps, More Apps, Send after pasting as its own toggle); the `SendToCard` above every window pane **[superseded Nov 7 2026: `SendToToolbar` in the window's toolbar]**; the first-run step. `UI/StatusItemController.swift`, `UI/Components/SendTo.swift` |
| **Watch** (the window, live, as video) | **Watch** beside the Send to name, or by itself after a send (Settings › Show the app after sending), or the Watch widget; Done ends it. The name at the top is the window menu (page dots, a swipe in from a side edge flips); tap = click, tap twice = double-click, tap then hold-and-move = drag, hold / two fingers = right-click, pinch = zoom; **Pan \| Scroll** under the thumb (Scroll picks itself when the whole window is on screen, and when a window was fitted to the phone); Esc · ↑ · ↓ · ⏎ · **···** (More keys, by section) or the question's answers as buttons; the **KEYBOARD · MIC · TRACKPAD** row above the Thread (Oct 19 2026 — the pages slide under it; the trackpad takes the Thread's room) **[superseded Nov 7 2026, round 5: on every iPhone, while a window shows, one row — Keyboard · a 64 pt mic · Trackpad — no page row, no Thread]**; **Mac Controls** beside Sound in the header (the carousel fixes). `UI/WatchPanel.swift`, `Model/Watcher.swift`, `UI/InputCarousel.swift` | Streams the one window (`Watch/WatchService.swift`, `VideoPipe`, `WindowStream`), posts clicks, drags, the pointer, typing, keys and trackpad-style scrolls (`InputService.swift`, `ScrollPoster.swift`); the menu bar icon becomes a ring and the menu gets **Stop Showing ‹app›** while a phone watches |
| **The header cluster** by Done: **zoom out** (`arrow.down.right.and.arrow.up.left`, the whole window and back), **Window** (`macwindow`) | One piece of glass; each only when the connected Mac names its feature. `UI/WatchReader.swift` is Text: your text size, selectable, Copy All, follows the newest line, asked every 2.5 s | Reader: a terminal's own text, else recognition over the column you type in (`WindowReader.swift`); `mpctl reader` |
| **The Window menu** (in order of use) | Fit to iPhone · Text size on this iPhone (Normal · Larger · Largest, per app) · Size on your Mac (Fill the Screen `rectangle.inset.filled` · Left Half · Right Half · Middle · Back to How It Was) · Minimize · Close Window (asked first) · the photo / file / clipboard items (the same as Send to's ⋯, here because the panel is away) **[superseded Nov 7 2026, round 2: gone — the paperclip leads the key row]** · Show Tips Again | `WindowFit.swift` resizes through Accessibility and restores on Done / Quit |
| **First-use tips** (`UI/WatchTips.swift`) | Five at most, one card at a time over the window's top, each only when it works with this Mac: Tap to click / hold to right-click · Pinch to zoom, or Fit to iPhone · Swipe in from the side (two windows or more) · Pan or Scroll (auto-Scroll named)· More keys. `watch.tips.seen`; Window › Show Tips Again | — |
| **Photos, files, the clipboard** (`Core/Share.swift`: features `attachments`, `clipboard`) | Send to's ⋯ and the Window menu — the same `MacShareItems`; a photo or file goes into the chat you send to (the watched window while one shows), the clipboard only when asked; the status line says where it landed | `Delivery/Attachments.swift` (kept a week in From iPhone; the image into a chat app, its path into a terminal), `ClipboardShare.swift` (a concealed copy never leaves) |
| **Chats that answered you** (feature `needsYou`) | The ember dot on the app's icon in Send to, "Answered you" / "Asking you" by the pick's name, `circlebadge.fill` in the window menus, the mark on the widget; looking clears it | `Watch/ReplyWatcher.swift`: a window you sent to from the phone, answered by its hook agent or by its picture settling |
| **Agents** (Claude Code, Codex, by their hooks) | Nothing to see: the notification the moment one asks ("Claude Code is asking you something" + the question; a tap watches that window) — Settings › Alerts › When an agent asks something. The phone's Agents panel was removed Oct 18 ("not actually a useful section") and the `agents` wire with it | The **Agents** page (its own sidebar section, `AgentsPane`; Connect / Disconnect), the menu bar's **Connect Claude Code…** until it is; `Watch/AgentHub.swift` keeps the sessions for the alert, the Answered you mark and the lookout; `POST /v1/agent`, `mp hook` |
| **Alerts when nobody's looking** (feature `attention`, `attention-cloud`) | The notification; through iCloud when the app is closed (`Model/AgentAlerts.swift`, builds signed for it) | `AttentionWatcher` reads agent windows nobody watches (controls through Accessibility, else Vision); `CloudAlerts` writes the record |
| **The Watch widget** (`iOS/MacrophoneControls/WatchWidget.swift`) | Up to four of the Mac's open apps with their icons and the ember mark; small 2 × 2, medium a row with names; a tap = `macrophone://watch?target=…` (watches, and picks it in Send to); fed through `Shared/WatchWidgetData.swift` | — |
| **How it's connected** (`LinkRoute`) | The Mac pill's glyph (Wi-Fi, direct link, Tailscale shield, globe); the status line "Ready · ‹Mac› · Tailscale"; Settings › Connected now | The menu header "Connected · Tailscale · away from home" (`MenuWords.via` — the route's `short`, the same words as the status line and the phone); Devices › Away from home |
| **Open / quit an app** | **+** at the end of the Send to row → Open an App (search, Quit beside an open one) | `AppCatalog` opens / quits; the menu's More Apps lists only open ones |
| **The Mac window** | — | Sidebar: History · Dictation · Agents · Devices · Developer · General (⌘1–6); the Send to card above every pane **[superseded Nov 7 2026: Send to in the toolbar, the panes System Settings' grouped forms — "The Mac app as Apple would make it"]**; the menu bar menu is `StatusItemController` + `MenuBar/` (header · Stop Showing · Open Macrophone · Send to · Recent · the rare ones · Quit) |

Glyphs that mean one thing: `eye` = Watch (the button, Settings, the widget's kicker; `eye.slash` =
Stop Showing), `macwindow` = the Window menu (Fill the Screen is
`rectangle.inset.filled`; a flipped-to window's note and the swipe tip wear `arrow.left.and.right`),
`text.cursor` = Where I'm typing and `app` = a nameless app on both apps (`TargetGlyph` /
`TargetIcons`), `paperplane` = Send after pasting, `sparkles` = Claude Code / the Agents page.
Feature flags: a message goes only to a peer that named its feature in hello / welcome
(`LinkClient.features`, `LinkServer.macFeatures`; `mpctl serve` names them all) — App Store
iPhone 1.0 and an older Mac keep working.

## The iPhone Duo (Oct 25 2026)

Sameer: "make the app work on the iPhone Duo. Everything we built needs to work well on the front
screen and then we need to come up with an epic inside screen experience … like a little MacBook
with the window or full screen taking up the full half when partially folded and the bottom half
being trackpad or keyboard or mic … a Duo version that supports every fold option". The Duo folds
like a book: a cover screen (466 × 678 pt — wider and shorter than a Pro, its status bar on the
side) and an inner screen (669 × 951 pt). Nothing changes for any other iPhone. Two passes the
same day; the second (below, "the laptop in earnest") wins where they differ. **[Nov 1 2026: the
inner screen's fold runs along its long side — upright (669 × 951) the laptop and flat portrait,
on its side (951 × 669) the book and flat landscape; the passes below had the laptop 951 wide
and the book 669 wide, and every frame with them. "The Duo at its real shape" (below) wins.]**
- **Poses** (`FoldPose`, MacrophoneKit `Core/FoldPose.swift`, pure, `FoldPoseTests`): `closed`
  (the cover: the phone's layout, `MainView.phoneBody`, compact), `open(landscape:)` (the inner
  screen flat), `laptop` (partly folded, the hinge across), `book` (partly folded, the hinge up
  and down). `FoldPose.derive(FoldReading)`: the hinge decides (closed · partiallyOpen · fullyOpen);
  partly open, the fold's region says which way (a band wider than tall = laptop) else the scene's
  shape; no hinge reading and a scene ≥ 600 pt on its short side is still the inner screen, open.
  `FoldHalves.split` cuts the scene at the fold's region (margins included; a 28 pt band in the
  middle without one). `deckRise(angle:)` = 0 flat → 1 past ~120°.
- **Read** (`Model/Posture.swift`, `Posture.shared`, iOS 27.1 gated, older systems untouched):
  SwiftUI's `onHingeChange` (`DeviceHinge.status` / `angle`) and `GeometryProxy.reservedRegions(kind:
  .division, options: [.includeInactive])` — `PostureReader` round the main view (`RootView`), the
  size measured with the keyboard ignored so a folded layout never shrinks for it. UIKit's
  `UIHingeInteraction` / `UIView.reservedRegions` are the same facts; the app reads them once, in
  SwiftUI. A pose change: `Haptics.soft()`, a VoiceOver layout announcement (`FoldPose.spoken`),
  "pose: laptop (112°, 951×669)" in the log; the layouts cross-fade on the settle spring
  (`MainView.poseBody`), the halves follow the hinge (`Posture.rise`: the deck rises, the picture
  settles into its half; Reduce Motion fades).
- **The folded poses are a laptop (`UI/DuoView.swift`, the second pass) [the laptop half is superseded Oct 31 2026: the picture alone, the header and answers on the deck — see below].** *Laptop* — the top
  half IS the Mac's screen: `DuoMacHalf` draws `WatchWindow` edge to edge (`bezelWidth` 2,
  `corner` 14, `fill: true`) with a slim translucent header laid over its top like a menu bar
  (`DuoOverlayHeader`: `WatchHeaderBar(dragSwitch: true)` — the window's name and menu, the dots,
  Sound | Mac Controls, Pan | Scroll as glyphs, zoom out | Window, Done — on a gradient that fades
  into the picture) that fades 3.5 s after a touch and comes back on any touch of the half
  (`DuoLook.headerHold`; never fades for VoiceOver, while the window isn't live, or under
  `MACROPHONE_DUO_HEADER=held`); the question's answers float over the picture's foot
  (`WatchActions(floating: true)`: Esc, then the answers in one row, a column when too long —
  no key row on the deck: Esc · ⇥ · the arrows ride the keyboard page's bar). The bottom half
  is the deck, all of it (`DuoDeck`): the carousel fills it with its row hidden
  (`InputCarousel(rowHidden:)`) and the three pages as one small cluster of glass cells in the
  deck's top-right corner (`InputCornerSwitcher`, the same `input-pages` adjustable element); the
  trackpad is the whole half (`TrackpadPage(big:)`: an even inset, the faint outline of a pad);
  the mic page is the Thread across the half (an 84 pt slot) with the mic under it, the pair
  centred — and while the mic is open the words show over the picture above on a card of glass
  (`DuoLiveWords`: the destination line and `LiveWords`, up to 62% of the half); the keyboard
  page is the iOS keyboard rising over the deck with `MacKeyboardBar` on it. *Book* — the same,
  the Mac on the LEFT page and the deck on the RIGHT (the right thumb drives the trackpad); the
  header takes two rows (`twoRows`); the iOS keyboard is the screen's width, so it rises over the
  foot of both pages (nothing to do about that: the Mac's page keeps its height).
- **The picture fills a folded half** (`Watcher.fillsView`, set by the pose; `ViewerScrollView.fill`):
  the start scale covers the half (`max(fitWidth, fillHeight)`, capped at the usual 1.8 × the
  width-fit so a window shaped nothing like the half — one the Mac can't reshape on the book's
  tall page — never zooms onto a sliver), the zoom's top end at least that; the zoom-out button
  still shows it whole; the whole screen fills too (its `wholeWindow` start is off while
  `fillsView`). **And a window the Mac can reshape takes the half's shape by itself**
  (`Watcher.applyHalfFit`, quietly: once per entry into a folded pose, once the window is live
  and the view measured, never the whole screen; `shapeSent` set so `followShape` doesn't
  re-send; the app's fitted flag and Scroll as Fit to iPhone sets them). `mpctl serve`'s demo
  window is fixed at 1400 × 900 whatever shape is asked, so on the simulator it fills by zoom.
- **Done on the inner screen is the glance, not a closed window** (`Watcher.glance()` /
  `done()` / `glanceOnDone`, set by the pose; `isShowing` = open and not glancing; the cover and
  every other iPhone close as ever, and a glance closes with the inner screen): the pictures keep
  coming, the controls are put away (the pointer hidden, the pages back to the mic), and
  `DuoGlance` draws the live window big with a bar over its foot — the app's icon and name, "Live
  on your Mac" (or "Paused · Show it here to go on"), **Show it here**
  (`AppModel.showWindowForPose`, which opens it again — `Watcher.open` clears the glance). Nothing
  watched yet: the picked app on a plate and the same button; Pair a Mac / Looking for ‹Mac›.
  While two viewers overlap in the cross-fade, a `ViewerScrollView` leaving the window hands the
  video canvas to the newest one that wants it (`wantedVideo` / `newest`) — the one on its way out
  used to take the canvas with it and leave the glance black.
- **Open, upright** (669 × 951) **[the fourth pass, below, re-laid the lower part; superseded Nov 1 2026: flat upright is the laptop's layout, the fold across its middle — and on its side the right page is the cover's view]**: the top bar,
  the window large (`DuoMacArea` → `WatchPanel(duo: true)`: the answers float over the picture's
  foot there too, `WatchActions(keysOnly: true)` under it; a first-run tip is a strip under the
  window, `WatchTipCard(inline:)`), then Send to across the whole width (a grid of every place
  with its name, none on the fold's line; the transcript while the mic is open), then a band
  split at the fold: Send after pasting and Cleanup on the left (`optionsPanel`), the carousel on
  the right (tight: a 48 pt Thread slot, a one-line status) — each half a set width (a flexible
  split had the carousel chasing its own measure: the hang of Oct 25). *Open, on its side*
  (951 × 669): the window left at full height, a 344 pt rail right — the top bar, Send to as a
  grid three across (the transcript while the mic is open), then the deck filling the rest (the
  trackpad whole, the mic in the middle). The rail rather than a bottom deck: it keeps the window
  near-square, so a window fitted to it reads like a laptop's, puts the controls under the right
  thumb, and only the picture crosses the fold.
- **Rules** **[Nov 1 2026: opened flat it's the glance, folded it comes in hand — see "The Duo at its real shape"]:** opening the inner screen opens the pick's window by itself (`AppModel.poseChanged` →
  `openWindowForPose`: the Whole Screen for the Clipboard / Where I'm typing; waits for the Mac
  when it isn't connected yet — `linkClient(_:stateChanged:)`); closing the phone closes a window
  view the pose opened (`openedByPose`), never one he opened. The deck remembers its page per
  folded pose (`MacInput.deckPage(for:)`, UserDefaults `duo.deck.laptop` / `duo.deck.book`, the
  trackpad the first time; `MacInput.poseChanged`, `opened()` honours it); flat or closed, the mic
  as ever. A window fitted to the phone follows the view's shape when the pose changes
  (`Watcher.followShape`: 0.7 s after the view settles, only `isFitted`, only when the aspect
  moved > 6%, quiet). Orientation: `AppDelegate.application(_:supportedInterfaceOrientationsFor:)`
  — every way on a screen ≥ 600 pt on its short side (the inner), upright on the cover and every
  other iPhone (Info.plist lists all four; the delegate narrows).
- **The simulator can't be folded from a script** **[the frames' shapes and bars are corrected Nov 1 2026 — `MACROPHONE_FRAME=669x951` is the laptop and flat portrait, `951x669` the book and flat landscape, each with its bars stood in for].** Xcode 27.1's Device Hub folds and rotates a
  simulated Duo, but opening it the first time asks for an admin password ("DevicesSystemUpdater
  is trying to install Apple software") — not done; `simctl` has no hinge command, the Duo's
  `io enumerate` lists the cover (1398 × 2034) and the inner (2007 × 2853) displays but the app
  runs on the cover with the inner dark, and nothing in CoreSimulator / DeviceHub / backboardd
  names a hinge. So: `MACROPHONE_POSTURE=closed|portrait|landscape|laptop|book[@<angle>]` forces
  the pose (a fold band in the middle stands for the region) and `MACROPHONE_FRAME=951x669` /
  `669x951` draws the inner screen's frame to scale on the cover (`duo-frame` for the tests; the
  cover's side status bar leaves it 375 pt wide); the real APIs are wired and untested on hardware.
  **The keyboard-frame finding:** the first pass's keyboard frames looked wrong because the
  cover's own portrait keyboard rises at 1:1 over the scaled frame — the simulation, not the
  layout. `MACROPHONE_FAKE_KEYBOARD=<height>` draws a stand-in keyboard of that height inside the
  frame at its scale, with `MacKeyboardBar` above it (`DebugKeyboard` in RootView; the real field
  never takes the keyboard then): at 216 pt (a landscape iPhone keyboard) the bar and keys cover
  the laptop's deck exactly and the Mac's half is untouched. `MACROPHONE_WATCH_ACTIONS` gained
  `say@<words>` (the mic opening with those words while the window shows) and `done` is
  `watcher.done()` (the glance on the inner screen). Frames: `docs/screens/duo/<pose>/` (main · the
  window on each page · Mac Controls · Settings · the glance · the live words; a before | after
  contact sheet each). UI tests `DuoUITests` (a paired `mpctl serve`; the springboard's
  notifications prompt tapped away on a fresh simulator): the laptop pose opens on the trackpad
  which takes ≥ 80% of the bottom half, the answers sit over the top half, the header fades and a
  touch brings it back, a drag moves the pointer, the corner switcher brings the keyboard and
  typing reaches the Mac, hide comes back to the trackpad it rose over, Done leaves the glance ("Live on
  your Mac", the pages put away) and Show it here brings the deck back; the book's deck is the
  right page and its answers float on the left; the open screen keeps the mic and the panel off
  the fold under a large window; on its side the rail holds Send to, the mic and the trackpad.
  `TEST_RUNNER_MACROPHONE_DUO_SHOTS=<dir>`.
- **The third pass (the review, the same day) — what it changed:**
  - *The rule:* an inner pose needs the inner screen. `FoldPose.derive` keeps a scene narrower
    than `innerShortSide` at `.closed` whatever the hinge says (the hinge is partly open while
    the app is still on the cover as the phone opens or closes — the cover drew a 466 pt laptop
    for a frame); a size of zero still lets the hinge's word stand. `deckRise` is in fiftieths,
    so a hinge trembling by a fraction of a degree moves nothing. Tested.
  - *The read:* `Posture` publishes only what a layout draws from (the pose, the halves, the
    rise); the raw `reading` isn't published and `hinge(_:angle:)` drops a reading that changes
    neither the status nor the rise's step — every half-degree used to re-lay the whole main
    view. The first pose derived after the first measure is the one the app opened in: no tick,
    no announcement for it. `PostureReader` measures the scene in a background layer that
    ignores the keyboard, so the content keeps the keyboard avoidance it always had — the
    second pass had wrapped the whole main view in `ignoresSafeArea(.keyboard)`, which took it
    away from every regular iPhone (the keyboard covered the window instead of the window
    moving up); the folded bodies ignore the keyboard themselves, as before. `DeviceHinge.angle`
    is an `Angle` (`.degrees`); `ReservedRegion.frame` is in the proxy's own space, margins
    included (UIKit's `UIViewReservedRegion` says so in words) — both checked against the SDK.
  - *The Mac's window is reshaped only on a pose change:* `Watcher.followShape` is armed by
    `poseSettled()` (AppModel's `poseChanged`) and spent by the next follow or after 4 s —
    it used to run on every change of the view's size, so on a regular iPhone a fitted window
    was reshaped on the Mac each time the keyboard rose, a question's answers appeared or a
    tip card went. `applyHalfFit` takes only a folded half's own measure
    (`viewerMeasured(_:fill:)`, `WatchWindow(fill:)` says which), never the phone layout's
    still on screen in the cross-fade; `shapeSent` is cleared on a switch and on close.
  - *The deck:* `MacInput.hideKeyboard()` — the bar's button, the swipe down and the system
    closing the keyboard — goes back to the page the keyboard rose over on a folded deck (the
    trackpad on a laptop: the hands are already there; `underKeyboard`), the mic on a flat
    screen as ever; the deck never remembers the keyboard as its page (it rose at once on the
    next open), only the mic or the trackpad; a pose change while glancing shows no page (no
    pointer sent while the controls are put away: `isShowing`).
  - *The overlay header:* a finger moving over the picture re-arms its hold at most twice a
    second (it was a task per touch frame); the hold is cancelled when the half leaves; its
    ground takes a tap (a tap between its controls never clicked through to the Mac's title
    bar under it); the book's header has Pan | Scroll too (it had no way to it).
  - *The glance* of a pick that isn't open on the Mac says so instead of offering Show it
    here (opening a closed app's window started a watch that never came up).
  - *The keyboard page survives a cross-fade* (`KeyboardTextView`, MacKeyboardView.swift): every
    pose lays out its own carousel, so while two layouts cross-fade — a fold, an unfold, the
    deck's not-watching screen giving way to the window — two keyboard fields are alive and
    both want the keyboard; the arriving one took it, UIKit resigned the leaving one, and 0.35 s
    later the leaving one declared the keyboard gone and put the page back (on the simulator
    SwiftUI even kept the deck's faded-out layout around at alpha 0, so the laptop's keyboard
    page fell back to the trackpad every time, 0.6 s in). Now a field hidden by an ancestor
    (alpha 0, hidden) never takes the keyboard, a resign inside the field's own
    `becomeFirstResponder` (asked twice) is no loss, "gone" is never declared while another
    field of the page holds the keyboard (`current`), and a field leaving the window hands the
    keyboard to one still there (`all`). `MacInput.hideKeyboard` is what every keyboard-gone
    path calls.
  - *The room (Sameer: "make sure the app is appropriately taking advantage of the additional
    screen space inside"):* on the inner screen every place in Send to has its name under its
    icon (`QuickControls(named:)`, `PlacesLook` 68 × 62 cells — the row reads at a glance, and
    Open… at its end); a sheet is a form in the middle of the screen (`InnerScreenSheet`:
    `presentationSizing(.form)`, the Mac Controls panel `.fitted`, iOS 18+ and only while the
    pose is inner — the cover and every other iPhone keep their sheets); the laptop's deck with
    nothing watched lays Send to and the mic side by side (the stack of top bar, panel and mic
    overflowed a 320 pt half). The window already fills what each pose gives it; Sound, Mac
    Controls, zoom out, Window, Pan | Scroll are visible in every header; Whole Screen, Mac
    Controls, Refresh and ⋯ are round buttons on the panel.
- **The fourth pass (the QA walkthrough, the same day — Sameer: "make sure the app is
  appropriately taking advantage of the additional screen space inside"):**
  - *Send to on the inner screen is a grid* (`PlacesLayout.grid(gutter:maxRows:)`,
    `QuickControls(layout:options:)`): every open app in view with its name, Clipboard, Where I'm
    typing and + among them, in rows that wrap (`FoldFlow`, a `Layout`: cells of one size, left
    to right; given a `gutter` — `DuoLook.creaseBand`, the fold's band — no cell sits across the
    middle of the width, so the crease reads as the gap between two columns). Open upright it
    spans the width under the window; the rail and a folded deck with nothing watched take it
    three or four across, `maxRows` before it scrolls (as tall as its rows, then an edge fade —
    a scroll view would otherwise take whatever the deck below it left). A cell is a set width
    and as tall as its name — "Where I'm typing" takes two lines, never "…". Open upright, Send
    after pasting and Cleanup leave the panel for a small panel of their own on the left of the
    band under it, level with the mic (`optionsPanel`), so the band balances: the two switches
    left, the pages, the Thread and the mic right. The phone's panel is untouched.
  - *The answers never cover the question* (`WatchWindow(footInset:)` → `ViewerScrollView
    .footInset`): what floats over the picture's foot — the answers, on the open screen and a
    folded half — is the viewer's bottom inset, so the picture's newest lines sit above the
    chips (the view's visible height is the bounds less the inset: the fit, the fill, the
    centring and the bottom all use it; the zoom-out shows the whole window above them). The
    floating row wraps (`FoldFlow` again): three long answers take two rows, not three; one
    longer than the row wraps its words. The words you're saying still go over the picture.
  - *A first-run tip on the inner screen is a strip under the window* (`WatchTipCard(inline:)`:
    the symbol, "TIP 1 OF 6 · the title", the words whole, Next and ×), between the picture and
    the key row — never a card over the picture's text; a folded half shows no tips, as before.
  - *A window that can't fill a folded half* (`DuoMacHalf.shortPicture` — one the Mac can't
    reshape, or hasn't yet; the whole screen; the demo on the book's tall page) sits at the top
    at the width-fit scale times the fill's cap (`ViewerScrollView.fillCap`, 1.8), the header
    above it with room of its own (never over its first lines), and the room under it holds the
    answers with Esc · Keys and Pan | Scroll (the phone's column), or the keys, and the words
    you're saying (`DuoLiveWords(below:)`); the glance there puts its bar under the picture
    (`DuoGlance(pictureHeight:)`, Show it here on its own line when the page is narrow). No
    black above or below. A window the Mac does reshape fills the half as before.
  - *A folded deck's mic page is a laptop's* (`carousel(rowHidden:)`): the mic a size up
    (`DuoLook.deckMic`, 112 — the glyph and the ring grow with it, `MicButton(size:)`), the
    Thread across the half in a 96 pt slot with the room over it for the pages' cluster
    (`DuoLook.deckThreadTop`; more on the book's tall page, so the Thread and the mic sit
    together in the middle of the page — the mic page aligns to the Thread, not the room's
    middle), the status line in the body size (`StatusLine(font:)`). The laptop's deck with
    nothing watched puts the top bar over the mic on the right, so the grid on the left has two
    rows of room.
  - DuoUITests' portrait test now checks that Send to spans the screen and that no place sits
    on the fold's line. Frames: `docs/screens/duo/<pose>/` again, before | after sheets each.
- **Needs a real Duo:** the hinge's angle range and update rate (the deck's rise is tuned to
  165°→120°), the division region's frame and margins, which display the scene lands on when
  folding, the inner keyboard's height in the laptop pose (the deck is ~320 pt; the bar + keys
  should cover it, not the Mac — the stand-in says they would at 216 pt), whether a SwiftUI
  touch over the window's UIKit viewer reveals the header on hardware as it does on the
  simulator, the Mac's picture at the inner screen's size (the stream is already up to 2,560 px
  wide; `watchShape` carries the view's points — nothing on the Mac changes), and a real Mac
  window taking the half's shape (the demo can't); the inner screen's size class (a form sheet is
  a form only in a regular width — on a compact one `presentationSizing(.form)` is a plain
  sheet, which is no worse than before); whether UIKit asks the delegate again for the
  orientations when the scene moves between the displays (`setNeedsUpdateOfSupportedInterface
  Orientations()` is called on the pose crossing the fold, in case it doesn't); the keyboard on
  the open poses (it avoids as on the phone: the window moves up over it).
  The frames are taken by `DuoShotsTests` (`TEST_RUNNER_MACROPHONE_DUO_SHOTS=<dir>`, and
  `…_DUO_REGULAR=1` for the regular iPhone's) — in Xcode 27 the simulator has no window of its
  own and `simctl io screenshot` returns the dark inner display, so `XCUIScreen` is the one way
  to the cover's pixels. Turn `settings.agentAlerts` off on the simulator first (`simctl spawn
  <udid> defaults write com.sameer.macrophone settings.agentAlerts -bool false`): the demo Mac's
  question raises a banner over the frame's top.

## The Duo, done properly: the cover's vertical bar and the mini MacBook (Oct 30–31 2026)

Sameer, on his Duo: "None of the controls have been put in the side bar … lots of empty space …
make the app easy to use with one hand", then "nail the laptop fold view … make the duo function
like a mini laptop … the app picker [doesn't] need to always be on the screen when unfolded".
This section wins over the four passes above where they differ.
- **The cover is not a wide phone.** Its usable area is **382 × 653 pt**: the status bar turns
  into Apple's **vertical bar**, an 84 pt column on the camera side (trailing on his phone; it can
  flip). Only real toolbar items go in it, so on the cover MainView sits in a `NavigationStack`
  (`coverBody`, `UI/CoverBar.swift`) and the buttons are `ToolbarItem`s. The cover is spotted by
  `UITraitCollection.verticalBarEdge != .unspecified` (`VerticalBarProbe`, iOS 27.1), never by
  width (a `> 440` check never fired on hardware). At rest the bar holds Mac (`CoverMacItem`, the
  pill's tap) · History · Settings, then (`.bottomBar`, nearer the thumb) Whole Screen · Mac
  Controls · ⋯ (Refresh, photo, file, clipboard) **[the ⋯ superseded Nov 7 2026, round 2: Attach by the cover's Dock]**; watching it holds Done (`visibilityPriority(.high)`,
  it never folds into the overflow) · Sound · Mac Controls · Pan|Scroll · zoom out · Window.
- **Cover, at rest:** no Mac pill row while connected; Send to's name on one line, the places as a
  named grid (`QuickControls(cover:)`, three rows), Send after pasting and Cleanup on one row; the
  Thread and the mic under the thumb. **Watching:** the window's name floats over its corner (still
  the window menu); answers are one sideways-scrolling row of chips (`WatchActions(oneLine:)`) and
  the key row steps aside while they show; the mic row is ⌨︎ · mic · trackpad (no page row; the
  trackpad page gets 116 pt more, sits 16 pt in from the sides, and has its own row under the plate —
  ⌨︎ · "Two fingers scroll" · ✕ where the mic row's keyboard and trackpad were, `InputCarousel(trackpadBar:)`,
  `TrackpadBar`; Oct 31: "there's no way to close the trackpad", and a mic in its middle that only went
  back was "useless"); the carousel clips its pages at the sides only (`SidesOnly`), so the mic's glow is
  never cut; **the pages never set the carousel's width** (`PagesLayout`: the room offered does — on his
  Duo a page measured wide on the first pass and the carousel kept that width, the trackpad ran off both
  sides and the keyboard's button sat off screen); **one `MicButton` in every state** (MainView's mic
  page: a hold flips the cover to the live words, and two branches made that a new button mid-press, so
  the release was lost and the mic stayed open — `DuoShotsTests.testCoverMicHold` fails on the old code);
  the area above the mic is clipped at its foot only (`FootOnly`), so the window's glow spills under the
  vertical bar instead of being cut into a box, and the answers' one-line row masks its own sides (a
  fade at the far end) so it never runs under the bar; on a short screen the recording clock has its own
  line under the Thread while the mic is open (`MainView.timerLine`); keyboard up: no name, no row,
  the Mac's keys in **one row** on the keyboard (`MacKeyboardBar.oneRow`, the cover's keyboard is
  466 wide), the bar flush on the keys (`safeAreaRegions = []`). Tips are the inline strip.
- **The hide button froze the app** (Oct 30): `KeyboardTextView.applyFocus` resigned the keyboard
  inside SwiftUI's `updateUIView`; the keyboard's tracking re-rendered the same graph and
  AttributeGraph spun in a cycle (`sample` on the simulator's process showed it). The resign is now
  on the next run-loop turn, like taking the keyboard always was. Never resign or become first
  responder synchronously from `updateUIView`.
- **The mini MacBook** (`UI/DuoLaptopDeck.swift`, deleted) **[superseded Nov 1 2026 on the laptop: its deck is one mode at a time, each the whole half; superseded Nov 7 2026 (round 3) on the side page too — one deck on every inner pose, below]**: while a window shows on the inner screen the
  deck is a laptop's lower half, all at once — Send to as a menu (every open app with its icon; a
  pick shows its window), the Thread and the mic on the "palm rest", the trackpad in the middle,
  keycaps on the right **[superseded Nov 7 2026 on the column: a Keyboard button and a Mac Keys toggle; keycaps only with it on]** (esc ⇥ ⌫ ⌨︎ · ⌘ ⌥ ⌃ ⇧ lit when waiting · return · fn and the inverted-T
  arrows with half-height ▲▼, repeating while held). Across on the laptop's deck and under the
  window open upright (270 pt; it folds away while the keyboard is up); down a column on the
  book's page and the open screen's rail. The deck keeps the input page on the trackpad (the
  pointer always live; ⌨︎ raises the keyboard, hide comes back). The grid of places shows only
  when no window does (the open poses at rest, the glance). `WatchPanel(deck:)`: Pan | Scroll in
  the header, no key row.
- **Three fingers on the trackpad** (`TrackpadTouchView.onThreeSwipe`, `MacInput.threeFingerSwipe`):
  up Mission Control (⌃↑), down App Exposé (⌃↓), left the desktop to the right (⌃→), right the one
  to the left (⌃←) — once per sweep, a soft haptic and the name over the window.
- **The Thread rolls** (`Filament.restingWave`, `waveSpeed` 2.5 rad/s): the crests travel left to
  right at rest (one about every 2.5 s), faster and taller with his voice, and while sending.
- **Testing the cover without his phone:** the Duo simulator has the vertical bar too.
  `DuoShotsTests.testCoverFrames` (`TEST_RUNNER_MACROPHONE_DUO_COVER=1`, with `…_DUO_SHOTS=<dir>`)
  shoots it as it really runs (no frame, no forced pose); turn the tips off first (`simctl spawn
  <udid> defaults write com.sameer.macrophone watch.tips.seen "click,input,keys,scroll,swipe,zoom"`).
  On his phone `xcrun devicectl device capture screenshot --device <udid> --destination x.png`
  takes the real cover — but launching the app there takes his phone from him; ask first.

## The window takes the view's shape; the laptop is the picture alone (Oct 31 2026)

Sameer: "when an app is opened or the view window dimensions is changed the app should default to
resize to fill the view window. This should not be true for temp view window changes such as when
the keyboard or trackpad are opened", then on the laptop: "the view window fully filling one half",
"the hot keys to all be the bottom half … so that nothing blocks the view window", "the trackpad to
take up a big portion of the bottom half … enable all the Mac multi finger track pad gestures".
This wins over the older sections where they differ (fitNextOpen, followShape, applyHalfFit, the
laptop's overlay header and floating answers are gone).
- **Auto-fit** (`Watcher`, "The window takes the view's shape"): every window the view opens (a
  switch too) and every pose change (`poseSettled`) owes a shape (`wantsAutoFit`); it's sent 0.5 s
  after the view stops changing (`autoFitSoon` → `applyAutoFit`, `sendShape`), only with the view
  **at rest** (`viewAtRest`: not the keyboard page; not the trackpad except on the inner screen,
  where the deck is a trackpad all the time; only the interactive window measures —
  `viewerMeasured(_:fill:interactive:)`, so the mic's strip and the glance never count), never the
  whole screen, folded only from the half's own measure, and not when the aspect moved < 4%. A
  page change back to rest sends a shape still owed (`MacInput.show` → `inputPageChanged`).
  **The viewer's zoom holds for the keyboard too** (Nov 4 2026, Sameer: "I don't want the window
  to auto zoom when I open the keyboard"): while the keyboard page is up, and for a second after,
  a change of the view's height alone keeps the zoom and the spot (the bottom if it showed) —
  `ViewerScrollView.keyboardUp` / `keepZoom`; every other size change re-fits as before.
  **And the window moves once when the keyboard comes or goes** (same day: "the window jumps up
  and down too much"): what the keyboard replaces — the carousel's room and the Thread, the key
  row, the cover's name (`bare`) — follows `MacInput.keysUp`, set from keyboardWillShow / WillHide
  heard with no queue, so it lands in the keyboard's own animation pass. Until the keyboard rises
  the keyboard page keeps the trackpad's room. Before, the window shrank by the keyboard's height
  and then grew back by the room under a spring of its own (logged: 520 → 306 → 380 pt; now
  520 → 380).
  He sizing it himself (a Window menu size, a text size) stops it until the next window
  (`sizedByHand`); **Back to How It Was or a text size keeps that app's own size from then on**
  (`watch.ownSize.<bundle id>`, or a remembered `watch.fit`); Fit to iPhone clears that. A window
  shaped by itself **goes back as it was** when the view leaves it (`putBackAutoFit`: `.restore`
  sent before the next watch / `watch(nil)`; the Mac's `beforeWindowChanges` already holds the
  frame) — one he asked Fit to iPhone for stays (`askedForFit`). Proven against `mpctl serve`
  (which now prints `WATCH SHAPE <aspect>`): one shape at open, none for the keyboard, typing,
  the trackpad or the mic, `WATCH WINDOW restore` on Done.
- **The laptop** (`DuoMacHalf`, `!vertical`) **[the deck is superseded Nov 1 2026: modes, the answers on a row of their own; the picture alone above stands]**: the top half is `WatchWindow` alone, edge to edge — no
  overlay header, no floating answers, no live-words card, no short-picture layout. The deck
  (`DuoLaptopDeck(menuBar: true)`, `laptop`): `WatchHeaderBar` across the top (always there, never
  fades) with the question's answers in its middle (`WatchHeaderBar(middle:)` ←
  `WatchActions(floating:oneLine:)`, one sideways-scrolling row), then Send to + the mic (112 pt,
  no Thread) · the trackpad (no inset of its own — `TrackpadPage(inset: 0)`; ~590 × 240 pt) · the
  keys. While the mic is open the words (`DuoLiveWords(below:)`) take the trackpad's place. The
  book is unchanged (its overlay header and floating answers stay).
- **More trackpad gestures** (`TrackpadTouchView.onGesture`, `MacInput.trackpadGesture`): two
  fingers pinching = ⌘= / ⌘− a step per 25% (a pinch is decided as the fingers leave the slop:
  the spread changing more than 1.5× the midpoint travel, and > 18 pt; a posted magnify gesture
  isn't something a Mac takes); three fingers tapped (< 0.5 s, none moved) = Look Up ⌃⌘D; four
  fingers spread 40% = Show Desktop (F11); four fingers sweeping = the three-finger sweeps. Each
  says its name over the window with a soft haptic.

## The Duo at its real shape: the cover goes on, the laptop is a little Mac (Nov 1 2026)

Sameer, on his Duo: (1) "The app selector looks bad, especially on the front screen as there
weird empty space on the right … more compact and take the design to the next level"; (2) "When I
am on this selector screen and open the phone, the app is not taking up the full screen … the view
that is on the out screen should be what I see on the right half on the open duo screen with more
content on the left side"; (3) "it's all about consistency … the same toggles in the side bar …
The only thing that changes is that there is now more to view"; (4) "in laptop mode the trackpad
is really small … select mic mode, keyboard mode to trackpad mode and have each of those modes
take up the full half"; (5) "in laptop view the view window should take up the whole top half …
Almost as if the duo was a mini Mac." This section wins over every Duo section above where they
differ. Frames: `docs/screens/duo/nov1/` (before | after sheets per pose and the cover).
- **The screen's real shape** (from his phone's diagnostics log — `pose: laptop (105°, 669×835)`,
  `book (174°, 867×635)`, `landscape (180°, 867×635)`, `portrait (180°, 669×835)`, `closed (180°,
  951×553)`): the inner screen is 669 × 951 with **the fold along the middle of its long side**,
  so a half is the cover's size (475 × 669). Upright the fold runs *across*: the laptop, and flat
  portrait. On its side it runs *down*: the book, and flat landscape — the phone's natural way
  open, the cover becoming the right half. Every pass before had the laptop 951 wide (halves of
  951 × 320 — impossible) and the book 669 wide, and every frame with them. Now: `FoldPose
  .foldAcross` / `.hasVerticalBar` (the vertical bar, 84 pt on the camera side, is there on the
  cover, the book and flat landscape; upright the inner screen has a status bar on top instead),
  `derive`'s no-region fallback flipped (upright folds as a laptop), `FoldPoseTests
  .testTheFoldLiesAlongTheLongSide` with the log's numbers. **The simulator's frames** are
  `MACROPHONE_FRAME=669x951` (the laptop, portrait) and `951x669` (the book, landscape) with the
  bars stood in for (`DebugHooks.frameInsets`: on its side trailing 84 + bottom 34 → 867 × 635;
  upright top 82 + bottom 34 → 669 × 835 — which of the 116 is which needs a real Duo; plain
  padding, not `safeAreaPadding`, which a NavigationStack's content took back; and on a barred
  pose no trailing padding at all, since a NavigationStack inside a frame draws its own ~82 pt
  vertical bar with the items in it — the stand-in for the system's) and the forced fold at the
  *screen's* middle (`Posture.recompute`), inactive when flat so `foldLine` is known. A layout
  splits its *own* measure at the fold (`Posture.halves(for:in:)`), never the scene's.
  "Not expanding" (2) was `FoldReading.screen` (the whole screen says which screen; commit
  8f02801); the rest of (2) and (3) is the layout below.
- **One rule for every inner pose: the half that was the cover goes on being the cover, and the
  other half is the Mac** (`UI/DuoView.swift`, `MainView.poseBody`). Nothing in hand — the phone
  just opened, or Done — the cover's half shows `phoneBody` whole (Send to, Send after pasting
  and Cleanup, the Thread, the mic; the vertical bar's buttons where the screen has one, its own
  top bar where it hasn't) and the Mac's half the glance (the picked app's window live, Show it
  here). Flat on its side: the glance on the left page, the cover on the right (`openLandscape
  Body`, split at `Posture.foldLine`; `DuoLook.rail` 377 is only the fallback without a line).
  Flat upright and the laptop are **one layout** (`laptopBody`, `Posture.halves(for:in:)` — the
  real halves folded, the inactive fold's line flat): the Mac above the fold, the cover's view
  below; folding moves nothing. The book: the Mac on the left page, the cover on the right. In
  hand: the laptop's modes (below) or, down a page (the book, flat on its side), the
  `DuoLaptopDeck` column (its `band` across is gone). `openWindowForPose`: opened **flat** the
  window is the glance; **folded** (the laptop, the book) it comes in hand at once — and folding
  while glancing takes it in hand (`poseChanged`). The old open-upright layout (the grid across
  the width, `optionsPanel`, `sendToPanel`, `lowerPanel`) is gone.
- **The same bar on both screens (3)** — `MainView.barUsed` = the vertical-bar trait *and* a pose
  that has one (on the simulator the inner screen is a frame on the cover, whose trait would
  otherwise speak for every pose): the cover, flat landscape and the book are `barred` — one
  NavigationStack, the same `coverToolbar` (Mac · History · Settings; Whole Screen · Mac Controls
  · ⋯; watching: Done · Sound · Mac Controls · Pan|Scroll · zoom out · Window), the window's
  header name-only (`controlsInVerticalBar`). Upright (the laptop, flat portrait) draws its own:
  the deck's header carries the clusters and Done, `phoneBody` its top bar. `quickControls` is the
  tile grid on every Duo screen (`barUsed || pose.isInner`).
- **The laptop is a little Mac (4, 5)** (`laptopBody`, `DuoMacHalf(edge: true)`, `DuoDeck
  .laptopModes`): the top half is `WatchWindow` with **no bezel and no corner** (`bezelWidth` 0,
  `corner` 0 — `DuoGlance(edge:)` the same at rest), filling the half (`fill`; auto-fit gives the
  Mac's window the half's shape, so a window the Mac reshapes has no bands; the demo's fixed
  1400 × 900 fills a 669 × 393 half by zoom), **the status bar hidden while a window is in hand** **[superseded Nov 7 2026: only full screen hides it — see Overnight polish, round 1]**
  (`.statusBarHidden`, folded or laid flat; the frame gives its top 82 back then — whether the
  real screen does, with the camera on that edge, needs a real Duo), nothing over it. The deck: `WatchHeaderBar` across
  the top (name, Sound|Mac Controls, Pan|Scroll, zoom out|Window, Done — never fades), **the
  question's answers on a row of their own under it only while one is up** (in the header's
  middle they had room for one digit at 669 pt), then **one mode at a time, the whole of the
  rest** — the trackpad edge to edge (~645 × 330), the mic with the Thread across the half, or
  the iOS keyboard with the Mac's keys on its bar — picked by the `InputCornerSwitcher` cluster **[superseded Nov 7 2026: `DuoModeBar`, a labelled Trackpad · Mic · Keyboard control]**
  overlaid in the deck's top-right corner (it had been written and never placed: the modes had
  no way between them). The deck remembers its mode (the trackpad first; `MacInput.deckPage`).
  While you talk the words sit over the Thread (`DuoLiveWords(below:)`); the mic never moves.
- **The cover's picker (1)** is commit 8f02801's `PlacesLayout.tiles` (icon-only tiles in even
  columns across the width, five on the cover and nine on a 669 pt half, the pick a lit plate
  that slides — `PlaceTileStyle`), now seen: no hole on the right, two rows for nine places.
- **Tests:** `DuoUITests` rewritten for the real shapes (the laptop: every mode takes the deck,
  the trackpad ≥ 80% of its width, a pinch zooms, typing reaches the Mac, Done leaves the glance
  with Send to under the fold; the book's column on the right page; flat upright and on its side:
  the glance in the Mac's half, Send to and the mic in the cover's, nothing on the fold).
  `DuoShotsTests` shoots every pose's `0-rest` and uses a 300 pt stand-in keyboard upright.
- **Needs a real Duo** (added to the list above): the top inset upright with the status bar
  hidden (82 pt back, or a camera's cutout kept); which of the 116 upright points is the top;
  the iOS keyboard's height on a 669 pt-wide portrait screen (the deck's mode area is ~390 pt);
  `verticalBarEdge` on the inner screen on its side (assumed trailing, as on his cover) and that
  it is `.unspecified` upright; the fold's region frame flat (`.includeInactive`) — the flat
  layouts split at it and fall back to the middle.

## Full Screen on the Duo on its side (Nov 3 2026) **[superseded Nov 8 2026: every screen — upright inside, the cover, every iPhone; the button in the header or the vertical bar — see "The window is the app"]**

Sameer: "a full screen button … next to the window selector … the window take up the entirety,
edge to edge … the window should resize to fill the screen … if it's the Mac display, it should
just fill the screen". On the inner screen on its side (flat landscape, the book —
`Watcher.allowsFullScreen`), a glass button beside the window's name (`WatchHeaderBar
.fullScreenButton`, shown where `\.fullScreenAvailable` is set; `watch-fullscreen`) calls
`Watcher.setFullScreen(true)`: `MainView.poseBody` draws `DuoFullScreen` instead of the pose's
layout — `WatchWindow(fill: true)` edge to edge, no bar, no status bar, no home indicator — and
one exit button in the top-left corner that fades after 3.5 s and comes back on a touch
(`watch-fullscreen-exit`) **[superseded: beside the mic, Nov 4; never fades, Nov 7 — below]**. Entering or leaving re-arms auto-fit (`poseSettled`), so a window takes
the screen's shape (`WATCH SHAPE 1.42` on the sim) and goes back to the page's after; the whole
screen fills rather than showing whole. The pages go to the mic (no pointer without the deck).
Ends on Done / the glance / close, and on a pose that doesn't allow it. **The mic floats** (`FloatingMic`, Sameer: "make it small and give me a little lip on it so I could drag and move anywhere"): the same `MicButton` at 52 pt with a glass grab tab on its top edge — the disc keeps tap and hold, only the lip drags it; it stays where it's left (`duo.fullscreen.mic.x/y`, fractions, bottom-right first), clamped clear of the rounded corners; never fades. **In full screen a dictation goes to Where I'm typing** (Sameer: "it should default to pasting wherever the cursor is"): `AppModel.startRecording` gives it a `.frontApp` override unless something else asked for a place (a Shortcut); the Send to pick is untouched, and Show the app after sending stays put. It pastes, never sends. **And Where I'm typing never refuses** (Mac 1.1.3, `Paster`'s `.front`): a focused element that doesn't read as a text field still gets ⌘V — Claude's search names the highlighted row of its list as focused while the caret is in the box; `Paster.nearestInput(around:)` finds that box (up to its dialog) only to read the words back. Password fields are still refused. **A hold brings a trackpad** (Sameer: "press and hold … a see through track pad should appear there quickly … dissolve away after like 5 sec of no interaction"): in full screen a hold on the picture (`WatchWindow(onHold:)` → `ViewerScrollView.onHold`, ahead of the right-click — two fingers still right-click) puts a 340 × 220 frosted `TrackpadSurface` centred under the finger (kept on screen) and the trackpad page up (the pointer shows); the finger that held drives the pointer at once, no lift (`onHoldMoved` / `onHoldEnded`, the hold's own moves in the window's space); any use of it (`TrackpadSurface(onUse:)`) or a finger still down keeps it, 3 s with none dissolves it and the pointer goes (`DuoFullScreen.summonPad` / `dismissPad`; `MACROPHONE_FULLSCREEN_PAD=x,y` for a shot; `FullScreenUITests` — a Duo sim opened flat, paired with `mpctl serve`). Hook:
`MACROPHONE_WATCH_ACTIONS=…,fullscreen,windowed,record,stoprecord` (with `MACROPHONE_SIM_RECORD=<words>`; `mpctl serve` prints `RECEIVED → Where I'm typing`).

**The mic's two buttons, always there (Nov 7 2026).** Sameer: "the zoom out toggle next to the mic
was there permanently and not conditionally so that users don't struggle to figure out how to close
the screen", and "a trackpad button to the right of the mic button to temp transform the mic into a
track pad. Press and hold trackpad should still work". `FloatingMic(exit:trackpad:)` is a trio:
**exit on the disc's left** (`watch-fullscreen-exit`, unchanged label) and **Trackpad on its right**
(`watch-fullscreen-trackpad`, `rectangle.and.hand.point.up.left`, a toggle: label "Trackpad", value
On / Off — XCUITest lists it as a switch), both 40 pt glass, level with the disc, always the same way
round; they hide only while the lip is dragged. No fade at all (the reveal timer and
`DuoLook.headerHold` are gone). `place` clamps the whole trio on screen (half-width
`gap + 20` = 79 pt from the disc's centre), so at an edge the mic sits in by that much. The
trackpad button calls `summonPad(at:held: false)` with `DuoFullScreen.padSpot`: the same 340 × 220
pad centred over the mic, clear of the lip and the Undo chip (under the disc when there's no room
above), kept on screen; lit (white on the accent) while it's up; a tap again or 3 s unused puts it
away. Hidden when the Mac has no trackpad page; disabled while the words show. The hold is
untouched. Hook `MACROPHONE_FULLSCREEN_TRACKPAD=1` (the button's pad 2 s in).
`FullScreenUITests.testTheTrackpadButtonAndThePermanentExit`. Frames: `docs/screens/duo/nov7-fullscreen/`.

## Opening without a stutter (Nov 3 2026)

Sameer: "when I open the app or switch view, elements seem to briefly stutter or glitch before
correcting … specifically when I open the app". Found frame by frame (`simctl io recordVideo
--display=<the Duo display's uuid>`, ffmpeg `mpdecimate` to the distinct frames, tiled):
- **The launch screen** was near-black in light mode, then the app faded up: `LaunchBackground`
  has light (#F2F2F7) and dark (black) now. SpringBoard caches the launch image — a simulator
  needs its app's `Library/SplashBoard` cleared and a reboot to show a new one.
- **The first frames had no vertical bar** (the probe reported after the first draw, the phone's
  layout jumped to the bar's): `MainView.verticalBar` starts from `VerticalBarProbe.atLaunch`
  (the scene's trait, read before anything is drawn).
- **The stand-in sky, then the Mac's wallpaper**: `WallpaperStore.useMac` loads the kept picture
  synchronously the first time (before the first frame); later ones still decode off the main thread.
- **The cover's Mac pill popped in and out** while the link was made: `AppModel.settling` (2.5 s
  after the app becomes active) — not connected yet isn't news then.
- **The bar's lower buttons arrived one by one**: what the Mac offered when last connected
  (`bar.had.wholeScreen`, `bar.had.controls`) stays in place, dimmed, until it's connected again.
- **Opening a window / Done slid Send to down and up** under the fade (the mic row changes size):
  the settings layer keeps the height it had while it showed (`settingsRoom`), its layout isn't
  animated with `watcher.isShowing`, and it fades out in 0.1 s, back in on the settle spring.

## Opening fast: the last picture, the last address, one word (Nov 3 2026)

Sameer picked three of the smoothness ideas: "show the last picture right away", "connect faster",
"one connecting message".
- **Each window's last picture** (`Model/WindowSnapshots.swift`): kept per Mac and per place
  (app + window number, hashed; in Caches, ≤ 1,280 px, JPEG 0.6, never leaves the phone) when a
  watch switches away, closes or pauses, and every 30 s while live (`Watcher.keepPicture` — video
  through `VideoCanvas.displayedFrame()`, the renderer's `displayedPixelBuffer`, iOS 17.4+).
  `Watcher.lastPicture` is loaded on open and drawn dimmed in `WatchWindow` under the viewer
  until 0.5 s after the first frame (the video layer draws a moment after it's handed one — the
  plate never shows bare); the Duo's glance treats it as a picture (its shape, its bar), and while
  the Mac connects at launch (`model.settling`) shows the pick's kept picture laid out exactly as
  the live glance will be, "Connecting to ‹Mac›…" in the bar and Show it here waiting.
- **The last address** (`LinkClient`, `link.lastAddress.<mac>`): the Mac's IPv4/6 and port on this
  network from the last local session; at launch, before Bonjour has it, it's dialled beside the
  name (`Route.nearby`, `raceNearby`, unverified — the handshake proves the Mac). Simulator: first
  frame → connected 650 → 385 ms ("nearby: the last address answered first"). His phone's cold
  launch was ~850 ms from first frame to connected before.
- **One word while it connects**: `StatusLine` says "Connecting to ‹Mac›" through `settling`,
  whatever the link's state; no "Looking for", no Wi-Fi warning in the glance.

## Undo, the landed pill, fixing a word (Nov 3 2026)

Sameer picked three of the experience ideas.
- **The landed pill** (`LandedPill`, `View.landedPill()` on every mic — `MainView.micButton`,
  the Duo deck's `carousel`, the full-screen `FloatingMic`): "✓ Pasted into Claude" (the app's
  name, not the window's title — `Landing.chipWords`) rises from the mic for 2.2 s on a landing
  that succeeded; the status line stays quiet meanwhile. `AppModel.landedChip`.
- **Undo** (MacrophoneKit `Core/UndoPaste.swift`, `Transport/UndoLink.swift`, feature `undo`):
  for a paste that wasn't sent, from a Mac that names it, the pill carries Undo for 5 s **[superseded Nov 7 2026, round 2: 28 s, the `UndoChip` by the Thread, a shake, History]** →
  `.undoPaste(id)`; the Mac (`DeliveryEngine.undo`, Mac 1.1.4) undoes only its last paste, not
  sent, within 30 s (`UndoPaste.window`): the app (and window, `Paster.Result.pid`/`windowID`)
  brought forward, ⌘Z, History marked "Undone from the phone"; `.undoDone(UndoResult)` → the pill
  says "Undone" and the status line the Mac's words. `mpctl serve` answers (`UNDO <id>`,
  `--no-undo` is a Mac from before). Needs a real check: ⌘Z after a paste in Claude, Terminal
  (a terminal may not undo a paste), Notes.
- **Fix a word before it goes** (`Model/WordFixes.swift`, `FixWordCard` in `UI/MainView.swift`):
  each settled word in `LiveWords` is a link (`macrophone-fix://<index>`, drawn in ink); a tap
  opens one row over the keyboard — × · the word · Add to Dictionary · Take Out · Done — the word
  highlighted in the words (two lines kept in sight above the card). Fixes go into the final words
  before cleanup (`WordFixes.apply`: at its index if the word there still matches, else the first
  match; a taken-out word takes a space with it). The mic closing while the card is up holds the
  words (`heldOutcome`) until Done or ×. Hooks: `MACROPHONE_WATCH_ACTIONS=…,fixopen@1,fix@1@the,undo`
  (with `MACROPHONE_SIM_RECORD`).

## The window out of the Dock, the glow where words land (Nov 4 2026)

Sameer picked two of "what would Apple build":
- **The Dock icon opens into the window** (`DockSpot`, `UI/MacOS/Dock.swift`; `MainView
  .windowTransition` / `DockZoom`): the pick's icon reports its frame on screen; opening a window
  on the phone's desktop grows `WatchPanel` out of that icon (scale from the icon's width, offset
  from its middle, faded in) on the settle spring that already carries it, and Done shrinks it back
  into the icon. No Dock drawn (the Duo, the cover — `DockSpot.pick` cleared when it goes), or
  Reduce Motion: the fade as before.
- **The Mac shows where the words landed** (`Mac/App/Delivery/LandingGlow.swift`, Mac 1.1.5,
  no wire): once a paste is in (before the send key), a ring of Apple Intelligence's colours
  (`MacOSIntelligence`: blue · violet · pink · orange and back, so orange never meets blue — that
  blend reads grey) blooms round the box it went into (its AX frame, when it's a box — under
  1100 × 320) or round the caret (`kAXBoundsForRangeParameterizedAttribute` on the selection —
  a terminal, a document) and fades in 0.9 s; a borderless click-through panel on every Space.
  Nothing when there's nowhere to point. `MACROPHONE_GLOW=x,y,w,h` (DEBUG) draws it every 1.5 s.
  Needs a real check: the ring round Claude's composer, Messages' field, the caret in Terminal.

## The polish pass (Nov 4 2026)

Sameer: "still pretty stuttery with window resizes as you open the app … go through it all in great
detail … every detail considered … no detail is too small". Part 1 (this session), then three
agents (the cover, the regular iPhone, the inner screen) each with their own section below.
- **A window opens at its shape:** the phone sends its view's shape right behind the watch
  (`Watcher.shapeAhead`, when the view was measured in this pose before), to a Mac naming
  `WatchShape.aheadFeature` ("fitPhoneAhead", Mac 1.1.6); the Mac keeps it until the window is
  found (`Watch.wantedShape`) and reshapes it before the first picture (`look`, as Aa's sizes),
  so the phone never sees it at its own size and then jump. A reshape mid-watch (a fold, a turn)
  holds the frames until the size settles (`VideoPipe.holdForReshape`: 0.3–0.9 s, then the settled
  one at once).
- **Launch:** `RootView` hides the main view until it has a real size and lets nothing animate
  for its first 0.7 s — the first frames had been laid out at almost no size and the settle
  spring grew the window, the Dock and the mic out of the corner.
- **The kept picture on the first frame** (`WindowSnapshots.cached`, a small memory cache).
- **One mic:** `matchedGeometryEffect(id: micID, in: micSpace)` on both mic buttons, so a layout
  change moves it rather than cross-fading two. **Hand-overs:** `AnyTransition.handoff` (what
  leaves goes in 0.12 s, `Motion.leave`) between the Duo's layouts. The flat upright inner
  screen's window grows into hand on the settle spring. The focus re-crop glides.
- Hooks: `MACROPHONE_WATCH=rest` + actions `open`, `close`, `pick@<app>`, `sheet@…`.

## iPhone polish (Nov 4 2026)

The regular iPhone's pass (the Duo's cover and inner screen had their own), walked frame by
frame on an iPhone 17 Pro simulator against `mpctl serve`, light and dark, and at the SE's size.
`regularPhone` (MainView) = not `barUsed` and not an inner pose: what's below changes nothing on
the Duo unless it says so.
- **The keyboard page moves the window once, both ways.** The safe area SwiftUI gives the keyboard
  and `MacInput.keysUp` came in different passes, a sixth of a second apart: rising, the window
  shrank to a sliver and grew back; going, it grew, shrank under the key row and grew again, and
  the page row's words and glyphs came apart. Now the regular iPhone ignores the keyboard's safe
  area on the mic screen (`phoneBody`, `.ignoresSafeArea(.keyboard)`) and lays the room out
  itself: `MacInput.keyboardRoom` (from `keyboardWillChangeFrame`, heard by an observer made in the
  app's `init` — `MacInput.listenEarly`) changes with `keysUp` in one bounce-less spring over the
  keyboard's own time, and the carousel's keyboard page is that tall (`InputCarousel(keyboardRoom:)`).
  The page row draws as one picture (`.drawingGroup()`) and its lit page changes at once.
- **Fixing a word:** the keyboard covers the mic as it would any screen and `FixWordCard` rides
  on it (an overlay on `phoneBody`, `LiveWords(cardInline: false)`); the whole screen used to
  shove up, the Thread squeezed flat. A fix lands without a cross-fade (both versions of the
  re-flowed line were drawn over each other).
- **The window steps aside for the words in place** (`windowViaDock`, set off at the mic's touch
  while a window shows): it had shrunk into the hidden Dock as the mic opened and grown out of it
  after. Done still goes into the Dock.
- **The landed pill is said once:** the status line no longer repeats "Pasted into …" when the
  pill leaves (`AppModel.pillSaidIt`). While the mic is open over a window the page row stays in
  its place, faded, and takes no tap or swipe (`InputCarousel(rowDimmed:)`) **[superseded Nov 7
  2026, round 5: the phone draws no page row; `rowDimmed` now only stops the swipe]**.
- **The Dock:** the pick's name stays on the visible shelf over an icon at either end, scrolled
  or not (it was cut: "alendar"); a pick's old name goes at once (two labels garbled together).
- **The menu bar:** a long Mac name ends in "…" (it pushed the bar past both sides and lost
  Settings); Whole Screen and Mac Controls hold their places, dimmed, while the Mac connects
  (`bar.had.*`, as the cover's bar does), and the display glyph keeps last time's shape
  (`MacReach.looksSeveral`).
- **The window's header** fits "Terminal" on an SE (tighter gaps under 380 pt); the trackpad no
  longer shows Newest the moment it comes up (`keepPointerInView` moves the view only for a
  pointer near an edge); the panel overflows downward, never under the status bar.
- **The listening edge** (`EdgeGlow`) draws its colours masked by the edge rather than stroking
  the whole screen with a gradient (`SpecularEdge`'s finding): the app at 87% CPU while the mic
  listened, 13% after (simulator). The Pan | Scroll pill's and the lit answer's rims the same way.
- Pairing the first Mac keeps "Pair Your Mac" as the title through to the success page.
- Left: on an SE a long Mac name is down to a few letters beside four extras; the Send after
  pasting bar reads "Send" on a Pro (the full words don't fit beside Cleanup's level); the
  simulator's first keyboard of a launch comes up late, so the first rise is the roughest.

## Inner screen polish (Nov 4 2026)

The inner screen's part of the polish pass, walked on a real Duo simulator (`duo-sim.sh pose`,
every pose and every change between them, light and dark) against `mpctl serve`, frame by frame
(`simctl io recordVideo --display=<inner>`, ffmpeg `mpdecimate`). What Sameer's screenshot showed —
flat upright after Done, the picture running up under the bar and down past the fold over the Dock,
the Thread and Show it here — was WatchWindow's kept picture: aspect-filled in a flexible frame, it
made the whole window its own size whenever it was taller than the room (a window auto-fitted to the
in-hand deck, then shown in the shorter glance). Fixed in WatchWindow by the cover pass (fd1259e:
the kept picture goes through the viewer). Repro: flat portrait, `MACROPHONE_WATCH=rest
MACROPHONE_WATCH_ACTIONS=show,fit@largest,done,show,close`, then launch flat portrait again.
- **One bar for every inner pose** (`MainView.innerBarred`, `innerLayout`): the pose's layout
  changes inside one NavigationStack; the stack never does. A stack per pose (and none on the
  laptop) made every fold a new stack, which laid its content out from nothing — the window and the
  mic grew out of the corner as the laptop opened flat. Where the pose has no system bar (the
  laptop) the toolbars are hidden (`.toolbar(.hidden, for:)`), and `controlsInVerticalBar` follows
  `barUsed`. Flat upright keeps its items in the bar (Mac · History · Settings up top beside the
  clock, Whole Screen · Mac Controls · ⋯ at the foot **[the ⋯ superseded Nov 7 2026, round 2: Attach is by the Dock]**; Done and the window's clusters in hand), as
  Sameer asked on Nov 1 — it's the system's own bar, nothing drawn over the window.
- **The bar from the first frame on its side** (`barUsed`: on the inner screen the pose alone says
  there's a bar): opening the phone, the scene's first frames had no vertical-bar trait yet and the
  layout drew its own top bar (the Mac's pill, History, Settings) for a moment.
- **The mic is matched within one screen** (`MainView.micID`: "mic" on the cover, "mic.inner"
  inside): matched across the fold, the inner mic flew in from where the cover's had been and was
  missing for the first frames of every unfold. **[Inside, superseded by the second pass: one mic, `innerMic`.]**
- **Show it here grows the glance, Done shrinks it back** (`DuoMacHalf.screenSpace`, a
  `matchedGeometryEffect` on every branch): the glance and the window in hand are one screen, not
  one at its new size fading in over the other at its old. **[Superseded by the second pass: both are built and
  fade (`KeptHidden`); a flat upright half still grows with its frame.]** **On its side the left page stays put**
  (`openLandscapeBody`): only the right page changes (the deck or the cover's view); the whole
  spread used to be swapped, the window fading out and in with it.
- **The deck beside the window arrives with its layout** (`DuoLaptopDeck`): its own 0.5 s entrance
  on top of the hand-over left the right page empty for a beat (after full screen, after a fold).
  On Done it fades as the trackpad it was — it had flashed "Your Mac's version has no trackpad yet"
  as the pages were put away.
- **The lit rim is drawn by the GPU** (`SpecularEdge`, Theme.swift — every device): a gradient
  *stroke* is drawn on the CPU into a backing store the plate's whole size (`ripc_DrawShading` in
  `sample`): ~200 ms a draw on the watched window, on every frame of a resize. Now the gradient
  masked by the hairline. Keep it that way.
- **The book's page sits in from the screen's corners** (`edgeInset` on its three outer sides, as
  the laptop's); **the laptop's mode cluster steps aside while you talk** (it sat over the words'
  card); **Settings and History take two columns only in a regular-width sheet**
  (`horizontalSizeClass`): the simulator's sheet is compact (~650 pt on its side, though 835 is
  asked), and the collapsed split opened Settings on Send to with a back button.
- Hook: `MACROPHONE_WATCH_ACTIONS=…,show` (the glance's Show it here, `showWindowForPose`).
- **Found, not fixed (first pass):** the simulator plays its own fold animation (the folding half
  blurs and darkens, and shows the old frame under it) — not the app. The kept picture can show at
  another zoom than the live one for a frame (WatchWindow, the cover pass's). [The Show it here
  pause, the two mics and full screen's exit button: the second pass, below.]

**The second pass (Nov 4 2026, same day).** Profiled with `xctrace record --template 'Time Profiler'
--device <udid> --attach <pid>` (the exported `time-profile` table, main-thread runs grouped per
action) and measured with `MACROPHONE_HITCH=1` (`HitchProbe`, DebugHooks: each action's time to the
next display frame, logged "HITCH …"; a square at the screen's foot turns red/green the moment it
starts, so a recording shows the tap). Show it here held the main thread 370 ms the first time and
~180 ms after (on its side; Done ~130 ms; leaving full screen ~245 ms): building the deck (its
keyboard field, trackpad, keys), the window's panel (header, menus) and the cover's view each time,
and re-vending the bar's UIKit items (`ToolbarBridge` → `UIKitBarButtonItemGroup.makeVended`,
the menus' `UIKitMenuButton`), ~60–120 ms on its own.
- **Built ahead, shown by a fade** (`MainView.keptPair`, `KeptHidden`, DuoView.swift): the cover's
  view and the deck (on its side, the book, the laptop), the window in hand and the glance
  (`DuoMacArea`, `DuoMacHalf`) are all built and stay built; Show it here and Done change opacity
  (what leaves in `Motion.leave`, what arrives on the settle spring). A hidden one takes no touch,
  is hidden from VoiceOver, its Thread stops (`threadPaused` → `ThreadView.paused`), and it keeps the
  size it had when last on screen (the cover's view re-laid in a shorter deck kept that room's scroll
  offset — its top bar came back cut in half). Only the one on screen has a viewer (`WatchWindow
  (dormant:)`, `WatchPanel(dormant:)`, `DuoGlance(dormant:)`), so the video is never wanted twice; the
  one leaving keeps its viewer through its fade (`DormantAfterFade`, 0.25 s) — gone at once it left an
  empty plate fading. The cover's view on the inner screen is the rest view only (`windowHere`,
  `phoneSettings`, `InputCarousel(restOnly:)`): never the window's pages, never a keyboard field.
- **The bar changes after the motion** **[superseded Nov 7 2026: it swaps in the layout's own transaction]** (`innerBarWindow`, `barFollows`): on the inner screen the
  bar's items (Done · Sound · … or the Mac · History · Settings) swap 0.55 s after the window, once
  it has settled; a pose change swaps at once. (Hiding the bar is as costly: the laptop keeps its
  own top bar at rest, made to fit — `tightInner`: a breath less over the mic and a one-line status
  upright inside; its top bar used to be cut in half above Send to.)
- **Full screen lies over the layout**, which stays built, hidden (`innerAsleep`: its windows lose
  their viewers 0.35 s in), so leaving it is a fade, not a rebuild; the column deck doesn't force its
  trackpad page under full screen.
- **One mic inside** (`MicSlot`, `micSlot`, `innerMic` → `InnerMic`): each inner layout keeps an
  empty slot where its mic goes (the cover's view 92, the laptop's mic mode 112, the column 72) and
  one `MicButton`, drawn over the inner screen (in `innerBarred`), goes to the slot of the layout on
  screen (`micOwner`: pose + in hand or not; a layout fading out still reports its slot and is
  ignored), drawn at 112 and scaled down. It glides from a slot that showed, appears in place from
  one that didn't (the laptop on its trackpad, the keyboard up); never two. The cover and every other
  iPhone keep their own (`micButton`, matched as before).
- **Full screen's way out is beside the mic** (`FloatingMic(exitShown:exit:)`): a 40 pt glass circle
  level with the disc, on the side towards the screen's middle, fading with the screen's controls
  (3.5 s; always for VoiceOver), hidden while the mic is dragged **[superseded Nov 7 2026: always
  shown, always on the mic's left, with the trackpad toggle on its right — see "Full Screen on the
  Duo on its side"]**. In the top-left corner it covered
  the Mac window's close, minimise and zoom buttons — every Mac window has them there, and a touch
  there raised it under the finger as the tap went through to them. Beside the mic it's wherever he
  put the mic: somewhere he doesn't need on the Mac, under his thumb.
- **Numbers** (Debug, simulator, a loaded Mac; base = main before this pass, alternated in one run):
  main-thread time at Show it here 370 / ~180 ms → ~60 / 15–28 ms (first / later; the rest of each
  frame of the spring is 8–13 ms); Done ~130 → 17–30 ms; leaving full screen ~245 → ~75 ms; the bar's
  swap (~70–120 ms) now lands after the motion. `HITCH` first frame: Show it here 360–383 / 151–194
  → 48–124 ms; Done 117–144 → 39–69 ms. Recorded from the red square to the first changed frame on
  its side: Show it here 218–375 → 123–168 ms, Done 120–145 → 20–103 ms — the window's first frame
  of motion still comes 2–6 frames after the tap on the simulator: the main thread is free (the
  `sample` of the main thread shows no wait), the simulator's renderer takes that long to draw the
  newly visible glass for the first time. Needs his phone, in Release.
- **Left / pre-existing:** `DuoUITests.testLaptopPoseIsAMacAboveAndTheDeckBelow` (the iOS keyboard
  doesn't come up) and `testOpenPortraitIsTheGlanceOverTheCoversView` (Send to 276 < 306 pt wide)
  fail on main as well; the other Duo tests and `FullScreenUITests` pass. The column deck squeezes its
  trackpad to a sliver if the keyboard is up while the mic is open (only reachable from a hook).

## Cover polish (Nov 4 2026)

Walked frame by frame on a Duo simulator's cover (`simctl io recordVideo --display=<cover>`,
`mpdecimate`) against `mpctl serve`, light and dark. What was wrong and what changed:
- **A window opened in three looks** (an empty plate, the kept picture whole and pale, then the
  live one at another scale, double-exposed in the fade). The kept picture now goes into the
  window's own `WindowViewer` until the first frame (`WatchWindow`: `kept`), so it opens at the
  live view's zoom and spot and the first frame lands in its place, no dissolve (`ViewerScrollView
  .kept`). Where you type is kept beside the picture (`WindowSnapshots.keep(focus:)`, read on open)
  so the view starts framed on the column. The name says "Opening …" only after 450 ms
  (`WatchKicker.slow`). A UIKit viewer takes its proposed size, so a `fill` kept picture no longer
  grows the window past its room (the inner screen's flat-upright overflow). Everywhere, not only
  the cover.
- **Everything dropped 48 pt as a window opened** (and rose on Done): the cover's NavigationStack
  kept a toolbar's height (82 pt) free at the foot for the `.bottomBar` group — whose items are in
  the vertical bar — and gave it back when the toolbar changed. `CoverFoot` (MainView) ignores the
  container inset at the foot and pads by the window's own (34 pt), or nothing while the keyboard
  is up, on the keyboard's curve.
- **The page row showed for one pass** as a window opened (tied to `watcher.isOpen`, which comes a
  beat after the pages): `rowHidden` is the cover itself.
- **The mic row and the window moved a frame apart:** the mic page's height is measured a frame
  late, so on Done it landed unanimated and cut the window short (`InputCarousel(smoothHeight:)`);
  the trackpad taking its room shrank the window in one frame — the cover's page buttons and the
  trackpad bar now change the page inside the pages' spring (`withAnimation(Motion.settle)`), and
  MainView animates on the page and on `keysUp` (keys constant off the cover).
- **The keyboard:** the viewer's height shrinks on the keyboard's spring but its spot was set at
  once, so the newest lines jumped up over an empty plate. `ViewerScrollView.followResize` copies
  the keyboard's own size animation onto the bounds origin, so the picture's foot rides the view's.
  The keyboard page's fold rides `MacInput.keysUp`'s own spring (the keyboard's duration, the
  iPhone pass's) — nothing on the cover overrides it. (The overshoot as the keyboard went is fixed
  in the second pass, below.)
- **Words over the mic:** the cover's one-line status could wrap over the mic row (now one line,
  `minimumScaleFactor`); the trackpad's how-to was drawn where its page would land while it slid in,
  across the mic and its buttons — it shows on its own page only, fading in once the slide is done.
- **The landed pill** sat over the window's answers (Esc, Yes) when a window was up: there it takes
  the status line's place under the mic (`landedPill(below:)`, the status line hidden meanwhile); at
  rest the Thread's check stays hidden while the pill says the same thing (it peeked out behind).
- **The window lingered** full size under the Thread as the mic opened (it faded on the settle
  spring): on the cover it leaves on `.handoff`.
- `PlaceTileStyle`'s lit rim is a gradient masked by a plain stroke (a gradient stroke draws on the
  CPU). Hook: `MACROPHONE_WATCH_ACTIONS=…,tappage@trackpad|keyboard|mic` (as the cover's buttons).
- Seen and left: the launch screen in dark is black for ~1 s before the fade-in (the launch image);
  the floating window name covers the Mac window's own title bar (Oct 30 decision); the demo window
  can't reshape, so it letterboxes in Scroll.
- **The second pass (the same day):**
  - *The keyboard going no longer overshoots.* `CoverFoot` had its two steps the wrong way round:
    `.ignoresSafeArea(.container)` then `.padding(.bottom, 34)` laid the padding out *in* the
    stack's safe area, so the keyboard's room was already taken (and given back in one step as it
    went: the window ran to the foot for ~5 frames), the foot's 34 counted twice (the mic screen
    ended 68 pt up, not 34) and nothing inside could ignore either. Now it pads first and ignores
    `.all` at the bottom outside, the same in every state; the cover lays the keyboard's room out
    itself like the regular iPhone (`MainView.laysOutKeyboard`: `InputCarousel(keyboardRoom:)` =
    `MacInput.keyboardRoom` − the 34). Measured: the mic screen 620 pt tall from the first frame,
    keyboard up or down. Fixing a word: `FixWordCard` rides the keyboard from an overlay outside
    `CoverFoot` (the screen under it doesn't move). The whole cover screen sits 34 pt lower than
    before (the 34 it meant to have). On the simulator the cover's keyboard vanishes in one frame
    as it goes; the window then grows down on the keyboard's spring — a device slides it.
  - *One screen at a time* (`AnyTransition.handoffAfter`, `Motion.afterLeave`, cover only): the
    window, the live words and Send to hand over in turn — what leaves goes in 0.12 s, what arrives
    fades in after it; the Thread and the clock wait for the window too (they were drawn over its
    answers). Status messages do the same (`StatusLine(swap:)`): out, then in at their own width.
  - *The landed pill is the status line's in every state* (under the mic, the line hidden while it
    shows): hung from the mic's frame by an alignment guide it landed ~40 pt off — over the disc
    and both buttons beside a window, across the Thread and the mic's ring at rest — and jumped from
    under to over on Done. The cover's pages sit on the foot while their height follows
    (`InputCarousel`, `smoothHeight`): a taller mic page hung over the home indicator as the mic
    opened, and as the keyboard went the mic row rode down from the top of the shrinking room.
  - *The mic's light follows its size* (`MicLightView.disc`, every device): the one mic is 64 beside
    a window and 92 at rest; its bloom, rim and level kept the first size and a landing ring stayed
    at the old middle, off to one side.
  - Left: the mic's opening ring shows over the window's answers for the 0.12 s the window takes
    to go; a first open of a window with no kept picture shows a plain plate (light in light mode)
    until the first frame; the bar's buttons change a frame before the window moves (system bar).

## Settings and sheets polish (Nov 4 2026)

Settings, History, every sheet, setup and pairing, walked on an iPhone 17 Pro, an SE (at an
accessibility text size too) and a Duo's cover and inner screen, light and dark — still frames
through the hooks and real taps recorded frame by frame (`SettingsWalkUITests`). What changed:
- **Setup slides page by page.** A tapped Continue / Skip cut to the next page: the step was an
  `@AppStorage` value, whose change reaches the view outside `withAnimation`. `OnboardingView`
  shows a `@State` step (`shownRaw`) and stores it beside. Already-done steps pass in the same
  slide (`isDone`; the mic page skipping itself cut the slide). The page is a `ZStack` round the
  step's switch, so the slide moves it whole — on the bare switch the slide reached the step's own
  views, and pairing's phases (each `.transition(.opacity)` now) faded in place or blanked and slid
  in from the edge. Titles end without a full stop (the pairing pages never had one); the first is
  "Steer your Mac from here".
- **Pairing closes with ×** (`Button(role: .close)`, Cancel before iOS 26) on the leading side, as
  a flow does — not Done; none on the success page, whose button finishes it.
- **Grabbers only where a sheet moves:** Your Macs (medium/large) and Control Center keep it;
  Settings, History, pairing, Open an App and Custom Cleanup (a bar with Done) don't.
- **Settings:** Send to's section has no header (its first row says it); the Macs and Recording
  footers are a sentence or two (the quiet sentence only while the switch is on); Unpair beside
  each Mac is a small red capsule (as Open an App's Quit) plus a swipe and a long press (Make
  Active · Unpair…); unpaired, the Mac section drops the Pair row (the banner pairs). "Use my
  Mac's wallpaper" in sentence case like its neighbours. At the accessibility sizes Cleanup is a
  checked list (`Picker(.inline)`) — the segmented control keeps small type there.
- **The Mac's page** (`MacConnectionView`): ends in **Unpair This Mac** (asked first; pops back,
  except as the inner screen's group page — `popsOnUnpair`); its name moves into the bar once the
  header's has scrolled under it (`ScrolledPast`, iOS 18+), never twice on screen. Away from
  home's fourteen-line footer is **Set Up Away from Home** (`AwaySetupView`, `SettingsRoute
  .awaySetup`, `away-setup`): five numbered steps, then Without Tailscale **[superseded Nov 7 2026:
  `AwayGuideView`, a checklist that checks itself — see "Setup on the iPhone, and Tailscale guided"]**.
- **Custom Cleanup's editor grows with its words** (`TextField(axis: .vertical)`, 8 lines at
  least; Return is a new line): a fixed 340 pt editor was a scroll inside the page's scroll, its
  last line cut. Reset to Default is down the page. "Use Custom" stacks under its words at the
  accessibility sizes (it broke "Cus-tom").
- Hooks: `MACROPHONE_SCREEN=connection|awaysetup|settings-pairing|historypage|controls`;
  `MACROPHONE_SCROLL=middle|bottom|<0…1>` scrolls the front sheet's list after
  `MACROPHONE_SCROLL_AFTER` (2.5 s; launch is ~3 s, so shoot at ~8). `SettingsWalkUITests`
  (`TEST_RUNNER_MACROPHONE_WALK=1`; grant the microphone first) walks Settings, History, pairing
  and setup, a beat between steps for `recordVideo`. The Custom instructions UI tests select all
  and type (the field is taller than the screen).
- Seen and left: on the inner screen the simulator gives Settings / History a compact sheet
  (~650 pt), so one column (known, Inner screen polish); History's Clear All sits top-left where a
  Cancel would (it asks first); the Dictionary keeps the keyboard after Return to add the next word;
  the onboarding test page's title wraps at the accessibility sizes and its pages scroll under the
  pinned button (as Setup Assistant's); the Control Center caps its type at xxLarge (recorded).

## Nothing over the window (Nov 6 2026)

Sameer: "I don't like having anything ever overlaid over the window because it blocks UI elements
and it makes it so that the user can't fully see the window". This wins over every older section
that floats something over the picture (the cover's floating name, the book's fading overlay
header, the answers floating over the picture's foot, the tip card over the window's top):
- `WatchPanel`: the name (`WatchHeaderBar`, name-only where the vertical bar holds the buttons) is
  a row above the window on every phone, the cover included (gone with the keyboard up, `bare`);
  the question's answers on the Duo (cover and inner) are a row under the window
  (`WatchActions(floating:oneLine:)`, the cover's key row stepping aside as before); tips are the
  inline strip everywhere (`WatchTipCard(inline: true)`). No `footInset` from the panel.
- The book's page (`DuoMacHalf`): the header a row above the picture, the answers a row under it;
  `DuoOverlayHeader` and its fade / reveal are gone. The laptop was already clean.
- Still over the picture, on purpose: the words you're saying while the mic is open, the
  Accessibility banner (×), a moment's note ("Terminal — codex ~/api"), full screen's floating mic.

## Alerts from the Mac: any window on watch, every alert with a picture (Nov 6 2026)

Sameer: "have the app watch any window and alert me with a notification and an image of the window
for any significant state change", then "have agent alerts work through this new way now. So it's
all consistent and uniform". Keep-alerting with guards was his pick (not one-shot). Wins over the
older alert sections where they differ.
- **The rule** (MacrophoneKit `Core/MacAlerts.swift`, pure, `MacAlertsTests`): `WindowChangeDetector`
  per window, a look every 3 s (6 s after ten quiet minutes): busy while the picture changes by more
  than a caret (`activity` 0.0003) or the window says it's working (`StillWorking`); it **settles**
  after a tenth of the busy time, 8–30 s; a short settle counts only if the picture ended
  meaningfully different (a spinner isn't news), a run of 20 s or more always does (a rerun ending as
  before). A dialog / sheet over it (`AlertCenter.dialogs` — companions at the normal level) alerts
  at once. More than three alerts in ten minutes → **calm**: only a two-minute stillness counts,
  until half an hour without one. Looking at it on the phone = `seen()`. A watch ends when its
  window closes (a "window closed" alert with the last picture), after 12 quiet hours, or when
  turned off; 8 at most.
- **The words** (`AlertReading`, `AlertWords`): the window's text by accurate recognition (4 s,
  then fast — fast reads "1 error" as "l error"), pieces on one row joined; what's new compared
  loosely (letter for letter ignoring signs, a prefix, or a tenth's edit distance — the same line
  reads differently picture to picture); of the window's last eight lines, the new ones, else all
  (`isPrompt` drops the shell prompt). The headline from the on-device model (`Writer`, greedy, no
  example numbers) only when **grounded**: every number and every longer word is the window's own or
  a status word (`statusWords`) — it once wrote "Build failed: 3 errors" for 1 error and "Build
  completed" for an upload; else the window's own status line ("Upload complete"), else plain
  words. The line under it is always the window's own (`AlertWords.detail`: a summary failure line,
  a failure, a success, else the last). Real-window proof (a Debug copy, a Terminal window, display
  asleep): "Build failed · Build failed with 1 error in 23.4s", "Upload complete · Upload complete:
  report.pdf (2.1 MB)", "Terminal is asking you something · Do you want to continue?", "Terminal
  window closed".
- **One sender** (`Mac/App/Watch/WindowAlerts.swift`: `AlertCenter` + `WindowAlertWatcher`): every
  alert — a window on watch, `AgentHub`'s agent asking, `AttentionWatcher`'s question — is a
  `MacAlert` with a JPEG of the window (≤ 1,100 px, ≤ 150 KB, `MacAlerts.jpeg`; the dialog included
  when one is up): `.macAlert` to a phone naming `macAlerts`, `.attention` to an older phone (a
  question only), else iCloud. A question isn't told twice (`recentlyAsked`, 20 s). The lookout skips
  windows on watch. Pictures are captured with the display asleep (the usual case — he's away);
  `frontWindow` reads the window server straight, drawn or not. `StayAwake.update(alertWatches:)`:
  no idle system sleep while anything's on watch (the display may sleep).
- **Wire** (`Transport/AlertLink.swift`): phone → Mac `.alertWatch(AlertWatchRequest)`; Mac → phone
  `.alertWatches([AlertWatch])` after the welcome and on each change, `.macAlert(MacAlert)` (`kind` a
  string, so a newer kind never breaks a phone).
- **iCloud** (`CloudAlerts`, `CloudAlertRecord`): the Production schema takes no new types or fields
  without a CloudKit Console deploy, so alerts ride the old "Ask" type: `line` headline, `window`
  title, `ref`, and `promptID` = a JSON payload (kind, line, picture as base64). Record
  `alert-<window>`, overwritten; the Mac deletes any older than a day (`alerts.cloud.written`). The
  push shows `line` / `window` / "Tap to see it."; the subscription asks for mutable content.
- **The picture through iCloud needs the notification extension** (`iOS/MacrophoneAlerts`,
  `NotificationService`: fetches the record, `AlertNotification.fill`, removes the window's older
  alert, deletes the record). Written, built, **not embedded yet**: its App ID
  (`com.sameer.macrophone.alerts`, registered Nov 6 with iCloud through the API) has no container —
  Apple's API can't link one and there's no Xcode account on this Mac. Sameer: developer.apple.com ›
  Identifiers › com.sameer.macrophone.alerts › iCloud › Configure › tick iCloud.com.sameer.macrophone.
  Then uncomment `- target: MacrophoneAlerts` in `iOS/project.yml`; the phone then names
  `macAlerts-cloudPicture` and the Mac starts putting the picture in the record (until then it
  doesn't — no point storing it). A dev profile "Macrophone Alerts Development" was made through the
  API (without the container) — regenerate it after the tick.
- **Every iPhone build is iCloud-signed now** (`MACROPHONE_CLOUD_ALERTS` YES,
  `Macrophone-iCloud.entitlements`): TestFlight builds get alerts with the app closed.
- **Phone** (`Model/WindowAlerts.swift`): `alertWatches`, `setAlertWatch` / `toggleAlertWatch`,
  `AlertWatchButton` (the Window menu's first section; a place's long press on the cover / inner
  tiles), the Dock popover's "Alert Me When It Changes" row (`dock-alert-on/off`), `AlertWatchBadge`
  (a gold bell at the icon's top-left; grey when calm), Settings › Alerts lists each with Stop.
  `AgentAlerts.post(MacAlert)` → `AlertNotification` (one per window, `threadIdentifier` "alerts").
  A question goes by the agents switch; a window he put on watch always alerts. Nothing while he's
  looking at that window. Mac menu: "Alert Me When ‹front app› Changes" and a Stop row per watch.
- **Hooks:** phone `MACROPHONE_WATCH_ACTIONS=…,alert,alertoff`, `MACROPHONE_FAKE_ALERT=<s>`;
  `AlertNotificationUITests` (`TEST_RUNNER_MACROPHONE_ALERT_TEST=1`, `…_ALERT_SHOTS=<dir>`); Mac
  `MACROPHONE_ALERTS_PRINT=1` (each alert and look to stdout, the JPEG in $TMPDIR) and the distributed
  notification `com.sameer.macrophone.debug.alertWatch` (object `bundle` or `bundle#windowID`);
  `mpctl serve` keeps watches and says one finished after `--alert-after` (6 s), `--no-alerts`.
- **Seen on the simulator:** the iOS 27 simulator draws no attachment thumbnail at all
  (QuickLook: "No extension found for com.apple.private.quicklook.notification") — the attachment is
  copied in fine. **Needs his phone:** the picture in the notification; an alert through iCloud with
  the app closed (Production "Ask" type and the Mac's save); the model's headlines on real apps.

## Alerts that arrive: animations aren't activity, the chat's answer is the word (Nov 7 2026)

Sameer, away on Tailscale, put the Claude app's window on watch (07:49:38 UTC), dictated, left,
and the reply came (`ReplyWatcher`: "needs you: a chat answered" 07:51:19) — no alert, and after
bfd57f4 (the Mac always posts to iCloud with no phone connected) still no `alert:` line at all.
Measured with a Debug copy on that very window at rest (`MACROPHONE_ALERTS_PRINT=1`, 41 looks):
**0.01–0.11% of the picture changed between every two looks** — the composer's caret, a spinner,
the live simulator panes beside the chat — straddling `WindowChangeDetector.activity` (0.03%), so
the window read as busy for 20–30 s of every minute and was still for the eight seconds a settle
needs only now and then; `ReplyWatcher`'s still threshold is 0.6%, which is why it saw the answer.
- **The detector** (`WindowChangeDetector`, MacrophoneKit, `MacAlertsTests`): every sample has a
  **heat** — up two on a change since the last look, down one without; at `animated` (3) it has
  been changing look after look and its changes aren't activity, as long as the animated samples
  together are under `liveArea` (2% of the picture: a column scrolling as a reply streams is far
  more, and stays busy until it stops). At a settle the comparison with the picture from before
  leaves out what's animating right now (heat ≥ 5), so a spinner in both never makes a settle
  news, while a reply that stopped three looks ago has cooled and counts whole. A clock ticking
  once a minute is a blip that settles as not news. `told(at:)` — another path told him (below) —
  makes the settle that follows not news for 30 s. `WatchChange.differs` is the one-sample compare.
- **What the Mac knows counts too** (`WindowAlertWatcher.signal`): a chat he wrote to from the
  phone answering (`ReplyWatcher.answered(windowID:)` — exact for a hook agent, by picture
  otherwise) alerts a window on watch the moment it's known, kind `answered` ("Claude answered
  you", the window's last line under it; `asking` when it's asking — a phone from before reads
  `answered` as `updated`); an agent's turn ending (`AgentHub.state(of:)` → not working) alerts
  `finished`. One alert per happening: the detector is `told`, and a signal within 30 s of a
  picture alert is dropped ("told by its picture already").
- **The log says why not** (diagnostics.log, numbers only): "a window went still after N s of
  change but 0.08% of it differs from before — no alert"; "a window has kept changing for 90 s
  (0.05% of it since the last look, 0.12% animating) — no alert until it's still" (once per busy
  stretch); "no picture of a window 3 looks in a row"; "Screen Recording is off".
- **The list survives a restart** (`alerts.watches`, `restore()` at launch: each window by its
  number and app, those gone dropped — "N back on watch from last time (M gone)"), and the phone
  gets it with the welcome as before.
- **Phone:** `AgentAlerts.cloudState` (idle · unavailable · notificationsOff · noAccount ·
  failed · trying · ready) — the account is checked before the save; the subscription is tried
  again when the app comes to the front and when the Mac's list arrives (`retryIfNeeded`).
  Settings › Alerts shows `CloudAlertsStatusRow` only while something wants alerts and something's
  in the way: one line, one button (Open Settings for notifications or iCloud, Try Again for a
  refusal). The Mac's 07:57 line "the phone hasn't said it subscribed" means his phone never
  managed the subscription — the row now says which of the three it is.
- **Proven on this Mac** with a Debug copy (125 s, the Claude window on watch, 39 looks every
  3 s): its idle flicker ended in "went still after 3 s of change but 0.01% of it differs from
  before — no alert" three times and nothing else; one real change in it (the chat moved on)
  gave exactly one alert, "finished", with a 144 KB picture; the watch came back at launch ("1
  back on watch from last time"). The real app's log already shows `CloudAlerts.post` succeeding
  from the iCloud-signed build ("alert: dialog in Claude — sent through iCloud", 07:57:43). A
  Terminal job finishing and a chat's answer through `ReplyWatcher` are proven by the unit tests
  only: the Debug copy's Screen Recording grant flapped off on every other look once its binary
  had been rebuilt (TCC; the same code had looked fine minutes before), and AppleScript to drive
  Terminal / TextEdit hangs without Automation consent. **Needs his phone:** Settings › Alerts' row
  (which state it shows), then an alert through iCloud with the app closed; **needs the installed
  Mac build:** a Terminal command finishing and a Claude reply with the window on watch.

## The answer finds you (Nov 8 2026)

From his Mac's log: 47 of his last 50 dictations went to the Claude app with send, almost all from
away (Tailscale); the loop is dictate → pocket the phone → come back for the answer. On Nov 7 the Mac
logged "needs you: a chat answered" 25 times and not one notification reached him: answers alerted
only windows on watch, and his phone never managed the iCloud subscription. Now **any chat the phone
wrote to alerts when it answers**, no watch needed. Wins over "Chats that answered you" where they
differ (the mark in Send to stays as it was). Frames: `docs/screens/answers-nov8/`.
- **The rule** (MacrophoneKit `Core/MacAlerts.swift`: `ChatAnswers`, `AnswerFollower`, pure,
  `ChatAnswersTests`): a chat is what `ReplyWatcher` already tracks (a dictation sent there, Return /
  an answer from the watch view). Each new answer (`ReplyDetector.answeredAt`) is told once while the
  chat is **followed**: two hours after the phone last wrote to it, two answers at most, 30 s apart at
  least (an answer that flickers isn't told twice). Writing to it again re-arms it (a new follower).
  Not while he's looking at it on the phone (the follower marks what showed as seen), not for a window
  on watch (`WindowAlertWatcher.signal` tells it the same moment), not an agent's question
  (`AgentHub` told it as it asked; `recentlyAsked` drops a repeat by picture). Every answer is seen by
  the follower once, told or not, so one passed by is never told late.
- **The alert** (`ReplyWatcher.tell`): kind `answered` ("Claude answered you" — the app's name) or
  `asking` (the agent says waiting, or `PromptVision` reads a question off the picture: the question
  under it, its `promptID`); the line under it is the reply's last lines (`AlertWords.reply`: the last
  two or three as read, joined, ≤ 160 characters cut at a word — one recognised line alone is a
  fragment), told against the window's lines read 1 s after the phone wrote (`before`: its own message
  landed, the composer empty); a JPEG of the window; `MacAlert.chat = true`. Through the one sender
  (`AlertCenter.send`: a connected phone, else iCloud). Chats followed keep the Mac from idle sleep
  (`StayAwake.update(followedChats:)`, the display may sleep). Log: kinds and counts only — "chat
  answers: a chat answered — alert 1 of 2 (5 new lines read)", "chat answers: on (the phone's switch)".
- **The switch: Settings › Alerts › When a chat answers you** (first in the section, on by default,
  `settings.chatAnswers`, `chat-answers`). Wire (`Messages.chatAnswers(on:)`, `ChatAnswers.feature`
  in both hello and welcome): the phone's hello carries `chatAnswers-on|off` every connect
  (`LinkClient.setChatAnswers` keeps the word current), and a change while connected goes at once to a
  Mac naming the feature. The Mac keeps it (`AlertCenter.chatAnswers`, instance-safe defaults); nil —
  no phone with the switch ever connected, an older phone — means no chat alerts, the old behaviour.
  The phone drops a live `chat` alert with the switch off (the Mac's copy may lag a reconnect); a
  `chat` question goes by this switch, not the agents one. No Mac-side mirror (the Mac has no alerts
  settings; it follows the phone).
- **The tap** opens that window live (`openAttention`) at the bottom — `Watcher.lookAtNewest` sets the
  kept view's `bottom` (the zoom and spot across stay); already open, `showNewest`.
- **The subscription, read again — what could fail silently, and what changed** (`AgentAlerts`):
  1. *A remembered "ready" was trusted*: `cloudState` started `.ready` from `alerts.cloud` and
     `retryIfNeeded` returned at `.ready`, so with the agents switch off and the watch list not yet
     arrived at launch, the subscription was never saved again (a "ready" from an earlier build or
     environment stood forever). Now it's confirmed once per launch (`confirmed`); a retry runs until
     a save succeeds in this launch.
  2. *The push registration was never heard*: the app delegate had no
     `didRegisterForRemoteNotifications…` / `didFail…`. Now a failure is `.pushOff` (row: "Apple's
     notification service didn't take this iPhone", Try Again) and both are logged.
  3. *Every iCloud status but available read "no account"*: now `.noAccount` (sign in), `.iCloudOff`
     (restricted, or iCloud off for Macrophone — Settings › your name › iCloud), `.signInAgain`
     (temporarilyUnavailable); an unknown status tries anyway; `notAuthenticated` from the save is
     no account. A refusal naming the schema logs what to do in the CloudKit Console (an index on
     Ask's recordName, or deploying the Ask type) — whether Production needs that index for a
     TRUEPREDICATE query subscription isn't documented; the log will say if it does.
  4. *Wanted only for agents or watches*: `wanted` includes the chat switch, and **the first dictation
     sent into a chat asks for notifications** (iOS asks once — `sentToChat`, from the landing) and
     subscribes; the first window opened asks too, as before. One try at a time (two minutes at most).
  The hello now also carries **`alertPush-development|production|simulator`** beside `alertState-…`
  (from `embedded.mobileprovision`: a TestFlight / App Store build has none = production); the Mac logs
  "phone alerts while closed: ready, push development". **Suspect first if everything says ready:**
  `testflight.sh` installs the *dev-signed* build straight to his phone when it's reachable
  (`aps-environment` development, CloudKit Production by `MACROPHONE_CLOUD_ENVIRONMENT`) — whether
  CloudKit's Production pushes reach a sandbox push token is Apple's to say (as far as I know they go
  through production APNs); the TestFlight build is production on both. Also needs: the phone and the
  Mac on the same Apple ID (the record is in his private database).
- **mpctl:** `serve --answer-after <s>` "answers" a dictation sent to an app that many seconds after it
  lands (`ANSWER sent: Claude answered you · … · picture 75 KB`, or `ANSWER held: the phone's switch is
  off`), names `chatAnswers` (`--no-chat-answers` = a Mac from before), prints `CHAT ANSWERS on|off`
  (hello or live). Mac DEBUG: distributed notification `com.sameer.macrophone.debug.chatAnswers`
  (object "on"/"off") stands in for a phone's switch, with `….debug.engage` (an app's front window
  made a chat) and `MACROPHONE_ALERTS_PRINT=1`.
- **Proven:** `ChatAnswersTests` (8) and `swift test` (278); `ChatAnswersUITests`
  (`TEST_RUNNER_MACROPHONE_CHAT_TEST=1`, `…_CHAT_SHOTS=<dir>`, an iPhone 17 Pro sim paired with
  `serve --answer-after 4`): a dictation into Claude with send, the banner "Claude answered you · Here's
  the change: … the login test passes again" 4 s after the landing, a tap on it opens Claude's window;
  the switch off in the hello → `ANSWER held`, no banner; the switch flipped in Settings while
  connected → serve prints `CHAT ANSWERS off` / `on` at once. On this Mac, a Debug copy and a stand-in
  chat window behind everything (an LSUIElement app streaming a reply on a distributed notification):
  reply 1 → "alert 1 of 2", reply 2 → "alert 2 of 2", reply 3 → nothing (past the cap), written to
  again → "alert 1 of 2" — each with the window's picture (69–122 KB) and "AnswerDemo answered you ·
  …and added a test for the edge. The login test passes again locally and on CI."; no phone, so it went
  to iCloud, which the Debug build isn't signed for. Seen once on the sim: an answer that arrives while
  the first-time notifications prompt is still up isn't shown (iOS posts nothing before Allow).
- **Needs his phone:** Settings › Alerts' row after this build (which state, and the Mac's "phone
  alerts while closed: …, push …" line); a Claude reply with the app closed through iCloud — on the
  TestFlight build, and on a dev-installed build to settle the push-environment question; a real
  Claude window's answer read with `before` (the composer's placeholder shouldn't be the line).

## Overnight polish, round 1 (Nov 7 2026)

Sameer, going to sleep: "make macrophone the best iPhone Mac controller period … polish and detail
and perfection … a really easy to use app that excels on the iPhone Duo", and earlier the same night:
the Mac keyboard "is much slower to type on than the default iOS keyboard … give users the iOS
keyboard and give them the ability to toggle to the more detailed Mac keyboard", "the apps layout
was jumping around", "doesn't have perspective on what should be easy to access vs buried in a
menu". Four streams, merged together. Frames: `docs/screens/overnight-nov7/round-1/<stream>/`,
`docs/screens/keyboard-nov7/`, `docs/screens/duo/nov7/`, `docs/screens/stability-nov7/`,
`docs/screens/watch-header-nov7/`.
- **Typing: iOS's keyboard first, everywhere** (the phone, the cover, the laptop, the book, flat).
  Autocorrect and predictions on; smart quotes, dashes, auto-capitals and Writing Tools off (a
  rewrite would go to the Mac as typing). **One 44 pt bar** (`MacKeyboardBar`, was two rows /
  94 pt): esc · ⇥ · ← ↑ ↓ → (held repeat) · `KeyboardEcho` (the words just typed, grey, newest at
  the right; back to "Typing in ‹app›" 1.5 s after the last key; "⌘ next key" in blue, a chord as
  "⌘K"; never logged) · **Mac Keys** (`keyboard-mac-keys`) **[superseded round 3: a plain text key, "Mac" / "ABC", never a lit ⌘]** · hide (`keyboard-hide`). Mac Keys swaps
  the field's `inputView` for `DeckKeyboardHost` in place, like the globe key (`reloadSoon()`, the
  next run-loop turn — never inside `updateUIView`), at the iOS keyboard's measured height on that
  screen (`keyboard.iosKeys.<surface>.<tall|wide>`; capped to the bottom half upright inside), so
  the window doesn't move; ABC (`keyboard-abc`) swaps back. Remembered per screen
  (`Model/KeyboardChoice.swift`, `keyboard.macKeys.phone|cover|inner`; the surface is decided in
  `KeyboardTextView.applyKeys()`, pose first, then the vertical bar). The bar's ⌘ ⌥ ⌃ ⇧ and fn moved
  into Mac Keys. `DeckKeyboard` (`deck-keyboard`): keys fire on touch-down with a pop-up, ⌫ /
  arrows / space repeat (the first press felt, repeats quiet), bottom row ABC · fn · ⌃ · ⌥ · ⌘ ·
  space · arrows, ⇧ both ends (double tap = caps lock), on the system keyboard's background. The
  book's / side column: a Keyboard button (`deck-keyboard-button`) + a Mac Keys toggle
  (`deck-mac-keys`) instead of four rows of keycaps (three rows with it on); the column hides
  whole while the keyboard is up (`micSlot(visible:)`) **[superseded round 3: the column is gone —
  one deck on every inner pose]**. Hook `MACROPHONE_MAC_KEYS=1|0` (DEBUG, not
  saved); `type@` now types through the real field. `KeyboardChoiceUITests`.
- **The Duo's inner screen, the same on every path.** *The band:* hiding the status bar at runtime
  on iOS 27.1 (upright with a window in hand) left SwiftUI's content 82 pt down under an empty band
  with the mic cut at the foot — so **only full screen hides it** (`MainView.hidesStatusBar`) and
  the window sits just under the status bar on every path. Upright with a window in hand there's
  no system bar — the deck's header has Done and the controls; flat upright at rest keeps Mac ·
  History · Settings (`innerBarShown`). *The laptop's deck*, top down: the answers row (only while
  a question is up), one mode, **`DuoModeBar`** (`UI/DuoModeBar.swift`: Trackpad · Mic · Keyboard,
  glyph and word, 44 pt, the lit one slides; still the adjustable `input-pages` element — tests tap
  it by position, 0.17 / 0.5 / 0.83), then the header. The mic fits the room (`DuoLook.deckMicFit`:
  112 → 92 → 80). Flat upright's deck is a fixed 372 pt (was 300 / 360), so a mode change or an
  answer never moves the window. *Dictating from the trackpad* shows the mic and goes back to the
  mode after (`MacInput.micOpen(_:)`, a 1 s window for the phone's view switching first). The deck's
  mode is kept across a fold (upright = "laptop", on its side = "book"). *The book and flat on its
  side are one view* (`sideBody`, replacing `bookBody` / `openLandscapeBody`; `DuoMacArea` is gone),
  so folding between them moves nothing; the book's fade with the hinge is gone (at his 174° it left
  the deck ~30% visible). Typing on any inner pose sizes the window from the keyboard's real frame
  (`input.keyboardRoom`, `keyboardTop`). *The glance*: connecting and live share one frame and the
  bar under the picture (`DuoGlance.pictured`, 64 pt). `DuoLayoutStabilityUITests`
  (`TEST_RUNNER_MACROPHONE_DUO_REAL=portrait|laptop`, a real duo-sim pose).
- **The cover and the phone hold still.** *The drift:* the mic page measured itself in the room it
  was last offered, so after open → Done the status line kept one line and the cover's desktop sat
  20 pt low until relaunch; it measures at its own height now (`InputCarousel`, fixedSize) —
  `StabilityUITests` holds rest = after Done (±0.5 pt). *The vertical bar's set is fixed while it
  shows:* Done · Keyboard (one toggle, `bar-keyboard` / `bar-keyboard-hide` **[round 5: one id, `bar-keyboard`, the title says the state]**; **[round 3: the cover only — the inner screen's deck has its own Keyboard mode]**) · Sound · Mac Controls ·
  bell · Pan|Scroll (there from the first moment, dimmed until live) · zoom out · Window; items only
  dim or change symbol, never come or go (each change re-vends the bar), and with the mic open the
  set stays, dimmed **[amended round 5: separate items in tiers; with the keyboard up the system's
  column holds two positions, so it shows Done · ⋯ itself — see "The cover's bar holds while typing"]**. The inner bar swaps in the layout's own transaction (`innerBarWindow` /
  `barFollows` removed) **[superseded round 3: on its side it swaps 50 ms after Show it here, with the deck]**. *Pages change in place:* a tap fades the old page out and the new one in
  with a 0.96 settle (Reduce Motion: fade); only a finger on the Thread slides them; pages sit on
  the room's foot; the keyboard page keeps the last page's room (`restBand`) until the keys rise.
  The keyboard page itself is never faded or scaled (an effect's new container made UIKit hand the
  keyboard back after it let go). `phoneBody` animates on `input.page` on every phone; the regular
  iPhone's page row folds away while `keysUp` **[superseded round 5: no page row on the phone while a window shows]**. The trackpad's hint is one line ("Trackpad · Two
  fingers scroll"); Mac Controls is `switch.2` everywhere (`MacControlsButton.symbol`); the cover's
  Whole Screen keeps last time's shape while connecting.
- **The window's own controls, primary first** (`UI/WatchPanel.swift`). *The name reads whole* on
  every phone (it was "C…" on a Pro, gone on an SE): the header's bell is gone — a gold
  `WatchAlertBadge` (`watch-alert-on`, "Alerts on") beside the name when alerts are on (not where a
  vertical bar has its own bell), Alert Me first in the Window menu; a tight row gives up the page
  dots, then "Paused ·", then zoom out, which moves into the Window menu (`WatchWindowMenu
  (zoomItem:)`, "Show the Whole Window" / "Zoom Back In"). `WatchAlertToggle` is removed. *Answers
  are chips* (`chipWords`: the number and whole words to ~24 letters, then "…"; the full answer to
  VoiceOver and in a long-press preview with Answer): on a phone one sideways row
  (`WatchChipScroller`, Esc first, Keys last, an edge fade while more is hidden) exactly as tall as
  the key row it replaces, so a question never moves the window; at 560 pt or wider
  (`WatchActions.wideRoom`) up to two rows (`WatchChipRows`), never three. *The zoom holds* as the
  answers come or go (`ViewerScrollView.answersUp`, 0.8 s, like `keyboardUp`; logged "viewer: the
  answers came/went — zoom X before, Y after"). *A window filled past its width with no saved view
  opens at its top-left* (`reset()`, `fromCorner`), so the traffic lights show. `WatchHeaderUITests`
  (`TEST_RUNNER_MACROPHONE_WATCH_SE=1` for the SE frame).
- **Needs a real Duo:** the laptop's keyboard — iOS reserves a ~55 pt band above its keys off the
  hinge, so the bar sits just above the fold on the window's half (nothing inside the keyboard moves
  it; the window should give up that strip); whether hiding the status bar upright misbehaves on
  hardware as on the 27.1 simulator (if not, the mini-Mac top edge could come back); the cover
  keyboard's height and the system background behind Mac Keys; the inner bar's swap in Release
  (Debug drew the new items 0.2–0.3 s before the layout moved — delay by `Motion.leave` if it shows).
  Left: the bar has no ⌘ on the iOS keyboard (Mac Keys is one tap; ask him); Mac Keys inside is one
  setting for the column's keycaps and the keyboard that rises; on an SE the echo shows only the
  last letters; to pin the picture's foot on the trackpad page too, `WindowViewer(keyboardUp:)`
  could take `input.page != .mic || input.keysUp`. Pre-existing failures seen again:
  `DuoUITests` laptop / open portrait (and book / open-landscape on some runs),
  `HardwareKeyboardUITests.testAHardwareKeyboardTypesAndChordsOnTheMac`,
  `InputCarouselUITests.testClosingTheWindowBringsTheMainScreenBack`, `testMicButtonNeverMoves`.

## Overnight polish, round 2 (Nov 7 2026)

Round 2 of the overnight passes (Sameer's goal as in round 1). Emphasis: what's primary vs buried,
and opening / returning without a hitch. Four streams, merged together; frames
`docs/screens/overnight-nov7/round-2/<stream>/`. In one breath:
- **Watch is one tap from the desktop:** the pick's window sits in the desktop's room as a small Mac
  window (`DesktopWindowCard`, `desktop-window`) on the regular iPhone and the cover; the window
  panel is built once and kept (`MainView.keepsPanel`), so Open grows it out of the card or the
  Dock icon and Done shrinks it back; Pan | Scroll is decided at open (`Watcher.decideDragAhead`).
- **Back from the background without the Reconnecting flash:** a return grace (`AppModel.returning`,
  1.5 s, `looksConnected` for looks only; `watchWhenConnected` for a tap during it).
- **Send after pasting is a labelled toggle** (`SendToggle`: "Paste only" / "Paste & Send") and
  **attachments are one paperclip** (`AttachMenu`) by the Dock, leading the key row, or in the
  inner deck's header; the Window menu, the cover bar's ⋯ and the Send to panel's ⋯ lost the share
  items; Refresh Open Apps lives in Open an App.
- **Undo lasts as long as the Mac can take it back** (28 s): the landed pill shrinks into an
  `UndoChip` at the Thread's end; a shake asks; History offers Undo Paste.
- **Integration (this merge):** the desktop card follows the return grace too — it never dims on a
  return and its tap waits for the connect (`DesktopWindowCard.canWatch` = `looksConnected`,
  `MainView.watchFromCard` → `watchWhenConnected`); the paperclip keeps its place through the grace
  and a reconnect (`AttachMenu.available` remembers `bar.had.attach`, as the bar's `bar.had.*`) —
  without it the app switcher's snapshot and the first frame back had no paperclip. The landed pill
  sat on the mic's disc (its alignment guide was ignored — the builder's own frame shows it too);
  `View.landedPill` lifts it by an offset now (36 + 18 + 6 − size × 0.125), and
  `UndoChipUITests` pill → chip and the chip's Undo (`UNDO <id>` at serve) pass, with the shake
  test, `DesktopWindowUITests` and `StabilityUITests`. Smoke-tested on
  an iPhone 17 Pro and a Duo (cover, flat on its side, flat upright, the laptop, the book, closed
  again) against `mpctl serve`: the card, open from rest, trackpad / keyboard / mic pages, typing
  (`WATCH TYPE`), a click, Done back into the card; a return from Settings.app keeps the bar, the
  pill and the paperclip (the cover too). (Two simulators can't pair with one `serve` here — give each its own
  `--name` and `--state`.)
- **Needs a real Duo / phone:** the first open after launch (244 ms on the simulator; warm the
  header at launch next); the hidden panel kept at opacity 0.001 (battery); Settings' first frame
  in Release (150–400 ms on the simulator, the render server); the cover sheets' card beside the
  vertical bar; the shake alert; VoiceOver skipping the hidden desktop under an open window.
  **Open:** `UndoChipUITests.testHistoryOffersUndoPasteOnlyWhileItCan` fails (three runs: no Undo
  Paste in the row's leading swipe, by identifier or by title) — the History path is unproven; check
  whether the landing reaches `rememberUndoable` while the History sheet is up, and whether the
  first cell is the newest.

### Watch from the desktop

The room between the menu bar and the Dock was empty (the widget went Nov 1) and the only way to
watch was the picked Dock icon's second tap. Frames: `docs/screens/overnight-nov7/round-2/watch-from-desktop/`.
- **The pick's window on the desktop** **[the look and the zoom superseded Nov 7 2026, round 4: App Exposé's thumbnail, only the picture flies — see round 4]** (`UI/MacOS/DesktopWindow.swift`, `DesktopWindowCard`): the
  regular iPhone and the Duo's cover (never inside — the glance is the window there), in
  `phoneBody`'s room under the menu bar as an overlay (it never moves the Dock, its options, the
  Thread or the mic; below 140 pt of room it isn't drawn; `DesktopEmptyState` wins while there's
  trouble; no card for the Clipboard). A small Mac window: the kept picture
  (`WindowSnapshots.cached`) aspect-fit under a title bar (`MacWindowFrame(decorative:lights:)` —
  the bar's own lights only when there's no picture, since the picture has the Mac window's own),
  the app's icon and name, the window's title, the gold bell, the ember dot + "Answered you" /
  "Asking you", and **eye Watch** at the trailing end. The whole card is one button
  (`desktop-window`, "Show ‹App›'s window"), doing what the Dock's second tap does. No picture
  yet: "Show the ‹App› window here"; not open: "‹App› isn't open" + Open (`openOnMac`); not
  connected: dimmed. `WindowSnapshots` now posts `didKeep` and puts the new picture in memory
  itself (a read during the write had kept the old one).
- **The window panel is built once and kept** (`MainView.keepsPanel`: paired, not inside): Open
  and Done change `DockZoom` (now a state on the panel, not an insertion transition) — out of the
  card when the card opened it (`watchFromCard`: the card's frame is rendered as the start first,
  the open goes on the next run-loop turn; `DesktopWindowSpot`), else out of the Dock icon, and
  back into wherever it came from. Hidden it's drawn at opacity 0.001 (`DockZoom.asleep`: at 0
  the renderer dropped its layers and each open drew the glass afresh), its viewer holds the
  pick's kept picture (`\.watchRestPicture`) but takes no touch and reports nothing
  (`\.watchWindowHidden`), its header is left out (`bare`), and under the words it has no viewer
  (`panelDormant`). `OutOfReach` hides a kept layer from VoiceOver — **XCUITest on the iOS 27
  simulator still finds `accessibilityHidden` elements**, which is why the header goes while
  hidden (and why `testClosingTheWindowBringsTheMainScreenBack` passes again).
- **Pan | Scroll is decided at open** (`Watcher.decideDragAhead`): a window about to take the
  view's shape opens in Scroll (it did 0.5 s in), else the kept picture and the last measured
  view say whether all of it shows (`ViewerScrollView.opensWhole`, the viewer's own
  `startScale` rule shared as a static). Logged "watching: starts in Scroll (…)".
- **The cover:** desktop and window cross-fade with an overlap (`panelAnimation`,
  `settingsAnimation`): the window in 0.18 s over the desktop fading in 0.3; back the same way
  (after the words, `Motion.afterLeave` as before). Reduce Motion: a plain fade.
- **Numbers** (`MACROPHONE_HITCH=1 MACROPHONE_WATCH=rest MACROPHONE_WATCH_ACTIONS=open,close,…`,
  iPhone 17 Pro sim, Debug): open's first frame 263 / 138 ms before → 244 / 58–66 after (first /
  later); Done 53–187 → 24–45. The first open after launch still builds the header and the
  viewer's first video frame; with the header kept it was 129 — a warm-up there is the next step.
- **Left:** the cover's cross-fade with a live window and the Done-into-the-card motion are
  shown by the code and the UI test, not by a recording (the Duo sim couldn't pair with the
  stand-in Mac a second time; the recording opened from the Dock); a card for a pick that isn't
  open wasn't shot. `DesktopWindowUITests` (a paired `mpctl serve`, Claude open).

### Back without a hitch

Round 2's "return-without-a-hitch" stream (Sameer: "the apps layout was jumping around and was not
reliable"). Frames: `docs/screens/overnight-nov7/round-2/return-without-a-hitch/`.
- **A return grace** (`AppModel`, "Back without a hitch"). The link is let go in the background
  and made again on return (~400 ms on home Wi-Fi), and every return flashed "Reconnecting to
  ‹Mac›…", a dimmed Whole Screen and Mac Controls, the eye badge gone from the pick, the pill's
  light grey. Now `returning` is set the moment the app leaves with the link up (`holdLooks` in
  `scenePhaseChanged(.background)` — the app switcher's snapshot and the first frame back show
  the populated bar; the link's states while away change nothing on screen) and ends on the
  connect or `returnGrace` (1.5 s) after the scene is active again; only then is a link still
  down a reconnect (`beginReconnecting`, as a drop while here). `looksConnected` =
  `isConnected || returning || (settling && connectedLastSession)` (`link.wasConnected`, written
  on connect, cleared on not found / unpaired) is for **looks only**: the Dock's eye badge, needs
  marks and window previews, the menu bar's extras (`PhoneMenuBar`), the cover bar's items and
  `CoverMacItem`, the pill's light and glyph (`shownRoute` = the live route, else `lastRoute`),
  the cover tiles, `DesktopTrouble`. The status line keeps the words it had on leaving (the
  `.connected` branch also matches `returning`; never "Connecting…"). An action needing the link
  waits: the eye / a tile tapped again calls `watchWhenConnected`, which keeps `waitingWatch`
  and opens it on the connect (dropped only if the reconnect limit passes). A watched window:
  `Watcher.sceneBecameActive(quietFor:)` sets `quietUntil`, and `WatchPanel`'s capsule waits
  `capsuleWait` (the longer of `WatchReconnect.quietFor` and what's left of the grace) — the held
  picture stays bare through it; a real drop while active (`beginReconnecting` clears
  `quietUntil`) shows it after 0.5 s as before. Proven on an iPhone 17 Pro simulator against
  `mpctl serve`, recorded (`simctl io recordVideo`, 4 fps tiles): before, "Reconnecting to…"
  under the mic for ~1 s on every return; after, nothing — unless the link really takes longer
  than the grace (this Mac, loaded with seven serves, took 2–8 s some runs: then the line comes
  at 1.5 s and goes on the connect, the extras dim with it). Serve killed while away: the grace,
  then "Reconnecting to ‹Mac›…"; serve back: connected.
- **Settings' first frame, measured, not fixed.** `HITCH sheet@settings` on the Pro: 389 ms the
  first open, 153–167 ms after (before); 395 / 154–165 (after). `sample` of the open: no app
  code in the top frames — ~200 ms is `CABackingStoreUpdate_` waiting on the render server
  (`CA::Render::Context::wait_for_synchronize`, the simulator's software renderer) and ~125 ms
  SwiftUI laying out the Form's cells (`UICollectionView` list cells measured one by one,
  `_UIHostingView.layoutSubviews`). What moved anyway: `refreshAvailability()` runs 0.6 s after
  the sheet rises (`.task`), not in `onAppear`'s pass, and the Thread's display link pauses under
  a sheet that covers the screen (`AppSheet.coversScreen` → `threadPaused`; `ThreadView.tick` was
  36 of the main thread's samples while the sheet came up). Needs his phone (Release, a real
  render server) before chasing it further; the under-100 ms target wasn't met here.
- **The cover's sheets beside the vertical bar** (`InnerScreenSheet`'s cover branch, iOS 27.1,
  `VerticalBarProbe.edge` / `.width`): the system already lays a sheet's content beside the
  bar's column and vends its Done / × into the column (as the main screen's items), but the
  sheet's white ran the full width under the clock and Wi-Fi. Now the sheet's ground is cleared
  (`presentationBackground(.clear)`) and a card of the system's ground (grouped for Settings /
  History, plain for the rest) is drawn beside the column with the sheet's top corners; Settings
  hides the Form's own ground there (`scrollContentBackground(.hidden)`). Pairing's inline title
  is a `.principal` item on the cover, so it reads centred as on every other iPhone. Tried and
  dropped: padding the content itself by the bar's width — the NavigationStack inside still
  reserves the column from its own bounds (the trait says the bar is there), so the form came out
  230 pt wide. Inner-screen sheets and every other iPhone are untouched.
- Hooks / scripts used: `MACROPHONE_HITCH=1 MACROPHONE_WATCH=rest MACROPHONE_WATCH_ACTIONS=
  sheet@settings,sheet@none,…`; the return is `simctl launch com.apple.Preferences`, a wait, then
  `simctl launch com.sameer.macrophone` under `recordVideo`.

### Attach and Send after pasting, in plain sight

Sameer: "doesn't have perspective on what should be easy to access vs buried in a menu". The two
things a developer uses every dictation are now one obvious tap in every state. Wins over the map's
"⋯ = Send a Photo… · Send a File… · …" and the Window menu's photo / file / clipboard items.
Frames: `docs/screens/overnight-nov7/round-2/attach-and-send-toggle/`.
- **Send after pasting is `SendToggle`** (QuickControls.swift): one button that says its state —
  "Paste only" (`paperplane`, ink) or "Paste & Send" (`paperplane.fill`, white on a capsule of the
  accent, like the lit answer and `DuoModeBar`). Both words are laid in one `ZStack`, so a flip never
  changes the bar's width. `Haptics.pick`, `setSend`, `explain`, the plane hops on turning on and on
  a sent landing. VoiceOver: label "Send after pasting", value On / Off, `.isToggle`, the hint the
  place's detail; id `send-toggle` (UI tests find it with `descendants(matching: .any)`, not
  `switches`). **Hidden, not greyed, where the pick can't send** (the Clipboard). `short: true` says
  "Send" with the lit state (the last fallback). `OptionsRow` (the unpaired panel, the cover's old
  panel) uses it too.
- **`DockOptions`** (Desktop.swift) is [Send toggle] · [Cleanup ⌄] · [📎 Attach]; the words give
  way in order: "Cleanup:" → Attach's word → the toggle's. A Pro keeps "Paste only · Medium ·
  Attach"; a level longer than Medium or the simulator's "Cleanup off" drops Attach's word.
- **`AttachMenu`** (SendToMac.swift, id `attach-menu`; styles `.labelled`, `.glyph`, `.round`,
  `.cell(height:)`, `.bar`): the paperclip over `MacShareItems`, now Photo… · File… (under "Into
  ‹app›", or "To your Mac's Downloads" where `SaveToDownloads.isDefault`) · Save to Mac's Downloads ›
  (chats) · Clipboard: Send Clipboard to Mac · Copy Mac's Clipboard. Shown when the Mac can attach or
  share the clipboard. The pickers stay with the binding's owner (`macSharePickers`), outside any
  `ViewThatFits` that lays a menu out more than once.
- **Where it is:** at rest by the Dock (phone, cover, the inner screen's cover half); watching on a
  phone or the cover it **leads the key row** [📎] [Esc ↑ ↓ ⏎ ···] [Pan|Scroll] (`WatchActions
  .keyRow`; the keys keep 200 pt before Pan | Scroll turns to glyphs, then the gaps tighten — an SE
  fits); while answers show, "Keys" brings it back. In hand on the Duo's inner screen it's a cell in
  the deck's header beside Window (`WatchHeaderBar.attachHere` = `dragSwitch`: the laptop's deck,
  flat upright; on the book, where the bar holds the window's buttons, at the header's end). Full
  screen: none (nothing over the window). A photo or file sent while watching still goes into the
  watched window's chat (`attachTarget`).
- **Gone:** the Window menu's share items (it's about the window now: alerts, fit, text size, sizes,
  minimize / close, tips), the cover bar's ⋯ at rest (Attach is by its Dock), the Send to panel's ⋯
  and round Refresh (the panel's Attach is `.round`). **Refresh Open Apps lives in Open an App**:
  pull to refresh, a toolbar button (`refresh-apps`), and a fresh look every time the sheet opens.
- Proven on an iPhone 17 Pro (and the SE frame), light and dark, against `mpctl serve --save-to`:
  `MACROPHONE_SEND_FILE=attach-notes.txt` landed ("ATTACHMENT saved 25 bytes as attach-notes.txt");
  `MacrophoneUITests.testAttachMenu` (`TEST_RUNNER_MACROPHONE_LIVE=1`, `…_ATTACH_SHOTS=<dir>`,
  `…_ATTACH_FILE=<name>`, `…_ATTACH_FRAME=375x667`) opens Attach at rest and in the key row, opens
  the file picker from File…, and checks the Window menu has no share items. The simulator's file
  browser doesn't list the app's Documents, so the pick itself is the hook's. On a Duo simulator:
  the cover at rest and watching, the laptop's and the book's header.

### Undo you can reach

Sameer's round-2 emphasis ("what's primary vs buried … Undo kept longer"): the Mac undoes its last
paste for 30 s (`UndoPaste.window`), but the phone offered Undo on the landed pill for 5 s and the
pill hung over the mic's ring and bloom. Now, one path in AppModel (`undo(id:)`, `undoable`,
`canUndo(_:)`; the chip, a shake and History all use it; it refuses after the window):
- **The pill, then the chip.** **[superseded Nov 7 2026, round 4: both sit in the status line's slot under the mic, the chip is "Undo Paste" — see round 4]** The landed pill rises as before (2.2 s, `AppModel.pillHold`; its
  foot now 18 pt clear of the ring at every mic size — `landedPill(size:)`, the frame is 1.25 × the
  disc and the ring 6 pt outside it). **[the guide was ignored; an offset since the merge — see round 2's integration note]** For a paste the Mac can take back (`LandedChip.canUndo`) it
  then shrinks into **`UndoChip`** (MainView.swift: `arrow.uturn.backward` + Undo on glass, 28 pt,
  `landed-undo-chip`) — a `matchedGeometryEffect` pair in `micSpace` (`LandedMatch`; Reduce
  Motion: a fade). The chip sits at the trailing end of the Thread's band, centred on it
  (`View.undoChip`, on `threadBand`), where the mic's bloom never reaches; it never moves the mic,
  the Thread or the status line. It stays until `AppModel.undoLife` (28 s — a breath under the
  Mac's own 30) after the landing, the next dictation, the next landing or Undo, and fades to 0.55
  for its last 5 s (`chipFade`). On the cover while watching it takes the status line's place under
  the mic row, as the pill does; on the Duo's inner screen the cover's view has the same Thread
  band; in full screen it floats just above the mic's lip (`FloatingMic`). A new landing or a
  landing that failed clears the one before (`rememberUndoable`); the Mac undoes only its last.
- **Shake to Undo** (`UI/ShakeToUndo.swift`): while the pill or chip is up, a shake asks "Undo
  Paste into ‹App›?" (Undo · Cancel, a UIAlertController over whatever's in front), only while the
  system's Shake to Undo is on (`UIAccessibility.isShakeToUndoEnabled`). Heard at the end of the
  responder chain — `AppDelegate` is a `UIResponder` now (one word in DuoView.swift) and the override
  lives in the extension — so nothing takes first responder from the keyboard's field or
  `HardwareKeysView`.
- **History**: while a dictation is the Mac's last paste and still undoable, its row's leading swipe
  offers **Undo Paste** first (`history-undo`, ember; a full swipe never undoes by accident), the
  context menu too, and `HistoryPage`'s bottom bar has Undo Paste before Send Again
  (`history-page-undo`). After an undo the row reads "Undone from the phone" (`AppModel.undoneWords`,
  `HistoryItem.wasUndone`; `Landing.chip` / `.sentence` pass it through; the mark is the uturn arrow).
- **Hooks**: `MACROPHONE_WATCH_ACTIONS=…,undo,shake`; `MACROPHONE_UNDO_LIFE=<s>` shortens the chip's
  life (DEBUG). Log lines carry seconds only ("undo asked 12s after the landing"). `UndoChipUITests`
  (a paired `mpctl serve`): the pill → the chip, clear of the mic, out at its life's end with the mic
  unmoved; the chip's Undo reaches the Mac (`UNDO <id>` in serve's log); a shake asks; History offers
  Undo Paste only while it can. Frames: `docs/screens/overnight-nov7/round-2/undo-you-can-reach/`.
- Left: a window in hand on the inner screen (the laptop's mic mode, the book's column —
  `DuoLaptopDeck` / `DuoDeck`) draws its own mic with no Thread band, so the chip isn't placed
  there — the pill, a shake and History still work there; the cover-watching frame in the folder
  caught the Clipboard pick (no undoable paste), so that placement is by code only; `mpctl serve`'s stdout is
  block-buffered to a file, so its `LANDED` line lands late — time a shot from the phone's
  diagnostics log instead.

## Overnight polish, round 3 (Nov 7 2026)

Round 3 of the overnight passes (Sameer's goal as in round 1). Emphasis: the Duo's inner screen as a
mini Mac that never jumps, and the window view's touch targets, Mac Keys and VoiceOver basics. Four
streams, merged together; frames `docs/screens/overnight-nov7/round-3/<stream>/`. In one breath:
- **One deck on every inner pose** (`DuoDeck.modes`): the book and flat on its side get the laptop's
  deck — one mode at a time filling the page, `DuoModeBar` (Trackpad · Mic · Keyboard) at its foot,
  a glass **+** = Open an App (`deck-open-app`). `DuoLaptopDeck.swift` (the column of keycaps, the
  lone ⌘ pill, Send to's menu) is deleted; the inner vertical bar has no Keyboard item (the cover
  keeps it). The laptop's answers row hides whole while the keyboard is asked for or up.
- **Typing never moves the Mac's screen:** the book keeps both pages and the crease, only their
  heights giving way to the keyboard's top on its own curve; upright the Mac's half is laid out from
  its rest room (left, width, scale and top fixed; only its foot gives way where the keyboard reaches
  over the fold, never below half — `DuoLook.keyboardGap`, `typingMacFloor`); the zoom holds
  ("viewer: the keyboard came/went — zoom X before, Y after"). `MACROPHONE_SEND_TO=screen` works.
- **The inner screen settles:** the one mic (`InnerMic`) shows only in a slot that has held still
  two frames with no fold in the last 0.45 s and no keyboard moving; it fades in there, glides only
  between settled slots in one pose, and a finger on it keeps it. A folded launch (laptop, book)
  goes straight to the window in hand on its kept picture (`Posture.provisional`: a pose guessed
  before the hinge reading stays hidden and untouchable, 0.3 s at most). Full screen's floating mic
  starts at the right edge, halfway down.
- **The window view's basics:** 44 pt touch targets with no layout change (`WatchLook.reach`,
  `View.watchTouch`, 6 pt either side); Mac Keys is a text key ("Mac" / "ABC"); `esc` one way
  (VoiceOver: "Escape"); chips read "1, Yes", the highlighted one selected; the cover bar's Sound and
  Alerts say On / Off. `accessibilityGone(_:)` (UI/AccessibilityGone.swift) is the one seam for a
  hidden layer — `OutOfReach` and `KeptHidden` go through it.
- **Integration (this merge):** the builders branched before round 2 — `InnerMic` keeps round 2's
  `landedPill(size:namespace:)` (at `placedSize`), and the settings layer keeps round 2's
  `OutOfReach` (now via `accessibilityGone`). Smoke-tested on a Duo (cover; flat on its side, flat
  upright and the laptop with a window in hand through every mode, typing — `WATCH TYPE` — and Done;
  a cold folded launch in dark; unfold to the glance) and an iPhone 17 Pro in dark, against `mpctl
  serve`: the book kept its pages with the mode bar over the keyboard, flat upright and the laptop
  kept the window's top while typing, the laptop opened straight in hand, nothing regressed seen.
- **Needs a real Duo / phone:** the 50 ms bar delay on its side in Release; the hinge reading's
  timing at launch (`Posture.provisional`); the Mac Keys input-assistant band (~57 pt) that makes
  both keyboards reach ~68 pt over the fold on the laptop (subtracting it in `MacKeyboardView`'s cap
  would leave the Mac's half whole); whether real VoiceOver skips the hidden layers (the XCUITest
  tree and `performAccessibilityAudit` list them whatever `.accessibilityHidden` says).
  **Open:** a folded cold launch opens before the link is up, so `Watcher` shows "Reconnecting…"
  over the kept picture on a slow connect (it should say nothing, or "Connecting"); a stale app list
  can open a watch the Mac reports unavailable; `DuoUITests` open portrait (Send to 276 < 306) still
  fails; `FullScreenUITests`, `StabilityUITests`, `HardwareKeyboardUITests` weren't re-run.

### One deck on every inner pose

Sameer's brief that night: "The app often doesn't have perspective on what should be easy to access
vs buried in a menu", and folding the Duo 90° changed the whole control model — the laptop's deck
was one mode at a time, the side page a column of everything at once (a Keyboard button, a lone ⌘
pill for Mac Keys, keycaps, the trackpad, a Send to menu, the mic) with a second Keyboard button in
the vertical bar. Now one vocabulary wherever the screen is. Frames:
`docs/screens/overnight-nov7/round-3/duo-one-deck/`.
- **`DuoDeck.modes`** (UI/DuoView.swift) is the deck in hand on every inner pose (`vertical` = the
  side page): one mode at a time filling the room — the trackpad edge to edge, the mic with the
  Thread across it (`carousel(fill:compact:rowHidden: true)`), or the iOS keyboard — and
  `DuoModeBar` at its foot (same segments, order, symbols, `input-pages`). The laptop adds its
  answers row on top and `WatchHeaderBar` under the modes; the side page has neither (its name is a
  row over the picture, its answers a row under it, its controls in the vertical bar), and lines up
  with the left page (`DuoLook.edgeInset` top and bottom). `DuoLaptopDeck.swift` is deleted with
  `DeckKeys`, `Keycap`/`KeycapStyle`, `RepeatKeycap`, `DeckFnKey`, `DeckSendTo`, `DeckLook` and
  `keepTrackpad` (the deck remembers its mode per pose as before: `duo.deck.book` on its side, the
  trackpad the first time). Mac Keys lives in the keyboard bar's toggle only.
- **Open an App** with a window in hand: a 44 pt glass **+** at the end of the mode row
  (`deck-open-app`), the modes centred between it and its twin's width — the window's name menu
  lists only open apps, and Send to's menu is gone from the deck.
- **The vertical bar drops Keyboard on the inner screen** (`coverToolbar`: `!posture.pose.isInner`);
  the cover keeps it, and within a pose the set still never comes or goes.
- **The laptop's answers row** hides whole the moment the keyboard is asked for or up
  (`input.page == .keyboard || input.keysUp`), out in `Motion.leave`, back (Esc first) only when
  both are false — so whenever it shows `keysUp` is false and its chips never change; the deck's
  height never changes, so the window never moves.
- **Keyboard picked, keyboard not up yet:** the Thread fades with the mic page in `Motion.leave`
  (in `carousel`, `rowHidden` only) and a quiet keyboard glyph and "Keyboard" (Ink.tertiary) sit in
  the room until the keys rise. With the keyboard up on the side page the carousel draws nothing and
  only the mode row shows over the keyboard (once `sideBody` gives the deck a room ending at the
  keyboard's top — the duo-inner-typing stream; in this branch the page is still 0 wide while typing).
- **The mic's slot on a deck is laid at its settled place** (an overlay on the carousel at
  `threadTop + slot + 8`, the mic page keeping an empty frame there): it had ridden the Thread's slot
  opening on the spring, so the one mic showed at the room's top and slid down every time the mic
  mode came.
- **`DuoModeBar`** is as wide as its content and centred (segments = glyph + word + 14 pt a side,
  min 56), glyphs only where the words don't fit (`ViewThatFits` — the side page, ~300 pt). Still one
  adjustable "Input" for VoiceOver; `MACROPHONE_MODE_SEGMENTS=1` (set by `DuoUITests`) exposes the
  segments as `input-mode-<page>` buttons so tests tap them by id, never by position.
- **Seen, not fixed:** on the simulator the app's first frame after a page change lands ~3 frames
  after the keyboard starts rising, so on the laptop the answers' fade overlaps the bar's first rise;
  the laptop still grows the window over the keyboard (the duo-inner-typing stream's).
  `DuoUITests`: the book, flat-landscape and laptop tests pass with the new deck (≥ 80% of the
  page, the mode bar under it, no column ids; the laptop's answers gone while the keyboard is up and
  back Esc first, `duo-window` unmoved); flat portrait's older failure (Send to 276 < 306) stands.

### Typing on the inner screen never moves the Mac's screen

Round 3's `duo-inner-typing` stream. Found frame by frame on a Duo simulator (`vid/…` under the
round's scratch, 3 fps): on the book the keyboard rising gave the Mac's window the *whole* width
(the code assumed "the keyboard is the screen's width"; iOS splits it at the hinge), so the picture
stretched across the crease at twice the zoom each way and the right page vanished; on the laptop
the top half took "everything above the keyboard", so the Whole Screen was re-measured from the
shorter room and shrank from 579 to ~480 pt wide, re-centred (the spec's `p2laptop/t82 → t84`).
Now (`UI/DuoView.swift`, `sideBody` / `laptopBody`; frames `docs/screens/overnight-nov7/round-3/
duo-inner-typing/`):
- **The book stays a book** (and flat on its side — one layout): while typing each page keeps its
  width and the crease between them; only their heights give way to the keyboard's top
  (`keyboardTop(in:)` − `DuoLook.keyboardGap`), in the keyboard's own motion (`keysUp` and
  `keyboardRoom` change inside it — no spring of our own). The deck is framed to end at the
  keyboard's top, never to width 0 (its field hosts the keyboard); what it shows above the keys
  is the deck's own business. The answers row under the picture keeps its chips (Esc rides the
  keyboard's bar, as on every screen).
- **The laptop (and flat upright) is a Mac's screen**: the room at rest (`restMac` · `restGap` ·
  `restDeck`) is computed once, untouched by the keyboard. The deck ends at the keyboard's top;
  only where the keyboard reaches up past the fold does the Mac's frame give room, from its foot
  only, never below `DuoLook.typingMacFloor` (half) of its rest. A window's frame shortens from the
  bottom, so the viewer keeps its zoom and the bottom if it showed (the composer stays above the
  keys); the Whole Screen is sized from the rest room and sits in a frame clipped from the bottom
  — the keyboard's band hides its foot instead of shrinking it. Width, scale and top edge never
  change for either keyboard.
- **The viewer says so** (`ViewerScrollView.keyboardUp`): "viewer: the keyboard came/went — zoom
  X before, Y after (view H → H pt)" 1.2 s after each flip. Measured: the book 0.559 → 0.559
  (471 → 198 pt), the laptop 0.461 → 0.461 (367 → 307 pt), iOS's keyboard and Mac Keys alike;
  `mpctl serve` printed one `WATCH SHAPE` per window opened and none for five keyboard rises.
- **Why Mac Keys lost the title bar** (the spec's d): not a push — on the folded laptop the
  keyboard's frame reaches ~68 pt above the fold (the ~55 pt band iOS keeps above its keys off the
  hinge, plus the gap), the same for iOS's keys and the Mac's (the host takes the measured iOS
  height, capped to the half), so the window's foot gives 60 pt and `keepZoom` keeps the bottom —
  the title bar scrolls up out of a shorter view, by design. The top never moves.
- `MACROPHONE_SEND_TO=screen` now picks the Whole Screen (the hook had no such case, so the
  earlier "Whole Screen" runs were Claude's window). `DuoTypingUITests`
  (`TEST_RUNNER_MACROPHONE_DUO_REAL=book|laptop`, the real pose): Claude and the Whole Screen, Mac
  Keys off and on — the window's left, width and top unchanged (±1), the book's window never past
  the screen's middle, back to its rest frame after hide; it prints where the keyboard's bar lands
  against the fold. Measured on the laptop (tabletop): Claude (12, 88, 645 × 368) → 645 × 308,
  the Whole Screen (44, 83, 581 × 373) unchanged, the bar's top at 408 of 951 (the fold at 475)
  with either keyboard.

### The Duo's inner screen settles

Nothing on the inner screen shows in the wrong place. Frames: `docs/screens/overnight-nov7/round-3/duo-inner-settle/`.
- **The one mic only shows in a settled slot** (`InnerMic`, DuoView.swift): a slot's frame counts once it has held
  still for two display frames (`still`) with nothing on its way — no pose change in the last `poseQuiet` (0.45 s),
  the keyboard not coming or going (`keyboardQuiet` 0.35 s after `keysUp` changes; the keyboard page's keyboard still
  up after the page left it, for 0.6 s at most). From hidden it's placed, then faded in there (0.15 s, the next
  frame); it glides only from a slot it showed in to another in the same pose; a pose change hides it at once (in the
  same frame — `placedPose` must be the pose) until the new slot settles. A finger on it (`holding`,
  `stopOnRelease`) keeps it shown and following its slot. Before: on the laptop, keyboard → mic, the disc sat on the
  Mac window's text for half a second; unfolding, it appeared over the glance and flew right. `micSlot` / `MicSlot`
  / `micOwner` unchanged.
- **Folded is the window in hand from the first frame** (`AppModel.openWindowForPose`): folded (the laptop, the
  book) and paired, it opens before the link is up — the watch holds the kept picture and asks again when connected;
  the pick's open state from the last list (unknown: open anyway), the whole screen from `bar.had.wholeScreen`. Flat
  still waits for the link (the glance). `poseChanged` opens on folding with nothing open too: at launch the first
  pose is guessed flat from the screen's size (`portrait (0×0)` in the log), then the laptop. **Seen, not fixed
  (Watcher's, round 2's):** with the link slow, the held picture dims under "Reconnecting…" (`Watcher.start` with no
  link → `beginReconnecting`) until the Mac answers — on a cold launch it should say nothing, or "Connecting".
- **No frame from a guessed pose** (`Posture.provisional`): the inner screen measured before the hinge has spoken
  (the no-hinge rule says "open") hides the layout (`MainView.poseBody`) until the hinge speaks or `hingeWait`
  (0.3 s) passes.
- **The side bar changes with the deck** (`MainView.innerBarWindow`, `followBar`): on its side, Show it here changes
  the vertical bar's set 50 ms after the tap (it led the deck's fade by ~0.2 s on the simulator; 120 ms trailed it by
  as much); Done and a pose change at once. The cover and upright are untouched (`barWindow`).
- **A turn removes the old layout at once** (`MainView.turn`: insertion fades, removal is identity). Closed →
  portrait still shows a stranded "Show it here" and a faint mic for a moment: that's the system's rotation
  snapshot (the old landscape frame, rotated, fading) — the same before and after.
- **Full screen's floating mic starts at the right edge, halfway down** (`FloatingMic`, `duo.fullscreen.mic.x/y`
  1.0 / 0.5 — bottom-right sat on a chat's Send button); a saved place stays; a drag moves it from where it rests
  (`home`), even from the clamped edge.
- Tests: `DuoSettleUITests` (a real Duo sim in a real pose, `TEST_RUNNER_MACROPHONE_DUO_REAL=laptop|book`, a paired
  `mpctl serve`): a folded launch never shows the glance (`duo-show`) or `send-toggle` while `duo-window` comes; on
  the laptop, mic mode → keyboard → hide, every frame the mic reports is its last. **Found, not fixed:** XCUITest
  still lists the hidden desktop's Dock (`places`, a scroll view in the `KeptHidden` rest layer) under the window in
  hand, and `mic-button` while the keyboard is up (the one mic at opacity 0, `accessibilityHidden(!visible)`) — check
  with VoiceOver whether they're reachable (the window-targets-voiceover stream's area); the test checks `duo-show`.

### The window view's basics: touch targets, Mac Keys, VoiceOver

Stream `window-targets-voiceover`. Frames and the trees / audits before | after:
`docs/screens/overnight-nov7/round-3/window-targets-voiceover/`.
- **44 pt targets, the layout untouched** (`WatchLook.reach` 6, `View.watchTouch`): every button in
  the window view — the header's cells (name menu, Sound, Mac Controls, zoom out, Window, Done),
  the key row, the answer chips, Pan | Scroll's options, the keyboard bar's cells — gets real
  vertical padding that is then given back to the layout, so the glass keeps its 32 / 38 and the
  row its height (a Menu's UIKit button takes padding where a `contentShape` past the frame
  wouldn't). It reaches into the rows' own gaps (6–8 pt), never into a neighbour beside it, never
  over the window. `WatchChipScroller` grows by the same reach (a scroll view takes no touch
  outside its bounds) and gives it back. Not yet proven by coordinate taps: WatchHeaderUITests
  ran green on the frame, the tap-5-pt-outside test is still to write.
- **Mac Keys is a text key**, like the system keyboard's "123" / "ABC": "Mac" while iOS's keyboard
  is up, "ABC" while the Mac's is — plain, never lit (it switches layers; it isn't a light). It
  had been ⌘, which with Mac Keys up put two ⌘ on screen with two meanings. Label "Mac Keys",
  value on / off, id `keyboard-mac-keys` unchanged.
- **"esc"** everywhere visible (the key row, the answers row, the bar, the keycaps); VoiceOver says
  "Escape". **Answer chips** read "1, Yes"; the one Return would pick is `.isSelected` with the
  value "Highlighted on your Mac". In the answers row **Pan | Scroll** collapses to glyphs as the
  key row does when the answers would keep under 250 pt (`ViewThatFits`, the scroller's ideal
  width 250): words on a Pro, glyphs on an SE. The cover bar's Sound and Alerts items say On / Off.
- **Hidden layers in the accessibility tree — the finding** (`UI/AccessibilityGone.swift`,
  `accessibilityGone(_:)`, used on the phone's settings layer under a window, the carousel's pages
  and row, `KeptHidden`): on the iOS 27 simulator the XCUITest snapshot and
  `performAccessibilityAudit` list SwiftUI's nodes whatever `.accessibilityHidden` says — the Mac
  pill (a plain Button) under a window, the blank status placeholder, the delivered check, the
  edge strips, `.accessibilityElement(children: .ignore)`'s children: all in every tree, all
  audited ("Contrast failed" for "Send" under the window). So the audit is not VoiceOver's view,
  and nothing short of not building a subtree (or `.hidden()`) takes a node out of it. A pair of
  sentinel platform views hiding the UIKit views between them changed nothing (the sentinels
  showed as empty nodes; the hosts aren't siblings of the content's views) and was dropped. What
  does go: `DeliveredCheck` is built only while it shows, and the status slot's blank
  placeholder is `.hidden()`. `AccessibilityTreeUITests` keeps each state's tree, audit and
  frame (`TEST_RUNNER_MACROPHONE_TREE_DIR`) and its assertions say what is still in the tree — it
  fails on main and on this branch for the desktop under a window (by design: it's the record).
  Whether VoiceOver itself stops on those layers needs a device with VoiceOver on, or the
  Accessibility Inspector on a simulator; neither was run.
## The laptop's picture from the screen's top edge (Nov 7 2026)

Sameer, on his Duo with build 11: "In laptop view, the window has gotten smaller … to accommodate
the iPhone's time and status bar. I would rather not accommodate those elements … fill up as much
of the screen without being cut off by the Duo's rounded corners." Wins over round 1's "only full
screen hides it". Frames: `docs/screens/duo/nov7-laptop-fill/` (the 55 pt corners drawn on).
- **Upright with a window in hand the status bar is hidden** (`MainView.hidesStatusBar`: full
  screen, or `pose.foldAcross && watcher.isShowing` — the laptop and flat upright). At rest it
  shows as before. The picture's top sits `uprightPictureTop` down: `DuoLook.cornerClear(side: 12)`
  = 21 pt hidden (the square corner point on the 55 pt curve, the sides keeping the deck's 12),
  6 under the status bar. Square, not concentric: a rounded plate would cut the traffic lights.
- **The band was SwiftUI's root, not the layout** (measured with probes on a real Duo sim pose):
  hiding the status bar there, the window's and the hosting view's safe area go to 0 but SwiftUI's
  root keeps laying the app out from y = 82 with no inset left to reach into (a full-screen
  `ignoresSafeArea()` reader reports its global minY as 82). `StatusBarRoomFix` (RootView) reads
  that minY and pads the root's top by minus it — 0 on every other screen and pose. Proven on
  `duo-sim.sh` tabletop / portrait / closed (launch folded, unfold, fold flat and back, close and
  reopen, trackpad / mic / keyboard, Done and Show it here): no band frame, the top settles at 21.
- **Mic, seen while there (not this change's):** on the inner screen the one mic sometimes shows at
  a stale slot (over the glance's app icon) for ~0.5 s after an unfold and then glides down to its
  slot; on Show it here it rises ~85 pt as the cover's view is re-laid in the shorter in-hand deck
  before the fade; after Done it comes in low (behind the bottom toolbar) and rises ~65 pt over
  0.6 s. Also a transient bottom inset of 82 (34 + a 48 pt bottom bar) for ~0.1 s at launch and
  after an unfold, which shrinks the whole root for that moment. Same on build 11 (baseline run).
  **[The mic part is fixed — see the next section.]**

## The inner mic and the laptop, verified on a Duo sim (Nov 7 2026)

Sameer on build 11: "In both modes [inner portrait and laptop] the mic button seems to shift up and
then come down to its appropriate place after about a second." Round 3's settle and the laptop fill
were checked on a real `duo-sim.sh` pose against `mpctl serve`, every frame of the inner display
recorded and the mic found in each (frames `docs/screens/duo/nov7-verify/`, before | after). Three
causes were left, all the system re-laying the screen a pass or more *after* the slot had settled:
- **The vertical bar's room outlived the turn.** Upright from a pose with a vertical bar (the
  simulator unfolds through landscape; the cover has one too) the inner NavigationStack kept the
  bar's 84 pt trailing inset for ~0.6–0.85 s: the laptop's window and deck laid out 585 wide and then
  sprang to 669, and the mic, shown in the narrow layout, glided 57 pt across after. Upright the
  content now ignores the horizontal safe area (`innerBarred`: `.ignoresSafeArea(.container, edges:
  foldAcross ? .horizontal : [])`) — upright has none of its own.
- **The bar's lower group arrives late at the foot** (flat upright at rest: Whole Screen · Mac
  Controls), ~0.4 s after the turn, and only the mic's slot moves (the bar's 48 pt; all above stays).
  `InnerMic` waits for it when it's due (`MainView.uprightFootBar` and the room's bottom inset under
  `footBarRoom`, `barWait` 1.5 s at most), and any change of its own room (`RoomKey`: its frame and
  insets) restarts the stillness and adds `roomQuiet` (0.3 s — the halves are published a pass
  later, then spring). Shown, a room change makes it move in step with the slot (`follow`), never
  glide after it.
- **In hand ↔ at rest:** Show it here hid the mic with a fade that began under a busy main thread
  and drew after the status bar's 82 pt had gone — one opaque frame 82 pt up; Done showed it in the
  hidden rest layer's old frame (100 pt low) and it rose for up to 2 s. Now `watcher.isShowing`
  hides it at once, the owner (`placedOwner`, rest or hand) is checked in the body like the pose (so
  no frame shows it in the other layout's place), and it waits `poseQuiet` before its new slot.
  It no longer glides between rest and hand — it fades in where it stays. `still` is 0.1 s (a busy
  main thread spaced a spring's frames past two display frames, and it took a mid-spring frame).
- A slot laid out off the screen (negative origin, a layout measured mid-turn) never counts.
- **Seen, per path, after:** cold launch flat upright and laptop, unfold closed → flat upright and →
  laptop (at rest and with a window in hand), Show it here / Done ×3, the laptop's trackpad · mic ·
  keyboard switches, laptop → flat upright → laptop: the mic only ever appears where it stays
  (after Done ~0.6 s with no mic, then a fade in place). Once, on the first unfold after a launch, it
  showed 8 pt low at a spring's tail and settled over 0.25 s. The laptop in hand: no status bar,
  the picture 21 pt from the top, full width from the first frame, the top edge unmoved by the
  keyboard (its foot gives way as designed).
- **Left (simulator):** `duo-sim.sh` unfolds through a landscape pose for ~1 s, so the side layout
  (and its mic, cut at the edge) shows in the system's rotation; whether a real unfold does is his
  phone's to say. On Show it here the cover's view drops its "Paste only" row and shifts 25 pt for
  two frames before its fade (the bottom bar going). With the simulator's hardware keyboard
  connected a fold always opens the deck on the trackpad (`deckPage`), so the mic mode after an
  unfold needs `page@mic` (or a run with `GCKeyboard` kept out).

## Overnight polish, round 4 (Nov 7 2026)

Round 4 of the overnight passes (Sameer's goal as in round 1). Emphasis: polish what round 2 added
and the everyday flows on the regular iPhone and the Duo's cover. Four streams, merged together;
frames `docs/screens/overnight-nov7/round-4/<stream>/`. Wins over round 2 where they differ.
- **The desktop card is App Exposé's thumbnail** (`DesktopWindowCard`): the kept picture whole
  (corner 12, a 0.5 pt `Ink.line` edge, a shadow) — so the Mac window's own title bar is the only
  one — a caption under it (icon · name · title · bell · Answered you), a decorative glass `eye`
  badge in its corner; the whole card is the button. Nothing kept, or not open: a plate of regular
  material, at most 180 pt (and half the room), never black in dark; not open adds Open. Centred in
  the room with `DesktopWindowLook.air` (24 pt) above and below. No `MacWindowFrame`, no Watch
  capsule. The Dock's pick has no eye badge; its second tap still watches (`DockSpot.watchedAt`).
- **Only the picture flies on open and Done** (`UI/MacOS/WindowZoom.swift`): `DockZoom` is a fade
  only now (`asleep` 0.001; once faded the hidden panel is parked at 0.02 scale —
  `WindowZoom.panelParked` — so XCUITest doesn't take it as covering the desktop). `liftFromCard`
  on the card's tap; `opened` aims at an estimate, then re-aims 50 ms in at the real viewer
  (`viewerPlace` reads `ViewerScrollView`'s canvas through UIKit, so it lands on the viewer's zoom
  and scroll; an estimate from the layout if the viewer is restructured); the chrome fades in at
  0.28 s (`holdsPanel`), the flight hands over at 0.38 s. `closing` measures the viewer, fades the
  view in `Motion.leave` (its header kept, `leaving`) and flies home — into the card, or the icon
  if the Dock's tap opened it. `DesktopWindowSpot.frame` is the picture's rect; the card hides its
  picture while a flight is up (`cardHidden`). No flight on the cover, the inner screen, with
  Reduce Motion or for the live words (`MainView.flightAllowed`): the fade as before.
- **One confirmation for a landing, in the status line's place** (`LandedSlot` under the mic on
  every phone layout, the cover's already did): the Thread's check hides while the pill shows;
  after 2.2 s the pill becomes **"↶ Undo Paste"** in the same spot (`UndoChip`: 44 pt target drawn
  32 tall, a ring round the arrow draining over the undo life — static under Reduce Motion — fading
  its last 5 s). The mic and the Thread never move. After Undo: "Undone", then "Took the paste out
  of ‹App›" in teal (a scheduled status reset had wiped it early). On the inner screen the cover's
  view at rest uses the slot; in hand the one mic floats the pill (`InnerMic`, `landedPill(on:
  want.hasSuffix("/hand"))` — the deck has no slot); full screen's floating mic keeps it above.
  **History** shows a bordered **Undo** at the newest row's end while the Mac can take it back, like
  Mail's Unsend (its own accessibility element; the swipe and long press keep theirs).
- **A photo or file is confirmed like a paste**: the pill with the photo itself (24 pt thumbnail,
  made off the main thread after the send) and "Added to ‹App›", a document glyph for a file,
  "Saved to your Mac's Downloads"; then "Say what it's for" in the status line (the Mac's words
  for Downloads or a failure). `attachmentsInFlight` holds the thumbnail until the landing.
- **Mac Controls' slider stands at the Mac's real volume before any touch** (MacrophoneKit
  `Core/MacVolume.swift`, `Transport/VolumeLink.swift`, feature `macVolume`): the Mac
  sends `.macVolume` after the welcome and on every change (Core Audio listeners on the default
  output's volume, mute and which device is default — `Mac/App/Core/MacReach.swift`; a burst sent
  once, 100 ms after it stops). The phone remembers each Mac's last level (opens there before the
  Mac answers; cleared for unpaired Macs when Control Center opens, `forgetVolumes`), follows
  keys pressed on the Mac, and a drag sends exactly the key presses for the distance (56% → 30% is
  4 down). Muted: the level kept, faded, the slash. Unknown (an older Mac): the empty track and
  "Press + or − to change your Mac's volume", never a guessed 0. `mpctl serve` reports 56%
  (`--no-volume` = a Mac from before, `--volume-after N` delays it); `listen --features macVolume`
  prints `VOLUME 56%`. `MacReachUITests.testTheVolumeSliderStandsAtTheMacsLevelBeforeATouch`.
- **Flipping windows goes in the Dock's order and only looks** (`AppModel.watchSessions`,
  `Watcher.watchCount`): the order is frozen for the length of a watch; a flip never changes Send
  to, the Dock's pick or the card. While a window shows, a dictation goes to it as a
  one-recording override (`AppModel.watchedPlace` → `recordingOverride`; the live words say "To
  Messages"; after Done the pick is still what it was). The Duo's inner screen still picks on flip
  (its glance and Show it here follow the pick). **A window flipped past is never reshaped**: one
  reached by a switch owes its shape only after a second on screen (`Watcher.switchedAt`, no
  `shapeAhead` on a switch), so no `WATCH SHAPE` / restore for pass-throughs — the cost is a
  visible reshape after that second. Hooks `MACROPHONE_WATCH_PACE=<s>`, `wait@<s>`.
- **The options bar reads one way in every state**: wand + level word (Off · Light · Medium ·
  Heavy · Custom), never "Cleanup:" or "Cleanup off"; every level's word is laid hidden under the
  visible one, so the bar is one width on a Pro, an SE and the cover whatever the level or Send;
  unavailable reads "Off" with a grey wand. Settings' `CleanupMenu` keeps "Cleanup: Medium" and
  says "Cleanup: Off".
- **A freshly paired Mac starts on Where I'm typing** (pasted), not the Clipboard
  (`MacPreferences.firstSelection`; stored picks untouched), so the card and the Send toggle show
  right after pairing. "Keyboard connected · typing on ‹App›" is said once per keyboard in the
  status line, never over the picture (`HardwareKeyboard.noted`, forgotten after 10 s gone; the
  simulator's keyboard connects every launch).
- **Integration (this merge):** the inner screen's pill at rest moved into the slot like the
  phone's (above). Smoke-tested on an iPhone 17 Pro (light and dark) and a Duo (cover; flat open;
  tabletop) against `mpctl serve`: pairing picked Where I'm typing, the card, open, trackpad click,
  typing, a flip to Messages left the pick on Claude, Done back to the card, a landing → Undo Paste
  under the mic, Control Center at 56% untouched; the Duo's glance, Show it here, every deck mode.
- **Needs a real device:** the flight in Release; the Mac's Core Audio listener (keys, the menu
  bar slider, AirPods, an HDMI output with no volume) — the Mac app must be installed for the level
  to reach the phone; History's Undo tapped by a real finger; the not-open card state (no shot).
  **[Fixed Nov 7 2026:** the cover's Control Center and Your Macs — height-detent sheets, whose
  system glass a cleared background doesn't remove — skip the card beside the column
  (`InnerScreenSheet(floats:)`) and are the system's own sheet, the full width; Control Center's
  content takes the whole width too (it never rises into the column), Your Macs' stays beside
  the column (its large detent reaches the column's buttons).**]**

## Overnight polish, round 5 (Nov 7 2026)

Round 5 of the overnight passes (Sameer's goal as in round 1). Emphasis: the regular iPhone's
window gets as much of the screen as it can, and the Duo cover's vertical bar holds its set while
typing. Two streams, merged together; frames `docs/screens/overnight-nov7/round-5/<stream>/`. In
one breath:
- **The window takes the iPhone:** while a window shows, the regular iPhone does what the cover
  does (`MainView.rowWatching`, was `coverWatching`): no page row, no Thread, one row of Keyboard ·
  64 pt mic · Trackpad (`pageButton`, ids `phone-page-*`; the cover keeps `cover-page-*`); the
  trackpad gets its own `TrackpadBar` with close. The picture 41% → 66% of a Pro's height (SE 44% →
  67%). The room changes only on a page change (the pages' spring) or with `keysUp`; the zoom holds
  for the trackpad as for the keyboard (`WindowViewer(keyboardUp:)` = `input.page != .mic ||
  input.keysUp` — on the inner screen too, where the trackpad is often the page). The page left for
  the keyboard goes at once, so no ghost of the mic row under the keyboard's glass bar.
- **The cover's bar holds while typing:** the trailing items are separate `ToolbarItem`s in tiers
  (`BarTier`, `ToolbarItemVisibilityPriority.bar`), one identity each (`bar-keyboard` in both
  states — `bar-keyboard-hide` is gone; the bell `cover-alert`). The cover's keyboard leaves the
  system's column two positions whatever the app asks, so typing shows Done · ⋯ (Hide Keyboard
  first in it); hiding brings the eight back to the pixel.
- **Integration (this merge):** only CLAUDE.md conflicted (both streams opened this section).
  Smoke-tested on a Duo (cover; flat on its side; tabletop) and an iPhone 17 Pro against `mpctl
  serve`: open, trackpad click (`WATCH MOUSE`), keyboard typing (`WATCH TYPE`), Done (`WATCH WINDOW
  restore`); the cover's one row and its bar folding to ✓ · ⋯ with the keyboard up; the inner
  deck's modes and the glance unchanged; the Pro's one row with the window at about two thirds.
  `InputCarouselUITests` (4) and `StabilityUITests` pass on the Pro after the merge.
- **Needs a real Duo / phone:** the empty room for the 4–5 frames before the keys rise (the cost
  of no ghost); the tiered items' glass on a real cover; the trackpad's held zoom on the laptop and
  the book in hand (not re-tested); the plate's left-edge swipe back (close is the way out).

### The window takes the iPhone

On a regular iPhone the watched window had 41% of the screen (43% on an SE): under the key row sat
the page row (Keyboard · Mic · Trackpad), the Thread's 84 pt band and a 92 pt mic over bare
wallpaper. Now the regular iPhone does what the Duo's cover does (`MainView.rowWatching` =
`(isCover || regularPhone) && watcher.isOpen && !showLiveWords`, replacing `coverWatching`):
- **While a window shows:** no page row (`rowHidden: isCover || regularPhone`), no Thread, and one
  row under the key row — `pageButton(.keyboard)` · a 64 pt mic · `pageButton(.trackpad)` (round
  glass, labels "Keyboard" / "Trackpad"; ids `phone-page-keyboard|trackpad`, the cover keeps
  `cover-page-…`) with the one-line status (`LandedSlot` in it) under it. Measured on an iPhone 17
  Pro: the picture 41% → 66% of the screen's height; the SE frame 44% → 67%. A swipe beside the
  mic still changes the page.
- **The trackpad** gets its own row (`TrackpadBar`: keyboard · "Two fingers scroll" · close,
  `trackpad-bar-close`) and `trackpadRoom` over the mic row: 116 on the cover (as before), 122 on
  a compact phone, 172 on a Pro — a plate of ~206 pt on a Pro and ~156 on an SE, its edges in line
  with the window's (`InputCarousel(trackpadInset:)`, `WatchLook.sideMargin`; the cover's 16).
- **No jumps:** the room changes only with a page change (the pages' spring — the window follows
  it, ends within 1 pt of where it started, `smoothHeight` on the phone too) and with `keysUp`, in
  the keyboard's motion. Measured per frame (`docs/screens/overnight-nov7/round-5/phone-one-row-watch/window-foot-per-frame.txt`):
  the keyboard 2045 → 1289 px in one move, back 1289 → 2045 in one (the simulator's keyboard
  vanishes in a frame, so the first step down is 54 pt); the trackpad 2045 → 1527 → 2045, a 0.7 pt
  settle at each end. `serve`: one `WATCH SHAPE` at open, none for the pages, typing or the mic.
- **The zoom holds for the trackpad** as it does for the keyboard: `WindowViewer(keyboardUp:)` is
  `input.page != .mic || input.keysUp` (logged "viewer: the keyboard or trackpad came/went …").
- **No ghost under the keyboard's bar** (the cover and every phone): the page leaving for the
  keyboard goes at once instead of fading in `leave` — faded, it was still drawn under the
  keyboard's glass bar as the keys rose. For the 4–5 frames before the keys come the room is empty.
- **The mic opening over a window** is the cover's path: the same `MicButton` grows to 92, the
  Thread comes back after the window leaves (`.handoff`-style `Motion.afterLeave` insertion now on
  the phone too), and Done brings the rest desktop back unchanged. `rowDimmed` only stops the swipe.
- Tests: `InputCarouselUITests` (no row; a swipe beside the mic to the trackpad and the keyboard;
  the buttons as every way in and out — trackpad drag, close, keyboard typing, hide — with the
  window's foot ±0.5 pt after each), `AccessibilityTreeUITests` taps the buttons.
- A swipe has to start off the mic's own ground (70 pt either side of the middle — `onMic`), so
  with no Thread it starts on the keyboard's or the trackpad's button. XCUITest lists the hidden
  pages' elements (`input-trackpad`, `trackpad-bar-close`) on the mic page too: tests tell the
  page by the window's foot, not by existence.
- Left: the answers row under the window blinks out for a moment as the keyboard goes
  (WatchActions, round 1); the plate's left-edge swipe back wasn't re-proven (close is the way).

### The cover's bar holds while typing

Stream `cover-bar-keyboard`. Cover, watching Claude, the keyboard page: the bar had Done ·
Keyboard · Sound · Mac Controls · bell · Pan|Scroll · zoom out · Window; at the tap the glass
emptied, shrank with the keyboard's rise, and settled as ✓ and ⋯ with every other item inside.
Frames: `docs/screens/overnight-nov7/round-5/cover-bar-keyboard/` (before | after, light and dark,
the rise frame by frame). Measured on a Duo simulator's cover (the UI test prints it):
- **The column.** Keyboard down: Done's cell at y 175–213, then 52 pt a pitch (38 pt cells) to
  Window at 547–585 — 410 pt for eight items on a 678 pt screen. Keyboard up: the cover's keyboard
  spans the vertical bar's column too (its keys from y 433, our 44 pt bar over them at 335), and the
  system lays the column out short of it: **two positions** (175–213 and 235–273, the second the
  `BottomOverflowBarButtonItem`), whatever the app asks — 60 pt of air is left above the bar. `.ignoresSafeArea(.keyboard)` on the cover's NavigationStack changes nothing (tried: the
  column is the system's, laid against the keyboard, not the stack's safe area); so does
  `toolbarVerticalCompressionBehavior(.prefersToolbarItems)`, already set. Eight items can't fit
  two positions, so **the keyboard-up bar is Done · ⋯ by the system's hand**, and the empty glass
  during the rise is the system's own overflow transition (the folded items leave at
  keyboardWillShow, the capsule shrinks with the keyboard, ⋯ fades in at the end) — not a re-vend
  of ours: it's the same with nothing of ours changing identity.
- **What changed** (`MainView.coverToolbar`, `coverKeyboardItem`, `BarTier`; CoverBar.swift
  `ToolbarItemVisibilityPriority.bar`): the trailing group is **separate `ToolbarItem`s, each in a
  tier** (`.done` above `.high`, `.keyboard` = `.high`, then `.window`, `.sound`, `.controls`,
  `.drag`, `.alerts`, `.whole`, each a step lower — iOS 27's `visibilityPriority`; an older system
  lays them out as they come), so a short column folds from the foot one item at a time, never the
  set as one (as one group, the whole group went into ⋯ and only Done stayed; now any third position
  the system finds goes to the keyboard's item, then the Window menu). **The keyboard's item keeps
  one identity**: id `bar-keyboard` in both states, the title "Keyboard" / "Hide Keyboard" (what ⋯
  shows), the symbol replaced in place; `bar-keyboard-hide` is gone. The bar's bell is `cover-alert`
  (one id, value On / Off) for the same reason. Nothing is added or removed on `keysUp`.
- **With the keyboard up** the bar is ✓ Done and ⋯ (Hide Keyboard · Sound · Mac Controls · Alerts
  Off · Scroll (or Pan) · Whole Window · Window ›), and the keyboard's own bar has hide. Hiding from either
  brings the eight back to the pixel. At rest the cover's bar is unchanged; the inner screen's bars
  untouched (the inner vertical bar still has no Keyboard item). **Round 1's set list stands with
  this amendment:** the set is fixed and nothing of ours comes or goes, but with the keyboard up the
  system itself shows two of it.
- `CoverBarKeyboardUITests` (a paired `mpctl serve`, a Duo cover): the eight ids in order and
  hittable, the keyboard raised from the bar, Done in place and ⋯ hittable with it up, every folded
  item in ⋯ with Hide Keyboard first, hide from there, the eight back at their frames (±1 pt).
  `StabilityUITests` hides from the keyboard's bar now.
- **Left:** a bar of eight that folds to two is the cover's real shape; the way to more while typing
  is a shorter set (Whole Window and Alerts into the Window menu changes nothing here: two positions
  are two) or the system giving the column the keyboard's bar height back — Apple's call. Dark mode
  and the rest set were shot, not changed.

## Setup on the iPhone, and Tailscale guided (Nov 7 2026)

Sameer: "a round of polish on the iOS and Mac app to make setup simple and clean and not confusing
… we need to stick with Tailscale … the Mac app and iOS app should guide users through the setup
clearly to get it all to work." The iPhone's half (the Mac's own guide was a parallel stream).
Wins over the older setup and away-from-home sections where they differ. Frames:
`docs/screens/setup-nov7/iphone/` (`before/`, `after/`, `after-dark/`, `after-se/` — a real SE simulator —, `after-ax/` — accessibility-large —, `after-duo-cover/`).
- **Setup is five steps, not seven** (`OnboardingView`, `OnboardingStep`): welcome · **voice**
  (the microphone and speech recognition on one page — one Continue, iOS's two questions back to
  back, what's off said with Open Settings) · **get the Mac app** (sameer.us/macrophone, Send the
  Link to Yourself, and a line saying iOS asks next about the local network — its Continue starts
  the link, so the pre-ask page went) · pair · test. The "Looking for your Mac…" page went too:
  the scanner says what to open on the Mac, and the code picker says after 10 s what to check
  ("Can't see it? … same Wi-Fi. No Mac app yet? …"). The raw values are kept (0, 1, 3, 5, 6): a
  stored 2 opens voice, a stored 4 pairing (`OnboardingStep(stored:)`); a Mac already in sight
  skips the get-the-app page. Welcome is one sentence.
- **Pairing:** Local Network off says so on the scanner and the code picker (ochre, in place of
  "talk directly over this network") with Open Settings as the button; the code page says "click
  They Match" (the Mac's button — it said Match); "Looking for Macs on this Wi-Fi…".
- **The away guide** (`UI/Settings/AwayGuide.swift`, `AwayGuideView`, still `SettingsRoute
  .awaySetup` / `away-setup`): a header ("Use it anywhere"), four steps each with one button and a
  green check once done, re-read on every return to the front and every 2 s while open —
  1 **Your Mac** (done when it has shared a Tailscale address: `AppModel.macAway` = ready /
  noTailscale / off from `macToldAddresses`; the Mac broadcasts an empty list with Away from home
  off; noTailscale offers "Send Tailscale to Your Mac", a share of tailscale.com/download/mac; the
  address is shown, selectable, never logged) · 2 **Get Tailscale on this iPhone** (done when
  Tailscale's app answers `tailscale://` — `LSApplicationQueriesSchemes` in project.yml — or the
  phone is on Tailscale; a no is never claimed, the App Store button shows) · 3 **Sign in and turn
  it on** (done when `TailscaleHere.isOn`: a 100.64/10 address on any interface; Open Tailscale) ·
  4 **Test it** (`AppModel.testAway` → `LinkClient.probeAway`). Without Tailscale is a folded
  disclosure with the port-forwarding sentence and the typed address (moved off the Mac's page).
  The Mac's page is now Connected now (only while connected) and one row, Away from Home ·
  Ready / Set Up, over Unpair; its jargon footer ("Remote access … (Devices)") is gone.
- **Test it** (MacrophoneKit `Transport/AwayProbe.swift`, `AwayProbeResult`, `AwayProbeTests`):
  dials the active Mac's Tailscale address and name on the away path (`LinkServer.awayParameters`),
  sends the hello, checks the Mac's proof, closes — no session, the link untouched, **no wire
  change** (the Mac sees a hello that never finishes). works · remoteOff (a refused connection or
  one cut before the hello: Away from home off on the Mac) · unreachable (nothing answered —
  phrased "Tailscale is off on this iPhone" when it is) · notThisMac (another device has the
  address) · noAddress · notPaired. Logged as words, never an address. At home it still goes over
  Tailscale (100.x routes through its tunnel), so it proves the away path from the couch.
- **Where people meet it:** once, after the first pairing — setup's Finish, or the pairing
  sheet's Start Dictating — `AwayOfferSheet` (`AppSheet.awayOffer`, medium detent: "Use it away
  from home" · Set Up / Not Now; `away.offered`, set by either answer or by dismissing; skipped
  silently when both ends are already ready; only with nothing else on screen). Settings: the
  Mac's page. **"Can't find ‹Mac›"** (the desktop and the Duo's glance, `MacNotFoundAction`): on
  a network the Mac was on, Wake Your Mac as before; elsewhere (`AppModel.awayHelp`) "Set Up Away
  from Home" (no Tailscale address from the Mac), "Turn On Tailscale" (the Mac's ready, this
  iPhone isn't) or "Test the Connection", each with its own sentence. `AppModel.openAwayGuide()`
  opens Settings at the guide (`settingsOpenPath`), after any sheet that's up.
- **Hooks:** `MACROPHONE_FAKE_TAILSCALE=on|off`, `MACROPHONE_FAKE_TAILSCALE_APP=1|0`,
  `MACROPHONE_FAKE_AWAY=tailscale|remote|off`, `MACROPHONE_FAKE_AWAY_TEST=works|remoteOff|
  unreachable|notThisMac|noAddress`, `MACROPHONE_AWAY_OFFER=1|again`; `MACROPHONE_RESET` clears
  `away.*`. `AwayGuideUITests` (`TEST_RUNNER_MACROPHONE_AWAY=1`: every step's state, each test
  outcome's words, the offer once — Set Up and Not Now —, the empty state's two buttons);
  `TEST_RUNNER_MACROPHONE_AWAY_LIVE=1` (+ `…_AWAY_PORT=<serve's --port>`) with the simulator paired
  to `mpctl serve --remote` on a Mac that's on Tailscale: the Mac's real 100.x address arrives and
  step 1 checks itself, and the simulator shares the Mac's interfaces, so step 3 reads done. **A Mac
  can't connect to its own Tailscale address** (`nc -z` to it times out; the app's real Test it
  said "didn't answer over Tailscale", correctly), so the live test dials serve's away door on
  loopback (`MACROPHONE_AWAY_TEST_ADDRESS=host:port`, DEBUG): the button, the dial, the hello and
  the Mac's proof → "Works away from home."
- **Needs a real phone:** whether Tailscale's iOS app takes `tailscale://` (if not, step 2 waits
  for step 3 and Open Tailscale goes to the App Store); Test it over cellular and on home Wi-Fi
  with Tailscale on; the Mac's guide and this one side by side (the Mac stream's words — "Away
  from home", "Devices", "Pair" (the Mac's code sheet is Don't Pair / Pair since the Mac setup pass) — are quoted as in the Mac code).

## The fix-up pass (Nov 7 2026, evening)

Sameer: "Do all the improvements" — three agents, merged together, smoke-tested on an iPhone 18 Pro
(iOS 27.0) and a Duo (27.1) against `mpctl serve`.

**Connecting, not reconnecting; an app that isn't open.** A window opened before the link is up (a
folded Duo launch, a widget or alert at launch) used to show "Reconnecting…" over a dimmed kept
picture: `Watcher.start` with no link always called `beginReconnecting`. Now that hold is a first
connect (`Watcher.firstConnect`): nothing over the held picture while the app comes up or comes back
(`Watcher.linkQuiet` = AppModel's `settling || returning`, pushed by `linkLooks`), then "Connecting
to ‹Mac›…" (`holdWords`; the glance's bar too). A real drop while here still says "Reconnecting…"
after 0.5 s. The phone's list of open apps can be old (`targets-<id>.json`, a folded launch, a
widget tapped before the list came): the Mac's answer for an app that isn't running is
`WatchState.unavailable(…, notOpen: true)` ("‹App› isn't open on your Mac"; `WatchService.find`,
kept by `resolve` when it strips `closed` for a window never seen; `WatchState.saysAppNotOpen` reads
it, or an older Mac's words). The phone closes the view as Done does (`Watcher.appNotOpen`) and
`AppModel.watchedAppNotOpen` takes the app out of `liveTargets`, asks the Mac for its list and says
so, so the card and the glance show "‹App› isn't open" with Open ‹App›. Send to is untouched; just
opened from here (`isOpening`) it asks again in a second. `mpctl serve --quit <bundle ids>`;
`WatchConnectingUITests` (`TEST_RUNNER_MACROPHONE_NO_MAC=1` with the Mac stopped,
`…_QUIT_TEST=1` with `serve --quit com.tinyspeck.slackmacgap`). Frames: `docs/screens/connecting-nov7/`.

**The laptop's keyboard.** Measured (`MACROPHONE_KBD_DUMP=1`): folded as a laptop, iOS starts the
keyboard's frame at the top of the hinge's band (455.5, 20 pt above the fold) whatever's in it, its
keys ~50 pt lower (526) — it isn't the predictions bar. **The keyboard's window takes every touch in
that band**: a bar drawn there by the layout looked right but hide and the keys never answered (the
first try, reverted the same evening — `DuoSettleUITests`' mic test caught it). So the bar stays the
keyboard's accessory everywhere, on top of that frame (403.7), and the laptop's window gives its
foot as before (Claude 434.7 → 374.7 pt; its top, left and width never move; the Whole Screen keeps
its size, its foot under the keys). Flat upright has no band (the frame starts at 549): its in-hand
deck is at least the keyboard's height (`flatUprightKeyboard`), so the window there stays whole with
either keyboard. The keyboard's height is kept per shape (`keyboard.iosKeys.v2.<surface>.<wide|laptop|tall>`;
the laptop's 495 used to overwrite flat upright's 350). `DuoTypingUITests` checks hide answers a tap.
Frames: `docs/screens/duo/nov7-laptop-keyboard/` (the "after" there is the reverted try).

**The first open, warmed.** The first window opened after launch held the main thread ~200 ms
(later opens ~75): SwiftUI building, for the first time, the carousel's keyboard and trackpad pages
(the keyboard's field is the app's first text view) and the header. `MainView.warmPanel`: once per
launch, 0.7 s after the Mac first connects, `PagesWarmup` and the hidden panel's header are built
unseen for 0.25 s, then let go; skipped if a window or the words are up; `MACROPHONE_NO_WARMUP=1`
to compare. iPhone 17 Pro sim, 10 launches each: median 154 ms with it, 205 without.

**Undo in History, a real keyboard, the tests that failed.** History's Undo was never broken (round
2's test swiped `cells.firstMatch`, not the newest row); `UndoChipUITests` now proves the row's
Undo, the leading swipe and `HistoryPage`'s Undo Paste each reach the Mac (`UNDO <id>`) and the row
reads "Undone from the phone", and that none is offered after `MACROPHONE_UNDO_LIFE`. **A real
keyboard typed nothing on the Mac**: `HardwareKeysCatcher`, behind everything in `RootView`, was
updated by SwiftUI only at launch, so `HardwareKeysView` never took the keyboard; it now follows the
watcher, the pages and `HardwareKeyboard` itself (Combine). `testMicButtonNeverMoves` checks the
controls are out of reach while recording by a tap where they sit (XCUITest calls the faded layer
hittable) — it leaves the simulator unpaired, run it last; `DuoUITests` flat upright: Send to is the
Dock, as wide as its icons. serve's `stdout()` flushes each line. `DesktopWindowUITests` fails the
very first time on a fresh simulator (no kept picture: the card's plate becomes the picture after the
first open); it passes after.

## Setup on the Mac, and Tailscale guided (Nov 7 2026)

Sameer: "the QR code pops up on the Mac even when a phone is paired and that is a bit confusing …
we need to stick with Tailscale … make setting up with Tailscale easy and the Mac app and iOS app
should guide users through the setup clearly". The Mac side (the iPhone's was another agent's).
Wins over the older setup and Away-from-home words below. Frames: `docs/screens/setup-nov7/mac/`
(`before/`, `after/` light and dark, `sheet-*.png`).
- **Why the code showed with a phone paired:** the launch opened the pairing page whenever
  `hasCompletedSetup` was false — and only Done on the last page set it. Closing the window after
  pairing, quitting mid-run, or a reinstall that kept its pairings (keychain + the support folder,
  not the defaults) brought the QR back on every launch. General's "Show the welcome again" also
  opened on the code. Now (`AppDelegate.firstLaunch`): nothing paired → the first run; a phone
  paired and setup not done → the first run *after* pairing (only what's missing), or no window
  at all when the grants are on and it opens at login (log: "setup: a phone was already paired
  …"). **Any close of the setup window ends the first run** (`windowWillClose` sets
  `hasCompletedSetup` — Done, Set Up Later, the close button); it never opens by itself again.
  Pairing another phone is only ever asked for: **Pair Another iPhone…** in Devices and the menu
  (Pair Your iPhone… with none).
- **Modes and pages** (`UI/Setup/SetupWindow.swift`): `SetupMode` `.firstRun` (pair · permissions
  · away · all set, each skipped when it's done — `SetupWindowController.isDone`: a phone paired,
  both grants, Remote access on with Tailscale connected) · `.pair` (the code, then Paired, Done)
  · `.permissions` (a phone's "Open Macrophone on my Mac") · `.away` (the guide alone).
  `start(mode)` resets; `next()` / `back()` walk a first run (`nav.history`; pairing is never
  behind Back). The code is open only while its page shows (leaving it calls `endPairing`). Five
  pages became four: **login and "Where dictations go" folded into one "You're all set" page**
  (`AllSetPage`: "Open Macrophone when I log in" as a checkbox, the menu bar / shortcut line; Send
  to is picked on the phone, and the main window has the card). Words: "Pair another iPhone" when
  one's paired, "Paired" no longer promises the clipboard (a fresh phone picks Where I'm typing),
  the permissions page is "Allow Macrophone to work your Mac", the code check is a sheet with
  **Don't Pair / Pair** (`CodeApproval`, was an overlay with They Match).
- **Looks like Setup Assistant** (`UI/Setup/SetupLook.swift`): the window follows the system's
  light or dark (`SystemAppearance`, read from `AppleInterfaceStyle` and followed live — the app
  forces dark everywhere else, so `window.appearance = nil` would stay dark) **[superseded Nov 7 2026: the app follows General › Appearance; the setup inherits it — `SystemAppearance` is gone]**, the system's window
  background, `SetupPage` (a 50 pt symbol, a 26 pt bold title, one sentence, the content, the
  buttons along the foot: Back left, the one thing to do right, large controls), system buttons,
  the app's accent. No step dots, no serif, no uppercase kicker. `CheckList` / `CheckRow` /
  `CheckDivider` / `GuideButton` draw a checklist natively, or as the window's plates and pills **[Nov 7 2026: in a pane each step is a row of the grouped form]**
  under `.environment(\.guideLook, .pane)`.
- **Tailscale, guided** (`Core/Tailscale.swift`, `UI/Components/AwayGuide.swift`):
  `TailscaleMonitor` (`model.tailscale`) sees installed (`io.tailscale.ipn.macsys` /
  `.macos`, or `/Applications/Tailscale.app`), running, connected (a 100.64.0.0/10 address on an
  interface — `NetworkAddresses`, no CLI) and the MagicDNS name (reverse lookup, cached per
  address); every 2 s while a guide shows, and on every path change and at launch otherwise. It
  only looks. `AwayGuide`, five steps, each a green check when done, the next one's number lit:
  1 **Get Tailscale** (the Mac App Store, id1475387142) · 2 **Sign in** (Open Tailscale; "open
  but not connected" said) · 3 **Turn on Remote access** (a switch) · 4 **Tailscale on your
  iPhone** (a QR code to the iOS App Store, id1470499037) · 5 **Your iPhone can reach this Mac
  away from home** — green once a paired phone has connected over an away route
  (`settings.reachedAway`, per peer, kept after it disconnects, dropped on forget/unpair;
  `AppModel.lastReachedAway`; step 4 counts as done then too); before that it says what to do
  ("turn off Wi-Fi on your iPhone and open Macrophone" while one is connected here).
  **Remote access turns itself on once Tailscale is connected** (`AppModel.tailscaleChanged`,
  log "remote access turned on by itself") unless he switched it himself
  (`settings.remoteAccessChosen`, set by `chooseRemoteAccess` — the guide's and Devices' switch);
  it never turns itself off. The first run offers it as its last optional step ("Use it away from
  home": three lines — from anywhere · private · free — **Not Now / Set Up**; straight to the
  steps when Tailscale is already installed); Devices › Away from home is the same guide on
  plates, with the port-forwarding way folded into a **Without Tailscale** disclosure (the local
  addresses with Copy, the port, one sentence). No wire change: the phone already gets
  `.remoteAddresses` when Remote access is on (a 100.x address in it = the Mac is ready).
- **General › Set up again** (was "Show the welcome again") opens the first run, skipping what's
  done; it never shows the code (pairing another phone is Devices').
- Hooks (DEBUG): `MACROPHONE_QUIET_WINDOWS=1` (windows open behind everything, never key, no Dock
  icon, no activation, no Accessibility prompt — `screencapture -l <id>` still reads them; the
  setup's shots were taken that way while he used this Mac), `MACROPHONE_APPEARANCE=light|dark`,
  `MACROPHONE_SHOW=setup | setup-pair | setup-paired | setup-paired-generic | setup-permissions |
  setup-away | setup-away-intro | setup-done | code-approval`, `MACROPHONE_FAKE_TAILSCALE=missing|
  installed|running|connected`, `MACROPHONE_FAKE_AWAY=1`, `MACROPHONE_FAKE_GRANTS=both|none|
  accessibility|screen`, `MACROPHONE_FAKE_LOGIN=1`, `MACROPHONE_WITHOUT_TAILSCALE=1` (the
  disclosure open). `MACROPHONE_FAKE_PEERS` now stages at once too (the first launch decides from it).
- **Proven** with a Debug copy (`MACROPHONE_INSTANCE`, fresh state, quiet windows): fresh launch →
  the code; a real pairing with `mpctl pair` → Paired (name it); killed, `hasCompletedSetup` set
  back to NO, relaunched → the permissions page, not the code (log "setup: a phone was already
  paired — the setup starts after pairing"); paired + grants + login item → no window; relaunch
  after that → no window. `swift test` passes (242).
- **Needs a real check:** Get Tailscale / Open Tailscale on a Mac without it (the App Store page,
  the app opening); the MagicDNS name's reverse lookup on his tailnet; Remote access switching
  itself on when his Tailscale connects (log line); step 5 turning green after his phone connects
  over Tailscale from cellular; the window's light / dark following a switch in System Settings
  while it's open; the default button's accent tint (the shots are of a window that isn't key, so
  every button reads grey).

## Trackpad speed (Nov 7 2026)

Sameer: "a trackpads sensitivity toggle in setting". Settings › (under Show the app after sending)
**Trackpad speed**: the Mac's own Tracking speed slider — tortoise to hare, ten steps, Normal (1×)
in the middle, on a log curve 0.4× … 2.5× (`TrackpadSpeedWords`, SettingsView.swift); the value
reads Slowest · Slower · Normal · Faster · Fastest; Back to Normal shows while it isn't.
`settings.trackpadSpeed` (UserDefaults; `Settings.trackpadSpeedNow` for the pointer path) multiplies
`TrackpadMotion.step(_:dt:speed:)` — the whole acceleration curve — for the pointer and drags
(`MacInput.pointerMoved` / `dragMoved`), every trackpad (the page, the Duo's deck, full screen's
pad). Two-finger scrolling keeps its own speed. Ids `trackpad-speed`, `trackpad-speed-reset`.
Frame: `docs/screens/trackpad-speed-nov7/`.

## Settings, regrouped (Nov 7 2026)

Sameer: "review the setting menu complete and make sure it's organized in an easy way to understand
and has great ui". Wins over the older Settings sections where they differ. Every section has a
heading and a footer of a sentence or two, in the order of use: the Mac banner · **Dictation**
(Send to, Send after pasting — paired only —, Language, Stop when I stop talking + its delay) ·
**Cleanup** (the level with what it does right under it in the same row — ochre when unavailable —,
Custom instructions, Dictionary; one section, no footer between) · **Watching** (Show the app after
sending, Trackpad speed — Reset beside the value off Normal, `trackpad-speed-reset`, no extra row)
· **Alerts** (When an agent asks you — Nov 8: "…asks something" wrapped on a Pro —, the iCloud status row, the windows on watch with a red
Stop capsule) · **Appearance** · **Devices** (the Macs listed only with two or more — one Mac is
the banner, Unpair on its page —, Pair Another Mac, This iPhone's name) · **History** · **About**.
The inner screen's sidebar (`SettingsGroup`) is the same sections one for one: dictation, cleanup,
watching, alerts, appearance, devices, history, about. Frames: `docs/screens/settings-nov7/`.

## What's in front on your Mac (Nov 7 2026)

Sameer: "pick up where the Mac is" — whatever window is in front on the Mac, a tap on the phone and
you're watching it. **Handoff was tried and dropped** (branch `worktree-agent-a48ebd8a78bc9b46c`,
69422a0): `useractivityd` accepts a background app's `becomeCurrent()` but its "DETERMINE" step
advertises only the front app's activity (`setAdvertisableItems:(())`), and a menu bar app is almost
never the front app. Its front-window read, its never-offered rules and the phone's "watch this
window on that Mac" path were lifted into `FrontWindow`; nothing of NSUserActivity is left.
Frames: `docs/screens/front-window-nov7/`.
- **Wire** (MacrophoneKit `Core/FrontWindow.swift`, `Transport/FrontWindowLink.swift`, feature
  `frontWindow`, the volume's pattern — own delegate protocols): `.frontWindow(FrontWindow?)` Mac →
  phone after the welcome and on each change; `FrontWindow` = bundle id, app name, window number
  (= a `LiveTarget`'s `windowKey`), title (one line, ≤ 60, "…"; dropped when it's the app's name);
  `line` "Terminal — codex ~/api", `target`, `isSame(as:)` (same app and window, or the app with no
  window named). Nil = nothing safe to offer. `neverShown` (password managers, Keychain Access,
  Passwords, the login window, SecurityAgent, the Dock, Control Center…) and Macrophone's own copies
  (`mayShow`). `FrontWindowPacer` (pure): a change waits 0.5 s to stay put (⌘Tab through three apps
  sends one), never sooner than 0.5 s after the last, the same value never twice. Only to a phone
  naming it; an older phone never gets it, an older Mac never sends it. `FrontWindowTests` (the
  shape, titles, the pacing, a real connection both ways, ports 47941–47943).
- **Mac** (`Mac/App/Core/FrontWindow.swift`, `FrontWindowWatcher`, made in `AppModel.init`;
  `AppModel: LinkServerFrontWindowDelegate`): looks only while a phone naming it is connected
  (`phonesChanged()` on connect / disconnect) — at once on NSWorkspace's activate / space / wake /
  unlock / quit, then every 2 s, every 6 s after a quiet minute; the read (`CGWindowListCopyWindowInfo`
  on screen: the app's first layer-0 window ≥ 160 × 90, its title with Screen Recording, else
  Accessibility's focused window) off the main thread. A phone connecting gets `now()` (read at once
  when the last read is over 3 s old). Macrophone in front changes nothing (the last real app's
  window stays). Nil for a `neverShown` app, a non-regular app in front (a system dialog), a window
  kept out of screen capture (sharing state none), Secure Input held by the front app, a locked
  screen or the session switched away. The log has counts and reasons only ("front window: 3 changes
  told", "nothing offered — a password field is in front") — never a title. DEBUG:
  `MACROPHONE_FRONT_PRINT=1` (each one told, to stdout), `MACROPHONE_FRONT_FAKE=<bundle id>` (that
  app taken as in front — proves it without the focus).
- **Phone** (`iOS/Macrophone/Model/FrontWindowHere.swift`): `AppModel.macFront` (`MacFront`: the
  window and which Mac said it; cleared when the link drops), `frontNow` (connected, the active
  Mac's), `frontOffer` (= `frontNow` unless it's the pick, or the pick is Where I'm typing — its own
  card watches the app in front then), `frontTarget` (the list's entry when it knows that window).
  **The line** (`UI/MacOS/FrontWindowLine.swift`, `front-window-line`): a glass capsule under the
  desktop card (regular iPhone, the Duo's cover) — the app's icon, "Now on your Mac" (dropped first
  when it's narrow), "Terminal — codex — ~/api", an eye; label "Now on your Mac: ‹line›". Under the
  Duo glance's bar the same (`DuoGlance.pictured`). **Its room is kept while the Mac tells it**
  (`macTellsFront`, `bar.had.front` while it connects, as the bar keeps its buttons), so the card and
  the glance never move as the line comes and goes; without room for both (`leastRoom`, 180 pt of
  picture) the line goes. **A tap only looks** (`watchFront`, as a flip): Send to stays, a dictation
  while it shows goes to it for that recording (`watchedPlace`); on the inner screen it picks, as a
  flip does there.
- **Watch What's in Front, from cold** (`watchWhatsInFront`): the Home Screen quick action (second,
  after Dictate to the pick — `QuickActions.Kind.front`), a Control Center / Lock Screen / Action
  Button control (`WatchFrontControl`, `iOS/Shared/WatchFrontIntent.swift`, in `MacrophoneControls`)
  and the App Intent `WatchFrontIntent` ("Watch What's in Front"; phrases "Watch what's in front
  with Macrophone", "… on my Mac …", "Show what's on my Mac …", "Pick up where my Mac is …"). The
  intent's title and description have no "Mac" (ITMS-90626). It waits for the connect
  (`waitingFront`, run again from `stateChanged` and each `.frontWindow`), then watches the Mac's
  word at that moment; a Mac from before (or no word 1.5 s after the welcome) is asked for
  `.frontApp`, which every Mac adopts (`WatchService.find`); the Mac saying nil: "Nothing in front on
  ‹Mac› to show right now", nothing opened.
- **mpctl:** `serve` names it and tells a demo front window (`Sources/mpctl/Front.swift`: `--front
  <bundle id>[#<key>]|none`, `--front-every N` moves it along the demo's windows, 20 s; 0 never;
  `--no-front` a Mac from before); a watch of Where I'm typing is answered with the front window's
  app; every watch prints `WATCH TARGET <bundle id>#<key>` (" (front)" for Where I'm typing). `listen
  --features frontWindow` prints `FRONT <bundle id>#<key> · <line>` (or `FRONT none`).
- **Proven:** `swift test`; `mpctl listen` against `serve` (welcome + each change; an older phone
  hears nothing and stays connected); a Debug copy of the Mac app (`MACROPHONE_INSTANCE=front`,
  `MACROPHONE_FRONT_FAKE=com.apple.finder`) told a paired `mpctl listen` Finder after the welcome and
  once from the pacer, and nothing to a phone not naming it. iPhone 18 Pro simulator (27.0) against
  `serve --front com.apple.Terminal#42 --front-every 0`: `FrontWindowUITests`
  (`TEST_RUNNER_MACROPHONE_FRONT_TEST=1`, `…_SERVE_LOG`, `…_FRONT_SHOTS`) — the line under Claude's
  card, a tap → `WATCH TARGET com.apple.Terminal#42`, Done → Claude still the pick and the card where
  it was; the quick action and the intent before the link is up → the same window once connected;
  against `serve --no-front` (`…_FRONT_OLD_MAC=1`) both → Where I'm typing. `serve --front none`:
  the room kept, no line, the status line's sentence. The inner glance through the stand-in frame
  (`MACROPHONE_POSTURE=portrait MACROPHONE_FRAME=669x951`). Hooks: `MACROPHONE_FRONT_ACTION=quick|
  intent|model` (`MACROPHONE_FRONT_DELAY`), `MACROPHONE_WATCH_ACTIONS=…,front` (the line's tap).
- **Needs a real Mac and phone:** the installed Mac app's read on real windows (Claude's, a
  Terminal tab's title, a full-screen Space, a password field, the lock screen); the Control Center
  control and the quick action from a real cold launch; Siri's phrases; the line on a real Duo's
  inner screen.

## Keep Awake (Nov 7 2026)

Sameer: "the other thing to move from SameerOS to macrophone Mac app is the feature sets that keep
the Mac awake", then "more consumer grade" and "go deep on how you make … keep [the Mac] from
sleeping production ready". SameerOS's On The Go (manual: `~/claude-projects/OnTheGo/CLAUDE.md`,
code `SameerOS-Mac/SameerOSMac/Displays/` + `SameerOSHelper/`, read only, untouched) moved here as
**Keep Awake**, for anyone's Mac: one switch, one sentence ("Your Mac stays on with the lid closed,
so you can use it from your iPhone"; a desktop: "stays awake and reachable"), defaults most people
never change, no machinery's names in the UI. Frames: `docs/screens/keep-awake-nov7/` (the page
blocked by SameerOS, on with displays off and a timer, on before the permission at 18%, a desktop;
the phone tile off, on, displays off, blocked) and `dry-run-proof.txt` (seven dry runs, below).
- **What moved, mechanics kept:** sleep settings (`sleep 0 · hibernatemode 0 (laptops) ·
  displaysleep 0 · disablesleep 1`) through a root helper, backed up first and put back; the
  power assertions; the built-in at brightness 0 and back; displays off (BetterDisplay's virtual
  unplug, optional, else `pmset displaysleepnow`) with BetterDisplay started in the background when
  it has quit, one CLI process per display, failures kept and retried 3× then a notification;
  smart auto-dim (listen-only event tap, physical input only — `eventSourceUnixProcessID == 0`, so
  steering the Mac from the phone never keeps its displays on — 2/5/10/15 min or right away, the
  first touch brings them back, input ignored 6 s after a dim); the screen lock via `sysadminctl`
  with the login password in the Keychain (**opt-in, behind Advanced**, honest words about what
  saving it means, never asked from a timer); "Back at desk in…" (30 m–8 h); the 5-minute watchdog;
  the audio guard; resume after a quit; the "Restore Normal Sleep / Resume Keep Awake" question.
- **What improved:** the state machine is pure and tested (MacrophoneKit `Core/KeepAwakeEngine.swift`,
  the machine behind `KeepAwakeSystem`); one record (`keep-awake.json` in Macrophone's own folder,
  atomic writes — no `~/.onthego-*` files), settings in UserDefaults, one log (diagnostics, states and
  numbers only); **sleep settings backed up per power source** (`pmset -g custom`: battery and
  charger differ; On The Go's single `-a` restore flattened them) and, with no backup, this kind of
  Mac's own defaults (a desktop is never given hibernatemode 3); **in-process assertions**
  (PreventSystemSleep, PreventUserIdleSystemSleep, PreventUserIdleDisplaySleep — what `caffeinate -s
  -i -d` takes) that die with the app, so a force-quit never orphans a `caffeinate`; only the
  **built-in** is dimmed (`CGDisplayIsBuiltin` — On The Go dimmed whatever was main, an external in
  clamshell); DisplayServices **dlopen'd** (missing on a future macOS or an Intel Mac: brightness is
  left alone, the displays still sleep); the audio guard runs only while on and logs device kinds,
  never names; the helper quits after 10 quiet minutes; a phone or the API never triggers a dialog.
- **The helper** (`Mac/Helper`, target `MacrophoneHelper`, embedded at `Contents/MacOS/MacrophoneHelper`,
  launchd plist written by `Mac/scripts/helper-plist.sh` into `Contents/Library/LaunchDaemons/<label>.plist`
  before signing): label `com.sameer.macrophone.mac.helper` (Debug `…mac.debug.helper`, so a debug
  build never collides with a release), registered with `SMAppService.daemon`. It runs only changes
  that pass `PowerChange(wire:)` — **the same file** (`Core/KeepAwakePower.swift`) is compiled into
  the daemon and tested in MacrophoneKit: four keys, their sane values, one source each,
  `disablesleep` only with `-a`, all checked before any runs. Code requirements both ways
  (`PowerHelperIdentity`): the daemon takes `anchor apple generic and certificate leaf[subject.OU] =
  "8523EX5882" and (identifier "com.sameer.macrophone.mac" or "….mac.debug")` — Developer ID and
  Apple Development both satisfy it (checked with `codesign -v -R` against this build and the
  installed Developer ID app); the app only talks to a daemon signed as the helper by the team.
  **Version handshake:** `PowerHelperVersion.current` (1); an older daemon (Macrophone updated, the
  old one still running) is asked to `stepDown` and launchd starts the new one on the next call.
  Its states: ready · not installed · waiting for approval · needs an update — each a row on the
  page with one button. `release.sh` now checks the helper and its plist are there, signed as
  `com.sameer.macrophone.mac.helper` by the team, Developer ID, hardened runtime, and that the app
  meets the daemon's requirement (the export re-signs nested code; not run — no release made).
- **The one-time permission, guided:** "Allow Macrophone to change sleep settings" → Allow…
  registers the helper and opens Login Items; the page looks every 2 s and turns green by itself.
  Until then Keep Awake still turns on (assertions — awake while open) and says "keep the lid open";
  approved later, the lid can close at once with no toggle (`helperMayHaveChanged`). A desktop needs
  no helper (it's offered as "also stays awake if someone chooses Sleep"). The administrator dialog
  is never the first experience — only "Or turn it on with your administrator password, just this
  once", or a Restore Normal Sleep / turn-off he clicked when the helper is gone.
- **Production states (each a unit test or a dry-run line):** laptop vs desktop (`MachinePower`:
  internal battery or a clamshell key — no lid or battery wording on an iMac/mini/Studio); one
  display, several, none (headless: no displays row); helper never approved / approved then removed
  ("can't change sleep settings any more, so closing the lid would put your Mac to sleep" — the
  watchdog never prompts) / outdated; **a crash or force-quit mid-toggle** (the record says
  turningOn / turningOff before anything changes: `recover` resumes, finishes or cleans up —
  `testRecoveryMatrix`); **a restart while on** (sleep came back → the question; displays left dark
  are put back first); **the Mac set never to sleep with Keep Awake off** (any cause) → never silent:
  "Restore Normal Sleep" first in the menu bar, a banner on the page, `sleepStillOff` on the phone,
  one click; a turn-off on its own that can't restore says so the same way; one that he asked for
  stays on, consistent. Quitting from the menu with sleep settings changed asks (Turn Off and Quit ·
  Quit · Cancel). **Battery:** a warning under 20% on battery and after 2 h on battery; off at a
  floor (5 · **10** · 20 % · Never) with a notification; it won't turn on at or under the floor.
  **Heat:** `thermalState` serious → "Your Mac is hot. If it's in a bag, take it out…" (once);
  critical → off with a notification, and won't turn on until cooler. Low Power Mode: shown, never
  notified. **Uninstall:** Advanced › Restore normal sleep and remove permission (`prepareForRemoval`:
  sleep back, screen lock back, password forgotten, helper unregistered). Deleting the app while on
  can't be caught: then `sudo pmset -a disablesleep 0` (and System Settings › Battery for the rest),
  or reinstall and use that button.
- **SameerOS never fought** (`OtherKeeper`): `~/.onthego-active` → "SameerOS's On The Go is on —
  turn it off there first."; SameerOS's helper still loaded (`launchctl print
  system/com.sameer.sameeros-mac.helper`, once a minute) → "SameerOS can still change sleep settings
  — remove its helper…". Either refuses to turn on and touches nothing of SameerOS's; a record of
  ours while SameerOS is on stands down. **This is what his Mac shows today** (On The Go is on).
- **Mac UI:** sidebar **Keep Awake** after Agents (`Pane.keepAwake`, `cup.and.heat.waves`,
  `UI/Window/KeepAwakePane.swift`): the switch with the status line ("On · lid can close · displays
  off since 3:12 · back at desk at 5:00"), Displays (Turn Off Now / Turn On), Back at desk, Battery;
  problem / warning banners with their fix; With the lid closed (the permission); Displays (turn off
  after…, external displays — only with BetterDisplay; without it a footer names it as an optional
  extra); Battery (the floor); Keyboard shortcuts (⌘⇧G Keep Awake, ⌘⇧D displays — recordable, ⇧⌘
  allowed here, off with ×; the footer says ⇧⌘G is also Finder's Go to Folder; a shortcut another
  app holds is retried every 30 s); Advanced (the screen lock, the audio guard, remove). Menu bar
  (`KeepAwake/KeepAwakeMenu.swift`): "Keep Awake" (checked, ⌘⇧G shown, its line as the subtitle),
  while on "Displays off · idle 3m" (a click switches, ⌘⇧D) and "Back at desk in…"; a problem's fix.
  `HotkeyCenter` now holds several hot keys and dispatches by id (`register(id:_:action:)`; id 1 is
  Open Macrophone), passing on events that aren't ours.
- **The wire** (`Core/KeepAwake.swift`, `Transport/KeepAwakeLink.swift`, feature `keepAwake`):
  `.keepAwake(KeepAwakeStatus)` Mac → phone after the welcome and on every change (on, busy,
  machine, lidCanClose, since, displaysOff(+Since), hasDisplays, backAt, battery, charging, onPower,
  blocked, problem, warning, sleepStillOff — every field decodes with a default);
  `.keepAwakeSet(KeepAwakeRequest)` phone → Mac (`action` a string: on · off · displaysOn ·
  displaysOff · timer(minutes) · restoreSleep — an unknown one ignored, never a session's end). The
  Mac always answers the asking phone. From the phone nothing ever prompts on the Mac. Tests:
  `KeepAwakeTests` (46: allowlist, pmset parse/restore, words, warnings, recovery matrix, every
  engine path above, two loopback ports 47941–47943).
- **iPhone** (`Model/KeepAwakeModel.swift`, `UI/MacOS/KeepAwakeModule.swift`): a Control Center
  toggle module above Sound, only with a Mac that has it — the lit cup, "Keep Awake", "Lid can close
  · 84%" / "Keep the lid open · 50% · charging" / "Stays awake" / the blocked reason in ochre; while
  on a Displays button ("They turn on with a key or the mouse on your Mac"); a note for a problem,
  a warning, "Turns off at 5:00 PM", or "Your Mac is set never to sleep — Open Macrophone on your
  Mac and choose Restore Normal Sleep". A tap shows its result at once and settles to the Mac's
  answer (6 s without one: back, and "Your Mac didn't answer"); kept per Mac (`mac.keepAwake.<id>`),
  "Last known ·" while not connected. Ids `cc-keep-awake`, `cc-keep-awake-displays`,
  `cc-keep-awake-line`, `cc-keep-awake-note`. Hook `MACROPHONE_REACH=controls,awake@on|off|displaysOff|displaysOn|timer`.
- **CLI / API:** `mp awake [status|on|off] | displays on|off [--json]` → `GET/POST /v1/awake`
  (docs/API.md); exit 1 when `on` didn't turn it on. `mpctl serve` names it (`--no-awake`,
  `--awake-desktop`, `--awake-blocked`, `--awake-no-helper`, `--awake-battery N`) and prints `AWAKE
  on` / `AWAKE off` / `AWAKE displays off` / `AWAKE timer 60m`; `mpctl awake on|off|displays-on|
  displays-off|timer N|restore|status` as the phone, printing `KEEP AWAKE …`.
- **Dry run (every DEBUG build by default):** `KeepAwakeMacSystem` logs each change ("would run
  pmset -a sleep 0 (through the helper)", "would set the built-in display's brightness to 0%",
  "would unregister the helper", "would notify: …") and keeps a simulated SleepDisabled; reads are
  real. `MACROPHONE_AWAKE_DRYRUN=0` acts for real. Hooks: `MACROPHONE_AWAKE_PRINT=1` (to stdout),
  `MACROPHONE_AWAKE_ACTIONS=on,phoneon,off,phoneoff,displaysoff,displayson,input,timer@N,tick,idle,
  watchdog,power,restore,keep,remove,wait@S`, `MACROPHONE_AWAKE_MINUTE=<s>` (a "minute" for
  auto-dim and the timer), `MACROPHONE_AWAKE_HELPER=ready|missing|approval|outdated`,
  `MACROPHONE_AWAKE_POWER=battery:18,ac:0,charging:1,thermal:3,lpm:1`, `MACROPHONE_AWAKE_MACHINE=desktop`,
  `MACROPHONE_AWAKE_IGNORE_SAMEEROS=1`, `MACROPHONE_AWAKE_SIM_RESTART=1`,
  `MACROPHONE_AWAKE_RESOLVE=restore|keep`, `MACROPHONE_AWAKE_ALERT=1` (a dry run shows no launch
  alert otherwise), `MACROPHONE_SHOW=quiet-<pane>` (the window on screen without taking the
  keyboard). Proven on this Mac with no real change (`dry-run-proof.txt`): blocked by SameerOS;
  on → displays off → a touch inside 6 s ignored, after it the displays back → watchdog → a 3-"minute"
  timer off with "Keep Awake is off" → on/off from the phone path → auto-dim after 5 idle "minutes";
  a simulated restart → the question → resumed; the battery floor (refused at 9%, off at the floor);
  critically hot → off; sleep left off → restored with the laptop defaults; removal.
- **Needs a real check on his Mac** (after SameerOS's On The Go is off — below — with an installed
  release build): the helper's approval in Login Items and the page turning green by itself; a real
  lid close on battery and on power (the Mac stays reachable from the phone); `pmset -g custom`
  after on → off matching before, per source; BetterDisplay unplug / reconnect of the U2720Q (and
  with BetterDisplay quit); the built-in dim in clamshell with an external (only the built-in
  dims); the screen lock opt-in (`sysadminctl` "-14" if the keybag drifted — the page explains);
  the audio guard with the monitors' speakers; ⌘⇧G / ⌘⇧D once SameerOS no longer holds them; a
  helper version bump stepping down; a crash mid-toggle (kill -9 while turning on); a restart while
  on (the question at login); the quit question; Remove; a desktop Mac and an Intel Mac if one is
  around.
- **Switching SameerOS's On The Go off** (Sameer does it; nothing of SameerOS was touched): in
  SameerOS choose **Back at Desk** (puts sleep, displays and the screen lock back; check
  `~/.onthego-active` is gone and `pmset -g | grep SleepDisabled` says 0); quit SameerOS and take it
  out of Login Items; in System Settings › General › Login Items & Extensions turn off SameerOS
  under "Allow in the Background" (its helper `com.sameer.sameeros-mac.helper`; `launchctl print
  system/com.sameer.sameeros-mac.helper` then fails); optionally delete `~/.onthego-*`, `~/bin/otg`
  and the Keychain items `com.sameer.sameeros-mac` / `com.sameer.onthego` (screenlock-password).
  Then Macrophone › Keep Awake › Allow… once.

## Delight (Nov 8 2026)

Sameer: "I just don't quite feel surprise and delight when using this app … Do it." Apple's way: a
few memorable moments and many small physical ones, never slower, never in the way of a long
prompt, nothing running at rest. All new code is in `iOS/Macrophone/UI/Delight/`; existing views
got one-line hooks. `Delight` (Delight.swift) hears AppModel at three moments —
`wordsLeaving` (in `finish`, as the send begins), `landed` / `missed` (`showLanding`), `undone`
(`undoDone`) — and nothing there touches the link or logs anything but counts. Frames, GIFs and the
rendered sounds: `docs/screens/delight-nov8/`.
- **The words travel** (`WordFlightLayer`, WordFlight.swift; overlay on `MainView.body`): as the
  words go out, their first few (`Delight.firstWords`, ~26 letters) lift off the transcript
  (`Delight.wordsFrame`, from LiveWords) as a glass chip with the Thread's light round its edge
  and drop along a curve — down first, then in, so an icon at the Dock's end never takes it off
  screen — into the pick's Dock icon (`DockSpot.pick`), shrinking, two motes trailing (0.62 s).
  Into a window that shows (the mic opened over it) they sink into the window instead. Only the
  regular iPhone and the cover (`allowed`), only when the words go to the pick, never in full
  screen; nothing is built outside a flight.
- **The Dock catches them** (`DockCatch`, one `.modifier` on `DockIcon`'s tile; events from
  `DockCatches`, its own object so a flight never redraws the Dock): on the landing the pick dips
  under the words, hops 10 pt and settles, a glow of the Intelligence colours behind it; a landing
  that failed shakes it (a Mac's login field). A landing that comes while the words are still in
  the air waits for them (`pendingCatch`). **An app opening from here** (`PlaceOption.Kind
  .opening`) bounces in the Dock the way a Mac's does while an app launches (the spinner only under
  Reduce Motion), never past `AppModel.isOpening`'s 20 s.
- **The Thread is a string** (Filament.swift, "Plucking"; `Filament(pluckable:)`, MainView's
  `threadPluckable`: at rest, never while the mic is open or the words go out, never over a
  window, never on the Duo's deck where a swipe changes pages): a finger pulls it into a triangle
  with its apex under the finger (harder the further, `tanh`), let go it rings with a real string's
  first seven modes (3.1 Hz seen, higher modes dying faster: the kink runs out and smooths away in
  ~1.6 s), a tap plucks it, plucks add up, the cores and bloom glint. Haptics (`ThreadHaptics`,
  Core Haptics, engine made on the first touch and auto-shut-down): a tension that firms as it
  stretches, then a transient and a buzz decaying with the string. The note is where it was
  plucked (`SoundCues.pluck`, G major pentatonic, low on the left). The display link only while a
  finger is on it or it rings. `DelightUITests` plucks it with a real tap and pull and checks the mic
  stayed closed (plucks counted in `debug.plucks`, DEBUG — read the container's prefs plist; `simctl
  spawn defaults read` doesn't see it).
- **Sounds** (`SoundCues`): a landing's two glass tinks (E6 · B6), a send's breath of air then a
  tink, Undo's tinks falling, a milestone's arpeggio, pairing's two notes meeting, the Thread's
  plucked string (Karplus–Strong). Synthesised in code (`SoundSynth`, no assets), rendered once to
  Caches/Sounds as 16-bit WAVs 4 s after launch (`SoundCues.prepare`), played as system sounds:
  they follow the Ring / Silent switch, mix with the app's own audio session (the Mac's sound, a
  podcast) and are quiet by design (−13 dBFS peaks). Played at the catch (with the words' arrival),
  else at the landing. **No listening sound**: it would land in the first syllable the recognizer
  hears. Settings › Appearance › **Sounds** (`settings.sounds`, on by default, `@AppStorage` in
  SettingsView, id `settings-sounds`).
- **Firsts and milestones** (`MilestoneBanner`, Moments.swift; overlay on `MainView.body`): the
  first dictation that ever lands ("Your first dictation landed · Hold the mic for a long prompt,
  tap it for a quick one") and 1,000 / 10,000 / 100,000 words ("… words, said not typed · About
  N minutes / hours of typing saved" — typing at 40 wpm, speaking at 150) — a glass banner that drops
  in under the status bar 0.65 s after the catch, with the milestone sound and `Haptics.arrived`,
  read out to VoiceOver, gone after 5 s or a tap (`delight-milestone`). Only at rest (never over a
  window, the words, a sheet or full screen; one that comes meanwhile waits). Counted on this
  iPhone (`delight.words`, an Undo takes its words back off), never sent. **Seeded from History**
  the first time (`delight.seeded`): someone with months of dictations gets neither "first" nor a
  mark already passed the day this arrives.
- **Pairing: the two meet** (`View.pairingCelebration()`, one line on PairingView's check): a ring
  of the Intelligence colours blooms out from the check, a soft wash behind it, fourteen sparks
  fly, and the paired sound. Reduce Motion: a glow that comes and goes.
- **The Mac pill says hello** (`ConnectRipple` on the pill's dot): when `looksConnected` turns on
  — the first connect, a wake, back after the Mac was gone; not a return from the background, which
  keeps looking connected — a ring spreads once from the dot.
- **The wallpaper has depth** (`ParallaxImage`, in `DesktopWallpaper`): the Mac's wallpaper drifts
  12 pt against the tilt like the Home Screen's — `UIInterpolatingMotionEffect`, applied by UIKit,
  no Core Motion of ours and nothing per frame in SwiftUI; UIKit turns it off under Reduce Motion,
  and it's off in Low Power Mode.
- **Reduce Motion** everywhere: no flight (the catch is the glow alone), no hop or shake, no launch
  bounce (the spinner), the Thread's pluck is light and one soft tap, the banner fades, pairing
  glows. **At rest** nothing of this runs (no timers, no display links); the app measured 2–3% CPU
  at rest on the simulator, the Thread's idle flow as before.
- Hooks (DEBUG): `MACROPHONE_DELIGHT=first,milestone@10000,pluck@0.3,flight@<words>,catch,miss,undo,open@<bundle id>,wait@<s>`
  (each ~1.4 s apart, after `MACROPHONE_DELIGHT_AFTER`, 3 s); a real dictation with
  `MACROPHONE_SIM_RECORD` + `MACROPHONE_WATCH=rest` + `MACROPHONE_WATCH_ACTIONS=wait@1,record,wait@2,stoprecord`.
- Seen on an iPhone 17 Pro (27.0, light and dark) and a Duo's cover (27.1) against `mpctl serve`:
  the flight into Claude's icon and the catch on "LANDED pasted", the miss shake, TextEdit bouncing
  while it opens, a real finger's pull and ring, the first-dictation and milestone banners, pairing.
  The inner screen is unchanged (no flight there; the banner and the pluck on the cover's half).
  `DelightUITests`, `StabilityUITests`, `UndoChipUITests` (7) and `InputCarouselUITests` (4) pass
  on the Pro (`open@` leaves the pick on an app that's "opening" — pick Claude again before the
  carousel's close test, which otherwise watches a window the stand-in doesn't have).
- **Needs his phone:** every haptic (the simulator has none — the pluck's tension and decay above
  all), every sound (rendered and checked as files, never heard: their loudness on a real speaker,
  and that a system sound plays while the Mac's sound has the session), the parallax (the simulator
  doesn't tilt), the flight and catch timing against a real Mac's landing (~0.3–0.9 s; the stand-in
  answers ~1 s after the words arrive).
- **Not done:** alternate app icons (Icon Composer `.icon` bundles per colourway plus
  `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES` — a build-settings change with its own
  verification; worth its own pass), a menu bar clock (the status bar already shows the time), the
  pick's icon breathing while a chat answers (the ember dot says it), the Mac's wallpaper washing in
  as they meet (the wallpaper arrives after the success page).

## Design polish (Nov 8 2026)

Sameer, going to sleep: "another round of design polish on the iOS app. Clean up any rough edges
you find." Walked on an iPhone 17 Pro (27.0; the SE frame; light, dark, accessibility-large) and a
Duo (27.1: the cover, flat on its side, the book, flat upright, the laptop, full screen) against
`mpctl serve`, every sheet and Settings page, frames and recordings. Most of the app held up; what
was rough was mostly **words over the wallpaper**. Frames: `docs/screens/polish-nov8/` (before |
after per area; `walk-pro.png` / `walk-duo.png` the states walked).
- **The status line reads over any wallpaper** (`StatusLine(legible:)`, true everywhere but setup's
  white page, which keeps its look): secondaryLabel straight on the Mac's picture under the veil
  measured ~2 : 1 over the demo's blue, and a miss set in red ~1.6 : 1 ("Didn't land in Claude…"
  all but vanished). Now the words are the label colour on a soft halo of the ground, and the
  meaning is in the mark — the coloured dot, the ✓, and for a miss `exclamationmark.circle.fill` in
  its colour (rose, or ochre for "copied instead"); "Open Settings" is semibold ink.
- **`Ink.tertiary` does what its comment says**: 0.42 grey / systemGray read ~2 : 1 over a
  mid-blue picture (the recording's "To Terminal · Medium cleanup", the window row's hints); now
  0.33 in light and 0.64 in dark (~3 : 1 / ~4 : 1). The recording clock uses it (was secondaryLabel).
- **Undo you can read and hit:** the landed pill's Undo was systemBlue on its glass (1.45 : 1
  measured in dark) and its touch the word's own 16 pt — now ink, its touch the pill's whole
  trailing end, 44 pt tall (`watchTouch(4)` on a 36 pt row). The Undo Paste chip keeps the accent on
  its draining ring and arrow, its words in ink. Ids unchanged (`landed-undo`, `landed-undo-chip`).
- **A picked window that's gone is named by its app:** "That Terminal window isn't open on your Mac
  — it'll be copied instead", not the window's whole title (it ran to three shrunken lines under the
  cover's mic). An app that isn't open still says its own name.
- **Menu bar extras in one ink** (`MenuExtraStyle`: `.monochrome`, was `.hierarchical`, which drew
  the clock's face grey beside a solid display and gear) — as a Mac's template extras.
- **Nothing held for a Mac that isn't paired:** after an unpair the phone's menu bar (and the
  cover's bar) kept a dimmed Whole Screen and Control Center beside "Pair your Mac" — `bar.had.*`
  counts only while a Mac is paired.
- **Settings › Alerts:** "When an agent asks something" wrapped to two lines on a Pro; it's "When an
  agent asks you".
- **The cover's sheets centre their titles** (Open an App, Custom Cleanup — a `.principal` title
  where `VerticalBarProbe.edge` is set, as pairing does); the cover had laid them at the leading edge.
- **Tests:** `UndoChipUITests`, `InputCarouselUITests` (4), `StabilityUITests`, `WatchHeaderUITests`,
  `DesktopWindowUITests` pass. `WatchHeaderUITests.testTheNameReadsWhole` failed on a fresh
  simulator — the first alert watch raises the notifications prompt and the window view waits
  under it (header bare, "Connecting…"); the test now taps Allow as the others do (not a UI bug).
  The cover's keyboard-bar test skips on a Pro, as before.
- **Seen and left:** `mpctl serve` takes one new pairing per run (a second phone gets "Open Macrophone
  on your Mac and choose Pair iPhone" until serve restarts) — a stand-in limit, noted for whoever
  pairs two simulators. `MACROPHONE_TYPE` doesn't reach sheets (use `simctl ui content_size`). The
  bright mic disc shows through medium-detent glass sheets (Your Macs, Control Center) as a soft
  white spot — the system's glass. Control Center's slider fill is black in light (a choice, not a
  bug); its two brightness glyphs (sun.min / sun.max) read nearly alike. The unpaired panel still
  says "Cleanup: Off" (the Dock's bar says "Off" — round 4 kept the long form off the Dock). The
  cover shows "Pair your Mac" three ways at once unpaired (pill, empty state, status line — designed,
  Nov 5). The desktop card's "Show the Terminal window here" runs into its eye badge at accessibility
  sizes, and the card said "Terminal isn't open" for a stale window of an open Terminal — the card is
  another stream's (left alone). The demo window letterboxes in every pose (it can't reshape).

## The ten polish ideas (Nov 5 2026)

Sameer: "Do all 10" — eight agents in parallel, merged the same night. Each below.

### The icon in every Home Screen style (Nov 5 2026)
 `AppIcon.icon` (both apps) is four groups, front to back: Thread (glass: `thread-light`, `thread-dark`, `thread-mono`), Light (halo + glow), Stars (one `stars.png`, 2/3 on the light sky), Sky (opaque). Each is switched per appearance with `opacity-specializations` (light / dark / tinted) plus a white tinted `fill-specializations`. Xcode 27's actool keeps both and drops `hidden-` / `image-name-specializations`, so a layer is only ever faded, never hidden or swapped. Default keeps the dusk sky (a glowing strand needs dark behind it); Dark is the deeper sky. "tinted" covers both mono styles, Clear and Tinted: the sky fades out, the bolder white mono strand (`IconArt.half(.tinted)` = 46) comes in, the glow is a breath (`MonoLook.glow` 0.22 — at ½ it was a white fog) and the stars stay (`MonoLook.stars` 0.9). `sh scripts/sky-icon.sh <work> [install]` also renders all six styles through Icon Composer's `ictool`, before | after, at 60 / 29 pt, in amber and on macOS, into `docs/icon/sky/appearances.png`. Needs his phone: Clear / Tinted / Dark on a real Home Screen (the style picker can't be scripted on the simulator).

### The menu bar icon reacts (Nov 5 2026)
`Mac/App/UI/MenuBar/StatusIconMotion.swift`, driven by `StatusItemController` (`show(_:)`, `cue(_:)`); `DeliveryEngine` says `.arriving` / `.landed` / `.failed` / `.settled` through `AppModel.statusItemCue`. Landed: the icon swells to 1.2× and back in 0.5 s while a layer of the Intelligence colours (`MacOSIntelligence`) masked by the icon's own shape fades in and out (~0.8 s). Failed: a 0.45 s shake and the same in system red. Arriving: an opacity breath, only past 0.35 s, ended by the outcome or after 30 s. Every image change fades (`CATransition`); the watching ring also settles in from 0.82×. All Core Animation on the button's layer — no timer at rest, the template image untouched, no tint while the menu is open. Reduce Motion: fades only (the breath a held dim). DEBUG `MACROPHONE_MENUBAR_DEMO=cycle|landed|failed|arriving|watching|silent[,reduced]`. Needs a real check: a light menu bar, a TextEdit paste with a countdown (the breath), the system's Reduce Motion.

### A dropped connection keeps the picture (Nov 5 2026)
When the link blips while a window shows (Wi-Fi, the app away, the Mac's session restarting), the watch behaves like FaceTime: `Watcher.Phase.reconnecting` holds the last frame (`freezePicture` puts the video's displayed frame under the canvas; `keepPicture` saves it), a shade darker, with a glass "Reconnecting…" capsule (`watch-reconnecting`) only after `WatchReconnect.quietFor` (0.5 s). Taps are off (the viewer is interactive only while live); the answers, the key row and the header's cells keep their places dimmed (`View.watchLive`, `Phase.holdsLayout`, `Watcher.heldFeature` for Sound and Mac Controls, here and in the cover's bar). Link back: `start()` asks for the same window and the phase stays `.reconnecting` until the Mac answers (`answerWait` 10 s, then `.starting`); the first frame lands over the held one with no rim or haptic (`resuming`), `windowSeq` unchanged, so zoom, spot and input page stay; a picture of the same shape at another resolution (home ↔ away) keeps the view (`WatchReconnect.sameShape` / `carriedZoom` in `ViewerScrollView.update`). After `WatchReconnect.limit` (25 s) it's `.offline` with the old card; `.notPaired` goes there at once. `AppModel.reconnecting` (a drop from the connected Mac while active, or coming back to the app after being connected) makes the status line say "Reconnecting to ‹Mac›…", keeps the cover's Mac pill hidden, and drives the Duo glance's words. `.paused(.leftScreen)` holds the same way (no "Paused" card in the app switcher). Proven by killing and restarting `mpctl serve --state <dir>` by PID: iPhone, background return, Duo glance and full screen. Needs a real check: home ↔ away resolution change, the decoder after a real background.

### Haptics and symbol effects (Nov 5 2026)
One vocabulary, named by meaning, in `Haptics` (Theme.swift, the list as its doc comment): `micOpen` rigid (prepared ahead by `readyMic()` from `refreshAvailability` and after each `micClose` — the mic starts on touch-down, so there's no earlier moment), `micClose` soft, `landed` success, `caution` warning, `failed` error, `pick` selection (a place, a page, a switch, a level, a Mac, a window, a size, a slider's detent), `press` light (a key, a click, a command to the Mac, Copy, Send Again), `rightClick` medium, `grab` (a drag picked up, the floating mic lifted, the hold's trackpad), `arrived` soft (a window's first picture, a fold, a window closed on the Mac). Generators are made once. One event, one haptic: a view calling a model method that already speaks stays quiet. A held key's repeats go through `Haptics.quietly`. Nothing on navigation: Done, a sheet, Show it here, full screen, opening a window (its first picture is `arrived`). Symbol effects only when a glyph changes meaning or an action lands, never at rest: `LandedGlyph` (MainView: the check `drawOn` on iOS 26, else a bounce; `LandedChip.sent` → `paperplane.circle.fill` bouncing up; Undo's arrow replaces), `DockOptions`' paper plane flies on turning Send on and on a sent landing (`flights`), History rows' mark replaces and the plane hops on landing (`landings`), the widget's status replaces and Copy → Copied for 1.5 s, Sound / Pan|Scroll / the display glyph replace, Control Center's keys bounce on a tap (`taps`, not the slider's steps), the eye on a watch tap (`PlaceButton.watches`), the wand on a cleanup level. `MacControlsPanel` is unused (MacControlCenter replaced it).

### Empty and error states (Nov 5 2026)
Every one is `EmptyState` (`UI/EmptyState.swift`, a `ContentUnavailableView`): a symbol, a sentence-case title with no full stop, one sentence, at most one button that fixes it (`emptyStateButton()`; Wake Your Mac is `WakeMacAction`, the menu bar's rule). The phone's desktop and the Duo's cover say what stands between the mic and the Mac in the desktop's empty room (`DesktopTrouble`, `DesktopEmptyState`, an overlay under the menu bar that never moves the mic), in order: the mic or speech recognition off (Open Settings, also found at launch by `Recorder.permissionOff`), unpaired (Pair a Mac), Local Network off (Open Settings), not found (Wake Your Mac; never while `settling` or `reconnecting` — **[Nov 7 2026: away from the Mac's network, the missing Tailscale step instead, `MacNotFoundAction`]**). On the regular iPhone the status line says nothing about it meanwhile (`StatusLine(desktopSays:)`) and the menu bar's Wake steps aside; on the cover the line keeps its words and drops its "Open Settings" link (`desktopFixes`). In a short room the state sheds its sentence, then its symbol. The Duo glance: Pair your Mac · Can't find ‹Mac› (Wake) · Local Network · ‹App› isn't open (Open ‹App›, `openOnMac`); still looking is "Connecting to ‹Mac›". History off has Turn On History; Open an App offline has Wake, no apps has Try Again; Your Macs, Dictionary and Language have their own. The Dock has no divider with no open apps. Hooks: `MACROPHONE_FAKE_PAIRED=none | <name>@offline`. Frames: `docs/screens/empty-states-nov5/`.

### The Dock's window previews (Nov 5 2026)
A long press on a Dock icon (`DockIcon`'s simultaneous `LongPressGesture`, 0.42 s, 10 pt reach — a drag fails it, so the scrub never opens it; `swallowTap` keeps the lift from being a tap; `Haptics.grab`) opens `DockWindowsPopover` (`UI/MacOS/DockWindows.swift`) — a glass popover over the icon (`.popover` + `presentationCompactAdaptation(.popover)`; a context menu's preview takes no taps and doesn't scroll): the app's name and "N windows", a sideways strip of `DockWindowCard`s — the window's kept picture (`WindowSnapshots.small(_:maxPixel:)`, decoded small off the main thread and cached apart from `cached`; the card's width from `pictureSize`, read off the file's header, so the popover never changes width), or the app's icon on a plate, its title, the pick ringed in the accent, the ember mark and "Answered you" / "Asking you" — then Show Window (`dock-show-window`; the pick or the newest, picked then watched 0.32 s later so it grows out of its icon). A card tap picks that window. A picked Clipboard / Where I'm typing gets Show Window alone. VoiceOver: each card a button named by its title, selected for the pick, with a Show Window action; the icon has "Show Windows". No wire: the pictures are the ones kept last time each window showed. Tests: `DockPreviewsUITests` (a paired `mpctl serve`; `TEST_RUNNER_MACROPHONE_DOCK_SHOTS=<dir>`). Frames: `docs/screens/dock-previews-nov5/`. XCUITest's synthetic drag doesn't drive the Dock's scrub (on main before too); it needs a real finger.

### The icon's long press, Siri and Shortcuts (Nov 5 2026)
Quick actions (`App/QuickActions.swift`): Dictate to ‹pick› (`mic`) · Watch ‹app› (`eye`, the last two windows watched, `quick.watched.<mac>`, only while their app is open) · Whole Screen (`display`, when the Mac offers it or did last time — `bar.had.wholeScreen`) · Dictate to Where I'm typing (`text.cursor`), four at most, refreshed (debounced) on the pick, the open apps, the Mac, the link and every watch. Cold launch: `AppDelegate.application(_:configurationForConnecting:options:)` reads `options.shortcutItem` and sets `QuickActionSceneDelegate`; warm: `windowScene(_:performActionFor:)`. Dictate goes the way `startFromIntent` does, Watch the way the widget's `openAttention` does, Whole Screen waits for the connect (`waitingWholeScreen`). The widget's `onOpenURL` still works with the custom scene delegate (tested). Intents: `SendTextIntent` (no app open; text, place, `sendAfterPasting: Bool?` — nil = the place's own setting) → `AppModel.sendTextFromIntent`: History, `deliver`, queued when the Mac can't be reached, never cleaned, Siri says where it went. `WatchPlaceIntent` (place or `screen`, options from `WatchPlaceOptions`). `TargetQuery` is an `EntityStringQuery` and offers an app with several windows by its own name. Phrases: "Send to / Tell / Send text to ‹place› with Macrophone" (Send Text — moved off Start Dictation), "Watch / Show ‹place› with Macrophone", "Watch my Mac with Macrophone", "Dictate to Macrophone". Hooks: `MACROPHONE_INTENT_SEND=<place>@<text>[@send|@paste]`, `MACROPHONE_INTENT_WATCH=<place>`. `QuickActionsUITests` (`TEST_RUNNER_MACROPHONE_QUICK_TEST=1`, a paired `mpctl serve` with Claude watched once; a fresh simulator has the icon on page 2). Needs a real phone: Siri's parameterized phrases (the simulator's Siri didn't match them), Send Text connecting from a background launch.

### A real keyboard types into the Mac (Nov 5 2026)
With a Bluetooth / Magic Keyboard (or the simulator's) on the phone while a window is in hand, any iPhone: `HardwareKeysView` (UI/HardwareKeysView.swift, behind RootView) is first responder while `watcher.isShowing`, the page isn't the keyboard, `HardwareKeyboard.shared.connected` (GCKeyboard; a heard press counts too), no sheet is presented and no other `UIKeyInput` holds the keyboard (looked at every 0.4 s). `HardwareKeyRouter` (MacrophoneKit `Core/HardwareKeys.swift`, pure, `HardwareKeysTests`): HID usage → Mac key name; characters (⇧ ⌥ included, iOS's layout) → `watchType`; non-characters (Esc ↩ ⇥ ⌫ ⌦ arrows Home/End Page F1–F20) → `watchKey` with ⇧⌥; ⌘ and ⌃ held on the Mac via `watchKeyState` while held here (reconciled on every key, let go on Done / resign active / another responder / disconnect); ⌥Tab = the Mac's ⌘Tab with ⌘ held until ⌥ is let go (iOS keeps ⌘Tab: Tab never arrives while ⌘ is down); Caps Lock stays on the phone. The phone repeats a held key itself (0.4 s, then every 0.045 s: characters, ⌫ ⌦, arrows, Page, Space — never a ⌘/⌃ chord, Esc, ↩, ⇥). The view is a `UIKeyInput` with an empty input view (`insertText` / `deleteBackward` routed too, guarded 0.1 s after a press); Tab in every combination is a priority key command. On the keyboard page `KeyboardTextView` types characters / ↩ / ⇥ / ⌫ itself and sends chords, Esc and arrows as keys. ⇧ / ⌥ held go on clicks (`takeModifiers`). With a keyboard the folded deck opens on the trackpad; "Keyboard connected — typing on your Mac" once per connection. XCUITest on the simulator: `typeText` arrives as inserted text, plain `typeKey` never reaches a responder, chords with ⌘/⌥ are real presses, Tab never comes. Hook `MACROPHONE_WATCH_ACTIONS=hwkeys@command+tab+tab`. `HardwareKeyboardUITests` (`TEST_RUNNER_MACROPHONE_SERVE_LOG=<serve's output>`). Needs a real keyboard: plain letters / arrows / Esc as presses, no double typing, ⌘H / ⌘Space releasing ⌘ on the Mac.

Left from the Nov 5 pass: `MacrophoneUITests.testMicButtonNeverMoves` fails at "the controls are hidden while recording" — on 6503903 too (the desktop redesign keeps Send after pasting on screen while the mic is open); the test predates it.

## The Mac's own pointer on the trackpad (Nov 1 2026)

Sameer: the trackpad's cursor "a bit smaller … it should contextually change just like it does on
the Mac". `MacCursor` (MacrophoneKit `Core/MacCursor.swift`, `Transport/CursorLink.swift`, feature
`cursorShape`, the wallpaper pattern): `.macCursor` Mac → phone — the cursor's PNG at 2× its points,
its size and hot spot, an id hashed from its pixels — only to a phone that named it, only while that
phone's trackpad pointer is up. The Mac (`WatchService.followCursor`) reads `NSCursor.currentSystem`
15 times a second through `MacCursorReader` (`Core/MacCursorAppKit.swift`: drawn into a small bitmap
and compared; the PNG only on a change; reset on each show so the shape goes at once). The phone
(`PointerShape` in `UI/TrackpadView.swift`) draws it at its size in points with the hot spot under
the pointer; until one arrives, and for a Mac from before, a drawn arrow like the Mac's (black, a
white edge, ~13 × 20 pt — was 16 × 25 with a cyan glow). Dropped on a switch to another Mac. AppKit
must be up before a cursor has a picture (`NSApplication.shared` — the tests and `mpctl` do it).
`mpctl serve` names it and sends the demo's shapes (the hand over the traffic lights, the I-beam
over the text column, resize at the side edges, else the arrow; `WATCH CURSOR <name> N bytes`) —
its demo window still draws its own white arrow into the picture, offset from the phone's: the
stand-in only. Tests: `MacCursorTests`. Needs a real check: the Mac app with a real phone — an
I-beam over TextEdit, the hand over a link in Safari, resize at a window's edge, a background app's
cursor (macOS updates a background app's cursor only where it asks to).

## Several Macs on one iPhone (Oct 19 2026)

Sameer: "I should also be able to pair multiple Macs to my phone and switch easily by swiping up
and down in the top left where it shows what Mac is connected." The phone keeps every pairing
(`PairingStore` always could); **one Mac is active** — the mic sends to it, the window view shows
it, the pill names it. The Mac side is unchanged: each Mac pairs with the phone on its own.
- **Rules** (`Storage/MacRoster.swift`, tested in `MacRosterTests`): the order is the order they
  were paired; the active Mac is the chosen one (`macrophone.activeMac` in UserDefaults) else the
  most recently paired — v1's rule, so a phone with one Mac migrates with nothing to re-pair;
  `step(±1)` goes round the list. `MacPreferences`: each Mac's own Send to pick and remembered
  Paste / Paste & send (`settings.selection.<macID>`, `settings.sendByTarget.<macID>`); the one
  Mac's old keys are adopted by the first Mac once (`adopt`). Open apps cache per Mac
  (`targets-<id>.json`, the old `targets.json` moved once); wake info and landing reports were
  per Mac already; remote addresses live on the `PairedPeer`.
- **Link** (`LinkClient.setActiveMac`): the session to the Mac before closes, a dial that
  finished for it never installs (`switchGeneration`), anything waiting on it fails with
  `LinkError.anotherMac` and the app queues it **for that Mac** (`DeliveryQueue.Entry.macID`;
  `flushQueue` sends only the active Mac's; `send(_:delayed:to:)` refuses another Mac's). A Mac
  that forgets the phone, or is unpaired, hands over to the next (`settleChoice`); none left →
  not paired. Pairing again with a known Mac keeps its place and addresses.
- **Phone:** `AppModel.pairedMacs` / `pairedMac` (active), `switchMac(to:direction:)`,
  `stepMac(±1)`, `adoptMac` (everything on screen becomes that Mac's: apps, pick, marks, displays;
  the watch closes), `standing(of:)` (connected · looking · not found; another Mac: on this
  network or not, by Bonjour). **The pill** (`MacPill`, `RollingName`): tap → the Macs list
  (`UI/MacsSheet.swift`: each Mac's light, standing and sign, a tap switches; Pair Another Mac…;
  Settings) with several, Settings with one, pairing with none; **swipe up / down = next /
  previous**, the name rolls on the settle spring with a tick (Reduce Motion: cross-fade), the
  pill's width follows on the same spring; VoiceOver: adjustable + "Choose a Mac". Settings › Macs
  lists every Mac (`MacRow`, Unpair beside each, a tap switches) and Pair Another Mac; the pairing
  flow adds to the list and the new Mac becomes active. Widgets and the control follow the active
  Mac (`CachedTarget` / `WidgetApp` re-saved on a switch).
- **Hooks:** `MACROPHONE_FAKE_PAIRED="Studio Mac|MacBook Air"`, `MACROPHONE_PILL_ROLL=0.45`
  (held mid-roll), `MACROPHONE_SWITCH_MAC=<name>`, `MACROPHONE_UNPAIR=<name>`,
  `MACROPHONE_SCREEN=macs`. Proven on the simulator against two `mpctl serve --name … --remote
  --port 47951|47952 --state <dir>` (`MultiMacUITests`, real swipes on the pill; each serve's log
  says which words it got); frames in `docs/screens/multi-mac/`.

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

## The carousel fixes (Oct 19 2026) — what Sameer found on his iPhone and Mac

Contact sheet (before | after, Pro and SE): `docs/screens/carousel-fixes-oct19/`. Proven with real
touches by `InputCarouselUITests` (a paired `mpctl serve`): a swipe on the Thread, a drag on the
trackpad read back off its value ("Pointer 52 percent across, 61 percent down"), hide → mic, the
Mac Controls button and panel, Close Window → the main screen.
- **The page row is above the Thread** **[superseded Nov 7 2026, round 5: while a window shows, no row and no Thread on any iPhone — the keyboard and the trackpad are buttons beside a 64 pt mic]** ("the switcher should be above the wave form"): `InputCarousel`
  now holds the row, then the Thread (`thread:`), then the pages, as one band — a horizontal swipe
  anywhere on the Thread or beside the mic (never on it) slides the pages; the mic's tap and hold,
  the window's gestures and vertical scrolling are untouched. The Thread shows on the mic page only.
- **The trackpad takes the Thread's room** (`pagesHeight`: the mic page's height + the Thread's slot,
  so the window above never moves; Reduce Motion: a fade). The row stays above it to go back.
- **The keyboard page is the iOS keyboard with ONE bar** **[superseded Nov 7 2026: one 44 pt row, the modifiers in Mac Keys — round 1]** (`MacKeyboardBar`, two rows, 94pt:
  `esc ⇥ | ← ↑ ↓ →  Typing in Claude` over `⌘ ⌥ ⌃ ⇧ … fn | ⌨︎`): the arrows had been on the
  carousel's page and the modifiers on the keyboard's bar — two strips laid out by two systems that
  overlapped once the keyboard rose. The page itself is a 10pt breath under the row. A swipe
  right-to-left on the bar's open room, hide, or the row come back to the mic — and **the keyboard
  leaving for any reason leaves the page too** (`KeyboardTextView.onKeyboardGone`, 0.35 s after a
  resign the field still wanted): never a keyboard page with no keyboard.
- **The pointer is an arrow you can see** (`PointerSpriteView`, TrackpadView.swift): the Mac's own
  arrow shape ×1.3, white with a dark edge and a cyan glow, placed in UIKit by `ViewerScrollView`
  (`pointerHost`) but drawn in `WatchWindow`'s stack above Newest and the notes (`PointerOverlay`,
  `PointerLink`); it mirrors at the window's right/bottom edge so the body stays whole; a pulse on
  first show. It **starts where the Mac's pointer is**: the frames' words carry `cursor`
  (`WatchVideoFrame.cursor` / `WatchFrame.cursor`, optional — a Mac from before sends none; the
  Mac fills it from `CGEvent.location` while the trackpad is up and the pointer is inside the
  window, and sends words at once on `.show`), else in the middle of what's on screen
  (`MacInput.visibleCenter`, from the viewer); the Mac's place is taken only until the trackpad
  moves it (`untouchedSinceShown`). The zoomed view follows it (`keepPointerInView`, content
  coordinates, 36pt margin). **One pointer:** the Mac no longer draws its own into the stream
  (`WindowStream.showsCursor` stays off; it lagged the phone's by a frame and read as a ghost;
  hover still works — the pointer is left where it is). The trackpad plate lights under each
  finger (a radial glow that follows and fades). Mac diagnostics: "watch input: N clicks, M
  pointer moves (K didn't land, warped there)" — `InputPoster.missed` reads the cursor back before
  each move while the trackpad is up and warps when it isn't at the last target.
- **[superseded Oct 31 2026: every window opens fitted — auto-fit above]** **An app opened from the phone opens fitted to the iPhone** (`AppModel.openOnMac` →
  `Watcher.fitNextOpen`, only for an app that wasn't running; applied on its first picture once the
  viewer has its size, `fitToPhone(opened: true)`, forgotten after 10 min). Windows he had keep
  their remembered choice.
- **Mac Controls is its own button** (`MacControlsButton`): a cell beside Sound in the window
  view's header (one piece of glass; every page, Whole Screen too) and a pill beside Watch on the
  Send to panel — only with a Mac naming "macControls". It opens `MacControlsPanel` (sheet,
  `.height(418)`): the Mac's answer as words and a meter (`MacReach.lastControl`), big cells for
  volume − / mute / +, brightness − / +, ⏮ ⏯ ⏭; a press ticks and the panel stays; a key the Mac
  can't press says why in ochre. The submenus in the ··· keys menu and Send to's ⋯ are gone.
  Hook: `MACROPHONE_REACH=controls`.
- **A closed window brings the main screen back** (`WatchState.unavailable(_, canReveal:, closed:)`,
  coded by hand in the synthesized shape so older peers interoperate — `WatchStateWireTests`): the
  Mac's `resolve` marks a window gone for good (closed, its app quit, no window left) and says so
  only after a 1.2 s beat still gone (a window re-created meanwhile is found again and nothing is
  said; after the phone's own Close there's no beat); minimized / another desktop never comes this
  way, nor the whole screen. The phone closes the view as Done does, one soft haptic, "Closed
  ‹name›" in the status line, and Send to moves to the app when it still has another window, else
  Where I'm typing (`AppModel.windowClosed`). `mpctl serve` closes its demo window on the Window
  menu's Close (`WATCH CLOSED`).
- Words: the tip is "Swipe the Thread for a trackpad or keyboard".

## The polish pass over the five Oct 19 features (Oct 19 2026)

Sameer: "do a polish agent to make sure everything works well together and looks fantastic."
Walked on the simulators against `mpctl serve`; the contact sheet is `docs/screens/polish-oct19/`.
What changed (the mechanics below still hold where not named here):
- **The keyboard's keys fit every phone, in two rows** **[superseded Nov 7 2026: one 44 pt bar + Mac Keys — round 1]** (`MacKeyboardStrip` + `MacKeyboardBar`,
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
  the tip is "Swipe beside the mic for a trackpad or keyboard" **[superseded by the carousel
  fixes: "Swipe the Thread for a trackpad or keyboard"]**; with two displays the Whole
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

- **The carousel** (`UI/InputCarousel.swift`, `Model/MacInput.swift`) **[the layout is superseded by
  the carousel fixes above: the row sits above the Thread, the Thread is part of the swipeable band,
  the trackpad takes the Thread's room, the keyboard's keys are one bar on the keyboard; the gestures
  and the wire below still hold]**: the area under the Thread,
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

## What's laid over the window shows, and takes clicks (Oct 19 2026)

Sameer: "I tried opening TextEdit, the document creator popped up, but I could not click anything
on it from my phone." TextEdit is sandboxed: its Open panel is drawn by the Open and Save Panel
Service (`com.apple.appkit.xpc.openAndSavePanelService`, an XPC process, layer 0, a window id
*older* than TextEdit's — it's reused) in its own window over TextEdit's, and the stream showed
only TextEdit's (130 frames given, 1 changed) while each click "raised" TextEdit first.
- **Companions** (`WatchCompanions`, MacrophoneKit, pure, `WatchCompanionsTests`): on-screen
  windows in front of the watched one that overlap it and are the same app's (any level 1–1000 —
  menus, popovers, panels, tooltips — or a normal-level window inside it and smaller: a sheet), a
  known remote-view service's (open/save panel, ViewBridge, share sheet, Quick Look, by bundle id
  or owner name — found from the process path when it has no app entry), the window server's
  pop-up menus (layer ≥ 101), or any non-app process's window made after it, ≥80% over it and no
  bigger, while its app is in front. Never another ordinary app, never Notification Center's
  full-screen layer 21, the Dock, Control Center, Macrophone.
- **Streamed together** (`WindowStream.show(display:windows:area:)`): `SCContentFilter(display:
  including:)` = window + companions, `sourceRect` = their union clipped to the window's display;
  `show(window:)` goes back to the window alone. `Settle`: a new set or area goes at once, back to
  alone only after 0.4 s gone. The watch loop looks every 0.25 s for 2.5 s after a click or key,
  0.5 s while companions are up, else 1.5 s. Log: "watch: with N companion windows".
- **The phone's fractions follow the area** (`InputPoster.set(area:)`, `ScrollPoster.area`,
  `points` = the area's size, the place to type re-framed — `WatchCompanions.reframe`); a click on a
  companion is posted straight there (`WindowServer.spot` → `.companion`: no raise, no wait); `act`
  counts a companion in front as the window; Every Window leaves companions of a watched window out.
- **Needs a real-device check:** TextEdit's Open panel (open TextEdit with no document, watch it,
  pick a file / New Document), a right-click menu in TextEdit (hold on the phone, pick Look Up),
  a pop-up button menu (the font-size pop-up in TextEdit's ruler), and a Save sheet (⌘S on an
  edited document, type a name, Save) — each should show on the phone and take the taps.

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
| `Mac/` | Menu bar app (XcodeGen `Mac/project.yml`): Send to (live targets, paste and send), History, Dictation (hold 🌐 at the desk — `App/Desk/`), Agents, Devices, Developer, General; the `macrophone`/`mp` CLI + MCP server (+ `mp hook`); Sparkle updates, `scripts/release.sh` |

| `Mac/` | Menu bar app (XcodeGen `Mac/project.yml`): Send to (live targets, paste and send), History, Agents, Keep Awake, Devices, Developer, General; the `macrophone`/`mp` CLI + MCP server (+ `mp hook`, `mp awake`); `Mac/Helper` = Keep Awake's root daemon (`MacrophoneHelper`); Sparkle updates, `scripts/release.sh` |
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
  with no built-in or Apple (vendor 0x610) display answers that it can't. Phone **[superseded by the
  carousel fixes: `MacControlsButton` + `MacControlsPanel`, the submenus are gone]**: `MacControlsMenu` — a submenu in
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
  are, a swipe in from a side edge goes to the next/previous; Send to follows the window shown **[superseded Nov 7 2026, round 4: flips go in Dock order and only look; a dictation goes to the window on screen for that recording alone — the Duo's inner poses still pick on flip]**.
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
- **Mac:** Devices › Away from home — Remote access (off by default **[Nov 7 2026: on by itself once Tailscale is connected, unless switched by hand]**; `Settings.remoteAccess`,
  `remotePort`, default 47821). On, `LinkServer.setRemote` listens on the fixed port and takes
  connections from beyond the network; off, a connection from away (`!isLocal(source)`) is closed
  before any handshake. `AppModel.refreshRemoteAddresses` (on listener ready, the setting, an
  `NWPathMonitor` change) publishes the list and `broadcastRemoteAddresses` to phones whose hello
  named `"remote"` (`RemoteAccess.feature`); the pane shows the Tailscale address and name (or Get
  Tailscale), the local addresses with Copy, the port, and two sentences on Tailscale / port
  forwarding **[superseded Nov 7 2026: the five-step `AwayGuide`, the rest under Without Tailscale — "Setup on the Mac, and Tailscale guided"]**. `SecureSession.isRemote`, `LinkServer.isRemote(peer)`, `AppModel.remotePeers` —
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
  typed address (`setTypedAddress`) **[Nov 7 2026: inside the away guide; the typed address under
  its Without Tailscale]**; diagnostics count the addresses, never print them.
- **mpctl:** `serve --remote [--port N]`; phone side `--dial host[:port]`, `--no-bonjour` (stands
  in for a network where Bonjour finds nothing), `--away-after`; `mpctl roam [--bonjour-after N]
  [--expect remote|home]` prints `PATH remote (away from home)` / `PATH local (back home)`.
  Proven on one Mac (the LAN IP 192.168.4.22 as the VPN stand-in): away in 5–9 ms, a dictation
  lands, the move home with no "not found" in between. Still needs a real phone on cellular with
  Tailscale on both.

## Permissions on the Mac, and the video lane away from home (Oct 19 2026)

**Permissions.** The Mac's setup is pair · paired · login · **permissions** · modes (four dots) **[superseded Nov 7 2026: pair · permissions · away · all set, each skipped when done, no dots; the setup's rows are `CheckRow`s, General keeps `PermissionRows`]**.
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

## The Duo, shipped for his review (Nov 1 2026, evening)

Sameer: "ship, I'll review and tell you what I want to be done better". Built and installed, not
yet seen on his phone:
- **The box on the open screen** was `UIRequiresFullScreen` (deprecated in iOS 26): iOS treated
  the app as fixed-size and kept it at the size it launched at (his log: `469×553 on 669×951`).
  Gone; `AppDelegate`'s orientations follow the hinge (`Posture.hingeOpen` = every way), asked
  again the moment the hinge opens or closes. The simulator never showed the box.
- **The laptop's picture** sits in from the screen's rounded corners (`DuoLook.edgeInset` =
  r·(1 − 1/√2) of the display's corner, read from the screen, else 40; its corner concentric,
  `edgeCorner`). **Upright, the keyboard has no bar** (`MacKeyboardField` drops its accessory in
  the laptop and flat upright): nothing over the window; the system keyboard's own hide key.
- **Flat upright is no longer the laptop's halves:** the window takes all but a deck of
  `DuoLook.flatDeck` 300 (360 at rest, at most 45%), and the controls go in the bar —
  `MainView.barUsed` is true for `.open(landscape: false)` (where iOS puts the items upright
  needs his phone).
- **Settings and History take the inner screen.** On the inner screen they are no longer a form card:
  `InnerScreenSheet(size: .screen)` sizes them with `InnerScreenFill` (the window's safe area less
  16 pt a side). Settings is iPad Settings (`SettingsView.split`, `NavigationSplitView`: the Mac
  banner, then `SettingsGroup` — Send to · Cleanup · Watching and alerts · Recording · Appearance ·
  Your Macs · History · About; pages push in the detail column; it opens on Send to). History is
  Mail on an iPad (`HistoryView.split`: the list left, `HistoryPage(onDelete:)` right, the newest
  open). The cover and every other iPhone keep the one list. Unverified: that a sheet there gets a
  regular width (else one column), and that each group fits without scrolling.

## The Mac's wallpaper on the iPhone (Nov 1 2026)

Sameer: "imagine if Apple built a Mac controller for the iPhone" — the phone is being drawn as a
little macOS desktop, with the connected Mac's own desktop picture behind it. The plumbing only;
the screens draw it.
- **Wire** (`Core/MacWallpaper.swift`, `Transport/WallpaperLink.swift`, feature `wallpaper`, the
  `permissions` pattern): `.macWallpaper(MacWallpaper)` Mac → phone — `id` (the first 16 hex of
  the JPEG's SHA-256), `jpeg`, `width`, `height`, `isDark?` (average brightness under the middle)
  — after the welcome (asked of `LinkServerWallpaperDelegate.macWallpaper(_:for:)` on its own task,
  so the receive loop never waits for a drawing) and on a change (`sendWallpaper(_:to:)` /
  `broadcastWallpaper`, which refuse a phone whose hello didn't name it). The phone hears it
  through `LinkClientWallpaperDelegate` with the Mac's id. Never the file's path or name: the
  picture is drawn afresh (no metadata, no photo's location). `MacWallpaper.make(from:)`: the
  whole picture, never cropped (the phone takes its own slice — upright, on its side, the Duo),
  long side ≤ 2,400 px, JPEG 0.7 stepping down to ≤ 400 KB, never over 1.2 MB. Tests:
  `WallpaperTests` (the making, the shape, a phone that named it gets it after the welcome and on
  a change, an older phone never does and its session goes on).
- **Mac** (`Mac/App/Core/Wallpaper.swift`, `WallpaperSource`): the main screen's
  `desktopImageURL` read with ImageIO at 2,400 px (a dynamic HEIC's main picture), else
  `NSImage(contentsOf:)`; a folder or an unreadable file sends nothing. Made off the main thread
  once per file + date (kept on the Mac only); again on a space change, a display change and every
  30 s while a phone that shows it is connected; each phone gets a picture once. Log: "wallpaper:
  made N KB, W×H, in N ms" / "wallpaper: sent N KB, W×H, in N ms" — sizes and times only (reading
  this Mac's own 4096 × 2160 HEIC at 2,400 px took ~400 ms the first time, in a probe).
- **Phone** (`iOS/Macrophone/Model/WallpaperStore.swift`): `model.wallpaper.image` (UIImage?, the
  active Mac's, decoded off the main thread) and `.isDark`; each Mac's last one on disk
  (`wallpaper-<mac>.jpg` + `.json` with its id), shown at launch and on a switch, dropped on unpair.
  `MACROPHONE_FAKE_WALLPAPER=1` (DEBUG) holds the drawn demo gradient.
- **mpctl:** `serve` sends the drawn demo (blue, teal, lilac washes) or `--wallpaper <path>`;
  `listen --features wallpaper [--save-wallpaper x.jpg]` prints `WALLPAPER 2400×1350 98 KB · dark · id …`.
- Needs a real check: the Mac app against a phone (only `mpctl` stood in for it), a folder /
  rotating wallpaper, an aerial (`.madesktop`) picked as the wallpaper, a space with its own picture.

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
.build/release/mpctl wake-testset ~/wakeset && .build/release/mpctl wake-bench ~/wakeset --quiet   # the wake word: hits, false triggers, cost (~28 min real time)
.build/release/mpctl wake-soak --minutes 30 --set ~/wakeset --every 60                           # CPU and memory over time; --ungated is the no-tiers baseline
.build/debug/mpctl watch --target com.anthropic.claudefordesktop --swipe 0.3 --features video   # a swipe as the phone sends it, video back
.build/debug/mpctl watch --sound --features video,sound      # the Mac's sound: serve's tone, latency and underruns printed
.build/debug/mpctl serve --remote --port 47899 --auto-approve   # then: mpctl pair '<url>' (at home), and
.build/debug/mpctl roam --no-bonjour --bonjour-after 3 --expect home   # away by the stored address, then back home
.build/debug/mpctl relay --listen 47915 --to 127.0.0.1:47899 --loss 0.02 --rtt 80   # a lossy link (with serve --remote --busy)
.build/debug/mpctl probe --no-bonjour --dial 127.0.0.1:47915 --only-dial --features video [--no-lane]   # input round trips under it
```

## Rules

- Every iPhone build goes to TestFlight too (Nov 6 2026): `~/claude-projects/scripts/testflight.sh macrophone`. Never submit for review or touch the store listing unless Sameer asks. The Mac app still installs locally only.
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
