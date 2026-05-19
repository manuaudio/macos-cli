# Changelog

Honest version history. Each entry documents what works, what was broken, and what was fixed.

---

## [0.5.2] — 2026-05-18

### Added — 6 new commands (30 total)

- **`shortcuts`** — list and run Apple Shortcuts from the CLI
  - `shortcuts list` — lists all shortcuts (name only, 0 shortcuts if none configured)
  - `shortcuts run <name>` — runs a named shortcut with optional stdin input and 30s timeout
  - `--json` on run returns `{"name", "output"}`

- **`pdf`** — extract text and metadata from PDF files via PDFKit (on-device, no network)
  - `pdf text --path <file>` — extract all text; `--page N` for a single page
  - `pdf info --path <file>` — page count, author, title, creator, created/modified dates, encryption status

- **`focus`** — read macOS Focus mode and Do Not Disturb state
  - `focus status` — returns `{"dnd_active": bool, "mode": string, "assertion_count": int}`
  - `focus modes` — lists all configured Focus modes with identifiers
  - `focus on` / `focus off` — enables/disables legacy DND via `com.apple.notificationcenterui` defaults
  - **Known limitation:** `focus on/off` uses the legacy defaults approach which does not toggle named Focus modes on Ventura. Status reads are accurate (Assertions.json). For named Focus modes, create an Apple Shortcut and call it via `shortcuts run`.

- **`process`** — list and kill running processes
  - `process list [--sort cpu|mem|name|pid] [--limit N]` — top N processes by chosen sort key
  - `process find <name>` — substring match across all running processes
  - `process kill --pid N` or `--name <name>` — sends TERM (or `--signal KILL/HUP/etc.`) to matching process(es); `--all` for multiple matches

- **`disk`** — mount, unmount, eject, and inspect volumes
  - `disk list` — all disks and partitions with device, name, size, mount point
  - `disk info <path>` — detailed info for a device path or mount point
  - `disk eject <path>` — eject a volume (safe removal)
  - `disk unmount <path>` — unmount without ejecting; `--force` for busy volumes
  - `disk mount <path>` — mount a device or `.dmg`/`.iso` file

- **`location`** — GPS coordinates via CoreLocation
  - `location get` — returns `{"latitude", "longitude", "accuracy_meters", "timestamp"}`
  - Requires Location Services permission; 15s timeout by default
  - **Known limitation:** requires interactive permission grant on first use; CLI apps show "Command Line Tool" in Location Services

- **`contacts create`** — create a new contact with name, phones, emails, org, note
- **`contacts update <id>`** — add phone/email or update name/org/note on existing contact
- **`contacts delete <id>`** — delete a contact by identifier

### No regressions
All 24 previously-existing commands verified working in this release. Bug fixes from 0.5.1 unchanged.

---

## [0.5.1] — 2026-05-18

### Fixed — remaining known issues from 0.5.0
- **`reminders done`** — no `--json` flag. Now returns `{"id", "title", "completed": true, "completion_date"}`.
- **`calendar create --json`** — missing `all_day` field in response. Now always present.
- **`calendar create --all-day`** — date-only strings (`YYYY-MM-DD`) were rejected; only `YYYY-MM-DD HH:MM` was accepted. Now both formats work; `--all-day` with a date-only string defaults end to start+1 day.
- **`notify send`** — no `--json` flag. Now returns `{"sent": true, "title", "body"}`.
- **`info power settings --json`** — returned `{"raw": "..."}` (unparsed pmset blob). Now parses pmset output into structured keys (`displaysleep`, `sleep`, `lowpowermode`, etc.) with correct types (int for numbers, bool for 0/1 flags).
- **`info network --json`** — inconsistent field shape per interface (missing fields instead of nulls). Now always emits `name`, `ipv4`, `mac` with explicit `null` when absent.
- **`ax read`** — required `--app <name>` flag but help text implied positional. Now accepts `apple ax read Finder` (positional) or `--app Finder` (option). Frontmost app when omitted.
- **`system display brightness`** — silently exited 0 when `brightness` CLI was missing. Now exits non-zero with a clear install instruction.

### Known flakiness (not a code bug)
- `apple setup` Mail check occasionally shows ❌ due to JXA permission state in macOS not refreshing immediately after permission grant. `apple mail accounts` works correctly when called directly. Run `apple setup` again if Mail shows red after granting Automation permission.

---

## [0.5.0] — 2026-05-18

### Fixed — critical hangs
- **`mail search` hangs indefinitely** on large mailboxes — was iterating `m.content()` across every message in every account via JXA with no timeout. Now uses 20s timeout; returns a clear error if exceeded instead of hanging forever.
- **`photos search` hangs indefinitely** on large libraries — same root cause (JXA iterating all items). Fixed with 20s timeout.
- **`info spotlight` hangs on first invocation** — `mdfind` without `--onlyin` triggered a metadata log parse that stalled. Now enforces a 15s timeout and surfaces a helpful error suggesting `--onlyin <dir>`.

### Fixed — JSON correctness
- **`system audio mute`** had no `--json` flag (`--json` returned exit 64). Now returns `{"muted": true/false}` for both get and set.
- **`system audio devices --json`** was returning raw `system_profiler` internal keys (`_name`, `_items`, `coreaudio_*`). Now returns clean fields: `name`, `manufacturer`, `type`, `default_input`, `default_output`, `input_channels`, `output_channels`.
- **`speech voices --json`** — `sample` field included a leading `#` from the `say -v ?` output format separator. Now stripped.
- **`system wifi status --json`** — `mac` field was always `""` (macOS Ventura redacts BSSID in system_profiler). Now omitted when empty rather than returning a misleading empty string.
- **`finder cwd`** — missing `--json` flag. Now returns `{"path": "..."}`.

### Known issues (not yet fixed)
- `info power settings --json` returns `{"raw": "..."}` instead of structured keys
- `info network --json` — inconsistent field shape per interface (no nulls for missing fields)
- `system display brightness` exits 0 when `brightness` CLI is missing — should be non-zero
- `ax read` — requires `--app <name>` flag but help implies positional; confusing UX
- `reminders done` — no `--json` flag
- `calendar create --json` — missing `all_day` field in response
- `notify send` — no `--json` flag

### Changed
- Version reset from inflated 0.9.0 → honest **0.5.0**. 24 subcommands exist but 3 had critical hangs, 8 had JSON bugs, and several lacked `--json` flags. 0.9.0 implied near-release quality; 0.5.0 reflects real state.

---

## [0.4.1] — 2026-05-17 (previously mislabeled 0.9.0)

### Added
- `ocr file --path` — OCR any image file (JPEG, PNG, HEIC) via Vision framework; returns JSON array of text lines
- Complete README rewrite: install curl command at top, all 24 subcommands documented (was stuck at 0.3.0 docs)
- CHANGELOG introduced

### Fixed (partial — full fix in 0.5.0)
- `system audio devices --json` — partial key normalization
- `finder cwd --json` — flag was completely absent

---

## [0.4.0] — 2026-05-17 (previously mislabeled 0.8.0)

### Added
- `ocr` — full screen and region OCR via Apple Vision framework
  - **Note:** `--json` returns a flat array of strings (one per text line), not `{"text": "..."}` as some early docs incorrectly stated
- `window` — list, move, resize, focus, minimize app windows
- `music` — control Apple Music: status, play, pause, next, prev, volume, search library
- `finder` — Finder integration: selected files, reveal, open, cwd
- `calendar delete` — delete events by EventKit ID

### Fixed
- `storage volumes` crash on volumes with missing size fields
- `messages conversations` returning empty output on fresh installs

---

## [0.3.0] — 2026-05-16 (previously labeled 0.7.0 / 0.6.0)

### Added
- `setup` — interactive permission checker; green/red per capability; run after install to verify
- `install.sh` — one-command installer: clone → build → install to `/usr/local/bin` → run setup
- `setup` Screen Recording verification — confirms screenshots capture real window content, not blank wallpaper

---

## [0.2.0] — 2026-05-15 (previously labeled 0.5.0)

### Added
- `mouse` — move, click (left/right), drag, scroll, get position
- `keyboard` — type text with configurable keystroke delay; send key shortcuts (`cmd+c`, `escape`, etc.)
- `ax` — accessibility tree: find/click UI elements by name, dump app UI tree
  - **Known issue:** `ax read` requires `--app <name>` flag but overview implies positional argument
- `screenshot` — full screen, specific app window (Screen Recording required), screen region
- `safari` — list tabs, open URLs, read page text, execute JavaScript in current tab
- `mail` — create drafts, search messages (critical hang bug — fixed in 0.5.0), list accounts
- `messages` — send iMessages/SMS, list recent conversations
- `photos` — list albums, search library (critical hang bug — fixed in 0.5.0), list recent photos
- `system wifi` — Wi-Fi status (mac field always empty in 0.2.0–0.4.1, fixed in 0.5.0), network scan, join/leave

---

## [0.1.1] — 2026-05-14 (previously labeled 0.4.0)

### Changed
- `notes` — switched from JXA to direct SQLite read; eliminates Automation TCC requirement, significantly faster

---

## [0.1.0] — 2026-05-13 (previously labeled 0.3.0)

### Added
- `reminders` — list, create, complete reminders; list reminder lists
  - **Known issue:** `reminders done` has no `--json` flag
- `calendar` — list upcoming events, create events with automatic alerts, list calendars
  - **Known issue:** `calendar create --json` response missing `all_day` field
- `contacts` — search by name/email/phone, get full record by ID
- `system` — battery, audio, clipboard, display
- `apps` — list installed apps, launch, quit, get app info
- `storage` — mounted volumes, disk usage at any path
- `notify` — Notification Center banner (no `--json` flag)
- `speech` — text-to-speech; list voices (`sample` field had `#` prefix bug — fixed in 0.5.0)
- `info` — system info, network interfaces, power settings (unparsed blob), Spotlight search, Keychain
- `notes` — list, search, read, create
- `--json` flag on all read commands for LLM-friendly output
