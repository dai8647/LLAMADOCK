#!/usr/bin/env node
import { JSDOM, VirtualConsole } from "jsdom";
import { Readability } from "@mozilla/readability";
import TurndownService from "turndown";
import { fetchSafeUrl } from "./safe-fetch.mjs";

const USER_AGENT =
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
  "(KHTML, like Gecko) Chrome/124.0 Safari/537.36";
const VIRTUAL_CONSOLE = new VirtualConsole();

const rawArgs = process.argv.slice(2);
if (rawArgs.includes("--help") || rawArgs.includes("-h")) {
  console.error("Usage: node tools/deep-research-harness.mjs <query>");
  console.error("Optional env: RESEARCH_MODE=light|standard|heavy");
  process.exit(0);
}

const query = rawArgs.join(" ").trim();
if (!query) {
  console.error("Usage: node tools/deep-research-harness.mjs <query>");
  process.exit(1);
}

const mode = (process.env.RESEARCH_MODE || "standard").toLowerCase();
const config = getModeConfig(mode);
const llmBaseUrl = (process.env.RESEARCH_LLM_BASE_URL || "http://127.0.0.1:8080/v1").replace(/\/$/, "");
const llmModel = process.env.RESEARCH_LLM_MODEL || (await discoverModel(llmBaseUrl)) || "local-model";
const pageChars = numberEnv("RESEARCH_PAGE_CHARS", config.pageChars);
const context = deriveQueryContext(query);

const state = {
  question: query,
  mode,
  searched_at: new Date().toISOString(),
  llm: { base_url: llmBaseUrl, model: llmModel },
  config,
  context,
  plan: buildPlan(query, context),
  rounds: [],
  evidence: [],
  rejected: [],
  unresolved_gaps: [],
};

progress(`mode=${mode}, model=${llmModel}`);
progress(`context entity="${context.entity}" location="${context.location}" category="${context.category}"`);
let activeGaps = state.plan.map((item) => item.question);
progress(`plan angles=${state.plan.length}`);

for (let round = 1; round <= config.rounds; round += 1) {
  progress(`round ${round}/${config.rounds}: generating queries`);
  const queries = generateQueries(query, state.plan, activeGaps, round, context);
  const roundState = {
    round,
    goals: activeGaps,
    queries,
    search_results: [],
    fetched_pages: [],
    extracted: [],
  };

  progress(`round ${round}: searching ${queries.length} queries`);
  for (const q of queries) {
    progress(`round ${round}: query "${q}"`);
    const searchResults = await searchWeb(q, config.resultsPerQuery);
    for (const result of searchResults) {
      if (!roundState.search_results.some((item) => item.url === result.url)) {
        roundState.search_results.push({ query: q, ...result });
      }
    }
  }

  const ranked = rankResults(roundState.search_results, query, context, state.evidence)
    .slice(0, config.fetchPerRound);
  progress(`round ${round}: search_results=${roundState.search_results.length}, fetching=${ranked.length}`);

  for (const result of ranked) {
    progress(`round ${round}: fetch ${result.url}`);
    const page = await fetchReadable(result, pageChars);
    roundState.fetched_pages.push(page);
    if (!page.ok || !page.content) {
      const fallbackEvidence = evidenceFromSearchResult(result, round, context);
      if (fallbackEvidence && !isDuplicateEvidence(state.evidence, fallbackEvidence)) {
        state.evidence.push(fallbackEvidence);
        roundState.extracted.push(fallbackEvidence);
      }
      state.rejected.push({ url: result.url, title: result.title, reason: page.error || "empty content" });
      continue;
    }

    if (!isPageRelevant(page, context)) {
      const fallbackEvidence = evidenceFromSearchResult(result, round, context);
      if (fallbackEvidence && !isDuplicateEvidence(state.evidence, fallbackEvidence)) {
        state.evidence.push(fallbackEvidence);
        roundState.extracted.push(fallbackEvidence);
      }
      state.rejected.push({ url: page.url, title: page.title, reason: "missing critical query terms" });
      continue;
    }

    const extracted = await extractEvidence(query, activeGaps, page);
    progress(`round ${round}: extracted ${extracted.length} finding(s) from ${page.url}`);
    for (const item of extracted) {
      const evidence = normalizeEvidence(item, page, round, context);
      if (evidence && !isDuplicateEvidence(state.evidence, evidence)) {
        state.evidence.push(evidence);
        roundState.extracted.push(evidence);
      }
    }
  }

  activeGaps = reflectGaps(state.plan, state.evidence).slice(0, Math.min(5, config.planItems));
  progress(`round ${round}: total_evidence=${state.evidence.length}, remaining_gaps=${activeGaps.length}`);
  state.unresolved_gaps = activeGaps;
  state.rounds.push(roundState);
  if (state.evidence.length >= config.maxEvidence || activeGaps.length === 0) break;
}

state.evidence = state.evidence
  .sort((a, b) => b.score - a.score)
  .slice(0, config.maxEvidence);
state.source_count = new Set(state.evidence.map((item) => item.url)).size;
state.evidence_count = state.evidence.length;
state.summary = {
  answered_angles: summarizeCoverage(state.plan, state.evidence),
  remaining_gaps: state.unresolved_gaps,
  source_urls: [...new Set(state.evidence.map((item) => item.url))],
};

console.log(JSON.stringify({
  question: state.question,
  mode: state.mode,
  searched_at: state.searched_at,
  context: state.context,
  plan: state.plan,
  evidence: state.evidence.map((item) => ({
    claim: item.claim,
    evidence: item.evidence,
    date: item.date,
    angle: item.angle,
    source_quality: item.source_quality,
    confidence: item.confidence,
    title: item.title,
    url: item.url,
  })),
  summary: state.summary,
}));

function getModeConfig(value) {
  const modes = {
    light: {
      rounds: 2,
      planItems: 4,
      queriesPerRound: 4,
      resultsPerQuery: 3,
      fetchPerRound: 5,
      maxEvidence: 16,
      pageChars: 3000,
      llmMaxTokens: 600,
    },
    standard: {
      rounds: 3,
      planItems: 6,
      queriesPerRound: 8,
      resultsPerQuery: 2,
      fetchPerRound: 8,
      maxEvidence: 32,
      pageChars: 4000,
      llmMaxTokens: 768,
    },
    heavy: {
      rounds: 4,
      planItems: 8,
      queriesPerRound: 10,
      resultsPerQuery: 2,
      fetchPerRound: 10,
      maxEvidence: 48,
      pageChars: 5000,
      llmMaxTokens: 960,
    },
  };
  const selected = modes[value] || modes.standard;
  return {
    ...selected,
    searchBudget: selected.rounds * selected.queriesPerRound * selected.resultsPerQuery,
    fetchBudget: selected.rounds * selected.fetchPerRound,
  };
}

function progress(message) {
  console.error(`[research] ${message}`);
}

async function discoverModel(baseUrl) {
  try {
    const response = await fetch(`${baseUrl}/models`, { signal: AbortSignal.timeout(5000) });
    if (!response.ok) return "";
    const data = await response.json();
    return data?.data?.[0]?.id || "";
  } catch {
    return "";
  }
}

function buildPlan(userQuestion, ctx) {
  const label = ctx.label || userQuestion;
  const base = [
    ["A1", `${label}の公式サイト、公式プロフィール、基本情報を確認する`, "公式情報を最初に固定する"],
    ["A2", `${label}の口コミ、評判、第三者サイトの評価を確認する`, "利用者評価と外部評価を見る"],
    ["A3", `${label}の料金、システム、利用条件を確認する`, "具体的な利用条件を見る"],
    ["A4", `${label}の所在地、対応エリア、地域名との一致を確認する`, "同名別件を除外する"],
    ["A5", `${label}の最新情報、更新日、営業状況を確認する`, "古い情報を避ける"],
    ["A6", `${label}の注意点、トラブル情報、信頼性を確認する`, "リスクと信頼性を見る"],
    ["A7", `${label}と同名サービス、別業種、別地域との取り違えを除外する`, "検索ノイズを除外する"],
    ["A8", `${label}について複数ソースで同じ事実を照合する`, "単一ソース依存を避ける"],
  ];
  return base.slice(0, config.planItems).map(([id, question, rationale]) => ({ id, question, rationale }));
}

function generateQueries(userQuestion, plan, gaps, round, ctx) {
  const targets = (gaps.length ? gaps : plan.map((item) => item.question)).slice(0, config.planItems);
  const fallback = buildSeedQueries(userQuestion, ctx, round);
  for (const target of targets) {
    const cleanTarget = stripAnglePrefix(target);
    if (isQuerySpecific(cleanTarget, ctx)) {
      fallback.push(cleanTarget);
      fallback.push(`${cleanTarget} 最新`);
    }
  }

  return uniqueStrings(fallback)
    .filter((item) => item.length > 2)
    .filter((item) => isQuerySpecific(item, ctx))
    .map((item) => item.slice(0, 180))
    .slice(0, config.queriesPerRound);
}

function buildSeedQueries(userQuestion, ctx, round) {
  const core = [ctx.location, ctx.entity, ctx.category].filter(Boolean).join(" ");
  const base = core || userQuestion;
  const perRound = [
    ["公式", "口コミ", "評判", "料金"],
    ["システム", "アクセス", "営業", "更新"],
    ["レビュー", "掲示板", "比較", "注意"],
    ["最新", "閉店", "求人", "店舗情報"],
  ];
  const modifiers = perRound[Math.min(round - 1, perRound.length - 1)];
  return uniqueStrings([
    base,
    ctx.entity ? `"${ctx.entity}" ${[ctx.location, ctx.category].filter(Boolean).join(" ")}` : "",
    `${base} 公式`,
    ...modifiers.map((term) => `${base} ${term}`),
    ctx.entity && ctx.category ? `${ctx.entity} ${ctx.category}` : "",
    ctx.entity && ctx.location ? `${ctx.entity} ${ctx.location}` : "",
    userQuestion,
  ]);
}

async function extractEvidence(userQuestion, gaps, page) {
  const prompt = [
    "Extract useful evidence for a Japanese research report from this page.",
    "Return JSON only: {\"findings\":[{\"claim\":\"...\",\"evidence\":\"...\",\"date\":\"\",\"angle\":\"...\",\"source_quality\":\"high|medium|low\",\"confidence\":0.0}]}",
    "Only include facts directly supported by the page text. Prefer specific facts, dates, numbers, exact names, and URLs.",
    "Return {\"findings\":[]} if the page is not directly related, only generic, or about a different entity.",
    "Do not guess.",
    "",
    `Original request: ${userQuestion}`,
    `Open gaps: ${JSON.stringify(gaps)}`,
    `Page title: ${page.title}`,
    `URL: ${page.url}`,
    `Content:\n${page.content.slice(0, pageChars)}`,
  ].join("\n");

  const data = await callJson(prompt, 0.1, config.llmMaxTokens);
  if (Array.isArray(data?.findings)) return data.findings;

  const fallbackClaim = cleanText(page.snippet || page.content.slice(0, 600));
  return fallbackClaim ? [{ claim: fallbackClaim, evidence: fallbackClaim, source_quality: "low", confidence: 0.25 }] : [];
}

function reflectGaps(plan, evidence) {
  const covered = summarizeCoverage(plan, evidence);
  return covered
    .filter((item) => item.evidence_count === 0)
    .map((item) => item.question);
}

async function callJson(prompt, temperature, maxTokens) {
  try {
    const response = await fetch(`${llmBaseUrl}/chat/completions`, {
      method: "POST",
      signal: AbortSignal.timeout(90000),
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        model: llmModel,
        messages: [
          {
            role: "system",
            content:
              "You are a careful web research extractor. Return valid JSON only. Preserve user-provided proper nouns exactly. Use Japanese for Japanese fields.",
          },
          { role: "user", content: prompt },
        ],
        temperature,
        max_tokens: maxTokens,
      }),
    });
    if (!response.ok) return null;
    const data = await response.json();
    const content = data?.choices?.[0]?.message?.content || "";
    return parseJsonLoose(content);
  } catch {
    return null;
  }
}

async function searchDuckDuckGo(q, limit) {
  for (let attempt = 0; attempt < 2; attempt += 1) {
    try {
      const searchUrl = new URL("https://html.duckduckgo.com/html/");
      searchUrl.searchParams.set("q", q);
      searchUrl.searchParams.set("kl", "jp-jp");
      searchUrl.searchParams.set("kp", "-2");
      const response = await fetch(searchUrl, {
        signal: AbortSignal.timeout(15000),
        headers: {
          "User-Agent": attempt === 0 ? USER_AGENT : "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/123.0 Safari/537.36",
          Accept: "text/html,application/xhtml+xml",
          "Accept-Language": "ja,en-US;q=0.8,en;q=0.6",
        },
      });
      if (!response.ok) continue;
      const html = await response.text();
      if (html.includes("challenge")) continue;
      const dom = new JSDOM(html, { virtualConsole: VIRTUAL_CONSOLE });
      const items = [...dom.window.document.querySelectorAll(".result")];
      const out = [];
      for (const item of items) {
        const link = item.querySelector(".result__a");
        if (!link) continue;
        const title = cleanText(link.textContent || "");
        const href = normalizeDuckDuckGoUrl(link.getAttribute("href") || "");
        const snippet = cleanText(item.querySelector(".result__snippet")?.textContent || "");
        if (!title || !href || !isUsefulHttpUrl(href)) continue;
        if (out.some((entry) => entry.url === href)) continue;
        out.push({ title, url: href, snippet });
        if (out.length >= limit) break;
      }
      if (out.length > 0) return out;
    } catch {
      // retry
    }
  }
  return [];
}

async function searchBing(q, limit) {
  try {
    const searchUrl = new URL("https://www.bing.com/search");
    searchUrl.searchParams.set("q", q);
    searchUrl.searchParams.set("setlang", "ja-JP");
    searchUrl.searchParams.set("cc", "JP");
    searchUrl.searchParams.set("count", "20");
    searchUrl.searchParams.set("safesearch", "off");

    const response = await fetch(searchUrl, {
      signal: AbortSignal.timeout(15000),
      headers: {
        "User-Agent": USER_AGENT,
        Accept: "text/html,application/xhtml+xml",
        "Accept-Language": "ja,en-US;q=0.8,en;q=0.6",
      },
    });
    if (!response.ok) return [];
    const html = await response.text();
    const dom = new JSDOM(html, { virtualConsole: VIRTUAL_CONSOLE });
    const items = [...dom.window.document.querySelectorAll("li.b_algo")];
    const out = [];
    for (const item of items) {
      const link = item.querySelector("h2 a");
      if (!link) continue;
      const title = cleanText(link.textContent || "");
      const url = normalizeBingUrl(link.getAttribute("href") || "");
      const snippet = cleanText(item.querySelector(".b_caption p, p")?.textContent || "");
      if (!title || !url || !isUsefulHttpUrl(url)) continue;
      if (out.some((entry) => entry.url === url)) continue;
      out.push({ title, url, snippet });
      if (out.length >= limit) break;
    }
    return out;
  } catch {
    return [];
  }
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
        headers: {
          "User-Agent": USER_AGENT,
          Accept: "text/html,application/xhtml+xml",
          "Accept-Language": "ja,en-US;q=0.8,en;q=0.6",
          Cookie: "safesearch=off",
        },
      });
      if (response.status === 429) continue;
      if (!response.ok) return [];
      const html = await response.text();
      if (html.includes("challenge") || html.includes("captcha")) continue;
      const dom = new JSDOM(html, { virtualConsole: VIRTUAL_CONSOLE });
      const links = [...dom.window.document.querySelectorAll("div[data-type=\"web\"] a, a.result-header")];
      const out = [];
      for (const link of links) {
        const href = link.getAttribute("href") || "";
        if (!href.startsWith("http") || href.includes("brave.com")) continue;
        const title = cleanText(link.textContent || "");
        const parent = link.closest(".snippet, .result, div[data-type=\"web\"]");
        const snippet = parent ? cleanText(parent.querySelector(".snippet-description, .snippet-content")?.textContent || "") : "";
        if (!title || !href) continue;
        if (out.some((entry) => entry.url === href)) continue;
        out.push({ title, url: href, snippet });
        if (out.length >= limit) break;
      }
      if (out.length > 0) return out;
    } catch {
      // retry
    }
  }
  return [];
}

async function searchWeb(q, limit) {
  const serper = await searchSerper(q, limit);
  if (serper.length > 0) return filterRelevantResults(serper.map((item) => ({ ...item, engine: "serper" })), q);
  const brave = await searchBrave(q, limit);
  if (brave.length > 0) return filterRelevantResults(brave.map((item) => ({ ...item, engine: "brave" })), q);
  const ddg = await searchDuckDuckGo(q, limit);
  if (ddg.length > 0) return filterRelevantResults(ddg.map((item) => ({ ...item, engine: "duckduckgo" })), q);
  return filterRelevantResults((await searchBing(q, limit)).map((item) => ({ ...item, engine: "bing" })), q);
}

async function searchSerper(q, limit) {
  const apiKey = process.env.SERPER_API_KEY || process.env.SERPER_KEY || "";
  if (!apiKey) return [];
  try {
    const response = await fetch("https://google.serper.dev/search", {
      method: "POST",
      signal: AbortSignal.timeout(15000),
      headers: {
        "X-API-KEY": apiKey,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        q,
        gl: "jp",
        hl: "ja",
        num: Math.min(Math.max(limit, 3), 10),
        autocorrect: false,
      }),
    });
    if (!response.ok) return [];
    const data = await response.json();
    const organic = Array.isArray(data?.organic) ? data.organic : [];
    return organic
      .map((item) => ({
        title: cleanText(item.title || ""),
        url: cleanText(item.link || ""),
        snippet: cleanText(item.snippet || ""),
      }))
      .filter((item) => item.title && item.url && isUsefulHttpUrl(item.url))
      .slice(0, limit);
  } catch {
    return [];
  }
}

async function fetchReadable(result, maxChars) {
  try {
    const response = await fetchSafeUrl(result.url, {
      timeoutMs: 25000,
      headers: {
        "User-Agent": USER_AGENT,
        Accept: "text/html,application/xhtml+xml,text/plain",
        "Accept-Language": "ja,en-US;q=0.8,en;q=0.6",
      },
    });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);

    const contentType = response.headers.get("content-type") || "";
    const raw = await response.text();
    let text = "";
    if (contentType.includes("html")) {
      const dom = new JSDOM(raw, { url: result.url, virtualConsole: VIRTUAL_CONSOLE });
      const reader = new Readability(dom.window.document);
      const article = reader.parse();
      if (article?.content) {
        const turndown = new TurndownService({ headingStyle: "atx" });
        text = turndown.turndown(article.content);
      }
      if (!text) text = dom.window.document.body?.textContent || "";
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

function deriveQueryContext(userQuestion) {
  const text = cleanText(userQuestion);
  const categoryTerms = [
    "デリヘル", "風俗", "ソープ", "メンズエステ", "キャバクラ", "コンカフェ",
    "ホテル", "レストラン", "クリニック", "病院", "会社", "サービス",
  ];
  const category = categoryTerms.find((term) => text.includes(term)) || "";

  let entity = "";
  const patterns = [
    /[「『"]([^「」『'"]{2,40})[」』"]/,
    /にある\s*([^\s、。]{2,40}?)を?という(?:店|サービス|会社|デリヘル|風俗|サイト)/,
    /([^\s、。]{2,40}?)という(?:店|サービス|会社|デリヘル|風俗|サイト)/,
    /(?:ある|の|店名|サービス名|という)\s*([^\s、。について]{2,40}?)\s*(?:という|について|を|の)/,
  ];
  for (const pattern of patterns) {
    const match = text.match(pattern);
    if (match?.[1]) {
      entity = cleanupEntity(match[1], category);
      if (entity) break;
    }
  }

  const locationMatch = text.match(/([一-龠ぁ-んァ-ンA-Za-z0-9]{2,12})(?:駅|周辺|にある|の)(?=.*(?:という|について|調査|評判|口コミ|公式|デリヘル|風俗))/);
  const location = locationMatch?.[1] || "";
  const label = [location, entity, category].filter(Boolean).join(" ");
  return { text, entity, location, category, label: label || text };
}

function cleanupEntity(value, category) {
  let text = cleanText(value)
    .replace(/^.*?にある\s*/, "")
    .replace(/^(?:にある|ある|の|店名|サービス名|という)\s*/, "")
    .replace(/\s*(?:という|について|を|の|調査).*$/, "")
    .replace(/[をはがの]$/, "")
    .trim();
  if (category) text = text.replace(new RegExp(`${escapeRegex(category)}.*$`), "").trim();
  if (text.length < 2 || text.length > 40) return "";
  return text;
}

function isQuerySpecific(queryText, ctx) {
  const text = cleanText(queryText);
  if (text.length < 2) return false;
  if (!/[\p{L}\p{N}]/u.test(text)) return false;
  if (ctx.entity && !text.includes(ctx.entity)) return false;
  if (ctx.location && ctx.category) return text.includes(ctx.location) || text.includes(ctx.category);
  if (ctx.location && !text.includes(ctx.location)) return false;
  if (ctx.category && !text.includes(ctx.category)) return false;
  return true;
}

function isRelevantResult(result, q) {
  const terms = cleanText(q).toLowerCase().split(/\s+/).filter((term) => term.length > 1);
  if (terms.length === 0) return true;
  const haystack = `${result.title} ${result.snippet}`.toLowerCase();
  let matchCount = 0;
  for (const term of terms) {
    if (haystack.includes(term)) matchCount += 1;
  }
  return matchCount >= Math.ceil(terms.length * 0.5);
}

function filterRelevantResults(results, q) {
  const relevant = results.filter((r) => isRelevantResult(r, q));
  if (relevant.length >= 2) return relevant;
  return results;
}

function isPageRelevant(page, ctx) {
  const haystack = `${page.title} ${page.snippet} ${page.content} ${page.url}`.toLowerCase();
  if (ctx.entity && !haystack.includes(ctx.entity.toLowerCase())) return false;
  if (ctx.location && ctx.category) {
    return haystack.includes(ctx.location.toLowerCase()) || haystack.includes(ctx.category.toLowerCase());
  }
  if (ctx.location && !haystack.includes(ctx.location.toLowerCase())) return false;
  if (ctx.category && !haystack.includes(ctx.category.toLowerCase())) return false;
  return true;
}

const BLOCKED_DOMAINS = [
  "xhamster", "xvideos", "pornhub", "xnxx", "xhamster3", "xhcdn",
  "zhihu.com", "douban.com", "weibo.com", "baidu.com",
  "facebook.com", "instagram.com", "tiktok.com",
  "youtube.com", "quora.com",
  "amazon.com", "amazon.co.jp", "ebay.com",
  "aliexpress.com", "taobao.com",
];

function isBlockedDomain(url) {
  try {
    const host = new URL(url).hostname.toLowerCase();
    return BLOCKED_DOMAINS.some((d) => host.includes(d));
  } catch {
    return false;
  }
}

function rankResults(results, userQuestion, ctx, existingEvidence) {
  const seenUrls = new Set(existingEvidence.map((item) => item.url));
  const terms = new Set([userQuestion, ctx.entity, ctx.location, ctx.category]
    .filter(Boolean)
    .flatMap((value) => cleanText(value).toLowerCase().split(/\s+/))
    .filter((term) => term.length > 1));

  return results
    .filter((item) => !seenUrls.has(item.url))
    .filter((item) => !isBlockedDomain(item.url))
    .map((item) => {
      const haystack = `${item.title} ${item.snippet} ${item.url}`.toLowerCase();
      let score = 0;
      for (const term of terms) {
        if (haystack.includes(term)) score += 1;
      }
      if (ctx.entity && haystack.includes(ctx.entity.toLowerCase())) score += 5;
      if (ctx.location && haystack.includes(ctx.location.toLowerCase())) score += 2;
      if (ctx.category && haystack.includes(ctx.category.toLowerCase())) score += 2;
      if (/official|公式|access|price|system|review|口コミ|評判|料金|店舗|shop|site/i.test(haystack)) score += 1;
      if (/login|signin|account|cart|privacy|terms/i.test(item.url)) score -= 3;
      return { ...item, score };
    })
    .sort((a, b) => b.score - a.score);
}

function normalizeEvidence(item, page, round, ctx) {
  const claim = cleanText(String(item.claim || ""));
  const evidence = cleanText(String(item.evidence || ""));
  if (!claim || !evidence) return null;
  const combined = `${claim} ${evidence} ${page.title} ${page.url}`.toLowerCase();
  if (ctx.entity && !combined.includes(ctx.entity.toLowerCase())) return null;
  const confidence = Math.max(0, Math.min(1, Number(item.confidence ?? 0.5)));
  const quality = String(item.source_quality || "medium").toLowerCase();
  const qualityScore = quality === "high" ? 2 : quality === "low" ? 0 : 1;
  return {
    claim: claim.slice(0, 300),
    evidence: evidence.slice(0, 500),
    date: cleanText(String(item.date || "")).slice(0, 80),
    angle: cleanText(String(item.angle || "")).slice(0, 120),
    source_quality: ["high", "medium", "low"].includes(quality) ? quality : "medium",
    confidence,
    title: page.title,
    url: page.url,
    snippet: page.snippet,
    round,
    score: confidence * 10 + qualityScore,
  };
}

function evidenceFromSearchResult(result, round, ctx) {
  const claim = cleanText(`${result.title}${result.snippet ? ` - ${result.snippet}` : ""}`);
  if (!claim) return null;
  const combined = `${claim} ${result.url}`.toLowerCase();
  if (ctx.entity && !combined.includes(ctx.entity.toLowerCase())) return null;
  if (ctx.location && ctx.category && !combined.includes(ctx.location.toLowerCase()) && !combined.includes(ctx.category.toLowerCase())) return null;
  if (ctx.location && !ctx.category && !combined.includes(ctx.location.toLowerCase())) return null;
  if (ctx.category && !ctx.location && !combined.includes(ctx.category.toLowerCase())) return null;
  return {
    claim: claim.slice(0, 300),
    evidence: cleanText(result.snippet || result.title).slice(0, 500),
    date: "",
    angle: "search result snippet",
    source_quality: "low",
    confidence: 0.3,
    title: result.title,
    url: result.url,
    snippet: result.snippet,
    round,
    score: 3,
  };
}

function isDuplicateEvidence(existing, item) {
  const norm = item.claim.toLowerCase().replace(/[^\p{L}\p{N}]/gu, "").slice(0, 80);
  return existing.some((old) => {
    const oldNorm = old.claim.toLowerCase().replace(/[^\p{L}\p{N}]/gu, "").slice(0, 80);
    return old.url === item.url && oldNorm === norm;
  });
}

function summarizeCoverage(plan, evidence) {
  return plan.map((angle) => {
    const keywords = extractKeywords(angle.question);
    const count = evidence.filter((item) => {
      const haystack = `${item.angle} ${item.claim} ${item.evidence} ${item.title}`.toLowerCase();
      return keywords.some((keyword) => haystack.includes(keyword.toLowerCase()));
    }).length;
    return { id: angle.id, question: angle.question, evidence_count: count };
  });
}

function extractKeywords(value) {
  return uniqueStrings(cleanText(value)
    .split(/[、。,\s]+/)
    .filter((part) => part.length >= 2)
    .slice(0, 8));
}

function parseJsonLoose(content) {
  const trimmed = String(content || "").trim();
  if (!trimmed) return null;
  try {
    return JSON.parse(trimmed);
  } catch {}

  const fenced = trimmed.match(/```(?:json)?\s*([\s\S]*?)```/i);
  if (fenced) {
    try {
      return JSON.parse(fenced[1].trim());
    } catch {}
  }

  const start = trimmed.indexOf("{");
  const end = trimmed.lastIndexOf("}");
  if (start >= 0 && end > start) {
    try {
      return JSON.parse(trimmed.slice(start, end + 1));
    } catch {}
  }
  return null;
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

function normalizeBingUrl(href) {
  if (!href) return "";
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

function cleanText(value) {
  return String(value || "").replace(/\s+/g, " ").trim();
}

function uniqueStrings(values) {
  const out = [];
  for (const value of values) {
    const text = cleanText(String(value || ""));
    if (!text) continue;
    if (out.some((item) => item.toLowerCase() === text.toLowerCase())) continue;
    out.push(text);
  }
  return out;
}

function stripAnglePrefix(value) {
  return cleanText(value).replace(/^[^:：・]{2,40}[:：・]\s*/, "");
}

function escapeRegex(value) {
  return String(value).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function numberEnv(name, fallback) {
  const value = Number(process.env[name]);
  return Number.isFinite(value) && value > 0 ? value : fallback;
}
