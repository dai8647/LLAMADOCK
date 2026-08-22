import test from "node:test";
import assert from "node:assert/strict";

import { comfyLaunchArgs, vramGuardNote } from "./client-manager.js";

const spec = { id: "ComfyUI", port: 8188 };

test("comfyLaunchArgs mirrors the CLI default (--reserve-vram)", () => {
  delete process.env.LLAMADOCK_COMFY_FLAGS;
  assert.deepEqual(comfyLaunchArgs(spec), [
    "main.py", "--port", "8188", "--listen", "127.0.0.1", "--reserve-vram", "1.0",
  ]);
});

test("LLAMADOCK_COMFY_FLAGS overrides extras like the CLI launcher", () => {
  process.env.LLAMADOCK_COMFY_FLAGS = "--fast fp16_accumulation";
  try {
    assert.deepEqual(comfyLaunchArgs(spec), [
      "main.py", "--port", "8188", "--listen", "127.0.0.1", "--fast", "fp16_accumulation",
    ]);
  } finally {
    delete process.env.LLAMADOCK_COMFY_FLAGS;
  }
});

test("vramGuardNote fires only for ComfyUI while llama-server runs", () => {
  assert.match(vramGuardNote("ComfyUI", { status: "running", model: "m.gguf" }), /VRAM 競合/);
  assert.equal(vramGuardNote("ComfyUI", { status: "idle" }), "");
  assert.equal(vramGuardNote("WebUI", { status: "running" }), "");
});
