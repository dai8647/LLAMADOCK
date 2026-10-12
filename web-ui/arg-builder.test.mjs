import test from "node:test";
import assert from "node:assert/strict";

import { resolveParams, buildArgs, allParams, filterUnsupportedArgs, parseHelpOptions } from "./arg-builder.js";

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

// --- filterUnsupportedArgs: engine-help-driven argv filtering ---------------
// Shaped like the real llama.cpp dump: option lines at column 0, single space
// before the usage token, padded gap before the description, wrapped
// description lines indented. >= 30 options / >= 40 lines so parseHelpOptions
// accepts the text instead of bailing out.
function cannedHelp() {
  const lines = ["----- common params -----", ""];
  lines.push("-t,    --threads N                      number of CPU threads to use during generation (default: -1)");
  lines.push("                                          (env: LLAMA_ARG_THREADS)");
  lines.push("-tb,   --threads-batch N                number of threads to use during batch and prompt processing");
  lines.push("-ngl,  --gpu-layers, --n-gpu-layers N   max. number of layers to store in VRAM, either an exact number,");
  lines.push("                                          'auto', or 'all' (default: auto)");
  lines.push("-ctk,  --cache-type-k TYPE              KV cache data type for K");
  lines.push("                                          allowed values: f32, f16, bf16, q8_0, q4_0, q5_1");
  lines.push("                                          (default: f16)");
  lines.push("-ctkd, --cache-type-k-draft TYPE        KV cache data type for K for the draft model");
  lines.push("                                          allowed values: f32, f16, bf16, q8_0, q4_0, q5_1");
  lines.push("-fa,   --flash-attn [on|off|auto]       set Flash Attention use ('on', 'off', or 'auto')");
  lines.push("--spec-type none,draft-simple,draft-eagle3,draft-mtp");
  lines.push("                                          comma-separated list of speculative decoding types");
  lines.push("--spec-draft-p-min, --draft-p-min P     minimum speculative decoding probability (default: 0.00)");
  lines.push("--moe-cache-mib N|auto                  size of the MoE cache, or 'auto' to derive it");
  lines.push("--version                               show version and build info");
  lines.push("--tools TOOL1,TOOL2,...                 enable built-in tools for AI agents");
  lines.push("-rea,  --reasoning [on|off|auto]        use reasoning/thinking in the chat");
  lines.push("--seed INT                              seed for random number generation (default: -1)");
  lines.push("--host IP                              IP address to bind to (default: 127.0.0.1)");
  lines.push("--port PORT                            port to listen on (default: 8080)");
  for (let i = 0; i < 24; i++) lines.push(`--filler-${i} N                          filler option ${i} for the parser`);
  lines.push("");
  return lines.join("\n");
}

test("parseHelpOptions: usage, description, allowed values and enums", () => {
  const opts = parseHelpOptions(cannedHelp());
  assert.ok(opts, "help dump should parse");
  assert.equal(opts.get("-t").usage, "N");
  assert.match(opts.get("-t").desc, /CPU threads/);
  assert.deepEqual(opts.get("-ctk").allowedValues, ["f32", "f16", "bf16", "q8_0", "q4_0", "q5_1"]);
  assert.deepEqual(opts.get("--spec-type").enumValues, ["none", "draft-simple", "draft-eagle3", "draft-mtp"]);
  assert.equal(opts.get("--tools").enumValues, null, "'...' placeholders are not an enum");
  assert.ok(opts.get("-ngl").desc.includes("'auto'"));
  assert.equal(parseHelpOptions("not a help dump"), null);
});

test("filterUnsupportedArgs drops unknown flags together with their value", () => {
  const { args, dropped } = filterUnsupportedArgs(
    ["model.gguf", "--moe-expert-placement", "all-gpu", "-t", "8"],
    cannedHelp(),
  );
  assert.deepEqual(args, ["model.gguf", "-t", "8"]);
  assert.deepEqual(dropped, ["--moe-expert-placement", "all-gpu"]);
});

test("filterUnsupportedArgs drops auto for a numeric slot unless documented", () => {
  const drop = filterUnsupportedArgs(["-t", "auto", "-tb", "auto"], cannedHelp());
  assert.deepEqual(drop.args, []);
  assert.deepEqual(drop.dropped, ["-t auto", "-tb auto"]);
  // -ngl documents 'auto', so it must survive even though its usage is N.
  const keep = filterUnsupportedArgs(["-ngl", "auto", "--moe-cache-mib", "auto"], cannedHelp());
  assert.deepEqual(keep.args, ["-ngl", "auto", "--moe-cache-mib", "auto"]);
  assert.deepEqual(keep.dropped, []);
});

test("filterUnsupportedArgs rejects values outside enums and allowed lists", () => {
  const { args, dropped } = filterUnsupportedArgs(
    ["--spec-type", "off", "-ctkd", "auto", "-ctk", "q8_0", "-fa", "on"],
    cannedHelp(),
  );
  assert.deepEqual(args, ["-ctk", "q8_0", "-fa", "on"]);
  assert.deepEqual(dropped, ["--spec-type off", "-ctkd auto"]);
});

test("filterUnsupportedArgs keeps negatives, positionals and unknown help", () => {
  const argv = ["C:\\models\\x.gguf", "--seed", "-1", "--host", "127.0.0.1"];
  assert.deepEqual(filterUnsupportedArgs(argv, "").args, argv, "no help -> untouched");
  assert.deepEqual(filterUnsupportedArgs(argv, cannedHelp()).args, argv);
});

function blank() {
  return Object.fromEntries(allParams(schema).map((p) => [p.id, p.default]));
}
