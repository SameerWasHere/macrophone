# Macrophone

Free iPhone app + companion Mac app: dictate on the phone, pick any app open on the Mac (or the
clipboard, or wherever you're typing), and the text is pasted there — or pasted and sent — at the
cleanup level you choose (Off · Light · Medium · Heavy · Custom). Agents can pull dictations through
a small local API / CLI / MCP. Simplified to that core on Oct 13 2026 (automations, snippets,
templates and the Delivery pane were removed on purpose — don't bring them back unasked).
The original spec is `docs/SPEC.md`. Push to `main`.

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
  as a real switch, Cleanup's menu, ⋯ = Refresh + the share items) and **the Dock** (`SendToDock`,
  `UI/MacOS/Dock.swift`: the open apps with running dots, a divider, Clipboard and Where I'm
  typing, + = Open an App; the pick lifted with its name over it — `send-to`; tapped again =
  Watch, the eye badge; a long press = its windows; a finger scrubbing along it magnifies and
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
  with its steps — moved off the main list). Every row leads with a Settings icon (`SettingsIcon`,
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

## The product, as it stands (Oct 18 2026)

Reader (the window's words as text) was cut the same evening — Sameer: "not that great … focus on making the window view really good". The speed pass (same night): no paste countdown when nobody's at the Mac, no fixed settle waits, the result before the clipboard's restore; the Mac gets the place ready while you speak (`prepare`, feature "prepare" — Paster.prepare); cleanup runs during your pauses (AppModel.cleanAhead); video sends every real change (WatchPacing `live`), 60 fps at home, Retina up to 2,560 px.

Two days of features from several hands, read as one product: every feature has one name, one
glyph and one obvious way in on each app. This map wins over any older section below (the ones it
replaces are marked **superseded**); the sections below keep the mechanics and the numbers.

| Feature | iPhone | Mac |
| --- | --- | --- |
| **Send to** (the shared choice, "Send to" everywhere — never "Send To") | The controls panel by the mic: `SEND TO` kicker, the pick's name, a row of app icons only (a long press lists an app's windows), **+** at the end = Open an App (the only way to open one that isn't open), **⋯** = Send a Photo… · Send a File… · Copy Mac's Clipboard · Send Clipboard to Mac · Refresh Open Apps. Settings › Send to is the full list. `UI/QuickControls.swift`, `UI/SendTo.swift`, `UI/SendToMac.swift` | The menu bar menu's Send to section (a check on the current, the first six apps, More Apps, Send after pasting as its own toggle); the `SendToCard` above every window pane; the first-run step. `UI/StatusItemController.swift`, `UI/Components/SendTo.swift` |
| **Watch** (the window, live, as video) | **Watch** beside the Send to name, or by itself after a send (Settings › Show the app after sending), or the Watch widget; Done ends it. The name at the top is the window menu (page dots, a swipe in from a side edge flips); tap = click, tap twice = double-click, tap then hold-and-move = drag, hold / two fingers = right-click, pinch = zoom; **Pan \| Scroll** under the thumb (Scroll picks itself when the whole window is on screen, and when a window was fitted to the phone); Esc · ↑ · ↓ · ⏎ · **···** (More keys, by section) or the question's answers as buttons; the **KEYBOARD · MIC · TRACKPAD** row above the Thread (Oct 19 2026 — the pages slide under it; the trackpad takes the Thread's room); **Mac Controls** beside Sound in the header (the carousel fixes). `UI/WatchPanel.swift`, `Model/Watcher.swift`, `UI/InputCarousel.swift` | Streams the one window (`Watch/WatchService.swift`, `VideoPipe`, `WindowStream`), posts clicks, drags, the pointer, typing, keys and trackpad-style scrolls (`InputService.swift`, `ScrollPoster.swift`); the menu bar icon becomes a ring and the menu gets **Stop Showing ‹app›** while a phone watches |
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
  Controls · ⋯ (Refresh, photo, file, clipboard); watching it holds Done (`visibilityPriority(.high)`,
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
- **The mini MacBook** (`UI/DuoLaptopDeck.swift`) **[superseded Nov 1 2026 on the laptop: its deck is one mode at a time, each the whole half; this column stays on the book's page and the open screen's right page]**: while a window shows on the inner screen the
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

## Full Screen on the Duo on its side (Nov 3 2026)

Sameer: "a full screen button … next to the window selector … the window take up the entirety,
edge to edge … the window should resize to fill the screen … if it's the Mac display, it should
just fill the screen". On the inner screen on its side (flat landscape, the book —
`Watcher.allowsFullScreen`), a glass button beside the window's name (`WatchHeaderBar
.fullScreenButton`, shown where `\.fullScreenAvailable` is set; `watch-fullscreen`) calls
`Watcher.setFullScreen(true)`: `MainView.poseBody` draws `DuoFullScreen` instead of the pose's
layout — `WatchWindow(fill: true)` edge to edge, no bar, no status bar, no home indicator — and
one exit button in the top-left corner that fades after 3.5 s and comes back on a touch
(`watch-fullscreen-exit`). Entering or leaving re-arms auto-fit (`poseSettled`), so a window takes
the screen's shape (`WATCH SHAPE 1.42` on the sim) and goes back to the page's after; the whole
screen fills rather than showing whole. The pages go to the mic (no pointer without the deck).
Ends on Done / the glance / close, and on a pose that doesn't allow it. **The mic floats** (`FloatingMic`, Sameer: "make it small and give me a little lip on it so I could drag and move anywhere"): the same `MicButton` at 52 pt with a glass grab tab on its top edge — the disc keeps tap and hold, only the lip drags it; it stays where it's left (`duo.fullscreen.mic.x/y`, fractions, bottom-right first), clamped clear of the rounded corners; never fades. **In full screen a dictation goes to Where I'm typing** (Sameer: "it should default to pasting wherever the cursor is"): `AppModel.startRecording` gives it a `.frontApp` override unless something else asked for a place (a Shortcut); the Send to pick is untouched, and Show the app after sending stays put. It pastes, never sends. **And Where I'm typing never refuses** (Mac 1.1.3, `Paster`'s `.front`): a focused element that doesn't read as a text field still gets ⌘V — Claude's search names the highlighted row of its list as focused while the caret is in the box; `Paster.nearestInput(around:)` finds that box (up to its dialog) only to read the words back. Password fields are still refused. **A hold brings a trackpad** (Sameer: "press and hold … a see through track pad should appear there quickly … dissolve away after like 5 sec of no interaction"): in full screen a hold on the picture (`WatchWindow(onHold:)` → `ViewerScrollView.onHold`, ahead of the right-click — two fingers still right-click) puts a 340 × 220 frosted `TrackpadSurface` centred under the finger (kept on screen) and the trackpad page up (the pointer shows); the finger that held drives the pointer at once, no lift (`onHoldMoved` / `onHoldEnded`, the hold's own moves in the window's space); any use of it (`TrackpadSurface(onUse:)`) or a finger still down keeps it, 3 s with none dissolves it and the pointer goes (`DuoFullScreen.summonPad` / `dismissPad`; `MACROPHONE_FULLSCREEN_PAD=x,y` for a shot; `FullScreenUITests` — a Duo sim opened flat, paired with `mpctl serve`). Hook:
`MACROPHONE_WATCH_ACTIONS=…,fullscreen,windowed,record,stoprecord` (with `MACROPHONE_SIM_RECORD=<words>`; `mpctl serve` prints `RECEIVED → Where I'm typing`).

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
  for a paste that wasn't sent, from a Mac that names it, the pill carries Undo for 5 s →
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
  its place, faded, and takes no tap or swipe (`InputCarousel(rowDimmed:)`).
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
  clock, Whole Screen · Mac Controls · ⋯ at the foot; Done and the window's clusters in hand), as
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
  (3.5 s; always for VoiceOver), hidden while the mic is dragged. In the top-left corner it covered
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
  .awaySetup`, `away-setup`): five numbered steps, then Without Tailscale.
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
  "⌘K"; never logged) · **Mac Keys** (`keyboard-mac-keys`) · hide (`keyboard-hide`). Mac Keys swaps
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
  whole while the keyboard is up (`micSlot(visible:)`). Hook `MACROPHONE_MAC_KEYS=1|0` (DEBUG, not
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
  shows:* Done · Keyboard (one toggle, `bar-keyboard` / `bar-keyboard-hide`) · Sound · Mac Controls ·
  bell · Pan|Scroll (there from the first moment, dimmed until live) · zoom out · Window; items only
  dim or change symbol, never come or go (each change re-vends the bar), and with the mic open the
  set stays, dimmed. The inner bar swaps in the layout's own transaction (`innerBarWindow` /
  `barFollows` removed). *Pages change in place:* a tap fades the old page out and the new one in
  with a 0.96 settle (Reduce Motion: fade); only a finger on the Thread slides them; pages sit on
  the room's foot; the keyboard page keeps the last page's room (`restBand`) until the keys rise.
  The keyboard page itself is never faded or scaled (an effect's new container made UIKit hand the
  keyboard back after it let go). `phoneBody` animates on `input.page` on every phone; the regular
  iPhone's page row folds away while `keysUp`. The trackpad's hint is one line ("Trackpad · Two
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

## Typing on the inner screen never moves the Mac's screen (Nov 7 2026, round 3)

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
Every one is `EmptyState` (`UI/EmptyState.swift`, a `ContentUnavailableView`): a symbol, a sentence-case title with no full stop, one sentence, at most one button that fixes it (`emptyStateButton()`; Wake Your Mac is `WakeMacAction`, the menu bar's rule). The phone's desktop and the Duo's cover say what stands between the mic and the Mac in the desktop's empty room (`DesktopTrouble`, `DesktopEmptyState`, an overlay under the menu bar that never moves the mic), in order: the mic or speech recognition off (Open Settings, also found at launch by `Recorder.permissionOff`), unpaired (Pair a Mac), Local Network off (Open Settings), not found (Wake Your Mac; never while `settling` or `reconnecting`). On the regular iPhone the status line says nothing about it meanwhile (`StatusLine(desktopSays:)`) and the menu bar's Wake steps aside; on the cover the line keeps its words and drops its "Open Settings" link (`desktopFixes`). In a short room the state sheds its sentence, then its symbol. The Duo glance: Pair your Mac · Can't find ‹Mac› (Wake) · Local Network · ‹App› isn't open (Open ‹App›, `openOnMac`); still looking is "Connecting to ‹Mac›". History off has Turn On History; Open an App offline has Wake, no apps has Try Again; Your Macs, Dictionary and Language have their own. The Dock has no divider with no open apps. Hooks: `MACROPHONE_FAKE_PAIRED=none | <name>@offline`. Frames: `docs/screens/empty-states-nov5/`.

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
- **The page row is above the Thread** ("the switcher should be above the wave form"): `InputCarousel`
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
