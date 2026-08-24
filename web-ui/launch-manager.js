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

// Mirror of select-model.ps1's Wait-VramRelease: a llama-server that was just
// stopped keeps the upstream port open for a moment. Spawning a replacement
// too early either fails to bind or (worse) lets "-ngl auto" fit layers from
// depleted free VRAM and silently degrade to CPU-heavy placement.
async function waitForPortClosed(port, { timeoutMs = 20000 } = {}) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      await jsonRequest(port, "GET", "/health", undefined, { timeoutMs: 800 });
      /* still answering — keep waiting */
    } catch {
      return true; // nothing listening
    }
    await new Promise((r) => setTimeout(r, 1000));
  }
  return false;
}

// Post-launch decode-speed sanity check, mirroring Test-GpuOffloadProbe in
// select-model.ps1: a GPU-ineffective placement shows up as very low tok/s.
async function probeGpuOffload(port, model, { maxTokens = 24 } = {}) {
  const started = Date.now();
  try {
    const res = await jsonRequest(
      port,
      "POST",
      "/v1/chat/completions",
      {
        model,
        messages: [{ role: "user", content: "hi" }],
        max_tokens: maxTokens,
        temperature: 0,
        stream: false,
      },
      { timeoutMs: 120000 },
    );
    const wallMs = Date.now() - started;
    const usage = res.body?.usage || {};
    const tokens = usage.completion_tokens ?? 0;
    if (res.status === 200 && tokens > 0) {
      return { ok: true, tokensPerSec: tokens / (wallMs / 1000), wallMs, tokens };
    }
    return { ok: false, error: `status=${res.status}` };
  } catch (error) {
    return { ok: false, error: errorMessage(error) };
  }
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
    gpuProbe: null,
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

  async function launch({ model, engine = null, engineBin = null, extraPath = null, args = [], env = {}, port = upstreamPort, resolvedParams = null }) {
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
      gpuProbe: null,
      log: [],
    });
    log(`launch requested: model=${model} engine=${engine || "auto"} port=${port}`);

    let childExited = false;
    try {
      if (process.platform === "win32") {
        // Wait for a just-stopped previous instance to release the upstream
        // port (and its VRAM) before spawning — see waitForPortClosed above.
        const portFree = await waitForPortClosed(port);
        if (!portFree) {
          throw new Error(
            `ポート ${port} が使用中です。前のインスタンスが 20 秒以内に解放しませんでした。先に停止するか、LLAMADOCK_UPSTREAM_PORT を変更してください。`,
          );
        }
        // Engine binary is resolved by server.js from the select-model.ps1
        // candidate table; LLAMADOCK_ENGINE_BIN still wins when set.
        const bin = process.env.LLAMADOCK_ENGINE_BIN || engineBin;
        if (!bin) {
          throw new Error(
            "起動するエンジン実行ファイルを解決できませんでした。LLAMADOCK_ENGINE_BIN を設定するか、select-model.ps1 のランタイム候補パスに llama-server.exe を配置してください。",
          );
        }
        log(`spawning engine: ${bin}`);
        const spawnEnv = { ...process.env, ...env };
        if (extraPath) {
          // HIP DLLs (amdhip64.dll etc.) live in the ROCm bin dir; the
          // PowerShell core prepends it the same way.
          spawnEnv.PATH = `${extraPath};${spawnEnv.PATH || ""}`;
        }
        child = spawn(bin, args, { env: spawnEnv, stdio: ["ignore", "pipe", "pipe"] });
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
        childExited = true;
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

      // Abort the ready-wait as soon as the process dies — a crashed engine
      // must surface its error immediately, not after the full timeout.
      const health = await waitForHealth(port, { shouldAbort: () => stopping || childExited });
      if (!health) {
        throw new Error(
          stopping
            ? "起動処理は停止されました"
            : childExited
              ? `プロセスが起動直後に終了しました（127.0.0.1:${port}）。ログを確認してください。`
              : `起動後 ${Math.round(READY_TIMEOUT_MS / 1000)}s 以内に /health が応答しませんでした（127.0.0.1:${port}）`,
        );
      }
      setState({ status: STATES.RUNNING, health, metrics: metricsFromHealth(health) });
      log(`ready: ${health.model || model} on http://127.0.0.1:${port}${state.simulated ? " (simulation)" : ""}`);
      startHealthPolling();
      if (!state.simulated) {
        // Fire-and-forget GPU offload probe (mirrors the CLI guard): never
        // blocks the launch response, result lands in state.gpuProbe + log.
        void probeGpuOffload(port, model).then((probe) => {
          setState({ gpuProbe: probe });
          if (!probe.ok) {
            log(`GPU probe failed/skipped: ${probe.error}`);
          } else if (probe.tokensPerSec < 8) {
            log(
              `WARNING: decode speed is only ${probe.tokensPerSec.toFixed(1)} tok/s — GPU offload looks INEFFECTIVE. ` +
                "Close VRAM-heavy apps or relaunch with an explicit -ngl layer count.",
            );
          } else {
            log(`GPU probe ok (${probe.tokensPerSec.toFixed(1)} tok/s in ${probe.wallMs} ms)`);
          }
        });
      }
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
      gpuProbe: state.gpuProbe || null,
      health: state.health || null,
      logTail: state.log.slice(-80),
    };
  }

  return { launch, stop, benchmark, summary, STATES };
}

function errorMessage(error) {
  return error instanceof Error ? error.message : String(error);
}
