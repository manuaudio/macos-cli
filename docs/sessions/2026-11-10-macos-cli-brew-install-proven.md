# 2026-11-10 macos-cli-brew-install-proven

**What.** The brew line was run on this Mac's real Homebrew (/opt/homebrew, Homebrew 7.0.12) in a clean
environment, the way a stranger types it; the formula was rewritten so Homebrew's own audit has nothing to say; the
README puts the brew line first. No binary or asset had to change, so there is no v0.9.1.

**Found.** `brew tap manuaudio/tap && brew install macos-cli` is refused by Homebrew 7: "Refusing to load formula
manuaudio/tap/macos-cli from untrusted tap manuaudio/tap." That is Homebrew's policy for every third-party tap, not
our formula. Naming the formula in full trusts that one formula, so `brew install manuaudio/tap/macos-cli` works from
a tapped and from an untapped Homebrew. Every place we publish carries only the full name (README, tap README,
release notes). The old formula also failed `brew style` (desc "command line", a redundant `version` line) and `brew
audit` could not be run on it without trusting the tap.

**Formula** (manuaudio/homebrew-tap 4623cfc, README 96f0c6a): no `version` line (it comes from the url), `livecheck`
on GitHub's latest release, `depends_on arch: :arm64`, `depends_on macos: :ventura` from `Package.swift`'s
`.macOS(.v13)`. A separate `depends_on :macos` was tried and refused by both audit ("Calling `depends_on :macos` with
`depends_on macos:` is disabled!") and style ("Remove redundant depends_on :macos"), so it is not there.

**Transcript** (env -i HOME=$HOME PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin, auto-update and cleanup off
so nothing else in Homebrew moves), trimmed:

```
$ brew install manuaudio/tap/macos-cli          # untapped
==> Tapping manuaudio/tap
Tapped 1 formula (14 files, 7.9KB).
🍺  /opt/homebrew/Cellar/macos-cli/0.9.0: 4 files, 7.1MB, built in 2 seconds
$ /opt/homebrew/bin/macos --version
0.9.0
$ macos --help | head -3
OVERVIEW: macOS CLI — full agentic control of macOS via the terminal
USAGE: macos <subcommand>
$ macos doctor --for-agent --json | python3 -c 'import json,sys; json.load(sys.stdin)'
doctor json ok, keys: ['areas', 'binary', 'capabilities', 'missing', 'ok', 'ready']
$ codesign --verify --strict --verbose=2 /opt/homebrew/Cellar/macos-cli/0.9.0/bin/macos
valid on disk / satisfies its Designated Requirement
Identifier=com.manuaudio.macos-cli  Authority=Developer ID Application: Manuel Jimenez (4M72M3J3UN)  TeamIdentifier=4M72M3J3UN
$ spctl -a -t install -vv …/bin/macos
accepted  source=Notarized Developer ID
$ spctl -a -t exec -vv …/bin/macos
rejected (the code is valid but does not seem to be an app)     # Gatekeeper gives a bare CLI no exec verdict
$ brew test macos-cli
==> /opt/homebrew/Cellar/macos-cli/0.9.0/bin/macos --version
$ brew info macos-cli
==> manuaudio/tap/macos-cli: stable 0.9.0
Drive your Mac from the terminal, with JSON output for agents
License: MIT   Required: arm64 architecture, macOS >= 13
$ brew uninstall macos-cli && brew untap manuaudio/tap
$ brew tap manuaudio/tap && brew install manuaudio/tap/macos-cli   # tapped: same checks, all pass
$ brew tap manuaudio/tap && brew install macos-cli                 # refused, untrusted tap (see Found)
$ brew audit --strict --online --formula manuaudio/tap/macos-cli   # exit 0, nothing printed
$ brew style manuaudio/tap                                         # 2 files inspected, no offenses detected
$ brew livecheck manuaudio/tap/macos-cli                           # macos-cli: 0.9.0 ==> 0.9.0
```

Audit ran with `XDG_CONFIG_HOME` in a temp folder for `brew trust`, so `~/.homebrew/trust.json` was never changed.
After: `brew list --versions` and `brew tap` identical to before, `~/.local/bin/macos` the same link and sha256.
`brew test` once updated Homebrew's own vendored gems (bindata 3.0.0 → 3.0.1); that is Homebrew's bundle, not a
formula.

**From now on.** `factory/bin/tool-release` ends every release with this run (`brew_proof`) and is not done until
every step passes; `tool-release macos-cli <version> --prove` runs it alone. Logs: ~/Builds.local/macos-cli-brew-install-proven/.
