#!/usr/bin/env node
import http from "node:http";
import { URL } from "node:url";
import { execFile } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { fetchSafeUrl } from "./tools/safe-fetch.mjs";
import { Readability } from "@mozilla/readability";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { JSDOM } from "jsdom";
import TurndownService from "turndown";
import { z } from "zod";

const HOST = process.env.MCP_HOST || "127.0.0.1";
const PORT = Number(process.env.MCP_PORT || 3100);
const ENDPOINT = "/mcp";
const USER_AGENT =
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
  "(KHTML, like Gecko) Chrome/124.0 Safari/537.36";
const REQUEST_TIMEOUT_MS = Number(process.env.MCP_WEB_TIMEOUT_MS || 15000);

// Serper API key lives in the environment only (never committed). When set,
// search_web / search_and_fetch use Serper as the primary provider and the
// HTML-scraping providers (DuckDuckGo / Brave / Bing) as fallbacks.
const SERPER_API_KEY = process.env.SERPER_API_KEY || "";
const SERPER_ENDPOINT = "https://google.serper.dev/search";

// In-memory search-result cache: identical queries within the TTL are served
// without hitting the network again. Keyed by provider set + query + region.
const SEARCH_CACHE_TTL_MS = Number(process.env.MCP_SEARCH_CACHE_TTL_MS || 5 * 60 * 1000);
const searchCache = new Map();

function cacheKey(provider, query, limit, region) {
  return `${provider}|${limit}|${region}|${query.trim().toLowerCase()}`;
}

function cacheGet(provider, query, limit, region) {
  const key = cacheKey(provider, query, limit, region);
  const hit = searchCache.get(key);
  if (!hit) return null;
  if (Date.now() - hit.at > SEARCH_CACHE_TTL_MS) {
    searchCache.delete(key);
    return null;
  }
  return hit.results;
}

function cacheSet(provider, query, limit, region, results) {
  if (!results || results.length === 0) return;
  const key = cacheKey(provider, query, limit, region);
  searchCache.set(key, { at: Date.now(), results });
  // Bound the cache size so a research burst cannot grow memory unbounded.
  if (searchCache.size > 200) {
    const oldest = searchCache.keys().next().value;
    searchCache.delete(oldest);
  }
}

const MAX_BODY_BYTES = 10 * 1024 * 1024; // 10 MiB request body cap (memory DoS guard)
// The research harness can run up to 1200s (heavy mode); keep the execFile
// timeout aligned so MCP deep_research is not cut off mid-run.
const RESEARCH_TIMEOUT_MS = Number(process.env.MCP_RESEARCH_TIMEOUT_MS || 1200000);

const httpServer = http.createServer(async (req, res) => {
  setCorsHeaders(res, req);

  if (req.method === "OPTIONS") {
    res.writeHead(204);
    res.end();
    return;
  }

  const reqUrl = new URL(req.url || "/", `http://${req.headers.host || `${HOST}:${PORT}`}`);

  if (reqUrl.pathname === "/health") {
    sendJson(res, 200, { ok: true, endpoint: `http://${HOST}:${PORT}${ENDPOINT}` });
    return;
  }

  if (reqUrl.pathname !== ENDPOINT) {
    sendJson(res, 404, {
      error: "not_found",
      message: `Use http://${HOST}:${PORT}${ENDPOINT} as the MCP endpoint.`,
    });
    return;
  }

  if (req.method !== "POST") {
    sendJson(res, 405, {
      jsonrpc: "2.0",
      error: { code: -32000, message: "Method not allowed." },
      id: null,
    });
    return;
  }

  const mcpServer = createMcpServer();
  const transport = new StreamableHTTPServerTransport({
    sessionIdGenerator: undefined,
  });

  res.on("close", () => {
    transport.close();
    mcpServer.close();
  });

  try {
    await mcpServer.connect(transport);
    // Streamable HTTP responses may contain Japanese search results.  Keep
    // the charset explicit so Windows clients that do not default to UTF-8
    // do not render valid UTF-8 bytes as mojibake.
    const setHeader = res.setHeader.bind(res);
    res.setHeader = (name, value) => {
      if (String(name).toLowerCase() === "content-type" && String(value).toLowerCase() === "text/event-stream") {
        value = "text/event-stream; charset=utf-8";
      }
      return setHeader(name, value);
    };
    res.setHeader("Content-Type", "text/event-stream; charset=utf-8");
    const body = await readJsonBody(req);
    await transport.handleRequest(req, res, body);
  } catch (error) {
    console.error(error);
    if (!res.headersSent) {
      const status = error && error.statusCode ? error.statusCode : 500;
      if (status === 413) res.setHeader("Connection", "close");
      sendJson(res, status, { error: "mcp_error", message: errorMessage(error) });
    } else {
      res.end();
    }
  }
});

httpServer.listen(PORT, HOST, () => {
  console.error(`MCP Web Search server running at http://${HOST}:${PORT}${ENDPOINT}`);
});

function createMcpServer() {
  const mcpServer = new McpServer({
    name: "mcp-web-search",
    version: "1.0.0",
  });

  mcpServer.registerTool(
    "search_web",
    {
      title: "Web Search",
      description:
        "Search the web. Uses the Serper API when SERPER_API_KEY is set, otherwise falls back to DuckDuckGo / Brave / Bing HTML search. Identical queries within a short window are served from cache.",
      inputSchema: {
        q: z.string().min(1).describe("Search query"),
        limit: z.number().int().min(1).max(20).default(8),
        lang: z.string().default("jp-jp").describe("Search region, such as jp-jp or us-en"),
        provider: z.enum(["auto", "serper", "bing", "duckduckgo", "brave"]).default("auto"),
      },
    },
    async ({ q, limit = 8, lang = "jp-jp", provider = "auto" }) => {
      const results = await searchWeb(q, limit, lang, provider);
      return textResult({ provider, query: q, lang, results });
    },
  );

  mcpServer.registerTool(
    "search_and_fetch",
    {
      title: "Search And Fetch",
      description:
        "Search the web, fetch top result pages, and return extracted readable content for research.",
      inputSchema: {
        q: z.string().min(1).describe("Search query"),
        search_limit: z.number().int().min(1).max(20).default(8),
        fetch_limit: z.number().int().min(1).max(10).default(5),
        lang: z.string().default("jp-jp").describe("Search region/language, such as jp-jp or us-en"),
        provider: z.enum(["auto", "serper", "bing", "duckduckgo", "brave"]).default("auto"),
        per_page_chars: z.number().int().min(500).max(20000).default(5000),
        include_failed: z.boolean().default(false),
      },
    },
    async ({
      q,
      search_limit = 8,
      fetch_limit = 5,
      lang = "jp-jp",
      provider = "auto",
      per_page_chars = 5000,
      include_failed = false,
    }) => {
      const startedAt = Date.now();
      const searchResults = await searchWeb(q, search_limit, lang, provider);
      const selectedResults = searchResults.slice(0, fetch_limit);
      const pages = await Promise.all(
        selectedResults.map((result) => fetchSearchResult(result, per_page_chars)),
      );
      const usablePages = include_failed ? pages : pages.filter((page) => page.ok);

      return textResult({
        provider,
        query: q,
        lang,
        search_result_count: searchResults.length,
        fetched_count: usablePages.length,
        elapsed_ms: Date.now() - startedAt,
        pages: usablePages,
      });
    },
  );

  mcpServer.registerTool(
    "fetch_url",
    {
      title: "Fetch URL Content",
      description: "Fetch a URL and extract readable page content.",
      inputSchema: {
        url: z.string().url(),
        mode: z.enum(["compact", "standard", "full"]).default("standard"),
        max_length: z.number().int().min(500).max(100000).optional(),
        format: z.enum(["markdown", "text", "html"]).default("markdown"),
      },
    },
    async ({ url, mode = "standard", max_length, format = "markdown" }) => {
      const content = await fetchUrl(url, mode, max_length, format);
      return textResult(content);
    },
  );

  const harnessScriptPath = join(
    dirname(fileURLToPath(import.meta.url)),
    "tools",
    "deep-research-harness.mjs",
  );

  mcpServer.registerTool(
    "deep_research",
    {
      title: "Deep Research",
      description:
        "Run iterative deep-research harness. Searches multiple angles, fetches pages, extracts evidence with LLM, and returns a structured evidence pack. Use for thorough investigation of a topic.",
      inputSchema: {
        q: z.string().min(1).describe("Research query or topic to investigate deeply"),
        mode: z.enum(["light", "standard", "heavy"]).default("standard").describe("Research depth: light (fast), standard (balanced), heavy (most thorough)"),
      },
    },
    async ({ q, mode = "standard" }) => {
      const llmBaseUrl = process.env.RESEARCH_LLM_BASE_URL || "http://127.0.0.1:8080/v1";
      const llmModel = process.env.RESEARCH_LLM_MODEL || "local-model";

      const result = await new Promise((resolve, reject) => {
        execFile(
          "node",
          [harnessScriptPath, q],
          {
            timeout: RESEARCH_TIMEOUT_MS,
            maxBuffer: 10 * 1024 * 1024,
            env: {
              ...process.env,
              RESEARCH_MODE: mode,
              RESEARCH_LLM_BASE_URL: llmBaseUrl,
              RESEARCH_LLM_MODEL: llmModel,
            },
          },
          (error, stdout, stderr) => {
            if (error && !stdout) {
              reject(new Error(`Deep research failed: ${error.message}\n${stderr}`));
              return;
            }
            resolve(stdout);
          },
        );
      });

      return textResult(result);
    },
  );

  return mcpServer;
}

async function searchWeb(query, limit, region, provider) {
  // Serve repeat queries from cache before touching the network.
  const cached = cacheGet(provider, query, limit, region);
  if (cached) return cached;

  const results = [];
  const errors = [];
  let providers;
  if (provider === "auto") {
    providers = SERPER_API_KEY
      ? ["serper", "duckduckgo", "brave", "bing"]
      : ["duckduckgo", "brave", "bing"];
  } else {
    providers = [provider];
  }

  for (const currentProvider of providers) {
    try {
      let nextResults;
      if (currentProvider === "serper") {
        nextResults = await searchSerper(query, limit);
      } else if (currentProvider === "bing") {
        nextResults = await searchBing(query, limit, region);
      } else if (currentProvider === "brave") {
        nextResults = await searchBrave(query, limit);
      } else {
        nextResults = await searchDuckDuckGo(query, limit, region);
      }
      mergeSearchResults(results, nextResults, limit);
      if (results.length >= limit) break;
    } catch (error) {
      errors.push({ provider: currentProvider, error: errorMessage(error) });
    }
  }

  if (results.length === 0 && errors.length > 0) {
    throw new Error(errors.map((item) => `${item.provider}: ${item.error}`).join("; "));
  }

  if (results.length > 0) cacheSet(provider, query, limit, region, results);
  return results;
}

async function searchSerper(query, limit) {
  const response = await fetch(SERPER_ENDPOINT, {
    method: "POST",
    signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
    headers: {
      "Content-Type": "application/json",
      "X-API-KEY": SERPER_API_KEY,
    },
    body: JSON.stringify({ q: query, num: Math.min(limit, 20), gl: "jp", hl: "ja" }),
  });

  if (!response.ok) {
    throw new Error(`Serper returned HTTP ${response.status}`);
  }

  const payload = await response.json();
  const results = [];
  for (const item of payload.organic || []) {
    const title = cleanText(item.title);
    const url = item.link;
    const snippet = cleanText(item.snippet);
    if (!title || !isUsefulHttpUrl(url)) continue;
    results.push({ provider: "serper", title, url, snippet });
    if (results.length >= limit) break;
  }
  return results;
}

async function searchDuckDuckGo(query, limit, region) {
  const searchUrl = new URL("https://html.duckduckgo.com/html/");
  searchUrl.searchParams.set("q", query);
  searchUrl.searchParams.set("kl", region);

  const response = await fetch(searchUrl, {
    signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
    headers: {
      "User-Agent": USER_AGENT,
      Accept: "text/html,application/xhtml+xml",
      "Accept-Language": regionToAcceptLanguage(region),
    },
  });

  if (!response.ok) {
    throw new Error(`DuckDuckGo returned HTTP ${response.status}`);
  }

  const html = await response.text();
  const dom = new JSDOM(html);
  const document = dom.window.document;
  const items = [...document.querySelectorAll(".result")];
  const results = [];

  for (const item of items) {
    const link = item.querySelector(".result__a");
    if (!link) continue;

    const title = cleanText(link.textContent);
    const rawHref = link.getAttribute("href") || "";
    const url = normalizeDuckDuckGoUrl(rawHref);
    const snippet = cleanText(item.querySelector(".result__snippet")?.textContent || "");

    if (!title || !url || url.includes("duckduckgo.com/y.js")) continue;
    results.push({ provider: "duckduckgo", title, url, snippet });
    if (results.length >= limit) break;
  }

  return results;
}

async function searchBrave(query, limit) {
  for (let attempt = 0; attempt < 2; attempt += 1) {
    try {
      if (attempt > 0) await new Promise((r) => setTimeout(r, 2000));
      const searchUrl = new URL("https://search.brave.com/search");
      searchUrl.searchParams.set("q", query);
      searchUrl.searchParams.set("source", "web");

      const response = await fetch(searchUrl, {
        signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
        headers: {
          "User-Agent": USER_AGENT,
          Accept: "text/html,application/xhtml+xml",
          "Accept-Language": "ja,en-US;q=0.8,en;q=0.6",
        },
      });

      if (response.status === 429) continue;
      if (!response.ok) throw new Error(`Brave returned HTTP ${response.status}`);

      const html = await response.text();
      if (html.includes("challenge") || html.includes("captcha")) continue;
      const dom = new JSDOM(html);
      const document = dom.window.document;
      const links = [...document.querySelectorAll("div[data-type=\"web\"] a, a.result-header")];
      const results = [];

      for (const link of links) {
        const href = link.getAttribute("href") || "";
        if (!href.startsWith("http") || href.includes("brave.com")) continue;
        const title = cleanText(link.textContent);
        const parent = link.closest(".snippet, .result, div[data-type=\"web\"]");
        const snippet = parent
          ? cleanText(parent.querySelector(".snippet-description, .snippet-content")?.textContent || "")
          : "";
        if (!title || !isUsefulHttpUrl(href)) continue;
        if (results.some((entry) => entry.url === href)) continue;
        results.push({ provider: "brave", title, url: href, snippet });
        if (results.length >= limit) break;
      }

      if (results.length > 0) return results;
    } catch (error) {
      if (attempt === 1) throw error;
    }
  }
  return [];
}

async function searchBing(query, limit, region) {
  const searchUrl = new URL("https://www.bing.com/search");
  searchUrl.searchParams.set("q", query);
  searchUrl.searchParams.set("count", String(Math.min(50, Math.max(limit, 10))));
  searchUrl.searchParams.set("setlang", regionToBingLanguage(region));
  searchUrl.searchParams.set("cc", regionToCountry(region));

  const response = await fetch(searchUrl, {
    signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
    headers: {
      "User-Agent": USER_AGENT,
      Accept: "text/html,application/xhtml+xml",
      "Accept-Language": regionToAcceptLanguage(region),
    },
  });

  if (!response.ok) {
    throw new Error(`Bing returned HTTP ${response.status}`);
  }

  const html = await response.text();
  const dom = new JSDOM(html);
  const document = dom.window.document;
  const items = [...document.querySelectorAll("li.b_algo")];
  const results = [];

  for (const item of items) {
    const link = item.querySelector("h2 a");
    if (!link) continue;

    const title = cleanText(link.textContent);
    const url = normalizeBingUrl(link.getAttribute("href") || "");
    const snippet = cleanText(
      item.querySelector(".b_caption p")?.textContent ||
        item.querySelector("p")?.textContent ||
        "",
    );

    if (!title || !isUsefulHttpUrl(url)) continue;
    results.push({ provider: "bing", title, url, snippet });
    if (results.length >= limit) break;
  }

  return results;
}

async function fetchSearchResult(result, perPageChars) {
  try {
    const page = await fetchUrl(result.url, "standard", perPageChars, "markdown");
    return {
      ok: true,
      source_provider: result.provider,
      search_title: result.title,
      search_snippet: result.snippet,
      url: page.url,
      title: page.title || result.title,
      content_type: page.content_type,
      truncated: page.truncated,
      content: page.content,
    };
  } catch (error) {
    return {
      ok: false,
      source_provider: result.provider,
      search_title: result.title,
      search_snippet: result.snippet,
      url: result.url,
      error: errorMessage(error),
    };
  }
}

async function fetchUrl(url, mode, maxLength, format) {
  const response = await fetchWithGuard(url);

  if (!response.ok) {
    throw new Error(`Fetch returned HTTP ${response.status}`);
  }

  const contentType = response.headers.get("content-type") || "";
  const source = await response.text();
  const limit = maxLength || defaultMaxLength(mode);
  let title = "";
  let output = source;

  if (contentType.includes("html")) {
    const dom = new JSDOM(source, { url });
    const article = new Readability(dom.window.document.cloneNode(true)).parse();
    title = article?.title || dom.window.document.title || "";

    if (format === "html") {
      output = article?.content || dom.window.document.body?.innerHTML || source;
    } else if (format === "text") {
      output = article?.textContent || dom.window.document.body?.textContent || source;
    } else {
      const turndown = new TurndownService({ headingStyle: "atx", codeBlockStyle: "fenced" });
      output = turndown.turndown(article?.content || dom.window.document.body?.innerHTML || source);
    }
  } else if (format === "markdown" || format === "text") {
    output = source;
  }

  output = cleanForModel(output);
  const truncated = output.length > limit;
  if (truncated) output = `${output.slice(0, limit)}\n\n[truncated]`;

  return {
    url: response.url || url,
    title: cleanText(title),
    mode,
    format,
    content_type: contentType,
    content_length: output.length,
    truncated,
    content: output,
  };
}

// SSRF guard (fetchSafeUrl / assertSafeRemoteUrl / isBlockedIp) lives in
// tools/safe-fetch.mjs and is shared with the research harnesses.
async function fetchWithGuard(url) {
  return fetchSafeUrl(url, {
    timeoutMs: REQUEST_TIMEOUT_MS,
    headers: {
      "User-Agent": USER_AGENT,
      Accept: "text/html,application/xhtml+xml,text/plain;q=0.9,*/*;q=0.8",
      "Accept-Language": "ja,en-US;q=0.8,en;q=0.6",
    },
  });
}

function mergeSearchResults(target, source, limit) {
  const seen = new Set(target.map((item) => canonicalUrl(item.url)));
  for (const item of source) {
    const key = canonicalUrl(item.url);
    if (!key || seen.has(key)) continue;
    target.push(item);
    seen.add(key);
    if (target.length >= limit) break;
  }
}

function textResult(value) {
  return {
    content: [{ type: "text", text: JSON.stringify(value, null, 2) }],
  };
}

function defaultMaxLength(mode) {
  if (mode === "compact") return 3000;
  if (mode === "full") return 100000;
  return 8000;
}

function normalizeDuckDuckGoUrl(href) {
  try {
    const url = new URL(href, "https://duckduckgo.com");
    const uddg = url.searchParams.get("uddg");
    return uddg ? decodeURIComponent(uddg) : url.href;
  } catch {
    return href;
  }
}

function normalizeBingUrl(href) {
  try {
    const url = new URL(href, "https://www.bing.com");
    const target = url.searchParams.get("u") || url.searchParams.get("url");
    if (target) {
      try {
        const stripped = target.startsWith("a1") ? target.slice(2) : target;
        return Buffer.from(stripped, "base64").toString("utf-8");
      } catch {
        return decodeURIComponent(target);
      }
    }
    if (url.hostname.includes("bing.com") && url.pathname.startsWith("/ck/")) return "";
    return url.href;
  } catch {
    return href;
  }
}

function canonicalUrl(value) {
  try {
    const url = new URL(value);
    url.hash = "";
    for (const param of ["utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content"]) {
      url.searchParams.delete(param);
    }
    return url.href;
  } catch {
    return "";
  }
}

function isUsefulHttpUrl(value) {
  try {
    const url = new URL(value);
    if (!["http:", "https:"].includes(url.protocol)) return false;
    if (url.hostname.includes("bing.com") && url.pathname.startsWith("/ck/")) return false;
    return true;
  } catch {
    return false;
  }
}

function regionToAcceptLanguage(region) {
  if (region.toLowerCase().startsWith("jp")) return "ja-JP,ja;q=0.9,en-US;q=0.7,en;q=0.5";
  return "en-US,en;q=0.9,ja;q=0.6";
}

function regionToBingLanguage(region) {
  return region.toLowerCase().startsWith("jp") ? "ja" : "en";
}

function regionToCountry(region) {
  return region.toLowerCase().startsWith("jp") ? "JP" : "US";
}

function cleanText(value) {
  return String(value || "").replace(/\s+/g, " ").trim();
}

function cleanForModel(value) {
  return String(value || "")
    .replace(/\r/g, "")
    .replace(/\n{4,}/g, "\n\n\n")
    .trim();
}

function isLoopbackHostname(hostname) {
  const host = String(hostname || "").toLowerCase().replace(/^\[|\]$/g, "");
  return host === "localhost" || host === "localhost.localdomain" ||
    host === "::1" || host === "::ffff:127.0.0.1" ||
    /^127\.\d{1,3}\.\d{1,3}\.\d{1,3}$/.test(host);
}

function setCorsHeaders(res, req) {
  // The server binds to 127.0.0.1, so only grant CORS to pages served from
  // loopback origins. Requests without an Origin header (curl, native MCP
  // clients such as Cline/OpenCode) get no CORS headers, which is fine: only
  // browsers enforce CORS, and a browser page from anywhere else must not be
  // able to POST to the MCP endpoint.
  const origin = req && req.headers && req.headers.origin;
  let allowedOrigin = null;
  if (origin) {
    try {
      if (isLoopbackHostname(new URL(origin).hostname)) allowedOrigin = origin;
    } catch {
      allowedOrigin = null;
    }
  }
  if (!allowedOrigin) return;
  res.setHeader("Access-Control-Allow-Origin", allowedOrigin);
  res.setHeader("Vary", "Origin");
  res.setHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
  res.setHeader(
    "Access-Control-Allow-Headers",
    "Content-Type, MCP-Protocol-Version, Mcp-Session-Id, Last-Event-ID",
  );
  res.setHeader("Access-Control-Expose-Headers", "Mcp-Session-Id");
}

function sendJson(res, status, value) {
  res.writeHead(status, { "Content-Type": "application/json; charset=utf-8" });
  res.end(JSON.stringify(value, null, 2));
}

class BodyTooLargeError extends Error {
  constructor() {
    super("Request body exceeds the 10 MiB limit");
    this.statusCode = 413;
  }
}

function readJsonBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let totalBytes = 0;
    req.on("data", (chunk) => {
      totalBytes += chunk.length;
      if (totalBytes > MAX_BODY_BYTES) {
        // Do not destroy the socket (the client would see a reset instead of
        // the 413); drain the rest of the body and let the caller respond.
        req.resume();
        reject(new BodyTooLargeError());
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => {
      const raw = Buffer.concat(chunks).toString("utf8");
      if (!raw) {
        resolve(undefined);
        return;
      }
      try {
        resolve(JSON.parse(raw));
      } catch (error) {
        reject(new Error(`Invalid JSON body: ${errorMessage(error)}`));
      }
    });
    req.on("error", reject);
  });
}

function errorMessage(error) {
  return error instanceof Error ? error.message : String(error);
}
