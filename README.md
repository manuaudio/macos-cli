# apple-cli

A native macOS command-line tool that gives your terminal and your AI agent first-class access to Apple APIs. Reminders, Calendar, Contacts, Messages, Mail, Photos, Music, Safari, screenshots, OCR, mouse/keyboard automation, and more. One binary. Zero AppleScript.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![macOS](https://img.shields.io/badge/macOS-13%2B-black?logo=apple)](#requirements)
[![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange?logo=swift)](https://swift.org)
[![Version](https://img.shields.io/badge/version-0.5.0-blue)](#install)

---

## Install

```bash
curl -sSL https://raw.githubusercontent.com/manuaudio/apple-cli/main/install.sh | bash
```

Builds from source, installs to `/usr/local/bin/apple`, and runs a permission check. Takes ~30 seconds.

**Requirements:** macOS 13 (Ventura) or later · Swift 5.9+ (included with Xcode Command Line Tools)

If you don't have Xcode CLT yet: `xcode-select --install`, then re-run the curl command.

### Verify

```bash
apple --version   # apple-cli 0.5.0
apple setup       # check all permissions — green checkmark per capability
```

---

## What's included

| Category | Commands |
|---|---|
| **Productivity** | `reminders` `calendar` `contacts` `notes` |
| **Communication** | `messages` `mail` |
| **Media** | `photos` `music` |
| **Browser** | `safari` |
| **Automation** | `mouse` `keyboard` `ax` (accessibility tree) |
| **Screen** | `screenshot` `ocr` `window` |
| **System** | `system` `apps` `storage` `info` `notify` `speech` `finder` |
| **Setup** | `setup` |

Every read command supports `--json` for clean, parseable output. Designed for both humans and LLM agents.

---

## Quick start

```bash
# What's on your calendar today
apple calendar events --json

# Create a reminder
apple reminders create --title "Follow up with Ryan" --due 2026-05-20

# Find a contact
apple contacts search "Ryan" --json

# Take a screenshot
apple screenshot full --output ~/Desktop/shot.png

# OCR the entire screen
apple ocr full --json

# Read the current Safari tab
apple safari read

# Check battery
apple system battery

# Send a notification
apple notify send --title "Build finished" --body "All tests passed"

# What music is playing
apple music status

# Type text into the frontmost app
apple keyboard type "Hello from the terminal"

# Click a UI element by name (accessibility)
apple ax click "OK"
```

---

## Command reference

### `reminders` — Apple Reminders

```bash
# Create
apple reminders create --title "Email Ryan about deposit"
apple reminders create --title "Review stems" --due 2026-05-20 --list "Work" --notes "priority: high" --json

# List incomplete reminders
apple reminders list
apple reminders list --list "Work" --json

# Mark complete (use the id from --json)
apple reminders done "x-apple-reminder://AB12CD34-..."

# See all your lists
apple reminders lists --json
```

**`create --json` returns:**
```json
{"id": "x-apple-reminder://AB12...", "title": "Review stems", "list": "Work", "due": "2026-05-20", "notes": "priority: high"}
```

---

### `calendar` — Apple Calendar

```bash
# Upcoming events (today + 7 days by default)
apple calendar events --json

# Custom date range
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

# Delete an event (use the id from events --json)
apple calendar delete --id "8E486F91-...:34CE5C3E-..."

# List all calendars
apple calendar calendars --json
```

> Every event created by `apple calendar create` automatically gets a 1-day and 1-hour alert.

---

### `contacts` — Apple Contacts

```bash
# Search by name, email, or phone
apple contacts search "Ryan" --json
apple contacts search "ryan@example.com" --json --limit 5

# Get full record by ID
apple contacts get "AB12CD34-..." --json
```

**`search --json` returns:**
```json
[{"id": "AB12...", "name": "Ryan B.", "phones": [{"number": "+13105550100", "label": "mobile"}], "emails": [{"email": "ryan@example.com", "label": "work"}]}]
```

---

### `notes` — Apple Notes

```bash
apple notes list --json              # all notes (title + id)
apple notes search "meeting" --json
apple notes read "AB12CD34-..."      # read by id
apple notes create --title "My note" --body "Content here"
```

---

### `messages` — Apple Messages

```bash
# Send an iMessage or SMS
apple messages send --to "+13105550100" --body "On my way"
apple messages send --to "ryan@example.com" --body "Check your email"

# List recent conversations
apple messages conversations --json
apple messages conversations --limit 20 --json
```

---

### `mail` — Apple Mail

```bash
# Create a draft (opens in Mail, does not send)
apple mail draft --to "ryan@example.com" --subject "Invoice" --body "See attached."
apple mail draft --to "a@b.com" --subject "Hello" --body "Hi" --json

# Search messages
apple mail search "invoice" --json
apple mail search "Ryan" --limit 20 --json

# List accounts
apple mail accounts --json
```

---

### `photos` — Apple Photos

```bash
apple photos albums --json           # list all albums with photo count
apple photos search "sunset" --json
apple photos recent --limit 10 --json
```

---

### `music` — Apple Music

```bash
apple music status                   # current track + playback state
apple music status --json

apple music play
apple music pause
apple music next
apple music prev

apple music volume                   # get current volume (0–100)
apple music volume 50                # set volume to 50

apple music search "Daft Punk"       # search library and play first result
```

**`status --json` returns:**
```json
{"state": "playing", "track": "Get Lucky", "artist": "Daft Punk", "album": "Random Access Memories", "duration": 248, "position": 43, "volume": 72}
```

---

### `safari` — Safari control

```bash
apple safari tabs --json             # list all open tabs (title + URL)
apple safari open "https://example.com"
apple safari read                    # get text content of current tab
apple safari execute "document.title"  # run JavaScript in current tab
```

---

### `screenshot` — Screen capture

```bash
# Full screen
apple screenshot full --output ~/Desktop/shot.png

# Specific app window (requires Screen Recording permission)
apple screenshot window --app "Terminal" --output /tmp/term.png

# Region (points from top-left)
apple screenshot region --x 0 --y 0 --width 800 --height 600 --output /tmp/region.png
```

---

### `ocr` — Vision OCR

Read text from the screen or an image file using Apple's Vision framework. Runs fully on-device, no network call.

```bash
# OCR the entire screen
apple ocr full
apple ocr full --json                # ["line one", "line two", ...]

# OCR a screen region (x y width height, in points)
apple ocr region --x 100 --y 200 --width 600 --height 300

# OCR an image file (JPEG, PNG, HEIC, etc.)
apple ocr file --path ~/Desktop/receipt.png
apple ocr file --path /tmp/screenshot.png --json
```

---

### `mouse` — Cursor control

```bash
apple mouse position --json          # {"x": 500, "y": 300}

apple mouse move --x 500 --y 300
apple mouse click --x 500 --y 300
apple mouse click --x 500 --y 300 --right   # right-click
apple mouse drag --from-x 100 --from-y 100 --to-x 500 --to-y 500
apple mouse scroll --x 500 --y 300 --delta-y -3
```

---

### `keyboard` — Keyboard input

```bash
# Type text into the frontmost app
apple keyboard type "Hello, world"
apple keyboard type "Hello" --delay 50    # 50ms between keystrokes

# Send a key or shortcut
apple keyboard key "return"
apple keyboard key "cmd+c"
apple keyboard key "cmd+shift+4"
apple keyboard key "escape"
```

Common key names: `return` `escape` `tab` `space` `delete` `up` `down` `left` `right` `f1`–`f12`

---

### `ax` — Accessibility tree

Interact with any app's UI elements by name — no screen coordinates needed.

```bash
# Find UI elements matching a name
apple ax find "OK" --app "Safari" --json

# Click a UI element by name
apple ax click "OK"
apple ax click "Reminders" --app "Finder"

# Dump the UI tree of an app (top 2 levels)
apple ax read "Safari" --json
apple ax read "Finder"
```

**`find --json` returns:**
```json
[{"role": "AXButton", "name": "OK", "x": 845, "y": 512}]
```

---

### `window` — Window management

```bash
apple window list --json             # all visible windows with position + size

apple window move --app "Safari" --x 0 --y 0
apple window resize --app "Safari" --width 1200 --height 800
apple window focus --app "Terminal"
apple window minimize --app "Safari"
```

---

### `finder` — Finder integration

```bash
apple finder selected                # paths of selected files in Finder
apple finder selected --json         # as JSON array

apple finder cwd                     # current folder in front Finder window
apple finder cwd --json              # {"path": "/Users/you/Desktop"}

apple finder reveal ~/Desktop/file.txt   # reveal in Finder
apple finder open ~/Desktop/folder       # open in Finder
```

---

### `system` — System state

```bash
apple system battery --json
# {"level": 87, "charging": false, "plugged_in": true}

apple system audio volume            # get current volume
apple system audio mute              # toggle mute
apple system audio devices --json
apple system audio now-playing --json

apple system wifi status --json      # SSID, channel, security
apple system clipboard               # read clipboard to stdout
apple system display --json
```

---

### `apps` — Application management

```bash
apple apps list --json               # installed apps
apple apps list --all --json         # all apps with full paths

apple apps launch "Safari"
apple apps quit "Safari"
apple apps quit "Xcode" --force

apple apps info "Final Cut Pro" --json
```

---

### `storage` — Disk info

```bash
apple storage volumes --json         # mounted volumes with usage
apple storage usage                  # disk usage at /
apple storage usage ~/Developer --json
```

---

### `notify` — Notifications

```bash
apple notify send --title "Build complete"
apple notify send --title "Reminder" --body "Follow up with team" --subtitle "Work"
apple notify send --title "Done" --sound "Glass"
```

---

### `speech` — Text-to-speech

```bash
apple speech say "Meeting in 10 minutes"
apple speech say "Hello" --voice "Samantha" --rate 180
apple speech say "This is a recording" --output ~/Desktop/note.aiff

apple speech voices --json           # list all available voices
```

---

### `info` — System diagnostics

```bash
apple info system --json             # macOS version, hardware model
apple info network --json            # interfaces and IP addresses
apple info power                     # sleep and power settings
apple info spotlight                 # Spotlight index status
apple info keychain                  # Keychain summary
```

---

### `setup` — Permission checker

```bash
apple setup
```

Checks every capability and prints a green checkmark or red X. Run after install or after granting new permissions.

---

## Permissions

macOS will prompt on first use for each protected API. Grant in advance at **System Settings → Privacy & Security**:

| Permission | Required for |
|---|---|
| Reminders | `apple reminders` |
| Calendars | `apple calendar` |
| Contacts | `apple contacts` |
| Screen Recording | `apple screenshot window` |
| Accessibility | `apple mouse` `apple keyboard` `apple ax` |
| Automation | `apple messages` `apple mail` `apple photos` `apple music` `apple safari` `apple finder` |

No permissions required: `system` `apps` `storage` `notify` `speech` `info` `notes` `ocr full/file` `screenshot full/region`

---

## Using with AI agents

Every read command exits `0` on success, non-zero on failure, and emits clean `--json` output. Built for LLM tool use.

### Example: Claude tool definition

```json
{
  "name": "create_reminder",
  "description": "Create an Apple Reminder with an optional due date",
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

Maps to: `apple reminders create --title <title> [--due <due>] [--list <list>] [--notes <notes>] --json`

### Example: check calendar before scheduling

```bash
COUNT=$(apple calendar events --from 2026-05-20 --to 2026-05-20 --json \
  | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
echo "$COUNT events on that day"
```

### Example: OCR a receipt and extract the text

```bash
apple ocr file --path ~/Desktop/receipt.png --json \
  | python3 -c "import sys,json; print('\n'.join(json.load(sys.stdin)))"
```

### Example: click a UI element without knowing its coordinates

```bash
apple ax click "Sign In" --app "Safari"
```

---

## Build from source

```bash
git clone https://github.com/manuaudio/apple-cli
cd apple-cli

swift build              # debug build
swift build -c release   # release build
make install             # release build + install to /usr/local/bin
```

---

## Contributing

Pull requests welcome.

1. Add a test in `Tests/` for any new behavior
2. `--json` output shapes are part of the public API — don't change field names without a version bump
3. New top-level commands: open an issue first to align on the interface

---

## License

MIT — see [LICENSE](LICENSE).

---

*Built for [Aura](https://github.com/manuaudio/chief) — a personal AI chief of staff running on macOS.*
