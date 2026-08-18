import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

import {
  loadNativeRealmCatalog,
  nativeSelectorNavigation,
  selectorRowLocalization,
  selectorScrollbarVectorToThumbTop,
  semanticScrollbarAtPlannedPosition,
  semanticScrollbarLandingAccepted,
} from "../src/native-realm-catalog.mjs";
import {
  classifyCapture,
  proveSemanticMapReadiness,
  semanticCoverageReadinessFromClassification,
} from "../src/perception.mjs";
import {
  coverageReferenceChunks,
  coverageReferenceDelta,
  planNativeRealmCoverage,
  queueItemsForCoveragePlan,
} from "../src/native-realm-coverage.mjs";
import {
  applyNativeRealmLedgerEvent,
  createNativeRealmCoverageLedger,
  nextNativeRealmLedgerItem,
  verifyNativeRealmCoverageLedger,
} from "../src/native-realm-ledger.mjs";
import {
  isNativeRealmCarrySourceItemID,
  nativeRealmCarryCaptureAccepted,
  nativeRealmCoverageCropMatches,
  nativeRealmWorkKey,
} from "../src/native-realm-carry-forward.mjs";
import { finalizeQueueManifest, validateQueueManifest } from "../src/protocol.mjs";
import { loadSemanticCalibrationRegistry } from "../src/semantic-profile.mjs";

const workerRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const digestA = "a".repeat(64);
const digestB = "b".repeat(64);
const digestC = "c".repeat(64);

test("native selector catalog contains only the 47 reviewed live entries", () => {
  const catalog = loadNativeRealmCatalog();
  assert.equal(catalog.entries.length, 47);
  assert.equal(catalog.validation.accepted_surface_count, 1);
  assert.equal(catalog.validation.accepted_realm_count, 46);
  assert.equal(catalog.validation.excluded_other_maps_count, 1047);
  assert.deepEqual(catalog.validation.excluded_native_selector_ids, [
    "cache-world-map:ghorrock-prison",
    "cache-world-map:lassar-undercity",
    "cache-world-map:tutorial-2",
  ]);
  assert.equal(catalog.entries[0].id, "surface-gielinor");
  assert.equal(catalog.entries.at(-1).id, "cache-world-map:zanaris");
  assert.deepEqual(
    catalog.entries.find((entry) => entry.id === "cache-world-map:asgarnia-ice-dungeon")
      ?.reopen_center,
    { x: 93, y: 96 }
  );
  assert.deepEqual(
    catalog.entries.find((entry) => entry.id === "cache-world-map:taverley-underground")
      ?.reopen_center,
    { x: 109, y: 225 }
  );
  assert.deepEqual(
    catalog.entries.find((entry) => entry.id === "cache-world-map:varlamore-underground")
      ?.reopen_center,
    { x: 416, y: 129 }
  );
  assert.equal(catalog.entries.some((entry) => entry.id === "cache-world-map:lassar-undercity"), false);
  assert.equal(new Set(catalog.entries.map((entry) => entry.id)).size, 47);
  assert.equal(new Set(catalog.entries.map((entry) => entry.label)).size, 47);
  assert.equal(
    catalog.entries.some((entry) =>
      entry.group === "other_maps"
        || entry.id.startsWith("other-map-")
        || entry.id.startsWith("cache-special-region:")
    ),
    false
  );
});

test("native selector navigation covers visible, bounded position, and bottom strategies", () => {
  const catalog = loadNativeRealmCatalog();
  const visible = nativeSelectorNavigation(catalog.entries[2].label, scrollbarProof(543));
  assert.equal(visible.required, false);
  assert.equal(visible.visible_row_index, 2);
  assert.equal(selectorRowLocalization(catalog.entries[2].label, scrollbarProof(543)).visible_row_index, 2);

  const positioned = nativeSelectorNavigation(catalog.entries[20].label, scrollbarProof(543));
  assert.equal(positioned.required, true);
  assert.equal(positioned.anchor, "position");
  assert.equal(positioned.maximum_drags, 1);
  assert.equal(positioned.target_thumb_top, 570);
  assert.equal(
    selectorRowLocalization(catalog.entries[20].label, scrollbarProof(positioned.target_thumb_top)).visible_row_index,
    4
  );
  assert.equal(semanticScrollbarAtPlannedPosition(scrollbarProof(567), positioned), false);
  assert.equal(semanticScrollbarAtPlannedPosition(scrollbarProof(positioned.target_thumb_top), positioned), true);
  assert.equal(semanticScrollbarAtPlannedPosition(scrollbarProof(575), positioned), false);
  assert.equal(semanticScrollbarAtPlannedPosition(scrollbarProof(576), positioned), false);
  assert.equal(semanticScrollbarAtPlannedPosition(scrollbarProof(577), positioned), false);
  assert.equal(semanticScrollbarAtPlannedPosition(scrollbarProof(580), positioned), false);
  assert.equal(semanticScrollbarAtPlannedPosition(scrollbarProof(581), positioned), false);

  const snapped = nativeSelectorNavigation(catalog.entries[8].label, scrollbarProof(543));
  assert.equal(snapped.visible_top_index, 4);
  assert.equal(snapped.visible_row_index, 4);
  assert.deepEqual(snapped.target_thumb_top_bounds, { minimum: 549, maximum: 550 });
  assert.equal(semanticScrollbarAtPlannedPosition(scrollbarProof(544), snapped), false);
  assert.equal(semanticScrollbarAtPlannedPosition(scrollbarProof(550), snapped), true);
  assert.equal(semanticScrollbarAtPlannedPosition(scrollbarProof(551), snapped), false);
  assert.equal(semanticScrollbarAtPlannedPosition(scrollbarProof(552), snapped), false);
  assert.equal(semanticScrollbarAtPlannedPosition(scrollbarProof(553), snapped), false);
  assert.equal(semanticScrollbarAtPlannedPosition(scrollbarProof(557), snapped), false);
  assert.equal(semanticScrollbarAtPlannedPosition(scrollbarProof(558), snapped), false);
  assert.equal(semanticScrollbarAtPlannedPosition(scrollbarProof(559), snapped), false);
  assert.equal(semanticScrollbarAtPlannedPosition(scrollbarProof(560), snapped), false);

  const feldip = nativeSelectorNavigation(catalog.entries[9].label, scrollbarProof(543));
  assert.equal(feldip.visible_top_index, 6);
  assert.equal(feldip.visible_row_index, 3);
  assert.equal(feldip.target_thumb_top, 552);
  assert.deepEqual(feldip.target_thumb_top_bounds, { minimum: 552, maximum: 553 });
  assert.equal(semanticScrollbarAtPlannedPosition(scrollbarProof(545), feldip), false);
  assert.equal(semanticScrollbarAtPlannedPosition(scrollbarProof(552), feldip), true);
  assert.equal(semanticScrollbarAtPlannedPosition(scrollbarProof(553), feldip), true);
  assert.equal(semanticScrollbarAtPlannedPosition(scrollbarProof(554), feldip), false);
  assert.equal(semanticScrollbarAtPlannedPosition(scrollbarProof(559), feldip), false);
  assert.equal(semanticScrollbarAtPlannedPosition(scrollbarProof(561), feldip), false);

  const bottom = nativeSelectorNavigation(catalog.entries[46].label, scrollbarProof(543));
  assert.equal(bottom.required, true);
  assert.equal(bottom.anchor, "bottom");
  assert.equal(bottom.target_thumb_top, 613);
  assert.deepEqual(bottom.target_thumb_top_bounds, { minimum: 613, maximum: 613 });
  assert.equal(semanticScrollbarAtPlannedPosition(scrollbarProof(612), bottom), false);
  assert.equal(semanticScrollbarAtPlannedPosition(scrollbarProof(613), bottom), true);
  assert.equal(selectorRowLocalization(catalog.entries[46].label, scrollbarProof(613)).visible_row_index, 7);
});

test("native selector accepts an intermediate landing only when the requested row is pixel-proven visible", () => {
  const catalog = loadNativeRealmCatalog();
  const kharidian = catalog.entries.find((entry) => entry.label === "Kharidian Desert Underground");
  assert.ok(kharidian);

  const navigation = nativeSelectorNavigation(kharidian.label, scrollbarProof(543));
  assert.equal(navigation.required, true);
  assert.equal(navigation.anchor, "position");
  assert.deepEqual(navigation.target_thumb_top_bounds, { minimum: 561, maximum: 562 });
  assert.equal(semanticScrollbarAtPlannedPosition(scrollbarProof(560), navigation), false);
  assert.equal(semanticScrollbarLandingAccepted(scrollbarProof(560), navigation, kharidian.label), true);
  assert.equal(semanticScrollbarLandingAccepted(scrollbarProof(559), navigation, kharidian.label), true);
  assert.equal(semanticScrollbarLandingAccepted(scrollbarProof(563), navigation, kharidian.label), true);
  assert.equal(semanticScrollbarLandingAccepted(scrollbarProof(543), navigation, kharidian.label), false);
  assert.equal(semanticScrollbarLandingAccepted(scrollbarProof(570), navigation, kharidian.label), false);

  const mole = nativeSelectorNavigation("Mole Hole", scrollbarProof(543));
  assert.deepEqual(mole.target_thumb_top_bounds, { minimum: 572, maximum: 573 });
  assert.equal(semanticScrollbarAtPlannedPosition(scrollbarProof(569), mole), false);
  assert.equal(semanticScrollbarLandingAccepted(scrollbarProof(569), mole, "Mole Hole"), true);
  assert.equal(semanticScrollbarLandingAccepted(scrollbarProof(561), mole, "Mole Hole"), false);

  const bottom = nativeSelectorNavigation(catalog.entries[46].label, scrollbarProof(543));
  assert.equal(bottom.anchor, "bottom");
  assert.equal(semanticScrollbarLandingAccepted(scrollbarProof(612), bottom, catalog.entries[46].label), false);
});

test("native selector preserves the live partial-row pixel offset at intermediate thumb positions", () => {
  const catalog = loadNativeRealmCatalog();
  const liveStates = [
    { index: 6, top: 552, expectedTop: 6, expectedRow: 0 },
    { index: 8, top: 553, expectedTop: 6, expectedRow: 2 },
    { index: 7, top: 554, expectedTop: 7, expectedRow: 0 },
    { index: 9, top: 557, expectedTop: 8, expectedRow: 1 },
    { index: 11, top: 557, expectedTop: 8, expectedRow: 3 },
    { index: 13, top: 557, expectedTop: 8, expectedRow: 5 },
    { index: 14, top: 562, expectedTop: 11, expectedRow: 3 },
  ];
  for (const state of liveStates) {
    const localization = selectorRowLocalization(
      catalog.entries[state.index].label,
      scrollbarProof(state.top)
    );
    assert.equal(localization.visible_top_index, state.expectedTop);
    assert.equal(localization.visible_row_index, state.expectedRow);
    assert.equal(localization.visible_top_index + localization.visible_row_index, state.index);
  }
  const exactLiveDwarven = selectorRowLocalization(catalog.entries[8].label, scrollbarProof(553));
  assert.deepEqual(exactLiveDwarven.normalized_click_point, { x: 257, y: 574 });
  const boundedLiveDwarven = selectorRowLocalization(catalog.entries[8].label, scrollbarProof(551));
  assert.equal(boundedLiveDwarven.visible_top_index, 5);
  assert.equal(boundedLiveDwarven.visible_row_index, 3);
  assert.deepEqual(boundedLiveDwarven.normalized_click_point, { x: 257, y: 590 });

  const acceptedLiveDwarven = selectorRowLocalization(catalog.entries[8].label, scrollbarProof(550));
  assert.equal(acceptedLiveDwarven.visible_top_index, 4);
  assert.deepEqual(acceptedLiveDwarven.normalized_click_point, { x: 257, y: 597 });

  const failedLiveKebos = selectorRowLocalization(catalog.entries[13].label, scrollbarProof(558));
  assert.equal(failedLiveKebos.visible_top_index, 9);
  assert.equal(failedLiveKebos.visible_row_index, 4);
  assert.deepEqual(failedLiveKebos.normalized_click_point, { x: 257, y: 605 });

  const failedLiveCamdozaal = selectorRowLocalization(
    catalog.entries[31].label,
    scrollbarProof(589)
  );
  assert.equal(failedLiveCamdozaal.visible_top_index, 26);
  assert.equal(failedLiveCamdozaal.visible_row_index, 5);
  assert.deepEqual(failedLiveCamdozaal.normalized_observed_bbox, {
    left: 166,
    top: 608,
    right: 349,
    bottom: 622,
  });
  assert.deepEqual(failedLiveCamdozaal.normalized_click_point, { x: 257, y: 615 });
  assert.equal(
    failedLiveCamdozaal.proof_method,
    "NATIVE_SELECTOR_CATALOG_CONTINUOUS_GEOMETRY_V4"
  );
});

test("native selector visible-row clicks follow the calibrated 14-pixel cadence", () => {
  const catalog = loadNativeRealmCatalog();
  const localizations = catalog.entries.slice(0, 8).map((entry) =>
    selectorRowLocalization(entry.label, scrollbarProof(543))
  );

  assert.deepEqual(
    localizations.map((localization) => localization.normalized_click_point.y),
    [540, 554, 568, 582, 596, 610, 624, 638]
  );
  for (let index = 1; index < localizations.length; index += 1) {
    assert.equal(
      localizations[index - 1].normalized_observed_bbox.bottom,
      localizations[index].normalized_observed_bbox.top
    );
  }
});

test("every live selector label has unique calibrated closed-state identity", async () => {
  const registry = loadSemanticCalibrationRegistry({ requireAll: true });
  assert.equal(Object.keys(registry.surfaces).length, 47);
  for (const [label, calibration] of Object.entries(registry.surfaces)) {
    const classification = await classifyCapture(calibration.absolute_closed_template);
    const readback = classification.surface_readback;
    assert.equal(readback?.exact_match, true, label);
    assert.equal(readback?.surface, label, label);
    assert.ok(readback.normalized_correlation >= 0.72, label);
    assert.ok(readback.correlation_separation >= 0.08, label);
  }
});

test("closed-state readiness rejects a different native realm", async () => {
  const registry = loadSemanticCalibrationRegistry({ requireAll: true });
  const godWars = registry.surfaces["God Wars Dungeon"].absolute_closed_template;
  const wrong = await proveSemanticMapReadiness(godWars, "Kebos Underground");
  assert.equal(wrong.passed, false);
  assert.equal(wrong.observed_surface, "God Wars Dungeon");
  assert.equal("proof_method" in wrong, false);
});

test("native coverage readiness delegates sparse crop content without weakening realm identity", () => {
  const classification = {
    connection: "CONNECTED",
    map_shell: "FLOATING_MAP_OPEN",
    overlay: "NONE",
    map_content: "BLACK_OR_EMPTY",
    committable: false,
    surface_readback: {
      surface: "Morytania Underground",
      exact_match: true,
      normalized_correlation: 1,
      correlation_separation: 0.35,
    },
    normalization: { family: "GAMEPLAY_MAP_768x839" },
  };
  const sparse = semanticCoverageReadinessFromClassification(
    classification,
    "Morytania Underground"
  );
  assert.equal(sparse.passed, true);
  assert.equal(sparse.nonblack, false);
  assert.equal(sparse.coverage_content_delegated, true);

  assert.equal(semanticCoverageReadinessFromClassification(
    classification,
    "Kebos Underground"
  ).passed, false);
  assert.equal(semanticCoverageReadinessFromClassification({
    ...classification,
    overlay: "SURFACE_SELECTOR",
  }, "Morytania Underground").passed, false);
});

test("native selector vectors normalize against fresh window geometry", () => {
  const reviewed = selectorScrollbarVectorToThumbTop(575, scrollbarProof(543, 768, 839));
  assert.deepEqual(reviewed.reference.to, { x: 349, y: 583 });
  assert.deepEqual(reviewed.delivered.to, { x: 349, y: 586 });

  const retina = selectorScrollbarVectorToThumbTop(575, scrollbarProof(543, 1536, 1678));
  assert.deepEqual(retina.reference.to, { x: 349, y: 583 });
  assert.deepEqual(retina.delivered.to, { x: 698, y: 1170 });
  assert.notDeepEqual(retina.delivered.from, retina.delivered.to);

  const live = selectorScrollbarVectorToThumbTop(553, scrollbarProof(543, 1614, 1722));
  assert.deepEqual(live.reference.to, { x: 349, y: 561 });
  assert.deepEqual(live.delivered.to, { x: 733, y: 1156 });
  const sourceGrabOffset = live.delivered.from.y
    - scrollbarProof(543, 1614, 1722).source_observed_bbox.top;
  const deliveredSourceTop = live.delivered.to.y - sourceGrabOffset;
  assert.equal(Math.round((deliveredSourceTop * 839) / 1722), 555);

  const dwarven = selectorScrollbarVectorToThumbTop(550, scrollbarProof(543, 1614, 1722));
  assert.deepEqual(dwarven.delivered.to, { x: 733, y: 1150 });

  const dorgeshKaan = selectorScrollbarVectorToThumbTop(554, scrollbarProof(543, 1614, 1722));
  assert.deepEqual(dorgeshKaan.delivered.to, { x: 733, y: 1158 });

  const feldip = selectorScrollbarVectorToThumbTop(558, scrollbarProof(543, 1614, 1722));
  assert.deepEqual(feldip.delivered.to, { x: 733, y: 1166 });

  const resetToTop = selectorScrollbarVectorToThumbTop(543, scrollbarProof(573, 1614, 1722));
  assert.deepEqual(resetToTop.reference.to, { x: 349, y: 543 });
  assert.deepEqual(resetToTop.delivered.to, { x: 733, y: 1_114 });
});

test("native realm coverage planner is complete, stable, and catalog-bound", () => {
  const plan = planNativeRealmCoverage();
  const again = planNativeRealmCoverage();
  assert.equal(plan.positions.length, 617);
  assert.deepEqual(plan.proof, {
    exact_gap_free: true,
    no_out_of_bounds_centers: true,
    realm_zoom_count: 235,
    total_positions: 617,
    stable_order: true,
  });
  assert.deepEqual(plan.positions.map((position) => position.id), again.positions.map((position) => position.id));
  assert.equal(plan.planner_version, "native-realm-coverage-planner-v14");
  assert.equal(plan.positions[0].id, "native-realm-production-v14-01-surface-gielinor-z37p5-r000-c000");
  assert.equal(plan.positions.at(-1).id, "native-realm-production-v14-47-cache-world-map-zanaris-z0200-r000-c000");
  assert.deepEqual(plan.positions[0].coverage_crop, { left: 178, top: 70, width: 338, height: 550 });
  assert.deepEqual(
    plan.positions.find((position) => position.realm_id !== "surface-gielinor").coverage_crop,
    { left: 4, top: 70, width: 512, height: 550 }
  );
  assert.ok(plan.positions.every(({ reset_center: center }) =>
    Number.isFinite(center?.x) && Number.isFinite(center?.y)
  ));
  assert.ok(plan.positions.every(({ anchor_attempt_budget: attempts }) => attempts === undefined));
  assert.equal(plan.positions.some((position) => position.realm_id.startsWith("other-map-")), false);
  const catalog = loadNativeRealmCatalog();
  const defaultPlanes = new Map(catalog.entries.map((entry) => [entry.id, entry.default_plane]));
  assert.ok(plan.positions.every((position) =>
    position.coverage_plane === defaultPlanes.get(position.realm_id)
  ));

  const counts = new Set(plan.positions.map((position) => `${position.realm_id}:${position.zoom_percent}`).map((key) =>
    plan.positions.filter((position) => `${position.realm_id}:${position.zoom_percent}` === key).length
  ));
  assert.ok(counts.size > 1);
});

test("v14 plans Varlamore from its provenance-derived reopen center", () => {
  const position = planNativeRealmCoverage().positions.find((candidate) =>
    candidate.realm_id === "cache-world-map:varlamore-underground"
      && candidate.zoom_percent === 200
      && candidate.row === 0
      && candidate.column === 2
  );
  assert.ok(position);
  assert.deepEqual(position.reset_center, { x: 416, y: 129 });
  assert.deepEqual(position.capture_center, { x: 448, y: 137.5 });
  const delta = coverageReferenceDelta(position.reset_center, position.capture_center, 200);
  assert.deepEqual(delta, { dx: -64, dy: 17 });
  assert.deepEqual(coverageReferenceChunks(delta), [{ dx: -64, dy: 17 }]);
});

test("v14 keeps fully visible Asgarnia axes at the reviewed reopen center", () => {
  const positions = planNativeRealmCoverage().positions.filter((candidate) =>
    candidate.realm_id === "cache-world-map:asgarnia-ice-dungeon"
  );
  for (const zoom of [37.5, 50, 75, 100]) {
    const position = positions.find((candidate) => candidate.zoom_percent === zoom);
    assert.ok(position);
    assert.ok(Math.abs(position.capture_center.x - 93) <= 0.1);
    assert.ok(Math.abs(position.capture_center.y - 96) <= 0.1);
    assert.deepEqual(
      coverageReferenceDelta(position.reset_center, position.capture_center, zoom),
      { dx: 0, dy: 0 }
    );
    assert.deepEqual(
      coverageReferenceChunks(
        coverageReferenceDelta(position.reset_center, position.capture_center, zoom)
      ),
      []
    );
    assert.ok(position.capture_bounds.min_x <= position.realm_bounds.min_x);
    assert.ok(position.capture_bounds.min_y <= position.realm_bounds.min_y);
    assert.ok(position.capture_bounds.max_x >= position.realm_bounds.max_x);
    assert.ok(position.capture_bounds.max_y >= position.realm_bounds.max_y);
  }
  assert.equal(positions.filter((position) => position.zoom_percent === 200).length, 1);
});

test("v14 carry-forward work keys ignore only versioned queue identity", () => {
  const item = queueItemsForCoveragePlan(planNativeRealmCoverage())[0];
  const old = structuredClone(item);
  old.id = old.id.replace("v14", "v13");
  old.catalog_version = "native-selector-catalog-v2";
  old.planner_version = "native-realm-coverage-planner-v10";
  old.selector_index = 48;
  old.item_sha256 = digestA;
  assert.equal(nativeRealmWorkKey(item), nativeRealmWorkKey({ requested_work: old }));
  old.capture_center.x += 1;
  assert.notEqual(nativeRealmWorkKey(item), nativeRealmWorkKey({ requested_work: old }));
});

test("v14 carry-forward accepts only matching v14 crop lineage", () => {
  assert.equal(
    isNativeRealmCarrySourceItemID("native-realm-production-v10-09-cache-world-map-dwarven-mines-z37p5-r000-c000"),
    false
  );
  assert.equal(
    isNativeRealmCarrySourceItemID("native-realm-production-v12-09-cache-world-map-dwarven-mines-z37p5-r000-c000"),
    false
  );
  assert.equal(
    isNativeRealmCarrySourceItemID("native-realm-production-v11-09-cache-world-map-dwarven-mines-z37p5-r000-c000"),
    false
  );
  assert.equal(
    isNativeRealmCarrySourceItemID("native-realm-production-v13-09-cache-world-map-dwarven-mines-z37p5-r000-c000"),
    false
  );
  assert.equal(isNativeRealmCarrySourceItemID("native-realm-production-v9-old"), false);
  assert.equal(
    isNativeRealmCarrySourceItemID("native-realm-production-v14-09-cache-world-map-dwarven-mines-z37p5-r000-c000"),
    true
  );
  assert.equal(isNativeRealmCarrySourceItemID("semantic-map-capture-v11-foreign"), false);
});

test("v14 carry-forward crop identity is independent of JSON key order", () => {
  const expected = { left: 178, top: 70, width: 338, height: 550 };
  assert.equal(nativeRealmCoverageCropMatches(
    { height: 550, left: 178, top: 70, width: 338 },
    expected
  ), true);
  assert.equal(nativeRealmCoverageCropMatches(
    { height: 550, left: 178, top: 70, width: 337 },
    expected
  ), false);
  assert.equal(nativeRealmCoverageCropMatches(
    { left: 178, top: 70, width: 338 },
    expected
  ), false);
  assert.equal(nativeRealmCoverageCropMatches(
    { left: 178, top: 70, width: 338, height: 550, right: 516 },
    expected
  ), false);
});

test("carry-forward accepts sparse coverage frames only with delegated crop proof", () => {
  const readiness = {
    passed: true,
    observed_surface: "Morytania Underground",
    surface_readback: {
      exact_match: true,
      normalized_correlation: 1,
      correlation_separation: 0.35,
    },
    nonblack: false,
    coverage_content_delegated: true,
  };
  assert.equal(nativeRealmCarryCaptureAccepted({
    role: "coverage_target",
    targetSurface: "Morytania Underground",
    readiness,
    contentProof: { passed: true },
  }), true);
  assert.equal(nativeRealmCarryCaptureAccepted({
    role: "coverage_fresh",
    targetSurface: "Morytania Underground",
    readiness,
    contentProof: null,
  }), false);
  assert.equal(nativeRealmCarryCaptureAccepted({
    role: "surface_ready",
    targetSurface: "Morytania Underground",
    readiness,
    contentProof: { passed: true },
  }), false);
});

test("production queue validation rejects other_maps and catalog mismatches", () => {
  const plan = planNativeRealmCoverage();
  const manifest = productionManifest(plan);
  assert.equal(validateQueueManifest(manifest).manifest.items.length, 617);

  for (const mutate of [
    (item) => { item.realm_id = "other-map-123"; },
    (item) => { item.realm_id = "cache-special-region:37"; },
    (item) => { item.surface = "Full Map"; },
    (item) => { item.selector_index = 47; },
  ]) {
    const changed = structuredClone(manifest);
    delete changed.policy_digest;
    changed.items = changed.items.map((item) => {
      const copy = { ...item };
      delete copy.item_sha256;
      return copy;
    });
    mutate(changed.items[0]);
    assert.throws(
      () => validateQueueManifest(finalizeQueueManifest(changed)),
      /QUEUE_NATIVE_REALM_PRODUCTION_ITEM_INVALID/
    );
  }
});

test("native production ledger resumes deterministically and rejects malformed evidence", () => {
  const plan = planNativeRealmCoverage();
  const manifest = productionManifest(plan);
  const ledger = createNativeRealmCoverageLedger({ queue: manifest, plan, createdAt: "2026-08-11T00:00:00.000Z" });
  const first = nextNativeRealmLedgerItem(ledger);
  assert.equal(first.item_id, manifest.items[0].id);

  const accepted = applyNativeRealmLedgerEvent(ledger, {
    event: "accepted_in_sandbox",
    item_id: first.item_id,
    item_sha256: first.item_sha256,
    predecessor_item_id: null,
    result_digest: digestA,
  }, "2026-08-11T00:01:00.000Z");
  assert.equal(nextNativeRealmLedgerItem(accepted).item_id, manifest.items[1].id);
  assert.equal(accepted.summary.accepted_in_sandbox, 1);
  assert.equal(accepted.summary.remaining, 616);

  const invalidSelector = structuredClone(ledger);
  invalidSelector.items[0].selector_index = 47;
  assert.throws(
    () => verifyNativeRealmCoverageLedger(invalidSelector),
    /NATIVE_REALM_LEDGER_ITEM_INVALID/
  );

  assert.deepEqual(applyNativeRealmLedgerEvent(accepted, {
    event: "accepted_in_sandbox",
    item_id: first.item_id,
    item_sha256: first.item_sha256,
    predecessor_item_id: null,
    result_digest: digestA,
  }), accepted);
  assert.throws(() => applyNativeRealmLedgerEvent(accepted, {
    event: "accepted_in_sandbox",
    item_id: first.item_id,
    item_sha256: first.item_sha256,
    predecessor_item_id: null,
    result_digest: digestB,
  }), /NATIVE_REALM_LEDGER_ACCEPTANCE_REPLAY_MISMATCH/);
  assert.throws(() => applyNativeRealmLedgerEvent(accepted, {
    event: "accepted_in_sandbox",
    item_id: manifest.items[1].id,
    item_sha256: manifest.items[1].item_sha256,
    predecessor_item_id: null,
    result_digest: digestB,
  }), /NATIVE_REALM_LEDGER_PREDECESSOR_MISMATCH/);
  assert.throws(() => applyNativeRealmLedgerEvent(accepted, {
    event: "accepted_in_sandbox",
    item_id: manifest.items[1].id,
    item_sha256: "not-a-digest",
    predecessor_item_id: first.item_id,
    result_digest: digestB,
  }), /NATIVE_REALM_LEDGER_EVENT_SHA_MISMATCH/);

  const exported = applyNativeRealmLedgerEvent(accepted, {
    event: "canonically_exported",
    item_id: first.item_id,
    item_sha256: first.item_sha256,
    predecessor_item_id: null,
    export_digest: digestC,
  });
  assert.equal(exported.summary.canonically_exported, 1);
  assert.throws(() => applyNativeRealmLedgerEvent(exported, {
    event: "revoked",
    item_id: first.item_id,
    item_sha256: first.item_sha256,
    predecessor_item_id: null,
    reason: "operator mistake",
  }), /NATIVE_REALM_LEDGER_TERMINAL_EXPORT_REVOKE_FORBIDDEN/);

  const malformed = structuredClone(ledger);
  malformed.items[10].predecessor_item_id = "wrong";
  malformed.summary = { ...malformed.summary };
  assert.throws(() => verifyNativeRealmCoverageLedger(malformed, manifest), /NATIVE_REALM_LEDGER_ITEM_INVALID/);
});

test("native production failed and revoked rows permit only exact terminal replay", () => {
  const plan = planNativeRealmCoverage();
  const manifest = productionManifest(plan);
  const initial = createNativeRealmCoverageLedger({
    queue: manifest,
    plan,
    createdAt: "2026-08-11T00:00:00.000Z",
  });
  const first = nextNativeRealmLedgerItem(initial);

  for (const terminalState of ["failed", "revoked"]) {
    const terminalEvent = {
      event: terminalState,
      item_id: first.item_id,
      item_sha256: first.item_sha256,
      predecessor_item_id: null,
      reason: `${terminalState} for deterministic test`,
      evidence: {
        report_sha256: digestA,
        result_sha256: digestB,
      },
    };
    const terminal = applyNativeRealmLedgerEvent(
      initial,
      terminalEvent,
      "2026-08-11T00:01:00.000Z"
    );
    assert.deepEqual(
      applyNativeRealmLedgerEvent(terminal, terminalEvent, "2026-08-11T00:02:00.000Z"),
      terminal
    );

    assert.throws(() => applyNativeRealmLedgerEvent(terminal, {
      ...terminalEvent,
      reason: "changed reason",
    }), /NATIVE_REALM_LEDGER_TERMINAL_IMMUTABLE/);
    assert.throws(() => applyNativeRealmLedgerEvent(terminal, {
      ...terminalEvent,
      evidence: {
        ...terminalEvent.evidence,
        result_sha256: digestC,
      },
    }), /NATIVE_REALM_LEDGER_TERMINAL_IMMUTABLE/);
    assert.throws(() => applyNativeRealmLedgerEvent(terminal, {
      ...terminalEvent,
      event: terminalState === "failed" ? "revoked" : "failed",
    }), /NATIVE_REALM_LEDGER_TERMINAL_IMMUTABLE/);
    assert.throws(() => applyNativeRealmLedgerEvent(terminal, {
      event: "accepted_in_sandbox",
      item_id: first.item_id,
      item_sha256: first.item_sha256,
      predecessor_item_id: null,
      result_digest: digestA,
    }), /NATIVE_REALM_LEDGER_TERMINAL_IMMUTABLE/);
    assert.throws(() => applyNativeRealmLedgerEvent(terminal, {
      event: "canonically_exported",
      item_id: first.item_id,
      item_sha256: first.item_sha256,
      predecessor_item_id: null,
      export_digest: digestC,
    }), /NATIVE_REALM_LEDGER_TERMINAL_IMMUTABLE/);
  }
});

test("native production queue and ledger CLIs emit machine-readable verified artifacts", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "osrs-native-production."));
  const queueOutput = path.join(root, "queue.json");
  const ledgerOutput = path.join(root, "ledger.json");
  const create = spawnSync(process.execPath, [
    path.join(workerRoot, "scripts", "create-native-realm-production-queue.mjs"),
    "--generation", "native-production-test",
    "--artifact-root", path.join(root, "artifacts"),
    "--queue-output", queueOutput,
    "--ledger-output", ledgerOutput,
  ], { encoding: "utf8" });
  assert.equal(create.status, 0, create.stderr);
  const summary = JSON.parse(create.stdout);
  assert.equal(summary.status, "NATIVE_REALM_PRODUCTION_QUEUE_READY");
  assert.equal(summary.realm_count, 47);
  assert.equal(summary.coverage_positions, 617);
  assert.equal(summary.excluded_other_maps_count, 1047);

  const verify = spawnSync(process.execPath, [
    path.join(workerRoot, "scripts", "verify-native-realm-production.mjs"),
    "--queue", queueOutput,
    "--ledger", ledgerOutput,
  ], { encoding: "utf8" });
  assert.equal(verify.status, 0, verify.stderr);
  assert.equal(JSON.parse(verify.stdout).status, "NATIVE_REALM_PRODUCTION_VERIFIED");
});

function productionManifest(plan) {
  return finalizeQueueManifest({
    schema_version: 2,
    execution_profile: "semantic_map_capture_v1",
    generation_id: "native-production-test",
    target_bundle_id: "com.jagex.osclient",
    allowed_operations: ["capture", "click", "drag", "open_world_map"],
    artifact_root: "/tmp/osrs-native-production",
    items: queueItemsForCoveragePlan(plan),
  });
}

function scrollbarProof(top, width = 768, height = 839) {
  const scaleX = (value) => Math.round((value * width) / 768);
  const scaleY = (value) => Math.round((value * height) / 839);
  const track = { left: 342, top: 543, right: 356, bottom: 629 };
  const observed = { left: 342, top, right: 356, bottom: top + 16 };
  const state = top === 543 ? "top" : (top === 613 ? "bottom" : "intermediate");
  return {
    target: "SEMANTIC_SURFACE_SCROLLBAR_THUMB",
    anchor: state,
    state,
    selector_open: true,
    thumb_at_stop: state !== "intermediate",
    exactly_one_target: true,
    normalized_track_bbox: track,
    normalized_observed_bbox: observed,
    normalized_click_point: { x: 349, y: top + 8 },
    normalized_correlation: 0.96,
    distinct_second_correlation: 0.10,
    correlation_separation: 0.86,
    pixel_resolution: 1,
    coordinate_semantics: "LEFT_TOP_INCLUSIVE_RIGHT_BOTTOM_EXCLUSIVE",
    stop_tolerance_pixels: 0,
    normalized_up_button_bbox: { left: 342, top: 529, right: 356, bottom: 543 },
    normalized_down_button_bbox: { left: 342, top: 629, right: 356, bottom: 643 },
    up_button_correlation: 0.96,
    up_button_distinct_second_correlation: 0.10,
    down_button_correlation: 0.96,
    down_button_distinct_second_correlation: 0.10,
    top_clearance_pixels: top - 543,
    bottom_clearance_pixels: 613 - top,
    remaining_travel_to_top_pixels: top - 543,
    remaining_travel_to_bottom_pixels: 613 - top,
    travel_range_pixels: 70,
    top_stop_thumb_top_bounds: { minimum: 543, maximum: 543 },
    bottom_stop_thumb_top_bounds: { minimum: 613, maximum: 613 },
    source_frame_geometry: { width, height },
    source_track_bbox: {
      left: scaleX(track.left),
      top: scaleY(track.top),
      right: scaleX(track.right),
      bottom: scaleY(track.bottom),
    },
    source_observed_bbox: {
      left: scaleX(observed.left),
      top: scaleY(observed.top),
      right: scaleX(observed.right),
      bottom: scaleY(observed.bottom),
    },
    source_click_point: { x: scaleX(349), y: scaleY(top + 8) },
  };
}
