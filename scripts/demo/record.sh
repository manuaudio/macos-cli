#!/bin/bash
# Records docs/demo.cast and renders docs/demo.svg: an agent's three calls, real output.
#
# Run:  bash scripts/demo/record.sh            (uses .build/debug/macos-cli)
#       MACOS_BIN=/path/to/macos bash scripts/demo/record.sh
#
# Nothing private is shown. The recording runs under a fresh HOME (default policy), asks for
# a calendar that does not exist, and searches for one contact this script creates first and
# deletes afterwards. Needs uvx (asciinema) and npx (svg-term-cli).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MACOS_BIN="${MACOS_BIN:-$REPO_ROOT/.build/debug/macos-cli}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin" "$WORK/home" "$WORK/setup/.config/macos-cli"
ln -s "$MACOS_BIN" "$WORK/bin/macos"
echo '{"capabilities":{"contacts.write":true,"contacts.delete":true}}' \
    > "$WORK/setup/.config/macos-cli/auth.json"

id="$(HOME="$WORK/setup" "$MACOS_BIN" contacts create --first-name Ada --last-name Quillfeather \
    --organization "Example Studio" --phone "+13105550100" --email ada@example.com --json | jq -r .id)"
cleanup_contact() { HOME="$WORK/setup" "$MACOS_BIN" contacts delete "$id" --json >/dev/null; }
trap 'cleanup_contact; rm -rf "$WORK"' EXIT

env -i HOME="$WORK/home" PATH="$WORK/bin:/opt/homebrew/bin:/usr/bin:/bin" TERM=xterm-256color \
    uvx --from asciinema asciinema rec --overwrite --cols 88 --rows 24 \
    -c "bash $REPO_ROOT/scripts/demo/agent.sh" "$REPO_ROOT/docs/demo.cast"

npx --yes svg-term-cli@2.1.1 --in "$REPO_ROOT/docs/demo.cast" --out "$REPO_ROOT/docs/demo.svg" \
    --window --width 88 --height 24
ls -l "$REPO_ROOT/docs/demo.cast" "$REPO_ROOT/docs/demo.svg"
