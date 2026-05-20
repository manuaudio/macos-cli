#!/usr/bin/env bun
// macos-bridge — local HTTP server that exposes the macos CLI in OpenAI
// function-calling format. Default port 2772.
//
// Endpoints:
//   GET  /v1/tools           → { tools: [{ type: "function", function: {name, description, parameters} }] }
//   POST /v1/tool_calls      → request: [{name, arguments}]; response: [{name, result | error}]
//   GET  /v1/health          → { ok: true, version, tools_count }

import toolsJson from "./tools.json" with { type: "json" };
import { runTool, type ToolDef } from "./runner.ts";

interface ToolsFile {
  version: string;
  tools: ToolDef[];
}

const tools = (toolsJson as ToolsFile).tools;
const version = (toolsJson as ToolsFile).version;
const toolsByName = new Map<string, ToolDef>(tools.map((t) => [t.name, t]));

// ── parse args ──────────────────────────────────────────────────────────────
function parsePort(argv: string[]): number {
  const i = argv.indexOf("--port");
  if (i !== -1 && argv[i + 1]) {
    const p = Number(argv[i + 1]);
    if (Number.isFinite(p) && p > 0 && p < 65536) return p;
  }
  const envPort = process.env.MACOS_BRIDGE_PORT;
  if (envPort) {
    const p = Number(envPort);
    if (Number.isFinite(p) && p > 0 && p < 65536) return p;
  }
  return 2772;
}

const port = parsePort(process.argv.slice(2));

// ── OpenAI tools schema ─────────────────────────────────────────────────────
function openAIToolSchema(t: ToolDef) {
  const cleanedProps: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(t.parameters.properties)) {
    const { positional: _drop, ...rest } = v as Record<string, unknown> & { positional?: boolean };
    cleanedProps[k] = rest;
  }
  return {
    type: "function" as const,
    function: {
      name: t.name,
      description: t.description,
      parameters: {
        type: "object" as const,
        properties: cleanedProps,
        required: t.parameters.required ?? [],
      },
    },
  };
}

// ── HTTP handlers ───────────────────────────────────────────────────────────
function corsHeaders(): Record<string, string> {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type, Authorization",
  };
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store", ...corsHeaders() },
  });
}

async function handleToolCalls(req: Request): Promise<Response> {
  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return jsonResponse({ error: "invalid JSON body" }, 400);
  }

  if (!Array.isArray(body)) {
    return jsonResponse({ error: "body must be an array of {name, arguments}" }, 400);
  }

  const calls = body as Array<{ name?: unknown; arguments?: unknown }>;
  console.error(`[${new Date().toISOString()}] tool_calls: ${calls.map((c: any) => c.name).join(", ")}`);
  const results = await Promise.all(
    calls.map(async (call): Promise<{ name: string; result?: string; error?: string }> => {
      const name = typeof call.name === "string" ? call.name : "";
      const args =
        call.arguments && typeof call.arguments === "object"
          ? (call.arguments as Record<string, unknown>)
          : {};
      const tool = toolsByName.get(name);
      if (!tool) {
        return { name, error: `unknown tool: ${name}` };
      }
      try {
        const r = await runTool(tool, args);
        if (r.ok) {
          return { name, result: r.stdout || "(no output)" };
        }
        return { name, error: r.error ?? r.stderr };
      } catch (e: any) {
        return { name, error: e?.message ?? String(e) };
      }
    }),
  );

  return jsonResponse(results);
}

const server = Bun.serve({
  hostname: "127.0.0.1",
  port,
  async fetch(req) {
    const url = new URL(req.url);

    if (req.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: corsHeaders() });
    }

    if (req.method === "GET" && url.pathname === "/v1/health") {
      return jsonResponse({ ok: true, version, tools_count: tools.length });
    }

    if (req.method === "GET" && url.pathname === "/v1/tools") {
      return jsonResponse({ tools: tools.map(openAIToolSchema) });
    }

    if (req.method === "POST" && url.pathname === "/v1/tool_calls") {
      return handleToolCalls(req);
    }

    return jsonResponse({ error: "not found" }, 404);
  },
});

console.log(`macos-bridge ${version} listening on http://${server.hostname}:${server.port}`);
console.log(`tools: ${tools.length}`);
