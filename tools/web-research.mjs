#!/usr/bin/env node
import { JSDOM } from "jsdom";
import { Readability } from "@mozilla/readability";
import TurndownService from "turndown";
import { fetchSafeUrl } from "./safe-fetch.mjs";

const USER_AGENT =
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
  "(KHTML, like Gecko) Chrome/124.0 Safari/537.36";

const query = process.argv.slice(2).join(" ").trim();
if (!query) {
  console.error("Usage: node tools/web-research.mjs <query>");
  process.exit(1);
}

const searchLimit = Number(process.env.RESEARCH_SEARCH_LIMIT || 6);
const fetchLimit = Number(process.env.RESEARCH_FETCH_LIMIT || 4);
const perPageChars = Number(process.env.RESEARCH_PAGE_CHARS || 5000);

let results = await searchDuckDuckGo(query, searchLimit);
if (results.length === 0) {
  results = await searchBrave(query, searchLimit);
}
const pages = [];
for (const result of results.slice(0, fetchLimit)) {
  pages.push(await fetchReadable(result, perPageChars));
}

console.log(
  JSON.stringify(
    {
      query,
      searched_at: new Date().toISOString(),
      result_count: results.length,
      fetched_count: pages.filter((page) => page.ok).length,
      results,
      pages,
    },
    null,
    2,
  ),
);

async function searchDuckDuckGo(q, limit) {
  const searchUrl = new URL("https://html.duckduckgo.com/html/");
  searchUrl.searchParams.set("q", q);
  searchUrl.searchParams.set("kl", "jp-jp");

  const response = await fetch(searchUrl, {
    signal: AbortSignal.timeout(15000),
    headers: {
      "User-Agent": USER_AGENT,
      Accept: "text/html,application/xhtml+xml",
      "Accept-Language": "ja,en-US;q=0.8,en;q=0.6",
    },
  });

  if (!response.ok) {
    throw new Error(`DuckDuckGo returned HTTP ${response.status}`);
  }

  const html = await response.text();
  const dom = new JSDOM(html);
  const items = [...dom.window.document.querySelectorAll(".result")];
  const out = [];

  for (const item of items) {
    const link = item.querySelector(".result__a");
    if (!link) continue;

    const title = cleanText(link.textContent || "");
    const href = normalizeDuckDuckGoUrl(link.getAttribute("href") || "");
    const snippet = cleanText(item.querySelector(".result__snippet")?.textContent || "");
    if (!title || !href) continue;
    if (out.some((entry) => entry.url === href)) continue;

    out.push({ title, url: href, snippet });
    if (out.length >= limit) break;
  }

  return out;
}

async function searchBrave(q, limit) {
  for (let attempt = 0; attempt < 2; attempt += 1) {
    try {
      if (attempt > 0) await new Promise((r) => setTimeout(r, 2000));
      const searchUrl = new URL("https://search.brave.com/search");
      searchUrl.searchParams.set("q", q);
      searchUrl.searchParams.set("source", "web");
      const response = await fetch(searchUrl, {
        signal: AbortSignal.timeout(15000),
        headers: { "User-Agent": USER_AGENT, Accept: "text/html,application/xhtml+xml", "Accept-Language": "ja,en;q=0.6" }
      });
      if (response.status === 429) continue;
      if (!response.ok) return [];
      const html = await response.text();
      if (html.includes("challenge") || html.includes("captcha")) continue;
      const dom = new JSDOM(html);
      const links = [...dom.window.document.querySelectorAll("div[data-type=\"web\"] a, a.result-header")];
      const out = [];
      for (const link of links) {
        const href = link.getAttribute("href") || "";
        if (!href.startsWith("http") || href.includes("brave.com")) continue;
        const title = cleanText(link.textContent || "");
        const parent = link.closest(".snippet, .result, div[data-type=\"web\"]");
        const snippet = parent ? cleanText(parent.querySelector(".snippet-description, .snippet-content")?.textContent || "") : "";
        if (!title || !href) continue;
        if (out.some(e => e.url === href)) continue;
        out.push({ title, url: href, snippet });
        if (out.length >= limit) break;
      }
      if (out.length > 0) return out;
    } catch { /* retry */ }
  }
  return [];
}

async function fetchReadable(result, maxChars) {
  try {
    const response = await fetchSafeUrl(result.url, {
      timeoutMs: 20000,
      headers: {
        "User-Agent": USER_AGENT,
        Accept: "text/html,application/xhtml+xml,text/plain",
        "Accept-Language": "ja,en-US;q=0.8,en;q=0.6",
      },
    });

    if (!response.ok) {
      throw new Error(`HTTP ${response.status}`);
    }

    const contentType = response.headers.get("content-type") || "";
    const raw = await response.text();
    let text = "";

    if (contentType.includes("html")) {
      const dom = new JSDOM(raw, { url: result.url });
      const reader = new Readability(dom.window.document);
      const article = reader.parse();
      if (article?.content) {
        const turndown = new TurndownService({ headingStyle: "atx" });
        text = turndown.turndown(article.content);
      }
      if (!text) {
        text = dom.window.document.body?.textContent || "";
      }
    } else {
      text = raw;
    }

    return {
      ok: true,
      title: result.title,
      url: result.url,
      snippet: result.snippet,
      content: cleanText(text).slice(0, maxChars),
    };
  } catch (error) {
    return {
      ok: false,
      title: result.title,
      url: result.url,
      snippet: result.snippet,
      error: error instanceof Error ? error.message : String(error),
    };
  }
}

function normalizeDuckDuckGoUrl(href) {
  if (!href) return "";
  try {
    const url = new URL(href, "https://duckduckgo.com");
    const redirected = url.searchParams.get("uddg");
    if (redirected) return redirected;
    return url.href;
  } catch {
    return href;
  }
}

function cleanText(value) {
  return value.replace(/\s+/g, " ").trim();
}
