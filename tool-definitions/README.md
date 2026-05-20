# tool-definitions

`tools.json` is the canonical, machine-readable description of every `macos` CLI command as a callable tool. Both `macos-mcp` (MCP server) and `macos-bridge` (HTTP/OpenAI bridge) read this file to register their tools — there is no second source of truth.

## Schema

Each entry:

| Field | Type | Description |
|---|---|---|
| `name` | string | Tool identifier (matches `macos_<command>_<subcommand>` convention). |
| `description` | string | One-line human description. Sent to the model. |
| `command` | string[] | CLI args appended to the binary (e.g. `["calendar", "events"]`). |
| `parameters` | JSON Schema | OpenAI function-calling–compatible parameter spec. |
| `flags` | object | Map of parameter name → CLI flag name. |
| `flags_boolean` | string[] | Parameters that are bare boolean flags (no value). |

A property may have `"positional": true` — those arguments are appended after the `command` prefix, in the order they appear in `properties`, before any `--flag` values.

## Adding a tool

1. Find or add the subcommand in `Sources/macos-cli/Commands/`.
2. Run `macos <cmd> <sub> --help` and copy the exact flag names.
3. Append a new tool block to `tools.json`.
4. Bump the top-level `version` if the change is user-visible.
