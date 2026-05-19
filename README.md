# macOS CLI

A native macOS command-line tool that gives your terminal and your AI agent first-class access to Apple APIs. Reminders, Calendar, Contacts, Messages, Mail, Photos, Music, Safari, screenshots, OCR, mouse/keyboard automation, and more. One binary. Zero AppleScript.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![macOS](https://img.shields.io/badge/macOS-13%2B-black?logo=apple)](#requirements)
[![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange?logo=swift)](https://swift.org)
[![Version](https://img.shields.io/badge/version-0.5.8-blue)](#install)

---

## Install

```bash
curl -sSL https://raw.githubusercontent.com/manuaudio/macos-cli/main/install.sh | bash
```

Builds from source, installs to `/usr/local/bin/macos`, and runs a permission check. Takes ~30 seconds.

**Requirements:** macOS 13 (Ventura) or later · Swift 5.9+ (included with Xcode Command Line Tools)

If you don't have Xcode CLT yet: `xcode-select --install`, then re-run the curl command.

### Verify

```bash
macos --version   # 0.5.8
macos setup       # check all permissions — green checkmark per capability
```

---

## What's included

| Category | Commands |
|---|---|
| **Productivity** | `reminders` `calendar` `contacts` `notes` |
| **Communication** | `messages` `mail` |
| **Media** | `photos` `music` `voice-memos` |
| **Browser** | `safari` |
| **Automation** | `mouse` `keyboard` `ax` (accessibility tree) `shortcuts` |
| **Screen** | `screenshot` `screen` `ocr` `window` |
| **System** | `system` `apps` `storage` `info` `notify` `speech` `finder` `process` `disk` `focus` `location` `bluetooth` `login-items` `dock` |
| **Files** | `pdf` `file` `trash` `spotlight` |
| **System Config** | `defaults` `keychain` `network` |
| **Setup** | `setup` |

Every command supports `--json` for clean, parseable output. Designed for both humans and LLM agents.

---

## Quick start

```bash
# What's on your calendar today
macos calendar events --json

# Create a reminder
macos reminders create --title "Follow up with Ryan" --due 2026-05-20

# Find a contact
macos contacts search "Ryan" --json

# Take a screenshot
macos screenshot full --output ~/Desktop/shot.png

# OCR the entire screen
macos ocr full --json

# Read the current Safari tab
macos safari read

# Check battery
macos system battery

# Send a notification
macos notify send --title "Build finished" --body "All tests passed"

# What music is playing
macos music status

# Type text into the frontmost app
macos keyboard type "Hello from the terminal"

# Click a UI element by name (accessibility)
macos ax click "OK"
```

---

## Command reference

### `reminders` — Apple Reminders

```bash
# Create
macos reminders create --title "Email Ryan about deposit"
macos reminders create --title "Review stems" --due 2026-05-20 --list "Work" --notes "priority: high" --json

# List incomplete reminders
macos reminders list
macos reminders list --list "Work" --json

# Mark complete / uncomplete
macos reminders done <id>
macos reminders uncomplete <id>

# Update a reminder
macos reminders update --id <id> --title "New title" --due 2026-05-25 --list "Personal"

# Delete a reminder
macos reminders delete --id <id>

# See all your lists
macos reminders lists --json
```

---

### `calendar` — Apple Calendar

```bash
# Upcoming events (today + 7 days by default)
macos calendar events --json

# Custom date range
macos calendar events --from 2026-05-20 --to 2026-05-23 --json

# Filter by calendar
macos calendar events --calendar "Work" --json

# Create an event
macos calendar create \
  --title "Soundcheck — Orpheum" \
  --start "2026-05-20 14:00" \
  --end   "2026-05-20 17:00" \
  --calendar "Work" \
  --location "842 S Broadway, Los Angeles"

# All-day event
macos calendar create --title "Travel day" --start "2026-05-20" --all-day

# Update an existing event (use id from events --json)
macos calendar update --id <event-id> --title "New Title" --start "2026-05-20 15:00"

# Delete an event by title and date
macos calendar delete --title "Soundcheck — Orpheum" --date 2026-05-20

# List all calendars
macos calendar calendars --json
```

> Every event created by `macos calendar create` automatically gets a 1-day and 1-hour alert.

---

### `contacts` — Apple Contacts

```bash
# Search by name, email, or phone
macos contacts search "Ryan" --json
macos contacts search "ryan@example.com" --json --limit 5

# Get full record by ID
macos contacts get "AB12CD34-..." --json
```

**`search --json` returns:**
```json
[{"id": "AB12...", "name": "Ryan B.", "phones": [{"number": "+13105550100", "label": "mobile"}], "emails": [{"email": "ryan@example.com", "label": "work"}]}]
```

---

### `notes` — Apple Notes

```bash
macos notes list --json              # all notes (title + modified date)
macos notes search "meeting" --json
macos notes read "My note"           # read by title
macos notes create --title "My note" --body "Content here"
macos notes update --title "My note" --body "New content"
macos notes delete --title "My note"
macos notes folders --json           # list all folders with note count
macos notes create-folder --name "Projects"
```

---

### `messages` — Apple Messages

```bash
# Send an iMessage or SMS
macos messages send --to "+13105550100" --text "On my way"
macos messages send --to "ryan@example.com" --text "Check your email"

# List recent conversations
macos messages conversations --json
macos messages conversations --limit 20 --json

# Read messages from a conversation
macos messages read --with "Ryan" --limit 20 --json

# Delete a conversation
macos messages delete --with "Ryan"
```

---

### `mail` — Apple Mail

```bash
# Create a draft (does not send)
macos mail draft --to "ryan@example.com" --subject "Invoice" --body "See attached."

# Send immediately
macos mail send --to "ryan@example.com" --subject "Invoice" --body "See attached." --cc "boss@example.com"

# Search messages
macos mail search "invoice" --json
macos mail search "Ryan" --limit 20 --json

# Read full message content
macos mail read "invoice" --json

# Delete messages
macos mail delete "old newsletter" --limit 5

# Mark messages
macos mail mark "invoice" --read
macos mail mark "important email" --flagged

# List mailboxes / folders
macos mail mailboxes --json
macos mail mailboxes --account "Gmail" --json

# Reply to a message
macos mail reply "Re: invoice" --body "Thanks, will process now."
macos mail reply "all-hands" --body "Noted." --all   # reply-all

# List accounts
macos mail accounts --json
```

---

### `photos` — Apple Photos

```bash
macos photos albums --json           # list all albums with photo count
macos photos search "sunset" --json
macos photos recent --limit 10 --json
```

---

### `music` — Apple Music

```bash
macos music status                   # current track + playback state
macos music status --json

macos music play
macos music pause
macos music next
macos music prev

macos music volume                   # get current volume (0–100)
macos music volume 50                # set volume to 50

macos music search "Daft Punk"       # search library and play first result
```

**`status --json` returns:**
```json
{"state": "playing", "track": "Get Lucky", "artist": "Daft Punk", "album": "Random Access Memories", "duration": 248, "position": 43, "volume": 72}
```

---

### `safari` — Safari control

```bash
macos safari tabs --json             # list all open tabs (title + URL)
macos safari open "https://example.com"
macos safari read                    # get text content of current tab
macos safari execute "document.title"  # run JavaScript in current tab
```

---

### `screenshot` — Screen capture

```bash
# Full screen
macos screenshot full --output ~/Desktop/shot.png

# Specific app window (requires Screen Recording permission)
macos screenshot window --app "Terminal" --output /tmp/term.png

# Region (points from top-left)
macos screenshot region --x 0 --y 0 --width 800 --height 600 --output /tmp/region.png
```

---

### `ocr` — Vision OCR

Read text from the screen or an image file using Apple's Vision framework. Runs fully on-device, no network call.

```bash
# OCR the entire screen
macos ocr full
macos ocr full --json                # ["line one", "line two", ...]

# OCR a screen region (x y width height, in points)
macos ocr region --x 100 --y 200 --width 600 --height 300

# OCR an image file (JPEG, PNG, HEIC, etc.)
macos ocr file --path ~/Desktop/receipt.png
macos ocr file --path /tmp/screenshot.png --json
```

---

### `mouse` — Cursor control

```bash
macos mouse position --json          # {"x": 500, "y": 300}

macos mouse move --x 500 --y 300
macos mouse click --x 500 --y 300
macos mouse click --x 500 --y 300 --right   # right-click
macos mouse drag --from-x 100 --from-y 100 --to-x 500 --to-y 500
macos mouse scroll --x 500 --y 300 --delta-y -3
```

---

### `keyboard` — Keyboard input

```bash
# Type text into the frontmost app
macos keyboard type "Hello, world"
macos keyboard type "Hello" --delay 50    # 50ms between keystrokes

# Send a key or shortcut
macos keyboard key "return"
macos keyboard key "cmd+c"
macos keyboard key "cmd+shift+4"
macos keyboard key "escape"
```

Common key names: `return` `escape` `tab` `space` `delete` `up` `down` `left` `right` `f1`–`f12`

---

### `ax` — Accessibility tree

Interact with any app's UI elements by name — no screen coordinates needed.

```bash
# Find UI elements matching a name
macos ax find "OK" --app "Safari" --json

# Click a UI element by name
macos ax click "OK"
macos ax click "Reminders" --app "Finder"

# Dump the UI tree of an app (top 2 levels)
macos ax read "Safari" --json
macos ax read "Finder"
```

**`find --json` returns:**
```json
[{"role": "AXButton", "name": "OK", "x": 845, "y": 512}]
```

---

### `window` — Window management

```bash
macos window list --json             # all visible windows with position + size

macos window move --app "Safari" --x 0 --y 0
macos window resize --app "Safari" --width 1200 --height 800
macos window focus --app "Terminal"
macos window minimize --app "Safari"
```

---

### `finder` — Finder integration

```bash
macos finder selected                # paths of selected files in Finder
macos finder selected --json         # as JSON array

macos finder cwd                     # current folder in front Finder window
macos finder cwd --json              # {"path": "/Users/you/Desktop"}

macos finder reveal ~/Desktop/file.txt   # reveal in Finder
macos finder open ~/Desktop/folder       # open in Finder
```

---

### `system` — System state

```bash
macos system battery --json
# {"level": 87, "charging": false, "plugged_in": true}

macos system audio volume            # get current volume
macos system audio mute              # toggle mute
macos system audio devices --json
macos system audio now-playing --json

macos system wifi status --json      # SSID, channel, security
macos system clipboard               # read clipboard to stdout
macos system display --json
```

---

### `apps` — Application management

```bash
macos apps list --json               # installed apps
macos apps list --all --json         # all apps with full paths

macos apps launch "Safari"
macos apps quit "Safari"
macos apps quit "Xcode" --force

macos apps info "Final Cut Pro" --json
```

---

### `storage` — Disk info

```bash
macos storage volumes --json         # mounted volumes with usage
macos storage usage                  # disk usage at /
macos storage usage ~/Developer --json
```

---

### `notify` — Notifications

```bash
macos notify send --title "Build complete"
macos notify send --title "Reminder" --body "Follow up with team" --subtitle "Work"
macos notify send --title "Done" --sound "Glass"
```

---

### `speech` — Text-to-speech

```bash
macos speech say "Meeting in 10 minutes"
macos speech say "Hello" --voice "Samantha" --rate 180
macos speech say "This is a recording" --output ~/Desktop/note.aiff

macos speech voices --json           # list all available voices
```

---

### `info` — System diagnostics

```bash
macos info system --json             # macOS version, hardware model
macos info network --json            # interfaces and IP addresses
macos info power                     # sleep and power settings
macos info spotlight                 # Spotlight index status
macos info keychain                  # Keychain summary
```

---

### `shortcuts` — Apple Shortcuts

```bash
# List all shortcuts
macos shortcuts list
macos shortcuts list --json          # ["Shortcut 1", "Shortcut 2", ...]

# Run a shortcut by name
macos shortcuts run "Morning Focus"
macos shortcuts run "Resize Image" --input "~/Desktop/photo.jpg" --json
```

**`run --json` returns:**
```json
{"name": "Morning Focus", "output": ""}
```

---

### `pdf` — PDF text extraction

Extract text from PDFs on-device via Apple's PDFKit — no network, no cloud.

```bash
# Extract all text
macos pdf text --path ~/Desktop/contract.pdf

# Single page
macos pdf text --path ~/Desktop/contract.pdf --page 3

# JSON output (array of {page, text} objects)
macos pdf text --path ~/Desktop/contract.pdf --json

# File metadata
macos pdf info --path ~/Desktop/contract.pdf --json
```

**`info --json` returns:**
```json
{"page_count": 12, "title": "Q1 Invoice", "author": "Ryan B.", "created": "2026-01-15T00:00:00Z", "encrypted": false}
```

---

### `focus` — Focus mode and Do Not Disturb

```bash
# Current state
macos focus status --json            # {"dnd_active": false}

# List all configured Focus modes
macos focus modes --json

# Toggle legacy DND (see limitations in CHANGELOG)
macos focus on
macos focus off
```

> For named Focus modes (Work, Personal, Sleep), create an Apple Shortcut and invoke it with `shortcuts run`.

---

### `process` — Process management

```bash
# List top processes by CPU (default)
macos process list --json
macos process list --sort mem --limit 10 --json

# Find by name (substring match)
macos process find "Safari" --json

# Kill a process
macos process kill --pid 1234
macos process kill --name "Safari"           # first match
macos process kill --name "Safari" --all     # all matches
macos process kill --name "MyApp" --signal KILL
```

**`list --json` returns:**
```json
[{"pid": 1234, "cpu": 2.3, "mem": 1.5, "name": "/Applications/Safari.app/Contents/MacOS/Safari"}]
```

---

### `disk` — Volume management

```bash
# List all disks and volumes
macos disk list --json

# Detailed info
macos disk info /dev/disk2 --json
macos disk info /Volumes/BackupDrive --json

# Eject (safe removal)
macos disk eject /Volumes/BackupDrive
macos disk eject /dev/disk2

# Unmount without ejecting
macos disk unmount /Volumes/BackupDrive
macos disk unmount /Volumes/BackupDrive --force

# Mount
macos disk mount /dev/disk2s1
macos disk mount ~/Desktop/image.dmg
```

---

### `location` — GPS coordinates

```bash
macos location get                   # 34.052235, -118.243683 (±15m)
macos location get --json
macos location get --timeout 30      # longer timeout for low-signal environments
```

**`get --json` returns:**
```json
{"latitude": 34.052235, "longitude": -118.243683, "accuracy_meters": 14.8, "timestamp": "2026-05-18T13:00:00Z"}
```

Requires Location Services permission. macOS will show "Command Line Tool" in System Settings → Privacy → Location Services.

---

### `contacts` — Apple Contacts (write operations)

```bash
# Create a contact
macos contacts create --first-name "Ryan" --last-name "B." \
  --phone "+13105550100" --phone-label "mobile" \
  --email "ryan@example.com" --email-label "work" \
  --json

# Update an existing contact
macos contacts update "AB12CD34-..." \
  --add-phone "+13105559999" \
  --add-phone-label "work" \
  --json

# Delete a contact
macos contacts delete "AB12CD34-..." --json
```

---

### `defaults` — macOS user defaults

Read and write app preferences stored in macOS user defaults (plist system).

```bash
# Read a value
macos defaults read --domain com.apple.finder --key AppleShowAllFiles

# Write a value
macos defaults write --domain com.apple.finder --key AppleShowAllFiles --value YES --type bool

# Delete a key
macos defaults delete --domain com.apple.finder --key AppleShowAllFiles

# List all domains
macos defaults list-domains --json
```

---

### `keychain` — Keychain access

Read and write secrets stored in the macOS Keychain.

```bash
# Get a password
macos keychain get --service "example-service" --json

# Save or update a password
macos keychain set --service "my-service" --account "username" --password "secret" --update

# Delete a Keychain item
macos keychain delete --service "my-service" --account "username"

# List Keychain service/account metadata (no passwords exposed)
macos keychain list --query "aura" --json
```

---

### `network` — Network diagnostics

```bash
# Ping a host
macos network ping --host 8.8.8.8 --count 4 --json

# DNS lookup
macos network dns --host example.com --json

# Check if a port is open
macos network port --host example.com --port 443 --json

# Traceroute
macos network traceroute --host example.com --max-hops 20

# List network interfaces and IPs
macos network interfaces --json
```

---

### `setup` — Permission checker

```bash
macos setup
```

Checks every capability and prints a green checkmark or red X. Run after install or after granting new permissions.

---

## Permissions

macOS will prompt on first use for each protected API. Grant in advance at **System Settings → Privacy & Security**:

| Permission | Required for |
|---|---|
| Reminders | `macos reminders` |
| Calendars | `macos calendar` |
| Contacts | `macos contacts` |
| Screen Recording | `macos screenshot window` |
| Accessibility | `macos mouse` `macos keyboard` `macos ax` |
| Automation | `macos messages` `macos mail` `macos photos` `macos music` `macos safari` `macos finder` |

No permissions required: `system` `apps` `storage` `notify` `speech` `info` `notes` `ocr full/file` `screenshot full/region` `pdf` `process` `disk` `focus` `shortcuts`

| Permission | Required for |
|---|---|
| Location Services | `macos location get` |

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

Maps to: `macos reminders create --title <title> [--due <due>] [--list <list>] [--notes <notes>] --json`

### Example: check calendar before scheduling

```bash
COUNT=$(macos calendar events --from 2026-05-20 --to 2026-05-20 --json \
  | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
echo "$COUNT events on that day"
```

### Example: OCR a receipt and extract the text

```bash
macos ocr file --path ~/Desktop/receipt.png --json \
  | python3 -c "import sys,json; print('\n'.join(json.load(sys.stdin)))"
```

### Example: click a UI element without knowing its coordinates

```bash
macos ax click "Sign In" --app "Safari"
```

---

## Build from source

```bash
git clone https://github.com/manuaudio/macos-cli
cd macos-cli

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
