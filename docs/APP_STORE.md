# Macrophone: App Store submission (iPhone, 1.0)

Everything App Store Connect asks for, ready to paste, for the app as simplified on Oct 13 2026:
you speak on the iPhone, pick any app open on your Mac (or Clipboard, or Where I'm typing), and
the Mac pastes it there, or pastes and sends it, at the cleanup level you chose. Character
counts were checked with `python3 -c 'print(len("…"))'`. The Mac app is not on the App Store.
It's a signed, notarized download from sameer.us/macrophone/download.

Readiness was audited on Oct 13 2026: a Release archive built with no warnings, and the
`.xcarchive` was inspected (see "Build audit" at the end).

---

## Blockers before you press Submit

1. **The Mac app has to be downloadable.** On Oct 13 2026 every sameer.us/macrophone page said
   "Mac app: coming soon", and the download page said it is "being signed and notarized". No
   `.dmg` is served. The iPhone app's "Get the free app" banner, onboarding step 4 and Settings
   all link there, and the review notes below send App Review there. A reviewer who finds
   "coming soon" can reject the app under 2.1 (App Completeness): its main feature depends on
   something you can't get. Publish the notarized Mac build first (Mac/`scripts/release.sh`,
   `docs/RELEASING.md`), then submit the iPhone app.
2. **Confirm `macrophone@sameer.us` receives mail.** It's the address on the support and privacy
   pages and the App Review contact. Send it a test from another account. (I didn't send anything.)
3. After approval, swap the site's "iPhone app: coming soon to the App Store" for the real
   App Store link (search the sameer-gpt repo for `TODO: app id`).
4. The name: see `NAME_CHECK.md`. "Macrophone" is usable with moderate risk (Apple's "Mac" mark).
   **Wiremic** is the ready fallback if review objects.

---

## Submit in 10 minutes

1. **Sign into Xcode.** Xcode › Settings › Accounts › + › Apple ID. Pick team `8523EX5882`.
2. **Open the project.** `cd ~/claude-projects/Macrophone/iOS && xcodegen generate && open Macrophone.xcodeproj`.
   The `.xcodeproj` is generated and not checked in, so always regenerate it.
3. **Archive.** Scheme *Macrophone*, destination *Any iOS Device (arm64)*, then Product › Archive.
   Signing is automatic. This first archive also registers the two App IDs
   (`com.sameer.macrophone`, `com.sameer.macrophone.controls`) in your developer account,
   which App Store Connect needs before you can make the app record.
4. **Create the app record.** In [App Store Connect](https://appstoreconnect.apple.com), go to
   Apps › + › New App. Platform **iOS**, Name **Macrophone**, Primary language **English (U.S.)**,
   Bundle ID **com.sameer.macrophone**, SKU **macrophone-ios-1**, User Access **Full Access**.
5. **Upload the build.** In the Organizer (opens after Archive), pick Distribute App ›
   App Store Connect › Upload, and keep the defaults (automatic signing, upload symbols). Wait
   about 10–30 minutes for "Processing" to finish. Export compliance won't be asked:
   `ITSAppUsesNonExemptEncryption` is `NO`.
6. **Paste the listing** (sections below). On the 1.0 version page: promotional text,
   description, keywords, support and marketing URLs, and copyright `2026 Sameer Bhutani`.
   In App Information: subtitle, categories, content rights (**No**, the app has no
   third-party content), age rating. In App Privacy: privacy policy URL, then the data answer.
7. **Screenshots.** Drag in `iOS/docs/store-screenshots/6.9/01…06` for the 6.9" display and
   `6.5/01…06` for 6.5". No iPad screenshots are needed, because the app is iPhone only.
8. **Pricing and availability.** Free, all territories. **Turn off** "Make this app available"
   under *iPhone and iPad Apps on Apple Silicon Macs* and under *Apple Vision Pro*. A phone mic
   for your Mac makes no sense running on the Mac itself, and it was never tested there.
9. **App Review information.** Sign-in not required. Contact: you, `macrophone@sameer.us`,
   your phone number. Paste the notes below.
10. **Pick the build** under "Build", choose "Manually release this version", then
    **Add for Review › Submit**.

---

## Name, subtitle, promotional text

| Field | Text | Length / limit |
| --- | --- | --- |
| Name | Macrophone | 10 / 30 |
| Subtitle | Control your Mac by voice | 25 / 30 |
| Promotional text | Your agents never wait on you again. See any app on your Mac live, tap and swipe it like you're there, and say what's next. Free, private, no account. | 150 / 170 |

Positioning: `docs/POSITIONING.md` (the people, the jobs, the words).

Promotional text can change without a new build. The name, subtitle, promotional text and
keywords name no third-party app on purpose (see "Third-party names").

## Description

(≤4,000 characters; this is 2,424.)

```
Steer your Mac from your iPhone. Your agents never wait on you again.

Leave your Mac running: a Mac mini on a shelf, a MacBook docked with its lid shut, the desk across the room. When a coding agent stops to ask you something, you see it on your iPhone and answer in seconds. When you think of the next task, you say it, and it's typed and sent.

SEE IT
• Any app's window on your Mac, live on your iPhone: the terminal running your coding agent, an AI chat app, your editor, a message thread.
• It opens on the part you type in and follows the newest output.

STEER IT
• Tap anywhere to click there on your Mac: switch sessions, pick an option, open a file.
• Swipe to scroll the window right where your finger is.
• Esc, Up, Down and Return under the window: move through an agent's question, approve it, or stop it.
• Open any app on your Mac, even one that isn't running.

SAY IT
• Hold the mic and talk. Your words are transcribed on your iPhone, tidied up (no ums, no false starts), pasted into the app and sent.
• Long prompts are easier to say than to type, especially on a phone.
• Pick how much cleanup: Off, Light, Medium, Heavy, or your own instructions. It edits your words and never answers them.

WORKS WITH EVERYTHING
Coding agents in a terminal, an AI app or your editor, chat and messaging apps, notes, mail: any app on your Mac with somewhere to type. Your Mac finds them on its own; nothing to set up.

PRIVATE BY DESIGN
• Speech is turned into text on your iPhone. No audio is kept.
• Your iPhone talks straight to your Mac over your own network, end-to-end encrypted. No server, no account.
• Only the one window you pick is shown, only while you look, and it's never saved.
• No ads, no analytics. Data Not Collected. Open source.

HANDY EXTRAS
• Action Button, Control Center, Lock Screen, Siri and Shortcuts.
• A dictionary for names and terms it should hear right.
• If your Mac is asleep, your iPhone holds the dictation and delivers it later.
• For developers: a local API, a command-line tool and an MCP server on the Mac.

REQUIREMENTS
iPhone with iOS 17 or later. Mac with macOS 14 or later, running the free Macrophone for Mac from sameer.us/macrophone. Cleanup needs an iPhone that supports Apple Intelligence, on iOS 26 or later.

Free. No in-app purchases, no subscription.

App names belong to their owners. Macrophone is an independent app and isn't affiliated with or endorsed by them.
```

## Keywords

```
coding agent,remote,voice control,dictation,terminal,AI,prompt,speech to text,hands-free,mac mini
```

97 / 100 characters. Words already in the name and subtitle (Macrophone, speak, iPhone, type,
Mac) are indexed anyway, so they're left out. No competitor or third-party trademarks
(guideline 2.3.7).

## What's New in This Version (1.0)

```
Macrophone is here. Speak on your iPhone, pick any app open on your Mac, and your words are pasted there, or pasted and sent. Five cleanup levels, including your own Custom instructions, all on your iPhone. No account, nothing collected. Dictate in many languages; cleanup in English.
```

(On a 1.0 App Store Connect doesn't show this field. Keep the text for the website's version
history.)

## Categories

- Primary: **Developer Tools**
- Secondary: **Productivity**

## Age rating questionnaire

Every content question (violence, sexual content or nudity, profanity, horror or fear,
alcohol/tobacco/drugs, gambling, simulated gambling, contests, medical or wellness topics,
mature or suggestive themes): **None**.

| Question | Answer |
| --- | --- |
| Unrestricted web access | No |
| User-generated content | No |
| Messaging and chat between users | No |
| Advertising | No |
| Parental controls | No |
| Age assurance | No |
| Made for Kids | No |

Expected rating: **4+**.

## URLs

All three returned HTTP 200 on Oct 13 2026.

| Field | URL |
| --- | --- |
| Marketing URL | https://sameer.us/macrophone |
| Support URL | https://sameer.us/macrophone/support |
| Privacy Policy URL | https://sameer.us/macrophone/privacy |

Support email on the site and in the listing: **macrophone@sameer.us** (confirm it receives mail).

## App Privacy (the "nutrition label")

Answer **"No, we do not collect data from this app."** That gives **Data Not Collected**.

Why that's true:

- Speech recognition is forced to run on the device (`requiresOnDeviceRecognition`). Audio is
  never stored.
- Cleanup runs on Apple's on-device model (Foundation Models).
- Dictation text goes only to the user's own paired Mac over the local network, encrypted with a
  key created at pairing. The developer never receives it.
- There are no analytics, crash reporting, ads or third-party SDKs. The iPhone app contacts no
  server. Its only links open sameer.us in Safari.
- "Share Diagnostics" (Settings) builds a text file the user can share with the share sheet if
  they choose. It holds no dictation text. Data the user decides to send you, one time, isn't
  "collected" under Apple's definition.
- The iPhone keeps the names of the apps open on the Mac (in a keychain item shared with its
  Control Center extension) so the picker and controls work offline. That's configuration that
  stays on the device, not collected data.
- Both the app and the extension ship privacy manifests: no tracking, no collected data types,
  plus required-reason APIs (UserDefaults `CA92.1` in both; system boot time `35F9.1` in the
  app, for the animation clock).

If analytics, crash reporting or any server is ever added to the iPhone app, change the label in
the same release.

## Export compliance

`ITSAppUsesNonExemptEncryption` = **NO** (in `iOS/project.yml` → `Info.plist`; confirmed in the
archive), so App Store Connect won't ask on each build.

Why NO is correct: the app's only cryptography is Apple's CryptoKit (X25519 key agreement, HMAC,
ChaCha20-Poly1305 for the phone-to-Mac link), and Security for the keychain. It implements no
algorithm itself and bundles no third-party crypto library. Using encryption built into Apple's
operating system is exempt. If App Store Connect ever asks *"What type of encryption algorithms
does your app implement?"*, the answer is **None of the algorithms mentioned above**. No
documents to upload, and no French declaration.

## App Review information

**Sign-in required:** No. There are no accounts.
**Contact:** Sameer Bhutani · macrophone@sameer.us · (phone number)

**Notes** (paste into "Notes"; ≤4,000 characters):

```
Macrophone is a dictation app. You speak into the iPhone, it turns the speech into text on the device, and it sends the text to a free companion app on the user's own Mac, which pastes it into the app the user picked (or pastes it and presses send).

NO ACCOUNT. TESTING WITHOUT A MAC
There is no login. The iPhone app also works on its own: until a Mac is paired, every dictation is copied to the iPhone's clipboard. To test:
1. Open Macrophone. The setup screens ask for each permission with an explanation first. Tap Skip on "Get the Mac app", "Looking for your Mac" and "Scan the code on your Mac".
2. On the main screen, tap the large mic button, say a sentence, then tap it again to stop.
3. The text appears under the button, the status line says it was copied on the iPhone, and the text is on the clipboard. Paste it in Notes to check.
4. The cleanup buttons (Off, Light, Medium, Heavy, Custom) choose how much the text is tidied up. Cleanup uses Apple's on-device model and needs a device with Apple Intelligence on iOS 26 or later. Elsewhere the exact transcript is used. The History button shows the last dictations with Cleaned and Raw versions.

THE FREE MAC APP (OPTIONAL FOR REVIEW)
"Macrophone for Mac" is a free menu bar app, offered as a signed and notarized download at https://sameer.us/macrophone/download. There's no paid tier anywhere. To test the full path, install it on a Mac on the same Wi-Fi network, open it, choose Pair iPhone, and scan the QR code from the iPhone app (or tap "Use a Code Instead" and type the six-digit code). The apps open on the Mac then appear by the mic button. Pick one, dictate, and the Mac pastes the text there. With the Mac connected, the Watch button next to the picked app (or sending with "Send after pasting" on) shows that one app window on the iPhone, live; taps and the Esc / Up / Down / Return keys under it act in that window on the Mac. The Mac asks for its Screen Recording permission for this; the iPhone needs no extra permission.

PERMISSIONS AND WHY
- Microphone: to hear the user while they tap or hold the mic button. Audio is never stored.
- Speech Recognition: speech to text on the device (Apple's SpeechAnalyzer on iOS 26+, else SFSpeechRecognizer with requiresOnDeviceRecognition). Audio is not sent to Apple or to us.
- Local Network: to find the user's Mac with Bonjour (_macrophone._tcp) and send it the text directly. The iOS prompt appears at the "Looking for your Mac" setup step, or the first time the user pairs. Nothing goes to the internet.
- Camera: only to scan the pairing QR code shown on the Mac, requested at that step. Pairing also works with a six-digit code instead.

OTHER NOTES
- No ads, analytics, in-app purchases or third-party SDKs. App Privacy: Data Not Collected.
- App Intents: "Start Dictation" opens the app already listening (iOS needs the app in the foreground to use the microphone). Its optional "Send To" parameter is Clipboard, Where I'm typing, or an app open on the user's Mac. "Dictate Text" returns the transcript to the user's own shortcut. A Control Center / Lock Screen / Action Button control ("Dictate to Mac") runs Start Dictation on iOS 18 and later.
- App names that appear in the app (for example the apps open on the Mac) come from the user's own Mac. Macrophone has no integration with those apps' makers, sends nothing to them, and isn't affiliated with them.
- The app is iPhone only and portrait only.
```

## Screenshots

Upload the **6.9"** set (1320 × 2868, iPhone 16/17 Pro Max) and the **6.5"** set
(1284 × 2778). App Store Connect scales the 6.9" set down for smaller iPhones. The files are
`iOS/docs/store-screenshots/6.9/` and `/6.5/`: the same six shots in each, real screens captured
through the DEBUG hooks (`iOS/scripts/capture-store-shots.sh`) and framed by
`iOS/scripts/render-store-shots.swift`. All are RGB, no alpha, at the exact required sizes.

Style: the app's dark ink ground, a mono kicker and a two-line serif caption at the top, and the
phone below with the Filament crossing the frame. No caption names a third-party app.

| # | File | Screen | Headline |
| --- | --- | --- | --- |
| 1 | `01-hero.png` | A MacBook showing a Terminal running Claude Code; the iPhone in front showing the same window, live, with Esc · ↑ · ↓ · Return | Steer your Mac from your **iPhone**. |
| 2 | `02-talk.png` | Replying while watching: the window as a strip, the reply appearing, the mic recording | **Say** what's next. It's typed and sent. |
| 3 | `03-tap.png` | The live window with a tap marker on "1. Yes" | Tap and **swipe**, like you're there. |
| 4 | `04-apps.png` | Send to with Watch and ⋯, the Mac's apps with their icons, Send after pasting, cleanup | Every agent. Every **app**. |
| 5 | `05-open.png` | Open an app: the Mac's installed apps with icons | Open **any app** on your Mac. |
| 6 | `06-cleanup.png` | Settings with a HEARD / SENT · MEDIUM card | Ums and uhs, **cleaned up**. |
| 7 | `07-private.png` | Onboarding: scan the code on your Mac | **Private.** No account. No cloud. |

The marketing pass (Oct 14 2026): bold SF headlines at 122 pt (readable as search thumbnails), one
lit word each, from `docs/POSITIONING.md`. Re-rendered Oct 14 2026 for the new pitch. Shots 1–4 come from a live stand-in Mac
(`mpctl serve`, see the capture script's header) so the window and the app icons are real. Use the
"Macrophone Shots 6.9" (723B841D-…) and "Macrophone Shots 6.5" (13583BDA-…) simulators.

## Third-party names (guidelines 2.3.7 / 5.2.1)

Keep third-party names out of the name, subtitle, keywords, promotional text and screenshot
captions. The description now names none (the old compatibility list went with the target
gallery). Inside the screenshots, "Claude" and "Terminal" appear as the user's own open Mac apps,
which shows the app in use (2.3.3), not borrowed branding. If App Review objects to that anyway,
re-capture shots 1–3 and 5 with other sample apps (`MACROPHONE_FAKE_TARGETS`, `DebugHooks.swift`).
The onboarding's first screen says "into Claude, a terminal, or wherever you're working". That's
a plain compatibility mention, but it's the one place in the shipped UI that names a brand.
Change it to "into an AI chat" if review asks.

## Build audit (Oct 13 2026)

Checked in `iOS/**` and a Release `xcodebuild archive` (Xcode 27.0, iOS 27.0 SDK, development
signing, built in `/private/tmp` and deleted afterwards):

| Check | Result |
| --- | --- |
| Archive | **Succeeded, 0 warnings.** |
| Bundle ids | App `com.sameer.macrophone`, extension `com.sameer.macrophone.controls` (prefixed by the app's, embedded at `PlugIns/MacrophoneControls.appex`) |
| Version | 1.0 (1) in both, from `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` |
| Device family | `UIDeviceFamily = [1]` (iPhone) in both. **Fixed**: XcodeGen gave each target "1,2", so the app had been building as universal (that would have required iPad screenshots and iPad review). It's now set per target in `project.yml`. |
| Deployment | App iOS 17.0, extension iOS 18.0 (controls need 18; on iOS 17 the app runs without them). FoundationModels is weak-linked, so the app launches on iOS 17–25. |
| Encryption | `ITSAppUsesNonExemptEncryption = NO` |
| Usage strings | Microphone, Speech Recognition, Camera, Local Network (+ `NSBonjourServices` `_macrophone._tcp`). No unused permission keys. No `UIBackgroundModes` (nothing runs in the background). |
| Entitlements (`codesign -d --entitlements`) | App: `keychain-access-groups` = own + `.shared`. Extension: `.shared`. Nothing else, no App Groups, no capabilities left from removed features. (`get-task-allow` is only true under development signing; the App Store signature drops it.) |
| Privacy manifests | App and extension both in the bundle. **Added** the extension's (it reads UserDefaults through the shared intent code) and the app's system-boot-time reason. |
| App icon | Any, dark and tinted at 1024², RGB with no alpha (tinted is grayscale), compiled into `Assets.car` |
| Launch screen | `UILaunchScreen` with the `LaunchBackground` colour |
| Debug code | `DebugHooks` and every `MACROPHONE_*` hook sit behind `#if DEBUG`. The Release binary has no `MACROPHONE_` strings. |
| Private API | None: no `NSClassFromString` / `NSSelectorFromString` / `dlopen` / underscored KVC |
| App Intents | `Metadata.appintents` in the app and the extension. Start Dictation and Dictate Text are App Shortcuts, and every phrase includes `.applicationName`. |
| Standalone path | Verified on the simulator: unpaired, a dictation lands on the iPhone's clipboard with "Copied on iPhone — paste it anywhere". A Release build launches into onboarding with Skip on every step. |
