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
  return {
    id, value: "", checked: false, disabled: false, selected: false,
    style: { display: "" }, className: "", innerHTML: "", textContent: "",
    dataset: {}, scrollTop: 0, scrollHeight: 0, placeholder: "",
    children: [], options: [], selectedIndex: -1,
    appendChild(c) { this.children.push(c); return c; },
    addEventListener() {}, removeEventListener() {},
    querySelector() { return null; },
    querySelectorAll() { return []; },
    closest() { return null; },
    classList: { add() {}, remove() {} },
    focus() {}, click() {},
    setAttribute() {}, getAttribute() { return null; },
  };
}

const els = new Map();
function el(id) { if (!els.has(id)) els.set(id, makeEl(id)); return els.get(id); }
el("mode-radio"); // placeholder, unused

const state = {
  fetches: [],
  modeValue: "quick",
  planReply: { reply: "ok" },
  resetFail: false,
  statusResult: { status: "success", videos: [{ filename: "a.mp4", type: "output", path: "C:\\x\\a.mp4", kind: "video" }] },
};

async function fakeFetch(url, opts) {
  state.fetches.push({ url, opts });
  const j = (obj, ok = true, status = 200) => ({ ok, status, json: async () => obj });
  if (url === "/api/queue") return j({ queue_running: [], queue_pending: [] });
  if (url === "/api/plan-models") return j({ models: [], current: null, running: false });
  if (url === "/api/generate") return j({ prompt_id: "p1", eff_mode: state.modeValue, override_label: "" });
  if (url.startsWith("/api/status/")) return j(state.statusResult);
  if (url === "/api/refimages") return j({ images: [{ path: "C:\\ComfyUI\\output\\x.png", name: "x.png", dir: "output" }] });
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
  alert() {},
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
  curImageFilename = "keyimg.png";
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
  curImageFilename = "key2.png";
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

console.log("[6] pickRefImage selection sets imguse=ref");
run(`$("#imguse").value = "first";`);
await run(`(async () => { await pickRefImage(); })()`);
await tick();
{
  const grid = el("refgrid");
  check("ref grid populated", grid.children.length === 1);
  grid.children[0].onclick();
  check("imguse switched to ref on pick", run(`$("#imguse").value`) === "ref");
  check("curImageFilename set to picked path", run(`curImageFilename`) === "C:\\ComfyUI\\output\\x.png");
  check("ref-clear visible", el("ref-clear").style.display === "inline-block");
}

console.log("[7] resetPlan: server failure is surfaced, not swallowed");
state.resetFail = true;
const msgsBefore = el("msgs").children.length;
await run(`(async () => { await resetPlan(); })()`);
await tick();
{
  const added = el("msgs").children.slice(msgsBefore);
  check("warning shown on reset failure",
    added.some(c => c.innerHTML.includes("サーバー側のリセットに失敗")));
  check("local state cleared anyway", run(`lastFinalPrompt === null && planStage === "chat"`));
}
state.resetFail = false;
const msgsBefore2 = el("msgs").children.length;
await run(`(async () => { await resetPlan(); })()`);
await tick();
{
  const added = el("msgs").children.slice(msgsBefore2);
  check("no warning on successful reset",
    !added.some(c => c.innerHTML.includes("サーバー側のリセットに失敗")));
  check("reset greeted", added.some(c => c.innerHTML.includes("新しい企画を始めましょう")));
}

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
