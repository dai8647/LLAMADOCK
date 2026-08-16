// Shared SSRF guard used by the MCP server and the research harnesses.
//
// Web-search tools are exposed to local agents, so do not allow them to reach
// loopback, private, link-local, or metadata endpoints (including redirects
// and DNS names that resolve to those ranges). Redirects are checked one hop
// at a time to reduce SSRF and DNS-rebinding risk.
import dns from "node:dns/promises";
import net from "node:net";

const LOOPBACK_NAMES = new Set([
  "localhost",
  "localhost.localdomain",
  "metadata.google.internal",
]);

const IPV4_MAPPED_RE = /^::ffff:(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})$/i;
const IPV4_COMPAT_RE = /^::(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})$/i;
const IPV4_HEX_RE = /^[0-9a-f]{8}$/i;

function blockedIpv4(a, b, c, d) {
  return a === 0 || a === 10 || a === 127 || (a === 169 && b === 254) ||
    (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168) ||
    a >= 224;
}

export function isBlockedIp(value) {
  let normalized = String(value || "").toLowerCase().replace(/^\[|\]$/g, "");
  // Expand IPv4-mapped (::ffff:10.0.0.1 / ::ffff:a00:1) and IPv4-compatible
  // (::10.0.0.1) addresses to their IPv4 form so they cannot dodge the IPv4
  // private-range check. Without this, net.isIP() reports family 6 and the v6
  // rules miss embedded private IPv4 addresses.
  const mapped = normalized.match(IPV4_MAPPED_RE);
  const compatible = normalized.match(IPV4_COMPAT_RE);
  if (mapped || compatible) {
    normalized = (mapped || compatible)[1];
  } else if (normalized.startsWith("::ffff:")) {
    // Node's URL normalizes ::ffff:10.0.0.1 to ::ffff:a00:1 (hex form).
    // Recover the embedded IPv4 address from the trailing hex groups, padding
    // each group back to 4 digits (compression drops leading zeros).
    const groups = normalized.slice(7).split(":");
    const hex = groups.map((g) => g.padStart(4, "0")).join("");
    if (IPV4_HEX_RE.test(hex)) {
      const n = parseInt(hex, 16);
      normalized = `${(n >>> 24) & 255}.${(n >>> 16) & 255}.${(n >>> 8) & 255}.${n & 255}`;
    }
  }

  const family = net.isIP(normalized);
  if (family === 4) {
    const octets = normalized.split(".").map(Number);
    return blockedIpv4(octets[0], octets[1], octets[2], octets[3]);
  }
  if (family === 6) {
    return normalized === "::" || normalized === "::1" || normalized.startsWith("fe80:") ||
      normalized.startsWith("fc") || normalized.startsWith("fd") || normalized.startsWith("ff");
  }
  return false;
}

export async function assertSafeRemoteUrl(value) {
  let url;
  try {
    url = new URL(value);
  } catch {
    throw new Error("URL is invalid");
  }
  if (!["http:", "https:"].includes(url.protocol)) {
    throw new Error("Only HTTP(S) URLs are allowed");
  }
  const hostname = url.hostname.replace(/^\[|\]$/g, "").toLowerCase();
  if (isBlockedIp(hostname) || LOOPBACK_NAMES.has(hostname)) {
    throw new Error("Private or local network URLs are blocked");
  }
  const records = await dns.lookup(hostname, { all: true, verbatim: true });
  if (!records.length || records.some((record) => isBlockedIp(record.address))) {
    throw new Error("URL resolves to a private or local network address");
  }
}

// Fetches a URL while re-checking the SSRF guard on every redirect hop.
// `options` may carry `timeoutMs` and `headers`; `redirect: "manual"` is forced
// so each hop is validated before it is followed.
export async function fetchSafeUrl(initialUrl, options = {}) {
  const timeoutMs = options.timeoutMs || 15000;
  const headers = options.headers || {};
  let currentUrl = initialUrl;
  for (let hop = 0; hop <= 5; hop += 1) {
    await assertSafeRemoteUrl(currentUrl);
    const response = await fetch(currentUrl, {
      redirect: "manual",
      signal: AbortSignal.timeout(timeoutMs),
      headers,
    });
    if (![301, 302, 303, 307, 308].includes(response.status)) return response;
    const location = response.headers.get("location");
    if (!location) throw new Error(`Fetch returned redirect ${response.status} without Location`);
    if (hop === 5) throw new Error("Fetch exceeded redirect limit");
    currentUrl = new URL(location, currentUrl).href;
  }
  throw new Error("Fetch exceeded redirect limit");
}
