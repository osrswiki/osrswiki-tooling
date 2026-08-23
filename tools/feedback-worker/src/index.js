/**
 * OSRS Wiki feedback Worker — POST /createGithubIssue
 *
 * Compatible request shapes (Task 3 clients keep the same path name):
 * - Android CloudFunctionIssueRequest: { title, body, labels? }
 * - iOS osrsCloudFunctionIssueRequest: { title, body, labels?, platform: "ios" }
 * - Extended: { title, body, labels?, platform?, appVersion?, distribution?: "play"|"foss" }
 *
 * Routing: platform=ios → osrswiki/osrswiki-ios; otherwise → osrswiki/osrswiki-android
 * Auth: env.GITHUB_TOKEN (wrangler secret). Never log the token.
 */

const MAX_TITLE_LEN = 200;
const MAX_BODY_LEN = 8000;
const MAX_LABELS = 10;
const MAX_LABEL_LEN = 50;
const MAX_JSON_BYTES = 32 * 1024;

/** @type {Map<string, { count: number, resetAt: number }>} */
const rateLimitByIp = new Map();
const RATE_LIMIT_WINDOW_MS = 15 * 60 * 1000;
const RATE_LIMIT_MAX = 8;

const PLATFORM_REPOS = {
  ios: "osrswiki-ios",
  android: "osrswiki-android",
};

function jsonResponse(status, payload, extraHeaders = {}) {
  return new Response(JSON.stringify(payload), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      ...corsHeaders(),
      ...extraHeaders,
    },
  });
}

function corsHeaders() {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type, User-Agent",
    "Access-Control-Max-Age": "3600",
  };
}

function clientIp(request) {
  return (
    request.headers.get("CF-Connecting-IP") ||
    request.headers.get("X-Forwarded-For")?.split(",")[0]?.trim() ||
    "unknown"
  );
}

function checkRateLimit(ip) {
  const now = Date.now();
  // Opportunistic prune so the Map cannot grow without bound on a busy isolate.
  if (rateLimitByIp.size > 5000) {
    for (const [key, entry] of rateLimitByIp) {
      if (entry.resetAt <= now) rateLimitByIp.delete(key);
    }
  }

  let entry = rateLimitByIp.get(ip);
  if (!entry || entry.resetAt <= now) {
    entry = { count: 0, resetAt: now + RATE_LIMIT_WINDOW_MS };
    rateLimitByIp.set(ip, entry);
  }
  entry.count += 1;
  if (entry.count > RATE_LIMIT_MAX) {
    const retryAfterSec = Math.max(1, Math.ceil((entry.resetAt - now) / 1000));
    return { ok: false, retryAfterSec };
  }
  return { ok: true };
}

function normalizeString(value, maxLen) {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  if (!trimmed) return null;
  return trimmed.slice(0, maxLen);
}

function normalizeLabels(labels) {
  if (labels == null) return undefined;
  if (!Array.isArray(labels)) return undefined;
  const out = [];
  for (const raw of labels.slice(0, MAX_LABELS)) {
    if (typeof raw !== "string") continue;
    const label = raw.trim().slice(0, MAX_LABEL_LEN);
    if (label) out.push(label);
  }
  return out.length ? out : undefined;
}

function normalizePlatform(platform) {
  if (typeof platform !== "string") return "android";
  const p = platform.trim().toLowerCase();
  if (p === "ios") return "ios";
  return "android";
}

function appendMetadataFooter(body, { platform, appVersion, distribution }) {
  const lines = [];
  lines.push(`- Platform: ${platform}`);
  if (appVersion) lines.push(`- App version: ${appVersion}`);
  if (distribution) lines.push(`- Distribution: ${distribution}`);
  if (lines.length === 1 && !appVersion && !distribution) {
    // Always include platform for triage even when clients omit extras.
  }
  return `${body}\n\n---\n**Client metadata (Worker)**\n${lines.join("\n")}\n`;
}

async function handleCreateGithubIssue(request, env) {
  const ip = clientIp(request);
  const rate = checkRateLimit(ip);
  if (!rate.ok) {
    return jsonResponse(
      429,
      { message: "Too many requests. Please try again later." },
      { "Retry-After": String(rate.retryAfterSec) }
    );
  }

  const contentLength = Number(request.headers.get("content-length") || "0");
  if (contentLength > MAX_JSON_BYTES) {
    return jsonResponse(413, { message: "Payload too large." });
  }

  let rawText;
  try {
    rawText = await request.text();
  } catch {
    return jsonResponse(400, { message: "Bad Request: unable to read body." });
  }
  if (rawText.length > MAX_JSON_BYTES) {
    return jsonResponse(413, { message: "Payload too large." });
  }

  let data;
  try {
    data = JSON.parse(rawText);
  } catch {
    return jsonResponse(400, { message: "Bad Request: JSON body required." });
  }
  if (!data || typeof data !== "object" || Array.isArray(data)) {
    return jsonResponse(400, { message: "Bad Request: JSON object required." });
  }

  const title = normalizeString(data.title, MAX_TITLE_LEN);
  const body = normalizeString(data.body, MAX_BODY_LEN);
  if (!title || !body) {
    return jsonResponse(400, {
      message: "Bad Request: Missing or empty title or body.",
    });
  }

  const labels = normalizeLabels(data.labels);
  const platform = normalizePlatform(data.platform);
  const appVersion =
    typeof data.appVersion === "string"
      ? data.appVersion.trim().slice(0, 64)
      : "";
  const distributionRaw =
    typeof data.distribution === "string"
      ? data.distribution.trim().toLowerCase()
      : "";
  const distribution =
    distributionRaw === "play" || distributionRaw === "foss"
      ? distributionRaw
      : "";

  // Turnstile: deferred for v1. When enabled, verify data.turnstileToken here
  // against env.TURNSTILE_SECRET_KEY before calling GitHub.
  // See README.md "Optional: Cloudflare Turnstile".

  const token = env.GITHUB_TOKEN;
  if (!token) {
    console.error("GITHUB_TOKEN secret is not configured");
    return jsonResponse(500, {
      message: "Internal Server Error: feedback service misconfigured.",
    });
  }

  const owner = env.GITHUB_OWNER || "osrswiki";
  const repo = PLATFORM_REPOS[platform] || PLATFORM_REPOS.android;
  const issueBody = appendMetadataFooter(body, {
    platform,
    appVersion,
    distribution,
  });

  const issuePayload = { title, body: issueBody };
  if (labels) issuePayload.labels = labels;

  const ghUrl = `https://api.github.com/repos/${owner}/${repo}/issues`;

  let ghResponse;
  try {
    ghResponse = await fetch(ghUrl, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${token}`,
        Accept: "application/vnd.github+json",
        "Content-Type": "application/json",
        "User-Agent": "osrswiki-feedback-worker",
        "X-GitHub-Api-Version": "2022-11-28",
      },
      body: JSON.stringify(issuePayload),
    });
  } catch (err) {
    console.error("GitHub request failed:", err?.message || String(err));
    return jsonResponse(502, {
      message: "Bad Gateway: failed to reach GitHub.",
    });
  }

  if (!ghResponse.ok) {
    // Do not echo GitHub error bodies (may contain sensitive context).
    console.error(
      `GitHub issue create failed: status=${ghResponse.status} repo=${owner}/${repo}`
    );
    const status = ghResponse.status === 401 || ghResponse.status === 403 ? 502 : 500;
    return jsonResponse(status, {
      message: "Internal Server Error: Failed to create GitHub issue.",
    });
  }

  let issue;
  try {
    issue = await ghResponse.json();
  } catch {
    return jsonResponse(200, { message: "Issue created successfully." });
  }

  const url = typeof issue.html_url === "string" ? issue.html_url : undefined;
  return jsonResponse(200, {
    message: "Issue created successfully.",
    ...(url ? { url } : {}),
  });
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: corsHeaders() });
    }

    // Keep path name for easy Android/iOS client swap (Task 3).
    if (
      request.method === "POST" &&
      (url.pathname === "/createGithubIssue" ||
        url.pathname === "/createGithubIssue/")
    ) {
      return handleCreateGithubIssue(request, env);
    }

    if (request.method === "GET" && url.pathname === "/") {
      return jsonResponse(200, {
        message: "osrswiki-feedback worker",
        endpoints: ["POST /createGithubIssue"],
      });
    }

    return jsonResponse(405, { message: "Method Not Allowed" });
  },
};
