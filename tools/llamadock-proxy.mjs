#!/usr/bin/env node
/*
 * Small OpenAI-compatible gateway used by LlamaDock clients.
 *
 * It keeps UTF-8 and streaming behavior identical for Cline, OpenCode,
 * OpenClaude, Computer, and the research clients.  If a client disconnects
 * while llama-server is still inside a long prefill, the gateway writes a
 * restart request consumed by llamadock-server-supervisor.ps1.  llama-server
 * has no reliable Windows-side cancel endpoint for this case, so recovering
 * the single np=1 slot requires restarting the child process.
 */

import http from "node:http";
import { randomUUID, createHash } from "node:crypto";
import { appendFile, mkdir, writeFile } from "node:fs/promises";
import { once } from "node:events";

// ---------------------------------------------------------------------------
// Status / observability state (§2 of harness design)
// ---------------------------------------------------------------------------
const GATEWAY_STARTED_AT = new Date().toISOString();
let activeRequestCount = 0;
const recentResults = [];          // { ts, ok, status, fingerprint }
const RECENT_WINDOW = 50;          // keep last N results
const fingerprintCounts = new Map(); // fingerprint → { count, firstAt, lastAt }
const LOOP_THRESHOLD = 3;
const LOOP_WINDOW_MS = 60_000;     // 60-second window for loop detection
const FINGERPRINT_MAX_ENTRIES = 500; // bound the map to prevent unbounded growth
let lastRestartRequest = null;     // last restart request written to CONTROL_FILE
let possibleRetryLoops = [];       // { fingerprint, count, detectedAt }

function option(name, fallback) {
  const index = process.argv.indexOf(name);
  return index >= 0 && process.argv[index + 1] ? process.argv[index + 1] : fallback;
}

const HOST = option("--host", process.env.LLAMADOCK_PROXY_HOST || "127.0.0.1");
const PORT = Number(option("--port", process.env.LLAMADOCK_PROXY_PORT || 8090));
const UPSTREAM = (option("--upstream", process.env.LLAMADOCK_UPSTREAM_URL || "http://127.0.0.1:8080")).replace(/\/$/, "");
const CONTROL_FILE = option("--restart-flag", process.env.LLAMADOCK_RESTART_FLAG || "");
const LOG_DIR = option("--log-dir", process.env.LLAMADOCK_LOG_DIR || "");
const MAX_BODY = 16 * 1024 * 1024;
// Cline must be able to finish JSON tool arguments. 512 tokens truncates
// ordinary file-edit payloads and leaves the agent retrying the same action.
// Clients may still override this cap with LLAMADOCK_CLINE_MAX_TOKENS.
const CLINE_MAX_TOKENS = Number(process.env.LLAMADOCK_CLINE_MAX_TOKENS || 2048);

function computeFingerprint(body) {
  if (!body) return "";
  return createHash("sha256").update(body).digest("hex");
}

function trackFingerprint(fp) {
  if (!fp) return;
  const now = Date.now();
  const entry = fingerprintCounts.get(fp) || { count: 0, firstAt: now, lastAt: now };
  // Reset if outside the window
  if (now - entry.firstAt > LOOP_WINDOW_MS) {
    entry.count = 0;
    entry.firstAt = now;
  }
  entry.count += 1;
  entry.lastAt = now;
  fingerprintCounts.set(fp, entry);
  // #9 - Bound/prune the fingerprint map to prevent unbounded growth
  if (fingerprintCounts.size > FINGERPRINT_MAX_ENTRIES) {
    const cutoff = now - LOOP_WINDOW_MS;
    for (const [key, val] of fingerprintCounts) {
      if (val.lastAt < cutoff) fingerprintCounts.delete(key);
    }
    // If still over limit, drop oldest entries
    if (fingerprintCounts.size > FINGERPRINT_MAX_ENTRIES) {
      const entries = [...fingerprintCounts.entries()].sort((a, b) => a[1].lastAt - b[1].lastAt);
      const toRemove = entries.slice(0, entries.length - FINGERPRINT_MAX_ENTRIES);
      for (const [key] of toRemove) fingerprintCounts.delete(key);
    }
  }
  if (entry.count >= LOOP_THRESHOLD) {
    const already = possibleRetryLoops.find((item) => item.fingerprint === fp);
    if (!already) {
      possibleRetryLoops.push({ fingerprint: fp, count: entry.count, detectedAt: new Date().toISOString() });
      // Keep the list bounded
      if (possibleRetryLoops.length > 20) possibleRetryLoops.shift();
    }
  }
}

function recordResult(ok, status, fingerprint) {
  recentResults.push({ ts: new Date().toISOString(), ok, status, fingerprint });
  if (recentResults.length > RECENT_WINDOW) recentResults.shift();
}

function checkUpstreamHealth() {
  return fetch(`${UPSTREAM}/health`, { signal: AbortSignal.timeout(3000) })
    .then((res) => ({ ok: res.ok, status: res.status }))
    .catch(() => ({ ok: false, status: 0 }));
}

function isInferencePath(pathname) {
  return pathname === "/v1/chat/completions" || pathname === "/completion";
}

function isOptionalClineTool(name) {
  return name === "skills" || name === "ask_question" || name === "spawn_agent" || name.startsWith("team_");
}

function isClineToolSet(names) {
  return names.some((name) => [
    "read_files",
    "search_codebase",
    "run_commands",
    "fetch_web_content",
    "editor",
  ].includes(name));
}

function compactSchema(schema) {
  if (Array.isArray(schema)) return schema.map(compactSchema);
  if (!schema || typeof schema !== "object") return schema;
  const compacted = {};
  for (const [key, value] of Object.entries(schema)) {
    if (["description", "title", "default", "examples"].includes(key)) continue;
    compacted[key] = compactSchema(value);
  }
  return compacted;
}

function compactClineTool(tool) {
  if (!tool || typeof tool !== "object") return tool;
  const functionDefinition = tool.function;
  if (!functionDefinition || typeof functionDefinition !== "object") return tool;
  const compacted = {
    ...tool,
    function: {
      ...functionDefinition,
      parameters: compactSchema(functionDefinition.parameters),
    },
  };
  const shortDescriptions = {
    read_files: "Read files by absolute path.",
    search_codebase: "Search the codebase with regex queries.",
    run_commands: "Run non-interactive PowerShell commands on Windows. Use New-Item -ItemType File -Force -Path <path> to create a file; do not use -LiteralPath with New-Item. Avoid multiline Set-Content and backtick-escaped source; use the editor tool for file contents. Never use cmd.exe-only commands such as `type nul > file`.",
    fetch_web_content: "Fetch and analyze web URLs.",
    editor: "Edit or create a text file. For a missing file, use new_text and omit insert_line. For an existing empty file, use insert_line: 1. Never send insert_line: -1; never use old_text for a missing file.",
  };
  if (shortDescriptions[functionDefinition.name]) {
    compacted.function.description = shortDescriptions[functionDefinition.name];
  } else {
    delete compacted.function.description;
  }
  return compacted;
}

async function record(event) {
  if (!LOG_DIR) return;
  try {
    await mkdir(LOG_DIR, { recursive: true });
    await appendFile(`${LOG_DIR}/requests.jsonl`, `${JSON.stringify({
      timestamp: new Date().toISOString(),
      ...event,
    })}\n`, "utf8");
  } catch {
    // Logging must never break the inference path.
  }
}

async function requestRestart(reason) {
  if (!CONTROL_FILE) return;
  lastRestartRequest = { reason, timestamp: new Date().toISOString() };
  try {
    await writeFile(CONTROL_FILE, JSON.stringify({
      reason,
      timestamp: new Date().toISOString(),
    }), "utf8");
  } catch (error) {
    await record({ type: "restart_flag_error", message: String(error) });
  }
}

function readBody(request) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    request.on("data", (chunk) => {
      size += chunk.length;
      if (size > MAX_BODY) {
        reject(new Error("request body too large"));
        request.destroy();
        return;
      }
      chunks.push(chunk);
    });
    request.on("end", () => resolve(Buffer.concat(chunks)));
    request.on("error", reject);
  });
}

function copyResponseHeaders(response) {
  const headers = {};
  for (const [key, value] of response.headers) {
    if (key === "transfer-encoding" || key === "content-encoding" || key === "connection") continue;
    headers[key] = value;
  }
  headers["access-control-allow-origin"] = "*";
  headers["access-control-allow-headers"] = "Content-Type, Authorization, X-Request-ID";
  return headers;
}

async function writeResponseBody(response, nodeResponse, controller, requestId) {
  if (!response.body) {
    nodeResponse.end();
    return;
  }
  const reader = response.body.getReader();
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      if (!nodeResponse.write(Buffer.from(value))) await once(nodeResponse, "drain");
    }
    nodeResponse.end();
  } catch (error) {
    controller.abort();
    if (!nodeResponse.writableEnded) nodeResponse.end();
    await record({ type: "upstream_stream_error", request_id: requestId, message: String(error) });
  }
}

const server = http.createServer(async (request, response) => {
  const requestId = request.headers["x-request-id"] || randomUUID();
  const url = new URL(request.url || "/", `http://${request.headers.host || `${HOST}:${PORT}`}`);

  if (request.method === "OPTIONS") {
    response.writeHead(204, {
      "access-control-allow-origin": "*",
      "access-control-allow-methods": "GET,POST,OPTIONS",
      "access-control-allow-headers": "Content-Type, Authorization, X-Request-ID",
    });
    response.end();
    return;
  }

  // GET /llamadock/status — observability endpoint (§2 of harness design)
  if (request.method === "GET" && url.pathname === "/llamadock/status") {
    const upstreamHealth = await checkUpstreamHealth();
    const status = {
      gateway: {
        started_at: GATEWAY_STARTED_AT,
        uptime_seconds: Math.floor((Date.now() - new Date(GATEWAY_STARTED_AT).getTime()) / 1000),
        host: HOST,
        port: PORT,
        upstream: UPSTREAM,
      },
      active_requests: activeRequestCount,
      recent_results: recentResults.slice(-10),
      restart_request: lastRestartRequest,
      possible_retry_loops: possibleRetryLoops.slice(-5),
      upstream_health: upstreamHealth,
    };
    response.writeHead(200, {
      "content-type": "application/json; charset=utf-8",
      "access-control-allow-origin": "*",
    });
    response.end(JSON.stringify(status));
    return;
  }

  const started = Date.now();
  const inference = isInferencePath(url.pathname);
  activeRequestCount += 1;
  let requestFingerprint = "";
  const controller = new AbortController();
  let completed = false;
  let disconnected = false;
  let responseBodyDone = false;
  let requestMeta = {};
  const abortUpstream = () => {
    if (completed || disconnected || responseBodyDone || response.writableEnded || response.writableFinished) return;
    disconnected = true;
    controller.abort();
    if (inference) void requestRestart("client_disconnect");
    void record({ type: "client_disconnect", request_id: requestId, path: url.pathname, ...requestMeta });
  };
  request.on("aborted", abortUpstream);
  response.on("close", abortUpstream);

  try {
    let body = ["GET", "HEAD"].includes(request.method || "") ? undefined : await readBody(request);
    if (body && inference) {
      try {
        const parsed = JSON.parse(body.toString("utf8"));
        const originalTools = Array.isArray(parsed.tools) ? parsed.tools : [];
        const originalToolNames = originalTools.map((tool) => tool?.function?.name || tool?.name || "unknown");
        const clineToolSet = isClineToolSet(originalToolNames);
        const requestedMaxTokens = Number(parsed.max_tokens ?? parsed.max_completion_tokens);
        let clineMaxTokensApplied = null;
        if (clineToolSet && Number.isFinite(CLINE_MAX_TOKENS) && CLINE_MAX_TOKENS > 0 &&
            (!Number.isFinite(requestedMaxTokens) || requestedMaxTokens > CLINE_MAX_TOKENS)) {
          parsed.max_tokens = Math.floor(CLINE_MAX_TOKENS);
          delete parsed.max_completion_tokens;
          clineMaxTokensApplied = Math.floor(CLINE_MAX_TOKENS);
        }
        const optionalClineTools = clineToolSet
          ? originalTools.filter((tool) => isOptionalClineTool(tool?.function?.name || tool?.name || ""))
          : [];
        if (optionalClineTools.length > 0) {
          parsed.tools = originalTools.filter((tool) => !isOptionalClineTool(tool?.function?.name || tool?.name || ""));
        }
        const toolsBeforeCompaction = Array.isArray(parsed.tools) ? parsed.tools : [];
        const compactClineTools = clineToolSet && process.env.LLAMADOCK_CLINE_COMPACT_TOOLS !== "0";
        if (compactClineTools) parsed.tools = toolsBeforeCompaction.map(compactClineTool);
        body = Buffer.from(JSON.stringify(parsed), "utf8");
        // Compute SHA-256 fingerprint of the request body (§2 of harness design)
        requestFingerprint = computeFingerprint(body);
        trackFingerprint(requestFingerprint);
        requestMeta = {
          request_bytes: body.length,
          model: parsed.model,
          message_count: Array.isArray(parsed.messages) ? parsed.messages.length : 0,
          tool_count: Array.isArray(parsed.tools) ? parsed.tools.length : 0,
          tool_names: Array.isArray(parsed.tools)
            ? parsed.tools.map((tool) => tool?.function?.name || tool?.name || "unknown")
            : [],
          tool_bytes: Array.isArray(parsed.tools) ? Buffer.byteLength(JSON.stringify(parsed.tools), "utf8") : 0,
          original_tool_bytes: Buffer.byteLength(JSON.stringify(originalTools), "utf8"),
          pruned_optional_tool_count: optionalClineTools.length,
          pruned_optional_tool_names: optionalClineTools.map((tool) => tool?.function?.name || tool?.name || "unknown"),
          original_tool_count: originalTools.length,
          original_tool_names: originalToolNames,
          compacted_cline_tools: compactClineTools,
          cline_max_tokens_requested: Number.isFinite(requestedMaxTokens) ? requestedMaxTokens : null,
          cline_max_tokens_applied: clineMaxTokensApplied,
          system_chars: Array.isArray(parsed.messages)
            ? parsed.messages.filter((message) => message?.role === "system").reduce((total, message) => total + String(message.content || "").length, 0)
            : 0,
        };
      } catch {
        requestMeta = { request_bytes: body.length, json_parse: "failed" };
      }
    }
    const headers = {};
    for (const [key, value] of Object.entries(request.headers)) {
      // Do not forward hop-by-hop framing or Expect: 100-continue.  The
      // latter is emitted by .NET for larger JSON bodies and undici can fail
      // before it even opens the upstream request when it is copied through.
      if (["host", "content-length", "connection", "transfer-encoding", "expect"].includes(key)) continue;
      if (typeof value === "string") headers[key] = value;
    }
    headers["x-request-id"] = requestId;
    const upstreamResponse = await fetch(`${UPSTREAM}${url.pathname}${url.search}`, {
      method: request.method,
      headers,
      body,
      signal: controller.signal,
    });
    response.writeHead(upstreamResponse.status, copyResponseHeaders(upstreamResponse));
    await writeResponseBody(upstreamResponse, response, controller, requestId);
    responseBodyDone = true;
    completed = true;
    activeRequestCount = Math.max(0, activeRequestCount - 1);
    // #9 - upstream HTTP errors must be ok=false
    const upstreamOk = upstreamResponse.status >= 200 && upstreamResponse.status < 300;
    recordResult(upstreamOk, upstreamResponse.status, requestFingerprint);
    // #9 - possible_retry_loop written to structured request log without body content
    await record({
      type: "request_complete",
      request_id: requestId,
      path: url.pathname,
      status: upstreamResponse.status,
      ok: upstreamOk,
      elapsed_ms: Date.now() - started,
      fingerprint: requestFingerprint,
      possible_retry_loop: possibleRetryLoops.some((item) => item.fingerprint === requestFingerprint),
      ...requestMeta,
    });
  } catch (error) {
    responseBodyDone = true;
    completed = true;
    activeRequestCount = Math.max(0, activeRequestCount - 1);
    const isAbort = error?.name === "AbortError";
    recordResult(false, isAbort ? 499 : 502, requestFingerprint);
    // When the upstream llama-server has crashed (TypeError: fetch failed,
    // ECONNREFUSED, etc.) the gateway still owns port 8090 and every retry
    // would replay the same 502. Ask the supervisor once to recycle the
    // upstream so the next client request can succeed. This does not change
    // the 502 returned to the current client; it just prevents a ghost
    // gateway from persisting past one request.
    if (!isAbort) {
      const message = String(error?.message || error || "");
      const looksUnreachable =
        message.includes("fetch failed") ||
        message.includes("ECONNREFUSED") ||
        message.includes("ECONNRESET") ||
        message.includes("fetch failed") ||
        error?.cause?.code === "ECONNREFUSED" ||
        error?.cause?.code === "ECONNRESET";
      if (looksUnreachable) {
        void requestRestart("upstream_unreachable");
      }
    }
    if (!response.headersSent) {
      response.writeHead(isAbort ? 499 : 502, {
        "content-type": "application/json; charset=utf-8",
        "access-control-allow-origin": "*",
      });
      response.end(JSON.stringify({ error: {
        type: "llamadock_gateway_error",
        message: isAbort ? "Client disconnected while inference was running." : String(error),
        request_id: requestId,
      }}));
    } else if (!response.writableEnded) {
      response.end();
    }
    await record({ type: "request_error", request_id: requestId, path: url.pathname, message: String(error), ...requestMeta });
  } finally {
    if (!completed) activeRequestCount = Math.max(0, activeRequestCount - 1);
    request.off("aborted", abortUpstream);
    response.off("close", abortUpstream);
  }
});

server.listen(PORT, HOST, () => {
  console.error(`LlamaDock gateway listening at http://${HOST}:${PORT} -> ${UPSTREAM}`);
});
