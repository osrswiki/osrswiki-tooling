#!/usr/bin/env node

import { gunzipSync } from 'node:zlib';
import { execFileSync } from 'node:child_process';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const scriptPath = fileURLToPath(import.meta.url);
const repoRoot = path.resolve(path.dirname(scriptPath), '../..');
const androidRequire = createRequire(path.join(repoRoot, 'platforms/android/package.json'));
const { chromium } = androidRequire('@playwright/test');
const androidAssetRoot = path.join(repoRoot, 'platforms/android/app/src/main/assets');
const rawHtmlRoot = path.join(repoRoot, 'qa-evidence/android-article-aesthetic-reaudit-2026-07-06/raw/parse-html');
const storageHelper = path.join(repoRoot, 'scripts/shared/local-artifact-root.sh');
const outputRoot = execFileSync(
  storageHelper,
  [
    'prepare',
    'active',
    process.env.OSRS_LANE_ID || 'android-article-aesthetic-fix-and-art-08',
    'collapse-hierarchy-metrics',
  ],
  { encoding: 'utf8', env: process.env },
).trim();

const pages = [
  { id: 'ARA-013', title: 'Money making guide/Catching dark crabs', slug: 'money-making-guide-catching-dark-crabs', raw: 'ARA-013-money-making-guide-catching-dark-crabs.html.gz' },
  { id: 'ARA-001', title: 'Abyssal whip', slug: 'abyssal-whip', raw: 'ARA-001-abyssal-whip.html.gz' },
  { id: 'ARA-019', title: 'Dragon scimitar', slug: 'dragon-scimitar', raw: 'ARA-019-dragon-scimitar.html.gz' },
  { id: 'ARA-016', title: 'Trailblazer Reloaded League/Tasks', slug: 'trailblazer-reloaded-league-tasks', raw: 'ARA-016-trailblazer-reloaded-league-tasks.html.gz' },
  { id: 'ARA-258', title: 'Cooking', slug: 'cooking', raw: 'ARA-258-cooking.html.gz' },
  { id: 'ARA-265', title: 'Pay-to-play Ranged training', slug: 'pay-to-play-ranged-training', raw: 'ARA-265-pay-to-play-ranged-training.html.gz' }
];

const cssAssets = [
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
  'styles/android-article-aesthetics.css'
];

const jsAssets = [
  'web/collapsible_content.js',
  'web/switch_infobox.js',
  'web/horizontal_scroll_interceptor.js',
  'web/responsive_videos.js'
];

async function readAsset(relativePath) {
  return readFile(path.join(androidAssetRoot, relativePath), 'utf8');
}

function escapeScriptValue(value) {
  return JSON.stringify(value).replace(/</g, '\\u003c');
}

async function buildDocument(pageInfo, fontScale) {
  const rawBuffer = await readFile(path.join(rawHtmlRoot, pageInfo.raw));
  const body = gunzipSync(rawBuffer).toString('utf8');
  const css = (await Promise.all(cssAssets.map(readAsset))).join('\n\n');
  const js = (await Promise.all(jsAssets.map(readAsset))).join('\n\n');
  const pageTitle = pageInfo.title.replace(/_/g, ' ');

  return `<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>${pageTitle}</title>
  <style>${css}</style>
  <style>body { visibility: visible !important; font-size: ${fontScale}%; }</style>
  <script>
    window.OSRS_TABLE_COLLAPSED = true;
    window.RLCONF = {
      wgTitle: ${escapeScriptValue(pageTitle)},
      wgPageName: ${escapeScriptValue(pageTitle.replaceAll(' ', '_'))}
    };
  </script>
</head>
<body>
  <h1 class="page-header">${pageTitle}</h1>
  ${body}
  <script>${js}</script>
</body>
</html>`;
}

async function collectMetrics(page) {
  return page.evaluate(() => {
    const textStart = document.body.innerText.replace(/\s+/g, ' ').trim().slice(0, 1100);
    const controls = Array.from(document.querySelectorAll('.collapsible-container')).map((container, index) => {
      const rect = container.getBoundingClientRect();
      const label = container.querySelector('.collapsible-label')?.textContent?.trim() || '';
      const summary = container.querySelector(':scope > .collapsible-summary')?.textContent?.trim() || '';
      return {
        index,
        label,
        stateText: container.querySelector('.collapsible-state')?.textContent?.trim() || '',
        labelKind: container.getAttribute('data-collapse-label-kind') || '',
        taskCritical: container.getAttribute('data-task-critical') === 'true',
        collapsed: container.classList.contains('collapsed'),
        hasSummary: summary.length > 0,
        summary: summary.slice(0, 240),
        top: Math.round(rect.top),
        height: Math.round(rect.height)
      };
    });
    const nativeMetrics = window.OSRSCollapseMetrics || {};
    return {
      url: location.href,
      textStart,
      nativeMetrics,
      controls,
      counts: {
        collapseControls: controls.length,
        genericCollapseLabels: controls.filter((control) => control.labelKind === 'generic').length,
        primaryExpandedControls: controls.filter((control) => control.taskCritical && !control.collapsed).length,
        primarySummaries: controls.filter((control) => control.taskCritical && control.collapsed && control.hasSummary).length,
        hiddenTaskCriticalControls: controls.filter((control) => control.taskCritical && control.collapsed && !control.hasSummary).length
      }
    };
  });
}

function evaluateResult(pageInfo, variant, metrics) {
  const hiddenTaskCritical = metrics.counts.hiddenTaskCriticalControls;
  const firstTaskControl = metrics.controls.find((control) => control.taskCritical);
  const firstGenericControl = metrics.controls.find((control) => control.labelKind === 'generic');
  const genericBeforePrimary = !!(
    firstGenericControl &&
    firstTaskControl &&
    firstGenericControl.index < firstTaskControl.index
  );

  return {
    page: pageInfo.title,
    variant,
    pass: hiddenTaskCritical === 0 && !genericBeforePrimary,
    hiddenTaskCritical,
    genericBeforePrimary,
    firstTaskControl: firstTaskControl || null,
    firstGenericControl: firstGenericControl || null
  };
}

async function main() {
  await mkdir(path.join(outputRoot, 'surrogate'), { recursive: true });
  await mkdir(path.join(outputRoot, 'analysis'), { recursive: true });

  const browser = await chromium.launch({ headless: true });
  const results = [];
  const startedAt = new Date().toISOString();
  try {
    for (const pageInfo of pages) {
      for (const variant of [
        { name: 'normal', fontScale: 100 },
        { name: 'font135', fontScale: 135 }
      ]) {
        const context = await browser.newContext({
          viewport: { width: 390, height: 844 },
          deviceScaleFactor: 1,
          isMobile: true
        });
        const page = await context.newPage();
        const html = await buildDocument(pageInfo, variant.fontScale);
        const started = performance.now();
        await page.setContent(html, { waitUntil: 'load', timeout: 120000 });
        await page.waitForFunction(() => document.body.classList.contains('js-transforms-complete'), null, { timeout: 120000 });
        const elapsedMs = Math.round(performance.now() - started);
        const metrics = await collectMetrics(page);
        const screenshot = path.join(outputRoot, 'surrogate', `${pageInfo.id}-${pageInfo.slug}-${variant.name}.png`);
        await page.screenshot({ path: screenshot, fullPage: false });
        await context.close();

        results.push({
          id: pageInfo.id,
          title: pageInfo.title,
          variant: variant.name,
          fontScale: variant.fontScale,
          elapsedMs,
          screenshot: path.relative(repoRoot, screenshot),
          metrics,
          evaluation: evaluateResult(pageInfo, variant.name, metrics)
        });
      }
    }
  } finally {
    await browser.close();
  }

  const failed = results.filter((result) => !result.evaluation.pass);
  const payload = {
    status: failed.length === 0 ? 'pass' : 'fail',
    startedAt,
    finishedAt: new Date().toISOString(),
    pages: pages.map((pageInfo) => pageInfo.title),
    results
  };
  await writeFile(
    path.join(outputRoot, 'analysis/and-art-08-collapse-metrics.json'),
    JSON.stringify(payload, null, 2) + '\n'
  );

  const lines = [
    '# AND-ART-08 Collapse Metrics',
    '',
    `Status: ${payload.status}`,
    '',
    '| Page | Variant | Controls | Generic labels | Primary expanded | Primary summaries | Hidden primary | Render ms |',
    '| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |'
  ];
  for (const result of results) {
    const counts = result.metrics.counts;
    lines.push(`| ${result.title} | ${result.variant} | ${counts.collapseControls} | ${counts.genericCollapseLabels} | ${counts.primaryExpandedControls} | ${counts.primarySummaries} | ${counts.hiddenTaskCriticalControls} | ${result.elapsedMs} |`);
  }
  lines.push('');
  lines.push('Screenshots are in the local artifact directory for this run.');
  await writeFile(path.join(outputRoot, 'analysis/and-art-08-collapse-metrics.md'), lines.join('\n') + '\n');

  if (failed.length > 0) {
    console.error(`AND-ART-08 metrics failed for ${failed.length} page variants.`);
    process.exit(1);
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
