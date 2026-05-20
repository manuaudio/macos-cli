# macos-bridge

Local HTTP server that exposes the `macos` CLI in OpenAI function-calling format. Point any local LLM stack — Ollama, LM Studio, Open WebUI, llama.cpp server — at it and your model can drive the Mac.

## Install

```bash
cd macos-bridge
bun install
bun run build           # produces ./macos-bridge (Intel)
# or: bun run build:arm  (Apple Silicon)
sudo install -m 755 macos-bridge /usr/local/bin/macos-bridge
```

The repo-level `install.sh` does this and (optionally) wires the LaunchAgent.

## Run

```bash
# Foreground
/usr/local/bin/macos-bridge --port 2772

# Background (LaunchAgent — survives logout/restart, user scope, no sudo)
cp macos-bridge/com.macos-cli.bridge.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.macos-cli.bridge.plist
```

## Endpoints

```
GET  /v1/health         → { ok: true, version, tools_count }
GET  /v1/tools          → { tools: [...] }   # OpenAI function-calling format
POST /v1/tool_calls     → [ { name, arguments } ]   # request
                          [ { name, result | error } ]  # response
```

## Wire into Ollama (function calling)

```bash
# Fetch tool catalog
curl -s http://localhost:2772/v1/tools | jq '.tools | length'

# Make a call directly
curl -s -X POST http://localhost:2772/v1/tool_calls \
  -H 'content-type: application/json' \
  -d '[{"name":"macos_calendar_list","arguments":{"days":3,"json":true}}]' | jq
```

In your Ollama client, register the tools returned by `/v1/tools` and route any tool call back through `/v1/tool_calls`.

## Wire into LM Studio / Open WebUI

Both support custom OpenAI-compatible function-calling tool sources. Set the tool-source URL to `http://localhost:2772/v1/tools` and the execution URL to `http://localhost:2772/v1/tool_calls`.

## Errors

Auth-denied calls (e.g. `calendar.delete is denied`) appear as
`{"name": "macos_calendar_delete", "error": "capability denied: ..."}`
in the response — never as HTTP 4xx. The model can read the error and propose grant.
