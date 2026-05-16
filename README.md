# apple-cli

A generic macOS command-line interface for native Apple data — Reminders, Calendar, and Contacts. Built for AI agents (LLM tool use) but useful for any scripting context.

## Install

```bash
swift build -c release
install .build/release/apple-cli $(go env GOPATH)/bin/apple
```

Or via the Makefile:
```bash
make install
```

## Usage

### Reminders

```bash
# Create
apple reminders create --title "Email Ryan about deposit" --due 2026-05-20 --list "Reminders" --notes "gigs | priority: high"

# List
apple reminders list
apple reminders list --list "Reminders" --json

# Complete
apple reminders done <identifier>

# Show all lists
apple reminders lists
```

### Calendar

```bash
# List events (today + 7 days)
apple calendar events

# Custom range
apple calendar events --from 2026-05-16 --to 2026-05-23 --json

# Create event (always adds 1-day + 1-hour alerts)
apple calendar create \
  --title "Soundcheck — Orpheum" \
  --start "2026-05-20 14:00" \
  --end "2026-05-20 17:00" \
  --calendar "Work" \
  --location "842 S Broadway, Los Angeles"

# List calendars
apple calendar calendars --json
```

### Contacts

```bash
# Search by name, phone, or email
apple contacts search "Ryan"
apple contacts search "ryan@example.com" --json

# Get by ID
apple contacts get <identifier> --json
```

## Design

- **No personal data hardcoded** — generic tool, works for any user
- **JSON output** on all commands via `--json` flag — compatible with LLM tool use
- **Deterministic auth** — uses semaphore + runloop thread; no NSApplication needed
- **Calendar alerts** — every created event gets 1-day + 1-hour alerts (macOS Calendar best practice)
- **TCC-aware** — requests access at first use; macOS will prompt if not granted

## Requirements

- macOS 13+
- Swift 5.9+
- TCC permissions: grant access to Reminders, Calendar, and Contacts in **System Preferences > Privacy & Security**

## License

MIT
