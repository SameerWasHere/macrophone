# Macrophone for Mac — automations

Everything a profile can do on the Mac beyond "copy it". This is the source for the website's
automation docs: UI names are exact (in **bold**), defaults are what ships. The pure rules live in
`Packages/MacrophoneKit/Sources/MacrophoneKit/Core/Automation.swift`; the Mac side is
`Mac/App/Delivery/`. Screens: `Mac/docs/screens/`.

## How one dictation is handled

1. **Pick the profile.** A voice prefix ("Claude, …") wins, then the profile picked on the iPhone
   (or by a Shortcut / Action Button), then — only when the iPhone sent it on **Automatic** — the
   rule for the app in front when it arrived, then the default profile.
2. **Snippets** expand inside the text.
3. The profile's **Format** shapes it.
4. The profile's **Template** wraps it, with context variables filled in.
5. It goes where the profile says (**Where it goes**), and everything under **Also** runs (save to
   Obsidian / Apple Notes / Reminders, Ask Claude), plus the script and webhook.

Safety rules that always hold: a **2.5-second countdown** with **Cancel** before anything is pasted
or sent (hovering the popup pauses it; **Send Now** / **Paste Now** skips it); the send key only in
apps on the **Return list**; never into a password field or while Secure Keyboard Entry is on;
dictations the iPhone queued while the Mac was away (**delayed**) are only copied — never pasted,
typed or sent on their own. After a paste, the clipboard is put back.

---

## App targeting (Profiles › Where it goes › **Send to an app**)

Dictate straight into an app and have it sent — a Claude chat, the Terminal tab running Claude
Code, ChatGPT, Cursor's agent. Macrophone:

1. brings the app forward (launching it if needed) — and, when the profile names a window or tab,
   that window or tab first;
2. puts the cursor in the message box (chat apps), even if you'd clicked somewhere else;
3. pastes, then checks the words actually showed up in the box;
4. presses the send key (if the profile sends and the app is on the Return list), then checks the
   box emptied;
5. puts your clipboard back and, if you asked, brings back the app you were using.

### The target catalog

Tuned behaviour for these apps (any other app works too — "**Any app…**" — it pastes where the
cursor is):

| Target | Bundle id | Sends by default | Send key | What "tuned" means |
| --- | --- | --- | --- | --- |
| Claude | `com.anthropic.claudefordesktop` | Yes | Return | Finds the message box ("Write your prompt to Claude" / "Ask Claude anything"), focuses it, verifies paste and send |
| ChatGPT | `com.openai.chat` | Yes | Return | Same, for ChatGPT's message box |
| Codex | `com.openai.codex` | Yes | Return | Same, for the task box |
| Cursor | `com.todesktop.230313mzl4w4u92` | Yes | Return | Same, for the Agent box ("Plan, Build…") |
| VS Code | `com.microsoft.VSCode` | No | Return | Pastes where the cursor is (editor or chat box) |
| Terminal | `com.apple.Terminal` | Yes | Return | Picks the tab by title or by the program running in it |
| iTerm2 | `com.googlecode.iterm2` | Yes | Return | Picks the session by its name |
| Ghostty | `com.mitchellh.ghostty` | Yes | Return | Window titles |
| Warp | `dev.warp.Warp-Stable` | Yes | Return | Window titles |
| Slack | `com.tinyspeck.slackmacgap` | **No** — it reaches people | Return | Finds the message box; the editor warns if you turn sending on |

Apps that send by default are on the **Return list** out of the box (Delivery › Return list), so
they work without setup. An install from before the catalog gets them added once.

### Ready-made profiles

Added on first run (when the app is installed) and offered in **Add a Target…** (Profiles):

| Profile | Goes to | Sends | Voice prefix |
| --- | --- | --- | --- |
| **Claude** | Claude (desktop) | Yes | "Claude" |
| **Claude Code (Terminal)** | Terminal — the tab running `claude` | Yes | "Claude Code" |
| **ChatGPT** | ChatGPT | Yes | "ChatGPT" |
| **Cursor** | Cursor | Yes | "Cursor" |

An install from before this release: the untouched "Claude prompt" profile becomes **Claude**
(same id, so an iPhone that had it picked keeps it) and the others are added once if their apps are
installed.

### Profile settings for a target

- **Only the window with this in its title** (chat apps, editors) / **Only the tab or window with
  this in its title or running this program** (terminals). Empty = the front window. Matching is
  case-insensitive "contains".
  - **Terminal:** with Automation permission for Terminal, every tab is checked — its custom title,
    the window name, and the programs running in it — so `claude` finds the tab running Claude
    Code even when another tab is selected. Without the permission, window and tab titles are
    matched through Accessibility (Claude Code puts "Claude" in its title, so it usually still works).
  - **iTerm2:** session names, with Automation permission; titles otherwise.
  - Others: window titles and native tab titles.
  - Windows on another desktop (Space) can't be seen. **If nothing matches, nothing is pasted** —
    the popup says "No Terminal tab matching “claude”", the text is on the clipboard, **Try Again**.
- **Send it — press the send key after pasting** — default from the catalog.
- **Send key** — **Return** or **⌘ Return**. Default from the catalog (Return for every target
  today); change it for apps set to send with ⌘ Return.
- **Go back to where I was after sending** — off by default.
- If the target isn't on the Return list, the editor says so with an **Add <app>** button.

### Automation permission

Asked only when a profile needs it, from the editor's **Allow…** button (never by surprise):
"Lets Macrophone pick the Terminal tab by the program running in it, not just its title. Without
it, only titles are matched." Denied → the row says how to turn it on in System Settings ›
Privacy & Security › Automation, and titles still work.

### What the popup says

| Result | Popup |
| --- | --- |
| Pasted, sent, box emptied | **Sent to Claude** |
| Terminal / tmux (can't read back) | **Sent to Terminal** |
| Pasted, not set to send | **Pasted into Claude** |
| Pasted, app not on the Return list | **Pasted into Notes** · "Return skipped — Notes isn't on your Return list" |
| Pressed send, words still in the box | **Pasted into Claude** (ochre) · "Pressed Return, but it's still in the message box — Claude may still be answering. Press Return when it's ready." |
| The words never reached the message box | **Not sent** · "Didn't send — Claude's message box wasn't focused" · on the clipboard · **Try Again** |
| No matching window/tab | **Not pasted** · "No Terminal tab matching “claude”" · **Try Again** |
| Password field | **Not pasted** · "Not pasted — a password field is active" |
| Accessibility off | **Copied, not pasted** · **Open System Settings** |

While counting down the kicker reads "Sending to Claude" (or "Pasting into…"), plus the window
match ("· “claude”"). A dictation picked by voice prefix shows the profile first: "Claude Code ·
Sending to Terminal · “claude”".

---

## Per-app rules (Profiles › **When an app is in front**)

"**When <app> is in front, use <profile>**". **Add Rule…** picks the app; a menu picks the profile;
the minus removes it. "Otherwise: <default profile>".

Applies **only** to dictations the iPhone sends on **Automatic** (`profileSource: "automatic"`). A
voice prefix or a profile picked on the iPhone always wins. The app in front is the one in front
**when the dictation arrives**. A rule whose profile was deleted falls back to the default.

## Voice prefixes (profile editor › **Voice prefix**)

Editable chips ("Type a word, press Return"). Start a dictation with one of them and a pause —
"Claude, fix the failing test" — and that profile is used for that one dictation; the iPhone takes
the words off before sending. A prefix must be followed by the recognizer's pause punctuation
(`,` `:` `.` `;` `!` `—`) or the spoken words "colon"/"comma", so "note that the API…" never
matches "note". Longest prefix wins ("Claude Code" over "Claude"). The Mac sends every profile's
prefixes to the phone (`ProfileSummary.voicePrefixes`) whenever profiles change or a phone
connects. Profile rows show them as chips.

## Output formats (profile editor › Shape the text › **Format**)

With a live preview. Default **Plain text**.

| Format | What it does |
| --- | --- |
| Plain text | The text as cleaned up |
| Single line | Line breaks become spaces — good for terminals and chat inputs that send on Return |
| Code block | Wrapped in a ``` fenced block (```` if the text has ``` in it) |
| Markdown quote | Each line starts with "> " |
| Shell-quoted | One safely single-quoted argument |
| JSON string | A JSON string literal, quotes and escapes included |

## Templates and context variables (profile editor › Shape the text › **Template**)

`{{text}}` is the dictation (after snippets and the format). A template without `{{text}}` gets
the text appended after a blank line. The editor has variable chips (click to insert, hover for
what each is), a **Preview · sample values** box, a warning for anything that isn't a known
variable ("It'll be left as typed") or malformed braces, and a note for variables that need a
permission. Only the variables a profile's template (or a matching snippet) uses are gathered.

| Variable | Value |
| --- | --- |
| `{{text}}` | What you dictated, after snippets and the format |
| `{{raw}}` | The raw transcript, before cleanup |
| `{{clipboard}}` | What was on the Mac clipboard just before this dictation |
| `{{selection}}` | The text selected in the app in front (Accessibility) |
| `{{app}}` | The name of the app in front |
| `{{window}}` | The title of the front window (Accessibility) |
| `{{url}}` | The front tab's URL in Safari, Chrome, Arc, Brave or Edge — the browser in front, else the browser with the front-most window. Asks for Automation once per browser |
| `{{tmux_cwd}}` | The working directory of the profile's tmux pane |
| `{{date}}` | `2026-10-12` |
| `{{time}}` | `14:05` |
| `{{datetime}}` | ISO 8601, e.g. `2026-10-12T14:05:00-07:00` |
| `{{profile}}` | The profile's name |
| `{{device}}` | The iPhone it came from |

"In front" means when the dictation arrived, before anything was brought forward.

Example — a code-review prompt with context:
```
You are a careful code reviewer. I'm looking at {{window}} in {{app}}.
Selected:
{{selection}}

{{text}}
```

## Snippets (sidebar › **Snippets**)

"Say a short phrase, get something longer." **New Snippet** → **When you say** (the trigger) /
**Put this instead** (the expansion, which can use the variables above, with the same chips and
preview) / **Try it** (live). Triggers match whole words anywhere in the dictation, ignoring case
and the commas the recognizer adds; longer triggers win; duplicates are refused. Snippets apply to
every profile, before its format and template.

Example: `my email` → `sameer@example.com`; `sig` → `Thanks,\nSameer\n{{date}}`.

## tmux panes (Where it goes › **Type into a tmux pane**)

A pane picker lists every pane (`session:window.pane`, the program running, the folder) from
`tmux list-panes -a`, with **Refresh**; or type a target. tmux is found in `/opt/homebrew/bin`,
`/usr/local/bin`, then a login shell's PATH ("tmux isn't installed. Install it with Homebrew: brew
install tmux" otherwise).

Works whatever app is in front — even with the terminal hidden. One line goes in as literal keys
(`tmux send-keys -t <target> -l <text>`); several lines go in as one bracketed paste
(`load-buffer` + `paste-buffer -p`), so a line break never runs a half-typed command. **Press
Return after typing** sends `Enter`. Same countdown; delayed dictations are never typed. A pane
that's gone → "There's no tmux pane work:1.0 right now", on the clipboard, **Try Again**.

## Also: Save to Obsidian

**Vault** (Choose Vault… — the folder), **Note** (path inside the vault; empty = today's daily
note), **Daily folder** (empty = the folder in Obsidian's Daily notes settings, else the vault
root; the note name follows that plugin's date format, default `YYYY-MM-DD`), **Under heading**
(optional — appended at the end of that section; the heading is created at the end of the note if
it's missing). Each dictation adds `- 14:05 what you said` (extra lines indented under the bullet).
A plain file write — Obsidian doesn't need to be open. Paths can't escape the vault.

## Also: Save to Apple Notes

**Each dictation** — **Makes a new note** (in **Folder**, else Notes' default folder; a folder
that doesn't exist is created) or **Adds to one note** (**Note title**, created if there's none).
"Syncs through iCloud if you use iCloud Notes." Uses Automation for Notes, asked from the editor's
**Allow…** (or the first time it runs).

## Also: Add to Reminders

**List** (your default list, or one of yours — Macrophone asks for Reminders access with **Allow…**
to show them), **Dates** — **Turn “tomorrow at 5pm” into a due date** (on by default): "Call the
dentist tomorrow at 5pm" becomes "Call the dentist", due tomorrow at 5:00 PM, with an alert. The
popup says "In Reminders · due tomorrow at 5:00 PM".

## Also: Ask Claude

Sends the final text to Claude with **your own Anthropic API key** — labelled **Sends text to
Anthropic** (the profile row shows **Sends text off this Mac**). **Model**: Claude Sonnet 5.5
(`claude-sonnet-5-5`, default), Claude Opus 5.5 (`claude-opus-5-5`), Claude Haiku 5.5
(`claude-haiku-5-5`). **Instructions** (optional system prompt). **Reply** — **Copy Claude's reply
to the clipboard** (on by default).

The reply streams into the popup (it grows, with **Copy Reply** / **Dismiss**; it stays two minutes,
hover holds it) and is kept in History next to the dictation, and in the pull API as `reply`.
Sonnet 5.5 and Opus 5.5 requests opt into Anthropic's server-side fallback, so a classifier decline
is answered by the recommended fallback model.

The key: **Developer › Claude API key** — paste it (`sk-ant-…`), **Save**, **Test Key** (lists models;
costs nothing), **Remove…**. Kept in the login keychain, never in diagnostics. Errors are popup
states: no key ("Add your Anthropic API key to ask Claude"), bad key, rate-limited, Claude busy,
offline, declined — with **Ask Again** where it helps. The dictation itself is still delivered.

## Script and webhook

Unchanged (docs/API.md), except that they now get the final text (snippets, format and template
applied).

## A way in when the menu bar icon is hidden

**General › Open Macrophone from anywhere** — a global shortcut, default **⌃⌥⌘M**
(Control-Option-Command-M), that opens the main window. Click the shortcut to record a new one
(it needs ⌘ or ⌃ — Option alone types characters — and plain ⌘-letter shortcuts and the system's
own, like ⌥⌘M "Minimize All", are refused with a reason; Esc cancels, Delete removes it); the ⓧ
removes it; **Use ⌃⌥⌘M** puts the default back. If another app owns the shortcut, the row says
so. A saved ⌥⌘M from an earlier version (it collided with "Minimize All") moves to ⌃⌥⌘M once.
The menu's **Open Macrophone…** item shows the shortcut. Opening Macrophone from Spotlight or
Finder also opens the window.

When the menu bar has no room for the icon (a crowded bar, the notch) or it's turned off,
Macrophone notices (screen and window notifications — nothing polls) and says so once: the main
window opens with "Your menu bar is hiding Macrophone's icon" and how to reach the app (the
shortcut, Spotlight, Finder) until **Got It**; the first-run setup says the same on its last
step. Popups then appear at the top right of the screen in use.

## What the iPhone needs to know

- Send `profileSource` on every dictation: `"prefix"` when a voice prefix picked the profile (with
  that profile's `profileID`), `"chosen"` when the person or a Shortcut picked one, `"automatic"`
  when the phone is on Automatic (then the Mac's per-app rules decide; `profileID` may be nil).
- Voice prefixes arrive in `ProfileSummary.voicePrefixes`; match with `VoicePrefix.match` and strip
  them before cleanup/sending.
- Profiles named "Claude prompt" on older Macs are renamed "Claude" by the upgrade (same id).
