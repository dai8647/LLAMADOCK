// Character library store (config/characters/) for the LlamaDock Web GUI.
// ---------------------------------------------------------------------------
// One JSON file per character (<id>.json), edited from the GUI and consumed by
// tools/h3-chat.py (which re-reads the directory on every request, so changes
// apply on the next generation without restarting anything). Kept as a pure
// store module so the CRUD + validation logic is unit-testable without HTTP
// (same pattern as results-store.js).
//
// Security: ids are validated against ^[a-z0-9][a-z0-9_-]{0,63}$ before they
// ever touch the filesystem, so path traversal via an id is impossible.
// ---------------------------------------------------------------------------
import { readFile, writeFile, rename, mkdir, readdir, stat, unlink, rm } from "node:fs/promises";
import { dirname, join, resolve, sep } from "node:path";

const CHAR_ID_RE = /^[a-z0-9][a-z0-9_-]{0,63}$/;
export const ALLOWED_REF_EXTS = [".png", ".jpg", ".jpeg", ".webp"];
export const MAX_REF_BYTES = 20 * 1024 * 1024; // 20MB — generous for photos

export function charIdOk(id) {
  return typeof id === "string" && CHAR_ID_RE.test(id);
}

function cleanTags(value) {
  // English tag column: collapse whitespace/newlines to single spaces.
  return String(value ?? "").replace(/\s+/g, " ").trim();
}

function cleanLora(value) {
  if (!value || typeof value !== "object") return {};
  const out = {};
  for (const engine of ["kimg", "krea2", "qimg"]) {
    const list = value[engine];
    if (!Array.isArray(list)) continue;
    const entries = [];
    for (const entry of list) {
      const e = typeof entry === "string" ? { name: entry } : entry;
      const name = String(e?.name ?? "").trim();
      if (!name || name.includes("/") || name.includes("\\") || name.includes("..")) continue;
      let strength = Number(e?.strength);
      if (!Number.isFinite(strength)) strength = 1.0;
      strength = Math.min(2.0, Math.max(0.0, strength));
      entries.push({ name, strength: Math.round(strength * 100) / 100 });
    }
    if (entries.length) out[engine] = entries;
  }
  return out;
}

/** Validate + normalize a card body. Returns { ok, card?, error? }. */
export function normalizeCard(body, { existingId } = {}) {
  if (!body || typeof body !== "object") return { ok: false, error: "body はオブジェクトで指定してください" };
  const id = String(body.id ?? existingId ?? "").trim();
  if (!charIdOk(id)) {
    return { ok: false, error: "id は小文字英数字・ハイフン・_ の 1〜64 文字で指定してください" };
  }
  const name = String(body.name ?? "").trim().slice(0, 100);
  if (!name) return { ok: false, error: "name は必須です" };
  const summary = cleanTags(body.summary);
  if (!summary) return { ok: false, error: "summary（英語タグ列）は必須です" };
  let seed = body.seed ?? null;
  if (seed !== null && seed !== "") {
    const n = Number(seed);
    if (!Number.isInteger(n) || n < 0) return { ok: false, error: "seed は 0 以上の整数か null で指定してください" };
    seed = n % (2 ** 31 - 1);
  } else {
    seed = null;
  }
  const refImages = (Array.isArray(body.refImages) ? body.refImages : [])
    .filter((p) => typeof p === "string" && p.trim())
    .map((p) => String(p).trim())
    .slice(0, 9);
  return {
    ok: true,
    card: {
      id,
      name,
      summary: summary.slice(0, 2000),
      negative: cleanTags(body.negative).slice(0, 1000),
      lora: cleanLora(body.lora),
      seed,
      refImages,
      notes: String(body.notes ?? "").slice(0, 4000),
      updated: new Date().toISOString(),
    },
  };
}

/** List every valid card in the directory (invalid files are skipped). */
export async function listCharacters(dir) {
  let names;
  try {
    names = await readdir(dir);
  } catch {
    return [];
  }
  const out = [];
  for (const fn of names.sort()) {
    if (!fn.endsWith(".json")) continue;
    try {
      const card = JSON.parse(await readFile(join(dir, fn), "utf8"));
      if (card && typeof card === "object" && charIdOk(card.id) && card.summary) out.push(card);
    } catch {
      /* skip broken file */
    }
  }
  return out;
}

/** Atomic write (tmp + rename), same pattern as saveModelsConfig. */
export async function saveCharacter(dir, body) {
  const { ok, card, error } = normalizeCard(body);
  if (!ok) throw new Error(error);
  await mkdir(dir, { recursive: true });
  const path = join(dir, `${card.id}.json`);
  const tmp = `${path}.tmp`;
  await writeFile(tmp, `${JSON.stringify(card, null, 2)}\n`, "utf8");
  await rename(tmp, path);
  return card;
}

export async function readCharacter(dir, id) {
  if (!charIdOk(id)) return null;
  try {
    return JSON.parse(await readFile(join(dir, `${id}.json`), "utf8"));
  } catch {
    return null;
  }
}

export async function deleteCharacter(dir, id) {
  if (!charIdOk(id)) throw new Error("id が不正です");
  const path = join(dir, `${id}.json`);
  await unlink(path);
  // Leave reference images alone: they live under ref/<id>/ and are removed
  // only by the explicit refimg DELETE endpoint.
}

/** Path boundary check for reference-image storage: ref/<id>/<file>. */
export function refDir(root, id) {
  if (!charIdOk(id)) throw new Error("id が不正です");
  const allowed = resolve(join(root, "ref", id));
  if (!allowed.startsWith(resolve(root) + sep)) throw new Error("id が不正です");
  return allowed;
}

export function refFileName(name) {
  // Reject separators outright: only the bare filename (stem + extension)
  // survives. Traversal like "../evil.png" or "..\\..\\x.png" throws here
  // instead of silently sanitizing into a file that looks harmless.
  const raw = String(name ?? "");
  if (!raw || /[\\/]\.\.[\\/]/.test(raw) || raw.startsWith("..") || raw.includes("\\") || raw.includes("/")) {
    throw new Error("ファイル名にパス区切りや .. は使えません");
  }
  const dot = raw.lastIndexOf(".");
  if (dot <= 0) throw new Error(`拡張子は ${ALLOWED_REF_EXTS.join(" / ")} のみです`);
  const ext = raw.slice(dot).toLowerCase();
  if (!ALLOWED_REF_EXTS.includes(ext)) throw new Error(`拡張子は ${ALLOWED_REF_EXTS.join(" / ")} のみです`);
  const stem = raw.slice(0, dot).replace(/[^\w-]+/g, "_").slice(0, 80) || "img";
  return `${Date.now()}_${stem}${ext}`;
}

export async function listRefImages(root, id) {
  const dir = refDir(root, id);
  let names;
  try {
    names = await readdir(dir);
  } catch {
    return [];
  }
  const out = [];
  for (const fn of names.sort()) {
    if (!ALLOWED_REF_EXTS.includes(fn.slice(fn.lastIndexOf(".")).toLowerCase())) continue;
    try {
      const st = await stat(join(dir, fn));
      out.push({ file: fn, size: st.size, url: `/api/characters/${id}/refimg/${encodeURIComponent(fn)}` });
    } catch {
      /* skip unreadable */
    }
  }
  return out;
}

export async function deleteRefImage(root, id, file) {
  const dir = refDir(root, id);
  const target = resolve(join(dir, file));
  if (!target.startsWith(dir + sep)) throw new Error("ファイル名が不正です");
  await rm(target, { force: true });
}

export { dirname };
