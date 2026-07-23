const EXISTING_IOS_COLLAPSE_SELECTORS = new Set([
  'infobox',
  'wikitable',
  'navbox',
]);

const LAYOUT_CLASS_TOKENS = new Set([
  'navbar',
  'plainlinks',
  'hlist',
  'metadata',
  'noprint',
  'nomobile',
  'mw-editsection',
  'ambox',
  'mbox',
  'messagebox',
  'toc',
  'vertical-navbox',
]);

const QUEST_OVERVIEW_CLASS_PATTERNS = [
  /quest.*details/,
  /quest.*overview/,
  /guide.*overview/,
  /quick.*guide/,
  /diary.*details/,
  /diary.*overview/,
  /task.*details/,
  /task.*overview/,
  /league.*details/,
  /league.*overview/,
  /minigame.*details/,
  /minigame.*overview/,
  /boss.*details/,
  /boss.*overview/,
  /strategy.*overview/,
];

const OVERVIEW_LABEL_PATTERNS = [
  /\bstart point\b/,
  /\bofficial difficulty\b/,
  /\bofficial length\b/,
  /\bdescription\b/,
  /\brequirements?\b/,
  /\bitems required\b/,
  /\brecommended\b/,
  /\benemies to defeat\b/,
  /\bcombat level\b/,
  /\bquest points?\b/,
  /\bironman concerns\b/,
  /\bexperience gained\b/,
  /\brewards?\b/,
  /\blocation\b/,
  /\bcompletion time\b/,
];

const CONTEXT_HEADING_PATTERNS = [
  /\bdetails\b/,
  /\boverview\b/,
  /\bguide overview\b/,
  /\bquick guide\b/,
  /\bwalkthrough\b/,
  /\bstrategy\b/,
  /\brequirements?\b/,
];

function lower(value) {
  return String(value || '').toLowerCase();
}

function classTokens(table) {
  return Array.isArray(table.classes) ? table.classes.map(lower).filter(Boolean) : [];
}

function hasExistingIosCollapseClass(table) {
  return classTokens(table).some((token) => EXISTING_IOS_COLLAPSE_SELECTORS.has(token));
}

function hasLayoutClass(table) {
  return classTokens(table).some((token) => LAYOUT_CLASS_TOKENS.has(token));
}

function hasClassPattern(table, patterns) {
  const className = classTokens(table).join(' ');
  return patterns.some((pattern) => pattern.test(className));
}

function textMatches(text, patterns) {
  const normalized = lower(text);
  return patterns.filter((pattern) => pattern.test(normalized)).length;
}

function isWrapped(table) {
  return table.insideCollapsible === true || table.collapsibleState === 'collapsed' || table.collapsibleState === 'expanded';
}

function tableArea(table) {
  const width = Number(table.width) || 0;
  const height = Number(table.height) || 0;
  return width * height;
}

function isTooSmallToCollapse(table) {
  const rows = Number(table.rows) || 0;
  const columns = Number(table.columns) || 0;
  const width = Number(table.width) || 0;
  const height = Number(table.height) || 0;
  return rows <= 2 && columns <= 3 && width < 260 && height < 120;
}

function isNestedStructuralTable(table) {
  if (table.hasAncestorTable && !table.hasOwnCaption && !hasClassPattern(table, QUEST_OVERVIEW_CLASS_PATTERNS)) {
    return true;
  }

  const selector = lower(table.selector);
  return selector.includes('.navbar') || selector.includes('.navbox') || selector.includes('.infobox');
}

function severityFor(table, rationale) {
  const rows = Number(table.rows) || 0;
  const height = Number(table.height) || 0;

  if (rationale === 'questdetails overview table') {
    return 'P1';
  }

  if (rationale === 'explicit mw-collapsible table left untransformed') {
    return rows >= 8 || height >= 500 ? 'P1' : 'P2';
  }

  if (height >= 900 || rows >= 16) {
    return 'P2';
  }

  return 'P3';
}

function expectedRationaleFor(page, table) {
  if (isWrapped(table)) {
    return null;
  }

  if (hasLayoutClass(table) || isTooSmallToCollapse(table) || isNestedStructuralTable(table)) {
    return null;
  }

  const tokens = classTokens(table);
  const text = [table.caption, table.nearestHeading, table.textSample].filter(Boolean).join(' ');
  const labelMatchCount = textMatches(text, OVERVIEW_LABEL_PATTERNS);
  const headingMatchCount = textMatches(table.nearestHeading || '', CONTEXT_HEADING_PATTERNS);
  const rows = Number(table.rows) || 0;
  const columns = Number(table.columns) || 0;
  const height = Number(table.height) || 0;
  const area = tableArea(table);

  if (tokens.includes('questdetails')) {
    return 'questdetails overview table';
  }

  if (tokens.includes('mw-collapsible') || tokens.includes('mw-collapsed')) {
    return 'explicit mw-collapsible table left untransformed';
  }

  if (hasClassPattern(table, QUEST_OVERVIEW_CLASS_PATTERNS) && rows >= 4 && columns <= 4) {
    return 'semantic overview/details table class';
  }

  if (headingMatchCount > 0 && labelMatchCount >= 3 && rows >= 4 && columns <= 4 && height >= 220) {
    return 'key-value overview table under guide/details heading';
  }

  if (!hasExistingIosCollapseClass(table) &&
      labelMatchCount >= 4 &&
      rows >= 6 &&
      columns <= 4 &&
      (height >= 360 || area >= 120000)) {
    return 'large semantic overview table missed by iOS selectors';
  }

  if (!hasExistingIosCollapseClass(table) &&
      rows >= 12 &&
      columns >= 2 &&
      area >= 220000 &&
      (table.hasOwnCaption || headingMatchCount > 0)) {
    return 'large captioned table missed by iOS selectors';
  }

  return null;
}

function tablePath(table) {
  if (table.domPath) return table.domPath;
  if (table.selector) return table.selector;
  return 'table';
}

export function analyzeRenderedTables(page) {
  return (page.tables || []).flatMap((table, index) => {
    const rationale = expectedRationaleFor(page, table);
    if (!rationale) return [];

    const severity = severityFor(table, rationale);
    return [{
      findingId: table.findingId || null,
      title: page.title,
      url: page.url,
      tableIndex: table.tableIndex ?? index,
      selector: table.selector || 'table',
      domPath: tablePath(table),
      classes: table.classes || [],
      nearbyHeading: table.nearestHeading || '',
      caption: table.caption || '',
      dimensions: {
        width: Number(table.width) || 0,
        height: Number(table.height) || 0,
      },
      rowCount: Number(table.rows) || 0,
      columnCount: Number(table.columns) || 0,
      existingCollapseState: table.collapsibleState || 'none',
      insideCollapsible: table.insideCollapsible === true,
      expectedCollapseRationale: rationale,
      severity,
      actionable: severity !== 'P3' || rationale !== 'large captioned table missed by iOS selectors',
      textSample: table.textSample || '',
    }];
  });
}

export const detectionCriteria = {
  existingIosCollapseSelectors: Array.from(EXISTING_IOS_COLLAPSE_SELECTORS),
  ignoredLayoutClassTokens: Array.from(LAYOUT_CLASS_TOKENS),
  questOverviewClassPatterns: QUEST_OVERVIEW_CLASS_PATTERNS.map(String),
  overviewLabelPatterns: OVERVIEW_LABEL_PATTERNS.map(String),
  contextHeadingPatterns: CONTEXT_HEADING_PATTERNS.map(String),
  description: [
    'Scan post-transform rendered DOM/layout, not raw API HTML alone.',
    'Do not flag tables already inside .collapsible-container.',
    'Do not flag known layout/navigation/messagebox micro-tables.',
    'Flag questdetails and related overview/details tables that iOS selectors miss.',
    'Flag explicit mw-collapsible tables left untransformed.',
    'Flag large semantic key-value overview tables under details/overview/guide headings.',
  ],
};
