#!/bin/bash
# macOS CLI installer
#
# Installs exactly ONE artifact: the `macos` command.
#
#   curl -fsSL https://raw.githubusercontent.com/manuaudio/macos-cli/main/install.sh | bash
#
# By default it downloads this version's Release: a binary signed with the
# project's Developer ID and notarized by Apple. It checks the zip's sha256, the
# signature (codesign --verify --strict), the Developer ID authority, the
# identifier and team, and the version, then installs. No Xcode, no Swift.
#
# Build from source instead (permissions must be re-granted after each rebuild):
#   MACOS_CLI_SIGN_MODE=adhoc ./install.sh
# or with your own certificate:
#   MACOS_CLI_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./install.sh
#
# macOS ties every privacy (TCC) permission to the binary's code identity, so an
# ad-hoc build loses every granted permission on each rebuild. See docs/SIGNING.md.
#
# Install location (default): $HOME/.local/bin/macos
#   Override with:  MACOS_CLI_INSTALL_DIR=/somewhere/on/your/PATH ./install.sh
#
# Source-build inputs (environment, or ~/.config/macos-cli/signing.env); setting
# any of them, or having that file, chooses the source build:
#   MACOS_CLI_SIGN_MODE        developer-id | adhoc
#   MACOS_CLI_SIGN_IDENTITY    Developer ID Application identity label
#   MACOS_CLI_SIGN_TIMESTAMP   1 (default) | 0   — secure timestamp, needed to notarize
#   MACOS_CLI_SIGN_CONFIG      alternate path to the config file
#
# This installer NEVER uses sudo, NEVER installs a second executable (no MCP
# server, no HTTP bridge), and NEVER loads a LaunchAgent or background service.
# It also does NOT grant TCC permissions for you — it prints guidance so you can
# grant them yourself, deliberately.

set -euo pipefail

REPO_URL="https://github.com/manuaudio/macos-cli.git"
INSTALL_DIR="${MACOS_CLI_INSTALL_DIR:-$HOME/.local/bin}"
BINARY_NAME="macos"
# The SwiftPM product name (the built executable file) — installed AS `macos`.
PRODUCT_NAME="macos-cli"
CLONE_DIR="/tmp/macos-cli-install"
# The Release this installer fetches; CLITests and the contract test hold it to Version.swift.
VERSION="0.9.0"
RELEASE_BASE="${MACOS_CLI_RELEASE_BASE:-https://github.com/manuaudio/macos-cli/releases/download}"
BUNDLE_ID="com.manuaudio.macos-cli"
TEAM_ID="4M72M3J3UN"
ZIP_NAME="macos-cli-$VERSION-arm64.zip"

echo ""
echo "macOS CLI installer"
echo "==================="
echo ""

# ── After either path: PATH hint and permissions guidance ────────────────────
after_install() {   # after_install DEST MODE
    local dest="$1" mode="$2"
    case ":$PATH:" in
        *":$INSTALL_DIR:"*) : ;;  # already on PATH
        *)
            echo "⚠️   $INSTALL_DIR is not on your PATH."
            echo "    Add this to your shell profile (~/.zshrc or ~/.bash_profile):"
            echo "      export PATH=\"$INSTALL_DIR:\$PATH\""
            echo ""
            ;;
    esac
    echo "Next: grant the macOS privacy permissions you want this tool to use."
    echo ""
    echo "  • Calendar, Contacts and Reminders ask the first time a command touches"
    echo "    them, or pre-authorize: $BINARY_NAME authorize calendar"
    echo "  • Full Disk Access has NO Info.plist key and is never requested by a"
    echo "    prompt: add $dest yourself under"
    echo "    System Settings ▸ Privacy & Security ▸ Full Disk Access if you want the"
    echo "    commands that read protected databases (Notes, Messages, Safari) to work."
    echo ""
    echo "  Check what's granted at any time (this never prompts):"
    echo "      $BINARY_NAME doctor"
    echo ""
    if [ "$mode" = "adhoc" ]; then
        echo "⚠️   Ad-hoc build: the permissions you grant will be dropped by macOS the next"
        echo "    time you rebuild. Install the Release (no MACOS_CLI_SIGN_* set) for durable grants."
    else
        echo "This binary has a stable Developer ID code identity at a fixed path, which is"
        echo "what macOS matches a stored grant against, so grants are expected to survive"
        echo "'$BINARY_NAME update' and a reinstall. Confirm with '$BINARY_NAME doctor' after one."
    fi
    echo "This installer intentionally does not grant any permission for you."
    echo "🎉  Done — one binary, no background services."
}

# ── The Release: download, verify, install ───────────────────────────────────
# Returns 2 when this version has no Release asset, 1 on any other failure.
# Nothing is written to the install directory until every check has passed.
install_release() (   # a subshell: its cleanup trap and `set -e` stay its own
    local work url code expected actual details reported staged
    work="$(mktemp -d "${TMPDIR:-/tmp}/macos-cli-release.XXXXXX")" || return 1
    trap 'rm -rf "$work"' EXIT
    url="$RELEASE_BASE/v$VERSION/$ZIP_NAME"
    echo "📦  Downloading macos $VERSION..."
    code="$(curl -sSL -w '%{http_code}' -o "$work/$ZIP_NAME" "$url" 2>"$work/curl.err")" || code="${code:-000}"
    case "$code" in
        200) ;;
        404) return 2 ;;
        *) echo "❌  Could not download $url (HTTP $code): $(cat "$work/curl.err")"; return 1 ;;
    esac
    if ! curl -fsSL -o "$work/$ZIP_NAME.sha256" "$url.sha256"; then
        echo "❌  Could not download $url.sha256."; return 1
    fi
    expected="$(awk 'NR==1{print tolower($1)}' "$work/$ZIP_NAME.sha256")"
    actual="$(shasum -a 256 "$work/$ZIP_NAME" | awk '{print $1}')"
    if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
        echo "❌  The download's sha256 ($actual) does not match the Release ($expected). Nothing was installed."
        return 1
    fi
    echo "✅  sha256 matches"
    mkdir "$work/x" && ditto -x -k "$work/$ZIP_NAME" "$work/x" || { echo "❌  Could not unpack $ZIP_NAME."; return 1; }
    local bin="$work/x/$BINARY_NAME"
    [ -f "$bin" ] || { echo "❌  $ZIP_NAME holds no $BINARY_NAME binary."; return 1; }
    if ! codesign --verify --strict "$bin" 2>/dev/null; then
        echo "❌  The downloaded binary's signature does not verify. Nothing was installed."; return 1
    fi
    # Not spctl: Gatekeeper gives a bare command-line binary no verdict, notarized or not.
    details="$(codesign -dv --verbose=2 "$bin" 2>&1)"
    if ! grep -qx "Identifier=$BUNDLE_ID" <<<"$details" || ! grep -qx "TeamIdentifier=$TEAM_ID" <<<"$details" ||
        ! grep -q "^Authority=Developer ID Application: .*($TEAM_ID)$" <<<"$details"; then
        echo "❌  The downloaded binary is not signed with Developer ID as $BUNDLE_ID by team $TEAM_ID. Nothing was installed."; return 1
    fi
    reported="$("$bin" --version 2>/dev/null || true)"
    if [ "$reported" != "$VERSION" ]; then
        echo "❌  The downloaded binary reports version '$reported', not $VERSION. Nothing was installed."; return 1
    fi
    echo "✅  Developer ID signature of team $TEAM_ID as $BUNDLE_ID, version $VERSION"

    # Staged in the destination directory, then one rename onto `macos`.
    mkdir -p "$INSTALL_DIR" || { echo "❌  Could not create $INSTALL_DIR (no sudo is used by design)."; return 1; }
    staged="$(mktemp "$INSTALL_DIR/.$BINARY_NAME.tmp.XXXXXX")" || { echo "❌  Could not write to $INSTALL_DIR."; return 1; }
    cat "$bin" > "$staged" && chmod 755 "$staged" && mv -f "$staged" "$INSTALL_DIR/$BINARY_NAME" || {
        rm -f "$staged"; echo "❌  Could not install into $INSTALL_DIR."; return 1; }
    echo "✅  Installed: $("$INSTALL_DIR/$BINARY_NAME" --version) at $INSTALL_DIR/$BINARY_NAME"
    echo ""
    return 0
)

source_build_requested() {
    [ -n "${MACOS_CLI_SIGN_MODE:-}${MACOS_CLI_SIGN_IDENTITY:-}${MACOS_CLI_SIGN_CONFIG:-}" ] ||
        [ -f "${XDG_CONFIG_HOME:-$HOME/.config}/macos-cli/signing.env" ]
}

if ! source_build_requested; then
    rc=0
    install_release || rc=$?
    case "$rc" in
        0) after_install "$INSTALL_DIR/$BINARY_NAME" developer-id; exit 0 ;;
        2) echo "⚠️   There is no Release for $VERSION, so this builds from source with an ad-hoc signature."
           echo "    The permissions macOS grants to an ad-hoc build will not survive the next rebuild."
           echo ""
           export MACOS_CLI_SIGN_MODE=adhoc ;;
        *) exit 1 ;;
    esac
fi

# ── Locate the repo (clone only if we are not already inside it) ─────────────
if [ -f "Package.swift" ] && [ -d "Sources" ]; then
    REPO_DIR="$(pwd)"
    echo "✅  Using local repo: $REPO_DIR"
else
    echo "📦  Cloning macos-cli..."
    rm -rf "$CLONE_DIR"
    git clone --depth 1 "$REPO_URL" "$CLONE_DIR" 2>&1 | tail -1
    REPO_DIR="$CLONE_DIR"
fi

# ── Signing contract ─────────────────────────────────────────────────────────
# Loaded and validated BEFORE the build, so a misconfigured run costs a second
# instead of a full release compile — and never creates the install directory.
# shellcheck source=scripts/lib/sign_verify.sh
source "$REPO_DIR/scripts/lib/sign_verify.sh"

if ! sv_load_sign_config; then
    exit 1
fi

case "$SV_SIGN_MODE" in
    developer-id)
        echo "🔏  Signing mode: developer-id"
        echo "    Identity: $SV_SIGN_IDENTITY"
        echo "    Identifier: $SV_BUNDLE_ID (stable — intended to keep TCC grants across rebuilds)"
        ;;
    adhoc)
        echo "🔏  Signing mode: adhoc (contributor / local build)"
        echo "    ⚠️   An ad-hoc signature has no certificate-based identity: macOS pins the"
        echo "        permission grant to this exact build's cdhash, so EVERY rebuild will"
        echo "        require you to grant Contacts / Calendar / Reminders / Automation again."
        echo "        Use MACOS_CLI_SIGN_IDENTITY=... for an install with durable permissions."
        ;;
esac
echo ""

# ── Check for Swift ──────────────────────────────────────────────────────────
if ! command -v swift &>/dev/null; then
    echo "❌  Swift not found."
    echo "    Install Xcode Command Line Tools first:"
    echo "    xcode-select --install"
    echo "    Then re-run this script."
    exit 1
fi
echo "✅  Swift $(swift --version 2>&1 | head -1 | awk '{print $3}')"

# ── Build ────────────────────────────────────────────────────────────────────
echo "🔨  Building (this takes ~30s)..."
cd "$REPO_DIR"
if ! swift build -c release 2>&1 | tee /tmp/macos-build.log | grep -q "Build complete"; then
    echo "❌  Build failed. Full output:"
    cat /tmp/macos-build.log
    exit 1
fi

# Deterministically ask SwiftPM where it put the product — no `find | head`
# ambiguity, no risk of matching a stray file in checkouts or a dSYM bundle.
BIN_PATH="$(swift build -c release --show-bin-path 2>/dev/null)"
BUILT_BINARY="$BIN_PATH/$PRODUCT_NAME"
if [ ! -x "$BUILT_BINARY" ]; then
    echo "❌  Build succeeded but product not found at: $BUILT_BINARY"
    exit 1
fi

# The Info.plist is embedded at link time; if it is missing or stale, the binary
# has no bundle identity and no permission prompt text. Catch that before signing.
echo "🔎  Verifying the embedded Info.plist..."
if ! sv_verify_info_plist "$BUILT_BINARY" "$SV_EXPECTED_VERSION"; then
    echo "❌  The built binary does not carry the expected embedded Info.plist."
    echo "    Expected identifier $SV_BUNDLE_ID and version $SV_EXPECTED_VERSION."
    exit 1
fi
echo "✅  Info.plist embedded: $SV_BUNDLE_ID $SV_EXPECTED_VERSION"

# ── Stage inside the destination directory, sign, verify, then swap ──────────
mkdir -p "$INSTALL_DIR"
DEST="$INSTALL_DIR/$BINARY_NAME"

TMP_DEST=""
cleanup_staged() { [ -n "$TMP_DEST" ] && rm -f "$TMP_DEST" 2>/dev/null; true; }
trap cleanup_staged EXIT

echo "📋  Staging into $INSTALL_DIR..."
# Stage into the SAME directory as the destination so the final swap can be a
# plain rename(2), and create the staging file exclusively (mktemp, mode 0600)
# so a pre-planted symlink at a guessable name cannot redirect this copy — or
# the codesign that follows it — onto some other file.
if ! TMP_DEST="$(sv_stage_temp "$INSTALL_DIR" ".$BINARY_NAME.tmp")"; then
    echo "❌  Could not write to $INSTALL_DIR (no sudo is used by design)."
    echo "    Pick a writable dir on your PATH, e.g.:"
    echo "      MACOS_CLI_INSTALL_DIR=\"\$HOME/.local/bin\" ./install.sh"
    exit 1
fi
if ! cat "$BUILT_BINARY" > "$TMP_DEST"; then
    echo "❌  Could not write the staged binary into $INSTALL_DIR."
    exit 1
fi
chmod +x "$TMP_DEST"

echo "🔏  Signing..."
if ! sv_sign_binary "$TMP_DEST" "$SV_SIGN_MODE" "$SV_SIGN_IDENTITY"; then
    echo "❌  Code signing failed — nothing was installed."
    if [ "$SV_SIGN_MODE" = "developer-id" ] && [ "${SV_SIGN_TIMESTAMP:-1}" != "0" ]; then
        echo "    A secure timestamp requires network access to Apple's timestamp server."
        echo "    Set MACOS_CLI_SIGN_TIMESTAMP=0 to sign without one (the result CANNOT be"
        echo "    notarized, but its Developer ID identity is still stable)."
    fi
    exit 1
fi

# ── Verify the exact bytes that are about to become `macos` ──────────────────
echo "🔎  Verifying signature, identity and version..."
if ! sv_verify_signature "$TMP_DEST" "$SV_SIGN_MODE"; then
    echo "❌  Signature verification failed — nothing was installed."
    exit 1
fi
if ! sv_verify_info_plist "$TMP_DEST" "$SV_EXPECTED_VERSION"; then
    echo "❌  The signed artifact lost its embedded Info.plist — nothing was installed."
    exit 1
fi
if ! sv_verify_version "$TMP_DEST" "$SV_EXPECTED_VERSION"; then
    echo "❌  The signed artifact does not report the expected version — nothing was installed."
    exit 1
fi

DR="$(sv_designated_requirement "$TMP_DEST")"
TEAM="$(sv_team_identifier "$TMP_DEST")"
echo "✅  Designated requirement: $DR"
[ "$SV_SIGN_MODE" = "developer-id" ] && echo "✅  Team identifier: $TEAM"

# ── Install (atomic same-directory rename, with rollback) ────────────────────
# Everything before this point fails without touching the installed executable.
# The swap itself is destructive, so the previous binary is copied aside inside
# the same directory first and moved back if the post-swap checks fail.
post_swap_verify() {
    sv_verify_version "$DEST" "$SV_EXPECTED_VERSION" || return 1
    sv_verify_signature "$DEST" "$SV_SIGN_MODE" || return 1
    return 0
}

echo "📋  Installing to $DEST..."
if ! sv_install_with_rollback "$TMP_DEST" "$DEST" post_swap_verify; then
    echo "❌  Install failed — nothing usable was left in place by this script."
    echo "    If an executable was already installed at $DEST it has been restored;"
    echo "    if this was a first install, no executable was left behind."
    exit 1
fi

echo "✅  Installed: $("$DEST" --version)"
echo ""

after_install "$DEST" "$SV_SIGN_MODE"
