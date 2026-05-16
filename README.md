# 🍎 apple-cli

> A native macOS command-line tool that gives your terminal — and your AI agent — first-class access to Apple data. Reminders, Calendar, Contacts, system state, notifications, screenshots, and more. One binary, zero AppleScript.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![macOS](https://img.shields.io/badge/macOS-13%2B-black?logo=apple)](#requirements)
[![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange?logo=swift)](https://swift.org)
[![Version](https://img.shields.io/badge/version-0.3.0-blue)](#install)

Native macOS frameworks (EventKit, Contacts, UserNotifications) have no CLI surface. Getting your calendar events in a script means AppleScript — which is slow, breaks on Sonoma+, and returns data that's painful to parse. `apple-cli` wraps those frameworks in a clean, consistent `--json` interface designed for both humans and LLMs.

```bash
$ apple reminders create --title "Follow up with Ryan" --due 2026-05-20 --json
{"id":"x-apple-reminder://AB12...","title":"Follow up with Ryan","list":"Reminders","due":"2026-05-20","notes":""}

$ apple calendar events --from 2026-05-20 --to 2026-05-21 --json
[{"title":"Soundcheck","start":"2026-05-20T14:00:00-07:00","end":"2026-05-20T17:00:00-07:00","calendar":"Work","location":"842 S Broadway"}]

$ apple system battery --json
{"level":87,"charging":false,"plugged_in":true,"time_remaining_minutes":312}
```

---

## ✨ What's included

**📋 Productivity**

| Command | What it does |
|---|---|
| `reminders` | Create, list, complete reminders across all your lists |
| `calendar` | Read upcoming events, create new ones with automatic alerts |
| `contacts` | Search by name, phone, or email — returns full contact records |

**💻 System**

| Command | What it does |
|---|---|
| `system` | Battery, audio controls, Wi-Fi, clipboard, display info |
| `apps` | List installed apps, launch, quit, get app info |
| `screen` | Screen info, capture screenshots, lock the screen |
| `storage` | Disk volumes and usage at any path |
| `info` | System info, network interfaces, power settings, Spotlight, Keychain |

**🔔 Interaction**

| Command | What it does |
|---|---|
| `notify` | Post a Notification Center banner — no permissions required |
| `speech` | Text-to-speech synthesis, list available voices |

---

## 📦 Install

### From source

Requires **Xcode Command Line Tools** (comes with macOS) and **Swift 5.9+**:

```bash
git clone https://github.com/manuaudio/apple-cli
cd apple-cli
make install
```

That's it. The `apple` binary is installed to `/usr/local/bin/apple`.

### Manual build

```bash
swift build -c release
install .build/release/apple-cli /usr/local/bin/apple
```

### Verify

```bash
apple --version   # apple-cli 0.3.0
apple --help      # lists all commands
```

---

## 🔐 Permissions

macOS will prompt you the first time each protected command runs. You can also grant access in advance:

**System Settings → Privacy & Security**

| Permission | Required for |
|---|---|
| **Reminders** | `apple reminders` |
| **Calendars** | `apple calendar` |
| **Contacts** | `apple contacts` |

Everything else (`system`, `apps`, `screen`, `storage`, `notify`, `speech`, `info`) requires no special permissions.

---

## 🚀 Quick start

A few things you can do right away:

```bash
# See what's on your calendar this week
apple calendar events --json

# Create a reminder with a due date
apple reminders create --title "Call insurance broker" --due 2026-05-23

# Find a contact's phone number
apple contacts search "Ryan" --json

# Check your battery
apple system battery

# Send yourself a notification
apple notify send --title "Build finished" --body "All tests passed"

# Take a screenshot
apple screen capture --output ~/Desktop/shot.png

# Lock your screen
apple screen lock
```

---

## 📖 Command reference

### `reminders` — Apple Reminders

```bash
# Create
apple reminders create --title "Email Ryan about deposit"
apple reminders create --title "Review stems" --due 2026-05-20 --list "Work" --notes "priority: high" --json

# List (incomplete reminders from a list)
apple reminders list
apple reminders list --list "Work" --json

# Mark complete (use the id from --json)
apple reminders done "x-apple-reminder://AB12CD34-..."

# See all your lists
apple reminders lists --json
```

**`create --json` returns:**
```json
{
  "id": "x-apple-reminder://AB12CD34-...",
  "title": "Review stems",
  "list": "Work",
  "due": "2026-05-20",
  "notes": "priority: high"
}
```

---

### `calendar` — Apple Calendar

```bash
# Upcoming events (today + 7 days)
apple calendar events
apple calendar events --from 2026-05-20 --to 2026-05-23 --json

# Filter by calendar
apple calendar events --calendar "Work" --json

# Create an event
apple calendar create \
  --title "Soundcheck — Orpheum" \
  --start "2026-05-20 14:00" \
  --end   "2026-05-20 17:00" \
  --calendar "Work" \
  --location "842 S Broadway, Los Angeles"

# All-day event
apple calendar create --title "Travel day" --start "2026-05-20" --all-day

# List all calendars
apple calendar calendars --json
```

> Every event created by `apple calendar create` automatically gets a **1-day** and **1-hour** alert — no extra flags needed.

---

### `contacts` — Apple Contacts

```bash
# Search by name, email, or phone
apple contacts search "Ryan"
apple contacts search "ryan@example.com" --json --limit 5

# Get full record by ID
apple contacts get "AB12CD34-..." --json
```

**`search --json` returns:**
```json
[{
  "id": "AB12CD34-...",
  "name": "Ryan Billingsley",
  "phones": [{"number": "+13105550100", "label": "mobile"}],
  "emails": [{"email": "ryan@example.com", "label": "work"}]
}]
```

---

### `system` — System state

```bash
apple system battery             # level, charging status, time remaining
apple system battery --json

apple system audio volume        # current volume
apple system audio mute          # toggle mute
apple system audio devices --json
apple system audio now-playing --json

apple system wifi                # current SSID + signal
apple system clipboard           # paste clipboard to stdout
apple system display             # display info
```

**`battery --json` returns:**
```json
{"level": 87, "charging": false, "plugged_in": true, "time_remaining_minutes": 312}
```

---

### `apps` — Applications

```bash
apple apps list                  # installed apps
apple apps list --all --json     # all apps with full paths

apple apps launch "Safari"
apple apps quit "Safari"
apple apps quit "Xcode" --force

apple apps info "Final Cut Pro" --json
```

---

### `screen` — Screen

```bash
apple screen info --json                     # resolution, scale, display count
apple screen capture                         # capture to clipboard
apple screen capture --output ~/Desktop/shot.png
apple screen capture --window "Terminal"     # capture specific window
apple screen lock                            # lock screen immediately
```

---

### `storage` — Disk

```bash
apple storage volumes              # list mounted volumes
apple storage volumes --json

apple storage usage                # usage at /
apple storage usage ~/Developer --json
```

---

### `notify` — Notifications

```bash
apple notify send --title "Build complete"
apple notify send --title "Reminder" --body "Follow up with team" --subtitle "Work"
apple notify send --title "Done" --sound "Glass"
```

> The `send` subcommand is required. `apple notify --title "..."` will return an error.

---

### `speech` — Text-to-speech

```bash
apple speech say "Meeting in 10 minutes"
apple speech say "Hello" --voice "Samantha" --rate 180
apple speech say "This is a recording" --output ~/Desktop/note.aiff

apple speech voices --json        # list all available voices
```

---

### `info` — System diagnostics

```bash
apple info system --json          # macOS version, hardware model
apple info network --json         # interfaces and IP addresses
apple info power                  # sleep and power settings
apple info spotlight              # Spotlight index status
apple info keychain               # Keychain summary
```

---

## 🤖 Using with AI agents

Every read command returns clean `--json` output and exits `0` on success, non-zero on failure — exactly what LLM tool use needs.

### Example: Claude tool definition

```json
{
  "name": "create_reminder",
  "description": "Create an Apple Reminder with an optional due date",
  "input_schema": {
    "type": "object",
    "properties": {
      "title": {"type": "string"},
      "due":   {"type": "string", "description": "YYYY-MM-DD"},
      "list":  {"type": "string"},
      "notes": {"type": "string"}
    },
    "required": ["title"]
  }
}
```

Maps to: `apple reminders create --title <title> [--due <due>] [--list <list>] [--notes <notes>] --json`

### Example: check for calendar conflicts before scheduling

```bash
CONFLICTS=$(apple calendar events --from 2026-05-20 --to 2026-05-20 --json \
  | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
echo "$CONFLICTS events already on that day"
```

### Example: look up a contact before composing an email

```bash
apple contacts search "Ryan" --limit 1 --json \
  | python3 -c "
import sys, json
c = json.load(sys.stdin)[0]
print(c['name'], '—', c['emails'][0]['email'] if c['emails'] else 'no email')
"
```

---

## 🛠 Build from source

```bash
git clone https://github.com/manuaudio/apple-cli
cd apple-cli

swift build              # debug build
swift build -c release   # release build
make install             # build release + install to /usr/local/bin

swift test               # run tests
```

**Requirements:**
- macOS 13 (Ventura) or later
- Swift 5.9+ / Xcode 15+

---

## 🤝 Contributing

Pull requests are welcome. A few things to keep in mind:

1. Add a test in `Tests/` for any new behavior
2. `swift test` must pass before submitting
3. `--json` output shapes are part of the public API — don't change field names without a version bump
4. The binary installs as `apple`, not `apple-cli` — this is intentional

For new top-level commands, open an issue first to align on the interface.

---

## 📄 License

MIT — see [LICENSE](LICENSE).

---

*Built for [Aura](https://github.com/manuaudio/chief) — a personal AI chief of staff running on macOS.*
