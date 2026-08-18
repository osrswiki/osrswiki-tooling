import {
  classifyCapture,
  refineSemanticPostCloseClassification,
  isAuthorizedMapClassification,
  localizeOpenSemanticSurfaceSelectorToggle,
} from "./perception.mjs";

export const recoveryItemKindPrefix = "osrs-recovery-v1-";

const recoverySpecs = Object.freeze({
  TRY_AGAIN: Object.freeze({ kind: "click", button: "left", downstream: [
    "STEAM_SIGN_IN", "CONNECTING", "CLICK_TO_PLAY", "GAMEPLAY_NO_MAP", "MAP_READY"
  ] }),
  STEAM_SIGN_IN: Object.freeze({ kind: "click", button: "left", downstream: [
    "CONNECTING", "CLICK_TO_PLAY", "GAMEPLAY_NO_MAP", "MAP_READY"
  ] }),
  CONNECTING: Object.freeze({ kind: null, button: null, downstream: [
    "CLICK_TO_PLAY", "GAMEPLAY_NO_MAP", "MAP_READY"
  ] }),
  CLICK_TO_PLAY: Object.freeze({ kind: "click", button: "left", downstream: [
    "GAMEPLAY_NO_MAP", "MAP_READY"
  ] }),
  GAMEPLAY_NO_MAP: Object.freeze({ kind: "open_world_map", button: null, downstream: [
    "MAP_READY"
  ] }),
  CONTEXT_MENU_OPEN_MAP: Object.freeze({ kind: "click", button: "left", downstream: [
    "MAP_READY"
  ] }),
  SURFACE_SELECTOR_OPEN: Object.freeze({ kind: "click", button: "left", downstream: [
    "MAP_READY"
  ] })
});

export function isRecoveryItem(item) {
  return typeof item?.kind === "string" && item.kind.startsWith(recoveryItemKindPrefix);
}

export function validateRecoveryItem(item) {
  if (!isRecoveryItem(item)) throw new Error("RECOVERY_ITEM_KIND_REQUIRED");
  const state = item.kind.slice(recoveryItemKindPrefix.length);
  const spec = recoverySpecs[state];
  if (!spec) throw new Error(`RECOVERY_ITEM_STATE_FORBIDDEN:${state || "MISSING"}`);
  const operations = item.operations;
  const expectedKinds = spec.kind ? ["capture", spec.kind] : ["capture"];
  if (
    !Array.isArray(operations)
    || operations.length !== expectedKinds.length
    || operations.some((operation, index) => operation.kind !== expectedKinds[index])
  ) {
    throw new Error(`RECOVERY_ITEM_OPERATION_SEQUENCE_INVALID:${state}`);
  }
  if (spec.kind === "click") {
    const operation = operations[1];
    if (
      operation.button !== spec.button
      || operation.event_source_mode !== "combined_session_state"
      || operation.delivery_mode !== "foreground_global"
      || !validPoint(operation.point)
    ) {
      throw new Error(`RECOVERY_ITEM_CLICK_POLICY_INVALID:${state}`);
    }
  } else if (spec.kind === "open_world_map") {
    const operation = operations[1];
    if (
      Object.keys(operation).some((key) => ![
        "kind", "event_source_mode", "delivery_mode"
      ].includes(key))
      || operation.event_source_mode !== "combined_session_state"
      || operation.delivery_mode !== "foreground_global"
    ) {
      throw new Error(`RECOVERY_ITEM_WORLD_MAP_SHORTCUT_POLICY_INVALID:${state}`);
    }
  }
  return { state, spec, operation: operations[1] || null };
}

export async function executeRecoveryClaim({
  claim,
  deadline,
  captureFrame,
  performAction,
  classify = classifyCapture,
  localizeSelectorToggle = localizeOpenSemanticSurfaceSelectorToggle,
  isStopping = () => false,
  wait = delay,
  preflightCaptureAttempts = 20,
  preflightCaptureIntervalMilliseconds = 250,
  postCaptureAttempts = 120,
  postCaptureIntervalMilliseconds = 500
}) {
  if (claim.selector?.bundleIdentifier !== "com.jagex.osclient") {
    throw new Error("RECOVERY_TARGET_FORBIDDEN");
  }
  const { state, spec, operation } = validateRecoveryItem(claim.item);
  const evidence = [];
  try {
    assertActive(deadline, isStopping);
    const { capture: before, classification: beforeClassification } = await captureRecoveryPreflight({
      state,
      deadline,
      captureFrame,
      classify,
      isStopping,
      wait,
      preflightCaptureAttempts,
      preflightCaptureIntervalMilliseconds,
      evidence,
    });
    requireExactRecoveryState(beforeClassification, state);

    if (!operation) {
      const transition = await captureRecoveryTransition({
        before,
        state,
        spec,
        deadline,
        captureFrame,
        classify,
        isStopping,
        wait,
        postCaptureAttempts,
        postCaptureIntervalMilliseconds,
        evidence
      });
      return { evidence, finalCapture: transition.capture };
    }

    const localization = state === "SURFACE_SELECTOR_OPEN"
      ? await localizeSelectorToggle(before.pngPath)
      : beforeClassification.recovery_localization;
    if (operation.kind === "click") {
      if (!localization?.source_click_point || localization.exactly_one_target !== true) {
        throw new Error(`PRECISELY_BLOCKED_NO_CLICK:${state}:LOCALIZATION_REQUIRED`);
      }
      if (
        before.pixelWidth !== localization.source_frame_geometry.width
        || before.pixelHeight !== localization.source_frame_geometry.height
      ) {
        throw new Error(`RECOVERY_CAPTURE_GEOMETRY_BINDING_MISMATCH:${state}`);
      }
      if (!samePoint(operation.point, localization.source_click_point)) {
        throw new Error(`RECOVERY_OPERATION_POINT_MISMATCH:${state}`);
      }
    }

    assertActive(deadline, isStopping);
    const actionEvidence = await performAction(operation, before);
    evidence.push({
      kind: operation.kind === "open_world_map" ? "recovery_open_world_map" : "recovery_click",
      state,
      operation,
      localization,
      input_evidence: actionEvidence
    });
    assertActive(deadline, isStopping);
    const transition = await captureRecoveryTransition({
      before,
      state,
      spec,
      deadline,
      captureFrame,
      classify,
      isStopping,
      wait,
      postCaptureAttempts,
      postCaptureIntervalMilliseconds,
      evidence
    });
    return { evidence, finalCapture: transition.capture };
  } catch (error) {
    error.partialEvidence = evidence;
    throw error;
  }
}

const inlineSemanticRecoveryRoles = Object.freeze({
  TRY_AGAIN: "recovery_try_again",
  STEAM_SIGN_IN: "recovery_steam_sign_in",
  CLICK_TO_PLAY: "recovery_click_to_play",
  GAMEPLAY_NO_MAP: "recovery_open_world_map",
});

export async function executeInlineSemanticRecovery({
  initialCapture,
  deadline,
  captureFrame,
  performAction,
  classify = classifyCapture,
  isStopping = () => false,
  wait = delay,
  postCaptureAttempts = 120,
  postCaptureIntervalMilliseconds = 500,
}) {
  const evidence = [];
  const history = [];
  const actions = [];
  try {
    assertActive(deadline, isStopping);
    assertCaptureContext(null, initialCapture);
    let capture = initialCapture;
    let classification = await classify(capture.pngPath);
    let state = observedReadinessState(classification);

    for (let ordinal = 1; ordinal <= 6 && state !== "MAP_READY"; ordinal += 1) {
      const spec = recoverySpecs[state];
      if (!spec || ["CONTEXT_MENU_OPEN_MAP", "SURFACE_SELECTOR_OPEN"].includes(state)) {
        throw new Error(`PRECISELY_BLOCKED_INLINE_SEMANTIC_RECOVERY_STATE:${state}`);
      }
      const before = capture;
      const beforeClassification = classification;
      const role = inlineSemanticRecoveryRoles[state] ?? null;
      let actionRecord = null;

      if (spec.kind === "click") {
        const localization = classification.recovery_localization;
        if (!role || !localization?.source_click_point || localization.exactly_one_target !== true) {
          throw new Error(`PRECISELY_BLOCKED_NO_CLICK:${state}:LOCALIZATION_REQUIRED`);
        }
        if (
          before.pixelWidth !== localization.source_frame_geometry?.width
          || before.pixelHeight !== localization.source_frame_geometry?.height
        ) {
          throw new Error(`RECOVERY_CAPTURE_GEOMETRY_BINDING_MISMATCH:${state}`);
        }
        const operation = {
          kind: "click",
          point: localization.source_click_point,
          button: "left",
        };
        assertActive(deadline, isStopping);
        const inputEvidence = await performAction(
          { ...operation, semantic_role: role },
          before
        );
        actionRecord = {
          role,
          capture_id: before.captureIdentifier,
          operation,
          input_evidence: inputEvidence,
        };
        actions.push(actionRecord);
        evidence.push({
          kind: "semantic_recovery_click",
          state,
          localization,
          input_evidence: inputEvidence,
        });
      } else if (spec.kind === "open_world_map") {
        if (!role) throw new Error(`INLINE_SEMANTIC_RECOVERY_ROLE_MISSING:${state}`);
        const operation = { kind: "open_world_map" };
        assertActive(deadline, isStopping);
        const inputEvidence = await performAction(
          { ...operation, semantic_role: role },
          before
        );
        actionRecord = {
          role,
          capture_id: before.captureIdentifier,
          operation,
          input_evidence: inputEvidence,
        };
        actions.push(actionRecord);
        evidence.push({
          kind: "semantic_recovery_open_world_map",
          state,
          input_evidence: inputEvidence,
        });
      }

      const transition = await captureRecoveryTransition({
        before,
        state,
        spec,
        deadline,
        captureFrame,
        classify,
        isStopping,
        wait,
        postCaptureAttempts,
        postCaptureIntervalMilliseconds,
        evidence,
      });
      history.push({
        ordinal,
        state,
        observed_state: transition.observedState,
        action_role: role,
        before_capture: before,
        after_capture: transition.capture,
        before_classification: beforeClassification,
        after_classification: transition.classification,
      });
      capture = transition.capture;
      classification = transition.classification;
      state = transition.observedState;
    }

    if (state !== "MAP_READY") {
      throw new Error("PRECISELY_BLOCKED_INLINE_SEMANTIC_RECOVERY_EXHAUSTED");
    }
    return { capture, classification, evidence, history, actions };
  } catch (error) {
    error.partialEvidence = evidence;
    error.partialRecoveryHistory = history;
    error.partialActionHistory = actions;
    throw error;
  }
}

async function captureRecoveryPreflight({
  state,
  deadline,
  captureFrame,
  classify,
  isStopping,
  wait,
  preflightCaptureAttempts,
  preflightCaptureIntervalMilliseconds,
  evidence,
}) {
  let previousCapture = null;
  for (let attempt = 1; attempt <= preflightCaptureAttempts; attempt += 1) {
    assertActive(deadline, isStopping);
    const capture = await captureFrame();
    assertCaptureContext(previousCapture, capture);
    try {
      const classification = await classify(capture.pngPath);
      evidence.push({
        kind: "recovery_preflight_capture",
        attempt,
        capture,
        classification,
      });
      return { capture, classification };
    } catch (error) {
      if (!isTransientRecoveryClassificationError(error)) throw error;
      evidence.push({
        kind: "recovery_preflight_unclassified",
        attempt,
        capture,
        classification_error: error.message,
      });
      previousCapture = capture;
      if (attempt < preflightCaptureAttempts) {
        await wait(preflightCaptureIntervalMilliseconds);
      }
    }
  }
  throw new Error(`PRECISELY_BLOCKED_RECOVERY_PREFLIGHT_TIMEOUT:${state}`);
}

async function captureRecoveryTransition({
  before,
  state,
  spec,
  deadline,
  captureFrame,
  classify,
  isStopping,
  wait,
  postCaptureAttempts,
  postCaptureIntervalMilliseconds,
  evidence
}) {
  for (let attempt = 1; attempt <= postCaptureAttempts; attempt += 1) {
    assertActive(deadline, isStopping);
    await wait(postCaptureIntervalMilliseconds);
    assertActive(deadline, isStopping);
    const capture = await captureFrame();
    assertCaptureContext(before, capture);
    if (capture.pngSHA256 === before.pngSHA256) {
      evidence.push({ kind: "recovery_transition_unchanged", attempt, capture });
      continue;
    }
    let classification;
    try {
      classification = await classify(capture.pngPath);
    } catch (error) {
      if (!isTransientRecoveryClassificationError(error)) throw error;
      evidence.push({
        kind: "recovery_transition_unclassified",
        attempt,
        capture,
        classification_error: error.message,
      });
      continue;
    }
    assertActive(deadline, isStopping);
    let observedState;
    try {
      observedState = observedReadinessState(classification);
    } catch (error) {
      if (error?.message !== "PRECISELY_BLOCKED_RECOVERY_UNKNOWN_OR_AMBIGUOUS_SCREEN") {
        throw error;
      }
      evidence.push({
        kind: "recovery_transition_unclassified",
        attempt,
        capture,
        classification,
      });
      continue;
    }
    evidence.push({
      kind: "recovery_transition_capture",
      attempt,
      capture,
      classification,
      observed_state: observedState
    });
    if (observedState === state) continue;
    if (!spec.downstream.includes(observedState)) {
      throw new Error(`RECOVERY_TRANSITION_FORBIDDEN:${state}->${observedState}`);
    }
    return { capture, classification, observedState };
  }
  throw new Error(`PRECISELY_BLOCKED_RECOVERY_TIMEOUT:${state}`);
}

function isTransientRecoveryClassificationError(error) {
  const message = error?.message || "";
  return [
    "UNSUPPORTED_OSRS_CAPTURE_ASPECT_RATIO",
    "AMBIGUOUS_OSRS_CAPTURE_ASPECT_RATIO",
    "PRECISELY_BLOCKED_RECOVERY_STATE_AMBIGUOUS",
  ].includes(message)
    || /^PRECISELY_BLOCKED_NO_CLICK:[A-Z_]+:AMBIGUOUS_LOCALIZATION$/.test(message);
}

function requireExactRecoveryState(classification, expectedState) {
  const observedState = observedReadinessState(classification);
  if (observedState !== expectedState) {
    throw new Error(`RECOVERY_STATE_OPERATION_MISMATCH:${expectedState}->${observedState}`);
  }
  if (!["CONNECTING", "GAMEPLAY_NO_MAP", "SURFACE_SELECTOR_OPEN"].includes(expectedState)
      && !classification.recovery_localization) {
    throw new Error(`PRECISELY_BLOCKED_NO_CLICK:${expectedState}:LOCALIZATION_REQUIRED`);
  }
}

function observedReadinessState(classification) {
  if (isAuthorizedMapClassification(classification)) return "MAP_READY";
  if (classification?.connection === "CONNECTED"
      && classification?.map_shell === "FLOATING_MAP_OPEN"
      && classification?.overlay === "SURFACE_SELECTOR"
      && classification?.committable === false) {
    return "SURFACE_SELECTOR_OPEN";
  }
  const recoveryClassification = refineSemanticPostCloseClassification(classification);
  if (recoverySpecs[recoveryClassification?.recovery_state]) {
    return recoveryClassification.recovery_state;
  }
  throw new Error("PRECISELY_BLOCKED_RECOVERY_UNKNOWN_OR_AMBIGUOUS_SCREEN");
}

function assertCaptureContext(before, capture) {
  if (
    !capture
    || !capture.captureIdentifier
    || !capture.pngPath
    || !capture.pngSHA256
    || !Number.isInteger(capture.pixelWidth)
    || !Number.isInteger(capture.pixelHeight)
    || capture.target?.bundleIdentifier !== "com.jagex.osclient"
  ) {
    throw new Error("RECOVERY_CAPTURE_EVIDENCE_INVALID");
  }
  if (!before) return;
  const firstTarget = before.target;
  const nextTarget = capture.target;
  if (
    !firstTarget
    || !nextTarget
    || firstTarget.bundleIdentifier !== "com.jagex.osclient"
    || nextTarget.bundleIdentifier !== firstTarget.bundleIdentifier
    || nextTarget.processIdentifier !== firstTarget.processIdentifier
    || nextTarget.windowIdentifier !== firstTarget.windowIdentifier
    || capture.captureIdentifier === before.captureIdentifier
    || capture.pngPath === before.pngPath
  ) {
    throw new Error("RECOVERY_TARGET_OR_CONTEXT_LOST");
  }
}

function assertActive(deadline, isStopping) {
  if (isStopping()) throw new Error("WORKER_STOPPING");
  if (!Number.isFinite(deadline) || Date.now() >= deadline) {
    throw new Error("ITEM_EXECUTION_DEADLINE_EXCEEDED");
  }
}

function validPoint(point) {
  return Number.isFinite(point?.x) && point.x >= 0
    && Number.isFinite(point?.y) && point.y >= 0;
}

function samePoint(first, second) {
  return first?.x === second?.x && first?.y === second?.y;
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}
