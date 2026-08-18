import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import os from "node:os";
import test from "node:test";
import { fileURLToPath } from "node:url";
import sharp from "sharp";

import { createExecutionLifecycle } from "../derived/reviewed-v4/source/execution-lifecycle.mjs";
import {
  classifyDecodedFrame,
  decodeImage,
  evaluateAxisCommitGate,
  evaluateNovelty,
  loadTemplates,
  localizeSelector,
  localizeZoomControl,
  readObservedSurface,
  sha256
} from "../derived/reviewed-v4/runtime/explorer-v4-runtime.mjs";
import {
  classifyCapture,
  refineSemanticPostCloseClassification,
  localizeOpenSemanticSurfaceSelectorToggle,
  readOSRSReadiness,
  refineSparseSemanticMapClassification,
  refineSemanticSelectorClassification,
  requireSemanticInteriorMapContent,
  requireAuthorizedOSRSMap,
  requireAuthorizedOSRSSelector
} from "../src/perception.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const reviewed = path.join(root, "derived", "reviewed-v4");

test("reviewed frame classification and recovery parity", async () => {
  const surface = await classifyCapture(path.join(reviewed, "templates", "gielinor-surface-closed.png"));
  assert.deepEqual(
    pick(surface, ["connection", "map_shell", "overlay", "map_content", "committable"]),
    {
      connection: "CONNECTED",
      map_shell: "FLOATING_MAP_OPEN",
      overlay: "NONE",
      map_content: "NONBLACK_CONTENT",
      committable: true
    }
  );
  assert.equal(surface.surface_readback.surface, "Gielinor Surface");
  assert.equal(surface.surface_readback.exact_match, true);
  const recovery = await classifyCapture(path.join(reviewed, "templates", "recovery-gameplay-no-map.jpeg"));
  assert.equal(recovery.recovery_state, "GAMEPLAY_NO_MAP");
  assert.equal(recovery.recovery_localization, null);
  assert.equal(recovery.committable, false);
  const selector = await classifyCapture(path.join(reviewed, "templates", "surface-selector-open.jpeg"));
  assert.equal(selector.overlay, "SURFACE_SELECTOR");
  const readiness = await readOSRSReadiness(path.join(reviewed, "templates", "gielinor-surface-closed.png"));
  assert.equal(readiness.status, "MAP_READY");
  await assert.rejects(
    requireAuthorizedOSRSMap(path.join(reviewed, "templates", "recovery-gameplay-no-map.jpeg")),
    /UNKNOWN_OR_UNAUTHORIZED_OSRS_SCREEN/
  );
});

test("pixel-localized scrollbar keeps a bottom-scrolled selector authorized", async () => {
  const source = path.join(root, "calibrations", "surface-selector-scrollbar-top.png");
  const bottomScrolled = path.join(
    os.tmpdir(),
    `osrs-selector-bottom-scrolled-${process.pid}-${Date.now()}.png`
  );
  try {
    const template = await decodeImage(await fs.readFile(source));
    const observation = {
      ...template,
      raw: Buffer.from(template.raw),
      sha256: "synthetic-bottom-scrolled-selector",
    };

    // Replace list content so the inherited whole-overlay matcher no longer applies.
    for (let y = 532; y < 670; y += 1) {
      for (let x = 165; x < 342; x += 1) {
        const offset = (y * observation.width + x) * 3;
        const high = (x + y) % 2 === 0;
        observation.raw[offset] = high ? 255 : 0;
        observation.raw[offset + 1] = high ? 0 : 255;
        observation.raw[offset + 2] = 255;
      }
      for (let x = 356; x < 359; x += 1) {
        const offset = (y * observation.width + x) * 3;
        observation.raw[offset] = 255;
        observation.raw[offset + 1] = 0;
        observation.raw[offset + 2] = 255;
      }
    }

    const thumb = cropDecoded(template, 342, 543, 14, 16);
    const trackRow = cropDecoded(template, 342, 590, 14, 1);
    for (let y = 543; y < 629; y += 1) {
      replacePatch(observation, trackRow, 342, y);
    }
    replacePatch(observation, thumb, 342, 613);

    const config = JSON.parse(
      await fs.readFile(path.join(reviewed, "config", "explorer-v4-config.json"), "utf8")
    );
    for (const value of Object.values(config.templates)) {
      value.path = path.join(reviewed, "templates", path.basename(value.path));
    }
    const templates = await loadTemplates(config);
    const inherited = classifyDecodedFrame(observation, templates);
    assert.equal(inherited.overlay, "NONE");

    await sharp(observation.raw, {
      raw: { width: observation.width, height: observation.height, channels: 3 },
    }).png().toFile(bottomScrolled);
    const classification = await classifyCapture(bottomScrolled);
    assert.equal(classification.overlay, "SURFACE_SELECTOR");
    assert.equal(classification.committable, false);
    assert.equal(classification.metrics.selector_scrollbar_pixel_state, "bottom");
    assert.equal(classification.metrics.selector_scrollbar_top_clearance_pixels, 70);
    assert.equal(classification.metrics.selector_scrollbar_bottom_clearance_pixels, 0);
    await requireAuthorizedOSRSSelector(bottomScrolled);
  } finally {
    await fs.rm(bottomScrolled, { force: true });
  }
});

test("unproven coarse selector matches do not turn map tooltips into open selectors", () => {
  const tooltip = refineSemanticSelectorClassification({
    connection: "CONNECTED",
    map_shell: "FLOATING_MAP_OPEN",
    overlay: "SURFACE_SELECTOR",
    map_content: "NONBLACK_CONTENT",
    committable: false,
    metrics: { selector_overlay_score: 32.843701226309925 },
  });
  assert.equal(tooltip.overlay, "NONE");
  assert.equal(tooltip.committable, true);
  assert.equal(tooltip.metrics.selector_overlay_coarse_match_rejected, true);

  const productionCoverageMap = refineSemanticSelectorClassification({
    connection: "CONNECTED",
    map_shell: "FLOATING_MAP_OPEN",
    overlay: "SURFACE_SELECTOR",
    map_content: "NONBLACK_CONTENT",
    committable: false,
    metrics: { selector_overlay_score: 23.64849498327759 },
  });
  assert.equal(productionCoverageMap.overlay, "NONE");
  assert.equal(productionCoverageMap.committable, true);
  assert.equal(
    productionCoverageMap.metrics.selector_overlay_coarse_match_rejected,
    true
  );

  const legacySelector = refineSemanticSelectorClassification({
    connection: "CONNECTED",
    map_shell: "FLOATING_MAP_OPEN",
    overlay: "SURFACE_SELECTOR",
    map_content: "NONBLACK_CONTENT",
    committable: false,
    metrics: { selector_overlay_score: 14.403455964325529 },
  });
  assert.equal(legacySelector.overlay, "SURFACE_SELECTOR");
  assert.equal(legacySelector.committable, false);
});

test("post-close gameplay proof tolerates a transient close tooltip", () => {
  const postClose = refineSemanticPostCloseClassification({
    connection: "UNKNOWN",
    map_shell: "UNKNOWN",
    overlay: "SURFACE_SELECTOR",
    map_content: "NONBLACK_CONTENT",
    recovery_state: null,
    committable: false,
    metrics: {
      geometry: true,
      close_orange_fraction: 0,
      controls_stddev: 26.62,
      hud_stddev: 48.03,
      viewport_stddev: 31.73,
      selector_overlay_score: 22.64,
    },
    normalization: { family: "GAMEPLAY_MAP_768x839" },
  });
  assert.equal(postClose.connection, "CONNECTED");
  assert.equal(postClose.overlay, "UNKNOWN");
  assert.equal(postClose.recovery_state, "GAMEPLAY_NO_MAP");
  assert.equal(postClose.committable, false);
  assert.equal(postClose.metrics.semantic_post_close_gameplay_hud_proof, true);

  const mapStillOpen = refineSemanticPostCloseClassification({
    ...postClose,
    map_shell: "FLOATING_MAP_OPEN",
    recovery_state: null,
    metrics: { ...postClose.metrics, close_orange_fraction: 0.02 },
  });
  assert.equal(mapStillOpen.recovery_state, null);
  assert.equal(mapStillOpen.map_shell, "FLOATING_MAP_OPEN");
});

test("exact calibrated surfaces accept sparse map islands but reject empty viewports", () => {
  const base = {
    connection: "CONNECTED",
    map_shell: "FLOATING_MAP_OPEN",
    overlay: "NONE",
    map_content: "BLACK_OR_EMPTY",
    committable: false,
    metrics: { viewport_stddev: 7.1 },
  };
  const surfaceReadback = { surface: "Ancient Cavern", exact_match: true };
  const empty = {
    width: 768,
    height: 839,
    raw: Buffer.alloc(768 * 839 * 3),
  };
  const sparse = { ...empty, raw: Buffer.from(empty.raw) };
  for (let index = 0; index < 1_600; index += 1) {
    const x = 150 + (index % 80);
    const y = 100 + Math.floor(index / 80);
    const offset = (y * sparse.width + x) * 3;
    sparse.raw[offset] = 64;
    sparse.raw[offset + 1] = 32;
    sparse.raw[offset + 2] = 16;
  }

  const accepted = refineSparseSemanticMapClassification(base, sparse, surfaceReadback);
  assert.equal(accepted.map_content, "NONBLACK_CONTENT");
  assert.equal(accepted.committable, true);
  assert.equal(accepted.metrics.semantic_sparse_content_proof, true);
  assert.ok(accepted.metrics.semantic_sparse_bright_pixel_fraction >= 0.005);
  assert.ok(accepted.metrics.semantic_sparse_chromatic_pixel_fraction >= 0.0008);

  const residual = { ...empty, raw: Buffer.from(empty.raw) };
  for (let index = 0; index < 1_200; index += 1) {
    const x = 8 + (index % 80);
    const y = 100 + Math.floor(index / 80);
    const offset = (y * residual.width + x) * 3;
    const chromatic = index < 160;
    residual.raw[offset] = chromatic ? 64 : 32;
    residual.raw[offset + 1] = chromatic ? 32 : 32;
    residual.raw[offset + 2] = chromatic ? 16 : 32;
  }
  const residualRejected = refineSparseSemanticMapClassification(base, residual, surfaceReadback);
  assert.equal(residualRejected.map_content, "BLACK_OR_EMPTY");
  assert.equal(residualRejected.committable, false);
  assert.equal(residualRejected.metrics.semantic_sparse_content_proof, false);

  const rejected = refineSparseSemanticMapClassification(base, empty, surfaceReadback);
  assert.equal(rejected.map_content, "BLACK_OR_EMPTY");
  assert.equal(rejected.committable, false);
  assert.equal(rejected.metrics.semantic_sparse_content_proof, false);

  const uncalibrated = refineSparseSemanticMapClassification(
    base,
    sparse,
    { surface: null, exact_match: false }
  );
  assert.equal(uncalibrated.map_content, "BLACK_OR_EMPTY");
});

test("semantic interior accepts sparse grayscale maps but rejects empty viewports", () => {
  const base = {
    connection: "CONNECTED",
    map_shell: "FLOATING_MAP_OPEN",
    overlay: "NONE",
    map_content: "BLACK_OR_EMPTY",
    committable: true,
    metrics: {},
  };
  const empty = { width: 768, height: 839, raw: Buffer.alloc(768 * 839 * 3) };
  const grayscale = { ...empty, raw: Buffer.from(empty.raw) };
  for (let index = 0; index < 2_600; index += 1) {
    const x = 220 + (index % 130);
    const y = 130 + Math.floor(index / 130);
    const offset = (y * grayscale.width + x) * 3;
    grayscale.raw[offset] = 48;
    grayscale.raw[offset + 1] = 48;
    grayscale.raw[offset + 2] = 48;
  }

  const accepted = requireSemanticInteriorMapContent(base, grayscale);
  assert.equal(accepted.map_content, "NONBLACK_CONTENT");
  assert.equal(accepted.committable, true);
  assert.ok(accepted.metrics.semantic_interior_grayscale_bright_pixel_fraction >= 0.02);

  const rejected = requireSemanticInteriorMapContent(base, empty);
  assert.equal(rejected.map_content, "BLACK_OR_EMPTY");
  assert.equal(rejected.committable, false);
});

test("adapter calibration identifies Ardougne Underground without changing the reviewed package", async () => {
  const calibration = path.join(root, "calibrations", "ardougne-underground-closed.jpeg");
  const classification = await classifyCapture(calibration);
  assert.deepEqual(
    pick(classification, ["connection", "map_shell", "overlay", "map_content", "committable"]),
    {
      connection: "CONNECTED",
      map_shell: "FLOATING_MAP_OPEN",
      overlay: "NONE",
      map_content: "NONBLACK_CONTENT",
      committable: true
    }
  );
  assert.equal(classification.surface_readback.surface, "Ardougne Underground");
  assert.equal(classification.surface_readback.exact_match, true);
  assert.equal(
    classification.surface_readback.calibration,
    "ADAPTER_OWNED_NORMALIZED_CORRELATION"
  );
  assert.ok(classification.surface_readback.normalized_correlation >= 0.72);
  assert.ok(classification.surface_readback.correlation_separation >= 0.08);
});

test("all reviewed recovery fixtures retain their exact geometry family", async () => {
  const fixtures = [
    ["recovery-try-again.jpeg", "TRY_AGAIN", "RECOVERY_768x861"],
    ["recovery-steam-sign-in.jpeg", "STEAM_SIGN_IN", "RECOVERY_768x861"],
    ["recovery-connecting.jpeg", "CONNECTING", "RECOVERY_768x861"],
    ["recovery-click-to-play.jpeg", "CLICK_TO_PLAY", "GAMEPLAY_MAP_768x839"],
    ["recovery-gameplay-no-map.jpeg", "GAMEPLAY_NO_MAP", "GAMEPLAY_MAP_768x839"],
    ["context-menu-open-map.jpeg", "CONTEXT_MENU_OPEN_MAP", "GAMEPLAY_MAP_768x839"]
  ];
  for (const [file, state, family] of fixtures) {
    const classification = await classifyCapture(path.join(reviewed, "templates", file));
    assert.equal(classification.recovery_state, state);
    assert.equal(classification.normalization.family, family);
    assert.equal(classification.committable, false);
  }
});

test("exact C3 capture is recognized as noncommittable TRY_AGAIN", async (context) => {
  const c3 = "/Users/miyawaki/Library/Application Support/OSRS Explorer Adapter/evidence/adapter-c3-transition-20260804T044611Z/captures/fa6e20a3-026e-4a97-bd2f-59c9c01e00e4.png";
  try {
    await fs.access(c3);
  } catch {
    context.skip("immutable C3 evidence is unavailable on this host");
    return;
  }
  assert.equal(sha256(await fs.readFile(c3)), "05bc2e8ebafd668e3ad4334879efa18fd7b4c78ef5113cdd99ab323c9609f22d");
  const classification = await classifyCapture(c3);
  assert.equal(classification.recovery_state, "TRY_AGAIN");
  assert.equal(classification.normalization.family, "RECOVERY_768x861");
  assert.equal(classification.committable, false);
  assert.deepEqual(classification.recovery_localization.source_click_point, { x: 786, y: 688 });
  await assert.rejects(requireAuthorizedOSRSMap(c3), /UNKNOWN_OR_UNAUTHORIZED_OSRS_SCREEN/);
  const readiness = await readOSRSReadiness(c3);
  assert.equal(readiness.status, "RECOGNIZED_RECOVERY:TRY_AGAIN");
  assert.deepEqual(readiness.suggested_operation, {
    kind: "click",
    point: { x: 786, y: 688 },
    button: "left"
  });
});

test("reviewed gameplay map control recommends the current direct opener", async () => {
  const gameplay = path.join(reviewed, "templates", "recovery-gameplay-no-map.jpeg");
  const readiness = await readOSRSReadiness(gameplay);
  assert.equal(readiness.status, "RECOGNIZED_RECOVERY:GAMEPLAY_NO_MAP");
  assert.deepEqual(readiness.suggested_operation, {
    kind: "open_world_map"
  });
});

test("native ScreenCaptureKit geometry normalizes to the reviewed frame contract", async () => {
  const source = path.join(reviewed, "templates", "gielinor-surface-closed.png");
  const native = path.join(os.tmpdir(), `osrs-native-frame-${process.pid}-${Date.now()}.png`);
  try {
    await sharp(source).resize(1614, 1762, { fit: "fill" }).png().toFile(native);
    const classification = await classifyCapture(native);
    assert.deepEqual(
      pick(classification, ["connection", "map_shell", "overlay", "map_content", "committable"]),
      {
        connection: "CONNECTED",
        map_shell: "FLOATING_MAP_OPEN",
        overlay: "NONE",
        map_content: "NONBLACK_CONTENT",
        committable: true
      }
    );
    assert.deepEqual(classification.normalization, {
      source_width: 1614,
      source_height: 1762,
      reviewed_width: 768,
      reviewed_height: 839,
      family: "GAMEPLAY_MAP_768x839",
      aspect_ratio_error: classification.normalization.aspect_ratio_error,
      mode: "SCREEN_CAPTURE_KIT_TO_REVIEWED_FRAME_FAMILY"
    });
  } finally {
    await fs.rm(native, { force: true });
  }
});

test("live resizable gameplay geometry selects the closest reviewed family", async () => {
  const source = path.join(reviewed, "templates", "recovery-gameplay-no-map.jpeg");
  const live = path.join(os.tmpdir(), `osrs-live-resizable-frame-${process.pid}-${Date.now()}.png`);
  try {
    await sharp(source).resize(1614, 1722, { fit: "fill" }).png().toFile(live);
    const readiness = await readOSRSReadiness(live);
    assert.equal(readiness.status, "RECOGNIZED_RECOVERY:GAMEPLAY_NO_MAP");
    assert.equal(readiness.classification.normalization.family, "GAMEPLAY_MAP_768x839");
    assert.equal(readiness.classification.normalization.source_width, 1614);
    assert.equal(readiness.classification.normalization.source_height, 1722);
  } finally {
    await fs.rm(live, { force: true });
  }
});

test("live resizable disconnect geometry recognizes its compatible recovery family", async () => {
  const source = path.join(reviewed, "templates", "recovery-try-again.jpeg");
  const live = path.join(os.tmpdir(), `osrs-live-resizable-disconnect-${process.pid}-${Date.now()}.png`);
  try {
    await sharp(source).resize(1572, 1722, { fit: "fill" }).png().toFile(live);
    const readiness = await readOSRSReadiness(live);
    assert.equal(readiness.status, "RECOGNIZED_RECOVERY:TRY_AGAIN");
    assert.equal(readiness.classification.normalization.family, "RECOVERY_768x861");
    assert.equal(readiness.classification.normalization.source_width, 1572);
    assert.equal(readiness.classification.normalization.source_height, 1722);
    assert.deepEqual(
      readiness.classification.recovery_localization.source_frame_geometry,
      { width: 1572, height: 1722 }
    );
    assert.deepEqual(
      readiness.suggested_operation.point,
      readiness.classification.recovery_localization.source_click_point
    );
  } finally {
    await fs.rm(live, { force: true });
  }
});

test("narrow login layout preserves reviewed recovery control geometry by width", async () => {
  const source = path.join(reviewed, "templates", "recovery-click-to-play.jpeg");
  const narrow = path.join(os.tmpdir(), `osrs-narrow-login-${process.pid}-${Date.now()}.png`);
  try {
    const scaled = await sharp(source)
      .resize({ width: 828 })
      .png()
      .toBuffer({ resolveWithObject: true });
    await sharp(scaled.data)
      .extend({
        bottom: 1722 - scaled.info.height,
        background: { r: 0, g: 0, b: 0, alpha: 1 },
      })
      .png()
      .toFile(narrow);
    const readiness = await readOSRSReadiness(narrow);
    assert.equal(readiness.status, "RECOGNIZED_RECOVERY:CLICK_TO_PLAY");
    assert.equal(readiness.classification.normalization.family, "GAMEPLAY_MAP_768x839");
    assert.equal(
      readiness.classification.normalization.mode,
      "SCREEN_CAPTURE_KIT_WIDTH_PRESERVING_TOP_CROP_OR_PAD"
    );
    assert.deepEqual(
      readiness.classification.recovery_localization.source_frame_geometry,
      { width: 828, height: 1722 }
    );
    assert.deepEqual(
      readiness.suggested_operation.point,
      readiness.classification.recovery_localization.source_click_point
    );
  } finally {
    await fs.rm(narrow, { force: true });
  }
});

test("live narrow click-to-play capture retains unique reviewed control localization", async (context) => {
  const live = "/Users/miyawaki/Library/Application Support/OSRS Explorer Adapter/evidence/adapter-recovery-steam-20260809T180827Z/captures/404691ec-2d83-4067-8932-a759d5f770f3.png";
  try {
    await fs.access(live);
  } catch {
    context.skip("immutable narrow click-to-play evidence is unavailable on this host");
    return;
  }
  assert.equal(
    sha256(await fs.readFile(live)),
    "8f645f02431aa6b4f05fb947292b5e3584796f0ccda016ac3eee03eea3ded131"
  );
  const readiness = await readOSRSReadiness(live);
  assert.equal(readiness.status, "RECOGNIZED_RECOVERY:CLICK_TO_PLAY");
  assert.ok(readiness.classification.recovery_localization.normalized_correlation >= 0.72);
  assert.ok(
    readiness.classification.recovery_localization.normalized_correlation
      - readiness.classification.recovery_localization.distinct_second_correlation >= 0.08
  );
  assert.deepEqual(readiness.suggested_operation, {
    kind: "click",
    point: readiness.classification.recovery_localization.source_click_point,
    button: "left",
  });
});

test("capture normalization rejects an incompatible aspect ratio", async () => {
  const source = path.join(reviewed, "templates", "gielinor-surface-closed.png");
  const square = path.join(os.tmpdir(), `osrs-square-frame-${process.pid}-${Date.now()}.png`);
  try {
    await sharp(source).resize(1000, 1000, { fit: "fill" }).png().toFile(square);
    await assert.rejects(classifyCapture(square), /UNSUPPORTED_OSRS_CAPTURE_ASPECT_RATIO/);
    const readiness = await readOSRSReadiness(square);
    assert.equal(readiness.status, "PRECISELY_BLOCKED");
    assert.equal(readiness.reason, "UNSUPPORTED_OSRS_CAPTURE_ASPECT_RATIO");
  } finally {
    await fs.rm(square, { force: true });
  }
});

test("capture normalization rejects the ambiguous intermediate family gap", async () => {
  const source = path.join(reviewed, "templates", "gielinor-surface-closed.png");
  const intermediate = path.join(os.tmpdir(), `osrs-intermediate-frame-${process.pid}-${Date.now()}.png`);
  try {
    await sharp(source).resize(768, 850, { fit: "fill" }).png().toFile(intermediate);
    await assert.rejects(classifyCapture(intermediate), /AMBIGUOUS_OSRS_CAPTURE_ASPECT_RATIO/);
  } finally {
    await fs.rm(intermediate, { force: true });
  }
});

test("surface and zoom localization replay", async () => {
  const config = JSON.parse(await fs.readFile(path.join(reviewed, "config", "explorer-v4-config.json"), "utf8"));
  for (const value of Object.values(config.templates)) {
    value.path = path.join(reviewed, "templates", path.basename(value.path));
  }
  const templates = await loadTemplates(config);
  const file = path.join(reviewed, "templates", "gielinor-surface-closed.png");
  const bytes = await fs.readFile(file);
  const observation = { ...(await decodeImage(bytes)), sha256: sha256(bytes) };
  const selector = localizeSelector(observation, templates);
  assert.equal(selector.exactly_one_target, true);
  assert.equal(selector.click_point_inside_observed_bounds, true);
  const surface = readObservedSurface(observation, templates);
  assert.equal(surface.surface, "Gielinor Surface");
  assert.equal(surface.exact_match, true);
  for (const direction of ["minus", "plus"]) {
    const zoom = localizeZoomControl(observation, templates, direction);
    assert.equal(zoom.exactly_one_target, true);
    assert.equal(zoom.click_point_inside_observed_bounds, true);
  }
});

test("open selector recovery localizes the calibrated toggle", async () => {
  const file = path.join(reviewed, "templates", "surface-selector-open.jpeg");
  const classification = await classifyCapture(file);
  assert.equal(classification.overlay, "SURFACE_SELECTOR");
  assert.equal(classification.committable, false);
  const selector = await localizeOpenSemanticSurfaceSelectorToggle(file);
  assert.equal(selector.exactly_one_target, true);
  assert.equal(selector.click_point_inside_observed_bounds, true);
  assert.deepEqual(selector.source_click_point, { x: 349, y: 660 });
});

test("axis gate and novelty remain fail closed", () => {
  assert.deepEqual(
    evaluateAxisCommitGate({
      axes: { connection: "CONNECTED", map_shell: "FLOATING_MAP_OPEN", overlay: "NONE", map_content: "NONBLACK_CONTENT" },
      requestedSurface: "Gielinor Surface",
      observedSurface: "Gielinor Surface",
      requestedZoom: 100,
      observedZoom: 100
    }),
    { passed: true, failures: [] }
  );
  const unchanged = Buffer.alloc(64 * 64 * 3, 120);
  const novelty = evaluateNovelty({
    preRaw: unchanged,
    postRaw: unchanged,
    sameFamilyRaw: unchanged,
    width: 64,
    height: 64,
    thresholds: {
      pre_post_mean_abs_minimum: 1,
      same_family_mean_abs_minimum: 1,
      delivered_displacement_minimum_cells: 2,
      new_extent_mean_abs_minimum: 2
    }
  });
  assert.equal(novelty.passed, false);
  assert.equal(novelty.pre_post_mean_abs, 0);
});

test("inherited lifecycle drains with zero late work", async () => {
  let contexts = 0;
  const lifecycle = createExecutionLifecycle({
    identity: "adapter-replay",
    assertActiveExecutionContext: async () => { contexts += 1; }
  });
  lifecycle.setReservationReceipt({ reservation_id: "reservation", reservation_sha256: "a".repeat(64) });
  const result = await lifecycle.runOperation("root", "unit", async () => 42);
  assert.equal(result, 42);
  lifecycle.closeAdmission();
  lifecycle.markControllerInactive();
  await lifecycle.drain();
  const quiescence = lifecycle.measuredQuiescence();
  assert.equal(contexts, 2);
  assert.equal(quiescence.zero_outstanding, true);
  assert.equal(quiescence.no_background_promise_after_return, true);
});

function pick(value, keys) {
  return Object.fromEntries(keys.map((key) => [key, value[key]]));
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
