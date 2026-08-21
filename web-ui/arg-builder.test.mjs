import test from "node:test";
import assert from "node:assert/strict";

import { resolveParams, buildArgs, allParams } from "./arg-builder.js";

const schema = {
  groups: [
    {
      id: "load",
      params: [
        { id: "context_tokens", type: "int", flags: ["-c"], default: 32768, per_model: true },
        { id: "flash_attn", type: "bool", flags: ["-fa"], default: false, per_model: true },
        {
          id: "cache_type_v",
          type: "select",
          flags: ["-ctv"],
          default: "q8_0",
          per_model: true,
          allowed: ["q8_0", "q4_0", "none"],
          allow_custom: true,
        },
        {
          id: "moe_experts_count",
          type: "int",
          flag_value: "--override-kv llama.expert_used_count=int:{value}",
          default: "",
          per_model: true,
        },
        {
          id: "chat_template_kwargs",
          type: "text",
          flag_value: "env LLAMA_ARG_CHAT_TEMPLATE_KWARGS={value}",
          default: "",
          per_model: true,
        },
        { id: "engine", type: "select", flags: [], default: "Auto" },
      ],
    },
  ],
};

test("resolveParams precedence: overrides > memory > profile > default", () => {
  const modelsConfig = {
    _profiles: [{ match: ["(?i)TQ3"], context_tokens: 16384, cache_type_v: "q4_0" }],
    models: { "X-TQ3.gguf": { context_tokens: 8192 } },
  };
  const resolved = resolveParams(schema, {
    modelName: "X-TQ3.gguf",
    modelsConfig,
    overrides: { flash_attn: true },
  });
  assert.equal(resolved.context_tokens, 8192); // memory beats profile
  assert.equal(resolved.cache_type_v, "q4_0"); // profile fills the rest
  assert.equal(resolved.flash_attn, true); // override wins
  assert.equal(resolved.engine, "Auto"); // default fallback
});

test("compilePattern strips PowerShell (?i) prefix", () => {
  const modelsConfig = { _profiles: [{ match: ["(?i)tq3"], engine: "TurboTan" }], models: {} };
  const resolved = resolveParams(schema, { modelName: "Model-TQ3_4S.gguf", modelsConfig });
  assert.equal(resolved.engine, "TurboTan");
});

test("buildArgs: bool emits bare flag only when truthy", () => {
  const { args } = buildArgs(schema, { ...blank(), flash_attn: true }, {});
  assert.ok(args.includes("-fa"));
  const off = buildArgs(schema, { ...blank(), flash_attn: false }, {}).args;
  assert.ok(!off.includes("-fa"));
});

test("buildArgs: flag_value splits into argv tokens", () => {
  const { args } = buildArgs(schema, { ...blank(), moe_experts_count: 8 }, {});
  const i = args.indexOf("--override-kv");
  assert.notEqual(i, -1);
  assert.equal(args[i + 1], "llama.expert_used_count=int:8");
});

test("buildArgs: env flag_value becomes env var, not argv", () => {
  const { args, env } = buildArgs(
    schema,
    { ...blank(), chat_template_kwargs: '{"enable_thinking":false}' },
    {},
  );
  assert.equal(env.LLAMA_ARG_CHAT_TEMPLATE_KWARGS, '{"enable_thinking":false}');
  assert.ok(!args.some((a) => a.includes("LLAMA_ARG")));
});

test("buildArgs: host/port appended last", () => {
  const { args } = buildArgs(schema, blank(), { host: "127.0.0.1", port: 8080 });
  assert.deepEqual(args.slice(-4), ["--host", "127.0.0.1", "--port", "8080"]);
});

test("allParams flattens groups", () => {
  assert.equal(allParams(schema).length, 6);
});

function blank() {
  return Object.fromEntries(allParams(schema).map((p) => [p.id, p.default]));
}
