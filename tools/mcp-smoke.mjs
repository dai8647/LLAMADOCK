#!/usr/bin/env node
// LlamaDock MCP web-search server — smoke test.
//
// Boots mcp-server.js on an ephemeral port, then verifies:
//   1. GET  /health returns ok
//   2. POST /mcp initialize round-trips
//   3. POST /mcp tools/list exposes search_web, search_and_fetch, fetch_url, deep_research
//   4. search_web returns results (network-dependent; reported, not fatal)
//
// Usage: node tools/mcp-smoke.mjs
// Exit code is 0 when steps 1-3 pass; step 4 failure is reported with a warning
// (sandboxed networks can block outbound search providers).

import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import http from "node:http";

const __dirname = dirname(fileURLToPath(import.meta.url));
const serverPath = join(__dirname, "..", "mcp-server.js");
const PORT = 3900 + Math.floor(Math.random() * 500);

let failures = 0;

function report(name, ok, detail = "") {
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}${detail ? ` — ${detail}` : ""}`);
  if (!ok) failures += 1;
}

function requestJson(port, method, path, body) {
  return new Promise((resolve, reject) => {
    const data = body === undefined ? null : JSON.stringify(body);
    const headers = {
      Accept: "application/json, text/event-stream",
      "MCP-Protocol-Version": "2025-03-26",
    };
    if (data) {
      headers["Content-Type"] = "application/json";
      headers["Content-Length"] = String(Buffer.byteLength(data));
    }
    const req = http.request(
      {
        host: "127.0.0.1",
        port,
        path,
        method,
        headers,
        timeout: 20000,
      },
      (res) => {
        const chunks = [];
        res.on("data", (c) => chunks.push(c));
        res.on("end", () => {
          const raw = Buffer.concat(chunks).toString("utf8");
          // Streamable HTTP may answer with plain JSON or with an SSE frame
          // ("event: message\ndata: {...}"). Accept both.
          let body = null;
          if (raw) {
            try {
              body = JSON.parse(raw);
            } catch {
              const dataLines = raw
                .split(/\r?\n/)
                .filter((line) => line.startsWith("data:"))
                .map((line) => line.slice(5).trim());
              try {
                body = JSON.parse(dataLines.join(""));
              } catch {
                body = raw;
              }
            }
          }
          resolve({ status: res.statusCode, body, raw });
        });
      },
    );
    req.on("timeout", () => req.destroy(new Error("timeout")));
    req.on("error", reject);
    if (data) req.write(data);
    req.end();
  });
}

async function waitForHealth(port, tries = 30) {
  for (let i = 0; i < tries; i += 1) {
    try {
      const res = await requestJson(port, "GET", "/health");
      if (res.status === 200 && res.body?.ok) return true;
    } catch {
      /* not up yet */
    }
    await new Promise((r) => setTimeout(r, 300));
  }
  return false;
}

const child = spawn(process.execPath, [serverPath], {
  env: { ...process.env, MCP_HOST: "127.0.0.1", MCP_PORT: String(PORT) },
  stdio: ["ignore", "pipe", "pipe"],
});

let stderrTail = "";
child.stderr.on("data", (c) => {
  stderrTail = (stderrTail + c.toString()).slice(-2000);
});

let exited = false;
child.on("exit", (code) => {
  exited = true;
  if (code !== 0) report("server exited cleanly", false, `code=${code}`);
});

try {
  report("server boots", await waitForHealth(PORT));

  const init = await requestJson(PORT, "POST", "/mcp", {
    jsonrpc: "2.0",
    id: 1,
    method: "initialize",
    params: {
      protocolVersion: "2025-03-26",
      capabilities: {},
      clientInfo: { name: "llamadock-mcp-smoke", version: "1.0.0" },
    },
  });
  report("initialize round-trip", init.status === 200 && !!init.body?.result?.serverInfo, `status=${init.status}`);

  const tools = await requestJson(PORT, "POST", "/mcp", {
    jsonrpc: "2.0",
    id: 2,
    method: "tools/list",
    params: {},
  });
  const toolNames = (tools.body?.result?.tools || []).map((t) => t.name).sort();
  for (const expected of ["search_web", "search_and_fetch", "fetch_url", "deep_research"]) {
    report(`tool exposed: ${expected}`, toolNames.includes(expected));
  }

  // Real search is network-dependent; report it as a warning, not a hard fail.
  try {
    const search = await requestJson(PORT, "POST", "/mcp", {
      jsonrpc: "2.0",
      id: 3,
      method: "tools/call",
      params: { name: "search_web", arguments: { q: "llama.cpp", limit: 3, lang: "us-en" } },
    });
    const content = search.body?.result?.content?.[0]?.text || "{}";
    const parsed = JSON.parse(content);
    const n = Array.isArray(parsed.results) ? parsed.results.length : -1;
    if (n > 0) {
      report("search_web returns results", true, `n=${n}`);
    } else {
      console.log(`WARN  search_web returned ${n} results (outbound search may be blocked here)`);
    }
  } catch (error) {
    console.log(`WARN  search_web unavailable: ${error.message}`);
  }
} catch (error) {
  report("smoke run", false, error.message);
  console.error(stderrTail);
} finally {
  child.kill("SIGTERM");
  setTimeout(() => {
    if (!exited) child.kill("SIGKILL");
  }, 1500);
}

console.log(failures === 0 ? "\nSmoke test OK." : `\n${failures} check(s) failed.`);
process.exit(failures === 0 ? 0 : 1);
