# 2026-11-11: macos-cli as a skill for every agent

Lane macos-cli-skill-for-every-agent (plan MACOS-CLI-LAUNCH-20261110, lane 2), on the VPS.

## What

- `macos commands [--json]`: every runnable command with its path, flags, one line of help and `writes`.
  The tree is ArgumentParser's own dump (`MacOSCLI._dumpHelp()`), so a command cannot exist unlisted;
  `writes` comes from `MacCLICore.commandWrites`, which names all 220 commands once (115 write). A command
  missing from the table is listed as a write.
- Root `SKILL.md`, written by `scripts/gen-skill.sh` from `scripts/skill/SKILL.template.md` and
  `commands --json`: frontmatter (`name`, `description`, OpenClaw's `metadata.openclaw` with `os`,
  `requires.bins`, the brew install), step one `macos doctor --for-agent`, the read-only commands, the
  writes, the envelope, the exit codes, three examples. `skills.sh.json` groups it on its skills.sh page
  (validated against skills.sh's schema).
- README: "Add it as a skill" (the `npx skills` and `hermes skills install` lines, `macos commands --json`).

## Why the skill has no curl line

Hermes' skills guard rates any `curl … | bash` in a SKILL.md as a critical supply-chain finding and refuses to
install it, even with `--force`. The skill names the Homebrew install and links the README for the rest.

## How proven

- `CatalogueTests` (MacCLICoreTests) and the catalogue checks in MacCLICoreTestRunner: leaves only, sorted,
  hidden and `help` left out, `--help`/`--version` dropped, unknown is a write. Run green on Linux with Swift
  6.0.3 and ArgumentParser 1.7.1 against a small command tree.
- Written, not yet run (this host has no push access to macos-cli, so the mini could not compile it): CLITests,
  against the built binary: `commands --json` equals the leaves of `--experimental-dump-help`, each
  with a bool `writes`; `commandWrites` names exactly those commands; `skill_is_current_test.sh` and
  `readme_examples_test.sh` (now README and SKILL.md) exit 0; SKILL.md's exit-code table matches the code.
- `npx skills add` listed and installed the skill from a clone of the branch; Hermes (temp `HERMES_HOME`)
  installed and inspected it by its raw URL, the fetch answered from the local file. SKILL.md here was
  generated from a mirror of the command tree read from the sources; `skill_is_current_test.sh` on a Mac is
  what holds it to the binary.

## Finished on the mini (lane macos-cli-skill-for-every-agent-finish, 2026-11-10)

The branch came over from the VPS as a git bundle and was pushed from here. On the Mac, `bash scripts/gen-skill.sh`
left SKILL.md unchanged, so the Linux-generated file was already right. `swift test --filter 'CLITests|MacCLICoreTests'`
passed (33, one skipped by its own guard), `skill_is_current_test.sh` passed, `readme_examples_test.sh` passed 41/41,
and `macos commands --json` lists 220 commands, each with `writes` (115 writes). The GitHub page now has the
description, the manuaudio.com homepage and the topics macos, cli, ai-agents, claude-code, swift, agent-skills.
