#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";

import { verifyNativeRealmCoverageLedger } from "../src/native-realm-ledger.mjs";
import { validateQueueManifest } from "../src/protocol.mjs";

const args = parseArgs(process.argv.slice(2));
for (const name of ["fullQueue", "successorQueue", "ledger", "carry"]) {
  if (!args[name]) throw new Error(`NATIVE_REALM_V11_VERIFY_OPTION_REQUIRED:${name}`);
  if (!path.isAbsolute(args[name])) throw new Error(`NATIVE_REALM_V11_VERIFY_ABSOLUTE_PATH_REQUIRED:${name}`);
}

const fullQueue = readImmutableJSON(args.fullQueue);
const successorQueue = readImmutableJSON(args.successorQueue);
const ledger = readImmutableJSON(args.ledger);
const carry = readImmutableJSON(args.carry);
validateQueueManifest(fullQueue);
validateQueueManifest(successorQueue);
verifyNativeRealmCoverageLedger(ledger, successorQueue);

if (fullQueue.items.length !== 617
    || carry.expected_item_count !== fullQueue.items.length
    || carry.carried_item_count !== carry.carried?.length
    || carry.pending_item_count !== successorQueue.items.length
    || carry.carried_item_count + carry.pending_item_count !== fullQueue.items.length
    || carry.successor_generation_id !== successorQueue.generation_id
    || carry.successor_queue_policy_digest !== successorQueue.policy_digest
    || carry.full_queue_generation_id !== fullQueue.generation_id
    || carry.full_queue_policy_digest !== fullQueue.policy_digest
    || ledger.catalog_version !== "native-selector-catalog-v4"
    || ledger.planner_version !== "native-realm-coverage-planner-v14") {
  throw new Error("NATIVE_REALM_V11_SUCCESSOR_SUMMARY_INVALID");
}

const fullByID = new Map(fullQueue.items.map((item) => [item.id, item]));
const carriedIDs = new Set();
for (const entry of carry.carried) {
  const item = fullByID.get(entry.target_item_id);
  if (!item
      || carriedIDs.has(item.id)
      || item.item_sha256 !== entry.target_item_sha256
      || entry.capture_proofs?.length !== 3
      || new Set(entry.capture_proofs.map((proof) => proof.sha256)).size !== 3
      || entry.capture_proofs.some((proof) =>
        proof.observed_surface !== item.surface
          || proof.normalized_correlation < 0.72
          || proof.correlation_separation < 0.08
      )) {
    throw new Error(`NATIVE_REALM_V11_CARRY_ENTRY_INVALID:${entry.target_item_id}`);
  }
  carriedIDs.add(item.id);
}

const pendingIDs = new Set();
for (const item of successorQueue.items) {
  const fullItem = fullByID.get(item.id);
  if (!fullItem
      || pendingIDs.has(item.id)
      || carriedIDs.has(item.id)
      || fullItem.item_sha256 !== item.item_sha256) {
    throw new Error(`NATIVE_REALM_V11_PENDING_ENTRY_INVALID:${item.id}`);
  }
  pendingIDs.add(item.id);
}
if ([...fullByID.keys()].some((id) => !carriedIDs.has(id) && !pendingIDs.has(id))) {
  throw new Error("NATIVE_REALM_V11_PARTITION_GAP");
}

process.stdout.write(`${JSON.stringify({
  status: "NATIVE_REALM_V11_SUCCESSOR_VERIFIED",
  catalog_version: ledger.catalog_version,
  planner_version: ledger.planner_version,
  expected_items: fullQueue.items.length,
  carried_items: carriedIDs.size,
  pending_items: pendingIDs.size,
  rejected_acceptances: carry.rejected_acceptance_count,
  successor_generation_id: successorQueue.generation_id,
  successor_queue_policy_digest: successorQueue.policy_digest,
  ledger_summary: ledger.summary,
})}\n`);

function parseArgs(values) {
  const result = {};
  const names = new Map([
    ["--full-queue", "fullQueue"], ["--successor-queue", "successorQueue"],
    ["--ledger", "ledger"], ["--carry", "carry"],
  ]);
  for (let index = 0; index < values.length; index += 2) {
    const name = names.get(values[index]);
    if (!name || values[index + 1] === undefined) throw new Error(`ARGUMENT_UNSUPPORTED:${values[index]}`);
    result[name] = values[index + 1];
  }
  return result;
}

function readImmutableJSON(filePath) {
  const stat = fs.lstatSync(filePath);
  if (!stat.isFile() || stat.isSymbolicLink() || (stat.mode & 0o222) !== 0) {
    throw new Error(`IMMUTABLE_FILE_REQUIRED:${filePath}`);
  }
  return JSON.parse(fs.readFileSync(filePath, "utf8"));
}
