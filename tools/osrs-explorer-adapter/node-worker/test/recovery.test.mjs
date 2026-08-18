import assert from "node:assert/strict";
import test from "node:test";

import {
  executeInlineSemanticRecovery,
  executeRecoveryClaim,
  validateRecoveryItem
} from "../src/recovery.mjs";

const states = [
  ["TRY_AGAIN", "STEAM_SIGN_IN", clickOperation("left")],
  ["STEAM_SIGN_IN", "CONNECTING", clickOperation("left")],
  ["CONNECTING", "CLICK_TO_PLAY", null],
  ["CLICK_TO_PLAY", "GAMEPLAY_NO_MAP", clickOperation("left")],
  ["GAMEPLAY_NO_MAP", "MAP_READY", openWorldMapOperation()],
  ["CONTEXT_MENU_OPEN_MAP", "MAP_READY", clickOperation("left")],
  ["SURFACE_SELECTOR_OPEN", "MAP_READY", clickOperation("left")]
];

test("full reviewed recovery transition replay uses only ordered sealed operations", async () => {
  const performed = [];
  for (const [beforeState, afterState, operation] of states) {
    const claim = recoveryClaim(beforeState, operation);
    const captures = [
      capture(`${beforeState}-before`, "a", {}, heightForState(beforeState)),
      capture(`${beforeState}-after`, "b", {}, heightForState(afterState))
    ];
    const classifications = new Map([
      [`${beforeState}-before.png`, classification(beforeState)],
      [`${beforeState}-after.png`, classification(afterState)]
    ]);
    const result = await executeRecoveryClaim({
      claim,
      deadline: Date.now() + 10_000,
      captureFrame: async () => captures.shift(),
      performAction: async (sealedOperation, boundCapture) => {
        performed.push({ beforeState, sealedOperation, capture: boundCapture.captureIdentifier });
        return { path: `${beforeState}-input.json`, sha256: "c".repeat(64) };
      },
      classify: async (pngPath) => classifications.get(pngPath),
      localizeSelectorToggle: async () => ({
        exactly_one_target: true,
        source_frame_geometry: { width: 768, height: 839 },
        source_click_point: { x: 100, y: 100 },
      }),
      wait: async () => {}
    });
    assert.equal(result.finalCapture.captureIdentifier, `${beforeState}-after`);
  }
  assert.deepEqual(performed.map(({ beforeState, sealedOperation }) => [
    beforeState,
    sealedOperation.kind,
    sealedOperation.button,
    sealedOperation.point
  ]), [
    ["TRY_AGAIN", "click", "left", { x: 100, y: 100 }],
    ["STEAM_SIGN_IN", "click", "left", { x: 100, y: 100 }],
    ["CLICK_TO_PLAY", "click", "left", { x: 100, y: 100 }],
    ["GAMEPLAY_NO_MAP", "open_world_map", undefined, undefined],
    ["CONTEXT_MENU_OPEN_MAP", "click", "left", { x: 100, y: 100 }],
    ["SURFACE_SELECTOR_OPEN", "click", "left", { x: 100, y: 100 }]
  ]);
});

test("one semantic item recovers an idle session through the bounded reviewed chain", async () => {
  const initial = capture("inline-try-again", "1", {}, heightForState("TRY_AGAIN"));
  const captures = [
    capture("inline-steam", "2", {}, heightForState("STEAM_SIGN_IN")),
    capture("inline-click", "3", {}, heightForState("CLICK_TO_PLAY")),
    capture("inline-gameplay", "4", {}, heightForState("GAMEPLAY_NO_MAP")),
    capture("inline-map", "5", {}, heightForState("MAP_READY")),
  ];
  const classifications = new Map([
    [initial.pngPath, classification("TRY_AGAIN")],
    [captures[0].pngPath, classification("STEAM_SIGN_IN")],
    [captures[1].pngPath, classification("CLICK_TO_PLAY")],
    [captures[2].pngPath, classification("GAMEPLAY_NO_MAP")],
    [captures[3].pngPath, classification("MAP_READY")],
  ]);
  const performed = [];
  const result = await executeInlineSemanticRecovery({
    initialCapture: initial,
    deadline: Date.now() + 10_000,
    captureFrame: async () => captures.shift(),
    performAction: async (operation, boundCapture) => {
      performed.push({ operation, capture: boundCapture.captureIdentifier });
      return { path: `/fixture/${boundCapture.captureIdentifier}.json`, sha256: "f".repeat(64) };
    },
    classify: async (pngPath) => classifications.get(pngPath),
    wait: async () => {},
  });

  assert.equal(result.capture.captureIdentifier, "inline-map");
  assert.deepEqual(result.history.map(({ state, observed_state }) => [state, observed_state]), [
    ["TRY_AGAIN", "STEAM_SIGN_IN"],
    ["STEAM_SIGN_IN", "CLICK_TO_PLAY"],
    ["CLICK_TO_PLAY", "GAMEPLAY_NO_MAP"],
    ["GAMEPLAY_NO_MAP", "MAP_READY"],
  ]);
  assert.deepEqual(performed.map(({ operation }) => operation.semantic_role), [
    "recovery_try_again",
    "recovery_steam_sign_in",
    "recovery_click_to_play",
    "recovery_open_world_map",
  ]);
  assert.deepEqual(result.actions.map(({ role }) => role), performed.map(({ operation }) =>
    operation.semantic_role
  ));
});

test("semantic recovery may enter at a downstream recognized state without fabricating earlier input", async () => {
  const initial = capture("inline-gameplay-direct", "6", {}, heightForState("GAMEPLAY_NO_MAP"));
  const ready = capture("inline-map-direct", "7", {}, heightForState("MAP_READY"));
  const performed = [];
  const result = await executeInlineSemanticRecovery({
    initialCapture: initial,
    deadline: Date.now() + 10_000,
    captureFrame: async () => ready,
    performAction: async (operation) => {
      performed.push(operation);
      return { path: "/fixture/direct-open.json", sha256: "e".repeat(64) };
    },
    classify: async (pngPath) => pngPath === initial.pngPath
      ? classification("GAMEPLAY_NO_MAP")
      : classification("MAP_READY"),
    wait: async () => {},
  });
  assert.equal(result.history.length, 1);
  assert.equal(result.history[0].state, "GAMEPLAY_NO_MAP");
  assert.deepEqual(performed.map(({ semantic_role }) => semantic_role), ["recovery_open_world_map"]);
});

test("Steam sign-in recovery recognizes ordinary gameplay before opening the world map", async () => {
  const initial = capture("inline-steam-direct", "8", {}, heightForState("STEAM_SIGN_IN"));
  const gameplay = capture("inline-ordinary-gameplay", "9", {}, heightForState("GAMEPLAY_NO_MAP"));
  const ready = capture("inline-map-after-gameplay", "a", {}, heightForState("MAP_READY"));
  const captures = [gameplay, ready];
  const performed = [];
  const result = await executeInlineSemanticRecovery({
    initialCapture: initial,
    deadline: Date.now() + 10_000,
    captureFrame: async () => captures.shift(),
    performAction: async (operation, boundCapture) => {
      performed.push({ operation, capture: boundCapture.captureIdentifier });
      return { path: `/fixture/${boundCapture.captureIdentifier}.json`, sha256: "d".repeat(64) };
    },
    classify: async (pngPath) => {
      if (pngPath === initial.pngPath) return classification("STEAM_SIGN_IN");
      if (pngPath === ready.pngPath) return classification("MAP_READY");
      return {
        connection: "UNKNOWN",
        map_shell: "UNKNOWN",
        overlay: "UNKNOWN",
        map_content: "NONBLACK_CONTENT",
        committable: false,
        recovery_state: null,
        metrics: {
          geometry: true,
          close_orange_fraction: 0,
          controls_stddev: 22,
          hud_stddev: 48,
        },
        normalization: { family: "GAMEPLAY_MAP_768x839" },
      };
    },
    wait: async () => {},
  });

  assert.equal(result.capture.captureIdentifier, "inline-map-after-gameplay");
  assert.deepEqual(result.history.map(({ state, observed_state }) => [state, observed_state]), [
    ["STEAM_SIGN_IN", "GAMEPLAY_NO_MAP"],
    ["GAMEPLAY_NO_MAP", "MAP_READY"],
  ]);
  assert.deepEqual(performed.map(({ operation }) => operation.semantic_role), [
    "recovery_steam_sign_in",
    "recovery_open_world_map",
  ]);
});

test("Steam account transition is never promoted to gameplay by the HUD fallback", async () => {
  const initial = capture("inline-steam-transition", "b", {}, heightForState("STEAM_SIGN_IN"));
  const checking = capture("inline-checking-steam", "c", {}, heightForState("STEAM_SIGN_IN"));
  let actions = 0;
  await assert.rejects(
    executeInlineSemanticRecovery({
      initialCapture: initial,
      deadline: Date.now() + 10_000,
      captureFrame: async () => checking,
      performAction: async () => {
        actions += 1;
        return { path: "/fixture/steam-transition.json", sha256: "c".repeat(64) };
      },
      classify: async (pngPath) => pngPath === initial.pngPath
        ? classification("STEAM_SIGN_IN")
        : {
            connection: "UNKNOWN",
            map_shell: "UNKNOWN",
            overlay: "SURFACE_SELECTOR",
            map_content: "NONBLACK_CONTENT",
            committable: false,
            recovery_state: null,
            metrics: {
              geometry: true,
              close_orange_fraction: 0,
              controls_stddev: 41,
              hud_stddev: 17.43,
            },
            normalization: { family: "GAMEPLAY_MAP_768x839" },
          },
      postCaptureAttempts: 1,
      wait: async () => {},
    }),
    /PRECISELY_BLOCKED_RECOVERY_TIMEOUT:STEAM_SIGN_IN/
  );
  assert.equal(actions, 1);
});

test("world map opener rejects parameterization and legacy click fallback", () => {
  const valid = recoveryClaim("GAMEPLAY_NO_MAP", openWorldMapOperation()).item;
  assert.equal(validateRecoveryItem(valid).operation.kind, "open_world_map");
  for (const operation of [
    { ...openWorldMapOperation(), key_code: 4 },
    { ...openWorldMapOperation(), modifiers: ["control"] },
    { ...openWorldMapOperation(), delivery_mode: "background_pid" },
    clickOperation("left")
  ]) {
    assert.throws(
      () => validateRecoveryItem(recoveryClaim("GAMEPLAY_NO_MAP", operation).item),
      /RECOVERY_ITEM_(OPERATION_SEQUENCE_INVALID|WORLD_MAP_SHORTCUT_POLICY_INVALID)/
    );
  }
});

test("recovery item rejects extra, reordered, and policy-mismatched operations", () => {
  const valid = recoveryClaim("TRY_AGAIN", clickOperation("left")).item;
  assert.equal(validateRecoveryItem(valid).state, "TRY_AGAIN");
  assert.throws(
    () => validateRecoveryItem({ ...valid, operations: [...valid.operations, clickOperation("left")] }),
    /RECOVERY_ITEM_OPERATION_SEQUENCE_INVALID/
  );
  assert.throws(
    () => validateRecoveryItem({ ...valid, operations: [valid.operations[1], valid.operations[0]] }),
    /RECOVERY_ITEM_OPERATION_SEQUENCE_INVALID/
  );
  assert.throws(
    () => validateRecoveryItem({
      ...valid,
      operations: [valid.operations[0], { ...valid.operations[1], delivery_mode: "background_pid" }]
    }),
    /RECOVERY_ITEM_CLICK_POLICY_INVALID/
  );
});

test("mismatched sealed point and normal map state stop before input", async () => {
  let actions = 0;
  const mismatched = recoveryClaim("TRY_AGAIN", {
    ...clickOperation("left"),
    point: { x: 101, y: 100 }
  });
  await assert.rejects(
    executeRecoveryClaim({
      claim: mismatched,
      deadline: Date.now() + 10_000,
      captureFrame: async () => capture("before", "a"),
      performAction: async () => { actions += 1; },
      classify: async () => classification("TRY_AGAIN"),
      wait: async () => {}
    }),
    /RECOVERY_OPERATION_POINT_MISMATCH/
  );
  const mapClaim = recoveryClaim("TRY_AGAIN", clickOperation("left"));
  await assert.rejects(
    executeRecoveryClaim({
      claim: mapClaim,
      deadline: Date.now() + 10_000,
      captureFrame: async () => capture("map", "m"),
      performAction: async () => { actions += 1; },
      classify: async () => classification("MAP_READY"),
      wait: async () => {}
    }),
    /RECOVERY_STATE_OPERATION_MISMATCH:TRY_AGAIN->MAP_READY/
  );
  assert.equal(actions, 0);
});

test("interruption, context loss, stale frames, and unknown transitions emit zero late input", async () => {
  const claim = recoveryClaim("TRY_AGAIN", clickOperation("left"));
  let stoppedActions = 0;
  await assert.rejects(
    executeRecoveryClaim({
      claim,
      deadline: Date.now() + 10_000,
      captureFrame: async () => capture("before", "a"),
      performAction: async () => { stoppedActions += 1; },
      classify: async () => classification("TRY_AGAIN"),
      isStopping: () => true,
      wait: async () => {}
    }),
    /WORKER_STOPPING/
  );
  assert.equal(stoppedActions, 0);

  for (const failure of ["context", "stale", "unknown"]) {
    let actions = 0;
    const captures = failure === "context"
      ? [capture("before", "a"), capture("after", "b", { windowIdentifier: 99 })]
      : failure === "stale"
        ? [capture("before", "a"), capture("after", "a"), capture("after-2", "a")]
        : [capture("before", "a"), capture("after", "b")];
    await assert.rejects(
      executeRecoveryClaim({
        claim,
        deadline: Date.now() + 10_000,
        captureFrame: async () => captures.shift(),
        performAction: async () => { actions += 1; },
        classify: async (pngPath) => pngPath === "before.png"
          ? classification("TRY_AGAIN")
          : classification("UNKNOWN"),
        wait: async () => {},
        postCaptureAttempts: failure === "stale" ? 2 : 1
      }),
      failure === "context"
        ? /RECOVERY_TARGET_OR_CONTEXT_LOST/
        : /PRECISELY_BLOCKED_RECOVERY_TIMEOUT/
    );
    assert.equal(actions, 1);
  }
});

test("a failed recovery claim is not retried inside the item executor", async () => {
  const claim = recoveryClaim("TRY_AGAIN", clickOperation("left"));
  let actions = 0;
  await assert.rejects(
    executeRecoveryClaim({
      claim,
      deadline: Date.now() + 10_000,
      captureFrame: async () => capture("before", "a"),
      performAction: async () => {
        actions += 1;
        throw new Error("HOST_ACTION_FAILED");
      },
      classify: async () => classification("TRY_AGAIN"),
      wait: async () => {}
    }),
    /HOST_ACTION_FAILED/
  );
  assert.equal(actions, 1);
});

test("a changed transitional frame never causes a second click", async () => {
  const claim = recoveryClaim("TRY_AGAIN", clickOperation("left"));
  const captures = [
    capture("before", "a"),
    capture("transition", "b"),
    capture("downstream", "c")
  ];
  let actions = 0;
  const result = await executeRecoveryClaim({
    claim,
    deadline: Date.now() + 10_000,
    captureFrame: async () => captures.shift(),
    performAction: async () => {
      actions += 1;
      return { path: "input.json", sha256: "d".repeat(64) };
    },
    classify: async (pngPath) => pngPath === "before.png"
      ? classification("TRY_AGAIN")
      : pngPath === "downstream.png"
        ? classification("STEAM_SIGN_IN")
        : classification("UNKNOWN"),
    wait: async () => {}
  });
  assert.equal(actions, 1);
  assert.equal(result.finalCapture.captureIdentifier, "downstream");
});

test("transient ambiguous recovery localization is observed without more input", async () => {
  const claim = recoveryClaim("STEAM_SIGN_IN", clickOperation("left"));
  const captures = [
    capture("before", "a"),
    capture("partial-click-to-play", "b"),
    capture("downstream", "c", {}, 839)
  ];
  let actions = 0;
  const result = await executeRecoveryClaim({
    claim,
    deadline: Date.now() + 10_000,
    captureFrame: async () => captures.shift(),
    performAction: async () => {
      actions += 1;
      return { path: "input.json", sha256: "d".repeat(64) };
    },
    classify: async (pngPath) => {
      if (pngPath === "before.png") return classification("STEAM_SIGN_IN");
      if (pngPath === "partial-click-to-play.png") {
        throw new Error("PRECISELY_BLOCKED_NO_CLICK:CLICK_TO_PLAY:AMBIGUOUS_LOCALIZATION");
      }
      return classification("CLICK_TO_PLAY");
    },
    wait: async () => {}
  });
  assert.equal(actions, 1);
  assert.equal(result.finalCapture.captureIdentifier, "downstream");
  assert.equal(result.evidence[2].kind, "recovery_transition_unclassified");
  assert.equal(
    result.evidence[2].classification_error,
    "PRECISELY_BLOCKED_NO_CLICK:CLICK_TO_PLAY:AMBIGUOUS_LOCALIZATION"
  );
});

test("transient recovery resize frames are observed without more input", async () => {
  for (const classificationError of [
    "UNSUPPORTED_OSRS_CAPTURE_ASPECT_RATIO",
    "AMBIGUOUS_OSRS_CAPTURE_ASPECT_RATIO",
  ]) {
    const claim = recoveryClaim("STEAM_SIGN_IN", clickOperation("left"));
    const captures = [
      capture("before", "a"),
      capture("resizing", "b", {}, 820),
      capture("downstream", "c", {}, 839),
    ];
    let actions = 0;
    const result = await executeRecoveryClaim({
      claim,
      deadline: Date.now() + 10_000,
      captureFrame: async () => captures.shift(),
      performAction: async () => {
        actions += 1;
        return { path: "input.json", sha256: "d".repeat(64) };
      },
      classify: async (pngPath) => {
        if (pngPath === "before.png") return classification("STEAM_SIGN_IN");
        if (pngPath === "resizing.png") throw new Error(classificationError);
        return classification("CLICK_TO_PLAY");
      },
      wait: async () => {},
    });
    assert.equal(actions, 1);
    assert.equal(result.finalCapture.captureIdentifier, "downstream");
    assert.equal(result.evidence[2].kind, "recovery_transition_unclassified");
    assert.equal(result.evidence[2].classification_error, classificationError);
  }
});

test("transient ambiguous recovery preflight stabilizes before one input", async () => {
  const claim = recoveryClaim("CLICK_TO_PLAY", clickOperation("left"));
  const captures = [
    capture("loading", "a", {}, 839),
    capture("stable", "b", {}, 839),
    capture("downstream", "c")
  ];
  let actions = 0;
  const result = await executeRecoveryClaim({
    claim,
    deadline: Date.now() + 10_000,
    captureFrame: async () => captures.shift(),
    performAction: async () => {
      actions += 1;
      return { path: "input.json", sha256: "d".repeat(64) };
    },
    classify: async (pngPath) => {
      if (pngPath === "loading.png") {
        throw new Error("PRECISELY_BLOCKED_NO_CLICK:CLICK_TO_PLAY:AMBIGUOUS_LOCALIZATION");
      }
      return pngPath === "stable.png"
        ? classification("CLICK_TO_PLAY")
        : classification("GAMEPLAY_NO_MAP");
    },
    wait: async () => {}
  });
  assert.equal(actions, 1);
  assert.equal(result.finalCapture.captureIdentifier, "downstream");
  assert.equal(result.evidence[0].kind, "recovery_preflight_unclassified");
  assert.equal(result.evidence[1].kind, "recovery_preflight_capture");
});

test("ambiguous recovery preflight exhaustion emits zero input", async () => {
  const claim = recoveryClaim("CLICK_TO_PLAY", clickOperation("left"));
  let captures = 0;
  let actions = 0;
  await assert.rejects(
    executeRecoveryClaim({
      claim,
      deadline: Date.now() + 10_000,
      captureFrame: async () => capture(`loading-${++captures}`, String(captures), {}, 839),
      performAction: async () => {
        actions += 1;
        return { path: "input.json", sha256: "d".repeat(64) };
      },
      classify: async () => {
        throw new Error("PRECISELY_BLOCKED_NO_CLICK:CLICK_TO_PLAY:AMBIGUOUS_LOCALIZATION");
      },
      wait: async () => {},
      preflightCaptureAttempts: 2,
    }),
    /PRECISELY_BLOCKED_RECOVERY_PREFLIGHT_TIMEOUT:CLICK_TO_PLAY/
  );
  assert.equal(captures, 2);
  assert.equal(actions, 0);
});

function recoveryClaim(state, operation) {
  return {
    generation_id: `generation-${state}`,
    selector: { bundleIdentifier: "com.jagex.osclient" },
    item: {
      id: `item-${state}`,
      kind: `osrs-recovery-v1-${state}`,
      operations: operation ? [{ kind: "capture" }, operation] : [{ kind: "capture" }]
    }
  };
}

function clickOperation(button) {
  return {
    kind: "click",
    point: { x: 100, y: 100 },
    button,
    event_source_mode: "combined_session_state",
    delivery_mode: "foreground_global"
  };
}

function openWorldMapOperation() {
  return {
    kind: "open_world_map",
    event_source_mode: "combined_session_state",
    delivery_mode: "foreground_global"
  };
}

function capture(identifier, digest, targetOverrides = {}, pixelHeight = 861) {
  return {
    captureIdentifier: identifier,
    pngPath: `${identifier}.png`,
    pngSHA256: digest.repeat(64),
    pixelWidth: 768,
    pixelHeight,
    target: {
      bundleIdentifier: "com.jagex.osclient",
      processIdentifier: 7,
      windowIdentifier: 8,
      frame: { x: 10, y: 20, width: 768, height: pixelHeight },
      ...targetOverrides
    }
  };
}

function classification(state) {
  if (state === "MAP_READY") {
    return {
      connection: "CONNECTED",
      map_shell: "FLOATING_MAP_OPEN",
      overlay: "NONE",
      map_content: "NONBLACK_CONTENT",
      committable: true,
      recovery_state: null,
      normalization: { family: "GAMEPLAY_MAP_768x839" }
    };
  }
  if (state === "UNKNOWN") {
    return {
      connection: "UNKNOWN",
      map_shell: "UNKNOWN",
      overlay: "UNKNOWN",
      map_content: "UNKNOWN",
      committable: false,
      recovery_state: null,
      normalization: { family: "RECOVERY_768x861" }
    };
  }
  if (state === "SURFACE_SELECTOR_OPEN") {
    return {
      connection: "CONNECTED",
      map_shell: "FLOATING_MAP_OPEN",
      overlay: "SURFACE_SELECTOR",
      map_content: "NONBLACK_CONTENT",
      committable: false,
      recovery_state: null,
      recovery_localization: null,
      normalization: { family: "GAMEPLAY_MAP_768x839" }
    };
  }
  return {
    connection: ["GAMEPLAY_NO_MAP", "CONTEXT_MENU_OPEN_MAP"].includes(state)
      ? "CONNECTED"
      : state,
    map_shell: state === "CONTEXT_MENU_OPEN_MAP" ? "CLOSED" : "UNKNOWN",
    overlay: state === "CONTEXT_MENU_OPEN_MAP" ? "CONTEXT_MENU_OPEN_MAP" : "UNKNOWN",
    map_content: "NONBLACK_CONTENT",
    committable: false,
    recovery_state: state,
    recovery_localization: ["CONNECTING", "GAMEPLAY_NO_MAP"].includes(state) ? null : {
      exactly_one_target: true,
      source_frame_geometry: { width: 768, height: heightForState(state) },
      source_click_point: { x: 100, y: 100 }
    },
    normalization: {
      family: ["TRY_AGAIN", "STEAM_SIGN_IN", "CONNECTING"].includes(state)
        ? "RECOVERY_768x861"
        : "GAMEPLAY_MAP_768x839"
    }
  };
}

function heightForState(state) {
  return ["TRY_AGAIN", "STEAM_SIGN_IN", "CONNECTING"].includes(state) ? 861 : 839;
}
