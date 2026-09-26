# Code identity, signing, and why permissions stop disappearing

For a **bundled** app, macOS keys a privacy (TCC) grant by bundle identifier.
This tool is an **unbundled command-line executable**, and those are keyed
differently: TCC stores the entry against the binary's **stable absolute path**
*plus* a **code requirement** captured when the grant was made. Both halves
matter, and losing either one loses the grant:

- **Move or reinstall the binary somewhere else** — different path, no grant.
  This is why `install.sh` installs to one fixed location
  (`$MACOS_CLI_INSTALL_DIR`, default `~/.local/bin/macos`) and replaces it in
  place, rather than running from a build directory.
- **Change the code requirement** — the stored requirement no longer matches, so
  macOS treats the binary at that path as a different program and re-prompts (or
  silently denies).

For an unsigned or ad-hoc binary the recorded requirement is pinned to the
build's cdhash, which changes on every single rebuild. A Developer ID signature
with a stable identifier produces a requirement that stays constant across
rebuilds:

| build | recorded code requirement | what happens to your grants |
|---|---|---|
| unsigned / linker ad-hoc (the old `install.sh`) | pinned to this build's cdhash | **lost on every rebuild** |
| ad-hoc `codesign --sign -` | `cdhash H"…"` | **lost on every rebuild** |
| Developer ID + stable identifier | `identifier "com.manuaudio.macos-cli" and anchor apple generic and certificate leaf[subject.OU] = "TEAMID"` | **survives rebuilds and reinstalls at the same path** |

So `install.sh` signs, installs to a stable path, and refuses to guess which of
those signing modes you meant.

## The pinned identity

- Bundle identifier: `com.manuaudio.macos-cli` (`SV_BUNDLE_ID` in
  `scripts/lib/sign_verify.sh`). It is what the signature's designated
  requirement pins, so changing it changes the recorded code requirement and
  invalidates every existing grant on every user's machine.
- Info.plist: `Resources/macos-cli-Info.plist`, embedded into the executable's
  `__TEXT,__info_plist` section at link time by `Package.swift`. There is no
  `.app` bundle; this section *is* the bundle metadata, and `codesign` seals it
  into the signature (`codesign -dv` must report `Info.plist entries=N`, not
  `Info.plist=not bound`).
- Entitlements: `Resources/macos-cli.entitlements` — only
  `com.apple.security.automation.apple-events`. The Hardened Runtime blocks a
  process from sending Apple events without it, and any future in-process
  `NSAppleScript` / `AEDeterminePermissionToAutomateTarget` call would fail
  outright without it. Nothing else is requested: no sandbox, no
  `disable-library-validation`, no JIT, no debugger entitlements.
  `sv_verify_entitlements` reads the entitlements back off the *signed artifact*
  and rejects both a missing Apple Events entitlement and any entitlement beyond
  that one, so the shipped bytes cannot quietly diverge from this file.

  **Automation attribution is intended behaviour, not a verified result.** Today
  the CLI sends its Apple events by spawning `/usr/bin/osascript` rather than
  in-process. Which process TCC holds *responsible* for those events — this
  binary, the terminal that launched it, or a launchd job further up the chain —
  depends on the launch chain and **has not been verified here**. Nothing in
  this repo tests it, and neither the terminal nor the launchd case has been
  exercised (see *Not covered here*). Treat "the automation is attributed to
  this binary" as the expectation being aimed at, not an established fact.

  **This file must contain no XML comments.** `codesign` does not parse
  entitlements with `plutil`; it hands them to AMFI's stricter reader, which
  fails with `AMFIUnserializeXML: syntax error` on a comment block that
  `plutil -lint` accepts without complaint. The installer contract test signs a
  throwaway Mach-O with the real file so this cannot regress silently into a
  release build.
- Hardened Runtime: `codesign --options runtime`, required for notarization.

## Usage descriptions

The embedded Info.plist carries the text macOS shows in the permission prompt:

| key | surface |
|---|---|
| `NSContactsUsageDescription` | Contacts |
| `NSCalendarsUsageDescription` | Calendars (macOS 13) |
| `NSCalendarsFullAccessUsageDescription` | Calendars full access (macOS 14+) |
| `NSRemindersUsageDescription` | Reminders (macOS 13) |
| `NSRemindersFullAccessUsageDescription` | Reminders full access (macOS 14+) |
| `NSAppleEventsUsageDescription` | Automation of other apps |
| `NSLocationUsageDescription` | Location (general macOS key) |
| `NSLocationWhenInUseUsageDescription` | Location for `requestWhenInUseAuthorization()` |

Both the legacy and the macOS 14 full-access keys are present because the
package deploys to macOS 13. Both Location keys are present because
`Commands/LocationCommand.swift` calls
`CLLocationManager.requestWhenInUseAuthorization()`: macOS reads the
when-in-use key for that call, and `NSLocationUsageDescription` is the older
general macOS key. `SV_REQUIRED_PLIST_KEYS` in `scripts/lib/sign_verify.sh`
requires every key in this table, and the contract test fails if the sources
call a TCC API whose key is missing.

### Full Disk Access has no Info.plist key

**macOS provides no Info.plist usage-description key that requests or grants
Full Disk Access.** There is no `NSFullDiskAccessUsageDescription`; nothing in a
plist can trigger an FDA prompt, and no key in this repo should be read as
claiming otherwise. FDA is granted only by a human, per binary, in
**System Settings ▸ Privacy & Security ▸ Full Disk Access**.

Commands that read protected databases (Apple Notes, Messages history, Safari
data) therefore need you to add the installed `macos` binary to that list
yourself. The plist carries a `MacOSCLIFullDiskAccessRationale` string, which is
our own informational key — deliberately outside Apple's `NS…` namespace, read
by no system component, and present only so a human inspecting the binary finds
the rationale next to the real usage descriptions.

FDA is granted per binary and matched against the same code identity, so a
stable Developer ID signature at a stable path is what an FDA grant is
*expected* to survive on across rebuilds. Like the Automation attribution
above, FDA grant survival has **not been verified here** — it needs the live
gates listed under *Not covered here*.

## Signing modes

Mode and identity come from the environment, or from
`~/.config/macos-cli/signing.env` (override with `MACOS_CLI_SIGN_CONFIG`). The
environment wins over the file. The file is **parsed, not sourced**, so it
cannot execute code.

| variable | values | default |
|---|---|---|
| `MACOS_CLI_SIGN_MODE` | `developer-id`, `adhoc` | `developer-id` |
| `MACOS_CLI_SIGN_IDENTITY` | Developer ID Application identity label | *(none — required for `developer-id`)* |
| `MACOS_CLI_SIGN_TIMESTAMP` | exactly `1` or `0` | `1` |
| `MACOS_CLI_SIGN_CONFIG` | path to a config file | `~/.config/macos-cli/signing.env` |

The config file is parsed strictly, and every rejection names the file and the
offending line number:

- Only the three `MACOS_CLI_SIGN_*` keys above may be assigned. Any other
  **unknown key** is an error, as is any line that is not a `KEY=VALUE`
  assignment (blank lines and `#` comments are ignored).
- A key may be assigned **at most once**; a **duplicate** assignment is an error
  rather than a last-one-wins surprise.
- A value that opens a `"` or `'` must close it with the same quote; an
  **unclosed** quote is an error, not a value with its last character removed.
- `MACOS_CLI_SIGN_TIMESTAMP` must be exactly `0` or `1`, from the environment or
  the file. `2`, `yes`, `true`, `01` and an empty value are all rejected — they
  are not silently read as "enabled".

```bash
# Production install — durable permissions
export MACOS_CLI_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
./install.sh

# Contributor / local build — permissions reset on every rebuild
MACOS_CLI_SIGN_MODE=adhoc ./install.sh
```

There is **no fallback between modes**. Missing identity, uninstalled identity,
unknown mode, or a `MACOS_CLI_SIGN_CONFIG` pointing at a nonexistent file each
abort with an explicit message *before* the build starts, and the install
directory is never created or written.

`--timestamp` needs network access to Apple's timestamp server. Setting
`MACOS_CLI_SIGN_TIMESTAMP=0` signs without one: the Developer ID identity is
still stable, but the artifact **cannot be notarized**.

## What the install path verifies before it declares success

`install.sh` stages the binary inside the destination directory, signs it there,
and only swaps it in after all of the following pass (`scripts/lib/sign_verify.sh`).
The staging file is created with `mktemp` (exclusive create, mode 0600) rather
than at a predictable `.macos.tmp.$$` name, and every path involved is checked
to be a regular non-symlink file, so nobody who can write the install directory
can redirect the copy — or the `codesign` that follows it — onto another file.

1. `sv_verify_info_plist` — an `__TEXT,__info_plist` section exists, lints as a
   plist, carries `com.manuaudio.macos-cli`, the expected version in both
   `CFBundleShortVersionString` and `CFBundleVersion`, and a non-empty value for
   every required usage-description key.
2. `sv_verify_entitlements` — the entitlements read back off the *signed
   artifact* are exactly `com.apple.security.automation.apple-events`. Missing
   it fails; carrying anything extra fails. This runs inside
   `sv_verify_signature`, so a signing path that stopped applying entitlements
   could not pass while a separate fixture test still went green.
3. `sv_verify_signature` — `codesign --verify --strict` passes, the signature's
   `Identifier` equals the pinned bundle id, the Info.plist is *sealed into* the
   signature, and the designated requirement pins that identifier. In
   `developer-id` mode it additionally requires a `TeamIdentifier`, a
   `Developer ID Application` authority, `anchor apple generic`, the team's
   `subject.OU` in the requirement, the Hardened Runtime flag, and an independent
   `codesign --verify -R=…` against that requirement.
4. `sv_verify_version` — the signed artifact runs and prints the expected version.
5. `sv_atomic_install` — the staged file must be a regular, non-symlink file in
   the *same* directory and on the same filesystem as the destination, so the
   swap is a `rename(2)` and a concurrent `macos` invocation can never observe a
   half-written or half-signed executable. A cross-directory or cross-filesystem
   staging path, a symlinked staging file, and a destination that is not a
   regular file are all refused rather than silently accepted.
6. Post-swap, the version and signature checks are repeated against the file
   that actually landed on disk.

### What a failure actually leaves behind

Every check up to and including step 5 runs *before* the rename, so failing any
of them leaves the previously installed executable untouched.

The rename itself is destructive, so "nothing was installed" stops being true
the moment it lands — and step 6 runs after it. `sv_install_with_rollback`
therefore copies the existing executable aside first (same directory, same
`mktemp` exclusive-create rule, original mode preserved) and, if the post-swap
verification fails, moves it back with another same-directory rename. So:

- **Pre-swap failure** — the old executable was never touched.
- **Post-swap failure with a previous install** — the old executable is
  **rolled back** into place, and the installer exits non-zero.
- **Post-swap failure on a first install** — there is nothing to restore, so the
  newly installed file is removed rather than left on `PATH` unverified.
- **A failed rollback** (the restore rename itself fails) prints the path of the
  preserved previous executable so you can move it back by hand.

The rollback path is exercised by the contract suite with a forced post-swap
verification failure; it has not been exercised against a real Developer ID
install on this machine (see *Not covered here*).

## Staging a release

```bash
./scripts/stage-release.sh            # Developer ID
./scripts/stage-release.sh --allow-dirty
```

Builds, signs a **copy** in `dist/staging/`, verifies it, and writes
`dist/staging/macos-cli-<rev>-staging.json` recording the git revision and
dirtiness, the toolchain, the as-built (pre-codesign) SHA-256, the embedded
Info.plist SHA-256, the signed artifact's SHA-256 and cdhash, the signing mode,
the public identity label, the Team ID, the entitlements found on the artifact,
and the resulting designated requirement.

The manifest is built as a property list and converted by `plutil`'s own JSON
writer (`sv_manifest_begin` / `sv_manifest_set` / `sv_manifest_write_json`), so
values like the designated requirement — quotes, backslashes and all — are
escaped by a real encoder instead of hand-written `sed`.

It installs nothing and adds nothing to your PATH. The manifest carries no
secrets — no certificate hashes, no Keychain material, no private data.

### What the manifest proves about the source

- **Clean tree**: the recorded `git_revision` identifies the source the bytes
  were built from, and `source_reconstructible` is `true`.
- **Dirty tree (`--allow-dirty`)**: `source_reconstructible` is `false` and the
  manifest makes no claim of tying the artifact to a committed revision. What it
  does record is deterministic evidence of the working-tree state:
  `git_tracked_diff_sha256` (SHA-256 of `git diff HEAD`),
  `git_untracked_sha256` (SHA-256 over the sorted `digest  path` index of every
  untracked, non-ignored file) and `git_untracked_file_count`, plus two
  sidecars — `…-dirty.patch` and `…-untracked-index.txt`. Those let you check
  later whether a given tree matches the one that was built; they do not let you
  rebuild it.

The *procedure* is reproducible; the signed bytes are not bit-identical between
runs, because a Developer ID signature embeds an RFC-3161 secure timestamp.
Compare `as_built_sha256` to check the build; use `signed_sha256` to identify
one specific signed artifact.

## Tests

```bash
bash scripts/tests/installer_contract_test.sh                 # fast, hermetic
MACOS_CLI_TEST_E2E=1 bash scripts/tests/installer_contract_test.sh          # + real ad-hoc install into a temp dir
MACOS_CLI_TEST_INTEGRATION=1 bash scripts/tests/installer_contract_test.sh  # + this machine's real keychain
```

The default run is **hermetic**: it never consults the live Keychain, so the
check count and results are the same on every machine. The identity-resolution
path is still covered, with a mocked `security` binary on `PATH`. Checks that
depend on what is actually installed in *your* keychain live behind
`MACOS_CLI_TEST_INTEGRATION=1`.

The suite builds throwaway Mach-O fixtures with crafted good/bad Info.plists,
entitlements and signatures, and asserts the verification helpers reject each
defect individually: missing section, wrong bundle id, wrong version, missing
usage description (including the Location keys), missing Apple Events
entitlement, an extra entitlement, wrong identifier, tampered bytes, ad-hoc
signature offered as production, cross-directory install, a symlinked staging
path, a symlinked destination, a malformed signing config, and a forced
post-swap failure that must roll the previous executable back.

## Not covered here

- **Notarization and stapling.** `--options runtime` and a secure timestamp make
  the artifact *eligible*. Nothing in this repo runs `notarytool submit` or
  `stapler`, and no artifact produced here has been through notarization.
- **Distribution.** No zip/DMG packaging, no release upload.
- **Terminal vs. launchd Automation attribution.** Which process TCC records as
  *responsible* for the Apple events this CLI sends via `/usr/bin/osascript` has
  not been tested, from an interactive terminal or from a launchd job. Until
  both are exercised on a real machine, the attribution claims above are
  intent, not evidence. (This tool loads no LaunchAgent itself.)
- **Grant survival across a rebuild** — including Full Disk Access — must be
  confirmed on a real machine: grant once, rebuild and reinstall with the same
  Developer ID identity to the same path, and check the permission is still
  there.
- **Real-install rollback.** The rollback path is covered by the contract suite
  with a simulated post-swap failure; it has not been run against a real
  Developer ID install.
