#!/bin/bash
# The three calls the README's recording shows, typed the way an agent sends them.
# record.sh runs this inside asciinema; it needs `macos` and `jq` on PATH.

set -f   # the commands are split into words for typing; keep `[:3]` from globbing

type_out() {
    local word first=1
    printf '\033[1;32m$\033[0m '
    for word in $1; do
        (( first )) || printf ' '
        printf '%s' "$word"
        first=0
        sleep 0.12
    done
    printf '\n'
}

run() {
    clear
    type_out "$1"
    bash -c "$1"
    local rc=$?
    (( rc != 0 )) && printf '\033[2m(exit %d)\033[0m\n' "$rc"
    sleep 3
}

run "macos doctor --for-agent | jq '{ready, missing: .missing[:3]}'"
run 'macos calendar events --json --calendar "Demo Gigs"'
run 'macos contacts search "Quillfeather" --json'
# A last prompt after the pause, so the player holds the final result before it loops.
printf '\033[1;32m$\033[0m '
sleep 1
