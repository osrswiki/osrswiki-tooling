import assert from "node:assert/strict";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

test("worker exits before RPC when parent identity is lost", async () => {
  const child = spawn(process.execPath, [path.join(root, "src", "worker.mjs")], {
    env: {
      ...process.env,
      OSRS_ADAPTER_SOCKET: "/tmp/does-not-exist.sock",
      OSRS_ADAPTER_WORKER_CAPABILITY: "not-used",
      OSRS_ADAPTER_PARENT_PID: "1"
    },
    stdio: "ignore"
  });
  const status = await new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error("WORKER_DID_NOT_EXIT")), 2_000);
    child.once("error", reject);
    child.once("exit", (code, signal) => {
      clearTimeout(timeout);
      resolve({ code, signal });
    });
  });
  assert.deepEqual(status, { code: 0, signal: null });
});
