# Macrophone — local pull API, CLI and MCP (the contract)

The Mac app owns this. The CLI, the MCP server and the website's developer docs all follow it.
JSON shape of one item is `PulledDictation` in `Packages/MacrophoneKit/Sources/MacrophoneKit/Core/PullAPI.swift`.
Where dictations go (Send to: Clipboard, Where I'm typing, any open app, an automation) is
`docs/TARGETS.md`; the automations (tmux, snippets, templates, Obsidian/Notes/Reminders, Ask
Claude, script, webhook) are `docs/AUTOMATIONS.md`.

## One item

```json
{ "id": "6F1C…", "text": "Refactor the history store…", "raw": "um refactor the the history store…",
  "cleaned": "Refactor the history store…", "cleanup_level": "medium", "language": "en-US",
  "profile": "Claude", "created_at": "2026-10-12T20:41:03Z", "received_at": "2026-10-12T20:41:04Z",
  "delayed": false, "stopped_early": false, "source_device": "Sameer's iPhone", "reply": null }
```

Every key is always present. `cleaned`, `profile` and `reply` are `null` when absent.

- `text` is what the phone delivered (cleaned when there is one, else raw). Snippets, the output
  format and the template are **not** applied here — that's what went to the app/pane.
- `profile` is where it went on the Mac: the automation's name ("Daily log"), or the Send to target
  ("Claude", "Terminal — claude", "Where I'm typing", "Clipboard"). The key keeps its old name.
- `reply` is Claude's answer when the automation has an **Ask Claude** action (the person's own API
  key). It is `null` until the reply has finished streaming, and for every other dictation. An
  item first appears (`/v1/next`, `/v1/stream`) as soon as the dictation arrives, with
  `reply: null`; read `/v1/latest` or `/v1/history` afterwards to get the reply. With history off,
  the reply is held in memory with the latest item only.

## HTTP API

- Listens on **127.0.0.1:47820 only** (`Product.apiPort`). If the port is taken, the next free
  port up to 47829; the chosen port is written to the config file.
- **Token:** `Authorization: Bearer mp_…`. Shown (and regenerable) in the Mac app's main window
  under Developer. Also written to `~/Library/Application Support/Macrophone/api.json`
  (`{"port":47820,"token":"mp_…"}`, mode 0600) so the CLI/MCP read it automatically.
- **Browser lockdown:** any request carrying an `Origin` header (or `Sec-Fetch-Site`) is refused
  with 403; the `Host` header must be `127.0.0.1:<port>` or `localhost:<port>` (blocks DNS
  rebinding); no CORS headers are ever sent; `OPTIONS` → 403. So no website can read dictations.
- **On by default** (token-protected, localhost-only); Settings › Developer can turn it off. The CLI says so when it can't connect.
- With history off, endpoints return the latest item held in memory only; nothing hits disk.

| Method & path | Returns |
| --- | --- |
| `GET /v1/latest` | `200` one item, or `204` if nothing yet |
| `GET /v1/history?limit=N` | `200 {"items":[…]}`, newest first, N 1–50 (default 10) |
| `GET /v1/next?timeout=S&after=<id>` | Long-poll: `200` the next dictation that arrives after the request (or, with `after`, any item newer than that id, immediately), `204` on timeout. S 1–300, default 60 |
| `GET /v1/stream` | `text/event-stream`: `event: dictation` + `data: {item}` per arrival; `: keep-alive` comment every 15 s |
| `GET /v1/status` | `200 {"app_version","api_version":1,"history_enabled","phones":[{"name","connected","last_seen"}]}` |

Errors are JSON `{"error":"…"}`: 401 missing/wrong token, 403 browser request, 404 unknown path,
405 wrong method.

## CLI — `macrophone` (alias `mp`)

Bundled inside the app (`Macrophone.app/Contents/Helpers/macrophone`). Settings › Developer ›
"Install command-line tool" symlinks `/usr/local/bin/macrophone` and `/usr/local/bin/mp`
(asks for an admin password once). Thin wrapper over the HTTP API.

```
mp                     # same as `mp latest`
mp latest [--raw] [--json]       # print the latest dictation's text (raw transcript with --raw)
mp list [-n 10] [--json]
mp wait [--timeout 60] [--json]  # block until the next dictation, print it; exit 1 on timeout
mp watch [--json]                # print every new dictation as it arrives, one per line (JSON lines with --json)
mp status
mp mcp                           # run the MCP server on stdio
mp --version | --help
```

Exit codes: 0 ok, 1 nothing/timeout, 2 usage, 3 Mac app not running or API off, 4 auth failed.
Output is plain text with a trailing newline, safe to pipe (`mp wait | pbcopy`, `$(mp)`).

## MCP server — `macrophone mcp`

JSON-RPC 2.0 over stdio, MCP protocol `2025-06-18` (accept older client versions). Tools:

| Tool | Input | Output |
| --- | --- | --- |
| `get_latest_dictation` | `{ "raw"?: bool }` | the latest dictation's text, plus metadata as structured content |
| `list_dictations` | `{ "limit"?: 1–50 }` | recent dictations, newest first |
| `wait_for_dictation` | `{ "timeout_seconds"?: 1–300 }` | the next dictation's text, or "No dictation arrived in N seconds." |

Install in Claude Code: `claude mcp add macrophone -- macrophone mcp`.
Claude Desktop: `{"mcpServers":{"macrophone":{"command":"/usr/local/bin/macrophone","args":["mcp"]}}}`.

## Webhook body (POST, `Content-Type: application/json`)

```json
{ "id": "…", "text": "…(template applied)…", "raw": "…", "cleaned": "…", "profile": "Daily log",
  "created_at": "2026-10-12T20:41:03Z", "language": "en-US", "source_device": "Sameer's iPhone",
  "delayed": false }
```
`text` here is the final text (snippets, output format and template applied). Header
`User-Agent: Macrophone/<version>`. 10 s timeout, one retry after 3 s.

## Script

`/bin/zsh -lc "<command>"` with the text (snippets, format and template applied) on stdin, and env vars
`MACROPHONE_TEXT`, `MACROPHONE_RAW`, `MACROPHONE_PROFILE` (the automation's name), `MACROPHONE_ID`. 30 s timeout;
non-zero exit shows the error state in the popup with the first line of stderr.

## MCP and CLI and the reply

`mp latest --json`, `mp list --json`, `mp wait --json` and the MCP tools' structured content carry
the same item, so `reply` is there too (`null` when there isn't one). Plain-text output is unchanged
(the dictation's text).

## Debug-only hooks (Mac DEBUG builds)

A Debug build listens for the distributed notification `com.sameer.macrophone.debug.dictate` with
`object` = JSON `{"text": "…", "target"?: "clipboard|front|<bundle id>", "window"?: "<window key>",
"send"?: bool, "automation"?: "<name>", "delayed"?: bool}` and runs it through exactly the path a
phone dictation takes (no target = this Mac's Send to choice). `com.sameer.macrophone.debug.openMenu`
opens the menu bar menu. More in docs/TARGETS.md › Debug hooks. Release builds have none of these.
