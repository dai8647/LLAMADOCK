// LlamaDock — run-results.json store + qualification logic (Phase 4).
// ---------------------------------------------------------------------------
// Accumulates measured runs per model + configuration fingerprint into
// config/run-results.json (gitignored). A configuration only becomes
// "recommended (measured)" once it has minRuns successful runs — the policy
// from PARAMETER-CATALOG.md: recommendations are hypotheses backed by
// measurement, never assertions.
//
// File shape:
// {
//   "version": 1,
//   "updated": "...",
//   "configs": [{
//     "model": "Qwen3.5-9B-Q5_K_M.gguf",
//     "engine": "TurboTan",
//     "key": "cache_ram_mib=8192|context_tokens=16384|...",
//     "params": { ...resolved values for this run... },
//     "runs": [{ "at", "ok", "tokensPerSec", "vramGb", "ramGb",
//                "promptTokens", "completionTokens", "elapsedMs", "error" }],
//     "okCount", "failCount", "bestTps", "lastAt"
//   }]
// }
// ---------------------------------------------------------------------------

import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname } from "node:path";

export function fingerprint(params) {
  return Object.keys(params || {})
    .sort()
    .map((k) => `${k}=${params[k]}`)
    .join("|");
}

export async function loadResults(path) {
  try {
    return JSON.parse(await readFile(path, "utf8"));
  } catch {
    return { version: 1, updated: null, configs: [] };
  }
}

export async function addRun(path, run) {
  const results = await loadResults(path);
  // The fingerprint identifies the *configuration* — the engine is part of it,
  // otherwise the same params measured on two different runtimes would merge
  // into one config and produce a misleading recommendation.
  const key = fingerprint({ engine: run.engine || "", ...run.params });
  let config = results.configs.find((c) => c.model === run.model && c.key === key);
  if (!config) {
    config = {
      model: run.model,
      engine: run.engine || null,
      key,
      params: run.params || {},
      runs: [],
    };
    results.configs.push(config);
  }

  const entry = {
    at: new Date().toISOString(),
    ok: !!run.ok,
    tokensPerSec: Number.isFinite(run.tokensPerSec) ? Math.round(run.tokensPerSec * 100) / 100 : null,
    vramGb: run.vramGb ?? null,
    ramGb: run.ramGb ?? null,
    promptTokens: run.promptTokens ?? null,
    completionTokens: run.completionTokens ?? null,
    elapsedMs: Math.round(run.elapsedMs || 0),
    error: run.error || null,
  };
  config.runs.push(entry);
  rollup(config);
  results.updated = new Date().toISOString();

  await mkdir(dirname(path), { recursive: true });
  const tmp = `${path}.tmp`;
  await writeFile(tmp, `${JSON.stringify(results, null, 2)}\n`, "utf8");
  await rename(tmp, path);
  return { results, config };
}

function rollup(config) {
  const ok = config.runs.filter((r) => r.ok);
  config.okCount = ok.length;
  config.failCount = config.runs.length - ok.length;
  config.bestTps = ok.length ? Math.max(...ok.map((r) => r.tokensPerSec ?? 0)) : null;
  config.lastAt = config.runs.length ? config.runs[config.runs.length - 1].at : null;
}

// Per model: which configs qualify (okCount >= minRuns) and which qualified
// config is the fastest. The fastest qualified config becomes "recommended".
export function summarize(results, { minRuns = 3 } = {}) {
  const byModel = new Map();
  for (const config of results?.configs || []) {
    if (!byModel.has(config.model)) byModel.set(config.model, []);
    byModel.get(config.model).push(config);
  }

  const models = [];
  for (const [model, configs] of byModel) {
    const qualified = configs
      .filter((c) => c.okCount >= minRuns)
      .sort((a, b) => (b.bestTps ?? 0) - (a.bestTps ?? 0));
    models.push({
      model,
      configCount: configs.length,
      okRuns: configs.reduce((n, c) => n + c.okCount, 0),
      failRuns: configs.reduce((n, c) => n + c.failCount, 0),
      qualified: qualified.map((c) => ({
        key: c.key,
        engine: c.engine,
        bestTps: c.bestTps,
        okCount: c.okCount,
        failCount: c.failCount,
        params: c.params,
      })),
      recommended: qualified.length
        ? {
            key: qualified[0].key,
            engine: qualified[0].engine,
            bestTps: qualified[0].bestTps,
            okCount: qualified[0].okCount,
            params: qualified[0].params,
          }
        : null,
    });
  }
  models.sort((a, b) => a.model.localeCompare(b.model));
  return { minRuns, updated: results?.updated ?? null, models };
}
