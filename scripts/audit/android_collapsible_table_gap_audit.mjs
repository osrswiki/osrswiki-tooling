#!/usr/bin/env node

import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs/promises';
import fssync from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

import {
  classifyTableGap,
  detectionCriteriaSummary,
  normalizeClassSignature,
} from './android_collapsible_table_gap_detector.mjs';

const scriptPath = fileURLToPath(import.meta.url);
const repoRoot = path.resolve(path.dirname(scriptPath), '../..');
const androidRequire = createRequire(path.join(repoRoot, 'platforms/android/package.json'));
const { chromium } = androidRequire('@playwright/test');

const WIKI_BASE = 'https://oldschool.runescape.wiki';
const API_URL = `${WIKI_BASE}/api.php`;
const storageHelper = path.join(repoRoot, 'scripts/shared/local-artifact-root.sh');
const DEFAULT_EVIDENCE_ROOT = execFileSync(
  storageHelper,
  [
    'path',
    'active',
    process.env.OSRS_LANE_ID || 'android-collapsible-table-gap-audit',
    'audit-output',
  ],
  { encoding: 'utf8', env: process.env },
).trim();
const DEFAULT_RANDOM_TARGET = 10000;
const DEFAULT_SEED = 20260709;
const DEFAULT_CONCURRENCY = 4;
const VIEWPORT = { width: 390, height: 844 };
const USER_AGENT = 'OSRSWikiAndroidCollapsibleTableGapAudit/2026-07-09 (local QA; contact: app developer)';

const androidAssetRoot = path.join(repoRoot, 'platforms/android/app/src/main/assets');

const styleSheetAssets = [
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
  'styles/android-article-aesthetics.css',
];

const mediawikiArtifacts = ['startup.js'];
const jsAssetPaths = [
  'js/tablesort.min.js',
  'js/tablesort_init.js',
  'web/collapsible_content.js',
  'web/infobox_switcher_bootstrap.js',
  'web/switch_infobox.js',
  'web/horizontal_scroll_interceptor.js',
  'web/responsive_videos.js',
  'web/clipboard_bridge.js',
];

const forcedPages = [
  { title: 'The Blood Moon Rises/Quick guide', category: 'trigger', rationale: 'Observed quick-guide Details/questdetails table gap.' },
  { title: 'The Blood Moon Rises', category: 'trigger-related', rationale: 'Observed news card destination and full quest page counterpart.' },
  { title: 'Dragon Slayer II/Quick guide', category: 'quest-guide', rationale: 'Quest quick guide with Details table.' },
  { title: 'Desert Treasure II - The Fallen Empire/Quick guide', category: 'quest-guide', rationale: 'Grandmaster quest quick guide.' },
  { title: 'Monkey Madness II/Quick guide', category: 'quest-guide', rationale: 'Quest quick guide forced edge case.' },
  { title: 'Sins of the Father/Quick guide', category: 'quest-guide', rationale: 'Quest quick guide forced edge case.' },
  { title: 'While Guthix Sleeps/Quick guide', category: 'quest-guide', rationale: 'Quest quick guide forced edge case.' },
  { title: 'Zulrah', category: 'boss-guide', rationale: 'Boss article with infoboxes and strategy tables.' },
  { title: 'Vorkath', category: 'boss-guide', rationale: 'Boss article with table-heavy mechanics.' },
  { title: 'Chambers of Xeric', category: 'boss-guide', rationale: 'Raid article and previous article-aesthetic edge case.' },
  { title: 'Theatre of Blood', category: 'boss-guide', rationale: 'Raid article and table-heavy guide.' },
  { title: 'Tombs of Amascut', category: 'boss-guide', rationale: 'Raid article and table-heavy guide.' },
  { title: 'Doom of Mokhaiotl', category: 'boss-guide', rationale: 'Recent boss/infobox edge case.' },
  { title: 'Barrows', category: 'minigame-guide', rationale: 'Minigame/boss hybrid with table-heavy rewards.' },
  { title: 'Tempoross', category: 'minigame-guide', rationale: 'Minigame article.' },
  { title: 'Wintertodt', category: 'minigame-guide', rationale: 'Minigame article.' },
  { title: 'Guardians of the Rift', category: 'minigame-guide', rationale: 'Minigame article.' },
  { title: 'Pest Control', category: 'minigame-guide', rationale: 'Minigame article.' },
  { title: 'Pay-to-play Ranged training', category: 'skill-training', rationale: 'Training page from existing collapse contract.' },
  { title: 'Free-to-play Ranged training', category: 'skill-training', rationale: 'Training page forced edge case.' },
  { title: 'Agility training', category: 'skill-training', rationale: 'Training page forced edge case.' },
  { title: 'Cooking', category: 'skill-training', rationale: 'Skill page and previous article-aesthetic edge case.' },
  { title: 'Prayer', category: 'skill-training', rationale: 'Skill page and previous article-aesthetic edge case.' },
  { title: 'Construction', category: 'skill-training', rationale: 'Skill page and previous article-aesthetic edge case.' },
  { title: 'Money making guide/Catching dark crabs', category: 'money-making-guide', rationale: 'Existing Android collapse priority fixture.' },
  { title: 'Money making guide/Killing Zulrah', category: 'money-making-guide', rationale: 'Money making guide forced edge case.' },
  { title: 'Money making guide/Charging air orbs', category: 'money-making-guide', rationale: 'Money making guide forced edge case.' },
  { title: 'Calculator:Combat level', category: 'calculator-tool', rationale: 'Calculator/tool page forced edge case.' },
  { title: 'Calculator:Construction/Planks', category: 'calculator-tool', rationale: 'Calculator/tool page forced edge case.' },
  { title: 'Calculator:Herblore/Potions', category: 'calculator-tool', rationale: 'Calculator/tool page forced edge case.' },
  { title: 'Trailblazer Reloaded League/Tasks', category: 'league-task-page', rationale: 'Existing Android giant task table fixture.' },
  { title: 'Demonic Pacts League/Tasks', category: 'league-task-page', rationale: 'League task page forced edge case.' },
  { title: 'Leagues V', category: 'league-task-page', rationale: 'League overview page forced edge case.' },
  { title: 'Treasure Trails/Guide/Cryptics', category: 'table-heavy', rationale: 'Table-heavy guide.' },
  { title: 'Slayer task', category: 'table-heavy', rationale: 'Table-heavy reference page.' },
  { title: 'Achievement Diary', category: 'table-heavy', rationale: 'Table-heavy reference page.' },
  { title: 'Clue scroll (master)', category: 'table-heavy', rationale: 'Table-heavy item/reference page.' },
  { title: 'Abyssal whip', category: 'infobox-heavy', rationale: 'Previous article-aesthetic edge case.' },
  { title: 'Dragon scimitar', category: 'infobox-heavy', rationale: 'Previous article-aesthetic edge case.' },
  { title: '3rd age mage hat', category: 'infobox-heavy', rationale: 'Previous article-aesthetic edge case.' },
];

function parseArgs(argv) {
  const options = {
    outputRoot: DEFAULT_EVIDENCE_ROOT,
    randomTarget: DEFAULT_RANDOM_TARGET,
    seed: DEFAULT_SEED,
    concurrency: DEFAULT_CONCURRENCY,
    refreshSample: false,
    forceRescan: false,
    maxSamples: null,
    representativeScreenshots: 20,
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--output-root') options.outputRoot = argv[++i];
    else if (arg === '--random-target') options.randomTarget = Number(argv[++i]);
    else if (arg === '--seed') options.seed = Number(argv[++i]);
    else if (arg === '--concurrency') options.concurrency = Number(argv[++i]);
    else if (arg === '--refresh-sample') options.refreshSample = true;
    else if (arg === '--force-rescan') options.forceRescan = true;
    else if (arg === '--max-samples') options.maxSamples = Number(argv[++i]);
    else if (arg === '--representative-screenshots') options.representativeScreenshots = Number(argv[++i]);
    else if (arg === '--help' || arg === '-h') {
      console.log(`Usage: node scripts/audit/android_collapsible_table_gap_audit.mjs [options]

Options:
  --output-root DIR              Evidence root. Default: ${DEFAULT_EVIDENCE_ROOT}
  --random-target N              Distinct random rendered pages target. Default: ${DEFAULT_RANDOM_TARGET}
  --seed N                       Deterministic sample seed metadata. Default: ${DEFAULT_SEED}
  --concurrency N                Render/fetch workers. Default: ${DEFAULT_CONCURRENCY}
  --refresh-sample               Rebuild sample manifest even if it exists.
  --force-rescan                 Ignore existing scan result JSONL files.
  --max-samples N                Debug limit; scans first N manifest samples.
  --representative-screenshots N Capture trigger plus top N finding screenshots. Default: 20`);
      process.exit(0);
    } else {
      throw new Error(`Unknown option: ${arg}`);
    }
  }
  return options;
}

function sha(value) {
  return createHash('sha256').update(String(value)).digest('hex');
}

function slugForTitle(title) {
  return title
    .toLowerCase()
    .replace(/&/g, 'and')
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 80) || sha(title).slice(0, 12);
}

function wikiPath(title) {
  return title
    .replace(/ /g, '_')
    .split('/')
    .map((part) => encodeURIComponent(part))
    .join('/');
}

function gzipReadJson(filePath) {
  const raw = fssync.readFileSync(filePath);
  return JSON.parse(zlib.gunzipSync(raw).toString('utf8'));
}

function gzipWrite(filePath, text) {
  fssync.mkdirSync(path.dirname(filePath), { recursive: true });
  fssync.writeFileSync(filePath, zlib.gzipSync(Buffer.from(text, 'utf8')));
}

async function fetchJson(url) {
  let lastError;
  for (let attempt = 0; attempt < 5; attempt += 1) {
    try {
      const response = await fetch(url, { headers: { 'User-Agent': USER_AGENT } });
      if (!response.ok) {
        throw new Error(`HTTP ${response.status} ${response.statusText}`);
      }
      return await response.json();
    } catch (error) {
      lastError = error;
      await new Promise((resolve) => setTimeout(resolve, 900 * (attempt + 1)));
    }
  }
  throw lastError;
}

async function apiGetCached(cachePath, params) {
  if (fssync.existsSync(cachePath)) {
    return gzipReadJson(cachePath);
  }
  const url = `${API_URL}?${new URLSearchParams(params).toString()}`;
  const payload = await fetchJson(url);
  gzipWrite(cachePath, JSON.stringify(payload));
  return payload;
}

async function randomPageBatch(evidenceRoot, batchIndex, limit) {
  const cachePath = path.join(evidenceRoot, 'raw/api-random-pages', `batch-${String(batchIndex).padStart(4, '0')}.json.gz`);
  return apiGetCached(cachePath, {
    action: 'query',
    format: 'json',
    list: 'random',
    rnnamespace: '0',
    rnlimit: String(limit),
  });
}

async function buildOrLoadManifest(options, evidenceRoot) {
  const manifestPath = path.join(evidenceRoot, 'sample-manifest.json');
  if (!options.refreshSample && fssync.existsSync(manifestPath)) {
    return JSON.parse(await fs.readFile(manifestPath, 'utf8'));
  }

  await fs.mkdir(evidenceRoot, { recursive: true });
  const samples = [];
  const seenRandomPageIds = new Set();
  const seenForcedTitles = new Set();

  forcedPages.forEach((page, index) => {
    const normalizedTitle = page.title.replace(/_/g, ' ');
    if (seenForcedTitles.has(normalizedTitle.toLowerCase())) return;
    seenForcedTitles.add(normalizedTitle.toLowerCase());
    samples.push({
      sample_id: `FORCED-${String(index + 1).padStart(3, '0')}`,
      kind: 'forced',
      title: normalizedTitle,
      forced_category: page.category,
      forced_rationale: page.rationale,
      source_url: `${WIKI_BASE}/w/${wikiPath(normalizedTitle)}`,
    });
  });

  const desiredRandom = options.randomTarget + 800;
  let batch = 0;
  while (seenRandomPageIds.size < desiredRandom) {
    const payload = await randomPageBatch(evidenceRoot, batch, 500);
    for (const page of payload.query?.random || []) {
      const pageId = Number(page.id);
      if (!pageId || seenRandomPageIds.has(pageId)) continue;
      seenRandomPageIds.add(pageId);
      samples.push({
        sample_id: `RND-${String(seenRandomPageIds.size).padStart(5, '0')}`,
        kind: 'random',
        pageid: pageId,
        title: page.title,
        source_url: `${WIKI_BASE}/w/${wikiPath(page.title)}`,
      });
    }
    batch += 1;
  }

  const manifest = {
    generated_at: new Date().toISOString(),
    seed: options.seed,
    user_agent: USER_AGENT,
    random_target_distinct_rendered: options.randomTarget,
    forced_count: samples.filter((sample) => sample.kind === 'forced').length,
    random_sample_manifest_count: samples.filter((sample) => sample.kind === 'random').length,
    total_manifest_count: samples.length,
    forced_categories: [...new Set(forcedPages.map((page) => page.category))].sort(),
    criteria_summary: detectionCriteriaSummary(),
    samples,
  };
  await fs.writeFile(manifestPath, JSON.stringify(manifest, null, 2) + '\n');
  return manifest;
}

async function parsePage(sample, evidenceRoot) {
  const key = sample.pageid
    ? `pageid-${sample.pageid}`
    : `title-${sha(sample.title).slice(0, 16)}`;
  const jsonPath = path.join(evidenceRoot, 'raw/parse-json', `${key}.json.gz`);
  const params = {
    action: 'parse',
    format: 'json',
    prop: 'text|displaytitle|categories|revid',
    redirects: '1',
    disablelimitreport: '1',
  };
  if (sample.pageid) {
    params.pageid = String(sample.pageid);
  } else {
    params.page = sample.title;
  }
  const payload = await apiGetCached(jsonPath, params);
  if (payload.error) {
    return { payload, jsonPath, htmlPath: null, error: payload.error.info || payload.error.code || 'parse error' };
  }
  const html = payload.parse?.text?.['*'] || '';
  const title = payload.parse?.title || sample.title;
  const pageId = payload.parse?.pageid || sample.pageid || null;
  const htmlPath = path.join(evidenceRoot, 'raw/parse-html', `${pageId || sha(title).slice(0, 16)}-${slugForTitle(title)}.html.gz`);
  if (!fssync.existsSync(htmlPath)) {
    gzipWrite(htmlPath, html);
  }
  return { payload, jsonPath, htmlPath, error: null };
}

function escapeHtml(value) {
  return String(value)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

function escapeScriptString(value) {
  return JSON.stringify(String(value)).replace(/</g, '\\u003c');
}

function preprocessHtml(html) {
  return html
    .replace(/<tr\b([^>]*\bclass="[^"]*(?:advanced-data|leagues-global-flag|infobox-padding)[^"]*"[^>]*)>[\s\S]*?<\/tr>/gi, '')
    .replace(/\b(src|href)=["']\/(?!\/)([^"']+)["']/gi, (_match, attr, url) => `${attr}="${WIKI_BASE}/${url}"`)
    .replace(/\bsrcset=["']\/(?!\/)([^"']+)["']/gi, (_match, url) => `srcset="${WIKI_BASE}/${url}"`);
}

function buildAppHtml(title, bodyContent) {
  const cleanTitle = String(title || 'OSRS Wiki').replace(/<[^>]+>/g, '').trim() || 'OSRS Wiki';
  const body = preprocessHtml(bodyContent).replace(/<h1\s+class="page-header"[^>]*>[\s\S]*?<\/h1>/gi, '');
  const cssLinks = styleSheetAssets
    .map((assetPath) => `<link rel="stylesheet" href="https://appassets.androidplatform.net/assets/${assetPath}">`)
    .join('\n');
  const mediawikiScripts = mediawikiArtifacts
    .map((assetPath) => `<script src="https://appassets.androidplatform.net/assets/${assetPath}"></script>`)
    .join('\n');
  const jsScripts = jsAssetPaths
    .map((assetPath) => `<script src="https://appassets.androidplatform.net/assets/${assetPath}"></script>`)
    .join('\n');
  const safeTitle = escapeScriptString(cleanTitle);
  const safePageName = escapeScriptString(cleanTitle.replaceAll(' ', '_'));
  return `<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <base href="https://appassets.androidplatform.net/">
  <title>${escapeHtml(cleanTitle)}</title>
  <link rel="preload" href="https://appassets.androidplatform.net/res/font/runescape_plain.ttf" as="font" type="font/ttf" crossorigin="anonymous">
  ${cssLinks}
  <script>window.OSRS_TABLE_COLLAPSED = true;</script>
  <script>
    var RLCONF = {"wgBreakFrames": false, "wgCanonicalNamespace": "", "wgNamespaceNumber": 0, "wgPageName": ${safePageName}, "wgTitle": ${safeTitle}, "wgArticleId": 1, "wgIsArticle": true, "wgAction": "view", "wgServer": "${WIKI_BASE}", "wgServerName": "oldschool.runescape.wiki", "wgScriptPath": "", "wgScript": "/load.php"};
    var RLSTATE = {"site.styles": "ready", "user.styles": "ready", "user": "ready", "user.options": "loading", "jquery.tablesorter.styles": "ready"};
    var RLPAGEMODULES = ["site", "mediawiki.page.ready"];
  </script>
</head>
<body style="visibility: hidden;">
  <h1 class="page-header">${escapeHtml(cleanTitle)}</h1>
  ${body}
  ${mediawikiScripts}
  ${jsScripts}
</body>
</html>`;
}

async function installAssetRoutes(context) {
  const transparentPng = Buffer.from(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=',
    'base64',
  );
  await context.route('https://appassets.androidplatform.net/assets/**', async (route) => {
    const requestUrl = new URL(route.request().url());
    const relative = decodeURIComponent(requestUrl.pathname.replace(/^\/assets\//, ''));
    const localPath = path.join(androidAssetRoot, relative);
    try {
      await route.fulfill({ status: 200, body: await fs.readFile(localPath) });
    } catch {
      await route.fulfill({ status: 404, body: `missing asset ${relative}` });
    }
  });
  await context.route('https://appassets.androidplatform.net/res/font/runescape_plain.ttf', async (route) => {
    const fontPath = path.join(repoRoot, 'platforms/android/app/src/main/res/font/runescape_plain.ttf');
    try {
      await route.fulfill({ status: 200, body: await fs.readFile(fontPath), contentType: 'font/ttf' });
    } catch {
      await route.fulfill({ status: 404, body: 'missing font' });
    }
  });
  await context.route('**/*', async (route) => {
    const request = route.request();
    const resourceType = request.resourceType();
    if (request.url().startsWith('https://appassets.androidplatform.net/')) {
      await route.fallback();
      return;
    }
    if (resourceType === 'image') {
      await route.fulfill({ status: 200, body: transparentPng, contentType: 'image/png' });
      return;
    }
    if (['media', 'font'].includes(resourceType)) {
      await route.abort();
      return;
    }
    await route.abort();
  });
}

async function renderAndCollect(page, sample, parseResult) {
  const parse = parseResult.payload.parse;
  const title = parse.title || sample.title;
  const html = zlib.gunzipSync(fssync.readFileSync(parseResult.htmlPath)).toString('utf8');
  const appHtml = buildAppHtml(title, html);
  await page.setContent(appHtml, { waitUntil: 'domcontentloaded', timeout: 90000 });
  await page.waitForFunction(() => document.body.classList.contains('js-transforms-complete'), null, { timeout: 90000 });
  await page.evaluate(() => {
    document.body.style.visibility = 'visible';
  });

  return page.evaluate((sampleInput) => {
    const normalizeText = (text) => String(text || '').replace(/\s+/g, ' ').trim();
    const cssPath = (el) => {
      if (!el) return '';
      const parts = [];
      let node = el;
      while (node && node.nodeType === Node.ELEMENT_NODE && node !== document.body) {
        const tag = node.tagName.toLowerCase();
        const id = node.id ? `#${CSS.escape(node.id)}` : '';
        const classes = String(node.className || '')
          .split(/\s+/)
          .filter(Boolean)
          .slice(0, 3)
          .map((item) => `.${CSS.escape(item)}`)
          .join('');
        let nth = '';
        if (!id && node.parentElement) {
          const sameTag = Array.from(node.parentElement.children).filter((child) => child.tagName === node.tagName);
          if (sameTag.length > 1) {
            nth = `:nth-of-type(${sameTag.indexOf(node) + 1})`;
          }
        }
        parts.unshift(`${tag}${id}${classes}${nth}`);
        node = node.parentElement;
      }
      return `body > ${parts.join(' > ')}`;
    };
    const findHeading = (element) => {
      let cursor = element;
      while (cursor && cursor !== document.body) {
        let previous = cursor.previousElementSibling;
        while (previous) {
          const heading = previous.matches?.('h1,h2,h3,h4,h5,h6')
            ? previous
            : previous.querySelector?.('.mw-heading h1, .mw-heading h2, .mw-heading h3, .mw-heading h4, .mw-heading h5, .mw-heading h6, h1, h2, h3, h4, h5, h6');
          const headingText = normalizeText(heading?.textContent);
          if (headingText) return headingText;
          previous = previous.previousElementSibling;
        }
        cursor = cursor.parentElement;
      }
      return '';
    };
    const visible = (element) => {
      const rect = element.getBoundingClientRect();
      const style = getComputedStyle(element);
      return rect.width > 0 && rect.height > 0 && style.display !== 'none' && style.visibility !== 'hidden';
    };
    const excludedAncestorFor = (table) => {
      const ancestor = table.closest('.messagebox, .ambox, .mbox, .notebox, .navbox, .navbox-subgroup, .infobox, .gallery, .toc, .mw-editsection, .js-tooltip-wrapper, .hidden, .metadata');
      return ancestor ? cssPath(ancestor).replace(/^body > /, '') : '';
    };
    const tables = Array.from(document.querySelectorAll('table'));
    const records = tables.map((table, tableIndex) => {
      const rect = table.getBoundingClientRect();
      const rows = Array.from(table.querySelectorAll(':scope > tbody > tr, :scope > thead > tr, :scope > tr'));
      const columnCount = rows.reduce((max, row) => {
        const cells = Array.from(row.children).filter((child) => ['TD', 'TH'].includes(child.tagName));
        return Math.max(max, cells.length);
      }, 0);
      const closestCollapsible = table.closest('.collapsible-container');
      const headings = Array.from(table.querySelectorAll('tr:first-child th, thead th'))
        .map((cell) => normalizeText(cell.textContent))
        .filter(Boolean)
        .slice(0, 6);
      const firstHeader = table.querySelector('th');
      const firstData = table.querySelector('td');
      return {
        sample_id: sampleInput.sample_id,
        title: document.title,
        requested_title: sampleInput.title,
        tableIndex,
        selectorPath: cssPath(table),
        className: String(table.className || ''),
        role: table.getAttribute('role') || '',
        visible: visible(table),
        closestCollapsible: closestCollapsible ? {
          collapsed: closestCollapsible.classList.contains('collapsed'),
          label: normalizeText(closestCollapsible.querySelector('.collapsible-label')?.textContent || closestCollapsible.querySelector('.title-wrapper')?.textContent),
          labelKind: closestCollapsible.getAttribute('data-collapse-label-kind') || '',
          taskCritical: closestCollapsible.getAttribute('data-task-critical') === 'true',
        } : null,
        closestTableAncestor: !!table.parentElement?.closest('table'),
        excludedAncestor: excludedAncestorFor(table),
        rowCount: rows.length,
        columnCount,
        headerCellCount: table.querySelectorAll('th').length,
        textLength: normalizeText(table.textContent).length,
        width: Math.round(rect.width),
        height: Math.round(rect.height),
        left: Math.round(rect.left),
        top: Math.round(rect.top + window.scrollY),
        scrollWidth: table.scrollWidth,
        clientWidth: table.clientWidth,
        viewportWidth: window.innerWidth,
        caption: normalizeText(table.querySelector('caption')?.textContent),
        nearbyHeading: findHeading(table),
        firstHeaderText: normalizeText(firstHeader?.textContent).slice(0, 180),
        firstDataText: normalizeText(firstData?.textContent).slice(0, 220),
        headings,
      };
    });
    return {
      sample_id: sampleInput.sample_id,
      kind: sampleInput.kind,
      requested_title: sampleInput.title,
      rendered_title: document.title,
      pageid: sampleInput.pageid || null,
      body_class: document.body.className || '',
      transformed: document.body.classList.contains('js-transforms-complete'),
      collapse_metrics: window.OSRSCollapseMetrics || null,
      counts: {
        tables: records.length,
        collapsibleContainers: document.querySelectorAll('.collapsible-container').length,
        unwrappedVisibleTables: records.filter((record) => record.visible && !record.closestCollapsible).length,
      },
      tables: records,
    };
  }, sample);
}

function enrichedFindings(sample, parsePayload, renderPayload) {
  const categories = (parsePayload.parse?.categories || []).map((item) => item['*']).filter(Boolean);
  return renderPayload.tables.map((table) => {
    const classification = classifyTableGap(table);
    if (!classification.isCandidate) return null;
    return {
      finding_id: `${sample.sample_id}-T${String(table.tableIndex).padStart(3, '0')}`,
      sample_id: sample.sample_id,
      kind: sample.kind,
      forced_category: sample.forced_category || null,
      title: parsePayload.parse?.title || renderPayload.rendered_title || sample.title,
      requested_title: sample.title,
      pageid: parsePayload.parse?.pageid || sample.pageid || null,
      revid: parsePayload.parse?.revid || null,
      source_url: `${WIKI_BASE}/w/${wikiPath(parsePayload.parse?.title || sample.title)}`,
      categories,
      table,
      classification,
      severity: classification.severity,
      actionable: classification.actionable,
      signature: classification.signature,
      expected_collapse_rationale: classification.expectedCollapseRationale,
    };
  }).filter(Boolean);
}

async function appendJsonLine(filePath, payload) {
  await fs.mkdir(path.dirname(filePath), { recursive: true });
  await fs.appendFile(filePath, JSON.stringify(payload) + '\n');
}

function loadExistingJsonlIds(filePath) {
  const ids = new Set();
  if (!fssync.existsSync(filePath)) return ids;
  const text = fssync.readFileSync(filePath, 'utf8');
  for (const line of text.split(/\n/)) {
    if (!line.trim()) continue;
    try {
      const item = JSON.parse(line);
      if (item.sample_id) ids.add(item.sample_id);
    } catch {
      // Leave validation to the explicit JSON validation command.
    }
  }
  return ids;
}

async function scanSamples(options, evidenceRoot, manifest) {
  const resultsPath = path.join(evidenceRoot, 'scan-results.jsonl');
  const findingsPath = path.join(evidenceRoot, 'findings.jsonl');
  if (options.forceRescan) {
    await fs.rm(resultsPath, { force: true });
    await fs.rm(findingsPath, { force: true });
  }
  const scannedIds = loadExistingJsonlIds(resultsPath);
  const allSamples = options.maxSamples ? manifest.samples.slice(0, options.maxSamples) : manifest.samples;
  const samples = allSamples.filter((sample) => !scannedIds.has(sample.sample_id));
  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({
    viewport: VIEWPORT,
    deviceScaleFactor: 1,
    isMobile: true,
    userAgent: USER_AGENT,
  });
  await installAssetRoutes(context);

  let nextIndex = 0;
  let processed = scannedIds.size;
  const startedAt = Date.now();

  async function worker(workerIndex) {
    const page = await context.newPage();
    page.setDefaultTimeout(90000);
    while (nextIndex < samples.length) {
      const sample = samples[nextIndex];
      nextIndex += 1;
      const started = Date.now();
      try {
        const parseResult = await parsePage(sample, evidenceRoot);
        if (parseResult.error) {
          await appendJsonLine(resultsPath, {
            sample_id: sample.sample_id,
            kind: sample.kind,
            requested_title: sample.title,
            status: 'parse_error',
            error: parseResult.error,
          });
          processed += 1;
          continue;
        }
        const renderPayload = await renderAndCollect(page, sample, parseResult);
        renderPayload.pageid = parseResult.payload.parse?.pageid || sample.pageid || null;
        renderPayload.revid = parseResult.payload.parse?.revid || null;
        renderPayload.categories = (parseResult.payload.parse?.categories || []).map((item) => item['*']).filter(Boolean);
        const findings = enrichedFindings(sample, parseResult.payload, renderPayload);
        const result = {
          sample_id: sample.sample_id,
          kind: sample.kind,
          requested_title: sample.title,
          rendered_title: parseResult.payload.parse?.title || renderPayload.rendered_title,
          pageid: renderPayload.pageid,
          revid: renderPayload.revid,
          status: 'rendered',
          duration_ms: Date.now() - started,
          worker: workerIndex,
          counts: renderPayload.counts,
          collapse_metrics: renderPayload.collapse_metrics,
          findings_count: findings.length,
          finding_ids: findings.map((finding) => finding.finding_id),
          render_payload: renderPayload,
        };
        await appendJsonLine(resultsPath, result);
        for (const finding of findings) {
          await appendJsonLine(findingsPath, finding);
        }
      } catch (error) {
        await appendJsonLine(resultsPath, {
          sample_id: sample.sample_id,
          kind: sample.kind,
          requested_title: sample.title,
          status: 'render_error',
          error: error.stack || error.message || String(error),
        });
      } finally {
        processed += 1;
        if (processed % 100 === 0) {
          const elapsedSec = Math.max(1, Math.round((Date.now() - startedAt) / 1000));
          console.log(`scan progress: ${processed}/${allSamples.length} samples (${Math.round(processed / elapsedSec)} samples/sec)`);
        }
      }
    }
    await page.close();
  }

  try {
    await Promise.all(Array.from({ length: Math.max(1, options.concurrency) }, (_unused, index) => worker(index + 1)));
  } finally {
    await context.close();
    await browser.close();
  }
}

function readJsonl(filePath) {
  if (!fssync.existsSync(filePath)) return [];
  return fssync.readFileSync(filePath, 'utf8')
    .split(/\n/)
    .filter((line) => line.trim())
    .map((line) => JSON.parse(line));
}

function severityRank(severity) {
  return { high: 3, medium: 2, low: 1 }[severity] || 0;
}

function summarize(evidenceRoot, manifest, options) {
  const results = readJsonl(path.join(evidenceRoot, 'scan-results.jsonl'));
  const findings = readJsonl(path.join(evidenceRoot, 'findings.jsonl'));
  const rendered = results.filter((result) => result.status === 'rendered');
  const randomRenderedPageIds = new Set(
    rendered
      .filter((result) => result.kind === 'random' && result.pageid)
      .map((result) => String(result.pageid)),
  );
  const allRenderedPageIds = new Set(rendered.filter((result) => result.pageid).map((result) => String(result.pageid)));
  const bySeverity = findings.reduce((acc, finding) => {
    acc[finding.severity] = (acc[finding.severity] || 0) + 1;
    return acc;
  }, {});
  const bySignatureMap = new Map();
  for (const finding of findings) {
    const signature = finding.signature || normalizeClassSignature(finding.table?.className || '') || 'unclassed-table';
    const item = bySignatureMap.get(signature) || {
      signature,
      count: 0,
      severity: finding.severity,
      actionable: finding.actionable,
      example_titles: [],
      classes: finding.table?.className || '',
    };
    item.count += 1;
    if (severityRank(finding.severity) > severityRank(item.severity)) {
      item.severity = finding.severity;
    }
    item.actionable = item.actionable || finding.actionable;
    if (item.example_titles.length < 8 && !item.example_titles.includes(finding.title)) {
      item.example_titles.push(finding.title);
    }
    bySignatureMap.set(signature, item);
  }
  const bySignature = [...bySignatureMap.values()].sort((a, b) =>
    severityRank(b.severity) - severityRank(a.severity) ||
    b.count - a.count ||
    a.signature.localeCompare(b.signature),
  );
  const topFindings = [...findings].sort((a, b) =>
    severityRank(b.severity) - severityRank(a.severity) ||
    Number(b.table?.height || 0) - Number(a.table?.height || 0) ||
    a.title.localeCompare(b.title),
  ).slice(0, 50);
  return {
    status: randomRenderedPageIds.size >= options.randomTarget ? 'complete' : 'below-target',
    generated_at: new Date().toISOString(),
    evidence_root: path.relative(repoRoot, evidenceRoot),
    random_target_distinct_rendered: options.randomTarget,
    sample_count_total: results.length,
    sample_count_rendered: rendered.length,
    sample_count_distinct_rendered: allRenderedPageIds.size,
    random_sample_count_distinct_rendered: randomRenderedPageIds.size,
    forced_manifest_count: manifest.forced_count,
    random_manifest_count: manifest.random_sample_manifest_count,
    findings_count: findings.length,
    findings_by_severity: bySeverity,
    actionable_findings_count: findings.filter((finding) => finding.actionable).length,
    detection_criteria: detectionCriteriaSummary(),
    top_signatures: bySignature.slice(0, 25),
    top_findings: topFindings.map((finding) => ({
      finding_id: finding.finding_id,
      severity: finding.severity,
      actionable: finding.actionable,
      title: finding.title,
      source_url: finding.source_url,
      signature: finding.signature,
      selector_path: finding.table.selectorPath,
      nearby_heading: finding.table.nearbyHeading,
      caption: finding.table.caption,
      dimensions: {
        width: finding.table.width,
        height: finding.table.height,
        rows: finding.table.rowCount,
        columns: finding.table.columnCount,
      },
      rationale: finding.expected_collapse_rationale,
    })),
    parse_errors: results.filter((result) => result.status === 'parse_error').length,
    render_errors: results.filter((result) => result.status === 'render_error').length,
  };
}

async function captureRepresentativeEvidence(options, evidenceRoot, summary) {
  const findings = readJsonl(path.join(evidenceRoot, 'findings.jsonl'));
  const wanted = [];
  const trigger = findings.find((finding) => finding.title === 'The Blood Moon Rises/Quick guide' && finding.table.className.includes('questdetails'));
  if (trigger) wanted.push(trigger);
  for (const finding of findings.sort((a, b) =>
    severityRank(b.severity) - severityRank(a.severity) ||
    Number(b.table?.height || 0) - Number(a.table?.height || 0))) {
    if (wanted.length >= options.representativeScreenshots + (trigger ? 1 : 0)) break;
    if (!wanted.some((item) => item.finding_id === finding.finding_id)) {
      wanted.push(finding);
    }
  }
  if (!wanted.length) return [];

  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({
    viewport: VIEWPORT,
    deviceScaleFactor: 1,
    isMobile: true,
    userAgent: USER_AGENT,
  });
  await installAssetRoutes(context);
  const page = await context.newPage();
  const captures = [];
  try {
    for (const finding of wanted) {
      const htmlCandidates = fssync.readdirSync(path.join(evidenceRoot, 'raw/parse-html'))
        .filter((name) => name.startsWith(`${finding.pageid}-`) && name.endsWith('.html.gz'));
      if (!htmlCandidates.length) continue;
      const htmlPath = path.join(evidenceRoot, 'raw/parse-html', htmlCandidates[0]);
      const rawHtml = zlib.gunzipSync(fssync.readFileSync(htmlPath)).toString('utf8');
      const appHtml = buildAppHtml(finding.title, rawHtml);
      await page.setContent(appHtml, { waitUntil: 'domcontentloaded', timeout: 90000 });
      await page.waitForFunction(() => document.body.classList.contains('js-transforms-complete'), null, { timeout: 90000 });
      await page.evaluate(() => {
        document.body.style.visibility = 'visible';
      });
      const tableIndex = finding.table.tableIndex;
      const domEvidence = await page.evaluate((index) => {
        const tables = Array.from(document.querySelectorAll('table'));
        const table = tables[index];
        if (!table) return null;
        table.setAttribute('data-audit-highlight', 'true');
        table.style.outline = '4px solid #c62828';
        table.style.outlineOffset = '3px';
        table.scrollIntoView({ block: 'center', inline: 'nearest' });
        const rect = table.getBoundingClientRect();
        return {
          outerHTML: table.outerHTML.slice(0, 12000),
          rect: {
            top: Math.round(rect.top),
            left: Math.round(rect.left),
            width: Math.round(rect.width),
            height: Math.round(rect.height),
          },
        };
      }, tableIndex);
      if (!domEvidence) continue;
      await page.waitForTimeout(100);
      const stem = `${finding.finding_id}-${slugForTitle(finding.title)}`;
      const screenshotPath = path.join(evidenceRoot, 'screenshots', `${stem}.png`);
      const domPath = path.join(evidenceRoot, 'dom-evidence', `${stem}.json`);
      await fs.mkdir(path.dirname(screenshotPath), { recursive: true });
      await fs.mkdir(path.dirname(domPath), { recursive: true });
      await page.screenshot({ path: screenshotPath, fullPage: false });
      await fs.writeFile(domPath, JSON.stringify({ finding, domEvidence }, null, 2) + '\n');
      captures.push({
        finding_id: finding.finding_id,
        title: finding.title,
        screenshot: path.relative(repoRoot, screenshotPath),
        dom_evidence: path.relative(repoRoot, domPath),
      });
    }
  } finally {
    await page.close();
    await context.close();
    await browser.close();
  }

  summary.representative_evidence = captures;
  await fs.writeFile(path.join(evidenceRoot, 'summary.json'), JSON.stringify(summary, null, 2) + '\n');
  return captures;
}

async function writeEvidenceIndex(evidenceRoot, manifest, summary, captures) {
  const index = {
    generated_at: new Date().toISOString(),
    status: summary.status,
    evidence_root: path.relative(repoRoot, evidenceRoot),
    files: {
      sample_manifest: path.relative(repoRoot, path.join(evidenceRoot, 'sample-manifest.json')),
      criteria: path.relative(repoRoot, path.join(evidenceRoot, 'criteria.json')),
      scan_results_jsonl: path.relative(repoRoot, path.join(evidenceRoot, 'scan-results.jsonl')),
      findings_jsonl: path.relative(repoRoot, path.join(evidenceRoot, 'findings.jsonl')),
      summary_json: path.relative(repoRoot, path.join(evidenceRoot, 'summary.json')),
      screenshots_dir: path.relative(repoRoot, path.join(evidenceRoot, 'screenshots')),
      dom_evidence_dir: path.relative(repoRoot, path.join(evidenceRoot, 'dom-evidence')),
      raw_parse_json_dir: path.relative(repoRoot, path.join(evidenceRoot, 'raw/parse-json')),
      raw_parse_html_dir: path.relative(repoRoot, path.join(evidenceRoot, 'raw/parse-html')),
    },
    sample_counts: {
      forced_manifest_count: manifest.forced_count,
      random_manifest_count: manifest.random_sample_manifest_count,
      sample_count_total: summary.sample_count_total,
      sample_count_distinct_rendered: summary.sample_count_distinct_rendered,
      random_sample_count_distinct_rendered: summary.random_sample_count_distinct_rendered,
    },
    detection_criteria: summary.detection_criteria,
    top_signatures: summary.top_signatures,
    representative_evidence: captures,
  };
  await fs.writeFile(path.join(evidenceRoot, 'evidence-index.json'), JSON.stringify(index, null, 2) + '\n');
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const evidenceRoot = execFileSync(
    storageHelper,
    ['validate-path', path.resolve(repoRoot, options.outputRoot)],
    { encoding: 'utf8', env: process.env },
  ).trim();
  await fs.mkdir(evidenceRoot, { recursive: true });
  const criteria = {
    generated_at: new Date().toISOString(),
    criteria_summary: detectionCriteriaSummary(),
    existing_android_transform_selectors: ['table.infobox', 'table.wikitable', 'table.navbox', 'div.mw-collapsible'],
    high_severity_anchor: 'table.questdetails on The Blood Moon Rises/Quick guide Details section',
    exclusions: ['messagebox', 'ambox/mbox/notebox', 'navbox internals', 'infobox internals', 'galleries', 'TOC/edit UI', 'hidden tooltip tables', 'nested tables', 'already inside .collapsible-container'],
  };
  await fs.writeFile(path.join(evidenceRoot, 'criteria.json'), JSON.stringify(criteria, null, 2) + '\n');

  const manifest = await buildOrLoadManifest(options, evidenceRoot);
  console.log(`manifest samples: ${manifest.total_manifest_count} (${manifest.random_sample_manifest_count} random + ${manifest.forced_count} forced)`);
  await scanSamples(options, evidenceRoot, manifest);
  const summary = summarize(evidenceRoot, manifest, options);
  await fs.writeFile(path.join(evidenceRoot, 'summary.json'), JSON.stringify(summary, null, 2) + '\n');
  const captures = await captureRepresentativeEvidence(options, evidenceRoot, summary);
  await writeEvidenceIndex(evidenceRoot, manifest, summary, captures);
  console.log(JSON.stringify({
    status: summary.status,
    sample_count_total: summary.sample_count_total,
    sample_count_distinct_rendered: summary.sample_count_distinct_rendered,
    random_sample_count_distinct_rendered: summary.random_sample_count_distinct_rendered,
    findings_count: summary.findings_count,
    evidence_root: path.relative(repoRoot, evidenceRoot),
  }, null, 2));
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error.stack || error.message || String(error));
    process.exit(1);
  });
