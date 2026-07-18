#!/bin/bash
# macOS CLI installer
#
# Builds and installs exactly ONE artifact: the `macos` command.
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/manuaudio/macos-cli/main/install.sh | bash
#   git clone https://github.com/manuaudio/macos-cli && cd macos-cli && ./install.sh
#
# Install location (default): $HOME/.local/bin/macos
#   Override with:  MACOS_CLI_INSTALL_DIR=/somewhere/on/your/PATH ./install.sh
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

echo ""
echo "macOS CLI installer"
echo "==================="
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

# ── Clone or use existing repo ───────────────────────────────────────────────
if [ -f "Package.swift" ] && [ -d "Sources" ]; then
    REPO_DIR="$(pwd)"
    echo "✅  Using local repo: $REPO_DIR"
else
    echo "📦  Cloning macos-cli..."
    rm -rf "$CLONE_DIR"
    git clone --depth 1 "$REPO_URL" "$CLONE_DIR" 2>&1 | tail -1
    REPO_DIR="$CLONE_DIR"
fi

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

# ── Install (atomic, non-destructive on failure) ─────────────────────────────
mkdir -p "$INSTALL_DIR"
DEST="$INSTALL_DIR/$BINARY_NAME"
TMP_DEST="$INSTALL_DIR/.$BINARY_NAME.tmp.$$"

echo "📋  Installing to $DEST..."
# Copy to a temp file in the SAME directory, then rename. rename(2) within one
# filesystem is atomic: a concurrent `macos` invocation sees either the old
# executable or the new one, never a half-written file. If the copy fails, the
# previously installed executable is left untouched.
if ! cp "$BUILT_BINARY" "$TMP_DEST"; then
    echo "❌  Could not write to $INSTALL_DIR (no sudo is used by design)."
    echo "    Pick a writable dir on your PATH, e.g.:"
    echo "      MACOS_CLI_INSTALL_DIR=\"\$HOME/.local/bin\" ./install.sh"
    rm -f "$TMP_DEST" 2>/dev/null || true
    exit 1
fi
chmod +x "$TMP_DEST"
mv -f "$TMP_DEST" "$DEST"

echo "✅  Installed: $("$DEST" --version)"
echo ""

# ── PATH hint ────────────────────────────────────────────────────────────────
case ":$PATH:" in
    *":$INSTALL_DIR:"*) : ;;  # already on PATH
    *)
        echo "⚠️   $INSTALL_DIR is not on your PATH."
        echo "    Add this to your shell profile (~/.zshrc or ~/.bash_profile):"
        echo "      export PATH=\"$INSTALL_DIR:\$PATH\""
        echo ""
        ;;
esac

# ── Permissions guidance (NOT granted automatically) ─────────────────────────
echo "Next: grant the macOS privacy permissions you want this tool to use."
echo ""
echo "  • Reminders and Notes work read-only with no extra setup on most Macs."
echo "  • Calendar and Contacts require you to grant access the first time a"
echo "    command touches them — macOS will prompt, or you can pre-authorize in"
echo "    System Settings ▸ Privacy & Security."
echo ""
echo "  Check what's granted at any time (this never prompts):"
echo "      $BINARY_NAME reminders status --json"
echo "      $BINARY_NAME setup            # summarizes every capability"
echo ""
echo "This installer intentionally does not grant any permission for you."
echo "🎉  Done — one binary, no background services."
