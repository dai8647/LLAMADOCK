// LlamaDock — schema-driven argument builder.
// ---------------------------------------------------------------------------
// Phase 1/2 core, implemented in Node so it is testable on every platform.
// Reads config/params-schema.json and turns a resolved parameter set into the
// llama-server argument vector + environment, mirroring the GUI preview in
// app.js exactly (resolution order: overrides -> per-model memory -> _profiles
// pattern -> schema default).
// ---------------------------------------------------------------------------

export function allParams(schema) {
  return (schema?.groups || []).flatMap((g) => g.params || []);
}

export function paramById(schema, id) {
  return allParams(schema).find((p) => p.id === id);
}

function hasOwn(obj, key) {
  return Object.prototype.hasOwnProperty.call(obj, key);
}

// Patterns may carry PowerShell-style "(?i)" inline flags, which are invalid
// in JS. The "i" flag is applied here, so strip the prefix before compiling.
function compilePattern(pattern) {
  return new RegExp(String(pattern || "").replace(/^\(\?i\)/, ""), "i");
}

function matchProfile(profiles, modelName) {
  for (const profile of profiles || []) {
    const matches = (profile.match || []).every((pat) => {
      try {
        return compilePattern(pat).test(modelName);
      } catch {
        return false;
      }
    });
    if (matches) return profile;
  }
  return null;
}

// Resolve the effective value for every schema param.
//   overrides  -> session edits (includes preset-applied values from the UI)
//   modelsConfig.models[model] -> per-model memory
//   modelsConfig._profiles     -> family patterns
//   schema default             -> fallback
export function resolveParams(schema, { modelName = null, modelsConfig = null, overrides = {} } = {}) {
  const resolved = {};
  for (const param of allParams(schema)) {
    let value;
    if (hasOwn(overrides, param.id)) {
      value = overrides[param.id];
    } else if (modelName) {
      const mem = modelsConfig?.models?.[modelName];
      if (mem && hasOwn(mem, param.id)) {
        value = mem[param.id];
      } else {
        const profile = matchProfile(modelsConfig?._profiles, modelName);
        if (profile && hasOwn(profile, param.id)) value = profile[param.id];
      }
    }
    if (value === undefined) value = param.default;
    resolved[param.id] = value;
  }
  return resolved;
}

export function isTruthyBool(value) {
  return value === true || value === "true" || value === "on" || value === 1 || value === "1";
}

// Build the llama-server argument vector + env for a resolved parameter set.
//   model -> positional model path (first argument)
//   port / host -> appended as --port / --host
// Special handling:
//   - type=bool        -> flag only when truthy
//   - flag_value       -> custom template; "env KEY={value}" becomes an env var
//   - params without flags (engine/preset/mcp_mode/...) -> never emitted
export function buildArgs(schema, resolved, { model = null, port = null, host = null } = {}) {
  const args = [];
  const env = {};
  if (model) args.push(model);

  for (const param of allParams(schema)) {
    const value = resolved[param.id];
    if (value === undefined || value === null || value === "") continue;

    if (param.type === "bool") {
      if (isTruthyBool(value)) args.push(param.flags[0]);
      continue;
    }

    if (param.flag_value) {
      const rendered = param.flag_value.replaceAll("{value}", String(value));
      if (rendered.startsWith("env ")) {
        const eq = rendered.slice(4).indexOf("=");
        if (eq > 0) {
          const key = rendered.slice(4, 4 + eq).trim();
          const val = rendered.slice(4 + eq + 1).trim();
          env[key] = val;
        }
      } else {
        args.push(...rendered.split(/\s+/).filter(Boolean));
      }
      continue;
    }

    if (!param.flags || param.flags.length === 0) continue;
    args.push(param.flags[0], String(value));
  }

  if (host) args.push("--host", String(host));
  if (port) args.push("--port", String(port));
  return { args, env };
}
