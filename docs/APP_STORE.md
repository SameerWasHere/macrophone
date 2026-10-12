# Macrophone — App Store listing (iPhone, 1.0)

Everything App Store Connect asks for, ready to paste. Character limits were counted
(`python3 -c 'print(len("…"))'`). The Mac app is not on the App Store: it's a signed,
notarized download from sameer.us/macrophone/download.

**Before submitting:** replace the `id0000000000` placeholder on the website once the app
record exists (search the sameer-gpt repo for `TODO: app id`), confirm `macrophone@sameer.us`
receives mail, and decide on the name (see `NAME_CHECK.md`).

---

## Name, subtitle, promotional text

| Field | Text | Length / limit |
| --- | --- | --- |
| Name | Macrophone | 10 / 30 |
| Subtitle | Speak on iPhone, send on Mac | 28 / 30 |
| Promotional text | Speak on your iPhone and your words go straight into the AI chat, terminal or app on your Mac, and send. Or just onto the clipboard. On-device, free, no account. | 161 / 170 |

Promotional text can change without a new build; use it for launches ("Now with …"). The subtitle and
promotional text name no third-party app on purpose (see "Third-party names" below); the
description does, as compatibility statements.

## Description

(≤4,000 characters; this is about 3,530.)

```
Say it on your iPhone, and it goes straight into the app on your Mac and sends. Macrophone turns your iPhone into a wireless microphone for your Mac: tap the mic, talk, and your words land in an AI chat, the terminal tab running your coding agent, or your editor, with the send key pressed for you after a moment to cancel. Or just on the clipboard.

SAY WHERE IT GOES
• Start with a target's name and a pause ("Claude, fix the failing test") and that dictation goes there. Your iPhone takes the name off before sending.
• Or pick a target from Send To by the mic, or leave it on Automatic and let your Mac pick by the app you're using.
• Put a target on the Action Button, in Control Center, or ask Siri: "Dictate to Claude with Macrophone".

INTO THE APP, AND SENT
The free Mac app brings the app forward, finds the message box, pastes your words, checks they arrived and presses send. Ready-made targets for Claude, Claude Code in Terminal, ChatGPT and Cursor, with tuned support for Codex, VS Code, Terminal, iTerm2, Ghostty, Warp and Slack, and any other app. It can pick the Terminal tab by the program running in it, so your prompt reaches the right session.

Safe by design: a 2.5-second countdown with Cancel before anything is sent, the send key only in apps you approve, never into a password field, and dictations that waited while your Mac was asleep are only copied, never sent.

CLEANUP THAT EDITS, NEVER ANSWERS
On iPhones that support Apple Intelligence, Macrophone tidies what you said on the phone itself. Choose Off, Light, Medium or Heavy: from removing ums and repeats, to fixing false starts, to rewriting rambling speech into tidy text. Cleanup only edits your words; it never answers them, so a prompt arrives as a prompt. The raw transcript is always one tap away.

PRIVATE BY DESIGN
• Speech is transcribed on your iPhone. No audio is kept.
• The text goes straight to your Mac over your local network, encrypted with a key made when you pair. There's no server in between.
• No account, no ads, no analytics. Data Not Collected.
• Your words go where you send them. Anything on the Mac that sends text elsewhere, like a webhook, is labelled.

POWERFUL WHEN YOU WANT IT
• Templates with context: wrap your words with the selected text, the window title or the page you're reading.
• Snippets and formats: say "my email", get the address; send as one line, a code block or a quote.
• Type into a tmux pane, save to Obsidian, Apple Notes or Reminders, run scripts and webhooks.
• A local API, command-line tool and MCP server, so agents can read what you just said or wait for what you say next.
• Custom dictionary: up to 50 names, tools and acronyms, heard right and never "corrected" away.
• Offline queue: if your Mac is asleep, your iPhone holds the dictation and delivers it later.
• History of your last 50 dictations, raw and cleaned, kept only on your iPhone.

WORKS ON ITS OWN, TOO
Before you pair a Mac, every dictation is copied to your iPhone's clipboard.

REQUIREMENTS
iPhone with iOS 17 or later. Mac with macOS 14 or later, running the free Macrophone for Mac from sameer.us/macrophone. Cleanup needs an iPhone that supports Apple Intelligence, on iOS 26 or later. Dictate in many languages; cleanup in English.

Free. No in-app purchases, no subscription.

Claude and Claude Code are trademarks of Anthropic. ChatGPT and Codex are trademarks of OpenAI. Other app names belong to their owners and are used only to describe compatibility. Macrophone is not affiliated with or endorsed by them.
```

## Keywords

```
dictation,voice to text,prompt,AI,chat,agent,hands-free,terminal,transcribe,wireless mic,MCP,notes
```

98 / 100 characters. Words already in the name and subtitle (Macrophone, speak, iPhone,
send, Mac) are indexed anyway, so they're left out. "AI" and "chat" are separate so they also
match "AI chat" and "chat app". No competitor or third-party trademarks (no "Claude",
"ChatGPT", "Cursor", "Whisper") — guideline 2.3.7 forbids packing metadata with trademarked
terms or popular app names.

## Categories

- Primary: **Productivity**
- Secondary: **Developer Tools**

## Age rating questionnaire

Every content question (violence, sexual content, profanity, horror, drugs/alcohol/tobacco,
gambling, contests, medical/treatment information, mature themes): **None**.

| Question | Answer |
| --- | --- |
| Unrestricted web access | No |
| User-generated content shared with others | No |
| Messaging / chat between users | No |
| Advertising | No |
| Parental controls / age assurance | No (not needed) |
| Made for Kids | No |

Expected rating: **4+**.

## URLs

| Field | URL |
| --- | --- |
| Support URL | https://sameer.us/macrophone/support |
| Marketing URL | https://sameer.us/macrophone |
| Privacy Policy URL | https://sameer.us/macrophone/privacy |

## App Privacy ("nutrition label")

**Data Not Collected.** In App Store Connect › App Privacy, answer *"No, we do not collect
data from this app."*

Why that's accurate:

- Speech recognition is forced on-device (`requiresOnDeviceRecognition`); audio is never stored.
- Cleanup runs on Apple's on-device model (Foundation Models).
- Dictation text goes only to the user's own paired Mac over the local network, encrypted
  end to end with a key created at pairing. The developer never receives it.
- No analytics, crash reporting, advertising or third-party SDKs in the app.
- "Share Diagnostics" exports a text file the user sends themselves (Mail, AirDrop). It is
  optional, user-initiated, and contains no dictation text — Apple doesn't count data the user
  chooses to send you, case by case, as collection.
- Webhooks, scripts, Ask Claude (the user's own Anthropic API key) and the Notes / Reminders /
  Obsidian actions all run in the Mac app (not distributed through the App Store) and only send
  where the user points them. The iPhone app never contacts Anthropic, OpenAI or any other service.
- The iPhone caches the Mac's target names, cleanup levels and voice prefixes (a keychain item
  shared with its Controls extension) so the Send-to picker and controls work offline. That's
  on-device configuration, not collected data.

Keep this answer true: if analytics, crash reporting or any server is ever added to the iPhone
app, the label has to change in the same release.

## Export compliance

The app uses encryption only through Apple's operating system (CryptoKit: X25519 key
agreement, HMAC, ChaCha20-Poly1305 for the phone-to-Mac link; no custom or third-party
crypto). That is exempt from export documentation.

- `ITSAppUsesNonExemptEncryption` is already `NO` in `iOS/project.yml` / `Info.plist`, so App
  Store Connect won't ask on each build.
- If asked in App Store Connect: *"What type of encryption algorithms does your app
  implement?"* → **None of the algorithms mentioned above** (it only uses or accesses the
  encryption within Apple's operating system). No documentation to upload. French export
  declaration not required.

## App Review information

**Sign-in required:** No. There are no accounts.

**Contact:** Sameer Bhutani · macrophone@sameer.us (+ phone number in App Store Connect)

**Notes** (paste into "Notes"; ≤4,000 characters):

```
Macrophone is a dictation app: you speak into the iPhone, it transcribes on the device, and it sends the text to a companion app on the user's own Mac.

TESTING WITHOUT A MAC
The iPhone app works on its own. Before any Mac is paired, every dictation is copied to the iPhone's clipboard. To test:
1. Open Macrophone. The setup screens explain each permission; you can skip "Get the Mac app" and "Looking for your Mac".
2. Tap the large mic button, say a sentence, tap it again to stop.
3. The text appears under the button and is copied to the clipboard. Paste it in Notes to confirm. Raw / Cleaned toggles between the exact transcript and the cleaned-up version (cleanup is available on Apple Intelligence devices running iOS 26 or later; elsewhere the raw text is shown).

THE COMPANION MAC APP
"Macrophone for Mac" is a free menu bar app, distributed as a signed and notarized download from https://sameer.us/macrophone/download (it is not sold or required to be purchased anywhere; there is no paid tier). If you'd like to test the full path: install it on a Mac on the same Wi-Fi, open it, and scan the QR code it shows from the iPhone app. Dictations then appear on the Mac's clipboard.

PERMISSIONS AND WHY
- Microphone: to hear the user while they hold or tap the mic button. Audio is never stored.
- Speech Recognition: transcription, forced to run on the device (requiresOnDeviceRecognition). Audio is not sent to Apple or to us.
- Local Network: to find the user's Mac via Bonjour (_macrophone._tcp) and send it text directly. Nothing goes to the internet.
- Camera: only to scan the pairing QR code on the Mac, requested at that step. Pairing also works with a six-digit code instead.

OTHER NOTES
- No account, login, in-app purchase, ads or analytics. App Privacy: Data Not Collected.
- App Intents: "Start Dictation" opens the app already recording (iOS requires the app in the foreground to use the microphone); its "Send To" parameter picks one of the user's Mac targets or Automatic. "Dictate Text" returns the transcript to the user's own shortcut. A Control Center / Lock Screen / Action Button control ("Dictate to Mac", configurable per target, e.g. "Dictate to Claude") runs Start Dictation on iOS 18 and later.
- "Send to" targets (names like "Claude", "Claude Code (Terminal)", "ChatGPT", "Cursor") are labels for the user's own setups on their Mac, which pastes the text into those desktop apps on the user's behalf. Macrophone has no integration with, and sends nothing to, Anthropic, OpenAI or Cursor; it is not affiliated with them. Without a paired Mac, the Send-to list only shows Automatic.
- The app is iPhone only.
```

## Screenshots

Upload the **6.9"** set (1320 × 2868, iPhone 16/17 Pro Max) — App Store Connect scales it for
smaller iPhones — and the **6.5"** set (1284 × 2778) so older-device pages show the real layout.
Both sets ship: `iOS/docs/store-screenshots/6.9/` and `/6.5/`, the same six shots, real screens
captured with DEBUG hooks and framed by `iOS/scripts/render-store-shots.swift`.

Style: the app's own dark ink ground, a mono kicker and a two-line serif caption at the top,
the phone below with the Filament crossing the frame.

| # | File | Screen | Kicker | Caption (in the image) |
| --- | --- | --- | --- | --- |
| 1 | `01-recording.png` | Mid-dictation: live transcript starting “Claude, …”, the Filament alive, timer, **SAID · Claude** chip, “Listening — this one goes to Claude” | DICTATE | Speak into your iPhone. It lands on your Mac. |
| 2 | `02-delivered.png` | Delivered: mint line with ✓, Send to · Automatic, “Sent to Claude — you said “Claude, …””, last dictation card (→ CLAUDE, Cleaned / Raw, Copy, Resend) | VOICE TARGETS | Say where it goes. It goes straight there. |
| 3 | `03-send-to.png` | The Send To sheet: Automatic, then the Mac's targets (Clipboard, Claude, Claude Code (Terminal), ChatGPT, Cursor, Quick note) with their “Say …” hints | SEND TO | Pick where it goes. Or just say it. |
| 4 | `04-cleanup.png` | Settings: the cleanup slider (Off · Light · Medium · Heavy) with a HEARD / SENT · MEDIUM CLEANUP card | CLEANUP | Four levels of cleanup. It edits, never answers. |
| 5 | `05-history.png` | History: three items with Cleaned / Raw, target chips (Claude · you said “Claude, …”, Claude Code (Terminal), Automatic), Delivered, cleanup level | HISTORY | Raw and cleaned, kept on your iPhone. |
| 6 | `06-pairing.png` | Onboarding step 5: “Scan the code on your Mac.” with the QR viewfinder and “Use a code instead” | PRIVATE BY DESIGN | Pair once. No account, no cloud, no audio kept. |

**Before upload, change shot 2's caption** (see the recommendation below) to:
**“Say where it goes. It goes straight there.”** (kicker VOICE TARGETS unchanged). Everything
else, including the target names inside the app's UI, can stay.

App Preview video (optional, 15–30 s): the website's demo loop as a real recording — say
“Claude Code, …”, send, land in the Terminal tab and send.

## Third-party names (Claude, ChatGPT, Cursor) — guideline 2.3.7 / 5.2

**Recommendation:** keep third-party names out of the name, subtitle, keywords and promotional
text and out of screenshot *captions*; name them only in the description, as compatibility
statements with a non-affiliation line, and in the real app UI shown in screenshots. Concretely:
change shot 2's caption from “Say where it goes. It goes straight there.” to “Say where it
goes. It goes straight there.”; shots 1, 3 and 5 can keep “Claude”, “ChatGPT” and “Cursor”
inside the UI.

Why:

- **2.3.7** says not to “pack any of your metadata with trademarked terms, popular app names …
  just to game the system”, and that subtitles must not “reference other apps”. Keywords and
  subtitle are the fields it names; the description is where factual “works with” wording
  belongs. A June 2026 case shows how far it can reach: a fan app was rejected under
  4.1(a) for a third-party brand in its subtitle, keywords *and* a screenshot showing that brand's
  product, with App Review never naming the field.
  ([App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/),
  [Apple Developer Forums thread 829229](https://developer.apple.com/forums/thread/829229))
- **5.2.1** forbids using third-party trademarks without permission or “misleading … names, or
  metadata”, and reviewers have asked developers to prove they may use “ChatGPT” / “OpenAI”
  because users might think the app is OpenAI's. A caption that headlines “Claude” twice is the
  kind of prominent, brand-led use that invites that question; a factual “works with” line in the
  description is not. ([OpenAI community thread, May 2023](https://community.openai.com/t/about-use-the-terms-chatgpt-and-openai/211907))
- **2.3.3** wants screenshots to show “the app in use”. The target names in the UI are the user's
  own setups (the Mac makes them), so showing them is showing the app in use, not borrowing a brand.
- **The owners' own rules** point the same way: Anthropic's trademark guidelines bar any use that
  “implies Anthropic’s sponsorship or endorsement” and expect approval for brand use; OpenAI's
  brand page bars model names in app names. Neither covers plain compatibility wording, so keep it
  plain, never use their logos (the Mac app's target gallery shows app icons; don't put that screen
  in App Store screenshots or marketing), and carry the non-affiliation line.
  ([Anthropic trademark guidelines](https://www.anthropic.com/legal/trademark-guidelines),
  [OpenAI brand guidelines](https://openai.com/brand/))
- If App Review still objects, the fallback is cheap: swap the caption (already planned), and if
  asked, re-capture shots 1, 2 and 5 with a target named “AI chat” via `MACROPHONE_FAKE_PROFILES`.
  The App Review notes already explain the targets are user labels with no integration.

These are forum reports and published guidelines, not a ruling; Apple is inconsistent here, so
the conservative choice above costs little.

## What's New in This Version (1.0)

```
Macrophone is here. Speak into your iPhone and the text lands on your Mac: straight into an AI chat or your terminal and sent, after a moment to cancel, or on the clipboard. Say a target's name first, pick one by the mic, or let your Mac pick by the app you're using. Transcribed on your iPhone, cleaned up on-device, and never stored as audio. Dictate in many languages; cleanup in English.
```

## Store line on languages

Use exactly: **"Dictate in many languages; cleanup in English."** (in the description's
Requirements and in What's New). The UI and listing are English only in 1.0.
