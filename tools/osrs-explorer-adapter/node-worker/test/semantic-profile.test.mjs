import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { decodeImage } from "../derived/reviewed-v4/runtime/explorer-v4-runtime.mjs";
import {
  localizeSemanticSurfaceOption,
  localizeSemanticSurfaceScrollbar,
  measureSemanticSurfaceScrollbarPixels,
  proveSemanticMapReadiness,
  snapNativeSelectorOptionPixelRow,
} from "../src/perception.mjs";
import { SEMANTIC_CRITERION_FAMILIES } from "../src/protocol.mjs";
import {
  MOTION_VECTORS,
  inverseMotionVector,
  isRepeatedTerminalRealmPerformanceCycle,
  loadSemanticCalibrationRegistry,
  measuredInverseMotionVector,
  restorationDisplacementForMotion,
  motionVector,
  selectorScrollbarVector,
  semanticMatrixItems,
  semanticPilotItems,
  semanticSurfaceNavigation,
} from "../src/semantic-profile.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const selectorOpen = path.join(root, "calibrations", "surface-selector-scrollbar-top.png");
const selectorBottom = path.join(root, "calibrations", "zanaris-selector-bottom.png");
const selectorBottomRetina = path.join(
  root,
  "calibrations",
  "surface-selector-scrollbar-bottom.png"
);
const asgarniaClosed = path.join(root, "calibrations", "asgarnia-ice-cave-closed.png");
const zanarisClosed = path.join(root, "calibrations", "zanaris-closed.png");
const gielinorClosed = path.join(
  root,
  "derived",
  "reviewed-v4",
  "templates",
  "gielinor-surface-closed.png"
);

test("native selector identifies the Tolna row from the complete visible pixel window", () => {
  const raw = Buffer.alloc(768 * 839 * 3);
  const bands = [
    [534, 544, 114], [548, 558, 130], [562, 573, 101], [577, 587, 48],
    [592, 602, 50], [607, 617, 72], [621, 631, 133], [635, 644, 108],
  ];
  for (const [top, bottom, width] of bands) {
    for (let y = top; y <= bottom; y += 1) {
      for (let x = 200; x < 200 + width; x += 1) {
        const offset = (y * 768 + x) * 3;
        raw[offset] = 230;
        raw[offset + 1] = 130;
        raw[offset + 2] = 20;
      }
    }
  }
  const snapped = snapNativeSelectorOptionPixelRow(
    { width: 768, height: 839, raw },
    {
      selector_index: 38,
      visible_top_index: 34,
      visible_row_index: 4,
      normalized_observed_bbox: { left: 166, top: 597, right: 349, bottom: 611 },
      normalized_click_point: { x: 257, y: 604 },
    }
  );

  assert.equal(snapped.visible_top_index, 34);
  assert.equal(snapped.visible_row_index, 4);
  assert.deepEqual(snapped.normalized_observed_bbox, {
    left: 166, top: 592, right: 349, bottom: 603,
  });
  assert.deepEqual(snapped.normalized_click_point, { x: 257, y: 597 });
  assert.equal(snapped.geometric_click_delta_y, -7);
  assert.ok(snapped.catalog_window_score >= 0.72);
  assert.ok(snapped.catalog_window_separation >= 0.08);
  assert.equal(snapped.proof_method, "NATIVE_SELECTOR_CATALOG_PIXEL_WINDOW_V5");
});

test("native selector exact live Tolna frame selects Tolna instead of The Abyss", async () => {
  const frame = process.env.OSRS_TOLNA_SELECTOR_REGRESSION_FRAME;
  if (!frame) return;
  const localization = await localizeSemanticSurfaceOption(frame, "Tolna's Rift", {
    nativeCatalog: true,
  });
  assert.equal(localization.visible_top_index, 34);
  assert.equal(localization.visible_row_index, 4);
  assert.equal(localization.normalized_click_point.y, 595);
  assert.equal(localization.proof_method, "NATIVE_SELECTOR_CATALOG_PIXEL_WINDOW_V5");
});

test("native selector accepts a uniquely identified seven-row clipped window", async () => {
  const frame = process.env.OSRS_TOLNA_CLIPPED_SELECTOR_REGRESSION_FRAME;
  if (!frame) return;
  const localization = await localizeSemanticSurfaceOption(frame, "Tolna's Rift", {
    nativeCatalog: true,
  });
  assert.equal(localization.visible_top_index, 35);
  assert.equal(localization.visible_row_index, 3);
  assert.equal(localization.detected_row_count, 7);
  assert.equal(localization.normalized_click_point.y, 588);
  assert.equal(localization.proof_method, "NATIVE_SELECTOR_CATALOG_PIXEL_WINDOW_V5");
});

test("full semantic matrix contains all 100 unique restored cells", () => {
  const cells = semanticMatrixItems();
  assert.equal(cells.length, 100);
  assert.equal(new Set(cells.map((item) => JSON.stringify(item))).size, 100);
  assert.ok(cells.every((item) => item.restore_after_capture === true));
});

test("every pilot phase has one fixed ordered item definition", () => {
  assert.equal(semanticPilotItems("motion-smoke").length, 5);
  assert.equal(semanticPilotItems("surface-smoke").length, 4);
  const terminalCycles = semanticPilotItems("terminal-realm-performance");
  assert.equal(terminalCycles.length, 20);
  assert.ok(terminalCycles.every((item) => item.surface === "Zanaris"));
  assert.ok(terminalCycles.every((item) => item.zoom_percent === 75));
  assert.ok(terminalCycles.every((item) => item.criterion_family === "center_detail"));
  assert.ok(terminalCycles.every((item) => item.restore_after_capture === true));
  assert.equal(semanticPilotItems("matrix").length, 100);
  assert.equal(semanticPilotItems("operational-soak").length, 25);
  assert.deepEqual(semanticPilotItems("canonical-canary"), [{
    kind: "semantic_map_capture",
    surface: "Gielinor Surface",
    zoom_percent: 37.5,
    criterion_family: "eastward_topology",
    restore_after_capture: false,
  }]);
  assert.equal(semanticPilotItems("canonical-5").length, 5);
  assert.equal(semanticPilotItems("canonical-10").length, 10);
  const canonical25 = semanticPilotItems("canonical-25");
  assert.equal(canonical25.length, 25);
  assert.deepEqual(
    canonical25.filter((_, index) => index % 5 === 0).map((item) => [
      item.surface,
      item.zoom_percent,
    ]),
    [
      ["Gielinor Surface", 37.5],
      ["Ancient Cavern", 50],
      ["Ardougne Underground", 75],
      ["Asgarnia Ice Cave", 100],
      ["Gielinor Surface", 200],
    ]
  );
  for (let offset = 0; offset < canonical25.length; offset += 5) {
    assert.deepEqual(
      canonical25.slice(offset, offset + 5).map((item) => item.criterion_family),
      SEMANTIC_CRITERION_FAMILIES
    );
  }
  assert.ok(canonical25.every((item) => item.restore_after_capture === false));
});

test("only the fixed repeated terminal benchmark skips cross-cycle novelty", () => {
  const terminal = {
    id: "terminal-realm-performance-002",
    ...semanticPilotItems("terminal-realm-performance")[1],
  };
  assert.equal(isRepeatedTerminalRealmPerformanceCycle(terminal), true);
  assert.equal(isRepeatedTerminalRealmPerformanceCycle({
    ...terminal,
    id: "terminal-realm-performance-timing-v2-002",
  }), true);
  assert.equal(isRepeatedTerminalRealmPerformanceCycle({
    ...terminal,
    id: "matrix-002",
  }), false);
  assert.equal(isRepeatedTerminalRealmPerformanceCycle({
    ...terminal,
    restore_after_capture: false,
  }), false);
  assert.equal(isRepeatedTerminalRealmPerformanceCycle({
    ...terminal,
    criterion_family: "eastward_topology",
  }), false);
});

test("fixed pan vectors normalize and reverse without changing their reviewed identity", () => {
  for (const [family, reference] of Object.entries(MOTION_VECTORS)) {
    const native = motionVector(family, { width: 1536, height: 1678 });
    assert.deepEqual(native.delivered.from, { x: reference.from.x * 2, y: reference.from.y * 2 });
    assert.deepEqual(native.delivered.to, { x: reference.to.x * 2, y: reference.to.y * 2 });
    const inverse = inverseMotionVector(family, { width: 1536, height: 1678 });
    assert.deepEqual(inverse.delivered.from, native.delivered.to);
    assert.deepEqual(inverse.delivered.to, native.delivered.from);
  }
});

test("pan anchor translation preserves the reviewed vector and remains tightly bounded", () => {
  const translated = motionVector(
    "westward_boundary",
    { width: 1536, height: 1678 },
    { x: -10, y: 8 }
  );
  assert.deepEqual(translated.reference, MOTION_VECTORS.westward_boundary);
  assert.deepEqual(translated.anchor_translation, { x: -10, y: 8 });
  assert.deepEqual(translated.translated_reference, {
    from: { x: 80, y: 308 },
    to: { x: 420, y: 308 },
  });
  assert.deepEqual(translated.delivered, {
    from: { x: 160, y: 616 },
    to: { x: 840, y: 616 },
  });
  assert.throws(() => motionVector(
    "westward_boundary",
    { width: 768, height: 839 },
    { x: -37, y: 0 }
  ), /ANCHOR_TRANSLATION_INVALID/);
  assert.throws(() => motionVector(
    "westward_boundary",
    { width: 768, height: 839 },
    { x: 0.5, y: 0 }
  ), /ANCHOR_TRANSLATION_INVALID/);
});

test("measured restoration stays opposite, bounded, and normalized to live geometry", () => {
  const vector = measuredInverseMotionVector(
    "center_detail",
    { width: 1614, height: 1722 },
    { dx: -54, dy: -62, magnitude_cells: Math.hypot(54, 62) },
    { x: 86, y: 113 }
  );
  assert.deepEqual(vector.reference, {
    from: { x: 86, y: 113 },
    to: { x: 356, y: 423 },
  });
  assert.deepEqual(vector.delivered, {
    from: { x: 181, y: 232 },
    to: { x: 748, y: 868 },
  });
  assert.equal(vector.measurement_kind, "MEASURED_EFFECTIVE_FORWARD_DISPLACEMENT");
  assert.deepEqual(vector.restoration_displacement, { x: -54, y: -62 });

  const nearFull = measuredInverseMotionVector(
    "center_detail",
    { width: 1614, height: 1722 },
    { dx: -53, dy: -60, magnitude_cells: Math.hypot(53, 60) },
    { x: 86, y: 113 }
  );
  assert.deepEqual(nearFull.restoration_displacement, { x: -54, y: -62 });
  assert.deepEqual(nearFull.reference.to, { x: 356, y: 423 });

  const boundaryLimited = measuredInverseMotionVector(
    "center_detail",
    { width: 1614, height: 1722 },
    { dx: -20, dy: -15, magnitude_cells: 25 },
    { x: 170, y: 200 }
  );
  assert.deepEqual(boundaryLimited.restoration_displacement, { x: -20, y: -15 });
  assert.deepEqual(boundaryLimited.reference.to, { x: 270, y: 275 });
  assert.throws(() => measuredInverseMotionVector(
    "center_detail",
    { width: 768, height: 839 },
    { dx: 55, dy: -62 },
    { x: 86, y: 113 }
  ), /MEASUREMENT_OUT_OF_PROFILE/);
});

test("measured restoration snaps to the delivered sparse profile within tolerance", () => {
  assert.deepEqual(restorationDisplacementForMotion(
    "eastward_topology",
    { dx: -60, dy: 0, magnitude_cells: 60 },
    { dx: -61, dy: 0 }
  ), { x: -61, y: 0 });

  const vector = measuredInverseMotionVector(
    "eastward_topology",
    { width: 1614, height: 1722 },
    { dx: -60, dy: 0, magnitude_cells: 60 },
    { x: 82, y: 350 },
    { dx: -61, dy: 0 }
  );
  assert.deepEqual(vector.restoration_displacement, { x: -61, y: 0 });
  assert.deepEqual(vector.expected_forward_displacement, { dx: -61, dy: 0 });
  assert.deepEqual(vector.reference.to, { x: 387, y: 350 });
  assert.deepEqual(vector.delivered, {
    from: { x: 172, y: 718 },
    to: { x: 813, y: 718 },
  });

  assert.deepEqual(restorationDisplacementForMotion(
    "center_detail",
    { dx: -42, dy: -48, magnitude_cells: Math.hypot(42, 48) },
    { dx: -43, dy: -50 }
  ), { x: -43, y: -49 });
});

test("scrollbar vectors use the localized thumb and the reviewed opposite stop", () => {
  const geometry = { width: 1536, height: 1678 };
  assert.deepEqual(selectorScrollbarVector("bottom", {
    normalized_click_point: { x: 349, y: 551 },
    normalized_track_bbox: { left: 342, top: 543, right: 356, bottom: 629 },
    normalized_observed_bbox: { left: 342, top: 543, right: 356, bottom: 559 },
    source_click_point: { x: 698, y: 1102 },
    source_track_bbox: { left: 684, top: 1086, right: 712, bottom: 1258 },
    source_observed_bbox: { left: 684, top: 1086, right: 712, bottom: 1118 },
    source_frame_geometry: geometry,
  }).delivered, {
    from: { x: 698, y: 1102 },
    to: { x: 698, y: 1257 },
  });
  assert.deepEqual(selectorScrollbarVector("top", {
    normalized_click_point: { x: 349, y: 621 },
    normalized_track_bbox: { left: 342, top: 543, right: 356, bottom: 629 },
    normalized_observed_bbox: { left: 342, top: 613, right: 356, bottom: 629 },
    source_click_point: { x: 698, y: 1242 },
    source_track_bbox: { left: 684, top: 1086, right: 712, bottom: 1258 },
    source_observed_bbox: { left: 684, top: 1226, right: 712, bottom: 1258 },
    source_frame_geometry: geometry,
  }).delivered, {
    from: { x: 698, y: 1242 },
    to: { x: 698, y: 1086 },
  });
});

test("scrollbar vectors map exact stops into the live non-integer capture geometry", () => {
  const geometry = { width: 1614, height: 1722 };
  const bottom = selectorScrollbarVector("bottom", {
    normalized_click_point: { x: 349, y: 551 },
    normalized_track_bbox: { left: 342, top: 543, right: 356, bottom: 629 },
    normalized_observed_bbox: { left: 342, top: 543, right: 356, bottom: 559 },
    source_click_point: { x: 733, y: 1131 },
    source_track_bbox: { left: 719, top: 1114, right: 748, bottom: 1291 },
    source_observed_bbox: { left: 719, top: 1114, right: 748, bottom: 1147 },
    source_frame_geometry: geometry,
  });
  assert.deepEqual(bottom.delivered, {
    from: { x: 733, y: 1131 },
    to: { x: 733, y: 1290 },
  });
});

test("top scrollbar thumb localizes uniquely and closed selectors reject navigation", async () => {
  const top = await localizeSemanticSurfaceScrollbar(selectorOpen, "Zanaris", "top");
  assert.equal(top.anchor, "top");
  assert.equal(top.selector_open, true);
  assert.equal(top.thumb_at_stop, true);
  assert.equal(top.state, "top");
  assert.equal(top.normalized_observed_bbox.top, 543);
  assert.equal(top.top_clearance_pixels, 0);
  assert.equal(top.bottom_clearance_pixels, 70);
  assert.equal(top.exactly_one_target, true);
  assert.ok(top.normalized_correlation >= 0.72);
  assert.ok(top.normalized_correlation - top.distinct_second_correlation >= 0.08);
  await assert.rejects(
    () => localizeSemanticSurfaceScrollbar(gielinorClosed, "Zanaris", "top"),
    /SEMANTIC_SURFACE_SELECTOR_NOT_OPEN/
  );
});

test("pixel geometry rejects a one-pixel-short thumb and accepts only the exact bottom row", async () => {
  const registry = loadSemanticCalibrationRegistry();
  const template = await decodeImage(await fs.readFile(selectorOpen));
  template.sha256 = "selector-open-template";
  const bottomTemplate = await decodeImage(await fs.readFile(selectorBottomRetina));
  bottomTemplate.sha256 = "selector-bottom-template";
  const templates = { top: template, bottom: bottomTemplate };
  const observation = cloneDecoded(template);
  replacePatch(observation, solidTrackPatch(template), 342, 543);
  replacePatch(observation, cropDecoded(template, 342, 543, 14, 16), 342, 612);

  const measured = measureSemanticSurfaceScrollbarPixels(
    observation,
    templates,
    registry.surface_selector_scrollbar
  );
  assert.equal(measured.state, "intermediate");
  assert.deepEqual(measured.normalized_observed_bbox, {
    left: 342,
    top: 612,
    right: 356,
    bottom: 628,
  });
  assert.equal(measured.top_clearance_pixels, 69);
  assert.equal(measured.bottom_clearance_pixels, 1);
  assert.equal(measured.remaining_travel_to_bottom_pixels, 1);

  const bottom = cloneDecoded(bottomTemplate);
  const bottomMeasured = measureSemanticSurfaceScrollbarPixels(
    bottom,
    templates,
    registry.surface_selector_scrollbar
  );
  assert.equal(bottomMeasured.state, "bottom");
  assert.equal(bottomMeasured.normalized_observed_bbox.top, 613);
  assert.equal(bottomMeasured.bottom_clearance_pixels, 0);
  assert.equal(bottomMeasured.remaining_travel_to_bottom_pixels, 0);
  assert.equal(bottomMeasured.calibration_template_role, "bottom");
});

test("non-integer Retina rendering proves the exact bottom with its reviewed template", async () => {
  const bottom = await localizeSemanticSurfaceScrollbar(
    selectorBottomRetina,
    "Zanaris",
    "bottom"
  );
  assert.equal(bottom.state, "bottom");
  assert.equal(bottom.normalized_observed_bbox.top, 613);
  assert.equal(bottom.bottom_clearance_pixels, 0);
  assert.equal(bottom.calibration_template_role, "bottom");
  assert.ok(bottom.normalized_correlation >= 0.72);
  assert.ok(bottom.correlation_separation >= 0.08);
});

test("scrollbar buttons, track, and thumb follow a shifted selector at one-pixel resolution", async () => {
  const registry = loadSemanticCalibrationRegistry();
  const template = await decodeImage(await fs.readFile(selectorOpen));
  template.sha256 = "selector-open-template";
  const shifted = shiftDecoded(template, 2, 3);
  const measured = measureSemanticSurfaceScrollbarPixels(
    shifted,
    template,
    registry.surface_selector_scrollbar
  );
  assert.deepEqual(measured.normalized_up_button_bbox, {
    left: 344, top: 532, right: 358, bottom: 546,
  });
  assert.deepEqual(measured.normalized_track_bbox, {
    left: 344, top: 546, right: 358, bottom: 632,
  });
  assert.deepEqual(measured.normalized_observed_bbox, {
    left: 344, top: 546, right: 358, bottom: 562,
  });
  assert.deepEqual(measured.normalized_down_button_bbox, {
    left: 344, top: 632, right: 358, bottom: 646,
  });
  assert.equal(measured.state, "top");
  assert.equal(measured.pixel_resolution, 1);
});

test("all four initially visible selector rows localize uniquely at the calibration thresholds", async () => {
  for (const surface of [
    "Gielinor Surface",
    "Ancient Cavern",
    "Ardougne Underground",
    "Asgarnia Ice Cave",
  ]) {
    const localization = await localizeSemanticSurfaceOption(selectorOpen, surface);
    assert.ok(localization.normalized_correlation >= 0.72, surface);
    assert.ok(
      localization.normalized_correlation - localization.distinct_second_correlation >= 0.08,
      surface
    );
    assert.equal(localization.exactly_one_target, true);
    const productionGeometry = [
      "NATIVE_SELECTOR_CATALOG_CONTINUOUS_GEOMETRY_V4",
      "NATIVE_SELECTOR_CATALOG_PIXEL_ROW_V4",
    ].includes(localization.proof_method);
    assert.equal(
      localization.click_anchor,
      productionGeometry
        ? localization.proof_method === "NATIVE_SELECTOR_CATALOG_PIXEL_ROW_V4"
          ? "PIXEL_LOCALIZED_TEXT_ROW_CENTER"
          : "PIXEL_LOCALIZED_ROW_CENTER"
        : "PIXEL_LOCALIZED_ROW_TOP_INSET"
    );
    assert.equal(
      localization.normalized_click_point.y,
      productionGeometry
        ? Math.floor(
          (localization.normalized_observed_bbox.top
            + localization.normalized_observed_bbox.bottom) / 2
        )
        : localization.normalized_observed_bbox.top + 2,
      surface
    );
    assert.ok(
      localization.source_click_point.y >= localization.source_observed_bbox.top
        && localization.source_click_point.y < localization.source_observed_bbox.bottom,
      surface
    );
  }
});

test("native production localization uses the measured catalog window for a visible surface", async () => {
  const legacy = await localizeSemanticSurfaceOption(selectorOpen, "Gielinor Surface");
  const production = await localizeSemanticSurfaceOption(
    selectorOpen,
    "Gielinor Surface",
    { nativeCatalog: true }
  );

  assert.equal(legacy.normalized_click_point.y, 528);
  assert.deepEqual(production.normalized_click_point, { x: 257, y: 537 });
  assert.equal(production.proof_method, "NATIVE_SELECTOR_CATALOG_PIXEL_WINDOW_V5");
  assert.equal(production.realm_id, "surface-gielinor");
});

test("terminal navigation is fixed and every live calibration is reviewed", async () => {
  assert.deepEqual(semanticSurfaceNavigation("Zanaris"), {
    required: true,
    mode: "scrollbar_drag",
    anchor: "bottom",
    maximum_drags: 1,
  });
  assert.deepEqual(semanticSurfaceNavigation("Gielinor Surface"), {
    required: false,
    mode: null,
    anchor: null,
    maximum_drags: 0,
  });
  const registry = loadSemanticCalibrationRegistry({ requireAll: true });
  assert.deepEqual(registry.terminal_selector_entry, {
    expected: "Zanaris",
    observed: "Zanaris",
    confirmed: true,
    status: "reviewed",
  });

  const terminalOption = await localizeSemanticSurfaceOption(selectorBottom, "Zanaris");
  assert.deepEqual(terminalOption.normalized_click_point, { x: 253, y: 640 });
  assert.ok(terminalOption.normalized_correlation >= 0.72);
  assert.ok(
    terminalOption.normalized_correlation - terminalOption.distinct_second_correlation >= 0.08
  );
  assert.equal(terminalOption.pixel_resolution, 1);

  const retinaTerminalOption = await localizeSemanticSurfaceOption(
    selectorBottomRetina,
    "Zanaris"
  );
  assert.deepEqual(retinaTerminalOption.normalized_click_point, { x: 253, y: 632 });
  assert.equal(retinaTerminalOption.normalized_correlation, 1);
  assert.ok(
    retinaTerminalOption.normalized_correlation
      - retinaTerminalOption.distinct_second_correlation >= 0.08
  );
  assert.equal(retinaTerminalOption.pixel_resolution, 1);

  const bottom = await localizeSemanticSurfaceScrollbar(selectorBottom, "Zanaris", "bottom");
  assert.equal(bottom.state, "bottom");
  assert.equal(bottom.bottom_clearance_pixels, 0);
  assert.equal(bottom.pixel_resolution, 1);

  for (const [surface, capture] of [
    ["Asgarnia Ice Cave", asgarniaClosed],
    ["Zanaris", zanarisClosed],
  ]) {
    const proof = await proveSemanticMapReadiness(capture, surface);
    assert.equal(proof.passed, true, surface);
    assert.equal(proof.observed_surface, surface);
    assert.equal(proof.surface_readback.normalized_correlation, 1);
    assert.ok(proof.surface_readback.correlation_separation >= 0.08, surface);
  }
});

function cloneDecoded(decoded) {
  return {
    ...decoded,
    raw: Buffer.from(decoded.raw),
    sha256: `${decoded.sha256 ?? "frame"}-copy`,
  };
}

function cropDecoded(decoded, left, top, width, height) {
  const raw = Buffer.alloc(width * height * 3);
  for (let y = 0; y < height; y += 1) {
    const sourceStart = ((top + y) * decoded.width + left) * 3;
    decoded.raw.copy(raw, y * width * 3, sourceStart, sourceStart + width * 3);
  }
  return { raw, width, height };
}

function replacePatch(target, patch, left, top) {
  for (let y = 0; y < patch.height; y += 1) {
    const targetStart = ((top + y) * target.width + left) * 3;
    patch.raw.copy(target.raw, targetStart, y * patch.width * 3, (y + 1) * patch.width * 3);
  }
}

function shiftDecoded(decoded, offsetX, offsetY) {
  const shifted = {
    ...decoded,
    raw: Buffer.alloc(decoded.raw.length),
    sha256: `${decoded.sha256 ?? "frame"}-shifted-${offsetX}-${offsetY}`,
  };
  for (let y = 0; y < decoded.height - offsetY; y += 1) {
    const sourceStart = y * decoded.width * 3;
    const targetStart = ((y + offsetY) * decoded.width + offsetX) * 3;
    decoded.raw.copy(
      shifted.raw,
      targetStart,
      sourceStart,
      sourceStart + (decoded.width - offsetX) * 3
    );
  }
  return shifted;
}

function solidTrackPatch(template) {
  const row = cropDecoded(template, 342, 590, 14, 1);
  const raw = Buffer.alloc(14 * 86 * 3);
  for (let y = 0; y < 86; y += 1) {
    row.raw.copy(raw, y * 14 * 3);
  }
  return { raw, width: 14, height: 86 };
}
