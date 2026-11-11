<h1 align="center">🖥️ macOS CLI</h1>

<p align="center">
  <b>Drive your entire Mac from the command line — and hand that same power to your AI agent.</b>
</p>

<p align="center">
  Calendar · Contacts · Mail · Messages · Notes · Reminders · Photos · Music · Safari ·
  screenshots · OCR · windows · mouse &amp; keyboard · the Accessibility tree · and 40+ more.<br>
  One native Swift binary. Every command that returns data speaks <code>--json</code>.
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-yellow.svg" alt="License: MIT"></a>
  <a href="#install"><img src="https://img.shields.io/badge/macOS-13%2B-black?logo=apple&logoColor=white" alt="macOS 13+"></a>
  <a href="https://swift.org"><img src="https://img.shields.io/badge/Swift-5.9%2B-F05138?logo=swift&logoColor=white" alt="Swift 5.9+"></a>
  <a href="#-use-it-with-ai-agents"><img src="https://img.shields.io/badge/agent--ready-JSON-8A2BE2?logo=anthropic&logoColor=white" alt="Agent-ready JSON"></a>
  <img src="https://img.shields.io/badge/runtime_deps-0-brightgreen" alt="Zero runtime deps">
  <a href="https://github.com/manuaudio/macos-cli/releases"><img src="https://img.shields.io/badge/version-0.8.1-blue" alt="Version 0.8.1"></a>
</p>

<p align="center">
  Zero runtime deps · no Python, no Node · just a ~7&nbsp;MB binary
</p>

---

```bash
macos calendar events --json          # what's on today
macos mail search "invoice" --json    # find that email
macos ocr full                        # read everything on screen as text
macos ax click "Sign In"              # click a button by its name — no coordinates
```

## Why you'll want this

macOS hides its best features behind GUI apps and brittle AppleScript. **macOS CLI turns all of it into clean, scriptable commands that print JSON** — so you can wire your Mac into shell scripts, automations, and especially LLM agents.

- 🤖 **Built for AI agents.** Point Claude, Ollama, or any tool-calling model at it and your assistant can read your calendar, triage your inbox, move windows, and click buttons *by name*.
- 🪶 **One tiny binary.** Native Swift, ~7 MB, zero runtime dependencies. No interpreter, no `node_modules`, no glue code.
- 🧩 **40+ capabilities, one grammar.** Every command follows `macos <area> <action>`; every command that returns data takes `--json`, and under `--json` every failure is JSON too.
- 🔒 **Local & private.** It talks to your Mac's own frameworks. Nothing leaves your machine.

## Install

```bash
brew install manuaudio/tap/macos-cli
```

Homebrew installs the [Release](https://github.com/manuaudio/macos-cli/releases): a single `macos` binary for Apple silicon, signed with a Developer ID and notarized by Apple. `brew upgrade macos-cli` updates it, and the permissions you granted stay, because every release carries the same signature. Type the full name: Homebrew refuses a short `brew install macos-cli` from a tap you have not trusted.

No Homebrew:

```bash
curl -fsSL https://raw.githubusercontent.com/manuaudio/macos-cli/main/install.sh | bash
```

The same signed, notarized binary, without Homebrew: the script checks its sha256, Developer ID signature, team and version, and installs it to `$HOME/.local/bin/macos`. No Xcode, no sudo, no background service, no second executable.

Update the curl install in place, at the same path, so the permissions you granted stay with it (`--check` only reports):

```bash
macos update
```

Install somewhere else on your `PATH`:

```bash
curl -fsSL https://raw.githubusercontent.com/manuaudio/macos-cli/main/install.sh | MACOS_CLI_INSTALL_DIR="$HOME/bin" bash
```

Build from source instead with `MACOS_CLI_SIGN_MODE=adhoc ./install.sh` (needs Xcode Command Line Tools and Swift 5.9+), or with your own certificate by setting `MACOS_CLI_SIGN_IDENTITY`. An ad-hoc build has one catch: macOS ties privacy grants to the signature, so it asks again for Calendars, Contacts and the rest after every rebuild. [docs/SIGNING.md](docs/SIGNING.md) has the details.

The installer does **not** grant any macOS privacy permission for you — it prints guidance and leaves you in control (see [Permissions](#permissions)).

> **Requirements:** macOS 13 (Ventura)+ on Apple silicon.
> Make sure `$HOME/.local/bin` is on your `PATH` (the installer reminds you if it isn't).

```bash
macos --version
macos doctor      # every macOS permission, its state, and how to get it (never prompts)
macos setup       # checks every capability end to end — a green ✓ per capability
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
macos reminders create --title "Call the bank" --due "2026-07-21 09:00"

# Find a contact, then text them
macos contacts search "Ryan" --json
macos messages send --to "+13105550100" --text "On my way"

# See your screen — literally
macos screenshot full --output ~/shot.png
macos ocr full                         # everything on screen → plain text

# Read the web page you're looking at
macos safari read --json

# Drive the UI like a human (Accessibility)
macos ax find "Sign In"                # locate it
macos ax click "Sign In"               # click it — by label, no pixel coordinates
macos keyboard type "hello world"
```

Commands that return data take `--json` for clean, parseable output:

```bash
macos system battery --json
# {"charging": false, "level": 87, "plugged_in": true, "time_remaining_minutes": 13}
```

## 🤖 Use it with AI agents

macOS CLI is **one binary and nothing else** — no MCP server, no HTTP bridge, no daemon. An agent drives it exactly the way you do: it runs `macos <area> <action> --json` as a subprocess and parses the result. That is the whole integration. Point your agent framework's shell/exec tool at `$HOME/.local/bin/macos` and it can read your calendar, triage your inbox, move windows, and click buttons by name.

```bash
# Whatever your agent can shell out to, it can call:
"$HOME/.local/bin/macos" reminders export --json
"$HOME/.local/bin/macos" calendar events --json
```

### Add it as a skill

The repo's [`SKILL.md`](SKILL.md) teaches an agent the tool: check permissions first, then every
command, which ones write, the error envelope and the exit codes. One line adds it to Claude Code,
Codex, Cursor and the other agents [skills.sh](https://skills.sh) knows:

```bash
npx skills add manuaudio/macos-cli
```

Hermes Agent takes it from its URL:

```bash
hermes skills install https://raw.githubusercontent.com/manuaudio/macos-cli/main/SKILL.md
```

The skill's command list is generated from the binary (`bash scripts/gen-skill.sh`), and the binary
prints the same list itself, with each command's flags and whether it writes:

```bash
macos commands --json
```

### What may this agent do? `macos doctor --for-agent`

Before an agent reads anything, it can ask the binary what macOS allows it, without
triggering a single prompt:

```jsonc
// macos doctor --for-agent   (trimmed)
{
  "ok": true,
  "ready": false,
  "missing": ["calendars", "full_disk_access"],
  "areas": [
    { "area": "calendars", "state": "not_determined", "granted": false, "needed_by": ["calendar"],
      "hint": "A person runs `macos authorize calendars`, or turns it on in System Settings › Privacy & Security › Calendars.",
      "authorize": "macos authorize calendars" },
    { "area": "reminders", "state": "granted", "granted": true, "needed_by": ["reminders"],
      "hint": null, "authorize": "macos authorize reminders" }
  ],
  "binary": { "path": "…/macos", "bundle_id": "com.manuaudio.macos-cli", "version": "…", "signature": "…", "team_id": "…" },
  "session": { "terminal": false, "gui_session": true, "note": "…" },
  "capabilities": { "calendar.read": true, "mail.send": false }
}
```

Areas: `calendars`, `reminders`, `contacts`, `full_disk_access`, `accessibility`, `screen_recording`,
`location`, and `automation.<app>` for Mail, Messages, Notes, Safari, Music, Photos, Finder and
System Events. A state is `granted`, `denied`, `not_determined`, `restricted`, `write_only` or
`unknown` (macOS answers Automation only for a running app). `capabilities` is the `auth.json`
policy below, resolved.

`macos authorize <area>` asks macOS for one area: it shows the system prompt (waiting at most
`--timeout` seconds, default 60), or opens the settings pane for the areas macOS never prompts for
again. A person clicks Allow; the agent cannot.

A command never waits on a prompt nobody can see. When Calendars, Reminders or Contacts are
undecided and no person is at a terminal (an agent's shell, cron, launchd), the command fails at
once with `access_denied`, `"state": "not_determined"` and the `authorize` command to run. Notes
reads without Full Disk Access fail with `access_denied`, `"area": "full_disk_access"`, never
`count: 0`.

### The policy file: only a person widens it

`~/.config/macos-cli/auth.json` turns capabilities on and off (`macos auth list`). Turning one
**on** — `auth grant`, `auth reset`, `auth setup` — asks the person at the terminal to type a
confirmation, read from `/dev/tty`, so piped input cannot answer it. Without a terminal it refuses
with `person_required` (exit 4) and the policy is unchanged: the agent the policy restricts cannot
lift it. `auth deny` needs no confirmation.

### Agent-safe surfaces (0.8.0)

These commands are built for unattended, read-mostly automation — stable JSON, fail-closed filters, and a machine-readable error contract:

| Command | What it guarantees |
|---|---|
| `macos reminders status --json` | Reports the Reminders authorization state **without prompting** — safe to poll. |
| `macos reminders export --json` | Rich read-only export. `--list NAME` is **fail-closed**: an unknown list yields zero rows, never all of them. |
| `macos reminders export --timeout N` | A fetch timeout is a **hard error** — prints `{"status":"error","error":"fetch_timeout",…}` on stdout and exits `5`, so a hang can never be mistaken for "zero reminders." |
| `macos reminders complete --id ID` | The **only** way to complete a reminder. Defaults to a **dry run**; it writes only when `--approve` exactly matches a non-empty `APPLE_EVENTKIT_APPROVE_TOKEN` environment variable. `complete-safe` is a kept alias. |
| `macos calendar export --json` | Rich read-only export as a single envelope `{ok,status,count,filter,calendars,events}`. Enumerates **all linked calendars from all sources** by default; `--calendar NAME` is **fail-closed** (unknown name ⇒ zero events *and* zero calendars, never all). `--from`/`--to` validate `from ≤ to` and emit a structured `invalid_date_range`/`invalid_date` error + exit `64` on bad input. |
| `macos calendar … --calendar-id ID` | `events`, `export`, `create`, `update` and `delete` take the id `calendar calendars --json` prints (with `source`, `writable` and `color`). A write by a `--calendar NAME` that two calendars share is refused with `ambiguous_calendar` (exit 64) and both ids, never sent to the first one found. |
| `macos calendar delete --id ID` | Deletes exactly one event by stable identifier (`EKSpanThisEvent`). `--id` and `--title`/`--date` are **mutually exclusive**; a missing id prints `{"error":"event_not_found",…,"deleted":false}` and exits `3`. Result carries only `id` + `deleted` — no private event content. |
| `macos notes export --json` | Read-only Notes export straight from the local store (Unicode-preserving), with a fail-closed `--folder` filter. |

The old `reminders done` command is **retired** — it was an ungated write. It now performs no writes and prints a one-line pointer to `reminders complete`.

Example — let an agent complete a reminder only after you've set the approval token in its environment:

```bash
export APPLE_EVENTKIT_APPROVE_TOKEN="$(openssl rand -hex 16)"   # you set this, once
macos reminders complete --id "$ID"                 # dry run — no token passed, nothing changes
macos reminders complete --id "$ID" --approve "$APPLE_EVENTKIT_APPROVE_TOKEN"   # writes
```

### Errors and exit codes

Under `--json` a failure is one JSON object on stdout, and stderr stays empty. The `export` commands always answer this way, with or without the flag. Branch on `error`; `message` and `hint` are for people and may change.

```jsonc
// macos calendar events --json --calendar "Nope"
{
  "ok": false,
  "status": "error",
  "error": "calendar_not_found",
  "message": "No calendar is named 'Nope'.",
  "hint": "Run `macos calendar calendars` to see the names.",
  "calendar": "Nope",
  "exit_code": 3
}
```

| Exit | Meaning | `error` codes |
|---|---|---|
| 0 | Success | — |
| 64 | The command line was rejected: unknown option, missing argument, a value that doesn't parse | `usage`, `invalid_argument`, `invalid_date`, `invalid_date_range`, `invalid_alarm`, `invalid_delete_mode`, `invalid_timezone`, `ambiguous_calendar` |
| 3 | The named thing does not exist | `not_found`, `calendar_not_found`, `event_not_found` |
| 4 | Not allowed | `capability_denied` (turned off in `auth.json`), `access_denied` (macOS privacy settings), `person_required` (a policy change only a person may make) |
| 5 | No answer in time | `timeout`, `fetch_timeout` |
| 6 | The system or an app reported an error | `app_error` |

Commands that only perform an action (move a window, click, play music) print a line of text and have no `--json` output; asked for `--json`, they answer with a `usage` error that says so. Without `--json`, a failure is one `Error:` line and usually a `Hint:` line on stderr.

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

Dates are ISO8601 UTC unless `--timezone America/Los_Angeles` (any IANA name) asks for another zone, which is also the zone `--from`/`--to` are read in. `--start`/`--end` are accepted for `--from`/`--to`. `export --since 2026-11-01` (or an ISO 8601 date-time) keeps only events created or changed since then. `--from` is inclusive, `--to` is the exclusive upper bound; both default to a bounded ±1-year window and accept explicit multi-year ranges (a single EventKit query spans at most ~4 years — chunk beyond that). An unknown `--calendar` returns a valid envelope with `count: 0` and `calendars: []` — never all.

`calendar update --id ID --alarm 15 --alarm 60` replaces an event's alarms; `--clear-alarms` removes them.

**Create with custom alarms** (each `--alarm` is minutes-before and repeatable; with no `--alarm` the event has no alarms; the result echoes the minute list, never notes):

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
macos contacts update "$ID" --job-title "Tour Manager"        # write
macos contacts get "$ID" --json | jq -r .job_title            # → "Tour Manager"
```

The written value appears verbatim in the very next `get`/`export`, so the write can be confirmed rather than assumed.

`contacts export` carries a `history_token`. Pass it back as `--since TOKEN` and the export holds only the contacts added or changed since, plus `deleted_ids`, and a new `history_token`.

### Mail by Message-ID

`mail search QUERY --json` returns each message's `message_id` (the Message-ID header), `account` and `mailbox`; `mail read --id MESSAGE_ID` reads that one message. Both take `--mailbox NAME` and `--account NAME`, which skip every other mailbox; an unknown one is `not_found`, not zero results.

## Permissions

macOS gates these capabilities behind privacy permissions — by design. On first use you'll be prompted to grant **Automation**, **Calendars**, **Contacts**, **Accessibility**, **Screen Recording**, etc. Run `macos doctor` any time to see exactly what's granted and what's missing, and `macos authorize <area>` to ask for one. Nothing is bypassed; you stay in control.

## Build from source

```bash
git clone https://github.com/manuaudio/macos-cli
cd macos-cli
swift build -c release
mkdir -p ~/.local/bin && cp .build/release/macos-cli ~/.local/bin/macos
```

SwiftPM names the product `macos-cli`; it is installed as `macos`. `./install.sh` does the same and signs the binary; `make test` runs the tests.

## Contributing

Issues and PRs welcome. The codebase is plain Swift + [swift-argument-parser](https://github.com/apple/swift-argument-parser) — one command per file under `Sources/macos-cli/Commands/`.

## License

MIT © [manuaudio](https://github.com/manuaudio) — see [LICENSE](LICENSE).
