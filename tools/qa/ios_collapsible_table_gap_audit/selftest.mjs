import assert from 'node:assert/strict';
import { analyzeRenderedTables } from './audit_logic.mjs';

const bloodMoonFixture = {
  title: 'The Blood Moon Rises/Quick guide',
  url: 'https://oldschool.runescape.wiki/w/The_Blood_Moon_Rises/Quick_guide',
  tables: [{
    selector: 'table.questdetails',
    classes: ['questdetails'],
    caption: '',
    nearestHeading: 'Details',
    rows: 14,
    columns: 2,
    width: 343,
    height: 1280,
    textSample: 'Start point Official difficulty Official length Description Requirements',
    insideCollapsible: false,
    collapsibleState: 'none',
    firstWikitableIndex: null,
  }],
};

const bloodMoonFindings = analyzeRenderedTables(bloodMoonFixture);
assert.equal(bloodMoonFindings.length, 1);
assert.equal(bloodMoonFindings[0].expectedCollapseRationale, 'questdetails overview table');
assert.equal(bloodMoonFindings[0].severity, 'P1');
assert.equal(bloodMoonFindings[0].actionable, true);

const primaryWikitableFixture = {
  title: 'Experience',
  url: 'https://oldschool.runescape.wiki/w/Experience',
  tables: [{
    selector: 'table.wikitable',
    classes: ['wikitable'],
    caption: 'Experience table',
    nearestHeading: '',
    rows: 5,
    columns: 3,
    width: 343,
    height: 300,
    textSample: 'Level Experience Difference',
    insideCollapsible: true,
    collapsibleState: 'expanded',
    firstWikitableIndex: 0,
  }],
};

assert.equal(analyzeRenderedTables(primaryWikitableFixture).length, 0);

const navboxFixture = {
  title: 'Doom of Mokhaiotl',
  url: 'https://oldschool.runescape.wiki/w/Doom_of_Mokhaiotl',
  tables: [{
    selector: 'table.navbox',
    classes: ['navbox', 'mw-collapsible', 'mw-collapsed'],
    caption: '',
    nearestHeading: '',
    rows: 9,
    columns: 2,
    width: 343,
    height: 700,
    textSample: 'Demons Standard demons Slayer demons',
    insideCollapsible: true,
    collapsibleState: 'collapsed',
    firstWikitableIndex: null,
  }],
};

assert.equal(analyzeRenderedTables(navboxFixture).length, 0);

const smallLayoutFixture = {
  title: 'Tiny layout table',
  url: 'https://oldschool.runescape.wiki/w/Tiny_layout_table',
  tables: [{
    selector: 'table.plainlinks',
    classes: ['plainlinks'],
    caption: '',
    nearestHeading: '',
    rows: 1,
    columns: 2,
    width: 190,
    height: 44,
    textSample: 'v t e',
    insideCollapsible: false,
    collapsibleState: 'none',
    firstWikitableIndex: null,
  }],
};

assert.equal(analyzeRenderedTables(smallLayoutFixture).length, 0);

console.log('ios_collapsible_table_gap_audit self-test passed');
