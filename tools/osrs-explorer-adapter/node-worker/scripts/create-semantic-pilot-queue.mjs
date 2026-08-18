#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";

import { finalizeQueueManifest } from "../src/protocol.mjs";
import {
  loadSemanticCalibrationRegistry,
  semanticPilotItems,
} from "../src/semantic-profile.mjs";

const [profile, generationID, artifactRoot, outputPath, runID] = process.argv.slice(2);
if (!profile || !generationID || !artifactRoot || !outputPath) {
  throw new Error(
    "USAGE:create-semantic-pilot-queue.mjs <motion-smoke|surface-smoke|terminal-realm-performance|matrix|operational-soak|canonical-canary|canonical-5|canonical-10|canonical-25> <generation-id> <artifact-root> <output-path> [run-id]"
  );
}
if (!/^[A-Za-z0-9._-]+$/.test(generationID)) throw new Error("GENERATION_ID_INVALID");
if (runID && (!/^[A-Za-z0-9._-]+$/.test(runID) || runID.length > 64)) {
  throw new Error("RUN_ID_INVALID");
}
if (!path.isAbsolute(artifactRoot) || !path.isAbsolute(outputPath)) {
  throw new Error("ABSOLUTE_PATHS_REQUIRED");
}
loadSemanticCalibrationRegistry({ requireAll: true });

const items = semanticPilotItems(profile).map((item, index) => ({
  id: `${profile}${runID ? `-${runID}` : ""}-${String(index + 1).padStart(3, "0")}`,
  ...item,
}));
const manifest = finalizeQueueManifest({
  schema_version: 2,
  execution_profile: "semantic_map_capture_v1",
  generation_id: generationID,
  run_id: runID ?? null,
  target_bundle_id: "com.jagex.osclient",
  allowed_operations: ["capture", "click", "drag", "open_world_map"],
  artifact_root: artifactRoot,
  items,
});
writeImmutableJSON(outputPath, manifest);
process.stdout.write(`${JSON.stringify({
  status: "SEMANTIC_PILOT_QUEUE_READY",
  profile,
  generation_id: generationID,
  item_count: items.length,
  output_path: outputPath,
})}\n`);

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
