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
echo "Building macos binary..."
if ! swift build -c release 2>&1 | tee /tmp/macos-build.log | grep -q "Build complete"; then
    echo "Build failed. Full output:"
    cat /tmp/macos-build.log
    exit 1
fi

BUILT_BINARY=$(find .build -path '*/release/macos-cli' -type f -not -path '*dSYM*' -not -path '*checkouts*' 2>/dev/null | head -1)
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
echo ""
echo "✓ macos installed. Setting up permissions..."
echo ""
"$INSTALL_DIR/$BINARY_NAME" auth setup --all --yes 2>/dev/null || true
echo ""
echo "Run 'macos auth setup' to customize permissions interactively."
echo "Run 'macos setup' to verify everything works."

# ── Optional: install MCP + HTTP bridge ──────────────────────────────────────
# These let local LLM stacks (Claude Desktop / Code via MCP, Ollama / LM Studio
# / Open WebUI via HTTP) drive the same tools. Skipped if bun is not installed.

install_wrapper_layer() {
    if ! command -v bun &>/dev/null; then
        echo ""
        echo "ℹ️   Skipping MCP + bridge install — bun not found."
        echo "    To enable later: brew install oven-sh/bun/bun, then re-run install.sh."
        return 0
    fi

    BUN_MAJOR=$(bun --version 2>/dev/null | cut -d. -f1)
    if [ -z "$BUN_MAJOR" ] || [ "$BUN_MAJOR" -lt 1 ]; then
        echo "ℹ️  Bun 1.0+ required for MCP server build. Run: brew install oven-sh/bun/bun"
        return 0
    fi

    echo ""
    echo "🔌  Building MCP server + HTTP bridge..."

    local ARCH
    ARCH="$(uname -m)"
    local BUILD_SCRIPT="build"
    if [ "$ARCH" = "arm64" ]; then BUILD_SCRIPT="build:arm"; fi

    # Always re-copy canonical tools.json into both wrappers
    if [ -f "$REPO_DIR/tool-definitions/tools.json" ]; then
        cp "$REPO_DIR/tool-definitions/tools.json" "$REPO_DIR/macos-mcp/tools.json"
        cp "$REPO_DIR/tool-definitions/tools.json" "$REPO_DIR/macos-bridge/tools.json"
    fi

    # macos-mcp
    if [ -d "$REPO_DIR/macos-mcp" ]; then
        (cd "$REPO_DIR/macos-mcp" && bun install --silent >/dev/null && bun run "$BUILD_SCRIPT" 2>&1 | tail -3)
        if [ -f "$REPO_DIR/macos-mcp/macos-mcp" ]; then
            if cp "$REPO_DIR/macos-mcp/macos-mcp" "$INSTALL_DIR/macos-mcp" 2>/dev/null; then
                chmod +x "$INSTALL_DIR/macos-mcp"
            else
                sudo cp "$REPO_DIR/macos-mcp/macos-mcp" "$INSTALL_DIR/macos-mcp"
                sudo chmod +x "$INSTALL_DIR/macos-mcp"
            fi
            echo "✅  Installed: $INSTALL_DIR/macos-mcp"
        else
            echo "⚠️   macos-mcp build did not produce a binary — skipping install"
        fi
    fi

    # macos-bridge
    if [ -d "$REPO_DIR/macos-bridge" ]; then
        (cd "$REPO_DIR/macos-bridge" && bun install --silent >/dev/null && bun run "$BUILD_SCRIPT" 2>&1 | tail -3)
        if [ -f "$REPO_DIR/macos-bridge/macos-bridge" ]; then
            if cp "$REPO_DIR/macos-bridge/macos-bridge" "$INSTALL_DIR/macos-bridge" 2>/dev/null; then
                chmod +x "$INSTALL_DIR/macos-bridge"
            else
                sudo cp "$REPO_DIR/macos-bridge/macos-bridge" "$INSTALL_DIR/macos-bridge"
                sudo chmod +x "$INSTALL_DIR/macos-bridge"
            fi
            echo "✅  Installed: $INSTALL_DIR/macos-bridge"

            # Offer to enable the LaunchAgent (user-level, no sudo)
            local PLIST_SRC="$REPO_DIR/macos-bridge/com.macos-cli.bridge.plist"
            local PLIST_DST="$HOME/Library/LaunchAgents/com.macos-cli.bridge.plist"
            if [ -f "$PLIST_SRC" ]; then
                if [ -t 0 ]; then
                    read -r -p "Start macos-bridge automatically on login? [y/N] " ans
                else
                    ans="n"
                fi
                if [[ "$ans" =~ ^[Yy] ]]; then
                    mkdir -p "$HOME/Library/LaunchAgents"
                    cp "$PLIST_SRC" "$PLIST_DST"
                    launchctl unload "$PLIST_DST" 2>/dev/null || true
                    launchctl load "$PLIST_DST"
                    echo "✅  LaunchAgent loaded: com.macos-cli.bridge (port 2772)"
                else
                    echo "ℹ️   Skipped LaunchAgent. Enable later with:"
                    echo "      cp \"$PLIST_SRC\" ~/Library/LaunchAgents/"
                    echo "      launchctl load ~/Library/LaunchAgents/com.macos-cli.bridge.plist"
                fi
            fi
        else
            echo "⚠️   macos-bridge build did not produce a binary — skipping install"
        fi
    fi

    echo ""
    echo "🎉  Wrapper layer installed."
    echo ""
    echo "    Claude Desktop config snippet:"
    echo '      { "mcpServers": { "macos": { "command": "/usr/local/bin/macos-mcp" } } }'
    echo ""
    echo "    Local LLM HTTP endpoint:"
    echo "      http://localhost:2772/v1/tools"
    echo ""
}

install_wrapper_layer
