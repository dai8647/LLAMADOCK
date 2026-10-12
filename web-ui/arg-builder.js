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

// --- Engine help parsing / unsupported-argument filtering -------------------
// Mirrors Remove-UnsupportedEngineArgs in select-model.ps1, but the accept
// list is read from the engine's own --help instead of a hand-kept flag list.
// The schema defaults are written for the whole llama.cpp family, so on a
// build that lacks an option ("--moe-expert-placement") or an enum member
// ("--spec-type off", "-t auto") llama-server exits with a parse error before
// it ever binds a port, which looks like a hung launch in the GUI.

const NUMERIC_USAGE = /^(?:N|P|INT|NUM|NUMBER|FLOAT|DECIMAL|FRACTION|SECONDS|MS|COUNT)$/i;

function isNumeric(value) {
  return /^-?\d+(?:\.\d+)?$/.test(String(value));
}

function isValueLike(token) {
  const t = String(token);
  return !t.startsWith("-") || /^-?\d/.test(t);
}

// "a, b, c" | "a,b,c" | "[a|b|c]" | "{none,layer,row}" -> list, or null when
// the slot is a placeholder list ("TOOL1,TOOL2,...") rather than a real enum.
function splitEnum(raw) {
  const text = String(raw || "").trim();
  if (!text || text.includes("...")) return null;
  const inner = text.replace(/^\[|\]$/g, "").replace(/^\{|\}$/g, "");
  if (!/[,|]/.test(inner)) return null;
  if (/\s/.test(inner)) return null;
  const parts = inner.split(/[,|]/).map((s) => s.trim()).filter(Boolean);
  return parts.length > 1 ? parts : null;
}

// Index every option the engine advertises: flag name -> { usage, desc,
// allowedValues, enumValues }. Returns null when the text is not a help dump
// (the caller then skips filtering rather than guessing).
//
// llama.cpp aligns its help in columns: option lines start at column 0, the
// usage token follows a single space and the description is separated by a
// padded gap, while wrapped description lines are indented. Option lines were
// confirmed to carry no leading indent at all.
export function parseHelpOptions(helpText) {
  const lines = String(helpText || "").split(/\r?\n/);
  if (lines.length < 40) return null;
  const options = new Map();
  let current = null;
  for (const line of lines) {
    if (line.trim() === "") {
      current = null;
      continue;
    }
    const head = /^(-{1,2}\S.*)$/.exec(line);
    if (head) {
      let rest = head[1];
      const flags = [];
      for (;;) {
        const m = /^(-{1,2}[A-Za-z0-9][A-Za-z0-9-]*)(,)?/.exec(rest);
        if (!m) break;
        flags.push(m[1]);
        rest = rest.slice(m[0].length);
        const ws = /^\s+/.exec(rest);
        if (!ws || !/^-{1,2}[A-Za-z0-9]/.test(rest.slice(ws[0].length))) break;
        rest = rest.slice(ws[0].length);
      }
      if (flags.length === 0) {
        current = null;
        continue;
      }
      let usage = "";
      let desc = "";
      if (/^\s{2,}/.test(rest)) {
        desc = rest.trim();
      } else {
        rest = rest.replace(/^\s/, "");
        const gap = /\s{2,}/.exec(rest);
        if (gap) {
          usage = rest.slice(0, gap.index).trim();
          desc = rest.slice(gap.index).trim();
        } else {
          usage = rest.trim();
        }
      }
      current = { usage, desc };
      for (const flag of flags) options.set(flag, current);
      continue;
    }
    if (current && /^\s{4,}\S/.test(line)) {
      current.desc = `${current.desc} ${line.trim()}`.trim();
    }
  }
  if (options.size < 30) return null;
  for (const opt of options.values()) {
    const allowed = /allowed values:\s*([^(\n]+)/i.exec(opt.desc);
    opt.allowedValues = allowed
      ? allowed[1].split(",").map((s) => s.trim()).filter(Boolean)
      : null;
    opt.enumValues = splitEnum(opt.usage);
  }
  return options;
}

function valueRejected(opt, value) {
  const v = String(value);
  if (opt.allowedValues) {
    return !opt.allowedValues.some((a) => a.toLowerCase() === v.toLowerCase());
  }
  if (opt.enumValues) {
    if (opt.enumValues.some((e) => e.toLowerCase() === v.toLowerCase())) return false;
    // "{none,auto}" style slots also take a literal number (e.g. --moe-cache-mib).
    if (opt.enumValues.some((e) => NUMERIC_USAGE.test(e)) && isNumeric(v)) return false;
    return true;
  }
  if (NUMERIC_USAGE.test(opt.usage)) {
    if (isNumeric(v)) return false;
    // --gpu-layers documents "either an exact number, 'auto', or 'all'".
    if (/(?:^|['"\s])(?:auto|all)(?:['"\s]|$)/i.test(opt.desc)) return false;
    return true;
  }
  return false;
}

// Drop the arguments the given engine build would refuse, keeping the rest.
// Positional tokens, unknown-but-harmless shapes and anything we cannot
// classify are passed through: the engine stays the final judge, we only
// remove the things that are provably rejected from its own help text.
export function filterUnsupportedArgs(args, helpText) {
  const list = Array.isArray(args) ? args.map(String) : [];
  const options = parseHelpOptions(helpText);
  if (!options) return { args: list, dropped: [] };
  const out = [];
  const dropped = [];
  for (let i = 0; i < list.length; i++) {
    const token = list[i];
    if (!token.startsWith("-")) {
      out.push(token);
      continue;
    }
    let flag = token;
    let inline = null;
    const eq = token.indexOf("=");
    if (token.startsWith("--") && eq > 1) {
      flag = token.slice(0, eq);
      inline = token.slice(eq + 1);
    }
    const opt = options.get(flag);
    if (!opt) {
      dropped.push(token);
      if (inline === null && i + 1 < list.length && isValueLike(list[i + 1])) {
        i += 1;
        dropped.push(list[i]);
      }
      continue;
    }
    if (inline !== null) {
      if (valueRejected(opt, inline)) dropped.push(token);
      else out.push(token);
      continue;
    }
    if (!opt.usage) {
      out.push(token);
      continue;
    }
    const next = i + 1 < list.length ? list[i + 1] : null;
    if (next === null || !isValueLike(next)) {
      out.push(token);
      continue;
    }
    i += 1;
    if (valueRejected(opt, next)) dropped.push(`${token} ${next}`);
    else out.push(token, next);
  }
  return { args: out, dropped };
}
