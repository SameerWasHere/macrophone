# Macrophone: App Store submission (iPhone, 1.0)

**Resubmitted Nov 11 2026 as 1.0 (44)** — Sameer: "submit the latest build". Build 5 had sat in
Waiting for Review since Nov 2; that submission was cancelled (through the App Store Connect API),
build 44 attached to version 1.0 and a new submission made (Waiting for Review, release after
approval). The listing wasn't touched. Three lines of the review notes were brought up to date
(the setup's Skip step — the "iOS asks to find devices" page is gone; notifications also asked
after a dictation into a chat; a line on iCloud's private database carrying alerts); the notes
are at the 4,000-character limit (3,995). **Found that day: all of sameer.us answered 402
`DEPLOYMENT_DISABLED`** (Vercel) — the support URL, the privacy policy and the Mac download the
notes point to were unreachable; it has to be back before review reaches the app.
**New screenshots the same night** — Sameer: "submit with updated screenshots … we have made a
lot of app changes". All three sets re-shot from build 44's code and replaced through the API
(the submission cancelled first — a version waiting for review can't be edited — then submitted
again: `a4d1396f-…`, Waiting for Review, build 44, release after approval). Captions unchanged.
sameer.us still answered 402 that night; **back on Nov 12 2026** (Sameer unblocked it: the site, privacy,
support, the download page and the 1.1.6 disk image all answer 200).
**Resubmitted Nov 2 2026 as 1.0 (5)** after App Review's automated scan asked about "VPN
functionality" (there is none — answered in the message thread and in the review notes; the
description's "over your own VPN" became "when you're away from home"). Build 5 is main as of
that day (the open Duo's glance, the Mac's pointer shapes).
**Resubmitted Nov 1 2026 as 1.0 (4)** after the first review (Oct 15 2026) was rejected for
5.1.1(iv) — a pre-permission screen's button said "Allow" — and 5.2.5 — "Mac" in the subtitle.
Every pre-permission button now says Continue and asks nothing (the network step's "Tap Allow
when iOS asks" and "Look for My Mac" went too); the subtitle is "Control your computer by voice"
and "mac mini" left the keywords. The listing below is what App Store Connect holds (pushed with
the App Store Connect API, `~/claude-projects/MagicCoinFlip/scripts/asc.py`). The Duo's screen
corner is a constant now (it had been read through private KVC).

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
| Subtitle | Control your computer by voice | 30 / 30 |
| Promotional text | Your agents never wait on you again. See your computer live, steer it with a trackpad and keyboard, and say what's next. Free, private, no account. | 147 / 170 |

Positioning: `docs/POSITIONING.md` (the people, the jobs, the words).

Promotional text can change without a new build. The name, subtitle, promotional text and
keywords name no third-party app on purpose (see "Third-party names").

## Description

(≤4,000 characters; this is 3,240.)

```
Steer your Mac from your iPhone. Your agents never wait on you again.

Leave your Mac running: a Mac mini on a shelf, a MacBook docked with its lid shut, the desk across the room. When a coding agent stops to ask you something, you see it on your iPhone and answer in seconds. When you think of the next task, you say it, and it's typed and sent.

SEE IT
• Any app's window on your Mac, live and smooth on your iPhone, or the whole screen.
• Your Mac's apps sit in a Dock at the bottom of the screen, with your Mac's own wallpaper behind them. Tap one to send to it, tap it again to watch it.
• Light and dark, like the rest of your iPhone.

STEER IT
• Tap to click, tap twice to double-click, hold to right-click, tap then hold and move to drag.
• A full trackpad, with two-finger scrolling and the gestures you know: Mission Control, App Exposé, switching desktops.
• A real Mac keyboard: Esc, Tab, the arrows, ⌘ ⌥ ⌃ ⇧ and every shortcut, typed straight into the window.
• When an agent asks a question, its answers appear as buttons.
• Mac controls: volume, brightness, play and pause. Hear your Mac's sound on your iPhone if you like.
• Open any app on your Mac, even one that isn't running.

SAY IT
• Tap or hold the mic and talk. Your words are transcribed on your iPhone, tidied up (no ums, no false starts), pasted into the app and sent.
• Long prompts are easier to say than to type, especially on a phone.
• Pick how much cleanup: Off, Light, Medium, Heavy, or your own instructions. It edits your words and never answers them.

MADE FOR IPHONE DUO
Folded like a laptop, the top half is your Mac's screen and the bottom half is a trackpad, a keyboard or the mic. Opened flat, your Mac sits beside the controls you already know from the cover.

WORKS WITH EVERYTHING
Coding agents in a terminal, an AI app or your editor, chat and messaging apps, notes, mail: any app on your Mac with somewhere to type. Your Mac finds them on its own; nothing to set up. Pair more than one Mac and swipe between them.

PRIVATE BY DESIGN
• Speech is turned into text on your iPhone. No audio is kept.
• Your iPhone talks straight to your Mac over your own network, end-to-end encrypted. No server, no account.
• Only what you pick is shown, only while you look, and it's never saved.
• No ads, no analytics. Data Not Collected. Open source.

HANDY EXTRAS
• Send a photo, a file or your clipboard to your Mac.
• A notification when an agent on your Mac stops to ask you something.
• Action Button, Control Center, Lock Screen, a Home Screen widget, Siri and Shortcuts.
• A dictionary for names and terms it should hear right.
• Reach your Mac when you're away from home.
• For developers: a local API, a command-line tool and an MCP server on the Mac.

REQUIREMENTS
iPhone with iOS 17 or later. Mac with macOS 14 or later, running the free Macrophone for Mac from sameer.us/macrophone. Cleanup needs an iPhone that supports Apple Intelligence, on iOS 26 or later. Watching and controlling need the Mac app's Screen Recording and Accessibility permissions, which it walks you through.

Free. No in-app purchases, no subscription.

App names belong to their owners. Macrophone is an independent app and isn't affiliated with or endorsed by them.
```

## Keywords

```
coding agent,remote,voice control,dictation,terminal,AI,prompt,speech to text,hands-free,trackpad
```

97 / 100 characters. No "Mac" (Nov 1 2026: "mac mini" went with the 5.2.5 rejection of "Mac" in the subtitle). No competitor or third-party trademarks
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

**Notes** (paste into "Notes"; ≤4,000 characters; this is 3,853):

```
Macrophone is a dictation and remote-control app for the user's own Mac. You speak into the iPhone, it turns the speech into text on the device, and it sends the text to a free companion app on the user's own Mac, which pastes it into the app the user picked (or pastes it and presses send). With the Mac connected, the iPhone can also show one window (or the whole screen) of that Mac live and click, scroll and type in it.

CHANGES SINCE THE LAST REVIEW
- Guideline 5.1.1(iv): every screen shown before a permission request now has a "Continue" button and no wording that asks the user to allow it.
- Guideline 5.2.5: the subtitle no longer uses "Mac"; it is "Control your computer by voice".

NO ACCOUNT. TESTING WITHOUT A MAC
There is no login. The iPhone app also works on its own: until a Mac is paired, every dictation is copied to the iPhone's clipboard. To test:
1. Open Macrophone. The setup screens explain each permission, then tap Continue to see the system request. On "Get Macrophone for your Mac", "Next, iOS asks to find devices on your network" and "Scan the code on your Mac", tap Skip (top right).
2. On the main screen, tap the large round mic button, say a sentence, then tap it again to stop.
3. The text appears above the button, the status line says it was copied on the iPhone, and the text is on the clipboard. Paste it in Notes to check.
4. The Cleanup menu (Off, Light, Medium, Heavy, Custom) chooses how much the text is tidied up. Cleanup uses Apple's on-device model and needs a device with Apple Intelligence on iOS 26 or later. Elsewhere the exact transcript is used. History (the clock button) shows past dictations with Cleaned and Raw versions.

THE FREE MAC APP (OPTIONAL FOR REVIEW)
"Macrophone for Mac" is a free menu bar app, offered as a signed and notarized download at https://sameer.us/macrophone/download. There's no paid tier anywhere. To test the full path, install it on a Mac on the same Wi-Fi network, open it, choose Pair iPhone, and scan the QR code from the iPhone app (or tap "Use a Code Instead" and type the six-digit code). The apps open on the Mac then appear in a Dock at the bottom of the iPhone screen. Tap one, dictate, and the Mac pastes the text there. Tap the picked app again to watch it live: taps click, and the trackpad and keyboard under the window move the pointer and type on the Mac. The Mac asks for its Screen Recording and Accessibility permissions for this; the iPhone needs no extra permission.

PERMISSIONS AND WHY
- Microphone: to hear the user while they tap or hold the mic button. Audio is never stored.
- Speech Recognition: speech to text on the device (Apple's SpeechAnalyzer on iOS 26+, else SFSpeechRecognizer with requiresOnDeviceRecognition). Audio is not sent to Apple or to us.
- Local Network: to find the user's Mac with Bonjour (_macrophone._tcp) and talk to it directly. Nothing goes to the internet.
- Camera: only to scan the pairing QR code shown on the Mac, requested at that step. Pairing also works with a six-digit code.
- Notifications: asked the first time a Mac window is watched, for an alert when an app on the user's own Mac waits for an answer.

OTHER NOTES
- No ads, analytics, in-app purchases or third-party SDKs. App Privacy: Data Not Collected.
- App Intents: "Start Dictation" opens the app already listening. "Dictate Text" returns the transcript to the user's own shortcut. A Control Center / Lock Screen / Action Button control runs Start Dictation on iOS 18 and later. A Home Screen widget shows the Mac's open apps.
- App names that appear in the app (the apps open on the Mac) come from the user's own Mac. Macrophone isn't affiliated with their makers.
- The app is iPhone only. On iPhone Duo it uses the inner screen in every orientation (a laptop-like layout when folded); on the cover and on other iPhones it is portrait only.
```

## Screenshots

Three sets, uploaded through the API on Nov 1 2026 and re-shot and replaced on Nov 11 2026 (`APP_IPHONE_67` 6.9" 1320 × 2868,
`APP_IPHONE_65` 6.5" 1284 × 2778, and `APP_IPHONE_DUO` 2007 × 2853 — the Duo's inner screen; App
Store Connect took the size). Files: `iOS/docs/store-screenshots/6.9/`, `/6.5/`, `/duo/`, real
screens captured through the DEBUG hooks against a stand-in Mac (`iOS/scripts/capture-store-shots.sh`,
`capture-duo-store-shots.sh`) and framed by `iOS/scripts/render-store-shots.swift` (`duo` mode for
the Duo). RGB, no alpha. No caption names a third-party app or says "Mac".
To re-shoot: the stand-in Mac is `MPCTL_NO_DRAWN_POINTER=1 mpctl serve --name "Sameer's MacBook"
--auto-approve --no-attention --rounded --reshape --front-every 0 --state <fresh dir>` (the phone
draws the pointer itself; the demo's own would be a second one), one fresh `--state` per simulator
(a pairing URL works once); unpair any older stand-in Mac on the simulator first, or the pairing
shot lands on the test page. The 6.5" set is rendered from the 6.9" captures. The Duo script turns
off a fresh simulator's "slide to type" keyboard introduction.

| # | 6.9 / 6.5 | Caption |
| --- | --- | --- |
| 1 | `01-hero.png` — a MacBook behind, the phone watching the live Terminal window with the answers (dark) | Your computer, live on your **iPhone**. |
| 2 | `02-talk.png` — replying while watching, the words appearing (light) | **Say** what's next. It's typed and sent. |
| 3 | `03-tap.png` — the trackpad page, the pointer on "1. Yes" (dark) | Point, tap, **scroll**, like you're there. |
| 4 | `04-apps.png` — at rest: menu bar, wallpaper, the window's card, the Dock and the options bar magnified (light) | Every app in your **Dock**. |
| 5 | `05-open.png` — Open an App | Open **any app** on your computer. |
| 6 | `06-cleanup.png` — Settings' Cleanup with a Heard / Sent card | Ums and uhs, **cleaned up**. |
| 7 | `07-private.png` — setup: scan the code | **Private.** No account. No cloud. |

| # | Duo | Caption |
| --- | --- | --- |
| 1 | `01-laptop.png` — folded: the live window above, the trackpad below | Fold it into a little **laptop**. |
| 2 | `02-keyboard.png` — the same with the Mac keyboard | A full **keyboard** for your computer. |
| 3 | `03-book.png` — the book: the window left, keys, trackpad and mic right | Open it up. **Everything** in hand. |
| 4 | `04-open.png` — flat: the glance left, the cover's view right | Watch on one side, **talk** on the other. |
| 5 | `05-cover.png` — the cover with the window live: its answers, keyboard · mic · trackpad, the vertical bar | Closed, it's all in one **hand**. |

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
