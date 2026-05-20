# macos-mcp

MCP server that exposes every `macos` CLI command as a tool to MCP hosts (Claude Desktop, Claude Code, etc.). Reads `tools.json` (generated from the canonical `tool-definitions/tools.json`) and spawns `macos <args>` per call.

## Install

```bash
cd macos-mcp
bun install
bun run build           # produces ./macos-mcp (Intel)
# or: bun run build:arm  (Apple Silicon)
sudo install -m 755 macos-mcp /usr/local/bin/macos-mcp
```

The repo-level `install.sh` does this automatically when you opt in.

## Wire into Claude Desktop

Edit `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "macos": {
      "command": "/usr/local/bin/macos-mcp"
    }
  }
}
```

Restart Claude Desktop. The tools appear under "macos" in the tools menu.

## Wire into Claude Code

Add to `~/.claude.json` under `mcpServers`:

```json
{
  "macos": { "command": "/usr/local/bin/macos-mcp" }
}
```

## Errors

Authorization-denied responses from the binary (e.g. `calendar.delete is denied`) are surfaced as `isError: true` MCP results with a `capability denied:` prefix — they are not exceptions. Grant the capability with `macos auth grant calendar.delete` and the tool starts working.
