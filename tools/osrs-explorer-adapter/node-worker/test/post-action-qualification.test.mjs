import assert from "node:assert/strict";
import test from "node:test";

import { captureAuthorizedOSRSPostAction } from "../src/post-action-qualification.mjs";

test("post-action qualification retains rejected frames before accepting a fresh map frame", async () => {
  const evidence = [];
  const waits = [];
  let captures = 0;
  const accepted = await captureAuthorizedOSRSPostAction({
    captureFrame: async () => ({ pngPath: `/tmp/frame-${++captures}.png` }),
    classify: async (path) => {
      if (!path.endsWith("3.png")) throw new Error("TRANSIENT_FRAME");
      return { authorized: true, path };
    },
    recordEvidence: (entry) => evidence.push(entry),
    wait: async (milliseconds) => waits.push(milliseconds)
  });

  assert.equal(accepted.pngPath, "/tmp/frame-3.png");
  assert.deepEqual(waits, [250, 250]);
  assert.deepEqual(
    evidence.map(({ kind, attempt }) => [kind, attempt]),
    [
      ["post_capture", 1],
      ["post_action_osrs_screen_rejection", 1],
      ["post_capture", 2],
      ["post_action_osrs_screen_rejection", 2],
      ["post_capture", 3],
      ["post_action_osrs_screen_qualification", 3]
    ]
  );
});

test("post-action qualification fails closed after the bounded attempt count", async () => {
  const evidence = [];
  let captures = 0;
  await assert.rejects(
    captureAuthorizedOSRSPostAction({
      captureFrame: async () => ({ pngPath: `/tmp/frame-${++captures}.png` }),
      classify: async () => { throw new Error("UNKNOWN_SCREEN"); },
      recordEvidence: (entry) => evidence.push(entry),
      attempts: 3,
      wait: async () => {}
    }),
    /POST_ACTION_OSRS_SCREEN_UNQUALIFIED_AFTER_3:UNKNOWN_SCREEN/
  );
  assert.equal(captures, 3);
  assert.equal(evidence.filter(({ kind }) => kind === "post_capture").length, 3);
  assert.equal(evidence.filter(({ kind }) => kind.endsWith("rejection")).length, 3);
  assert.equal(evidence.filter(({ kind }) => kind.endsWith("qualification")).length, 0);
});
