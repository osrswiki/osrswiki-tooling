import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";

const workerRoot = path.resolve(import.meta.dirname, "..");
const generator = path.join(workerRoot, "scripts", "create-semantic-pilot-queue.mjs");

test("semantic pilot queue run id creates fresh stable item identities", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "semantic-pilot-queue-"));
  const outputPath = path.join(root, "queue.json");
  const execution = spawnSync(process.execPath, [
    generator,
    "terminal-realm-performance",
    "terminal-generation-two",
    path.join(root, "artifacts"),
    outputPath,
    "timing-v2",
  ], { cwd: workerRoot, encoding: "utf8" });

  assert.equal(execution.status, 0, execution.stderr);
  const queue = JSON.parse(fs.readFileSync(outputPath, "utf8"));
  assert.equal(queue.items.length, 20);
  assert.equal(queue.items[0].id, "terminal-realm-performance-timing-v2-001");
  assert.equal(queue.items[19].id, "terminal-realm-performance-timing-v2-020");
  assert.equal(new Set(queue.items.map((item) => item.item_sha256)).size, 20);
  assert.equal(fs.statSync(outputPath).mode & 0o777, 0o444);
});

test("semantic pilot queue keeps legacy item ids when no run id is supplied", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "semantic-pilot-queue-legacy-"));
  const outputPath = path.join(root, "queue.json");
  const execution = spawnSync(process.execPath, [
    generator,
    "canonical-canary",
    "canonical-generation",
    path.join(root, "artifacts"),
    outputPath,
  ], { cwd: workerRoot, encoding: "utf8" });

  assert.equal(execution.status, 0, execution.stderr);
  const queue = JSON.parse(fs.readFileSync(outputPath, "utf8"));
  assert.equal(queue.items[0].id, "canonical-canary-001");
});
