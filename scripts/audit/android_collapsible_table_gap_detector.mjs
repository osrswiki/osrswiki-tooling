const SUPPORT_TABLE_CLASS_RE = /\b(?:messagebox|ambox|mbox|notebox|ombox|cmbox|tmbox|fmbox|navbox-subgroup|metadata|nowraplinks|gallery|toc|vertical-navbox)\b/i;
const SUPPORT_ANCESTOR_RE = /\.(?:messagebox|ambox|mbox|notebox|navbox|navbox-subgroup|infobox|gallery|toc|mw-editsection|js-tooltip-wrapper|hidden|metadata)\b/i;
const SEMANTIC_TABLE_CLASS_RE = /\b(?:questdetails|wikitable|mw-datatable|mw_metadata|lighttable|sortable|item-drops|dropstable|shop|ge-table|combat-styles|infotable-bonuses|mmg-table|tbrl-tasks)\b/i;

export function normalizeClassSignature(className = '') {
  return String(className)
    .split(/\s+/)
    .map((part) => part.trim())
    .filter(Boolean)
    .sort((a, b) => a.localeCompare(b))
    .join(' ');
}

function lower(value) {
  return String(value || '').toLowerCase();
}

function isSupportTable(record) {
  const className = String(record.className || '');
  if (record.role === 'presentation' && SUPPORT_TABLE_CLASS_RE.test(className)) {
    return true;
  }
  if (SUPPORT_TABLE_CLASS_RE.test(className)) {
    return true;
  }
  if (record.excludedAncestor && SUPPORT_ANCESTOR_RE.test(record.excludedAncestor)) {
    return true;
  }
  if (record.closestTableAncestor) {
    return true;
  }
  return false;
}

function tableHasSemanticShape(record) {
  const rows = Number(record.rowCount || 0);
  const columns = Number(record.columnCount || 0);
  const headers = Number(record.headerCellCount || 0);
  const textLength = Number(record.textLength || 0);
  const className = String(record.className || '');
  const hasRecognizedClass = SEMANTIC_TABLE_CLASS_RE.test(className);
  const hasHeadingContext = !!String(record.caption || record.nearbyHeading || record.firstHeaderText || '').trim();
  const isWide = Number(record.width || 0) >= Math.min(320, Number(record.viewportWidth || 390) * 0.78);
  const overflowsHorizontally = Number(record.scrollWidth || 0) > Number(record.viewportWidth || 390) + 12;

  if (className.split(/\s+/).includes('questdetails')) {
    return true;
  }

  return rows >= 3 &&
    columns >= 2 &&
    textLength >= 120 &&
    (headers > 0 || hasHeadingContext) &&
    (hasRecognizedClass || isWide || overflowsHorizontally);
}

function severityFor(record) {
  const className = lower(record.className);
  const heading = lower([record.caption, record.nearbyHeading, record.firstHeaderText].join(' '));
  const rows = Number(record.rowCount || 0);
  const height = Number(record.height || 0);
  const top = Number(record.top || 0);
  const viewportWidth = Number(record.viewportWidth || 390);
  const width = Number(record.width || 0);
  const scrollWidth = Number(record.scrollWidth || 0);

  if (className.split(/\s+/).includes('questdetails')) {
    return 'high';
  }
  if (top < 1600 && rows >= 5 && width >= viewportWidth * 0.85 && /(details|overview|requirements)/.test(heading)) {
    return 'high';
  }
  if (/(details|overview|requirements|fight|rewards|drops|tasks|training|calculator)/.test(heading) &&
      (rows >= 8 || height >= 420 || scrollWidth > viewportWidth + 24)) {
    return 'medium';
  }
  if (rows >= 12 || height >= 520 || scrollWidth > viewportWidth + 24) {
    return 'medium';
  }
  return 'low';
}

function actionableFor(record, severity) {
  const className = lower(record.className);
  if (className.split(/\s+/).includes('questdetails')) {
    return true;
  }
  if (SEMANTIC_TABLE_CLASS_RE.test(className) && severity !== 'low') {
    return true;
  }
  return false;
}

function rationaleFor(record, severity, actionable) {
  const pieces = [];
  const classSignature = normalizeClassSignature(record.className);
  if (classSignature) {
    pieces.push(`class signature \`${classSignature}\``);
  }
  if (record.nearbyHeading) {
    pieces.push(`near heading "${record.nearbyHeading}"`);
  }
  if (record.caption) {
    pieces.push(`caption "${record.caption}"`);
  }
  pieces.push(`${record.rowCount || 0} rows x ${record.columnCount || 0} columns`);
  pieces.push(`rendered ${Math.round(record.width || 0)}x${Math.round(record.height || 0)} px`);
  const policy = actionable
    ? 'matches a reusable semantic table selector'
    : 'needs fixer review before adding a broad selector';
  return `Unwrapped rendered table ${pieces.join(', ')}; existing Android collapse policy wraps comparable article tables, so this is ${severity} severity and ${policy}.`;
}

export function classifyTableGap(record) {
  if (!record || record.visible === false) {
    return { isCandidate: false, reason: 'not-visible' };
  }
  if (record.closestCollapsible) {
    return { isCandidate: false, reason: 'already-collapsible' };
  }
  if (isSupportTable(record)) {
    return { isCandidate: false, reason: 'excluded-support-table' };
  }
  if (!tableHasSemanticShape(record)) {
    return { isCandidate: false, reason: 'below-semantic-threshold' };
  }

  const severity = severityFor(record);
  const actionable = actionableFor(record, severity);
  return {
    isCandidate: true,
    severity,
    actionable,
    signature: normalizeClassSignature(record.className) || 'unclassed-table',
    expectedCollapseRationale: rationaleFor(record, severity, actionable),
  };
}

export function detectionCriteriaSummary() {
  return [
    'Scan the rendered DOM after Android app WebView transformations complete (`body.js-transforms-complete`), not raw API HTML.',
    'A finding must be a visible `table` that is not already inside `.collapsible-container` and is not nested inside another table.',
    'Exclude support/layout tables: `messagebox`, `ambox`/`mbox`/`notebox`, navbox internals, infobox internals, galleries, TOC/edit UI, hidden tooltip tables, and `role="presentation"` message tables.',
    'Flag reusable semantic article tables when they have a data-table shape: at least 3 rows, at least 2 columns, meaningful header/caption/nearby heading text, enough text, and either a known wiki table class or rendered width/overflow comparable to tables Android already collapses.',
    '`table.questdetails` is high severity and actionable because shared CSS styles it as a full-width wiki details table and the Blood Moon quick-guide trigger is a visible Details/overview table outside the current Android selectors.',
  ].join(' ');
}
