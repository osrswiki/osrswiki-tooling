import crypto from "node:crypto";

import {
  RAW_SELECTOR_SCROLLBAR_CALIBRATION_KIND,
  RAW_SELECTOR_SCROLLBAR_RESET_KIND,
  requireRawSelectorScrollbarCalibrationShape,
} from "./raw-selector-calibration.mjs";
import { nativeRealmEntryForID } from "./native-realm-catalog.mjs";

export const MAXIMUM_QUEUE_ITEMS = 128;
export const MAXIMUM_SEMANTIC_PRODUCTION_QUEUE_ITEMS = 100_000;
export const MAXIMUM_ITEM_OPERATIONS = 32;
export const SEMANTIC_EXECUTION_PROFILE = "semantic_map_capture_v1";
export const SEMANTIC_SURFACES = Object.freeze([
  "Gielinor Surface",
  "Ancient Cavern",
  "Ardougne Underground",
  "Asgarnia Ice Cave",
  "Zanaris",
]);
export const NATIVE_REALM_CATALOG_VERSION = "native-selector-catalog-v4";
export const SEMANTIC_ZOOM_LEVELS = Object.freeze([37.5, 50, 75, 100, 200]);
export const SEMANTIC_CRITERION_FAMILIES = Object.freeze([
  "eastward_topology",
  "southward_topology",
  "westward_boundary",
  "northward_detail",
  "center_detail",
]);

export function canonicalJson(value) {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.keys(value)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${canonicalJson(value[key])}`)
      .join(",")}}`;
  }
  return JSON.stringify(value);
}

export function sha256(value) {
  return crypto.createHash("sha256").update(value).digest("hex");
}

export function validateQueueManifest(manifest) {
  if (![1, 2].includes(manifest?.schema_version)) throw new Error("QUEUE_SCHEMA_UNSUPPORTED");
  const semantic = manifest.schema_version === 2;
  if ((semantic && manifest.execution_profile !== SEMANTIC_EXECUTION_PROFILE)
      || (!semantic && manifest.execution_profile !== undefined)) {
    throw new Error("QUEUE_EXECUTION_PROFILE_INVALID");
  }
  if (!/^[A-Za-z0-9._-]+$/.test(manifest.generation_id || "")) {
    throw new Error("QUEUE_GENERATION_INVALID");
  }
  if (manifest.target_bundle_id !== "com.jagex.osclient" && manifest.target_kind !== "lab") {
    throw new Error("QUEUE_TARGET_FORBIDDEN");
  }
  const allowed = new Set(["capture", "click", "drag", "open_world_map"]);
  const legacySemanticAllowed = new Set(["capture", "click", "drag"]);
  const recoverySemanticAllowed = new Set(["capture", "click", "drag", "open_world_map"]);
  const sourceModes = new Set(["private_state", "combined_session_state", "hid_system_state"]);
  const deliveryModes = new Set(["background_pid", "foreground_pid", "foreground_global"]);
  if (!Array.isArray(manifest.allowed_operations)
      || manifest.allowed_operations.length === 0
      || manifest.allowed_operations.length > allowed.size
      || new Set(manifest.allowed_operations).size !== manifest.allowed_operations.length
      || manifest.allowed_operations.some((op) => !allowed.has(op))) {
    throw new Error("QUEUE_OPERATION_FORBIDDEN");
  }
  if (semantic
      && (manifest.target_bundle_id !== "com.jagex.osclient"
        || manifest.target_kind !== undefined
        || (![legacySemanticAllowed, recoverySemanticAllowed].some((operations) =>
          manifest.allowed_operations.length === operations.size
            && [...operations].every((operation) => manifest.allowed_operations.includes(operation)))))) {
    throw new Error("QUEUE_SEMANTIC_BOUNDARY_INVALID");
  }
  const maximumItems = semantic ? MAXIMUM_SEMANTIC_PRODUCTION_QUEUE_ITEMS : MAXIMUM_QUEUE_ITEMS;
  if (!Array.isArray(manifest.items)
      || manifest.items.length === 0
      || manifest.items.length > maximumItems) {
    throw new Error("QUEUE_ITEMS_REQUIRED");
  }
  const ids = new Set();
  for (const item of manifest.items) {
    if (!/^[A-Za-z0-9._-]+$/.test(item.id || "")) throw new Error("QUEUE_ITEM_ID_INVALID");
    if (ids.has(item.id)) throw new Error("QUEUE_ITEM_DUPLICATE");
    ids.add(item.id);
    if (item.supersedes_item_id) {
      if (item.supersedes_item_id === item.id
          || !Array.isArray(item.repair_lineage)
          || item.repair_lineage.length === 0
          || !item.repair_lineage.includes(item.supersedes_item_id)) {
        throw new Error("QUEUE_REPAIR_LINEAGE_INVALID");
      }
    } else if (item.repair_lineage !== undefined) {
      throw new Error("QUEUE_ORPHAN_REPAIR_LINEAGE");
    }
    const operations = item.operations ?? [];
    if (semantic) {
      validateSemanticItem(item);
    } else if (!Array.isArray(item.operations)
        || item.operations.length === 0
        || item.operations.length > MAXIMUM_ITEM_OPERATIONS) {
      throw new Error("QUEUE_ITEM_OPERATIONS_REQUIRED");
    }
    for (const operation of operations) {
      if (!allowed.has(operation?.kind) || !manifest.allowed_operations.includes(operation.kind)) {
        throw new Error("QUEUE_ITEM_OPERATION_FORBIDDEN");
      }
      if (operation.kind === "click" && (!validPoint(operation.point) || !["left", "right"].includes(operation.button))) {
        throw new Error("QUEUE_CLICK_INVALID");
      }
      if (operation.kind === "drag" && (!validPoint(operation.from) || !validPoint(operation.to))) {
        throw new Error("QUEUE_DRAG_INVALID");
      }
      if (operation.kind === "open_world_map") {
        const keys = Object.keys(operation);
        if (item.kind !== "osrs-recovery-v1-GAMEPLAY_NO_MAP"
            || manifest.target_bundle_id !== "com.jagex.osclient"
            || keys.some((key) => !["kind", "event_source_mode", "delivery_mode"].includes(key))
            || operation.event_source_mode !== "combined_session_state"
            || operation.delivery_mode !== "foreground_global") {
          throw new Error("QUEUE_WORLD_MAP_SHORTCUT_BOUNDARY_INVALID");
        }
      }
      if (operation.kind === "capture" && operation.event_source_mode !== undefined) {
        throw new Error("QUEUE_CAPTURE_SOURCE_MODE_FORBIDDEN");
      }
      if (operation.kind === "capture" && operation.delivery_mode !== undefined) {
        throw new Error("QUEUE_CAPTURE_DELIVERY_MODE_FORBIDDEN");
      }
      if (operation.kind !== "capture"
          && operation.event_source_mode !== undefined
          && !sourceModes.has(operation.event_source_mode)) {
        throw new Error("QUEUE_EVENT_SOURCE_MODE_INVALID");
      }
      if (operation.kind !== "capture"
          && operation.delivery_mode !== undefined
          && !deliveryModes.has(operation.delivery_mode)) {
        throw new Error("QUEUE_DELIVERY_MODE_INVALID");
      }
    }
    if (item.kind === RAW_SELECTOR_SCROLLBAR_CALIBRATION_KIND
        || item.kind === RAW_SELECTOR_SCROLLBAR_RESET_KIND) {
      requireRawSelectorScrollbarCalibrationShape({
        item,
        targetBundleID: manifest.target_bundle_id,
        allowedOperations: manifest.allowed_operations,
      });
      if (manifest.target_kind !== undefined) {
        throw new Error(item.kind === RAW_SELECTOR_SCROLLBAR_RESET_KIND
          ? "QUEUE_SELECTOR_SCROLLBAR_RESET_INVALID"
          : "QUEUE_SELECTOR_SCROLLBAR_CALIBRATION_INVALID");
      }
    }
    const withoutItemDigest = { ...item };
    delete withoutItemDigest.item_sha256;
    const itemDigest = sha256(canonicalJson(withoutItemDigest));
    if (item.item_sha256 !== itemDigest) throw new Error(`QUEUE_ITEM_SHA256_MISMATCH:${item.id}`);
  }
  const withoutDigest = { ...manifest };
  delete withoutDigest.policy_digest;
  const calculated = sha256(canonicalJson(withoutDigest));
  if (manifest.policy_digest !== calculated) throw new Error("QUEUE_POLICY_DIGEST_MISMATCH");
  return { manifest, calculated };
}

function validateSemanticItem(item) {
  const allowedKeys = new Set([
    "id", "kind", "item_sha256", "surface", "zoom_percent",
    "criterion_family", "restore_after_capture", "catalog_version",
    "planner_version", "realm_id", "selector_index", "capture_center",
    "coverage_cell",
  ]);
  const production = item.realm_id !== undefined
    || item.selector_index !== undefined
    || item.capture_center !== undefined
    || item.coverage_cell !== undefined
    || item.catalog_version !== undefined
    || item.planner_version !== undefined;
  if (Object.keys(item).some((key) => !allowedKeys.has(key))
      || item.kind !== "semantic_map_capture"
      || typeof item.surface !== "string"
      || item.surface.length === 0
      || !SEMANTIC_ZOOM_LEVELS.includes(item.zoom_percent)
      || !SEMANTIC_CRITERION_FAMILIES.includes(item.criterion_family)
      || typeof item.restore_after_capture !== "boolean"
      || (!production && !SEMANTIC_SURFACES.includes(item.surface))) {
    throw new Error("QUEUE_SEMANTIC_ITEM_INVALID");
  }
  if (production) validateNativeRealmProductionItem(item);
}

function validateNativeRealmProductionItem(item) {
  if (item.catalog_version !== NATIVE_REALM_CATALOG_VERSION
      || ![
        "native-realm-coverage-planner-v1",
        "native-realm-coverage-planner-v2",
        "native-realm-coverage-planner-v3",
        "native-realm-coverage-planner-v4",
        "native-realm-coverage-planner-v5",
        "native-realm-coverage-planner-v6",
        "native-realm-coverage-planner-v7",
        "native-realm-coverage-planner-v8",
        "native-realm-coverage-planner-v9",
        "native-realm-coverage-planner-v10",
        "native-realm-coverage-planner-v11",
        "native-realm-coverage-planner-v12",
        "native-realm-coverage-planner-v13",
        "native-realm-coverage-planner-v14",
      ]
        .includes(item.planner_version)
      || typeof item.realm_id !== "string"
      || item.realm_id.length === 0
      || item.realm_id.startsWith("other-map-")
      || item.realm_id.startsWith("cache-special-region:")
      || !(item.realm_id === "surface-gielinor" || item.realm_id.startsWith("cache-world-map:"))
      || !Number.isInteger(item.selector_index)
      || item.selector_index < 0
      || item.selector_index >= 47
      || !validCenter(item.capture_center)
      || !validCoverageCell(item.coverage_cell)) {
    throw new Error("QUEUE_NATIVE_REALM_PRODUCTION_ITEM_INVALID");
  }
  let entry;
  try {
    entry = nativeRealmEntryForID(item.realm_id);
  } catch {
    throw new Error("QUEUE_NATIVE_REALM_PRODUCTION_ITEM_INVALID");
  }
  if (entry.label !== item.surface || entry.selector_index !== item.selector_index) {
    throw new Error("QUEUE_NATIVE_REALM_PRODUCTION_ITEM_INVALID");
  }
  if ([
    "native-realm-coverage-planner-v10",
    "native-realm-coverage-planner-v11",
    "native-realm-coverage-planner-v12",
    "native-realm-coverage-planner-v13",
    "native-realm-coverage-planner-v14",
  ].includes(item.planner_version)) {
    const defaultPlane = entry.asset_planes.find((plane) => plane.plane === entry.default_plane);
    if (!defaultPlane
        || item.coverage_cell.coverage_plane !== entry.default_plane
        || !sameBounds(item.coverage_cell.realm_bounds, defaultPlane.display_bounds)) {
      throw new Error("QUEUE_NATIVE_REALM_PRODUCTION_ITEM_INVALID");
    }
  }
  if (item.planner_version === "native-realm-coverage-planner-v8"
      && (!Number.isInteger(item.coverage_cell.anchor_attempt_budget)
        || item.coverage_cell.anchor_attempt_budget < 2
        || item.coverage_cell.anchor_attempt_budget > 40)) {
    throw new Error("QUEUE_NATIVE_REALM_PRODUCTION_ITEM_INVALID");
  }
  if ([
    "native-realm-coverage-planner-v3",
    "native-realm-coverage-planner-v4",
    "native-realm-coverage-planner-v5",
    "native-realm-coverage-planner-v6",
    "native-realm-coverage-planner-v7",
    "native-realm-coverage-planner-v8",
    "native-realm-coverage-planner-v9",
    "native-realm-coverage-planner-v10",
    "native-realm-coverage-planner-v11",
    "native-realm-coverage-planner-v12",
    "native-realm-coverage-planner-v13",
    "native-realm-coverage-planner-v14",
  ].includes(item.planner_version)
      && (item.capture_center.x !== roundTenth(
        (item.coverage_cell.capture_bounds.min_x + item.coverage_cell.capture_bounds.max_x) / 2
      )
        || item.capture_center.y !== roundTenth(
          (item.coverage_cell.capture_bounds.min_y + item.coverage_cell.capture_bounds.max_y) / 2
        ))) {
    throw new Error("QUEUE_NATIVE_REALM_PRODUCTION_ITEM_INVALID");
  }
  if (item.planner_version === "native-realm-coverage-planner-v14") {
    const expectedCrop = item.realm_id === "surface-gielinor"
      ? { left: 178, top: 70, width: 338, height: 550 }
      : { left: 4, top: 70, width: 512, height: 550 };
    const crop = item.coverage_cell.coverage_crop;
    if (!crop
        || Object.keys(crop).sort().join(",") !== "height,left,top,width"
        || Object.entries(expectedCrop).some(([key, value]) => crop[key] !== value)
        || item.coverage_cell.viewport.width
          !== roundTenth(expectedCrop.width * 100 / item.zoom_percent)
        || item.coverage_cell.viewport.height
          !== roundTenth(expectedCrop.height * 100 / item.zoom_percent)) {
      throw new Error("QUEUE_NATIVE_REALM_PRODUCTION_ITEM_INVALID");
    }
  }
}

function sameBounds(first, second) {
  return first?.min_x === second?.min_x
    && first?.min_y === second?.min_y
    && first?.max_x === second?.max_x
    && first?.max_y === second?.max_y;
}

function validCenter(value) {
  return Number.isFinite(value?.x) && Number.isFinite(value?.y);
}

function validCoverageCell(value) {
  const base = Number.isInteger(value?.row)
    && value.row >= 0
    && Number.isInteger(value?.column)
    && value.column >= 0
    && validBounds(value.realm_bounds)
    && validBounds(value.capture_bounds)
    && Number.isFinite(value.viewport?.width)
    && value.viewport.width > 0
    && Number.isFinite(value.viewport?.height)
    && value.viewport.height > 0;
  if (!base) return false;
  if (value.coverage_plane === undefined && value.reset_center === undefined) return true;
  return Number.isInteger(value.coverage_plane)
    && value.coverage_plane >= 0
    && validCenter(value.reset_center)
    && (value.anchor_attempt_budget === undefined
      || (Number.isInteger(value.anchor_attempt_budget)
        && value.anchor_attempt_budget >= 2
        && value.anchor_attempt_budget <= 40))
    && centerInside(value.reset_center, value.realm_bounds)
    && centerInside({
      x: (value.capture_bounds.min_x + value.capture_bounds.max_x) / 2,
      y: (value.capture_bounds.min_y + value.capture_bounds.max_y) / 2,
    }, value.realm_bounds);
}

function centerInside(center, bounds) {
  return center.x >= bounds.min_x
    && center.x <= bounds.max_x
    && center.y >= bounds.min_y
    && center.y <= bounds.max_y;
}

function roundTenth(value) {
  return Math.round(value * 10) / 10;
}

function validBounds(value) {
  return Number.isFinite(value?.min_x)
    && Number.isFinite(value?.min_y)
    && Number.isFinite(value?.max_x)
    && Number.isFinite(value?.max_y)
    && value.min_x < value.max_x
    && value.min_y < value.max_y;
}

export function finalizeQueueManifest(draft) {
  const manifest = structuredClone(draft);
  manifest.items = manifest.items.map((item) => {
    const finalized = { ...item };
    delete finalized.item_sha256;
    finalized.item_sha256 = sha256(canonicalJson(finalized));
    return finalized;
  });
  delete manifest.policy_digest;
  manifest.policy_digest = sha256(canonicalJson(manifest));
  return manifest;
}

function validPoint(point) {
  return point && Number.isFinite(point.x) && Number.isFinite(point.y) && point.x >= 0 && point.y >= 0;
}
