#!/bin/bash
# Installer / build-identity contract tests.
#
# These lock down the *durability* of the installed artifact's code identity —
# the property that makes a granted TCC permission survive a reinstall:
#
#   1. An Info.plist is embedded in the executable (__TEXT,__info_plist) with
#      bounded, human-readable usage descriptions.
#   2. The documented install path signs with a Developer ID identity taken from
#      an explicit environment/config input, with `--options runtime` and the
#      stable identifier com.manuaudio.macos-cli.
#   3. There is an explicit contributor/local ad-hoc mode, and NO silent fallback
#      between the two.
#   4. The build/install path verifies plist + signature designated requirement +
#      version, and replaces the destination atomically from the same directory.
#
# Run:  bash scripts/tests/installer_contract_test.sh
#       MACOS_CLI_TEST_E2E=1 bash scripts/tests/installer_contract_test.sh  (adds a
#       full ad-hoc build+install into a throwaway temp dir; slow)
#       MACOS_CLI_TEST_INTEGRATION=1 bash scripts/tests/installer_contract_test.sh
#         (adds checks that consult THIS machine's real login keychain)
#
# The default run is hermetic: it never consults the live Keychain, so the check
# count and the results are identical on every machine. Keychain-dependent checks
# live behind MACOS_CLI_TEST_INTEGRATION=1; the hermetic suite covers the same
# code path with a mocked `security` binary on PATH.
#
# Nothing here reads Apple private data, touches the real install directory,
# loads a LaunchAgent, or prints certificate hashes.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="$REPO_ROOT/scripts/lib/sign_verify.sh"
PLIST="$REPO_ROOT/Resources/macos-cli-Info.plist"
ENTITLEMENTS="$REPO_ROOT/Resources/macos-cli.entitlements"
STAGE="$REPO_ROOT/scripts/stage-release.sh"
INSTALL_SH="$REPO_ROOT/install.sh"
SIGNING_DOC="$REPO_ROOT/docs/SIGNING.md"

BUNDLE_ID="com.manuaudio.macos-cli"
EXPECTED_VERSION="0.8.1"
APPLE_EVENTS_ENT="com.apple.security.automation.apple-events"

# Every usage-description key the embedded plist must carry, one per TCC surface
# the CLI actually touches. Location is here because LocationCommand.swift calls
# CLLocationManager.requestWhenInUseAuthorization().
REQUIRED_USAGE_KEYS=(
    NSContactsUsageDescription
    NSCalendarsUsageDescription
    NSCalendarsFullAccessUsageDescription
    NSRemindersUsageDescription
    NSRemindersFullAccessUsageDescription
    NSAppleEventsUsageDescription
    NSLocationUsageDescription
    NSLocationWhenInUseUsageDescription
)

PASS=0
FAIL=0
FAILED_NAMES=()

ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1"); printf '  FAIL %s\n' "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; return 0; }
group(){ printf '\n== %s ==\n' "$1"; }

# assert_ok NAME CMD...   — command must exit 0
assert_ok() {
    local name="$1"; shift
    local out
    if out="$("$@" 2>&1)"; then ok "$name"; else bad "$name" "exit!=0: ${out:0:400}"; fi
}
# assert_fails NAME CMD... — command must exit non-zero
assert_fails() {
    local name="$1"; shift
    local out
    if out="$("$@" 2>&1)"; then bad "$name" "expected non-zero exit, got 0: ${out:0:400}"; else ok "$name"; fi
}
assert_eq() {
    local name="$1" actual="$2" expected="$3"
    if [ "$actual" = "$expected" ]; then ok "$name"; else bad "$name" "expected '$expected', got '$actual'"; fi
}
assert_file() {
    local name="$1" path="$2"
    if [ -f "$path" ]; then ok "$name"; else bad "$name" "missing file: $path"; fi
}
assert_grep() {   # assert_grep NAME PATTERN FILE
    local name="$1" pat="$2" file="$3"
    if [ -f "$file" ] && grep -Eq "$pat" "$file"; then ok "$name"; else bad "$name" "pattern not found in $file: $pat"; fi
}
assert_not_grep() {
    local name="$1" pat="$2" file="$3"
    if [ ! -f "$file" ]; then bad "$name" "missing file: $file"; return; fi
    if grep -Eq "$pat" "$file"; then bad "$name" "forbidden pattern present in $file: $pat"; else ok "$name"; fi
}

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/macos-cli-contract.XXXXXX")"
cleanup() { rm -rf "$TMPROOT"; }
trap cleanup EXIT

# macOS ships no coreutils `timeout`; this is the bash-native equivalent.
# The watchdog's stdout is redirected so command substitution around a call
# still returns as soon as the real command exits.
TIMED_OUT_RC=137
run_with_timeout() {   # run_with_timeout SECONDS CMD...
    local secs="$1"; shift
    "$@" &
    local pid=$!
    ( sleep "$secs"; kill -9 "$pid" 2>/dev/null ) >/dev/null 2>&1 &
    local watcher=$!
    local rc=0
    wait "$pid" || rc=$?
    kill "$watcher" 2>/dev/null
    wait "$watcher" 2>/dev/null
    return "$rc"
}

# Build a throwaway Mach-O carrying an arbitrary embedded Info.plist.
# Used to exercise the verification helpers on crafted (good and bad) inputs
# without rebuilding the real product.
make_fixture() {   # make_fixture OUT [PLIST_PATH]
    local out="$1" plist="${2:-}"
    local src="$TMPROOT/fixture-main.c"
    printf 'int main(void){return 0;}\n' > "$src"
    if [ -n "$plist" ]; then
        clang -o "$out" "$src" -Wl,-sectcreate,__TEXT,__info_plist,"$plist" 2>/dev/null
    else
        clang -o "$out" "$src" 2>/dev/null
    fi
}

# A syntactically valid plist with an overridable key set.
write_plist() {   # write_plist PATH BUNDLE_ID VERSION [omit_key]
    local path="$1" bid="$2" ver="$3" omit="${4:-}"
    {
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
        echo '<plist version="1.0"><dict>'
        echo "<key>CFBundleIdentifier</key><string>$bid</string>"
        echo '<key>CFBundleName</key><string>macos</string>'
        echo "<key>CFBundleShortVersionString</key><string>$ver</string>"
        echo "<key>CFBundleVersion</key><string>$ver</string>"
        local k
        for k in "${REQUIRED_USAGE_KEYS[@]}"; do
            [ "$k" = "$omit" ] && continue
            echo "<key>$k</key><string>Fixture rationale sentence for contract tests.</string>"
        done
        echo '</dict></plist>'
    } > "$path"
}

# Sign a fixture ad-hoc with an arbitrary entitlements plist (or none).
sign_fixture() {   # sign_fixture BIN [ENTITLEMENTS_PATH] [IDENTIFIER]
    local bin="$1" ent="${2:-}" ident="${3:-$BUNDLE_ID}"
    local -a a=(--force --sign - --options runtime --identifier "$ident")
    [ -n "$ent" ] && a+=(--entitlements "$ent")
    codesign "${a[@]}" "$bin" 2>/dev/null
}

write_entitlements() {   # write_entitlements PATH KEY...
    local path="$1"; shift
    {
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
        echo '<plist version="1.0"><dict>'
        local k
        for k in "$@"; do echo "<key>$k</key><true/>"; done
        echo '</dict></plist>'
    } > "$path"
}

########################################################################
group "shell syntax"
########################################################################
for f in "$INSTALL_SH" "$LIB" "$STAGE" "${BASH_SOURCE[0]}"; do
    if [ -f "$f" ]; then
        assert_ok "bash -n $(basename "$f")" bash -n "$f"
    else
        bad "bash -n $(basename "$f")" "missing file: $f"
    fi
done
for f in "$INSTALL_SH" "$STAGE"; do
    if [ -x "$f" ]; then ok "executable: $(basename "$f")"; else bad "executable: $(basename "$f")" "not executable: $f"; fi
done

########################################################################
group "embedded Info.plist source of truth"
########################################################################
assert_file "Resources/macos-cli-Info.plist exists" "$PLIST"
if [ -f "$PLIST" ]; then
    assert_ok "plist lints" plutil -lint "$PLIST"
    assert_eq "plist CFBundleIdentifier" "$(plutil -extract CFBundleIdentifier raw -o - "$PLIST" 2>/dev/null)" "$BUNDLE_ID"
    assert_eq "plist CFBundleShortVersionString" "$(plutil -extract CFBundleShortVersionString raw -o - "$PLIST" 2>/dev/null)" "$EXPECTED_VERSION"
    assert_eq "plist CFBundleVersion" "$(plutil -extract CFBundleVersion raw -o - "$PLIST" 2>/dev/null)" "$EXPECTED_VERSION"

    # Version must not drift from the CLI's own --version string.
    swift_version="$(grep -Eo 'version: "[0-9][^"]*"' "$REPO_ROOT/Sources/macos-cli/MacOSCLI.swift" | head -1 | sed -E 's/.*"(.*)"/\1/')"
    assert_eq "plist version matches MacOSCLI.swift" "$swift_version" "$EXPECTED_VERSION"

    # Bounded, human-readable usage descriptions for every TCC surface the CLI uses.
    for key in "${REQUIRED_USAGE_KEYS[@]}"; do
        val="$(plutil -extract "$key" raw -o - "$PLIST" 2>/dev/null)"
        if [ -z "$val" ]; then
            bad "usage description $key" "key missing or empty"
            continue
        fi
        len=${#val}
        if [ "$len" -lt 24 ] || [ "$len" -gt 200 ]; then
            bad "usage description $key bounded 24..200 chars" "length $len"
        elif [[ "$val" != *" "* ]]; then
            bad "usage description $key human-readable" "no spaces: $val"
        elif [[ "$val" != *. ]]; then
            bad "usage description $key ends in a period" "$val"
        elif [[ "$val" == *TODO* || "$val" == *XXX* ]]; then
            bad "usage description $key has no placeholder text" "$val"
        else
            ok "usage description $key bounded + human-readable ($len chars)"
        fi
    done

    # Every TCC API the sources actually call must have its usage description in
    # the plist. A key list that drifts from the code produces a blank (or
    # missing) system prompt at exactly the moment the user is asked to trust us.
    if grep -rqs 'requestWhenInUseAuthorization' "$REPO_ROOT/Sources"; then
        for key in NSLocationUsageDescription NSLocationWhenInUseUsageDescription; do
            val="$(plutil -extract "$key" raw -o - "$PLIST" 2>/dev/null)"
            if [ -n "$val" ]; then ok "CoreLocation is used => $key present"
            else bad "CoreLocation is used => $key present" "sources call requestWhenInUseAuthorization but $key is missing from $PLIST"; fi
        done
    else
        printf '  skip sources do not call requestWhenInUseAuthorization\n'
    fi

    # macOS has NO Info.plist key that grants Full Disk Access. The plist must not
    # imply otherwise with an Apple-namespaced key, and the rationale must live in
    # a clearly non-Apple, non-TCC key plus separate documentation.
    assert_not_grep "no fake Apple-namespaced Full Disk Access key" '<key>NS[A-Za-z]*FullDisk[A-Za-z]*</key>' "$PLIST"
    fda="$(plutil -extract MacOSCLIFullDiskAccessRationale raw -o - "$PLIST" 2>/dev/null)"
    if [ -n "$fda" ]; then ok "custom (non-Apple-namespaced) FDA rationale key present"; else bad "custom (non-Apple-namespaced) FDA rationale key present" "MacOSCLIFullDiskAccessRationale missing"; fi
fi

assert_file "Resources/macos-cli.entitlements exists" "$ENTITLEMENTS"
if [ -f "$ENTITLEMENTS" ]; then
    assert_ok "entitlements lints" plutil -lint "$ENTITLEMENTS"
    # plutil treats '.' as a key-path separator, so the reverse-DNS entitlement
    # key has to be escaped or it resolves to a nonexistent nested path.
    assert_eq "hardened-runtime Apple Events entitlement" \
        "$(plutil -extract 'com\.apple\.security\.automation\.apple-events' raw -o - "$ENTITLEMENTS" 2>/dev/null)" "true"

    # plutil is NOT the parser that matters. codesign hands the entitlements to
    # AMFI's much stricter XML reader (AMFIUnserializeXML), which rejects things
    # plutil happily accepts — a leading comment block, for one. So sign a real
    # throwaway Mach-O with the real file and require codesign itself to accept
    # it, then require the entitlement to actually land in the signature.
    make_fixture "$TMPROOT/bin-ent"
    if [ -x "$TMPROOT/bin-ent" ]; then
        if out="$(codesign --force --sign - --options runtime \
                    --identifier "$BUNDLE_ID" \
                    --entitlements "$ENTITLEMENTS" "$TMPROOT/bin-ent" 2>&1)"; then
            ok "codesign accepts the entitlements file (AMFI XML parser)"
            if codesign -d --entitlements - --xml "$TMPROOT/bin-ent" 2>/dev/null \
                 | plutil -extract 'com\.apple\.security\.automation\.apple-events' raw -o - - 2>/dev/null \
                 | grep -q '^true$'; then
                ok "signed binary carries the Apple Events entitlement"
            else
                bad "signed binary carries the Apple Events entitlement" "entitlement absent from the signature"
            fi
        else
            bad "codesign accepts the entitlements file (AMFI XML parser)" "${out:0:400}"
            bad "signed binary carries the Apple Events entitlement" "signing failed"
        fi
    else
        bad "codesign accepts the entitlements file (AMFI XML parser)" "clang fixture build failed"
        bad "signed binary carries the Apple Events entitlement" "clang fixture build failed"
    fi
fi

assert_file "docs/SIGNING.md exists" "$SIGNING_DOC"
if [ -f "$SIGNING_DOC" ]; then
    assert_grep "SIGNING.md documents Full Disk Access separately" 'Full Disk Access' "$SIGNING_DOC"
    assert_grep "SIGNING.md states no Info.plist key grants FDA" '[Nn]o .*Info\.plist key' "$SIGNING_DOC"
    assert_grep "SIGNING.md documents the ad-hoc contributor mode" 'MACOS_CLI_SIGN_MODE' "$SIGNING_DOC"
fi

########################################################################
group "Package.swift embeds the plist into the executable"
########################################################################
PKG="$REPO_ROOT/Package.swift"
assert_grep "Package.swift uses -sectcreate" '\-sectcreate' "$PKG"
assert_grep "Package.swift targets __TEXT,__info_plist" '__info_plist' "$PKG"
assert_grep "Package.swift references the plist by absolute package path" 'Context\.packageDirectory' "$PKG"
assert_grep "Package.swift references macos-cli-Info.plist" 'macos-cli-Info\.plist' "$PKG"

########################################################################
group "sign/verify library"
########################################################################
LIB_OK=0
if [ -f "$LIB" ]; then
    # shellcheck source=/dev/null
    if source "$LIB" 2>"$TMPROOT/source.err"; then LIB_OK=1; ok "sign_verify.sh sources cleanly"
    else bad "sign_verify.sh sources cleanly" "$(head -3 "$TMPROOT/source.err")"; fi
else
    bad "scripts/lib/sign_verify.sh exists" "missing file: $LIB"
fi

lib_missing() { bad "$1" "cannot run: scripts/lib/sign_verify.sh unavailable"; }

if [ "$LIB_OK" = 1 ]; then
    assert_eq "SV_BUNDLE_ID constant" "${SV_BUNDLE_ID:-}" "$BUNDLE_ID"
    assert_eq "SV_EXPECTED_VERSION constant" "${SV_EXPECTED_VERSION:-}" "$EXPECTED_VERSION"

    # The verifier's "complete" key list must really be complete, or every check
    # built on it is false-green.
    for key in "${REQUIRED_USAGE_KEYS[@]}"; do
        found=0
        for k in "${SV_REQUIRED_PLIST_KEYS[@]:-}"; do [ "$k" = "$key" ] && found=1; done
        if [ "$found" = 1 ]; then ok "SV_REQUIRED_PLIST_KEYS contains $key"
        else bad "SV_REQUIRED_PLIST_KEYS contains $key" "verifier does not require $key"; fi
    done

    # --- config resolution: explicit input, loud failure, no silent fallback ---
    cfg_run() {  # cfg_run <env assignments...> -> prints "MODE|IDENTITY", exit code preserved
        env -u MACOS_CLI_SIGN_MODE -u MACOS_CLI_SIGN_IDENTITY -u MACOS_CLI_SIGN_CONFIG -u XDG_CONFIG_HOME \
            HOME="$TMPROOT/fakehome" "$@" \
            bash -c 'source "$0"; sv_load_sign_config >/dev/null || exit 1; printf "%s|%s\n" "$SV_SIGN_MODE" "$SV_SIGN_IDENTITY"' "$LIB"
    }
    mkdir -p "$TMPROOT/fakehome"

    # No explicit input at all: must fail loudly, never quietly ad-hoc sign.
    out="$(cfg_run 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ]; then ok "no signing input => hard failure (no silent fallback)"
    else bad "no signing input => hard failure (no silent fallback)" "exited 0 with: $out"; fi
    if [[ "$out" == *MACOS_CLI_SIGN_IDENTITY* && "$out" == *MACOS_CLI_SIGN_MODE* ]]; then
        ok "failure message names both env vars"
    else bad "failure message names both env vars" "$out"; fi
    if [[ "$out" != *adhoc*fallback* ]]; then ok "failure message does not promise a fallback"; else bad "failure message does not promise a fallback" "$out"; fi

    # developer-id explicitly requested but no identity: must fail, must NOT become ad-hoc.
    out="$(cfg_run MACOS_CLI_SIGN_MODE=developer-id 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ]; then ok "developer-id without identity => hard failure"
    else bad "developer-id without identity => hard failure" "exited 0 with: $out"; fi
    if [[ "$out" != *"|adhoc"* && "$out" != adhoc\|* ]]; then ok "developer-id failure never resolves to adhoc"
    else bad "developer-id failure never resolves to adhoc" "$out"; fi

    # Explicit contributor/local mode works and is opt-in.
    out="$(cfg_run MACOS_CLI_SIGN_MODE=adhoc 2>/dev/null)"; rc=$?
    if [ "$rc" -eq 0 ] && [ "${out%%|*}" = "adhoc" ]; then ok "explicit adhoc mode resolves"
    else bad "explicit adhoc mode resolves" "rc=$rc out=$out"; fi

    # Unknown mode is rejected.
    assert_fails "unknown sign mode rejected" env HOME="$TMPROOT/fakehome" MACOS_CLI_SIGN_MODE=banana \
        bash -c 'source "$0"; sv_load_sign_config' "$LIB"

    # A Developer ID identity that is not installed must fail (never silently downgrade).
    out="$(cfg_run MACOS_CLI_SIGN_MODE=developer-id MACOS_CLI_SIGN_IDENTITY="Developer ID Application: Nobody (ZZZZZZZZZZ)" 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ]; then ok "uninstalled Developer ID identity => hard failure"
    else bad "uninstalled Developer ID identity => hard failure" "exited 0 with: $out"; fi

    # Config file supplies the identity; the environment overrides the file.
    cfgdir="$TMPROOT/cfg"; mkdir -p "$cfgdir"
    cat > "$cfgdir/signing.env" <<'EOF'
MACOS_CLI_SIGN_MODE=adhoc
MACOS_CLI_SIGN_IDENTITY=from-config
EOF
    out="$(env -u MACOS_CLI_SIGN_MODE -u MACOS_CLI_SIGN_IDENTITY HOME="$TMPROOT/fakehome" \
        MACOS_CLI_SIGN_CONFIG="$cfgdir/signing.env" \
        bash -c 'source "$0"; sv_load_sign_config >/dev/null || exit 1; printf "%s|%s\n" "$SV_SIGN_MODE" "$SV_SIGN_IDENTITY"' "$LIB" 2>&1)"
    assert_eq "config file supplies mode" "${out%%|*}" "adhoc"

    out="$(env -u MACOS_CLI_SIGN_IDENTITY HOME="$TMPROOT/fakehome" \
        MACOS_CLI_SIGN_CONFIG="$cfgdir/signing.env" MACOS_CLI_SIGN_MODE=adhoc \
        bash -c 'source "$0"; sv_load_sign_config >/dev/null || exit 1; printf "%s\n" "$SV_SIGN_MODE"' "$LIB" 2>&1)"
    assert_eq "environment overrides config file" "$out" "adhoc"

    # An explicitly-pointed-at config that does not exist is an error, not a silent skip.
    assert_fails "missing explicit config file is an error" env HOME="$TMPROOT/fakehome" \
        MACOS_CLI_SIGN_CONFIG="$TMPROOT/nope.env" MACOS_CLI_SIGN_MODE=adhoc \
        bash -c 'source "$0"; sv_load_sign_config' "$LIB"

    ####################################################################
    group "signing config is validated to its documented contract"
    ####################################################################
    # A config file is only ever *parsed*. Anything it says that the documented
    # contract does not allow must abort, never be silently reinterpreted.
    write_cfg() {   # write_cfg NAME <<lines
        local name="$1"; shift
        printf '%s\n' "$@" > "$TMPROOT/cfg-$name.env"
        printf '%s' "$TMPROOT/cfg-$name.env"
    }
    # cfg_load CFGPATH [env assignments...] -> prints "MODE|IDENTITY|TIMESTAMP"
    cfg_load() {
        local cfgpath="$1"; shift
        env -u MACOS_CLI_SIGN_MODE -u MACOS_CLI_SIGN_IDENTITY -u MACOS_CLI_SIGN_TIMESTAMP \
            -u XDG_CONFIG_HOME HOME="$TMPROOT/fakehome" MACOS_CLI_SIGN_CONFIG="$cfgpath" "$@" \
            bash -c 'source "$0"; sv_load_sign_config >/dev/null || exit 1
                     printf "%s|%s|%s\n" "$SV_SIGN_MODE" "$SV_SIGN_IDENTITY" "$SV_SIGN_TIMESTAMP"' "$LIB"
    }

    # --- MACOS_CLI_SIGN_TIMESTAMP is exactly 0 or 1 ---
    c="$(write_cfg ts-ok 'MACOS_CLI_SIGN_MODE=developer-id' 'MACOS_CLI_SIGN_IDENTITY=x' 'MACOS_CLI_SIGN_TIMESTAMP=0')"
    for bad_ts in 2 yes true "" " " 01 -1 0x0; do
        c_bad="$(write_cfg ts-bad "MACOS_CLI_SIGN_MODE=adhoc" "MACOS_CLI_SIGN_TIMESTAMP=$bad_ts")"
        if out="$(cfg_load "$c_bad" 2>&1)"; then
            bad "config MACOS_CLI_SIGN_TIMESTAMP='$bad_ts' rejected" "accepted, resolved to: $out"
        else ok "config MACOS_CLI_SIGN_TIMESTAMP='$bad_ts' rejected"; fi
    done
    for bad_ts in 2 yes ""; do
        if out="$(env HOME="$TMPROOT/fakehome" MACOS_CLI_SIGN_MODE=adhoc MACOS_CLI_SIGN_TIMESTAMP="$bad_ts" \
                    bash -c 'source "$0"; sv_load_sign_config' "$LIB" 2>&1)"; then
            bad "env MACOS_CLI_SIGN_TIMESTAMP='$bad_ts' rejected" "accepted"
        else ok "env MACOS_CLI_SIGN_TIMESTAMP='$bad_ts' rejected"; fi
    done
    c="$(write_cfg ts-one 'MACOS_CLI_SIGN_MODE=adhoc' 'MACOS_CLI_SIGN_TIMESTAMP=1')"
    out="$(cfg_load "$c" 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ]; then ok "config MACOS_CLI_SIGN_TIMESTAMP=1 accepted"; else bad "config MACOS_CLI_SIGN_TIMESTAMP=1 accepted" "$out"; fi

    # --- quoting: a value that opens a quote must close it ---
    # Quote stripping is a property of the parser, so it is asserted on the
    # parser's own output. Reading it back through sv_load_sign_config in adhoc
    # mode would prove nothing: that mode deliberately replaces the identity
    # with the literal '-' codesign expects, so the assertion would stay green
    # even if the quotes were never stripped.
    cfg_identity() {   # cfg_identity CFGPATH -> prints _SV_CFG_IDENTITY; parser exit code preserved
        env -u MACOS_CLI_SIGN_MODE -u MACOS_CLI_SIGN_IDENTITY -u MACOS_CLI_SIGN_TIMESTAMP \
            -u MACOS_CLI_SIGN_CONFIG -u XDG_CONFIG_HOME HOME="$TMPROOT/fakehome" \
            bash -c 'source "$0"; _sv_parse_config "$1" || exit 1
                     printf "%s\n" "$_SV_CFG_IDENTITY"' "$LIB" "$1"
    }

    c="$(write_cfg q-ok 'MACOS_CLI_SIGN_MODE=developer-id' 'MACOS_CLI_SIGN_IDENTITY="Developer ID Application: Someone (TEAM123456)"')"
    assert_eq "matched double quotes are stripped" \
        "$(cfg_identity "$c" 2>/dev/null)" "Developer ID Application: Someone (TEAM123456)"

    c="$(write_cfg q-single 'MACOS_CLI_SIGN_MODE=developer-id' "MACOS_CLI_SIGN_IDENTITY='quoted value'")"
    assert_eq "matched single quotes are stripped" \
        "$(cfg_identity "$c" 2>/dev/null)" "quoted value"

    c="$(write_cfg q-unclosed 'MACOS_CLI_SIGN_MODE=adhoc' 'MACOS_CLI_SIGN_IDENTITY="unterminated')"
    if out="$(cfg_load "$c" 2>&1)"; then bad "unclosed double quote rejected" "accepted, resolved to: $out"
    else ok "unclosed double quote rejected"; fi

    c="$(write_cfg q-lone 'MACOS_CLI_SIGN_MODE=adhoc' 'MACOS_CLI_SIGN_IDENTITY="')"
    if out="$(cfg_load "$c" 2>&1)"; then
        bad "lone quote character rejected" "accepted, resolved to: $out"
    else ok "lone quote character rejected"; fi

    # --- duplicate / unknown / malformed lines ---
    c="$(write_cfg dup 'MACOS_CLI_SIGN_MODE=adhoc' 'MACOS_CLI_SIGN_MODE=developer-id')"
    if out="$(cfg_load "$c" 2>&1)"; then bad "duplicate assignment rejected" "accepted, resolved to: $out"
    else ok "duplicate assignment rejected"; fi

    c="$(write_cfg unknown 'MACOS_CLI_SIGN_MODE=adhoc' 'MACOS_CLI_SIGN_BANANA=1')"
    if out="$(cfg_load "$c" 2>&1)"; then bad "unknown MACOS_CLI_SIGN_* key rejected" "accepted, resolved to: $out"
    else ok "unknown MACOS_CLI_SIGN_* key rejected"; fi

    c="$(write_cfg garbage 'MACOS_CLI_SIGN_MODE=adhoc' 'rm -rf /')"
    if out="$(cfg_load "$c" 2>&1)"; then bad "non-assignment line rejected" "accepted, resolved to: $out"
    else ok "non-assignment line rejected"; fi

    c="$(write_cfg comments '# a comment' '' '   ' 'MACOS_CLI_SIGN_MODE=adhoc' '# trailing comment')"
    out="$(cfg_load "$c" 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ] && [ "${out%%|*}" = "adhoc" ]; then ok "comments and blank lines are allowed"
    else bad "comments and blank lines are allowed" "rc=$rc out=$out"; fi

    # A rejected config must name the offending file and line, not fail silently.
    c="$(write_cfg garbage2 'MACOS_CLI_SIGN_MODE=adhoc' 'oops')"
    out="$(cfg_load "$c" 2>&1 || true)"
    if [[ "$out" == *"$c"* ]]; then ok "config rejection names the config file"
    else bad "config rejection names the config file" "${out:0:300}"; fi

    ####################################################################
    group "keychain identity lookup (mocked — hermetic)"
    ####################################################################
    # The default suite must not depend on what is in THIS machine's keychain.
    # `security` is mocked on PATH so the identity-resolution path is exercised
    # deterministically everywhere.
    mockbin="$TMPROOT/mockbin"; mkdir -p "$mockbin"
    cat > "$mockbin/security" <<'MOCK'
#!/bin/bash
if [ "${1:-}" = "find-identity" ]; then
    printf '  1) %s "Developer ID Application: Mock Signer (MOCKTEAM01)"\n' "$(printf 'A%.0s' {1..40})"
    printf '     1 valid identities found\n'
    exit 0
fi
exit 1
MOCK
    chmod +x "$mockbin/security"
    mock_load() {   # mock_load IDENTITY -> exit code of sv_load_sign_config
        env -u MACOS_CLI_SIGN_CONFIG -u XDG_CONFIG_HOME HOME="$TMPROOT/fakehome" \
            PATH="$mockbin:$PATH" MACOS_CLI_SIGN_MODE=developer-id \
            MACOS_CLI_SIGN_IDENTITY="$1" \
            bash -c 'source "$0"; sv_load_sign_config' "$LIB"
    }
    assert_ok    "mocked keychain: matching Developer ID identity resolves" \
        mock_load "Developer ID Application: Mock Signer (MOCKTEAM01)"
    assert_fails "mocked keychain: absent identity is a hard failure" \
        mock_load "Developer ID Application: Someone Else (NOPE000000)"
    assert_fails "mocked keychain: prefix of an installed identity does not match" \
        mock_load "Developer ID Application: Mock Signer"

    # A quoted identity in a config file has to arrive at SV_SIGN_IDENTITY with
    # its quotes stripped. This is the developer-id path — the one where the
    # identity is used as written rather than replaced by '-' — so the mocked
    # keychain lookup only succeeds if the stripping actually happened.
    c="$(write_cfg q-mock 'MACOS_CLI_SIGN_MODE=developer-id' 'MACOS_CLI_SIGN_IDENTITY="Developer ID Application: Mock Signer (MOCKTEAM01)"')"
    out="$(env -u MACOS_CLI_SIGN_MODE -u MACOS_CLI_SIGN_IDENTITY -u XDG_CONFIG_HOME \
        HOME="$TMPROOT/fakehome" PATH="$mockbin:$PATH" MACOS_CLI_SIGN_CONFIG="$c" \
        bash -c 'source "$0"; sv_load_sign_config >/dev/null || exit 1
                 printf "%s\n" "$SV_SIGN_IDENTITY"' "$LIB" 2>&1)"
    assert_eq "mocked keychain: a quoted config identity resolves unquoted" \
        "$out" "Developer ID Application: Mock Signer (MOCKTEAM01)"

    # The hermetic suite itself must not shell out to the real keychain: every
    # invocation of the keychain identity tool in this file has to sit below the
    # integration guard marker.
    #
    # The scan term is assembled from fragments so this scanner cannot match its
    # own source line, and comment-only lines are skipped so prose describing the
    # rule is not mistaken for a breach of it. Either alone would make the check
    # report a violation it created itself, which is how it read before.
    kc_scan="secur""ity find-""identity"
    guard_line="$(grep -n '^# INTEGRATION-ONLY-BELOW' "${BASH_SOURCE[0]}" | head -1 | cut -d: -f1)"
    if [ -z "$guard_line" ]; then
        bad "default suite never queries the real keychain" "no '# INTEGRATION-ONLY-BELOW' marker in the suite"
    else
        early="$(grep -n -F -- "$kc_scan" "${BASH_SOURCE[0]}" \
                 | grep -v '^[0-9][0-9]*:[[:space:]]*#' \
                 | awk -F: -v g="$guard_line" '$1 < g {print $1}')"
        if [ -z "$early" ]; then ok "default suite never queries the real keychain"
        else bad "default suite never queries the real keychain" "live keychain query at line(s): $(printf '%s' "$early" | tr '\n' ' ')"; fi
    fi

    # --- Info.plist verification against real Mach-O fixtures ---
    write_plist "$TMPROOT/good.plist" "$BUNDLE_ID" "$EXPECTED_VERSION"
    write_plist "$TMPROOT/badid.plist" "com.example.other" "$EXPECTED_VERSION"
    write_plist "$TMPROOT/badver.plist" "$BUNDLE_ID" "9.9.9"
    write_plist "$TMPROOT/nokey.plist" "$BUNDLE_ID" "$EXPECTED_VERSION" NSContactsUsageDescription
    write_plist "$TMPROOT/noloc.plist" "$BUNDLE_ID" "$EXPECTED_VERSION" NSLocationUsageDescription
    write_plist "$TMPROOT/nolocwiu.plist" "$BUNDLE_ID" "$EXPECTED_VERSION" NSLocationWhenInUseUsageDescription

    make_fixture "$TMPROOT/bin-good"   "$TMPROOT/good.plist"
    make_fixture "$TMPROOT/bin-badid"  "$TMPROOT/badid.plist"
    make_fixture "$TMPROOT/bin-badver" "$TMPROOT/badver.plist"
    make_fixture "$TMPROOT/bin-nokey"  "$TMPROOT/nokey.plist"
    make_fixture "$TMPROOT/bin-noloc"  "$TMPROOT/noloc.plist"
    make_fixture "$TMPROOT/bin-nolocwiu" "$TMPROOT/nolocwiu.plist"
    make_fixture "$TMPROOT/bin-none"

    if [ -x "$TMPROOT/bin-good" ]; then
        assert_ok    "verify plist: well-formed fixture passes"          sv_verify_info_plist "$TMPROOT/bin-good"   "$EXPECTED_VERSION"
        assert_fails "verify plist: missing __info_plist section fails"  sv_verify_info_plist "$TMPROOT/bin-none"   "$EXPECTED_VERSION"
        assert_fails "verify plist: wrong bundle identifier fails"       sv_verify_info_plist "$TMPROOT/bin-badid"  "$EXPECTED_VERSION"
        assert_fails "verify plist: wrong version fails"                 sv_verify_info_plist "$TMPROOT/bin-badver" "$EXPECTED_VERSION"
        assert_fails "verify plist: missing usage description fails"     sv_verify_info_plist "$TMPROOT/bin-nokey"  "$EXPECTED_VERSION"
        assert_fails "verify plist: missing NSLocationUsageDescription fails" sv_verify_info_plist "$TMPROOT/bin-noloc" "$EXPECTED_VERSION"
        assert_fails "verify plist: missing NSLocationWhenInUseUsageDescription fails" sv_verify_info_plist "$TMPROOT/bin-nolocwiu" "$EXPECTED_VERSION"
        assert_ok    "extract plist from fixture"                        sv_extract_info_plist "$TMPROOT/bin-good" "$TMPROOT/extracted.plist"
        assert_fails "extract plist fails when section absent"           sv_extract_info_plist "$TMPROOT/bin-none" "$TMPROOT/extracted2.plist"
    else
        for t in "verify plist: well-formed fixture passes" "verify plist: missing __info_plist section fails" \
                 "verify plist: wrong bundle identifier fails" "verify plist: wrong version fails" \
                 "verify plist: missing usage description fails" "extract plist from fixture" \
                 "extract plist fails when section absent"; do
            bad "$t" "clang fixture build failed"
        done
    fi

    # --- signature verification ---
    if [ -x "$TMPROOT/bin-good" ]; then
        # Signed exactly the way the production path signs: the real entitlements
        # file, so the verifier is exercised against the real artifact shape.
        cp "$TMPROOT/bin-good" "$TMPROOT/bin-adhoc"
        sign_fixture "$TMPROOT/bin-adhoc" "$ENTITLEMENTS"
        assert_ok    "verify signature: adhoc binary passes in adhoc mode"        sv_verify_signature "$TMPROOT/bin-adhoc" adhoc
        assert_fails "verify signature: adhoc binary REJECTED in developer-id mode" sv_verify_signature "$TMPROOT/bin-adhoc" developer-id

        cp "$TMPROOT/bin-good" "$TMPROOT/bin-wrongid"
        sign_fixture "$TMPROOT/bin-wrongid" "$ENTITLEMENTS" "com.example.wrong"
        assert_fails "verify signature: wrong identifier rejected" sv_verify_signature "$TMPROOT/bin-wrongid" adhoc

        cp "$TMPROOT/bin-adhoc" "$TMPROOT/bin-tampered"
        printf 'tamper' >> "$TMPROOT/bin-tampered"
        assert_fails "verify signature: tampered binary rejected" sv_verify_signature "$TMPROOT/bin-tampered" adhoc
    else
        for t in "verify signature: adhoc binary passes in adhoc mode" \
                 "verify signature: adhoc binary REJECTED in developer-id mode" \
                 "verify signature: wrong identifier rejected" \
                 "verify signature: tampered binary rejected"; do
            bad "$t" "clang fixture build failed"
        done
    fi

    ####################################################################
    group "entitlements are verified on the artifact that ships"
    ####################################################################
    # The signing path could silently stop applying entitlements (bad
    # --entitlements path, edited flags) and every other check would still pass.
    # The shared verifier therefore has to read them back off the signed binary.
    if [ -x "$TMPROOT/bin-good" ]; then
        write_entitlements "$TMPROOT/ent-extra.plist" "$APPLE_EVENTS_ENT" "com.apple.security.cs.allow-jit"
        write_entitlements "$TMPROOT/ent-wrong.plist" "com.apple.security.cs.allow-jit"

        cp "$TMPROOT/bin-good" "$TMPROOT/bin-ent-none";  sign_fixture "$TMPROOT/bin-ent-none"
        cp "$TMPROOT/bin-good" "$TMPROOT/bin-ent-extra"; sign_fixture "$TMPROOT/bin-ent-extra" "$TMPROOT/ent-extra.plist"
        cp "$TMPROOT/bin-good" "$TMPROOT/bin-ent-wrong"; sign_fixture "$TMPROOT/bin-ent-wrong" "$TMPROOT/ent-wrong.plist"

        assert_ok    "verify entitlements: production entitlement set accepted"  sv_verify_entitlements "$TMPROOT/bin-adhoc"
        assert_fails "verify entitlements: no entitlements at all rejected"      sv_verify_entitlements "$TMPROOT/bin-ent-none"
        assert_fails "verify entitlements: extra entitlement rejected"           sv_verify_entitlements "$TMPROOT/bin-ent-extra"
        assert_fails "verify entitlements: wrong entitlement rejected"           sv_verify_entitlements "$TMPROOT/bin-ent-wrong"
        assert_fails "verify entitlements: unsigned binary rejected"             sv_verify_entitlements "$TMPROOT/bin-none"

        # …and sv_verify_signature must include that check, not leave it to a
        # test that only ever inspects a separate fixture.
        assert_fails "verify signature: missing Apple Events entitlement rejected" sv_verify_signature "$TMPROOT/bin-ent-none"  adhoc
        assert_fails "verify signature: extra entitlement rejected"                sv_verify_signature "$TMPROOT/bin-ent-extra" adhoc
    else
        for t in "verify entitlements: production entitlement set accepted" \
                 "verify entitlements: no entitlements at all rejected" \
                 "verify entitlements: extra entitlement rejected" \
                 "verify entitlements: wrong entitlement rejected" \
                 "verify entitlements: unsigned binary rejected" \
                 "verify signature: missing Apple Events entitlement rejected" \
                 "verify signature: extra entitlement rejected"; do
            bad "$t" "clang fixture build failed"
        done
    fi

    # --- version verification ---
    cat > "$TMPROOT/fake-version" <<EOF
#!/bin/bash
echo "$EXPECTED_VERSION"
EOF
    chmod +x "$TMPROOT/fake-version"
    cat > "$TMPROOT/fake-version-bad" <<'EOF'
#!/bin/bash
echo "0.0.1"
EOF
    chmod +x "$TMPROOT/fake-version-bad"
    assert_ok    "verify version: matching --version passes" sv_verify_version "$TMPROOT/fake-version" "$EXPECTED_VERSION"
    assert_fails "verify version: mismatched --version fails" sv_verify_version "$TMPROOT/fake-version-bad" "$EXPECTED_VERSION"

    # --- atomic same-directory replacement ---
    instdir="$TMPROOT/instdir"; mkdir -p "$instdir"
    printf 'OLD' > "$instdir/macos"
    printf 'NEW' > "$instdir/.macos.tmp.1"
    assert_ok "atomic install: same-directory rename succeeds" sv_atomic_install "$instdir/.macos.tmp.1" "$instdir/macos"
    assert_eq "atomic install: destination replaced" "$(cat "$instdir/macos" 2>/dev/null)" "NEW"

    otherdir="$TMPROOT/otherdir"; mkdir -p "$otherdir"
    printf 'CROSS' > "$otherdir/staged"
    assert_fails "atomic install: cross-directory source refused" sv_atomic_install "$otherdir/staged" "$instdir/macos"
    assert_eq "atomic install: destination untouched after refusal" "$(cat "$instdir/macos" 2>/dev/null)" "NEW"
    assert_fails "atomic install: missing source refused" sv_atomic_install "$instdir/.macos.tmp.absent" "$instdir/macos"

    ####################################################################
    group "staging paths are unpredictable and never follow a symlink"
    ####################################################################
    # A predictable staging name (e.g. .macos.tmp.$$) lets anyone who can write
    # the install directory pre-create a symlink and redirect the copy — and the
    # subsequent codesign — onto another file.
    stagedir="$TMPROOT/stagedir"; mkdir -p "$stagedir"
    s1="$(sv_stage_temp "$stagedir" ".macos.tmp")"; rc1=$?
    s2="$(sv_stage_temp "$stagedir" ".macos.tmp")"; rc2=$?
    if [ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ] && [ -n "$s1" ] && [ "$s1" != "$s2" ]; then
        ok "sv_stage_temp returns a fresh unpredictable path each call"
    else bad "sv_stage_temp returns a fresh unpredictable path each call" "rc=$rc1/$rc2 s1=$s1 s2=$s2"; fi
    if [ -f "$s1" ] && [ ! -L "$s1" ]; then ok "sv_stage_temp creates a regular, non-symlink file"
    else bad "sv_stage_temp creates a regular, non-symlink file" "$s1"; fi
    assert_eq "sv_stage_temp file is created private (0600)" "$(stat -f '%OLp' "$s1" 2>/dev/null)" "600"
    assert_fails "sv_stage_temp refuses a directory that does not exist" sv_stage_temp "$TMPROOT/no-such-dir" ".macos.tmp"
    rm -f "$s1" "$s2"

    # A symlink planted at the staged path must never be written through.
    victim="$TMPROOT/victim"; printf 'VICTIM' > "$victim"
    ln -s "$victim" "$stagedir/.macos.tmp.planted"
    assert_fails "regular-file check rejects a planted symlink" sv_assert_regular_file "$stagedir/.macos.tmp.planted"
    assert_fails "atomic install refuses a symlinked staged file" sv_atomic_install "$stagedir/.macos.tmp.planted" "$stagedir/macos"
    assert_eq "planted symlink target was not clobbered" "$(cat "$victim")" "VICTIM"

    printf 'NEW' > "$stagedir/.macos.tmp.real"
    ln -s "$victim" "$stagedir/macos-link"
    assert_fails "atomic install refuses a symlinked destination" sv_atomic_install "$stagedir/.macos.tmp.real" "$stagedir/macos-link"
    assert_eq "symlinked destination target was not clobbered" "$(cat "$victim")" "VICTIM"

    ####################################################################
    group "post-swap failure restores the previous executable"
    ####################################################################
    # The install path claims a failure leaves the previous executable in place.
    # After the rename that is only true if the old bytes were kept and put back.
    cat > "$TMPROOT/verify-ok" <<'EOF'
#!/bin/bash
exit 0
EOF
    cat > "$TMPROOT/verify-fail" <<'EOF'
#!/bin/bash
echo "simulated post-swap verification failure" >&2
exit 1
EOF
    chmod +x "$TMPROOT/verify-ok" "$TMPROOT/verify-fail"

    rb="$TMPROOT/rollback"; mkdir -p "$rb"
    printf 'OLD' > "$rb/macos"; chmod 755 "$rb/macos"
    staged="$(sv_stage_temp "$rb" ".macos.tmp")"; printf 'NEW' > "$staged"
    assert_ok "rollback: successful install swaps the new executable in" \
        sv_install_with_rollback "$staged" "$rb/macos" "$TMPROOT/verify-ok"
    assert_eq "rollback: destination holds the new bytes on success" "$(cat "$rb/macos")" "NEW"
    assert_eq "rollback: no backup or staging litter left behind on success" \
        "$(ls -A "$rb" | grep -v '^macos$' | tr '\n' ' ')" ""

    printf 'PREVIOUS' > "$rb/macos"; chmod 755 "$rb/macos"
    staged="$(sv_stage_temp "$rb" ".macos.tmp")"; printf 'BROKEN' > "$staged"
    assert_fails "rollback: post-swap verification failure reports failure" \
        sv_install_with_rollback "$staged" "$rb/macos" "$TMPROOT/verify-fail"
    assert_eq "rollback: previous executable is restored byte-for-byte" "$(cat "$rb/macos")" "PREVIOUS"
    assert_eq "rollback: restored executable keeps its mode" "$(stat -f '%OLp' "$rb/macos")" "755"
    assert_eq "rollback: no backup or staging litter left behind on failure" \
        "$(ls -A "$rb" | grep -v '^macos$' | tr '\n' ' ')" ""

    # First-ever install: there is nothing to roll back to, so a failed
    # verification must not leave a broken executable on PATH.
    fresh="$TMPROOT/rollback-fresh"; mkdir -p "$fresh"
    staged="$(sv_stage_temp "$fresh" ".macos.tmp")"; printf 'BROKEN' > "$staged"
    assert_fails "rollback: failed first install reports failure" \
        sv_install_with_rollback "$staged" "$fresh/macos" "$TMPROOT/verify-fail"
    if [ ! -e "$fresh/macos" ]; then ok "rollback: failed first install leaves no executable behind"
    else bad "rollback: failed first install leaves no executable behind" "$(cat "$fresh/macos")"; fi

    ####################################################################
    group "manifest JSON is produced by a real encoder"
    ####################################################################
    # Hand-rolled sed escaping silently corrupts any value containing a quote,
    # a backslash, a control character or a newline.
    mplist="$TMPROOT/manifest.plist"; mjson="$TMPROOT/manifest.json"
    nasty='ident "quoted" \back\ and <tag> & ampersand
second line	tab'
    if sv_manifest_begin "$mplist" \
        && sv_manifest_set "$mplist" tricky string "$nasty" \
        && sv_manifest_set "$mplist" git_dirty bool true \
        && sv_manifest_set "$mplist" count integer 3 \
        && sv_manifest_write_json "$mplist" "$mjson"; then
        ok "manifest helpers produce a JSON file"
        assert_ok "manifest JSON parses with a real JSON parser" /usr/bin/python3 -m json.tool "$mjson"
        assert_eq "manifest JSON round-trips an awkward string exactly" \
            "$(plutil -extract tricky raw -o - "$mjson" 2>/dev/null)" "$nasty"
        assert_eq "manifest JSON encodes a real boolean" \
            "$(plutil -extract git_dirty raw -o - "$mjson" 2>/dev/null)" "true"
        assert_eq "manifest JSON encodes a real integer" \
            "$(plutil -extract count raw -o - "$mjson" 2>/dev/null)" "3"
    else
        for t in "manifest helpers produce a JSON file" "manifest JSON parses with a real JSON parser" \
                 "manifest JSON round-trips an awkward string exactly" \
                 "manifest JSON encodes a real boolean" "manifest JSON encodes a real integer"; do
            bad "$t" "sv_manifest_* helpers unavailable or failed"
        done
    fi

    ####################################################################
    group "dirty-source provenance is recorded, not merely flagged"
    ####################################################################
    # git_dirty=true alone says nothing about what the source actually was.
    gr="$TMPROOT/gitrepo"; mkdir -p "$gr"
    (
        cd "$gr" || exit 1
        git init -q . >/dev/null 2>&1
        printf 'tracked v1\n' > tracked.txt
        git add tracked.txt >/dev/null 2>&1
        git -c user.email=t@example.invalid -c user.name=Test -c commit.gpgsign=false \
            commit -q -m init >/dev/null 2>&1
    )
    if [ -d "$gr/.git" ]; then
        printf 'tracked v2\n' > "$gr/tracked.txt"
        printf 'untracked A\n' > "$gr/extra.txt"
        d1="$(cd "$gr" && sv_source_state_digests)"; rc=$?
        d2="$(cd "$gr" && sv_source_state_digests)"
        if [ "$rc" -eq 0 ] && [ -n "$d1" ]; then ok "sv_source_state_digests runs in a dirty work tree"
        else bad "sv_source_state_digests runs in a dirty work tree" "rc=$rc out=$d1"; fi
        assert_eq "source digests are deterministic across calls" "$d1" "$d2"
        set -- $d1
        if [[ "${1:-}" =~ ^[0-9a-f]{64}$ ]]; then ok "tracked-diff digest is a sha256"
        else bad "tracked-diff digest is a sha256" "${1:-<empty>}"; fi
        if [[ "${2:-}" =~ ^[0-9a-f]{64}$ ]]; then ok "untracked-source digest is a sha256"
        else bad "untracked-source digest is a sha256" "${2:-<empty>}"; fi
        assert_eq "untracked file count is recorded" "${3:-}" "1"

        printf 'untracked B\n' > "$gr/extra.txt"
        d3="$(cd "$gr" && sv_source_state_digests)"
        if [ "$d3" != "$d1" ]; then ok "changing an untracked file changes the digest"
        else bad "changing an untracked file changes the digest" "$d3"; fi

        printf 'tracked v3\n' > "$gr/tracked.txt"
        d4="$(cd "$gr" && sv_source_state_digests)"
        if [ "$d4" != "$d3" ]; then ok "changing a tracked file changes the tracked-diff digest"
        else bad "changing a tracked file changes the tracked-diff digest" "$d4"; fi

        idx="$(cd "$gr" && sv_untracked_source_index)"
        if [[ "$idx" == *"extra.txt"* ]] && [[ "$idx" =~ ^[0-9a-f]{64} ]]; then
            ok "untracked source index lists digest and path"
        else bad "untracked source index lists digest and path" "$idx"; fi
    else
        for t in "sv_source_state_digests runs in a dirty work tree" "source digests are deterministic across calls" \
                 "tracked-diff digest is a sha256" "untracked-source digest is a sha256" \
                 "untracked file count is recorded" "changing an untracked file changes the digest" \
                 "changing a tracked file changes the tracked-diff digest" \
                 "untracked source index lists digest and path"; do
            bad "$t" "could not create the throwaway git repo"
        done
    fi
else
    for t in "SV_BUNDLE_ID constant" "config resolution" "plist verification" "signature verification" \
             "version verification" "atomic install"; do lib_missing "$t"; done
fi

########################################################################
group "install.sh contract"
########################################################################
if [ -f "$INSTALL_SH" ]; then
    assert_grep "install.sh sources the shared sign/verify library" 'scripts/lib/sign_verify\.sh' "$INSTALL_SH"
    # Signing flags are owned by the shared library, not duplicated here: the
    # contract is that sign_verify.sh applies --options runtime and that
    # install.sh signs through it, so install.sh cannot drift into signing
    # differently from stage-release.sh.
    assert_grep "sign_verify.sh signs with --options runtime" '\-\-options runtime' "$LIB"
    assert_grep "install.sh signs via the shared library" 'sv_sign_binary' "$INSTALL_SH"
    assert_not_grep "install.sh does not hand-roll its own codesign call" '^[^#]*codesign ' "$INSTALL_SH"
    assert_grep "install.sh pins the stable identifier" "$BUNDLE_ID" "$INSTALL_SH"
    assert_grep "install.sh verifies the embedded plist" 'sv_verify_info_plist' "$INSTALL_SH"
    assert_grep "install.sh verifies the designated requirement" 'sv_verify_signature' "$INSTALL_SH"
    assert_grep "install.sh verifies the version" 'sv_verify_version' "$INSTALL_SH"
    assert_grep "rollback helper delegates to same-directory atomic install" 'sv_atomic_install' "$LIB"
    # Staging must be exclusive-create, not a name anyone can predict and
    # pre-empt with a symlink.
    assert_not_grep "install.sh does not stage at a predictable \$\$ path" '\.tmp\.\$\$' "$INSTALL_SH"
    assert_grep "install.sh stages through the shared mktemp helper" 'sv_stage_temp' "$INSTALL_SH"
    assert_grep "install.sh installs through the rollback-capable helper" 'sv_install_with_rollback' "$INSTALL_SH"
    assert_grep "sign_verify.sh checks entitlements inside sv_verify_signature" 'sv_verify_entitlements' "$LIB"
    assert_not_grep "install.sh has no silent ad-hoc fallback" 'codesign[^|]*\|\|[^|]*--sign -' "$INSTALL_SH"
    # Matches `sudo` only where it would actually run a command, not inside the
    # comments and echo lines that promise sudo is never used.
    assert_not_grep "install.sh never sudo-installs" '(^|;|&&|\|\||\bthen\b|\bdo\b)[[:space:]]*sudo[[:space:]]' "$INSTALL_SH"

    # Signing configuration is validated BEFORE the (slow) build, and a misconfigured
    # run must never create or write the install directory.
    idir="$TMPROOT/never-created/bin"
    out="$(cd "$REPO_ROOT" && run_with_timeout 25 env -u MACOS_CLI_SIGN_MODE -u MACOS_CLI_SIGN_IDENTITY \
        -u MACOS_CLI_SIGN_CONFIG MACOS_CLI_INSTALL_DIR="$idir" bash "$INSTALL_SH" 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ]; then ok "install.sh without signing input exits non-zero"
    else bad "install.sh without signing input exits non-zero" "exited 0"; fi
    if [ "$rc" -eq "$TIMED_OUT_RC" ]; then bad "install.sh fails fast (before building)" "timed out — validation happens after the build"; else ok "install.sh fails fast (before building)"; fi
    if [ ! -e "$idir" ]; then ok "install.sh leaves the install dir untouched on config failure"
    else bad "install.sh leaves the install dir untouched on config failure" "created $idir"; fi
    if [[ "$out" == *MACOS_CLI_SIGN_IDENTITY* ]]; then ok "install.sh failure explains how to configure signing"
    else bad "install.sh failure explains how to configure signing" "${out:0:400}"; fi

    out="$(cd "$REPO_ROOT" && run_with_timeout 25 env MACOS_CLI_SIGN_MODE=banana MACOS_CLI_INSTALL_DIR="$idir" \
        bash "$INSTALL_SH" 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ] && [ "$rc" -ne "$TIMED_OUT_RC" ]; then ok "install.sh rejects an unknown sign mode fast"
    else bad "install.sh rejects an unknown sign mode fast" "rc=$rc"; fi
else
    bad "install.sh exists" "missing $INSTALL_SH"
fi

########################################################################
group "Makefile"
########################################################################
MK="$REPO_ROOT/Makefile"
assert_not_grep "Makefile has no Go GOPATH dependency" 'go env GOPATH' "$MK"
assert_not_grep "Makefile does not reference the dead apple-cli product" 'apple-cli' "$MK"
assert_not_grep "Makefile test target does not read live Apple data" '(reminders lists|calendar events|contacts search)' "$MK"
assert_grep "Makefile install delegates to install.sh" 'install\.sh' "$MK"
assert_grep "Makefile test runs the hermetic suite" 'MacCLICoreTestRunner' "$MK"
assert_grep "Makefile runs the installer contract tests" 'installer_contract_test\.sh' "$MK"
if [ -f "$MK" ]; then
    assert_ok "make -n install parses" make -C "$REPO_ROOT" -n install
fi

########################################################################
group "staging script"
########################################################################
if [ -f "$STAGE" ]; then
    assert_grep "staging records the as-built (unsigned) hash" 'as_built_sha256' "$STAGE"
    assert_grep "staging records the signed artifact hash" 'signed_sha256' "$STAGE"
    assert_grep "staging records the git revision" 'git_revision' "$STAGE"
    assert_grep "staging writes into dist/staging" 'dist/staging' "$STAGE"
    assert_grep "staging records the designated requirement" 'designated_requirement' "$STAGE"
    assert_not_grep "staging never installs onto PATH" '\.local/bin' "$STAGE"
    assert_not_grep "staging never dumps certificate hashes" 'find-identity[^|]*$' "$STAGE"
    assert_not_grep "staging never reads keychain secrets" 'security (find-generic-password|find-internet-password|dump-keychain)' "$STAGE"

    # Manifest fields must go through a real encoder, not a heredoc with hand
    # escaping, and dirty builds must record what the source actually was.
    assert_grep "staging builds the manifest with a real JSON encoder" 'sv_manifest_write_json' "$STAGE"
    assert_not_grep "staging does not hand-escape JSON with sed" "sed .s/" "$STAGE"
    assert_not_grep "staging does not heredoc the manifest" 'cat > "\$MANIFEST"' "$STAGE"
    assert_grep "staging records the tracked-diff digest for dirty sources" 'tracked_diff_sha256' "$STAGE"
    assert_grep "staging records the untracked-source digest for dirty sources" 'untracked_sha256' "$STAGE"
    assert_grep "staging states whether the source is reconstructible" 'source_reconstructible' "$STAGE"
    # The header comment must not claim more than the manifest can prove.
    assert_not_grep "staging header does not overclaim source provenance" \
        'everything needed to prove later that a given signed' "$STAGE"

    # Staging shares the installer's exclusive-create staging rule.
    assert_grep "staging stages through the shared mktemp helper" 'sv_stage_temp' "$STAGE"
    assert_not_grep "staging does not cp onto a predictable path" '^cp "\$BUILT_BINARY" "\$STAGED"' "$STAGE"
else
    bad "scripts/stage-release.sh exists" "missing $STAGE"
fi

########################################################################
group "documented claims match what is actually verified"
########################################################################
# Claims about TCC attribution and grant survival can only be settled by
# running the installed binary from a terminal and from launchd. Until those
# gates are exercised, the docs and the installer must say "intended", not
# "does".
if [ -f "$SIGNING_DOC" ]; then
    assert_not_grep "SIGNING.md does not assert unverified Automation attribution" \
        'TCC still attributes' "$SIGNING_DOC"
    assert_not_grep "SIGNING.md does not claim any failure leaves the old binary untouched" \
        'Any failure leaves the previously installed executable untouched' "$SIGNING_DOC"
    assert_grep "SIGNING.md marks Automation attribution as unverified" \
        '(not been verified|unverified|intended|expected)' "$SIGNING_DOC"
    assert_grep "SIGNING.md names the terminal attribution gate" \
        '[Tt]erminal' "$SIGNING_DOC"
    assert_grep "SIGNING.md names the launchd attribution gate" \
        'launchd' "$SIGNING_DOC"
    assert_grep "SIGNING.md documents the post-swap rollback" \
        '(roll(ed)? back|rollback)' "$SIGNING_DOC"
    assert_grep "SIGNING.md documents the Location usage keys" \
        'NSLocationUsageDescription' "$SIGNING_DOC"
    assert_grep "SIGNING.md documents entitlement verification of the artifact" \
        'sv_verify_entitlements' "$SIGNING_DOC"
    assert_grep "SIGNING.md documents the strict signing-config rules" \
        '(duplicate|unknown key|unclosed)' "$SIGNING_DOC"
    assert_not_grep "SIGNING.md never claims the artifact is notarized" \
        '(is notarized|has been notarized|we notarize)' "$SIGNING_DOC"
fi
if [ -f "$INSTALL_SH" ]; then
    assert_not_grep "install.sh does not promise grant survival unconditionally" \
        'stay granted across future reinstalls' "$INSTALL_SH"
    assert_grep "install.sh qualifies grant survival as unverified" \
        '(not been verified|has not been confirmed|expected|intended)' "$INSTALL_SH"
    assert_not_grep "install.sh never claims the artifact is notarized" \
        '(is notarized|has been notarized)' "$INSTALL_SH"
fi

########################################################################
group "end-to-end ad-hoc install into a throwaway directory (opt-in)"
########################################################################
if [ "${MACOS_CLI_TEST_E2E:-0}" = "1" ]; then
    e2e="$TMPROOT/e2e-bin"
    if (cd "$REPO_ROOT" && env MACOS_CLI_SIGN_MODE=adhoc MACOS_CLI_INSTALL_DIR="$e2e" bash "$INSTALL_SH" > "$TMPROOT/e2e.log" 2>&1); then
        ok "e2e: ad-hoc install completes"
        assert_eq "e2e: installed binary reports the expected version" "$("$e2e/macos" --version 2>/dev/null)" "$EXPECTED_VERSION"
        if [ "$LIB_OK" = 1 ]; then
            assert_ok "e2e: installed binary carries the verified plist" sv_verify_info_plist "$e2e/macos" "$EXPECTED_VERSION"
            assert_ok "e2e: installed binary carries a valid adhoc signature" sv_verify_signature "$e2e/macos" adhoc
        fi
        assert_eq "e2e: signature identifier is stable" \
            "$(codesign -dv --verbose=2 "$e2e/macos" 2>&1 | sed -n 's/^Identifier=//p')" "$BUNDLE_ID"
        if codesign -dv --verbose=2 "$e2e/macos" 2>&1 | grep -q 'Info.plist entries='; then
            ok "e2e: Info.plist is sealed into the signature"
        else bad "e2e: Info.plist is sealed into the signature" "codesign reports Info.plist=not bound"; fi
    else
        bad "e2e: ad-hoc install completes" "$(tail -20 "$TMPROOT/e2e.log" 2>/dev/null)"
    fi
else
    printf '  skip set MACOS_CLI_TEST_E2E=1 to run the full ad-hoc build+install\n'
fi

########################################################################
# INTEGRATION-ONLY-BELOW
# Everything past this marker may consult THIS machine's real login keychain,
# so results and check counts would otherwise depend on the machine. It runs
# only with MACOS_CLI_TEST_INTEGRATION=1; the hermetic suite covers the same
# code path above with a mocked `security` on PATH.
########################################################################
group "live keychain (opt-in integration)"
if [ "${MACOS_CLI_TEST_INTEGRATION:-0}" = "1" ] && [ "$LIB_OK" = 1 ]; then
    real_identity="$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')"
    if [ -n "$real_identity" ]; then
        assert_ok "installed Developer ID identity resolves" env MACOS_CLI_SIGN_MODE=developer-id \
            MACOS_CLI_SIGN_IDENTITY="$real_identity" \
            bash -c 'source "$0"; sv_load_sign_config' "$LIB"
    else
        printf '  skip no Developer ID identity installed on this machine\n'
    fi
else
    printf '  skip set MACOS_CLI_TEST_INTEGRATION=1 to check this machine'"'"'s real keychain\n'
fi

########################################################################
printf '\n----------------------------------------\n'
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
    printf 'failed checks:\n'
    for n in "${FAILED_NAMES[@]}"; do printf '  - %s\n' "$n"; done
    exit 1
fi
exit 0
