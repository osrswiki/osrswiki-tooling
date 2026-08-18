import fs from "node:fs";
import path from "node:path";

import { finalizeQueueManifest, sha256 } from "../src/protocol.mjs";

const options = parseArguments(process.argv.slice(2));
for (const required of ["output", "artifact-root", "generation", "mode"]) {
  if (!options[required]) throw new Error(`--${required} required`);
}
const operations = [{ kind: "capture" }];
const eventSourceMode = options["event-source-mode"] || "private_state";
const deliveryMode = options["delivery-mode"] || "background_pid";
if (options.mode === "ax") {
  operations.push({
    kind: "click",
    point: point(options["click-point"] || "200,170"),
    button: "left",
    event_source_mode: eventSourceMode,
    delivery_mode: deliveryMode
  });
} else if (options.mode === "left-click") {
  operations.push({
    kind: "click",
    point: point(options["click-point"] || "300,400"),
    button: "left",
    event_source_mode: eventSourceMode,
    delivery_mode: deliveryMode
  });
} else if (options.mode === "right-click") {
  operations.push({
    kind: "click",
    point: point(options["right-click-point"] || "900,700"),
    button: "right",
    event_source_mode: eventSourceMode,
    delivery_mode: deliveryMode
  });
} else if (options.mode === "drag") {
  operations.push({
    kind: "drag",
    from: point(options["drag-from"] || "300,600"),
    to: point(options["drag-to"] || "950,750"),
    event_source_mode: eventSourceMode,
    delivery_mode: deliveryMode
  });
} else if (options.mode !== "capture") {
  operations.push(
    {
      kind: "click",
      point: point(options["click-point"] || "200,140"),
      button: "left",
      event_source_mode: eventSourceMode,
      delivery_mode: deliveryMode
    },
    {
      kind: "click",
      point: point(options["right-click-point"] || "760,440"),
      button: "right",
      event_source_mode: eventSourceMode,
      delivery_mode: deliveryMode
    },
    {
      kind: "drag",
      from: point(options["drag-from"] || "420,520"),
      to: point(options["drag-to"] || "860,680"),
      event_source_mode: eventSourceMode,
      delivery_mode: deliveryMode
    }
  );
}
const item = {
  id: options["item-id"] || `${options.mode}-item-001`,
  kind: `lab-${options.mode}`,
  operations
};
if (options.mode === "repair") {
  if (!options.supersedes) throw new Error("--supersedes required for repair");
  item.supersedes_item_id = options.supersedes;
  item.repair_lineage = (options.lineage || options.supersedes).split(",");
}
const manifest = finalizeQueueManifest({
  schema_version: 1,
  generation_id: options.generation,
  target_kind: "lab",
  target_title_contains: "Explorer Adapter Lab Target",
  allowed_operations: [...new Set(operations.map(({ kind }) => kind))],
  artifact_root: path.resolve(options["artifact-root"]),
  items: [item]
});
const data = `${JSON.stringify(manifest, null, 2)}\n`;
const destination = path.resolve(options.output);
fs.mkdirSync(path.dirname(destination), { recursive: true, mode: 0o700 });
fs.writeFileSync(destination, data, { flag: "wx", mode: 0o444 });
fs.chmodSync(destination, 0o444);
process.stdout.write(`${JSON.stringify({ path: destination, sha256: sha256(data), manifest })}\n`);

function point(value) {
  const [x, y] = value.split(",").map(Number);
  if (!Number.isFinite(x) || !Number.isFinite(y)) throw new Error(`invalid point ${value}`);
  return { x, y };
}

function parseArguments(arguments_) {
  const result = {};
  for (let index = 0; index < arguments_.length; index += 2) {
    const key = arguments_[index];
    if (!key?.startsWith("--") || !arguments_[index + 1]) throw new Error(`invalid argument ${key}`);
    result[key.slice(2)] = arguments_[index + 1];
  }
  return result;
}
