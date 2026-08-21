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
//                                    WebUI /
//                                    LlamaAgent / ComfyUI). Windows: detached spawn
//                                    of the real launcher; elsewhere: simulated
//                                    with the exact Windows command.
//     GET  /api/status           -> server + platform + runtime + clients state
//     GET  /api/clients/health   -> live probe of WebUI /
//                                    ComfyUI (own-server clients, env-port aware)
//
// The real machine binds to 127.0.0.1 per the design doc; the sandbox preview
// overrides HOST/PORT (0.0.0.0 + the injected port) from the environment.
// ---------------------------------------------------------------------------

import http from "node:http";
import { createReadStream, existsSync, readdirSync } from "node:fs";
import { readFile, writeFile, rename, mkdir, readdir, stat } from "node:fs/promises";
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
// Supervisor control directory (tools/llamadock-server-supervisor.ps1):
// server-arguments.json is re-read on every (re)spawn, and creating
// restart-request.json makes the supervisor restart llama-server only.
const SUPERVISOR_DIR = join(ROOT, "mcp-data", "server-supervisor");
const SERVER_ARGUMENTS_PATH = join(SUPERVISOR_DIR, "server-arguments.json");
const SUPERVISOR_STATUS_PATH = join(SUPERVISOR_DIR, "status.json");
const RESTART_FLAG_PATH = join(SUPERVISOR_DIR, "restart-request.json");

// --- Engine runtime resolution (mirrors select-model.ps1) ---
// Same candidate lists and env overrides as the PowerShell core so the GUI
// launcher picks the exact same binary the CLI flow would pick.
const ENGINE_CANDIDATES = [
  { name: "AtomicBot", env: "LLAMA_TQ3_ATOMICBOT_SERVER", paths: ["C:\\llama-tq3\\build-rocm71\\bin\\llama-server.exe", "C:\\llama-tq3\\build\\bin\\llama-server.exe"] },
  { name: "TurboTan", env: "LLAMA_TQ3_TURBOTAN_SERVER", paths: ["C:\\Users\\dai86\\Downloads\\llama-b10536-rocm\\llama-server.exe", "C:\\llama-tq3-turbotan\\build\\bin\\llama-server.exe"] },
  { name: "OfficialVulkan", env: "LLAMADOCK_OFFICIAL_VULKAN_SERVER", paths: ["C:\\llama.cpp-vulkan\\llama-server.exe", "C:\\Users\\dai86\\Downloads\\llama.cpp-vulkan\\llama-server.exe"] },
  { name: "OfficialHIP", env: "LLAMADOCK_OFFICIAL_HIP_SERVER", paths: ["C:\\llama.cpp-hip\\llama-server.exe", "C:\\Users\\dai86\\Downloads\\llama.cpp-hip\\llama-server.exe"] },
  { name: "OfficialCPU", env: "LLAMADOCK_OFFICIAL_CPU_SERVER", paths: ["C:\\llama.cpp-cpu\\llama-server.exe", "C:\\Users\\dai86\\Downloads\\llama.cpp-cpu\\llama-server.exe"] },
  { name: "PrismBonsai", env: "LLAMA_TQ3_PRISM_BONSAI_SERVER", paths: ["C:\\Users\\dai86\\Downloads\\prism-llama.cpp\\build-rocm71\\bin\\llama-server.exe", "C:\\Users\\dai86\\Downloads\\prism-llama.cpp\\build-win-vulkan\\bin\\llama-server.exe", "C:\\Users\\dai86\\Downloads\\prism-llama.cpp\\build\\bin\\llama-server.exe"] },
  { name: "ExpertsLaguna", env: "LLAMA_TQ3_EXPERTS_LAGUNA_SERVER", paths: ["C:\\Users\\dai86\\llama-cpp-turboquant-experts-laguna\\build-hip\\bin\\llama-server.exe", "C:\\Users\\dai86\\llama-cpp-turboquant\\build-hip\\bin\\llama-server.exe"] },
  { name: "LongCat", env: "LLAMA_TQ3_LONGCAT_SERVER", paths: ["C:\\Users\\dai86\\Downloads\\longcat-llama.cpp\\build-rocm71\\bin\\llama-server.exe", "C:\\Users\\dai86\\Downloads\\longcat-llama.cpp\\build\\bin\\llama-server.exe"] },
  { name: "DFlash2", env: "LLAMA_TQ3_DFLASH2_SERVER", paths: ["C:\\Users\\dai86\\Downloads\\llama-dflash2\\build-rocm71\\bin\\llama-server.exe"] },
];

function resolveEngineBin(name) {
  const cand = ENGINE_CANDIDATES.find(
    (e) => e.name.toLowerCase() === String(name || "").trim().toLowerCase(),
  );
  if (!cand) return null;
  const fromEnv = process.env[cand.env];
  if (fromEnv && existsSync(fromEnv)) return fromEnv;
  for (const p of cand.paths) {
    if (existsSync(p)) return p;
  }
  return null;
}

function engineHint(cand) {
  return `確認パス: ${cand.paths.join(" / ")}（env ${cand.env} で上書き可）`;
}

// Model -> required engine routing, same order as select-model.ps1's
// Get-RequiredEngine (Ternary before DeepSeek so REAP/TQ3 mixes route right).
function requiredEngineForModel(modelName) {
  const m = String(modelName || "");
  if (/ternary|bonsai/i.test(m)) return "PrismBonsai";
  if (/deepseek|ds4-compact|reap[-_ ]?k128|laguna/i.test(m)) return "ExpertsLaguna";
  if (/tq3_4s|tq3/i.test(m)) return "TurboTan";
  if (/longcat/i.test(m)) return "LongCat";
  if (/dflash2/i.test(m)) return "DFlash2";
  return "AtomicBot";
}

let rocmBinCache;
function resolveRocmBin() {
  if (rocmBinCache !== undefined) return rocmBinCache;
  try {
    const root = "C:\\Program Files\\AMD\\ROCm";
    const byVersion = readdirSync(root)
      .filter((n) => /^\d+(\.\d+)*$/.test(n))
      .sort((a, b) => {
        const pa = a.split(".").map(Number);
        const pb = b.split(".").map(Number);
        for (let i = 0; i < Math.max(pa.length, pb.length); i += 1) {
          const d = (pa[i] || 0) - (pb[i] || 0);
          if (d) return -d; // newest first
        }
        return 0;
      });
    for (const v of byVersion) {
      const bin = join(root, v, "bin");
      if (existsSync(bin)) {
        rocmBinCache = bin;
        return bin;
      }
    }
  } catch {
    /* no ROCm installed */
  }
  rocmBinCache = null;
  return null;
}

// GGUF model lookup under MODELS_BASE (same default as select-model.ps1).
function expandEnvVars(value) {
  return String(value || "").replace(/%([^%]+)%/g, (_, name) => process.env[name] ?? `%${name}%`);
}

export const MODELS_BASE = expandEnvVars(
  process.env.LLAMADOCK_MODELS_BASE || "C:\\Users\\dai86\\.lmstudio\\models",
);

async function findModelFile(modelName, maxDepth = 6) {
  const raw = String(modelName || "").trim();
  if (!raw) return null;
  // A full/relative path is used verbatim when it exists.
  if (/[\\/]/.test(raw)) return existsSync(raw) ? resolve(raw) : null;

  const target = raw.toLowerCase();
  async function walk(dir, depth) {
    if (depth > maxDepth) return null;
    let entries;
    try {
      entries = await readdir(dir, { withFileTypes: true });
    } catch {
      return null;
    }
    for (const ent of entries) {
      const full = join(dir, ent.name);
      if (ent.isDirectory()) {
        const hit = await walk(full, depth + 1);
        if (hit) return hit;
      } else if (ent.name.toLowerCase() === target) {
        return full;
      }
    }
    return null;
  }
  return existsSync(MODELS_BASE) ? walk(MODELS_BASE, 0) : null;
}

// GET /api/models/scan — every *.gguf under MODELS_BASE (60s cache). Feeds the
// add-model dialog's datalist so users pick real files instead of typing names.
let ggufScanCache = null;
async function scanGgufModels(maxDepth = 6) {
  if (ggufScanCache && Date.now() - ggufScanCache.at < 60000) return ggufScanCache.models;
  const out = [];
  async function walk(dir, depth) {
    if (depth > maxDepth) return;
    let entries;
    try {
      entries = await readdir(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const ent of entries) {
      const full = join(dir, ent.name);
      if (ent.isDirectory()) {
        await walk(full, depth + 1);
      } else if (ent.name.toLowerCase().endsWith(".gguf")) {
        let sizeGb = null;
        try {
          sizeGb = Math.round(((await stat(full)).size / 1073741824) * 10) / 10;
        } catch {
          /* unreadable — keep null */
        }
        out.push({ name: ent.name, sizeGb, path: full });
      }
    }
  }
  if (existsSync(MODELS_BASE)) await walk(MODELS_BASE, 0);
  out.sort((a, b) => a.name.localeCompare(b.name));
  ggufScanCache = { at: Date.now(), models: out };
  return out;
}

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
  // reset:true removes the model's whole memory entry so every param falls
  // back to profile/default again — the "undo a bad memory" path.
  if (patch.model && patch.reset) {
    delete models[patch.model];
  } else if (patch.model && patch.overrides) {
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
    // Headers may already be on the wire when a read fails mid-stream; only
    // the not-yet-opened case can still send a JSON error.
    if (!res.headersSent) {
      sendJson(res, 404, { error: "not_found", message: `${pathname} is not served by the LlamaDock GUI` });
    } else {
      res.destroy();
    }
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
          const next = await saveModelsConfig({ model: body.model, overrides: clean, reset: !!body.reset });
          sendJson(res, 200, { ok: true, saved: body.reset ? null : clean, reset: !!body.reset, modelsConfig: next });
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
          // Engine resolution mirrors select-model.ps1: schema/preset choice
          // first ("Auto" falls through), then the model-name routing table.
          const requestedEngine = String(body.engine || resolved.engine || "").trim();
          const engineName = !requestedEngine || /^auto$/i.test(requestedEngine)
            ? requiredEngineForModel(model)
            : requestedEngine;
          const cand = ENGINE_CANDIDATES.find(
            (e) => e.name.toLowerCase() === engineName.toLowerCase(),
          );
          const engineBin = process.env.LLAMADOCK_ENGINE_BIN
            || (cand ? resolveEngineBin(engineName) : null);
          if (!engineBin) {
            sendJson(res, 409, {
              ok: false,
              error: "engine_not_found",
              message: `エンジン「${engineName}」の llama-server が見つかりません。${cand ? engineHint(cand) : `スキーマの engine 値「${engineName}」はランタイム候補にありません（${ENGINE_CANDIDATES.map((e) => e.name).join(" / ")}）。`}`,
            });
            return;
          }
          // Resolve the GGUF on disk: explicit path > MODELS_BASE lookup.
          // A name-only model that exists nowhere must fail here with a clear
          // message instead of spawning a doomed llama-server.
          const modelPath = /[\\/]/.test(String(body.modelPath || ""))
            ? (existsSync(body.modelPath) ? resolve(body.modelPath) : null)
            : await findModelFile(model);
          if (!modelPath) {
            sendJson(res, 409, {
              ok: false,
              error: "model_not_found",
              message: `GGUF「${model}」が見つかりません。モデルベース: ${MODELS_BASE}（env LLAMADOCK_MODELS_BASE で変更可）。「+ 追加」ダイアログではスキャン済みファイルを選ぶのが確実です。`,
            });
            return;
          }
          const port = Number(body.port || DEFAULT_UPSTREAM_PORT);
          const { args, env } = buildArgs(payload.schema, resolved, {
            model: modelPath,
            host: "127.0.0.1",
            port,
          });

          const result = await launchManager.launch({
            model,
            engine: engineName,
            engineBin,
            extraPath: resolveRocmBin(),
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

    if (pathname === "/api/results/clear") {
      if (req.method === "POST") {
        const empty = { version: 1, updated: new Date().toISOString(), configs: [] };
        await mkdir(CONFIG_DIR, { recursive: true });
        const tmp = `${RESULTS_PATH}.tmp`;
        await writeFile(tmp, `${JSON.stringify(empty, null, 2)}\n`, "utf8");
        await rename(tmp, RESULTS_PATH);
        sendJson(res, 200, { ok: true, message: "実測記録をクリアしました", results: summarize(empty) });
        return;
      }
      sendJson(res, 405, { ok: false, error: "Method not allowed" });
      return;
    }

    if (pathname === "/api/models/scan") {
      if (req.method === "GET") {
        try {
          const models = await scanGgufModels();
          sendJson(res, 200, { ok: true, base: MODELS_BASE, count: models.length, models });
        } catch (error) {
          sendJson(res, 500, { ok: false, error: "scan_failed", message: errorMessage(error) });
        }
        return;
      }
      sendJson(res, 405, { ok: false, error: "Method not allowed" });
      return;
    }

    if (pathname === "/api/connect") {
      // Phase 2 contract: launch a workspace client against the running server.
      //   body: { client, model?, workspace?, prompt? }
      // Windows spawns the real launcher (detached); other platforms validate
      // the full request and return the exact command Windows would run.
      if (req.method === "POST") {
        try {
          const body = await readJsonBody(req);
          const result = await clientManager.connect({
            client: String(body.client || ""),
            model: body.model ? String(body.model) : null,
            workspace: body.workspace ? String(body.workspace) : null,
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
      // (WebUI :8000 / ComfyUI :8188 + LLAMADOCK_<ID>_PORT
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

    if (pathname === "/api/engine-settings") {
      if (req.method === "GET") {
        const args = await readJsonSafe(SERVER_ARGUMENTS_PATH);
        const sup = await readSupervisorState();
        if (!Array.isArray(args)) {
          sendJson(res, 200, { ok: false, error: "no_arguments_file", message: "server-arguments.json がありません。先に select-model.ps1 で起動してください。", ...sup });
          return;
        }
        sendJson(res, 200, {
          ok: true,
          ...sup,
          model: flagValue(args, "-m"),
          alias: flagValue(args, "-a"),
          ctk: flagValue(args, "-ctk") || "none",
          ctv: flagValue(args, "-ctv") || "none",
          fa: flagValue(args, "-fa") === "on",
          context: Number(flagValue(args, "-c")) || null,
          cacheRam: Number(flagValue(args, "--cache-ram")) || null,
          specType: flagValue(args, "--spec-type") || "off",
          specDraftModel: flagValue(args, "--spec-draft-model") || flagValue(args, "-md") || "",
          specDraftNMax: Number(flagValue(args, "--spec-draft-n-max")) || null,
        });
        return;
      }
      if (req.method === "POST") {
        try {
          const body = await readJsonBody(req);
          const current = await readJsonSafe(SERVER_ARGUMENTS_PATH);
          if (!Array.isArray(current)) {
            sendJson(res, 409, { ok: false, error: "no_arguments_file", message: "server-arguments.json がありません。先に select-model.ps1 で起動してください。" });
            return;
          }
          const next = [...current];

          if (body.ctk !== undefined) setFlag(next, "-ctk", body.ctk === "none" ? null : body.ctk);
          if (body.ctv !== undefined) setFlag(next, "-ctv", body.ctv === "none" ? null : body.ctv);
          if (body.fa !== undefined) setFlag(next, "-fa", body.fa ? "on" : "off");
          if (body.context !== undefined && Number.isFinite(Number(body.context))) {
            setFlag(next, "-c", clampInt(body.context, 1024, 262144, 32768));
          }
          if (body.cacheRam !== undefined && Number.isFinite(Number(body.cacheRam))) {
            setFlag(next, "--cache-ram", clampInt(body.cacheRam, 0, 131072, 8192));
          }

          if (body.specType !== undefined) {
            // Clear every spec-related flag first, then rebuild for the mode.
            for (const f of ["--spec-type", "--spec-draft-model", "-md", "--spec-draft-n-max", "--spec-draft-n-min", "-ngld", "-ctkd", "-ctvd"]) {
              setFlag(next, f, null);
            }
            if (body.specType === "draft-mtp") {
              // Self-draft: the combined *_MTP.gguf main model carries its own
              // MTP heads — select-model.ps1 does NOT add -md, and the running
              // supervisor config works without it. Only add it when the UI
              // explicitly supplies one.
              setFlag(next, "--spec-type", "draft-mtp");
              setFlag(next, "--spec-draft-n-max", "2");
              setFlag(next, "--spec-draft-n-min", "1");
              const ctk = flagValue(next, "-ctk");
              const ctv = flagValue(next, "-ctv");
              if (ctk) setFlag(next, "-ctkd", ctk);
              if (ctv) setFlag(next, "-ctvd", ctv);
              setFlag(next, "-ngld", "auto");
              const explicitDraft = String(body.specDraftModel || "").trim();
              if (explicitDraft) setFlag(next, "-md", explicitDraft);
            } else if (body.specType === "draft-dflash") {
              const draft = String(body.specDraftModel || "").trim();
              if (!draft) {
                sendJson(res, 400, { ok: false, error: "draft_model_required", message: "DFlash にはドラフトモデル（GGUF）のパスが必要です。" });
                return;
              }
              setFlag(next, "--spec-type", "draft-dflash");
              setFlag(next, "--spec-draft-model", draft);
              setFlag(next, "--spec-draft-n-max", String(clampInt(body.specDraftNMax, 1, 32, 15)));
            } else if (body.specType === "draft-dflash2") {
              const draft = String(body.specDraftModel || "").trim();
              if (!draft) {
                sendJson(res, 400, { ok: false, error: "draft_model_required", message: "DFlash2 にはドラフトモデル（GGUF）のパスが必要です。" });
                return;
              }
              setFlag(next, "--spec-type", "draft-dflash");
              setFlag(next, "--spec-draft-model", draft);
              setFlag(next, "--spec-draft-n-max", String(clampInt(body.specDraftNMax, 1, 32, 8)));
            }
            // "off": nothing to add.
          }

          // Atomic write (tmp + rename), same pattern as saveModelsConfig.
          const tmp = `${SERVER_ARGUMENTS_PATH}.tmp`;
          await writeFile(tmp, `${JSON.stringify(next, null, 2)}\n`, "utf8");
          await rename(tmp, SERVER_ARGUMENTS_PATH);

          const sup = await readSupervisorState();
          if (!sup.supervisorRunning || sup.breakerOpen) {
            sendJson(res, 200, { ok: true, restarted: false, reason: "supervisor_stopped", message: "設定は保存しました。supervisor 停止中のため再起動はスキップしました。select-model.ps1 で起動し直してください。" });
            return;
          }
          await writeFile(RESTART_FLAG_PATH, `${JSON.stringify({ reason: "ui_settings_change", timestamp: new Date().toISOString() }, null, 2)}\n`, "utf8");
          sendJson(res, 200, { ok: true, restarted: true, message: "再起動を要求しました。" });
        } catch (error) {
          sendJson(res, 400, { ok: false, error: "engine_settings_failed", message: errorMessage(error) });
        }
        return;
      }
      sendJson(res, 405, { ok: false, error: "Method not allowed" });
      return;
    }

    if (pathname === "/api/engine-health") {
      // Server-side probe of the coder engine (browser cannot hit 8090/8080
      // directly: no CORS headers on the gateway).
      sendJson(res, 200, { ok: true, upstream: await probeUpstreamHealth(), checkedAt: new Date().toISOString() });
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
        // Per-engine binary availability, so the GUI can show which runtimes
        // are actually installed instead of failing at launch time.
        engines: ENGINE_CANDIDATES.map((e) => ({
          name: e.name,
          found: !!(process.env.LLAMADOCK_ENGINE_BIN || resolveEngineBin(e.name)),
        })),
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

// --- Engine settings helpers (supervisor-managed coder engine, 8080/8090) ---

function flagValue(args, flag) {
  const i = args.indexOf(flag);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
}

// value === null removes the flag together with its value.
function setFlag(args, flag, value) {
  const i = args.indexOf(flag);
  if (value === null) {
    if (i >= 0) args.splice(i, 2);
    return args;
  }
  if (i >= 0) args[i + 1] = String(value);
  else args.push(flag, String(value));
  return args;
}

async function readSupervisorState() {
  const status = await readJsonSafe(SUPERVISOR_STATUS_PATH);
  return {
    supervisorRunning: !!(status && status.supervisor_pid && status.state && status.state !== "stopped"),
    state: status ? status.state : "unknown",
    breakerOpen: !!(status && status.breaker_open),
  };
}

async function probeUpstreamHealth() {
  try {
    const res = await fetch(`http://127.0.0.1:${DEFAULT_UPSTREAM_PORT}/health`, { signal: AbortSignal.timeout(2000) });
    return { up: res.ok, status: res.status };
  } catch {
    return { up: false, status: null };
  }
}
