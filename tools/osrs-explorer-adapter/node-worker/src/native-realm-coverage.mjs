import { SEMANTIC_CRITERION_FAMILIES, SEMANTIC_ZOOM_LEVELS } from "./protocol.mjs";
import {
  NATIVE_REALM_COVERAGE_CROP,
  NATIVE_SURFACE_COVERAGE_CROP,
  nativeCoverageCropForSurface,
} from "./semantic-profile.mjs";
import {
  loadNativeRealmCatalog,
  nativeRealmCatalogEntries,
} from "./native-realm-catalog.mjs";

export const NATIVE_REALM_COVERAGE_PLANNER_VERSION = "native-realm-coverage-planner-v14";
export const NATIVE_REALM_COVERAGE_OVERLAP_FRACTION = 0.2;
export const NATIVE_REALM_COVERAGE_CHUNK_LIMITS = Object.freeze({ x: 240, y: 400 });
export const NATIVE_REALM_COVERAGE_VIEWPORT = Object.freeze({
  source: "surface_specific_qualified_osrs_map_content_crop",
  reviewed_frame_crops: Object.freeze({
    surface: NATIVE_SURFACE_COVERAGE_CROP,
    realm: NATIVE_REALM_COVERAGE_CROP,
  }),
  coordinate_space: "native_display_units",
  raster_pixels_per_display_unit: 4,
});

export function planNativeRealmCoverage({
  restoreAfterCapture = false,
  criterionFamily = "center_detail",
} = {}) {
  if (!SEMANTIC_CRITERION_FAMILIES.includes(criterionFamily)) {
    throw new Error(`NATIVE_REALM_COVERAGE_CRITERION_UNSUPPORTED:${criterionFamily}`);
  }
  const catalog = loadNativeRealmCatalog();
  const positions = [];
  for (const entry of nativeRealmCatalogEntries()) {
    for (const zoomPercent of SEMANTIC_ZOOM_LEVELS) {
      const realmPlan = planRealmZoomCoverage(entry, zoomPercent);
      for (const cell of snakeOrderedCells(realmPlan.cells)) {
        positions.push({
          ...cell,
          id: productionItemID(entry, zoomPercent, cell.row, cell.column),
          kind: "semantic_map_capture",
          catalog_version: catalog.catalog_version,
          planner_version: NATIVE_REALM_COVERAGE_PLANNER_VERSION,
          realm_id: entry.id,
          selector_index: entry.selector_index,
          surface: entry.label,
          zoom_percent: zoomPercent,
          criterion_family: criterionFamily,
          restore_after_capture: restoreAfterCapture,
        });
      }
    }
  }
  const proof = proveCoveragePlan(positions);
  return {
    schema_version: 1,
    planner_version: NATIVE_REALM_COVERAGE_PLANNER_VERSION,
    catalog_version: catalog.catalog_version,
    viewport: NATIVE_REALM_COVERAGE_VIEWPORT,
    overlap_fraction: NATIVE_REALM_COVERAGE_OVERLAP_FRACTION,
    zoom_levels: SEMANTIC_ZOOM_LEVELS,
    realm_count: catalog.entries.length,
    positions,
    proof,
  };
}

export function planRealmZoomCoverage(entry, zoomPercent) {
  if (!SEMANTIC_ZOOM_LEVELS.includes(zoomPercent)) {
    throw new Error(`NATIVE_REALM_COVERAGE_ZOOM_UNSUPPORTED:${zoomPercent}`);
  }
  const plane = coveragePlane(entry);
  const bounds = { ...plane.display_bounds };
  validateBounds(bounds, `NATIVE_REALM_COVERAGE_BOUNDS_INVALID:${entry.id}`);
  const coverageCrop = nativeCoverageCropForSurface(entry.label);
  const viewport = viewportGameSize(zoomPercent, coverageCrop);
  const reopenCenter = resetCenter(entry, plane);
  const xStarts = coverageStarts(
    bounds.min_x,
    bounds.max_x,
    viewport.width,
    reopenCenter.x
  );
  const yStarts = coverageStarts(
    bounds.min_y,
    bounds.max_y,
    viewport.height,
    reopenCenter.y
  );
  const cells = [];
  yStarts.forEach((startY, row) => {
    xStarts.forEach((startX, column) => {
      const captureBounds = {
        min_x: startX,
        min_y: startY,
        max_x: roundTenth(startX + viewport.width),
        max_y: roundTenth(startY + viewport.height),
      };
      const center = {
        x: roundTenth((captureBounds.min_x + captureBounds.max_x) / 2),
        y: roundTenth((captureBounds.min_y + captureBounds.max_y) / 2),
      };
      cells.push({
        row,
        column,
        capture_center: center,
        capture_bounds: captureBounds,
        realm_bounds: bounds,
        viewport,
        coverage_crop: coverageCrop,
        coverage_plane: plane.plane,
        reset_center: reopenCenter,
      });
    });
  });
  const proof = proveAxisCoverage(bounds, viewport, xStarts, yStarts);
  return {
    realm_id: entry.id,
    surface: entry.label,
    zoom_percent: zoomPercent,
    row_count: yStarts.length,
    column_count: xStarts.length,
    position_count: cells.length,
    coverage_plane: plane.plane,
    raster: { width: plane.width, height: plane.height, pixels_per_display_unit: 4 },
    cells,
    proof,
  };
}

export function proveCoveragePlan(positions) {
  const byRealmZoom = new Map();
  for (const position of positions) {
    const key = `${position.realm_id}\u0000${position.zoom_percent}`;
    if (!byRealmZoom.has(key)) byRealmZoom.set(key, []);
    byRealmZoom.get(key).push(position);
    if (!centerInside(position.capture_center, position.realm_bounds)) {
      throw new Error(`NATIVE_REALM_COVERAGE_CENTER_OUT_OF_BOUNDS:${position.id}`);
    }
  }
  for (const [key, group] of byRealmZoom) {
    const first = group[0];
    const xIntervals = [...new Set(group.map((position) =>
      `${position.capture_bounds.min_x}:${position.capture_bounds.max_x}`
    ))].map((value) => {
      const [min, max] = value.split(":").map(Number);
      return { min, max };
    });
    const yIntervals = [...new Set(group.map((position) =>
      `${position.capture_bounds.min_y}:${position.capture_bounds.max_y}`
    ))].map((value) => {
      const [min, max] = value.split(":").map(Number);
      return { min, max };
    });
    if (!intervalsCover(first.realm_bounds.min_x, first.realm_bounds.max_x, xIntervals)
        || !intervalsCover(first.realm_bounds.min_y, first.realm_bounds.max_y, yIntervals)) {
      throw new Error(`NATIVE_REALM_COVERAGE_GAP:${key}`);
    }
  }
  return {
    exact_gap_free: true,
    no_out_of_bounds_centers: true,
    realm_zoom_count: byRealmZoom.size,
    total_positions: positions.length,
    stable_order: true,
  };
}

export function queueItemsForCoveragePlan(plan) {
  return plan.positions.map((position) => ({
    id: position.id,
    kind: position.kind,
    catalog_version: position.catalog_version,
    planner_version: position.planner_version,
    realm_id: position.realm_id,
    selector_index: position.selector_index,
    surface: position.surface,
    zoom_percent: position.zoom_percent,
    criterion_family: position.criterion_family,
    restore_after_capture: position.restore_after_capture,
    capture_center: position.capture_center,
    coverage_cell: {
      row: position.row,
      column: position.column,
      realm_bounds: position.realm_bounds,
      capture_bounds: position.capture_bounds,
      viewport: position.viewport,
      coverage_crop: position.coverage_crop,
      coverage_plane: position.coverage_plane,
      reset_center: position.reset_center,
    },
  }));
}

export function productionItemID(entry, zoomPercent, row, column) {
  return [
    "native-realm-production-v14",
    String(entry.selector_index + 1).padStart(2, "0"),
    entry.id.replace(/[^A-Za-z0-9]+/g, "-").replace(/^-|-$/g, ""),
    `z${String(zoomPercent).replace(".", "p").padStart(4, "0")}`,
    `r${String(row).padStart(3, "0")}`,
    `c${String(column).padStart(3, "0")}`,
  ].join("-");
}

export function coverageReferenceDelta(fromCenter, toCenter, zoomPercent) {
  for (const value of [fromCenter?.x, fromCenter?.y, toCenter?.x, toCenter?.y, zoomPercent]) {
    if (!Number.isFinite(value)) throw new Error("NATIVE_REALM_COVERAGE_DELTA_INVALID");
  }
  const delta = {
    // Dragging the map west/east moves the viewport center east/west.
    dx: Math.round((fromCenter.x - toCenter.x) * zoomPercent / 100),
    // Game Y grows northward while screen Y grows downward.
    dy: Math.round((toCenter.y - fromCenter.y) * zoomPercent / 100),
  };
  // The host intentionally rejects sub-cell drags. The 20% overlap budget is
  // much larger than one two-cell tolerance, so treat a target within that
  // tolerance as already reached and record the tolerance in the result.
  return Math.hypot(delta.dx, delta.dy) < 10 ? { dx: 0, dy: 0 } : delta;
}

export function coverageReferenceChunks(delta) {
  if (!Number.isInteger(delta?.dx) || !Number.isInteger(delta?.dy)) {
    throw new Error("NATIVE_REALM_COVERAGE_CHUNKS_INVALID");
  }
  const chunks = [];
  if (delta.dx === 0 && delta.dy === 0) return chunks;
  const chunkCount = Math.max(
    Math.ceil(Math.abs(delta.dx) / NATIVE_REALM_COVERAGE_CHUNK_LIMITS.x),
    Math.ceil(Math.abs(delta.dy) / NATIVE_REALM_COVERAGE_CHUNK_LIMITS.y)
  );
  if (chunkCount > 64) throw new Error("NATIVE_REALM_COVERAGE_CHUNK_BUDGET_EXCEEDED");
  let remainingDX = delta.dx;
  let remainingDY = delta.dy;
  for (let index = 0; index < chunkCount; index += 1) {
    const remainingChunks = chunkCount - index;
    const chunk = {
      dx: Math.round(remainingDX / remainingChunks),
      dy: Math.round(remainingDY / remainingChunks),
    };
    if (Math.abs(chunk.dx) > NATIVE_REALM_COVERAGE_CHUNK_LIMITS.x
        || Math.abs(chunk.dy) > NATIVE_REALM_COVERAGE_CHUNK_LIMITS.y) {
      throw new Error("NATIVE_REALM_COVERAGE_CHUNK_OUT_OF_BOUNDS");
    }
    if (Math.hypot(chunk.dx, chunk.dy) < 10) {
      throw new Error("NATIVE_REALM_COVERAGE_CHUNK_TOO_SMALL");
    }
    chunks.push(chunk);
    remainingDX -= chunk.dx;
    remainingDY -= chunk.dy;
  }
  if (remainingDX !== 0 || remainingDY !== 0) {
    throw new Error("NATIVE_REALM_COVERAGE_CHUNK_SUM_MISMATCH");
  }
  return chunks;
}

export function coverageAnchorCenter(item) {
  const cell = item?.coverage_cell;
  if (!cell?.reset_center) throw new Error("NATIVE_REALM_COVERAGE_ANCHOR_INVALID");
  return cell.reset_center;
}

function resetCenter(entry, plane) {
  const center = entry?.reopen_center;
  if (!Number.isFinite(center?.x)
      || !Number.isFinite(center?.y)
      || !centerInside(center, plane.display_bounds)) {
    throw new Error(`NATIVE_REALM_REOPEN_CENTER_INVALID:${entry?.id}`);
  }
  return { x: center.x, y: center.y };
}

function viewportGameSize(zoomPercent, coverageCrop) {
  return {
    width: roundTenth((coverageCrop.width * 100) / zoomPercent),
    height: roundTenth((coverageCrop.height * 100) / zoomPercent),
    zoom_percent: zoomPercent,
    overlap_fraction: NATIVE_REALM_COVERAGE_OVERLAP_FRACTION,
  };
}

function coveragePlane(entry) {
  const planes = entry?.asset_planes ?? [];
  if (planes.length === 0) throw new Error(`NATIVE_REALM_COVERAGE_PLANE_MISSING:${entry?.id}`);
  const plane = planes.find((candidate) => candidate.plane === entry.default_plane);
  if (!plane) throw new Error(`NATIVE_REALM_COVERAGE_DEFAULT_PLANE_MISSING:${entry?.id}`);
  if (!plane?.display_bounds
      || roundTenth((plane.display_bounds.max_x - plane.display_bounds.min_x) * 4) !== plane.width
      || roundTenth((plane.display_bounds.max_y - plane.display_bounds.min_y) * 4) !== plane.height) {
    throw new Error(`NATIVE_REALM_COVERAGE_DISPLAY_SCALE_INVALID:${entry?.id}`);
  }
  return plane;
}

function coverageStarts(minimum, maximum, viewportSize, reopenCenter) {
  const span = maximum - minimum;
  if (span <= viewportSize) {
    const reopenStart = roundTenth(reopenCenter - viewportSize / 2);
    if (reopenStart <= minimum && roundTenth(reopenStart + viewportSize) >= maximum) {
      return [reopenStart];
    }
    return [roundTenth((minimum + maximum - viewportSize) / 2)];
  }
  const step = Math.max(1, roundTenth(viewportSize * (1 - NATIVE_REALM_COVERAGE_OVERLAP_FRACTION)));
  const starts = [minimum];
  let current = minimum;
  while (roundTenth(current + viewportSize) < maximum) {
    const next = Math.min(roundTenth(current + step), roundTenth(maximum - viewportSize));
    if (next <= current) break;
    starts.push(next);
    current = next;
  }
  return starts;
}

function snakeOrderedCells(cells) {
  const rows = new Map();
  for (const cell of cells) {
    if (!rows.has(cell.row)) rows.set(cell.row, []);
    rows.get(cell.row).push(cell);
  }
  return [...rows.entries()]
    .sort(([first], [second]) => first - second)
    .flatMap(([row, rowCells]) => rowCells.sort((first, second) =>
      row % 2 === 0 ? first.column - second.column : second.column - first.column
    ));
}

function proveAxisCoverage(bounds, viewport, xStarts, yStarts) {
  const xIntervals = xStarts.map((start) => ({ min: start, max: roundTenth(start + viewport.width) }));
  const yIntervals = yStarts.map((start) => ({ min: start, max: roundTenth(start + viewport.height) }));
  if (!intervalsCover(bounds.min_x, bounds.max_x, xIntervals)
      || !intervalsCover(bounds.min_y, bounds.max_y, yIntervals)) {
    throw new Error("NATIVE_REALM_COVERAGE_AXIS_GAP");
  }
  const xCenters = xStarts.map((start) => roundTenth(start + viewport.width / 2));
  const yCenters = yStarts.map((start) => roundTenth(start + viewport.height / 2));
  if (xCenters.some((center) => center < bounds.min_x || center > bounds.max_x)
      || yCenters.some((center) => center < bounds.min_y || center > bounds.max_y)) {
    throw new Error("NATIVE_REALM_COVERAGE_AXIS_CENTER_OUT_OF_BOUNDS");
  }
  return {
    exact_gap_free: true,
    no_out_of_bounds_centers: true,
    row_count: yStarts.length,
    column_count: xStarts.length,
  };
}

function intervalsCover(minimum, maximum, intervals) {
  const sorted = [...intervals].sort((first, second) => first.min - second.min);
  let covered = minimum;
  for (const interval of sorted) {
    if (interval.max <= minimum || interval.min >= maximum) continue;
    if (interval.min > covered) return false;
    covered = Math.max(covered, interval.max);
    if (covered >= maximum) return true;
  }
  return covered >= maximum;
}

function centerInside(center, bounds) {
  return center.x >= bounds.min_x
    && center.x <= bounds.max_x
    && center.y >= bounds.min_y
    && center.y <= bounds.max_y;
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

function roundTenth(value) {
  return Math.round(value * 10) / 10;
}
