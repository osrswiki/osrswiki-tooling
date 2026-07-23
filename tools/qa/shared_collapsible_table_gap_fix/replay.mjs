#!/usr/bin/env node

import crypto from 'node:crypto';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs/promises';
import fssync from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(scriptDir, '../../..');
const androidRequire = createRequire(path.join(repoRoot, 'platforms/android/package.json'));
const { chromium } = androidRequire('@playwright/test');

const storageHelper = path.join(repoRoot, 'scripts/shared/local-artifact-root.sh');
const defaultEvidenceRoot = execFileSync(
  storageHelper,
  [
    'path',
    'active',
    process.env.OSRS_LANE_ID || 'shared-collapsible-table-gap-fix',
    'replay-output',
  ],
  { encoding: 'utf8', env: process.env },
).trim();
const evidenceRoot = execFileSync(
  storageHelper,
  ['validate-path', path.resolve(process.env.OSRS_QA_EVIDENCE_ROOT || defaultEvidenceRoot)],
  { encoding: 'utf8', env: process.env },
).trim();
const beforeDir = path.join(evidenceRoot, 'before');
const afterDir = path.join(evidenceRoot, 'after');

function sha256(value) {
  return crypto.createHash('sha256').update(value).digest('hex');
}

async function readText(relativePath) {
  return fs.readFile(path.join(repoRoot, relativePath), 'utf8');
}

function readGzipText(relativePath) {
  return zlib.gunzipSync(fssync.readFileSync(path.join(repoRoot, relativePath))).toString('utf8');
}

function explicitMwCollapsibleFixture() {
  return `
<h2>Level 20-99: Stealing from Port Roberts stalls</h2>
<table class="mw-collapsible mw-collapsed">
  <tbody>
    <tr><th align="left">Importable Watchdog config</th></tr>
    <tr><td><pre>{"type":"AlertGroup","alerts":[{"type":"XPDropAlert"}]}</pre></td></tr>
  </tbody>
</table>
<table class="navbox mw-collapsible mw-collapsed">
  <tbody><tr><th class="navbox-title">Navigation</th></tr><tr><td>Existing navbox path</td></tr></tbody>
</table>
<table class="messagebox mw-collapsible mw-collapsed">
  <tbody><tr><td>Message layout table stays outside the explicit fallback.</td></tr></tbody>
</table>
<div class="collapsible-container collapsed">
  <div class="collapsible-content">
    <table class="mw-collapsible mw-collapsed" id="alreadyWrapped">
      <tbody><tr><th>Already wrapped</th></tr><tr><td>Leave this table in its existing container.</td></tr></tbody>
    </table>
  </div>
</div>`;
}

function questdetailsFixture({ startPoint, difficulty, length, requirements }) {
  return `
<h2>Details</h2>
<table class="questdetails" cellspacing="3">
  <tbody>
    <tr><th class="questdetails-header">Start point</th><td class="questdetails-info">${startPoint}</td></tr>
    <tr><th class="questdetails-header">Official difficulty</th><td class="questdetails-info">${difficulty}</td></tr>
    <tr><th class="questdetails-header">Official length</th><td class="questdetails-info">${length}</td></tr>
    <tr><th class="questdetails-header">Requirements</th><td class="questdetails-info">${requirements}</td></tr>
    <tr><th class="questdetails-header">Items required</th><td class="questdetails-info">Quest-specific items and combat gear.</td></tr>
  </tbody>
</table>`;
}

async function fixtures() {
  return [
    {
      id: 'blood-moon-quick-guide',
      title: 'The Blood Moon Rises/Quick guide',
      cluster: 'questdetails',
      html: readGzipText('qa-evidence/android-collapsible-table-gap-audit-2026-07-09/raw/parse-html/666311-the-blood-moon-rises-quick-guide.html.gz'),
      screenshot: true,
    },
    {
      id: 'one-small-favour-quick-guide',
      title: 'One Small Favour/Quick guide',
      cluster: 'questdetails',
      html: questdetailsFixture({
        startPoint: 'Talk to Yanni Salika in Shilo Village.',
        difficulty: 'Experienced',
        length: 'Long',
        requirements: 'Completion of Shilo Village and supporting skill requirements.',
      }),
    },
    {
      id: 'recipe-for-disaster-quick-guide',
      title: 'Recipe for Disaster/Quick guide',
      cluster: 'questdetails',
      html: questdetailsFixture({
        startPoint: 'Talk to the Cook in Lumbridge Castle.',
        difficulty: 'Special',
        length: 'Very Long',
        requirements: 'Completion of Cook\'s Assistant and the prerequisite quest chain.',
      }),
    },
    {
      id: 'explicit-mw-collapsible-watchdog',
      title: 'Thieving training explicit mw-collapsible fixture',
      cluster: 'explicit-mw-collapsible',
      html: explicitMwCollapsibleFixture(),
      screenshot: true,
    },
  ];
}

function buildHtml({ title, html, script, css }) {
  return `<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>${title}</title>
  <style>${css}</style>
  <script>
    window.OSRS_TABLE_COLLAPSED = true;
    window.RenderTimeline = { log: function() {} };
  </script>
</head>
<body>
  <h1 class="page-header">${title}</h1>
  ${html}
  ${script ? `<script>${script}</script>` : ''}
</body>
</html>`;
}

async function collectPageState(page, cluster) {
  return page.evaluate((targetCluster) => {
    const text = (element, selector) => (element.querySelector(selector)?.textContent || '').replace(/\s+/g, ' ').trim();
    const containers = Array.from(document.querySelectorAll('.collapsible-container'));
    const questdetails = Array.from(document.querySelectorAll('table.questdetails'));
    const explicitTables = Array.from(document.querySelectorAll('table.mw-collapsible'));
    const targetExplicitTables = explicitTables.filter((table) =>
      table.id !== 'alreadyWrapped' &&
      !table.matches('table.navbox, table.messagebox, table.ambox, table.mbox, table.notebox')
    );

    return {
      transformsComplete: document.body.classList.contains('js-transforms-complete'),
      containerCount: containers.length,
      containers: containers.map((container) => ({
        classes: Array.from(container.classList),
        label: text(container, '.collapsible-label') || text(container, '.title-wrapper'),
        collapsed: container.classList.contains('collapsed'),
        hasQuestdetails: !!container.querySelector('table.questdetails'),
        hasExplicitMwCollapsible: !!container.querySelector('table.mw-collapsible'),
      })),
      questdetailsCount: questdetails.length,
      questdetailsOutsideContainer: questdetails.filter((table) => !table.closest('.collapsible-container')).length,
      explicitMwCollapsibleCount: explicitTables.length,
      targetExplicitOutsideContainer: targetExplicitTables.filter((table) => !table.closest('.collapsible-container')).length,
      alreadyWrappedDepth: document.getElementById('alreadyWrapped')
        ? containers.filter((container) => container.contains(document.getElementById('alreadyWrapped'))).length
        : null,
      navboxDepth: Array.from(document.querySelectorAll('table.navbox')).map((table) =>
        containers.filter((container) => container.contains(table)).length
      ),
      messageboxWrappedCount: Array.from(document.querySelectorAll('table.messagebox')).filter((table) =>
        table.closest('.collapsible-container')
      ).length,
      targetCluster,
    };
  }, cluster);
}

async function run() {
  await fs.mkdir(beforeDir, { recursive: true });
  await fs.mkdir(afterDir, { recursive: true });

  const androidScript = await readText('platforms/android/app/src/main/assets/web/collapsible_content.js');
  const iosScript = await readText('platforms/ios/osrswiki/Assets/web/collapsible_content.js');
  const androidCss = [
    'platforms/android/app/src/main/assets/web/collapsible_tables.css',
    'platforms/android/app/src/main/assets/web/collapsible_sections.css',
  ].map((asset) => fssync.readFileSync(path.join(repoRoot, asset), 'utf8')).join('\n');
  const iosCss = [
    'platforms/ios/osrswiki/Assets/web/collapsible_tables.css',
    'platforms/ios/osrswiki/Assets/web/collapsible_sections.css',
  ].map((asset) => fssync.readFileSync(path.join(repoRoot, asset), 'utf8')).join('\n');

  const browser = await chromium.launch({ channel: 'chrome', headless: true });
  const results = [];

  try {
    for (const fixture of await fixtures()) {
      const beforePage = await browser.newPage({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 1 });
      await beforePage.setContent(buildHtml({ ...fixture, css: androidCss, script: '' }), { waitUntil: 'load' });
      const before = await collectPageState(beforePage, fixture.cluster);
      if (fixture.screenshot) {
        await beforePage.screenshot({ path: path.join(beforeDir, `${fixture.id}.png`), fullPage: false });
      }
      await beforePage.close();

      for (const platform of [
        { name: 'android', script: androidScript, css: androidCss },
        { name: 'ios', script: iosScript, css: iosCss },
      ]) {
        const page = await browser.newPage({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 1 });
        const pageErrors = [];
        page.on('pageerror', (error) => pageErrors.push(error.message));
        await page.setContent(buildHtml({ ...fixture, css: platform.css, script: platform.script }), { waitUntil: 'load' });
        try {
          await page.waitForFunction(() => document.body.classList.contains('js-transforms-complete'), null, { timeout: 15000 });
        } catch (error) {
          const bodyState = await page.evaluate(() => ({
            readyState: document.readyState,
            bodyClass: document.body ? document.body.className : '',
            containerCount: document.querySelectorAll('.collapsible-container').length,
          })).catch(() => ({}));
          throw new Error(
            `Timed out waiting for transforms on ${platform.name}/${fixture.id}: ` +
            `${JSON.stringify({ bodyState, pageErrors }, null, 2)}`
          );
        }
        const after = await collectPageState(page, fixture.cluster);
        if (fixture.screenshot) {
          await page.screenshot({ path: path.join(afterDir, `${fixture.id}-${platform.name}.png`), fullPage: false });
        }
        await page.close();

        const passed = fixture.cluster === 'questdetails'
          ? after.questdetailsOutsideContainer === 0 && after.containers.some((container) => container.hasQuestdetails && container.collapsed)
          : after.targetExplicitOutsideContainer === 0 &&
              after.alreadyWrappedDepth === 1 &&
              after.messageboxWrappedCount === 0;

        results.push({
          platform: platform.name,
          fixture: fixture.id,
          title: fixture.title,
          cluster: fixture.cluster,
          before,
          after,
          passed,
        });
      }
    }
  } finally {
    await browser.close();
  }

  const summary = {
    generatedAt: new Date().toISOString(),
    evidenceRoot: path.relative(repoRoot, evidenceRoot),
    assetHashes: {
      androidCollapsibleContent: sha256(androidScript),
      iosCollapsibleContent: sha256(iosScript),
    },
    preservedAuditInputs: {
      androidReport: 'docs/internal/qa/android-collapsible-table-gap-audit-2026-07-09.md',
      androidFindingCount: 137,
      iosReport: 'docs/internal/qa/ios-collapsible-table-gap-audit-2026-07-09.md',
      iosFindingCount: 155,
      iosQuestdetailsFindings: 149,
      iosExplicitMwCollapsibleFindings: 6,
    },
    results,
  };

  await fs.writeFile(path.join(afterDir, 'replay-results.json'), JSON.stringify(summary, null, 2) + '\n');

  const failures = results.filter((result) => !result.passed);
  if (failures.length) {
    throw new Error(`Shared collapsible table replay failed ${failures.length} case(s)`);
  }

  console.log(`shared collapsible table replay passed ${results.length} platform fixture case(s)`);
}

run().catch((error) => {
  console.error(error);
  process.exit(1);
});
