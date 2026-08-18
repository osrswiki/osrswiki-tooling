import assert from "node:assert/strict";
import test from "node:test";

import { finalizeQueueManifest, validateQueueManifest } from "../src/protocol.mjs";
import { RAW_SELECTOR_SCROLLBAR_CALIBRATION_KIND } from "../src/raw-selector-calibration.mjs";

function queue(overrides = {}) {
  const base = {
    schema_version: 1,
    generation_id: "lab-generation-001",
    target_kind: "lab",
    allowed_operations: ["capture", "click", "drag"],
    artifact_root: "/tmp/osrs-adapter-lab",
    items: [{
      id: "item-001",
      kind: "lab-click-drag",
      operations: [
        { kind: "capture" },
        { kind: "click", point: { x: 120, y: 100 }, button: "left", delivery_mode: "foreground_pid" },
        { kind: "drag", from: { x: 160, y: 160 }, to: { x: 300, y: 220 }, delivery_mode: "foreground_pid" }
      ]
    }],
    ...overrides
  };
  return finalizeQueueManifest(base);
}

test("valid queue is accepted", () => {
  const manifest = queue();
  assert.equal(validateQueueManifest(manifest).manifest.generation_id, manifest.generation_id);
});

test("semantic queue v2 accepts only the fixed map-capture vocabulary", () => {
  const manifest = finalizeQueueManifest({
    schema_version: 2,
    execution_profile: "semantic_map_capture_v1",
    generation_id: "semantic-generation-001",
    target_bundle_id: "com.jagex.osclient",
    allowed_operations: ["capture", "click", "drag"],
    artifact_root: "/tmp/osrs-adapter-semantic",
    items: [{
      id: "gielinor-37_5-east",
      kind: "semantic_map_capture",
      surface: "Gielinor Surface",
      zoom_percent: 37.5,
      criterion_family: "eastward_topology",
      restore_after_capture: true,
    }],
  });
  assert.equal(validateQueueManifest(manifest).manifest.schema_version, 2);

  const recoveryEnabled = structuredClone(manifest);
  recoveryEnabled.allowed_operations.push("open_world_map");
  delete recoveryEnabled.policy_digest;
  recoveryEnabled.items.forEach((item) => { delete item.item_sha256; });
  assert.equal(validateQueueManifest(finalizeQueueManifest(recoveryEnabled)).manifest.schema_version, 2);

  for (const injected of [
    { operations: [{ kind: "click", point: { x: 1, y: 1 }, button: "left" }] },
    { pan_from: { x: 1, y: 1 } },
    { zoom_percent: 125 },
    { restore_after_capture: "yes" },
  ]) {
    const changed = structuredClone(manifest);
    Object.assign(changed.items[0], injected);
    const finalized = finalizeQueueManifest(changed);
    assert.throws(() => validateQueueManifest(finalized), /QUEUE_SEMANTIC_ITEM_INVALID/);
  }
});

test("raw queue v1 rejects semantic execution profile", () => {
  assert.throws(
    () => validateQueueManifest(queue({ execution_profile: "semantic_map_capture_v1" })),
    /QUEUE_EXECUTION_PROFILE_INVALID/
  );
});

function selectorCalibrationQueue(overrides = {}) {
  return finalizeQueueManifest({
    schema_version: 1,
    generation_id: "selector-calibration-001",
    target_bundle_id: "com.jagex.osclient",
    allowed_operations: ["capture", "click", "drag"],
    artifact_root: "/tmp/osrs-selector-calibration",
    items: [{
      id: "selector-bottom",
      kind: RAW_SELECTOR_SCROLLBAR_CALIBRATION_KIND,
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
    }],
    ...overrides,
  });
}

test("raw selector scrollbar calibration accepts only the fixed one-drag shape", () => {
  const manifest = selectorCalibrationQueue();
  assert.equal(validateQueueManifest(manifest).manifest.items[0].kind, RAW_SELECTOR_SCROLLBAR_CALIBRATION_KIND);

  for (const mutate of [
    (draft) => { draft.target_bundle_id = undefined; draft.target_kind = "lab"; },
    (draft) => { draft.items[0].operations.pop(); },
    (draft) => { draft.items[0].operations.push(structuredClone(draft.items[0].operations[2])); },
    (draft) => { draft.items[0].operations[2].to.y = draft.items[0].operations[2].from.y - 1; },
    (draft) => { draft.items[0].operations[1].delivery_mode = "background_pid"; },
    (draft) => { draft.items[0].surface = "Zanaris"; },
  ]) {
    const changed = structuredClone(manifest);
    delete changed.policy_digest;
    changed.items = changed.items.map((item) => {
      const copy = { ...item };
      delete copy.item_sha256;
      return copy;
    });
    mutate(changed);
    assert.throws(
      () => validateQueueManifest(finalizeQueueManifest(changed)),
      /QUEUE_SELECTOR_SCROLLBAR_CALIBRATION_INVALID/
    );
  }
});

test("keyboard operation is rejected", () => {
  const manifest = queue({ allowed_operations: ["capture", "keyboard"] });
  assert.throws(() => validateQueueManifest(manifest), /QUEUE_OPERATION_FORBIDDEN/);
});

test("fixed world map shortcut accepts no key or modifier parameters", () => {
  const fixed = queue({
    target_kind: undefined,
    target_bundle_id: "com.jagex.osclient",
    allowed_operations: ["capture", "open_world_map"],
    items: [{
      id: "open-map-001",
      kind: "osrs-recovery-v1-GAMEPLAY_NO_MAP",
      operations: [
        { kind: "capture" },
        {
          kind: "open_world_map",
          event_source_mode: "combined_session_state",
          delivery_mode: "foreground_global"
        }
      ]
    }]
  });
  assert.equal(validateQueueManifest(fixed).manifest.items[0].operations[1].kind, "open_world_map");

  for (const mutate of [
    (operation) => { operation.key_code = 4; },
    (operation) => { operation.modifiers = ["control"]; },
    (operation) => { operation.delivery_mode = "background_pid"; }
  ]) {
    const changed = structuredClone(fixed);
    delete changed.policy_digest;
    changed.items.forEach((item) => { delete item.item_sha256; });
    mutate(changed.items[0].operations[1]);
    assert.throws(
      () => validateQueueManifest(finalizeQueueManifest(changed)),
      /QUEUE_WORLD_MAP_SHORTCUT_BOUNDARY_INVALID/
    );
  }
});

test("repair requires lineage", () => {
  const manifest = queue({
    items: [{
      id: "repair-001",
      kind: "lab-click-drag",
      supersedes_item_id: "item-001",
      operations: [{ kind: "capture" }]
    }]
  });
  assert.throws(() => validateQueueManifest(manifest), /QUEUE_REPAIR_LINEAGE_INVALID/);
});

test("repair lineage must include superseded item", () => {
  const manifest = queue({
    items: [{
      id: "repair-001",
      kind: "lab-click-drag",
      supersedes_item_id: "item-001",
      repair_lineage: ["different-item"],
      operations: [{ kind: "capture" }]
    }]
  });
  assert.throws(() => validateQueueManifest(manifest), /QUEUE_REPAIR_LINEAGE_INVALID/);
});

test("unknown event source mode is rejected", () => {
  const manifest = queue({
    items: [{
      id: "item-001",
      kind: "lab-click",
      operations: [{
        kind: "click",
        point: { x: 120, y: 100 },
        button: "left",
        event_source_mode: "unsupported"
      }]
    }]
  });
  assert.throws(() => validateQueueManifest(manifest), /QUEUE_EVENT_SOURCE_MODE_INVALID/);
});

test("unknown delivery mode is rejected", () => {
  const manifest = queue({
    items: [{
      id: "item-001",
      kind: "lab-click",
      operations: [{
        kind: "click",
        point: { x: 120, y: 100 },
        button: "left",
        delivery_mode: "unsupported"
      }]
    }]
  });
  assert.throws(() => validateQueueManifest(manifest), /QUEUE_DELIVERY_MODE_INVALID/);
});

test("queue and per-item operation counts are bounded", () => {
  assert.throws(
    () => validateQueueManifest(queue({
      items: Array.from({ length: 129 }, (_, index) => ({
        id: `item-${index}`,
        kind: "capture",
        operations: [{ kind: "capture" }]
      }))
    })),
    /QUEUE_ITEMS_REQUIRED/
  );
  assert.throws(
    () => validateQueueManifest(queue({
      items: [{
        id: "item-001",
        kind: "capture",
        operations: Array.from({ length: 33 }, () => ({ kind: "capture" }))
      }]
    })),
    /QUEUE_ITEM_OPERATIONS_REQUIRED/
  );
});
