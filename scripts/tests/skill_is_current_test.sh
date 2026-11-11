#!/bin/bash
# The committed SKILL.md is what scripts/gen-skill.sh writes from the binary's own command list.
#
# Run:  bash scripts/tests/skill_is_current_test.sh            (builds a debug binary)
#       MACOS_BIN=/path/to/macos bash scripts/tests/skill_is_current_test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fresh="$(mktemp -t macos-cli-skill.XXXXXX)"
trap 'rm -f "$fresh"' EXIT

if ! bash "$REPO_ROOT/scripts/gen-skill.sh" "$fresh"; then
    echo "✗ scripts/gen-skill.sh failed"
    exit 1
fi
if diff -u "$REPO_ROOT/SKILL.md" "$fresh"; then
    echo "✓ SKILL.md is current"
else
    echo "✗ SKILL.md is stale: run bash scripts/gen-skill.sh and commit it"
    exit 1
fi
