#!/usr/bin/env node
// LlamaDock Web GUI server
// ---------------------------------------------------------------------------
// Zero-dependency Node server (node:http + node:fs only).
//
// - Serves the static GUI from ./web-ui (single-page, no build step).
// - Exposes the Phase 2/3/4 REST API:
//     GET  /api/health           -> { ok: true }
//     GET  /api/bootstrap        -> schema + presets + model notes + per-model memory
//     GET  /api/params           -> same core payload as /api/bootstrap
//     POST /api/params           -> persist per-model parameter memory
//                                    (config/models-config.json, gitignored)
//     POST /api/launch           -> resolve params -> build args -> spawn llama-server
//                                    (Windows: real engine via Phase 1 core;
//                                     elsewhere: web-ui/mock-llama-server.mjs so the
//                                     whole launch -> health -> benchmark loop runs)
//     POST /api/stop             -> stop the running server
//     POST /api/benchmark        -> N chat-completions, measure tok/s, accumulate
//                                    into config/run-results.json (Phase 4)
//     GET  /api/results          -> qualification summary of run-results.json
//     POST /api/connect          -> launch a workspace client (Cline / OpenCode /
//                                    OpenClaude / WebUI / DeepResearch /
//                                    LlamaAgent / ComfyUI). Windows: detached spawn
//                                    of the real launcher; elsewhere: simulated
//                                    with the exact Windows command.
//     GET  /api/status           -> server + platform + runtime + clients state
//     GET  /api/clients/health   -> live probe of WebUI / DeepResearch /
//                                    ComfyUI (own-server clients, env-port aware)
//
// The real machine binds to 127.0.0.1 per the design doc; the sandbox preview
// overrides HOST/PORT (0.0.0.0 + the injected port) from the environment.
// ---------------------------------------------------------------------------

import http from "node:http";
import { createReadStream } from "node:fs";
import { readFile, writeFile, rename, mkdir } from "node:fs/promises";
import { fileURLToPath, pathToFileURL } from "node:url";
import { dirname, join, normalize, extname, resolve, sep } from "node:path";

import { resolveParams, buildArgs } from "./arg-builder.js";
import { createLaunchManager, DEFAULT_UPSTREAM_PORT } from "./launch-manager.js";
import { addRun, loadResults, summarize } from "./results-store.js";
import { createClientManager, CLIENT_BASE_URL } from "./client-manager.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(__dirname, "..");
const WEB_ROOT = join(ROOT, "web-ui");
const CONFIG_DIR = join(ROOT, "config");
const MODELS_CONFIG_PATH = join(CONFIG_DIR, "models-config.json");
const RESULTS_PATH = join(CONFIG_DIR, "run-results.json");

// Single runtime launcher shared by every request (state machine owns the
// child process + health polling). Upstream port overridable for sandboxes
// where 8080 is already taken.
const launchManager = createLaunchManager({ upstreamPort: DEFAULT_UPSTREAM_PORT });

// Workspace clients are launched against a *running* server; the manager asks
// the launch manager for the current runtime state to enforce that contract.
const clientManager = createClientManager({ upstream: () => launchManager.summary() });

const HOST = process.env.HOST || process.env.MCP_HOST || "127.0.0.1";
const PORT = Number(process.env.PORT || process.env.MCP_PORT || 3000);

const MIME = {
  ".html": "text/html; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".ico": "image/x-icon",
  ".txt": "text/plain; charset=utf-8",
  ".map": "application/json",
  ".woff2": "font/woff2",
};

async function readJsonSafe(path) {
  try {
    return JSON.parse(await readFile(path, "utf8"));
  } catch {
    return null;
  }
}

async function loadModelsConfig() {
  return (await readJsonSafe(MODELS_CONFIG_PATH)) || { _profiles: [], models: {} };
}

async function saveModelsConfig(patch) {
  const current = await loadModelsConfig();
  const models = current.models || {};
  if (patch.model && patch.overrides) {
    models[patch.model] = { ...(models[patch.model] || {}), ...patch.overrides };
  }
  const next = { ...current, models, updated: new Date().toISOString() };
  await mkdir(CONFIG_DIR, { recursive: true });
  const tmp = `${MODELS_CONFIG_PATH}.tmp`;
  await writeFile(tmp, `${JSON.stringify(next, null, 2)}\n`, "utf8");
  await rename(tmp, MODELS_CONFIG_PATH);
  return next;
}

// Keep only per_model:true params in per-model memory, so the saved file stays
// a lean overlay (schema defaults + memory presets provide the rest).
function filterPerModelParams(schema, overrides) {
  const perModelIds = new Set(
    (schema?.groups || []).flatMap((g) =>
      (g.params || []).filter((p) => p.per_model).map((p) => p.id),
    ),
  );
  const out = {};
  for (const [id, value] of Object.entries(overrides || {})) {
    if (perModelIds.has(id)) out[id] = value;
  }
  return out;
}

async function readBootstrapPayload() {
  const [schema, presets, modelNotes] = await Promise.all([
    readJsonSafe(join(ROOT, "config", "params-schema.json")),
    readJsonSafe(join(ROOT, "config", "memory-presets.json")),
    readJsonSafe(join(ROOT, "model-notes.json")),
  ]);
  const modelsConfig = await loadModelsConfig();
  return { schema, presets, modelNotes, modelsConfig };
}

function sendJson(res, status, value) {
  res.writeHead(status, { "Content-Type": "application/json; charset=utf-8" });
  res.end(JSON.stringify(value, null, 2));
}

function sendStatic(res, pathname) {
  const rel = normalize(pathname).replace(/^([/\\])+/, "");
  let filePath = resolve(WEB_ROOT, rel || "index.html");
  // Path-boundary check (not a bare prefix): WEB_ROOT itself is a directory
  // and must never be served, and a sibling like "web-ui2/" must not pass a
  // simple startsWith(WEB_ROOT) comparison.
  if (filePath !== WEB_ROOT && filePath.startsWith(WEB_ROOT + sep)) {
    if (pathname === "/" || pathname === "/index.html") filePath = join(WEB_ROOT, "index.html");
  } else {
    sendJson(res, 403, { error: "forbidden" });
    return;
  }
  const stream = createReadStream(filePath);
  stream.on("error", () => {
    sendJson(res, 404, { error: "not_found", message: `${pathname} is not served by the LlamaDock GUI` });
  });
  stream.on("open", () => {
    res.writeHead(200, { "Content-Type": MIME[extname(filePath)] || "application/octet-stream" });
    stream.pipe(res);
  });
}

async function readJsonBody(req) {
  return new Promise((resolveBody, reject) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => {
      const raw = Buffer.concat(chunks).toString("utf8");
      if (!raw) {
        resolveBody({});
        return;
      }
      try {
        resolveBody(JSON.parse(raw));
      } catch {
        reject(new Error("Invalid JSON body"));
      }
    });
    req.on("error", reject);
  });
}

export function createAppServer() {
  return http.createServer(async (req, res) => {
    const url = new URL(req.url || "/", `http://${req.headers.host || `${HOST}:${PORT}`}`);
    const { pathname } = url;

    if (pathname === "/api/health") {
      sendJson(res, 200, { ok: true, name: "llamadock-web-ui", version: "1.0.0" });
      return;
    }

    if (pathname === "/api/bootstrap" || pathname === "/api/params") {
      if (req.method === "GET") {
        const payload = await readBootstrapPayload();
        sendJson(res, 200, { ...payload, updated: new Date().toISOString() });
        return;
      }
      if (req.method === "POST") {
        try {
          const body = await readJsonBody(req);
          const schema = (await readBootstrapPayload()).schema;
          const clean = filterPerModelParams(schema, body.overrides);
          const next = await saveModelsConfig({ model: body.model, overrides: clean });
          sendJson(res, 200, { ok: true, saved: clean, modelsConfig: next });
        } catch (error) {
          sendJson(res, 400, { ok: false, error: errorMessage(error) });
        }
        return;
      }
      sendJson(res, 405, { ok: false, error: "Method not allowed" });
      return;
    }

    if (pathname === "/api/launch") {
      if (req.method === "POST") {
        try {
          const body = await readJsonBody(req);
          const model = String(body.model || "").trim();
          if (!model) {
            sendJson(res, 400, { ok: false, error: "model_required", message: "起動するモデル名を指定してください。" });
            return;
          }

          // Resolve the effective parameter set exactly like the GUI preview:
          // session overrides -> per-model memory -> _profiles pattern -> default.
          const payload = await readBootstrapPayload();
          const resolved = resolveParams(payload.schema, {
            modelName: model,
            modelsConfig: payload.modelsConfig,
            overrides: body.params || {},
          });
          const engine = String(body.engine || resolved.engine || "").trim() || null;
          const port = Number(body.port || DEFAULT_UPSTREAM_PORT);
          const { args, env } = buildArgs(payload.schema, resolved, {
            model: String(body.modelPath || model), // Phase 1 core supplies the real GGUF path on Windows
            host: "127.0.0.1",
            port,
          });

          const result = await launchManager.launch({
            model,
            engine,
            args,
            env,
            port,
            resolvedParams: resolved,
          });
          sendJson(res, result.ok ? 200 : 409, result);
        } catch (error) {
          sendJson(res, 400, { ok: false, error: "launch_request_failed", message: errorMessage(error) });
        }
        return;
      }
      sendJson(res, 405, { ok: false, error: "Method not allowed" });
      return;
    }

    if (pathname === "/api/stop") {
      if (req.method === "POST") {
        const result = await launchManager.stop();
        sendJson(res, result.ok ? 200 : 409, result);
        return;
      }
      sendJson(res, 405, { ok: false, error: "Method not allowed" });
      return;
    }

    if (pathname === "/api/benchmark") {
      if (req.method === "POST") {
        try {
          const body = await readJsonBody(req);
          const runs = clampInt(body.runs, 1, 10, 3);
          const maxTokens = clampInt(body.maxTokens, 16, 512, 96);
          const result = await launchManager.benchmark({ runs, maxTokens });
          if (result.ok && result.runs) {
            // Phase 4: accumulate every measured run into run-results.json.
            const runtime = launchManager.summary();
            let recorded = 0;
            for (const run of result.runs) {
              await addRun(RESULTS_PATH, {
                model: runtime.model,
                engine: runtime.engine || null,
                params: runtime.resolvedParams || {},
                ...run,
              });
              recorded += 1;
            }
            result.recorded = recorded;
            result.simulated = runtime.simulated;
            result.results = summarize(await loadResults(RESULTS_PATH));
          }
          sendJson(res, 200, result);
        } catch (error) {
          sendJson(res, 400, { ok: false, error: "benchmark_failed", message: errorMessage(error) });
        }
        return;
      }
      sendJson(res, 405, { ok: false, error: "Method not allowed" });
      return;
    }

    if (pathname === "/api/results") {
      if (req.method === "GET") {
        sendJson(res, 200, summarize(await loadResults(RESULTS_PATH)));
        return;
      }
      sendJson(res, 405, { ok: false, error: "Method not allowed" });
      return;
    }

    if (pathname === "/api/connect") {
      // Phase 2 contract: launch a workspace client against the running server.
      //   body: { client, model?, workspace?, harness?, prompt? }
      // Windows spawns the real launcher (detached); other platforms validate
      // the full request and return the exact command Windows would run.
      if (req.method === "POST") {
        try {
          const body = await readJsonBody(req);
          const result = await clientManager.connect({
            client: String(body.client || ""),
            model: body.model ? String(body.model) : null,
            workspace: body.workspace ? String(body.workspace) : null,
            harness: body.harness === true,
            prompt: body.prompt ? String(body.prompt) : "",
          });
          const status = result.ok ? 200 : result.error === "unknown_client" ? 400 : 409;
          sendJson(res, status, result);
        } catch (error) {
          sendJson(res, 400, { ok: false, error: "connect_failed", message: errorMessage(error) });
        }
        return;
      }
      sendJson(res, 405, { ok: false, error: "Method not allowed" });
      return;
    }

    if (pathname === "/api/clients/health") {
      // Live probe of every client that runs its own HTTP server
      // (WebUI :8000 / DeepResearch :7000 / ComfyUI :8188 + LLAMADOCK_<ID>_PORT
      // overrides). Separate from /api/status so the GUI can poll it less
      // often without adding latency to the 3s runtime status poll.
      if (req.method === "GET") {
        const clients = await clientManager.checkHealth();
        sendJson(res, 200, { ok: true, checkedAt: new Date().toISOString(), clients });
        return;
      }
      sendJson(res, 405, { ok: false, error: "Method not allowed" });
      return;
    }

    if (pathname === "/api/status") {
      sendJson(res, 200, {
        ok: true,
        server: { platform: process.platform, node: process.version },
        launchable: process.platform === "win32",
        clientEndpoint: CLIENT_BASE_URL,
        upstreamEndpoint: `http://127.0.0.1:${launchManager.summary().port}`,
        runtime: launchManager.summary(),
        clients: clientManager.summary(),
      });
      return;
    }

    if (pathname.startsWith("/api/")) {
      sendJson(res, 404, { ok: false, error: "unknown_api", message: pathname });
      return;
    }

    sendStatic(res, pathname);
  });
}

export async function startServer({ host = HOST, port = PORT } = {}) {
  const server = createAppServer();
  await new Promise((resolveListen, reject) => {
    server.once("error", reject);
    server.listen(port, host, resolveListen);
  });
  console.error(`LlamaDock Web GUI listening on http://${host}:${port}`);
  return server;
}

const isMain =
  process.argv[1] &&
  import.meta.url === pathToFileURL(resolve(process.argv[1])).href;

if (isMain) {
  startServer().catch((error) => {
    console.error(`Failed to start LlamaDock Web GUI: ${errorMessage(error)}`);
    process.exit(1);
  });
}

function errorMessage(error) {
  return error instanceof Error ? error.message : String(error);
}

function clampInt(value, min, max, fallback) {
  const n = Number(value);
  if (!Number.isFinite(n)) return fallback;
  return Math.min(max, Math.max(min, Math.round(n)));
}
