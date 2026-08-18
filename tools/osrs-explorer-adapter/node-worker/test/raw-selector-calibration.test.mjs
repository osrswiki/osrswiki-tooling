import assert from "node:assert/strict";
import test from "node:test";

import {
  RAW_SELECTOR_SCROLLBAR_CALIBRATION_KIND,
  RAW_SELECTOR_SCROLLBAR_RESET_KIND,
  rawOSRSQualificationMode,
  requireRawSelectorScrollbarCalibrationShape,
} from "../src/raw-selector-calibration.mjs";
import {
  isAuthorizedMapClassification,
  isAuthorizedSelectorClassification,
} from "../src/perception.mjs";
import { finalizeQueueManifest, validateQueueManifest } from "../src/protocol.mjs";

const base = {
  connection: "CONNECTED",
  map_shell: "FLOATING_MAP_OPEN",
  map_content: "NONBLACK_CONTENT",
  normalization: { family: "GAMEPLAY_MAP_768x839" },
};

test("only the fixed calibration item admits selector-open intermediate states", () => {
  const calibration = { kind: RAW_SELECTOR_SCROLLBAR_CALIBRATION_KIND };
  assert.equal(rawOSRSQualificationMode(calibration, "click", "before"), "map");
  assert.equal(rawOSRSQualificationMode(calibration, "click", "after"), "selector");
  assert.equal(rawOSRSQualificationMode(calibration, "drag", "before"), "selector");
  assert.equal(rawOSRSQualificationMode(calibration, "drag", "after"), "selector");
  assert.equal(rawOSRSQualificationMode({ kind: "osrs-map-input-proof" }, "drag", "after"), "map");
  const reset = { kind: RAW_SELECTOR_SCROLLBAR_RESET_KIND };
  assert.equal(rawOSRSQualificationMode(reset, "drag", "before"), "selector");
  assert.equal(rawOSRSQualificationMode(reset, "drag", "after"), "selector");
});

test("worker-side calibration shape rejects malformed claims before execution", () => {
  const item = {
    id: "selector-bottom",
    kind: RAW_SELECTOR_SCROLLBAR_CALIBRATION_KIND,
    item_sha256: "digest",
    operations: [
      { kind: "capture" },
      {
        kind: "click",
        point: { x: 522, y: 1386 },
        button: "left",
        event_source_mode: "combined_session_state",
        delivery_mode: "foreground_global",
      },
      {
        kind: "drag",
        from: { x: 714, y: 1178 },
        to: { x: 714, y: 1319 },
        event_source_mode: "combined_session_state",
        delivery_mode: "foreground_global",
      },
    ],
  };
  assert.doesNotThrow(() => requireRawSelectorScrollbarCalibrationShape({
    item,
    targetBundleID: "com.jagex.osclient",
  }));
  for (const mutate of [
    (changed) => { changed.operations[1].semantic_role = "surface_selector_open"; },
    (changed) => { changed.operations[2].from.x = -1; },
    (changed) => { changed.operations.push(structuredClone(changed.operations[2])); },
  ]) {
    const changed = structuredClone(item);
    mutate(changed);
    assert.throws(
      () => requireRawSelectorScrollbarCalibrationShape({
        item: changed,
        targetBundleID: "com.jagex.osclient",
      }),
      /QUEUE_SELECTOR_SCROLLBAR_CALIBRATION_INVALID/
    );
  }
});

test("worker-side reset accepts one upward drag from the observed thumb", () => {
  const item = {
    id: "selector-reset",
    kind: RAW_SELECTOR_SCROLLBAR_RESET_KIND,
    operations: [
      { kind: "capture" },
      {
        kind: "drag",
        from: { x: 733, y: 1306 },
        to: { x: 733, y: 1170 },
        event_source_mode: "combined_session_state",
        delivery_mode: "foreground_global",
      },
    ],
    item_sha256: "digest",
  };
  assert.doesNotThrow(() => requireRawSelectorScrollbarCalibrationShape({
    item,
    targetBundleID: "com.jagex.osclient",
    allowedOperations: ["capture", "drag"],
  }));
  const manifest = finalizeQueueManifest({
    schema_version: 1,
    generation_id: "selector-reset-generation",
    target_bundle_id: "com.jagex.osclient",
    allowed_operations: ["capture", "drag"],
    artifact_root: "/tmp/selector-reset-generation",
    items: [item],
  });
  assert.doesNotThrow(() => validateQueueManifest(manifest));

  const downward = structuredClone(item);
  downward.operations[1].to.y = 1319;
  assert.throws(() => requireRawSelectorScrollbarCalibrationShape({
    item: downward,
    targetBundleID: "com.jagex.osclient",
    allowedOperations: ["capture", "drag"],
  }), /QUEUE_SELECTOR_SCROLLBAR_RESET_INVALID/);
});

test("map and selector qualification remain mutually exclusive", () => {
  const map = { ...base, overlay: "NONE", committable: true };
  const selector = { ...base, overlay: "SURFACE_SELECTOR", committable: false };
  assert.equal(isAuthorizedMapClassification(map), true);
  assert.equal(isAuthorizedSelectorClassification(map), false);
  assert.equal(isAuthorizedMapClassification(selector), false);
  assert.equal(isAuthorizedSelectorClassification(selector), true);

  for (const invalid of [
    { ...selector, connection: "DISCONNECTED" },
    { ...selector, map_content: "BLACK_OR_EMPTY" },
    { ...selector, committable: true },
    { ...selector, normalization: { family: "RECOVERY_768x861" } },
  ]) {
    assert.equal(isAuthorizedSelectorClassification(invalid), false);
  }
});
