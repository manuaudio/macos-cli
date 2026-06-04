<h1 align="center">🖥️ macOS CLI</h1>

<p align="center">
  <b>Drive your entire Mac from the command line — and hand that same power to your AI agent.</b>
</p>

<p align="center">
  Calendar · Contacts · Mail · Messages · Notes · Reminders · Photos · Music · Safari ·
  screenshots · OCR · windows · mouse &amp; keyboard · the Accessibility tree · and 40+ more.<br>
  One native Swift binary. Every command speaks <code>--json</code>.
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-yellow.svg" alt="License: MIT"></a>
  <a href="#install"><img src="https://img.shields.io/badge/macOS-13%2B-black?logo=apple&logoColor=white" alt="macOS 13+"></a>
  <a href="https://swift.org"><img src="https://img.shields.io/badge/Swift-5.9%2B-F05138?logo=swift&logoColor=white" alt="Swift 5.9+"></a>
  <a href="https://github.com/manuaudio/macos-cli/releases"><img src="https://img.shields.io/badge/release-v0.6.3-blue" alt="Release"></a>
  <a href="#-use-it-with-ai-agents"><img src="https://img.shields.io/badge/MCP-204_tools-8A2BE2?logo=anthropic&logoColor=white" alt="204 MCP tools"></a>
  <img src="https://img.shields.io/badge/runtime_deps-0-brightgreen" alt="Zero runtime deps">
</p>

<p align="center">
  Zero runtime deps · no Python, no Node · just a ~7&nbsp;MB binary
</p>

---

```bash
macos calendar events --json          # what's on today
macos mail search "invoice" --json    # find that email
macos ocr screen                      # read everything on screen as text
macos ax click "Sign In"              # click a button by its name — no coordinates
```

## Why you'll want this

macOS hides its best features behind GUI apps and brittle AppleScript. **macOS CLI turns all of it into clean, scriptable commands that print JSON** — so you can wire your Mac into shell scripts, automations, and especially LLM agents.

- 🤖 **Built for AI agents.** Point Claude, Ollama, or any tool-calling model at it and your assistant can read your calendar, triage your inbox, move windows, and click buttons *by name*.
- 🪶 **One tiny binary.** Native Swift, ~7 MB, zero runtime dependencies. No interpreter, no `node_modules`, no glue code.
- 🧩 **40+ capabilities, one grammar.** Every command follows `macos <area> <action>` and every command takes `--json`.
- 🔒 **Local & private.** It talks to your Mac's own frameworks. Nothing leaves your machine.

## Install

```bash
curl -sSL https://raw.githubusercontent.com/manuaudio/macos-cli/main/install.sh | bash
```

Builds from source, installs to `/usr/local/bin/macos`, and runs a permission check. ~30 seconds.

> **Requirements:** macOS 13 (Ventura)+ and Swift 5.9+ (ships with Xcode Command Line Tools).
> No CLT yet? `xcode-select --install`, then re-run the command above.

```bash
macos --version   # 0.6.3
macos setup       # checks every permission — a green ✓ per capability
```

## What it can do

| | Area | Examples |
|---|---|---|
| 📅 | **Calendar** | list, create, update, delete events across all calendars |
| ✅ | **Reminders** | create, complete, list by list, due dates |
| 👤 | **Contacts** | search, read, create, update — by name, email, or phone |
| 💬 | **Messages** | send iMessage/SMS, read threads, search |
| ✉️ | **Mail** | search, read, draft, send, reply, manage mailboxes |
| 📝 | **Notes** | read, create, search Apple Notes |
| 🎵 | **Music** | now playing, play/pause, skip, library queries |
| 🌐 | **Safari** | read the current tab, list tabs, open URLs |
| 📸 | **Screen** | full/window/region screenshots, screen recording check |
| 🔤 | **OCR** | extract text from the screen, a region, or any image |
| 🪟 | **Windows** | list, move, resize, focus app windows |
| 🖱️ | **Input** | type text, send shortcuts, move & click the mouse |
| ♿ | **Accessibility** | find & click UI elements *by name*, dump the UI tree |
| 🔋 | **System** | battery, focus modes, processes, disks, defaults, network |
| 🔑 | **Keychain** | read/write passwords and secrets (with your approval) |
| 📄 | **Files & PDF** | search files, read metadata, extract PDF text |

…and more. Run `macos --help` for the full list, or `macos <area> --help` for any area.

## Quick taste

```bash
# Calendar & reminders
macos calendar events --json
macos reminders create --title "Call the bank" --due "tomorrow 9am"

# Find a contact, then text them
macos contacts search "Ryan" --json
macos messages send --to "+13105550100" --text "On my way"

# See your screen — literally
macos screenshot --out ~/shot.png
macos ocr screen                       # everything on screen → plain text

# Read the web page you're looking at
macos safari current-tab --json

# Drive the UI like a human (Accessibility)
macos ax find "Sign In"                # locate it
macos ax click "Sign In"               # click it — by label, no pixel coordinates
macos keyboard type "hello world"
```

Every command supports `--json` for clean, parseable output:

```bash
macos battery --json
# {"level": 87, "charging": false, "plugged_in": true}
```

## 🤖 Use it with AI agents

This is where macOS CLI shines. Two ready-made adapters ship in the repo:

### Claude Desktop / Claude Code (MCP)

`install.sh` builds **`macos-mcp`** automatically if [`bun`](https://bun.sh) is present (`brew install oven-sh/bun/bun`). Then add it to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "macos": { "command": "macos-mcp" }
  }
}
```

Restart Claude and it gains **204 tools** — your assistant can now manage your calendar, inbox, reminders, and screen.

### Ollama / LM Studio / Open WebUI (HTTP bridge)

`macos-bridge` exposes an OpenAI-style function-calling endpoint on `localhost:2772`:

```
GET  /v1/tools        → tool catalog for any function-calling model
POST /v1/tool_calls   → [{name, arguments}] → [{name, result}]
```

Point your local model's tool layer at it and you get the same powers, no cloud required.

## Permissions

macOS gates these capabilities behind privacy permissions — by design. On first use you'll be prompted to grant **Automation**, **Calendars**, **Contacts**, **Accessibility**, **Screen Recording**, etc. Run `macos setup` any time to see exactly what's granted and what's missing. Nothing is bypassed; you stay in control.

## Build from source

```bash
git clone https://github.com/manuaudio/macos-cli
cd macos-cli
swift build -c release
cp .build/release/macos /usr/local/bin/
```

## Contributing

Issues and PRs welcome. The codebase is plain Swift + [swift-argument-parser](https://github.com/apple/swift-argument-parser) — one command per file under `Sources/macos-cli/Commands/`.

## License

MIT © [manuaudio](https://github.com/manuaudio) — see [LICENSE](LICENSE).
