#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";

import { validateNativeRealmCarryForward } from "../src/native-realm-carry-forward.mjs";
import { createNativeRealmCoverageLedger } from "../src/native-realm-ledger.mjs";
import { planNativeRealmCoverage, queueItemsForCoveragePlan } from "../src/native-realm-coverage.mjs";
import { finalizeQueueManifest } from "../src/protocol.mjs";

const args = parseArgs(process.argv.slice(2));
for (const name of [
  "generationID", "artifactRoot", "brokerRoot", "fullQueueOutput",
  "queueOutput", "ledgerOutput", "carryOutput",
]) {
  if (!args[name]) throw new Error(`NATIVE_REALM_V11_OPTION_REQUIRED:${name}`);
}
for (const name of [
  "artifactRoot", "brokerRoot", "fullQueueOutput", "queueOutput", "ledgerOutput", "carryOutput",
]) {
  if (!path.isAbsolute(args[name])) throw new Error(`NATIVE_REALM_V11_ABSOLUTE_PATH_REQUIRED:${name}`);
}
if (!/^[A-Za-z0-9._-]+$/.test(args.generationID)) throw new Error("GENERATION_ID_INVALID");

const plan = planNativeRealmCoverage();
const fullItems = queueItemsForCoveragePlan(plan);
const fullQueue = queueManifest(fullItems, `${args.generationID}-full-plan`);
const carry = await validateNativeRealmCarryForward({
  brokerRoot: args.brokerRoot,
  queueItems: fullQueue.items,
});
const pendingByID = new Set(carry.pending.map((item) => item.id));
const successorQueue = queueManifest(
  fullItems.filter((item) => pendingByID.has(item.id)),
  args.generationID
);
const successorPlan = { ...plan, positions: plan.positions.filter((position) => pendingByID.has(position.id)) };
const ledger = createNativeRealmCoverageLedger({ queue: successorQueue, plan: successorPlan });
const carryReport = {
  schema_version: carry.schema_version,
  carry_profile: carry.carry_profile,
  catalog_version: plan.catalog_version,
  planner_version: plan.planner_version,
  full_queue_generation_id: fullQueue.generation_id,
  full_queue_policy_digest: fullQueue.policy_digest,
  successor_generation_id: successorQueue.generation_id,
  successor_queue_policy_digest: successorQueue.policy_digest,
  broker_head: carry.broker_head,
  broker_commit_count: carry.broker_commit_count,
  expected_item_count: carry.expected_item_count,
  carried_item_count: carry.carried_item_count,
  pending_item_count: carry.pending_item_count,
  rejected_acceptance_count: carry.rejected_acceptance_count,
  carried: carry.carried,
  rejected: carry.rejected,
};

writeImmutableJSON(args.fullQueueOutput, fullQueue);
writeImmutableJSON(args.queueOutput, successorQueue);
writeImmutableJSON(args.ledgerOutput, ledger);
writeImmutableJSON(args.carryOutput, carryReport);
process.stdout.write(`${JSON.stringify({
  status: "NATIVE_REALM_V11_SUCCESSOR_READY",
  catalog_version: plan.catalog_version,
  planner_version: plan.planner_version,
  generation_id: successorQueue.generation_id,
  expected_items: carry.expected_item_count,
  carried_items: carry.carried_item_count,
  pending_items: carry.pending_item_count,
  rejected_acceptances: carry.rejected_acceptance_count,
  queue_output: args.queueOutput,
  ledger_output: args.ledgerOutput,
  carry_output: args.carryOutput,
})}\n`);

function queueManifest(items, generationID) {
  return finalizeQueueManifest({
    schema_version: 2,
    execution_profile: "semantic_map_capture_v1",
    generation_id: generationID,
    run_id: args.runID ?? null,
    target_bundle_id: "com.jagex.osclient",
    allowed_operations: ["capture", "click", "drag", "open_world_map"],
    artifact_root: args.artifactRoot,
    items,
  });
}

function parseArgs(values) {
  const result = {};
  const names = new Map([
    ["--generation", "generationID"], ["--artifact-root", "artifactRoot"],
    ["--broker-root", "brokerRoot"], ["--full-queue-output", "fullQueueOutput"],
    ["--queue-output", "queueOutput"], ["--ledger-output", "ledgerOutput"],
    ["--carry-output", "carryOutput"], ["--run-id", "runID"],
  ]);
  for (let index = 0; index < values.length; index += 2) {
    const name = names.get(values[index]);
    if (!name || values[index + 1] === undefined) throw new Error(`ARGUMENT_UNSUPPORTED:${values[index]}`);
    result[name] = values[index + 1];
  }
  return result;
}

function writeImmutableJSON(destination, value) {
  fs.mkdirSync(path.dirname(destination), { recursive: true, mode: 0o700 });
  const descriptor = fs.openSync(destination, "wx", 0o600);
  try {
    fs.writeFileSync(descriptor, `${JSON.stringify(value, null, 2)}\n`);
    fs.fsyncSync(descriptor);
  } finally {
    fs.closeSync(descriptor);
  }
  fs.chmodSync(destination, 0o444);
}
