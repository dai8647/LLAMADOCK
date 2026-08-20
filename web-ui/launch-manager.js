// LlamaDock — runtime launcher state machine.
// ---------------------------------------------------------------------------
// Owns the llama-server child process, ready-wait, health polling, metrics,
// a log ring buffer, and benchmark runs.
//
// Platform split:
//   - Windows: spawns the real llama.cpp engine (Phase 1 core). The engine
//     binary path is injected via LLAMADOCK_ENGINE_BIN; until the Phase 1 core
//     is wired this endpoint returns a clear error instead of pretending.
//   - other (sandbox/preview): spawns web-ui/mock-llama-server.mjs — a small
//     OpenAI-compatible stand-in — so the whole launch -> health -> benchmark
//     -> run-results loop is genuinely exercised here. `simulated: true` marks
//     these runs in the API responses.
// ---------------------------------------------------------------------------

import { spawn } from "node:child_process";
import http from "node:http";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const MOCK_SERVER = join(__dirname, "mock-llama-server.mjs");

export const DEFAULT_UPSTREAM_PORT = Number(process.env.LLAMADOCK_UPSTREAM_PORT || 8080);
const READY_TIMEOUT_MS = Number(process.env.LLAMADOCK_READY_TIMEOUT_MS || 20000);
const HEALTH_POLL_MS = 2500;
const LOG_RING_MAX = 300;

export const STATES = {
  IDLE: "idle",
  STARTING: "starting",
  RUNNING: "running",
  STOPPING: "stopping",
  ERROR: "error",
};

function hash(str) {
  let h = 0;
  for (let i = 0; i < str.length; i += 1) h = (Math.imul(h, 31) + str.charCodeAt(i)) | 0;
  return Math.abs(h);
}

// Deterministic simulated throughput (8..40 tok/s) so the same model + config
// measures consistently across runs — enough to demo the qualification loop.
function tpsForModel(model) {
  return 8 + (hash(`tps:${String(model || "")}`) % 33);
}

function ctxForModel(model) {
  const m = String(model || "").toLowerCase();
  if (m.includes("131k") || m.includes("131072")) return 131072;
  if (m.includes("98k") || m.includes("98304")) return 98304;
  if (m.includes("65k") || m.includes("65536")) return 65536;
  if (m.includes("49k") || m.includes("49152")) return 49152;
  return 32768;
}

function metricsFromHealth(health) {
  return {
    toks: Number.isFinite(health?.tokens_per_second) ? health.tokens_per_second : null,
    vramGb: health?.memory?.vram_mib != null ? health.memory.vram_mib / 1024 : null,
    ramGb: health?.memory?.ram_mib != null ? health.memory.ram_mib / 1024 : null,
  };
}

function jsonRequest(port, method, path, body, { timeoutMs = 30000 } = {}) {
  return new Promise((resolve, reject) => {
    const data = body === undefined ? null : JSON.stringify(body);
    const headers = { Accept: "application/json" };
    if (data) {
      headers["Content-Type"] = "application/json";
      headers["Content-Length"] = String(Buffer.byteLength(data));
    }
    const req = http.request(
      { host: "127.0.0.1", port, path, method, headers, timeout: timeoutMs },
      (res) => {
        const chunks = [];
        res.on("data", (c) => chunks.push(c));
        res.on("end", () => {
          const raw = Buffer.concat(chunks).toString("utf8");
          let parsed = null;
          try {
            parsed = JSON.parse(raw);
          } catch {
            parsed = raw;
          }
          resolve({ status: res.statusCode, body: parsed });
        });
      },
    );
    req.on("timeout", () => req.destroy(new Error(`timeout after ${timeoutMs}ms`)));
    req.on("error", reject);
    if (data) req.write(data);
    req.end();
  });
}

async function waitForHealth(port, { tries = Math.max(4, Math.ceil(READY_TIMEOUT_MS / 250)), intervalMs = 250, shouldAbort = null } = {}) {
  for (let i = 0; i < tries; i += 1) {
    if (shouldAbort?.()) return null;
    try {
      const res = await jsonRequest(port, "GET", "/health", undefined, { timeoutMs: 1500 });
      if (res.status === 200 && res.body && (res.body.status === "ok" || res.body.ok)) return res.body;
    } catch {
      /* not up yet */
    }
    await new Promise((r) => setTimeout(r, intervalMs));
  }
  return null;
}

export function createLaunchManager({ upstreamPort = DEFAULT_UPSTREAM_PORT } = {}) {
  let child = null;
  let stopping = false;
  let healthTimer = null;
  let state = {
    status: STATES.IDLE,
    model: null,
    engine: null,
    port: upstreamPort,
    pid: null,
    simulated: false,
    startedAt: null,
    error: null,
    args: [],
    env: {},
    resolvedParams: null,
    health: null,
    metrics: { toks: null, vramGb: null, ramGb: null },
    log: [],
  };

  function setState(patch) {
    state = { ...state, ...patch };
  }

  function log(line) {
    const t = new Date().toISOString().slice(11, 19);
    state.log.push(`[${t}] ${line}`);
    if (state.log.length > LOG_RING_MAX) state.log.splice(0, state.log.length - LOG_RING_MAX);
  }

  function pipe(name, stream) {
    stream?.on("data", (c) => {
      String(c)
        .split(/\r?\n/)
        .filter(Boolean)
        .forEach((line) => log(`${name}: ${line}`));
    });
  }

  async function pollHealthOnce() {
    try {
      const health = await jsonRequest(state.port, "GET", "/health", undefined, { timeoutMs: 1500 });
      if (health.status === 200 && health.body && (health.body.status === "ok" || health.body.ok)) {
        state.health = health.body;
        state.metrics = metricsFromHealth(health.body);
        return true;
      }
    } catch {
      /* downstream down */
    }
    state.metrics = { toks: null, vramGb: null, ramGb: null };
    return false;
  }

  function startHealthPolling() {
    clearInterval(healthTimer);
    healthTimer = setInterval(async () => {
      const healthy = await pollHealthOnce();
      if (!healthy && state.status === STATES.RUNNING) {
        log("upstream health check failed — server may have exited");
      }
    }, HEALTH_POLL_MS);
    healthTimer.unref?.();
  }

  async function launch({ model, engine = null, args = [], env = {}, port = upstreamPort, resolvedParams = null }) {
    if (state.status === STATES.RUNNING || state.status === STATES.STARTING) {
      return {
        ok: false,
        error: "already_running",
        message: `すでに「${state.model}」が起動中です。先に停止してください。`,
        status: summary(),
      };
    }

    setState({
      status: STATES.STARTING,
      model,
      engine,
      port,
      pid: null,
      startedAt: new Date().toISOString(),
      error: null,
      args,
      env,
      resolvedParams,
      simulated: process.platform !== "win32",
      health: null,
      metrics: { toks: null, vramGb: null, ramGb: null },
      log: [],
    });
    log(`launch requested: model=${model} engine=${engine || "auto"} port=${port}`);

    try {
      if (process.platform === "win32") {
        // Phase 1 core wiring: select-model.ps1's engine resolution will set
        // LLAMADOCK_ENGINE_BIN; until then this is a clear contract error.
        const engineBin = process.env.LLAMADOCK_ENGINE_BIN;
        if (!engineBin) {
          throw new Error(
            "Windows コア（select-model.ps1 の Phase 1 モジュール抽出）がまだ /api/launch に配線されていません。" +
              "LLAMADOCK_ENGINE_BIN にエンジン実行ファイルのパスを設定するか、Phase 1 の抽出後に接続してください。",
          );
        }
        log(`spawning engine: ${engineBin}`);
        child = spawn(engineBin, args, { env: { ...process.env, ...env }, stdio: ["ignore", "pipe", "pipe"] });
      } else {
        // Simulation stand-in: real spawn + ready-wait + stop lifecycle.
        child = spawn(process.execPath, [MOCK_SERVER], {
          env: {
            ...process.env,
            LLAMADOCK_MOCK_HOST: "127.0.0.1",
            LLAMADOCK_MOCK_PORT: String(port),
            LLAMADOCK_MOCK_MODEL: String(model || "mock-model.gguf"),
            LLAMADOCK_MOCK_TPS: String(tpsForModel(model)),
            LLAMADOCK_MOCK_CTX: String(ctxForModel(model)),
          },
          stdio: ["ignore", "pipe", "pipe"],
        });
      }

      state.pid = child.pid;
      pipe("out", child.stdout);
      pipe("err", child.stderr);
      child.on("exit", (code, signal) => {
        log(`process exited code=${code} signal=${signal ?? ""}`);
        clearInterval(healthTimer);
        stopping = false;
        if (state.status !== STATES.STOPPING && state.status !== STATES.IDLE) {
          setState({
            status: STATES.ERROR,
            error: `プロセスが予期せず終了しました (code=${code ?? "?"})`,
            pid: null,
            health: null,
            metrics: { toks: null, vramGb: null, ramGb: null },
          });
        } else {
          setState({
            status: STATES.IDLE,
            pid: null,
            health: null,
            metrics: { toks: null, vramGb: null, ramGb: null },
          });
        }
      });
      // spawn can fail asynchronously (ENOENT, EACCES). Without this handler
      // the error is unhandled and crashes the whole Node process.
      child.on("error", (error) => {
        log(`process error: ${error.message}`);
        clearInterval(healthTimer);
        stopping = false;
        setState({
          status: STATES.ERROR,
          error: `プロセスの起動に失敗しました: ${error.message}`,
          pid: null,
          health: null,
          metrics: { toks: null, vramGb: null, ramGb: null },
        });
      });

      const health = await waitForHealth(port, { shouldAbort: () => stopping });
      if (!health) {
        throw new Error(
          stopping
            ? "起動処理は停止されました"
            : `起動後 ${Math.round(READY_TIMEOUT_MS / 1000)}s 以内に /health が応答しませんでした（127.0.0.1:${port}）`,
        );
      }
      setState({ status: STATES.RUNNING, health, metrics: metricsFromHealth(health) });
      log(`ready: ${health.model || model} on http://127.0.0.1:${port}${state.simulated ? " (simulation)" : ""}`);
      startHealthPolling();
      return {
        ok: true,
        message: `「${model}」を起動しました（${state.simulated ? "シミュレーション" : "実ランタイム"}）`,
        status: summary(),
      };
    } catch (error) {
      const message = errorMessage(error);
      log(`launch failed: ${message}`);
      if (child) {
        try {
          child.kill("SIGKILL");
        } catch {
          /* already gone */
        }
        child = null;
      }
      // If a stop was requested while the server was still starting, the exit
      // handler has already moved the state machine to IDLE — do not clobber
      // that with a spurious ERROR.
      if (!stopping && state.status !== STATES.IDLE) {
        setState({ status: STATES.ERROR, error: message, pid: null });
      }
      return { ok: false, error: "launch_failed", message, status: summary() };
    }
  }

  async function stop() {
    if (![STATES.RUNNING, STATES.STARTING, STATES.ERROR].includes(state.status)) {
      return { ok: false, error: "not_running", message: "起動中のサーバーがありません", status: summary() };
    }
    if (state.status === STATES.ERROR && !child) {
      setState({ status: STATES.IDLE, error: null });
      return { ok: true, message: "エラー状態をリセットしました", status: summary() };
    }

    stopping = true;
    setState({ status: STATES.STOPPING });
    log("stop requested");
    const proc = child;
    child = null;

    if (proc) {
      await new Promise((resolveKill) => {
        let done = false;
        const finish = () => {
          if (!done) {
            done = true;
            resolveKill();
          }
        };
        proc.once("exit", finish);
        try {
          proc.kill("SIGTERM");
        } catch {
          finish();
        }
        setTimeout(() => {
          try {
            proc.kill("SIGKILL");
          } catch {
            /* gone */
          }
        }, 1500).unref?.();
        setTimeout(finish, 2500).unref?.();
      });
    }

    clearInterval(healthTimer);
    setState({
      status: STATES.IDLE,
      pid: null,
      health: null,
      metrics: { toks: null, vramGb: null, ramGb: null },
    });
    log("stopped");
    return { ok: true, message: "サーバーを停止しました", status: summary() };
  }

  // Runs N chat completions against the running server and returns per-run
  // measured metrics (tok/s from usage tokens / wall time).
  async function benchmark({ runs = 3, maxTokens = 96 } = {}) {
    if (state.status !== STATES.RUNNING) {
      return {
        ok: false,
        error: "not_running",
        message: "計測には起動中のサーバーが必要です（先に起動してください）",
        status: summary(),
      };
    }
    const measured = [];
    for (let i = 0; i < runs; i += 1) {
      const started = Date.now();
      try {
        const res = await jsonRequest(
          state.port,
          "POST",
          "/v1/chat/completions",
          {
            model: state.model,
            messages: [{ role: "user", content: `benchmark run ${i + 1} — measure token throughput` }],
            max_tokens: maxTokens,
            stream: false,
          },
          { timeoutMs: 60000 },
        );
        const elapsedMs = Date.now() - started;
        const usage = res.body?.usage || {};
        const ok = res.status === 200 && usage.completion_tokens > 0;
        measured.push({
          ok,
          tokensPerSec: ok ? usage.completion_tokens / (elapsedMs / 1000) : null,
          vramGb: state.metrics?.vramGb ?? null,
          ramGb: state.metrics?.ramGb ?? null,
          promptTokens: usage.prompt_tokens ?? null,
          completionTokens: usage.completion_tokens ?? null,
          elapsedMs,
          error: ok ? null : `status=${res.status}`,
        });
        log(`benchmark run ${i + 1}/${runs}: ${ok ? `${measured[i].tokensPerSec.toFixed(1)} tok/s` : `failed (${res.status})`}`);
      } catch (error) {
        measured.push({
          ok: false,
          tokensPerSec: null,
          vramGb: null,
          ramGb: null,
          promptTokens: null,
          completionTokens: null,
          elapsedMs: Date.now() - started,
          error: errorMessage(error),
        });
        log(`benchmark run ${i + 1}/${runs}: failed (${errorMessage(error)})`);
      }
    }
    return { ok: true, runs: measured, status: summary() };
  }

  function summary() {
    return {
      status: state.status,
      model: state.model,
      engine: state.engine,
      simulated: state.simulated,
      pid: state.pid,
      port: state.port,
      startedAt: state.startedAt,
      uptimeMs: state.startedAt ? Date.now() - new Date(state.startedAt).getTime() : null,
      error: state.error,
      args: state.args,
      resolvedParams: state.resolvedParams || null,
      metrics: state.metrics || { toks: null, vramGb: null, ramGb: null },
      health: state.health || null,
      logTail: state.log.slice(-80),
    };
  }

  return { launch, stop, benchmark, summary, STATES };
}

function errorMessage(error) {
  return error instanceof Error ? error.message : String(error);
}
