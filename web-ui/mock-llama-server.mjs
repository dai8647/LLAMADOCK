#!/usr/bin/env node
// LlamaDock — simulated llama-server (OpenAI-compatible).
// ---------------------------------------------------------------------------
// Used by the Web GUI's launch simulation on non-Windows platforms so the whole
// launch -> health poll -> benchmark -> run-results loop is exercised for real
// (spawn, PID, ready-wait, stop, tok/s measurement). The real launcher
// (Windows) runs the actual llama.cpp fork binary instead of this stand-in.
//
// Env:
//   LLAMADOCK_MOCK_HOST  bind host (default 127.0.0.1)
//   LLAMADOCK_MOCK_PORT  bind port (default 8080)
//   LLAMADOCK_MOCK_MODEL model id reported to clients (default mock-model.gguf)
//   LLAMADOCK_MOCK_TPS   base tokens/second (default 25)
//   LLAMADOCK_MOCK_CTX   context window reported via /health (default 32768)
// ---------------------------------------------------------------------------

import http from "node:http";

const HOST = process.env.LLAMADOCK_MOCK_HOST || "127.0.0.1";
const PORT = Number(process.env.LLAMADOCK_MOCK_PORT || 8080);
const MODEL = process.env.LLAMADOCK_MOCK_MODEL || "mock-model.gguf";
const BASE_TPS = Number(process.env.LLAMADOCK_MOCK_TPS || 25);
const N_CTX = Number(process.env.LLAMADOCK_MOCK_CTX || 32768);

function hash(str) {
  let h = 0;
  for (let i = 0; i < str.length; i += 1) h = (Math.imul(h, 31) + str.charCodeAt(i)) | 0;
  return Math.abs(h);
}

// Stable per-model throughput with a small time-window jitter so accumulated
// benchmark runs differ a little (like real hardware variance).
function tps() {
  const jitter = 0.94 + (hash(`${MODEL}:${Math.floor(Date.now() / 30000)}`) % 120) / 1000;
  return Math.round(BASE_TPS * jitter * 10) / 10;
}

function estimatePromptTokens(text) {
  return Math.max(1, Math.ceil(String(text || "").length / 3.4));
}

function sendJson(res, status, value) {
  res.writeHead(status, { "Content-Type": "application/json; charset=utf-8" });
  res.end(JSON.stringify(value));
}

function readJsonBody(req) {
  return new Promise((resolve) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => {
      try {
        resolve(JSON.parse(Buffer.concat(chunks).toString("utf8") || "{}"));
      } catch {
        resolve({});
      }
    });
    req.on("error", () => resolve({}));
  });
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url || "/", `http://${HOST}:${PORT}`);
  const { pathname } = url;
  const body = await readJsonBody(req);

  if (pathname === "/health") {
    sendJson(res, 200, {
      status: "ok",
      model: MODEL,
      n_ctx: N_CTX,
      tokens_per_second: tps(),
      slots: { idle: true, n_ctx: N_CTX },
      memory: {
        ram_mib: 2048 + (hash(MODEL) % 8192),
        vram_mib: (hash(MODEL) % 2048), // simulated VRAM footprint in MiB
      },
    });
    return;
  }

  if (pathname === "/props") {
    sendJson(res, 200, {
      default_generation_settings: { n_ctx: N_CTX },
      total_slots: 1,
      model_path: MODEL,
    });
    return;
  }

  if (pathname === "/v1/models") {
    sendJson(res, 200, {
      object: "list",
      data: [{ id: MODEL, object: "model", owned_by: "llamadock-mock" }],
    });
    return;
  }

  if (pathname === "/v1/chat/completions" || pathname === "/v1/completions") {
    const prompt = (body.messages || []).map((m) => String(m.content || "")).join("\n");
    const promptTokens = body.prompt_tokens || estimatePromptTokens(prompt);
    const completionTokens = Math.min(Math.max(body.max_tokens || 96, 16), 512);
    const speed = tps();
    // Simulate prompt processing (fast) + generation at the target tok/s so the
    // benchmark's wall-clock measurement lands close to the advertised speed.
    const promptMs = promptTokens * 0.35;
    const genMs = (completionTokens / speed) * 1000;
    await new Promise((r) => setTimeout(r, Math.round(promptMs + genMs)));

    sendJson(res, 200, {
      id: `chatcmpl-mock-${Date.now()}`,
      object: "chat.completion",
      created: Math.floor(Date.now() / 1000),
      model: MODEL,
      choices: [
        {
          index: 0,
          message: {
            role: "assistant",
            content: `[mock] model=${MODEL} generated=${completionTokens} tokens @ ~${speed.toFixed(1)} tok/s`,
          },
          finish_reason: "stop",
        },
      ],
      usage: {
        prompt_tokens: promptTokens,
        completion_tokens: completionTokens,
        total_tokens: promptTokens + completionTokens,
      },
      llamadock: { simulated: true, tokens_per_second: speed },
    });
    return;
  }

  sendJson(res, 404, { error: "not_found", path: pathname });
});

server.listen(PORT, HOST, () => {
  process.stdout.write(`mock llama-server listening on http://${HOST}:${PORT} (model=${MODEL}, ~${BASE_TPS} tok/s, ctx=${N_CTX})\n`);
});
