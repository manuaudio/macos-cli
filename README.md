# apple-cli

**A native macOS command-line interface for Apple data — built for AI agents and scripts.**

Access Reminders, Calendar, Contacts, system state, notifications, and more from a single binary. Every command returns structured JSON. No AppleScript, no automation permissions dialogs beyond standard TCC, no app launching required.

```bash
$ apple reminders create --title "Email Ryan about deposit" --due 2026-05-20 --json
{"id":"x-apple-reminder://...","title":"Email Ryan about deposit","list":"Reminders","due":"2026-05-20","notes":""}

$ apple calendar events --from 2026-05-20 --to 2026-05-21 --json
[{"title":"Soundcheck — Orpheum","start":"2026-05-20T14:00:00-07:00","end":"2026-05-20T17:00:00-07:00","calendar":"Work","location":"842 S Broadway, Los Angeles"}]

$ apple system battery --json
{"level":87,"charging":false,"plugged_in":true,"time_remaining_minutes":312}
```

---

## Why

macOS ships rich native frameworks (EventKit, Contacts, UserNotifications) with no CLI surface. Getting calendar events in a shell script means AppleScript or Automator — both brittle, slow, and hard to parse. `apple-cli` wraps these frameworks in a clean, consistent CLI designed for:

- **LLM tool use** — all output is `--json`; no screen-scraping required
- **Shell scripts and launchd daemons** — deterministic exit codes, no UI dependencies
- **AI personal assistants** — read Reminders, write Calendar events, query Contacts without Shortcuts or AppleScript

---

## Install

### Homebrew (recommended)

```bash
brew tap manuaudio/apple-cli
brew install apple-cli
```

### From source

Requires **Xcode Command Line Tools** and **Swift 5.9+**:

```bash
git clone https://github.com/manuaudio/apple-cli
cd apple-cli
make install          # builds release binary → installs to /usr/local/bin/apple
```

Or choose a custom install path:

```bash
swift build -c release
install .build/release/apple-cli /usr/local/bin/apple
```

### Verify

```bash
apple --version       # apple-cli 0.3.0
apple --help          # lists all top-level commands
```

---

## Permissions

`apple-cli` uses standard macOS TCC (Transparency, Consent, and Control). On first use, macOS will prompt for each permission. You can also grant them in advance:

**System Settings → Privacy & Security:**

| Permission | Commands that need it |
|---|---|
| Reminders | `reminders` |
| Calendars | `calendar` |
| Contacts | `contacts` |

No other permissions are required. `system`, `apps`, `screen`, `storage`, `notify`, `speech`, and `info` do not require TCC grants.

---

## Commands

### `reminders`

Read and write Apple Reminders.

```bash
# Create a reminder
apple reminders create --title "Call insurance broker"
apple reminders create --title "Follow up with Kim" --due 2026-05-23
apple reminders create --title "Review stems" --due 2026-05-20 --list "Work" --notes "flornan | priority: high" --json

# List reminders (incomplete, from default list)
apple reminders list
apple reminders list --list "Work" --json

# Complete a reminder (pass the id from --json output)
apple reminders done "x-apple-reminder://..."

# List all reminder lists
apple reminders lists --json
```

**`create --json` output:**
```json
{
  "id": "x-apple-reminder://AB12CD34-...",
  "title": "Review stems",
  "list": "Work",
  "due": "2026-05-20",
  "notes": "flornan | priority: high"
}
```

**Flags:**

| Flag | Description |
|---|---|
| `--title` | Reminder title (required) |
| `--due` | Due date: `YYYY-MM-DD` |
| `--list` | List name (default: "Reminders") |
| `--notes` | Notes / description |
| `--json` | Output as JSON |

---

### `calendar`

Read and create calendar events.

```bash
# List events (default: today + 7 days)
apple calendar events
apple calendar events --from 2026-05-20 --to 2026-05-23 --json

# Filter by calendar
apple calendar events --calendar "Work" --json

# Create an event
apple calendar create \
  --title "Soundcheck — Orpheum" \
  --start "2026-05-20 14:00" \
  --end "2026-05-20 17:00" \
  --calendar "Work" \
  --location "842 S Broadway, Los Angeles"

# All-day event
apple calendar create --title "Travel day" --start "2026-05-20" --all-day

# List all calendars
apple calendar calendars --json
```

> **Note:** Every event created by `apple calendar create` automatically gets a **1-day** and **1-hour** alert — no flags needed.

**`events --json` output:**
```json
[
  {
    "title": "Soundcheck — Orpheum",
    "start": "2026-05-20T14:00:00-07:00",
    "end": "2026-05-20T17:00:00-07:00",
    "calendar": "Work",
    "location": "842 S Broadway, Los Angeles",
    "notes": ""
  }
]
```

**Flags for `create`:**

| Flag | Description |
|---|---|
| `--title` | Event title (required) |
| `--start` | Start: `YYYY-MM-DD HH:MM` or `YYYY-MM-DD` |
| `--end` | End: `YYYY-MM-DD HH:MM` |
| `--calendar` | Calendar name (default: first writable calendar) |
| `--location` | Location string |
| `--notes` | Notes |
| `--all-day` | Create as all-day event |

---

### `contacts`

Search and retrieve Apple Contacts.

```bash
# Search by name, phone, or email
apple contacts search "Ryan"
apple contacts search "ryan@example.com" --json

# Limit results
apple contacts search "Kim" --limit 3 --json

# Get by contact ID
apple contacts get "AB12CD34-..." --json
```

**`search --json` output:**
```json
[
  {
    "id": "AB12CD34-...",
    "name": "Ryan Billingsley",
    "phones": [{"number": "+13105550100", "label": "mobile"}],
    "emails": [{"email": "ryan@example.com", "label": "work"}]
  }
]
```

> **Field names:** phones use `number` (not `value`), emails use `email` (not `value`).

**Flags:**

| Flag | Description |
|---|---|
| `--limit` | Max results (default: 10) |
| `--json` | Output as JSON |

---

### `system`

Query system state: battery, audio, wifi, clipboard, display.

```bash
apple system battery
apple system battery --json

apple system audio volume        # current volume level
apple system audio mute          # toggle mute
apple system audio devices --json
apple system audio now-playing --json

apple system wifi                # SSID + signal
apple system clipboard           # paste clipboard contents to stdout
apple system display             # display info
```

**`battery --json` output:**
```json
{
  "level": 87,
  "charging": false,
  "plugged_in": true,
  "time_remaining_minutes": 312
}
```

---

### `apps`

List, launch, and quit applications.

```bash
apple apps list                  # installed apps (common locations)
apple apps list --all --json     # all apps, full paths

apple apps launch "Safari"
apple apps launch "Xcode"

apple apps quit "Safari"
apple apps quit "Xcode" --force  # force-quit

apple apps info "Final Cut Pro" --json
```

---

### `screen`

Screen info, capture, and lock.

```bash
apple screen info --json         # resolution, scale, display count

apple screen capture             # capture to clipboard
apple screen capture --output ~/Desktop/shot.png
apple screen capture --window "Terminal"  # capture specific window

apple screen lock                # lock screen immediately
```

---

### `storage`

Disk and volume information.

```bash
apple storage volumes            # list mounted volumes
apple storage volumes --json

apple storage usage              # usage at /
apple storage usage ~/Developer  # usage at path
apple storage usage ~/Developer --json
```

---

### `notify`

Send macOS notification banners. Uses `display notification` — no special permissions required.

```bash
apple notify send --title "Build complete"
apple notify send --title "Reminder" --body "Follow up with Kim Petras team" --subtitle "Gigs"
apple notify send --title "Done" --body "Payment sent" --sound "Glass"
```

> **Important:** The `send` subcommand is required — `apple notify --title "..."` will error.

**Flags:**

| Flag | Description |
|---|---|
| `--title` | Notification title (required) |
| `--body` | Notification body |
| `--subtitle` | Notification subtitle |
| `--sound` | Sound name (e.g. `Glass`, `Basso`, `Ping`) |

---

### `speech`

Text-to-speech synthesis.

```bash
apple speech say "Reminder: soundcheck in one hour"
apple speech say "Meeting at 3pm" --voice "Samantha"
apple speech say "Hello" --rate 180

# Save to audio file
apple speech say "This is a test" --output ~/Desktop/test.aiff

# List available voices
apple speech voices
apple speech voices --json
```

---

### `info`

System diagnostics and macOS metadata.

```bash
apple info system                # macOS version, hardware info
apple info system --json

apple info network               # interfaces, IP addresses
apple info network --json

apple info power                 # power / sleep settings

apple info spotlight             # Spotlight index status

apple info keychain              # keychain items summary
```

---

## Using with AI agents

`apple-cli` is purpose-built for LLM tool use. Every subcommand that returns data accepts `--json` and exits 0 on success, non-zero on failure.

### Pattern: create a Reminder from LLM output

```bash
RESULT=$(apple reminders create \
  --title "Email Ryan about deposit" \
  --due 2026-05-20 \
  --notes "gigs | priority: high" \
  --json)

# Extract the ID for logging
REMINDER_ID=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
echo "Created reminder: $REMINDER_ID"
```

### Pattern: check calendar before scheduling

```bash
# Are there conflicts on May 20?
CONFLICTS=$(apple calendar events \
  --from 2026-05-20 \
  --to 2026-05-20 \
  --json | python3 -c "import sys,json; events=json.load(sys.stdin); print(len(events), 'events')")
echo "$CONFLICTS"
```

### Pattern: look up a contact before composing

```bash
apple contacts search "Ryan" --limit 1 --json \
  | python3 -c "
import sys, json
contacts = json.load(sys.stdin)
if contacts:
    c = contacts[0]
    email = c['emails'][0]['email'] if c['emails'] else 'no email'
    print(f\"{c['name']} — {email}\")
"
```

### Claude / AI agent tool definition (example)

```json
{
  "name": "create_reminder",
  "description": "Create an Apple Reminder with optional due date and notes",
  "input_schema": {
    "type": "object",
    "properties": {
      "title": {"type": "string"},
      "due": {"type": "string", "description": "YYYY-MM-DD"},
      "list": {"type": "string"},
      "notes": {"type": "string"}
    },
    "required": ["title"]
  }
}
```

Map to: `apple reminders create --title <title> [--due <due>] [--list <list>] [--notes <notes>] --json`

---

## Building

```bash
git clone https://github.com/manuaudio/apple-cli
cd apple-cli

# Debug build
swift build

# Release build
swift build -c release

# Install to /usr/local/bin
make install

# Run tests
swift test
```

**Requirements:**
- macOS 13 (Ventura) or later
- Swift 5.9+ / Xcode 15+
- Frameworks used: EventKit, Contacts, swift-argument-parser

---

## Design principles

- **One binary, one command.** `apple` — no prefixes, no namespacing gymnastics.
- **Structured output first.** `--json` on every read command. Human-readable default for interactive use.
- **Deterministic threading.** EventKit and Contacts use a semaphore + explicit runloop thread — no race conditions, no `NSApplication` needed.
- **Automatic alerts on calendar creates.** Every `apple calendar create` adds 1-day and 1-hour alerts. This mirrors how a human would add an event and prevents missed meetings.
- **TCC-only permissions.** No Accessibility, no Automation, no Full Disk Access. Only what each command strictly needs.

---

## Contributing

Pull requests welcome. Before submitting:

1. Add a test case in `Tests/` for new behavior
2. Run `swift test` — all tests must pass
3. Verify JSON output shape matches the documented schema
4. Keep the binary name `apple` (not `apple-cli`) — this is intentional

For significant new commands, open an issue first to discuss the interface.

---

## License

MIT — see [LICENSE](LICENSE).

---

*Built for [Aura](https://github.com/manuaudio/chief) — a personal AI chief of staff. Contributions and issues welcome.*
