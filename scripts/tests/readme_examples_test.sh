#!/bin/bash
# README and SKILL.md examples contract.
#
# Every `macos …` command the README or SKILL.md prints must be one the binary has: its
# subcommand path is the one `macos help <path>` shows on its USAGE line, and
# every `--flag` it uses appears in that command's help. A few read-only
# commands that need no privacy permission are also run, and must exit 0 with
# the keys the README shows.
#
# Run:  bash scripts/tests/readme_examples_test.sh            (builds a debug binary)
#       MACOS_BIN=/path/to/macos bash scripts/tests/readme_examples_test.sh
#
# Nothing here reads Calendar, Contacts, Mail, Notes, the screen or any other
# private data: `help` parses nothing but the command line.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [[ -z "${MACOS_BIN:-}" ]]; then
    (cd "$REPO_ROOT" && swift build >/dev/null) || { echo "❌  swift build failed"; exit 1; }
    MACOS_BIN="$(cd "$REPO_ROOT" && swift build --show-bin-path)/macos-cli"
fi

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ✗ $1"; }

# Every line inside a fenced block that runs the binary: `macos …`,
# `"$HOME/.local/bin/macos" …`, or a `// macos …` caption over a JSON sample.
# A caption that ends in `\` continues on the next `//` line.
examples() {
    awk '
        /^```/ { inblock = !inblock; next }
        !inblock { next }
        {
            line = $0
            sub(/^\/\/ +/, "", line)
            if (cont != "") { line = cont " " line; cont = "" }
            if (line ~ /\\[[:space:]]*$/) { sub(/\\[[:space:]]*$/, "", line); cont = line; next }
            sub(/^"\$HOME\/\.local\/bin\/macos"/, "macos", line)
            if (line ~ /^macos /) print line
        }
    ' "$1"
}

check_examples() {
    local doc="$1" count=0 example cmd words path w path_text help usage missing flag
    echo "$doc command examples"
    while IFS= read -r example; do
        count=$((count + 1))
        # Drop a trailing `# comment`, a pipe into another tool, and the `(fake data)` note.
        cmd="${example%%#*}"
        cmd="${cmd%%|*}"
        cmd="${cmd%%(fake data)*}"
        read -r -a words <<< "$cmd"

        # The subcommand path: the plain lowercase words after `macos`.
        path=()
        for w in "${words[@]:1}"; do
            [[ "$w" =~ ^[a-z][a-z0-9-]*$ ]] || break
            path+=("$w")
        done

        # bash 3.2 calls an empty array unbound under `set -u`; `macos --version` has no path.
        path_text="${path[*]+${path[*]}}"
        help="$("$MACOS_BIN" help ${path[@]+"${path[@]}"} 2>&1)"
        usage="$(grep -m1 '^USAGE:' <<< "$help")"
        if [[ -n "$path_text" && "$usage" != "USAGE: macos $path_text" && "$usage" != "USAGE: macos $path_text "* ]]; then
            fail "$example  — 'macos $path_text' is not a command (help says: ${usage:-nothing})"
            continue
        fi

        missing=""
        for w in "${words[@]}"; do
            flag="${w%%=*}"
            [[ "$flag" =~ ^--[a-z][a-z0-9-]*$ ]] || continue
            grep -qE -- "(^|[[ ,])${flag}([] ,=<]|$)" <<< "$help" || missing+=" $flag"
        done
        if [[ -n "$missing" ]]; then
            fail "$example  — unknown option(s):$missing"
        else
            pass "$example"
        fi
    done < <(examples "$REPO_ROOT/$doc")

    if (( count < 5 )); then
        fail "found only $count examples in $doc; the extractor is broken"
    fi
}

check_examples README.md
check_examples SKILL.md

# The recording's three commands are README examples, so the checks above cover them too.
echo "The recording's commands are in the README"
readme_examples="$(examples "$REPO_ROOT/README.md")"
recorded=0
while IFS= read -r cmd; do
    recorded=$((recorded + 1))
    if grep -qxF -- "$cmd" <<< "$readme_examples"; then pass "$cmd"; else fail "$cmd  — recorded in docs/demo.cast but not shown in the README"; fi
done < <(sed -nE "s/^run '(.*)'$/\1/p; s/^run \"(.*)\"$/\1/p" "$REPO_ROOT/scripts/demo/agent.sh" | sed 's/\\"/"/g')
(( recorded == 3 )) || fail "found $recorded recorded commands in scripts/demo/agent.sh, expected 3"

echo "Read-only commands that need no permission"
json_keys() { /usr/bin/python3 -I -c 'import json,sys; d=json.load(sys.stdin); print(" ".join(sorted(d)))'; }

out="$("$MACOS_BIN" --version)"; rc=$?
version="$(sed -nE 's/^let macosCLIVersion = "([^"]+)"$/\1/p' "$REPO_ROOT/Sources/macos-cli/Version.swift")"
if (( rc == 0 )) && [[ "$out" == "$version" ]]; then pass "macos --version → $out"; else fail "macos --version → '$out' (exit $rc), Version.swift says $version"; fi

out="$("$MACOS_BIN" system battery --json)"; rc=$?
keys="$(json_keys <<< "$out" 2>/dev/null)"
if (( rc == 0 )) && [[ " $keys " == *" level "* && " $keys " == *" charging "* && " $keys " == *" plugged_in "* ]]; then
    pass "macos system battery --json → {$keys}"
else
    fail "macos system battery --json → exit $rc, keys '$keys'"
fi

out="$("$MACOS_BIN" reminders status --json)"; rc=$?
keys="$(json_keys <<< "$out" 2>/dev/null)"
if (( rc == 0 )) && [[ " $keys " == *" authorization "* ]]; then
    pass "macos reminders status --json → {$keys}"
else
    fail "macos reminders status --json → exit $rc, keys '$keys'"
fi

# doctor never prompts; under a fresh HOME it reads the default policy.
out="$(HOME="$(mktemp -d)" "$MACOS_BIN" doctor --for-agent)"; rc=$?
keys="$(json_keys <<< "$out" 2>/dev/null)"
if (( rc == 0 )) && [[ " $keys " == *" ready "* && " $keys " == *" missing "* && " $keys " == *" areas "* && " $keys " == *" capabilities "* ]]; then
    pass "macos doctor --for-agent → {$keys}"
else
    fail "macos doctor --for-agent → exit $rc, keys '$keys'"
fi

out="$("$MACOS_BIN" commands --json)"; rc=$?
summary="$(/usr/bin/python3 -I -c 'import json,sys; c=json.load(sys.stdin); print(len(c), sum(type(e.get("writes")) is not bool for e in c))' <<< "$out" 2>/dev/null)"
if (( rc == 0 )) && [[ "$summary" =~ ^[1-9][0-9]*\ 0$ ]]; then
    pass "macos commands --json → ${summary%% *} commands, each with writes"
else
    fail "macos commands --json → exit $rc, '$summary'"
fi

echo
echo "$PASS passed, $FAIL failed"
(( FAIL == 0 ))
