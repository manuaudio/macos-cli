#!/bin/bash
# This repository is public: what is tracked here is the tool, its docs and its tests.
# Working notes about how a change was made live with the people who made it, not under docs/.
#
# Run:  bash scripts/tests/public_tree_test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
notes="$(git -C "$REPO_ROOT" ls-files -- docs/sessions)"
if [[ -n "$notes" ]]; then
    echo "✗ working notes are tracked in the public tree:"
    echo "$notes" | sed 's/^/    /'
    exit 1
fi
echo "✓ no working notes in the public tree"
