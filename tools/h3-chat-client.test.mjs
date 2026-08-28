// Client harness for h3-chat.py's embedded <script> (no browser needed).
// Extracts the JS, runs it in a vm with DOM/fetch stubs, and verifies the
// image-use (I2V/R2V) selection, prompt retention on failed generation, and
// reset error surfacing. Run: node tools/h3-chat-client.test.mjs
import { readFileSync } from "node:fs";
import vm from "node:vm";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const src = readFileSync(path.join(repo, "tools", "h3-chat.py"), "utf-8");
const js = src.match(/<script>([\s\S]*)<\/script>/)[1];

function makeEl(id) {
  const e = {
    id, value: "", checked: false, disabled: false, selected: false,
    style: { display: "" }, className: "", textContent: "",
    dataset: {}, scrollTop: 0, scrollHeight: 0, placeholder: "",
    children: [], options: [], selectedIndex: -1,
    appendChild(c) { this.children.push(c); return c; },
    addEventListener() {}, removeEventListener() {},
    querySelector() { return null; },
    querySelectorAll() { return []; },
    closest() { return null; },
    classList: { add() {}, remove() {}, toggle() {} },
    focus() {}, click() {},
    setAttribute() {}, getAttribute() { return null; },
  };
  // 実 DOM と同じく、innerHTML 代入は子要素を全て消す
  // （これがないと refgrid の「innerHTML = "" でクリア」が効かずカードが溜まる）。
  let html = "";
  Object.defineProperty(e, "innerHTML", {
    get() { return html; },
    set(v) { html = String(v); e.children.length = 0; },
  });
  return e;
}

const els = new Map();
function el(id) { if (!els.has(id)) els.set(id, makeEl(id)); return els.get(id); }
el("mode-radio"); // placeholder, unused

const state = {
  fetches: [],
  alerts: [],
  confirms: [],
  confirmAnswer: true,
  modeValue: "quick",
  planReply: { reply: "ok" },
  resetFail: false,
  refImagesResponse: null,   // null = default single image
  tuneIgnored: [],
  sessionsResponse: null,    // null = no sessions, no active
  sessionSaves: [],          // bodies posted to /api/sessions/save
  switchFail: false,
  switchResult: null,        // session doc returned by /api/sessions/switch
  extendResult: null,        // null = default {image: "h3_ext_1.png"}
  concatBodies: [],          // bodies posted to /api/concat
  statusResult: { status: "success", videos: [{ filename: "a.mp4", type: "output", path: "C:\\x\\a.mp4", kind: "video" }] },
};

async function fakeFetch(url, opts) {
  state.fetches.push({ url, opts });
  const j = (obj, ok = true, status = 200) => ({ ok, status, json: async () => obj });
  if (url === "/api/queue") return j({ queue_running: [], queue_pending: [] });
  if (url === "/api/plan-models") return j({ models: [], current: null, running: false });
  if (url === "/api/generate") return j({ prompt_id: "p1", eff_mode: state.modeValue, override_label: "", tune_ignored: state.tuneIgnored });
  if (url.startsWith("/api/status/")) return j(state.statusResult);
  if (url === "/api/refimages") return j({ images: state.refImagesResponse || [{ path: "C:\\ComfyUI\\output\\x.png", name: "x.png", dir: "output" }] });
  if (url === "/api/sessions") return j(state.sessionsResponse || { active_id: null, sessions: [], active: null });
  if (url === "/api/sessions/save") {
    state.sessionSaves.push({ body: opts.body });
    const b = JSON.parse(opts.body);
    return j({ id: b.id || "s-new-1", title: "t", updated: 1 });
  }
  if (url === "/api/sessions/switch") {
    if (state.switchFail) return j({ error: "boom" }, false, 500);
    return j({ session: state.switchResult });
  }
  if (url === "/api/sessions/delete") return j({ ok: true });
  if (url === "/api/extend") return j(state.extendResult || { image: "h3_ext_1.png" });
  if (url === "/api/upscale") return j({ prompt_id: "up-1", scale: 2 });
  if (url === "/api/concat") {
    state.concatBodies.push(opts.body);
    return j({ filename: "h3_joined_1.mp4", path: "C:\\x\\h3_joined_1.mp4" });
  }
  if (url === "/api/plan") {
    const body = opts && opts.body ? JSON.parse(opts.body) : {};
    if (body.text === "__RESET__") {
      if (state.resetFail) return j({ error: "boom" }, false, 500);
      return j({ reset: true, reply: "新しい企画を始めましょう。" });
    }
    return j(state.planReply);
  }
  if (url === "/api/shutdown") return j({ ok: true });
  if (url === "/api/cancel") return j({ ok: true });
  return j({});
}

const documentStub = {
  querySelector(sel) {
    if (sel.startsWith("#")) return el(sel.slice(1));
    if (sel === 'input[name="mode"]:checked') return { value: state.modeValue };
    if (sel === 'input[name="dit"]:checked') return { value: "default" };
    if (sel === 'input[name="imgengine"]:checked') return { value: "qimg" };
    return null;
  },
  getElementById(id) { return el(id); },
  createElement(tag) { return makeEl("<" + tag + ">"); },
  addEventListener() {},
};

const sandbox = {
  document: documentStub,
  fetch: fakeFetch,
  alert(msg) { state.alerts.push(String(msg)); },
  confirm(msg) { state.confirms.push(String(msg)); return state.confirmAnswer !== false; },
  navigator: { sendBeacon() {} },
  addEventListener() {},
  setInterval: () => 0,
  clearInterval() {},
  setTimeout, clearTimeout,
  console,
  encodeURIComponent, decodeURIComponent,
  JSON, Promise, Error, String, Math, Date,
};
sandbox.window = sandbox;
sandbox.globalThis = sandbox;
const ctx = vm.createContext(sandbox);
vm.runInContext(js, ctx);

let pass = 0, fail = 0;
function check(name, cond, extra = "") {
  if (cond) { pass++; console.log("  PASS", name); }
  else { fail++; console.log("  FAIL", name, extra); }
}
const run = (code) => vm.runInContext(code, ctx);
const tick = (ms = 80) => new Promise(r => setTimeout(r, ms));
const lastBody = () => {
  for (let i = state.fetches.length - 1; i >= 0; i--) {
    const f = state.fetches[i];
    if (f.url === "/api/generate") return JSON.parse(f.opts.body);
  }
  return null;
};

// --- setup default UI state
run(`
  $("#imguse").value = "first";
  $("#refmode").checked = false;
  $("#planmode").checked = true;
`);

console.log("[1] imageUseTag labels");
check("first tag", run(`$("#imguse").value="first"; imageUseTag()`) === "📌 先頭フレーム固定で生成する: ");
check("last tag", run(`$("#imguse").value="last"; imageUseTag()`) === "🏁 最終フレーム固定で生成する: ");
check("ref tag", run(`$("#imguse").value="ref"; imageUseTag()`) === "🎭 参照モード（R2V）で生成する: ");

console.log("[2] genPlanLast keeps prompt + sends image_use (I2V first)");
run(`
  lastFinalPrompt = "PROMPT_A";
  refImages = ["keyimg.png"];
  $("#imguse").value = "first";
`);
await run(`(async () => { genPlanLast(); })()`);
await tick();
{
  const b = lastBody();
  check("generate called", !!b);
  check("ref auto-on with image", b && b.ref === true);
  check("image sent", b && b.image === "keyimg.png");
  check("image_use=first sent", b && b.image_use === "first");
  check("lastFinalPrompt retained after generate", run(`lastFinalPrompt`) === "PROMPT_A");
  const userMsg = el("msgs").children.find(c => c.className === "msg user" && c.innerHTML.includes("PROMPT_A"));
  check("user message shows I2V tag", !!userMsg && userMsg.innerHTML.startsWith("📌 先頭フレーム固定で生成する: "));
}

console.log("[3] genPlanLast retry after failure still works (prompt not lost)");
state.statusResult = { status: "error", error: "VRAM OOM" };
await run(`(async () => { genPlanLast(); })()`);
await tick();
check("prompt still present after failed run", run(`lastFinalPrompt`) === "PROMPT_A");
check("retry button path: genPlanLast does not say 'no prompt'",
  !el("msgs").children.some(c => c.innerHTML.includes("生成するプロンプトがありません")));
state.statusResult = { status: "success", videos: [{ filename: "a.mp4", type: "output", path: "x", kind: "video" }] };

console.log("[4] R2V path: image_use=ref sent");
run(`$("#imguse").value = "ref";`);
await run(`(async () => { genPlanLast(); })()`);
await tick();
{
  const b = lastBody();
  check("image_use=ref sent", b && b.image_use === "ref");
  check("prompt still retained", run(`lastFinalPrompt`) === "PROMPT_A");
}

console.log("[5] confirmImage sets imguse=first");
run(`
  refImages = ["key2.png"];
  $("#imguse").value = "ref";   // 直前が参照でも確定で先頭固定が既定になる
`);
state.planReply = { reply: "相談しましょう" };
await run(`(async () => { confirmImage(); })()`);
await tick();
check("imguse switched to first", run(`$("#imguse").value`) === "first");
{
  const planCall = [...state.fetches].reverse().find(f => f.url === "/api/plan");
  const b = JSON.parse(planCall.opts.body);
  check("confirm sent __CONFIRM_IMAGE__", b.text === "__CONFIRM_IMAGE__" && b.image === "key2.png");
}

console.log("[6] pickRefImage single selection + apply sets imguse=ref");
run(`$("#imguse").value = "first"; refImages = [];`);
await run(`(async () => { await pickRefImage(); })()`);
await tick();
{
  const grid = el("refgrid");
  check("ref grid populated", grid.children.length === 1);
  grid.children[0].onclick();
  check("selection staged before apply", run(`refPickerSelection.length`) === 1);
  run(`applyRefPick()`);
  check("imguse switched to ref on apply", run(`$("#imguse").value`) === "ref");
  check("refImages set to picked path", run(`refImages[0]`) === "C:\\ComfyUI\\output\\x.png");
  check("ref-clear visible", el("ref-clear").style.display === "inline-block");
  check("ref-sel shows filename", el("ref-sel").textContent === "x.png");
}

console.log("[7] resetPlan: switch failure is surfaced, success clears to a fresh session");
run(`lastFinalPrompt = "PROMPT_KEEP"; planStage = "video";`);
state.switchFail = true;
const msgsBefore = el("msgs").children.length;
await run(`(async () => { await resetPlan(); })()`);
await tick();
{
  const added = el("msgs").children.slice(msgsBefore);
  check("warning shown on reset failure",
    added.some(c => c.innerHTML.includes("サーバー側のリセットに失敗")));
  check("messages and state kept on failure",
    el("msgs").children.length === msgsBefore + 1 && run(`lastFinalPrompt`) === "PROMPT_KEEP");
}
state.switchFail = false;
await run(`(async () => { await resetPlan(); })()`);
await tick();
{
  check("messages cleared on successful reset", el("msgs").children.length === 0);
  check("local state reset", run(`lastFinalPrompt === null && planStage === "chat" && activeSessionId === null`));
  const switches = state.fetches.filter(f => f.url === "/api/sessions/switch");
  check("switch(null) used for new session",
    switches.length > 0 && JSON.parse(switches[switches.length - 1].opts.body).id === null);
}

console.log("[8] plan() image stage: Japanese description + collapsible English");
run(`planStage = "chat"; lastImgPrompt = null;`);
state.planReply = {
  reply: "キー画像の案です。",
  img_prompt: "A young woman in a white sundress standing in a sunflower field, golden hour",
  img_prompt_ja: "夕暮れのヒマワリ畑に白いワンピースの女性が立つ一枚です。",
};
await run(`(async () => { await plan("キー画像を作って"); })()`);
await tick();
{
  const bots = el("msgs").children.filter(c => c.className === "msg bot");
  const last = bots[bots.length - 1];
  check("img JA box shown", last.innerHTML.includes("🖼 こんな画像になります") && last.innerHTML.includes("白いワンピース"));
  check("english original collapsible", last.innerHTML.includes("英語プロンプト（原文") && last.innerHTML.includes("sundress"));
  check("generate button shown", last.innerHTML.includes("🖼 キー画像を生成 ▶"));
  check("lastImgPrompt set (english)", run(`lastImgPrompt`).includes("sundress"));
  check("JA box appears before the collapsible", last.innerHTML.indexOf("こんな画像になります") < last.innerHTML.indexOf("英語プロンプト（原文"));
}

console.log("[9] plan() image stage: graceful degrade without JA tag");
run(`planStage = "chat";`);
state.planReply = {
  reply: "出しますね。",
  img_prompt: "A shiba inu running along the shoreline at sunset, warm golden light",
};
await run(`(async () => { await plan("キー画像を作って"); })()`);
await tick();
{
  const bots = el("msgs").children.filter(c => c.className === "msg bot");
  const last = bots[bots.length - 1];
  check("no JA box when tag missing", !last.innerHTML.includes("🖼 こんな画像になります"));
  check("collapsible english + button still there", last.innerHTML.includes("shiba inu") && last.innerHTML.includes("🖼 キー画像を生成 ▶"));
}

console.log("[10] multi-select picker: toggle, order, apply");
state.refImagesResponse = [
  { path: "C:\\ComfyUI\\output\\a.png", name: "a.png", dir: "output" },
  { path: "C:\\ComfyUI\\output\\b.png", name: "b.png", dir: "output" },
  { path: "C:\\ComfyUI\\input\\c.png", name: "c.png", dir: "input" },
];
run(`$("#imguse").value = "first"; refImages = [];`);
await run(`(async () => { await pickRefImage(); })()`);
await tick();
{
  const grid = el("refgrid");
  check("3 cards", grid.children.length === 3);
  grid.children[0].onclick();
  grid.children[2].onclick();
  check("2 selected in click order", run(`refPickerSelection.length`) === 2 && run(`refPickerSelection[1]`).endsWith("c.png"));
  check("count label updated", el("refpick-count").textContent.includes("2 枚選択中"));
  grid.children[0].onclick(); // toggle off
  check("toggle off works", run(`refPickerSelection.length`) === 1);
  grid.children[0].onclick(); // back on
  grid.children[1].onclick();
  run(`applyRefPick()`);
  check("applied 3 in order", run(`refImages.length`) === 3 && run(`refImages[2]`).endsWith("b.png"));
  check("ref-sel shows multi count", el("ref-sel").textContent.includes("計 3 枚") && el("ref-sel").textContent.includes("<Picture 1..3>"));
  check("imguse=ref after apply", run(`$("#imguse").value`) === "ref");
}

console.log("[11] payload carries images[] + ref_size + tune");
run(`
  lastFinalPrompt = "PROMPT_B";
  $("#imguse").value = "ref";
  $("#refsize-max").checked = true;
  $("#tune-easycache").value = "0.25";
  $("#tune-lora").value = "";
  $("#tune-crf").value = "19";
`);
await run(`(async () => { genPlanLast(); })()`);
await tick();
{
  const b = lastBody();
  check("images array sent", b && Array.isArray(b.images) && b.images.length === 3);
  check("image = first of images", b && b.image === b.images[0]);
  check("ref_size=max sent", b && b.ref_size === "max");
  check("tune partial (blank lora omitted)", b && b.tune && b.tune.easycache === 0.25 && b.tune.crf === 19 && !("lora" in b.tune));
}
run(`$("#refsize-max").checked = false; $("#tune-easycache").value = ""; $("#tune-crf").value = "";`);

console.log("[12] first/last with multiple images warns only 1st is used");
// 完了ポーリングが来ると bot.innerHTML が完成表示で置き換わり追記が消えるので、
// status=running のままにして「生成開始直後」の状態を検査する。
state.statusResult = { status: "running", elapsed_sec: 5, eta_sec: 100, pending: 0 };
run(`$("#imguse").value = "first"; lastFinalPrompt = "PROMPT_C";`);
await run(`(async () => { genPlanLast(); })()`);
await tick();
{
  // 警告は新規メッセージではなく生成開始メッセージ（最後の msg）に追記される
  const msgs = el("msgs").children;
  const botMsg = msgs[msgs.length - 1];
  check("warning shown for frame-fix + multi refs",
    botMsg.children.some(c => (c.textContent || "").includes("1 枚目の参照画像だけ使われます")));
}
// status=running のままだと setBusy(false) が呼ばれないので、次のテストのために解除
run(`setBusy(false);`);

console.log("[13] picker caps selection at 9");
state.refImagesResponse = Array.from({length: 11}, (_, i) => ({ path: "C:\\img\\p" + i + ".png", name: "p" + i + ".png", dir: "input" }));
run(`refImages = [];`);
state.alerts.length = 0;
await run(`(async () => { await pickRefImage(); })()`);
await tick();
{
  const grid = el("refgrid");
  for (let i = 0; i < 11; i++) grid.children[i].onclick();
  check("selection capped at 9", run(`refPickerSelection.length`) === 9);
  check("cap alert shown", state.alerts.some(a => a.includes("最大 9 枚")));
}
state.refImagesResponse = null;

console.log("[14] tune_ignored from server is surfaced");
// [12] と同じ理由で status=running のまま検査する（statusResult は既に running）
state.tuneIgnored = ["EasyCache 閾値（このモードは EasyCache 非使用）"];
run(`lastFinalPrompt = "PROMPT_D"; $("#imguse").value = "ref"; refImages = [];`);
await run(`(async () => { genPlanLast(); })()`);
await tick();
{
  const msgs = el("msgs").children;
  const botMsg = msgs[msgs.length - 1];
  check("tune_ignored hint shown",
    botMsg.children.some(c => (c.textContent || "").includes("反映されなかった設定")));
}
state.tuneIgnored = [];
state.statusResult = { status: "success", videos: [{ filename: "a.mp4", type: "output", path: "C:\\x\\a.mp4", kind: "video" }] };

console.log("[15] initSessions restores active session (messages + UI state)");
state.sessionsResponse = {
  active_id: "s1",
  sessions: [{ id: "s1", title: "テスト企画", updated: Math.floor(Date.now() / 1000) - 120, n: 2 }],
  active: {
    id: "s1", title: "テスト企画",
    messages: [
      { who: "user", html: "海辺の動画を作って" },
      { who: "bot", html: '<div class="meta">企画案</div>了解です' }
    ],
    ui: { planStage: "video", lastFinalPrompt: "SEASIDE_PROMPT", lastImgPrompt: null,
          refImages: ["ref1.png"], refConsultActive: false, imguse: "ref",
          curJobId: null, curJobKind: null }
  }
};
await run(`(async () => { await initSessions(); })()`);
await tick();
{
  check("messages rendered", el("msgs").children.length === 2);
  check("user message content", el("msgs").children[0].innerHTML.includes("海辺の動画"));
  check("UI state restored", run(`lastFinalPrompt`) === "SEASIDE_PROMPT" && run(`planStage`) === "video");
  check("refImages restored + footer updated",
    run(`refImages[0]`) === "ref1.png" && el("ref-sel").textContent.includes("ref1.png"));
  check("imguse restored", run(`$("#imguse").value`) === "ref");
  check("activeSessionId set", run(`activeSessionId`) === "s1");
  const items = el("sess-list").children.filter(c => (c.className || "").includes("sessitem"));
  check("sidebar shows session title",
    items.length === 1 && items[0].children[0].textContent === "テスト企画");
  check("sidebar marks active session", (items[0].className || "").includes("active"));
}

console.log("[16] saveSession posts snapshot + dedups unchanged saves");
state.sessionSaves.length = 0;
run(`addMsg("user", "新しいメッセージ");`);
await run(`(async () => { await saveSession(); })()`);
await tick();
{
  check("save posted", state.sessionSaves.length === 1);
  const b = JSON.parse(state.sessionSaves[0].body);
  check("save carries id + messages + ui",
    b.id === "s1" && b.messages.length === 3 && b.ui.planStage === "video");
}
await run(`(async () => { await saveSession(); })()`);
await tick();
check("unchanged save skipped (dedup)", state.sessionSaves.length === 1);

console.log("[17] switchSession: busy guard + loads target session");
run(`setBusy(true);`);
state.alerts.length = 0;
await run(`(async () => { await switchSession("s2"); })()`);
await tick();
check("busy blocks switch", state.alerts.some(a => a.includes("生成が進行中")));
run(`setBusy(false);`);
state.switchResult = {
  id: "s2", title: "別の企画",
  messages: [{ who: "user", html: "別の企画メッセージ" }],
  ui: { planStage: "chat", lastFinalPrompt: null, refImages: [], imguse: "first", curJobId: null }
};
await run(`(async () => { await switchSession("s2"); })()`);
await tick();
{
  check("target session rendered",
    el("msgs").children.length === 1 && el("msgs").children[0].innerHTML.includes("別の企画メッセージ"));
  check("activeSessionId switched", run(`activeSessionId`) === "s2");
  check("imguse restored to first", run(`$("#imguse").value`) === "first");
}
state.switchResult = null;

console.log("[18] newChat starts a fresh session");
await run(`(async () => { await newChat(); })()`);
await tick();
{
  check("messages cleared", el("msgs").children.length === 0);
  check("activeSessionId null", run(`activeSessionId`) === null);
  const switches = state.fetches.filter(f => f.url === "/api/sessions/switch");
  check("switch(null) called", JSON.parse(switches[switches.length - 1].opts.body).id === null);
}

console.log("[19] restoring a session with a running job resumes polling");
state.switchResult = {
  id: "s3", title: "生成中だった企画",
  messages: [{ who: "bot", html: '<div class="meta">生成中…</div>' }],
  ui: { planStage: "video", curJobId: "job-123", curJobKind: "video" }
};
await run(`(async () => { await switchSession("s3"); })()`);
await tick();
{
  check("job state cleared after resumed job completes", run(`curJobId === null && curJobKind === null`));
  check("poll completed after resume", el("msgs").children[0].innerHTML.includes("完成 ✅"));
  check("busy cleared after completion", run(`busy`) === false);
}
state.switchResult = null;
state.sessionsResponse = null;

console.log("[20] extendVideo: last frame staged + continuation setup");
run(`
  setBusy(false);
  segmentChain = []; extendFrom = null; refImages = [];
  $("#imguse").value = "ref"; $("#planmode").checked = false;
`);
await run(`(async () => { await extendVideo("a.mp4"); })()`);
await tick();
{
  const ext = state.fetches.filter(f => f.url === "/api/extend");
  check("extend posted with filename", ext.length === 1 && JSON.parse(ext[0].opts.body).filename === "a.mp4");
  check("refImages = extracted last frame", run(`refImages.length === 1 && refImages[0] === "h3_ext_1.png"`));
  check("imguse forced to first (I2V)", run(`$("#imguse").value`) === "first");
  check("planmode turned on", el("planmode").checked === true);
  check("planStage = video", run(`planStage`) === "video");
  check("extendFrom remembers source video", run(`extendFrom`) === "a.mp4");
  check("chain seeded with source video", run(`segmentChain.length === 1 && segmentChain[0] === "a.mp4"`));
  const bots = el("msgs").children.filter(c => c.className === "msg bot");
  check("guidance message shown", bots[bots.length - 1].innerHTML.includes("続きの準備 ✅"));
}

console.log("[21] continuation completion grows chain + shows action buttons");
// [20] の続き: extendFrom="a.mp4" の状態で動画が完成すると連鎖が伸びる
state.statusResult = { status: "success", videos: [{ filename: "b.mp4", type: "output", path: "C:\\x\\b.mp4", kind: "video" }] };
run(`lastFinalPrompt = "CONT_PROMPT"; $("#imguse").value = "first";`);
await run(`(async () => { genPlanLast(); })()`);
await tick();
{
  check("chain grew on continuation completion", run(`segmentChain.length === 2 && segmentChain[1] === "b.mp4"`));
  check("extendFrom cleared after completion", run(`extendFrom`) === null);
  const bots = el("msgs").children.filter(c => c.className === "msg bot");
  const last = bots[bots.length - 1];
  check("続きを作る + アップスケール buttons shown",
    last.innerHTML.includes("この動画の続きを作る") && last.innerHTML.includes("アップスケール（2倍）"));
  check("concat button shown at chain tail", last.innerHTML.includes("本の動画を1本に結合"));
  // onclick 属性: HTML エンティティをデコードして JS として構文チェック
  // （&quot; 方式がブラウザで実際に動くことの検証）
  const m = last.innerHTML.match(/onclick="([^"]*)"/);
  check("onclick attribute present", !!m);
  if (m) {
    const code = m[1].replace(/&quot;/g, '"').replace(/&amp;/g, "&");
    let okSyntax = true;
    try { new vm.Script(code); } catch (e) { okSyntax = false; }
    check("onclick JS syntactically valid after entity decode", okSyntax, code);
    check("onclick targets the completed file", code.includes("b.mp4"));
  }
}

console.log("[22] upscaleVideo: completes as upscale (no action buttons, no shutdown)");
state.statusResult = { status: "success", videos: [{ filename: "h3_upscaled_1.mp4", type: "output", path: "C:\\x\\h3_upscaled_1.mp4", kind: "video" }] };
el("shutdown-box").style.display = "none";
await run(`(async () => { await upscaleVideo("b.mp4"); })()`);
await tick();
{
  const up = state.fetches.filter(f => f.url === "/api/upscale");
  check("upscale posted with filename + scale=2",
    up.length === 1 && JSON.parse(up[0].opts.body).filename === "b.mp4" && JSON.parse(up[0].opts.body).scale === 2);
  const bots = el("msgs").children.filter(c => c.className === "msg bot");
  const last = bots[bots.length - 1];
  check("upscale completion label", last.innerHTML.includes("アップスケール完了 ✅"));
  check("no continuation buttons on upscale result", !last.innerHTML.includes("この動画の続きを作る"));
  check("chain not polluted by upscale job", run(`segmentChain.length === 2 && extendFrom === null`));
  check("shutdown box not triggered by upscale", el("shutdown-box").style.display !== "block");
  check("busy cleared after upscale", run(`busy`) === false);
}

console.log("[23] concatVideos: posts chain and shows joined player");
state.concatBodies.length = 0;
await run(`(async () => { await concatVideos(${JSON.stringify(JSON.stringify(["a.mp4", "b.mp4"]))}); })()`);
await tick();
{
  check("concat posted with the file list",
    state.concatBodies.length === 1 &&
    JSON.stringify(JSON.parse(state.concatBodies[0]).files) === JSON.stringify(["a.mp4", "b.mp4"]));
  const bots = el("msgs").children.filter(c => c.className === "msg bot");
  const last = bots[bots.length - 1];
  check("joined video player shown", last.innerHTML.includes("結合完了 ✅") && last.innerHTML.includes("h3_joined_1.mp4"));
}
{
  const n = state.concatBodies.length;
  await run(`(async () => { await concatVideos(JSON.stringify(["only.mp4"])); })()`);
  await tick();
  check("concat with <2 files rejected client-side", state.concatBodies.length === n);
}

console.log("[24] segmentChain/extendFrom survive save + session switch");
run(`segmentChain = ["a.mp4", "b.mp4"]; extendFrom = null;`);
state.sessionSaves.length = 0;
run(`addMsg("user", "チェイン保存テスト");`);
await run(`(async () => { await saveSession(); })()`);
await tick();
{
  const b = JSON.parse(state.sessionSaves[state.sessionSaves.length - 1].body);
  check("snapshot carries chain", JSON.stringify(b.ui.segmentChain) === JSON.stringify(["a.mp4", "b.mp4"]));
  check("snapshot carries extendFrom", b.ui.extendFrom === null);
}
state.switchResult = {
  id: "s9", title: "チェイン企画",
  messages: [{ who: "user", html: "チェイン復元" }],
  ui: { planStage: "video", refImages: [], imguse: "first", curJobId: null,
        segmentChain: ["a.mp4", "b.mp4"], extendFrom: "b.mp4" }
};
await run(`(async () => { await switchSession("s9"); })()`);
await tick();
check("chain + extendFrom restored on switch", run(`segmentChain.length === 2 && extendFrom === "b.mp4"`));
state.switchResult = { id: "s10", title: "x", messages: [], ui: { planStage: "chat" } };
await run(`(async () => { await switchSession("s10"); })()`);
await tick();
check("chain reset when session has none", run(`segmentChain.length === 0 && extendFrom === null`));
state.switchResult = null;

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
