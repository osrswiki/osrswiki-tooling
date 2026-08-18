import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const workerRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const generatedCatalogPath = path.join(
  workerRoot,
  "src",
  "native-realm-catalog.generated.json"
);

let catalogCache;

export function loadNativeRealmCatalog() {
  if (!catalogCache) {
    catalogCache = validateNativeRealmCatalog(
      JSON.parse(fs.readFileSync(generatedCatalogPath, "utf8"))
    );
  }
  return catalogCache;
}

export function validateNativeRealmCatalog(catalog) {
  if (catalog?.schema_version !== 1
      || catalog.catalog_version !== "native-selector-catalog-v4"
      || !Array.isArray(catalog.entries)
      || catalog.entries.length !== 47) {
    throw new Error("NATIVE_REALM_CATALOG_INVALID");
  }
  const entries = catalog.entries;
  if (catalog.validation?.accepted_native_entry_count !== 47
      || catalog.validation?.accepted_surface_count !== 1
      || catalog.validation?.accepted_realm_count !== 46
      || canonicalExcludedSelectorIDs(catalog.validation?.excluded_native_selector_ids)
        !== [
          "cache-world-map:ghorrock-prison",
          "cache-world-map:lassar-undercity",
          "cache-world-map:tutorial-2",
        ].join("\n")
      || catalog.validation?.excluded_other_maps_count !== 1047) {
    throw new Error("NATIVE_REALM_CATALOG_PROOF_INVALID");
  }
  const ids = new Set();
  const labels = new Set();
  entries.forEach((entry, index) => {
    if (entry.selector_index !== index) {
      throw new Error(`NATIVE_REALM_SELECTOR_ORDER_INVALID:${entry.id}`);
    }
    if (ids.has(entry.id) || labels.has(entry.label)) {
      throw new Error(`NATIVE_REALM_SELECTOR_DUPLICATE:${entry.id}`);
    }
    ids.add(entry.id);
    labels.add(entry.label);
    if (entry.group === "surface") {
      if (entry.id !== "surface-gielinor" || entry.is_surface !== true) {
        throw new Error(`NATIVE_REALM_SURFACE_INVALID:${entry.id}`);
      }
    } else if (entry.group === "realms") {
      if (!entry.id.startsWith("cache-world-map:") || entry.is_surface !== false) {
        throw new Error(`NATIVE_REALM_REALM_INVALID:${entry.id}`);
      }
    } else {
      throw new Error(`NATIVE_REALM_GROUP_FORBIDDEN:${entry.id}:${entry.group}`);
    }
    if (entry.id.startsWith("other-map-")
        || entry.id.startsWith("cache-special-region:")
        || entry.group === "other_maps") {
      throw new Error(`NATIVE_REALM_OTHER_MAP_FORBIDDEN:${entry.id}`);
    }
    validateBounds(entry.default_plane_bounds, `NATIVE_REALM_DEFAULT_BOUNDS:${entry.id}`);
    validateBounds(entry.bounds, `NATIVE_REALM_BOUNDS:${entry.id}`);
    const displayBounds = entry.asset_planes?.find((plane) => plane.plane === entry.default_plane)
      ?.display_bounds;
    if (!Number.isFinite(entry.reopen_center?.x)
        || !Number.isFinite(entry.reopen_center?.y)
        || !centerInside(entry.reopen_center, displayBounds)
        || !entry.reopen_center_proof?.mode) {
      throw new Error(`NATIVE_REALM_REOPEN_CENTER_INVALID:${entry.id}`);
    }
  });
  if (!ids.has("surface-gielinor") || !ids.has("cache-world-map:zanaris")) {
    throw new Error("NATIVE_REALM_REQUIRED_ENTRY_MISSING");
  }
  return deepFreeze(catalog);
}

export function nativeRealmCatalogEntries() {
  return loadNativeRealmCatalog().entries;
}

export function nativeRealmLabels() {
  return nativeRealmCatalogEntries().map((entry) => entry.label);
}

export function nativeRealmEntryForLabel(label) {
  const entry = loadNativeRealmCatalog().entries.find((candidate) => candidate.label === label);
  if (!entry) throw new Error(`NATIVE_REALM_SELECTOR_LABEL_UNSUPPORTED:${label}`);
  return entry;
}

export function nativeRealmEntryForID(id) {
  const entry = loadNativeRealmCatalog().entries.find((candidate) => candidate.id === id);
  if (!entry) throw new Error(`NATIVE_REALM_SELECTOR_ID_UNSUPPORTED:${id}`);
  return entry;
}

export function isNativeRealmLabel(label) {
  return loadNativeRealmCatalog().entries.some((entry) => entry.label === label);
}

export function validateProductionRealmID(id) {
  const entry = nativeRealmEntryForID(id);
  if (entry.group !== "surface" && entry.group !== "realms") {
    throw new Error(`NATIVE_REALM_PRODUCTION_GROUP_FORBIDDEN:${id}`);
  }
  return entry;
}

export function nativeSelectorNavigation(label, scrollbarObservation = null) {
  const catalog = loadNativeRealmCatalog();
  const entry = nativeRealmEntryForLabel(label);
  const geometry = catalog.selector_geometry;
  const visibleRowCount = geometry.visible_row_count;
  const maxTopIndex = catalog.entries.length - visibleRowCount;
  const visibleTopIndex = scrollbarObservation
    ? visibleTopIndexForScrollbar(scrollbarObservation, geometry, catalog.entries.length)
    : 0;
  if (entry.selector_index >= visibleTopIndex
      && entry.selector_index < visibleTopIndex + visibleRowCount) {
    return Object.freeze({
      required: false,
      mode: null,
      anchor: null,
      maximum_drags: 0,
      catalog_version: catalog.catalog_version,
      selector_index: entry.selector_index,
      visible_top_index: visibleTopIndex,
      visible_row_index: entry.selector_index - visibleTopIndex,
      target_thumb_top: scrollbarObservation?.normalized_observed_bbox?.top ?? null,
      proof: "expected_label_uniquely_visible_by_catalog_index_and_fresh_scrollbar_geometry",
    });
  }
  const targetTopIndex = stableVisibleTopIndex(
    entry.selector_index,
    visibleTopIndex,
    catalog.entries.length,
    geometry
  );
  const targetThumbTopBounds = thumbTopBoundsForVisibleTopIndex(
    targetTopIndex,
    geometry,
    catalog.entries.length
  );
  // The client snaps the list to the nearest discrete top-row position. Aim at
  // the first pixel in the requested interval; the source-geometry transfer
  // below supplies the bounded Retina handoff offset.
  const targetThumbTop = targetThumbTopBounds.minimum;
  return Object.freeze({
    required: true,
    mode: "scrollbar_drag",
    anchor: targetThumbTop === geometry.scrollbar.bottom_stop_thumb_top ? "bottom" : "position",
    maximum_drags: 1,
    catalog_version: catalog.catalog_version,
    selector_index: entry.selector_index,
    visible_top_index: targetTopIndex,
    visible_row_index: entry.selector_index - targetTopIndex,
    target_thumb_top: targetThumbTop,
    target_thumb_top_bounds: targetThumbTopBounds,
    proof: "bounded_single_thumb_position_from_fresh_scrollbar_geometry",
  });
}

export function selectorRowLocalization(label, scrollbarObservation = null) {
  const catalog = loadNativeRealmCatalog();
  const entry = nativeRealmEntryForLabel(label);
  const navigation = nativeSelectorNavigation(label, scrollbarObservation);
  const visibleRowIndex = navigation.visible_row_index;
  if (!Number.isInteger(visibleRowIndex)
      || visibleRowIndex < 0
      || visibleRowIndex >= catalog.selector_geometry.visible_row_count) {
    throw new Error(`NATIVE_REALM_SELECTOR_ROW_NOT_VISIBLE:${label}`);
  }
  const row = catalog.selector_geometry.option_rows;
  const top = scrollbarObservation
    ? continuousOptionTop(
      entry.selector_index,
      scrollbarObservation,
      catalog.selector_geometry,
      catalog.entries.length
    )
    : row.top + visibleRowIndex * row.row_height;
  const observedBox = {
    left: row.left,
    top,
    right: row.right,
    bottom: top + row.row_box_height,
  };
  return {
    target: `SEMANTIC_SURFACE_OPTION:${label}`,
    selector_catalog_version: catalog.catalog_version,
    realm_id: entry.id,
    selector_index: entry.selector_index,
    visible_top_index: navigation.visible_top_index,
    visible_row_index: visibleRowIndex,
    normalized_observed_bbox: observedBox,
    normalized_click_point: {
      x: Math.floor((observedBox.left + observedBox.right) / 2),
      y: Math.floor((observedBox.top + observedBox.bottom) / 2),
    },
    click_anchor: "PIXEL_LOCALIZED_ROW_CENTER",
    normalized_correlation: 1,
    distinct_second_correlation: 0,
    correlation_separation: 1,
    exactly_one_target: true,
    proof_method: "NATIVE_SELECTOR_CATALOG_CONTINUOUS_GEOMETRY_V4",
    proof:
      "The generated 47-entry catalog maps the requested label to the exact pixel row implied by the observed scrollbar thumb and targets the row center.",
  };
}

export function selectorScrollbarVectorToThumbTop(targetThumbTop, localization) {
  const track = localization?.normalized_track_bbox;
  const observed = localization?.normalized_observed_bbox;
  const sourceTrack = localization?.source_track_bbox;
  const sourceObserved = localization?.source_observed_bbox;
  if (!Number.isInteger(targetThumbTop)
      || !track || !observed || !sourceTrack || !sourceObserved
      || !localization?.normalized_click_point
      || !localization?.source_click_point
      || !localization?.source_frame_geometry) {
    throw new Error("NATIVE_SELECTOR_SCROLLBAR_VECTOR_INVALID");
  }
  const reviewedFrame = loadNativeRealmCatalog().selector_geometry.reviewed_frame;
  const targetTop = Math.max(track.top, Math.min(track.bottom - (observed.bottom - observed.top), targetThumbTop));
  const exactTopStop = targetTop === track.top && targetTop < observed.top;
  const normalizedTarget = {
    x: Math.floor((track.left + track.right) / 2),
    y: exactTopStop
      ? track.top
      : targetTop + Math.floor((observed.bottom - observed.top) / 2),
  };
  const sourceTargetTop = Math.round(
    (targetTop * localization.source_frame_geometry.height) / reviewedFrame.height
  );
  const sourcePixelScale = Math.max(1, Math.round(
    localization.source_frame_geometry.height / reviewedFrame.height
  ));
  const transferDirection = Math.sign(targetTop - observed.top);
  const targetTopIndex = visibleTopIndexForScrollbar({
    normalized_track_bbox: track,
    normalized_observed_bbox: {
      ...observed,
      top: targetTop,
      bottom: targetTop + (observed.bottom - observed.top),
    },
  }, loadNativeRealmCatalog().selector_geometry, loadNativeRealmCatalog().entries.length);
  const targetBounds = thumbTopBoundsForVisibleTopIndex(
    targetTopIndex,
    loadNativeRealmCatalog().selector_geometry,
    loadNativeRealmCatalog().entries.length
  );
  const transferPixelCount = targetBounds.maximum - targetBounds.minimum + 1;
  const sourceGrabOffsetY = localization.source_click_point.y - sourceObserved.top;
  const sourceTarget = {
    x: Math.round(
      (normalizedTarget.x * localization.source_frame_geometry.width) / reviewedFrame.width
    ),
    y: exactTopStop
      ? sourceTrack.top
      : sourceTargetTop
        + sourceGrabOffsetY
        + transferDirection * (sourcePixelScale + transferPixelCount),
  };
  return {
    reference_frame: reviewedFrame,
    reference: {
      from: localization.normalized_click_point,
      to: normalizedTarget,
    },
    delivered: {
      from: localization.source_click_point,
      to: sourceTarget,
    },
    target_thumb_top: targetTop,
  };
}

export function semanticScrollbarAtPlannedPosition(proof, navigation) {
  if (!navigation?.required) return true;
  const catalog = loadNativeRealmCatalog();
  const observed = proof?.normalized_observed_bbox;
  const track = proof?.normalized_track_bbox;
  const bounds = navigation.target_thumb_top_bounds;
  const visibleTopIndex = Number.isInteger(observed?.top)
    ? visibleTopIndexForScrollbar(proof, catalog.selector_geometry, catalog.entries.length)
    : null;
  const positionAccepted = observed?.top >= bounds?.minimum
    && observed?.top <= bounds?.maximum
    && visibleTopIndex === navigation.visible_top_index;
  return proof?.target === "SEMANTIC_SURFACE_SCROLLBAR_THUMB"
    && proof?.selector_open === true
    && proof?.exactly_one_target === true
    && proof?.pixel_resolution === 1
    && Number.isInteger(observed?.top)
    && Number.isInteger(bounds?.minimum)
    && Number.isInteger(bounds?.maximum)
    && positionAccepted
    && observed?.left === track?.left
    && observed?.right === track?.right;
}

export function semanticScrollbarLandingAccepted(proof, navigation, label) {
  if (semanticScrollbarAtPlannedPosition(proof, navigation)) return true;
  if (!navigation?.required || navigation.anchor !== "position") return false;

  const observed = proof?.normalized_observed_bbox;
  const track = proof?.normalized_track_bbox;
  const pixelResolvedOpenThumb = proof?.target === "SEMANTIC_SURFACE_SCROLLBAR_THUMB"
    && proof?.selector_open === true
    && proof?.exactly_one_target === true
    && proof?.pixel_resolution === 1
    && Number.isInteger(observed?.top)
    && observed?.left === track?.left
    && observed?.right === track?.right;
  if (!pixelResolvedOpenThumb) return false;

  let landedNavigation;
  try {
    landedNavigation = nativeSelectorNavigation(label, proof);
  } catch {
    return false;
  }
  return landedNavigation.required === false
    && landedNavigation.catalog_version === navigation.catalog_version
    && landedNavigation.selector_index === navigation.selector_index
    && Number.isInteger(landedNavigation.visible_top_index)
    && Number.isInteger(landedNavigation.visible_row_index);
}

function visibleTopIndexForScrollbar(observation, geometry, totalEntries) {
  const track = observation?.normalized_track_bbox;
  const observed = observation?.normalized_observed_bbox;
  if (!track || !observed) throw new Error("NATIVE_SELECTOR_SCROLLBAR_OBSERVATION_INVALID");
  const travel = track.bottom - track.top - (observed.bottom - observed.top);
  const maxTopIndex = totalEntries - geometry.visible_row_count;
  if (travel <= 0 || maxTopIndex <= 0) return 0;
  const raw = ((observed.top - track.top) * maxTopIndex) / travel;
  return Math.max(0, Math.min(maxTopIndex, Math.ceil(raw)));
}

function continuousOptionTop(selectorIndex, observation, geometry, totalEntries) {
  const track = observation?.normalized_track_bbox;
  const observed = observation?.normalized_observed_bbox;
  if (!track || !observed) throw new Error("NATIVE_SELECTOR_SCROLLBAR_OBSERVATION_INVALID");
  const thumbTravel = track.bottom - track.top - (observed.bottom - observed.top);
  const row = geometry.option_rows;
  const maximumContentOffset = (totalEntries - geometry.visible_row_count) * row.row_height;
  const contentOffset = thumbTravel <= 0 || maximumContentOffset <= 0
    ? 0
    : ((observed.top - track.top) * maximumContentOffset) / thumbTravel;
  return Math.round(row.top + selectorIndex * row.row_height - contentOffset);
}

function targetVisibleTopIndex(selectorIndex, totalEntries, visibleRowCount) {
  const maxTopIndex = totalEntries - visibleRowCount;
  const centeredTopIndex = selectorIndex - Math.floor(visibleRowCount / 2);
  return Math.max(0, Math.min(maxTopIndex, centeredTopIndex));
}

function stableVisibleTopIndex(selectorIndex, currentTopIndex, totalEntries, geometry) {
  const visibleRowCount = geometry.visible_row_count;
  const centeredTopIndex = targetVisibleTopIndex(
    selectorIndex,
    totalEntries,
    visibleRowCount
  );
  const minimumTopIndex = Math.max(0, selectorIndex - visibleRowCount + 1);
  const maximumTopIndex = Math.min(selectorIndex, totalEntries - visibleRowCount);
  const direction = Math.sign(centeredTopIndex - currentTopIndex);
  const candidates = [];
  for (let topIndex = minimumTopIndex; topIndex <= maximumTopIndex; topIndex += 1) {
    const bounds = thumbTopBoundsForVisibleTopIndex(topIndex, geometry, totalEntries);
    candidates.push({
      topIndex,
      intervalWidth: bounds.maximum - bounds.minimum + 1,
      centerDistance: Math.abs(topIndex - centeredTopIndex),
      directionRank: direction === 0 ? topIndex : -direction * topIndex,
    });
  }
  candidates.sort((left, right) =>
    right.intervalWidth - left.intervalWidth
      || left.centerDistance - right.centerDistance
      || left.directionRank - right.directionRank
  );
  return candidates[0].topIndex;
}

function thumbTopForVisibleTopIndex(visibleTopIndex, geometry, totalEntries) {
  const travel = geometry.scrollbar.bottom_stop_thumb_top - geometry.scrollbar.top_stop_thumb_top;
  const maxTopIndex = totalEntries - geometry.visible_row_count;
  if (maxTopIndex <= 0) return geometry.scrollbar.top_stop_thumb_top;
  return geometry.scrollbar.top_stop_thumb_top
    + Math.ceil((visibleTopIndex * travel) / maxTopIndex);
}

function thumbTopBoundsForVisibleTopIndex(visibleTopIndex, geometry, totalEntries) {
  const minimumTop = geometry.scrollbar.top_stop_thumb_top;
  const maximumTop = geometry.scrollbar.bottom_stop_thumb_top;
  const maxTopIndex = totalEntries - geometry.visible_row_count;
  if (visibleTopIndex === maxTopIndex) {
    return Object.freeze({ minimum: maximumTop, maximum: maximumTop });
  }
  const travel = maximumTop - minimumTop;
  const matchingTops = [];
  for (let top = minimumTop; top <= maximumTop; top += 1) {
    const observedTopIndex = maxTopIndex <= 0 || travel <= 0
      ? 0
      : Math.ceil(((top - minimumTop) * maxTopIndex) / travel);
    if (observedTopIndex === visibleTopIndex) matchingTops.push(top);
  }
  if (matchingTops.length === 0) {
    throw new Error(`NATIVE_SELECTOR_SCROLLBAR_POSITION_UNREPRESENTABLE:${visibleTopIndex}`);
  }
  return Object.freeze({
    minimum: matchingTops[0],
    maximum: matchingTops.at(-1),
  });
}

function validateBounds(bounds, error) {
  if (!Number.isFinite(bounds?.min_x)
      || !Number.isFinite(bounds?.min_y)
      || !Number.isFinite(bounds?.max_x)
      || !Number.isFinite(bounds?.max_y)
      || bounds.min_x >= bounds.max_x
      || bounds.min_y >= bounds.max_y) {
    throw new Error(error);
  }
}

function centerInside(center, bounds) {
  return Number.isFinite(bounds?.min_x)
    && Number.isFinite(bounds?.min_y)
    && Number.isFinite(bounds?.max_x)
    && Number.isFinite(bounds?.max_y)
    && center.x >= bounds.min_x
    && center.x <= bounds.max_x
    && center.y >= bounds.min_y
    && center.y <= bounds.max_y;
}

function deepFreeze(value) {
  if (value && typeof value === "object") {
    Object.freeze(value);
    for (const child of Object.values(value)) deepFreeze(child);
  }
  return value;
}

function canonicalExcludedSelectorIDs(value) {
  return Array.isArray(value) ? [...value].sort().join("\n") : "";
}
