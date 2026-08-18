#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";

import { canonicalJson, sha256 } from "../src/protocol.mjs";

const [inputManifestPath, provenanceRoot, outputPath] = process.argv.slice(2);
if (!inputManifestPath || !provenanceRoot || !outputPath) {
  throw new Error(
    "USAGE:generate-native-realm-catalog.mjs <underground-realms.json> <provenance-root> <output.json>"
  );
}
if (![inputManifestPath, provenanceRoot, outputPath].every(path.isAbsolute)) {
  throw new Error("ABSOLUTE_PATHS_REQUIRED");
}

const sourceBytes = fs.readFileSync(inputManifestPath);
const source = JSON.parse(sourceBytes);
if (!Array.isArray(source.realms)) throw new Error("SOURCE_REALMS_REQUIRED");

const groupCounts = source.realms.reduce((counts, record) => {
  counts[record.group] = (counts[record.group] ?? 0) + 1;
  return counts;
}, {});
const selectorIDs = source.selector?.entry_ids;
if (!Array.isArray(selectorIDs) || selectorIDs.length !== source.realms.length) {
  throw new Error("SOURCE_SELECTOR_BIJECTION_REQUIRED");
}
const recordsByID = new Map(source.realms.map((record) => [record.id, record]));
const excludedNativeSelectorIDs = new Set([
  "cache-world-map:ghorrock-prison",
  "cache-world-map:lassar-undercity",
  "cache-world-map:tutorial-2",
]);
const nativeIDs = selectorIDs.filter((id) => {
  const record = recordsByID.get(id);
  return (record?.group === "surface" || record?.group === "realms")
    && !excludedNativeSelectorIDs.has(id);
});
const provenance = loadRendererProvenance(source, provenanceRoot, nativeIDs, recordsByID);
const entries = nativeIDs.map((id, selectorIndex) => {
  const record = recordsByID.get(id);
  const defaultPlane = Number.isInteger(record.default_plane) ? record.default_plane : 0;
  const assets = Array.isArray(record.assets) ? record.assets : [];
  const allBounds = unionBounds(assets.flatMap((asset) => asset.source_bounds ?? []));
  const defaultPlaneBounds = unionBounds(
    assets
      .filter((asset) => asset.plane === defaultPlane)
      .flatMap((asset) => asset.source_bounds ?? [])
  ) ?? allBounds;
  if (!allBounds || !defaultPlaneBounds) {
    throw new Error(`SOURCE_NATIVE_REALM_BOUNDS_MISSING:${id}`);
  }
  const defaultAsset = assets.find((asset) => asset.plane === defaultPlane);
  if (!defaultAsset) throw new Error(`SOURCE_NATIVE_REALM_DEFAULT_ASSET_MISSING:${id}`);
  const reopen = deriveReopenCenter({
    record,
    asset: defaultAsset,
    defaultPlane,
    ownerCode: provenance.ownerCodes.get(id),
    projection: provenance.projection,
    rasterSHA256: provenance.rasterSHA256ByPlane.get(defaultPlane),
  });
  return {
    selector_index: selectorIndex,
    id,
    label: record.canonical_name,
    group: record.group,
    is_surface: record.group === "surface",
    native_file_id: record.native_file_id ?? null,
    map_id: record.map_id ?? null,
    center: {
      x: integerAt(record.center, 0, `${id}:center.x`),
      y: integerAt(record.center, 1, `${id}:center.y`),
    },
    default_plane: defaultPlane,
    reopen_center: reopen.center,
    reopen_center_proof: reopen.proof,
    planes: [...record.planes].sort((first, second) => first - second),
    bounds: allBounds,
    default_plane_bounds: defaultPlaneBounds,
    asset_planes: assets
      .map((asset) => ({
        plane: asset.plane,
        width: asset.width,
        height: asset.height,
        source_bounds: asset.source_bounds ?? [],
        display_bounds: asset.display_bounds ?? null,
        content_pixel_bounds: asset.content_pixel_bounds ?? null,
      }))
      .sort((first, second) => first.plane - second.plane),
  };
});

const catalog = {
  schema_version: 1,
  catalog_version: "native-selector-catalog-v4",
  provenance: {
    source_manifest_path: inputManifestPath,
    source_manifest_sha256: sha256(sourceBytes),
    source_candidate: source.candidate ?? null,
    source_product_label: source.product?.label ?? null,
    renderer_provenance: {
      projection: provenance.projection,
      raster_sha256_by_plane: Object.fromEntries(provenance.rasterSHA256ByPlane),
      owner_sampling: "verified uint16 grayscale raster sampled at each projected native center",
    },
    generator: "tools/osrs-explorer-adapter/node-worker/scripts/generate-native-realm-catalog.mjs",
    producer_identity_rule:
      "surface-gielinor plus cache-world-map:* records from producer groups surface and realms that are present in the live native selector",
    update_mechanism:
      "Regenerate from a verified underground-realms.json producer manifest and its exact renderer provenance rasters; never hand-edit entries.",
  },
  validation: {
    source_selector_entry_count: selectorIDs.length,
    accepted_native_entry_count: entries.length,
    accepted_surface_count: entries.filter((entry) => entry.group === "surface").length,
    accepted_realm_count: entries.filter((entry) => entry.group === "realms").length,
    excluded_native_selector_ids: [...excludedNativeSelectorIDs].sort(),
    excluded_native_selector_rule:
      "Producer realm records absent from the reviewed live native selector are excluded explicitly and fail closed until the profile is reviewed again.",
    excluded_other_maps_count: groupCounts.other_maps ?? 0,
    excluded_other_maps_rule:
      "All producer group other_maps records, including other-map-* and cache-special-region:* IDs, are excluded from native production queues.",
  },
  selector_geometry: {
    reviewed_frame: { width: 768, height: 839 },
    visible_row_count: 8,
    option_rows: {
      coordinate_semantics: "LEFT_TOP_INCLUSIVE_RIGHT_BOTTOM_EXCLUSIVE",
      left: 166,
      right: 349,
      top: 533,
      row_height: 14,
      row_box_height: 14,
      click_inset_y: 2,
    },
    scrollbar: {
      track: { left: 342, top: 543, right: 356, bottom: 629 },
      thumb: { width: 14, height: 16 },
      top_stop_thumb_top: 543,
      bottom_stop_thumb_top: 613,
    },
  },
  entries,
};

validateGeneratedCatalog(catalog);
writeImmutableJSON(outputPath, catalog);
process.stdout.write(`${JSON.stringify({
  status: "NATIVE_REALM_CATALOG_GENERATED",
  catalog_version: catalog.catalog_version,
  output_path: outputPath,
  accepted_native_entry_count: entries.length,
  excluded_other_maps_count: catalog.validation.excluded_other_maps_count,
  sha256: sha256(Buffer.from(`${canonicalJson(catalog)}\n`)),
})}\n`);

function validateGeneratedCatalog(catalog) {
  const entries = catalog.entries;
  if (catalog.schema_version !== 1
      || catalog.catalog_version !== "native-selector-catalog-v4"
      || entries.length !== 47
      || new Set(entries.map((entry) => entry.id)).size !== entries.length
      || new Set(entries.map((entry) => entry.label)).size !== entries.length
      || entries.filter((entry) => entry.group === "surface").length !== 1
      || entries.filter((entry) => entry.group === "realms").length !== 46
      || JSON.stringify(catalog.validation.excluded_native_selector_ids)
        !== JSON.stringify([
          "cache-world-map:ghorrock-prison",
          "cache-world-map:lassar-undercity",
          "cache-world-map:tutorial-2",
        ])
      || catalog.validation.excluded_other_maps_count !== 1047) {
    throw new Error("NATIVE_REALM_CATALOG_CARDINALITY_INVALID");
  }
  entries.forEach((entry, index) => {
    if (entry.selector_index !== index) {
      throw new Error(`NATIVE_REALM_CATALOG_ORDER_INVALID:${entry.id}`);
    }
    if (entry.group === "surface") {
      if (entry.id !== "surface-gielinor") {
        throw new Error(`NATIVE_REALM_SURFACE_ID_INVALID:${entry.id}`);
      }
    } else if (entry.group === "realms") {
      if (!entry.id.startsWith("cache-world-map:")) {
        throw new Error(`NATIVE_REALM_ID_INVALID:${entry.id}`);
      }
    } else {
      throw new Error(`NATIVE_REALM_GROUP_FORBIDDEN:${entry.id}:${entry.group}`);
    }
    if (entry.id.startsWith("other-map-") || entry.id.startsWith("cache-special-region:")) {
      throw new Error(`NATIVE_REALM_OTHER_MAP_FORBIDDEN:${entry.id}`);
    }
    for (const key of ["bounds", "default_plane_bounds"]) {
      const bounds = entry[key];
      if (!bounds
          || !Number.isFinite(bounds.min_x)
          || !Number.isFinite(bounds.min_y)
          || !Number.isFinite(bounds.max_x)
          || !Number.isFinite(bounds.max_y)
          || bounds.min_x >= bounds.max_x
          || bounds.min_y >= bounds.max_y) {
        throw new Error(`NATIVE_REALM_BOUNDS_INVALID:${entry.id}:${key}`);
      }
    }
    const displayBounds = entry.asset_planes.find((plane) => plane.plane === entry.default_plane)
      ?.display_bounds;
    if (!Number.isFinite(entry.reopen_center?.x)
        || !Number.isFinite(entry.reopen_center?.y)
        || !pointInside(entry.reopen_center, displayBounds, true)) {
      throw new Error(`NATIVE_REALM_REOPEN_CENTER_INVALID:${entry.id}`);
    }
  });
}

function loadRendererProvenance(source, root, nativeIDs, recordsByID) {
  const renderer = source.accounting?.renderer_provenance;
  const projection = renderer?.projection;
  const snapshots = source.inputs?.source_snapshots
    ?.all_floor_renderer_provenance_snapshot?.rendered_planes;
  if (renderer?.encoding?.sample_type !== "uint16"
      || renderer.encoding.channel !== "grayscale"
      || !renderer.invariants?.includes("last_writer_wins")
      || projection?.game_coord_scale !== 4
      || !Number.isFinite(projection.min_world_x)
      || !Number.isFinite(projection.max_world_y)
      || !Array.isArray(snapshots)) {
    throw new Error("SOURCE_RENDERER_PROVENANCE_INVALID");
  }
  const rasterSHA256ByPlane = new Map();
  for (const snapshot of snapshots) {
    const rasterPath = path.join(root, `img-${snapshot.rendered_plane}-provenance.png`);
    const bytes = fs.readFileSync(rasterPath);
    if (sha256(bytes) !== snapshot.provenance_png_sha256) {
      throw new Error(`SOURCE_RENDERER_PROVENANCE_DIGEST_MISMATCH:${snapshot.rendered_plane}`);
    }
    rasterSHA256ByPlane.set(snapshot.rendered_plane, snapshot.provenance_png_sha256);
  }

  const ownerCodes = new Map();
  const recordsByPlane = Map.groupBy(
    nativeIDs.map((id) => recordsByID.get(id)),
    (record) => Number.isInteger(record.default_plane) ? record.default_plane : 0
  );
  for (const [plane, records] of recordsByPlane) {
    if (!rasterSHA256ByPlane.has(plane)) {
      throw new Error(`SOURCE_RENDERER_PROVENANCE_PLANE_MISSING:${plane}`);
    }
    const expressions = records.map((record) => {
      const point = projectedSourcePixel(record.center, projection);
      return `%[fx:round(quantumrange*u.p{${point.x},${point.y}})]`;
    });
    const sampled = spawnSync(
      process.env.MAGICK_BINARY ?? "magick",
      [path.join(root, `img-${plane}-provenance.png`), "-format", expressions.join("\n"), "info:"],
      { encoding: "utf8", maxBuffer: 1024 * 1024 }
    );
    if (sampled.status !== 0) {
      throw new Error(`SOURCE_RENDERER_PROVENANCE_SAMPLE_FAILED:${plane}:${sampled.stderr.trim()}`);
    }
    const values = sampled.stdout.trim().split(/\s+/).map(Number);
    if (values.length !== records.length || values.some((value) => !Number.isInteger(value))) {
      throw new Error(`SOURCE_RENDERER_PROVENANCE_SAMPLE_INVALID:${plane}`);
    }
    records.forEach((record, index) => ownerCodes.set(record.id, values[index]));
  }
  return { projection, rasterSHA256ByPlane, ownerCodes };
}

function deriveReopenCenter({ record, asset, defaultPlane, ownerCode, projection, rasterSHA256 }) {
  if (record.id === "surface-gielinor") {
    return {
      center: { x: 2237.25, y: 971.5 },
      proof: {
        mode: "reviewed_live_surface_registration",
        rendered_plane: defaultPlane,
        provenance_raster_sha256: rasterSHA256,
      },
    };
  }
  const sourcePixel = projectedSourcePixel(record.center, projection);
  const componentCodes = new Set((record.components ?? [])
    .filter((component) => component.rendered_plane === defaultPlane
      && pointInside(sourcePixel, component.source_pixel_bounds))
    .map((component) => component.provenance_code));
  const candidates = (asset.layout_components ?? [])
    .filter((component) => pointInside(sourcePixel, component.source_pixel_bounds)
      && component.provenance_codes?.some((code) => componentCodes.has(code)))
    .map((component) => ({
      center: {
        x: roundTenth((component.asset_pixel_bounds.min_x - asset.canvas_origin[0]
          + sourcePixel.x - component.source_pixel_bounds.min_x) / projection.game_coord_scale),
        y: roundTenth((component.asset_pixel_bounds.min_y - asset.canvas_origin[1]
          + sourcePixel.y - component.source_pixel_bounds.min_y) / projection.game_coord_scale),
      },
      provenanceCodes: component.provenance_codes,
    }));
  const ownerCandidates = candidates.filter(({ provenanceCodes }) => provenanceCodes.includes(ownerCode));
  const selectedPool = ownerCandidates.length > 0 ? ownerCandidates : candidates;
  const uniqueCenters = new Map(selectedPool.map((candidate) => [
    `${candidate.center.x}:${candidate.center.y}`,
    candidate,
  ]));
  if (uniqueCenters.size !== 1) {
    throw new Error(`SOURCE_NATIVE_REALM_REOPEN_CENTER_AMBIGUOUS:${record.id}:${ownerCode}`);
  }
  const selected = [...uniqueCenters.values()][0];
  if (!pointInside(selected.center, asset.display_bounds, true)) {
    throw new Error(`SOURCE_NATIVE_REALM_REOPEN_CENTER_OUT_OF_BOUNDS:${record.id}`);
  }
  return {
    center: selected.center,
    proof: {
      mode: ownerCandidates.length > 0
        ? "renderer_owner_to_packed_layout"
        : "unique_record_layout_mapping",
      rendered_plane: defaultPlane,
      source_pixel: sourcePixel,
      sampled_owner_code: ownerCode,
      selected_layout_provenance_codes: selected.provenanceCodes,
      provenance_raster_sha256: rasterSHA256,
    },
  };
}

function projectedSourcePixel(center, projection) {
  return {
    x: (integerAt(center, 0, "center.x") - projection.min_world_x)
      * projection.game_coord_scale,
    y: (projection.max_world_y - integerAt(center, 1, "center.y"))
      * projection.game_coord_scale,
  };
}

function pointInside(point, bounds, inclusiveMaximum = false) {
  if (!point || !bounds) return false;
  return point.x >= bounds.min_x
    && point.y >= bounds.min_y
    && (inclusiveMaximum ? point.x <= bounds.max_x : point.x < bounds.max_x)
    && (inclusiveMaximum ? point.y <= bounds.max_y : point.y < bounds.max_y);
}

function roundTenth(value) {
  return Math.round(value * 10) / 10;
}

function unionBounds(bounds) {
  const normalized = bounds.map((bound) => normalizeBounds(bound)).filter(Boolean);
  if (normalized.length === 0) return null;
  return {
    min_x: Math.min(...normalized.map((bound) => bound.min_x)),
    min_y: Math.min(...normalized.map((bound) => bound.min_y)),
    max_x: Math.max(...normalized.map((bound) => bound.max_x)),
    max_y: Math.max(...normalized.map((bound) => bound.max_y)),
  };
}

function normalizeBounds(value) {
  if (!value) return null;
  const minX = value.min_x ?? value.minX;
  const minY = value.min_y ?? value.minY;
  const maxX = value.max_x ?? value.maxX;
  const maxY = value.max_y ?? value.maxY;
  if (![minX, minY, maxX, maxY].every(Number.isFinite)) return null;
  return { min_x: minX, min_y: minY, max_x: maxX, max_y: maxY };
}

function integerAt(values, index, label) {
  const value = Array.isArray(values) ? values[index] : undefined;
  if (!Number.isInteger(value)) throw new Error(`SOURCE_NATIVE_REALM_${label}_INVALID`);
  return value;
}

function writeImmutableJSON(destination, value) {
  fs.mkdirSync(path.dirname(destination), { recursive: true, mode: 0o700 });
  const data = `${JSON.stringify(value, null, 2)}\n`;
  const descriptor = fs.openSync(destination, "wx", 0o600);
  try {
    fs.writeFileSync(descriptor, data);
    fs.fsyncSync(descriptor);
  } finally {
    fs.closeSync(descriptor);
  }
  fs.chmodSync(destination, 0o444);
}
