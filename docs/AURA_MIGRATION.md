# Aura Migration — macos-cli 0.7.0

## Source of truth

macos-cli **0.7.0** is the one source implementation and the only installed
executable. It lives at:

```
$HOME/.local/bin/macos
```

There is **one CLI** — no MCP server, no HTTP bridge, no second executable.
Any surface that used to shell out to Aura's standalone Swift EventKit helper
must route through this binary instead.

## Command mappings

Aura must replace all direct invocation of
`tools/apple-eventkit/apple_eventkit.swift` (and its compiled helper) with these
exact CLI calls:

| Purpose            | Command |
|--------------------|---------|
| Authorization      | `macos reminders status --json` |
| Reminders export   | `macos reminders export [--list NAME] [--include-completed] [--timeout SECONDS]` |
| Reminder completion| `macos reminders complete --id ID [--approve TOKEN] --json` |
| Notes export       | `macos notes export [--folder NAME] [--limit N] [--include-deleted]` |
| Contacts export    | `macos contacts export [--limit N]` |
| Calendar reads     | `macos calendar export --from YYYY-MM-DD --to YYYY-MM-DD` *(rich envelope — see 0.8.0 section below)* |

## Invariants that must be preserved

### Empty-fetch cache deletion guard

A successful fetch that returns **zero rows** may update freshness metadata but
**must not soft-delete** existing cached reminders — unless an independently
verified healthy-fetch policy explicitly allows it. A timeout or error is
**never** to be interpreted as "empty." Only a fetch that is positively known to
have succeeded can be treated as an authoritative zero.

### Approval-token policy

The reminder completion gate requires a **non-empty** `APPLE_EVENTKIT_APPROVE_TOKEN`
that matches exactly. Preserve this policy unchanged:

- Never log, print, or persist the token — not in stdout, stderr, logs, cache,
  or Postgres.
- Completion **dry-runs** (no write) whenever the exact token is not supplied.
- The legacy `reminders done` command is **retired** — do not call it.

## JSON / failure invariants

- **Unknown list or folder** → returns **zero** rows (fail-closed filter), not an
  error and not the full unfiltered set.
- **Reminder fetch timeout** → emits structured JSON with `status=error` and
  `error=fetch_timeout` on stdout, and exits **nonzero**. On timeout there is
  **no `rows` array** in the payload — timeout is not an empty result.
- **Completion without the exact token** → dry-runs (no EventKit write) rather
  than mutating state.

## Migration sequence

Do these in order. Do not delete Aura's standalone implementation until the CLI
path is proven live.

1. **Build / test / install** the CLI (swift build, run the test runner,
   install to `$HOME/.local/bin/macos`).
2. **Grant TCC** to the **final installed binary** (Reminders, Notes, Contacts,
   Calendar) — the user grants these; see below.
3. **Verify live read-only parity** — compare CLI reads against the standalone
   helper on real data.
4. **Switch Aura's command path** to the CLI mappings above.
5. **Run Aura's tests / check-in** against the switched path.
6. **Only then** delete Aura's standalone EventKit source/binary and stale
   wrappers.

**Rollback** is by restoring the caller path to the standalone helper — **not**
by keeping two live implementations in parallel.

## TCC / permissions

TCC permissions must be granted by the **user** to the final installed
executable. Do **not** modify `TCC.db` or disable SIP. Permission is granted
interactively by the user against `$HOME/.local/bin/macos`.

---

## 0.8.0 Calendar migration

macos-cli **0.8.0** brings Calendar to full CLI parity. Aura's remaining
standalone calendar code paths — the direct `Calendar.sqlitedb` reader, the
`scripts/calendar_write/calendar_write` helper, and `scripts/cal.py` — must all
route through the one installed binary at `$HOME/.local/bin/macos`. No wrappers,
no second executable.

### Active ingestion — replace the direct `Calendar.sqlitedb` reader

Aura's calendar ingestion must stop reading `Calendar.sqlitedb` directly and
call the rich export envelope instead:

```
macos calendar export --from 2026-07-01 --to 2026-08-01
```

The envelope is a single JSON object with these keys:

- `events` — the array of rich event dicts.
- `count` — number of events in `events`.
- `calendars` — the resolved target calendar names (never broadened).
- `filter` — the exact calendar filter applied, or `null` when unfiltered.

**All linked event calendars are included by default.** Passing
`--calendar "Some Name"` applies an **exact** filter that is **fail-closed**: an
unknown calendar name returns **zero** events with `count: 0`, never the full
unfiltered set.

### Date semantics

- `--from` is **inclusive**; `--to` is **exclusive**. A single UTC day
  `2026-07-15` is `--from 2026-07-15 --to 2026-07-16`.
- Dates are `YYYY-MM-DD`. An invalid or reversed range is a **structured
  validation error**, not a silent empty result.

### Legacy `calendar_write` create → `macos calendar create`

Replace `scripts/calendar_write/calendar_write create ...` with:

```
macos calendar create \
  --title "Soundcheck — Example Venue" \
  --start "2026-07-20 15:00" \
  --end "2026-07-20 16:30" \
  --calendar "Gigs" \
  --alarm 1440 --alarm 60 \
  --json
```

**Alarms are explicit and repeatable.** Each `--alarm N` adds one alert N
minutes before start. **There is no default alarm** — a `create` with **no
`--alarm` args yields ZERO alarms.** Callers that want the old day-before +
hour-before alerts must pass `--alarm 1440 --alarm 60` themselves. With `--json`
the response echoes back the resolved alarm minute list.

### Legacy `cal.py delete-event` / `ekdelete` → `macos calendar delete --id`

Replace `scripts/cal.py delete-event ID` (and any `ekdelete` path) with
ID-bound deletion:

```
macos calendar delete --id "EVENT-ID-FROM-EXPORT" --json
```

`--id` mode is mutually exclusive with the existing title+date mode, which is
preserved. `calendar.delete` is a **gated** capability — it stays off by default
and must be enabled for the caller.

### Legacy `cal.py find` / `list` → export + caller-side matching

There is **no** server-side find/search. Replace `cal.py find`/`list` with an
`export` (or `events --json`) call, then match on the returned dicts in the
caller (by title, calendar, id, or time). Each event dict carries a stable `id`.

### Legacy `cal.py` rename/replace → query IDs, then `calendar update`

Replace in-place rename/replace flows with a two-step pattern: first resolve the
target event `id` from an `export` / `events --json` read and match caller-side,
then mutate by id:

```
macos calendar update --id "EVENT-ID-FROM-EXPORT" --title "New Title" --json
```

`update` takes at least one field (`--title`, `--start`, `--end`, `--location`,
`--notes`, `--calendar`); supplying none is a validation error.

### Optional fields and structured errors

- Event dicts expose the rich optional fields (location, notes, all-day flag,
  calendar name, timestamps) — read them; do not re-derive from a raw store.
- All failure modes emit **stable structured JSON errors** (validation, range,
  authorization). Authorization failures are **redacted** — no token, path, or
  internal detail leaks into the payload.

### TCC — Calendars

The Calendars TCC permission is granted **by the user**, interactively, to
`$HOME/.local/bin/macos`. It is **never** auto-granted, and `TCC.db` is never
edited.

### Staged rollout and rollback

1. Keep the existing `Calendar.sqlitedb` backups and ingestion caches in place —
   do not clear them during migration.
2. Cut over the **read-only** `export` path first and verify parity against the
   prior reader on real data.
3. **Do not perform a live calendar write** (`create` / `update` / `delete`) for
   verification without the user's **explicit authorization** — a write mutates
   the user's real calendar.
4. **Rollback** is by restoring the caller path to the legacy scripts and the
   retained backups/caches — not by running two live calendar implementations in
   parallel. Once the CLI path is proven live, the legacy scripts and wrappers
   are retired, leaving the one executable at `$HOME/.local/bin/macos`.

---

## 0.8.1 Contacts job-title parity

macos-cli **0.8.1** brings the contact **`job_title`** field to full read parity
across both contact read surfaces, so Aura's people/enrichment flows can verify a
title write through the one installed binary at `$HOME/.local/bin/macos` — no
standalone Contacts helper, no folding the title into a note.

### The read contract

`job_title` now appears in **both**:

- `macos contacts get <id> --json`
- `macos contacts export`

In each, `job_title` is a **string that is always present**: the contact's title,
or an **empty string `""`** when the contact has no title. It is **never `null`**
and never omitted — one stable shape for an ingestion consumer. Every pre-0.8.1
key is preserved with its original convention; `job_title` is purely additive, so
no existing parse breaks.

### Verified add-only title writes

The existing write path is unchanged and remains **add-only** — `contacts update
--job-title` sets the title field; it never touches phones, emails, note, or any
other field:

```
macos contacts update --id "CONTACT-ID" --job-title "Tour Manager" --json
```

Because `job_title` reads back verbatim, Aura enrichment can now **verify** the
write instead of assuming it. Write, then re-read the same field and confirm it
matches:

```
macos contacts update --id "$ID" --job-title "Tour Manager"   # write (add-only)
macos contacts get "$ID" --json                               # job_title == "Tour Manager"
```

The written value is present in the very next `get`/`export`, closing the
read-after-write loop through a single CLI. This satisfies the standing rule that
a write is only "done" once a read confirms it — the title enrichment no longer
relies on an unverified mutation.

### TCC — Contacts

The Contacts TCC permission is granted **by the user**, interactively, to
`$HOME/.local/bin/macos`. `contacts update` is a **gated write** capability; it is
never auto-granted, and `TCC.db` is never edited.
