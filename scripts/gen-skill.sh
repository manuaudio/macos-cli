#!/bin/bash
# Writes the root SKILL.md: scripts/skill/SKILL.template.md with its `<!-- commands -->` line
# replaced by the command lists `macos commands --json` gives, read-only first, then the writes.
#
# Run:  bash scripts/gen-skill.sh                      (builds a debug binary, writes SKILL.md)
#       MACOS_BIN=/path/to/macos bash scripts/gen-skill.sh [output]
#
# The output is the same for the same binary and template; scripts/tests/skill_is_current_test.sh
# regenerates it and diffs it with the committed file.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$REPO_ROOT/SKILL.md}"

if [[ -z "${MACOS_BIN:-}" ]]; then
    (cd "$REPO_ROOT" && swift build >/dev/null)
    MACOS_BIN="$(cd "$REPO_ROOT" && swift build --show-bin-path)/macos-cli"
fi

catalogue="$(mktemp -t macos-cli-commands.XXXXXX)"
trap 'rm -f "$catalogue"' EXIT
"$MACOS_BIN" commands --json > "$catalogue"

/usr/bin/python3 -I - "$REPO_ROOT/scripts/skill/SKILL.template.md" "$catalogue" "$OUT" <<'PY'
import json, sys

template, catalogue, out = sys.argv[1], sys.argv[2], sys.argv[3]
commands = json.load(open(catalogue, encoding="utf-8"))

def lines(writes):
    rows = []
    for c in commands:
        if c["writes"] != writes:
            continue
        flags = " ".join("`%s`" % f for f in c["flags"])
        rows.append("- `macos %s`: %s.%s" % (c["path"], c["help"].rstrip("."),
                                              " Flags: " + flags + "." if flags else ""))
    return rows

section = ["## Commands that only read", "",
           "These change nothing on the Mac. Saving a screenshot or an export to a path you name counts as reading.", ""]
section += lines(False)
section += ["", "## Commands that write", "",
            "These change data, a setting or the state of the Mac, or send, play or show something. Run one only "
            "when the person asked for that change.", ""]
section += lines(True)

text = open(template, encoding="utf-8").read()
marker = "<!-- commands -->"
if text.count(marker) != 1:
    sys.exit("the template must hold one %s line" % marker)
with open(out, "w", encoding="utf-8") as f:
    f.write(text.replace(marker, "\n".join(section)))
PY
