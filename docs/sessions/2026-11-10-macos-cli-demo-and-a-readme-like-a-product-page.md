# 2026-11-10 — a real recording and a README that reads like a product page

Lane `macos-cli-demo-and-a-readme-like-a-product-page` (plan MACOS-CLI-LAUNCH-20261110, lane 3).

## What

- `docs/demo.svg` (17 KB) from `docs/demo.cast` (14.6 s, 88x24), made by `scripts/demo/record.sh`:
  asciinema 2.4.0 through `uvx`, svg-term-cli 2.1.1 through `npx`. `scripts/demo/agent.sh` is what plays.
- README top rewritten: plain title, the license badge alone, one sentence, the two install lines, the
  recording and its three commands, "For agents" (skill line, `doctor --for-agent`, the error envelope in six
  lines, exit codes, the policy file), the area table without emoji, "Compared with". The body (install
  details, quick taste, agents in detail, errors, contracts, permissions) is kept; two headings renamed.
- `scripts/tests/readme_examples_test.sh`: the recorded commands must be README examples (so they are
  checked against `macos help` like the rest), and `doctor --for-agent` now runs for real under a fresh HOME.
  SKILL.md was already in the test.

## The recording, frame by frame

1. 0 s: `$ macos doctor --for-agent | jq '{ready, missing: .missing[:3]}'` typed word by word;
   output `ready: false`, missing `full_disk_access`, `accessibility`, `screen_recording` (fresh HOME, so
   Full Disk Access reads as missing there).
2. ~4.5 s: screen clears; `$ macos calendar events --json --calendar "Demo Gigs"`; the
   `calendar_not_found` envelope with hint and `exit_code: 3`, then `(exit 3)`.
3. ~10.6 s: screen clears; `$ macos contacts search "Quillfeather" --json`; one contact, Ada Quillfeather,
   Example Studio, ada@example.com, +13105550100; a last `$` prompt holds it until 14.6 s.

Why not the brief's `calendar events --from today --to today`: `--from` takes only dates (`today` is
`invalid_date`), and this Mac's calendars are Manu's synced Google and iCloud ones, with no Local calendar
and no command that creates one. A calendar read would show his events, so the frame shows the fail-closed
filter instead. The contact is created before recording under a separate temp HOME whose policy allows
contacts.write/delete, and deleted after (search verified empty).

## Compared with: numbers read with `gh api` on 2026-11-10

remindctl (openclaw) 417 stars, imsg (openclaw) 1,406, apple-mcp (supermemoryai) 3,112, archived;
macos-cli 1. RemCTL (655 in the plan) was left out of the table: the brief names three tools.

## Proven

- `MACOS_BIN=.build/debug/macos-cli bash scripts/tests/readme_examples_test.sh` → 45 passed, 0 failed;
  renaming the recorded contact in agent.sh makes it fail with "not shown in the README".
- `build-slot swift swift test --filter 'CLITests|MacCLICoreTests'` → 33 tests, 1 skipped, 0 failures.
- Frames rendered with `svg-term --at` and looked at; the README has one shields badge and no emoji.

Seen, not fixed: `contacts search --json` prints Apple's raw labels (`_$!<Work>!$_`); they show in the recording.
