# Changelog

All notable changes to apple-cli are documented here.

## [0.9.0] — 2026-05-17

### Added
- `ocr file --path` — OCR any image file (JPEG, PNG, HEIC) using Vision framework
- `finder cwd --json` — `cwd` now supports `--json` flag, returns `{"path": "..."}`

### Fixed
- `system audio devices --json` — output now returns clean normalized fields (`name`, `manufacturer`, `type`, `input_channels`, `output_channels`, `default_input`, `default_output`) instead of raw `system_profiler` internal keys (`_name`, `_items`, `coreaudio_*`)
- README corrected: `ocr full --json` returns a JSON array of strings, not `{"text": "..."}`
- README corrected: `system wifi` command is `apple system wifi status --json`, not `apple system wifi --json`

### Changed
- README completely rewritten: install command is now the first section, all 24 subcommands documented (mouse, keyboard, ax, ocr, screenshot, window, safari, mail, messages, photos, music, finder, setup were all missing), version badge updated from 0.3.0 to 0.9.0

## [0.8.0] — 2026-05-17

### Added
- `ocr` — OCR the full screen or a region using Apple Vision framework (`ocr full`, `ocr region`)
- `window` — list, move, resize, focus, and minimize app windows (`window list`, `window move`, `window resize`, `window focus`, `window minimize`)
- `music` — control Apple Music playback (`music status`, `music play`, `music pause`, `music next`, `music prev`, `music volume`, `music search`)
- `finder` — interact with Finder (`finder selected`, `finder reveal`, `finder open`, `finder cwd`)
- `calendar delete` — delete a calendar event by ID using EventKit

### Fixed
- `storage volumes` crash on volumes with missing size fields
- `messages conversations` returning empty output on fresh installs

## [0.7.0] — 2026-05-16

### Added
- `setup` Screen Recording permission check — `apple setup` now verifies screenshot captures actual window content (not blank wallpaper)

## [0.6.0] — 2026-05-16

### Added
- `setup` — interactive permission checker and capability verifier (`apple setup`)
- `install.sh` — one-command installer: clones, builds, installs to `/usr/local/bin`, runs `apple setup`

## [0.5.0] — 2026-05-15

### Added
- `mouse` — cursor control: move, click (left/right), drag, scroll, get position
- `keyboard` — type text and send key shortcuts (e.g. `cmd+c`, `escape`, `return`)
- `ax` — accessibility tree: find UI elements by name, click by name, dump app UI tree
- `screenshot` — capture full screen, specific app window, or screen region to file
- `safari` — list tabs, open URLs, read page text content, execute JavaScript
- `mail` — create drafts, search messages, list accounts
- `messages` — send iMessages/SMS, list recent conversations
- `photos` — list albums, search photos, list recent photos
- `system wifi` — Wi-Fi status, network scan, join/leave network

## [0.4.0] — 2026-05-14

### Changed
- `notes` — switched from JXA to direct SQLite read (no Automation TCC permission required, significantly faster)

## [0.3.0] — 2026-05-13

### Added
- `system` — battery, audio (volume/mute/devices/now-playing), Wi-Fi, clipboard, display
- `apps` — list installed apps, launch, quit, get app info
- `screen` — screen info, lock screen
- `storage` — mounted volumes, disk usage at any path
- `notify` — post a Notification Center banner
- `speech` — text-to-speech, list voices, save to audio file
- `info` — system info, network interfaces, power settings, Spotlight, Keychain

## [0.2.0] — 2026-05-12

### Added
- `notes` — list, search, read, and create Apple Notes via JXA

## [0.1.0] — 2026-05-10

### Added
- `reminders` — list, create, complete reminders; list reminder lists
- `calendar` — list upcoming events, create events (with automatic 1-day and 1-hour alerts), list calendars
- `contacts` — search by name/email/phone, get full record by ID
- `--json` flag on all read commands for LLM-friendly output
