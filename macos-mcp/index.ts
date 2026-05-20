#!/usr/bin/env bun
// macos-mcp — MCP server wrapping the macos CLI binary.
// Reads tools.json at startup, registers each tool, dispatches calls to runTool().

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";

import toolsJson from "./tools.json" with { type: "json" };
import { runTool, type ToolDef } from "./runner.ts";

interface ToolsFile {
  version: string;
  tools: ToolDef[];
}

const tools = (toolsJson as ToolsFile).tools;
const toolsByName = new Map<string, ToolDef>(tools.map((t) => [t.name, t]));

const server = new Server(
  {
    name: "macos-mcp",
    version: (toolsJson as ToolsFile).version,
  },
  {
    capabilities: { tools: {} },
  },
);

server.setRequestHandler(ListToolsRequestSchema, async () => {
  return {
    tools: tools.map((t) => ({
      name: t.name,
      description: t.description,
      inputSchema: stripPositional(t.parameters),
    })),
  };
});

server.setRequestHandler(CallToolRequestSchema, async (req) => {
  const tool = toolsByName.get(req.params.name);
  if (!tool) {
    return {
      isError: true,
      content: [{ type: "text" as const, text: `unknown tool: ${req.params.name}` }],
    };
  }

  const result = await runTool(tool, (req.params.arguments ?? {}) as Record<string, unknown>);
  if (result.ok) {
    return {
      content: [{ type: "text" as const, text: result.stdout || "(no output)" }],
    };
  }
  return {
    isError: true,
    content: [{ type: "text" as const, text: result.error ?? result.stderr }],
  };
});

// MCP InputSchema is JSON Schema — strip our custom "positional" extension before sending.
function stripPositional(params: ToolDef["parameters"]) {
  const cleanedProps: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(params.properties)) {
    const { positional: _drop, ...rest } = v as Record<string, unknown> & { positional?: boolean };
    cleanedProps[k] = rest;
  }
  return {
    type: "object" as const,
    properties: cleanedProps,
    required: params.required ?? [],
  };
}

const transport = new StdioServerTransport();
await server.connect(transport);
