# Macrophone for Mac — automations

Since Oct 13 2026 apps need no setup: every app open on the Mac with somewhere to type is listed
under **Send to** on the iPhone and the Mac (docs/TARGETS.md). **Automations** are the deeper
features — named things the iPhone lists under **Send to › Automations**: save to Obsidian, Apple
Notes or Reminders, type into a tmux pane, ask Claude, run a script, post to a webhook — each with
its own template, output format and voice prefixes. This is the source for the website's
automation docs: UI names are exact (in **bold**), defaults are what ships. The pure rules live in
`Packages/MacrophoneKit/Sources/MacrophoneKit/Core/Automation.swift`; the Mac side is
`Mac/App/Delivery/` and `Mac/App/Core/AutomationStore.swift` (stored as the shared `Profile` shape
in `automations.json`). Screens: `Mac/docs/screens/targets/`.

## How a dictation picks an automation

The iPhone sends it as the dictation's target (`TargetRef.automation`) — picked under Send to, or
by a voice prefix ("note, …"). An older iPhone sends the automation as its profile. Then:

1. **Snippets** expand inside the text (snippets are global — they apply to every dictation).
2. The automation's **Format** shapes it.
3. Its **Template** wraps it, with context variables filled in.
4. It goes where the automation says (**Where it goes**: copy it, paste it where I'm typing, type
   it into a tmux pane, or nowhere), and everything under **Also** runs (save to Obsidian / Apple
   Notes / Reminders, Ask Claude), plus the script and webhook.

Safety rules that always hold: a **2.5-second countdown** with **Cancel** before anything is
pasted or typed (hovering the popup pauses it; **Send Now** / **Paste Now** skips it); never into a
password field or while Secure Keyboard Entry is on; dictations the iPhone queued while the Mac
was away (**delayed**) are only copied — never pasted, typed or sent on their own (the actions
still run). After a paste, the clipboard is put back.

## The Automations pane

**New Automation** offers starting points: **Save to Obsidian**, **Save to Apple Notes**, **Add to
Reminders**, **Type into a tmux pane**, **Ask Claude**, **Run a script**, **Send to a webhook**,
**Copy with a template**. Each opens the editor: **Name**, **Voice prefix**, **Cleanup** (overrides
the iPhone's setting), **Where it goes**, **Then** (press Return / the send key after pasting or
typing), **Shape the text** (Format, Template), **Also** (actions), **Script and webhook**. Rows
show the voice prefixes, "Send to" when it's the current choice, and **Sends text off this Mac**
when it does.

## What changed on Oct 13 2026 (live targets)

Gone: the target catalog and **Add a Target…** gallery, ready-made app profiles, **Send to an
app** / window and tab matching, the per-app send key and "go back to where I was", **When an app
is in front** rules and the iPhone's **Automatic**, the default profile, the **Delivery** mode
setting and the **Return list**. The phone's **Paste & send** is the consent to send.

Migration (once, from `profiles.json`, which is left in place): a profile that only sent text to
an app, the clipboard or the app in front becomes nothing — that app shows up live. One that did
more — a tmux pane, nowhere-plus-actions, a template or output format, notes, reminders, Ask Claude,
a script or a webhook — becomes an automation; an app profile with extra actions keeps them, with
the text copied. The old delivery mode becomes the first Send to choice (Auto-paste → **Where I'm
typing**, else **Clipboard**) until a phone sends its own, and **Show a notification** (Clipboard +
notification → on, Clipboard only → off).

## Voice prefixes (editor › **Voice prefix**)

Editable chips ("Type a word, press Return"). Start a dictation with one of them and a pause —
"note, call the dentist tomorrow" — and that automation is used for that one dictation; the iPhone
takes the words off before sending. (An open app's own name works the same way — "Messages, I'm
running late" — `SpokenTarget`.) A prefix must be followed by the recognizer's pause punctuation
(`,` `:` `.` `;` `!` `—`) or the spoken words "colon"/"comma", so "note that the API…" never
matches "note". Longest prefix wins ("ask Claude" over "ask"). The Mac sends every automation's
prefixes to the phone (`ProfileSummary.voicePrefixes`) whenever automations change or a phone
connects. Automation rows show them as chips.

## Output formats (editor › Shape the text › **Format**)

With a live preview. Default **Plain text**.

| Format | What it does |
| --- | --- |
| Plain text | The text as cleaned up |
| Single line | Line breaks become spaces — good for terminals and chat inputs that send on Return |
| Code block | Wrapped in a ``` fenced block (```` if the text has ``` in it) |
| Markdown quote | Each line starts with "> " |
| Shell-quoted | One safely single-quoted argument |
| JSON string | A JSON string literal, quotes and escapes included |

## Templates and context variables (editor › Shape the text › **Template**)

`{{text}}` is the dictation (after snippets and the format). A template without `{{text}}` gets
the text appended after a blank line. The editor has variable chips (click to insert, hover for
what each is), a **Preview · sample values** box, a warning for anything that isn't a known
variable ("It'll be left as typed") or malformed braces, and a note for variables that need a
permission. Only the variables an automation's template (or a matching snippet) uses are gathered.

| Variable | Value |
| --- | --- |
| `{{text}}` | What you dictated, after snippets and the format |
| `{{raw}}` | The raw transcript, before cleanup |
| `{{clipboard}}` | What was on the Mac clipboard just before this dictation |
| `{{selection}}` | The text selected in the app in front (Accessibility) |
| `{{app}}` | The name of the app in front |
| `{{window}}` | The title of the front window (Accessibility) |
| `{{url}}` | The front tab's URL in Safari, Chrome, Arc, Brave or Edge — the browser in front, else the browser with the front-most window. Asks for Automation once per browser |
| `{{tmux_cwd}}` | The working directory of the automation's tmux pane |
| `{{date}}` | `2026-10-12` |
| `{{time}}` | `14:05` |
| `{{datetime}}` | ISO 8601, e.g. `2026-10-12T14:05:00-07:00` |
| `{{profile}}` | The automation's name (or where it went: "Claude", "Clipboard") |
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
every dictation — wherever it goes — before an automation's format and template.

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
Anthropic** (the automation's row shows **Sends text off this Mac**). **Model**: Claude Sonnet 5.5
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

- Automations arrive as `ProfileSummary`s (`broadcastProfiles`, and in `welcome`) — list them under
  **Send to › Automations**; picking one sends `.selection(SendSelection(target: .automation(id:name:)))`
  and each dictation carries `target: .automation(...)`. `isDefault` is always false now.
- Voice prefixes arrive in `ProfileSummary.voicePrefixes`; match with `VoicePrefix.match`, strip
  them, and send that dictation with the automation as its target.
- Apps come from `.targets([LiveTarget])` (docs/TARGETS.md), not from profiles.
