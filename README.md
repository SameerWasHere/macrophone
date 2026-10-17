# Macrophone

**Steer your Mac from your iPhone. Your agents never wait on you again.**

Macrophone is a free, open-source iPhone app and Mac menu bar app for people who leave their Mac
running agents — a Mac mini on a shelf, a MacBook docked with its lid shut — and want to keep them
moving from anywhere in the house. It works with every agent and every app: Claude Code, Codex,
Gemini CLI or anything in a terminal; Cursor and Windsurf; the Claude and ChatGPT apps; Messages,
Notes, Mail — any app on your Mac with somewhere to type.

- **See it.** Any app's window, live on your iPhone, starting on the part you type in.
- **Steer it.** A tap is a click there on the Mac; a swipe scrolls it right where your finger is;
  Esc, ↑, ↓ and Return move through an agent's question, approve it, or stop it. Open any app.
- **Say it.** Speak your next prompt; it's transcribed and cleaned up on the iPhone, pasted into
  the app and sent.

Website and downloads: **[sameer.us/macrophone](https://sameer.us/macrophone)** · who it's for and
why: [`docs/POSITIONING.md`](docs/POSITIONING.md)

Install the Mac app with [Homebrew](https://brew.sh):

```
brew install --cask sameerwashere/macrophone/macrophone
```

<p align="center">
  <img src="https://sameer.us/macrophone/img/iphone-watch-demo-poster.webp" width="300" alt="Macrophone on iPhone: a Terminal window running Claude Code, live, asking to make an edit, with Esc, up, down and Return keys under it">
</p>

## Private by design

- Speech is transcribed **on the iPhone** (Apple's SpeechAnalyzer on iOS 26+, on-device
  SFSpeechRecognizer before that) and cleaned up by Apple's **on-device** language model.
  No audio is ever kept.
- The phone talks **directly to your Mac** over the local network (Bonjour, peer-to-peer Wi-Fi
  when nearby). There's no server and no account.
- Everything on the wire is end-to-end encrypted: pairing by QR code or a six-digit code creates a
  shared key (X25519 + HKDF); every session uses ChaCha20-Poly1305 with per-direction keys.
- The window view captures **only the one window you picked**, only while you look, and never
  saves it. Neither app has analytics. The App Store label is "Data Not Collected".

## What's in the repo

| Path | What |
| --- | --- |
| `Packages/MacrophoneKit` | Shared Swift package: the wire format, pairing and encryption, the Bonjour transport (`LinkServer` on the Mac, `LinkClient` on the phone), history, on-device cleanup. `mpctl` is a command-line stand-in for either side. |
| `iOS/` | The iPhone app (SwiftUI) and its Control Center / Lock Screen controls. |
| `Mac/` | The menu bar app: finding apps with somewhere to type, pasting and sending, the window view (ScreenCaptureKit), a local API, the `mp` CLI and an MCP server. |
| `docs/` | Design notes: `TARGETS.md` (Send to, watching, opening apps), `API.md`, `CLEANUP.md`, `DESIGN.md`, `RELEASING.md`. |

## Building

You need Xcode 26 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`). Both projects are generated; set your own team in `project.yml`
(`DEVELOPMENT_TEAM`) first.

```sh
# The shared package and its tests
cd Packages/MacrophoneKit && swift test

# The Mac app (a Debug build is "Macrophone Debug", separate from an installed copy)
cd Mac && xcodegen generate && open Macrophone.xcodeproj

# The iPhone app
cd iOS && xcodegen generate && open Macrophone.xcodeproj
```

Try the protocol without either app: `swift run mpctl serve --auto-approve` plays the Mac (it
answers a watch with a drawn demo window), and `mpctl pair '<url>'`, `mpctl send "hello"`,
`mpctl watch`, `mpctl apps` play the phone.

Requirements: iPhone with iOS 17+ (cleanup needs an Apple Intelligence iPhone on iOS 26+), Mac
with macOS 14+. The Mac app needs Accessibility (to paste, click and press keys) and Screen
Recording (only for the window view).

## License

MIT — see [LICENSE](LICENSE). App names belong to their owners; Macrophone isn't affiliated with
or endorsed by them.
