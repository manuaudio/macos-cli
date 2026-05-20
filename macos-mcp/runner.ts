// runner.ts
// Shared subprocess + arg-building for the macos binary.
// Used by both macos-mcp and macos-bridge — keep the two copies identical.

import { existsSync } from "node:fs";

const TOOL_TIMEOUT_MS = parseInt(process.env.MACOS_MCP_TIMEOUT_MS ?? "60000", 10);

export interface ToolDef {
  name: string;
  description: string;
  command: string[];
  parameters: {
    type: "object";
    properties: Record<string, ToolProperty>;
    required?: string[];
  };
  flags: Record<string, string>;
  flags_boolean: string[];
}

export interface ToolProperty {
  type: "string" | "integer" | "number" | "boolean";
  description?: string;
  positional?: boolean;
}

export interface RunResult {
  ok: boolean;
  stdout: string;
  stderr: string;
  exitCode: number;
  error?: string;
}

const CANDIDATE_BINARY_PATHS = [
  "/usr/local/bin/macos",
  "/opt/homebrew/bin/macos",
  `${process.env.HOME ?? ""}/.local/bin/macos`,
];

let cachedBinaryPath: string | null = null;

export function resolveBinary(): string {
  if (cachedBinaryPath) return cachedBinaryPath;
  for (const p of CANDIDATE_BINARY_PATHS) {
    if (existsSync(p)) {
      cachedBinaryPath = p;
      return p;
    }
  }
  throw new Error(
    `macos binary not found in any of: ${CANDIDATE_BINARY_PATHS.join(", ")}. ` +
      `Install via https://github.com/manuaudio/macos-cli`,
  );
}

export function buildArgs(tool: ToolDef, args: Record<string, unknown>): string[] {
  const out: string[] = [...tool.command];

  // Positional args first, in property-declaration order.
  const props = tool.parameters.properties;
  for (const [paramName, prop] of Object.entries(props)) {
    if (prop.positional && args[paramName] !== undefined && args[paramName] !== null) {
      out.push(String(args[paramName]));
    }
  }

  // Then flagged args.
  for (const [paramName, flagName] of Object.entries(tool.flags)) {
    const value = args[paramName];
    if (value === undefined || value === null) continue;

    if (tool.flags_boolean.includes(paramName)) {
      if (value === true || value === "true") {
        out.push(flagName);
      }
      continue;
    }

    out.push(flagName, String(value));
  }

  return out;
}

export async function runTool(
  tool: ToolDef,
  args: Record<string, unknown>,
): Promise<RunResult> {
  const binary = resolveBinary();
  const cliArgs = buildArgs(tool, args);

  const proc = Bun.spawn([binary, ...cliArgs], {
    stdout: "pipe",
    stderr: "pipe",
  });

  const executionPromise: Promise<RunResult> = Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]).then(([stdoutText, stderrText, exitCode]) => {
    if (exitCode === 0) {
      return { ok: true, stdout: stdoutText, stderr: stderrText, exitCode } as RunResult;
    }
    // Auth denied is a known, non-fatal failure shape:
    //   "'calendar.delete' is denied. Run `macos auth grant calendar.delete` ..."
    const denied = /is denied(\.| by default)/.test(stderrText);
    return {
      ok: false,
      stdout: stdoutText,
      stderr: stderrText,
      exitCode,
      error: denied
        ? `capability denied: ${stderrText.trim()}`
        : `macos ${cliArgs.join(" ")} exited ${exitCode}: ${stderrText.trim() || "no stderr"}`,
    } as RunResult;
  });

  let timeoutHandle: ReturnType<typeof setTimeout>;
  const timeoutPromise = new Promise<RunResult>((resolve) => {
    timeoutHandle = setTimeout(() => {
      try { proc.kill(); } catch {}
      resolve({ ok: false, stdout: "", stderr: "", exitCode: -1, error: `Tool timed out after ${TOOL_TIMEOUT_MS / 1000}s` });
    }, TOOL_TIMEOUT_MS);
  });

  const result = await Promise.race([executionPromise, timeoutPromise]);
  clearTimeout(timeoutHandle!); // no-op if timeout already fired
  return result;
}
