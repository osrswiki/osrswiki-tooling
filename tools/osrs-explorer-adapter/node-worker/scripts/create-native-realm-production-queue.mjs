#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";

import { createNativeRealmCoverageLedger } from "../src/native-realm-ledger.mjs";
import {
  planNativeRealmCoverage,
  queueItemsForCoveragePlan,
} from "../src/native-realm-coverage.mjs";
import { finalizeQueueManifest } from "../src/protocol.mjs";

const args = parseArgs(process.argv.slice(2));
if (!args.generationID || !args.artifactRoot || !args.queueOutput || !args.ledgerOutput) {
  throw new Error(
    "USAGE:create-native-realm-production-queue.mjs --generation <id> --artifact-root <absolute> --queue-output <absolute.json> --ledger-output <absolute.json> [--run-id <id>]"
  );
}
for (const [label, value] of [
  ["artifact root", args.artifactRoot],
  ["queue output", args.queueOutput],
  ["ledger output", args.ledgerOutput],
]) {
  if (!path.isAbsolute(value)) throw new Error(`ABSOLUTE_${label.toUpperCase().replaceAll(" ", "_")}_REQUIRED`);
}
if (!/^[A-Za-z0-9._-]+$/.test(args.generationID)) throw new Error("GENERATION_ID_INVALID");
if (args.runID && (!/^[A-Za-z0-9._-]+$/.test(args.runID) || args.runID.length > 64)) {
  throw new Error("RUN_ID_INVALID");
}

const plan = planNativeRealmCoverage();
const items = queueItemsForCoveragePlan(plan);
const manifest = finalizeQueueManifest({
  schema_version: 2,
  execution_profile: "semantic_map_capture_v1",
  generation_id: args.generationID,
  run_id: args.runID ?? null,
  target_bundle_id: "com.jagex.osclient",
  allowed_operations: ["capture", "click", "drag", "open_world_map"],
  artifact_root: args.artifactRoot,
  items,
});
const ledger = createNativeRealmCoverageLedger({ queue: manifest, plan });
writeImmutableJSON(args.queueOutput, manifest);
writeImmutableJSON(args.ledgerOutput, ledger);
process.stdout.write(`${JSON.stringify({
  status: "NATIVE_REALM_PRODUCTION_QUEUE_READY",
  catalog_version: plan.catalog_version,
  planner_version: plan.planner_version,
  generation_id: args.generationID,
  queue_output: args.queueOutput,
  ledger_output: args.ledgerOutput,
  realm_count: plan.realm_count,
  zoom_levels: plan.zoom_levels,
  item_count: manifest.items.length,
  coverage_positions: plan.proof.total_positions,
  excluded_other_maps_count: 1047,
})}\n`);

function parseArgs(values) {
  const result = {};
  for (let index = 0; index < values.length; index += 1) {
    const key = values[index];
    const value = values[index + 1];
    if (key === "--generation") {
      result.generationID = value;
      index += 1;
    } else if (key === "--artifact-root") {
      result.artifactRoot = value;
      index += 1;
    } else if (key === "--queue-output") {
      result.queueOutput = value;
      index += 1;
    } else if (key === "--ledger-output") {
      result.ledgerOutput = value;
      index += 1;
    } else if (key === "--run-id") {
      result.runID = value;
      index += 1;
    } else {
      throw new Error(`ARGUMENT_UNSUPPORTED:${key}`);
    }
  }
  return result;
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
