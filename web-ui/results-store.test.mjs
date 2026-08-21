import test from "node:test";
import assert from "node:assert/strict";
import { writeFile, rm, mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { fingerprint, loadResults, addRun, summarize } from "./results-store.js";

test("fingerprint is key-order independent", () => {
  assert.equal(fingerprint({ a: 1, b: 2 }), fingerprint({ b: 2, a: 1 }));
  assert.notEqual(fingerprint({ a: 1 }), fingerprint({ a: 2 }));
});

test("addRun accumulates per config and rollup counts", async () => {
  const dir = await mkdtemp(join(tmpdir(), "llamadock-test-"));
  const path = join(dir, "run-results.json");
  const base = { model: "m.gguf", engine: "TurboTan", params: { context_tokens: 4096 } };
  for (const tps of [10, 20]) {
    await addRun(path, { ...base, ok: true, tokensPerSec: tps, elapsedMs: 100 });
  }
  await addRun(path, { ...base, ok: false, elapsedMs: 5, error: "boom" });
  const results = await loadResults(path);
  assert.equal(results.configs.length, 1);
  assert.equal(results.configs[0].okCount, 2);
  assert.equal(results.configs[0].failCount, 1);
  assert.equal(results.configs[0].bestTps, 20);
  await rm(dir, { recursive: true, force: true });
});

test("different engines stay separate configs", async () => {
  const dir = await mkdtemp(join(tmpdir(), "llamadock-test-"));
  const path = join(dir, "run-results.json");
  const params = { context_tokens: 4096 };
  await addRun(path, { model: "m.gguf", engine: "A", params, ok: true, tokensPerSec: 9, elapsedMs: 1 });
  await addRun(path, { model: "m.gguf", engine: "B", params, ok: true, tokensPerSec: 9, elapsedMs: 1 });
  const summary = summarize(await loadResults(path));
  assert.equal(summary.models[0].configCount, 2);
  await rm(dir, { recursive: true, force: true });
});

test("summarize recommends the fastest qualified config (minRuns)", () => {
  const results = {
    configs: [
      mkConfig("fast", 30, 3),
      mkConfig("slow-but-qualified", 20, 4),
      mkConfig("unqualified", 99, 2),
    ],
  };
  const summary = summarize(results, { minRuns: 3 });
  assert.equal(summary.models[0].recommended.key, "fast");
  assert.equal(summary.models[0].qualified.length, 2);
});

test("runs are capped at MAX_RUNS_PER_CONFIG=100", async () => {
  const dir = await mkdtemp(join(tmpdir(), "llamadock-test-"));
  const path = join(dir, "run-results.json");
  for (let i = 0; i < 130; i += 1) {
    await addRun(path, { model: "m.gguf", engine: "A", params: {}, ok: true, tokensPerSec: 1, elapsedMs: 1 });
  }
  const results = await loadResults(path);
  assert.equal(results.configs[0].runs.length, 100);
  // rollup reflects only kept runs
  assert.equal(results.configs[0].okCount, 100);
  await rm(dir, { recursive: true, force: true });
});

function mkConfig(key, tps, okRuns) {
  return {
    model: "m.gguf",
    engine: "E",
    key,
    params: {},
    runs: Array.from({ length: okRuns }, () => ({ at: "t", ok: true, tokensPerSec: tps })),
    okCount: okRuns,
    failCount: 0,
    bestTps: tps,
    lastAt: "t",
  };
}
