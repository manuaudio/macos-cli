## Unreleased

### Added
- **`macos commands --json`.** Every command with its flags, one line of help and whether it writes; `SKILL.md` is generated from it (`bash scripts/gen-skill.sh`).

## 0.9.0 — 2026-11-10

An agent can find out what it may do, and cannot widen it; calendars by id; faster Mail, Contacts and Reminders.

### Added
- **A signed, notarized Release, installed with one line.** `curl -fsSL https://raw.githubusercontent.com/manuaudio/macos-cli/main/install.sh | bash` downloads the Release binary and checks its sha256, Developer ID signature, team and version before installing it; no Xcode needed. A source build is `MACOS_CLI_SIGN_MODE=adhoc ./install.sh`.
- **`macos update [--check]`.** Replaces the binary with the newest Release at the same path, after the same checks, so the permissions macOS granted it stay with it.
- **Homebrew:** `brew install manuaudio/tap/macos-cli`.
- **`macos doctor [--for-agent | --json]`.** Every macOS privacy area this binary may need, its state and the fix, plus the binary's identity, the session and the resolved `auth.json` policy. It never prompts.
- **`macos authorize <area>`.** Asks macOS for one area (bounded by `--timeout`), or opens its settings pane.
- **`--calendar-id`** on `calendar events`, `export`, `create`, `update` and `delete`. `calendar calendars --json` adds `kind`, `source`, `writable` and `color`.
- **`calendar update --alarm/--clear-alarms`**, **`--timezone`** on events, export, create and update, **`calendar export --since`**, and `--start`/`--end` accepted for `--from`/`--to`.
- **`contacts export --since TOKEN`** with the `history_token` every export now carries.
- **`mail read --id MESSAGE_ID`**, and `--mailbox`/`--account` on `mail search` and `mail read`; results carry `message_id`, `account` and `date_sent`.

### Changed
- **Not found is exit 3, not a usage error.** A missing directory (`file list`, `finder`), a PDF page, a Space, an accessibility hint or an audio device that does not exist now fails with `not_found` (exit 3); a file that is not UTF-8 text with `app_error` (exit 6). They used to exit 64 with usage text.
- **Widening the policy needs a person.** `auth grant`, `auth reset` and `auth setup` ask for a typed confirmation on the terminal; without one they refuse with `person_required` (exit 4). `auth setup --yes` is gone.
- **No unanswerable prompts.** Calendars, Reminders and Contacts are requested only when a person is at a terminal; elsewhere an undecided permission fails at once with `state: not_determined` instead of a 15 s timeout. The Contacts request is bounded.
- **A write by a shared calendar name is refused** (`ambiguous_calendar`, exit 64) with every matching id; it used to go to the first calendar of that name.
- **`setup`** exits 4 when something is missing and never reads stdin without a terminal.
- **Mail search** asks Mail one query per mailbox instead of three or four Apple events per message.
- **`contacts export`** returns contacts in the store's order (no sort), which was most of its time.
- **Reminders `update`, `delete` and `uncomplete`** look the reminder up by id instead of fetching every reminder.

### Fixed
- **Notes without Full Disk Access** reported `count: 0`; Notes reads now fail with `access_denied`, `area: full_disk_access`.

### One error contract for every command, and `--json` where the README promised it

#### Fixed
- **`--json` on the four exports.** `calendar export`, `contacts export`, `notes export` and `reminders export` always printed JSON but refused the flag with `Unknown option '--json'` (exit 64). They accept it now.
- **Notes bodies.** `notes export` read some valid bodies as missing: a heuristic rejected text that was mostly digits or punctuation. The decoder now follows the note's own protobuf path (document → note → text), validates every enclosing message and the gzip checksum, and returns the text verbatim. A password-protected note is refused explicitly, and missing data is an error, distinct from an empty body.
- **README examples.** `contacts update` takes the contact id as an argument, not `--id`; the README now says so, and the `system battery --json` sample shows the real keys.
- **Unknown calendar.** `calendar events --calendar NAME` (and `delete`, `update`, `create`) with a name that does not exist printed the root usage text; it now says which calendar is missing and exits 3.

#### Changed
- **Errors.** Under `--json`, and always for the exports, a failure is one JSON object on stdout with stderr empty: `ok: false`, `status: "error"`, a stable code in `error`, a `message`, often a `hint`, and the `exit_code`. Without `--json` a failure is one `Error:` line and a `Hint:` line on stderr, without the usage text.
- **Exit codes.** 64 usage (including a rejected value such as a bad date), 3 not found, 4 permission, 5 timeout, 6 app error. The JSON errors that 0.8 emitted with exit 1 keep their codes and keys and exit with the status from this table: `invalid_date`, `invalid_date_range`, `invalid_alarm` and `invalid_delete_mode` exit 64, `event_not_found` 3, `access_denied` 4, `fetch_timeout` 5.
- **Permission failures are told apart.** A capability turned off in `auth.json` is `capability_denied`; macOS privacy settings refusing access is `access_denied`; a permission request nobody answered is `timeout`. 0.8 reported all three as `access_denied`.
- **`auth.json` follows `HOME`.** The policy file is `$HOME/.config/macos-cli/auth.json`, so a test or a sandboxed agent can point it at its own file.
- **`script run --json`** returns `{"output", "stderr"}`.
- The version string lives in one place, `Sources/macos-cli/Version.swift`; the installer and its tests read it from there.
- **`make test` checks the README.** `scripts/tests/readme_examples_test.sh` fails when a README example names a command or option the binary lacks, and runs the read-only examples that need no permission.

#### Removed
- The GitHub Actions workflow and Dependabot configuration. Checks run locally: `make test`.

---

## 0.8.1 — 2026-07-18

Additive contact `job_title` read parity — no breaking changes.

### Added
- **`job_title` in `contacts get <id> --json`.** The single-contact read now carries the contact's job title alongside `id`, `name`, `organization`, `phones`, and `emails`. `contacts export` already emitted it; this brings the two read surfaces to parity.
- **Stable encoding, both surfaces.** `job_title` is a string that is **always present** — the title, or an **empty string `""`** when the contact has none. It is never `null` and never omitted, so an ingestion consumer sees one shape.
- **Verified read-after-write.** Because `job_title` reads back verbatim, an agent can confirm a `contacts update --job-title` write by re-reading `contacts get <id> --json` (or `export`) rather than assuming the mutation landed.

### Notes
- No `--json` field names changed and no keys were removed; `job_title` is purely additive. This release is output-compatible with 0.8.0 for every existing consumer.

---

## 0.8.0 — 2026-07-18

Calendar ingestion and safe deletes.

### Added
- **`calendar export`** — every event in a window as one envelope `{ok, status, count, filter, calendars, events}`, across all linked calendars from all sources. `--from` is inclusive, `--to` exclusive; both default to a ±1-year window. `--calendar NAME` is fail-closed: an unknown name returns zero events and zero calendars, never all of them.
- **Rich event fields** in `calendar events --json` and `export`: `source`, `location`, `notes`, `url`, `timezone`, `created`, `last_modified`, `status`, `availability`, `recurring`, `organizer`, `attendees`, `alarms`. They are additive; the six original keys are unchanged.
- **`calendar create --alarm N`** (repeatable, minutes before start). With no `--alarm` the event has no alarms.
- **`calendar delete --id ID`** removes exactly one occurrence by identifier. `--id` and `--title`/`--date` are mutually exclusive.

### Changed
- Strict date parsing: an impossible date such as `2026-02-30` or a range with `--from` after `--to` is a structured JSON error, never silently replaced with a default.

---

## 0.7.0 — 2026-07-18

One binary, built for unattended use.

### Changed
- **One executable.** The MCP server, the HTTP bridge and the generated tool definitions are gone; an agent runs `macos <area> <action> --json` as a subprocess. `install.sh` builds from source, signs and verifies the binary, and installs only `macos` to `~/.local/bin` (no sudo).
- **`reminders done` retired.** It was an ungated write; it now changes nothing and points to `reminders complete`.

### Added
- **`reminders status --json`** — the Reminders authorization state, without prompting.
- **`reminders export`** — every reminder as rich JSON; `--list NAME` is fail-closed. A fetch that exceeds `--timeout` is an error (`fetch_timeout`), never an empty list.
- **`reminders complete --id ID`** — a dry run unless `--approve` matches the `APPLE_EVENTKIT_APPROVE_TOKEN` environment variable. `complete-safe` is an alias.
- **`notes export`** — notes with full Unicode bodies from the local store; `--folder` is fail-closed.
- **`contacts export`** — every contact as rich JSON.
- **MacCLICore**, the pure logic behind those guarantees, with an XCTest suite and a dependency-free runner (`swift run MacCLICoreTestRunner`).

---

## 0.6.3 — 2026-05-28

Correctness pass — fixed broken human-readable output and removed all compiler warnings.

### Fixed
- **`file list`, `bluetooth list`, `trash list`, `login-items list` printed nothing in non-`--json` mode.** Their table renderers used `String(format: "%s", swiftString)`, but the C `%s` conversion expects a C string pointer, not a Swift `String` — so the formatted output came out empty. Rewrote all four to use new `padRight`/`padLeft` column helpers in `Helpers.swift`. (`--json` output was always correct and is unchanged.)
- **`process list` header was misaligned** with its data rows — the header used `%-8@` width specifiers (ignored by `%@`) while data rows used `%-8d` (honored). Both now use the shared padding helpers, so columns line up.
- **`system audio` / `audio list` device-name read** used `var name = "" as CFString` with `&name`, which raised a "forming UnsafeMutableRawPointer to a CFString" warning and was technically unsound. Reworked to `Unmanaged<CFString>?` with a `noErr` guard.

### Removed (dead code / warnings)
- Unused `displays` throwaway call in `screen info` (`ScreenCommand`).
- Two unused scaffolding blocks (`py`, `windowScript`) in `screenshot window` (`ScreenshotCommand`).
- Unused `script` variable and a misplaced "quit System Preferences" call in `system display brightness` (`SystemCommand`).
- Unused `runningApps` / `raw` bindings in `window focus` (`WindowCommand`).
- Replaced two crash-prone `as!` force-casts in `window list` with safe optional casts.

### Added
- `--json` flag on `mail draft` and `messages send` for parity with every other subcommand.
- `LICENSE` file (MIT) — the README badge and link previously pointed at a file that did not exist.

### Notes
- `swift build -c release` now completes with **zero warnings** (was 5).
- No `--json` field names changed; this release is output-compatible with 0.6.2.

---

## 0.6.2 — 2026-05-20

Personal-install wrapper layer.

### Added
- `tool-definitions/tools.json` — canonical machine-readable catalog of every CLI command, in OpenAI function-calling schema with extra `command` and `flags` routing fields.
- `macos-mcp/` — Bun/TypeScript MCP server exposing every tool to Claude Desktop and Claude Code over stdio. Compiles to a single `/usr/local/bin/macos-mcp` binary via `bun build --compile`.
- `macos-bridge/` — Bun/TypeScript HTTP server exposing the same tools at `http://localhost:2772/v1/tools` and `/v1/tool_calls` in OpenAI function-calling format. Drop-in for Ollama, LM Studio, Open WebUI, llama.cpp server. Ships with a user-level `com.macos-cli.bridge` LaunchAgent template.
- `install.sh` now optionally builds both wrappers when `bun` is available and (with a y/N prompt) enables the LaunchAgent. Silently skips when `bun` is absent — vanilla CLI install always succeeds.

### Notes
- Auth-denied results from the binary surface as structured tool errors in both wrappers (`isError: true` for MCP, `{"error": "capability denied: ..."}` inside the tool-call response for the bridge) — never as transport-level failures.
- The wrappers are wholly additive — the Swift CLI itself is unchanged in this release (apart from the version string).
- v0.6.1 was skipped — it was used as a working version during scaffolding.

---

## [0.5.7] — 2026-05-19

### Renamed

- Project renamed from `apple-cli` to `macOS CLI`. Binary: `apple` → `macos`. Repo: manuaudio/apple-cli → manuaudio/macos-cli.

### Added — 6 new commands + 2 extensions

- `bluetooth` — list paired devices, connect, disconnect (IOBluetooth.framework)
- `trash` — move file/dir to trash, empty trash, list trash contents
- `spotlight` — search files via mdfind; filter by kind (app/image/pdf/audio/video/document/folder), limit results, scope to directory
- `file` — headless file ops: list directory, copy, move, delete, stat, read text files
- `login-items` — list/add/remove login items via System Events
- `dock` — list/add/remove pinned apps, restart Dock
- `system vpn` — VPN status/connect/disconnect via scutil
- `system display wallpaper` — get current wallpaper per display, set wallpaper on all displays

### Note on notify list/clear

`UNUserNotificationCenter` requires a bundle identifier — it crashes from a non-bundled CLI binary. `notify send` works fine (osascript). `list` and `clear` were removed as they cannot work from a CLI tool without a bundle.

---

# Changelog

Honest version history. Each entry documents what works, what was broken, and what was fixed.

---

## [0.5.6] — 2026-05-18

### Added — four capabilities that scripts had been working around

- **`apple contacts create/update --job-title`** — first-class job-title field on both create and update. Previously callers had to fold job title into `--note` as `Title: <value>` because the flag didn't exist.
- **`apple calendar reload`** — force Calendar to refresh from iCloud / CalDAV sources. Uses EventKit's `refreshSourcesIfNecessary()` directly (no AppleScript / Calendar.app dependency).
- **`apple mail refresh`** — force Mail.app to check all accounts for new mail. Wraps `tell application "Mail" to check for new mail` AppleScript inside the CLI so callers don't have to construct osascript shell commands themselves.
- **`apple contacts get-note <id>` + `apple contacts set-note <id> --text "..." [--if-empty]`** — read/write the contact note field. macOS 13+ gates `CNContactNoteKey` behind the `com.apple.developer.contacts.notes` entitlement that un-entitled binaries (including apple-cli and pyobjc) can't satisfy. AppleScript routes through Contacts.app — which IS entitled — so we wrap that path inside the CLI for the note field only. Same wrapped-AppleScript pattern as `mail refresh`.

### Why these landed together
Scripts that moved from raw `osascript` to the CLI had to work around these four missing commands. v0.5.6 adds them, so those scripts no longer need their own AppleScript.

---

## [0.5.3] — 2026-05-19

### Fixed — agent usability audit

- **`Process.capture(timeout:)`** — fixed pipe deadlock: commands with large output (e.g. `process list` with 700+ process lines) would fill the 64 KB pipe buffer and hang indefinitely. Pipe is now drained asynchronously in a background handler, unblocking the process and the timeout loop.
- **`apple process list/find`** — added 10s timeout to the `ps -axo` call; was never timing out before (no timeout), causing indefinite hang if ps deadlocked.
- **`apple notes create`** — added 10s timeout to osascript; previously hung forever if Notes Automation permission wasn't granted. Now exits 64 with a clear permission error.
- **`apple calendar delete`** — added `--json` flag; previously returned plain text `"deleted N"` with no JSON output, breaking agents that check exit + parse JSON.
- **`apple music search`** — added `--json` flag; previously had no JSON output mode. Also replaced `music.sources.whose({kind: "library"})` JXA API (fails with -1708 on some Music versions) with `music.tracks()` filter approach. Fixed `jxa()` helper to return nil on empty osascript output instead of passing empty string through.
- **`apple photos recent`** — added 30s timeout to osascript call; previously no timeout, could hang indefinitely on large libraries.
- **`apple photos search`** — increased timeout 20s → 45s for large photo libraries.
- **`apple mail search`** — increased timeout 20s → 45s for large mailboxes.
- **`apple speech voices --json`** — locale field was unreliable (wrong values for some voices due to fragile double-space split). Now uses regex `[a-z]{2}_[A-Z]{2}` to extract locale reliably.

### Agent readiness after this patch
All 30 commands tested. Confirmed: valid JSON on stdout, non-zero exit on error, no hangs. Agents can safely call all commands with a 30–60s timeout wrapper.

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

- **`focus`** — read and set macOS Focus / Do Not Disturb state
  - `focus status` — returns `{"dnd_active": bool, "modes": [...], "assertion_count": int}`
  - `focus modes` — lists all configured Focus modes with identifiers
  - `focus on [--mode <identifier>]` / `focus off` — read/write Assertions.json directly + SIGHUP donotdisturbd; no legacy defaults hack

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
