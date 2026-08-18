#!/usr/bin/env node

import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(scriptDirectory, '../../..');
const chromeBinary = process.env.OSRS_CHROME_BIN ||
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

async function read(relativePath) {
    return fs.readFile(path.join(repositoryRoot, relativePath), 'utf8');
}

function markedCssContract(css) {
    const start = css.indexOf('/* OSRS_SHARED_ARTICLE_SEMANTICS_START');
    const endMarker = '/* OSRS_SHARED_ARTICLE_SEMANTICS_END */';
    const end = css.indexOf(endMarker, start);
    assert.notEqual(start, -1, 'shared CSS contract start marker is present');
    assert.notEqual(end, -1, 'shared CSS contract end marker is present');
    return css.slice(start, end + endMarker.length);
}

async function assertAssetParity() {
    const sharedCollapsible = await read('shared/js/collapsible_content.js');
    const sharedPolish = await read('shared/js/mobile_article_polish.js');
    const sharedFixes = await read('shared/css/fixes.css');
    const androidCollapsible = await read('platforms/android/app/src/main/assets/web/collapsible_content.js');
    const iosCollapsible = await read('platforms/ios/osrswiki/Assets/web/collapsible_content.js');
    const androidPolish = await read('platforms/android/app/src/main/assets/web/mobile_article_polish.js');
    const iosPolish = await read('platforms/ios/osrswiki/Assets/web/mobile_article_polish.js');
    const androidFixes = await read('platforms/android/app/src/main/assets/styles/fixes.css');
    const iosFixes = await read('platforms/ios/osrswiki/Assets/styles/fixes.css');

    assert.equal(androidCollapsible, sharedCollapsible, 'Android collapsible JS matches canonical source');
    assert.equal(iosCollapsible, sharedCollapsible, 'iOS collapsible JS matches canonical source');
    assert.equal(androidPolish, sharedPolish, 'Android polish JS matches canonical source');
    assert.equal(iosPolish, sharedPolish, 'iOS polish JS matches canonical source');
    assert.equal(androidFixes, sharedFixes, 'Android fixes CSS matches canonical source');
    assert.equal(markedCssContract(iosFixes), markedCssContract(sharedFixes), 'iOS includes the canonical CSS contract');

    [
        'Money making guide/',
        'Calculator:',
        'Trailblazer Reloaded League/Tasks',
        'Pay-to-play',
        'normalizedPageTitle',
        'isSkillLandingPage',
        'getArticleContext'
    ].forEach((titleGate) => {
        assert.equal(sharedCollapsible.includes(titleGate), false, `canonical transform excludes ${titleGate}`);
    });
    assert.equal(
        (sharedCollapsible.match(/function shouldIgnoreCaptionTextElement/g) || []).length,
        1,
        'caption visibility has one canonical hidden-content guard'
    );
    assert.ok(
        sharedCollapsible.includes("element.hidden || element.getAttribute('aria-hidden') === 'true'"),
        'the caption guard ignores content already hidden by a prior idempotent pass'
    );
    assert.equal(sharedPolish.includes('[style*="padding"]'), false, 'inline icon classification is structural');
}

function documentHtml({ body, scripts, styles = '', evaluate }) {
    return `<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <style>
    :root {
      --wikitable-bg: #ded2b8;
      --wikitable-border: #9d8c70;
      --wikitable-header-bg: #c5b893;
      --colorsurfacevariant: #ded2b8;
      --coloronsurfacevariant: #241c12;
      --text-color: #241c12;
    }
    body { margin: 8px; }
    ${styles}
  </style>
  <script>
    window.__osrsTestErrors = [];
    window.addEventListener('error', event => window.__osrsTestErrors.push(String(event.error || event.message)));
    window.OSRS_TABLE_COLLAPSED = false;
    window.RenderTimeline = { log() {} };
  </script>
</head>
<body>
  ${body}
  ${scripts.map((script) => `<script>${script}</script>`).join('\n')}
  <script>
    try {
      // The assets normally defer to DOMContentLoaded. Invoke their public idempotent entry
      // points synchronously so --dump-dom needs no timing heuristic or persistent browser.
      if (typeof window.OSRSInitializeCollapsibleContent === 'function') {
        window.OSRSInitializeCollapsibleContent();
      }
      if (typeof window.OSRSApplyArticlePolish === 'function') {
        window.OSRSApplyArticlePolish();
      }
      const value = (${evaluate})();
      value.runtimeErrors = window.__osrsTestErrors;
      document.documentElement.setAttribute(
        'data-osrs-test-result',
        encodeURIComponent(JSON.stringify(value))
      );
    } catch (error) {
      document.documentElement.setAttribute(
        'data-osrs-test-error',
        encodeURIComponent(String(error && error.stack || error))
      );
    }
  </script>
</body>
</html>`;
}

function dumpDomWithBoundedChrome(argumentsList) {
    return new Promise((resolve, reject) => {
        const child = spawn(chromeBinary, argumentsList, {
            detached: true,
            stdio: ['ignore', 'pipe', 'pipe']
        });
        const maxBuffer = 20 * 1024 * 1024;
        let stdout = '';
        let stderr = '';
        let failure = null;
        let shutdownRequested = false;
        let forceKillTimer = null;

        function signalProcessGroup(signal) {
            if (!child.pid) return;
            try {
                process.kill(-child.pid, signal);
            } catch (error) {
                if (!error || error.code !== 'ESRCH') throw error;
            }
        }

        function requestShutdown(error) {
            if (error && !failure) failure = error;
            if (shutdownRequested) return;
            shutdownRequested = true;
            signalProcessGroup('SIGTERM');
            forceKillTimer = setTimeout(() => signalProcessGroup('SIGKILL'), 750);
            forceKillTimer.unref();
        }

        const deadline = setTimeout(() => {
            if (!stdout.includes('</html>')) {
                failure = new Error('headless Chrome did not emit a complete DOM within 15 seconds');
            }
            requestShutdown();
        }, 15_000);

        child.stdout.setEncoding('utf8');
        child.stdout.on('data', chunk => {
            stdout += chunk;
            if (stdout.length > maxBuffer) {
                requestShutdown(new Error('headless Chrome DOM output exceeded 20 MiB'));
            } else if (stdout.includes('</html>')) {
                // --dump-dom has finished its only useful work. End Chrome's dedicated process
                // group before its component-extension updater can keep the host test alive.
                requestShutdown();
            }
        });
        child.stderr.setEncoding('utf8');
        child.stderr.on('data', chunk => {
            if (stderr.length < 1024 * 1024) stderr += chunk;
        });
        child.on('error', error => requestShutdown(error));
        child.on('close', (code, signal) => {
            clearTimeout(deadline);
            // The browser parent may close slightly before its helper processes. Because Chrome
            // was launched in its own process group, this final exact-group signal prevents test
            // helpers from surviving the fixture that created them.
            if (shutdownRequested) signalProcessGroup('SIGKILL');
            if (forceKillTimer) clearTimeout(forceKillTimer);
            if (failure) {
                reject(failure);
            } else if (!stdout.includes('</html>')) {
                reject(new Error(
                    `headless Chrome exited before emitting a complete DOM (code=${code}, signal=${signal})\n${stderr}`
                ));
            } else {
                resolve(stdout);
            }
        });
    });
}

async function runDocument(configuration) {
    await fs.access(chromeBinary);
    const profileDirectory = await fs.mkdtemp(path.join(os.tmpdir(), 'osrs-article-semantics-'));
    const html = documentHtml(configuration);
    const fixturePath = path.join(profileDirectory, 'fixture.html');
    await fs.writeFile(fixturePath, html, 'utf8');
    const url = pathToFileURL(fixturePath).href;
    try {
        const stdout = await dumpDomWithBoundedChrome([
            '--headless=new',
            '--disable-background-networking',
            '--disable-component-extensions-with-background-pages',
            '--disable-component-update',
            '--disable-default-apps',
            '--disable-extensions',
            '--disable-gpu',
            '--disable-sync',
            '--metrics-recording-only',
            '--no-default-browser-check',
            '--no-first-run',
            '--window-size=390,1200',
            '--user-data-dir=' + profileDirectory,
            '--dump-dom',
            url
        ]);
        const errorMatch = stdout.match(/data-osrs-test-error="([^"]+)"/);
        if (errorMatch) throw new Error(decodeURIComponent(errorMatch[1]));
        const resultMatch = stdout.match(/data-osrs-test-result="([^"]+)"/);
        assert.ok(resultMatch, 'headless Chrome emitted the semantic test result');
        return JSON.parse(decodeURIComponent(resultMatch[1]));
    } finally {
        await fs.rm(profileDirectory, { recursive: true, force: true });
    }
}

async function assertRecipeContract(collapsible, fixes, collapsibleTables) {
    const body = await read(
        'platforms/android/app/src/test/resources/article-semantic-contract/recipe-semantic-variants.html'
    );
    const state = await runDocument({
        body,
        scripts: [collapsible],
        styles: collapsibleTables + '\n' + fixes,
        evaluate: `() => {
            const wrapper = document.getElementById('semanticRecipe');
            const containers = Array.from(wrapper.querySelectorAll(':scope > .collapsible-recipe-table'));
            const negativeWrapper = document.getElementById('nonSemanticRecipeChildren');
            const beforeSecondPass = document.querySelectorAll('.collapsible-recipe-table').length;
            window.OSRSInitializeCollapsibleContent();
            return {
                transformsComplete: document.body.classList.contains('js-transforms-complete'),
                wrapperInsideDisclosure: !!wrapper.closest('.collapsible-container'),
                childTags: containers.map(element => element.tagName),
                roles: containers.map(container => container.dataset.osrsTableRole),
                labels: containers.map(container => container.querySelector('.collapsible-label')?.textContent || ''),
                captionVisibility: Array.from(wrapper.querySelectorAll(':scope > .collapsible-recipe-table caption')).map(caption => ({
                    hidden: caption.hidden,
                    marker: caption.dataset.osrsCaptionHiddenByDisclosure
                })),
                tableDepths: Array.from(wrapper.querySelectorAll('table')).map(table =>
                    Array.from(wrapper.querySelectorAll('.collapsible-recipe-table')).filter(container => container.contains(table)).length
                ),
                headerContracts: containers.map(container => {
                    const header = container.querySelector(':scope > .collapsible-header');
                    const content = container.querySelector(':scope > .collapsible-content');
                    return {
                        role: header?.getAttribute('role'),
                        tabIndex: header?.getAttribute('tabindex'),
                        controls: header?.getAttribute('aria-controls'),
                        contentId: content?.id,
                        labelledBy: content?.getAttribute('aria-labelledby'),
                        headerId: header?.id
                    };
                }),
                duplicateVisibleLabels: containers.filter(container => {
                    const label = (container.querySelector('.collapsible-label')?.textContent || '')
                        .replace(/\\s+\\(\\d+\\)$/, '').trim().toLowerCase();
                    return Array.from(container.querySelectorAll('caption, th')).some(element =>
                        !element.hidden && element.textContent.trim().toLowerCase() === label
                    );
                }).length,
                beforeSecondPass,
                afterSecondPass: document.querySelectorAll('.collapsible-recipe-table').length,
                excludedRecipeControls: negativeWrapper.querySelectorAll('.collapsible-recipe-table').length,
                presentationRole: negativeWrapper.querySelector('table[role="presentation"]')?.dataset.osrsTableRole || '',
                nestedRole: negativeWrapper.querySelector('aside table')?.dataset.osrsTableRole || '',
                closeFooterDisplays: containers.map(container =>
                    getComputedStyle(container.querySelector('.collapsible-close-footer')).display
                )
            };
        }`
    });

    assert.deepEqual(state.runtimeErrors, []);
    assert.equal(state.transformsComplete, true);
    assert.equal(state.wrapperInsideDisclosure, false, 'the recipe wrapper is not collapsed as one unit');
    assert.deepEqual(state.childTags, ['DIV', 'DIV', 'DIV', 'DIV', 'DIV']);
    assert.deepEqual(state.roles, [
        'recipe-materials',
        'recipe-requirements',
        'recipe-other',
        'recipe-other',
        'recipe-materials'
    ]);
    assert.deepEqual(state.labels, ['Materials', 'Requirements', 'By-products', 'Method / Notes', 'Materials (2)']);
    assert.ok(state.captionVisibility.every(caption => caption.hidden && caption.marker === 'true'));
    assert.deepEqual(state.tableDepths, [1, 1, 1, 1, 1]);
    assert.ok(state.headerContracts.every(contract =>
        contract.role === 'button' &&
        contract.tabIndex === '0' &&
        contract.controls === contract.contentId &&
        contract.labelledBy === contract.headerId
    ));
    assert.equal(state.duplicateVisibleLabels, 0, 'generated labels never duplicate visible authored labels');
    assert.equal(state.beforeSecondPass, 5);
    assert.equal(state.afterSecondPass, 5, 'a repeated transform is idempotent');
    assert.equal(state.excludedRecipeControls, 0, 'presentation, navbox, and nested tables are not recipe disclosures');
    assert.equal(state.presentationRole, '');
    assert.equal(state.nestedRole, '');
    assert.ok(
        state.closeFooterDisplays.every(display => display !== 'none'),
        'recipe disclosures keep the same close footer as other tables'
    );
}

async function assertDisclosureAccessibilityContract(collapsible, fixes, collapsibleTables) {
    const state = await runDocument({
        body: `
          <script>window.OSRS_TABLE_COLLAPSED = true;</script>
          <table class="wikitable" id="accessibilityTable">
            <caption>Accessible details</caption>
            <tbody><tr><td><a href="#target" id="nestedLink">Nested action</a></td></tr></tbody>
          </table>`,
        scripts: [collapsible],
        styles: collapsibleTables + '\n' + fixes,
        evaluate: `() => {
            const container = document.getElementById('accessibilityTable').closest('.collapsible-container');
            const header = container.querySelector(':scope > .collapsible-header');
            const content = container.querySelector(':scope > .collapsible-content');
            const nestedLink = document.getElementById('nestedLink');
            const closeButton = content.querySelector('.collapsible-close-button');
            const initial = {
                collapsed: container.classList.contains('collapsed'),
                ariaHidden: content.getAttribute('aria-hidden'),
                inertAttribute: content.hasAttribute('inert'),
                inertProperty: content.inert,
                closeInsideInertContent: content.contains(closeButton)
            };

            header.click();
            const expanded = {
                collapsed: container.classList.contains('collapsed'),
                ariaHidden: content.getAttribute('aria-hidden'),
                inertAttribute: content.hasAttribute('inert'),
                inertProperty: content.inert
            };

            nestedLink.focus();
            const nestedLinkReceivedFocus = document.activeElement === nestedLink;
            header.click();
            const collapsedAgain = {
                collapsed: container.classList.contains('collapsed'),
                ariaHidden: content.getAttribute('aria-hidden'),
                inertAttribute: content.hasAttribute('inert'),
                inertProperty: content.inert,
                focusReturnedToHeader: document.activeElement === header,
                expandedState: header.getAttribute('aria-expanded')
            };
            return { initial, expanded, nestedLinkReceivedFocus, collapsedAgain };
        }`
    });

    assert.deepEqual(state.runtimeErrors, []);
    assert.deepEqual(state.initial, {
        collapsed: true,
        ariaHidden: 'true',
        inertAttribute: true,
        inertProperty: true,
        closeInsideInertContent: true
    });
    assert.deepEqual(state.expanded, {
        collapsed: false,
        ariaHidden: null,
        inertAttribute: false,
        inertProperty: false
    });
    assert.equal(state.nestedLinkReceivedFocus, true, 'expanded interactive descendants accept focus');
    assert.deepEqual(state.collapsedAgain, {
        collapsed: true,
        ariaHidden: 'true',
        inertAttribute: true,
        inertProperty: true,
        focusReturnedToHeader: true,
        expandedState: 'false'
    });
}

async function assertLayoutAndOwnershipContract(
    polish,
    horizontalScroll,
    fixes,
    collapsibleTables,
    switchInfoboxStyles,
    androidAesthetics
) {
    const body = `
      <main class="mw-parser-output">
        <div class="collapsible-primary-infobox" id="primaryContainer">
          <div class="collapsible-content osrs-article-scroll-region osrs-local-scroll-surface" id="primaryContent">
            <table class="main-infobox infobox infobox-switch" id="primary" style="min-width:720px"><tbody>
              <tr><th>State</th><td>Viewport-fit primary content</td></tr>
              <tr><td colspan="2"><div class="infobox-buttons" id="stateControls"><span class="button" id="stateOne">State A</span><span class="button" id="stateTwo">State B</span></div></td></tr>
            </tbody></table>
            <div id="lateStaleProtected" style="width:100px;overflow-x:auto"><div style="width:400px"><span id="lateStaleProtectedCell">Protected late marker</span></div></div>
          </div>
        </div>
        <div class="collapsible-container" id="wideDisclosure" style="width:320px">
          <div class="collapsible-header"><span class="collapsible-label">Comparison</span></div>
          <div class="collapsible-content" id="wideSurface" style="width:320px;overflow-x:auto">
            <table class="wikitable" id="wide" style="min-width:760px"><tbody><tr><th>One</th><th>Two</th><th>Three</th></tr><tr><td>A</td><td>B</td><td>C</td></tr></tbody></table>
          </div>
        </div>
        <div id="combatStatsHost" style="width:320px">
          <table class="infobox infobox-bonuses" id="combatStats">
            <tbody>
              <tr><th class="infobox-subheader">Attack bonuses and combat attributes</th><th class="infobox-bonuses-image">State A</th><th class="infobox-bonuses-image">State B</th></tr>
              <tr><td>Ranged attack</td><td id="combatValue">+10</td><td>+12</td></tr>
              <tr><td>Magic defence</td><td>+3</td><td>+4</td></tr>
            </tbody>
          </table>
        </div>
        <div class="osrs-article-scroll-region osrs-local-scroll-surface osrs-scroll-generated-surface" id="prewrappedCombat" role="region" aria-label="Scrollable Combat stats table" tabindex="0" style="width:320px;overflow-x:auto">
          <div class="collapsible-container collapsible-infobox collapsible-bonuses-infobox" id="prewrappedCombatDisclosure" style="width:320px">
            <div class="collapsible-header"><span class="collapsible-label">Prewrapped Combat stats</span></div>
            <div class="collapsible-content" id="prewrappedCombatContent" style="width:320px;overflow-x:auto">
              <table class="infobox infobox-switch infobox-bonuses" id="prewrappedCombatTable" style="float:right">
                <tbody>
                  <tr><th class="infobox-subheader">Attack bonuses and combat attributes</th><th class="infobox-bonuses-image">State A</th><th class="infobox-bonuses-image">State B</th></tr>
                  <tr><td>Ranged attack</td><td id="prewrappedCombatValue">+10</td><td>+12</td></tr>
                  <tr><td>Magic defence</td><td>+3</td><td>+4</td></tr>
                </tbody>
              </table>
            </div>
          </div>
        </div>
        <div class="osrs-article-scroll-region osrs-local-scroll-surface" id="manualCombatViewport" role="region" aria-label="Scrollable Manual Combat stats table" tabindex="0" style="width:320px;overflow-x:auto">
          <div class="collapsible-container collapsible-infobox collapsible-bonuses-infobox" id="manualCombatDisclosure" style="width:320px">
            <div class="collapsible-header"><span class="collapsible-label">Manual Combat stats</span></div>
            <div class="collapsible-content" id="manualCombatContent" style="width:320px;overflow-x:auto">
              <table class="infobox infobox-switch infobox-bonuses" id="manualCombatTable" style="float:right">
                <tbody>
                  <tr><th class="infobox-subheader">Attack bonuses and combat attributes</th><th class="infobox-bonuses-image">State A</th><th class="infobox-bonuses-image">State B</th></tr>
                  <tr><td>Ranged attack</td><td id="manualCombatValue">+10</td><td>+12</td></tr>
                  <tr><td>Magic defence</td><td>+3</td><td>+4</td></tr>
                </tbody>
              </table>
            </div>
          </div>
        </div>
        <div class="recipe-table osrs-recipe-unit osrs-article-scroll-region osrs-local-scroll-surface" id="recipe"><table class="wikitable" id="recipeTable" style="min-width:760px"><tbody><tr><td>Recipe prose</td></tr></tbody></table></div>
        <div class="collapsible-map-table"><div class="collapsible-content osrs-article-scroll-region osrs-local-scroll-surface" id="mapContent"><table class="wikitable osrs-map-table" id="mapTable" style="min-width:760px"><tbody><tr><td><span class="mw-kartographer-map">Map</span></td></tr></tbody></table></div></div>
        <p id="prose">Ordinary article prose.</p>
      </main>
      <script>document.getElementById('wideSurface').scrollLeft = 120;</script>`;
    const state = await runDocument({
        body,
        scripts: [polish, horizontalScroll],
        styles: collapsibleTables + '\n' + switchInfoboxStyles + '\n' + fixes + '\n' + androidAesthetics,
        evaluate: `() => {
            window.OSRSApplyArticlePolish();
            const wideSurface = document.getElementById('wideSurface');
            const classify = target => window.OSRSArticlePolish.classifyTouchOwner(target);
            const classifyPoint = target => {
                const rect = target.getBoundingClientRect();
                return window.OSRSArticleGestureOwnership.classifyPoint(
                    rect.left + Math.min(Math.max(rect.width / 2, 1), 8),
                    rect.top + Math.min(Math.max(rect.height / 2, 1), 8)
                );
            };
            const initialScrollLeft = wideSurface.scrollLeft;
            wideSurface.scrollLeft = 73;
            window.OSRSApplyArticlePolish();
            const wideCell = document.querySelector('#wide td');
            const combatTable = document.getElementById('combatStats');
            const combatSurface = combatTable.parentElement;
            const combatSubheader = combatTable.querySelector('.infobox-subheader');
            const combatStateColumn = combatTable.querySelector('.infobox-bonuses-image');
            const stateControls = document.getElementById('stateControls');
            const stateOne = document.getElementById('stateOne');
            const stateTwo = document.getElementById('stateTwo');
            const lateStaleProtected = document.getElementById('lateStaleProtected');
            // Model a delayed app-owned marker appearing after semantic cleanup. The gesture
            // classifier must still defend protected primary/map/recipe roles structurally.
            lateStaleProtected.classList.add('osrs-article-scroll-region', 'osrs-local-scroll-surface');
            const prewrappedCombatContent = document.getElementById('prewrappedCombatContent');
            const prewrappedCombatTable = document.getElementById('prewrappedCombatTable');
            const prewrappedCombat = document.getElementById('prewrappedCombat');
            const prewrappedContentRect = prewrappedCombatContent.getBoundingClientRect();
            const prewrappedTableRect = prewrappedCombatTable.getBoundingClientRect();
            const manualCombatViewport = document.getElementById('manualCombatViewport');
            const manualCombatContent = document.getElementById('manualCombatContent');
            const manualCombatTable = document.getElementById('manualCombatTable');
            const manualContentRect = manualCombatContent.getBoundingClientRect();
            const manualTableRect = manualCombatTable.getBoundingClientRect();
            return {
                initialized: wideSurface.dataset.osrsScrollStartInitialized,
                initialScrollLeft,
                retainedScrollLeft: wideSurface.scrollLeft,
                actualOverflow: wideSurface.scrollWidth - wideSurface.clientWidth,
                wideOwned: classify(wideCell).isLocalOwner,
                headerOwned: classify(document.querySelector('#wideDisclosure .collapsible-header')).isLocalOwner,
                combatOwned: classify(document.getElementById('combatValue')).isLocalOwner,
                combatPointOwned: classifyPoint(document.getElementById('combatValue')).isLocalOwner,
                headerPointOwned: classifyPoint(document.querySelector('#wideDisclosure .collapsible-header')).isLocalOwner,
                combatLocalClass: combatSurface.classList.contains('osrs-local-scroll-surface'),
                combatInitialized: combatSurface.dataset.osrsScrollStartInitialized,
                combatScrollLeft: combatSurface.scrollLeft,
                combatOverflow: combatSurface.scrollWidth - combatSurface.clientWidth,
                combatTableWidth: combatTable.getBoundingClientRect().width,
                combatSubheaderWidth: combatSubheader.getBoundingClientRect().width,
                combatStateColumnWidth: combatStateColumn.getBoundingClientRect().width,
                prewrappedContentLocalClass: prewrappedCombatContent.classList.contains('osrs-local-scroll-surface'),
                prewrappedOuterLocalClass: prewrappedCombat.classList.contains('osrs-local-scroll-surface'),
                prewrappedOuterRegionClass: prewrappedCombat.classList.contains('osrs-article-scroll-region'),
                prewrappedOuterRole: prewrappedCombat.getAttribute('role'),
                prewrappedOuterTabIndex: prewrappedCombat.getAttribute('tabindex'),
                prewrappedContentOverflow: prewrappedCombatContent.scrollWidth - prewrappedCombatContent.clientWidth,
                prewrappedTableFloat: getComputedStyle(prewrappedCombatTable).float,
                prewrappedTableStartsInsideViewport: prewrappedTableRect.left >= prewrappedContentRect.left - 0.5,
                prewrappedContentOwned: classify(document.getElementById('prewrappedCombatValue')).isLocalOwner,
                prewrappedHeaderOwned: classify(document.querySelector('#prewrappedCombatDisclosure .collapsible-header')).isLocalOwner,
                manualOuterLocalClass: manualCombatViewport.classList.contains('osrs-local-scroll-surface'),
                manualOuterRegionClass: manualCombatViewport.classList.contains('osrs-article-scroll-region'),
                manualOuterDemotedClass: manualCombatViewport.classList.contains('osrs-demoted-scroll-surface'),
                manualOuterRole: manualCombatViewport.getAttribute('role'),
                manualOuterTabIndex: manualCombatViewport.getAttribute('tabindex'),
                manualContentLocalClass: manualCombatContent.classList.contains('osrs-local-scroll-surface'),
                manualContentOverflow: manualCombatContent.scrollWidth - manualCombatContent.clientWidth,
                manualOuterOverflowStyle: getComputedStyle(manualCombatViewport).overflowX,
                manualTableFloat: getComputedStyle(manualCombatTable).float,
                manualTableStartsInsideViewport: manualTableRect.left >= manualContentRect.left - 0.5,
                manualContentOwned: classify(document.getElementById('manualCombatValue')).isLocalOwner,
                manualHeaderOwned: classify(document.querySelector('#manualCombatDisclosure .collapsible-header')).isLocalOwner,
                stateControlGap: stateTwo.getBoundingClientRect().left - stateOne.getBoundingClientRect().right,
                stateControlMargin: parseFloat(getComputedStyle(stateOne).marginLeft),
                stateControlPadding: parseFloat(getComputedStyle(stateOne).paddingLeft),
                stateControlCssGap: parseFloat(getComputedStyle(stateControls).columnGap),
                primaryOwned: classify(document.querySelector('#primary td')).isLocalOwner,
                lateStalePrimaryOwned: classify(document.getElementById('lateStaleProtectedCell')).isLocalOwner,
                recipeOwned: classify(document.querySelector('#recipeTable td')).isLocalOwner,
                mapOwnedAsGenericScroll: classify(document.querySelector('#mapTable td')).isLocalOwner,
                mapPointOwnedByMap: classifyPoint(document.querySelector('.mw-kartographer-map')).isLocalOwner,
                proseOwned: classify(document.getElementById('prose')).isLocalOwner,
                prosePointOwned: classifyPoint(document.getElementById('prose')).isLocalOwner,
                primaryLocalClass: document.getElementById('primaryContent').classList.contains('osrs-local-scroll-surface'),
                recipeLocalClass: document.getElementById('recipeTable').closest('.osrs-local-scroll-surface') !== null,
                mapLocalClass: document.getElementById('mapContent').classList.contains('osrs-local-scroll-surface'),
                primaryWidth: document.getElementById('primary').getBoundingClientRect().width,
                primaryContainerWidth: document.getElementById('primaryContainer').getBoundingClientRect().width,
                cueCount: document.querySelectorAll('.osrs-scroll-cue-layer').length,
                cellPaddingInline: parseFloat(getComputedStyle(wideCell).paddingLeft)
            };
        }`
    });

    assert.deepEqual(state.runtimeErrors, []);
    assert.equal(state.initialized, 'true');
    assert.equal(state.initialScrollLeft, 0, 'new local scrollports initialize at logical start');
    assert.equal(state.retainedScrollLeft, 73, 'later polish passes preserve reader position');
    assert.ok(state.actualOverflow > 300);
    assert.equal(state.wideOwned, true);
    assert.equal(state.headerOwned, true);
    assert.ok(state.combatTableWidth < 550, 'legacy 556px bonuses width is reduced');
    assert.ok(state.combatSubheaderWidth < 250, 'legacy 250px label column is reduced');
    assert.ok(state.combatStateColumnWidth < 153, 'legacy 153px state column is reduced');
    if (state.combatOverflow > 20) {
        assert.equal(state.combatOwned, true, 'Combat-stat content retains real local ownership when it overflows');
        assert.equal(state.combatPointOwned, true, 'native point classifier preserves Combat-stat ownership');
        assert.equal(state.headerPointOwned, true, 'a wide disclosure header shares its local owner');
        assert.equal(state.combatLocalClass, true);
        assert.equal(state.combatInitialized, 'true');
        assert.equal(state.combatScrollLeft, 0, 'Combat-stat local scroll starts at logical left');
    } else {
        assert.equal(state.combatOwned, false, 'a bonuses table that now fits the viewport must not steal article swipes');
    }
    assert.equal(state.prewrappedContentLocalClass, true, 'a prewrapped disclosure promotes its content to the true scroll viewport');
    assert.equal(state.prewrappedOuterLocalClass, false, 'the obsolete generated outer viewport is demoted');
    assert.equal(state.prewrappedOuterRegionClass, false, 'the obsolete generated wrapper is not a nested physical scrollport');
    assert.equal(state.prewrappedOuterRole, null, 'the obsolete generated viewport is not exposed as a duplicate region');
    assert.equal(state.prewrappedOuterTabIndex, null, 'the obsolete generated viewport is not a duplicate focus stop');
    assert.equal(state.prewrappedTableFloat, 'none', 'the intrinsic table anchors at logical start instead of overflowing negative X');
    assert.equal(state.prewrappedTableStartsInsideViewport, true, 'the first Combat column begins inside the local viewport');
    if (state.prewrappedContentOverflow > 20) {
        assert.equal(state.prewrappedContentOwned, true, 'prewrapped Combat cells retain local gesture ownership');
        assert.equal(state.prewrappedHeaderOwned, true, 'the disclosure header shares its promoted local owner');
    }
    assert.equal(state.manualOuterLocalClass, false, 'a stale manual outer viewport is demoted');
    assert.equal(state.manualOuterRegionClass, false, 'a stale manual outer wrapper is not a nested physical scrollport');
    assert.equal(state.manualOuterDemotedClass, true, 'the retired wrapper has an explicit non-scroll layout state');
    assert.equal(state.manualOuterRole, null, 'a stale manual outer wrapper is not a duplicate region');
    assert.equal(state.manualOuterTabIndex, null, 'a stale manual outer wrapper is not a duplicate focus stop');
    assert.equal(state.manualOuterOverflowStyle, 'visible', 'the retired outer wrapper cannot remain a physical scrollport');
    assert.equal(state.manualTableFloat, 'none', 'the manual-wrapper table is anchored at logical start');
    assert.equal(state.manualTableStartsInsideViewport, true, 'the manual-wrapper first column begins inside its viewport');
    if (state.manualContentOverflow > 20) {
        assert.equal(state.manualContentLocalClass, true, 'the direct disclosure content is the sole local scrollport');
        assert.equal(state.manualContentOwned, true, 'manual-wrapper table cells resolve to the sole outer owner');
        assert.equal(state.manualHeaderOwned, true, 'manual-wrapper disclosure header resolves to the sole outer owner');
    }
    assert.ok(state.stateControlGap > 0 && state.stateControlGap <= 4.1, 'state buttons use one compact flex gap');
    assert.equal(state.stateControlMargin, 0, 'state buttons do not double the authored flex gap');
    assert.ok(state.stateControlPadding > 0 && state.stateControlPadding <= 8.1);
    assert.ok(state.stateControlCssGap > 0 && state.stateControlCssGap <= 4.1);
    assert.equal(state.primaryOwned, false);
    assert.equal(state.lateStalePrimaryOwned, false, 'a late stale marker cannot claim protected primary content');
    assert.equal(state.recipeOwned, false);
    assert.equal(state.mapOwnedAsGenericScroll, false);
    assert.equal(state.mapPointOwnedByMap, true, 'a map remains map-owned rather than generic-scroll-owned');
    assert.equal(state.proseOwned, false);
    assert.equal(state.prosePointOwned, false);
    assert.equal(state.primaryLocalClass, false);
    assert.equal(state.recipeLocalClass, false);
    assert.equal(state.mapLocalClass, false);
    assert.ok(state.primaryWidth <= state.primaryContainerWidth + 0.5);
    assert.equal(state.cueCount, 0);
    assert.ok(state.cellPaddingInline > 0 && state.cellPaddingInline < 8);
}

async function assertReaderTextHook(fixes) {
    const state = await runDocument({
        body: '<p id="readerText">Reader text scale hook</p>',
        scripts: [],
        styles: fixes + '\n:root { --osrs-article-user-text-scale: 1.15; --osrs-article-text-scale: 1.5; }',
        evaluate: `() => {
            const readerText = document.getElementById('readerText');
            const ordinaryFontSize = parseFloat(getComputedStyle(readerText).fontSize);
            document.body.classList.add('osrs-accessibility-reflow');
            const accessibilityFontSize = parseFloat(getComputedStyle(readerText).fontSize);
            return { ordinaryFontSize, accessibilityFontSize };
        }`
    });
    assert.deepEqual(state.runtimeErrors, []);
    assert.ok(Math.abs(state.ordinaryFontSize - 18.4) < 0.05, '1.15 reader scale applies normally');
    assert.ok(
        Math.abs(state.accessibilityFontSize - 27.6) < 0.05,
        '1.15 reader scale composes multiplicatively with 1.5 accessibility scale'
    );
}

async function main() {
    await assertAssetParity();
    process.stdout.write('asset parity/title-gate contract: PASS\n');
    const [
        collapsible,
        polish,
        horizontalScroll,
        fixes,
        collapsibleTables,
        switchInfoboxStyles,
        androidAesthetics,
        iosHorizontalScroll,
        iosFixes,
        iosCollapsibleTables,
        iosSwitchInfoboxStyles
    ] = await Promise.all([
        read('shared/js/collapsible_content.js'),
        read('shared/js/mobile_article_polish.js'),
        read('shared/js/horizontal_scroll_interceptor.js'),
        read('shared/css/fixes.css'),
        read('platforms/android/app/src/main/assets/web/collapsible_tables.css'),
        read('shared/js/switch_infobox_styles.css'),
        read('platforms/android/app/src/main/assets/styles/android-article-aesthetics.css'),
        read('platforms/ios/osrswiki/Assets/web/horizontal_scroll_interceptor.js'),
        read('platforms/ios/osrswiki/Assets/styles/fixes.css'),
        read('platforms/ios/osrswiki/Assets/web/collapsible_tables.css'),
        read('platforms/ios/osrswiki/Assets/web/switch_infobox_styles.css')
    ]);
    await assertRecipeContract(collapsible, fixes, collapsibleTables);
    process.stdout.write('recipe semantic runtime contract: PASS\n');
    await assertDisclosureAccessibilityContract(collapsible, fixes, collapsibleTables);
    process.stdout.write('disclosure accessibility runtime contract: PASS\n');
    await assertLayoutAndOwnershipContract(
        polish,
        horizontalScroll,
        fixes,
        collapsibleTables,
        switchInfoboxStyles,
        androidAesthetics
    );
    process.stdout.write('Android table geometry/ownership runtime contract: PASS\n');
    await assertLayoutAndOwnershipContract(
        polish,
        iosHorizontalScroll,
        iosFixes,
        iosCollapsibleTables,
        iosSwitchInfoboxStyles,
        ''
    );
    process.stdout.write('iOS table geometry/ownership runtime contract: PASS\n');
    await assertReaderTextHook(fixes);
    process.stdout.write('shared article semantic/CSS self-test: PASS\n');
}

main().catch(error => {
    console.error(error);
    process.exitCode = 1;
});
