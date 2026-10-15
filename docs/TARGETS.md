# Macrophone — Send to: live targets

Sameer, Oct 13 2026: *"The Mac app should be aware of all the windows/applications open on the Mac
that have a text field in them, identify them and pass that to the iPhone. The iPhone user selects
which open app to paste into, with paste only or paste and auto-send."* and *"There should be a
one-to-one relationship between what's selected on the phone and on the Mac."*

So there is nothing to configure for apps. Open iMessage and it's on the phone's list; quit it and
it's gone. (Automations and snippets were removed on Oct 13 2026 — Sameer: "make the core
functionality the strong suit". Scripts and agents read dictations through docs/API.md.)

Code: `Mac/App/Targets/` (`TargetScanner`, `ComposerFinder`, `WindowServer`, `AppQuirks`),
`Mac/App/Delivery/Paster.swift` (delivery), `Mac/App/Delivery/DeliveryEngine.swift` (routing),
`Mac/App/Core/AppModel.swift` (the shared choice). The wire types are
`Packages/MacrophoneKit/Sources/MacrophoneKit/Core/Targets.swift`.

## The words (the same on the iPhone and the Mac)

**Send to** · **Clipboard** · **Where I'm typing** · the open apps · **Send after pasting** on or
off (the same words on the iPhone, in the Mac's menu bar and in its window).

## Discovery — "has somewhere to type"

A regular app (Dock app) is listed when one of its windows has a **composer**. Per window:

1. **Candidates** — every `AXTextArea`, `AXTextField`, `AXComboBox` in the window, found by a
   bounded depth-first walk (≤ 2,500 nodes, ≤ 150 ms per window). Subtrees that never hold a
   composer are skipped: menus, tables, outlines, lists, chat logs (`AXApplicationLog`), buttons,
   images, static text. **Web content** (`AXWebArea` — Electron apps, browsers, WebKit views) is
   never walked: the page's own search, `AXUIElementsForSearchPredicate` with
   `AXTextFieldSearchKey`, returns its text inputs in 0–5 ms (contenteditable composers like
   Claude's included).
2. **Rejected**: password fields (`AXSecureTextField`), search fields (role or subrole
   `AXSearchField`, or a description/placeholder/identifier saying search, find, filter, jump to,
   go to, quick open, command palette — unless it also says message/prompt/reply/ask…), address
   bars (address, URL, location), anything inside an `AXToolbar`, disabled or hidden inputs,
   inputs smaller than 40×10 pt or outside the window, native fields whose value can't be set
   (read-only), and — in a window with web content — the app's own native fields (a browser's
   address bar) unless they say they're for messages.
3. **Score** (highest wins): text area 3 · text field 1.5 · combo box 1; **+5** the input the person
   last typed in here (captured when they leave the app); **+3** it says it's for messages
   ("message", "prompt", "reply", "ask", "write", "chat", "compose", "comment", "send", "type
   here", "describe"…); **+1.5** it has focus now; **+0–2** lower in the window (chat apps keep the
   composer at the bottom); **+0–1.5** wider.
4. **Counts as a composer** (lists the app): a multi-line text area, a hinted input, the remembered
   input, or a single-line field at least 35% of the window wide in its lower 40%. A lone
   single-line field near the top (a name, a form) doesn't. An input taller than 45% of the window
   is a **document** (TextEdit, Notes): it counts, but Return there makes a new line, so "sent"
   isn't checked by the box emptying.

**Terminals** (Terminal, iTerm2, Ghostty, Warp, Alacritty, kitty, WezTerm, Hyper, Rio, Wave):
every standard window is the input. **Never listed**: Macrophone itself, Finder, System
Settings, Dock, Control Center, Activity Monitor, App Store, Maps, Photos, Preview, QuickTime,
Music, TV, Podcasts, Calculator, FaceTime, Weather, Passwords, Keychain Access (nothing to dictate
into, or only a search box — the heuristic drops most of these anyway; the list saves the walk).

**Windows.** Only standard, un-minimized windows. An app with **one** composer window is one entry
(`LiveTarget`, no `windowKey`); with **several**, each window is its own entry ("Terminal — claude
~/app"), keyed by its window-server id (`CGWindowID`, via `_AXUIElementGetWindow`), which is stable
for the window's life. Titles are cleaned: leading status glyphs that terminals and agents spin
("✳ Claude Code") and Terminal's "— 80×24" suffix are dropped; duplicates get " (2)".

**Other desktops (Spaces).** Accessibility only sees the current desktop. The window server
(`CGWindowListCopyWindowInfo` + `CGSCopySpacesForWindows`) sees every desktop: a window seen before
stays listed while it still exists on some desktop; a window an app has ordered out (a closed
Messages window) is on none and drops off. A terminal never seen yet but with a window on another
desktop is listed at app level.

**Order.** Most recently used first (NSWorkspace activations); until the person switches apps,
the window stacking order.

**Icons.** The app icon as a 128 px PNG, made once per bundle id. (The menu bar's Send to sets
16 pt icons on its items; on the macOS build this was tested on, AppKit draws no images in any
menu, so they don't show there — the main window's picker shows them.)

### Cost

- Nothing runs unless someone could look at the list: **a phone is connected, a Macrophone window
  is open, or its menu is open**. Otherwise no observers exist and no walk happens.
- While on, it is event-driven: NSWorkspace launch / quit / activate / deactivate / hide / unhide /
  desktop change, and per-app `AXObserver`s for window created, focused window changed,
  minimized / restored, and per-window destroyed / title changed. Events are coalesced per app
  (0.35–0.4 s; a title change 1.5 s) and each rescans only that app, on a utility queue. Every
  Accessibility request has a 0.4 s timeout (process-wide).
- Electron apps and Chromium browsers build their accessibility tree only when asked
  (`AXManualAccessibility`); Macrophone asks once per process and looks again 1.2 s later. (That
  keeps accessibility on in those apps for their lifetime — Chromium's cost, accepted for the
  feature.)
- The list goes to phones only when it changes: apps appearing or going after 0.25 s; a new order
  or a retitled window at most every 5 s.
- Measured on the dev Mac (Debug build, nine apps running): full scan 22–45 ms warm (418 ms the
  very first time, icons included); idle CPU **0.10%** with no phone and **0.13%** with a phone
  connected (30 s samples).

## Delivery

From `Dictation.target` + `Dictation.send` (each dictation carries them, so a sync race can't
misroute one). An **older phone** sends no target: it goes to this Mac's own Send to choice. An
older phone that still picks an automation gets it copied, and the popup says automations are
gone.

The text is delivered exactly as the phone sent it (its cleanup level applied there). A
**delayed** dictation (from the phone's offline queue) is only **copied** — never pasted or sent,
whatever the target.

| Send to | What happens |
| --- | --- |
| **Clipboard** | Copied. With **Show a notification when copying** (General, on by default) the popup shows it, and Notification Center keeps it if you're away; off, the menu bar icon ticks. |
| **Where I'm typing** | The app in front: its focused element must be a text input (else "Nowhere to type in Finder — copied instead"). An app that won't say what has focus is pasted into where the cursor is. |
| **An app / a window** | Brought to the front (its window raised first; on another desktop, macOS switches there), the composer found (above) and focused, pasted, checked. |

The paste: a **2.5-second countdown** with **Cancel** (hovering pauses; **Paste Now**/**Send Now**
skips) → secure-input check (a password field or Secure Keyboard Entry: copied instead) → the
text on the clipboard as a transient, concealed item → ⌘V → **read back**: the composer's value
must now contain the words (else "Didn't send — it didn't land in X's message box", copied, nothing
sent) → with **Send after pasting** on, the send key → for a message box, **check it emptied** (else ochre
"Pressed Return, but it's still in the message box") → the clipboard put back exactly (unless
something else changed it meanwhile).

**The phone's choice is the consent to send.** There is no Return allowlist any more.

**Gone**: an app that isn't running → "Claude isn't open — copied instead" (said at once, no
countdown; **Try Again** works once it's open). A window that closed → "That Terminal window
(“claude ~/app”) is closed — copied instead". An app running with no window (Messages after ⌘W)
is asked to reopen one, like a Dock click.

### Send keys (internal table, `AppQuirks.sendKeys`)

Return everywhere, except: Mail ⌘⇧D · Outlook, Spark, Superhuman, Linear, GitHub Desktop ⌘Return.

### Popup words

| Result | Kicker / headline |
| --- | --- |
| Counting down | "Sending to Claude" / "Pasting into Terminal — claude" / "Pasting where you're typing" |
| Sent, box emptied (or a terminal) | **Sent to Claude** |
| Sent into a document | **Pasted into TextEdit · pressed Return** |
| Pressed send, words still there | **Pasted into Claude** (ochre) + what to do |
| Pasted only | **Pasted into Messages** |
| App not open / window closed / nowhere to type | **Copied instead** · "Claude isn't open — copied instead" |
| Words didn't land | **Not sent** · "Didn't send — it didn't land in Claude's message box" |

## The shared choice (`SendSelection`)

One choice, the same on every paired phone and this Mac.

- **Phone → Mac**: the server calls `linkServer(_:selectionChanged:from:)`; the Mac stores it
  (UserDefaults `sendSelection`) and the server has already relayed it to the other phones.
- **On connect the phone wins**: the phone sends its choice right after welcome.
- **Mac → phones**: changing it in the menu bar (**Send to ▸**, **Send after pasting**), the main
  window (the **Send to** card above every pane) or the first-run setup calls `AppModel.choose`,
  which stores it and `broadcastSelection`s it.
- **Kept pointing at the list**: an app that went from one window to several is re-pointed at its
  most recent window; a picked window whose app now has only it becomes the app; a renamed window
  keeps its new name. Each of these is broadcast. An automation (from an older phone, or saved
  before they were removed) becomes Clipboard, broadcast too. A bare bundle id from a phone ("com.apple.MobileSMS") is shown by the app's name.
- An app that isn't open stays selected ("Claude (not open)"); dictations are copied until it is.
- First launch after the upgrade: the old delivery mode becomes the first choice (Auto-paste →
  Where I'm typing, else Clipboard) until a phone sends its own; Clipboard + notification / only
  becomes **Show a notification when copying** on / off.

## Known app quirks (looked at on the dev Mac, Oct 13 2026)

| App | What its tree looks like | Result |
| --- | --- | --- |
| Claude (Electron) | Two web areas (the shell, and claude.ai); composer `AXTextArea` "Write your prompt to Claude" / "Prompt" (contenteditable), found by the page search | Listed; paste + send verified, box-emptied check works |
| Muse (`com.meta.endo`, WKWebView) | The chat is exposed, but the composer is **not in the tree** (empty groups where it sits); no focused element reported | `AppQuirks.hiddenComposer`: listed while it has a window; pasted where Muse keeps its cursor (its composer) — not readable back |
| Messages | Native `AXTextField` "Message" (placeholder "Text Message • SMS"), plus a search field | Listed; paste verified by value |
| Terminal | `AXTextArea` "shell" (read-only value) | Terminal rule; paste + Return verified |
| TextEdit | One big `AXTextArea` | Listed as a document; paste + Return (a new line) |
| Dia / Chrome (Gmail) | Address bar is a native text area in the window chrome; Gmail's only input is "Search mail" | Not listed until a compose box is open |
| Finder, Maps | Search field only | Never listed |

Rules learned on the way: a child list can contain things that aren't AX elements (Muse) — every
list is type-checked before use; WebKit's hit-testing doesn't descend into a WKWebView;
Chromium's tree appears only after `AXManualAccessibility`.

## Debug hooks (Mac DEBUG builds)

`MACROPHONE_TARGETS_DEBUG=1` prints each scan (timing, what was found per window).
`MACROPHONE_INSTANCE=<name>` runs an isolated copy (own settings, folder, keychain items, identity,
"(name)" in its Bonjour name, never writes `api.json`). `MACROPHONE_PAIR_HEADLESS=1` +
`MACROPHONE_PAIR_URL_FILE` pair `mpctl` without a window. Distributed notifications:
`com.sameer.macrophone.debug.dictate` (JSON `{"text", "target"?: "clipboard|front|<bundle id>",
"window"?, "send"?, "delayed"?, "level"?}`), `com.sameer.macrophone.debug.choose` (JSON `{"target", "window"?,
"send"?}` — changes Send to on the Mac, as the menu does), `com.sameer.macrophone.debug.openMenu`.

Test recipe: `mpctl pair <url>` → `mpctl targets` → `mpctl select <bundleID|clipboard|front> [--send]`
→ `mpctl send "…"` (mpctl sends no target, so the Mac's choice — the one just set — is used).


## Watching (Oct 14 2026)

The phone can show the window of the place it sends to. Phone → Mac `watch(TargetRef?)` (nil
stops) `watchAction(WatchAction)`, `watchClick(x:y:)` and `watchScroll(x:y:dx:dy:)` (fractions of the window; a one-finger swipe on the phone scrolls the Mac window where the finger is, about 30 times a second, with a short carry-on for a flick — two fingers move the picture); Mac → phone `watchState(WatchState)` and `watchFrame(WatchFrame)`
(a JPEG ≤ ~1500 px wide, sent only when it changed, about two a second, each send awaited so a slow
link gets fewer pictures instead of a backlog). The Mac (`Mac/App/Watch/WatchService.swift`) finds
the window the way delivery does (the picked window, else the one last typed in, else the app's
front-most), captures only that window with ScreenCaptureKit (Screen Recording permission), and
re-reads the composer's frame every 5 s for the phone's starting view. Actions bring the window
forward first when it isn't already the front window (Accessibility), then press Return / Esc,
scroll a page over the window's middle, or click at the point (the pointer is moved there for it
and put back). It stops when the phone sends nil, disconnects, or the
person chooses Stop in the menu ("Your iPhone is watching Claude — Stop"). The phone pauses after
two idle minutes and when it leaves the screen. `mpctl watch` is a stand-in phone; `mpctl serve`
answers with a drawn demo window (`--watch-state permission|unavailable` for those states).


## Open an app (Oct 14 2026)

Sameer: "what if Claude is closed and I want to open it?" The phone's ⋯ beside Send to (and
"More apps" at the end of the row) opens a searchable list of every app installed on the Mac
(`listApps` → `apps([MacApp])`: name, bundle id, a 64 px icon, whether it's running; menu bar
agents, background-only apps and Macrophone itself are left out — `Mac/App/Targets/AppCatalog.swift`).
Tapping one sends `openApp(bundleID:)`: the Mac launches it (or brings it forward, asking for a
window), answers `appOpened(ok, detail)`, rescans, and the phone has already made it the Send-to
choice. For 20 s the phone shows it as "Opening…" (not "Not open") while its window appears.
`mpctl apps` / `mpctl open <bundleID>` drive it from the command line.
