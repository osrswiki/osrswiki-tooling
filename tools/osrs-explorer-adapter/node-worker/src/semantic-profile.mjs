import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import {
  SEMANTIC_CRITERION_FAMILIES,
  SEMANTIC_SURFACES,
  SEMANTIC_ZOOM_LEVELS,
  sha256,
} from "./protocol.mjs";
import {
  isNativeRealmLabel,
  nativeRealmLabels,
  nativeSelectorNavigation,
  selectorScrollbarVectorToThumbTop,
  semanticScrollbarAtPlannedPosition,
  semanticScrollbarLandingAccepted,
} from "./native-realm-catalog.mjs";

const workerRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const calibrationPath = path.join(workerRoot, "calibrations", "semantic-map-surfaces.json");

export const SEMANTIC_MATRIX_SURFACES = Object.freeze([
  "Gielinor Surface",
  "Ancient Cavern",
  "Ardougne Underground",
  "Asgarnia Ice Cave",
]);

export const REVIEWED_FRAME = Object.freeze({ width: 768, height: 839 });
export const CONTENT_CROP = Object.freeze({ left: 4, top: 70, width: 470, height: 560 });
export const MAP_CROP = Object.freeze({ left: 4, top: 35, width: 516, height: 641 });
// Both production crops exclude the close control above y=70 and all controls
// below y=620. Only the surface map has the fixed Key panel at x<178.
export const NATIVE_SURFACE_COVERAGE_CROP = Object.freeze({
  left: 178,
  top: 70,
  width: 338,
  height: 550,
});
export const NATIVE_REALM_COVERAGE_CROP = Object.freeze({
  left: 4,
  top: 70,
  width: 512,
  height: 550,
});
// Preserve the historical v10-v13 crop for retained queues and raw helpers.
// Production v14 items carry one of the new exact crops explicitly.
export const NATIVE_COVERAGE_CROP = Object.freeze({
  left: 178,
  top: 35,
  width: 310,
  height: 480,
});
export const MAP_ACTION_REGION = Object.freeze({
  left: CONTENT_CROP.left,
  top: CONTENT_CROP.top,
  right: CONTENT_CROP.left + CONTENT_CROP.width,
  bottom: CONTENT_CROP.top + CONTENT_CROP.height,
});
export const DISPLACEMENT_CELL_SIZE = 5;
export const MOTION_ANCHOR_TRANSLATION_MAXIMUM = 36;
const NEAR_PROFILE_RESTORATION_SNAP_CELLS = 2;
export const NOVELTY_THRESHOLDS = Object.freeze({
  pre_post_mean_abs_minimum: 2.5,
  same_family_mean_abs_minimum: 2.5,
  delivered_displacement_minimum_cells: 2,
  new_extent_mean_abs_minimum: 2,
  zoom_transition_mean_abs_minimum: 1.25,
  restored_displacement_maximum_cells: 1,
});
export const SELECTOR_SCROLLBAR = Object.freeze({
  coordinate_semantics: "LEFT_TOP_INCLUSIVE_RIGHT_BOTTOM_EXCLUSIVE",
  stop_tolerance_pixels: 0,
  search_region: Object.freeze({ left: 330, top: 525, right: 365, bottom: 655 }),
  up_button: Object.freeze({ left: 342, top: 529, right: 356, bottom: 543 }),
  down_button: Object.freeze({ left: 342, top: 629, right: 356, bottom: 643 }),
  track: Object.freeze({ left: 342, top: 543, right: 356, bottom: 629 }),
  thumb: Object.freeze({ width: 14, height: 16 }),
  top: Object.freeze({
    thumb_top_bounds: Object.freeze({ minimum: 543, maximum: 543 }),
    from: Object.freeze({ x: 349, y: 621 }),
    to: Object.freeze({ x: 349, y: 543 }),
  }),
  bottom: Object.freeze({
    thumb_top_bounds: Object.freeze({ minimum: 613, maximum: 613 }),
    from: Object.freeze({ x: 349, y: 551 }),
    to: Object.freeze({ x: 349, y: 628 }),
  }),
});
export const MOTION_VECTORS = Object.freeze({
  eastward_topology: Object.freeze({ from: Object.freeze({ x: 430, y: 300 }), to: Object.freeze({ x: 90, y: 300 }) }),
  southward_topology: Object.freeze({ from: Object.freeze({ x: 260, y: 560 }), to: Object.freeze({ x: 260, y: 150 }) }),
  westward_boundary: Object.freeze({ from: Object.freeze({ x: 90, y: 300 }), to: Object.freeze({ x: 430, y: 300 }) }),
  northward_detail: Object.freeze({ from: Object.freeze({ x: 260, y: 150 }), to: Object.freeze({ x: 260, y: 560 }) }),
  center_detail: Object.freeze({ from: Object.freeze({ x: 420, y: 520 }), to: Object.freeze({ x: 150, y: 210 }) }),
});

export function loadSemanticCalibrationRegistry({ requireAll = false } = {}) {
  const registry = JSON.parse(fs.readFileSync(calibrationPath, "utf8"));
  const scrollbar = registry.surface_selector_scrollbar;
  if (registry.schema_version !== 2
      || registry.reviewed_frame?.width !== REVIEWED_FRAME.width
      || registry.reviewed_frame?.height !== REVIEWED_FRAME.height
      || scrollbar?.coordinate_semantics !== SELECTOR_SCROLLBAR.coordinate_semantics
      || scrollbar?.stop_tolerance_pixels !== SELECTOR_SCROLLBAR.stop_tolerance_pixels
      || JSON.stringify(scrollbar?.search_region) !== JSON.stringify(SELECTOR_SCROLLBAR.search_region)
      || JSON.stringify(scrollbar?.up_button_reference_box) !== JSON.stringify(SELECTOR_SCROLLBAR.up_button)
      || JSON.stringify(scrollbar?.down_button_reference_box) !== JSON.stringify(SELECTOR_SCROLLBAR.down_button)
      || JSON.stringify(scrollbar?.track_reference_box) !== JSON.stringify(SELECTOR_SCROLLBAR.track)
      || JSON.stringify(scrollbar?.thumb_reference_size) !== JSON.stringify(SELECTOR_SCROLLBAR.thumb)
      || JSON.stringify(scrollbar?.top_stop_thumb_top_bounds)
        !== JSON.stringify(SELECTOR_SCROLLBAR.top.thumb_top_bounds)
      || JSON.stringify(scrollbar?.bottom_stop_thumb_top_bounds)
        !== JSON.stringify(SELECTOR_SCROLLBAR.bottom.thumb_top_bounds)
      || JSON.stringify(scrollbar?.top_stop_point) !== JSON.stringify(SELECTOR_SCROLLBAR.top.to)
      || JSON.stringify(scrollbar?.bottom_stop_point) !== JSON.stringify(SELECTOR_SCROLLBAR.bottom.to)
      || registry.terminal_selector_entry?.expected !== "Zanaris") {
    throw new Error("SEMANTIC_CALIBRATION_PROFILE_INVALID");
  }
  const scrollbarTemplate = path.resolve(
    path.dirname(calibrationPath),
    scrollbar.reference_template ?? ""
  );
  const scrollbarBottomTemplate = path.resolve(
    path.dirname(calibrationPath),
    scrollbar.bottom_reference_template ?? ""
  );
  if (!scrollbar.reference_template_sha256
      || !fs.existsSync(scrollbarTemplate)
      || sha256(fs.readFileSync(scrollbarTemplate)) !== scrollbar.reference_template_sha256
      || !scrollbar.bottom_reference_template_sha256
      || !fs.existsSync(scrollbarBottomTemplate)
      || sha256(fs.readFileSync(scrollbarBottomTemplate))
        !== scrollbar.bottom_reference_template_sha256) {
    throw new Error("SEMANTIC_SCROLLBAR_CALIBRATION_INVALID");
  }
  scrollbar.absolute_reference_template = scrollbarTemplate;
  scrollbar.absolute_bottom_reference_template = scrollbarBottomTemplate;
  const missing = [];
  const requiredSurfaces = new Set([...SEMANTIC_SURFACES, ...nativeRealmLabels()]);
  for (const surface of requiredSurfaces) {
    const calibration = registry.surfaces?.[surface];
    if (!calibration) throw new Error(`SEMANTIC_CALIBRATION_MISSING:${surface}`);
    const closedReference = calibration.closed_reference_box;
    if (closedReference
        && (closedReference.left < 0
          || closedReference.top < 0
          || closedReference.right > REVIEWED_FRAME.width
          || closedReference.bottom > REVIEWED_FRAME.height
          || closedReference.right - closedReference.left !== 152
          || closedReference.bottom - closedReference.top !== 18)) {
      throw new Error(`SEMANTIC_CALIBRATION_REFERENCE_BOX_INVALID:${surface}`);
    }
    if (!calibration.closed_template_sha256) {
      missing.push(`${surface}:closed_template`);
    } else {
      const absolute = path.resolve(path.dirname(calibrationPath), calibration.closed_template);
      if (!fs.existsSync(absolute)) throw new Error(`SEMANTIC_CALIBRATION_FILE_MISSING:${surface}`);
      const observed = sha256(fs.readFileSync(absolute));
      if (observed !== calibration.closed_template_sha256) {
        throw new Error(`SEMANTIC_CALIBRATION_SHA256_MISMATCH:${surface}`);
      }
      calibration.absolute_closed_template = absolute;
    }

    if (calibration.selector_navigation) {
      if (!calibration.selector_open_template_sha256) {
        missing.push(`${surface}:selector_open_template`);
      } else {
        const selectorTemplate = path.resolve(
          path.dirname(calibrationPath),
          calibration.selector_open_template
        );
        if (!fs.existsSync(selectorTemplate)) {
          throw new Error(`SEMANTIC_SELECTOR_CALIBRATION_FILE_MISSING:${surface}`);
        }
        const observed = sha256(fs.readFileSync(selectorTemplate));
        if (observed !== calibration.selector_open_template_sha256) {
          throw new Error(`SEMANTIC_SELECTOR_CALIBRATION_SHA256_MISMATCH:${surface}`);
        }
        calibration.absolute_selector_open_template = selectorTemplate;
      }
    }
  }
  const terminal = registry.terminal_selector_entry;
  if (terminal?.confirmed !== true || terminal?.observed !== terminal?.expected) {
    missing.push("terminal_selector_entry:confirmation");
  }
  if (requireAll && missing.length > 0) {
    throw new Error(`SEMANTIC_CALIBRATION_NOT_REVIEWED:${missing.join(",")}`);
  }
  return registry;
}

export function semanticSurfaceNavigation(surface, scrollbarObservation = null) {
  if (!isNativeRealmLabel(surface)) {
    throw new Error(`SEMANTIC_SURFACE_UNSUPPORTED:${surface}`);
  }
  if (scrollbarObservation) return nativeSelectorNavigation(surface, scrollbarObservation);
  const calibration = loadSemanticCalibrationRegistry().surfaces[surface];
  if (!calibration) {
    throw new Error(`SEMANTIC_SELECTOR_NAVIGATION_OBSERVATION_REQUIRED:${surface}`);
  }
  const configured = calibration.selector_navigation;
  if (!configured) {
    return Object.freeze({ required: false, mode: null, anchor: null, maximum_drags: 0 });
  }
  if (configured.mode !== "scrollbar_drag"
      || configured.anchor !== "bottom"
      || configured.maximum_drags !== 1) {
    throw new Error(`SEMANTIC_SELECTOR_NAVIGATION_INVALID:${surface}`);
  }
  return Object.freeze({ required: true, ...configured });
}

export function semanticScrollbarAtExactStop(proof, anchor) {
  if (!SELECTOR_SCROLLBAR[anchor]) return false;
  const track = proof?.normalized_track_bbox;
  const observed = proof?.normalized_observed_bbox;
  const upButton = proof?.normalized_up_button_bbox;
  const downButton = proof?.normalized_down_button_bbox;
  if (!validScrollbarGeometry(track, observed, upButton, downButton)) return false;
  const expectedTop = anchor === "top" ? track.top : track.bottom - SELECTOR_SCROLLBAR.thumb.height;
  const expectedBottom = expectedTop + SELECTOR_SCROLLBAR.thumb.height;
  const topClearance = expectedTop - track.top;
  const bottomClearance = track.bottom - expectedBottom;
  const travelRange = track.bottom - track.top - SELECTOR_SCROLLBAR.thumb.height;
  const correlation = proof?.normalized_correlation;
  const second = proof?.distinct_second_correlation;
  return proof?.target === "SEMANTIC_SURFACE_SCROLLBAR_THUMB"
    && proof?.anchor === anchor
    && proof?.state === anchor
    && proof?.selector_open === true
    && proof?.thumb_at_stop === true
    && proof?.exactly_one_target === true
    && proof?.pixel_resolution === 1
    && proof?.coordinate_semantics === SELECTOR_SCROLLBAR.coordinate_semantics
    && proof?.stop_tolerance_pixels === SELECTOR_SCROLLBAR.stop_tolerance_pixels
    && Number.isFinite(correlation)
    && correlation >= 0.72
    && Number.isFinite(second)
    && correlation - second >= 0.08
    && Math.abs(proof?.correlation_separation - (correlation - second)) < 1e-9
    && sameBox(proof?.normalized_observed_bbox, {
      left: track.left,
      top: expectedTop,
      right: track.right,
      bottom: expectedBottom,
    })
    && proof?.top_clearance_pixels === topClearance
    && proof?.bottom_clearance_pixels === bottomClearance
    && proof?.remaining_travel_to_top_pixels === topClearance
    && proof?.remaining_travel_to_bottom_pixels === bottomClearance
    && proof?.travel_range_pixels === travelRange
    && sameBounds(proof?.top_stop_thumb_top_bounds, { minimum: track.top, maximum: track.top })
    && sameBounds(proof?.bottom_stop_thumb_top_bounds, {
      minimum: track.bottom - SELECTOR_SCROLLBAR.thumb.height,
      maximum: track.bottom - SELECTOR_SCROLLBAR.thumb.height,
    })
    && buttonLocalizationPassed(proof, "up")
    && buttonLocalizationPassed(proof, "down");
}

export function validateSemanticQueueItem(item) {
  const production = item?.realm_id !== undefined
    || item?.catalog_version !== undefined
    || item?.coverage_cell !== undefined;
  if (item?.kind !== "semantic_map_capture"
      || !(SEMANTIC_SURFACES.includes(item.surface) || (production && isNativeRealmLabel(item.surface)))
      || !SEMANTIC_ZOOM_LEVELS.includes(item.zoom_percent)
      || !SEMANTIC_CRITERION_FAMILIES.includes(item.criterion_family)
      || typeof item.restore_after_capture !== "boolean") {
    throw new Error("SEMANTIC_ITEM_INVALID");
  }
  return item;
}

export function nativeCoverageCropForSurface(surface) {
  return surface === "Gielinor Surface"
    ? NATIVE_SURFACE_COVERAGE_CROP
    : NATIVE_REALM_COVERAGE_CROP;
}

export function normalizedPoint(point, geometry) {
  if (!geometry?.width || !geometry?.height) throw new Error("SEMANTIC_FRAME_GEOMETRY_INVALID");
  return {
    x: Math.round((point.x * geometry.width) / REVIEWED_FRAME.width),
    y: Math.round((point.y * geometry.height) / REVIEWED_FRAME.height),
  };
}

function sameBox(first, second) {
  return first?.left === second.left
    && first?.top === second.top
    && first?.right === second.right
    && first?.bottom === second.bottom;
}

function sameBounds(first, second) {
  return first?.minimum === second.minimum && first?.maximum === second.maximum;
}

export function motionVector(
  family,
  geometry,
  translation = { x: 0, y: 0 },
  profileFractionPercent = 100
) {
  const vector = MOTION_VECTORS[family];
  if (!vector) throw new Error(`SEMANTIC_MOTION_FAMILY_UNSUPPORTED:${family}`);
  if (!Number.isInteger(translation?.x) || !Number.isInteger(translation?.y)
      || Math.abs(translation.x) > MOTION_ANCHOR_TRANSLATION_MAXIMUM
      || Math.abs(translation.y) > MOTION_ANCHOR_TRANSLATION_MAXIMUM) {
    throw new Error("SEMANTIC_MOTION_ANCHOR_TRANSLATION_INVALID");
  }
  if (!Number.isInteger(profileFractionPercent)
      || profileFractionPercent < 5
      || profileFractionPercent > 100
      || profileFractionPercent % 5 !== 0) {
    throw new Error("SEMANTIC_MOTION_PROFILE_FRACTION_INVALID");
  }
  const scaledTo = {
    x: vector.from.x + Math.round(
      ((vector.to.x - vector.from.x) * profileFractionPercent) / 100
    ),
    y: vector.from.y + Math.round(
      ((vector.to.y - vector.from.y) * profileFractionPercent) / 100
    ),
  };
  const translated = {
    from: { x: vector.from.x + translation.x, y: vector.from.y + translation.y },
    to: { x: scaledTo.x + translation.x, y: scaledTo.y + translation.y },
  };
  for (const point of [translated.from, translated.to]) {
    if (point.x <= MAP_ACTION_REGION.left || point.x >= MAP_ACTION_REGION.right
        || point.y <= MAP_ACTION_REGION.top || point.y >= MAP_ACTION_REGION.bottom) {
      throw new Error("SEMANTIC_MOTION_ANCHOR_TRANSLATION_OUT_OF_BOUNDS");
    }
  }
  const result = {
    reference_frame: REVIEWED_FRAME,
    reference: vector,
    anchor_translation: translation,
    translated_reference: translated,
    delivered: {
      from: normalizedPoint(translated.from, geometry),
      to: normalizedPoint(translated.to, geometry),
    },
  };
  if (profileFractionPercent < 100) {
    result.profile_fraction_percent = profileFractionPercent;
  }
  return result;
}

export function inverseMotionVector(family, geometry) {
  const forward = motionVector(family, geometry);
  return {
    ...forward,
    reference: { from: forward.reference.to, to: forward.reference.from },
    translated_reference: {
      from: forward.translated_reference.to,
      to: forward.translated_reference.from,
    },
    delivered: { from: forward.delivered.to, to: forward.delivered.from },
  };
}

export function restorationDisplacementForMotion(
  family,
  displacement,
  expectedDisplacement = null
) {
  const forward = MOTION_VECTORS[family];
  if (!forward) throw new Error(`SEMANTIC_MOTION_FAMILY_UNSUPPORTED:${family}`);
  if (!Number.isInteger(displacement?.dx) || !Number.isInteger(displacement?.dy)) {
    throw new Error("SEMANTIC_RESTORATION_MEASUREMENT_INVALID");
  }
  const maximum = {
    x: Math.abs(forward.to.x - forward.from.x) / DISPLACEMENT_CELL_SIZE,
    y: Math.abs(forward.to.y - forward.from.y) / DISPLACEMENT_CELL_SIZE,
  };
  const expectedSign = {
    x: Math.sign(forward.to.x - forward.from.x),
    y: Math.sign(forward.to.y - forward.from.y),
  };
  for (const axis of ["x", "y"]) {
    const measured = axis === "x" ? displacement.dx : displacement.dy;
    const crossAxisMaximum = expectedSign[axis] === 0 ? 1 : maximum[axis];
    if (Math.abs(measured) > crossAxisMaximum
        || (expectedSign[axis] !== 0 && measured !== 0
          && Math.sign(measured) !== expectedSign[axis])) {
      throw new Error("SEMANTIC_RESTORATION_MEASUREMENT_OUT_OF_PROFILE");
    }
  }
  if (Math.hypot(displacement.dx, displacement.dy) < 2) {
    throw new Error("SEMANTIC_RESTORATION_MEASUREMENT_TOO_SMALL");
  }
  if (expectedDisplacement !== null) {
    if (!Number.isInteger(expectedDisplacement?.dx)
        || !Number.isInteger(expectedDisplacement?.dy)
        || Math.hypot(expectedDisplacement.dx, expectedDisplacement.dy) < 2) {
      throw new Error("SEMANTIC_RESTORATION_EXPECTED_DISPLACEMENT_INVALID");
    }
    for (const axis of ["x", "y"]) {
      const expected = axis === "x" ? expectedDisplacement.dx : expectedDisplacement.dy;
      if (Math.abs(expected) > maximum[axis]
          || (expectedSign[axis] === 0 && expected !== 0)
          || (expected !== 0 && Math.sign(expected) !== expectedSign[axis])) {
        throw new Error("SEMANTIC_RESTORATION_EXPECTED_DISPLACEMENT_OUT_OF_PROFILE");
      }
    }
  }
  const restorationDisplacement = {};
  for (const axis of ["x", "y"]) {
    const measured = axis === "x" ? displacement.dx : displacement.dy;
    const expected = expectedDisplacement === null
      ? null
      : axis === "x" ? expectedDisplacement.dx : expectedDisplacement.dy;
    if (expected !== null
        && expectedSign[axis] !== 0
        && Math.abs(expected - measured) <= NEAR_PROFILE_RESTORATION_SNAP_CELLS) {
      restorationDisplacement[axis] = measured + Math.sign(expected - measured);
    } else if (expectedSign[axis] !== 0
        && maximum[axis] - Math.abs(measured) <= NEAR_PROFILE_RESTORATION_SNAP_CELLS) {
      restorationDisplacement[axis] = expectedSign[axis] * maximum[axis];
    } else {
      restorationDisplacement[axis] = measured;
    }
  }
  return restorationDisplacement;
}

export function measuredInverseMotionVector(
  family,
  geometry,
  displacement,
  referenceStart,
  expectedDisplacement = null
) {
  if (!Number.isInteger(referenceStart?.x) || !Number.isInteger(referenceStart?.y)) {
    throw new Error("SEMANTIC_RESTORATION_MEASUREMENT_INVALID");
  }
  const restorationDisplacement = restorationDisplacementForMotion(
    family,
    displacement,
    expectedDisplacement
  );
  const referenceEnd = {
    x: referenceStart.x - restorationDisplacement.x * DISPLACEMENT_CELL_SIZE,
    y: referenceStart.y - restorationDisplacement.y * DISPLACEMENT_CELL_SIZE,
  };
  for (const point of [referenceStart, referenceEnd]) {
    if (point.x <= MAP_ACTION_REGION.left || point.x >= MAP_ACTION_REGION.right
        || point.y <= MAP_ACTION_REGION.top || point.y >= MAP_ACTION_REGION.bottom) {
      throw new Error("SEMANTIC_RESTORATION_VECTOR_OUT_OF_BOUNDS");
    }
  }
  return {
    reference_frame: REVIEWED_FRAME,
    measurement_kind: "MEASURED_EFFECTIVE_FORWARD_DISPLACEMENT",
    displacement_cell_size_reference_pixels: DISPLACEMENT_CELL_SIZE,
    measured_forward_displacement: displacement,
    expected_forward_displacement: expectedDisplacement,
    restoration_displacement: restorationDisplacement,
    reference: { from: referenceStart, to: referenceEnd },
    delivered: {
      from: normalizedPoint(referenceStart, geometry),
      to: normalizedPoint(referenceEnd, geometry),
    },
  };
}

export function selectorScrollbarVector(anchor, localization) {
  if (typeof anchor === "object" && anchor?.target_thumb_top !== undefined) {
    return selectorScrollbarVectorToThumbTop(anchor.target_thumb_top, localization);
  }
  const track = localization?.normalized_track_bbox;
  const observed = localization?.normalized_observed_bbox;
  const sourceTrack = localization?.source_track_bbox;
  const sourceObserved = localization?.source_observed_bbox;
  if (!SELECTOR_SCROLLBAR[anchor]
      || !track || !observed || !sourceTrack || !sourceObserved
      || !localization?.normalized_click_point
      || !localization?.source_click_point
      || !localization?.source_frame_geometry) {
    throw new Error(`SEMANTIC_SELECTOR_SCROLLBAR_VECTOR_INVALID:${anchor}`);
  }
  const normalizedTarget = {
    x: Math.floor((track.left + track.right) / 2),
    y: anchor === "bottom" ? track.bottom - 1 : track.top,
  };
  const sourceTarget = {
    x: Math.floor((sourceTrack.left + sourceTrack.right) / 2),
    y: anchor === "bottom" ? sourceTrack.bottom - 1 : sourceTrack.top,
  };
  return {
    reference_frame: REVIEWED_FRAME,
    reference: {
      from: localization.normalized_click_point,
      to: normalizedTarget,
    },
    delivered: {
      from: localization.source_click_point,
      to: sourceTarget,
    },
  };
}

function validScrollbarGeometry(track, observed, upButton, downButton) {
  const search = SELECTOR_SCROLLBAR.search_region;
  return Number.isInteger(track?.left)
    && Number.isInteger(track?.top)
    && Number.isInteger(track?.right)
    && Number.isInteger(track?.bottom)
    && track.left >= search.left
    && track.top >= search.top
    && track.right <= search.right
    && track.bottom <= search.bottom
    && track.right - track.left === SELECTOR_SCROLLBAR.track.right - SELECTOR_SCROLLBAR.track.left
    && track.bottom - track.top === SELECTOR_SCROLLBAR.track.bottom - SELECTOR_SCROLLBAR.track.top
    && observed?.left === track.left
    && observed?.right === track.right
    && observed?.bottom - observed?.top === SELECTOR_SCROLLBAR.thumb.height
    && upButton?.left === track.left
    && upButton?.right === track.right
    && upButton?.bottom === track.top
    && upButton?.bottom - upButton?.top === SELECTOR_SCROLLBAR.up_button.bottom - SELECTOR_SCROLLBAR.up_button.top
    && downButton?.left === track.left
    && downButton?.right === track.right
    && downButton?.top === track.bottom
    && downButton?.bottom - downButton?.top === SELECTOR_SCROLLBAR.down_button.bottom - SELECTOR_SCROLLBAR.down_button.top;
}

function buttonLocalizationPassed(proof, direction) {
  const correlation = proof?.[`${direction}_button_correlation`];
  const second = proof?.[`${direction}_button_distinct_second_correlation`];
  return Number.isFinite(correlation)
    && correlation >= 0.72
    && Number.isFinite(second)
    && correlation - second >= 0.08;
}

export function semanticMatrixItems({ restoreAfterCapture = true } = {}) {
  const items = [];
  for (const surface of SEMANTIC_MATRIX_SURFACES) {
    for (const zoomPercent of SEMANTIC_ZOOM_LEVELS) {
      for (const criterionFamily of SEMANTIC_CRITERION_FAMILIES) {
        items.push({
          kind: "semantic_map_capture",
          surface,
          zoom_percent: zoomPercent,
          criterion_family: criterionFamily,
          restore_after_capture: restoreAfterCapture,
        });
      }
    }
  }
  return items;
}

export function semanticPilotItems(profile) {
  if (profile === "motion-smoke") {
    return SEMANTIC_ZOOM_LEVELS.map((zoomPercent, index) => semanticItem(
      "Gielinor Surface",
      zoomPercent,
      SEMANTIC_CRITERION_FAMILIES[index],
      true
    ));
  }
  if (profile === "surface-smoke") {
    return SEMANTIC_MATRIX_SURFACES.map((surface) => semanticItem(
      surface,
      75,
      "center_detail",
      true
    ));
  }
  if (profile === "terminal-realm-performance") {
    return Array.from({ length: 20 }, () => semanticItem("Zanaris", 75, "center_detail", true));
  }
  if (profile === "matrix") return semanticMatrixItems();
  if (profile === "canonical-canary") {
    return [semanticItem("Gielinor Surface", 37.5, "eastward_topology", false)];
  }
  if (profile === "canonical-25") {
    const groups = [
      ["Gielinor Surface", 37.5],
      ["Ancient Cavern", 50],
      ["Ardougne Underground", 75],
      ["Asgarnia Ice Cave", 100],
      ["Gielinor Surface", 200],
    ];
    return groups.flatMap(([surface, zoomPercent]) => (
      SEMANTIC_CRITERION_FAMILIES.map((criterionFamily) => semanticItem(
        surface,
        zoomPercent,
        criterionFamily,
        false
      ))
    ));
  }
  const count = {
    "operational-soak": 25,
    "canonical-5": 5,
    "canonical-10": 10,
  }[profile];
  if (count) return semanticMatrixItems({ restoreAfterCapture: false }).slice(0, count);
  throw new Error(`SEMANTIC_PILOT_PROFILE_UNSUPPORTED:${profile}`);
}

export function isRepeatedTerminalRealmPerformanceCycle(item) {
  return item?.kind === "semantic_map_capture"
    && /^terminal-realm-performance-(?:[A-Za-z0-9._-]+-)?\d{3}$/.test(item.id ?? "")
    && item.surface === "Zanaris"
    && item.zoom_percent === 75
    && item.criterion_family === "center_detail"
    && item.restore_after_capture === true;
}

function semanticItem(surface, zoomPercent, criterionFamily, restoreAfterCapture) {
  return {
    kind: "semantic_map_capture",
    surface,
    zoom_percent: zoomPercent,
    criterion_family: criterionFamily,
    restore_after_capture: restoreAfterCapture,
  };
}

export {
  selectorScrollbarVectorToThumbTop,
  semanticScrollbarAtPlannedPosition,
  semanticScrollbarLandingAccepted,
};
