import fs from "node:fs";
import path from "node:path";

import { finalizeQueueManifest, sha256 } from "../src/protocol.mjs";

const options = parseArguments(process.argv.slice(2));
for (const required of ["output", "artifact-root", "generation", "item-id", "mode"]) {
  if (!options[required]) throw new Error(`--${required} required`);
}
if (!new Set(["capture", "proof"]).has(options.mode)) {
  throw new Error("--mode must be capture or proof");
}

const operations = [{ kind: "capture" }];
if (options.mode === "proof") {
  operations.push(
    {
      kind: "click",
      point: point(options["click-point"] || "700,700"),
      button: "left",
      event_source_mode: "combined_session_state",
      delivery_mode: "foreground_global"
    },
    {
      kind: "drag",
      from: point(options["drag-from"] || "620,760"),
      to: point(options["drag-to"] || "780,760"),
      event_source_mode: "combined_session_state",
      delivery_mode: "foreground_global"
    }
  );
}

const manifest = finalizeQueueManifest({
  schema_version: 1,
  generation_id: options.generation,
  target_bundle_id: "com.jagex.osclient",
  allowed_operations: [...new Set(operations.map(({ kind }) => kind))],
  artifact_root: path.resolve(options["artifact-root"]),
  items: [{
    id: options["item-id"],
    kind: options.mode === "capture" ? "osrs-map-capture-proof" : "osrs-map-input-proof",
    operations
  }]
});
const data = `${JSON.stringify(manifest, null, 2)}\n`;
const destination = path.resolve(options.output);
fs.mkdirSync(path.dirname(destination), { recursive: true, mode: 0o700 });
fs.writeFileSync(destination, data, { flag: "wx", mode: 0o444 });
fs.chmodSync(destination, 0o444);
process.stdout.write(`${JSON.stringify({ path: destination, sha256: sha256(data), manifest })}\n`);

function point(value) {
  const [x, y] = value.split(",").map(Number);
  if (!Number.isFinite(x) || !Number.isFinite(y) || x < 0 || y < 0) {
    throw new Error(`invalid point ${value}`);
  }
  return { x, y };
}

function parseArguments(arguments_) {
  const result = {};
  for (let index = 0; index < arguments_.length; index += 2) {
    const key = arguments_[index];
    if (!key?.startsWith("--") || !arguments_[index + 1]) {
      throw new Error(`invalid argument ${key}`);
    }
    result[key.slice(2)] = arguments_[index + 1];
  }
  return result;
}
