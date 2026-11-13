# 2026-11-13 — 0.10.0 released, so the one-line installer works again

**What.** install.sh on main said 0.10.0 while the newest Release was v0.9.1, so the install line failed for anyone
who pasted it. The 0.10.0 changelog notes went back under Unreleased (with the Master Tour query-string fix folded in:
0.10.0 never shipped, so it needs no Fixed line) and `factory/bin/tool-release macos-cli 0.10.0` cut the release:
commit 66944b8 "Release 0.10.0", notarization b121eb46-6c49-4830-b2bf-e5c18155206c accepted, Release v0.10.0 with
the zip, its sha256 and the manifest, the tap formula at 0.10.0.

**How proven.** In a temp HOME, the README's curl line downloaded and installed 0.10.0, `macos --version` said 0.10.0
and `macos commands --json` listed mastertour and daysheets. The Homebrew proof is in the lane report.
