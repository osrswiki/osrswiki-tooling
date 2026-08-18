import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import sharp from "sharp";

import {
  buildTemplate,
  classifyDecodedFrame,
  decodeImage,
  loadTemplates,
  localizeSelector,
  localizeZoomControl,
  readObservedSurface as readReviewedSurface,
  sha256
} from "../derived/reviewed-v4/runtime/explorer-v4-runtime.mjs";
import { loadSemanticCalibrationRegistry } from "./semantic-profile.mjs";
import {
  isNativeRealmLabel,
  selectorRowLocalization,
} from "./native-realm-catalog.mjs";

const workerRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const reviewedRoot = path.join(workerRoot, "derived", "reviewed-v4");
const calibrationRoot = path.join(workerRoot, "calibrations");
const ardougneCalibration = Object.freeze({
  path: path.join(calibrationRoot, "ardougne-underground-closed.jpeg"),
  sha256: "ddb1b32ed453be04b8ecf98ce2ef164e58c99c0ab3d66f821fefd27d1eae08ca"
});
let templatesPromise;
const reviewedFrameWidth = 768;
const maximumAspectRatioError = 0.06;
const minimumAspectRatioErrorSeparation = 0.01;
const frameFamilies = Object.freeze([
  Object.freeze({ id: "GAMEPLAY_MAP_768x839", width: 768, height: 839 }),
  Object.freeze({ id: "RECOVERY_768x861", width: 768, height: 861 })
]);
const recoveryFamilyByState = Object.freeze({
  TRY_AGAIN: "RECOVERY_768x861",
  STEAM_SIGN_IN: "RECOVERY_768x861",
  CONNECTING: "RECOVERY_768x861",
  CLICK_TO_PLAY: "GAMEPLAY_MAP_768x839",
  GAMEPLAY_NO_MAP: "GAMEPLAY_MAP_768x839",
  CONTEXT_MENU_OPEN_MAP: "GAMEPLAY_MAP_768x839"
});
const recoveryStatesWithoutLocalization = new Set(["CONNECTING", "GAMEPLAY_NO_MAP"]);
const recoveryReferenceBoxes = Object.freeze({
  TRY_AGAIN: Object.freeze({ left: 314, top: 317, right: 454, bottom: 356 }),
  STEAM_SIGN_IN: Object.freeze({ left: 244, top: 255, right: 523, bottom: 295 }),
  CLICK_TO_PLAY: Object.freeze({ left: 320, top: 330, right: 470, bottom: 375 }),
  GAMEPLAY_NO_MAP: Object.freeze({ left: 690, top: 147, right: 725, bottom: 184 }),
  CONTEXT_MENU_OPEN_MAP: Object.freeze({ left: 634, top: 197, right: 705, bottom: 214 })
});
const recoverySearchPadding = Object.freeze({ horizontal: 30, vertical: 44 });
const contextMenuSearchRegion = Object.freeze({ left: 610, top: 175, right: 740, bottom: 240 });
const minimumNormalizedCorrelation = 0.72;
const minimumCorrelationSeparation = 0.08;
const maximumUnprovenSelectorOverlayScore = 20;
// Stay inside the unobscured map viewport. The fixed Key panel, map close
// control, selector, and zoom controls must never satisfy the content gate.
const sparseMapViewport = Object.freeze({ left: 190, top: 90, width: 280, height: 400 });
const semanticMapCloseControl = Object.freeze({ left: 486, top: 35, right: 516, bottom: 70 });
const minimumSparseBrightPixelFraction = 0.0045;
const minimumSparseChromaticPixelFraction = 0.0006;
const minimumSparseGrayscaleBrightPixelFraction = 0.01;

export async function classifyCapture(pngPath) {
  const templates = await reviewedTemplates();
  const bytes = await fs.readFile(pngPath);
  const source = await sharp(bytes).metadata();
  if (!source.width || !source.height) {
    throw new Error("INVALID_OSRS_CAPTURE_GEOMETRY");
  }
  let family;
  try {
    family = selectFrameFamily(source.width, source.height);
  } catch (error) {
    if (error?.message !== "UNSUPPORTED_OSRS_CAPTURE_ASPECT_RATIO") throw error;
    const recovery = await recognizeRecoveryInWidthPreservingFamilies({
      bytes,
      source,
      templates,
    });
    if (!recovery) throw error;
    return buildCaptureClassification({
      base: recovery.base,
      recovery,
      source,
      family: recovery.family,
      surfaceReadback: null,
    });
  }
  const decoded = await decodeFrameFamily(bytes, family);
  const selectorClassification = classifySemanticSelector(
    classifyDecodedFrame(decoded, templates),
    decoded,
    templates
  );
  const surfaceReadback = selectorClassification.map_shell === "FLOATING_MAP_OPEN"
      && selectorClassification.overlay === "NONE"
    ? readCalibratedSurface(decoded, templates)
    : null;
  const base = requireSemanticInteriorMapContent(refineSparseSemanticMapClassification(
    selectorClassification,
    decoded,
    surfaceReadback
  ), decoded);
  const recovery = base.map_shell === "FLOATING_MAP_OPEN"
    ? null
    : await recognizeRecoveryAcrossCompatibleFamilies({
        bytes,
        source,
        templates,
        primaryFamily: family,
        primaryObservation: decoded,
        primaryBase: base,
      });
  return buildCaptureClassification({
    base,
    recovery,
    source,
    family,
    surfaceReadback,
  });
}

export async function classifySemanticPostCloseCapture(pngPath) {
  return refineSemanticPostCloseClassification(await classifyCapture(pngPath));
}

export function refineSemanticPostCloseClassification(classification) {
  if (classification.recovery_state === "GAMEPLAY_NO_MAP") return classification;
  const metrics = classification.metrics ?? {};
  const toleratesTransientCloseTooltip = classification.overlay === "SURFACE_SELECTOR"
    && metrics.hud_stddev > 40;
  if (classification.map_shell !== "UNKNOWN"
      || (classification.overlay !== "UNKNOWN" && !toleratesTransientCloseTooltip)
      || classification.map_content !== "NONBLACK_CONTENT"
      || metrics.geometry !== true
      || metrics.close_orange_fraction > 0.002
      || metrics.controls_stddev <= 7
      || metrics.hud_stddev <= 8
      || classification.normalization?.family !== "GAMEPLAY_MAP_768x839") {
    return classification;
  }
  return {
    ...classification,
    connection: "CONNECTED",
    overlay: "UNKNOWN",
    recovery_state: "GAMEPLAY_NO_MAP",
    committable: false,
    metrics: {
      ...metrics,
      semantic_post_close_gameplay_hud_proof: true,
    },
  };
}

function buildCaptureClassification({ base, recovery, source, family, surfaceReadback }) {
  const classificationFamily = recovery?.family ?? family;
  const classification = recovery
    ? applyRecoveryClassification(base, recovery)
    : base;
  return {
    ...classification,
    surface_readback: surfaceReadback,
    recovery_localization: recovery?.localization
      ? toSourceLocalization(recovery.localization, source, classificationFamily)
      : null,
    normalization: {
      source_width: source.width,
      source_height: source.height,
      reviewed_width: classificationFamily.width,
      reviewed_height: classificationFamily.height,
      family: classificationFamily.id,
      aspect_ratio_error: classificationFamily.aspectRatioError,
      mode: classificationFamily.normalizationMode
        ?? "SCREEN_CAPTURE_KIT_TO_REVIEWED_FRAME_FAMILY"
    }
  };
}

export async function requireAuthorizedOSRSMap(pngPath) {
  const classification = await classifyCapture(pngPath);
  if (!isAuthorizedMapClassification(classification)) {
    throw new Error(`UNKNOWN_OR_UNAUTHORIZED_OSRS_SCREEN:${JSON.stringify(classification)}`);
  }
  return classification;
}

export async function requireAuthorizedOSRSCoverageMap(pngPath, requestedSurface) {
  const classification = await classifyCapture(pngPath);
  const proof = semanticCoverageReadinessFromClassification(classification, requestedSurface);
  if (!proof.passed) {
    throw new Error(
      `UNKNOWN_OR_UNAUTHORIZED_OSRS_COVERAGE_SCREEN:${JSON.stringify(classification)}`
    );
  }
  return classification;
}

export async function requireAuthorizedOSRSSelector(pngPath) {
  const classification = await classifyCapture(pngPath);
  if (!isAuthorizedSelectorClassification(classification)) {
    throw new Error(`UNKNOWN_OR_UNAUTHORIZED_OSRS_SELECTOR:${JSON.stringify(classification)}`);
  }
  return classification;
}

export async function localizeSemanticSurfaceSelector(pngPath) {
  const { source, family, decoded, templates, classification } = await semanticObservation(pngPath);
  if (!isAuthorizedMapClassification(classification)) {
    throw new Error("SEMANTIC_SELECTOR_REQUIRES_QUALIFIED_MAP");
  }
  return reviewedLocalizationToSource(localizeSelector(decoded, templates), source, family);
}

export async function localizeSemanticMapClose(pngPath) {
  const { source, family, classification } = await semanticObservation(pngPath);
  if (!isAuthorizedMapClassification(classification)) {
    throw new Error("SEMANTIC_MAP_CLOSE_REQUIRES_QUALIFIED_MAP");
  }
  return toSourceLocalization({
    target: "SEMANTIC_MAP_CLOSE_CONTROL",
    exactly_one_target: true,
    normalized_observed_bbox: semanticMapCloseControl,
    normalized_click_point: { x: 500, y: 50 },
    localization_mode: "REVIEWED_NORMALIZED_CONTROL_GEOMETRY",
  }, source, family);
}

export async function localizeSemanticCoverageMapClose(pngPath, requestedSurface) {
  const { source, family, classification } = await semanticObservation(pngPath);
  const proof = semanticCoverageReadinessFromClassification(classification, requestedSurface);
  if (!isAuthorizedMapClassification(classification) && !proof.passed) {
    throw new Error("SEMANTIC_COVERAGE_MAP_CLOSE_REQUIRES_QUALIFIED_MAP");
  }
  return toSourceLocalization({
    target: "SEMANTIC_MAP_CLOSE_CONTROL",
    exactly_one_target: true,
    normalized_observed_bbox: semanticMapCloseControl,
    normalized_click_point: { x: 500, y: 50 },
    localization_mode: "REVIEWED_NORMALIZED_CONTROL_GEOMETRY",
  }, source, family);
}

export async function localizeOpenSemanticSurfaceSelectorToggle(pngPath) {
  const { source, family, decoded, templates, classification } = await semanticObservation(pngPath);
  if (classification.connection !== "CONNECTED"
      || classification.map_shell !== "FLOATING_MAP_OPEN"
      || classification.overlay !== "SURFACE_SELECTOR"
      || classification.committable !== false) {
    throw new Error("SEMANTIC_SELECTOR_RECOVERY_REQUIRES_OPEN_SELECTOR");
  }
  return reviewedLocalizationToSource(localizeSelector(decoded, templates), source, family);
}

export async function localizeSemanticSurfaceOption(
  pngPath,
  requestedSurface,
  { nativeCatalog = false } = {}
) {
  const { source, family, decoded, templates, classification } = await semanticObservation(pngPath);
  if (classification.overlay !== "SURFACE_SELECTOR") {
    throw new Error("SEMANTIC_SURFACE_SELECTOR_NOT_OPEN");
  }
  const registry = loadSemanticCalibrationRegistry();
  const calibration = registry.surfaces?.[requestedSurface];
  const option = calibration?.option_reference_box;
  if (nativeCatalog || !option) {
    if (!isNativeRealmLabel(requestedSurface)) {
      throw new Error(`SEMANTIC_SURFACE_OPTION_UNSUPPORTED:${requestedSurface}`);
    }
    const scrollbar = await observeSemanticSurfaceScrollbar(pngPath, requestedSurface);
    const geometric = selectorRowLocalization(requestedSurface, scrollbar);
    return toSourceLocalization(
      {
        ...snapNativeSelectorOptionPixelRow(decoded, geometric),
        normalized_frame_sha256: decoded.sha256,
        normalized_frame_geometry: { width: decoded.width, height: decoded.height },
      },
      source,
      family
    );
  }
  const selectorTemplate = calibration.selector_navigation
    ? templates.semanticSelectorTemplates?.[requestedSurface]
    : templates.surfaceSelectorOpen;
  if (!selectorTemplate) {
    throw new Error(`SEMANTIC_SELECTOR_NAVIGATION_CALIBRATION_NOT_REVIEWED:${requestedSurface}`);
  }
  const label = `SEMANTIC_SURFACE_OPTION:${requestedSurface}`;
  let localization = calibration.selector_navigation
    ? semanticOptionPixelLocalization(
        decoded,
        selectorTemplate,
        option,
        registry.surface_option_search_region,
        label
      )
    : locateUniqueNormalizedPatch(
        decoded,
        selectorTemplate,
        option,
        registry.surface_option_search_region,
        label
      );
  if (!calibration.selector_navigation) {
    localization = visibleSurfaceOptionClickLocalization(localization);
  }
  return toSourceLocalization(localization, source, family);
}

export function snapNativeSelectorOptionPixelRow(observation, geometric) {
  const region = { left: 166, top: 533, right: 342, bottom: 645 };
  if (observation?.width !== 768
      || observation?.height !== 839
      || !Buffer.isBuffer(observation?.raw)
      || observation.raw.length !== observation.width * observation.height * 3
      || !Number.isInteger(geometric?.selector_index)
      || !Number.isInteger(geometric?.visible_top_index)
      || !Number.isInteger(geometric?.normalized_click_point?.y)) {
    throw new Error("NATIVE_SELECTOR_PIXEL_ROW_OBSERVATION_INVALID");
  }

  const activeRows = [];
  for (let y = region.top; y < region.bottom; y += 1) {
    let count = 0;
    let minimumX = region.right;
    let maximumX = region.left - 1;
    for (let x = region.left; x < region.right; x += 1) {
      const offset = (y * observation.width + x) * 3;
      const red = observation.raw[offset];
      const green = observation.raw[offset + 1];
      const blue = observation.raw[offset + 2];
      const selectorOrange = red >= 150
        && green >= 55
        && green <= 220
        && blue <= 110
        && red >= green * 1.08
        && red >= blue * 1.5;
      if (!selectorOrange) continue;
      count += 1;
      minimumX = Math.min(minimumX, x);
      maximumX = Math.max(maximumX, x);
    }
    if (count >= 2) activeRows.push({ y, minimumX, maximumX });
  }

  const bands = [];
  for (const row of activeRows) {
    const current = bands.at(-1);
    if (!current || row.y > current.bottom + 2) {
      bands.push({
        top: row.y,
        bottom: row.y,
        left: row.minimumX,
        right: row.maximumX,
      });
      continue;
    }
    current.bottom = row.y;
    current.left = Math.min(current.left, row.minimumX);
    current.right = Math.max(current.right, row.maximumX);
  }
  const optionBands = bands.filter((band) => band.bottom - band.top + 1 >= 4);
  if (optionBands.length < 7 || optionBands.length > 8) {
    throw new Error(`NATIVE_SELECTOR_PIXEL_ROW_COUNT_INVALID:${optionBands.length}`);
  }

  const catalogRowMetrics = [
    [74, 9], [70, 9], [128, 11], [109, 11], [85, 11], [81, 9], [51, 9],
    [66, 11], [70, 9], [112, 11], [120, 11], [107, 11], [90, 11], [93, 11],
    [46, 11], [140, 11], [103, 11], [93, 9], [84, 9], [79, 9], [103, 11],
    [46, 9], [50, 9], [108, 11], [105, 9], [42, 11], [137, 11], [61, 9],
    [46, 9], [112, 11], [109, 11], [93, 9], [143, 11], [103, 11], [114, 11],
    [130, 11], [101, 11], [48, 11], [50, 9], [72, 11], [133, 11], [108, 11],
    [91, 11], [134, 11], [101, 11], [92, 11], [34, 9],
  ];
  const observedMetrics = optionBands.map((band) => [
    band.right - band.left + 1,
    band.bottom - band.top + 1,
  ]);
  const windowScores = [];
  for (let topIndex = 0; topIndex <= catalogRowMetrics.length - observedMetrics.length; topIndex += 1) {
    let error = 0;
    for (let row = 0; row < observedMetrics.length; row += 1) {
      error += Math.abs(observedMetrics[row][0] - catalogRowMetrics[topIndex + row][0]);
      error += 3 * Math.abs(observedMetrics[row][1] - catalogRowMetrics[topIndex + row][1]);
    }
    windowScores.push({ topIndex, score: Math.max(0, 1 - error / 400) });
  }
  windowScores.sort((left, right) => right.score - left.score || left.topIndex - right.topIndex);
  const matchedWindow = windowScores[0];
  const secondWindow = windowScores[1];
  const selectedOrdinal = geometric.selector_index - matchedWindow.topIndex;
  if (matchedWindow.score < 0.72
      || matchedWindow.score - secondWindow.score < 0.08
      || selectedOrdinal < 0
      || selectedOrdinal >= optionBands.length
      || Math.abs(matchedWindow.topIndex - geometric.visible_top_index) > 1) {
    throw new Error("NATIVE_SELECTOR_PIXEL_ROW_AMBIGUOUS");
  }

  const predictedY = geometric.normalized_click_point.y;
  const selected = optionBands[selectedOrdinal];
  const selectedCenter = Math.floor((selected.top + selected.bottom + 1) / 2);
  const selectedDistance = Math.abs(selectedCenter - predictedY);
  const measuredVisibleTopIndex = matchedWindow.topIndex;
  if (selectedDistance > 16
      || Math.abs(measuredVisibleTopIndex - geometric.visible_top_index) > 1
      || measuredVisibleTopIndex < 0
      || measuredVisibleTopIndex > 39) {
    throw new Error("NATIVE_SELECTOR_PIXEL_ROW_AMBIGUOUS");
  }

  return {
    ...geometric,
    visible_top_index: measuredVisibleTopIndex,
    visible_row_index: selectedOrdinal,
    geometry_predicted_bbox: geometric.normalized_observed_bbox,
    normalized_observed_bbox: {
      left: region.left,
      top: selected.top,
      right: 349,
      bottom: selected.bottom + 1,
    },
    normalized_click_point: { x: 257, y: selectedCenter },
    pixel_text_bbox: {
      left: selected.left,
      top: selected.top,
      right: selected.right + 1,
      bottom: selected.bottom + 1,
    },
    pixel_row_ordinal: selectedOrdinal,
    detected_row_count: optionBands.length,
    observed_row_metrics: observedMetrics.map(([width, height], ordinal) => ({
      ordinal,
      width,
      height,
    })),
    catalog_window_score: matchedWindow.score,
    catalog_window_second_score: secondWindow.score,
    catalog_window_separation: matchedWindow.score - secondWindow.score,
    geometric_click_delta_y: selectedCenter - predictedY,
    click_anchor: "PIXEL_LOCALIZED_TEXT_ROW_CENTER",
    proof_method: "NATIVE_SELECTOR_CATALOG_PIXEL_WINDOW_V5",
    proof:
      "The complete eight-row pixel signature uniquely identifies the visible catalog window; the click uses the requested catalog row inside that measured window.",
  };
}

export async function localizeSemanticSurfaceScrollbar(pngPath, requestedSurface, anchor) {
  if (!["top", "bottom"].includes(anchor)) {
    throw new Error(`SEMANTIC_SURFACE_SCROLLBAR_UNSUPPORTED:${requestedSurface}:${anchor}`);
  }
  const observation = await observeSemanticSurfaceScrollbar(pngPath, requestedSurface);
  if (observation.state !== anchor) {
    throw new Error(
      `SEMANTIC_SELECTOR_SCROLLBAR_${anchor.toUpperCase()}_UNPROVEN:`
      + `${observation.state}:top_clearance=${observation.top_clearance_pixels}:`
      + `bottom_clearance=${observation.bottom_clearance_pixels}`
    );
  }
  return { ...observation, anchor, thumb_at_stop: true };
}

export async function observeSemanticSurfaceScrollbar(pngPath, requestedSurface) {
  const { source, family, decoded, templates, classification } = await semanticObservation(pngPath);
  if (classification.overlay !== "SURFACE_SELECTOR") {
    throw new Error("SEMANTIC_SURFACE_SELECTOR_NOT_OPEN");
  }
  const registry = loadSemanticCalibrationRegistry();
  const scrollbar = registry.surface_selector_scrollbar;
  const calibration = registry.surfaces?.[requestedSurface];
  if (!scrollbar || !isNativeRealmLabel(requestedSurface)) {
    throw new Error(`SEMANTIC_SURFACE_SCROLLBAR_UNSUPPORTED:${requestedSurface}`);
  }
  const scrollbarTemplates = templates.semanticScrollbarTemplates;
  if (!scrollbarTemplates?.top || !scrollbarTemplates?.bottom) {
    throw new Error("SEMANTIC_SELECTOR_SCROLLBAR_THUMB_TEMPLATE_MISSING");
  }
  const measurement = measureSemanticSurfaceScrollbarPixels(
    decoded,
    scrollbarTemplates,
    scrollbar
  );
  const converted = toSourceLocalization(measurement, source, family);
  const sourceTrack = toSourceBox(measurement.normalized_track_bbox, source, family);
  return {
    ...converted,
    anchor: measurement.state,
    selector_open: true,
    thumb_at_stop: measurement.state === "top" || measurement.state === "bottom",
    normalized_track_bbox: measurement.normalized_track_bbox,
    source_track_bbox: sourceTrack,
    source_up_button_bbox: toSourceBox(measurement.normalized_up_button_bbox, source, family),
    source_down_button_bbox: toSourceBox(measurement.normalized_down_button_bbox, source, family),
    source_top_clearance_pixels:
      converted.source_observed_bbox.top - sourceTrack.top,
    source_bottom_clearance_pixels:
      sourceTrack.bottom - converted.source_observed_bbox.bottom,
  };
}

export function measureSemanticSurfaceScrollbarPixels(observation, templates, scrollbar) {
  const topTemplate = templates?.top ?? templates;
  const bottomTemplate = templates?.bottom ?? templates;
  const referenceTrack = scrollbar?.track_reference_box;
  const searchRegion = scrollbar?.search_region;
  const upReference = scrollbar?.up_button_reference_box;
  const downReference = scrollbar?.down_button_reference_box;
  const thumb = scrollbar?.thumb_reference_size;
  if (scrollbar?.coordinate_semantics !== "LEFT_TOP_INCLUSIVE_RIGHT_BOTTOM_EXCLUSIVE"
      || scrollbar?.stop_tolerance_pixels !== 0
      || !topTemplate || !bottomTemplate
      || !referenceTrack || !searchRegion || !upReference || !downReference || !thumb
      || thumb.width !== referenceTrack.right - referenceTrack.left
      || thumb.height <= 0
      || searchRegion.left < 0
      || searchRegion.top < 0
      || searchRegion.right > observation?.width
      || searchRegion.bottom > observation?.height
      || referenceTrack.bottom - referenceTrack.top < thumb.height) {
    throw new Error("SEMANTIC_SELECTOR_SCROLLBAR_PIXEL_PROFILE_INVALID");
  }
  const upButton = locateUniquePixelPatch(
    observation,
    topTemplate,
    upReference,
    searchRegion,
    "SEMANTIC_SELECTOR_SCROLLBAR_UP_BUTTON"
  );
  const downButton = locateUniquePixelPatch(
    observation,
    topTemplate,
    downReference,
    searchRegion,
    "SEMANTIC_SELECTOR_SCROLLBAR_DOWN_BUTTON"
  );
  const track = {
    left: upButton.normalized_observed_bbox.left,
    top: upButton.normalized_observed_bbox.bottom,
    right: upButton.normalized_observed_bbox.right,
    bottom: downButton.normalized_observed_bbox.top,
  };
  if (downButton.normalized_observed_bbox.left !== track.left
      || downButton.normalized_observed_bbox.right !== track.right
      || track.right - track.left !== referenceTrack.right - referenceTrack.left
      || track.bottom - track.top !== referenceTrack.bottom - referenceTrack.top) {
    throw new Error("PRECISELY_BLOCKED_NO_CLICK:SEMANTIC_SELECTOR_SCROLLBAR:TRACK_GEOMETRY_MISMATCH");
  }
  const referenceBox = {
    left: referenceTrack.left,
    top: referenceTrack.top,
    right: referenceTrack.left + thumb.width,
    bottom: referenceTrack.top + thumb.height,
  };
  const bottomReferenceBox = {
    left: referenceTrack.left,
    top: referenceTrack.bottom - thumb.height,
    right: referenceTrack.left + thumb.width,
    bottom: referenceTrack.bottom,
  };
  const maximumTop = track.bottom - thumb.height;
  const candidates = [];
  for (let top = track.top; top <= maximumTop; top += 1) {
    const topScore = normalizedPatchCorrelation(
      observation,
      topTemplate,
      referenceBox,
      track.left,
      top
    );
    // The bottom template captures endpoint-only Retina rendering. Intermediate
    // positions retain the top-state thumb appearance and are measured with
    // the top template at every pixel.
    const bottomScore = templates?.bottom && top === maximumTop
      ? normalizedPatchCorrelation(
        observation,
        bottomTemplate,
        bottomReferenceBox,
        track.left,
        top
      )
      : Number.NEGATIVE_INFINITY;
    candidates.push({
      top,
      score: Math.max(topScore, bottomScore),
      template_role: topScore >= bottomScore ? "top" : "bottom",
    });
  }
  candidates.sort((first, second) => second.score - first.score);
  const best = candidates[0];
  const second = best && candidates.find((candidate) =>
    candidate.top + thumb.height <= best.top || candidate.top >= best.top + thumb.height
  );
  if (!best
      || !second
      || !Number.isFinite(best.score)
      || best.score < minimumNormalizedCorrelation
      || best.score - second.score < minimumCorrelationSeparation) {
    throw new Error("PRECISELY_BLOCKED_NO_CLICK:SEMANTIC_SELECTOR_SCROLLBAR:AMBIGUOUS_PIXEL_GEOMETRY");
  }
  const observedBox = {
    left: track.left,
    top: best.top,
    right: track.left + thumb.width,
    bottom: best.top + thumb.height,
  };
  const topClearance = observedBox.top - track.top;
  const bottomClearance = track.bottom - observedBox.bottom;
  const topBounds = { minimum: track.top, maximum: track.top };
  const bottomTop = track.bottom - thumb.height;
  const bottomBounds = { minimum: bottomTop, maximum: bottomTop };
  const atTop = insideInclusive(best.top, topBounds);
  const atBottom = insideInclusive(best.top, bottomBounds);
  const state = atTop ? "top" : atBottom ? "bottom" : "intermediate";
  return {
    target: "SEMANTIC_SURFACE_SCROLLBAR_THUMB",
    calibration_template_sha256:
      best.template_role === "bottom" ? bottomTemplate.sha256 : topTemplate.sha256,
    calibration_template_role: best.template_role,
    normalized_frame_sha256: observation.sha256,
    normalized_frame_geometry: { width: observation.width, height: observation.height },
    normalized_track_bbox: track,
    normalized_observed_bbox: observedBox,
    normalized_click_point: {
      x: Math.floor((observedBox.left + observedBox.right) / 2),
      y: Math.floor((observedBox.top + observedBox.bottom) / 2),
    },
    normalized_correlation: best.score,
    distinct_second_correlation: second.score,
    correlation_separation: best.score - second.score,
    exactly_one_target: true,
    pixel_resolution: 1,
    coordinate_semantics: scrollbar.coordinate_semantics,
    stop_tolerance_pixels: scrollbar.stop_tolerance_pixels,
    normalized_up_button_bbox: upButton.normalized_observed_bbox,
    normalized_down_button_bbox: downButton.normalized_observed_bbox,
    up_button_correlation: upButton.normalized_correlation,
    up_button_distinct_second_correlation: upButton.distinct_second_correlation,
    down_button_correlation: downButton.normalized_correlation,
    down_button_distinct_second_correlation: downButton.distinct_second_correlation,
    state,
    top_clearance_pixels: topClearance,
    bottom_clearance_pixels: bottomClearance,
    remaining_travel_to_top_pixels: topClearance,
    remaining_travel_to_bottom_pixels: bottomClearance,
    travel_range_pixels: maximumTop - track.top,
    top_stop_thumb_top_bounds: topBounds,
    bottom_stop_thumb_top_bounds: bottomBounds,
  };
}

export async function localizeSemanticZoom(pngPath, direction) {
  if (direction !== "minus" && direction !== "plus") {
    throw new Error("SEMANTIC_ZOOM_DIRECTION_INVALID");
  }
  const { source, family, decoded, templates, classification } = await semanticObservation(pngPath);
  if (!isAuthorizedMapClassification(classification)) {
    throw new Error("SEMANTIC_ZOOM_REQUIRES_QUALIFIED_MAP");
  }
  return reviewedLocalizationToSource(
    localizeZoomControl(decoded, templates, direction),
    source,
    family
  );
}

export async function proveSemanticMapReadiness(pngPath, requestedSurface) {
  const classification = await classifyCapture(pngPath);
  const observedSurface = classification.surface_readback?.surface ?? null;
  return {
    passed: isAuthorizedMapClassification(classification)
      && observedSurface === requestedSurface
      && classification.surface_readback?.exact_match === true,
    requested_surface: requestedSurface,
    observed_surface: observedSurface,
    surface_readback: classification.surface_readback,
    axes: {
      connection: classification.connection,
      map_shell: classification.map_shell,
      overlay: classification.overlay,
      map_content: classification.map_content,
    },
    nonblack: classification.map_content === "NONBLACK_CONTENT",
  };
}

export async function proveSemanticCoverageReadiness(pngPath, requestedSurface) {
  return semanticCoverageReadinessFromClassification(
    await classifyCapture(pngPath),
    requestedSurface
  );
}

export function semanticCoverageReadinessFromClassification(classification, requestedSurface) {
  const observedSurface = classification.surface_readback?.surface ?? null;
  return {
    passed: classification.connection === "CONNECTED"
      && classification.map_shell === "FLOATING_MAP_OPEN"
      && classification.overlay === "NONE"
      && observedSurface === requestedSurface
      && classification.surface_readback?.exact_match === true
      && classification.normalization?.family === "GAMEPLAY_MAP_768x839",
    requested_surface: requestedSurface,
    observed_surface: observedSurface,
    surface_readback: classification.surface_readback,
    axes: {
      connection: classification.connection,
      map_shell: classification.map_shell,
      overlay: classification.overlay,
      map_content: classification.map_content,
    },
    nonblack: classification.map_content === "NONBLACK_CONTENT",
    coverage_content_delegated: true,
  };
}

export async function readOSRSReadiness(pngPath) {
  try {
    const classification = await classifyCapture(pngPath);
    if (isAuthorizedMapClassification(classification)) {
      return { status: "MAP_READY", classification };
    }
    if (classification.recovery_state) {
      const result = {
        status: `RECOGNIZED_RECOVERY:${classification.recovery_state}`,
        classification
      };
      if (classification.recovery_state === "GAMEPLAY_NO_MAP") {
        result.suggested_operation = { kind: "open_world_map" };
      } else if (classification.recovery_localization) {
        result.suggested_operation = {
          kind: "click",
          point: classification.recovery_localization.source_click_point,
          button: "left"
        };
      }
      return result;
    }
    return {
      status: "PRECISELY_BLOCKED",
      reason: "UNKNOWN_OR_AMBIGUOUS_OSRS_SCREEN",
      classification
    };
  } catch (error) {
    return {
      status: "PRECISELY_BLOCKED",
      reason: String(error?.message || error)
    };
  }
}

export function isAuthorizedMapClassification(classification) {
  return classification?.connection === "CONNECTED"
    && classification?.map_shell === "FLOATING_MAP_OPEN"
    && classification?.overlay === "NONE"
    && classification?.map_content === "NONBLACK_CONTENT"
    && classification?.committable === true
    && classification?.normalization?.family === "GAMEPLAY_MAP_768x839";
}

export function isAuthorizedSelectorClassification(classification) {
  return classification?.connection === "CONNECTED"
    && classification?.map_shell === "FLOATING_MAP_OPEN"
    && classification?.overlay === "SURFACE_SELECTOR"
    && classification?.map_content === "NONBLACK_CONTENT"
    && classification?.committable === false
    && classification?.normalization?.family === "GAMEPLAY_MAP_768x839";
}

function selectFrameFamily(width, height) {
  const candidates = compatibleFrameFamilies(width, height);
  if (candidates.length === 0) {
    throw new Error("UNSUPPORTED_OSRS_CAPTURE_ASPECT_RATIO");
  }
  if (
    candidates.length > 1
    && candidates[1].aspectRatioError - candidates[0].aspectRatioError
      < minimumAspectRatioErrorSeparation
  ) {
    throw new Error("AMBIGUOUS_OSRS_CAPTURE_ASPECT_RATIO");
  }
  return candidates[0];
}

function compatibleFrameFamilies(width, height) {
  return frameFamilies
    .map((family) => frameFamilyWithAspectRatioError(family, width, height))
    .filter(({ aspectRatioError }) => aspectRatioError <= maximumAspectRatioError)
    .sort((first, second) => first.aspectRatioError - second.aspectRatioError);
}

function frameFamilyWithAspectRatioError(family, width, height) {
  const sourceAspectRatio = width / height;
  const reviewedAspectRatio = family.width / family.height;
  return {
    ...family,
    aspectRatioError: Math.abs(sourceAspectRatio - reviewedAspectRatio) / reviewedAspectRatio
  };
}

async function decodeFrameFamily(bytes, family) {
  const normalized = await sharp(bytes)
    .resize(family.width, family.height, { fit: "fill" })
    .png()
    .toBuffer();
  return {
    ...(await decodeImage(normalized)),
    sha256: sha256(normalized)
  };
}

async function decodeWidthPreservingTopFrame(bytes, family) {
  const resized = await sharp(bytes)
    .resize({ width: family.width })
    .png()
    .toBuffer({ resolveWithObject: true });
  let normalized = resized.data;
  if (resized.info.height > family.height) {
    normalized = await sharp(resized.data)
      .extract({ left: 0, top: 0, width: family.width, height: family.height })
      .png()
      .toBuffer();
  } else if (resized.info.height < family.height) {
    normalized = await sharp(resized.data)
      .extend({
        bottom: family.height - resized.info.height,
        background: { r: 0, g: 0, b: 0, alpha: 1 },
      })
      .png()
      .toBuffer();
  }
  return {
    ...(await decodeImage(normalized)),
    sha256: sha256(normalized)
  };
}

async function recognizeRecoveryInWidthPreservingFamilies({ bytes, source, templates }) {
  for (const reviewedFamily of frameFamilies) {
    const family = {
      ...frameFamilyWithAspectRatioError(
        reviewedFamily,
        source.width,
        source.height
      ),
      normalizationMode: "SCREEN_CAPTURE_KIT_WIDTH_PRESERVING_TOP_CROP_OR_PAD",
      sourcePointScale: source.width / reviewedFamily.width,
    };
    const observation = await decodeWidthPreservingTopFrame(bytes, family);
    const base = classifySemanticSelector(
      classifyDecodedFrame(observation, templates),
      observation,
      templates
    );
    if (base.map_shell === "FLOATING_MAP_OPEN") continue;
    const recovery = recognizeRecovery(observation, templates, family, base);
    if (recovery) return { ...recovery, family, base };
  }
  return null;
}

async function recognizeRecoveryAcrossCompatibleFamilies({
  bytes,
  source,
  templates,
  primaryFamily,
  primaryObservation,
  primaryBase,
}) {
  const primaryRecovery = recognizeRecovery(
    primaryObservation,
    templates,
    primaryFamily,
    primaryBase
  );
  if (primaryRecovery) return { ...primaryRecovery, family: primaryFamily };

  for (const family of compatibleFrameFamilies(source.width, source.height)) {
    if (family.id === primaryFamily.id) continue;
    const observation = await decodeFrameFamily(bytes, family);
    const base = classifySemanticSelector(
      classifyDecodedFrame(observation, templates),
      observation,
      templates
    );
    const recovery = recognizeRecovery(observation, templates, family, base);
    if (recovery) return { ...recovery, family };
  }
  return null;
}

function recognizeRecovery(observation, templates, family, base) {
  const baseState = base.recovery_state;
  if (baseState && recoveryFamilyByState[baseState] === family.id) {
    return {
      state: baseState,
      localization: recoveryStatesWithoutLocalization.has(baseState)
        ? null
        : localizeRecoveryState(observation, templates, baseState)
    };
  }

  const candidates = Object.entries(recoveryFamilyByState)
    .filter(([state, familyID]) =>
      familyID === family.id && !recoveryStatesWithoutLocalization.has(state)
    )
    .flatMap(([state]) => {
      try {
        return [{ state, localization: localizeRecoveryState(observation, templates, state) }];
      } catch {
        return [];
      }
    })
    .sort((first, second) =>
      second.localization.normalized_correlation - first.localization.normalized_correlation
    );
  if (candidates.length === 0) return null;
  if (
    candidates.length > 1
    && candidates[0].localization.normalized_correlation
      - candidates[1].localization.normalized_correlation < minimumCorrelationSeparation
  ) {
    throw new Error("PRECISELY_BLOCKED_RECOVERY_STATE_AMBIGUOUS");
  }
  return candidates[0];
}

function localizeRecoveryState(observation, templates, state) {
  const referenceBox = recoveryReferenceBoxes[state];
  const template = state === "CONTEXT_MENU_OPEN_MAP"
    ? templates.floatingWorldMapItem
    : templates.recovery?.[state];
  if (!referenceBox || !template) {
    throw new Error(`PRECISELY_BLOCKED_RECOVERY_TEMPLATE_MISSING:${state}`);
  }
  const searchRegion = state === "CONTEXT_MENU_OPEN_MAP"
    ? contextMenuSearchRegion
    : {
        left: Math.max(0, referenceBox.left - recoverySearchPadding.horizontal),
        top: Math.max(0, referenceBox.top - recoverySearchPadding.vertical),
        right: Math.min(observation.width, referenceBox.right + recoverySearchPadding.horizontal),
        bottom: Math.min(observation.height, referenceBox.bottom + recoverySearchPadding.vertical)
      };
  return locateUniqueNormalizedPatch(
    observation,
    template,
    referenceBox,
    searchRegion,
    state
  );
}

function locateUniqueNormalizedPatch(observation, template, referenceBox, searchRegion, label) {
  const width = referenceBox.right - referenceBox.left;
  const height = referenceBox.bottom - referenceBox.top;
  const candidates = [];
  for (let top = searchRegion.top; top <= searchRegion.bottom - height; top += 2) {
    for (let left = searchRegion.left; left <= searchRegion.right - width; left += 2) {
      candidates.push({
        left,
        top,
        score: normalizedPatchCorrelation(
          observation,
          template,
          referenceBox,
          left,
          top
        )
      });
    }
  }
  candidates.sort((first, second) => second.score - first.score);
  const best = candidates[0];
  const distinct = best && candidates.find((candidate) =>
    Math.abs(candidate.left - best.left) >= Math.max(6, width * 0.08)
      || Math.abs(candidate.top - best.top) >= Math.max(6, height * 0.08)
  );
  if (
    !best
    || !Number.isFinite(best.score)
    || best.score < minimumNormalizedCorrelation
    || !distinct
    || best.score - distinct.score < minimumCorrelationSeparation
  ) {
    throw new Error(`PRECISELY_BLOCKED_NO_CLICK:${label}:AMBIGUOUS_LOCALIZATION`);
  }
  const observedBox = {
    left: best.left,
    top: best.top,
    right: best.left + width,
    bottom: best.top + height
  };
  return {
    target: label,
    normalized_frame_sha256: observation.sha256,
    normalized_frame_geometry: { width: observation.width, height: observation.height },
    search_region: searchRegion,
    normalized_observed_bbox: observedBox,
    normalized_click_point: {
      x: Math.floor((observedBox.left + observedBox.right) / 2),
      y: Math.floor((observedBox.top + observedBox.bottom) / 2)
    },
    normalized_correlation: best.score,
    distinct_second_correlation: distinct.score,
    exactly_one_target: true
  };
}

function locateUniquePixelPatch(observation, template, referenceBox, searchRegion, label) {
  const width = referenceBox.right - referenceBox.left;
  const height = referenceBox.bottom - referenceBox.top;
  const candidates = [];
  for (let top = searchRegion.top; top <= searchRegion.bottom - height; top += 1) {
    for (let left = searchRegion.left; left <= searchRegion.right - width; left += 1) {
      candidates.push({
        left,
        top,
        score: normalizedPatchCorrelation(
          observation,
          template,
          referenceBox,
          left,
          top,
          1
        ),
      });
    }
  }
  candidates.sort((first, second) => second.score - first.score);
  const best = candidates[0];
  const distinct = best && candidates.find((candidate) =>
    candidate.left + width <= best.left
      || candidate.left >= best.left + width
      || candidate.top + height <= best.top
      || candidate.top >= best.top + height
  );
  if (!best
      || !distinct
      || !Number.isFinite(best.score)
      || best.score < minimumNormalizedCorrelation
      || best.score - distinct.score < minimumCorrelationSeparation) {
    throw new Error(`PRECISELY_BLOCKED_NO_CLICK:${label}:AMBIGUOUS_PIXEL_GEOMETRY`);
  }
  return {
    normalized_observed_bbox: {
      left: best.left,
      top: best.top,
      right: best.left + width,
      bottom: best.top + height,
    },
    normalized_correlation: best.score,
    distinct_second_correlation: distinct.score,
  };
}

function semanticOptionPixelLocalization(
  observation,
  template,
  referenceBox,
  searchRegion,
  label
) {
  const pixel = locateUniquePixelPatch(
    observation,
    template,
    referenceBox,
    searchRegion,
    label
  );
  const observedBox = pixel.normalized_observed_bbox;
  return {
    target: label,
    normalized_frame_sha256: observation.sha256,
    normalized_frame_geometry: { width: observation.width, height: observation.height },
    search_region: searchRegion,
    ...pixel,
    normalized_click_point: {
      x: Math.floor((observedBox.left + observedBox.right) / 2),
      y: Math.floor((observedBox.top + observedBox.bottom) / 2),
    },
    exactly_one_target: true,
    pixel_resolution: 1,
  };
}

function visibleSurfaceOptionClickLocalization(localization) {
  const observedBox = localization.normalized_observed_bbox;
  return {
    ...localization,
    normalized_click_point: {
      x: Math.floor((observedBox.left + observedBox.right) / 2),
      y: Math.min(observedBox.bottom - 1, observedBox.top + 2),
    },
    click_anchor: "PIXEL_LOCALIZED_ROW_TOP_INSET",
  };
}

function normalizedPatchCorrelation(
  observation,
  template,
  referenceBox,
  candidateLeft,
  candidateTop,
  sampleStep = 2
) {
  let observationSum = 0;
  let templateSum = 0;
  let count = 0;
  for (let y = 0; y < referenceBox.bottom - referenceBox.top; y += sampleStep) {
    for (let x = 0; x < referenceBox.right - referenceBox.left; x += sampleStep) {
      observationSum += luminance(
        observation.raw,
        ((candidateTop + y) * observation.width + candidateLeft + x) * 3
      );
      templateSum += luminance(
        template.raw,
        ((referenceBox.top + y) * template.width + referenceBox.left + x) * 3
      );
      count += 1;
    }
  }
  if (count === 0) return Number.NEGATIVE_INFINITY;
  const observationMean = observationSum / count;
  const templateMean = templateSum / count;
  let numerator = 0;
  let observationSquares = 0;
  let templateSquares = 0;
  for (let y = 0; y < referenceBox.bottom - referenceBox.top; y += sampleStep) {
    for (let x = 0; x < referenceBox.right - referenceBox.left; x += sampleStep) {
      const observationValue = luminance(
        observation.raw,
        ((candidateTop + y) * observation.width + candidateLeft + x) * 3
      ) - observationMean;
      const templateValue = luminance(
        template.raw,
        ((referenceBox.top + y) * template.width + referenceBox.left + x) * 3
      ) - templateMean;
      numerator += observationValue * templateValue;
      observationSquares += observationValue * observationValue;
      templateSquares += templateValue * templateValue;
    }
  }
  const denominator = Math.sqrt(observationSquares * templateSquares);
  return denominator > 0 ? numerator / denominator : Number.NEGATIVE_INFINITY;
}

function luminance(raw, index) {
  return 0.299 * raw[index] + 0.587 * raw[index + 1] + 0.114 * raw[index + 2];
}

function insideInclusive(value, bounds) {
  return Number.isInteger(bounds?.minimum)
    && Number.isInteger(bounds?.maximum)
    && bounds.minimum <= bounds.maximum
    && value >= bounds.minimum
    && value <= bounds.maximum;
}

function applyRecoveryClassification(base, recovery) {
  const connected = recovery.state === "GAMEPLAY_NO_MAP"
    || recovery.state === "CONTEXT_MENU_OPEN_MAP";
  return {
    ...base,
    connection: connected ? "CONNECTED" : recovery.state,
    map_shell: recovery.state === "CONTEXT_MENU_OPEN_MAP" ? "CLOSED" : "UNKNOWN",
    overlay: recovery.state === "CONTEXT_MENU_OPEN_MAP"
      ? "CONTEXT_MENU_OPEN_MAP"
      : "UNKNOWN",
    recovery_state: recovery.state,
    committable: false,
    metrics: {
      ...base.metrics,
      recovery_normalized_correlation:
        recovery.localization?.normalized_correlation ?? null
    }
  };
}

function toSourceLocalization(localization, source, family) {
  const sourcePoint = (point) => toSourcePoint(point, source, family);
  return {
    ...localization,
    source_frame_geometry: { width: source.width, height: source.height },
    source_observed_bbox: {
      left: sourcePoint({
        x: localization.normalized_observed_bbox.left,
        y: localization.normalized_observed_bbox.top
      }).x,
      top: sourcePoint({
        x: localization.normalized_observed_bbox.left,
        y: localization.normalized_observed_bbox.top
      }).y,
      right: sourcePoint({
        x: localization.normalized_observed_bbox.right,
        y: localization.normalized_observed_bbox.bottom
      }).x,
      bottom: sourcePoint({
        x: localization.normalized_observed_bbox.right,
        y: localization.normalized_observed_bbox.bottom
      }).y
    },
    source_click_point: sourcePoint(localization.normalized_click_point)
  };
}

function toSourcePoint(point, source, family) {
  if (family.sourcePointScale) {
    return {
      x: Math.round(point.x * family.sourcePointScale),
      y: Math.round(point.y * family.sourcePointScale),
    };
  }
  return {
    x: Math.round((point.x * source.width) / family.width),
    y: Math.round((point.y * source.height) / family.height),
  };
}

function toSourceBox(box, source, family) {
  const topLeft = toSourcePoint({ x: box.left, y: box.top }, source, family);
  const bottomRight = toSourcePoint({ x: box.right, y: box.bottom }, source, family);
  return { left: topLeft.x, top: topLeft.y, right: bottomRight.x, bottom: bottomRight.y };
}

async function reviewedTemplates() {
  if (!templatesPromise) {
    templatesPromise = (async () => {
      const configPath = path.join(reviewedRoot, "config", "explorer-v4-config.json");
      const config = JSON.parse(await fs.readFile(configPath, "utf8"));
      for (const template of Object.values(config.templates)) {
        template.path = path.join(reviewedRoot, "templates", path.basename(template.path));
      }
      const registry = loadSemanticCalibrationRegistry();
      const semanticSurfaceTemplates = {};
      const semanticSelectorTemplates = {};
      for (const [surface, calibration] of Object.entries(registry.surfaces)) {
        if (!calibration.absolute_closed_template) continue;
        semanticSurfaceTemplates[surface] = await buildTemplate({
          path: calibration.absolute_closed_template,
          sha256: calibration.closed_template_sha256,
        });
        if (calibration.absolute_selector_open_template) {
          semanticSelectorTemplates[surface] = await buildTemplate({
            path: calibration.absolute_selector_open_template,
            sha256: calibration.selector_open_template_sha256,
          });
        }
      }
      return {
        ...(await loadTemplates(config)),
        ardougneClosed: await buildTemplate(ardougneCalibration),
        semanticScrollbarTemplates: {
          top: await buildTemplate({
            path: registry.surface_selector_scrollbar.absolute_reference_template,
            sha256: registry.surface_selector_scrollbar.reference_template_sha256,
          }),
          bottom: await buildTemplate({
            path: registry.surface_selector_scrollbar.absolute_bottom_reference_template,
            sha256: registry.surface_selector_scrollbar.bottom_reference_template_sha256,
          }),
        },
        semanticSurfaceTemplates,
        semanticSelectorTemplates,
      };
    })();
  }
  return templatesPromise;
}

function readCalibratedSurface(observation, templates) {
  const reviewed = readReviewedSurface(observation, templates);
  if (!reviewed.selector_localization) return reviewed;
  const registry = loadSemanticCalibrationRegistry();
  const defaultReferenceBox = { left: 180, top: 651, right: 332, bottom: 669 };
  const candidateLeft = reviewed.selector_localization.observed_bbox.left - 160;
  const candidateTop = reviewed.selector_localization.observed_bbox.top + 1;
  const scores = {};
  for (const [surface, template] of Object.entries(templates.semanticSurfaceTemplates ?? {})) {
    const referenceBox = registry.surfaces?.[surface]?.closed_reference_box
      ?? defaultReferenceBox;
    scores[surface] = normalizedPatchCorrelation(
      observation,
      template,
      referenceBox,
      candidateLeft,
      candidateTop
    );
  }
  const ordered = Object.entries(scores).sort((first, second) => second[1] - first[1]);
  const [surface, score] = ordered[0];
  const next = ordered[1]?.[1] ?? Number.NEGATIVE_INFINITY;
  const exactMatch = score >= minimumNormalizedCorrelation
    && score - next >= minimumCorrelationSeparation;
  return {
    ...reviewed,
    surface: exactMatch ? surface : null,
    scores,
    exact_match: exactMatch,
    calibration: "ADAPTER_OWNED_NORMALIZED_CORRELATION",
    normalized_correlation: score,
    distinct_second_correlation: next,
    correlation_separation: score - next,
  };
}

async function semanticObservation(pngPath) {
  const templates = await reviewedTemplates();
  const bytes = await fs.readFile(pngPath);
  const source = await sharp(bytes).metadata();
  if (!source.width || !source.height) throw new Error("INVALID_OSRS_CAPTURE_GEOMETRY");
  const family = selectFrameFamily(source.width, source.height);
  const normalized = await sharp(bytes)
    .resize(family.width, family.height, { fit: "fill" })
    .png()
    .toBuffer();
  const decoded = { ...(await decodeImage(normalized)), sha256: sha256(normalized) };
  const selectorClassification = classifySemanticSelector(
    classifyDecodedFrame(decoded, templates),
    decoded,
    templates
  );
  const surfaceReadback = selectorClassification.map_shell === "FLOATING_MAP_OPEN"
      && selectorClassification.overlay === "NONE"
    ? readCalibratedSurface(decoded, templates)
    : null;
  const base = refineSparseSemanticMapClassification(
    selectorClassification,
    decoded,
    surfaceReadback
  );
  const classification = {
    ...base,
    surface_readback: surfaceReadback,
    normalization: {
      source_width: source.width,
      source_height: source.height,
      reviewed_width: family.width,
      reviewed_height: family.height,
      family: family.id,
      aspect_ratio_error: family.aspectRatioError,
      mode: "SCREEN_CAPTURE_KIT_TO_REVIEWED_FRAME_FAMILY",
    },
  };
  return { source, family, decoded, templates, base, classification };
}

function classifySemanticSelector(base, decoded, templates) {
  if (base.map_shell !== "FLOATING_MAP_OPEN"
      || !["NONE", "SURFACE_SELECTOR"].includes(base.overlay)) return base;
  const scrollbar = loadSemanticCalibrationRegistry().surface_selector_scrollbar;
  if (!scrollbar
      || !templates.semanticScrollbarTemplates?.top
      || !templates.semanticScrollbarTemplates?.bottom) {
    return refineSemanticSelectorClassification(base);
  }
  try {
    const measurement = measureSemanticSurfaceScrollbarPixels(
      decoded,
      templates.semanticScrollbarTemplates,
      scrollbar
    );
    return refineSemanticSelectorClassification(base, measurement);
  } catch {
    return refineSemanticSelectorClassification(base);
  }
}

export function refineSparseSemanticMapClassification(base, observation, surfaceReadback) {
  if (base.map_shell !== "FLOATING_MAP_OPEN"
      || base.overlay !== "NONE"
      || base.map_content !== "BLACK_OR_EMPTY"
      || surfaceReadback?.exact_match !== true
      || !surfaceReadback.surface) {
    return base;
  }
  const metrics = sparseSemanticMapMetrics(observation);
  const contentProven = sparseSemanticMapContentProven(metrics);
  if (!contentProven) {
    return {
      ...base,
      metrics: {
        ...base.metrics,
        semantic_sparse_content_proof: false,
        semantic_sparse_bright_pixel_fraction: metrics.bright_pixel_fraction,
        semantic_sparse_chromatic_pixel_fraction: metrics.chromatic_pixel_fraction,
        semantic_sparse_grayscale_bright_pixel_fraction:
          metrics.grayscale_bright_pixel_fraction,
      },
    };
  }
  return {
    ...base,
    map_content: "NONBLACK_CONTENT",
    committable: true,
    metrics: {
      ...base.metrics,
      semantic_sparse_content_proof: true,
      semantic_sparse_bright_pixel_fraction: metrics.bright_pixel_fraction,
      semantic_sparse_chromatic_pixel_fraction: metrics.chromatic_pixel_fraction,
      semantic_sparse_grayscale_bright_pixel_fraction: metrics.grayscale_bright_pixel_fraction,
    },
  };
}

export function requireSemanticInteriorMapContent(base, observation) {
  if (base.map_shell !== "FLOATING_MAP_OPEN" || base.overlay !== "NONE") return base;
  const metrics = sparseSemanticMapMetrics(observation);
  const contentProven = sparseSemanticMapContentProven(metrics);
  return {
    ...base,
    map_content: contentProven ? "NONBLACK_CONTENT" : "BLACK_OR_EMPTY",
    committable: base.committable === true && contentProven,
    metrics: {
      ...base.metrics,
      semantic_interior_content_proof: contentProven,
      semantic_interior_bright_pixel_fraction: metrics.bright_pixel_fraction,
      semantic_interior_chromatic_pixel_fraction: metrics.chromatic_pixel_fraction,
      semantic_interior_grayscale_bright_pixel_fraction:
        metrics.grayscale_bright_pixel_fraction,
    },
  };
}

function sparseSemanticMapMetrics(observation) {
  const right = Math.min(observation.width, sparseMapViewport.left + sparseMapViewport.width);
  const bottom = Math.min(observation.height, sparseMapViewport.top + sparseMapViewport.height);
  let brightPixels = 0;
  let chromaticPixels = 0;
  let grayscaleBrightPixels = 0;
  let pixels = 0;
  for (let y = sparseMapViewport.top; y < bottom; y += 1) {
    for (let x = sparseMapViewport.left; x < right; x += 1) {
      const offset = (y * observation.width + x) * 3;
      const red = observation.raw[offset];
      const green = observation.raw[offset + 1];
      const blue = observation.raw[offset + 2];
      const maximum = Math.max(red, green, blue);
      const minimum = Math.min(red, green, blue);
      if (maximum >= 24) brightPixels += 1;
      if (maximum >= 18 && maximum - minimum >= 12) chromaticPixels += 1;
      if (maximum >= 24 && maximum - minimum < 12) grayscaleBrightPixels += 1;
      pixels += 1;
    }
  }
  return {
    bright_pixel_fraction: pixels === 0 ? 0 : brightPixels / pixels,
    chromatic_pixel_fraction: pixels === 0 ? 0 : chromaticPixels / pixels,
    grayscale_bright_pixel_fraction: pixels === 0 ? 0 : grayscaleBrightPixels / pixels,
  };
}

function sparseSemanticMapContentProven(metrics) {
  return metrics.bright_pixel_fraction >= minimumSparseBrightPixelFraction
    && (metrics.chromatic_pixel_fraction >= minimumSparseChromaticPixelFraction
      || metrics.grayscale_bright_pixel_fraction
        >= minimumSparseGrayscaleBrightPixelFraction);
}

export function refineSemanticSelectorClassification(base, measurement = null) {
  if (measurement) {
    return {
      ...base,
      overlay: "SURFACE_SELECTOR",
      committable: false,
      metrics: {
        ...base.metrics,
        selector_scrollbar_pixel_state: measurement.state,
        selector_scrollbar_top_clearance_pixels: measurement.top_clearance_pixels,
        selector_scrollbar_bottom_clearance_pixels: measurement.bottom_clearance_pixels,
      },
    };
  }
  if (base.overlay !== "SURFACE_SELECTOR"
      || base.metrics?.selector_overlay_score <= maximumUnprovenSelectorOverlayScore) {
    return base;
  }
  return {
    ...base,
    overlay: "NONE",
    committable: base.map_content === "NONBLACK_CONTENT",
    metrics: {
      ...base.metrics,
      selector_overlay_coarse_match_rejected: true,
    },
  };
}

function reviewedLocalizationToSource(localization, source, family) {
  const sourcePoint = (point) => ({
    x: Math.round((point.x * source.width) / family.width),
    y: Math.round((point.y * source.height) / family.height),
  });
  const observed = localization.observed_bbox;
  return {
    ...localization,
    source_frame_geometry: { width: source.width, height: source.height },
    source_observed_bbox: {
      left: sourcePoint({ x: observed.left, y: observed.top }).x,
      top: sourcePoint({ x: observed.left, y: observed.top }).y,
      right: sourcePoint({ x: observed.right, y: observed.bottom }).x,
      bottom: sourcePoint({ x: observed.right, y: observed.bottom }).y,
    },
    source_click_point: sourcePoint(localization.click_point),
  };
}
