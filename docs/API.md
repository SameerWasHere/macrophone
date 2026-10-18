# Macrophone — local API, CLI and MCP (the contract)

The Mac app owns this. The `mp` command, the MCP server and the website's developer docs all
follow it. Where dictations go on the Mac (Send to: Clipboard, Where I'm typing, any open app) is
`docs/TARGETS.md`; this page is only about reading them from scripts and agents.

Three ways in, all on this Mac only:

| | Use it for |
| --- | --- |
| **HTTP** — `127.0.0.1:47820` | anything that can make a request |
| **CLI** — `mp` (`macrophone`) | shell scripts, `$(mp)`, `mp wait \| pbcopy` |
| **MCP** — `macrophone mcp` | Claude Code, Claude Desktop and other agents |

## One dictation

```json
{
  "id": "6F1C2A1E-0B7D-4C1A-9E55-2D3A4B5C6D7E",
  "text": "Refactor the history store so it trims to fifty items on write.",
  "raw": "um refactor the the history store so it trims to fifty items on write",
  "cleaned": "Refactor the history store so it trims to fifty items on write.",
  "cleanup_level": "medium",
  "language": "en-US",
  "profile": "Claude",
  "created_at": "2026-10-12T20:41:03Z",
  "received_at": "2026-10-12T20:41:04Z",
  "delayed": false,
  "stopped_early": false,
  "source_device": "Sameer's iPhone"
}
```

Every key is always present; `cleaned` and `profile` are `null` when absent.

| Key | Meaning |
| --- | --- |
| `id` | UUID. Stable: a resend from the phone is never a second item. |
| `text` | What was delivered — the cleaned text when there is one, else `raw`. |
| `raw` | Exactly what the iPhone's recognizer heard. |
| `cleaned` | The cleaned-up text, or `null` when cleanup was off or unavailable. |
| `cleanup_level` | Chosen on the iPhone: `off`, `light`, `medium`, `heavy` or `custom` (the person's own instructions). |
| `language` | BCP-47, e.g. `en-US`. |
| `profile` | Where it went on the Mac: an app or window (`"Claude"`, `"Terminal — claude ~/app"`), `"Where I'm typing"` or `"Clipboard"`. |
| `created_at` / `received_at` | ISO 8601, UTC. When it was spoken; when the Mac got it. |
| `delayed` | It waited in the phone's queue while the Mac was away (it was only copied, never pasted). |
| `stopped_early` | Recording was interrupted (a call, the lock button); what was heard was still sent. |
| `source_device` | The iPhone's name (a name given on the Mac wins). |

## HTTP

- Listens on **127.0.0.1:47820 only**. If that port is taken, the next free one up to 47829; the
  port in use is in the config file.
- **Token:** every request needs `Authorization: Bearer mp_…`. It's shown, copied and regenerated
  in Macrophone › Developer, and written to
  `~/Library/Application Support/Macrophone/api.json` (`{"port":47820,"token":"mp_…"}`, readable
  only by you), where the CLI and MCP server read it.
- **No browsers:** a request with an `Origin` or `Sec-Fetch-*` header gets 403; the `Host` header
  must be `127.0.0.1:<port>` or `localhost:<port>` (no DNS rebinding); `OPTIONS` gets 403; no CORS
  headers are ever sent. No web page can read what you dictate.
- **On by default** (localhost and token only). Macrophone › Developer turns it off.
- With **History** off, nothing is written to disk and the API answers with the latest dictation
  held in memory only.

| Request | Answer |
| --- | --- |
| `GET /v1/latest` | `200` one dictation, or `204` if there's none yet |
| `GET /v1/history?limit=N` | `200 {"items":[…]}`, newest first. N is 1–50, default 10 |
| `GET /v1/next?timeout=S` | Waits for the next dictation to arrive and answers `200` with it, or `204` after S seconds (1–300, default 60) |
| `GET /v1/status` | `200 {"app_version":"1.0.0","api_version":1,"history_enabled":true,"phones":[{"name":"Sameer's iPhone","connected":true,"last_seen":"…"}]}` |

| `POST /v1/agent` | An agent's event (what `mp hook` sends): `{"agent":"claude","event":"PermissionRequest","session":"…","cwd":"…","tool":"Bash","toolDetail":"git push","pids":[…]}`. `204`. The phone's alert (and the Answered you mark in Send to) follow. |

**Agents (Oct 17 2026).** Macrophone › Agents › Connect adds `…/Macrophone.app/Contents/Helpers/macrophone hook claude` to Claude Code's hooks in `~/.claude/settings.json` (SessionStart, UserPromptSubmit, PermissionRequest, Notification, PostToolUse, Stop, SessionEnd) or sets Codex's `notify` in `~/.codex/config.toml` (never over one you set). The first change backs the file up beside it (`.macrophone-backup`); Disconnect takes out exactly what it added. The hook prints nothing, always exits 0 and gives up after 1.5 s.

Errors are JSON `{"error":"…"}`: `401` missing or wrong token, `403` a browser request or a wrong
`Host`, `404` unknown path, `405` anything but `GET`.

```sh
TOKEN=$(plutil -extract token raw ~/Library/Application\ Support/Macrophone/api.json)
curl -s -H "Authorization: Bearer $TOKEN" http://127.0.0.1:47820/v1/latest
curl -s -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:47820/v1/next?timeout=120"
```

## CLI — `mp`

Inside the app at `Macrophone.app/Contents/Helpers/macrophone`. Macrophone › Developer ›
**Install** links it as `/usr/local/bin/macrophone` and `/usr/local/bin/mp` (asks for your
password once).

```
mp latest [--json]                the latest dictation (also just `mp`)
mp wait [--timeout 60] [--json]   wait for the next dictation and print it (1–300 s)
mp list [-n 10] [--json]          recent dictations, newest first (1–50)
mp status                         is Macrophone running, which iPhones are connected
mp mcp                            run the MCP server on stdio
mp --version | --help
```

Plain output is the dictation's text with a trailing newline, safe to pipe (`mp wait | pbcopy`,
`git commit -m "$(mp)"`). `mp list` prints one per line with its time. `--json` prints the API's
JSON on one line (a dictation, or `{"items":[…]}` for `list`).

Exit codes: `0` ok · `1` nothing yet / timed out · `2` usage · `3` Macrophone isn't running or the
API is off · `4` token rejected.

## MCP — `macrophone mcp`

JSON-RPC 2.0 over stdio, MCP protocol `2025-06-18` (older client versions accepted). Two tools,
both read-only:

| Tool | Input | Returns |
| --- | --- | --- |
| `get_latest_dictation` | none | The latest dictation's text; the whole dictation (above) as structured content. "No dictation yet." when there's none. |
| `wait_for_dictation` | `{ "timeout_seconds"?: 1–300 }` (default 60) | The next dictation's text once it arrives, with the dictation as structured content; "No dictation arrived in N seconds." on timeout. |

Claude Code:

```sh
claude mcp add macrophone -- macrophone mcp
```

Claude Desktop (`claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "macrophone": {
      "command": "/usr/local/bin/macrophone",
      "args": ["mcp"]
    }
  }
}
```

## Debug-only hooks (Mac DEBUG builds)

A Debug build listens for the distributed notification `com.sameer.macrophone.debug.dictate` with
`object` = JSON `{"text": "…", "target"?: "clipboard|front|<bundle id>", "window"?: "<window key>",
"send"?: bool, "delayed"?: bool, "level"?: "off|light|medium|heavy|custom"}` and runs it through
exactly the path a phone dictation takes (no target = this Mac's Send to choice).
`com.sameer.macrophone.debug.openMenu` opens the menu bar menu. More in docs/TARGETS.md › Debug
hooks. Release builds have none of these.
