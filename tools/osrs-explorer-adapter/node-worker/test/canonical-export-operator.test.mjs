import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";

import { canonicalJson, sha256 } from "../src/protocol.mjs";

const workerRoot = path.resolve(import.meta.dirname, "..");
const operator = path.join(workerRoot, "scripts", "canonical-export-operator.mjs");

test("canonical export prepares one sandbox-accepted semantic result without submission", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "semantic-export-"));
  const fullPath = immutable(path.join(root, "fresh.png"), Buffer.from("fresh-frame"));
  const cropPath = immutable(path.join(root, "map.png"), Buffer.from("map-crop"));
  const resultPath = path.join(root, "result.json");
  const result = {
    schema_version: 2,
    execution_profile: "semantic_map_capture_v1",
    generation_id: "semantic-generation",
    item_id: "semantic-item-001",
    item_sha256: "a".repeat(64),
    requested_work: {
      surface: "Gielinor Surface",
      zoom_percent: 37.5,
      criterion_family: "eastward_topology",
      restore_after_capture: false,
    },
    target_identity: {
      bundle_identifier: "com.jagex.osclient",
      process_identifier: 41,
      window_identifier: 73,
    },
    surface_proof: { ready_gate: { passed: true } },
    zoom_proof: { observed_zoom_percent: 37.5 },
    pan_proof: {
      fresh_frame: {
        captureIdentifier: "fresh",
        capturedAt: "2026-08-05T00:00:00.000Z",
        pngPath: fullPath,
        pngSHA256: sha256(fs.readFileSync(fullPath)),
      },
      fresh_gate: { passed: true },
      novelty: { passed: true },
    },
    map_crop: {
      path: cropPath,
      sha256: sha256(fs.readFileSync(cropPath)),
      width: 516,
      height: 641,
    },
    recovery_history: [],
    action_history: [],
  };
  result.result_digest = sha256(canonicalJson(result));
  immutable(resultPath, Buffer.from(`${JSON.stringify(result, null, 2)}\n`));

  const sandboxRoot = path.join(root, "sandbox-broker");
  const acceptancePath = path.join(sandboxRoot, "commits", "000001-semantic-generation-semantic-item-001.json");
  const acceptance = {
    schema_version: 1,
    sandbox_only: true,
    sequence: 1,
    previous_commit_sha256: "0".repeat(64),
    generation_id: result.generation_id,
    item_id: result.item_id,
    item_sha256: result.item_sha256,
    result_path: resultPath,
    result_file_sha256: sha256(fs.readFileSync(resultPath)),
    result_digest: result.result_digest,
    broker_protocol: { protocol: "osrs-capture-broker-v4" },
  };
  immutable(acceptancePath, Buffer.from(`${JSON.stringify(acceptance, null, 2)}\n`));
  fs.mkdirSync(sandboxRoot, { recursive: true });
  fs.writeFileSync(path.join(sandboxRoot, "HEAD.json"), `${JSON.stringify({
    sequence: 1,
    commit_sha256: sha256(fs.readFileSync(acceptancePath)),
  }, null, 2)}\n`, { mode: 0o600 });

  const headPath = path.join(root, "HEAD.json");
  immutable(headPath, Buffer.from(`${JSON.stringify({
    sequence: 809,
    commit_sha256: "b".repeat(64),
  }, null, 2)}\n`));
  const outputPath = path.join(root, "export", "prepared.json");
  const execution = spawnSync(process.execPath, [
    operator,
    "--result", resultPath,
    "--sandbox-acceptance", acceptancePath,
    "--sandbox-broker-root", sandboxRoot,
    "--head", headPath,
    "--stage-root", path.join(root, "stage"),
    "--batch-root", path.join(root, "batch"),
    "--spool-root", path.join(root, "spool"),
    "--explorer-thread-id", "pilot-thread",
    "--output", outputPath,
  ], { cwd: workerRoot, encoding: "utf8" });

  assert.equal(execution.status, 0, execution.stderr);
  const status = JSON.parse(execution.stdout);
  assert.equal(status.status, "CANONICAL_EXPORT_PREPARED_NOT_SUBMITTED");
  assert.equal(fs.statSync(outputPath).mode & 0o777, 0o444);
  const prepared = JSON.parse(fs.readFileSync(outputPath, "utf8"));
  assert.deepEqual(prepared.expected_predecessor, {
    sequence: 809,
    commit_sha256: "b".repeat(64),
  });
  assert.equal(prepared.request.expected_predecessor.sequence, 809);
  assert.equal(prepared.request.expected_predecessor.commit_sha256, "b".repeat(64));
  assert.equal(prepared.request.idempotency_key, prepared.idempotency_key);
  assert.equal(prepared.request.metadata.explorer_thread_id, "pilot-thread");
  assert.equal(prepared.request.metadata.sandbox_acceptance.path, acceptancePath);
  assert.equal(fs.readdirSync(path.join(root, "stage")).length, 2);
  assert.equal(fs.existsSync(path.join(root, "spool", "requests")), false);
});

function immutable(destination, bytes) {
  fs.mkdirSync(path.dirname(destination), { recursive: true });
  fs.writeFileSync(destination, bytes, { flag: "wx", mode: 0o600 });
  fs.chmodSync(destination, 0o444);
  return destination;
}
