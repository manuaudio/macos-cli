# 2026-11-14: what the factory still scripted by hand goes into macos

Lane macos-cli-what-the-factory-still-scripts-by-hand. Manu, 2026-11-14: "every time you do something on this Mac
you should add it to macOS CLI".

## What

- `apps launch <name>` crashed (0.10.0: `libc++abi: terminating due to uncaught exception of type NSException`):
  the JXA envelope's `result` was the bare string "launched", and `JSONSerialization.data(withJSONObject:)` raises on
  a top-level string. The parser moved to MacCLICore (`JXA.swift`) and writes fragments; `safari execute` had the
  same crash on every result.
- `disk mount smb://user@host/share [--password-env VAR] [--json]`: NetFS, no root, no dialog (`UIOption=NoUI`); the
  keychain item or the named variable, never argv, and a URL with a password is refused without echoing it. A share
  already in the mount table (by `.local` or Finder's Bonjour name) is reported, not mounted again as `Arimaka-1`.
  New capability `disk.mount`, on by default; `disk.write` (eject, unmount) unchanged.
- `contacts export --per-source`: each container's cards, unlinked, with `source`, `source_id`, `source_type`;
  `is_me` on every exported card.
- `messages export --since-rowid N [--limit N]` and `messages latest --json`: chat.db through SQLite3 `mode=ro`,
  text from `attributedBody` (decoder in MacCLICore, a port of aura's `lib/imessage_body.py`), chat handles and
  attachments so aura's ingest has what its own SQL read. Gated by `messages.read` and Full Disk Access.
- `safari js SCRIPT [--window N] [--tab N | --url TEXT]` (old name `safari execute` still accepted), under the new
  capability `safari.js`, off by default: page JavaScript acts with the page's signed-in session (Venmo).

## How proven

- `tests-touched -- build-slot swift swift test`: 89 MacCLICore + 43 CLI tests, 0 failures; `swift run
  MacCLICoreTestRunner`: 294 checks. New: JXAEnvelopeTests, NetworkShareTests, MessagesStoreTests; CLI tests for
  messages export/latest on a fixture chat.db in the test's own HOME, the mount refusals, the safari.js denial.
- Live on this Mac (`~/Builds.local/macos-cli-what-the-factory-still-scripts-by-hand/live.log`):
  `apps launch Finder` crashes on installed 0.10.0 and prints "Launched: Finder" on the branch;
  `disk mount smb://manu@ManuStorage.local/Arimaka --json` → already, `/Volumes/Arimaka` (and the same by the Bonjour
  name); `contacts export --per-source` → 2,359 cards (iCloud 1,280, Google 1,078, On My Mac 1) against 1,977 unified;
  `is_me` false on all: this Mac's Contacts has no My Card (`unifiedMeContactWithKeys` fails, recall's own helper
  also reports none).
- Not run on live data: `messages export/latest` (this Mac's auth.json denies `messages.read`, and the brief forbids
  granting it from a lane) and `safari js` (`safari.js` is new and off). Both proven on fixtures only.

## Mined

aura `lib/imessage_body.py` (the decoder, ported), aura `ingest/imessage.py` (the join), factory
`recall/people/contacts-export.swift` (unifyResults=false, the Me id), `plumbing/qnap-mount.sh` (Bonjour names).
