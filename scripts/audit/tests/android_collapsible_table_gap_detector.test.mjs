import test from 'node:test';
import assert from 'node:assert/strict';

import {
  classifyTableGap,
  detectionCriteriaSummary,
  normalizeClassSignature,
} from '../android_collapsible_table_gap_detector.mjs';

function baseTable(overrides = {}) {
  return {
    title: 'The Blood Moon Rises/Quick guide',
    tableIndex: 0,
    selectorPath: 'body > section.mf-section-1 > table.questdetails',
    className: 'questdetails',
    role: '',
    visible: true,
    closestCollapsible: null,
    closestTableAncestor: false,
    excludedAncestor: '',
    rowCount: 8,
    columnCount: 2,
    headerCellCount: 8,
    textLength: 1600,
    width: 358,
    height: 620,
    scrollWidth: 358,
    viewportWidth: 390,
    top: 220,
    caption: '',
    nearbyHeading: 'Details',
    firstHeaderText: 'Start point',
    firstDataText: 'Talk to Sarius Guile in the Icyene Graveyard.',
    headings: ['Start point', 'Official difficulty', 'Official length'],
    ...overrides,
  };
}

test('classifies the Blood Moon questdetails overview as a high severity actionable gap', () => {
  const result = classifyTableGap(baseTable());

  assert.equal(result.isCandidate, true);
  assert.equal(result.severity, 'high');
  assert.equal(result.actionable, true);
  assert.match(result.expectedCollapseRationale, /questdetails/);
  assert.match(result.expectedCollapseRationale, /Details/);
});

test('ignores messagebox presentation tables', () => {
  const result = classifyTableGap(baseTable({
    selectorPath: 'body > section.mf-section-0 > table.messagebox',
    className: 'messagebox',
    role: 'presentation',
    rowCount: 1,
    columnCount: 2,
    headerCellCount: 0,
    textLength: 140,
    nearbyHeading: '',
    firstHeaderText: '',
  }));

  assert.equal(result.isCandidate, false);
  assert.equal(result.reason, 'excluded-support-table');
});

test('ignores tables already inside app collapsible containers', () => {
  const result = classifyTableGap(baseTable({
    className: 'wikitable sortable',
    selectorPath: 'body > div.collapsible-container > div.collapsible-content > table.wikitable',
    closestCollapsible: {
      collapsed: true,
      label: 'Fight overview',
      labelKind: 'secondary',
    },
  }));

  assert.equal(result.isCandidate, false);
  assert.equal(result.reason, 'already-collapsible');
});

test('ignores nested helper tables such as tooltip and navbox subgroup internals', () => {
  const result = classifyTableGap(baseTable({
    selectorPath: 'li > div.js-tooltip-wrapper > div.js-tooltip-text > table',
    className: '',
    closestTableAncestor: false,
    excludedAncestor: '.js-tooltip-wrapper',
    rowCount: 1,
    columnCount: 2,
    textLength: 32,
    nearbyHeading: 'Walkthrough',
  }));

  assert.equal(result.isCandidate, false);
  assert.equal(result.reason, 'excluded-support-table');
});

test('flags large unwrapped semantic data tables even without questdetails class', () => {
  const result = classifyTableGap(baseTable({
    title: 'Example table page',
    selectorPath: 'body > section.mf-section-2 > table.mw-datatable',
    className: 'mw-datatable sortable',
    rowCount: 24,
    columnCount: 4,
    headerCellCount: 4,
    textLength: 4200,
    width: 520,
    scrollWidth: 720,
    viewportWidth: 390,
    nearbyHeading: 'Rewards',
    firstHeaderText: 'Item',
  }));

  assert.equal(result.isCandidate, true);
  assert.equal(result.severity, 'medium');
  assert.equal(result.actionable, true);
});

test('normalizes noisy class signatures for aggregation', () => {
  assert.equal(
    normalizeClassSignature('sortable questdetails mw-collapsible extra-123'),
    'extra-123 mw-collapsible questdetails sortable',
  );
});

test('criteria summary mentions rendered DOM and explicit exclusions', () => {
  const summary = detectionCriteriaSummary();

  assert.match(summary, /rendered DOM/);
  assert.match(summary, /questdetails/);
  assert.match(summary, /messagebox/);
  assert.match(summary, /already inside/);
});
