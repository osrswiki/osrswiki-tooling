import assert from "node:assert/strict";
import test from "node:test";

import { reportFailedClaim } from "../src/failure-reporting.mjs";

const claim = {
  generation_id: "generation-001",
  item: { id: "item-001" }
};

test("failure evidence write failure still reports failure to the host", async () => {
  let completionCalls = 0;
  await assert.rejects(
    reportFailedClaim({
      claim,
      error: new Error("ITEM_FAILED"),
      writeFailureEvidence: () => {
        throw new Error("EVIDENCE_WRITE_FAILED");
      },
      completeFailure: async () => {
        completionCalls += 1;
      }
    }),
    /EVIDENCE_WRITE_FAILED/
  );
  assert.equal(completionCalls, 1);
});

test("host completion failure remains visible after evidence is written", async () => {
  let evidenceWrites = 0;
  await assert.rejects(
    reportFailedClaim({
      claim,
      error: new Error("ITEM_FAILED"),
      writeFailureEvidence: () => {
        evidenceWrites += 1;
      },
      completeFailure: async () => {
        throw new Error("HOST_COMPLETION_FAILED");
      }
    }),
    /HOST_COMPLETION_FAILED/
  );
  assert.equal(evidenceWrites, 1);
});
