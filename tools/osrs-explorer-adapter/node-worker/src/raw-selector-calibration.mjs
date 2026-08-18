export const RAW_SELECTOR_SCROLLBAR_CALIBRATION_KIND =
  "osrs-surface-selector-scrollbar-calibration-v1";
export const RAW_SELECTOR_SCROLLBAR_RESET_KIND =
  "osrs-surface-selector-scrollbar-reset-v1";

export function requireRawSelectorScrollbarCalibrationShape({
  item,
  targetBundleID,
  allowedOperations,
}) {
  if (item?.kind === RAW_SELECTOR_SCROLLBAR_RESET_KIND) {
    requireResetShape({ item, targetBundleID, allowedOperations });
    return;
  }
  if (item?.kind !== RAW_SELECTOR_SCROLLBAR_CALIBRATION_KIND) return;
  const operations = Array.isArray(item.operations) ? item.operations : [];
  const [capture, click, drag] = operations;
  const exactAllowedOperations = allowedOperations === undefined
    || (allowedOperations.length === 3
      && ["capture", "click", "drag"].every((kind) => allowedOperations.includes(kind)));
  const itemKeys = new Set(["id", "kind", "item_sha256", "operations"]);
  const captureKeys = new Set(["kind"]);
  const clickKeys = new Set([
    "kind", "point", "button", "event_source_mode", "delivery_mode",
  ]);
  const dragKeys = new Set([
    "kind", "from", "to", "event_source_mode", "delivery_mode",
  ]);
  const exactCapture = capture?.kind === "capture"
    && hasOnlyKeys(capture, captureKeys);
  const exactClick = click?.kind === "click"
    && validPoint(click.point)
    && click.button === "left"
    && click.event_source_mode === "combined_session_state"
    && click.delivery_mode === "foreground_global"
    && hasOnlyKeys(click, clickKeys);
  const exactDrag = drag?.kind === "drag"
    && validPoint(drag.from)
    && validPoint(drag.to)
    && drag.event_source_mode === "combined_session_state"
    && drag.delivery_mode === "foreground_global"
    && Math.abs(drag.from.x - drag.to.x) <= 8
    && drag.to.y > drag.from.y
    && hasOnlyKeys(drag, dragKeys);
  if (targetBundleID !== "com.jagex.osclient"
      || !exactAllowedOperations
      || Object.keys(item).some((key) => !itemKeys.has(key))
      || operations.length !== 3
      || !exactCapture
      || !exactClick
      || !exactDrag) {
    throw new Error("QUEUE_SELECTOR_SCROLLBAR_CALIBRATION_INVALID");
  }
}

export function rawOSRSQualificationMode(item, operationKind, phase) {
  if (item?.kind === RAW_SELECTOR_SCROLLBAR_RESET_KIND) return "selector";
  if (item?.kind !== RAW_SELECTOR_SCROLLBAR_CALIBRATION_KIND) return "map";
  if (phase === "before" && operationKind === "click") return "map";
  return "selector";
}

function requireResetShape({ item, targetBundleID, allowedOperations }) {
  const operations = Array.isArray(item.operations) ? item.operations : [];
  const [capture, drag] = operations;
  const exactAllowedOperations = allowedOperations === undefined
    || (allowedOperations.length === 2
      && ["capture", "drag"].every((kind) => allowedOperations.includes(kind)));
  const itemKeys = new Set(["id", "kind", "item_sha256", "operations"]);
  const exactCapture = capture?.kind === "capture"
    && hasOnlyKeys(capture, new Set(["kind"]));
  const exactDrag = drag?.kind === "drag"
    && validPoint(drag.from)
    && validPoint(drag.to)
    && drag.event_source_mode === "combined_session_state"
    && drag.delivery_mode === "foreground_global"
    && Math.abs(drag.from.x - drag.to.x) <= 8
    && drag.to.y < drag.from.y
    && hasOnlyKeys(drag, new Set([
      "kind", "from", "to", "event_source_mode", "delivery_mode",
    ]));
  if (targetBundleID !== "com.jagex.osclient"
      || !exactAllowedOperations
      || Object.keys(item).some((key) => !itemKeys.has(key))
      || operations.length !== 2
      || !exactCapture
      || !exactDrag) {
    throw new Error("QUEUE_SELECTOR_SCROLLBAR_RESET_INVALID");
  }
}

function hasOnlyKeys(value, allowed) {
  return Object.keys(value).every((key) => allowed.has(key));
}

function validPoint(point) {
  return point
    && Number.isFinite(point.x)
    && Number.isFinite(point.y)
    && point.x >= 0
    && point.y >= 0
    && Object.keys(point).length === 2
    && Object.keys(point).every((key) => key === "x" || key === "y");
}
