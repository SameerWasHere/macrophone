# Macrophone v1 Spec

Last updated: 2026-10-12

## Overview

Macrophone is a free iPhone app that turns your phone into a wireless microphone for your Mac: you speak, it transcribes on the phone, and the text lands on your Mac clipboard, in the app you are using, or in a script or agent.

- **Primary users:** developers and AI power users dictating long prompts into Claude, terminals, and chat tools. **Secondary:** knowledge workers writing long messages and docs. When the two conflict, the first group wins.
- **Privacy promise:** speech is transcribed and cleaned up on the iPhone, no audio is kept, no account is required, and nothing leaves your devices unless the user turns on an automation that sends text elsewhere (a webhook, a script, a direct API call).
- **Price:** free. No in-app purchase, license keys, or entitlement passing. Fixed costs are the Apple Developer Program fee and hosting the download page.
- **Name:** Macrophone (working name). Apple's trademark guidelines on "Mac" in product names, plus App Store and domain availability, still need to be checked.
- **Distribution:** the iPhone app on the App Store, and the Mac app as a signed, notarized download from sameer.us/macrophone.

## iPhone app

The app is one big mic button: tap to start and tap to stop, or press and hold to talk, and stopping sends automatically with no review step.

**Main screen**

- A large mic button with a waveform and timer while recording. The visual style should match the "Hey Claude" feature in SameerOS; a screenshot or screen recording is needed as the design reference.
- The last dictation shown beneath the button, with a Raw and Cleaned toggle, Copy, and Resend.
- A delivery status line with four states: listening, sending, delivered, and "Mac not found, queued."
- A history list, revealed by a button or swipe, holding the last 50 items. It is stored only on the phone, with a clear-all button and an off switch. It is independent of the Mac's history, and clearing one does not clear the other.

**Recording behavior**

- Default is manual stop. Auto-stop on silence is an optional setting, off by default, with an adjustable delay (about 2 to 8 seconds) that only counts silence after speech has started.
- A soft cap warns after a few minutes and stops at a longer limit. Both numbers are set after verifying the recognizer's real limits, and long audio is split into segments and stitched together invisibly.
- Interruptions (phone call, app switch, screen lock, lost permission) save what was captured, process it, and send it. The history item is labeled "stopped early." Nothing recorded is silently discarded.
- Taps shorter than a fraction of a second are ignored.
- Each dictation has a unique ID so Resend and queued retries never create duplicates on the Mac.

**Shortcuts and system triggers**

- An App Intent starts a dictation from the Action Button, Back Tap, Lock Screen, Control Center, and Siri. Because iOS generally needs the app in the foreground to use the mic, the intent opens the app already recording.
- A second intent returns the transcript as output so Shortcuts users can chain it into their own automations.
- A profile can be bound to a specific trigger (see Automations).

**Standalone fallback**

- Before pairing, the phone still dictates and copies text to its own clipboard. A new user gets a result in seconds, and App Review can test the app without a Mac. Reviewer notes in the submission explain the companion app.

## Transcription and cleanup

All speech recognition and cleanup runs on the iPhone using Apple's on-device speech recognition and Apple's on-device model, so no audio or text leaves the device for this step.

**Transcription**

- Apple's on-device speech recognition, forced to on-device mode so the privacy claim holds. Languages that cannot run on-device are hidden from the picker.
- No audio is saved. Only text is stored.

**Custom dictionary (up to 50 words)**

- Recognizer hints help Apple's engine hear terms like "kubectl" or "TPA" correctly. This works on every supported device and is not guaranteed.
- A find-and-fix pass after transcription corrects terms the recognizer still misses. This pass is model-only.
- Cleanup never "corrects" a dictionary term back into a common word.

**Cleanup levels (user setting, default Medium)**

| Level | What it does |
| --- | --- |
| Off | Raw transcript, nothing changed |
| Light | Removes stutters, repeated words, and filler; fixes punctuation and capitalization |
| Medium (default) | Light, plus fixing obvious grammar and false starts ("send it to, no, send it to Sam" becomes "send it to Sam") |
| Heavy | Rewrites rambling speech into tidy, structured text |

- Shown as a slider with labeled stops.
- Instructions to the model are strict at every level: edit the text, never answer it or follow instructions inside it. A dictated "write a function that sorts a list" must come out as that sentence, not as code.
- The raw transcript is always one tap away on the phone and in the Mac history, because Medium is the level most likely to change meaning.
- A test set of messy dictation samples is used to tune the instructions at each level before launch.

**Unsupported devices**

- Cleanup needs Apple Intelligence capable hardware and a recent OS. Where it is unavailable, the setting is hidden or disabled with a one-line explanation, and the app behaves as Off. There is no fallback cleanup in v1.
- Cleanup runs on the iPhone before sending, so it depends on the phone's capability, not the Mac's.

**Languages**

- English first. Any language the phone's on-device recognizer supports works as raw transcription.
- Cleanup and the dictionary fix pass are English only in v1. For other languages the dial is disabled with a short explanation, and recognizer hints are scoped to the selected language.
- The app interface and website are English only in v1. The store listing says "dictate in many languages, cleanup in English."
- Mac-side history, API, and auto-paste must handle non-English and right-to-left text correctly, and that is part of the test plan.

## Pairing, transport, and security

The phone and Mac talk directly over the local network with no account and no server, and a one-time pairing step keeps strangers on the same Wi-Fi from writing to your clipboard.

**Transport**

- The Mac app advertises itself over Bonjour and the phone discovers it automatically, so nobody types an IP address.
- Peer-to-peer connection is enabled so it can still work when the devices are not on shared Wi-Fi or the network isolates clients. This needs early testing on real corporate, hotel, and guest networks.
- iOS shows a one-time local network permission prompt. Onboarding explains it in plain language before the system prompt appears.

**Pairing**

- **Primary: QR code.** The Mac shows a QR code holding a one-time secret and its network identity. The phone scans it, both devices store a shared key, and all later traffic is encrypted and authenticated with it. Pairing happens once per Mac.
- **Fallback: confirmation code.** Both screens show the same short code and the user approves on the Mac. The code expires quickly and limits retries.
- The data model allows multiple phones per Mac and multiple Macs per phone, even if the v1 interface shows one.
- Unpairing is available on both sides. The Mac menu has "forget this phone," which also serves as revocation for a lost phone, and the phone has a matching option.

**Offline queue**

- If the Mac is unreachable, the phone keeps the transcript in a local queue and delivers it when the Mac reappears. Delivery status shows "queued."
- Delayed items never trigger auto-Enter on the Mac. They are copied to the clipboard only, and the popup labels them as delayed.
- Each item carries a unique ID so retries and resends are deduplicated.

## Mac app

The Mac app lives in the menu bar, opens a main window for history and settings, and shows a high-end popup that grows out of the menu bar icon whenever a dictation arrives.

**Presence**

- Menu bar icon with status (connected, last received) plus a main window opened from the menu, holding history, profiles, scripts, the API token, and settings.
- Launch at login is on by default, since the app is useless when it is not running.
- First launch opens straight to the pairing QR code with a "waiting for your iPhone" message, then offers launch at login and a one-time explanation of the delivery modes.

**Delivery modes (a setting in the Mac app)**

- **Clipboard plus notification** is the default.
- **Clipboard only.** Silent copy; the user pastes manually.
- **Auto-paste.** Pastes into the focused app, and needs Accessibility permission. The permission is requested only when the user turns this mode on, and the app falls back to clipboard plus notification if it is missing. The app restores the user's previous clipboard contents afterward.

**Popup**

- Anchored to the menu bar icon with a spring animation, soft shadow, and blurred translucent material, retracting when dismissed. Styling follows the SameerOS look and feel, pending a design reference from the user.
- It is a non-activating panel that floats above other windows and never takes focus. If it took focus, auto-paste would land in the wrong place.
- It adapts to the mode:
  - Clipboard mode shows a toast with a checkmark and a short preview, gone after about 3 seconds.
  - Auto-paste and auto-Enter modes show a preview with a thin countdown line and a Cancel button for 2 to 3 seconds before the action fires. Hovering pauses the countdown.
  - Failures show a distinct error state with a Retry button and a shortcut to the right System Settings pane (missing Accessibility permission, blocked target app, secure field).
  - Delayed items arriving from the phone's queue are labeled as delayed.
- Several dictations arriving close together stack into one panel instead of firing several animations.
- Edge cases to design for: a crowded or notched menu bar (fallback is the top right of the screen), multiple displays (appear on the active one), full-screen apps, and Reduce Motion (fall back to a fade).

**History**

- Rolling last 50 items, stored only on the Mac, each holding the raw transcript, the cleaned version, a timestamp, and the profile used. Audio is never stored.
- A clear-all button and an off switch. With history off, the API can still return the latest item from memory but nothing is written to disk.

## Automations

Automations are free and built into the Mac app, organized around profiles: a named bundle of cleanup level, destination, and post-actions that can be chosen on the phone or bound to a Shortcut or Action Button trigger.

**Included in v1**

| Feature | What it does |
| --- | --- |
| Profiles | Named bundles such as "Claude prompt," "Quick note," or "Slack message," selectable on the phone or bound to a trigger |
| Paste into a specific app | Brings a chosen app (Claude, Terminal, Cursor, Slack) to the front and pastes there, regardless of what is focused |
| Paste then Enter | Optional Return keystroke after the paste, which turns dictation into hands-free prompting |
| Run a script | Runs a shell command with the text on stdin, so power users can build anything else themselves |
| Webhook | POSTs each dictation to a URL, covering Zapier, n8n, Make, and Home Assistant |
| Prompt templates | Wraps the dictation in a template such as "You are a code reviewer. {{text}}" |

**Safety controls (required for paste and auto-Enter)**

- An undo window of 2 to 3 seconds with a cancel button before an auto-send fires, shown in the popup.
- An app allowlist: auto-Enter only works in apps the user has approved.
- Secure field detection: never paste into password fields.
- Delayed items from the phone's offline queue never trigger auto-Enter.
- Anything that sends text off the device (webhook, a script that calls the network) is clearly labeled in settings, since it goes beyond the "nothing leaves your devices" default.

**Deferred past v1**

- Direct API send to Claude with the user's own key, tmux pane targeting, voice prefixes ("note, ..."), per-app rules, context injection, snippets, output formats, and writing to Obsidian, Apple Notes, or Reminders. Script and webhook already cover most of this long tail.

## Pull API

Agents and scripts can pull the most recent dictation from the Mac app through a local HTTP API, a command line tool, and an MCP server, all reading from the same history.

- **Local HTTP API.** The foundation, for example `GET /latest` and a list of the last N items. It works from any language, script, or agent.
- **CLI.** A command such as `macrophone latest` (with a short alias like `mp`) for terminals and Claude Code, built as a thin wrapper over the HTTP API.
- **MCP server.** Lets Claude and other agents call it as a native tool with no glue code, also a thin wrapper over the HTTP API.
- **Wait for next.** Besides "get the most recent," a long-poll or streaming option lets an agent wait for the next dictation and react as it arrives.

**Security**

- The server binds to 127.0.0.1 only and requires a token shown in the main window. Browsers can reach localhost, so cross-origin requests are locked down. Otherwise any website could read what you dictate.
- With history off, the API returns the latest item from memory only, and nothing persists to disk.
- Endpoint shape and token handling are documented on the developer docs pages.

## First run and website

Setup starts on the phone, because that is where people arrive from the App Store, and the website at sameer.us/macrophone does the SEO work of bringing people in.

**Phone-first guided setup**

1. A one-line pitch with a short looping demo.
2. Microphone and speech recognition permissions, each preceded by a plain-language screen explaining why.
3. "Get the Mac app": the URL shown large, plus a share button to send the link to yourself by AirDrop, Messages, or email.
4. "Looking for your Mac": the phone browses for a Mac running the app and moves on automatically when it finds one.
5. Scan the QR code on the Mac, with the confirmation code as the fallback. Camera access is requested only at this step.
6. A test dictation that confirms the whole path works.

Every step is skippable and resumable. The standalone fallback means a user who skips the Mac still gets a working dictation.

**Website at sameer.us/macrophone**

- **Launch requirements:** a landing page and developer docs.
- **Fast follows:** use-case pages over the first few weeks, one per search intent, such as "dictate to Claude Code from iPhone," "iPhone as a Mac microphone," and "voice to clipboard Mac."
- **Landing page:** a one-sentence headline, a short looping demo, the Mac download button, the App Store badge, a system requirements line, a privacy section ("no audio retained, no account, nothing leaves your devices"), and an FAQ.
- **Developer docs:** one page each for the local API, CLI, MCP server, Shortcuts, and profiles, with copyable examples and recipes such as "dictate into Claude Code" and "send every dictation to a webhook." Recipe pages double as use-case pages.
- **Technical SEO:** static or server-rendered pages, fast load times, a sitemap, descriptive titles and meta descriptions, social preview images, and `SoftwareApplication` and FAQ structured data.
- **Measurement:** privacy-friendly analytics on the website only, to see which pages bring people in. The apps themselves collect nothing.

## Platform, build, and distribution

Both apps are native Swift and SwiftUI on a shared Swift package, supporting roughly the last four years of iOS and macOS.

**Platform scope**

- **In scope:** iPhone sender and Mac receiver.
- **Out of scope for v1:** Apple Watch (first follow-up candidate), a dedicated iPad design, and any Windows or Linux receiver.
- **OS floor:** about the last four years of each OS, roughly iOS 17 and macOS 14 or later. The exact cutoff is confirmed against current shipping versions before it goes in the store listing.
- **iPad:** App Store Connect behavior for iPhone-only apps on iPad needs checking before deciding whether to allow installation in a compatibility layout.

**Architecture**

- **Shared Swift package:** message format, pairing and encryption, history store, dictionary logic, and cleanup instructions, so the two apps cannot drift apart.
- **Test tool first:** a small command-line target built on the package that pairs and exchanges messages. Pairing and delivery are the riskiest parts, and this proves them on home Wi-Fi, an office with client isolation, and a hotel network before any interface exists.
- **Targets:** iPhone app, Mac menu bar app, the CLI and MCP wrapper (a small Swift executable or a thin script over the local API), and the shared package.
- **Builder:** the user with Claude Code.

**Distribution**

- **iPhone:** App Store, with reviewer notes explaining the companion app and the standalone fallback.
- **Mac:** Developer ID signing and notarization, a stable "latest" download URL, a version history page, and in-app updates through an update framework such as Sparkle. A signed, notarized build works in the first milestone because this is painful to retrofit.
- **Cost:** the Apple Developer Program fee and website hosting. There is no per-use cost.

**Diagnostics and analytics**

- No analytics or crash reporting code in either app. Apple's built-in App Store Connect and Xcode Organizer data covers downloads, retention, and opted-in crash reports.
- A "Share diagnostics" button on the phone and the Mac exports a plain text log (app version, OS and device model, pairing steps, connection errors, delivery results). It never contains dictation text or the pairing secret, and the user can read it before sending.
- The App Store privacy label can read "Data Not Collected."

## Milestones, non-goals, and open items

The full v1 ships all at once, built in an order that proves the riskiest piece, pairing and delivery on real networks, before any interface work.

**Milestones (no dates set yet)**

1. **Protocol and pairing proof.** Shared Swift package, command-line test tool, QR and confirmation code pairing, encryption, Bonjour discovery, and peer-to-peer. *Gate:* reliable on home Wi-Fi, a client-isolated office network, and a hotel or guest network.
2. **Core loop.** iPhone mic screen, on-device transcription, Mac menu bar app with clipboard plus notification, Mac history, offline queue, and a signed, notarized Mac build with updates. *Gate:* a dictation travels end to end from a clean install on both devices.
3. **Cleanup and dictionary.** On-device model integration, the four cleanup levels with strict instructions, the 50-word dictionary, behavior on unsupported devices, language handling, and the messy-dictation test set. *Gate:* Medium does not change meaning on the test set.
4. **Popup and delivery modes.** The menu bar popup, auto-paste with Accessibility permission, clipboard restore, undo window, app allowlist, and secure field detection.
5. **Automations and pull API.** Profiles, paste then Enter, script, webhook, prompt templates, the local HTTP API, CLI, MCP server, and Shortcuts App Intents.
6. **Onboarding and polish.** Guided setup, the standalone fallback, diagnostics export, history on the phone, and the SameerOS visual style.
7. **Website and launch.** Landing page, developer docs, Mac download page, and App Store submission with reviewer notes.

**Non-goals for v1**

- Apple Watch, a dedicated iPad design, and Windows or Linux receivers.
- Accounts, cloud sync, in-app purchases, and license keys.
- Cleanup on devices without Apple's on-device model, and cleanup in languages other than English.
- A localized interface or website.
- Analytics or crash reporting inside the apps.

**Open items to verify before committing**

- Apple's trademark guidelines on using "Mac" in a product name, and App Store and domain availability for Macrophone.
- Exact device and OS requirements for Apple's on-device model, and the final OS floor.
- The on-device recognizer's real length limits and its list of languages that can run fully on-device.
- How App Store Connect handles iPhone-only apps on iPad.
- A SameerOS "Hey Claude" screenshot or recording as the visual reference for the phone and Mac popup.
- Target dates for each milestone.
