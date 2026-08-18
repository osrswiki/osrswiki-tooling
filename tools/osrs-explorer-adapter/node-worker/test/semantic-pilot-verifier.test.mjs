import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";

import { canonicalJson, finalizeQueueManifest, sha256 } from "../src/protocol.mjs";
import { semanticPilotItems } from "../src/semantic-profile.mjs";

const workerRoot = path.resolve(import.meta.dirname, "..");
const verifier = path.join(workerRoot, "scripts", "verify-semantic-pilot.mjs");

test("semantic pilot verifier requires the complete accepted profile and timing gates", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "semantic-pilot-verify-"));
  const artifactRoot = path.join(root, "artifacts");
  const queue = finalizeQueueManifest({
    schema_version: 2,
    execution_profile: "semantic_map_capture_v1",
    generation_id: "canonical-canary-generation",
    target_bundle_id: "com.jagex.osclient",
    allowed_operations: ["capture", "click", "drag"],
    artifact_root: artifactRoot,
    items: [{
      id: "canonical-canary-001",
      kind: "semantic_map_capture",
      surface: "Gielinor Surface",
      zoom_percent: 37.5,
      criterion_family: "eastward_topology",
      restore_after_capture: false,
    }],
  });
  const queuePath = immutable(
    path.join(root, "queue.json"),
    Buffer.from(`${JSON.stringify(queue, null, 2)}\n`)
  );
  const item = queue.items[0];
  const result = {
    schema_version: 2,
    execution_profile: "semantic_map_capture_v1",
    generation_id: queue.generation_id,
    item_id: item.id,
    item_sha256: item.item_sha256,
    requested_work: {
      surface: item.surface,
      zoom_percent: item.zoom_percent,
      criterion_family: item.criterion_family,
      restore_after_capture: item.restore_after_capture,
    },
    surface_proof: {
      ready_gate: { passed: true },
      selector_navigation: {
        required: false,
        mode: null,
        anchor: null,
        maximum_drags: 0,
        drags: 0,
        transitions: [],
      },
    },
    zoom_proof: { observed_zoom_percent: item.zoom_percent },
    pan_proof: {
      pre_gate: { passed: true },
      post_gate: { passed: true },
      fresh_gate: { passed: true },
      novelty: { passed: true },
    },
    restoration_proof: { required: false, delivered: false },
    surface_reset_proof: { required: false, delivered: false },
    recovery_history: [],
    performance: {
      elapsed_milliseconds: 12_000,
      input_to_qualified_post_capture_milliseconds: 1_500,
      selector_open_to_surface_qualified_milliseconds: 500,
      hard_deadline_milliseconds: 120_000,
    },
  };
  result.result_digest = sha256(canonicalJson(result));
  const resultPath = immutable(
    path.join(artifactRoot, "worker", queue.generation_id, `${item.id}.json`),
    Buffer.from(`${JSON.stringify(result, null, 2)}\n`)
  );
  const brokerRoot = path.join(root, "broker");
  const priorCommit = {
    schema_version: 1,
    sandbox_only: true,
    sequence: 1,
    previous_commit_sha256: "0".repeat(64),
    generation_id: "prior-generation",
    item_id: "prior-item",
    item_sha256: "1".repeat(64),
    result_path: "/retained/prior-result.json",
    result_file_sha256: "2".repeat(64),
    result_digest: "3".repeat(64),
    broker_protocol: { protocol: "osrs-capture-broker-v4" },
  };
  const priorCommitPath = immutable(
    path.join(brokerRoot, "commits", "000001-prior-generation-prior-item.json"),
    Buffer.from(`${JSON.stringify(priorCommit, null, 2)}\n`)
  );
  const priorCommitSHA256 = sha256(fs.readFileSync(priorCommitPath));
  const commit = {
    schema_version: 1,
    sandbox_only: true,
    sequence: 2,
    previous_commit_sha256: priorCommitSHA256,
    generation_id: queue.generation_id,
    item_id: item.id,
    item_sha256: item.item_sha256,
    result_path: resultPath,
    result_file_sha256: sha256(fs.readFileSync(resultPath)),
    result_digest: result.result_digest,
    broker_protocol: { protocol: "osrs-capture-broker-v4" },
  };
  const commitPath = immutable(
    path.join(brokerRoot, "commits", `000002-${queue.generation_id}-${item.id}.json`),
    Buffer.from(`${JSON.stringify(commit, null, 2)}\n`)
  );
  fs.writeFileSync(path.join(brokerRoot, "HEAD.json"), `${JSON.stringify({
    sequence: 2,
    commit_sha256: sha256(fs.readFileSync(commitPath)),
  }, null, 2)}\n`, { mode: 0o600 });
  const outputPath = path.join(root, "report.json");
  const execution = spawnSync(process.execPath, [
    verifier,
    "--profile", "canonical-canary",
    "--queue", queuePath,
    "--broker-root", brokerRoot,
    "--output", outputPath,
  ], { cwd: workerRoot, encoding: "utf8" });

  assert.equal(execution.status, 0, execution.stderr);
  const report = JSON.parse(execution.stdout);
  assert.equal(report.status, "SEMANTIC_PILOT_PHASE_ACCEPTED");
  assert.equal(report.accepted_item_count, 1);
  assert.deepEqual(report.phase_commit_range, { first_sequence: 2, last_sequence: 2 });
  assert.equal(report.performance.no_recovery_item_p95_milliseconds, 12_000);
  assert.equal(report.performance.input_to_qualified_post_capture_p95_milliseconds, 1_500);
  assert.equal(report.performance.selector_open_to_surface_qualified_p95_milliseconds, 500);
  assert.equal(fs.statSync(outputPath).mode & 0o777, 0o444);
});

test("terminal realm verifier requires all 20 drags, selections, restorations, and resets", () => {
  const execution = runTerminalPilot(Array.from({ length: 20 }, (_, index) => 500 + index * 50));
  assert.equal(execution.status, 0, execution.stderr);
  const report = JSON.parse(execution.stdout);
  assert.equal(report.accepted_item_count, 20);
  assert.equal(report.performance.selector_open_to_surface_qualified_p95_milliseconds, 1_400);
  assert.equal(report.performance.selector_open_to_surface_qualified_maximum_milliseconds, 1_450);
  assert.deepEqual(report.selector_certification, {
    bottom_drag_count: 20,
    terminal_selection_count: 20,
    restored_capture_count: 20,
    verified_gielinor_reset_count: 20,
  });
});

test("terminal realm verifier aggregates exact accepted items across restarted generations", () => {
  const execution = runTerminalPilot(
    Array.from({ length: 20 }, (_, index) => 500 + index * 50),
    () => {},
    (index) => index === 0
      ? "terminal-realm-performance-prior-generation"
      : "terminal-realm-performance-generation"
  );
  assert.equal(execution.status, 0, execution.stderr);
  const report = JSON.parse(execution.stdout);
  assert.equal(report.accepted_item_count, 20);
  assert.deepEqual(report.accepted_generation_ids, [
    "terminal-realm-performance-prior-generation",
    "terminal-realm-performance-generation",
  ]);
  assert.deepEqual(report.phase_commit_range, { first_sequence: 1, last_sequence: 20 });
});

test("terminal realm verifier rejects any selector cycle over three seconds", () => {
  const durations = Array(20).fill(500);
  durations[19] = 3_001;
  const execution = runTerminalPilot(durations);
  assert.notEqual(execution.status, 0);
  assert.match(execution.stderr, /SEMANTIC_SELECTOR_MAXIMUM_EXCEEDED:3001/);
});

test("terminal realm verifier rejects the captured near-bottom thumb", () => {
  const execution = runTerminalPilot(Array(20).fill(500), (result, index) => {
    if (index !== 0) return;
    const proof = result.surface_proof.selector_navigation.transitions[0].post_drag_proof;
    proof.state = "intermediate";
    proof.normalized_observed_bbox = { left: 342, top: 615, right: 356, bottom: 629 };
    proof.top_clearance_pixels = 65;
    proof.bottom_clearance_pixels = 6;
    proof.remaining_travel_to_top_pixels = 65;
    proof.remaining_travel_to_bottom_pixels = 6;
  });
  assert.notEqual(execution.status, 0);
  assert.match(execution.stderr, /SEMANTIC_PILOT_RESULT_INVALID:terminal-cycle-01/);
});

function runTerminalPilot(
  selectorDurations,
  mutateResult = () => {},
  acceptedGeneration = () => "terminal-realm-performance-generation"
) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "semantic-terminal-pilot-"));
  const artifactRoot = path.join(root, "artifacts");
  const items = semanticPilotItems("terminal-realm-performance").map((item, index) => ({
    id: `terminal-cycle-${String(index + 1).padStart(2, "0")}`,
    ...item,
  }));
  const queue = finalizeQueueManifest({
    schema_version: 2,
    execution_profile: "semantic_map_capture_v1",
    generation_id: "terminal-realm-performance-generation",
    target_bundle_id: "com.jagex.osclient",
    allowed_operations: ["capture", "click", "drag"],
    artifact_root: artifactRoot,
    items,
  });
  const queuePath = immutable(
    path.join(root, "queue.json"),
    Buffer.from(`${JSON.stringify(queue, null, 2)}\n`)
  );
  const brokerRoot = path.join(root, "broker");
  let previousCommitSHA256 = "0".repeat(64);
  for (const [index, item] of queue.items.entries()) {
    const resultGeneration = acceptedGeneration(index);
    const result = {
      schema_version: 2,
      execution_profile: "semantic_map_capture_v1",
      generation_id: resultGeneration,
      item_id: item.id,
      item_sha256: item.item_sha256,
      requested_work: {
        surface: item.surface,
        zoom_percent: item.zoom_percent,
        criterion_family: item.criterion_family,
        restore_after_capture: item.restore_after_capture,
      },
      surface_proof: {
        ready_gate: { passed: true },
        selector_navigation: {
          required: true,
          mode: "scrollbar_drag",
          anchor: "bottom",
          maximum_drags: 1,
          drags: 1,
          transitions: [{
            mode: "scrollbar_drag",
            anchor: "bottom",
            post_drag_proof: scrollbarStopProof("bottom"),
          }],
        },
      },
      zoom_proof: { observed_zoom_percent: item.zoom_percent },
      pan_proof: {
        pre_gate: { passed: true },
        post_gate: { passed: true },
        fresh_gate: { passed: true },
        novelty: { passed: true },
      },
      restoration_proof: { required: true, delivered: true },
      surface_reset_proof: {
        required: true,
        delivered: true,
        requested_surface: "Gielinor Surface",
        post_drag_proof: scrollbarStopProof("top"),
        ready_gate: { passed: true },
      },
      recovery_history: [],
      performance: {
        elapsed_milliseconds: 5_000,
        input_to_qualified_post_capture_milliseconds: 1_000,
        selector_open_to_surface_qualified_milliseconds: selectorDurations[index],
        hard_deadline_milliseconds: 120_000,
      },
    };
    mutateResult(result, index);
    result.result_digest = sha256(canonicalJson(result));
    const resultPath = immutable(
      path.join(artifactRoot, "worker", resultGeneration, `${item.id}.json`),
      Buffer.from(`${JSON.stringify(result, null, 2)}\n`)
    );
    const commit = {
      schema_version: 1,
      sandbox_only: true,
      sequence: index + 1,
      previous_commit_sha256: previousCommitSHA256,
      generation_id: resultGeneration,
      item_id: item.id,
      item_sha256: item.item_sha256,
      result_path: resultPath,
      result_file_sha256: sha256(fs.readFileSync(resultPath)),
      result_digest: result.result_digest,
      broker_protocol: { protocol: "osrs-capture-broker-v4" },
    };
    const commitPath = immutable(
      path.join(
        brokerRoot,
        "commits",
        `${String(index + 1).padStart(6, "0")}-${resultGeneration}-${item.id}.json`
      ),
      Buffer.from(`${JSON.stringify(commit, null, 2)}\n`)
    );
    previousCommitSHA256 = sha256(fs.readFileSync(commitPath));
  }
  fs.writeFileSync(path.join(brokerRoot, "HEAD.json"), `${JSON.stringify({
    sequence: queue.items.length,
    commit_sha256: previousCommitSHA256,
  }, null, 2)}\n`, { mode: 0o600 });
  return spawnSync(process.execPath, [
    verifier,
    "--profile", "terminal-realm-performance",
    "--queue", queuePath,
    "--broker-root", brokerRoot,
    "--output", path.join(root, "report.json"),
  ], { cwd: workerRoot, encoding: "utf8" });
}

function scrollbarStopProof(anchor) {
  const top = anchor === "top" ? 543 : 613;
  const bottom = top + 16;
  const topClearance = top - 543;
  const bottomClearance = 629 - bottom;
  return {
    target: "SEMANTIC_SURFACE_SCROLLBAR_THUMB",
    anchor,
    state: anchor,
    selector_open: true,
    thumb_at_stop: true,
    exactly_one_target: true,
    pixel_resolution: 1,
    coordinate_semantics: "LEFT_TOP_INCLUSIVE_RIGHT_BOTTOM_EXCLUSIVE",
    stop_tolerance_pixels: 0,
    normalized_correlation: 0.9,
    distinct_second_correlation: 0.2,
    correlation_separation: 0.7,
    normalized_track_bbox: { left: 342, top: 543, right: 356, bottom: 629 },
    normalized_observed_bbox: { left: 342, top, right: 356, bottom },
    normalized_up_button_bbox: { left: 342, top: 529, right: 356, bottom: 543 },
    normalized_down_button_bbox: { left: 342, top: 629, right: 356, bottom: 643 },
    up_button_correlation: 0.95,
    up_button_distinct_second_correlation: 0.8,
    down_button_correlation: 0.95,
    down_button_distinct_second_correlation: 0.8,
    top_clearance_pixels: topClearance,
    bottom_clearance_pixels: bottomClearance,
    remaining_travel_to_top_pixels: topClearance,
    remaining_travel_to_bottom_pixels: bottomClearance,
    travel_range_pixels: 70,
    top_stop_thumb_top_bounds: { minimum: 543, maximum: 543 },
    bottom_stop_thumb_top_bounds: { minimum: 613, maximum: 613 },
  };
}

function immutable(destination, bytes) {
  fs.mkdirSync(path.dirname(destination), { recursive: true });
  fs.writeFileSync(destination, bytes, { flag: "wx", mode: 0o600 });
  fs.chmodSync(destination, 0o444);
  return destination;
}
