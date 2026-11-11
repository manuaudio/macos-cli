---
name: macos-cli
description: "Control a Mac from the terminal with the `macos` command (Calendar, Reminders, Contacts, Mail, Messages, Notes, Safari, Photos, Music, files, windows, screenshots, OCR, the Accessibility tree and system settings), where every command that returns data prints JSON with --json; run `macos doctor --for-agent` before anything else."
homepage: https://github.com/manuaudio/macos-cli
metadata:
  {
    "openclaw":
      {
        "os": ["darwin"],
        "requires": { "bins": ["macos"] },
        "install":
          [
            {
              "id": "brew",
              "kind": "brew",
              "formula": "manuaudio/tap/macos-cli",
              "bins": ["macos"],
              "label": "Install macos-cli with Homebrew",
            },
          ],
      },
  }
---

# macos-cli

`macos` is one signed binary that drives a Mac: `macos <area> <action>`. It runs on macOS 13 or later
on Apple silicon. Install it with `brew install manuaudio/tap/macos-cli`; the
[README](https://github.com/manuaudio/macos-cli#install) has the other ways.

## Step one: ask what you may do

Run this before any other command. It never shows a prompt.

```bash
macos doctor --for-agent
```

It answers with one JSON object. `ready` is true only when every privacy area is granted;
`missing` names the areas that are not. Each entry of `areas` carries `state`, `needed_by` (the
commands that fail without it) and `hint` (what a person does to grant it). `capabilities` is the
policy in `~/.config/macos-cli/auth.json`: a command whose capability is `false` is refused with
`capability_denied`.

What you cannot do yourself, ask the person to do:

- A privacy area (Calendars, Contacts, Full Disk Access, Accessibility, Screen Recording, …) is
  granted by a person, through `macos authorize <area>` or System Settings. You cannot click Allow.
- The policy is widened only by a person at a terminal (`macos auth grant <capability>`). Run by
  you, it refuses with `person_required` and nothing changes. `macos auth deny` needs no person.
- `macos reminders complete --id ID` is a dry run unless `--approve` matches the
  `APPLE_EVENTKIT_APPROVE_TOKEN` the person set in your environment.

The list below has every command with its flags, one line of help and whether it writes;
`macos commands --json` prints it. Run `macos help <area> <action>` for a
command's arguments.

<!-- commands -->

## Answers and errors

Under `--json` a command prints one JSON value on stdout. A failure is one JSON object on stdout,
stderr stays empty, and the exit status says what kind of failure it was. Branch on `error`;
`message` and `hint` are for people and may change.

```json
{
  "ok": false,
  "status": "error",
  "error": "calendar_not_found",
  "message": "No calendar is named 'Nope'.",
  "hint": "Run `macos calendar calendars` to see the names.",
  "calendar": "Nope",
  "exit_code": 3
}
```

| Exit | Meaning | `error` codes |
|---|---|---|
| 0 | Success | |
| 64 | The command line was rejected | `usage`, `invalid_argument`, `invalid_date`, `invalid_date_range`, `invalid_alarm`, `invalid_delete_mode`, `invalid_timezone`, `ambiguous_calendar` |
| 3 | The named thing does not exist | `not_found`, `calendar_not_found`, `event_not_found` |
| 4 | Not allowed | `capability_denied` (the policy), `access_denied` (macOS privacy settings), `person_required` (only a person may do it) |
| 5 | No answer in time | `timeout`, `fetch_timeout` |
| 6 | The system or an app reported an error | `app_error` |

A command that only performs an action (move a window, click, play) prints a line of text and has
no `--json` output; asked for `--json`, it answers with a `usage` error. A filter that names a
list, calendar or folder that does not exist returns nothing or an error, never everything.

## Examples

What is on the calendar this week:

```bash
macos doctor --for-agent
macos calendar events --from 2026-11-16 --to 2026-11-22 --json
```

Find a contact, then leave a draft in Mail for the person to read and send:

```bash
macos contacts search "Ana" --limit 5 --json
macos mail draft --to ana@example.com --subject "Thursday" --body "Does 3 pm still work?" --json
```

Add a reminder to a named list:

```bash
macos reminders lists --json
macos reminders create --title "Call the venue" --list Work --due "2026-11-12 10:00" --json
```
