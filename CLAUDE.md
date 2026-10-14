# Macrophone

Free iPhone app + companion Mac app: dictate on the phone, pick any app open on the Mac (or the
clipboard, or wherever you're typing), and the text is pasted there — or pasted and sent — at the
cleanup level you choose (Off · Light · Medium · Heavy · Custom). Agents can pull dictations through
a small local API / CLI / MCP. Simplified to that core on Oct 13 2026 (automations, snippets,
templates and the Delivery pane were removed on purpose — don't bring them back unasked).
The original spec is `docs/SPEC.md`. Push to `main`.

## Layout

| Path | What |
| --- | --- |
| `Packages/MacrophoneKit` | Shared Swift package: wire format, pairing + encryption, Bonjour/peer-to-peer transport (`LinkServer` Mac side, `LinkClient` phone side), history store, diagnostics log, on-device cleanup (`Cleaner`, `CleanupPrompts`, `CleanupGuard`), pull-API item shape. `mpctl` is the command-line protocol proof. |
| `iOS/` | iPhone app (XcodeGen `iOS/project.yml`) + Control Center / Lock Screen control extension |
| `Mac/` | Menu bar app (XcodeGen `Mac/project.yml`): Send to (live targets, paste and send), History, Devices, Developer, General; the `macrophone`/`mp` CLI + MCP server; Sparkle updates, `scripts/release.sh` |
| `docs/` | `TARGETS.md` (Send to and delivery), `API.md` (the local API / CLI / MCP contract), `DESIGN.md`, `CLEANUP.md`, `RELEASING.md`, `APP_STORE.md`, `NAME_CHECK.md` |

The website lives in the sameer.us repo (`sameer-gpt`), static pages under `public/macrophone/`.

## The protocol in one breath

Mac advertises `_macrophone._tcp` (peer-to-peer on). Pairing: QR carries a one-time token + the
Mac's X25519 key (phone proves it scanned it with an HMAC), or a six-digit code both screens show
(commit → key → reveal, approved on the Mac, 5 tries / 10 min). Both store a 32-byte pair key
(Keychain). Every connection: nonce handshake with HMAC proofs both ways → per-direction
ChaCha20-Poly1305 keys with counter nonces. Dictations carry a UUID; the Mac de-duplicates.

## Checks

```
cd Packages/MacrophoneKit && swift test
swift build && .build/debug/mpctl serve --auto-approve   # then mpctl pair '<url>' / pair-code / send
.build/debug/mpctl cleanup-eval                           # cleanup test set on the real on-device model
```

## Rules

- Never upload to App Store Connect / TestFlight unless Sameer explicitly asks to submit.
- The apps collect nothing. Diagnostics never contain dictation text or keys.
- Primary users are developers dictating long prompts; when in doubt, optimize for them.
- Testing on Sameer's Mac (he uses it while you work): stop only processes you started, by PID
  or exact path. Never `pkill -f`/`killall` with a short pattern — on Oct 13 2026
  `pkill -f "cat"` matched "/Applications" and closed every app he had open. Never auto-send
  into Messages, Mail, Slack, Muse or anything that reaches a person.
