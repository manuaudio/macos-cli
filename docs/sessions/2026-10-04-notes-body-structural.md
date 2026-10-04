# Notes structural body repair — 2026-10-04

Candidate branch: `manuaudio/notes-body-structural-20261004`, based on `efa0635`. Builder only; no merge or installation.

The generic Notes text heuristic rejected two unprotected, valid gzip/UTF-8 bodies because their letter/whitespace ratios were below 30%. The Notes-specific decoder now validates the complete protobuf messages along the observed document/note/text path (2/3/2), requires a unique correctly typed field at each level, and returns its UTF-8 string verbatim. Numeric, punctuation, short, empty, whitespace, and Unicode bodies are supported. The generic recursive extraction API is unchanged. Gzip Notes input additionally checks method/reserved flags, decoded CRC32 and ISIZE. Unsupported paths, malformed tags/varints/lengths, truncated fixed-width fields, duplicate target fields, invalid UTF-8 and corrupt compression remain errors. Protected notes are refused explicitly before decoding; export selects the protection flag and reports missing data as an error, distinct from a valid empty body. No collector changes.

## Validation

All commands run in the isolated macos-cli checkout, with Swift parallelism capped at four:

- `swift run -j 4 MacCLICoreTestRunner`: exit 0, **245 checks passed**.
- `swift test -j 4`: exit 0, **54 XCTest tests, zero failures** (the separate Swift Testing footer has zero tests).
- `bash scripts/tests/installer_contract_test.sh`: exit 0, **200 passed, zero failed**.
- `swift build -c release -j 4 --scratch-path /Volumes/Overflow/builds/macos-cli-notes-20261004`: exit 0, 20.06 seconds. SwiftPM canonical `--show-bin-path` returned the path below.
- Candidate `notes export`, captured exclusively in memory: exit 0, **167 nondeleted records, zero body_error, zero null bodies**. No bodies, titles, snippets or private IDs were printed or saved. This verifies read-only export, not collection or publication. Initial path assumption was corrected using SwiftPM's canonical path; that first attempt did not execute any binary.
- `git diff --check`: exit 0.

Synthetic cases cover low-ratio shapes, metadata longer than the actual body, Unicode, short/empty/whitespace, protection, unsupported layouts, invalid UTF-8, duplicate body fields, zero tags, truncated/overflow varints and lengths, truncated fixed-width data, corrupt/truncated gzip and CRC/size corruption. Existing authorization/filter/serialization and generic Unicode extraction checks remain.

Artifact: `/Volumes/Overflow/builds/macos-cli-notes-20261004/out/Products/Release/macos-cli`.
SHA256: `c0ddf305447a391b2aae72bba696cf2c1d248cc4bbd8db8cb3b99f4688f1ebd9`.
This is the SwiftPM as-built executable, with its linker signature, not a Developer-ID-staged/notarized release. No security configuration or installed executable was changed.

## Root installation and rollback (not executed by builder)

After independent verification/review, root can use the repository's existing installer and existing Developer ID configuration. Do not select the ad-hoc installer mode or alter permissions. From this exact reviewed isolated checkout:

```sh
cd /Users/factory/Developer/.worktrees/macos-cli/notes-body-structural-20261004
swift run -j 4 MacCLICoreTestRunner
swift test -j 4
bash scripts/tests/installer_contract_test.sh
swift build -c release -j 4
cp -p /Users/factory/.local/bin/macos /Volumes/Overflow/builds/macos-cli-notes-20261004/macos-before-notes-repair
codesign --verify --strict /Volumes/Overflow/builds/macos-cli-notes-20261004/macos-before-notes-repair
./install.sh
codesign --verify --strict /Users/factory/.local/bin/macos
```

The capped prebuild makes the installer's build incremental. `install.sh` loads the existing signing configuration, verifies the embedded plist/version, signs and verifies a same-directory staged binary, and atomically swaps with automatic rollback on post-swap failure. Missing valid Developer ID configuration is an external signing dependency, not permission to fall back or regrant TCC. The installer requires access to Apple's timestamp server under its existing timestamp policy. Neither dependency was exercised by this builder.

If root's independent post-install verification fails, preserve the already signed previous executable using a same-directory atomic restore:

```sh
python3 - <<'PY'
import os, pathlib, shutil, subprocess, tempfile
source = pathlib.Path('/Volumes/Overflow/builds/macos-cli-notes-20261004/macos-before-notes-repair')
dest = pathlib.Path('/Users/factory/.local/bin/macos')
subprocess.run(['codesign', '--verify', '--strict', str(source)], check=True)
fd, staged = tempfile.mkstemp(prefix='.macos.rollback.', dir=dest.parent)
os.close(fd)
try:
    shutil.copy2(source, staged)
    subprocess.run(['codesign', '--verify', '--strict', staged], check=True)
    os.replace(staged, dest)
finally:
    if os.path.exists(staged): os.unlink(staged)
PY
codesign --verify --strict /Users/factory/.local/bin/macos
```

Root should verify export using count-only in-memory handling, then manage any normal collector recovery independently. This candidate does not run the collector, write Notes or mirror state, modify authentication, install software, invoke updates, or change services. Primary checkout is preserved. Unsupported future Notes schemas remain explicit errors; there is no recurrence guarantee or broad security workaround.
