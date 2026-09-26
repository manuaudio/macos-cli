#!/bin/bash
# Shared code-identity contract for macos-cli: resolve the signing
# configuration, sign, and verify that an artifact really carries the identity
# a durable TCC grant depends on.
#
# Sourced (never executed) by install.sh, scripts/stage-release.sh and
# scripts/tests/installer_contract_test.sh, so all three enforce exactly the
# same rules.
#
# WHY THIS EXISTS
#   macOS records a privacy (TCC) grant against a binary's *code identity*:
#   its bundle identifier plus its code-signing designated requirement. An
#   unsigned or linker-ad-hoc-signed binary has an identity derived from its
#   cdhash, so it changes on every single rebuild and every granted permission
#   is silently lost. A Developer ID signature with a stable identifier keeps
#   the identity constant across rebuilds.
#
# CONTRACT
#   * Two explicit modes, never an implicit slide between them:
#       developer-id  production / documented install path (default)
#       adhoc         contributor + local build, TCC grants do NOT survive rebuilds
#   * Mode and identity come only from the environment or an explicit config
#     file. A missing or uninstalled Developer ID identity is a hard failure.
#   * Nothing here reads Apple private data, prints certificate hashes, or
#     touches the Keychain beyond asking whether a named identity exists.

# Guard against double-sourcing.
[ -n "${SV_LIB_LOADED:-}" ] && return 0
SV_LIB_LOADED=1

SV_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SV_REPO_ROOT="$(cd "$SV_LIB_DIR/../.." && pwd)"

# The stable code identity. Changing this string invalidates every existing TCC
# grant on every user's machine, so it is pinned here and asserted by the tests.
SV_BUNDLE_ID="com.manuaudio.macos-cli"
SV_EXPECTED_VERSION="0.8.1"
# Entitlements requested at signing time: only
# com.apple.security.automation.apple-events, which the Hardened Runtime
# requires for Apple-event automation. See docs/SIGNING.md for the rationale.
#
# KEEP THAT FILE FREE OF XML COMMENTS. codesign does not parse it with plutil;
# it hands it to AMFI's much stricter reader, which rejects a comment block with
# "AMFIUnserializeXML: syntax error" even though `plutil -lint` reports the file
# as valid. The installer contract test signs a throwaway Mach-O with the real
# file to catch exactly that.
SV_ENTITLEMENTS="$SV_REPO_ROOT/Resources/macos-cli.entitlements"
SV_INFO_PLIST_SOURCE="$SV_REPO_ROOT/Resources/macos-cli-Info.plist"

# The one entitlement the production signing path requests. Verified back off
# the signed artifact (see sv_verify_entitlements), not just off the source file.
SV_REQUIRED_ENTITLEMENTS=(
    com.apple.security.automation.apple-events
)

# Every key the embedded Info.plist must carry. The usage descriptions are the
# text macOS shows in the permission prompt; an empty one produces a blank,
# untrustworthy dialog (and on some releases no prompt at all).
#
# This list must cover every TCC API the sources actually call. Location is here
# because Commands/LocationCommand.swift calls
# CLLocationManager.requestWhenInUseAuthorization(): macOS reads
# NSLocationWhenInUseUsageDescription for that call and NSLocationUsageDescription
# as the older/general macOS key, so both are carried.
SV_REQUIRED_PLIST_KEYS=(
    CFBundleIdentifier
    CFBundleName
    CFBundleShortVersionString
    CFBundleVersion
    NSContactsUsageDescription
    NSCalendarsUsageDescription
    NSCalendarsFullAccessUsageDescription
    NSRemindersUsageDescription
    NSRemindersFullAccessUsageDescription
    NSAppleEventsUsageDescription
    NSLocationUsageDescription
    NSLocationWhenInUseUsageDescription
)

sv_log() { printf '%s\n' "$*"; }
sv_err() { printf '%s\n' "$*" >&2; }

sv_sha256() {   # sv_sha256 FILE -> bare hex digest
    [ -f "$1" ] || return 1
    /usr/bin/shasum -a 256 "$1" | awk '{print $1}'
}

# ---------------------------------------------------------------------------
# Signing configuration
# ---------------------------------------------------------------------------

# The only assignments a signing config file may contain.
SV_CONFIG_KEYS=(
    MACOS_CLI_SIGN_MODE
    MACOS_CLI_SIGN_IDENTITY
    MACOS_CLI_SIGN_TIMESTAMP
)

# Parse MACOS_CLI_SIGN_* assignments out of a config file WITHOUT sourcing it —
# the file is parsed, not executed, so a stray line cannot run code.
#
# The parse is strict on purpose. A signing config decides whether the artifact
# gets a durable code identity, so anything the documented contract does not
# allow is an error naming the file and line, never a value quietly reinterpreted:
#
#   * only the keys in SV_CONFIG_KEYS, each assigned at most once
#   * a value that opens a quote must close it with the same quote
#   * blank lines and #-comments are ignored; anything else is rejected
#
# On success sets _SV_CFG_<KEY-SUFFIX> for each key that was present.
_sv_parse_config() {   # _sv_parse_config FILE
    local file="$1" line raw key value lineno=0 known rc=0

    _SV_CFG_MODE=""; _SV_CFG_IDENTITY=""; _SV_CFG_TIMESTAMP=""; _SV_CFG_TIMESTAMP_SET=0
    local seen_mode=0 seen_identity=0 seen_timestamp=0

    while IFS= read -r raw || [ -n "$raw" ]; do
        lineno=$((lineno + 1))
        line="${raw%$'\r'}"
        # Trim surrounding whitespace.
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [ -z "$line" ] && continue
        case "$line" in \#*) continue ;; esac

        if [[ "$line" != *=* ]]; then
            sv_err "❌  $file:$lineno is not a KEY=VALUE assignment: $line"
            rc=1
            continue
        fi
        key="${line%%=*}"
        value="${line#*=}"

        known=0
        local k
        for k in "${SV_CONFIG_KEYS[@]}"; do [ "$key" = "$k" ] && known=1; done
        if [ "$known" != 1 ]; then
            sv_err "❌  $file:$lineno assigns an unknown key: $key"
            sv_err "    Allowed keys: ${SV_CONFIG_KEYS[*]}"
            rc=1
            continue
        fi

        # Exactly one layer of *matching* quotes. A value that opens a quote and
        # never closes it is a typo, not a value with its last character removed.
        if [[ "$value" == \"* || "$value" == \'* ]]; then
            local q="${value:0:1}"
            if [ "${#value}" -lt 2 ] || [ "${value: -1}" != "$q" ]; then
                sv_err "❌  $file:$lineno has an unterminated $q quote in the value of $key"
                rc=1
                continue
            fi
            value="${value:1:${#value}-2}"
        fi

        case "$key" in
            MACOS_CLI_SIGN_MODE)
                [ "$seen_mode" = 1 ] && { sv_err "❌  $file:$lineno assigns $key more than once"; rc=1; continue; }
                seen_mode=1; _SV_CFG_MODE="$value" ;;
            MACOS_CLI_SIGN_IDENTITY)
                [ "$seen_identity" = 1 ] && { sv_err "❌  $file:$lineno assigns $key more than once"; rc=1; continue; }
                seen_identity=1; _SV_CFG_IDENTITY="$value" ;;
            MACOS_CLI_SIGN_TIMESTAMP)
                [ "$seen_timestamp" = 1 ] && { sv_err "❌  $file:$lineno assigns $key more than once"; rc=1; continue; }
                seen_timestamp=1; _SV_CFG_TIMESTAMP="$value"; _SV_CFG_TIMESTAMP_SET=1 ;;
        esac
    done < "$file"

    return "$rc"
}

# Resolve SV_SIGN_MODE / SV_SIGN_IDENTITY / SV_SIGN_TIMESTAMP.
# Returns non-zero — loudly — rather than ever downgrading production signing.
sv_load_sign_config() {
    local cfg cfg_explicit=0
    if [ -n "${MACOS_CLI_SIGN_CONFIG:-}" ]; then
        cfg="$MACOS_CLI_SIGN_CONFIG"
        cfg_explicit=1
    else
        cfg="${XDG_CONFIG_HOME:-$HOME/.config}/macos-cli/signing.env"
    fi

    local cfg_mode="" cfg_identity="" cfg_timestamp="" cfg_timestamp_set=0
    if [ -f "$cfg" ]; then
        if ! _sv_parse_config "$cfg"; then
            sv_err "    Refusing to sign from a config file that does not match the documented"
            sv_err "    contract. See docs/SIGNING.md."
            return 1
        fi
        cfg_mode="$_SV_CFG_MODE"
        cfg_identity="$_SV_CFG_IDENTITY"
        cfg_timestamp="$_SV_CFG_TIMESTAMP"
        cfg_timestamp_set="$_SV_CFG_TIMESTAMP_SET"
    elif [ "$cfg_explicit" = 1 ]; then
        # An explicitly named config that does not exist is a mistake, not a
        # reason to quietly proceed with different settings.
        sv_err "❌  MACOS_CLI_SIGN_CONFIG points at a file that does not exist:"
        sv_err "      $cfg"
        return 1
    fi

    # Environment wins over the config file; the default is production signing.
    SV_SIGN_MODE="${MACOS_CLI_SIGN_MODE:-${cfg_mode:-developer-id}}"
    SV_SIGN_IDENTITY="${MACOS_CLI_SIGN_IDENTITY:-${cfg_identity:-}}"
    SV_SIGN_CONFIG_PATH="$cfg"

    # The timestamp switch is documented as exactly 0 or 1, so it is read with
    # unset-only defaulting: an explicitly empty value is a mistake, not a
    # request for the default. Anything else ('yes', 'true', '01', '2') would
    # previously have been read as "enabled" and silently diverge from the docs.
    local ts_source=""
    if [ -n "${MACOS_CLI_SIGN_TIMESTAMP+set}" ]; then
        SV_SIGN_TIMESTAMP="$MACOS_CLI_SIGN_TIMESTAMP"
        ts_source="the environment variable MACOS_CLI_SIGN_TIMESTAMP"
    elif [ "$cfg_timestamp_set" = 1 ]; then
        SV_SIGN_TIMESTAMP="$cfg_timestamp"
        ts_source="MACOS_CLI_SIGN_TIMESTAMP in $cfg"
    else
        SV_SIGN_TIMESTAMP=1
    fi
    case "$SV_SIGN_TIMESTAMP" in
        0|1) ;;
        *)
            sv_err "❌  Invalid MACOS_CLI_SIGN_TIMESTAMP: '$SV_SIGN_TIMESTAMP' (from $ts_source)"
            sv_err "    It must be exactly 1 (secure timestamp, required to notarize) or 0 (none)."
            return 1
            ;;
    esac

    case "$SV_SIGN_MODE" in
        developer-id|adhoc) ;;
        *)
            sv_err "❌  Unknown signing mode: '$SV_SIGN_MODE'"
            sv_err "    MACOS_CLI_SIGN_MODE must be 'developer-id' or 'adhoc'."
            return 1
            ;;
    esac

    if [ "$SV_SIGN_MODE" = "adhoc" ]; then
        # The ad-hoc identity is the literal '-' that codesign understands.
        SV_SIGN_IDENTITY="-"
        SV_SIGN_TIMESTAMP=0
        return 0
    fi

    if [ -z "$SV_SIGN_IDENTITY" ]; then
        sv_err "❌  Production signing is required but no Developer ID identity was supplied."
        sv_err ""
        sv_err "    macOS ties every privacy (TCC) permission to the binary's code identity."
        sv_err "    An unsigned build gets a new identity on every rebuild, so every permission"
        sv_err "    you granted is silently lost. This installer will not produce such a binary"
        sv_err "    unless you ask for it in writing."
        sv_err ""
        sv_err "    Choose one, explicitly:"
        sv_err ""
        sv_err "      # Production install — durable permissions across rebuilds:"
        sv_err "      export MACOS_CLI_SIGN_IDENTITY=\"Developer ID Application: Your Name (TEAMID)\""
        sv_err "      ./install.sh"
        sv_err ""
        sv_err "      # Contributor / local build — permissions must be re-granted after each rebuild:"
        sv_err "      MACOS_CLI_SIGN_MODE=adhoc ./install.sh"
        sv_err ""
        sv_err "    Or put MACOS_CLI_SIGN_MODE / MACOS_CLI_SIGN_IDENTITY in $cfg"
        sv_err "    See docs/SIGNING.md."
        return 1
    fi

    # Confirm the identity is actually installed. Only the identity's public
    # label is ever matched or echoed — no certificate hashes are read or shown.
    if ! security find-identity -v -p codesigning 2>/dev/null | grep -Fq "\"$SV_SIGN_IDENTITY\""; then
        sv_err "❌  Developer ID identity not found in the keychain:"
        sv_err "      $SV_SIGN_IDENTITY"
        sv_err ""
        sv_err "    Installed code-signing identities (labels only):"
        security find-identity -v -p codesigning 2>/dev/null \
            | grep -o '"[^"]*"' | sed 's/^/      /' >&2 || true
        sv_err ""
        sv_err "    Fix MACOS_CLI_SIGN_IDENTITY, or build a contributor binary with"
        sv_err "    MACOS_CLI_SIGN_MODE=adhoc (permissions will not survive rebuilds)."
        return 1
    fi

    return 0
}

# ---------------------------------------------------------------------------
# Info.plist verification
# ---------------------------------------------------------------------------

# Pull the embedded Info.plist out of a Mach-O's __TEXT,__info_plist section.
sv_extract_info_plist() {   # sv_extract_info_plist BIN OUT_PLIST
    local bin="$1" out="$2"
    [ -f "$bin" ] || { sv_err "no such binary: $bin"; return 1; }
    # otool -P prints two header lines (path, section name) before the payload.
    otool -P "$bin" 2>/dev/null \
        | awk 'found { print } /^\(__TEXT,__info_plist\) section$/ { found = 1 }' > "$out"
    if [ ! -s "$out" ]; then
        sv_err "no embedded Info.plist (__TEXT,__info_plist section) in: $bin"
        return 1
    fi
    if ! plutil -lint "$out" >/dev/null 2>&1; then
        sv_err "embedded Info.plist is not a valid property list: $bin"
        return 1
    fi
    return 0
}

# Verify the embedded plist carries the pinned identity, the expected version,
# and a non-empty usage description for every TCC surface the CLI touches.
sv_verify_info_plist() {   # sv_verify_info_plist BIN [EXPECTED_VERSION]
    local bin="$1" expected_version="${2:-$SV_EXPECTED_VERSION}"
    local tmp rc=0
    tmp="$(mktemp "${TMPDIR:-/tmp}/sv-plist.XXXXXX")" || return 1

    if ! sv_extract_info_plist "$bin" "$tmp"; then
        rm -f "$tmp"
        return 1
    fi

    local got
    got="$(plutil -extract CFBundleIdentifier raw -o - "$tmp" 2>/dev/null)"
    if [ "$got" != "$SV_BUNDLE_ID" ]; then
        sv_err "embedded CFBundleIdentifier is '$got', expected '$SV_BUNDLE_ID'"
        rc=1
    fi

    local key
    for key in CFBundleShortVersionString CFBundleVersion; do
        got="$(plutil -extract "$key" raw -o - "$tmp" 2>/dev/null)"
        if [ "$got" != "$expected_version" ]; then
            sv_err "embedded $key is '$got', expected '$expected_version'"
            rc=1
        fi
    done

    for key in "${SV_REQUIRED_PLIST_KEYS[@]}"; do
        got="$(plutil -extract "$key" raw -o - "$tmp" 2>/dev/null)"
        if [ -z "$got" ]; then
            sv_err "embedded Info.plist is missing a value for $key"
            rc=1
        fi
    done

    rm -f "$tmp"
    return "$rc"
}

# ---------------------------------------------------------------------------
# Signing
# ---------------------------------------------------------------------------

sv_sign_binary() {   # sv_sign_binary BIN MODE IDENTITY
    local bin="$1" mode="$2" identity="$3"
    [ -f "$bin" ] || { sv_err "no such binary to sign: $bin"; return 1; }
    [ -f "$SV_ENTITLEMENTS" ] || { sv_err "missing entitlements file: $SV_ENTITLEMENTS"; return 1; }

    local -a args=(
        --force
        --identifier "$SV_BUNDLE_ID"
        --options runtime
        --entitlements "$SV_ENTITLEMENTS"
    )

    case "$mode" in
        developer-id)
            [ -n "$identity" ] && [ "$identity" != "-" ] || {
                sv_err "developer-id signing requires a real identity"; return 1; }
            # A secure timestamp is mandatory for notarization; it needs network
            # access, and a failure here is a hard failure by design.
            if [ "${SV_SIGN_TIMESTAMP:-1}" != "0" ]; then
                args+=(--timestamp)
            else
                args+=(--timestamp=none)
            fi
            args+=(--sign "$identity")
            ;;
        adhoc)
            args+=(--timestamp=none --sign -)
            ;;
        *)
            sv_err "unknown signing mode: $mode"
            return 1
            ;;
    esac

    codesign "${args[@]}" "$bin"
}

# ---------------------------------------------------------------------------
# Entitlement verification
# ---------------------------------------------------------------------------

# plutil reads '.' as a key-path separator, so a reverse-DNS entitlement key has
# to be escaped or it resolves to a nonexistent nested path.
_sv_plutil_keypath() { printf '%s' "$1" | sed 's/\./\\./g'; }

sv_entitlement_keys() {   # sv_entitlement_keys BIN -> one entitlement key per line
    codesign -d --entitlements - --xml "$1" 2>/dev/null \
        | plutil -p - 2>/dev/null \
        | sed -n 's/^[[:space:]]*"\([^"]*\)" =>.*/\1/p'
}

# Read the entitlements back off the artifact that is actually about to ship.
# Checking the source file only proves what we *asked* for; a wrong
# --entitlements path, a dropped flag or a re-signing step would leave every
# other check passing while the shipped binary silently lost its Apple-event
# permission (or gained one nobody reviewed).
sv_verify_entitlements() {   # sv_verify_entitlements BIN
    local bin="$1" xml key got rc=0 e expected
    [ -f "$bin" ] || { sv_err "no such binary: $bin"; return 1; }

    xml="$(codesign -d --entitlements - --xml "$bin" 2>/dev/null)"
    if [ -z "$xml" ]; then
        sv_err "the signature of $bin carries no entitlements at all;"
        sv_err "expected: ${SV_REQUIRED_ENTITLEMENTS[*]}"
        return 1
    fi

    for key in "${SV_REQUIRED_ENTITLEMENTS[@]}"; do
        got="$(printf '%s' "$xml" | plutil -extract "$(_sv_plutil_keypath "$key")" raw -o - - 2>/dev/null)"
        if [ "$got" != "true" ]; then
            sv_err "signed artifact does not carry the entitlement $key (value: '${got:-absent}')"
            rc=1
        fi
    done

    # Nothing beyond the reviewed set may ride along: an extra entitlement
    # widens what the binary is allowed to do without widening the review.
    while IFS= read -r key; do
        [ -n "$key" ] || continue
        expected=0
        for e in "${SV_REQUIRED_ENTITLEMENTS[@]}"; do [ "$e" = "$key" ] && expected=1; done
        if [ "$expected" != 1 ]; then
            sv_err "signed artifact carries an unexpected entitlement: $key"
            rc=1
        fi
    done <<EOF
$(printf '%s' "$xml" | plutil -p - 2>/dev/null | sed -n 's/^[[:space:]]*"\([^"]*\)" =>.*/\1/p')
EOF

    return "$rc"
}

# ---------------------------------------------------------------------------
# Signature verification
# ---------------------------------------------------------------------------

# Verify the signature is valid, seals the Info.plist, carries the pinned
# identifier, and — in production mode — has a designated requirement anchored
# to Apple and pinned to the signing team. That designated requirement is
# literally what TCC matches a stored grant against.
sv_verify_signature() {   # sv_verify_signature BIN MODE
    local bin="$1" mode="$2" rc=0 info dr identifier team

    [ -f "$bin" ] || { sv_err "no such binary: $bin"; return 1; }

    if ! codesign --verify --strict --verbose=2 "$bin" >/dev/null 2>&1; then
        sv_err "codesign --verify --strict failed for: $bin"
        codesign --verify --strict --verbose=2 "$bin" 2>&1 | sed 's/^/      /' >&2 || true
        return 1
    fi

    info="$(codesign -dv --verbose=2 "$bin" 2>&1)"
    identifier="$(printf '%s\n' "$info" | sed -n 's/^Identifier=//p' | head -1)"
    team="$(printf '%s\n' "$info" | sed -n 's/^TeamIdentifier=//p' | head -1)"

    if [ "$identifier" != "$SV_BUNDLE_ID" ]; then
        sv_err "signature identifier is '$identifier', expected '$SV_BUNDLE_ID'"
        rc=1
    fi

    # "Info.plist=not bound" means the embedded plist is NOT covered by the
    # signature — TCC would not treat it as part of the code identity.
    if ! printf '%s\n' "$info" | grep -q '^Info.plist entries='; then
        sv_err "the embedded Info.plist is not sealed into the signature (Info.plist=not bound)"
        rc=1
    fi

    # The entitlements the shipped bytes actually carry — not the ones the source
    # file asks for.
    if ! sv_verify_entitlements "$bin"; then
        rc=1
    fi

    dr="$(sv_designated_requirement "$bin")"
    if [ -z "$dr" ]; then
        sv_err "could not read the designated requirement of: $bin"
        return 1
    fi

    case "$mode" in
        developer-id)
            # A certificate-backed designated requirement pins the identifier;
            # an ad-hoc one cannot (it has only a cdhash), which is exactly why
            # ad-hoc grants do not survive a rebuild.
            if [[ "$dr" != *"identifier \"$SV_BUNDLE_ID\""* ]]; then
                sv_err "designated requirement does not pin the identifier: $dr"
                rc=1
            fi
            if [ -z "$team" ] || [ "$team" = "not set" ]; then
                sv_err "signature carries no TeamIdentifier — this is not a Developer ID signature"
                return 1
            fi
            if ! printf '%s\n' "$info" | grep -q '^Authority=Developer ID Application:'; then
                sv_err "signature is not from a Developer ID Application certificate"
                rc=1
            fi
            if [[ "$dr" != *"anchor apple generic"* ]]; then
                sv_err "designated requirement is not anchored to Apple: $dr"
                rc=1
            fi
            if [[ "$dr" != *"certificate leaf[subject.OU] = \"$team\""* ]]; then
                sv_err "designated requirement does not pin the signing team ($team): $dr"
                rc=1
            fi
            # Hardened Runtime is required for notarization.
            if ! printf '%s\n' "$info" | grep -q 'flags=.*runtime'; then
                sv_err "signature does not have the Hardened Runtime flag (--options runtime)"
                rc=1
            fi
            # Independent re-check against the requirement TCC would evaluate.
            if ! codesign --verify -R="anchor apple generic and identifier \"$SV_BUNDLE_ID\" and certificate leaf[subject.OU] = \"$team\"" "$bin" >/dev/null 2>&1; then
                sv_err "binary does not satisfy the pinned production requirement"
                rc=1
            fi
            ;;
        adhoc)
            if ! printf '%s\n' "$info" | grep -q '^Signature=adhoc'; then
                sv_err "expected an ad-hoc signature, got: $(printf '%s\n' "$info" | sed -n 's/^Signature=//p')"
                rc=1
            fi
            if [[ "$dr" != *cdhash* ]]; then
                sv_err "ad-hoc designated requirement does not pin a cdhash: $dr"
                rc=1
            fi
            ;;
        *)
            sv_err "unknown signing mode: $mode"
            return 1
            ;;
    esac

    return "$rc"
}

# codesign prefixes the implicit (unstated) requirement of an ad-hoc signature
# with "# ", so both forms are normalised here.
sv_designated_requirement() {   # sv_designated_requirement BIN
    codesign -d -r- "$1" 2>/dev/null | sed -n 's/^[#[:space:]]*designated => //p'
}

sv_team_identifier() {   # sv_team_identifier BIN
    codesign -dv --verbose=2 "$1" 2>&1 | sed -n 's/^TeamIdentifier=//p' | head -1
}

sv_cdhash() {   # sv_cdhash BIN
    codesign -dvvv "$1" 2>&1 | sed -n 's/^CDHash=//p' | head -1
}

# ---------------------------------------------------------------------------
# Version + atomic install
# ---------------------------------------------------------------------------

sv_verify_version() {   # sv_verify_version BIN EXPECTED_VERSION
    local bin="$1" expected="${2:-$SV_EXPECTED_VERSION}" got
    [ -x "$bin" ] || { sv_err "not executable: $bin"; return 1; }
    if ! got="$("$bin" --version 2>/dev/null)"; then
        sv_err "could not run '$bin --version' (a bad signature can block execution)"
        return 1
    fi
    got="$(printf '%s' "$got" | tr -d '[:space:]')"
    if [ "$got" != "$expected" ]; then
        sv_err "installed binary reports version '$got', expected '$expected'"
        return 1
    fi
    return 0
}

# A path we are about to write to, sign, or rename must be a real file we
# created — never a symlink someone else planted pointing at something they want
# overwritten with our (executable, signed) bytes.
sv_assert_regular_file() {   # sv_assert_regular_file PATH
    local p="$1"
    if [ -L "$p" ]; then
        sv_err "refusing to use a symlink: $p"
        return 1
    fi
    if [ ! -f "$p" ]; then
        sv_err "not a regular file: $p"
        return 1
    fi
    return 0
}

# Create an exclusively-owned staging file inside DIR and print its path.
#
# mktemp(1) creates with O_EXCL and mode 0600, so — unlike a predictable
# "$dir/.macos.tmp.$$" that a `cp` would happily follow — a pre-existing symlink
# at the chosen name cannot redirect the copy (and the codesign that follows it)
# onto another user-writable file.
sv_stage_temp() {   # sv_stage_temp DIR PREFIX -> prints the staged path
    local dir="$1" prefix="${2:-.macos-cli-stage}" path
    if [ ! -d "$dir" ]; then
        sv_err "staging directory does not exist: $dir"
        return 1
    fi
    path="$(mktemp "$dir/$prefix.XXXXXXXX" 2>/dev/null)" || {
        sv_err "could not create a staging file in: $dir"
        return 1
    }
    if ! sv_assert_regular_file "$path"; then
        rm -f "$path" 2>/dev/null
        return 1
    fi
    printf '%s' "$path"
}

# Replace DEST with SRC by rename(2) within one directory.
#
# rename(2) inside a single directory is atomic: a concurrent `macos` invocation
# sees either the whole old executable or the whole new one, never a partially
# written or partially signed file. A cross-directory move is NOT guaranteed to
# be a rename (it degrades to copy+unlink across filesystems), so it is refused
# rather than silently accepted.
sv_atomic_install() {   # sv_atomic_install STAGED_SRC DEST
    local src="$1" dest="$2" src_dir dest_dir src_dev dest_dev

    if [ ! -e "$src" ] && [ ! -L "$src" ]; then
        sv_err "staged artifact does not exist: $src"
        return 1
    fi
    sv_assert_regular_file "$src" || return 1
    # An existing destination that is a symlink (or a directory, or a socket) is
    # not something this installer put there; replacing it would either follow
    # the link on some paths or hide a redirect on others.
    if [ -e "$dest" ] || [ -L "$dest" ]; then
        sv_assert_regular_file "$dest" || return 1
    fi
    src_dir="$(cd "$(dirname "$src")" && pwd -P)" || return 1
    dest_dir="$(cd "$(dirname "$dest")" && pwd -P)" || {
        sv_err "destination directory does not exist: $(dirname "$dest")"; return 1; }

    if [ "$src_dir" != "$dest_dir" ]; then
        sv_err "refusing a non-atomic install: staged file lives in '$src_dir'"
        sv_err "but the destination is in '$dest_dir'; they must be the same directory."
        return 1
    fi

    src_dev="$(stat -f '%d' "$src_dir")"
    dest_dev="$(stat -f '%d' "$dest_dir")"
    if [ "$src_dev" != "$dest_dev" ]; then
        sv_err "refusing a non-atomic install: '$src_dir' and '$dest_dir' are on different filesystems"
        return 1
    fi

    chmod 755 "$src" || return 1
    mv -f "$src" "$dest" || return 1
    return 0
}

# Swap SRC into DEST, run POST_VERIFY, and put the previous executable back if
# that verification fails.
#
# A same-directory rename is atomic but it is also destructive: once it lands,
# "nothing was installed" is no longer true and a post-swap check that fails has
# already replaced a working binary. So the old bytes are copied aside first —
# into the same directory, via the same exclusive-create staging rule, so the
# restore is itself an atomic rename — and moved back on failure. A first-ever
# install has nothing to restore, so a failed verification removes the new file
# rather than leaving a broken executable on PATH.
sv_install_with_rollback() {   # sv_install_with_rollback SRC DEST [POST_VERIFY_CMD...]
    local src="$1" dest="$2"; shift 2
    local dest_dir backup="" mode=""

    sv_assert_regular_file "$src" || return 1
    dest_dir="$(dirname "$dest")"

    if [ -e "$dest" ] || [ -L "$dest" ]; then
        sv_assert_regular_file "$dest" || return 1
        backup="$(sv_stage_temp "$dest_dir" ".$(basename "$dest").backup")" || return 1
        mode="$(stat -f '%OLp' "$dest" 2>/dev/null)"
        if ! cat "$dest" > "$backup"; then
            sv_err "could not back up the existing executable: $dest"
            rm -f "$backup" 2>/dev/null
            return 1
        fi
        [ -n "$mode" ] && chmod "$mode" "$backup" 2>/dev/null
    fi

    if ! sv_atomic_install "$src" "$dest"; then
        [ -n "$backup" ] && rm -f "$backup" 2>/dev/null
        return 1
    fi

    if [ $# -gt 0 ] && ! "$@"; then
        sv_err "post-install verification failed for: $dest"
        if [ -n "$backup" ]; then
            if mv -f "$backup" "$dest"; then
                sv_err "rolled back: the previously installed executable is back in place at $dest"
            else
                sv_err "❗️  ROLLBACK FAILED. The previous executable is still readable at:"
                sv_err "      $backup"
                sv_err "    Move it back to $dest yourself."
            fi
        else
            rm -f "$dest" 2>/dev/null
            sv_err "removed the newly installed executable (there was no previous one to restore)"
        fi
        return 1
    fi

    [ -n "$backup" ] && rm -f "$backup" 2>/dev/null
    return 0
}

# ---------------------------------------------------------------------------
# Manifest encoding
# ---------------------------------------------------------------------------
#
# Manifest values include a designated requirement full of quotes and
# backslashes and a certificate label chosen by someone else. Interpolating
# those into a JSON heredoc — with or without hand-written sed escaping — is how
# a provenance record ends up unparseable or, worse, quietly wrong. So the
# manifest is built as a property list with plutil and converted by plutil's own
# JSON writer, which does the escaping.

sv_manifest_begin() {   # sv_manifest_begin PLIST
    local f="$1"
    rm -f "$f" 2>/dev/null
    plutil -create xml1 "$f" >/dev/null 2>&1 || {
        sv_err "could not create the manifest scratch plist: $f"; return 1; }
}

sv_manifest_set() {   # sv_manifest_set PLIST KEY string|bool|integer VALUE
    local f="$1" key="$2" type="$3" value="$4"
    case "$type" in
        string|bool|integer) ;;
        *) sv_err "unsupported manifest value type: $type"; return 1 ;;
    esac
    plutil -replace "$(_sv_plutil_keypath "$key")" "-$type" "$value" "$f" >/dev/null 2>&1 || {
        sv_err "could not set manifest key $key"; return 1; }
}

sv_manifest_write_json() {   # sv_manifest_write_json PLIST OUT_JSON
    plutil -convert json -r -o "$2" "$1" >/dev/null 2>&1 || {
        sv_err "could not encode the manifest as JSON: $2"; return 1; }
}

# ---------------------------------------------------------------------------
# Source-state provenance
# ---------------------------------------------------------------------------
#
# "git_dirty=true" records that the source was not the committed revision — and
# nothing about what it actually was. These two helpers turn a dirty tree into
# something checkable: a digest of the tracked diff and a digest over the sorted
# (digest, path) index of every untracked, non-ignored file. Same working tree,
# same digests; any edit to either half changes them.

sv_untracked_source_index() {   # prints "SHA256  PATH" per untracked file, sorted
    local f
    git ls-files --others --exclude-standard 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
        [ -f "$f" ] || continue
        printf '%s  %s\n' "$(/usr/bin/shasum -a 256 "$f" | awk '{print $1}')" "$f"
    done
}

sv_source_state_digests() {   # prints "TRACKED_DIFF_SHA256 UNTRACKED_SHA256 UNTRACKED_COUNT"
    local diff_sha index untracked_sha count
    diff_sha="$(git diff HEAD 2>/dev/null | /usr/bin/shasum -a 256 | awk '{print $1}')" || return 1
    index="$(sv_untracked_source_index)"
    untracked_sha="$(printf '%s' "$index" | /usr/bin/shasum -a 256 | awk '{print $1}')"
    if [ -z "$index" ]; then count=0; else count="$(printf '%s\n' "$index" | wc -l | tr -d ' ')"; fi
    printf '%s %s %s\n' "$diff_sha" "$untracked_sha" "$count"
}
