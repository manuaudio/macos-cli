#!/bin/bash
# macOS CLI installer
# Usage: curl -sSL https://raw.githubusercontent.com/manuaudio/macos-cli/main/install.sh | bash
# Or:    git clone https://github.com/manuaudio/macos-cli && cd macos-cli && ./install.sh

set -e

REPO_URL="https://github.com/manuaudio/macos-cli.git"
INSTALL_DIR="/usr/local/bin"
BINARY_NAME="macos"
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

# ── Check install dir ────────────────────────────────────────────────────────
if [ ! -d "$INSTALL_DIR" ]; then
    echo "Creating $INSTALL_DIR..."
    sudo mkdir -p "$INSTALL_DIR"
fi

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
swift build -c release --quiet 2>/dev/null || swift build -c release 2>&1 | grep -E "error:|Build complete"

BUILT_BINARY=$(find .build -name "macos-cli" -type f ! -name "*.d" 2>/dev/null | grep release | head -1)
if [ -z "$BUILT_BINARY" ]; then
    echo "❌  Build failed — binary not found"
    exit 1
fi

# ── Install ──────────────────────────────────────────────────────────────────
echo "📋  Installing to $INSTALL_DIR/$BINARY_NAME..."
if cp "$BUILT_BINARY" "$INSTALL_DIR/$BINARY_NAME" 2>/dev/null; then
    chmod +x "$INSTALL_DIR/$BINARY_NAME"
else
    sudo cp "$BUILT_BINARY" "$INSTALL_DIR/$BINARY_NAME"
    sudo chmod +x "$INSTALL_DIR/$BINARY_NAME"
fi

echo "✅  Installed: $($INSTALL_DIR/$BINARY_NAME --version)"
echo ""

# ── Setup ────────────────────────────────────────────────────────────────────
echo "Running permission check..."
echo ""
"$INSTALL_DIR/$BINARY_NAME" setup
