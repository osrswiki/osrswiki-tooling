import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import sharp from "sharp";

import {
  displacementBetween,
  evaluateSemanticNovelty,
  executeSemanticMapCapture,
  measureSemanticExtentContribution,
  restorationReferenceAnchor,
  safeMotionVector,
  nativeCoverageVector,
  nativeCoverageDisplacementBetween,
  halfResolutionDisplacementBounds,
  requireNativeCoverageMovement,
  requireNativeCoverageContent,
  selectSafeCoverageTranslation,
  selectSafeMotionTranslation,
  selectSparseMotionRetention,
  sparseZoomScaleProof,
} from "../src/semantic-map-capture.mjs";
import {
  planNativeRealmCoverage,
  queueItemsForCoveragePlan,
} from "../src/native-realm-coverage.mjs";
import { requireSemanticInteriorMapContent } from "../src/perception.mjs";
import {
  measuredInverseMotionVector,
  NATIVE_REALM_COVERAGE_CROP,
  NATIVE_SURFACE_COVERAGE_CROP,
} from "../src/semantic-profile.mjs";

test("sparse zoom proof accepts centered map growth and rejects no-op or translation", () => {
  const width = 310;
  const height = 480;
  const frame = (left, top, rectangleWidth, rectangleHeight) => {
    const raw = Buffer.alloc(width * height * 3);
    for (let y = top; y < top + rectangleHeight; y += 1) {
      for (let x = left; x < left + rectangleWidth; x += 1) {
        const offset = (y * width + x) * 3;
        raw[offset] = 92;
        raw[offset + 1] = 61;
        raw[offset + 2] = 29;
      }
    }
    return raw;
  };
  const before = frame(140, 220, 30, 32);
  const grown = frame(137, 217, 36, 39);
  const translated = frame(150, 220, 30, 32);
  const dense = frame(10, 10, 290, 440);

  const proof = sparseZoomScaleProof(before, grown, width, height);
  assert.equal(proof.passed, true);
  assert.equal(proof.evidence_mode, "sparse_map_scale_growth_v1");
  assert.ok(proof.growth.informative_pixel_ratio >= 1.15);
  assert.ok(proof.growth.width_ratio >= 1.08);
  assert.ok(proof.growth.height_ratio >= 1.08);
  assert.ok(proof.growth.center_displacement_pixels <= 5);

  assert.equal(sparseZoomScaleProof(before, before, width, height).passed, false);
  assert.equal(sparseZoomScaleProof(before, translated, width, height).passed, false);
  assert.equal(sparseZoomScaleProof(dense, dense, width, height).passed, false);
});

test("semantic interior content rejects persistent gutter and Key chrome around a black map", () => {
  const width = 768;
  const height = 839;
  const raw = Buffer.alloc(width * height * 3);
  for (let y = 70; y < 630; y += 1) {
    for (let x = 4; x < 30; x += 1) {
      const offset = (y * width + x) * 3;
      raw[offset] = 34;
      raw[offset + 1] = 57;
      raw[offset + 2] = 76;
    }
  }
  for (let y = 35; y < 630; y += 1) {
    for (let x = 4; x < 178; x += 1) {
      const offset = (y * width + x) * 3;
      raw[offset] = (x * 7 + y * 3) % 256;
      raw[offset + 1] = (x * 5 + y * 11) % 256;
      raw[offset + 2] = (x * 13 + y * 17) % 256;
    }
  }
  const classified = requireSemanticInteriorMapContent({
    map_shell: "FLOATING_MAP_OPEN",
    overlay: "NONE",
    map_content: "NONBLACK_CONTENT",
    committable: true,
    metrics: {},
  }, { raw, width, height });
  assert.equal(classified.map_content, "BLACK_OR_EMPTY");
  assert.equal(classified.committable, false);
  assert.equal(classified.metrics.semantic_interior_content_proof, false);
});

test("semantic novelty measures changed extent within the reviewed 470 pixel crop", () => {
  const width = 470;
  const height = 560;
  const preRaw = Buffer.alloc(width * height * 3, 32);
  const postRaw = Buffer.alloc(width * height * 3);
  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      const offset = (y * width + x) * 3;
      postRaw[offset] = (x * 7 + y * 3) % 256;
      postRaw[offset + 1] = (x * 5 + y * 11) % 256;
      postRaw[offset + 2] = (x * 13 + y * 17) % 256;
    }
  }
  const novelty = evaluateSemanticNovelty({
    preRaw,
    postRaw,
    sameFamilyRaw: null,
    width,
    height,
    thresholds: {
      pre_post_mean_abs_minimum: 2.5,
      same_family_mean_abs_minimum: 2.5,
      delivered_displacement_minimum_cells: 2,
      new_extent_mean_abs_minimum: 2,
    },
  });

  assert.equal(Number.isFinite(novelty.extent.contribution_mean_abs), true);
  assert.equal(novelty.extent.contributed, true);
});

test("dense semantic novelty binds the expected displacement for a shortened vector", () => {
  const width = 470;
  const height = 560;
  const preRaw = Buffer.alloc(width * height * 3);
  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      const offset = (y * width + x) * 3;
      preRaw[offset] = (x * 7 + y * 3) % 256;
      preRaw[offset + 1] = (x * 5 + y * 11) % 256;
      preRaw[offset + 2] = (x * 13 + y * 17) % 256;
    }
  }
  const expectedDisplacement = { dx: -41, dy: 0 };
  const postRaw = Buffer.alloc(preRaw.length);
  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      const sourceX = x - expectedDisplacement.dx;
      if (sourceX < 0 || sourceX >= width) continue;
      preRaw.copy(
        postRaw,
        (y * width + x) * 3,
        (y * width + sourceX) * 3,
        (y * width + sourceX + 1) * 3
      );
    }
  }

  const novelty = evaluateSemanticNovelty({
    preRaw,
    postRaw,
    sameFamilyRaw: null,
    width,
    height,
    thresholds: {
      pre_post_mean_abs_minimum: 2.5,
      same_family_mean_abs_minimum: 2.5,
      delivered_displacement_minimum_cells: 2,
      new_extent_mean_abs_minimum: 2,
    },
    criterionFamily: "eastward_topology",
    expectedDisplacement,
  });

  assert.equal(novelty.passed, true);
  assert.deepEqual(novelty.displacement.expected_displacement, expectedDisplacement);
});

test("semantic extent accepts newly exposed dark terrain but rejects an unchanged dark edge", () => {
  const width = 94;
  const height = 112;
  const preRaw = Buffer.alloc(width * height * 3, 48);
  const changedPostRaw = Buffer.from(preRaw);
  const stripWidth = 12;
  for (let y = 0; y < height; y += 1) {
    changedPostRaw.fill(0, (y * width + width - stripWidth) * 3, (y * width + width) * 3);
  }
  const displacement = { dx: -12, dy: 0 };

  assert.ok(measureSemanticExtentContribution({
    preRaw,
    postRaw: changedPostRaw,
    width,
    height,
    displacement,
  }) >= 2);
  assert.equal(measureSemanticExtentContribution({
    preRaw: Buffer.alloc(preRaw.length),
    postRaw: Buffer.alloc(preRaw.length),
    width,
    height,
    displacement,
  }), 0);
});

test("semantic novelty admits a uniquely supported boundary-clipped sparse cave pan", () => {
  const width = 470;
  const height = 560;
  const preRaw = Buffer.alloc(width * height * 3);
  for (let y = 175; y <= 291; y += 1) {
    for (let x = 232; x <= 348; x += 1) {
      if ((x * 11 + y * 7) % 5 > 1) continue;
      const offset = (y * width + x) * 3;
      preRaw[offset] = 50 + ((x * 7 + y * 3) % 150);
      preRaw[offset + 1] = 35 + ((x * 5 + y * 11) % 130);
      preRaw[offset + 2] = 20 + ((x * 13 + y * 17) % 110);
    }
  }
  const postRaw = Buffer.alloc(preRaw.length);
  const deliveredX = -340;
  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      const sourceX = x - deliveredX;
      if (sourceX < 0 || sourceX >= width) continue;
      preRaw.copy(
        postRaw,
        (y * width + x) * 3,
        (y * width + sourceX) * 3,
        (y * width + sourceX + 1) * 3
      );
    }
  }
  const thresholds = {
    pre_post_mean_abs_minimum: 2.5,
    same_family_mean_abs_minimum: 2.5,
    delivered_displacement_minimum_cells: 2,
    new_extent_mean_abs_minimum: 2,
  };
  const novelty = evaluateSemanticNovelty({
    preRaw,
    postRaw,
    sameFamilyRaw: null,
    width,
    height,
    thresholds,
    criterionFamily: "eastward_topology",
  });

  assert.equal(novelty.passed, true);
  assert.equal(novelty.evidence_mode, "sparse_unique_clipped");
  assert.ok(novelty.displacement.dx >= -72 && novelty.displacement.dx <= -64);
  assert.ok(Math.abs(novelty.displacement.dy) <= 4);
  assert.ok(novelty.displacement.informative_pixel_count >= 8);
  assert.ok(novelty.extent.contribution_mean_abs >= 2);

  const unchanged = evaluateSemanticNovelty({
    preRaw,
    postRaw: Buffer.from(preRaw),
    sameFamilyRaw: null,
    width,
    height,
    thresholds,
    criterionFamily: "eastward_topology",
  });
  assert.equal(unchanged.passed, false);
});

test("semantic pan anchor moves to the nearest low-gradient path around a live hotspot", () => {
  const width = 768;
  const height = 839;
  const raw = Buffer.alloc(width * height * 3, 80);
  for (let y = 293; y <= 307; y += 1) {
    for (let x = 83; x <= 97; x += 1) {
      const value = (x + y) % 2 === 0 ? 0 : 255;
      raw.fill(value, (y * width + x) * 3, (y * width + x + 1) * 3);
    }
  }
  const translation = selectSafeMotionTranslation(raw, "westward_boundary");
  assert.notDeepEqual(translation, { x: 0, y: 0 });
  assert.ok(Math.abs(translation.x) <= 36);
  assert.ok(Math.abs(translation.y) <= 36);
  assert.ok(Math.hypot(translation.x, translation.y) <= 18);
});

test("semantic sparse motion retains a finite cave island while dense maps keep the full profile", async (t) => {
  const width = 470;
  const height = 560;
  const content = Buffer.alloc(width * height * 3);
  for (let y = 175; y <= 291; y += 1) {
    for (let x = 232; x <= 348; x += 1) {
      if ((x * 11 + y * 7) % 5 > 1) continue;
      const offset = (y * width + x) * 3;
      content[offset] = 50 + ((x * 7 + y * 3) % 150);
      content[offset + 1] = 35 + ((x * 5 + y * 11) % 130);
      content[offset + 2] = 20 + ((x * 13 + y * 17) % 110);
    }
  }
  const retention = selectSparseMotionRetention(content, "southward_topology");
  assert.ok(retention.profile_fraction_percent < 100);
  assert.ok(retention.profile_fraction_percent >= 5);
  assert.equal(retention.projected_displacement_reference.x, 0);
  assert.ok(retention.projected_displacement_reference.y <= -10);
  assert.ok(retention.retained_informative_pixels >= retention.minimum_retained_informative_pixels);
  assert.ok(retention.retained_chromatic_pixels >= retention.minimum_retained_chromatic_pixels);

  const root = await fs.mkdtemp(path.join(os.tmpdir(), "semantic-sparse-vector-"));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const full = Buffer.alloc(768 * 839 * 3);
  for (let y = 0; y < height; y += 1) {
    content.copy(
      full,
      ((y + 70) * 768 + 4) * 3,
      y * width * 3,
      (y + 1) * width * 3
    );
  }
  const sparsePath = path.join(root, "sparse.png");
  const densePath = path.join(root, "dense.png");
  await Promise.all([
    sharp(full, { raw: { width: 768, height: 839, channels: 3 } }).png().toFile(sparsePath),
    sharp(Buffer.alloc(full.length, 80), {
      raw: { width: 768, height: 839, channels: 3 },
    }).png().toFile(densePath),
  ]);
  const sparseVector = await safeMotionVector(
    sparsePath,
    "southward_topology",
    { width: 1536, height: 1678 }
  );
  assert.equal(sparseVector.profile_fraction_percent, retention.profile_fraction_percent);
  assert.equal(sparseVector.sparse_retention.strategy, "KEEP_VISIBLE_INFORMATIVE_SUPPORT");
  assert.ok(sparseVector.translated_reference.to.y > 150);
  assert.ok(sparseVector.delivered.to.y > 300);

  const denseVector = await safeMotionVector(
    densePath,
    "southward_topology",
    { width: 1536, height: 1678 }
  );
  assert.equal(denseVector.profile_fraction_percent, undefined);
  assert.deepEqual(denseVector.translated_reference, {
    from: { x: 260, y: 560 },
    to: { x: 260, y: 150 },
  });
});

test("semantic motion retention protects a compact cave above the sparse occupancy cutoff", () => {
  const width = 470;
  const height = 560;
  const content = Buffer.alloc(width * height * 3);
  for (let y = 80; y <= 430; y += 1) {
    for (let x = 130; x <= 370; x += 1) {
      if ((x * 11 + y * 7) % 5 > 1) continue;
      const offset = (y * width + x) * 3;
      content[offset] = 50 + ((x * 7 + y * 3) % 150);
      content[offset + 1] = 35 + ((x * 5 + y * 11) % 130);
      content[offset + 2] = 20 + ((x * 13 + y * 17) % 110);
    }
  }

  const retention = selectSparseMotionRetention(content, "southward_topology");
  assert.ok(retention.profile_fraction_percent < 100);
  assert.ok(retention.profile_fraction_percent >= 5);
  assert.ok(retention.retained_fraction >= 0.2);
  assert.ok(retention.retained_informative_pixels >= retention.minimum_retained_informative_pixels);
  assert.ok(retention.retained_chromatic_pixels >= retention.minimum_retained_chromatic_pixels);
});

test("semantic displacement preserves normalization for non-reviewed frame geometry", async (t) => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "semantic-displacement-"));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const width = 1614;
  const height = 1722;
  const pixels = Buffer.alloc(width * height * 3);
  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      const offset = (y * width + x) * 3;
      pixels[offset] = (x * 7 + y * 3) % 256;
      pixels[offset + 1] = (x * 5 + y * 11) % 256;
      pixels[offset + 2] = (x * 13 + y * 17) % 256;
    }
  }
  const firstPath = path.join(root, "first.png");
  const secondPath = path.join(root, "second.png");
  await Promise.all([
    sharp(pixels, { raw: { width, height, channels: 3 } }).png().toFile(firstPath),
    sharp(pixels, { raw: { width, height, channels: 3 } }).png().toFile(secondPath),
  ]);

  const displacement = await displacementBetween(firstPath, secondPath);

  assert.deepEqual(
    { dx: displacement.dx, dy: displacement.dy, error: displacement.error },
    { dx: 0, dy: 0, error: 0 }
  );
  assert.equal(displacement.magnitude_cells, 0);
});

test("semantic displacement admits a uniquely supported sparse translation", async (t) => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "semantic-sparse-displacement-"));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const width = 768;
  const height = 839;
  const forward = { x: -270, y: -310 };
  const first = Buffer.alloc(width * height * 3);
  for (let island = 0; island < 19; island += 1) {
    const left = 285 + (island % 5) * 35;
    const top = 350 + Math.floor(island / 5) * 32;
    for (let y = top; y < top + 8; y += 1) {
      for (let x = left; x < left + 8; x += 1) {
        const offset = (y * width + x) * 3;
        first[offset] = 80 + ((x * 7 + y * 3 + island * 11) % 150);
        first[offset + 1] = 60 + ((x * 5 + y * 11 + island * 17) % 160);
        first[offset + 2] = 70 + ((x * 13 + y * 17 + island * 23) % 150);
      }
    }
  }
  const second = Buffer.alloc(first.length);
  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      const sourceX = x - forward.x;
      const sourceY = y - forward.y;
      if (sourceX < 0 || sourceX >= width || sourceY < 0 || sourceY >= height) continue;
      first.copy(
        second,
        (y * width + x) * 3,
        (sourceY * width + sourceX) * 3,
        (sourceY * width + sourceX + 1) * 3
      );
    }
  }
  const firstPath = path.join(root, "first.png");
  const secondPath = path.join(root, "second.png");
  await Promise.all([
    sharp(first, { raw: { width, height, channels: 3 } }).png().toFile(firstPath),
    sharp(second, { raw: { width, height, channels: 3 } }).png().toFile(secondPath),
  ]);

  const displacement = await displacementBetween(firstPath, secondPath);

  assert.deepEqual({ dx: displacement.dx, dy: displacement.dy }, { dx: -54, dy: -62 });
  assert.equal(displacement.evidence_mode, "sparse_unique");
  assert.ok(displacement.informative_pixel_count >= 48);
  assert.ok(displacement.informative_coverage >= 0.75);
});

test("semantic restoration measures the delivered pan and anchors its inverse on map content", async (t) => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "semantic-restoration-vector-"));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const width = 768;
  const height = 839;
  const forward = { x: -270, y: -310 };
  const first = Buffer.alloc(width * height * 3);
  for (let y = 80; y < 625; y += 1) {
    for (let x = 8; x < 470; x += 1) {
      const offset = (y * width + x) * 3;
      first[offset] = 40 + ((x * 7 + y * 3) % 170);
      first[offset + 1] = 50 + ((x * 5 + y * 11) % 160);
      first[offset + 2] = 60 + ((x * 13 + y * 17) % 150);
    }
  }
  const second = Buffer.alloc(first.length);
  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      const sourceX = x - forward.x;
      const sourceY = y - forward.y;
      if (sourceX < 0 || sourceX >= width || sourceY < 0 || sourceY >= height) continue;
      first.copy(
        second,
        (y * width + x) * 3,
        (sourceY * width + sourceX) * 3,
        (sourceY * width + sourceX + 1) * 3
      );
    }
  }
  const firstPath = path.join(root, "first.png");
  const secondPath = path.join(root, "second.png");
  await Promise.all([
    sharp(first, { raw: { width, height, channels: 3 } }).png().toFile(firstPath),
    sharp(second, { raw: { width, height, channels: 3 } }).png().toFile(secondPath),
  ]);

  const measured = await displacementBetween(firstPath, secondPath);
  const anchor = await restorationReferenceAnchor(secondPath, measured);
  const inverse = measuredInverseMotionVector(
    "center_detail",
    { width: 1614, height: 1722 },
    measured,
    anchor.reference_point
  );

  assert.deepEqual({ dx: measured.dx, dy: measured.dy }, { dx: -54, dy: -62 });
  assert.equal(anchor.selection_strategy, "LOWEST_GRADIENT_NEAREST_FEASIBLE_CENTER");
  assert.ok(anchor.local_informative_pixels >= 25);
  assert.ok(anchor.gradient_risk >= 0);
  assert.deepEqual(inverse.reference.to, {
    x: inverse.reference.from.x + 270,
    y: inverse.reference.from.y + 310,
  });
  assert.ok(inverse.reference.from.x > 4 && inverse.reference.to.x < 474);
  assert.ok(inverse.reference.from.y > 70 && inverse.reference.to.y < 630);
});

test("semantic restoration anchor ignores blank canvas and selects low-gradient map content near the feasible center", async (t) => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "semantic-restoration-anchor-"));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const width = 768;
  const height = 839;
  const raw = Buffer.alloc(width * height * 3);
  for (let y = 320; y <= 380; y += 1) {
    for (let x = 320; x <= 395; x += 1) {
      raw.fill(100, (y * width + x) * 3, (y * width + x) * 3 + 3);
    }
  }
  const framePath = path.join(root, "frame.png");
  await sharp(raw, { raw: { width, height, channels: 3 } }).png().toFile(framePath);

  const anchor = await restorationReferenceAnchor(framePath, { dx: 47, dy: 0 });

  assert.deepEqual(anchor.reference_point, { x: 356, y: 350 });
  assert.equal(anchor.local_informative_pixels, 121);
  assert.equal(anchor.gradient_risk, 0);
  assert.equal(anchor.selection_strategy, "LOWEST_GRADIENT_NEAREST_FEASIBLE_CENTER");
});

test("semantic executor emits zero input when the live calibration gate is closed", async () => {
  let captures = 0;
  let actions = 0;
  await assert.rejects(() => executeSemanticMapCapture({
    claim: {
      generation_id: "calibration-blocked-generation",
      item: {
        id: "calibration-blocked-item",
        item_sha256: "d".repeat(64),
        kind: "semantic_map_capture",
        surface: "Zanaris",
        zoom_percent: 75,
        criterion_family: "center_detail",
        restore_after_capture: true,
      },
    },
    deadline: Date.now() + 120_000,
    captureFrame: async () => { captures += 1; },
    performAction: async () => { actions += 1; },
    writeMapCrop: async () => assert.fail("no map crop should be written"),
    perception: {
      requireSemanticCalibrationGate: async () => {
        throw new Error("SEMANTIC_CALIBRATION_NOT_REVIEWED:terminal_selector_entry:confirmation");
      },
    },
  }), /SEMANTIC_CALIBRATION_NOT_REVIEWED/);
  assert.equal(captures, 0);
  assert.equal(actions, 0);
});

test("semantic executor follows the fixed full-motion state sequence and observes a late zoom transition without repeated input", async () => {
  const captures = Array.from({ length: 14 }, (_, index) => ({
    captureIdentifier: `capture-${index + 1}`,
    pngPath: `/fixture/capture-${index + 1}.png`,
    pngSHA256: String(index + 1).padStart(64, "0"),
    pixelWidth: 1536,
    pixelHeight: 1678,
    capturedAt: `2026-08-05T00:00:${String(index + 1).padStart(2, "0")}.000Z`,
    target: {
      bundleIdentifier: "com.jagex.osclient",
      processIdentifier: 41,
      windowIdentifier: 73,
    },
  }));
  const actions = [];
  const waits = [];
  const optionLocalizationOptions = [];
  const differences = [0.5, 0.4, 0, 1.5, 1.6];
  const displacements = [
    { dx: -68, dy: 0, error: 0, magnitude_cells: 68, cell_size_reference_pixels: 5 },
    { dx: 0, dy: 0, error: 0, magnitude_cells: 0, cell_size_reference_pixels: 5 },
  ];
  const result = await executeSemanticMapCapture({
    claim: {
      generation_id: "semantic-generation",
      item: {
        id: "semantic-item-001",
        item_sha256: "a".repeat(64),
        kind: "semantic_map_capture",
        surface: "Gielinor Surface",
        realm_id: "surface-gielinor",
        zoom_percent: 75,
        criterion_family: "eastward_topology",
        restore_after_capture: true,
      },
    },
    deadline: Date.now() + 120_000,
    captureFrame: async () => {
      const next = captures.shift();
      assert.ok(next, "executor requested an unexpected capture");
      return next;
    },
    performAction: async (operation, capture) => {
      actions.push({ operation, capture });
      return { path: `/fixture/input-${actions.length}.json`, sha256: "f".repeat(64) };
    },
    writeMapCrop: async () => ({ path: "/fixture/map.png", sha256: "e".repeat(64) }),
    wait: async (milliseconds) => waits.push(milliseconds),
    perception: {
      requireSemanticCalibrationGate: async () => {},
      requireAuthorizedOSRSMap: async () => ({ map_shell: "FLOATING_MAP_OPEN" }),
      localizeSemanticSurfaceSelector: async () => ({ source_click_point: { x: 700, y: 1330 } }),
      observeSemanticSurfaceScrollbar: async () => scrollbarProof("top"),
      localizeSemanticSurfaceOption: async (_path, surface, options) => {
        optionLocalizationOptions.push(options);
        return {
          requested_surface: surface,
          source_click_point: { x: 500, y: 1084 },
          correlation: 0.9,
          separation: 0.2,
        };
      },
      localizeSemanticZoom: async (_path, direction) => ({
        source_click_point: direction === "minus" ? { x: 840, y: 1320 } : { x: 920, y: 1320 },
      }),
      proveSemanticMapReadiness: async (pngPath, surface) => ({
        passed: !pngPath.endsWith("capture-8.png") && !pngPath.endsWith("capture-10.png"),
        requested_surface: surface,
        observed_surface: surface,
        nonblack: true,
      }),
    },
    analysis: {
      contentRaw: async (source) => Buffer.from(source),
      meanDifference: () => differences.shift(),
      evaluateNovelty: () => ({
        passed: true,
        pre_post_mean_abs: 3.5,
        same_family_mean_abs: null,
        displacement: { delivered: true, magnitude_cells: 3 },
        extent: { contribution_mean_abs: 2.5 },
      }),
      mapCrop: async () => Buffer.from("map"),
      displacementBetween: async () => displacements.shift(),
      restorationReferenceAnchor: async () => ({
        reference_point: { x: 100, y: 300 },
        local_informative_pixels: 121,
        neighborhood_pixels: 121,
      }),
    },
  });

  assert.deepEqual(actions.map(({ operation }) => operation.semantic_role), [
    "surface_selector_open",
    "surface_option_select",
    "zoom_minus",
    "zoom_minus",
    "zoom_plus",
    "zoom_plus",
    "pan",
    "restore",
  ]);
  assert.equal(new Set(actions.map(({ capture }) => capture.captureIdentifier)).size, 8);
  assert.deepEqual(actions[6].operation.from, { x: 860, y: 600 });
  assert.deepEqual(actions[6].operation.to, { x: 180, y: 600 });
  assert.deepEqual(actions[7].operation.from, { x: 200, y: 600 });
  assert.deepEqual(actions[7].operation.to, { x: 880, y: 600 });
  assert.equal(result.surface_proof.ready_capture.captureIdentifier, "capture-3");
  assert.equal(result.pan_proof.pre_frame.captureIdentifier, "capture-11");
  assert.equal(result.pan_proof.post_frame.captureIdentifier, "capture-12");
  assert.equal(result.pan_proof.fresh_frame.captureIdentifier, "capture-13");
  assert.equal(result.restoration_proof.frame.captureIdentifier, "capture-14");
  assert.equal(result.zoom_proof.minimum.consecutive_no_transition_clicks, 2);
  assert.equal(result.zoom_proof.ascent_clicks, 2);
  assert.equal(result.zoom_proof.transitions.filter(({ direction }) => direction === "plus")[0]
    .transition_observation_count, 2);
  assert.equal(result.zoom_proof.transitions.filter(({ direction }) => direction === "plus")[1]
    .transition_observation_count, 1);
  assert.deepEqual(result.surface_proof.selector_navigation, {
    required: false,
    mode: null,
    anchor: null,
    maximum_drags: 0,
    catalog_version: "native-selector-catalog-v4",
    selector_index: 0,
    visible_top_index: 0,
    visible_row_index: 0,
    target_thumb_top: 543,
    proof: "expected_label_uniquely_visible_by_catalog_index_and_fresh_scrollbar_geometry",
    drags: 0,
    transitions: [],
  });
  assert.deepEqual(result.surface_reset_proof, { required: false, delivered: false });
  assert.deepEqual(optionLocalizationOptions, [{ nativeCatalog: true }]);
  assert.deepEqual(waits, [250, 250, 250, 250, 250, 250, 250, 250, 250, 900]);
  assert.equal(captures.length, 0);
});

test("native production executor proves a close and reopen reset before capture", async () => {
  const item = queueItemsForCoveragePlan(planNativeRealmCoverage())[0];
  const captures = Array.from({ length: 15 }, (_, index) => ({
    captureIdentifier: `coverage-capture-${index + 1}`,
    pngPath: `/fixture/coverage-capture-${index + 1}.png`,
    pngSHA256: String(index + 701).padStart(64, "0"),
    pixelWidth: 1536,
    pixelHeight: 1678,
    capturedAt: `2026-08-11T00:00:${String(index + 1).padStart(2, "0")}.000Z`,
    target: {
      bundleIdentifier: "com.jagex.osclient",
      processIdentifier: 41,
      windowIdentifier: 73,
    },
  }));
  const actions = [];
  const differences = [0.4, 0.3, 8.2, 7.4, 4.8, 2.3];
  const result = await executeSemanticMapCapture({
    claim: {
      generation_id: "native-coverage-generation",
      item: { ...item, item_sha256: "7".repeat(64) },
    },
    deadline: Date.now() + 120_000,
    captureFrame: async () => {
      const next = captures.shift();
      assert.ok(next, "executor requested an unexpected capture");
      return next;
    },
    performAction: async (operation, capture) => {
      actions.push({ operation, capture });
      return { path: `/fixture/coverage-input-${actions.length}.json`, sha256: "f".repeat(64) };
    },
    writeMapCrop: async () => ({ path: "/fixture/coverage-map.png", sha256: "e".repeat(64) }),
    wait: async () => {},
    perception: {
      requireSemanticCalibrationGate: async () => {},
      requireAuthorizedOSRSMap: async () => ({
        map_shell: "FLOATING_MAP_OPEN",
        map_content: "MAP_CONTENT_VISIBLE",
        surface_readback: { surface: "Gielinor Surface", exact_match: true },
      }),
      requireAuthorizedOSRSCoverageMap: async () => assert.fail(
        "a qualified generic initial map must not require the pending surface"
      ),
      classifyCapture: async (pngPath) => pngPath.endsWith("coverage-capture-2.png")
        ? { recovery_state: "GAMEPLAY_NO_MAP", connection: "CONNECTED", committable: false }
        : { map_shell: "FLOATING_MAP_OPEN", connection: "CONNECTED", committable: true },
      localizeSemanticMapClose: async () => assert.fail(
        "native coverage must not use the generic map-close qualifier"
      ),
      localizeSemanticCoverageMapClose: async (_path, surface) => {
        assert.equal(surface, item.surface);
        return {
          target: "SEMANTIC_MAP_CLOSE_CONTROL",
          exactly_one_target: true,
          normalized_observed_bbox: { left: 486, top: 35, right: 516, bottom: 70 },
          normalized_click_point: { x: 500, y: 50 },
          source_click_point: { x: 1000, y: 100 },
        };
      },
      localizeSemanticSurfaceSelector: async () => ({ source_click_point: { x: 700, y: 1330 } }),
      observeSemanticSurfaceScrollbar: async () => scrollbarProof("top"),
      localizeSemanticSurfaceOption: async (_path, surface) => ({
        target: `SEMANTIC_SURFACE_OPTION:${surface}`,
        source_click_point: { x: 500, y: 1084 },
        normalized_correlation: 0.9,
        distinct_second_correlation: 0.2,
        exactly_one_target: true,
      }),
      localizeSemanticZoom: async () => ({ source_click_point: { x: 840, y: 1320 } }),
      proveSemanticMapReadiness: async (_path, surface) => ({
        passed: true,
        requested_surface: surface,
        observed_surface: surface,
        nonblack: true,
      }),
      proveSemanticCoverageReadiness: async (_path, surface) => ({
        passed: true,
        requested_surface: surface,
        observed_surface: surface,
        nonblack: false,
        coverage_content_delegated: true,
      }),
    },
    analysis: {
      contentRaw: async (source) => Buffer.from(source),
      nativeContentRaw: async (_path, crop) => {
        const raw = Buffer.alloc(crop.width * crop.height * 3);
        for (let offset = 0; offset < raw.length; offset += 3) {
          raw[offset] = 80;
          raw[offset + 1] = 60;
          raw[offset + 2] = 40;
        }
        return raw;
      },
      meanDifference: () => differences.shift(),
      mapCrop: async () => Buffer.from("map"),
      safeNativeCoverageVector: async (_path, delta, geometry, crop) =>
        nativeCoverageVector(delta, geometry, { x: 0, y: 0 }, crop),
      nativeCoverageDisplacementBetween: async (_first, _second, delta) => ({
        evidence_mode: "native_crop_expected_neighborhood",
        expected_reference_delta: delta,
        delivered_reference_delta: delta,
        tolerance_reference_pixels: 10,
        aligned_mean_abs: 2,
        informative_coverage: 0.9,
        informative_pixel_count: 1_000,
        distinct_score_separation: 4,
      }),
    },
  });

  assert.deepEqual(actions.map(({ operation }) => operation.semantic_role), [
    "coverage_map_close",
    "coverage_map_reopen",
    "surface_selector_open",
    "surface_option_select",
    "zoom_minus",
    "zoom_minus",
    "coverage_pan",
    "coverage_pan",
    "coverage_pan",
  ]);
  assert.equal(actions[0].capture.captureIdentifier, "coverage-capture-1");
  assert.deepEqual(actions[0].operation.point, { x: 1000, y: 100 });
  assert.equal(actions[1].capture.captureIdentifier, "coverage-capture-2");
  assert.deepEqual(actions[1].operation, {
    kind: "open_world_map",
    semantic_role: "coverage_map_reopen",
  });
  assert.equal(result.coverage_navigation.mode, "map_reopen_relative");
  assert.equal(result.coverage_navigation.anchor.required, false);
  assert.equal(result.coverage_navigation.anchor.attempts, 0);
  assert.equal(result.coverage_navigation.nonblack, true);
  assert.equal(result.coverage_navigation.target_content_proof.passed, true);
  assert.equal(result.coverage_navigation.fresh_content_proof.passed, true);
  assert.equal(result.coverage_navigation.target_gate.coverage_content_passed, true);
  assert.equal(result.coverage_navigation.fresh_gate.coverage_content_passed, true);
  assert.equal(result.coverage_navigation.movement.action_count, 3);
  assert.ok(result.coverage_navigation.movement.transitions.every(
    ({ displacement_proof: proof }) => proof.passed === true
  ));
  assert.deepEqual(result.coverage_navigation.target_center, item.capture_center);
  assert.equal(result.coverage_reset_proof.mode, "map_close_reopen");
  assert.equal(result.coverage_reset_proof.before_close_capture.captureIdentifier, "coverage-capture-1");
  assert.equal(result.coverage_reset_proof.closed_capture.captureIdentifier, "coverage-capture-2");
  assert.equal(result.coverage_reset_proof.reopened_capture.captureIdentifier, "coverage-capture-3");
  assert.equal(result.coverage_reset_proof.closed_classification.recovery_state, "GAMEPLAY_NO_MAP");
  assert.deepEqual(result.map_crop.source_crop, { left: 178, top: 70, width: 338, height: 550 });
  assert.equal(result.map_crop.width, 338);
  assert.equal(result.map_crop.height, 550);
  assert.equal(captures.length, 1);
});

test("native coverage content proof rejects a black crop and accepts chromatic map support", () => {
  const black = Buffer.alloc(310 * 480 * 3);
  assert.throws(
    () => requireNativeCoverageContent(black),
    /NATIVE_REALM_COVERAGE_TARGET_CONTENT_UNPROVEN/
  );
  const map = Buffer.alloc(310 * 480 * 3);
  for (let y = 20; y < 30; y += 1) {
    for (let x = 20; x < 30; x += 1) {
      const offset = (y * 310 + x) * 3;
      map[offset] = 90;
      map[offset + 1] = 60;
      map[offset + 2] = 30;
    }
  }
  const proof = requireNativeCoverageContent(map);
  assert.equal(proof.passed, true);
  assert.equal(proof.evidence_mode, "native_crop_interior_content_v2");
  assert.ok(proof.informative_pixel_count >= 64);
  assert.ok(proof.chromatic_pixel_count >= 8);
});

test("v14 native coverage keeps underground content and motion inside its full-width crop", () => {
  const map = Buffer.alloc(
    NATIVE_REALM_COVERAGE_CROP.width * NATIVE_REALM_COVERAGE_CROP.height * 3
  );
  for (let y = 20; y < 30; y += 1) {
    for (let x = 20; x < 30; x += 1) {
      const offset = (y * NATIVE_REALM_COVERAGE_CROP.width + x) * 3;
      map[offset] = 90;
      map[offset + 1] = 60;
      map[offset + 2] = 30;
    }
  }
  assert.equal(
    requireNativeCoverageContent(map, NATIVE_REALM_COVERAGE_CROP).passed,
    true
  );

  const realmVector = nativeCoverageVector(
    { dx: 240, dy: -400 },
    { width: 768, height: 839 },
    { x: 0, y: 0 },
    NATIVE_REALM_COVERAGE_CROP
  );
  assert.deepEqual(realmVector.reference, {
    from: { x: 16, y: 608 },
    to: { x: 256, y: 208 },
  });

  const surfaceVector = nativeCoverageVector(
    { dx: -240, dy: 400 },
    { width: 768, height: 839 },
    { x: 0, y: 0 },
    NATIVE_SURFACE_COVERAGE_CROP
  );
  assert.deepEqual(surfaceVector.reference, {
    from: { x: 504, y: 82 },
    to: { x: 264, y: 482 },
  });
});

test("native coverage content proof accepts structural grayscale map support", () => {
  const map = Buffer.alloc(310 * 480 * 3);
  for (let y = 40; y < 160; y += 1) {
    for (let x = 30; x < 180; x += 1) {
      if (x !== 30 && x !== 179 && y !== 40 && y !== 159) continue;
      const offset = (y * 310 + x) * 3;
      map[offset] = 96;
      map[offset + 1] = 96;
      map[offset + 2] = 96;
    }
  }
  const proof = requireNativeCoverageContent(map);
  assert.equal(proof.passed, true);
  assert.equal(proof.chromatic_pixel_count, 0);
  assert.ok(proof.structural_edge_pixel_count >= 64);
  assert.equal(proof.structural_edge_threshold, 3);
});

test("native coverage translates both pan anchors away from high-gradient map links", () => {
  const raw = Buffer.alloc(768 * 839 * 3, 24);
  const delta = { dx: -236, dy: -245 };
  for (const anchor of [{ x: 476, y: 503 }, { x: 240, y: 258 }]) {
    for (let y = anchor.y - 7; y <= anchor.y + 7; y += 1) {
      for (let x = anchor.x - 7; x <= anchor.x + 7; x += 1) {
        const offset = (y * 768 + x) * 3;
        const value = (x + y) % 2 === 0 ? 0 : 255;
        raw[offset] = value;
        raw[offset + 1] = 255 - value;
        raw[offset + 2] = value;
      }
    }
  }

  const translation = selectSafeCoverageTranslation(raw, delta);
  const vector = nativeCoverageVector(delta, { width: 1536, height: 1678 }, translation);

  assert.notDeepEqual(translation, { x: 0, y: 0 });
  assert.ok(Math.abs(translation.x) <= 36);
  assert.ok(Math.abs(translation.y) <= 36);
  assert.deepEqual(vector.anchor_translation, translation);
  assert.equal(vector.reference.to.x - vector.reference.from.x, delta.dx);
  assert.equal(vector.reference.to.y - vector.reference.from.y, delta.dy);
  for (const point of [vector.reference.from, vector.reference.to]) {
    assert.ok(point.x >= 184 && point.x < 482);
    assert.ok(point.y >= 41 && point.y < 509);
  }
});

test("native coverage movement rejects no-op and unaligned visual evidence", () => {
  const expectedReferenceDelta = { dx: 228, dy: -41 };
  const displacement = {
    evidence_mode: "native_crop_expected_neighborhood",
    expected_reference_delta: expectedReferenceDelta,
    delivered_reference_delta: { dx: 226, dy: -42 },
    tolerance_reference_pixels: 10,
    aligned_mean_abs: 3,
    informative_coverage: 0.9,
  };
  assert.equal(requireNativeCoverageMovement({
    meanAbsDifference: 4.2,
    displacement,
    expectedReferenceDelta,
  }).passed, true);
  assert.equal(requireNativeCoverageMovement({
    meanAbsDifference: 4.2,
    displacement: { ...displacement, informative_coverage: 0.55 },
    expectedReferenceDelta,
  }).passed, true);
  assert.throws(() => requireNativeCoverageMovement({
    meanAbsDifference: 0.5,
    displacement,
    expectedReferenceDelta,
  }), /NATIVE_REALM_COVERAGE_PAN_NO_OP/);
  assert.throws(() => requireNativeCoverageMovement({
    meanAbsDifference: 4.2,
    displacement: { ...displacement, aligned_mean_abs: 60 },
    expectedReferenceDelta,
  }), /NATIVE_REALM_COVERAGE_DISPLACEMENT_UNPROVEN/);
  assert.throws(() => requireNativeCoverageMovement({
    meanAbsDifference: 4.2,
    displacement: { ...displacement, informative_coverage: 0.49 },
    expectedReferenceDelta,
  }), /NATIVE_REALM_COVERAGE_DISPLACEMENT_UNPROVEN/);
});

test("native coverage displacement measures the delivered crop translation", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "native-coverage-displacement-"));
  const width = 768;
  const height = 839;
  const crop = { left: 178, top: 35, width: 310, height: 480 };
  const delta = { dx: 20, dy: -14 };
  const first = Buffer.alloc(width * height * 3);
  const second = Buffer.alloc(width * height * 3);
  for (let y = 0; y < crop.height; y += 1) {
    for (let x = 0; x < crop.width; x += 1) {
      const source = ((crop.top + y) * width + crop.left + x) * 3;
      first[source] = 40 + (x * 7 + y * 3) % 180;
      first[source + 1] = 40 + (x * 5 + y * 11) % 180;
      first[source + 2] = 40 + (x * 13 + y * 17) % 180;
      const movedX = x + delta.dx;
      const movedY = y + delta.dy;
      if (movedX < 0 || movedX >= crop.width || movedY < 0 || movedY >= crop.height) continue;
      const destination = ((crop.top + movedY) * width + crop.left + movedX) * 3;
      second[destination] = first[source];
      second[destination + 1] = first[source + 1];
      second[destination + 2] = first[source + 2];
    }
  }
  const firstPath = path.join(root, "first.png");
  const secondPath = path.join(root, "second.png");
  await Promise.all([
    sharp(first, { raw: { width, height, channels: 3 } }).png().toFile(firstPath),
    sharp(second, { raw: { width, height, channels: 3 } }).png().toFile(secondPath),
  ]);
  try {
    const proof = await nativeCoverageDisplacementBetween(firstPath, secondPath, delta);
    assert.deepEqual(proof.delivered_reference_delta, delta);
    assert.ok(proof.aligned_mean_abs < 2);
    assert.ok(proof.informative_coverage > 0.9);
  } finally {
    await fs.rm(root, { recursive: true, force: true });
  }
});

test("native coverage displacement bounds never admit an out-of-tolerance odd delta", () => {
  assert.deepEqual(halfResolutionDisplacementBounds(35, 10), {
    minimum: 13,
    maximum: 22,
  });
  assert.deepEqual(halfResolutionDisplacementBounds(-35, 10), {
    minimum: -22,
    maximum: -13,
  });
  for (const expected of [-239, -35, 35, 239]) {
    const bounds = halfResolutionDisplacementBounds(expected, 10);
    for (let candidate = bounds.minimum; candidate <= bounds.maximum; candidate += 1) {
      assert.ok(Math.abs(candidate * 2 - expected) <= 10);
    }
  }
});

test("native coverage displacement resolves a uniform-ocean tie near the delivered vector", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "native-coverage-ocean-"));
  const width = 768;
  const height = 839;
  const crop = { left: 178, top: 35, width: 310, height: 480 };
  const expected = { dx: 240, dy: -95 };
  const delivered = { dx: 236, dy: -94 };
  const first = Buffer.alloc(width * height * 3);
  const second = Buffer.alloc(width * height * 3);
  for (const frame of [first, second]) {
    for (let y = 0; y < crop.height; y += 1) {
      for (let x = 0; x < crop.width; x += 1) {
        const offset = ((crop.top + y) * width + crop.left + x) * 3;
        frame[offset] = 82;
        frame[offset + 1] = 112;
        frame[offset + 2] = 164;
      }
    }
  }
  for (let y = 120; y < 210; y += 1) {
    for (let x = 20; x < 68; x += 1) {
      const source = ((crop.top + y) * width + crop.left + x) * 3;
      first[source] = 40 + (x * 7 + y * 3) % 180;
      first[source + 1] = 40 + (x * 5 + y * 11) % 180;
      first[source + 2] = 40 + (x * 13 + y * 17) % 180;
      const movedX = x + delivered.dx;
      const movedY = y + delivered.dy;
      const destination = ((crop.top + movedY) * width + crop.left + movedX) * 3;
      second[destination] = first[source];
      second[destination + 1] = first[source + 1];
      second[destination + 2] = first[source + 2];
    }
  }
  const firstPath = path.join(root, "first.png");
  const secondPath = path.join(root, "second.png");
  await Promise.all([
    sharp(first, { raw: { width, height, channels: 3 } }).png().toFile(firstPath),
    sharp(second, { raw: { width, height, channels: 3 } }).png().toFile(secondPath),
  ]);
  try {
    const proof = await nativeCoverageDisplacementBetween(firstPath, secondPath, expected);
    assert.deepEqual(proof.delivered_reference_delta, delivered);
    assert.equal(proof.expectation_bias_per_half_pixel, 0.01);
    assert.equal(proof.alignment_selection_mode, "edge_expected_neighborhood");
    assert.ok(proof.edge_informative_pixel_count >= 64);
    assert.equal(requireNativeCoverageMovement({
      meanAbsDifference: 4.2,
      displacement: proof,
      expectedReferenceDelta: expected,
    }).passed, true);
  } finally {
    await fs.rm(root, { recursive: true, force: true });
  }
});

test("native coverage displacement falls back to raw alignment when shared edges are sparse", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "native-coverage-smooth-ocean-"));
  const width = 768;
  const height = 839;
  const crop = { left: 178, top: 35, width: 310, height: 480 };
  const delta = { dx: 224, dy: -220 };
  const first = Buffer.alloc(width * height * 3);
  const second = Buffer.alloc(width * height * 3);
  for (let y = 0; y < crop.height; y += 1) {
    for (let x = 0; x < crop.width; x += 1) {
      const source = ((crop.top + y) * width + crop.left + x) * 3;
      first[source] = 75 + Math.floor(x / 32);
      first[source + 1] = 105 + Math.floor(y / 48);
      first[source + 2] = 155 + Math.floor((x + y) / 64);
      second[source] = first[source];
      second[source + 1] = first[source + 1];
      second[source + 2] = first[source + 2];
      const movedX = x + delta.dx;
      const movedY = y + delta.dy;
      if (movedX < 0 || movedX >= crop.width || movedY < 0 || movedY >= crop.height) continue;
      const destination = ((crop.top + movedY) * width + crop.left + movedX) * 3;
      second[destination] = first[source];
      second[destination + 1] = first[source + 1];
      second[destination + 2] = first[source + 2];
    }
  }
  const firstPath = path.join(root, "first.png");
  const secondPath = path.join(root, "second.png");
  await Promise.all([
    sharp(first, { raw: { width, height, channels: 3 } }).png().toFile(firstPath),
    sharp(second, { raw: { width, height, channels: 3 } }).png().toFile(secondPath),
  ]);
  try {
    const proof = await nativeCoverageDisplacementBetween(firstPath, secondPath, delta);
    assert.deepEqual(proof.delivered_reference_delta, delta);
    assert.equal(proof.alignment_selection_mode, "raw_low_edge_fallback");
    assert.ok(proof.edge_informative_pixel_count < 64);
    assert.ok(proof.aligned_mean_abs < 2);
  } finally {
    await fs.rm(root, { recursive: true, force: true });
  }
});

test("native coverage displacement proves a directional clipped-boundary turnover", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "native-coverage-boundary-"));
  const width = 768;
  const height = 839;
  const crop = { left: 178, top: 35, width: 310, height: 480 };
  const delta = { dx: 180, dy: 48 };
  const first = Buffer.alloc(width * height * 3);
  const second = Buffer.alloc(width * height * 3);
  for (let y = 300; y < 470; y += 1) {
    for (let x = 260; x < crop.width; x += 1) {
      const offset = ((crop.top + y) * width + crop.left + x) * 3;
      first[offset] = 76;
      first[offset + 1] = 104;
      first[offset + 2] = 138;
    }
  }
  for (let y = 0; y < 150; y += 1) {
    for (let x = 0; x < 90; x += 1) {
      const offset = ((crop.top + y) * width + crop.left + x) * 3;
      second[offset] = 142;
      second[offset + 1] = 96;
      second[offset + 2] = 52;
    }
  }
  const firstPath = path.join(root, "first.png");
  const secondPath = path.join(root, "second.png");
  await Promise.all([
    sharp(first, { raw: { width, height, channels: 3 } }).png().toFile(firstPath),
    sharp(second, { raw: { width, height, channels: 3 } }).png().toFile(secondPath),
  ]);
  try {
    const proof = await nativeCoverageDisplacementBetween(firstPath, secondPath, delta);
    assert.equal(proof.evidence_mode, "native_crop_boundary_turnover");
    assert.equal(proof.alignment_selection_mode, "directional_boundary_turnover");
    assert.deepEqual(proof.delivered_reference_delta, delta);
    assert.ok(proof.source_changed_pixel_count >= 64);
    assert.ok(proof.destination_changed_pixel_count >= 64);
    assert.ok(proof.source_exit_fraction >= 0.75);
    assert.ok(proof.destination_entry_fraction >= 0.75);
    assert.ok(proof.aligned_shared_pixel_count <= 63);
    assert.equal(requireNativeCoverageMovement({
      meanAbsDifference: 5.3,
      displacement: proof,
      expectedReferenceDelta: delta,
    }).passed, true);
  } finally {
    await fs.rm(root, { recursive: true, force: true });
  }
});

test("native coverage boundary turnover rejects unchanged and weak frames", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "native-coverage-boundary-reject-"));
  const width = 768;
  const height = 839;
  const crop = { left: 178, top: 35, width: 310, height: 480 };
  const delta = { dx: 180, dy: 48 };
  const unchanged = Buffer.alloc(width * height * 3);
  const weak = Buffer.alloc(width * height * 3);
  for (let y = 320; y < 328; y += 1) {
    for (let x = 280; x < 288; x += 1) {
      const offset = ((crop.top + y) * width + crop.left + x) * 3;
      weak[offset] = 100;
      weak[offset + 1] = 80;
      weak[offset + 2] = 60;
    }
  }
  const unchangedPath = path.join(root, "unchanged.png");
  const weakPath = path.join(root, "weak.png");
  await Promise.all([
    sharp(unchanged, { raw: { width, height, channels: 3 } }).png().toFile(unchangedPath),
    sharp(weak, { raw: { width, height, channels: 3 } }).png().toFile(weakPath),
  ]);
  try {
    await assert.rejects(
      nativeCoverageDisplacementBetween(unchangedPath, unchangedPath, delta),
      /SEMANTIC_DISPLACEMENT_UNPROVEN/
    );
    await assert.rejects(
      nativeCoverageDisplacementBetween(weakPath, unchangedPath, delta),
      /SEMANTIC_DISPLACEMENT_UNPROVEN/
    );
  } finally {
    await fs.rm(root, { recursive: true, force: true });
  }
});

test("native coverage displacement proves a sparse source-boundary exit", async (context) => {
  const firstPath = process.env.OSRS_VARLAMORE_BOUNDARY_SOURCE_FRAME;
  const secondPath = process.env.OSRS_VARLAMORE_BOUNDARY_DESTINATION_FRAME;
  if (!firstPath || !secondPath) {
    context.skip("live Varlamore boundary frames are not configured");
    return;
  }
  const expected = { dx: -161, dy: -121 };
  const proof = await nativeCoverageDisplacementBetween(firstPath, secondPath, expected);
  assert.equal(proof.evidence_mode, "native_crop_source_boundary_exit");
  assert.equal(proof.alignment_selection_mode, "directional_source_boundary_exit");
  assert.ok(proof.source_changed_pixel_count >= 64);
  assert.ok(proof.destination_changed_pixel_count >= 16);
  assert.ok(proof.destination_informative_pixel_count >= 32);
  assert.ok(proof.source_exit_fraction >= 0.5);
  assert.ok(proof.aligned_shared_pixel_count <= 63);
  assert.equal(requireNativeCoverageMovement({
    meanAbsDifference: 20,
    displacement: proof,
    expectedReferenceDelta: expected,
  }).passed, true);
});

test("semantic executor rejects a persistently unchanged zoom ascent without repeating input", async () => {
  const captures = Array.from({ length: 8 }, (_, index) => ({
    captureIdentifier: `zoom-noop-capture-${index + 1}`,
    pngPath: `/fixture/zoom-noop-capture-${index + 1}.png`,
    pngSHA256: String(index + 201).padStart(64, "0"),
    pixelWidth: 1536,
    pixelHeight: 1678,
    capturedAt: `2026-08-05T00:00:${String(index + 1).padStart(2, "0")}.000Z`,
    target: {
      bundleIdentifier: "com.jagex.osclient",
      processIdentifier: 41,
      windowIdentifier: 73,
    },
  }));
  const actions = [];
  const waits = [];
  const differences = [0.5, 0.4, 0, 0, 0];

  await assert.rejects(() => executeSemanticMapCapture({
    claim: {
      generation_id: "zoom-noop-generation",
      item: {
        id: "zoom-noop-item",
        item_sha256: "9".repeat(64),
        kind: "semantic_map_capture",
        surface: "Gielinor Surface",
        zoom_percent: 50,
        criterion_family: "eastward_topology",
        restore_after_capture: false,
      },
    },
    deadline: Date.now() + 120_000,
    captureFrame: async () => captures.shift(),
    performAction: async (operation, capture) => {
      actions.push({ operation, capture });
      return { path: `/fixture/zoom-noop-input-${actions.length}.json`, sha256: "f".repeat(64) };
    },
    writeMapCrop: async () => assert.fail("no map crop should be written"),
    wait: async (milliseconds) => waits.push(milliseconds),
    perception: {
      requireSemanticCalibrationGate: async () => {},
      requireAuthorizedOSRSMap: async () => ({ map_shell: "FLOATING_MAP_OPEN" }),
      localizeSemanticSurfaceSelector: async () => ({ source_click_point: { x: 700, y: 1330 } }),
      localizeSemanticSurfaceOption: async (_path, surface) => ({
        requested_surface: surface,
        source_click_point: { x: 500, y: 1084 },
        correlation: 0.9,
        separation: 0.2,
      }),
      localizeSemanticZoom: async (_path, direction) => ({
        source_click_point: direction === "minus" ? { x: 840, y: 1320 } : { x: 920, y: 1320 },
      }),
      proveSemanticMapReadiness: async (_path, surface) => ({
        passed: true,
        requested_surface: surface,
        observed_surface: surface,
        nonblack: true,
      }),
    },
    analysis: {
      contentRaw: async (source) => Buffer.from(source),
      meanDifference: () => differences.shift(),
    },
  }), /SEMANTIC_ZOOM_ASCENT_TRANSITION_UNPROVEN:1/);

  assert.deepEqual(actions.map(({ operation }) => operation.semantic_role), [
    "surface_selector_open",
    "surface_option_select",
    "zoom_minus",
    "zoom_minus",
    "zoom_plus",
  ]);
  assert.deepEqual(waits, [250, 250, 250, 250, 250]);
  assert.equal(captures.length, 0);
});

test("semantic executor selects terminal Zanaris with one drag and restores Gielinor", async () => {
  const captures = Array.from({ length: 13 }, (_, index) => ({
    captureIdentifier: `terminal-capture-${index + 1}`,
    pngPath: `/fixture/terminal-capture-${index + 1}.png`,
    pngSHA256: String(index + 101).padStart(64, "0"),
    pixelWidth: 768,
    pixelHeight: 839,
    capturedAt: `2026-08-05T00:01:${String(index + 1).padStart(2, "0")}.000Z`,
    target: {
      bundleIdentifier: "com.jagex.osclient",
      processIdentifier: 41,
      windowIdentifier: 73,
    },
  }));
  const actions = [];
  const waits = [];
  const differences = [0.4, 0.3];
  const displacements = [
    { dx: -54, dy: -62, error: 0, magnitude_cells: Math.hypot(54, 62), cell_size_reference_pixels: 5 },
    { dx: 0, dy: 0, error: 0, magnitude_cells: 0, cell_size_reference_pixels: 5 },
  ];
  const result = await executeSemanticMapCapture({
    claim: {
      generation_id: "terminal-generation",
      item: {
        id: "terminal-item-001",
        item_sha256: "b".repeat(64),
        kind: "semantic_map_capture",
        surface: "Zanaris",
        zoom_percent: 37.5,
        criterion_family: "center_detail",
        restore_after_capture: true,
      },
    },
    deadline: Date.now() + 120_000,
    captureFrame: async () => {
      const next = captures.shift();
      assert.ok(next, "executor requested an unexpected capture");
      return next;
    },
    performAction: async (operation, capture) => {
      actions.push({ operation, capture });
      return { path: `/fixture/terminal-input-${actions.length}.json`, sha256: "f".repeat(64) };
    },
    writeMapCrop: async () => ({ path: "/fixture/terminal-map.png", sha256: "e".repeat(64) }),
    wait: async (milliseconds) => waits.push(milliseconds),
    perception: {
      requireSemanticCalibrationGate: async () => {},
      requireAuthorizedOSRSMap: async () => ({ map_shell: "FLOATING_MAP_OPEN" }),
      localizeSemanticSurfaceSelector: async () => ({ source_click_point: { x: 350, y: 665 } }),
      localizeSemanticSurfaceScrollbar: async (_path, _surface, anchor) =>
        scrollbarProof(anchor),
      localizeSemanticSurfaceOption: async (_path, surface) => ({
        target: `SEMANTIC_SURFACE_OPTION:${surface}`,
        source_click_point: surface === "Zanaris" ? { x: 250, y: 640 } : { x: 250, y: 542 },
        normalized_correlation: 0.9,
        distinct_second_correlation: 0.2,
        exactly_one_target: true,
      }),
      localizeSemanticZoom: async () => ({ source_click_point: { x: 420, y: 660 } }),
      proveSemanticMapReadiness: async (_path, surface) => ({
        passed: true,
        requested_surface: surface,
        observed_surface: surface,
        nonblack: true,
      }),
    },
    analysis: {
      contentRaw: async (source) => Buffer.from(source),
      meanDifference: () => differences.shift(),
      evaluateNovelty: () => ({
        passed: true,
        pre_post_mean_abs: 3.5,
        same_family_mean_abs: null,
        displacement: { delivered: true, magnitude_cells: 3 },
        extent: { contribution_mean_abs: 2.5 },
      }),
      mapCrop: async () => Buffer.from("map"),
      displacementBetween: async () => displacements.shift(),
      restorationReferenceAnchor: async () => ({
        reference_point: { x: 86, y: 113 },
        local_informative_pixels: 121,
        neighborhood_pixels: 121,
      }),
    },
  });

  assert.deepEqual(actions.map(({ operation }) => operation.semantic_role), [
    "surface_selector_open",
    "surface_selector_scrollbar_drag",
    "surface_option_select",
    "zoom_minus",
    "zoom_minus",
    "pan",
    "restore",
    "surface_selector_open",
    "surface_selector_scrollbar_drag",
    "surface_option_select",
  ]);
  assert.deepEqual(actions[1].operation.from, { x: 349, y: 551 });
  assert.deepEqual(actions[1].operation.to, { x: 349, y: 628 });
  assert.deepEqual(actions[6].operation.from, { x: 86, y: 113 });
  assert.deepEqual(actions[6].operation.to, { x: 356, y: 423 });
  assert.deepEqual(actions[8].operation.from, { x: 349, y: 621 });
  assert.deepEqual(actions[8].operation.to, { x: 349, y: 543 });
  assert.equal(result.surface_proof.selector_navigation.required, true);
  assert.equal(result.surface_proof.selector_navigation.drags, 1);
  assert.equal(result.surface_proof.selector_navigation.transitions.length, 1);
  assert.equal(result.surface_proof.option_capture.captureIdentifier, "terminal-capture-3");
  assert.equal(result.surface_reset_proof.delivered, true);
  assert.equal(result.surface_reset_proof.ready_capture.captureIdentifier, "terminal-capture-13");
  assert.equal(result.surface_reset_proof.requested_surface, "Gielinor Surface");
  assert.deepEqual(waits, [250, 250, 250, 250, 900]);
  assert.equal(captures.length, 0);
});

test("semantic executor rejects a no-op terminal scrollbar drag without fallback", async () => {
  const target = {
    bundleIdentifier: "com.jagex.osclient",
    processIdentifier: 41,
    windowIdentifier: 73,
  };
  const captures = [
    { captureIdentifier: "initial", pngPath: "/fixture/initial.png", pngSHA256: "1".repeat(64) },
    { captureIdentifier: "selector", pngPath: "/fixture/selector.png", pngSHA256: "2".repeat(64) },
    { captureIdentifier: "unchanged", pngPath: "/fixture/unchanged.png", pngSHA256: "2".repeat(64) },
  ].map((capture) => ({
    ...capture,
    pixelWidth: 768,
    pixelHeight: 839,
    capturedAt: "2026-08-05T00:02:00.000Z",
    target,
  }));
  const actions = [];
  await assert.rejects(() => executeSemanticMapCapture({
    claim: {
      generation_id: "terminal-no-op-generation",
      item: {
        id: "terminal-no-op-item",
        item_sha256: "c".repeat(64),
        kind: "semantic_map_capture",
        surface: "Zanaris",
        zoom_percent: 75,
        criterion_family: "center_detail",
        restore_after_capture: true,
      },
    },
    deadline: Date.now() + 120_000,
    captureFrame: async () => captures.shift(),
    performAction: async (operation) => {
      actions.push(operation);
      return { path: `/fixture/no-op-input-${actions.length}.json`, sha256: "f".repeat(64) };
    },
    writeMapCrop: async () => assert.fail("no map crop should be written"),
    wait: async () => {},
    perception: {
      requireSemanticCalibrationGate: async () => {},
      requireAuthorizedOSRSMap: async () => ({ map_shell: "FLOATING_MAP_OPEN" }),
      localizeSemanticSurfaceSelector: async () => ({ source_click_point: { x: 350, y: 665 } }),
      localizeSemanticSurfaceScrollbar: async () => scrollbarProof("top"),
    },
  }), /SEMANTIC_SELECTOR_SCROLLBAR_NO_TRANSITION/);
  assert.deepEqual(actions.map((operation) => operation.semantic_role), [
    "surface_selector_open",
    "surface_selector_scrollbar_drag",
  ]);
});

function scrollbarProof(anchor) {
  const top = anchor === "top" ? 543 : 613;
  const bottom = top + 16;
  const topClearance = top - 543;
  const bottomClearance = 629 - bottom;
  return {
    target: "SEMANTIC_SURFACE_SCROLLBAR_THUMB",
    anchor,
    state: anchor,
    normalized_click_point: anchor === "top" ? { x: 349, y: 551 } : { x: 349, y: 621 },
    source_click_point: anchor === "top" ? { x: 349, y: 551 } : { x: 349, y: 621 },
    source_frame_geometry: { width: 768, height: 839 },
    source_observed_bbox: { left: 342, top, right: 356, bottom },
    source_track_bbox: { left: 342, top: 543, right: 356, bottom: 629 },
    source_top_clearance_pixels: topClearance,
    source_bottom_clearance_pixels: bottomClearance,
    normalized_observed_bbox: { left: 342, top, right: 356, bottom },
    normalized_track_bbox: { left: 342, top: 543, right: 356, bottom: 629 },
    normalized_up_button_bbox: { left: 342, top: 529, right: 356, bottom: 543 },
    normalized_down_button_bbox: { left: 342, top: 629, right: 356, bottom: 643 },
    up_button_correlation: 0.95,
    up_button_distinct_second_correlation: 0.8,
    down_button_correlation: 0.95,
    down_button_distinct_second_correlation: 0.8,
    normalized_correlation: 0.9,
    distinct_second_correlation: 0.2,
    correlation_separation: 0.7,
    exactly_one_target: true,
    selector_open: true,
    thumb_at_stop: true,
    pixel_resolution: 1,
    coordinate_semantics: "LEFT_TOP_INCLUSIVE_RIGHT_BOTTOM_EXCLUSIVE",
    stop_tolerance_pixels: 0,
    top_clearance_pixels: topClearance,
    bottom_clearance_pixels: bottomClearance,
    remaining_travel_to_top_pixels: topClearance,
    remaining_travel_to_bottom_pixels: bottomClearance,
    travel_range_pixels: 70,
    top_stop_thumb_top_bounds: { minimum: 543, maximum: 543 },
    bottom_stop_thumb_top_bounds: { minimum: 613, maximum: 613 },
  };
}
