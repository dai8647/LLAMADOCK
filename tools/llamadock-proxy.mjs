#!/usr/bin/env node
/*
 * Small OpenAI-compatible gateway used by LlamaDock clients.
 *
 * It keeps UTF-8 and streaming behavior identical for Cline, OpenCode,
 * Computer, and the research clients.  If a client disconnects
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
// Throttle upstream_unreachable restart requests. llama-server needs minutes
// to load a 35B MTP model with a 64K context; during that window every client
// request fails with "fetch failed" and the old code asked the supervisor to
// recycle the server each time, killing the freshly-started load and looping
// forever. One request per 60s caps the damage; the supervisor also ignores
// restart flags while the server is still loading.
let lastUpstreamRestartRequestAt = 0;
const UPSTREAM_RESTART_MIN_INTERVAL_MS = 60_000;

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
// Thinking/reasoning models also burn this budget before the answer, so the
// default is generous. Override with --cline-max-tokens <N> or the
// LLAMADOCK_CLINE_MAX_TOKENS environment variable (CLI argument wins).
const CLINE_MAX_TOKENS = Number(option("--cline-max-tokens", process.env.LLAMADOCK_CLINE_MAX_TOKENS || "16384"));

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

// === COMPACTION FALLBACK: remove this whole section when DSH ships native compaction (env LLAMADOCK_COMPACTION=0 disables it) ===
// Everything the fallback needs lives between these two markers: the kill switch,
// the refusal matcher, the token estimator, the elision helper, the compaction
// entry point, and the hook that the request path calls once.  Removing this
// block plus that single call site restores the exact pre-compaction behavior.
//
// Trigger : upstream HTTP 400 whose message says the prompt leaves no room.
// Action  : keep the leading system messages and the final user turn, elide
//           oversized tool results, drop the oldest middle messages until the
//           estimate fits (ctx - max_tokens - 512), then retry exactly once.
// Honesty : every other status/body is forwarded untouched, and a second 400
//           from the retry is forwarded untouched as well.
const COMPACTION_ENV_FLAG = "LLAMADOCK_COMPACTION";          // "0" disables the feature entirely
const COMPACTION_MARGIN_TOKENS = 512;                       // safety margin left for the template
const COMPACTION_DEFAULT_MAX_TOKENS = 4096;                 // used when the request has no max_tokens
const COMPACTION_ELIDE_ABOVE_CHARS = 32 * 1024;             // Unsloth's tool-result budget
const COMPACTION_ELIDE_HEAD_CHARS = 2000;
const COMPACTION_ELIDE_TAIL_CHARS = 2000;
const COMPACTION_ELIDE_MARKER = "...[tool result elided]...";
// Strata 0.1.40 answers: prompt (82668 tokens) leaves no room to answer in the
// context (65536); requests are never truncated.  The context parentheses are
// matched optionally so an engine that drops them still triggers the fallback.
const COMPACTION_NO_ROOM_RE = /prompt \((\d+) tokens\) leaves no room to answer in the context \(?(\d+)\)?/;

function compactionEnabled() {
  return process.env[COMPACTION_ENV_FLAG] !== "0";
}

// Rough token estimate: JSON-stringified chars / 4.  Good enough — the retry's
// own 400 is the ground truth, not this number.
function estimateTokens(value) {
  try {
    return Math.ceil(JSON.stringify(value ?? null).length / 4);
  } catch {
    return 0;
  }
}

function messageContentChars(message) {
  if (typeof message?.content === "string") return message.content.length;
  if (Array.isArray(message?.content)) {
    return message.content.reduce(
      (total, part) => total + (typeof part?.text === "string" ? part.text.length : JSON.stringify(part ?? null).length),
      0,
    );
  }
  if (message?.content == null) return 0;
  try {
    return JSON.stringify(message.content).length;
  } catch {
    return 0;
  }
}

// Oversized content is kept but shortened to head + marker + tail.  Pass
// threshold 0 to elide unconditionally (used only for a final user turn that
// cannot fit the budget even by itself).
function elideOversizedContent(message, threshold = COMPACTION_ELIDE_ABOVE_CHARS) {
  if (!message || typeof message !== "object") return message;
  if (messageContentChars(message) <= threshold) return message;
  if (typeof message.content === "string") {
    return {
      ...message,
      content: `${message.content.slice(0, COMPACTION_ELIDE_HEAD_CHARS)}${COMPACTION_ELIDE_MARKER}${message.content.slice(-COMPACTION_ELIDE_TAIL_CHARS)}`,
    };
  }
  if (Array.isArray(message.content)) {
    let changed = false;
    const content = message.content.map((part) => {
      if (typeof part?.text !== "string" || part.text.length <= threshold) return part;
      changed = true;
      return {
        ...part,
        text: `${part.text.slice(0, COMPACTION_ELIDE_HEAD_CHARS)}${COMPACTION_ELIDE_MARKER}${part.text.slice(-COMPACTION_ELIDE_TAIL_CHARS)}`,
      };
    });
    return changed ? { ...message, content } : message;
  }
  return message;
}

// Returns { promptTokens, contextTokens } for the engine's context refusal, or
// null for any other 400 (those must be forwarded untouched).
function matchNoRoomRefusal(upstreamText) {
  let payload = null;
  try {
    payload = JSON.parse(upstreamText);
  } catch {
    return null;
  }
  const message = typeof payload?.error?.message === "string"
    ? payload.error.message
    : typeof payload?.message === "string"
      ? payload.message
      : "";
  const match = COMPACTION_NO_ROOM_RE.exec(message);
  if (!match) return null;
  return { promptTokens: Number(match[1]), contextTokens: Number(match[2]) };
}

// Compaction entry point: turns the upstream refusal + the request body into a
// smaller body, or null when there is nothing worth a retry.
function maybeCompactForContext(refusal, requestBody) {
  const messages = Array.isArray(requestBody?.messages) ? requestBody.messages : [];
  if (messages.length === 0) return null;
  const requestedMax = Number(requestBody.max_tokens ?? requestBody.max_completion_tokens);
  const maxTokens = Number.isFinite(requestedMax) && requestedMax > 0 ? requestedMax : COMPACTION_DEFAULT_MAX_TOKENS;
  const budget = refusal.contextTokens - maxTokens - COMPACTION_MARGIN_TOKENS;
  if (budget <= 0) return null;

  let systemCount = 0;
  while (systemCount < messages.length && ["system", "developer"].includes(messages[systemCount]?.role)) {
    systemCount += 1;
  }
  let finalUserIndex = -1;
  for (let index = messages.length - 1; index >= systemCount; index -= 1) {
    if (messages[index]?.role === "user") {
      finalUserIndex = index;
      break;
    }
  }
  if (systemCount === 0 && finalUserIndex < 0) return null;

  const prepared = messages.map((message) => elideOversizedContent(message));
  const keep = new Set();
  let used = 0;
  for (let index = 0; index < systemCount; index += 1) {
    keep.add(index);
    used += estimateTokens(prepared[index]);
  }

  // The current turn is never dropped (Unsloth's rule).  It is only elided when
  // it alone is bigger than the whole budget, because keeping it verbatim could
  // not possibly fit and the retry would be a guaranteed second 400.
  let trimmedFinalUser = false;
  if (finalUserIndex >= 0) {
    let size = estimateTokens(prepared[finalUserIndex]);
    if (used + size > budget) {
      prepared[finalUserIndex] = elideOversizedContent(messages[finalUserIndex], 0);
      trimmedFinalUser = true;
      size = estimateTokens(prepared[finalUserIndex]);
    }
    keep.add(finalUserIndex);
    used += size;
  }

  // Unsloth-style oldest-drop: walk the rest newest -> oldest and keep whatever
  // still fits, skipping (not stopping at) the ones that do not.
  for (let index = messages.length - 1; index >= systemCount; index -= 1) {
    if (index === finalUserIndex) continue;
    const size = estimateTokens(prepared[index]);
    if (used + size > budget) continue;
    keep.add(index);
    used += size;
  }

  // Oldest-drop can leave a tool result whose assistant tool_call is gone; such
  // orphans are dropped so the chat template never sees an unmatched response.
  for (let index = messages.length - 1; index >= systemCount; index -= 1) {
    if (messages[index]?.role === "tool" && (index === 0 || !keep.has(index - 1))) keep.delete(index);
  }

  const keptMessages = [...keep].sort((a, b) => a - b).map((index) => prepared[index]);
  const changed = trimmedFinalUser
    || keptMessages.length !== messages.length
    || prepared.some((message, index) => message !== messages[index]);
  if (!changed) return null;

  return {
    body: Buffer.from(JSON.stringify({ ...requestBody, messages: keptMessages }), "utf8"),
    kept: keptMessages.length - systemCount - (finalUserIndex >= 0 ? 1 : 0),
    total: messages.length - systemCount - (finalUserIndex >= 0 ? 1 : 0),
    estimatedTokens: used,
    trimmedFinalUser,
  };
}

// The single hook the request path calls.  Returns the response to forward:
// the original one, or the retry's response when compaction fired.
async function applyContextCompactionFallback(upstreamResponse, call) {
  if (!compactionEnabled()) return upstreamResponse;
  if (call.pathname !== "/v1/chat/completions") return upstreamResponse;
  if (upstreamResponse.status !== 400 || !upstreamResponse.body) return upstreamResponse;

  // The refusal arrives before any stream starts, so buffering is safe.
  const upstreamText = await upstreamResponse.text();
  const headers = new Headers(upstreamResponse.headers);
  headers.delete("content-length");
  const passthrough = new Response(upstreamText, {
    status: upstreamResponse.status,
    statusText: upstreamResponse.statusText,
    headers,
  });

  const refusal = matchNoRoomRefusal(upstreamText);
  if (!refusal) return passthrough;
  let requestBody = null;
  try {
    requestBody = JSON.parse(call.body.toString("utf8"));
  } catch {
    requestBody = null;
  }
  const compacted = requestBody ? maybeCompactForContext(refusal, requestBody) : null;
  if (!compacted) return passthrough;

  const summary = `compaction: prompt ${refusal.promptTokens} > ctx ${refusal.contextTokens}; kept system + newest ${compacted.kept} of ${compacted.total} messages, est ~${compacted.estimatedTokens} tokens; retrying once`;
  console.error(summary);
  await record({
    type: "compaction",
    request_id: call.requestId,
    prompt_tokens: refusal.promptTokens,
    context_tokens: refusal.contextTokens,
    kept_messages: compacted.kept,
    droppable_messages: compacted.total,
    estimated_tokens: compacted.estimatedTokens,
    trimmed_final_user: compacted.trimmedFinalUser,
  });

  try {
    return await fetch(`${UPSTREAM}${call.pathname}${call.search}`, {
      method: call.method,
      headers: call.headers,
      body: compacted.body,
      signal: call.signal,
    });
  } catch (error) {
    // Client went away: keep the handler's existing 499 path.  Any other failure
    // means the retry never reached the engine, so forward the original 400.
    if (call.signal?.aborted || error?.name === "AbortError") throw error;
    return passthrough;
  }
}
// === END COMPACTION FALLBACK ===

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
    // Aborting the upstream request makes llama-server cancel the in-flight
    // generation and free the slot, so a client disconnect (e.g. pressing ESC
    // in Cline) must NOT recycle the whole server. The old behavior restarted
    // the model on every cancel. A genuinely dead server is still recovered via
    // the throttled upstream_unreachable path below.
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
    let upstreamResponse = await fetch(`${UPSTREAM}${url.pathname}${url.search}`, {
      method: request.method,
      headers,
      body,
      signal: controller.signal,
    });
    // COMPACTION FALLBACK: this is the section's one call site. Delete this line
    // (and change `let upstreamResponse` back to `const`) to remove the feature.
    upstreamResponse = await applyContextCompactionFallback(upstreamResponse, {
      pathname: url.pathname,
      search: url.search,
      method: request.method,
      headers,
      body,
      signal: controller.signal,
      requestId,
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
        const now = Date.now();
        if (now - lastUpstreamRestartRequestAt >= UPSTREAM_RESTART_MIN_INTERVAL_MS) {
          lastUpstreamRestartRequestAt = now;
          void requestRestart("upstream_unreachable");
        }
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
