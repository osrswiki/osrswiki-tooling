import assert from "node:assert/strict";
import test from "node:test";

import { rpcTimeoutMilliseconds } from "../src/rpc.mjs";

test("completion RPC keeps the item deadline margin while other calls stay strict", () => {
  assert.equal(rpcTimeoutMilliseconds("worker.complete"), 60_000);
  assert.equal(rpcTimeoutMilliseconds("worker.claim"), 15_000);
  assert.equal(rpcTimeoutMilliseconds("capture"), 15_000);
  assert.equal(rpcTimeoutMilliseconds("click"), 15_000);
  assert.equal(rpcTimeoutMilliseconds("drag"), 15_000);
});
