import assert from "node:assert/strict";
import test from "node:test";

import { requireLabVisualAcknowledgement } from "../src/lab-qualification.mjs";

test("lab acknowledgement accepts a changed target frame", () => {
  assert.doesNotThrow(() => requireLabVisualAcknowledgement(
    { pngSHA256: "before" },
    { pngSHA256: "after" },
    { kind: "drag", event_source_mode: "combined_session_state" }
  ));
});

test("lab acknowledgement rejects an unchanged target frame with mode evidence", () => {
  assert.throws(
    () => requireLabVisualAcknowledgement(
      { pngSHA256: "same" },
      { pngSHA256: "same" },
      { kind: "click", event_source_mode: "hid_system_state" }
    ),
    /LAB_VISUAL_ACK_MISSING:click:hid_system_state/
  );
});
