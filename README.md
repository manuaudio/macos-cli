<h1 align="center">🖥️ macOS CLI</h1>

<p align="center">
  <b>Drive your entire Mac from the command line — and hand that same power to your AI agent.</b>
</p>

<p align="center">
  Calendar · Contacts · Mail · Messages · Notes · Reminders · Photos · Music · Safari ·
  screenshots · OCR · windows · mouse &amp; keyboard · the Accessibility tree · and 40+ more.<br>
  One native Swift binary. Every command speaks <code>--json</code>.
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-yellow.svg" alt="License: MIT"></a>
  <a href="#install"><img src="https://img.shields.io/badge/macOS-13%2B-black?logo=apple&logoColor=white" alt="macOS 13+"></a>
  <a href="https://swift.org"><img src="https://img.shields.io/badge/Swift-5.9%2B-F05138?logo=swift&logoColor=white" alt="Swift 5.9+"></a>
  <a href="https://github.com/manuaudio/macos-cli/releases"><img src="https://img.shields.io/badge/release-v0.8.1-blue" alt="Release"></a>
  <a href="#-use-it-with-ai-agents"><img src="https://img.shields.io/badge/agent--ready-JSON-8A2BE2?logo=anthropic&logoColor=white" alt="Agent-ready JSON"></a>
  <img src="https://img.shields.io/badge/runtime_deps-0-brightgreen" alt="Zero runtime deps">
</p>

<p align="center">
  Zero runtime deps · no Python, no Node · just a ~7&nbsp;MB binary
</p>

---

```bash
macos calendar events --json          # what's on today
macos mail search "invoice" --json    # find that email
macos ocr screen                      # read everything on screen as text
macos ax click "Sign In"              # click a button by its name — no coordinates
```

## Why you'll want this

macOS hides its best features behind GUI apps and brittle AppleScript. **macOS CLI turns all of it into clean, scriptable commands that print JSON** — so you can wire your Mac into shell scripts, automations, and especially LLM agents.

- 🤖 **Built for AI agents.** Point Claude, Ollama, or any tool-calling model at it and your assistant can read your calendar, triage your inbox, move windows, and click buttons *by name*.
- 🪶 **One tiny binary.** Native Swift, ~7 MB, zero runtime dependencies. No interpreter, no `node_modules`, no glue code.
- 🧩 **40+ capabilities, one grammar.** Every command follows `macos <area> <action>` and every command takes `--json`.
- 🔒 **Local & private.** It talks to your Mac's own frameworks. Nothing leaves your machine.

## Install

```bash
curl -sSL https://raw.githubusercontent.com/manuaudio/macos-cli/main/install.sh | bash
```

Builds from source and installs exactly **one** binary — `macos` — to `$HOME/.local/bin/macos`. No sudo, no background service, no second executable. ~30 seconds.

Install somewhere else on your `PATH`:

```bash
MACOS_CLI_INSTALL_DIR="$HOME/bin" ./install.sh
```

The installer does **not** grant any macOS privacy permission for you — it prints guidance and leaves you in control (see [Permissions](#permissions)).

> **Requirements:** macOS 13 (Ventura)+ and Swift 5.9+ (ships with Xcode Command Line Tools).
> No CLT yet? `xcode-select --install`, then re-run the command above.
> Make sure `$HOME/.local/bin` is on your `PATH` (the installer reminds you if it isn't).

```bash
macos --version   # 0.8.1
macos setup       # checks every permission — a green ✓ per capability
```

## What it can do

| | Area | Examples |
|---|---|---|
| 📅 | **Calendar** | list, rich JSON export, create (custom alarms), update, delete (by id or title) across all linked calendars |
| ✅ | **Reminders** | create, complete, list by list, due dates |
| 👤 | **Contacts** | search, read, create, update — by name, email, or phone |
| 💬 | **Messages** | send iMessage/SMS, read threads, search |
| ✉️ | **Mail** | search, read, draft, send, reply, manage mailboxes |
| 📝 | **Notes** | read, create, search Apple Notes |
| 🎵 | **Music** | now playing, play/pause, skip, library queries |
| 🌐 | **Safari** | read the current tab, list tabs, open URLs |
| 📸 | **Screen** | full/window/region screenshots, screen recording check |
| 🔤 | **OCR** | extract text from the screen, a region, or any image |
| 🪟 | **Windows** | list, move, resize, focus app windows |
| 🖱️ | **Input** | type text, send shortcuts, move & click the mouse |
| ♿ | **Accessibility** | find & click UI elements *by name*, dump the UI tree |
| 🔋 | **System** | battery, focus modes, processes, disks, defaults, network |
| 🔑 | **Keychain** | read/write passwords and secrets (with your approval) |
| 📄 | **Files & PDF** | search files, read metadata, extract PDF text |

…and more. Run `macos --help` for the full list, or `macos <area> --help` for any area.

## Quick taste

```bash
# Calendar & reminders
macos calendar events --json
macos reminders create --title "Call the bank" --due "tomorrow 9am"

# Find a contact, then text them
macos contacts search "Ryan" --json
macos messages send --to "+13105550100" --text "On my way"

# See your screen — literally
macos screenshot --out ~/shot.png
macos ocr screen                       # everything on screen → plain text

# Read the web page you're looking at
macos safari current-tab --json

# Drive the UI like a human (Accessibility)
macos ax find "Sign In"                # locate it
macos ax click "Sign In"               # click it — by label, no pixel coordinates
macos keyboard type "hello world"
```

Every command supports `--json` for clean, parseable output:

```bash
macos battery --json
# {"level": 87, "charging": false, "plugged_in": true}
```

## 🤖 Use it with AI agents

macOS CLI is **one binary and nothing else** — no MCP server, no HTTP bridge, no daemon. An agent drives it exactly the way you do: it runs `macos <area> <action> --json` as a subprocess and parses the result. That is the whole integration. Point your agent framework's shell/exec tool at `$HOME/.local/bin/macos` and it can read your calendar, triage your inbox, move windows, and click buttons by name.

```bash
# Whatever your agent can shell out to, it can call:
"$HOME/.local/bin/macos" reminders export --json
"$HOME/.local/bin/macos" calendar events --json
```

### Agent-safe surfaces (0.8.0)

These commands are built for unattended, read-mostly automation — stable JSON, fail-closed filters, and a machine-readable error contract:

| Command | What it guarantees |
|---|---|
| `macos reminders status --json` | Reports the Reminders authorization state **without prompting** — safe to poll. |
| `macos reminders export --json` | Rich read-only export. `--list NAME` is **fail-closed**: an unknown list yields zero rows, never all of them. |
| `macos reminders export --timeout N` | A fetch timeout is a **hard error** — prints `{"status":"error","error":"fetch_timeout",…}` on stdout and exits `1`, so a hang can never be mistaken for "zero reminders." |
| `macos reminders complete --id ID` | The **only** way to complete a reminder. Defaults to a **dry run**; it writes only when `--approve` exactly matches a non-empty `APPLE_EVENTKIT_APPROVE_TOKEN` environment variable. `complete-safe` is a kept alias. |
| `macos calendar export --json` | Rich read-only export as a single envelope `{ok,status,count,filter,calendars,events}`. Enumerates **all linked calendars from all sources** by default; `--calendar NAME` is **fail-closed** (unknown name ⇒ zero events *and* zero calendars, never all). `--from`/`--to` validate `from ≤ to` and emit a structured `invalid_date_range`/`invalid_date` error + exit `1` on bad input. |
| `macos calendar delete --id ID` | Deletes exactly one event by stable identifier (`EKSpanThisEvent`). `--id` and `--title`/`--date` are **mutually exclusive**; a missing id prints `{"error":"event_not_found",…,"deleted":false}` and exits `1`. Result carries only `id` + `deleted` — no private event content. |
| `macos notes export --json` | Read-only Notes export straight from the local store (Unicode-preserving), with a fail-closed `--folder` filter. |

The old `reminders done` command is **retired** — it was an ungated write. It now performs no writes and prints a one-line pointer to `reminders complete`.

Example — let an agent complete a reminder only after you've set the approval token in its environment:

```bash
export APPLE_EVENTKIT_APPROVE_TOKEN="$(openssl rand -hex 16)"   # you set this, once
macos reminders complete --id "$ID"                 # dry run — no token passed, nothing changes
macos reminders complete --id "$ID" --approve "$APPLE_EVENTKIT_APPROVE_TOKEN"   # writes
```

### Calendar JSON contract

Two read shapes, chosen for compatibility:

- **`calendar events --json`** returns a bare **array** (unchanged since 0.7.0). Every element still carries the six stable keys `id`, `title`, `calendar`, `start`, `end`, `all_day`; richer fields (`source`, `location`, `notes`, `url`, `timezone`, `created`, `last_modified`, `status`, `availability`, `recurring`, `organizer`, `attendees`, `alarms`) are **additive** and appear only when the event has them.
- **`calendar export --json`** wraps those same event objects in the ingestion **envelope** (this is the shape to prefer for sync):

```jsonc
// macos calendar export --from 2026-07-01 --to 2026-07-31 --json   (fake data)
{
  "ok": true,
  "status": "ok",
  "count": 1,
  "filter": null,                       // echoes --calendar, or null when unfiltered
  "calendars": ["Home", "Work", "Gigs"],// exactly the resolved (never broadened) set
  "events": [
    {
      "id": "F1A2B3C4-0000-0000-0000-000000000001",
      "title": "Load-in",
      "calendar": "Gigs",
      "source": "iCloud",
      "start": "2026-07-20T22:00:00Z",
      "end": "2026-07-21T01:00:00Z",
      "all_day": false,
      "recurring": false,
      "location": "The Example Room",
      "timezone": "America/Los_Angeles",
      "last_modified": "2026-07-10T18:04:00Z",
      "status": "confirmed",
      "availability": "busy",
      "attendees": ["Stage Manager", "promoter@example.com"],
      "alarms": [1440, 60]
    }
  ]
}
```

Dates are ISO8601 UTC. `--from` is inclusive, `--to` is the exclusive upper bound; both default to a bounded ±1-year window and accept explicit multi-year ranges (a single EventKit query spans at most ~4 years — chunk beyond that). An unknown `--calendar` returns a valid envelope with `count: 0` and `calendars: []` — never all.

**Create with custom alarms** (each `--alarm` is minutes-before; repeatable; overrides the default 1-day + 1-hour alerts; the result echoes the minute list, never notes):

```jsonc
// macos calendar create --title "Soundcheck" --start "2026-07-20 16:00" \
//     --alarm 120 --alarm 30 --json   (fake data)
{ "id": "…", "title": "Soundcheck", "calendar": "Gigs",
  "start": "…", "end": "…", "all_day": false, "alarms": [120, 30] }
```

### Contacts JSON contract (0.8.1)

Both `macos contacts get <id> --json` and `macos contacts export` now carry a **`job_title`** field. It is a **string that is always present** — the contact's title, or an **empty string `""`** when the contact has no title. It is **never `null`** and never omitted, matching the export convention so an ingestion consumer sees one stable shape. Every pre-0.8.1 key (`id`, `name`, `organization`, `phones`, `emails`, and the rich export fields) is unchanged — `job_title` is purely additive.

Because the field reads back exactly as written, an agent can do a **verified read-after-write** around `contacts update --job-title`:

```bash
macos contacts update --id "$ID" --job-title "Tour Manager"   # write
macos contacts get "$ID" --json | jq -r .job_title            # → "Tour Manager"
```

The written value appears verbatim in the very next `get`/`export`, so the write can be confirmed rather than assumed.

## Permissions

macOS gates these capabilities behind privacy permissions — by design. On first use you'll be prompted to grant **Automation**, **Calendars**, **Contacts**, **Accessibility**, **Screen Recording**, etc. Run `macos setup` any time to see exactly what's granted and what's missing. Nothing is bypassed; you stay in control.

## Build from source

```bash
git clone https://github.com/manuaudio/macos-cli
cd macos-cli
swift build -c release
cp .build/release/macos /usr/local/bin/
```

## Contributing

Issues and PRs welcome. The codebase is plain Swift + [swift-argument-parser](https://github.com/apple/swift-argument-parser) — one command per file under `Sources/macos-cli/Commands/`.

## License

MIT © [manuaudio](https://github.com/manuaudio) — see [LICENSE](LICENSE).
