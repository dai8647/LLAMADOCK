import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, writeFile, readFile, rm, mkdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  charIdOk, normalizeCard, listCharacters, saveCharacter, readCharacter,
  deleteCharacter, refDir, refFileName, listRefImages, deleteRefImage,
} from "./characters-store.js";

test("charIdOk rejects traversal and bad shapes", () => {
  assert.equal(charIdOk("akari"), true);
  assert.equal(charIdOk("char-01_x"), true);
  assert.equal(charIdOk("..\\evil"), false);
  assert.equal(charIdOk("../evil"), false);
  assert.equal(charIdOk(""), false);
  assert.equal(charIdOk("Capital"), false);
  assert.equal(charIdOk(null), false);
  assert.equal(charIdOk("x".repeat(65)), false);
});

test("normalizeCard validates required fields and clamps values", () => {
  const ok = normalizeCard({ id: "akari", name: "あかり", summary: "japanese woman,  mid-20s" });
  assert.equal(ok.ok, true);
  assert.equal(ok.card.summary, "japanese woman, mid-20s"); // whitespace collapsed
  assert.equal(ok.card.seed, null);
  assert.deepEqual(ok.card.lora, {});

  assert.equal(normalizeCard({ name: "x", summary: "s" }).ok, false); // missing id
  assert.equal(normalizeCard({ id: "ok", summary: "s" }).ok, false); // missing name
  assert.equal(normalizeCard({ id: "ok", name: "n" }).ok, false); // missing summary
  assert.equal(normalizeCard({ id: "OK", name: "n", summary: "s" }).ok, false); // bad id
  assert.equal(normalizeCard({ id: "ok", name: "n", summary: "s", seed: -1 }).ok, false);
  assert.equal(normalizeCard({ id: "ok", name: "n", summary: "s", seed: 1.5 }).ok, false);

  const clamped = normalizeCard({
    id: "ok", name: "n", summary: "s", seed: 2 ** 32,
    lora: { kimg: [{ name: "a.safetensors", strength: 9 }], weird: [{ name: "x" }] },
  });
  assert.equal(clamped.ok, true);
  assert.ok(Number.isInteger(clamped.card.seed) && clamped.card.seed >= 0 && clamped.card.seed < 2 ** 31 - 1, "seed wrapped into int31 range");
  assert.deepEqual(Object.keys(clamped.card.lora), ["kimg"]);
  assert.equal(clamped.card.lora.kimg[0].strength, 2.0);
  assert.equal(clamped.card.lora.kimg[1], undefined); // unknown engine dropped
});

test("saveCharacter writes atomically and listCharacters skips invalid files", async () => {
  const dir = await mkdtemp(join(tmpdir(), "llamadock-chars-"));
  const card = await saveCharacter(dir, { id: "akari", name: "あかり", summary: "s" });
  assert.equal(card.id, "akari");
  const raw = await readFile(join(dir, "akari.json"), "utf8");
  assert.match(raw, /"id": "akari"/);
  assert.equal(await readFile(join(dir, "akari.json.tmp"), "utf8").then(() => true, () => false), false);

  await writeFile(join(dir, "broken.json"), "{oops", "utf8");
  await writeFile(join(dir, "index.json"), JSON.stringify({ _readme: "template" }), "utf8");
  const cards = await listCharacters(dir);
  assert.deepEqual(cards.map((c) => c.id), ["akari"]); // broken + template skipped
  await rm(dir, { recursive: true, force: true });
});

test("readCharacter + deleteCharacter round-trip", async () => {
  const dir = await mkdtemp(join(tmpdir(), "llamadock-chars-"));
  await saveCharacter(dir, { id: "akari", name: "あかり", summary: "s" });
  assert.equal((await readCharacter(dir, "akari")).name, "あかり");
  assert.equal(await readCharacter(dir, "..\\evil"), null);
  await deleteCharacter(dir, "akari");
  assert.equal(await readCharacter(dir, "akari"), null);
  await assert.rejects(() => deleteCharacter(dir, "../evil"));
  await rm(dir, { recursive: true, force: true });
});

test("ref image paths stay inside ref/<id>/", async () => {
  const root = await mkdtemp(join(tmpdir(), "llamadock-chars-"));
  const dir = refDir(root, "akari");
  assert.ok(dir.startsWith(join(root, "ref") + (process.platform === "win32" ? "\\" : "/")));
  assert.throws(() => refDir(root, "..\\evil"));

  const name = refFileName("my photo.PNG");
  assert.match(name, /^\d+_my_photo\.png$/);
  assert.throws(() => refFileName("evil.exe"));
  assert.throws(() => refFileName("../../evil.png"));

  // upload -> list -> delete round-trip
  await mkdir(dir, { recursive: true });
  const { writeFile: wf } = await import("node:fs/promises");
  await wf(join(dir, name), Buffer.from("pngdata"));
  const imgs = await listRefImages(root, "akari");
  assert.equal(imgs.length, 1);
  assert.equal(imgs[0].file, name);
  await deleteRefImage(root, "akari", name);
  assert.equal((await listRefImages(root, "akari")).length, 0);
  await assert.rejects(() => deleteRefImage(root, "akari", "..\\..\\x.png"));
  await rm(root, { recursive: true, force: true });
});
