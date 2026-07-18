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
| Calendar reads     | `macos calendar events ... --json` *(unchanged — existing path stays)* |

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
