#!/usr/bin/env node
import { execFileSync, spawn } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { analyzeRenderedTables, detectionCriteria } from './audit_logic.mjs';

const API_URL = 'https://oldschool.runescape.wiki/api.php';
const DEFAULT_USER_AGENT = 'OSRSWikiIOSCollapsibleTableGapAudit/2026-07-09 local QA contact: local-codex';
const DEFAULT_CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const VIEWPORT = { width: 375, height: 812, deviceScaleFactor: 3, mobile: true };

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, '../../..');
const storageHelper = path.join(repoRoot, 'scripts/shared/local-artifact-root.sh');

function localArtifactPath(category) {
  return execFileSync(
    storageHelper,
    ['path', 'active', process.env.OSRS_LANE_ID || 'ios-collapsible-table-gap-audit', category],
    { encoding: 'utf8', env: process.env },
  ).trim();
}

function validatedArtifactPath(candidate) {
  return execFileSync(
    storageHelper,
    ['validate-path', path.resolve(candidate)],
    { encoding: 'utf8', env: process.env },
  ).trim();
}

const DEFAULT_EVIDENCE_ROOT = localArtifactPath('audit-output');

const FORCED_CASES = [
  ['trigger', 'The Blood Moon Rises/Quick guide'],
  ['trigger_parent', 'The Blood Moon Rises'],
  ['quest_guides', 'Dragon Slayer II/Quick guide'],
  ['quest_guides', 'Desert Treasure II - The Fallen Empire/Quick guide'],
  ['quest_guides', 'Song of the Elves/Quick guide'],
  ['quest_guides', 'Recipe for Disaster/Quick guide'],
  ['quest_guides', 'While Guthix Sleeps/Quick guide'],
  ['quest_guides', 'Monkey Madness II/Quick guide'],
  ['quest_guides', 'Mourning\'s End Part II/Quick guide'],
  ['boss_guides', 'Zulrah/Strategies'],
  ['boss_guides', 'Vorkath/Strategies'],
  ['boss_guides', 'The Gauntlet/Strategies'],
  ['boss_guides', 'Chambers of Xeric/Strategies'],
  ['boss_guides', 'Theatre of Blood/Strategies'],
  ['boss_guides', 'Tombs of Amascut/Strategies'],
  ['boss_guides', 'Doom of Mokhaiotl'],
  ['minigame_guides', 'Wintertodt'],
  ['minigame_guides', 'Tempoross'],
  ['minigame_guides', 'Guardians of the Rift'],
  ['minigame_guides', 'Giants\' Foundry'],
  ['minigame_guides', 'Barrows'],
  ['minigame_guides', 'Mage Training Arena'],
  ['skill_training_pages', 'Agility training'],
  ['skill_training_pages', 'Construction training'],
  ['skill_training_pages', 'Pay-to-play melee training'],
  ['skill_training_pages', 'Pay-to-play Magic training'],
  ['skill_training_pages', 'Pay-to-play Ranged training'],
  ['skill_training_pages', 'Slayer training'],
  ['skill_training_pages', 'Ironman guide/Crafting'],
  ['money_making_guides', 'Money making guide'],
  ['money_making_guides', 'Money making guide/Catching dark crabs'],
  ['money_making_guides', 'Money making guide/Killing Vorkath'],
  ['money_making_guides', 'Money making guide/Killing Zulrah'],
  ['money_making_guides', 'Money making guide/Pickpocketing elves'],
  ['money_making_guides', 'Money making guide/Crafting dragonstone jewellery'],
  ['calculators_tools', 'Calculator:Combat level'],
  ['calculators_tools', 'Calculator:Agility/Agility arena tickets'],
  ['calculators_tools', 'Calculator:Herblore/Potions'],
  ['calculators_tools', 'Calculator:Crafting/Gem cutting'],
  ['calculators_tools', 'Treasure Trails/Guide/Coordinates'],
  ['league_task_pages', 'Trailblazer Reloaded League/Tasks'],
  ['league_task_pages', 'Trailblazer Reloaded League/Guide'],
  ['league_task_pages', 'Demonic Pacts League/Tasks'],
  ['league_task_pages', 'Raging Echoes League/Tasks'],
  ['table_heavy_pages', 'Experience'],
  ['table_heavy_pages', 'Construction/Level up table'],
  ['table_heavy_pages', 'One-handed slot table'],
  ['table_heavy_pages', 'Free-to-play PvP equipment'],
  ['table_heavy_pages', 'Treasure Trails/Guide/Emote clues'],
  ['infobox_heavy_pages', 'Duke Sucellus'],
  ['infobox_heavy_pages', 'Twisted bow'],
  ['infobox_heavy_pages', 'Dragon scimitar'],
  ['infobox_heavy_pages', 'Abyssal whip'],
  ['infobox_heavy_pages', 'Black demon'],
  ['infobox_heavy_pages', 'Ankou'],
  ['previous_article_aesthetic_edge', 'List of quests'],
  ['previous_article_aesthetic_edge', 'Combat level'],
  ['previous_article_aesthetic_edge', 'Calculator:Combat level'],
  ['previous_article_aesthetic_edge', 'Construction/Level up table'],
  ['previous_article_aesthetic_edge', 'Trailblazer Reloaded League/Tasks'],
];

function parseArgs(argv) {
  const args = {
    target: 10_000,
    oversample: 250,
    evidenceRoot: DEFAULT_EVIDENCE_ROOT,
    seed: 20260709,
    userAgent: DEFAULT_USER_AGENT,
    chrome: DEFAULT_CHROME,
    fetchConcurrency: 4,
    screenshotCount: 16,
    maxHtmlChars: 8_000_000,
    mode: 'full',
  };

  for (let i = 2; i < argv.length; i += 1) {
    const name = argv[i];
    const value = argv[i + 1];
    if (name === '--target') args.target = Number(value), i += 1;
    else if (name === '--oversample') args.oversample = Number(value), i += 1;
    else if (name === '--evidence-root') args.evidenceRoot = value, i += 1;
    else if (name === '--seed') args.seed = Number(value), i += 1;
    else if (name === '--user-agent') args.userAgent = value, i += 1;
    else if (name === '--chrome') args.chrome = value, i += 1;
    else if (name === '--fetch-concurrency') args.fetchConcurrency = Number(value), i += 1;
    else if (name === '--screenshot-count') args.screenshotCount = Number(value), i += 1;
    else if (name === '--max-html-chars') args.maxHtmlChars = Number(value), i += 1;
    else if (name === '--mode') args.mode = value, i += 1;
    else throw new Error(`Unknown argument: ${name}`);
  }
  return args;
}

function slug(value) {
  return String(value)
    .normalize('NFKD')
    .replace(/[^\w\s/.-]/g, '')
    .trim()
    .replace(/[\/\s]+/g, '-')
    .replace(/-+/g, '-')
    .toLowerCase()
    .slice(0, 90) || 'untitled';
}

function titleKey(title) {
  return String(title || '').replace(/_/g, ' ').trim().toLowerCase();
}

function wikiUrl(title) {
  return `https://oldschool.runescape.wiki/w/${encodeURIComponent(String(title).replace(/ /g, '_')).replace(/%2F/g, '/')}`;
}

function stableId(title, stratum) {
  return crypto.createHash('sha256').update(`${stratum}\n${title}`).digest('hex').slice(0, 16);
}

async function ensureDirs(root) {
  for (const dir of [
    root,
    path.join(root, 'raw-api', 'random'),
    path.join(root, 'raw-api', 'parse'),
    path.join(root, 'manifests'),
    path.join(root, 'screenshots'),
    path.join(root, 'dom-excerpts'),
    path.join(root, 'logs'),
  ]) {
    await fs.mkdir(dir, { recursive: true });
  }
}

async function readJsonIfExists(file) {
  try {
    return JSON.parse(await fs.readFile(file, 'utf8'));
  } catch (error) {
    if (error.code === 'ENOENT') return null;
    throw error;
  }
}

async function writeJson(file, value) {
  await fs.mkdir(path.dirname(file), { recursive: true });
  await fs.writeFile(file, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
}

async function apiGet(params, cacheFile, userAgent) {
  const cached = await readJsonIfExists(cacheFile);
  if (cached) return cached;

  const url = `${API_URL}?${new URLSearchParams(params)}`;
  let lastError;
  for (let attempt = 0; attempt < 5; attempt += 1) {
    try {
      const response = await fetch(url, { headers: { 'User-Agent': userAgent } });
      const text = await response.text();
      if (!response.ok) throw new Error(`${response.status} ${response.statusText}: ${text.slice(0, 200)}`);
      const json = JSON.parse(text);
      await writeJson(cacheFile, json);
      return json;
    } catch (error) {
      lastError = error;
      await new Promise((resolve) => setTimeout(resolve, 1000 * (attempt + 1)));
    }
  }
  throw lastError;
}

async function generateManifest(args, root) {
  const manifestFile = path.join(root, 'manifests', 'sample-manifest.json');
  const existing = await readJsonIfExists(manifestFile);
  if (existing && Array.isArray(existing.rows) && existing.rows.length >= args.target) {
    return existing;
  }

  const rows = [];
  const seen = new Set();
  const add = (title, stratum, source = 'forced_edge_case', pageid = null) => {
    const key = titleKey(title);
    if (!key || seen.has(key)) return;
    seen.add(key);
    rows.push({
      sample_id: stableId(title, stratum),
      sequence: rows.length + 1,
      title,
      title_key: key,
      url: wikiUrl(title),
      pageid,
      stratum,
      source,
    });
  };

  for (const [stratum, title] of FORCED_CASES) add(title, stratum);

  let batch = 0;
  const desiredRows = args.target + args.oversample;
  while (rows.length < desiredRows) {
    batch += 1;
    const randomJson = await apiGet({
      action: 'query',
      format: 'json',
      list: 'random',
      rnnamespace: '0',
      rnlimit: '50',
      origin: '*',
      requestid: `ios-collapsible-table-gap-${args.seed}-${batch}`,
    }, path.join(root, 'raw-api', 'random', `random-${String(batch).padStart(4, '0')}.json`), args.userAgent);

    for (const page of randomJson.query?.random || []) {
      add(page.title, 'random_namespace0_fill', 'random_namespace0', page.id);
      if (rows.length >= desiredRows) break;
    }
  }

  const manifest = {
    generated_utc: new Date().toISOString(),
    target_rendered_pages: args.target,
    oversample: args.oversample,
    user_agent: args.userAgent,
    forced_case_count: FORCED_CASES.length,
    total_rows: rows.length,
    rows,
  };
  await writeJson(manifestFile, manifest);
  return manifest;
}

function parseCacheFile(root, row) {
  const idPart = row.pageid ? `pageid-${row.pageid}` : `${slug(row.title)}-${row.sample_id}`;
  return path.join(root, 'raw-api', 'parse', `${idPart}.json`);
}

async function fetchParseForRow(root, row, args) {
  const params = {
    action: 'parse',
    format: 'json',
    formatversion: '2',
    prop: 'text|displaytitle|revid|categories',
    redirects: '1',
    disablelimitreport: '1',
    wrapoutputclass: 'mw-parser-output',
    origin: '*',
  };
  if (row.pageid) params.pageid = String(row.pageid);
  else params.page = row.title;

  const started = Date.now();
  try {
    const json = await apiGet(params, parseCacheFile(root, row), args.userAgent);
    if (json.error) throw new Error(`${json.error.code}: ${json.error.info}`);
    const parse = json.parse;
    if (!parse?.text) throw new Error('parse payload missing text');
    return {
      row,
      ok: true,
      parseTitle: parse.title,
      pageid: parse.pageid,
      revid: parse.revid,
      displaytitle: parse.displaytitle || '',
      categories: parse.categories || [],
      html: parse.text,
      bytes: Buffer.byteLength(parse.text, 'utf8'),
      elapsed_ms: Date.now() - started,
    };
  } catch (error) {
    return {
      row,
      ok: false,
      error: String(error?.message || error),
      elapsed_ms: Date.now() - started,
    };
  }
}

async function mapConcurrent(items, limit, worker, onProgress) {
  const results = new Array(items.length);
  let next = 0;
  let done = 0;

  async function run() {
    for (;;) {
      const index = next;
      next += 1;
      if (index >= items.length) return;
      results[index] = await worker(items[index], index);
      done += 1;
      if (onProgress && (done % 100 === 0 || done === items.length)) onProgress(done, items.length);
    }
  }

  await Promise.all(Array.from({ length: Math.max(1, limit) }, run));
  return results;
}

async function loadAsset(relativePath) {
  return fs.readFile(path.join(repoRoot, 'platforms/ios/osrswiki/Assets', relativePath), 'utf8');
}

async function appAssets() {
  const cssPaths = [
    'styles/themes.css',
    'styles/base.css',
    'styles/fonts.css',
    'styles/layout.css',
    'styles/components.css',
    'styles/wiki-integration.css',
    'styles/navbox_styles.css',
    'web/collapsible_tables.css',
    'web/collapsible_sections.css',
    'web/switch_infobox_styles.css',
    'styles/fixes.css',
  ];
  const jsPaths = [
    'startup.js',
    'js/tablesort.min.js',
    'js/tablesort_init.js',
    'web/article_tools.js',
    'web/collapsible_content.js',
    'web/infobox_switcher_bootstrap.js',
    'web/switch_infobox.js',
    'web/horizontal_scroll_interceptor.js',
    'web/responsive_videos.js',
    'web/clipboard_bridge.js',
  ];

  return {
    css: (await Promise.all(cssPaths.map(loadAsset))).join('\n'),
    js: (await Promise.all(jsPaths.map(loadAsset))).join('\n;\n'),
    cssPaths,
    jsPaths,
  };
}

function stripDuplicatePageHeaders(html) {
  return html.replace(/<h1\s+class="page-header"[^>]*>[\s\S]*?<\/h1>/gi, '');
}

function buildAppHtml(parseResult, assets) {
  const title = parseResult.parseTitle || parseResult.row.title;
  const body = `<h1 class="page-header">${escapeHtml(title)}</h1>${stripDuplicatePageHeaders(parseResult.html)}`;
  return `<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <base href="app-assets://localhost/">
  <title>${escapeHtml(title)}</title>
  <style>${assets.css}</style>
  <script>
    window.OSRS_TABLE_COLLAPSED = true;
    window.RenderTimeline = { log: function() {} };
    window.webkit = window.webkit || { messageHandlers: {} };
  </script>
  <script>
    var RLCONF = {"wgServer":"https://oldschool.runescape.wiki","wgServerName":"oldschool.runescape.wiki","wgScriptPath":"","wgPageName":${JSON.stringify(title)},"wgTitle":${JSON.stringify(title)}};
    var RLSTATE = {};
    var RLPAGEMODULES = [];
  </script>
</head>
<body style="visibility: visible;">
${body}
<script>${assets.js}</script>
</body>
</html>`;
}

function escapeHtml(value) {
  return String(value || '').replace(/[&<>"']/g, (char) => ({
    '&': '&amp;',
    '<': '&lt;',
    '>': '&gt;',
    '"': '&quot;',
    "'": '&#39;',
  }[char]));
}

class CdpClient {
  constructor(url) {
    this.url = url;
    this.id = 0;
    this.pending = new Map();
    this.sessions = new Map();
  }

  async connect() {
    this.socket = new WebSocket(this.url);
    this.socket.addEventListener('message', (event) => this.onMessage(event));
    await new Promise((resolve, reject) => {
      this.socket.addEventListener('open', resolve, { once: true });
      this.socket.addEventListener('error', reject, { once: true });
    });
  }

  onMessage(event) {
    const message = JSON.parse(event.data);
    if (message.id && this.pending.has(message.id)) {
      const { resolve, reject } = this.pending.get(message.id);
      this.pending.delete(message.id);
      if (message.error) reject(new Error(JSON.stringify(message.error)));
      else resolve(message.result);
    }
  }

  send(method, params = {}, sessionId = undefined) {
    const id = ++this.id;
    const payload = { id, method, params };
    if (sessionId) payload.sessionId = sessionId;
    this.socket.send(JSON.stringify(payload));
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      setTimeout(() => {
        if (this.pending.has(id)) {
          this.pending.delete(id);
          reject(new Error(`CDP timeout for ${method}`));
        }
      }, 30_000);
    });
  }

  close() {
    this.socket?.close();
  }
}

async function launchChrome(args, root) {
  await fs.access(args.chrome);
  const userDataDir = path.join(root, 'chrome-profile');
  await fs.rm(userDataDir, { recursive: true, force: true });
  await fs.mkdir(userDataDir, { recursive: true });
  const stderrFile = path.join(root, 'logs', 'chrome-stderr.log');
  const stderrHandle = await fs.open(stderrFile, 'w');
  const chrome = spawn(args.chrome, [
    '--headless=new',
    '--remote-debugging-port=0',
    `--user-data-dir=${userDataDir}`,
    '--no-first-run',
    '--no-default-browser-check',
    '--disable-gpu',
    '--disable-dev-shm-usage',
    `--window-size=${VIEWPORT.width},${VIEWPORT.height}`,
    'about:blank',
  ], { stdio: ['ignore', 'ignore', 'pipe'] });

  chrome.stderr.pipe(stderrHandle.createWriteStream());
  const endpoint = await new Promise((resolve, reject) => {
    let buffer = '';
    const timer = setTimeout(() => reject(new Error('Timed out waiting for Chrome DevTools endpoint')), 20_000);
    chrome.stderr.on('data', (chunk) => {
      buffer += chunk.toString();
      const match = buffer.match(/DevTools listening on (ws:\/\/[^\s]+)/);
      if (match) {
        clearTimeout(timer);
        resolve(match[1]);
      }
    });
    chrome.once('exit', (code) => reject(new Error(`Chrome exited before DevTools endpoint: ${code}`)));
  });

  const cdp = new CdpClient(endpoint);
  await cdp.connect();
  const target = await cdp.send('Target.createTarget', { url: 'about:blank' });
  const attached = await cdp.send('Target.attachToTarget', { targetId: target.targetId, flatten: true });
  const sessionId = attached.sessionId;
  await cdp.send('Page.enable', {}, sessionId);
  await cdp.send('Runtime.enable', {}, sessionId);
  await cdp.send('Emulation.setDeviceMetricsOverride', VIEWPORT, sessionId);

  return {
    cdp,
    sessionId,
    async close() {
      cdp.close();
      chrome.kill('SIGTERM');
      await stderrHandle.close().catch(() => {});
    },
  };
}

async function evaluate(cdp, sessionId, expression, awaitPromise = true) {
  const result = await cdp.send('Runtime.evaluate', {
    expression,
    awaitPromise,
    returnByValue: true,
    timeout: 30_000,
  }, sessionId);
  if (result.exceptionDetails) {
    throw new Error(JSON.stringify(result.exceptionDetails));
  }
  return result.result?.value;
}

async function renderPage(chrome, parseResult, assets, args) {
  const html = buildAppHtml(parseResult, assets);
  if (html.length > args.maxHtmlChars) {
    return {
      ok: false,
      skipped: true,
      error: `html_too_large:${html.length}`,
      htmlLength: html.length,
    };
  }

  const { cdp, sessionId } = chrome;
  await cdp.send('Page.navigate', { url: 'about:blank' }, sessionId);
  await new Promise((resolve) => setTimeout(resolve, 5));
  await evaluate(cdp, sessionId, `document.open(); document.write(${JSON.stringify(html)}); document.close(); true;`);
  await evaluate(cdp, sessionId, `new Promise((resolve) => {
    const deadline = Date.now() + 2500;
    function check() {
      if (document.body && document.body.classList.contains('js-transforms-complete')) resolve(true);
      else if (Date.now() > deadline) resolve(false);
      else setTimeout(check, 25);
    }
    check();
  })`);

  const rendered = await evaluate(cdp, sessionId, tableExtractionExpression());
  return {
    ok: true,
    htmlLength: html.length,
    ...rendered,
  };
}

function tableExtractionExpression() {
  return `(() => {
    function text(el) {
      return (el ? el.textContent || '' : '').replace(/\\s+/g, ' ').trim();
    }
    function nearestHeading(el) {
      let cursor = el;
      while (cursor && cursor !== document.body) {
        let prev = cursor.previousElementSibling;
        while (prev) {
          const heading = prev.matches?.('h1,h2,h3,h4,h5,h6') ? prev : prev.querySelector?.('.mw-heading h1,.mw-heading h2,.mw-heading h3,.mw-heading h4,.mw-heading h5,.mw-heading h6,h1,h2,h3,h4,h5,h6');
          if (text(heading)) return text(heading);
          prev = prev.previousElementSibling;
        }
        cursor = cursor.parentElement;
      }
      return '';
    }
    function cssPath(el) {
      const parts = [];
      let node = el;
      while (node && node.nodeType === 1 && node !== document.body) {
        let part = node.tagName.toLowerCase();
        if (node.id) {
          part += '#' + CSS.escape(node.id);
          parts.unshift(part);
          break;
        }
        const cls = Array.from(node.classList || []).slice(0, 3).map((c) => '.' + CSS.escape(c)).join('');
        part += cls;
        const parent = node.parentElement;
        if (parent) {
          const siblings = Array.from(parent.children).filter((child) => child.tagName === node.tagName);
          if (siblings.length > 1) part += ':nth-of-type(' + (siblings.indexOf(node) + 1) + ')';
        }
        parts.unshift(part);
        node = parent;
      }
      return parts.join(' > ');
    }
    const firstWikitables = Array.from(document.querySelectorAll('table.wikitable'));
    const tables = Array.from(document.querySelectorAll('table')).map((table, tableIndex) => {
      const rect = table.getBoundingClientRect();
      const rows = Array.from(table.querySelectorAll(':scope > tbody > tr, :scope > thead > tr, :scope > tfoot > tr, :scope > tr'));
      const maxCols = rows.reduce((max, row) => Math.max(max, row.children.length), 0);
      const container = table.closest('.collapsible-container');
      const caption = table.querySelector(':scope > caption');
      const outer = table.outerHTML || '';
      return {
        tableIndex,
        selector: table.tagName.toLowerCase() + (table.className ? '.' + String(table.className).trim().split(/\\s+/).slice(0, 8).join('.') : ''),
        domPath: cssPath(table),
        classes: Array.from(table.classList || []),
        caption: text(caption),
        hasOwnCaption: !!caption,
        nearestHeading: nearestHeading(table),
        rows: rows.length,
        columns: maxCols,
        width: Math.round(rect.width),
        height: Math.round(rect.height),
        top: Math.round(rect.top + window.scrollY),
        left: Math.round(rect.left),
        scrollWidth: table.scrollWidth,
        scrollHeight: table.scrollHeight,
        textSample: text(table).slice(0, 360),
        insideCollapsible: !!container,
        collapsibleState: container ? (container.classList.contains('collapsed') ? 'collapsed' : 'expanded') : 'none',
        collapsibleClasses: container ? Array.from(container.classList || []) : [],
        firstWikitableIndex: table.classList.contains('wikitable') ? firstWikitables.indexOf(table) : null,
        hasAncestorTable: !!table.parentElement?.closest('table'),
        outerHTMLSnippet: outer.slice(0, 4000),
      };
    });
    return {
      renderedTitle: text(document.querySelector('.page-header, #firstHeading, h1')),
      bodyTextLength: text(document.body).length,
      bodyScrollHeight: document.scrollingElement ? document.scrollingElement.scrollHeight : document.body.scrollHeight,
      transformsComplete: document.body.classList.contains('js-transforms-complete'),
      tables,
    };
  })()`;
}

async function screenshotFinding(chrome, parseResult, assets, finding, outputFile) {
  const rendered = await renderPage(chrome, parseResult, assets, { maxHtmlChars: 12_000_000 });
  if (!rendered.ok) return false;
  await evaluate(chrome.cdp, chrome.sessionId, `(() => {
    const table = document.querySelectorAll('table')[${finding.tableIndex}];
    if (!table) return false;
    table.style.outline = '4px solid #d22';
    table.style.outlineOffset = '3px';
    table.scrollIntoView({ block: 'center', inline: 'nearest' });
    return true;
  })()`);
  await new Promise((resolve) => setTimeout(resolve, 120));
  const result = await chrome.cdp.send('Page.captureScreenshot', {
    format: 'png',
    fromSurface: true,
    captureBeyondViewport: false,
  }, chrome.sessionId);
  await fs.writeFile(outputFile, Buffer.from(result.data, 'base64'));
  return true;
}

function rankFinding(finding) {
  const severityRank = { P1: 0, P2: 1, P3: 2 };
  return (severityRank[finding.severity] ?? 9) * 1_000_000 -
    (finding.rowCount * 1000 + finding.dimensions.height);
}

function attachFindingIds(findings) {
  return findings.map((finding, index) => ({
    ...finding,
    findingId: `IOSCTG-${String(index + 1).padStart(4, '0')}`,
  }));
}

async function main() {
  const args = parseArgs(process.argv);
  const root = validatedArtifactPath(path.resolve(repoRoot, args.evidenceRoot));
  await ensureDirs(root);
  const started = new Date();

  console.log(`Evidence root: ${root}`);
  console.log(`Generating/loading manifest for target ${args.target} (+${args.oversample} oversample)`);
  const manifest = await generateManifest(args, root);
  console.log(`Manifest rows: ${manifest.rows.length}`);

  console.log(`Fetching parse HTML with concurrency ${args.fetchConcurrency}`);
  const parseResults = await mapConcurrent(
    manifest.rows,
    args.fetchConcurrency,
    (row) => fetchParseForRow(root, row, args),
    (done, total) => console.log(`parse ${done}/${total}`),
  );
  await writeJson(path.join(root, 'parse-results.json'), parseResults.map((result) => ({
    sample_id: result.row.sample_id,
    title: result.row.title,
    stratum: result.row.stratum,
    ok: result.ok,
    parseTitle: result.parseTitle,
    pageid: result.pageid,
    revid: result.revid,
    bytes: result.bytes,
    error: result.error,
    elapsed_ms: result.elapsed_ms,
  })));

  const assets = await appAssets();
  await writeJson(path.join(root, 'asset-manifest.json'), {
    cssPaths: assets.cssPaths,
    jsPaths: assets.jsPaths,
    cssBytes: Buffer.byteLength(assets.css, 'utf8'),
    jsBytes: Buffer.byteLength(assets.js, 'utf8'),
    note: 'Asset order mirrors osrsPageHtmlBuilder includeAssetLinks=true for current iOS article path.',
  });

  let chrome;
  const scanRows = [];
  let renderedCount = 0;
  let parseErrorCount = 0;
  let renderErrorCount = 0;
  let findings = [];
  const parseBySample = new Map(parseResults.map((result) => [result.row.sample_id, result]));

  try {
    console.log(`Launching Chrome: ${args.chrome}`);
    chrome = await launchChrome(args, root);
    for (let i = 0; i < parseResults.length; i += 1) {
      const parseResult = parseResults[i];
      if (!parseResult.ok) {
        parseErrorCount += 1;
        scanRows.push({
          sample_id: parseResult.row.sample_id,
          sequence: parseResult.row.sequence,
          title: parseResult.row.title,
          stratum: parseResult.row.stratum,
          ok: false,
          stage: 'parse',
          error: parseResult.error,
        });
        continue;
      }
      try {
        const rendered = await renderPage(chrome, parseResult, assets, args);
        if (!rendered.ok) {
          renderErrorCount += 1;
          scanRows.push({
            sample_id: parseResult.row.sample_id,
            sequence: parseResult.row.sequence,
            title: parseResult.parseTitle || parseResult.row.title,
            stratum: parseResult.row.stratum,
            ok: false,
            stage: 'render',
            error: rendered.error,
            htmlLength: rendered.htmlLength,
          });
          continue;
        }

        renderedCount += 1;
        const page = {
          sample_id: parseResult.row.sample_id,
          title: parseResult.parseTitle || parseResult.row.title,
          url: wikiUrl(parseResult.parseTitle || parseResult.row.title),
          row: parseResult.row,
          tables: rendered.tables,
        };
        const pageFindings = analyzeRenderedTables(page);
        findings.push(...pageFindings.map((finding) => ({
          ...finding,
          sample_id: parseResult.row.sample_id,
          stratum: parseResult.row.stratum,
          pageid: parseResult.pageid,
          revid: parseResult.revid,
        })));

        const compactTables = rendered.tables.map((table) => ({
          tableIndex: table.tableIndex,
          selector: table.selector,
          domPath: table.domPath,
          classes: table.classes,
          caption: table.caption,
          nearestHeading: table.nearestHeading,
          rows: table.rows,
          columns: table.columns,
          width: table.width,
          height: table.height,
          top: table.top,
          scrollWidth: table.scrollWidth,
          scrollHeight: table.scrollHeight,
          textSample: table.textSample,
          insideCollapsible: table.insideCollapsible,
          collapsibleState: table.collapsibleState,
          collapsibleClasses: table.collapsibleClasses,
          firstWikitableIndex: table.firstWikitableIndex,
          hasAncestorTable: table.hasAncestorTable,
          hasOwnCaption: table.hasOwnCaption,
          outerHTMLSnippet: table.outerHTMLSnippet,
        }));

        const scanRow = {
          sample_id: parseResult.row.sample_id,
          sequence: parseResult.row.sequence,
          title: page.title,
          url: page.url,
          stratum: parseResult.row.stratum,
          ok: true,
          renderedTitle: rendered.renderedTitle,
          pageid: parseResult.pageid,
          revid: parseResult.revid,
          htmlBytes: parseResult.bytes,
          renderedHtmlLength: rendered.htmlLength,
          bodyTextLength: rendered.bodyTextLength,
          bodyScrollHeight: rendered.bodyScrollHeight,
          transformsComplete: rendered.transformsComplete,
          tableCount: rendered.tables.length,
          unwrappedTableCount: rendered.tables.filter((table) => !table.insideCollapsible).length,
          candidateFindingCount: pageFindings.length,
        };
        if (pageFindings.length > 0) {
          scanRow.tables = compactTables;
        }
        scanRows.push(scanRow);
      } catch (error) {
        renderErrorCount += 1;
        scanRows.push({
          sample_id: parseResult.row.sample_id,
          sequence: parseResult.row.sequence,
          title: parseResult.parseTitle || parseResult.row.title,
          stratum: parseResult.row.stratum,
          ok: false,
          stage: 'render',
          error: String(error?.message || error),
        });
      }

      if (renderedCount % 100 === 0 && renderedCount > 0) {
        console.log(`rendered ${renderedCount}/${args.target} distinct pages; findings so far ${findings.length}`);
      }
      if (renderedCount >= args.target && args.mode === 'target-only') break;
    }

    findings = attachFindingIds(findings.sort((a, b) => rankFinding(a) - rankFinding(b)));

    for (const finding of findings.slice(0, Math.max(args.screenshotCount, 0))) {
      const parseResult = parseBySample.get(finding.sample_id);
      if (!parseResult?.ok) continue;
      const file = path.join(root, 'screenshots', `${finding.findingId}-${slug(finding.title)}.png`);
      try {
        await screenshotFinding(chrome, parseResult, assets, finding, file);
        finding.screenshot = path.relative(root, file);
      } catch (error) {
        finding.screenshot_error = String(error?.message || error);
      }
      const scanRow = scanRows.find((row) => row.sample_id === finding.sample_id);
      const table = scanRow?.tables?.find((candidate) => candidate.tableIndex === finding.tableIndex);
      if (table?.outerHTMLSnippet) {
        const domFile = path.join(root, 'dom-excerpts', `${finding.findingId}-${slug(finding.title)}.html`);
        await fs.writeFile(domFile, `${table.outerHTMLSnippet}\n`, 'utf8');
        finding.domExcerpt = path.relative(root, domFile);
      }
    }
  } finally {
    await chrome?.close();
  }

  await writeJson(path.join(root, 'raw-scan-results.json'), scanRows);
  await writeJson(path.join(root, 'raw-findings.json'), findings);

  const countsByStratum = {};
  const countsBySeverity = {};
  const countsByRationale = {};
  for (const row of scanRows) countsByStratum[row.stratum] = (countsByStratum[row.stratum] || 0) + 1;
  for (const finding of findings) {
    countsBySeverity[finding.severity] = (countsBySeverity[finding.severity] || 0) + 1;
    countsByRationale[finding.expectedCollapseRationale] = (countsByRationale[finding.expectedCollapseRationale] || 0) + 1;
  }

  const summary = {
    status: renderedCount >= args.target ? 'IOS-COLLAPSIBLE-TABLE-GAP-AUDIT-REPORT-READY' : 'IOS-COLLAPSIBLE-TABLE-GAP-AUDIT-BLOCKED',
    started_utc: started.toISOString(),
    finished_utc: new Date().toISOString(),
    target_rendered_pages: args.target,
    manifest_rows: manifest.rows.length,
    sample_count_total: scanRows.length,
    sample_count_distinct_rendered: renderedCount,
    parse_error_count: parseErrorCount,
    render_error_count: renderErrorCount,
    finding_count: findings.length,
    counts_by_stratum: countsByStratum,
    counts_by_severity: countsBySeverity,
    counts_by_rationale: countsByRationale,
    detection_criteria: detectionCriteria,
    top_findings: findings.slice(0, 25),
    environment: {
      viewport: VIEWPORT,
      chrome: args.chrome,
      node: process.version,
      repoRoot,
    },
  };
  await writeJson(path.join(root, 'summary.json'), summary);
  console.log(JSON.stringify({
    status: summary.status,
    sample_count_distinct_rendered: renderedCount,
    finding_count: findings.length,
    top_findings: findings.slice(0, 5).map((finding) => ({
      id: finding.findingId,
      title: finding.title,
      severity: finding.severity,
      rationale: finding.expectedCollapseRationale,
    })),
  }, null, 2));
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
