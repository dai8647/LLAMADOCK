// LlamaDock — workspace client connection manager (Phase 2 contract).
// ---------------------------------------------------------------------------
// POST /api/connect maps a workspace client id to its real Windows launch,
// mirroring select-model.ps1's Open-*Client functions:
//   - Cline / OpenCode -> tools/llamadock-client-shell.ps1
//   - WebUI                          -> tools/computer-start.ps1 (Computer 0.9.9)
//   - LlamaAgent                     -> llama-agent.exe (MCP web-search auto-start)
//   - ComfyUI                        -> ComfyUI .venv python main.py (port 8188)
//
// On win32 the manager spawns the launcher detached and tracks it. On every
// other platform (sandbox/preview) it validates the full request and returns
// the exact command Windows would run with `simulated: true`, so the contract
// is exercised end-to-end here without pretending a client was opened.
// ---------------------------------------------------------------------------

import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join, resolve } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
export const PROJECT_ROOT = resolve(__dirname, "..");

// Clients are reached through the recovery gateway (8090), never the raw
// upstream (8080) — see docs/LlamaDock-Runbook.md.
export const CLIENT_BASE_URL =
  process.env.LLAMADOCK_CLIENT_BASE_URL || "http://127.0.0.1:8090/v1";

// Web-kind clients that run their own HTTP server get a health check. The
// probe target is env-overridable (LLAMADOCK_<ID>_PORT) so a ComfyUI on a
// non-default port — or a sandbox test server — is monitored correctly.
//   WebUI        -> Open WebUI / Computer UI on :8000
//   ComfyUI      -> /system_stats on :8188 (its own server, standalone)
export const CLIENTS = [
  { id: "Cline", label: "Cline", desc: "コーディング", kind: "cli" },
  { id: "OpenCode", label: "OpenCode", desc: "ターミナルコーディング", kind: "cli" },
  { id: "WebUI", label: "Open WebUI / Computer", desc: "チャット・検索", kind: "web", port: 8000, health: { path: "/" } },
  { id: "LlamaAgent", label: "Llama Agent", desc: "反復調査", kind: "cli" },
  { id: "DeepSeekHarness", label: "DeepSeek Harness", desc: "エージェントハーネス", kind: "web", port: 3080, standalone: true, health: { path: "/" } },
  // standalone: the client runs its own server and does not need a running
  // llama-server — mirrors select-model.ps1's Open-ComfyUIClient comment
  // ("ComfyUI runs its own server on :8188 and does not depend on the
  // llama-server that is already up").
  { id: "ComfyUI", label: "ComfyUI", desc: "動画 / 音声生成（単独起動）", kind: "web", port: 8188, standalone: true, health: { path: "/system_stats" } },
];

// Effective port for a client, honouring LLAMADOCK_<ID>_PORT (e.g.
// LLAMADOCK_COMFYUI_PORT=8190) over the schema default.
export function clientPort(spec) {
  const over = Number(process.env[`LLAMADOCK_${String(spec.id).toUpperCase()}_PORT`]);
  if (Number.isFinite(over) && over > 0) return over;
  return Number(spec.port) || 0;
}

export function healthUrlFor(spec) {
  if (!spec?.health) return null;
  const port = clientPort(spec);
  if (!port) return null;
  return `http://127.0.0.1:${port}${spec.health.path || "/"}`;
}

export function clientById(id) {
  return CLIENTS.find((c) => c.id === id) || null;
}

// Mirror select-model.ps1's Get-ComfyUILaunchArgs default profile so GUI- and
// CLI-launched ComfyUI instances are identical: --reserve-vram keeps 1 GB of
// VRAM for the desktop/OS (the H3 DiT otherwise fills the whole 16 GB card).
// The interactive ck/super/triton profiles stay a CLI-side feature; the
// LLAMADOCK_COMFY_FLAGS override works in both launchers.
export function comfyLaunchArgs(spec) {
  const base = ["main.py", "--port", String(clientPort(spec)), "--listen", "127.0.0.1"];
  const flagsOverride = String(process.env.LLAMADOCK_COMFY_FLAGS || "").trim();
  const extras = flagsOverride ? flagsOverride.split(/\s+/).filter(Boolean) : ["--reserve-vram", "1.0"];
  return [...base, ...extras];
}

// VRAM contention warning: the coder engine holds most of the 16 GB card while
// running; H3 DiT video generation alongside it OOMs on this hardware. The CLI
// front door is mutually exclusive ([1] LLM / [2] ComfyUI) while the GUI
// allows both, so warn instead of silently letting generation fail.
export function vramGuardNote(clientId, runtime) {
  if (clientId !== "ComfyUI" || !runtime || runtime.status !== "running") return "";
  return `⚠ 注意: llama-server（${runtime.model || "?"}）が同時稼働中です。VRAM 競合で ComfyUI の生成が失敗する可能性があります。`;
}

function q(value) {
  return `"${String(value ?? "").replaceAll('"', '\\"')}"`;
}

// Windows spawn plan for a client — argv array (no shell quoting issues for
// the real spawn) plus a human-readable command line for the simulation path.
function windowsPlan(spec, { model, workspace, prompt }) {
  const root = PROJECT_ROOT;
  const baseUrl = CLIENT_BASE_URL;
  const ws = workspace && workspace.trim() ? workspace : root;
  const shellArgs = ["-NoExit", "-ExecutionPolicy", "Bypass"];
  const clientShell = join(root, "tools", "llamadock-client-shell.ps1");

  switch (spec.id) {
    case "Cline": {
      const dataDir = process.env.LLAMADOCK_CLINE_DATA_DIR || join(root, "mcp-data", "cline");
      const args = [
        ...shellArgs, "-File", clientShell,
        "-Client", "Cline", "-ModelName", String(model || ""),
        "-BaseUrl", baseUrl, "-DataDir", dataDir, "-Workspace", ws,
      ];
      return { exe: "powershell.exe", args, cwd: root, display: `powershell.exe ${args.map(q).join(" ")}` };
    }
    case "OpenCode": {
      const configPath = join(root, "mcp-data", "opencode-local.json");
      const args = [
        ...shellArgs, "-File", clientShell,
        "-Client", "OpenCode", "-ModelName", String(model || ""),
        "-ConfigPath", configPath, "-BaseUrl", baseUrl, "-Workspace", ws,
      ];
      return { exe: "powershell.exe", args, cwd: root, display: `powershell.exe ${args.map(q).join(" ")}` };
    }
    case "WebUI": {
      const args = [...shellArgs, "-File", join(root, "tools", "computer-start.ps1")];
      return { exe: "powershell.exe", args, cwd: root, display: `powershell.exe ${args.map(q).join(" ")}` };
    }
    case "LlamaAgent": {
      // Phase 1 core will carry over select-model.ps1's full embedded script
      // (PATH setup, MCP server auto-start, research prompt). This is the
      // minimal equivalent that keeps the contract explicit.
      const agent = process.env.LLAMADOCK_LLAMA_AGENT_BIN ||
        "C:\\Users\\dai86\\llama-agent\\build\\bin\\llama-agent.exe";
      const script = [
        "Set-Location -LiteralPath '" + root.replaceAll("'", "''") + "'",
        "chcp 65001 | Out-Null",
        "$env:RESEARCH_LLM_BASE_URL='" + baseUrl + "'",
        "$env:RESEARCH_LLM_MODEL='" + String(model || "local-model") + "'",
        "& '" + agent.replaceAll("'", "''") + "'",
      ].join("\n");
      const args = [...shellArgs, "-Command", script];
      return { exe: "powershell.exe", args, cwd: root, display: `powershell.exe ${shellArgs.map(q).join(" ")} -Command <llama-agent 起動スクリプト>` };
    }
    case "ComfyUI": {
      const comfyRoot = process.env.LLAMADOCK_COMFYUI_ROOT || "C:\\Users\\dai86\\Documents\\ComfyUI";
      const python = join(comfyRoot, ".venv", "Scripts", "python.exe");
      // Same effective port as the health probe — LLAMADOCK_COMFYUI_PORT
      // overrides both, so launch and monitor can never diverge. Args mirror
      // the CLI launcher via comfyLaunchArgs (reserve-vram / FLAGS override).
      const args = comfyLaunchArgs(spec);
      return { exe: python, args, cwd: comfyRoot, display: `${q(python)} ${args.join(" ")}  (cwd: ${q(comfyRoot)})` };
    }
    case "DeepSeekHarness": {
      // Prefer the globally installed CLI (kept current by tools/dsh-update.ps1)
      // over npx; npx re-downloads the full ~450-package tree on every launch.
      // Node >=18.20 refuses to spawn .cmd/.bat shims directly (EINVAL, CVE
      // hardening), so route through the .ps1 shim or cmd.exe explicitly.
      const npmDir = join(process.env.APPDATA || "", "npm");
      const dshPs1 = join(npmDir, "dsh.ps1");
      if (existsSync(dshPs1)) {
        const args = [...shellArgs, "-ExecutionPolicy", "Bypass", "-File", dshPs1, "web"];
        return { exe: "powershell.exe", args, cwd: root, display: `powershell.exe ${args.map(q).join(" ")}` };
      }
      const dshCmd = join(npmDir, "dsh.cmd");
      if (existsSync(dshCmd)) {
        return {
          exe: "cmd.exe",
          args: ["/d", "/s", "/c", `"${dshCmd}" web`],
          cwd: root,
          spawnOptions: { windowsVerbatimArguments: true },
          display: `cmd.exe /c ${q(dshCmd)} web`,
        };
      }
      const npxArgs = ["--yes", "@deepseek-ai/dsh@latest", "web"];
      if (process.platform === "win32") {
        // npx.cmd hits the same EINVAL restriction — let PowerShell resolve it.
        const script = `npx ${npxArgs.join(" ")}`;
        return { exe: "powershell.exe", args: [...shellArgs, "-Command", script], cwd: root, display: `powershell.exe -Command "${script}"` };
      }
      return { exe: "npx", args: npxArgs, cwd: root, display: `npx ${npxArgs.join(" ")}` };
    }
    default:
      return null;
  }
}

export function createClientManager({ upstream = () => null } = {}) {
  // id -> { state: "idle"|"connected"|"simulated"|"error", at, message, pid }
  const clients = new Map();

  function mark(id, patch) {
    clients.set(id, { state: "idle", at: new Date().toISOString(), message: null, pid: null, ...(clients.get(id) || {}), ...patch });
  }

  async function connect({ client = "", model = null, workspace = null, prompt = "" } = {}) {
    const spec = clientById(String(client || "").trim());
    if (!spec) {
      return {
        ok: false,
        error: "unknown_client",
        message: `不明なクライアント: 「${client || "?"}」。対応: ${CLIENTS.map((c) => c.id).join(" / ")}`,
        supported: CLIENTS.map((c) => c.id),
      };
    }

    // Contract: a workspace client connects to a *running* server (via the
    // 8090 gateway in the real setup). The simulation mock counts as running.
    // Exception: standalone clients (ComfyUI) run their own server on their
    // own port, exactly like select-model.ps1, so they open regardless.
    const runtime = upstream() || {};
    if (runtime.status !== "running" && !spec.standalone) {
      return {
        ok: false,
        error: "server_not_running",
        message: `「${spec.label}」の起動には実行中の llama-server が必要です（先にモデルを起動してください）。`,
        client: spec.id,
      };
    }

    const plan = windowsPlan(spec, { model: model || runtime.model, workspace, prompt });
    if (!plan) {
      return { ok: false, error: "no_launcher", message: `「${spec.label}」の起動方法が未定義です。`, client: spec.id };
    }
    const guardNote = vramGuardNote(spec.id, runtime);

    if (process.platform === "win32") {
      try {
        const child = spawn(plan.exe, plan.args, {
          cwd: plan.cwd,
          detached: true,
          stdio: "ignore",
          ...(plan.spawnOptions || {}),
        });
        child.unref();
        mark(spec.id, { state: "connected", pid: child.pid, message: `${spec.label} を起動しました` });
        return {
          ok: true,
          simulated: false,
          client: spec.id,
          pid: child.pid,
          command: plan.display,
          message: `${guardNote ? guardNote + "\n" : ""}「${spec.label}」を起動しました（pid ${child.pid}）。接続先: ${CLIENT_BASE_URL}`,
        };
      } catch (error) {
        mark(spec.id, { state: "error", pid: null, message: errorMessage(error) });
        return { ok: false, error: "spawn_failed", message: `「${spec.label}」の起動に失敗: ${errorMessage(error)}`, client: spec.id };
      }
    }

    // Preview / sandbox: full contract validation, no client binary exists here.
    mark(spec.id, { state: "simulated", pid: null, message: `${spec.label}（シミュレーション）` });
    return {
      ok: true,
      simulated: true,
      client: spec.id,
      command: plan.display,
      message:
        `${guardNote ? guardNote + "\n" : ""}` +
        `（シミュレーション）Windows ランタイムでは「${spec.label}」を次で起動します: ${plan.display}。` +
        `このプレビューではクライアント本体は起動しません。`,
    };
  }

  // Probe every client that runs its own HTTP server (web-kind with a health
  // config). Returns one entry per client: up / latency / statusCode / error.
  // On Windows this tells the GUI "ComfyUI came up on :8188"; in the sandbox
  // connection-refused is reported truthfully (up: false).
  // Probes run in parallel: three down clients at a 2.5s timeout each must not
  // serialize into ~8s and overlap the next poll interval.
  async function checkHealth({ timeoutMs = 2500 } = {}) {
    const out = await Promise.all(CLIENTS.map(async (spec) => {
      const url = healthUrlFor(spec);
      if (!url) {
        return { id: spec.id, checked: false, up: null, url: null, latencyMs: null, statusCode: null, error: "no_health_check" };
      }
      const started = Date.now();
      try {
        const res = await fetch(url, { signal: AbortSignal.timeout(timeoutMs), redirect: "follow" });
        return {
          id: spec.id,
          checked: true,
          up: res.ok,
          url,
          latencyMs: Date.now() - started,
          statusCode: res.status,
          error: res.ok ? null : `HTTP ${res.status}`,
        };
      } catch (error) {
        return {
          id: spec.id,
          checked: true,
          up: false,
          url,
          latencyMs: Date.now() - started,
          statusCode: null,
          error: errorMessage(error),
        };
      }
    }));
    return out;
  }

  function summary() {
    return CLIENTS.map((c) => {
      const s = clients.get(c.id);
      return {
        id: c.id,
        label: c.label,
        desc: c.desc,
        kind: c.kind,
        port: clientPort(c),
        state: s?.state || "idle",
        at: s?.at ?? null,
        message: s?.message ?? null,
        pid: s?.pid ?? null,
        standalone: c.standalone === true,
        healthUrl: healthUrlFor(c),
      };
    });
  }

  return { connect, summary, checkHealth };
}

function errorMessage(error) {
  return error instanceof Error ? error.message : String(error);
}
