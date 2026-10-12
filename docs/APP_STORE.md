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
| Subtitle | Speak on iPhone, paste on Mac | 29 / 30 |
| Promotional text | Turn your iPhone into a wireless microphone for your Mac. Speak, and clean text lands on your Mac's clipboard, in your app, or in an AI agent. Free, private, no account. | 169 / 170 |

Promotional text can change without a new build; use it for launches ("Now with …").

## Description

(≤4,000 characters; this is about 2,670.)

```
Macrophone turns your iPhone into a wireless microphone for your Mac. Tap the mic, say what you want to write, and the text lands on your Mac a moment later: on the clipboard, pasted into the app you're using, or handed to a script or an AI agent.

It's made for long prompts. Talk through the bug, the plan or the review, and it arrives in Claude, your terminal or your chat app, already cleaned up. It's just as good for long messages, email replies and first drafts.

HOW IT WORKS
• Install Macrophone on your iPhone and the free Mac app from sameer.us/macrophone.
• Pair once by scanning a QR code. No account, no IP addresses.
• Tap to start and stop, or hold to talk. That's it.

CLEANUP THAT EDITS, NEVER ANSWERS
On iPhones that support Apple Intelligence, Macrophone tidies what you said on the phone itself. Choose Off, Light, Medium or Heavy: from removing ums and repeats, to fixing false starts, to rewriting rambling speech into tidy text. Cleanup only edits your words; it never answers them. The raw transcript is always one tap away.

PRIVATE BY DESIGN
• Speech is transcribed on your iPhone. No audio is kept.
• The text goes straight to your Mac over your local network, encrypted with a key made when you pair. There's no server in between.
• No account, no ads, no analytics. Data Not Collected.
• Text only leaves your devices if you set up an automation that sends it somewhere, such as a webhook.

POWERFUL WHEN YOU WANT IT
• Custom dictionary: up to 50 names, tools and acronyms, heard right and never "corrected" away.
• Profiles: "Claude prompt", "Slack message", "Quick note", each with its own cleanup level and destination.
• Paste into a specific app, and optionally press Return for hands-free prompting, with a countdown to cancel.
• Prompt templates, shell scripts and webhooks on the Mac.
• A local API, command-line tool and MCP server, so agents like Claude Code can read what you just said or wait for what you say next.
• Shortcuts: start from the Action Button, Back Tap, Control Center, the Lock Screen or Siri, or use Dictate Text to get the words back in your own shortcuts.
• Offline queue: if your Mac is asleep, your iPhone holds the dictation and delivers it later.
• History of your last 50 dictations, raw and cleaned, kept only on your iPhone.

WORKS ON ITS OWN, TOO
Before you pair a Mac, every dictation is copied to your iPhone's clipboard.

REQUIREMENTS
iPhone with iOS 17 or later. Mac with macOS 14 or later, running the free Macrophone for Mac. Cleanup needs an iPhone that supports Apple Intelligence, on iOS 26 or later. Dictate in many languages; cleanup in English.

Free. No in-app purchases, no subscription.
```

## Keywords

```
dictation,voice to text,speech,transcribe,wireless mic,clipboard,typing,prompt,AI,terminal,MCP,notes
```

100 / 100 characters. Words already in the name and subtitle (Macrophone, speak, iPhone,
paste, Mac) are indexed anyway, so they're left out. No competitor or third-party trademarks
(no "Claude", "ChatGPT", "Whisper") — guideline 2.3.7.

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
- Webhooks and scripts run on the Mac app (not distributed through the App Store) and only
  send where the user points them.

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
- App Intents: "Start Dictation" opens the app already recording (iOS requires the app in the foreground to use the microphone); "Dictate Text" returns the transcript to the user's own shortcut. A Control Center / Lock Screen control ("Dictate to Mac") runs Start Dictation on iOS 18 and later.
- The app is iPhone only.
```

## Screenshots

Upload the **6.9"** set (1320 × 2868, iPhone 16/17 Pro Max) — App Store Connect scales it for
smaller iPhones. Add the **6.5"** set (1284 × 2778, iPhone 14 Plus / 11 Pro Max class) as well,
so older-device pages show the real layout instead of a scaled one. Same six shots in both;
capture the 6.5" set on an iPhone 14 Plus simulator.

Style: the app's own dark ink ground, the caption in the serif at the top (two short lines,
sentence case, no emoji), the device frame-less screenshot below. The Filament is the hero in
shots 1 and 2. Captions match the website's voice.

| # | Screen | Caption |
| --- | --- | --- |
| 1 | Main screen mid-dictation: the Filament alive, live transcript in serif, "LISTENING" | Speak into your iPhone. The words land on your Mac. |
| 2 | Delivered state: mint line, "Delivered to MacBook Pro · Pasted", Raw / Cleaned toggle showing Cleaned | Cleaned up on your iPhone. No audio kept. |
| 3 | Cleanup level slider (Off · Light · Medium · Heavy) with the before/after sample | Four levels of cleanup. It edits, never answers. |
| 4 | Profiles picker on the phone: Claude prompt, Slack message, Quick note | One tap to choose where it goes. |
| 5 | Mac side (render the Mac popup over a Terminal window, framed as a Mac screenshot inside an iPhone-sized canvas): "Pasting into Terminal" with the countdown and Cancel | Paste into any app. Press Return for you, with a moment to cancel. |
| 6 | Shortcuts / Action Button: the "Dictate to Mac" control in Control Center, and "Dictate Text" in a shortcut | Start from the Action Button, Control Center or Siri. |

Optional 7th: privacy screen from onboarding — "Speech is transcribed on your iPhone. No
audio is kept. No account."

App Preview video (optional, 15–30 s): the website's demo loop as a real recording — speak,
send, land in Terminal.

## What's New in This Version (1.0)

```
Macrophone is here. Speak into your iPhone and the text lands on your Mac: on the clipboard, in the app you're using, or in a script or AI agent. Transcribed on your iPhone, cleaned up on-device, and never stored as audio. Dictate in many languages; cleanup in English.
```

## Store line on languages

Use exactly: **"Dictate in many languages; cleanup in English."** (in the description's
Requirements and in What's New). The UI and listing are English only in 1.0.
