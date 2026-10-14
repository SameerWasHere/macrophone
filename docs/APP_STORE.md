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
| Subtitle | Speak on iPhone, type on Mac | 28 / 30 |
| Promotional text | Speak on your iPhone and your words land in any app open on your Mac, pasted or pasted and sent. Cleaned up on the iPhone. Free, private, no account. | 149 / 170 |

Promotional text can change without a new build. The name, subtitle, promotional text and
keywords name no third-party app on purpose (see "Third-party names").

## Description

(≤4,000 characters; this is 2,565.)

```
Speak on your iPhone, pick any app open on your Mac, and Macrophone pastes your words there. Or pastes them and sends.

Your iPhone becomes a wireless microphone for your Mac. Tap the mic, talk, tap again, and the text lands where you're working: an AI chat, the terminal running your coding agent, your editor, a message box. It's built for long prompts you'd rather say than type.

PICK WHERE IT GOES
• The apps open on your Mac show up by the mic. Tap one, and that's where your next dictation goes.
• Or choose Where I'm typing (the app in front) or Clipboard.
• Or just say it: start with an open app's name and a pause ("Terminal, run the tests again") and that one dictation goes there.
• Turn on Send after pasting and the Mac presses send for you, after a short countdown you can cancel. It never types into a password field.

CLEANUP, YOUR WAY
Pick Off, Light, Medium, Heavy or Custom. Light takes out the ums and repeats. Medium also fixes false starts. Heavy turns rambling speech into tidy text. Custom follows your own instructions. Cleanup edits your words and never answers them, so a prompt arrives as a prompt. The raw transcript is always one tap away. Cleanup runs on your iPhone with Apple's on-device model.

PRIVATE BY DESIGN
• Speech is turned into text on your iPhone. No audio is kept.
• Your text goes straight to your Mac over your local network, encrypted with a key made when you pair. There's no server in between.
• No account, no ads, no analytics. Data Not Collected.

HANDY EXTRAS
• Action Button, Control Center, Lock Screen, Siri and Shortcuts: start dictating from anywhere.
• A dictionary of up to 50 names and terms it should hear right and keep as written.
• Stop when you stop talking, or hold the mic and let go.
• If your Mac is asleep, your iPhone holds the dictation and delivers it later.
• History of your last 50 dictations, raw and cleaned, kept only on your iPhone.
• For developers: the Mac app has a local API, a command-line tool and an MCP server, so your agents can read what you just said.

WORKS ON ITS OWN, TOO
Before you pair a Mac, every dictation is copied to your iPhone's clipboard.

REQUIREMENTS
iPhone with iOS 17 or later. Mac with macOS 14 or later, running the free Macrophone for Mac from sameer.us/macrophone. Cleanup needs an iPhone that supports Apple Intelligence, on iOS 26 or later. Dictate in many languages; cleanup in English.

Free. No in-app purchases, no subscription.

App names belong to their owners. Macrophone is an independent app and isn't affiliated with or endorsed by them.
```

## Keywords

```
dictation,voice to text,speech to text,prompt,AI,transcribe,wireless mic,hands-free,clipboard,agent
```

99 / 100 characters. Words already in the name and subtitle (Macrophone, speak, iPhone, type,
Mac) are indexed anyway, so they're left out. No competitor or third-party trademarks
(guideline 2.3.7).

## What's New in This Version (1.0)

```
Macrophone is here. Speak on your iPhone, pick any app open on your Mac, and your words are pasted there, or pasted and sent. Five cleanup levels, including your own Custom instructions, all on your iPhone. No account, nothing collected. Dictate in many languages; cleanup in English.
```

(On a 1.0 App Store Connect doesn't show this field. Keep the text for the website's version
history.)

## Categories

- Primary: **Productivity**
- Secondary: **Developer Tools**

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
"Macrophone for Mac" is a free menu bar app, offered as a signed and notarized download at https://sameer.us/macrophone/download. There's no paid tier anywhere. To test the full path, install it on a Mac on the same Wi-Fi network, open it, choose Pair iPhone, and scan the QR code from the iPhone app (or tap "Use a Code Instead" and type the six-digit code). The apps open on the Mac then appear by the mic button. Pick one, dictate, and the Mac pastes the text there.

PERMISSIONS AND WHY
- Microphone: to hear the user while they tap or hold the mic button. Audio is never stored.
- Speech Recognition: speech to text, forced to run on the device (requiresOnDeviceRecognition). Audio is not sent to Apple or to us.
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

| # | File | Screen | Kicker | Caption |
| --- | --- | --- | --- | --- |
| 1 | `01-recording.png` | Mid-dictation: the live transcript, the Filament alive, the timer, the dock of the Mac's open apps with Claude lit, "You said Claude", Send after pasting on, cleanup at Medium, "Listening — this one goes to Claude" | DICTATE | Speak into your iPhone. It lands on your Mac. |
| 2 | `02-delivered.png` | Delivered: the mint ✓ on the Filament, "Sent to Claude — you said "Claude" first", and the last dictation card (Cleaned / Raw, Copy, Resend) | VOICE TARGETS | Say where it goes. It goes straight there. |
| 3 | `03-send-to.png` | The main screen at rest: the dock with Claude picked, "Send to Claude", Send after pasting, and the status line "Pastes into Claude, then sends" | SEND TO | Pick where it goes. Or just say it. |
| 4 | `04-cleanup.png` | Settings: Send to · Clipboard, the cleanup steps (Off · Light · Medium · Heavy · Custom) with a HEARD / SENT · MEDIUM CLEANUP card | CLEANUP | Four levels, or your own. It edits, never answers. |
| 5 | `05-history.png` | History: three dictations with Cleaned / Raw, where each went (Claude · you said "Claude" first, Terminal — claude, Where I'm typing), Delivered, the cleanup level | HISTORY | Raw and cleaned, kept on your iPhone. |
| 6 | `06-pairing.png` | Onboarding step 5: "Scan the code on your Mac." with the QR viewfinder and "Use a Code Instead" | PRIVATE BY DESIGN | Pair once. No account, no cloud, no audio kept. |

The captured screens show only features the simplified app has. **Shots 1–3 show the main
screen as it was on Oct 13 2026.** The main screen is being redesigned (the last-dictation card
is going away, the mic moves to the bottom, and the transcript fills the space above it while
recording). Re-capture and re-render **01, 02 and 03** in both sizes after that lands, and before
upload. Shots 4–6 (Settings, History, pairing) aren't affected. Use the "Macrophone Shots 6.9"
(723B841D-…) and "Macrophone Shots 6.5" (13583BDA-…) simulators.

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
