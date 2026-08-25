/* LlamaDock Web GUI — schema-driven control panel
 * Loads config/params-schema.json + memory-presets.json + model-notes.json
 * from the API, auto-generates the parameter form, applies presets, renders
 * the effective llama-server arguments, and persists per-model memory.
 */
(() => {
  "use strict";

  const $ = (sel) => document.querySelector(sel);
  const $$ = (sel) => [...document.querySelectorAll(sel)];

  const state = {
    schema: null,
    presets: null,
    modelNotes: [],
    modelsConfig: { _profiles: [], models: {} },
    customModels: loadCustomModels(),
    selectedModel: null,
    overrides: {},          // edits made in this session for the selected model
    appliedPresetId: null,
    saveTimer: null,
    saveChain: Promise.resolve(), // serializes per-model saves (no lost updates)
    argString: "",
    health: {},             // client id -> latest /api/clients/health entry
    lastClients: [],        // last /api/status clients, for health re-render
    runningModel: null,     // model currently reported as running by /api/status
    pollFails: 0,           // consecutive /api/status failures -> offline banner
    ggufIndex: new Map(),   // lowercase name -> {name,sizeGb,path} from /api/models/scan
  };

  const CUSTOM_MODELS_KEY = "llamadock.customModels.v1";
  const GROUP_OPEN_KEY = "llamadock.groupsOpen.v1";
  const initialOpenGroups = (() => {
    try { return JSON.parse(localStorage.getItem(GROUP_OPEN_KEY) || "{}"); } catch { return {}; }
  })();

  function loadCustomModels() {
    try { return JSON.parse(localStorage.getItem(CUSTOM_MODELS_KEY) || "[]"); } catch { return []; }
  }
  function persistCustomModels() {
    localStorage.setItem(CUSTOM_MODELS_KEY, JSON.stringify(state.customModels));
  }

  /* ---------- tiny helpers ---------- */

  function esc(value) {
    return String(value ?? "")
      .replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;")
      .replaceAll('"', "&quot;").replaceAll("'", "&#39;");
  }

  let toastTimer = null;
  function toast(message, tone = "") {
    const el = $("#toast");
    el.textContent = message;
    el.className = `toast ${tone}`;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => el.classList.add("hidden"), 4200);
  }

  async function api(path, options = {}) {
    const res = await fetch(path, {
      headers: { "Content-Type": "application/json" },
      ...options,
    });
    return res.json();
  }

  function engineForModel(name) {
    const n = name.toLowerCase();
    // MiniMax H3 is a ComfyUI diffusion model (video/audio DiT), not a
    // llama-server text model — never guess a llama.cpp engine for it.
    if (/minimax.?h3|minimax_h3|fl2va|ref2va/.test(n)) return "ComfyUI (DiT)";
    // Same routing order as select-model.ps1's Get-RequiredEngine:
    // Ternary before DeepSeek so REAP/TQ3-mixed names route correctly.
    if (/ternary|bonsai/.test(n)) return "PrismBonsai";
    if (/deepseek|ds4-compact|reap[-_ ]?k128|laguna/.test(n)) return "ExpertsLaguna";
    if (/tq3_4s|tq3/.test(n)) return "TurboTan";
    if (/longcat/.test(n)) return "LongCat";
    if (/dflash2/.test(n)) return "DFlash2";
    return "AtomicBot";
  }

  // model-notes.json patterns carry PowerShell-style "(?i)" inline flags,
  // which are invalid in JavaScript regexes. The "i" flag is already applied
  // here, so strip the prefix before compiling — otherwise every note fails
  // to match and the warnings/presets never show.
  function compileNotePattern(pattern) {
    return new RegExp(String(pattern || "").replace(/^\(\?i\)/, ""), "i");
  }

  function notesForModel(name) {
    for (const note of state.modelNotes || []) {
      try {
        if (compileNotePattern(note.pattern).test(name)) return note;
      } catch { /* ignore broken pattern */ }
    }
    return null;
  }

  function allParams() {
    return (state.schema?.groups || []).flatMap((g) => g.params || []);
  }
  function paramById(id) {
    return allParams().find((p) => p.id === id);
  }

  /* ---------- effective value resolution ----------
   * order: session overrides → per-model memory → _profiles pattern match
   *        → schema default */
  function effectiveValue(paramId) {
    if (Object.prototype.hasOwnProperty.call(state.overrides, paramId)) {
      return state.overrides[paramId];
    }
    const modelName = state.selectedModel;
    if (modelName) {
      const mem = state.modelsConfig?.models?.[modelName];
      if (mem && Object.prototype.hasOwnProperty.call(mem, paramId)) return mem[paramId];
      for (const profile of state.modelsConfig?._profiles || []) {
        const matches = (profile.match || []).every((pat) => {
          try { return compileNotePattern(pat).test(modelName); } catch { return false; }
        });
        if (matches && Object.prototype.hasOwnProperty.call(profile, paramId)) return profile[paramId];
      }
    }
    const param = paramById(paramId);
    return param ? param.default : undefined;
  }

  function setOverride(paramId, value) {
    state.overrides[paramId] = value;
    refresh();
    scheduleSave();
  }

  function scheduleSave() {
    clearTimeout(state.saveTimer);
    state.saveTimer = setTimeout(savePerModelMemory, 500);
  }

  async function savePerModelMemory() {
    if (!state.selectedModel) return;
    const model = state.selectedModel;
    const perModel = {};
    for (const [id, value] of Object.entries(state.overrides)) {
      const p = paramById(id);
      if (p && p.per_model) perModel[id] = value;
    }
    // Serialize saves: a flush on model switch and the trailing debounce timer
    // must never run two read-modify-write cycles against models-config.json
    // concurrently (last-writer-wins would drop one of them).
    const task = state.saveChain.then(async () => {
      const result = await api("/api/params", {
        method: "POST",
        body: JSON.stringify({ model, overrides: perModel }),
      });
      if (result.ok) {
        state.modelsConfig = result.modelsConfig;
        updateResetMemoryButton();
      }
    }).catch(() => { /* transient — next edit re-saves */ });
    state.saveChain = task;
  }

  /* ---------- render: model list (left) ---------- */

  function renderModelList(filter = "") {
    const list = $("#model-list");
    const q = filter.trim().toLowerCase();
    const models = state.customModels.filter((m) => !q || m.name.toLowerCase().includes(q));

    if (models.length === 0) {
      list.innerHTML = "";
      $("#model-empty").classList.remove("hidden");
      return;
    }
    $("#model-empty").classList.add("hidden");

    list.innerHTML = models.map((m) => {
      const notes = notesForModel(m.name);
      const engine = engineForModel(m.name);
      const selected = state.selectedModel === m.name;
      const running = state.runningModel === m.name;
      const size = m.sizeGb ? `${m.sizeGb} GB` : "サイズ不明";
      return `
        <li>
          <button class="model-item ${selected ? "selected" : ""}" data-model="${esc(m.name)}" type="button">
            <div class="name">${esc(m.name)}</div>
            <div class="meta">
              <span>${esc(size)}</span>
              <span class="badge badge-engine">${engine}</span>
              ${running ? '<span class="badge badge-running">実行中</span>' : ""}
              ${notes?.recommended_preset ? `<span class="badge badge-preset">${esc(notes.recommended_preset)}</span>` : ""}
              ${notes?.warning ? '<span class="badge badge-warn">注意</span>' : ""}
            </div>
          </button>
        </li>`;
    }).join("");

    $$(".model-item").forEach((btn) => {
      btn.addEventListener("click", () => selectModel(btn.dataset.model));
    });
  }

  function renderFamilies() {
    const list = $("#family-list");
    list.innerHTML = (state.modelNotes || []).map((n) => `
      <li class="family-item">
        <div class="f-pattern">${esc(n.pattern)}</div>
        ${n.note ? `<div class="f-note">${esc(n.note)}</div>` : ""}
        ${n.warning ? `<div class="f-warn">⚠ ${esc(n.warning)}</div>` : ""}
        ${n.recommended_preset ? `<div class="f-preset"><span class="badge badge-preset">${esc(n.recommended_preset)}</span></div>` : ""}
      </li>`).join("");
  }

  function selectModel(name) {
    if (state.selectedModel !== name) {
      clearTimeout(state.saveTimer); // no trailing save for the *new* model
      savePerModelMemory(); // flush pending edits for the previous model
      state.selectedModel = name;
      state.overrides = {};
      state.appliedPresetId = null;
    }
    const meta = $("#model-meta");
    const notes = notesForModel(name);
    meta.textContent = notes ? `${name} — ${notes.recommended_preset || "推奨なし"}` : name;
    updateResetMemoryButton();
    renderModelList($("#model-search").value);
    renderGroups();
    renderPresetChips();
    refresh();
    toast(`モデル「${name}」を選択`);
  }

  function updateResetMemoryButton() {
    const btn = $("#btn-reset-memory");
    if (!btn) return;
    const mem = state.modelsConfig?.models?.[state.selectedModel];
    btn.classList.toggle("hidden", !mem || Object.keys(mem).length === 0);
  }

  /* ---------- render: parameter groups (center) ---------- */

  function renderGroups() {
    const container = $("#param-groups");
    const groups = state.schema?.groups || [];

    if (groups.length === 0) {
      container.innerHTML = "";
      $("#params-empty").classList.remove("hidden");
      return;
    }
    $("#params-empty").classList.add("hidden");

    container.innerHTML = groups.map((group) => {
      const open = initialOpenGroups[group.id] !== false;
      const visible = group.params || [];
      const advanced = visible.filter((p) => p.advanced);
      const basic = visible.filter((p) => !p.advanced);
      const body = [
        ...basic.map((p) => renderParam(p)),
        ...(advanced.length
          ? [
              `<button class="advanced-toggle" type="button">上級設定を開く（${advanced.length}）</button>`,
              `<div class="param-advanced">${advanced.map((p) => renderParam(p)).join("")}</div>`,
            ]
          : []),
      ].join("");
      return `
        <section class="group ${open ? "open" : ""}" data-group="${esc(group.id)}">
          <button class="group-head" type="button">
            ${esc(group.label)}
            <span class="group-count">${visible.length}</span>
            <span class="chevron">▶</span>
          </button>
          <div class="group-body">${body}</div>
        </section>`;
    }).join("");

    $$(".group-head").forEach((head) => {
      head.addEventListener("click", () => {
        const group = head.closest(".group");
        const id = group.dataset.group;
        group.classList.toggle("open");
        initialOpenGroups[id] = group.classList.contains("open");
        localStorage.setItem(GROUP_OPEN_KEY, JSON.stringify(initialOpenGroups));
      });
    });

    $$(".advanced-toggle").forEach((btn) => {
      btn.addEventListener("click", () => {
        const box = btn.closest(".group-body");
        const advanced = box.querySelector(".param-advanced");
        const open = advanced.style.display === "block";
        advanced.style.display = open ? "none" : "block";
        btn.textContent = open ? `上級設定を開く（${advanced.children.length}）` : "上級設定を閉じる";
      });
    });
  }

  function renderParam(param) {
    const value = effectiveValue(param.id);
    const mem = param.per_model ? '<span class="param-mem" title="この値はモデル別に記憶されます">記憶</span>' : "";
    const control = controlFor(param, value);
    return `
      <div class="param" data-param="${esc(param.id)}">
        <div class="param-head">
          <span class="param-label">${esc(param.label)}</span>
          ${mem}
          ${param.help ? `<span class="param-help" title="${esc(param.help)}">?</span>` : ""}
        </div>
        <div class="param-control">${control}</div>
      </div>`;
  }

  function controlFor(param, value) {
    const id = param.id;
    switch (param.type) {
      case "bool": {
        const checked = value === true || value === "true" || value === "on";
        return `
          <label class="toggle">
            <input type="checkbox" data-param="${esc(id)}" ${checked ? "checked" : ""} />
            <span class="track"></span>
          </label>
          <span class="muted small">${checked ? "オン" : "オフ"}</span>`;
      }
      case "select": {
        const options = (param.allowed || [])
          .map((opt) => {
            const v = typeof opt === "object" ? opt.value : opt;
            const label = typeof opt === "object" ? opt.label : opt;
            return `<option value="${esc(v)}" ${String(value) === String(v) ? "selected" : ""}>${esc(label)}</option>`;
          })
          .join("");
        // Explicit escape hatch back to custom values: without it, picking an
        // allowed value once makes custom values unreachable from the select.
        const customOpt = param.allow_custom ? `<option value="__custom__">カスタム…</option>` : "";
        const isCustom = param.allow_custom && !(param.allowed || []).some((o) => String(typeof o === "object" ? o.value : o) === String(value));
        const custom = param.allow_custom
          ? `<input type="text" data-param="${esc(id)}" data-custom="1" value="${esc(isCustom ? value : "")}" placeholder="カスタム値" ${isCustom ? "" : "hidden"} />`
          : "";
        return `<select data-param="${esc(id)}">${options}${customOpt}</select>${custom}`;
      }
      case "int":
      case "num": {
        const chips = (param.allowed || []).map((v) => {
          const active = String(v) === String(value);
          return `<button class="chip ${active ? "active" : ""}" data-param="${esc(id)}" data-value="${esc(v)}" type="button">${esc(v)}</button>`;
        }).join("");
        const step = param.type === "num" ? "any" : "1";
        return `
          <input type="number" data-param="${esc(id)}" value="${esc(value ?? "")}" min="${esc(param.min ?? "")}" step="${step}" />
          ${chips ? `<div class="chips">${chips}</div>` : ""}`;
      }
      default: {
        return `<input type="text" data-param="${esc(id)}" value="${esc(value ?? "")}" />`;
      }
    }
  }

  function bindParamControls() {
    const container = $("#param-groups");

    container.addEventListener("input", (event) => {
      const el = event.target;
      if (!el.dataset.param) return;
      let value = el.value;
      const param = paramById(el.dataset.param);
      if (param && (param.type === "int" || param.type === "num")) {
        if (value === "") value = "";
        else if (param.type === "int") value = Math.round(Number(value));
        else value = Number(value);
      }
      setOverride(el.dataset.param, value);
      if (el.dataset.custom) {
        // keep the matching select in sync when a custom value is typed
        const select = el.closest(".param-control").querySelector("select");
        if (select) select.value = value;
      }
      syncChips(el.dataset.param);
    });

    container.addEventListener("change", (event) => {
      const el = event.target;
      if (el.matches("select[data-param]")) {
        const customInput = el.parentElement.querySelector("input[data-custom]");
        if (customInput) {
          // "__custom__" only reveals the text input — the effective value
          // stays whatever it was until the user types one.
          if (el.value === "__custom__") {
            customInput.hidden = false;
            setTimeout(() => customInput.focus(), 0);
            return;
          }
          const isCustom = !(paramById(el.dataset.param)?.allowed || []).some(
            (o) => String(typeof o === "object" ? o.value : o) === el.value);
          customInput.hidden = !isCustom;
          if (isCustom && !el.value.startsWith("__")) customInput.value = el.value;
        }
        setOverride(el.dataset.param, el.value);
      }
    });

    container.addEventListener("click", (event) => {
      const chip = event.target.closest(".chip[data-param]");
      if (chip) {
        setOverride(chip.dataset.param, chip.dataset.value);
        const input = chip.closest(".param-control").querySelector("input[type=number]");
        if (input) input.value = chip.dataset.value;
        syncChips(chip.dataset.param);
      }
    });
  }

  function syncChips(paramId) {
    const value = effectiveValue(paramId);
    $$(`.chip[data-param="${CSS.escape(paramId)}"]`).forEach((chip) => {
      chip.classList.toggle("active", String(chip.dataset.value) === String(value));
    });
  }

  /* ---------- render: memory presets (center top) ---------- */

  function renderPresetChips() {
    const chips = $("#preset-chips");
    chips.innerHTML = (state.presets?.presets || []).map((preset) => {
      const active = state.appliedPresetId === preset.id;
      return `<button class="preset-chip ${active ? "active" : ""}" data-preset="${esc(preset.id)}" title="${esc(preset.description || "")}" type="button">${esc(preset.label)}</button>`;
    }).join("");

    $$(".preset-chip").forEach((chip) => {
      chip.addEventListener("click", () => {
        const preset = (state.presets?.presets || []).find((p) => p.id === chip.dataset.preset);
        if (!preset) return;
        state.appliedPresetId = preset.id;
        for (const [id, value] of Object.entries(preset.overrides || {})) {
          state.overrides[id] = value;
        }
        renderPresetChips();
        renderGroups();
        refresh();
        savePerModelMemory();
        toast(`プリセット「${preset.label}」を適用しました`, "ok");
      });
    });
  }

  /* ---------- render: effective args ---------- */

  function renderArgs() {
    const lines = [];
    const env = [];
    const engine = effectiveValue("engine");
    const preset = effectiveValue("preset");
    lines.push(`# engine=${engine || "Auto"}  preset=${preset || "Manual"}  model=${state.selectedModel || "未選択"}`);

    for (const param of allParams()) {
      if (!param.flags || param.flags.length === 0) continue;
      const value = effectiveValue(param.id);
      if (value === undefined || value === null || value === "") continue;
      if (param.type === "bool") {
        if (value === true || value === "true" || value === "on") lines.push(param.flags[0]);
        continue;
      }
      if (param.flag_value) {
        const rendered = param.flag_value.replaceAll("{value}", String(value));
        if (rendered.startsWith("env ")) env.push(rendered.slice(4));
        else lines.push(rendered);
        continue;
      }
      lines.push(`${param.flags[0]} ${value}`);
    }

    const parts = [...env.map((e) => `${e}`), ...lines];
    state.argString = parts.join("\n");
    $("#args-preview").textContent = state.argString || "—";
  }

  /* ---------- top bar: runtime signal, launch/stop, benchmark ---------- */

  const RUNTIME_LABEL = {
    idle: "停止中",
    starting: "起動準備中…",
    running: "起動中",
    stopping: "停止中…",
    error: "エラー",
  };

  const WS_STATE_LABEL = {
    idle: "未接続",
    connected: "接続済み",
    simulated: "sim",
    error: "エラー",
  };
  const RUNTIME_DOT = {
    idle: "dot-amber",
    starting: "dot-amber",
    running: "dot-green",
    stopping: "dot-amber",
    error: "dot-red",
  };

  function applyStatus(status) {
    const rt = status.runtime || {};
    const st = rt.status || "idle";
    const isSim = status.server && status.server.platform !== "win32";
    state.pollFails = 0;
    state.runningModel = st === "running" ? (rt.model || null) : null;

    const label = $("#runtime-signal-label");
    const dot = $("#runtime-signal").querySelector(".dot");
    if (st === "running") {
      label.textContent = `${RUNTIME_LABEL[st]} · ${rt.model || ""}${rt.simulated ? "（シミュレーション）" : ""}`;
    } else if (st === "idle") {
      label.textContent = isSim ? "プレビュー · シミュレーション可" : "Windows ランタイム · 停止中";
    } else {
      label.textContent = RUNTIME_LABEL[st] || st;
    }
    dot.className = `dot ${RUNTIME_DOT[st] || "dot-amber"}`;

    // Launch button mirrors the runtime state machine: no double-launch, and
    // the starting phase shows elapsed seconds instead of a dead button.
    const launchBtn = $("#btn-launch");
    if (launchBtn) {
      const starting = st === "starting";
      launchBtn.disabled = starting || st === "running";
      launchBtn.textContent =
        st === "running" ? "起動済み"
          : starting ? `起動中… ${Math.round((rt.uptimeMs || 0) / 1000)}s`
            : "起動";
      launchBtn.title = st === "running"
        ? `「${rt.model || ""}」が起動中です（停止してから切り替えてください）`
        : "選択モデルを起動（Windows ランタイム）";
    }
    const stopBtn = $("#btn-stop");
    if (stopBtn) {
      stopBtn.disabled = !(st === "running" || st === "starting" || st === "error");
    }

    $("#server-state").textContent =
      st === "running"
        ? `${rt.model || ""}${rt.simulated ? "（シミュレーション）" : ""}${rt.pid ? ` · pid ${rt.pid}` : ""}`.trim()
        : (RUNTIME_LABEL[st] || st);
    $("#server-dot").className = `dot ${RUNTIME_DOT[st] || "dot-red"}`;

    $("#m-toks").textContent = rt.metrics && rt.metrics.toks != null ? rt.metrics.toks.toFixed(1) : "—";
    $("#m-vram").textContent = rt.metrics && rt.metrics.vramGb != null ? `${rt.metrics.vramGb.toFixed(1)} GB` : "—";
    $("#m-ram").textContent = rt.metrics && rt.metrics.ramGb != null ? `${rt.metrics.ramGb.toFixed(1)} GB` : "—";
    // GPU probe chip (post-launch offload sanity check): measured tok/s when
    // the probe succeeded, 失敗 when it errored, — before it has run.
    const gpuChip = $("#m-gpu");
    if (gpuChip) {
      gpuChip.textContent = !rt.gpuProbe
        ? "—"
        : rt.gpuProbe.ok
          ? `${rt.gpuProbe.tokensPerSec.toFixed(1)} t/s`
          : "失敗";
      gpuChip.title = !rt.gpuProbe
        ? "起動後のGPUオフロードプローブは未実行"
        : rt.gpuProbe.ok
          ? `プロープ ${rt.gpuProbe.tokens} tok / ${rt.gpuProbe.wallMs}ms — 8 t/s 未満はCPUフォールバック疑い`
          : `プローブ失敗: ${rt.gpuProbe.error || "不明"}`;
    }

    const logView = $("#log-view");
    if (rt.logTail && rt.logTail.length) {
      logView.textContent = rt.logTail.join("\n");
      logView.scrollTop = logView.scrollHeight;
    } else {
      logView.textContent = "（ログなし）";
    }

    state.lastClients = status.clients || [];
    renderWorkspaceClients(state.lastClients);
  }

  /* ---------- workspace client list (right) ---------- */

  // Health dot next to the description: green when the client's own server is
  // reachable (e.g. ComfyUI :8188 /system_stats), red when it is down, and
  // nothing for CLI clients that expose no HTTP server.
  function healthDotFor(client) {
    const h = state.health[client.id];
    if (!h || !h.checked || h.up == null) return "";
    const cls = h.up ? "hdot-up" : "hdot-down";
    const title = h.up
      ? `稼働中 (${h.latencyMs}ms) · ${h.url}`
      : `停止中 · ${h.error || "応答なし"} · ${h.url}`;
    return `<span class="hdot ${cls}" title="${esc(title)}"></span>`;
  }

  function renderWorkspaceClients(clients) {
    const wsList = $("#workspace-list");
    if (!wsList || !clients.length) return;
    wsList.innerHTML = clients.map((c) => {
      const h = state.health[c.id];
      const up = !!(h && h.checked && h.up === true && h.url);
      const open = up && c.kind === "web"
        ? `<a class="ws-open" href="${esc(h.url)}" target="_blank" rel="noreferrer" title="ブラウザで開く: ${esc(h.url)}">開く ↗</a>`
        : "";
      return `
      <li class="ws-row">
        <button class="ws-item" data-client="${esc(c.id)}" type="button" title="${esc(c.message || c.desc || "")}">
          <span>${esc(c.label)}</span>
          <span class="ws-side">
            <span class="ws-desc">${esc(c.desc)}${healthDotFor(c)}</span>
            <span class="ws-state ws-state-${esc(c.state)}">${esc(WS_STATE_LABEL[c.state] || c.state)}</span>
          </span>
        </button>
        ${open}
      </li>`;
    }).join("");
    $$(".ws-item").forEach((btn) => {
      btn.addEventListener("click", () => connect(btn.dataset.client));
    });
  }

  // Standalone / web clients are probed on a slower cadence than the runtime
  // status (10s vs 3s) so the poll stays cheap even when a client is down and
  // the connection is refused after the full timeout.
  async function refreshHealth() {
    try {
      const payload = await api("/api/clients/health");
      const map = {};
      for (const h of payload.clients || []) map[h.id] = h;
      state.health = map;
      if (state.lastClients.length) renderWorkspaceClients(state.lastClients);
    } catch { /* transient — next poll */ }
  }

  async function loadStatus() {
    const status = await api("/api/status");
    applyStatus(status);
    const engines = status.engines || [];
    const engineChips = engines.length
      ? `<div class="status-row"><span class="label">エンジン</span><span class="engine-chips">${engines.map((e) => `<span class="badge ${e.found ? "badge-engine" : "badge-warn"}" title="${e.found ? "インストール済み" : "未検出"}">${esc(e.name)}</span>`).join("")}</span></div>`
      : "";
    $("#platform-body").innerHTML = `
      この環境は <strong>${esc(status.server?.platform || "不明")}</strong>（Node ${esc(status.server?.node || "?")}）です。<br/>
      llama-server の起動・停止・クライアント接続は Windows ランタイム（select-model.ps1 コア）が担います。
      ${engineChips}
    `;
    // Keep the monitor card's endpoint codes in sync with the server's
    // effective ports (LLAMADOCK_UPSTREAM_PORT / LLAMADOCK_CLIENT_BASE_URL
    // overrides are reflected here, not hardcoded).
    const clientEp = $("#endpoint-client");
    const upstreamEp = $("#endpoint-upstream");
    if (clientEp && status.clientEndpoint) clientEp.textContent = status.clientEndpoint;
    if (upstreamEp && status.upstreamEndpoint) upstreamEp.textContent = status.upstreamEndpoint;
    return status;
  }

  async function refreshStatus() {
    try {
      applyStatus(await api("/api/status"));
    } catch {
      // Persistent poll failure means the GUI server itself is gone — say so
      // instead of silently freezing on the last known state.
      state.pollFails += 1;
      if (state.pollFails >= 3) {
        const label = $("#runtime-signal-label");
        const dot = $("#runtime-signal").querySelector(".dot");
        if (label) label.textContent = "GUIサーバーに接続できません";
        if (dot) dot.className = "dot dot-red";
      }
    }
  }

  async function launch() {
    if (!state.selectedModel) {
      toast("先にモデルを選択してください", "warn");
      return;
    }
    try {
      const body = { model: state.selectedModel, params: state.overrides };
      const result = await api("/api/launch", { method: "POST", body: JSON.stringify(body) });
      toast(result.ok ? result.message : (result.message || "起動できません"), result.ok ? "ok" : "warn");
    } catch (error) {
      toast(`起動リクエストに失敗しました: ${error.message}`, "warn");
    }
    await refreshStatus();
  }

  async function stop() {
    try {
      const result = await api("/api/stop", { method: "POST", body: "{}" });
      toast(result.ok ? result.message : (result.message || "停止できません"), result.ok ? "ok" : "warn");
    } catch (error) {
      toast(`停止リクエストに失敗しました: ${error.message}`, "warn");
    }
    await refreshStatus();
  }

  async function benchmark() {
    const btn = $("#btn-benchmark");
    if (!btn || btn.disabled) return;
    const runs = Number($("#bench-runs")?.value) || 3;
    btn.disabled = true;
    btn.textContent = "計測中…";
    try {
      const result = await api("/api/benchmark", { method: "POST", body: JSON.stringify({ runs }) });
      if (result.ok) {
        toast(`計測完了: ${result.recorded} 回を run-results.json に記録`, "ok");
        await loadResults();
      } else {
        toast(result.message || "計測できません", "warn");
      }
    } catch (error) {
      toast(`計測に失敗しました: ${error.message}`, "warn");
    } finally {
      btn.disabled = false;
      btn.textContent = `計測実行（${runs}回）`;
      await refreshStatus();
    }
  }

  async function clearResults() {
    try {
      const result = await api("/api/results/clear", { method: "POST", body: "{}" });
      toast(result.ok ? "実測記録をクリアしました" : (result.message || "クリアできません"), result.ok ? "ok" : "warn");
    } catch (error) {
      toast(`クリアに失敗しました: ${error.message}`, "warn");
    }
    await loadResults();
  }

  async function loadGgufList() {
    try {
      const payload = await api("/api/models/scan");
      if (!payload.ok) return;
      const dl = $("#gguf-suggestions");
      if (dl) {
        // Same filename can exist under multiple repos (mmproj etc.) — one
        // suggestion per unique name is enough for the datalist.
        const seen = new Set();
        dl.innerHTML = payload.models
          .filter((m) => !seen.has(m.name.toLowerCase()) && seen.add(m.name.toLowerCase()))
          .map((m) => `<option value="${esc(m.name)}">${m.sizeGb != null ? `${m.sizeGb} GB` : ""}</option>`)
          .join("");
      }
      state.ggufIndex = new Map(payload.models.map((m) => [m.name.toLowerCase(), m]));
    } catch { /* scan is best-effort */ }
  }

  async function loadResults() {
    const el = $("#results-list");
    if (!el) return;
    try {
      const results = await api("/api/results");
      const models = results.models || [];
      if (!models.length) {
        el.innerHTML = `<li class="result-empty">まだ実測記録がありません。「起動 → 計測実行」で蓄積されます。</li>`;
        return;
      }
      el.innerHTML = models.map((m) => {
        const rec = m.recommended;
        const total = m.okRuns + m.failRuns;
        const pct = total > 0 ? Math.round((m.okRuns / total) * 100) : 0;
        return `
          <li class="result-item">
            <div class="result-name">${esc(m.model)}</div>
            <div class="result-meta">成功 ${m.okRuns} / 失敗 ${m.failRuns}（${pct}%）· ${m.configCount} 設定</div>
            ${rec
              ? `<div class="result-rec"><span class="badge badge-qualified">推奨（実測）</span> ${esc(rec.engine || "?")} · ${rec.bestTps != null ? rec.bestTps.toFixed(1) : "—"} tok/s · ${rec.okCount}回成功</div>`
              : `<div class="result-rec muted">未認定 — 成功 ${m.okRuns} 回 / 必要 ${results.minRuns} 回</div>`}
          </li>`;
      }).join("");
    } catch { /* API not ready yet */ }
  }

  async function connect(client) {
    try {
      const result = await api("/api/connect", {
        method: "POST",
        body: JSON.stringify({
          client,
          model: state.selectedModel,
          prompt: "",
        }),
      });
      const message = result.message || (result.ok ? `${client} を起動しました` : `${client}: 接続できません`);
      // Long simulated command lines stay readable in the state-chip tooltip;
      // the toast gets a short preview only.
      const short = message.length > 220 ? `${message.slice(0, 220)}…` : message;
      toast(short, result.ok ? "ok" : "warn");
    } catch (error) {
      toast(`接続リクエストに失敗しました: ${error.message}`, "warn");
    }
    await refreshStatus();
  }

  /* ---------- engine settings (coder engine 8080) ---------- */

  function setEsStatus(msg, cls) {
    const el = $("#es-status");
    if (!el) return;
    el.textContent = msg || "";
    el.className = "es-status " + (cls || "muted");
  }

  function toggleEsDraftRow() {
    const row = $("#es-draft-row");
    if (row) row.classList.toggle("hidden", !["draft-dflash", "draft-dflash2"].includes($("#es-spec").value));
  }

  async function loadEngineSettings() {
    try {
      const r = await fetch("/api/engine-settings");
      const j = await r.json();
      if (!j.ok) {
        setEsStatus(j.message || "サーバー未起動（引数ファイルなし）", "warn");
        return;
      }
      $("#es-ctk").value = [...$("#es-ctk").options].some((o) => o.value === j.ctk) ? j.ctk : "q8_0";
      $("#es-ctv").value = [...$("#es-ctv").options].some((o) => o.value === j.ctv) ? j.ctv : "q8_0";
      $("#es-fa").checked = !!j.fa;
      if (j.context) $("#es-context").value = j.context;
      if (j.cacheRam != null) $("#es-cacheram").value = j.cacheRam;
      const specSel = $("#es-spec");
      specSel.value = [...specSel.options].some((o) => o.value === j.specType) ? j.specType : "off";
      $("#es-draft").value = j.specDraftModel || "";
      toggleEsDraftRow();
      if (!j.supervisorRunning || j.breakerOpen) {
        setEsStatus("supervisor 停止中（適用しても再起動されません）", "warn");
      } else {
        setEsStatus("", "");
      }
    } catch {
      setEsStatus("設定を取得できません", "err");
    }
  }

  async function applyEngineSettings() {
    const btn = $("#es-apply");
    btn.disabled = true;
    setEsStatus("適用中…", "warn");
    const body = {
      ctk: $("#es-ctk").value,
      ctv: $("#es-ctv").value,
      fa: $("#es-fa").checked,
      context: Number($("#es-context").value) || undefined,
      cacheRam: Number($("#es-cacheram").value),
      specType: $("#es-spec").value,
    };
    if (["draft-dflash", "draft-dflash2"].includes(body.specType)) {
      body.specDraftModel = $("#es-draft").value.trim();
      if (!body.specDraftModel) {
        const label = body.specType === "draft-dflash2" ? "DFlash2" : "DFlash";
        setEsStatus(`${label} にはドラフトモデルのパスが必要です`, "err");
        btn.disabled = false;
        return;
      }
    }
    try {
      const r = await fetch("/api/engine-settings", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      });
      const j = await r.json();
      if (!j.ok) {
        setEsStatus(j.message || "適用に失敗しました", "err");
        btn.disabled = false;
        return;
      }
      if (!j.restarted) {
        setEsStatus(j.message || "保存のみ（supervisor 停止中）", "warn");
        btn.disabled = false;
        return;
      }
      await waitEngineRestart();
    } catch (error) {
      setEsStatus("適用に失敗しました: " + error.message, "err");
      btn.disabled = false;
    }
  }

  async function waitEngineRestart() {
    setEsStatus("再起動中…（モデル読込まで最大3分）", "warn");
    const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
    let sawDown = false;
    const start = Date.now();
    while (Date.now() - start < 180000) {
      await sleep(2000);
      try {
        const r = await fetch("/api/engine-health", { cache: "no-store" });
        const j = await r.json();
        if (!j.upstream.up) sawDown = true;
        if (j.upstream.up && (sawDown || Date.now() - start > 20000)) {
          setEsStatus("✅ 再起動完了", "ok");
          await loadEngineSettings();
          const applyBtn = $("#es-apply");
          if (applyBtn) applyBtn.disabled = false;
          return;
        }
      } catch {
        /* keep polling */
      }
    }
    setEsStatus("⚠ 再起動を確認できませんでした（3分経過）。ログを確認してください。", "err");
    const applyBtn = $("#es-apply");
    if (applyBtn) applyBtn.disabled = false;
  }

  /* ---------- refresh / boot ---------- */

  function refresh() {
    renderArgs();
    // keep chips in sync after any change
    for (const param of allParams()) {
      if (param.type === "select") {
        const sel = $(`select[data-param="${CSS.escape(param.id)}"]`);
        if (sel) sel.value = String(effectiveValue(param.id));
      }
    }
  }

  function bindStaticEvents() {
    $("#btn-refresh").addEventListener("click", async () => {
      // Full re-render from the API: the reload button is meant to reflect
      // server-side changes (schema / presets / notes), so do not use the
      // silent path that only updates state in memory.
      await loadBootstrap(false);
      toast("設定を再読込しました", "ok");
    });

    $("#model-search").addEventListener("input", (e) => renderModelList(e.target.value));

    $("#btn-add-model").addEventListener("click", () => {
      $("#add-model-name").value = "";
      $("#add-model-size").value = "";
      $("#add-model-dialog").showModal();
    });
    $("#btn-add-model-cancel").addEventListener("click", () => $("#add-model-dialog").close());
    // Enter confirms the dialog (all buttons are type=button, so implicit
    // form submission would otherwise do nothing).
    ["add-model-name", "add-model-size"].forEach((id) => {
      document.getElementById(id).addEventListener("keydown", (e) => {
        if (e.key === "Enter") {
          e.preventDefault();
          $("#btn-add-model-confirm").click();
        }
      });
    });
    $("#btn-add-model-confirm").addEventListener("click", () => {
      const name = $("#add-model-name").value.trim();
      if (!name) {
        toast("モデル名を入力してください", "warn");
        return;
      }
      let size = Number($("#add-model-size").value);
      if (!(Number.isFinite(size) && size > 0)) {
        const scanned = state.ggufIndex.get(name.toLowerCase());
        size = scanned?.sizeGb ?? null;
      }
      state.customModels.push({ name, sizeGb: size });
      persistCustomModels();
      $("#add-model-dialog").close();
      renderModelList();
      selectModel(name);
      toast(`「${name}」を追加しました`, "ok");
    });

    $("#btn-reset-memory").addEventListener("click", async () => {
      const model = state.selectedModel;
      if (!model) return;
      try {
        const result = await api("/api/params", {
          method: "POST",
          body: JSON.stringify({ model, reset: true }),
        });
        if (result.ok) {
          state.overrides = {};
          state.modelsConfig = result.modelsConfig;
          updateResetMemoryButton();
          renderGroups();
          refresh();
          toast(`「${model}」の記憶をリセットしました（プロファイル/既定値に戻す）`, "ok");
        } else {
          toast("リセットできませんでした", "warn");
        }
      } catch (error) {
        toast(`リセットに失敗しました: ${error.message}`, "warn");
      }
    });

    $("#btn-launch").addEventListener("click", launch);
    $("#btn-launch-args")?.addEventListener("click", launch);
    $("#btn-stop").addEventListener("click", stop);
    $("#btn-benchmark").addEventListener("click", benchmark);
    $("#btn-clear-results")?.addEventListener("click", clearResults);

    $("#es-apply").addEventListener("click", applyEngineSettings);
    $("#es-spec").addEventListener("change", toggleEsDraftRow);
    loadEngineSettings();

    $("#btn-copy-args").addEventListener("click", async () => {
      try {
        await navigator.clipboard.writeText(state.argString || "");
        toast("起動引数をコピーしました", "ok");
      } catch {
        toast("コピーに失敗しました", "warn");
      }
    });

    $$(".ws-item").forEach((btn) => {
      btn.addEventListener("click", () => connect(btn.dataset.client));
    });
  }

  async function loadBootstrap(silent = false) {
    try {
      const payload = await api("/api/bootstrap");
      state.schema = payload.schema;
      state.presets = payload.presets;
      state.modelNotes = payload.modelNotes || [];
      state.modelsConfig = payload.modelsConfig || { _profiles: [], models: {} };
      if (!silent) {
        renderFamilies();
        renderModelList();
        renderPresetChips();
        renderGroups();
        renderArgs();
        updateResetMemoryButton();
      }
    } catch (error) {
      toast(`API に接続できません: ${error.message}`, "warn");
    }
  }

  async function init() {
    bindParamControls();
    bindStaticEvents();
    await loadBootstrap();
    await loadStatus();
    await refreshHealth();
    await loadResults();
    loadGgufList();
    setInterval(refreshStatus, 3000);
    setInterval(refreshHealth, 10000);
  }

  init();
})();
