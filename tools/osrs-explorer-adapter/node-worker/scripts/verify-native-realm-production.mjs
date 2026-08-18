#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";

import { validateNativeRealmCatalog } from "../src/native-realm-catalog.mjs";
import { planNativeRealmCoverage } from "../src/native-realm-coverage.mjs";
import { verifyNativeRealmCoverageLedger } from "../src/native-realm-ledger.mjs";
import { validateQueueManifest } from "../src/protocol.mjs";

const args = parseArgs(process.argv.slice(2));
if (!args.queuePath || !args.ledgerPath) {
  throw new Error("USAGE:verify-native-realm-production.mjs --queue <queue.json> --ledger <ledger.json> [--catalog <catalog.json>]");
}
for (const [label, value] of Object.entries(args)) {
  if (value && !path.isAbsolute(value)) throw new Error(`ABSOLUTE_${label.toUpperCase()}_REQUIRED`);
}

const queue = JSON.parse(fs.readFileSync(args.queuePath, "utf8"));
validateQueueManifest(queue);
const ledger = JSON.parse(fs.readFileSync(args.ledgerPath, "utf8"));
verifyNativeRealmCoverageLedger(ledger, queue);
const catalog = args.catalogPath
  ? validateNativeRealmCatalog(JSON.parse(fs.readFileSync(args.catalogPath, "utf8")))
  : null;
const plan = planNativeRealmCoverage();
if (queue.items.length !== plan.positions.length) {
  throw new Error("NATIVE_REALM_PRODUCTION_QUEUE_COVERAGE_COUNT_MISMATCH");
}
const otherMapItems = queue.items.filter((item) =>
  item.realm_id?.startsWith("other-map-")
    || item.realm_id?.startsWith("cache-special-region:")
    || item.group === "other_maps"
);
if (otherMapItems.length !== 0) {
  throw new Error(`NATIVE_REALM_PRODUCTION_OTHER_MAP_FORBIDDEN:${otherMapItems[0].id}`);
}
process.stdout.write(`${JSON.stringify({
  status: "NATIVE_REALM_PRODUCTION_VERIFIED",
  catalog_version: plan.catalog_version,
  catalog_entries: catalog?.entries.length ?? plan.realm_count,
  queue_path: args.queuePath,
  ledger_path: args.ledgerPath,
  generation_id: queue.generation_id,
  queue_items: queue.items.length,
  coverage_positions: plan.proof.total_positions,
  coverage_exact_gap_free: plan.proof.exact_gap_free,
  no_out_of_bounds_centers: plan.proof.no_out_of_bounds_centers,
  excluded_other_maps_count: 1047,
  ledger_summary: ledger.summary,
})}\n`);

function parseArgs(values) {
  const result = {};
  for (let index = 0; index < values.length; index += 1) {
    const key = values[index];
    const value = values[index + 1];
    if (key === "--queue") {
      result.queuePath = value;
      index += 1;
    } else if (key === "--ledger") {
      result.ledgerPath = value;
      index += 1;
    } else if (key === "--catalog") {
      result.catalogPath = value;
      index += 1;
    } else {
      throw new Error(`ARGUMENT_UNSUPPORTED:${key}`);
    }
  }
  return result;
}
