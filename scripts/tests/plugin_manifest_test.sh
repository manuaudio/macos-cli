#!/bin/bash
# The Claude Code plugin is the root SKILL.md and nothing else: .claude-plugin/marketplace.json lists one
# plugin whose source is this repository, .claude-plugin/plugin.json points its skills at the root, and no
# second copy of the skill exists. `claude plugin validate` runs too when Claude Code is on PATH.
#
# Run:  bash scripts/tests/plugin_manifest_test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if ! /usr/bin/python3 -I - "$REPO_ROOT" <<'PY'
import json, pathlib, re, sys

root = pathlib.Path(sys.argv[1])
market = json.loads((root / ".claude-plugin/marketplace.json").read_text())
plugin = json.loads((root / ".claude-plugin/plugin.json").read_text())
skill = (root / "SKILL.md").read_text()
name = re.search(r"^name:\s*(\S+)", skill, re.M).group(1)
problems = []
if [p["name"] for p in market["plugins"]] != [name]:
    problems.append(f"the marketplace lists {[p['name'] for p in market['plugins']]}, not [{name!r}]")
elif market["plugins"][0]["source"] != "./":
    problems.append("the plugin's source is not this repository (\"./\")")
if plugin["name"] != name:
    problems.append(f"plugin.json is named {plugin['name']!r}, the skill {name!r}")
if plugin.get("skills") != ["./"]:
    problems.append("plugin.json does not point its skills at the root SKILL.md (\"skills\": [\"./\"])")
copies = [str(p.relative_to(root)) for p in root.rglob("SKILL.md") if p != root / "SKILL.md" and ".build" not in p.parts]
if copies:
    problems.append(f"a second SKILL.md: {copies}")
for p in problems:
    print("✗ " + p)
sys.exit(1 if problems else 0)
PY
then
    exit 1
fi
echo "✓ the plugin is the root SKILL.md"

if command -v claude >/dev/null 2>&1; then
    if out="$(claude plugin validate "$REPO_ROOT" 2>&1)"; then
        echo "✓ claude plugin validate passed"
    else
        echo "$out"
        echo "✗ claude plugin validate failed"
        exit 1
    fi
fi
