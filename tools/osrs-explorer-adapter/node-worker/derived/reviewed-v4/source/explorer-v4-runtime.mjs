import fs from "node:fs/promises";
import path from "node:path";
import crypto from "node:crypto";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const sharp = require(
  "/Applications/ChatGPT.app/Contents/Resources/cua_node/lib/node_modules/sharp/lib/index.js"
);

export const EMBEDDED_RUNTIME_IDENTITY = Object.freeze({
  source_version: "4.008.0",
  explorer_generation_id: "explorer-v4cr4-20260731T022656Z"
});
const ZOOM_LADDER = [37.5, 50, 75, 100, 200];
const MAP_CHROME_CROP = { left: 4, top: 35, width: 516, height: 641 };
const DEFAULT_CONTENT_CROP = { left: 4, top: 70, width: 470, height: 560 };
const RECOVERY_REFERENCE_BOXES = {
  TRY_AGAIN: { left: 314, top: 317, right: 454, bottom: 356 },
  STEAM_SIGN_IN: { left: 244, top: 255, right: 523, bottom: 295 },
  CLICK_TO_PLAY: { left: 254, top: 310, right: 474, bottom: 393 },
  GAMEPLAY_NO_MAP: { left: 690, top: 147, right: 725, bottom: 184 },
  CONTEXT_MENU_OPEN_MAP: { left: 634, top: 197, right: 705, bottom: 214 }
};
const MAP_ORB_SEARCH_PADDING = { horizontal: 30, vertical: 44 };
const MAP_OPEN_MENU_SEARCH_REGION = { left: 610, top: 175, right: 740, bottom: 240 };

export const sha256 = (bytes) => crypto.createHash("sha256").update(bytes).digest("hex");
let ACTIVE_LIFECYCLE = null;
export const sleep = (milliseconds) =>
  ACTIVE_LIFECYCLE
    ? ACTIVE_LIFECYCLE.delay(milliseconds, `runtime-sleep-${milliseconds}`)
    : new Promise((resolve) => setTimeout(resolve, milliseconds));

export function canonicalJson(value) {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.keys(value)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${canonicalJson(value[key])}`)
      .join(",")}}`;
  }
  return JSON.stringify(value);
}

export async function readJson(file) {
  return JSON.parse(await fs.readFile(file, "utf8"));
}

export async function writeAtomic(destination, bytes) {
  const temporary = `${destination}.tmp-${Date.now()}-${crypto.randomBytes(4).toString("hex")}`;
  await fs.writeFile(temporary, bytes, { flag: "wx" });
  await fs.rename(temporary, destination);
}

async function writeOrVerifyImmutableStage(destination, bytes) {
  try {
    await fs.writeFile(destination, bytes, { flag: "wx", mode: 0o444 });
  } catch (error) {
    if (error?.code !== "EEXIST") throw error;
    const existing = await fs.readFile(destination);
    if (!existing.equals(bytes)) throw new Error(`IMMUTABLE_STAGE_COLLISION:${destination}`);
  }
}

export function serializeError(error) {
  return {
    name: error?.name || "Error",
    message: String(error?.message || error),
    stack: typeof error?.stack === "string" ? error.stack : null,
    code: error?.code || null
  };
}

function preciseTerminalStatus(error) {
  const message = String(error?.message || error);
  if (
    message.startsWith("PRECISELY_BLOCKED") ||
    message.startsWith("ACTIONABLE_GAP_FOUND")
  ) {
    return message;
  }
  return `PRECISELY_BLOCKED_LEASE_EXCEPTION:${error?.name || "Error"}:${message}`;
}

export function createLeaseController({
  identity,
  explorerThreadId,
  expectedPredecessor,
  controllerGlobalName,
  sourceVersion = EMBEDDED_RUNTIME_IDENTITY.source_version,
  explorerGeneration =
    EMBEDDED_RUNTIME_IDENTITY.explorer_generation_id,
  lifecycleToken = null,
  finalizerReservation = null,
  finalizerBinding = null
}) {
  if (
    sourceVersion !== EMBEDDED_RUNTIME_IDENTITY.source_version ||
    explorerGeneration !==
      EMBEDDED_RUNTIME_IDENTITY.explorer_generation_id
  ) {
    throw new Error("CONTROLLER_RUNTIME_IDENTITY_MISMATCH");
  }
  const controller = {
    schema_version: 1,
    identity,
    source_version: sourceVersion,
    explorer_generation: explorerGeneration,
    explorer_thread_id: explorerThreadId,
    active: true,
    status: "RUNNING",
    error: null,
    primary_failure: null,
    finalization_failure: null,
    finalization_error: null,
    finalization_failure_record: null,
    started_at: new Date().toISOString(),
    finished_at: null,
    starting_head: JSON.parse(JSON.stringify(expectedPredecessor)),
    last_journal_head: JSON.parse(JSON.stringify(expectedPredecessor)),
    last_commit: null,
    accepted_commits: 0,
    accepted_commit_terminal_state: null,
    accepted_commit_continuity_record: null,
    committed_postprocessing_recovery: null,
    first_commit_proof: null,
    worklist_cursor: null,
    recovery_events: [],
    in_flight_ui_operations: [],
    no_action_in_flight: false,
    no_background_promise_after_return: false,
    duplicate_launch_permitted: false,
    rollover_emitted: false,
    finalization_record: null
  };
  Object.defineProperties(controller, {
    _lifecycle: {
      value: lifecycleToken,
      enumerable: false,
      writable: false
    },
    _finalizerReservation: {
      value: finalizerReservation,
      enumerable: false,
      writable: false
    },
    _finalizerBinding: {
      value: finalizerBinding,
      enumerable: false,
      writable: false
    }
  });
  globalThis[controllerGlobalName] = controller;
  return controller;
}

function exactHeadMatches(first, second) {
  return (
    first?.sequence === second?.sequence &&
    first?.commit_sha256 === second?.commit_sha256
  );
}

function cloneJson(value) {
  return JSON.parse(JSON.stringify(value));
}

export function recordAcceptedBrokerCommit({
  controller,
  acceptedEnvelope,
  expectedPredecessor,
  idempotencyKey,
  item = null,
  worklist = null,
  commitContext = {}
}) {
  const acceptedHead = acceptedEnvelope?.head;
  const acceptedCommit = acceptedEnvelope?.commit;
  if (
    acceptedEnvelope?.ok !== true ||
    acceptedEnvelope?.protocol !== "osrs-capture-broker-v4" ||
    acceptedEnvelope?.idempotency_key !== idempotencyKey ||
    !exactHeadMatches(acceptedEnvelope?.expected_predecessor, expectedPredecessor) ||
    acceptedHead?.sequence !== expectedPredecessor.sequence + 1 ||
    typeof acceptedHead?.commit_sha256 !== "string" ||
    acceptedCommit?.sequence !== acceptedHead.sequence ||
    acceptedCommit?.previous_commit_sha256 !== expectedPredecessor.commit_sha256
  ) {
    throw new Error("BROKER_ACCEPTED_TERMINAL_STATE_ENVELOPE_INVALID");
  }
  const brokerCommitIdentity = {
    sequence: acceptedHead.sequence,
    commit_sha256: acceptedHead.commit_sha256,
    commit_path: acceptedHead.commit_path || null,
    previous_commit_sha256: acceptedCommit.previous_commit_sha256,
    idempotency_key: idempotencyKey,
    request_fingerprint:
      acceptedEnvelope.raw_broker_response?.request_fingerprint ||
      acceptedCommit.broker_protocol?.request_fingerprint ||
      null
  };
  const nextAcceptedCount = controller.accepted_commits + 1;
  const recoveryDisposition = {
    state: "RECOVERY_REQUIRED_COMMITTED_POSTPROCESSING",
    reason: "BROKER_COMMIT_ACCEPTED_POSTPROCESSING_NOT_YET_COMPLETE",
    accepted_head: cloneJson(acceptedHead),
    accepted_count: nextAcceptedCount,
    exact_commit_identity: cloneJson(brokerCommitIdentity),
    stable_idempotency_key: idempotencyKey,
    work_item_id: item?.id || null,
    worklist_cursor_before_commit: worklist?.cursor ?? controller.worklist_cursor,
    worklist_action:
      "RECONCILE_ACCEPTED_HEAD_THEN_ADVANCE_EXACTLY_ONCE_WITHOUT_RECOMMIT",
    retry_commit_forbidden: true,
    next_eligible_condition:
      "accepted head, commit identity, and idempotency reconcile exactly"
  };

  // This synchronous controller update is intentionally the first operation
  // after the verified broker call returns. Any later await or injected error
  // therefore terminalizes the irreversible accepted commit, not its predecessor.
  controller.last_journal_head = cloneJson(acceptedHead);
  controller.accepted_commits = nextAcceptedCount;
  controller.last_commit = {
    head: cloneJson(acceptedHead),
    idempotency_key: idempotencyKey,
    exact_commit_identity: cloneJson(brokerCommitIdentity),
    accepted_envelope: cloneJson(acceptedEnvelope),
    ...cloneJson(commitContext)
  };
  controller.committed_postprocessing_recovery = recoveryDisposition;
  controller.accepted_commit_terminal_state = {
    schema_version: 1,
    record_type: "EXPLORER_V4_ACCEPTED_COMMIT_TERMINAL_STATE",
    controller_identity: controller.identity,
    accepted_at: new Date().toISOString(),
    verified_accepted_envelope: cloneJson(acceptedEnvelope),
    accepted_head: cloneJson(acceptedHead),
    accepted_count: nextAcceptedCount,
    exact_commit_identity: cloneJson(brokerCommitIdentity),
    stable_idempotency_key: idempotencyKey,
    worklist_recovery_disposition: cloneJson(recoveryDisposition),
    immutable: true
  };
  if (item) {
    item.state = "RECOVERY_REQUIRED_COMMITTED_POSTPROCESSING";
    item.defer_reason = recoveryDisposition.reason;
    item.next_eligible_condition = recoveryDisposition.next_eligible_condition;
  }
  return controller.accepted_commit_terminal_state;
}

export async function persistAcceptedCommitTerminalState({
  controller,
  statusRoot
}) {
  const state = controller.accepted_commit_terminal_state;
  if (!state) throw new Error("ACCEPTED_COMMIT_TERMINAL_STATE_MISSING");
  if (controller._finalizerReservation) {
    const bytes = Buffer.from(`${canonicalJson(state)}\n`);
    controller.accepted_commit_continuity_record = {
      persistence:
        "EMBEDDED_IN_STATUS_ONLY_CONTROLLER_FINALIZATION_RECORD",
      sha256: sha256(bytes),
      mode: null,
      readback: cloneJson(state),
      direct_status_root_write_performed: false
    };
    return controller.accepted_commit_continuity_record;
  }
  if (process.env.OSRS_EXPLORER_V4_OFFLINE_HARNESS !== "1") {
    throw new Error("STATUS_ONLY_FINALIZER_RESERVATION_REQUIRED");
  }
  const bytes = Buffer.from(`${canonicalJson(state)}\n`);
  const digest = sha256(bytes);
  const destination =
    `${statusRoot}/ACCEPTED_COMMIT_TERMINAL_STATE-` +
    `${controller.identity.replace(/[^a-zA-Z0-9_.-]/g, "_")}-` +
    `${String(state.accepted_head.sequence).padStart(6, "0")}-` +
    `${digest.slice(0, 12)}.json`;
  await writeOrVerifyImmutableStage(destination, bytes);
  await fs.chmod(destination, 0o444);
  const readback = await readJson(destination);
  if (canonicalJson(readback) !== canonicalJson(state)) {
    throw new Error("ACCEPTED_COMMIT_TERMINAL_STATE_READBACK_MISMATCH");
  }
  controller.accepted_commit_continuity_record = {
    path: destination,
    sha256: digest,
    mode: "0444",
    readback
  };
  return controller.accepted_commit_continuity_record;
}

export async function runSerialUiOperation(controller, kind, operation) {
  if (!controller?.active) {
    throw new Error(`PRECISELY_BLOCKED_UI_OPERATION_ON_INACTIVE_CONTROLLER:${kind}`);
  }
  if (controller.in_flight_ui_operations.length !== 0) {
    throw new Error(`PRECISELY_BLOCKED_CONCURRENT_UI_OPERATION:${kind}`);
  }
  const token = {
    id: `${controller.identity}:${kind}:${crypto.randomBytes(8).toString("hex")}`,
    kind,
    started_at: new Date().toISOString()
  };
  controller.in_flight_ui_operations.push(token);
  controller.no_action_in_flight = false;
  try {
    if (controller._lifecycle) {
      return await controller._lifecycle.runOperation(
        "policy",
        `policy-${kind}`,
        async () =>
          await controller._lifecycle.runOperation(
            "ui",
            `ui-${kind}`,
            async (signal) => await operation(signal)
          )
      );
    }
    return await operation();
  } finally {
    const index = controller.in_flight_ui_operations.findIndex(
      (candidate) => candidate.id === token.id
    );
    if (index >= 0) controller.in_flight_ui_operations.splice(index, 1);
    controller.no_action_in_flight =
      controller.in_flight_ui_operations.length === 0;
  }
}

export function constructControllerFinalization({
  controller,
  terminalResult,
  originalError,
  finalizationError = null,
  measuredQuiescence = null
}) {
  const primaryFailure = originalError ? serializeError(originalError) : null;
  const finalizationFailure = finalizationError
    ? serializeError(finalizationError)
    : null;
  controller.primary_failure = primaryFailure;
  controller.finalization_failure = finalizationFailure;
  controller.finalization_error = finalizationFailure;
  if (controller.in_flight_ui_operations.length !== 0) {
    const backgroundError = new Error("PRECISELY_BLOCKED_BACKGROUND_UI_OPERATION");
    if (!originalError) controller.error = serializeError(backgroundError);
    controller.status = "PRECISELY_BLOCKED_BACKGROUND_UI_OPERATION";
  }
  controller.active = false;
  controller.finished_at = new Date().toISOString();
  controller.no_action_in_flight =
    controller.in_flight_ui_operations.length === 0;
  controller.no_background_promise_after_return = measuredQuiescence
    ? measuredQuiescence.no_background_promise_after_return === true
    : process.env.OSRS_EXPLORER_V4_OFFLINE_HARNESS === "1" &&
      controller.in_flight_ui_operations.length === 0;
  controller.duplicate_launch_permitted = false;
  if (controller.error) controller.rollover_emitted = false;
  return {
    schema_version: 1,
    record_type: "EXPLORER_V4_CONTROLLER_FINALIZATION",
    source_version: controller.source_version,
    explorer_generation: controller.explorer_generation,
    explorer_thread_id: controller.explorer_thread_id,
    controller_identity: controller.identity,
    active: controller.active,
    status: controller.status,
    started_at: controller.started_at,
    finished_at: controller.finished_at,
    starting_head: controller.starting_head,
    last_journal_head: controller.last_journal_head,
    last_commit: controller.last_commit,
    accepted_commits: controller.accepted_commits,
    accepted_commit_terminal_state: controller.accepted_commit_terminal_state,
    accepted_commit_continuity_record:
      controller.accepted_commit_continuity_record,
    committed_postprocessing_recovery:
      controller.committed_postprocessing_recovery,
    first_commit_proof: controller.first_commit_proof,
    worklist_cursor: controller.worklist_cursor,
    recovery_events: controller.recovery_events,
    error: controller.error,
    primary_failure: primaryFailure,
    finalization_failure: finalizationFailure,
    original_error_preserved: primaryFailure,
    terminal_result_status: terminalResult?.status || null,
    in_flight_ui_operations: controller.in_flight_ui_operations,
    in_flight_ui_operation_count: controller.in_flight_ui_operations.length,
    no_action_in_flight: controller.no_action_in_flight,
    no_background_promise_after_return:
      controller.no_background_promise_after_return,
    measured_quiescence: measuredQuiescence,
    reservation_binding: controller._finalizerBinding,
    duplicate_launch_permitted: false,
    rollover_emitted: controller.rollover_emitted,
    immutable: true
  };
}

export async function persistControllerFinalization({
  controller,
  statusRoot,
  record
}) {
  if (controller._finalizerReservation) {
    const receipt = await controller._finalizerReservation.finalize(record);
    controller.finalization_record = {
      protocol: "osrs-status-finalizer-v1",
      receipt,
      path: null,
      basename: receipt.record_basename,
      sha256: receipt.record_sha256,
      mode: receipt.mode,
      readback: cloneJson(record),
      readback_sha256: receipt.readback_sha256,
      readback_verified: receipt.readback_verified,
      direct_status_root_write_performed: false
    };
    return controller.finalization_record;
  }
  if (process.env.OSRS_EXPLORER_V4_OFFLINE_HARNESS !== "1") {
    throw new Error("STATUS_ONLY_FINALIZER_RESERVATION_REQUIRED");
  }
  const bytes = Buffer.from(`${canonicalJson(record)}\n`);
  const destination =
    `${statusRoot}/CONTROLLER_FINALIZATION-${controller.identity.replace(/[^a-zA-Z0-9_.-]/g, "_")}.json`;
  await writeOrVerifyImmutableStage(destination, bytes);
  await fs.chmod(destination, 0o444);
  controller.finalization_record = {
    path: destination,
    sha256: sha256(bytes),
    mode: "0444",
    readback: await readJson(destination)
  };
  return controller.finalization_record;
}

export async function withControllerTerminalizer({
  controller,
  statusRoot,
  body
}) {
  let result = null;
  let primaryError = null;
  let finalizationError = null;
  let terminalState = null;
  try {
    result = await body();
    if (result?.status) controller.status = result.status;
    controller.rollover_emitted = result?.status === "ROLLOVER_READY";
  } catch (error) {
    primaryError = error;
    controller.error = serializeError(error);
    controller.primary_failure = serializeError(error);
    controller.status = preciseTerminalStatus(error);
    controller.rollover_emitted = false;
  } finally {
    if (controller._lifecycle) {
      if (primaryError) controller._lifecycle.abort(primaryError);
      else controller._lifecycle.closeAdmission();
      try {
        await controller._lifecycle.drain({
          allowTerminalResources: true
        });
      } catch (drainError) {
        if (!primaryError) {
          primaryError = drainError;
          controller.error = serializeError(drainError);
          controller.primary_failure = serializeError(drainError);
          controller.status = preciseTerminalStatus(drainError);
        }
      }
    }
    const measuredQuiescence =
      controller._lifecycle?.measuredQuiescence() || null;
    const record = constructControllerFinalization({
      controller,
      terminalResult: result,
      originalError: primaryError,
      measuredQuiescence
    });
    try {
      await persistControllerFinalization({
        controller,
        statusRoot,
        record
      });
    } catch (error) {
      finalizationError = error;
      controller.active = false;
      controller.finished_at ||= new Date().toISOString();
      controller.no_action_in_flight =
        controller.in_flight_ui_operations.length === 0;
      controller.no_background_promise_after_return = false;
      controller.duplicate_launch_permitted = false;
      controller.rollover_emitted = false;
      controller.finalization_error = serializeError(error);
      controller.finalization_failure = serializeError(error);
      if (!primaryError) {
        controller.status = preciseTerminalStatus(finalizationError);
      }
    }
    if (controller._lifecycle) {
      try {
        await controller._lifecycle.drain();
      } catch (drainError) {
        if (!finalizationError) finalizationError = drainError;
        else finalizationError.lifecycle_drain_error = serializeError(drainError);
        controller.finalization_error = serializeError(finalizationError);
        controller.finalization_failure = serializeError(finalizationError);
        if (!primaryError) {
          controller.status = preciseTerminalStatus(finalizationError);
        }
      }
      controller._lifecycle.markControllerInactive();
    }
    const returnedQuiescence =
      controller._lifecycle?.measuredQuiescence() || measuredQuiescence;
    terminalState = constructControllerFinalization({
      controller,
      terminalResult: result,
      originalError: primaryError,
      finalizationError,
      measuredQuiescence: returnedQuiescence
    });
    controller.finalization_failure_record = finalizationError
      ? cloneJson(terminalState)
      : null;
    if (controller.finalization_record) {
      controller.finalization_record.return_quiescence =
        cloneJson(returnedQuiescence);
      controller.finalization_record.return_terminal_state =
        cloneJson(terminalState);
    } else if (finalizationError) {
      controller.finalization_record = {
        protocol: "osrs-status-finalizer-v1",
        persisted: false,
        receipt: null,
        path: null,
        readback: cloneJson(terminalState),
        readback_verified: false,
        persistence_failure: serializeError(finalizationError),
        return_quiescence: cloneJson(returnedQuiescence),
        return_terminal_state: cloneJson(terminalState),
        direct_status_root_write_performed: false
      };
    }
  }
  if (primaryError || finalizationError) {
    const terminalError = primaryError || finalizationError;
    terminalError.controller_finalization = controller.finalization_record;
    terminalError.controller_terminal_state = terminalState;
    terminalError.primary_cause = primaryError
      ? serializeError(primaryError)
      : null;
    terminalError.finalization_cause = finalizationError
      ? serializeError(finalizationError)
      : null;
    throw terminalError;
  }
  return {
    ...result,
    controller_finalization: controller.finalization_record
  };
}

function regionStats(raw, width, height, left, top, regionWidth, regionHeight) {
  let count = 0;
  let sum = 0;
  let sumSquares = 0;
  let orange = 0;
  for (let y = Math.max(0, top); y < Math.min(height, top + regionHeight); y += 2) {
    for (let x = Math.max(0, left); x < Math.min(width, left + regionWidth); x += 2) {
      const index = (y * width + x) * 3;
      const red = raw[index];
      const green = raw[index + 1];
      const blue = raw[index + 2];
      const value = (red + green + blue) / 3;
      sum += value;
      sumSquares += value * value;
      count += 1;
      if (red > 150 && green > 45 && green < 195 && blue < 95) orange += 1;
    }
  }
  const mean = sum / Math.max(1, count);
  return {
    mean,
    stddev: Math.sqrt(Math.max(0, sumSquares / Math.max(1, count) - mean * mean)),
    orange_fraction: orange / Math.max(1, count)
  };
}

export function meanDifference(first, second, stride = 24) {
  const limit = Math.min(first.length, second.length);
  let sum = 0;
  let count = 0;
  for (let index = 0; index < limit; index += stride) {
    sum += Math.abs(first[index] - second[index]);
    sum += Math.abs(first[index + 1] - second[index + 1]);
    sum += Math.abs(first[index + 2] - second[index + 2]);
    count += 3;
  }
  return sum / Math.max(1, count);
}

function patchDifference(observation, template, referenceBox, candidateLeft, candidateTop) {
  const width = referenceBox.right - referenceBox.left;
  const height = referenceBox.bottom - referenceBox.top;
  let sum = 0;
  let count = 0;
  for (let y = 0; y < height; y += 3) {
    for (let x = 0; x < width; x += 3) {
      const current = ((candidateTop + y) * observation.width + candidateLeft + x) * 3;
      const reference =
        ((referenceBox.top + y) * template.width + referenceBox.left + x) * 3;
      sum += Math.abs(observation.raw[current] - template.raw[reference]);
      sum += Math.abs(observation.raw[current + 1] - template.raw[reference + 1]);
      sum += Math.abs(observation.raw[current + 2] - template.raw[reference + 2]);
      count += 3;
    }
  }
  return sum / Math.max(1, count);
}

export function locateUniquePatch(
  observation,
  template,
  referenceBox,
  searchRegion,
  label,
  searchStep = 2
) {
  const width = referenceBox.right - referenceBox.left;
  const height = referenceBox.bottom - referenceBox.top;
  const candidates = [];
  for (let top = searchRegion.top; top <= searchRegion.bottom - height; top += searchStep) {
    for (let left = searchRegion.left; left <= searchRegion.right - width; left += searchStep) {
      candidates.push({
        left,
        top,
        score: patchDifference(observation, template, referenceBox, left, top)
      });
    }
  }
  candidates.sort((first, second) => first.score - second.score);
  const best = candidates[0];
  const distinct = candidates.find(
    (candidate) =>
      Math.abs(candidate.left - best.left) >= Math.max(6, width * 0.08) ||
      Math.abs(candidate.top - best.top) >= Math.max(6, height * 0.08)
  );
  if (!best || best.score > 34 || !distinct || distinct.score - best.score < 0.25) {
    throw new Error(`PRECISELY_BLOCKED_NO_CLICK:${label}:AMBIGUOUS_LOCALIZATION`);
  }
  const observedBox = {
    left: best.left,
    top: best.top,
    right: best.left + width,
    bottom: best.top + height
  };
  const clickPoint = {
    x: Math.floor((observedBox.left + observedBox.right) / 2),
    y: Math.floor((observedBox.top + observedBox.bottom) / 2)
  };
  if (
    !(
      clickPoint.x > observedBox.left &&
      clickPoint.x < observedBox.right &&
      clickPoint.y > observedBox.top &&
      clickPoint.y < observedBox.bottom
    )
  ) {
    throw new Error(`PRECISELY_BLOCKED_NO_CLICK:${label}:POINT_OUTSIDE`);
  }
  return {
    target: label,
    fresh_frame_sha256: observation.sha256,
    frame_geometry: { width: observation.width, height: observation.height },
    search_region: searchRegion,
    observed_bbox: observedBox,
    click_point: clickPoint,
    best_score: best.score,
    distinct_second_score: distinct.score,
    exactly_one_target: true,
    click_point_inside_observed_bounds: true,
    localized_at: new Date().toISOString()
  };
}

export async function decodeImage(bytes) {
  const decoded = await sharp(bytes)
    .removeAlpha()
    .raw()
    .toBuffer({ resolveWithObject: true });
  return {
    raw: decoded.data,
    width: decoded.info.width,
    height: decoded.info.height
  };
}

async function cropRaw(png, crop) {
  return (
    await sharp(png)
      .extract(crop)
      .removeAlpha()
      .raw()
      .toBuffer({ resolveWithObject: true })
  ).data;
}

export async function buildTemplate(record) {
  const bytes = await fs.readFile(record.path);
  if (sha256(bytes) !== record.sha256) throw new Error(`TEMPLATE_DIGEST_MISMATCH:${record.path}`);
  return { ...(await decodeImage(bytes)), path: record.path, sha256: record.sha256 };
}

function fullTemplateDifference(observation, template) {
  return meanDifference(observation.raw, template.raw, 96);
}

function selectorListScore(observation, selectorTemplate) {
  const referenceBox = { left: 165, top: 532, right: 359, bottom: 670 };
  const search = { left: 150, top: 500, right: 380, bottom: 700 };
  try {
    return locateUniquePatch(
      observation,
      selectorTemplate,
      referenceBox,
      search,
      "SURFACE_SELECTOR_OVERLAY"
    ).best_score;
  } catch {
    return Number.POSITIVE_INFINITY;
  }
}

function contextMenuScore(observation, contextTemplate) {
  const referenceBox = { left: 630, top: 165, right: 768, bottom: 216 };
  const search = { left: 600, top: 135, right: 768, bottom: 250 };
  try {
    return locateUniquePatch(
      observation,
      contextTemplate,
      referenceBox,
      search,
      "PANEL_CONTEXT_MENU_OVERLAY"
    ).best_score;
  } catch {
    return Number.POSITIVE_INFINITY;
  }
}

export function classifyDecodedFrame(observation, templates) {
  const geometry =
    observation.width === 768 && (observation.height === 839 || observation.height === 861);
  const close = regionStats(observation.raw, observation.width, observation.height, 480, 35, 38, 38);
  const viewport = regionStats(
    observation.raw,
    observation.width,
    observation.height,
    4,
    70,
    470,
    560
  );
  const controls = regionStats(
    observation.raw,
    observation.width,
    observation.height,
    4,
    640,
    516,
    40
  );
  const hud = regionStats(
    observation.raw,
    observation.width,
    observation.height,
    530,
    32,
    228,
    190
  );
  const mapShell =
    geometry && close.orange_fraction > 0.012 && controls.stddev > 7 && hud.stddev > 8
      ? "FLOATING_MAP_OPEN"
      : "UNKNOWN";
  const selectorScore = templates.surfaceSelectorOpen
    ? selectorListScore(observation, templates.surfaceSelectorOpen)
    : Number.POSITIVE_INFINITY;
  const menuScore = templates.panelContextMenu
    ? contextMenuScore(observation, templates.panelContextMenu)
    : Number.POSITIVE_INFINITY;
  const closedMapContextMenu =
    menuScore < 34 && viewport.stddev <= 8;
  const reportedMapShell = closedMapContextMenu ? "CLOSED" : mapShell;
  let overlay = "NONE";
  if (selectorScore < 34) overlay = "SURFACE_SELECTOR";
  else if (menuScore < 34) {
    overlay =
      reportedMapShell === "FLOATING_MAP_OPEN"
        ? "PANEL_CONTEXT_MENU"
        : "CONTEXT_MENU_OPEN_MAP";
  } else if (reportedMapShell !== "FLOATING_MAP_OPEN") overlay = "UNKNOWN";
  const mapContent =
    viewport.stddev > 8 ? "NONBLACK_CONTENT" : viewport.stddev <= 8 ? "BLACK_OR_EMPTY" : "UNKNOWN";
  let recoveryState = null;
  let recoveryScore = Number.POSITIVE_INFINITY;
  if (closedMapContextMenu) {
    recoveryState = "CONTEXT_MENU_OPEN_MAP";
    recoveryScore = menuScore;
  } else if (reportedMapShell !== "FLOATING_MAP_OPEN" && templates.recovery) {
    const ordered = Object.entries(templates.recovery)
      .map(([state, template]) => [state, fullTemplateDifference(observation, template)])
      .sort((first, second) => first[1] - second[1]);
    if (ordered.length && ordered[0][1] < 26) {
      recoveryState = ordered[0][0];
      recoveryScore = ordered[0][1];
    }
  }
  return {
    connection:
      reportedMapShell === "FLOATING_MAP_OPEN" || closedMapContextMenu
        ? "CONNECTED"
        : recoveryState === "GAMEPLAY_NO_MAP"
          ? "CONNECTED"
          : recoveryState || "UNKNOWN",
    map_shell: reportedMapShell,
    overlay,
    map_content: mapContent,
    recovery_state: recoveryState,
    committable:
      reportedMapShell === "FLOATING_MAP_OPEN" &&
      overlay === "NONE" &&
      mapContent === "NONBLACK_CONTENT",
    metrics: {
      geometry,
      close_orange_fraction: close.orange_fraction,
      controls_stddev: controls.stddev,
      hud_stddev: hud.stddev,
      viewport_stddev: viewport.stddev,
      selector_overlay_score: selectorScore,
      context_menu_overlay_score: menuScore,
      recovery_template_score: recoveryScore
    }
  };
}

function grayThumbnail(raw, width, height, targetWidth = 94, targetHeight = 112) {
  const values = new Float32Array(targetWidth * targetHeight);
  for (let y = 0; y < targetHeight; y += 1) {
    const sourceY = Math.min(height - 1, Math.floor((y * height) / targetHeight));
    for (let x = 0; x < targetWidth; x += 1) {
      const sourceX = Math.min(width - 1, Math.floor((x * width) / targetWidth));
      const index = (sourceY * width + sourceX) * 3;
      values[y * targetWidth + x] = (raw[index] + raw[index + 1] + raw[index + 2]) / 3;
    }
  }
  return { values, width: targetWidth, height: targetHeight };
}

function displacementProof(preRaw, postRaw, width, height) {
  const pre = grayThumbnail(preRaw, width, height);
  const post = grayThumbnail(postRaw, width, height);
  let best = { dx: 0, dy: 0, error: Number.POSITIVE_INFINITY };
  let zeroError = null;
  for (let dy = -40; dy <= 40; dy += 2) {
    for (let dx = -40; dx <= 40; dx += 2) {
      let sum = 0;
      let count = 0;
      for (let y = Math.max(0, -dy); y < Math.min(pre.height, pre.height - dy); y += 2) {
        for (let x = Math.max(0, -dx); x < Math.min(pre.width, pre.width - dx); x += 2) {
          const difference =
            pre.values[y * pre.width + x] -
            post.values[(y + dy) * post.width + (x + dx)];
          sum += Math.abs(difference);
          count += 1;
        }
      }
      const error = sum / Math.max(1, count);
      if (dx === 0 && dy === 0) zeroError = error;
      if (error < best.error) best = { dx, dy, error };
    }
  }
  const magnitude = Math.sqrt(best.dx * best.dx + best.dy * best.dy);
  const delivered = magnitude >= 2 && best.error + 0.5 < (zeroError ?? Number.POSITIVE_INFINITY);
  return { ...best, zero_error: zeroError, magnitude_cells: magnitude, delivered };
}

function extentProof(postRaw, width, height, displacement) {
  const pixels = Math.max(Math.abs(displacement.dx), Math.abs(displacement.dy));
  if (pixels < 2) return { contribution_mean_abs: 0, contributed: false };
  const stripWidth = Math.max(2, Math.min(width / 3, Math.round((pixels * width) / 94)));
  let sum = 0;
  let count = 0;
  const startX = displacement.dx >= 0 ? width - stripWidth : 0;
  for (let y = 0; y < height; y += 3) {
    for (let x = startX; x < startX + stripWidth; x += 3) {
      const index = (y * width + x) * 3;
      sum += Math.abs(postRaw[index] - postRaw[index + 1]);
      sum += Math.abs(postRaw[index + 1] - postRaw[index + 2]);
      count += 2;
    }
  }
  const contribution = sum / Math.max(1, count);
  return { contribution_mean_abs: contribution, contributed: contribution >= 2 };
}

export function evaluateNovelty({
  preRaw,
  postRaw,
  sameFamilyRaw,
  width,
  height,
  thresholds
}) {
  const prePost = meanDifference(preRaw, postRaw);
  const sameFamily = sameFamilyRaw ? meanDifference(sameFamilyRaw, postRaw) : null;
  const displacement = displacementProof(preRaw, postRaw, width, height);
  const extent = extentProof(postRaw, width, height, displacement);
  const passed =
    prePost >= thresholds.pre_post_mean_abs_minimum &&
    (sameFamily === null || sameFamily >= thresholds.same_family_mean_abs_minimum) &&
    displacement.delivered &&
    displacement.magnitude_cells >= thresholds.delivered_displacement_minimum_cells &&
    extent.contribution_mean_abs >= thresholds.new_extent_mean_abs_minimum;
  return {
    passed,
    pre_post_mean_abs: prePost,
    same_family_mean_abs: sameFamily,
    displacement,
    extent
  };
}

export function deriveIdempotencyKey({
  predecessor,
  frameDigest,
  criterionFamilyKey,
  explorerThreadId
}) {
  return sha256(
    Buffer.from(
      canonicalJson({
        predecessor_sequence: predecessor.sequence,
        predecessor_commit_sha256: predecessor.commit_sha256,
        frame_sha256: frameDigest,
        criterion_family_key: criterionFamilyKey,
        explorer_thread_id: explorerThreadId
      })
    )
  );
}

export function verifyBrokerV4Envelope({
  expectedPredecessor,
  idempotencyKey,
  explorerThreadId,
  response,
  head,
  commit,
  metadata,
  observedCommitSha256
}) {
  const failures = [];
  if (response.ok !== true) failures.push("BROKER_RESPONSE_NOT_OK");
  if (response.protocol !== "osrs-capture-broker-v4") failures.push("BROKER_PROTOCOL");
  if (response.idempotency_key !== idempotencyKey) failures.push("RESPONSE_IDEMPOTENCY_KEY");
  if (response.explorer_thread_id !== explorerThreadId) {
    failures.push("RESPONSE_EXPLORER_THREAD_ID");
  }
  if (canonicalJson(response.expected_predecessor) !== canonicalJson(expectedPredecessor)) {
    failures.push("RESPONSE_EXPECTED_PREDECESSOR");
  }
  if (canonicalJson(response.accepted_predecessor) !== canonicalJson(expectedPredecessor)) {
    failures.push("RESPONSE_ACCEPTED_PREDECESSOR");
  }
  if (
    response.commit?.sequence !== head.sequence ||
    response.commit?.commit_sha256 !== head.commit_sha256
  ) {
    failures.push("RESPONSE_HEAD");
  }
  if (head.sequence !== expectedPredecessor.sequence + 1) failures.push("HEAD_SEQUENCE");
  if (head.explorer_thread_id !== explorerThreadId) {
    failures.push("HEAD_EXPLORER_THREAD_ID");
  }
  if (commit.sequence !== head.sequence) failures.push("COMMIT_SEQUENCE");
  if (commit.explorer_thread_id !== explorerThreadId) {
    failures.push("COMMIT_EXPLORER_THREAD_ID");
  }
  if (commit.previous_commit_sha256 !== expectedPredecessor.commit_sha256) {
    failures.push("PREDECESSOR_DIGEST");
  }
  if (head.commit_sha256 !== observedCommitSha256) {
    failures.push("HEAD_COMMIT_DIGEST");
  }
  if (commit.broker_protocol?.protocol !== "osrs-capture-broker-v4") {
    failures.push("COMMIT_BROKER_PROTOCOL");
  }
  if (commit.broker_protocol?.idempotency_key !== idempotencyKey) {
    failures.push("COMMIT_IDEMPOTENCY_KEY");
  }
  if (commit.broker_protocol?.explorer_thread_id !== explorerThreadId) {
    failures.push("COMMIT_PROTOCOL_EXPLORER_THREAD_ID");
  }
  if (
    canonicalJson(commit.broker_protocol?.expected_predecessor) !==
    canonicalJson(expectedPredecessor)
  ) {
    failures.push("COMMIT_EXPECTED_PREDECESSOR");
  }
  if (metadata.broker_protocol?.protocol !== "osrs-capture-broker-v4") {
    failures.push("METADATA_BROKER_PROTOCOL");
  }
  if (metadata.broker_protocol?.idempotency_key !== idempotencyKey) {
    failures.push("METADATA_IDEMPOTENCY_KEY");
  }
  if (metadata.explorer_thread_id !== explorerThreadId) {
    failures.push("METADATA_EXPLORER_THREAD_ID");
  }
  if (metadata.broker_protocol?.explorer_thread_id !== explorerThreadId) {
    failures.push("METADATA_PROTOCOL_EXPLORER_THREAD_ID");
  }
  if (
    canonicalJson(metadata.broker_protocol?.expected_predecessor) !==
    canonicalJson(expectedPredecessor)
  ) {
    failures.push("METADATA_EXPECTED_PREDECESSOR");
  }
  if (
    response.request_fingerprint !== commit.broker_protocol?.request_fingerprint ||
    response.request_fingerprint !== metadata.broker_protocol?.request_fingerprint
  ) {
    failures.push("REQUEST_FINGERPRINT");
  }
  return { passed: failures.length === 0, failures };
}

async function verifyBrokerV4AcceptedCommit({
  response,
  headPath,
  expectedPredecessor,
  idempotencyKey,
  explorerThreadId,
  fullDigest
}) {
  const head = await readJson(headPath);
  if (head.sequence !== expectedPredecessor.sequence + 1) {
    throw new Error(`BROKER_V4_ACCEPTED_HEAD_SEQUENCE_MISMATCH:${head.sequence}`);
  }
  const commitBytes = await fs.readFile(head.commit_path);
  const commit = JSON.parse(commitBytes);
  const metadata = await readJson(commit.metadata.path);
  if (commit.full_client.sha256 !== fullDigest) {
    throw new Error("BROKER_V4_ACCEPTED_FRAME_DIGEST_MISMATCH");
  }
  const envelope = verifyBrokerV4Envelope({
    expectedPredecessor,
    idempotencyKey,
    explorerThreadId,
    response,
    head,
    commit,
    metadata,
    observedCommitSha256: sha256(commitBytes)
  });
  if (!envelope.passed) {
    throw new Error(`BROKER_V4_ENVELOPE_FAILED:${envelope.failures.join(",")}`);
  }
  return {
    ok: true,
    protocol: "osrs-capture-broker-v4",
    idempotency_key: idempotencyKey,
    expected_predecessor: expectedPredecessor,
    head,
    commit,
    metadata,
    raw_broker_response: response
  };
}

async function commitThroughBrokerV4({
  request,
  headPath,
  spoolRoot,
  expectedPredecessor,
  idempotencyKey
}) {
  const requestId = `broker-v4-${idempotencyKey}`;
  const requestPath = `${spoolRoot}/requests/${requestId}.json`;
  const responsePath = `${spoolRoot}/responses/${requestId}.json`;
  const currentHead = await readJson(headPath);
  if (
    currentHead.sequence !== expectedPredecessor.sequence ||
    currentHead.commit_sha256 !== expectedPredecessor.commit_sha256
  ) {
    throw new Error("BROKER_PREDECESSOR_CHANGED_BEFORE_REQUEST");
  }
  const enriched = {
    ...request,
    explorer_thread_id: request.explorer_thread_id,
    idempotency_key: idempotencyKey,
    expected_predecessor: {
      sequence: expectedPredecessor.sequence,
      commit_sha256: expectedPredecessor.commit_sha256
    }
  };
  const requestBytes = Buffer.from(`${JSON.stringify(enriched)}\n`);
  const existingPending = await fs.readFile(requestPath).catch(() => null);
  if (existingPending && !existingPending.equals(requestBytes)) {
    throw new Error("BROKER_V4_IDEMPOTENCY_COLLISION_PENDING");
  }
  const priorResponseStat = await fs.stat(responsePath).catch(() => null);
  if (!existingPending) await writeAtomic(requestPath, requestBytes);
  const deadline = Date.now() + 30000;
  let rawResponse = null;
  while (Date.now() < deadline) {
    try {
      const responseStat = await fs.stat(responsePath);
      if (!priorResponseStat || responseStat.mtimeMs > priorResponseStat.mtimeMs) {
        rawResponse = await readJson(responsePath);
        break;
      }
    } catch (error) {
      if (!String(error).includes("ENOENT")) throw error;
    }
    await sleep(50);
  }
  if (!rawResponse) {
    throw new Error("BROKER_V4_RESPONSE_TIMEOUT");
  }
  if (!rawResponse.ok) {
    throw new Error(`BROKER_V4_REJECTED:${rawResponse.error}`);
  }
  return verifyBrokerV4AcceptedCommit({
    response: rawResponse,
    headPath,
    expectedPredecessor,
    idempotencyKey,
    explorerThreadId: request.explorer_thread_id,
    fullDigest: request.full_sha256
  });
}

export async function loadTemplates(config) {
  const contextMenuOpenMap = await buildTemplate(
    config.templates.context_menu_open_map
  );
  const floatingWorldMapItem = await buildTemplate(
    config.templates.floating_world_map_item
  );
  return {
    gielinorClosed: await buildTemplate(config.templates.gielinor_surface_closed),
    ancientClosed: await buildTemplate(config.templates.ancient_cavern_closed),
    surfaceSelectorOpen: await buildTemplate(config.templates.surface_selector_open),
    panelContextMenu: contextMenuOpenMap,
    contextMenuOpenMap,
    floatingWorldMapItem,
    recovery: {
      TRY_AGAIN: await buildTemplate(config.templates.recovery_try_again),
      STEAM_SIGN_IN: await buildTemplate(config.templates.recovery_steam_sign_in),
      CONNECTING: await buildTemplate(config.templates.recovery_connecting),
      CLICK_TO_PLAY: await buildTemplate(config.templates.recovery_click_to_play),
      GAMEPLAY_NO_MAP: await buildTemplate(config.templates.recovery_gameplay_no_map)
    }
  };
}

export async function observe(sky, templates, controller) {
  const appState = await runSerialUiOperation(
    controller,
    "OBSERVE_APP_STATE",
    async () => await sky.get_app_state({ app: "com.jagex.osclient" })
  );
  const jpeg = await fs.readFile(new URL(appState.screenshot.url));
  const png = await sharp(jpeg).png().toBuffer();
  const decoded = await decodeImage(png);
  const observation = {
    ...decoded,
    png,
    jpeg,
    sha256: sha256(png),
    observed_at: new Date().toISOString()
  };
  return { ...observation, axes: classifyDecodedFrame(observation, templates) };
}

async function clickSerial(sky, controller, request) {
  return await runSerialUiOperation(
    controller,
    `CLICK_${request.mouse_button === "right" ? "RIGHT" : "LEFT"}`,
    async () => await sky.click(request)
  );
}

async function dragSerial(sky, controller, request) {
  return await runSerialUiOperation(
    controller,
    "DRAG",
    async () => await sky.drag(request)
  );
}

async function invokeFailureInjection(failureInjector, point, context = {}) {
  if (!failureInjector) return;
  await failureInjector(point, context);
}

function requireFreshMapActionState(observation, {
  allowOverlay = false,
  allowBlack = false,
  label = "MAP_ACTION"
} = {}) {
  const passed =
    observation.axes.connection === "CONNECTED" &&
    observation.axes.map_shell === "FLOATING_MAP_OPEN" &&
    (allowOverlay || observation.axes.overlay === "NONE") &&
    (allowBlack || observation.axes.map_content === "NONBLACK_CONTENT");
  if (!passed) {
    throw new Error(
      `${label}_POSITIVE_MAP_GATE_FAILED:` +
        `${observation.axes.connection}|${observation.axes.map_shell}|` +
        `${observation.axes.overlay}|${observation.axes.map_content}`
    );
  }
}

async function recoverNonblackMapContent({
  sky,
  controller,
  observation,
  templates,
  transitionDelays
}) {
  let current = observation;
  for (let attempt = 0; attempt < 4; attempt += 1) {
    if (current.axes.map_content === "NONBLACK_CONTENT") return current;
    if (
      current.axes.connection !== "CONNECTED" ||
      current.axes.map_shell !== "FLOATING_MAP_OPEN" ||
      current.axes.overlay !== "NONE"
    ) {
      throw new Error(
        "PRECISELY_BLOCKED_MAP_CONTENT_PIVOT_LEFT_POSITIVE_MAP_STATE"
      );
    }
    const direction = attempt % 2 === 0 ? "plus" : "minus";
    const localization = localizeZoomControl(current, templates, direction);
    const beforeDigest = current.sha256;
    await clickSerial(sky, controller, {
      app: "com.jagex.osclient",
      x: localization.click_point.x,
      y: localization.click_point.y
    });
    await sleep(transitionDelays.pivot);
    const next = await observe(sky, templates, controller);
    if (next.sha256 === beforeDigest) {
      throw new Error(
        `PRECISELY_BLOCKED_MAP_CONTENT_PIVOT_STALE_DIGEST:${direction}`
      );
    }
    current = next;
  }
  throw new Error(
    "PRECISELY_BLOCKED_MAP_CONTENT_REMAINED_BLACK_AFTER_FRESH_LOCALIZED_PIVOTS"
  );
}

export async function recoverConnectedMap({
  sky,
  controller,
  initialObservation,
  templates,
  failureInjector = null,
  transitionDelays = {
    connecting: 1200,
    recovery_click: 1800,
    menu_click: 600,
    pivot: 350
  }
}) {
  let current = initialObservation;
  const started = Date.now();
  const events = [];
  while (current.axes.map_shell !== "FLOATING_MAP_OPEN") {
    if (Date.now() - started > 60000) {
      throw new Error(`PRECISELY_BLOCKED_RECOVERY_TIMEOUT:${current.axes.recovery_state}`);
    }
    const state = current.axes.recovery_state;
    if (state === "CONNECTING") {
      await sleep(transitionDelays.connecting);
      const next = await observe(sky, templates, controller);
      events.push({
        at: new Date().toISOString(),
        state,
        fresh_frame_sha256: current.sha256,
        outcome: next.axes.recovery_state || next.axes.map_shell,
        action: "WAIT_FOR_CONNECTING_TRANSITION"
      });
      current = next;
      continue;
    }
    if (state === "CONTEXT_MENU_OPEN_MAP") {
      throw new Error(
        "PRECISELY_BLOCKED_NO_CLICK:CONTEXT_MENU_OPEN_MAP:UNEXPECTED_OR_STALE_INITIAL_MENU"
      );
    }
    const template = templates.recovery?.[state];
    const referenceBox = RECOVERY_REFERENCE_BOXES[state];
    if (!template || !referenceBox) {
      throw new Error(
        `PRECISELY_BLOCKED_NO_CLICK:${state || "UNKNOWN_CREDENTIAL_ACCOUNT_OR_SECURITY_UI"}`
      );
    }
    const verticalOffset = current.height - template.height;
    const localization = locateUniquePatch(
      current,
      template,
      referenceBox,
      {
        left: Math.max(
          0,
          referenceBox.left - MAP_ORB_SEARCH_PADDING.horizontal
        ),
        top: Math.max(
          0,
          referenceBox.top + verticalOffset - MAP_ORB_SEARCH_PADDING.vertical
        ),
        right: Math.min(
          current.width,
          referenceBox.right + MAP_ORB_SEARCH_PADDING.horizontal
        ),
        bottom: Math.min(
          current.height,
          referenceBox.bottom + verticalOffset + MAP_ORB_SEARCH_PADDING.vertical
        )
      },
      state === "GAMEPLAY_NO_MAP" ? "GAMEPLAY_NO_MAP" : `RECOVERY_${state}`
    );
    const beforeDigest = current.sha256;
    await clickSerial(sky, controller, {
      app: "com.jagex.osclient",
      x: localization.click_point.x,
      y: localization.click_point.y,
      ...(state === "GAMEPLAY_NO_MAP" ? { mouse_button: "right" } : {})
    });
    if (state === "GAMEPLAY_NO_MAP") {
      await invokeFailureInjection(failureInjector, "after_right_click", {
        state,
        localization
      });
    }
    await sleep(transitionDelays.recovery_click);
    const next = await observe(sky, templates, controller);
    if (next.sha256 === beforeDigest) {
      throw new Error(
        `PRECISELY_BLOCKED_NO_CLICK:${state}:STALE_DIGEST_AFTER_ACTION`
      );
    }
    const nextState = next.axes.recovery_state || next.axes.map_shell;
    events.push({
      at: new Date().toISOString(),
      state,
      outcome: nextState,
      localization,
      fresh_transition: {
        before_sha256: beforeDigest,
        after_sha256: next.sha256
      }
    });
    if (state === "GAMEPLAY_NO_MAP") {
      if (
        next.axes.connection !== "CONNECTED" ||
        next.axes.map_shell === "FLOATING_MAP_OPEN" ||
        next.axes.overlay !== "CONTEXT_MENU_OPEN_MAP" ||
        next.axes.recovery_state !== "CONTEXT_MENU_OPEN_MAP"
      ) {
        throw new Error(
          "PRECISELY_BLOCKED_NO_CLICK:CONTEXT_MENU_OPEN_MAP:ABSENT_OR_AMBIGUOUS"
        );
      }
      const item = locateUniquePatch(
        next,
        templates.floatingWorldMapItem,
        RECOVERY_REFERENCE_BOXES.CONTEXT_MENU_OPEN_MAP,
        MAP_OPEN_MENU_SEARCH_REGION,
        "CONTEXT_MENU_OPEN_MAP"
      );
      const menuDigest = next.sha256;
      await clickSerial(sky, controller, {
        app: "com.jagex.osclient",
        x: item.click_point.x,
        y: item.click_point.y
      });
      await invokeFailureInjection(failureInjector, "after_menu_click", {
        state: "CONTEXT_MENU_OPEN_MAP",
        localization: item
      });
      await sleep(transitionDelays.menu_click);
      let opened = await observe(sky, templates, controller);
      if (opened.sha256 === menuDigest) {
        throw new Error(
          "PRECISELY_BLOCKED_MAP_OPEN_TRANSITION:STALE_DIGEST_AFTER_ITEM_CLICK"
        );
      }
      if (
        opened.axes.connection !== "CONNECTED" ||
        opened.axes.map_shell !== "FLOATING_MAP_OPEN" ||
        opened.axes.overlay !== "NONE"
      ) {
        throw new Error(
          "PRECISELY_BLOCKED_MAP_OPEN_TRANSITION:POSITIVE_READBACK_FAILED"
        );
      }
      events.push({
        at: new Date().toISOString(),
        state: "CONTEXT_MENU_OPEN_MAP",
        outcome:
          opened.axes.map_content === "NONBLACK_CONTENT"
            ? "MAP_OPEN_CONTENT"
            : "OVERLAY_NONE_MAP_OPEN_BLACK",
        localization: item,
        fresh_transition: {
          before_sha256: menuDigest,
          after_sha256: opened.sha256
        }
      });
      if (opened.axes.map_content !== "NONBLACK_CONTENT") {
        opened = await recoverNonblackMapContent({
          sky,
          controller,
          observation: opened,
          templates,
          transitionDelays
        });
      }
      if (
        opened.axes.connection !== "CONNECTED" ||
        opened.axes.map_shell !== "FLOATING_MAP_OPEN" ||
        opened.axes.overlay !== "NONE" ||
        opened.axes.map_content !== "NONBLACK_CONTENT"
      ) {
        throw new Error(
          "PRECISELY_BLOCKED_MAP_OPEN_TRANSITION:NONBLACK_CONTENT_NOT_PROVEN"
        );
      }
      current = opened;
      continue;
    }
    if (nextState === state) {
      throw new Error(
        `PRECISELY_BLOCKED_NO_CLICK:${state}:FAILED_TRANSITION_NO_REPEAT`
      );
    }
    current = next;
  }
  return { observation: current, events };
}

export function localizeSelector(observation, templates) {
  return locateUniquePatch(
    observation,
    templates.gielinorClosed,
    { left: 340, top: 650, right: 359, bottom: 670 },
    { left: 315, top: 630, right: 385, bottom: 690 },
    "SURFACE_SELECTOR_CONTROL",
    1
  );
}

function surfaceReadbackScore(observation, template, selectorLocalization) {
  const referenceBox = { left: 180, top: 651, right: 332, bottom: 669 };
  const candidateLeft = selectorLocalization.observed_bbox.left - 160;
  const candidateTop = selectorLocalization.observed_bbox.top + 1;
  return patchDifference(
    observation,
    template,
    referenceBox,
    candidateLeft,
    candidateTop
  );
}

export function readObservedSurface(observation, templates) {
  let selectorLocalization;
  try {
    selectorLocalization = localizeSelector(observation, templates);
  } catch (error) {
    return {
      surface: null,
      scores: {},
      fresh_frame_sha256: observation.sha256,
      selector_localization_error: String(error),
      exact_match: false
    };
  }
  const scores = {
    "Gielinor Surface": surfaceReadbackScore(
      observation,
      templates.gielinorClosed,
      selectorLocalization
    ),
    "Ancient Cavern": surfaceReadbackScore(
      observation,
      templates.ancientClosed,
      selectorLocalization
    )
  };
  const ordered = Object.entries(scores).sort((first, second) => first[1] - second[1]);
  const [surface, score] = ordered[0];
  const next = ordered[1]?.[1] ?? Number.POSITIVE_INFINITY;
  return {
    surface: score < 30 && next - score > 1 ? surface : null,
    scores,
    fresh_frame_sha256: observation.sha256,
    selector_localization: selectorLocalization,
    readback_box: {
      left: selectorLocalization.observed_bbox.left - 160,
      top: selectorLocalization.observed_bbox.top + 1,
      right: selectorLocalization.observed_bbox.left - 8,
      bottom: selectorLocalization.observed_bbox.top + 19
    },
    exact_match: score < 30 && next - score > 1
  };
}

export function localizeZoomControl(observation, templates, direction) {
  const cluster = locateUniquePatch(
    observation,
    templates.gielinorClosed,
    { left: 397, top: 644, right: 482, bottom: 676 },
    { left: 370, top: 620, right: 510, bottom: 700 },
    "ZOOM_CONTROL_CLUSTER",
    1
  );
  const offsets =
    direction === "minus"
      ? { left: 7, top: 4, right: 41, bottom: 28 }
      : { left: 43, top: 4, right: 81, bottom: 28 };
  const observedBox = {
    left: cluster.observed_bbox.left + offsets.left,
    top: cluster.observed_bbox.top + offsets.top,
    right: cluster.observed_bbox.left + offsets.right,
    bottom: cluster.observed_bbox.top + offsets.bottom
  };
  const clickPoint = {
    x: Math.floor((observedBox.left + observedBox.right) / 2),
    y: Math.floor((observedBox.top + observedBox.bottom) / 2)
  };
  if (
    !(
      clickPoint.x > observedBox.left &&
      clickPoint.x < observedBox.right &&
      clickPoint.y > observedBox.top &&
      clickPoint.y < observedBox.bottom
    )
  ) {
    throw new Error(`PRECISELY_BLOCKED_NO_CLICK:ZOOM_${direction.toUpperCase()}:POINT_OUTSIDE`);
  }
  return {
    target: `ZOOM_${direction.toUpperCase()}`,
    fresh_frame_sha256: observation.sha256,
    frame_geometry: { width: observation.width, height: observation.height },
    cluster_localization: cluster,
    observed_bbox: observedBox,
    click_point: clickPoint,
    exactly_one_target: true,
    click_point_inside_observed_bounds: true,
    localized_at: new Date().toISOString()
  };
}

export function evaluateAxisCommitGate({
  axes,
  requestedSurface,
  observedSurface,
  requestedZoom,
  observedZoom
}) {
  const failures = [];
  if (axes.connection !== "CONNECTED") failures.push("CONNECTION");
  if (axes.map_shell !== "FLOATING_MAP_OPEN") failures.push("MAP_SHELL");
  if (axes.overlay !== "NONE") failures.push("OVERLAY");
  if (axes.map_content !== "NONBLACK_CONTENT") failures.push("MAP_CONTENT");
  if (observedSurface !== requestedSurface) failures.push("SURFACE");
  if (!ZOOM_LADDER.includes(observedZoom)) failures.push("NONCANONICAL_ZOOM");
  if (observedZoom !== requestedZoom) failures.push("ZOOM");
  return { passed: failures.length === 0, failures };
}

async function ensureOverlayNone({ sky, controller, observation, templates }) {
  if (observation.axes.overlay === "NONE") return observation;
  if (observation.axes.overlay === "PANEL_CONTEXT_MENU") {
    requireFreshMapActionState(observation, {
      allowOverlay: true,
      allowBlack: true,
      label: "CONTEXT_MENU_CANCEL"
    });
    const cancel = locateUniquePatch(
      observation,
      templates.panelContextMenu,
      { left: 634, top: 197, right: 705, bottom: 214 },
      { left: 610, top: 175, right: 740, bottom: 240 },
      "PANEL_CONTEXT_MENU_CANCEL"
    );
    await clickSerial(sky, controller, {
      app: "com.jagex.osclient",
      x: cancel.click_point.x,
      y: cancel.click_point.y
    });
    await sleep(300);
    const after = await observe(sky, templates, controller);
    if (after.axes.overlay !== "NONE") throw new Error("OVERLAY_CANCEL_FAILED");
    return after;
  }
  if (observation.axes.overlay === "SURFACE_SELECTOR") {
    requireFreshMapActionState(observation, {
      allowOverlay: true,
      allowBlack: true,
      label: "SURFACE_SELECTOR_CLOSE"
    });
    const selector = localizeSelector(observation, templates);
    await clickSerial(sky, controller, {
      app: "com.jagex.osclient",
      x: selector.click_point.x,
      y: selector.click_point.y
    });
    await sleep(250);
    const after = await observe(sky, templates, controller);
    if (after.axes.overlay !== "NONE") throw new Error("SELECTOR_CLOSE_FAILED");
    return after;
  }
  throw new Error(`PRECISELY_BLOCKED_OVERLAY:${observation.axes.overlay}`);
}

async function ensureSurface({
  sky,
  controller,
  observation,
  templates,
  config,
  requestedSurface
}) {
  let current = await ensureOverlayNone({
    sky,
    controller,
    observation,
    templates
  });
  requireFreshMapActionState(current, {
    allowBlack: true,
    label: "SURFACE_SELECTOR_OPEN"
  });
  const beforeReadback = readObservedSurface(current, templates);
  if (
    beforeReadback.surface === requestedSurface &&
    current.axes.map_content === "NONBLACK_CONTENT"
  ) {
    return {
      observation: current,
      proof: {
        requested_surface: requestedSurface,
        delivered: true,
        action_required: false,
        readback: beforeReadback
      }
    };
  }
  const selector = localizeSelector(current, templates);
  await clickSerial(sky, controller, {
    app: "com.jagex.osclient",
    x: selector.click_point.x,
    y: selector.click_point.y
  });
  await sleep(300);
  const opened = await observe(sky, templates, controller);
  if (opened.axes.overlay !== "SURFACE_SELECTOR") {
    throw new Error("SURFACE_SELECTOR_DID_NOT_OPEN");
  }
  requireFreshMapActionState(opened, {
    allowOverlay: true,
    allowBlack: true,
    label: "SURFACE_OPTION_SELECT"
  });
  const optionConfig = config.surface_options[requestedSurface];
  if (!optionConfig) throw new Error(`SURFACE_OPTION_UNSUPPORTED:${requestedSurface}`);
  const option = locateUniquePatch(
    opened,
    templates.surfaceSelectorOpen,
    optionConfig.reference_box,
    { left: 150, top: 500, right: 380, bottom: 700 },
    `SURFACE_OPTION:${requestedSurface}`
  );
  await clickSerial(sky, controller, {
    app: "com.jagex.osclient",
    x: option.click_point.x,
    y: option.click_point.y
  });
  await sleep(500);
  const after = await observe(sky, templates, controller);
  const readback = readObservedSurface(after, templates);
  if (
    after.axes.overlay !== "NONE" ||
    after.axes.map_content !== "NONBLACK_CONTENT" ||
    readback.surface !== requestedSurface
  ) {
    return {
      observation: after,
      proof: {
        requested_surface: requestedSurface,
        delivered: false,
        selector_localization: selector,
        option_localization: option,
        readback
      }
    };
  }
  return {
    observation: after,
    proof: {
      requested_surface: requestedSurface,
      delivered: true,
      action_required: true,
      selector_localization: selector,
      option_localization: option,
      readback
    }
  };
}

async function clickZoomAndMeasure({
  sky,
  controller,
  observation,
  templates,
  direction,
  contentCrop
}) {
  requireFreshMapActionState(observation, { label: `ZOOM_${direction.toUpperCase()}` });
  const localization = localizeZoomControl(observation, templates, direction);
  const preContent = await cropRaw(observation.png, contentCrop);
  await clickSerial(sky, controller, {
    app: "com.jagex.osclient",
    x: localization.click_point.x,
    y: localization.click_point.y
  });
  await sleep(350);
  const after = await observe(sky, templates, controller);
  if (after.axes.overlay !== "NONE" || after.axes.map_shell !== "FLOATING_MAP_OPEN") {
    throw new Error(`ZOOM_ACTION_LEFT_MAP_STATE:${after.axes.overlay}`);
  }
  const postContent = await cropRaw(after.png, contentCrop);
  const transition = meanDifference(preContent, postContent);
  return {
    observation: after,
    transitioned: transition >= 1.25,
    proof: {
      direction,
      localization,
      pre_frame_sha256: observation.sha256,
      post_frame_sha256: after.sha256,
      pre_content_sha256: sha256(preContent),
      post_content_sha256: sha256(postContent),
      content_transition_mean_abs: transition,
      delivered_scale_transition: transition >= 1.25
    }
  };
}

async function ensureZoom({
  sky,
  controller,
  observation,
  templates,
  requestedZoom,
  contentCrop
}) {
  if (!ZOOM_LADDER.includes(requestedZoom)) throw new Error(`NONCANONICAL_ZOOM:${requestedZoom}`);
  let current = observation;
  const actions = [];
  let consecutiveNoChange = 0;
  for (let index = 0; index < 8 && consecutiveNoChange < 2; index += 1) {
    const step = await clickZoomAndMeasure({
      sky,
      controller,
      observation: current,
      templates,
      direction: "minus",
      contentCrop
    });
    actions.push(step.proof);
    current = step.observation;
    consecutiveNoChange = step.transitioned ? 0 : consecutiveNoChange + 1;
  }
  if (consecutiveNoChange < 2) {
    throw new Error("ZOOM_MINIMUM_NOT_POSITIVELY_ESTABLISHED");
  }
  let observedIndex = 0;
  const requestedIndex = ZOOM_LADDER.indexOf(requestedZoom);
  while (observedIndex < requestedIndex) {
    const step = await clickZoomAndMeasure({
      sky,
      controller,
      observation: current,
      templates,
      direction: "plus",
      contentCrop
    });
    actions.push(step.proof);
    if (!step.transitioned) throw new Error("ZOOM_LADDER_TRANSITION_NOT_DELIVERED");
    current = step.observation;
    observedIndex += 1;
  }
  return {
    observation: current,
    proof: {
      requested_zoom: requestedZoom,
      observed_zoom: ZOOM_LADDER[observedIndex],
      delivered: ZOOM_LADDER[observedIndex] === requestedZoom,
      base_calibration: "two consecutive freshly localized minus actions with no content-scale transition establish 37.5 percent",
      canonical_ladder: ZOOM_LADDER,
      actions,
      final_frame_sha256: current.sha256
    }
  };
}

function directionForCriterion(criterion) {
  const directions = {
    eastward_topology: { from: [430, 300], to: [90, 300] },
    southward_topology: { from: [260, 560], to: [260, 150] },
    westward_boundary: { from: [90, 300], to: [430, 300] },
    northward_detail: { from: [260, 150], to: [260, 560] },
    center_detail: { from: [420, 520], to: [150, 210] }
  };
  return directions[criterion] || directions.eastward_topology;
}

async function priorSameFamilyRaw(item, contentCrop) {
  if (!item.last_same_family_map_crop_path) return null;
  try {
    const mapCrop = await fs.readFile(item.last_same_family_map_crop_path);
    return (
      await sharp(mapCrop)
        .extract({
          left: contentCrop.left - MAP_CHROME_CROP.left,
          top: contentCrop.top - MAP_CHROME_CROP.top,
          width: contentCrop.width,
          height: contentCrop.height
        })
        .removeAlpha()
        .raw()
        .toBuffer({ resolveWithObject: true })
    ).data;
  } catch {
    return null;
  }
}

function nextPendingItem(worklist) {
  const count = worklist.items.length;
  for (let offset = 0; offset < count; offset += 1) {
    const index = (worklist.cursor + offset) % count;
    if (worklist.items[index].state === "PENDING") return { item: worklist.items[index], index };
  }
  return null;
}

function snapshotWorklist(worklist) {
  return JSON.parse(JSON.stringify(worklist));
}

export async function prepareFrameCommit({
  config,
  worklist,
  item,
  observation,
  preObservation,
  novelty,
  surfaceProof,
  zoomProof,
  head,
  frameNumber,
  leaseIdentity,
  explorerThreadId,
  sourceVersion,
  explorerGenerationId,
  sourcePath,
  sourceSha256,
  configPath,
  configSha256,
  worklistPath,
  worklistSha256,
  firstCommit,
  cutoverBinding,
  rolloverAfterCommit
}) {
  const stageRoot = config.paths.stage_root;
  const batchRoot = config.paths.batch_root;
  const mapCrop = await sharp(observation.png).extract(MAP_CHROME_CROP).png().toBuffer();
  const contentRaw = await cropRaw(observation.png, config.novelty.content_crop);
  const fullDigest = sha256(observation.png);
  const cropDigest = sha256(mapCrop);
  const contentDigest = sha256(contentRaw);
  const criterionFamilyKey = `${item.surface}|${item.zoom}|${item.criterion_family}`;
  const idempotencyKey = deriveIdempotencyKey({
    predecessor: head,
    frameDigest: fullDigest,
    criterionFamilyKey,
    explorerThreadId
  });
  const capturedAt = observation.observed_at;
  const paddedFrame = String(frameNumber).padStart(4, "0");
  const slug = item.surface.toLowerCase().replace(/[^a-z0-9]+/g, "_").replace(/^_|_$/g, "");
  const base =
    `${paddedFrame}_${slug}_z${String(item.zoom).replace(".", "_")}_v4gen4_` +
    `${item.criterion_family}_${idempotencyKey.slice(0, 10)}_settled`;
  const fullStage = `${stageRoot}/${base}-full.png`;
  const cropStage = `${stageRoot}/${base}-map.png`;
  await writeOrVerifyImmutableStage(fullStage, observation.png);
  await writeOrVerifyImmutableStage(cropStage, mapCrop);
  const fullDestination = `${batchRoot}/raw/full-client/${base}.png`;
  const cropDestination = `${batchRoot}/raw/map-crops/${base}_map.png`;
  const metadataDestination = `${batchRoot}/meta/${base}.json`;
  const gestureId = `${leaseIdentity}-${idempotencyKey.slice(0, 16)}`;
  const expectedNextSequence = head.sequence + 1;
  const metadata = {
    schema: "osrs-map-capture-runtime-v4-corrections-005-012",
    source_version: sourceVersion,
    explorer_generation_id: explorerGenerationId,
    lease_identity: leaseIdentity,
    explorer_thread_id: explorerThreadId,
    captured_at: capturedAt,
    surface: item.surface,
    true_zoom_percent: item.zoom,
    observed_axes: {
      connection: observation.axes.connection,
      map_shell: observation.axes.map_shell,
      overlay: observation.axes.overlay,
      map_content: observation.axes.map_content,
      action_in_flight: false
    },
    surface_readback_proof: surfaceProof,
    canonical_zoom_readback_proof: zoomProof,
    novelty_proof: {
      ...novelty,
      pre_gesture_content_sha256: sha256(
        await cropRaw(preObservation.png, config.novelty.content_crop)
      ),
      post_gesture_content_sha256: contentDigest,
      same_family_baseline_content_sha256: item.last_same_family_content_digest,
      same_family_baseline_map_crop_path: item.last_same_family_map_crop_path
    },
    full_client: {
      path: fullDestination,
      sha256: fullDigest,
      bytes: observation.png.length
    },
    map_crop: {
      path: cropDestination,
      sha256: cropDigest,
      bytes: mapCrop.length,
      crop: MAP_CHROME_CROP
    },
    broker_continuity: {
      protocol: config.broker.protocol,
      idempotency_key: idempotencyKey,
      expected_predecessor: {
        sequence: head.sequence,
        commit_sha256: head.commit_sha256
      },
      expected_accepted_sequence: expectedNextSequence,
      broker_implementation_sha256: config.broker.implementation_sha256,
      journal_helper_sha256: config.broker.journal_helper_sha256
    },
    worklist_before_commit: snapshotWorklist(worklist),
    work_item: JSON.parse(JSON.stringify(item)),
    correction_activation: firstCommit
      ? {
          corrections: Object.fromEntries(
            Object.entries(config.policy_records).map(([key, value]) => [key, value.sha256])
          ),
          exact_predecessor: cutoverBinding,
          source: { path: sourcePath, sha256: sourceSha256 },
          config: { path: configPath, sha256: configSha256 },
          worklist: { path: worklistPath, sha256: worklistSha256 },
          supervisor_identity: leaseIdentity
        }
      : null,
    rollover_checkpoint: rolloverAfterCommit
      ? {
          status: "ROLLOVER_READY",
          no_action_in_flight: true,
          terminal_predecessor_expected_sequence: expectedNextSequence,
          worklist_cursor_after_commit: (worklist.cursor + 1) % worklist.items.length,
          no_background_promise_after_return: true
        }
      : null,
    requirement_id: "V4_CORRECTIONS_005_006_007_008_009_010_011_012_COVERAGE",
    criterion_family_key: criterionFamilyKey,
    black_frame: false,
    immutable: true
  };
  return {
    request: {
      op: "commit",
      explorer_thread_id: explorerThreadId,
      full_stage: fullStage,
      crop_stage: cropStage,
      full_dest: fullDestination,
      crop_dest: cropDestination,
      meta_dest: metadataDestination,
      full_sha256: fullDigest,
      crop_sha256: cropDigest,
      metadata,
      captured_at: capturedAt,
      surface: item.surface,
      zoom: item.zoom,
      gesture_id: gestureId,
      requirement_id: metadata.requirement_id,
      criterion_family_key: criterionFamilyKey
    },
    idempotencyKey,
    fullDigest,
    cropDestination,
    contentDigest,
    metadataDestination
  };
}

async function persistRolloverCheckpoint({
  config,
  leaseIdentity,
  head,
  worklist,
  controller,
  monotonicStarted,
  sourceVersion,
  explorerGenerationId,
  packageBinding
}) {
  const checkpoint = {
    schema: "osrs-map-capture-runtime-v4-bounded-rollover-v1",
    source_version: sourceVersion,
    explorer_generation_id: explorerGenerationId,
    package_binding: packageBinding,
    status: "ROLLOVER_READY",
    lease_identity: leaseIdentity,
    terminal_journal_sequence: head.sequence,
    terminal_commit_sha256: head.commit_sha256,
    worklist,
    worklist_cursor: worklist.cursor,
    no_action_in_flight: true,
    no_background_promise_after_return: true,
    elapsed_ms: performance.now() - monotonicStarted,
    created_at: new Date().toISOString()
  };
  const bytes = Buffer.from(`${canonicalJson(checkpoint)}\n`);
  const digest = sha256(bytes);
  const destination =
    `${config.paths.stage_root}/ROLLOVER_READY-${leaseIdentity}-` +
    `${String(head.sequence).padStart(6, "0")}-${digest.slice(0, 12)}.json`;
  await writeOrVerifyImmutableStage(destination, bytes);
  return { checkpoint, path: destination, sha256: digest };
}

export function assertRuntimeIdentityBinding({
  config,
  manifest,
  activation,
  packageBinding
}) {
  const identity = EMBEDDED_RUNTIME_IDENTITY;
  if (
    config?.source_version !== identity.source_version ||
    manifest?.source_version !== identity.source_version ||
    activation?.source_version !== identity.source_version ||
    config?.explorer_generation_id !== identity.explorer_generation_id ||
    manifest?.explorer_generation_id !== identity.explorer_generation_id ||
    activation?.explorer_generation_id !== identity.explorer_generation_id
  ) {
    throw new Error("EMBEDDED_CONFIG_MANIFEST_ACTIVATION_IDENTITY_MISMATCH");
  }
  if (
    packageBinding?.package_root !== config.paths?.package_root ||
    packageBinding?.record_type !==
      "EXPLORER_V4_IMMUTABLE_PACKAGE_BINDING"
  ) {
    throw new Error("RUNTIME_IMMUTABLE_PACKAGE_BINDING_MISMATCH");
  }
  return { ...identity };
}

export async function runLease(options) {
  const claimAcceptedAt = options.claimAcceptedAt;
  if (!Number.isFinite(claimAcceptedAt)) {
    throw new Error("DURABLE_CLAIM_ACCEPTED_AT_REQUIRED");
  }
  const startedWall = claimAcceptedAt;
  const monotonicStarted = performance.now();
  const configBytes = await fs.readFile(options.configPath);
  const sourceBytes = await fs.readFile(options.sourcePath);
  const worklistBytes = await fs.readFile(options.worklistPath);
  if (sha256(configBytes) !== options.configSha256) throw new Error("CONFIG_DIGEST_MISMATCH");
  if (sha256(sourceBytes) !== options.sourceSha256) throw new Error("SOURCE_DIGEST_MISMATCH");
  if (sha256(worklistBytes) !== options.worklistSha256) throw new Error("WORKLIST_DIGEST_MISMATCH");
  const config = JSON.parse(configBytes);
  const boundIdentity = assertRuntimeIdentityBinding({
    config,
    manifest: {
      source_version: options.sourceVersion,
      explorer_generation_id: options.explorerGenerationId
    },
    activation: options.cutoverBinding?.runtime_identity,
    packageBinding: options.packageBinding
  });
  if (
    options.packageBinding?.expected?.source !== options.sourceSha256 ||
    options.packageBinding?.expected?.config !== options.configSha256 ||
    options.packageBinding?.expected?.worklist !== options.worklistSha256 ||
    options.packageBinding?.expected?.launcher !== options.launcherSha256 ||
    options.packageBinding?.expected?.package_manifest !==
      options.runtimePackageSha256 ||
    options.launcherPath !== `${config.paths.package_root}/src/explorer-v4-launch.mjs` ||
    options.runtimePackagePath !==
      `${config.paths.package_root}/EXPLORER_V4_RUNTIME_PACKAGE.json`
  ) {
    throw new Error("RUNTIME_PACKAGE_DIGEST_PROPAGATION_MISMATCH");
  }
  if (
    options.firstUsefulCommitDeadlineAt !==
    claimAcceptedAt + config.successor_first_commit_deadline_ms
  ) {
    throw new Error("FIRST_USEFUL_COMMIT_DEADLINE_ORIGIN_MISMATCH");
  }
  if (!options.explorerThreadId) throw new Error("EXPLORER_THREAD_BINDING_REQUIRED");
  const leaseIdentity =
    `${config.run_family}-lease-${String(options.leaseNumber).padStart(4, "0")}`;
  const controller = createLeaseController({
    identity: leaseIdentity,
    explorerThreadId: options.explorerThreadId,
    expectedPredecessor: options.expectedPredecessor,
    controllerGlobalName: config.controller_global_name,
    sourceVersion: boundIdentity.source_version,
    explorerGeneration: boundIdentity.explorer_generation_id,
    lifecycleToken: options.lifecycleToken,
    finalizerReservation: options.finalizerReservation,
    finalizerBinding: options.finalizerBinding
  });
  const previousLifecycle = ACTIVE_LIFECYCLE;
  ACTIVE_LIFECYCLE = options.lifecycleToken || null;
  try {
  return await withControllerTerminalizer({
    controller,
    statusRoot: config.paths.status_root,
    body: async () => {
  if (
    !Number.isFinite(options.successorLaunchStartedAt) ||
    options.successorLaunchStartedAt >
      claimAcceptedAt + config.successor_launch_deadline_ms
  ) {
    throw new Error("SUCCESSOR_LAUNCH_MISSED_15_SECOND_DEADLINE");
  }
  for (const [name, record] of Object.entries(config.policy_records)) {
    const bytes = await fs.readFile(record.path);
    if (sha256(bytes) !== record.sha256) throw new Error(`POLICY_DIGEST_MISMATCH:${name}`);
  }
  const brokerSource = await fs.readFile(config.broker.implementation_path);
  if (sha256(brokerSource) !== config.broker.implementation_sha256) {
    throw new Error("BROKER_IMPLEMENTATION_DIGEST_MISMATCH");
  }
  const journalHelper = await fs.readFile(config.broker.journal_helper_path);
  if (sha256(journalHelper) !== config.broker.journal_helper_sha256) {
    throw new Error("BROKER_JOURNAL_HELPER_DIGEST_MISMATCH");
  }
  const capabilityManifest = await fs.readFile(config.broker.capability_manifest_path);
  if (sha256(capabilityManifest) !== config.broker.capability_manifest_sha256) {
    throw new Error("BROKER_CAPABILITY_MANIFEST_DIGEST_MISMATCH");
  }
  const packageChecksums = await fs.readFile(config.broker.sha256sums_path);
  if (sha256(packageChecksums) !== config.broker.sha256sums_sha256) {
    throw new Error("BROKER_PACKAGE_SHA256SUMS_DIGEST_MISMATCH");
  }
  const templates = await loadTemplates(config);
  const worklist = options.rolloverCheckpoint?.worklist
    ? JSON.parse(JSON.stringify(options.rolloverCheckpoint.worklist))
    : JSON.parse(worklistBytes);
  const headPath = `${config.paths.journal_root}/HEAD.json`;
  let head = await readJson(headPath);
  if (
    head.sequence !== options.expectedPredecessor.sequence ||
    head.commit_sha256 !== options.expectedPredecessor.commit_sha256
  ) {
    throw new Error("LEASE_START_PREDECESSOR_MISMATCH");
  }
  const startingCommit = await readJson(head.commit_path);
  const startingMetadata = await readJson(startingCommit.metadata.path);
  let frameNumber = Number(startingMetadata.sequence || head.sequence) + 1;
  let accepted = 0;
  let lastAcceptedAt = Date.now();
  controller.starting_head = JSON.parse(JSON.stringify(head));
  controller.last_journal_head = JSON.parse(JSON.stringify(head));
  controller.worklist_cursor = worklist.cursor;
  const firstCommitDeadline = startedWall + config.successor_first_commit_deadline_ms;

  while (performance.now() - monotonicStarted < config.hard_rollover_maximum_ms) {
    const elapsed = performance.now() - monotonicStarted;
    if (elapsed >= config.self_rollover_target_ms - 2000) {
      const durableRollover = await persistRolloverCheckpoint({
        config,
        leaseIdentity,
        head,
        worklist,
        controller,
        monotonicStarted,
        sourceVersion: boundIdentity.source_version,
        explorerGenerationId: boundIdentity.explorer_generation_id,
        packageBinding: options.packageBinding
      });
      return {
        ...durableRollover.checkpoint,
        checkpoint_path: durableRollover.path,
        checkpoint_sha256: durableRollover.sha256
      };
    }
    const usefulGapMs = Date.now() - lastAcceptedAt;
    if (usefulGapMs >= config.scheduler.actionable_seconds_without_useful_commit * 1000) {
      throw new Error(`ACTIONABLE_GAP_FOUND:${usefulGapMs}`);
    }
    const selected = nextPendingItem(worklist);
    if (!selected) {
      return {
        status: "PRECISELY_BLOCKED_NO_PENDING_FAMILY",
        lease_identity: leaseIdentity,
        terminal_head: head,
        worklist,
        no_background_promise_after_return: true
      };
    }
    const { item, index } = selected;
    item.attempts += 1;
    let observation = await observe(options.sky, templates, controller);
    await invokeFailureInjection(options.failureInjector, "after_observation", {
      observation
    });
    if (observation.axes.map_shell !== "FLOATING_MAP_OPEN") {
      const recovered = await recoverConnectedMap({
        sky: options.sky,
        controller,
        initialObservation: observation,
        templates,
        failureInjector: options.failureInjector
      });
      observation = recovered.observation;
      controller.recovery_events = recovered.events;
    }
    observation = await ensureOverlayNone({
      sky: options.sky,
      controller,
      observation,
      templates
    });
    const surface = await ensureSurface({
      sky: options.sky,
      controller,
      observation,
      templates,
      config,
      requestedSurface: item.surface
    });
    if (!surface.proof.delivered) {
      item.state = "DEFERRED";
      item.defer_reason = "SURFACE_READBACK_FAILED";
      item.next_eligible_condition = "fresh exact selector localization and closed-label readback";
      worklist.cursor = (index + 1) % worklist.items.length;
      continue;
    }
    const zoom = await ensureZoom({
      sky: options.sky,
      controller,
      observation: surface.observation,
      templates,
      requestedZoom: item.zoom,
      contentCrop: config.novelty.content_crop
    });
    if (!zoom.proof.delivered || zoom.proof.observed_zoom !== item.zoom) {
      item.state = "DEFERRED";
      item.defer_reason = "CANONICAL_ZOOM_READBACK_FAILED";
      item.next_eligible_condition = "fresh localized control calibration reaches requested canonical zoom";
      worklist.cursor = (index + 1) % worklist.items.length;
      continue;
    }
    const pre = await observe(options.sky, templates, controller);
    const preSurface = readObservedSurface(pre, templates);
    const preAxisGate = evaluateAxisCommitGate({
      axes: pre.axes,
      requestedSurface: item.surface,
      observedSurface: preSurface.surface,
      requestedZoom: item.zoom,
      observedZoom: zoom.proof.observed_zoom
    });
    if (!pre.axes.committable || !preAxisGate.passed) {
      item.state = "DEFERRED";
      item.defer_reason = "PRE_GESTURE_AXIS_GATE_FAILED";
      worklist.cursor = (index + 1) % worklist.items.length;
      continue;
    }
    const direction = directionForCriterion(item.criterion_family);
    await dragSerial(options.sky, controller, {
      app: "com.jagex.osclient",
      from_x: direction.from[0],
      from_y: direction.from[1],
      to_x: direction.to[0],
      to_y: direction.to[1]
    });
    await sleep(900);
    let post = await observe(options.sky, templates, controller);
    let postSurface = readObservedSurface(post, templates);
    const postAxisGate = evaluateAxisCommitGate({
      axes: post.axes,
      requestedSurface: item.surface,
      observedSurface: postSurface.surface,
      requestedZoom: item.zoom,
      observedZoom: zoom.proof.observed_zoom
    });
    if (!post.axes.committable || !postAxisGate.passed) {
      item.defer_reason = "POST_GESTURE_AXIS_GATE_FAILED";
      worklist.cursor = (index + 1) % worklist.items.length;
      continue;
    }
    requireFreshMapActionState(post, { label: "POST_GESTURE_GATE" });
    const commitFresh = await observe(options.sky, templates, controller);
    const commitFreshSurface = readObservedSurface(commitFresh, templates);
    const commitAxisGate = evaluateAxisCommitGate({
      axes: commitFresh.axes,
      requestedSurface: item.surface,
      observedSurface: commitFreshSurface.surface,
      requestedZoom: item.zoom,
      observedZoom: zoom.proof.observed_zoom
    });
    if (!commitFresh.axes.committable || !commitAxisGate.passed) {
      item.defer_reason = "FRESH_PRECOMMIT_AXIS_GATE_FAILED";
      worklist.cursor = (index + 1) % worklist.items.length;
      continue;
    }
    post = commitFresh;
    postSurface = commitFreshSurface;
    const preRaw = await cropRaw(pre.png, config.novelty.content_crop);
    const postRaw = await cropRaw(post.png, config.novelty.content_crop);
    const sameFamilyRaw = await priorSameFamilyRaw(item, config.novelty.content_crop);
    const novelty = evaluateNovelty({
      preRaw,
      postRaw,
      sameFamilyRaw,
      width: config.novelty.content_crop.width,
      height: config.novelty.content_crop.height,
      thresholds: config.novelty
    });
    if (!novelty.passed) {
      item.defer_reason = "CONTENT_NOVELTY_GATE_FAILED";
      if (item.attempts >= config.scheduler.maximum_black_or_noop_outcomes_per_family) {
        item.state = "DEFERRED";
        item.next_eligible_condition = "independent center or repair directive";
      }
      worklist.cursor = (index + 1) % worklist.items.length;
      continue;
    }
    if (accepted === 0 && Date.now() >= firstCommitDeadline) {
      throw new Error("SUCCESSOR_FIRST_COMMIT_CANNOT_MEET_ACTIONABLE_DEADLINE");
    }
    const rolloverAfterCommit =
      performance.now() - monotonicStarted >= config.self_rollover_target_ms - 2000;
    const prepared = await prepareFrameCommit({
      config,
      worklist,
      item,
      observation: post,
      preObservation: pre,
      novelty,
      surfaceProof: {
        requested_surface: item.surface,
        delivery: surface.proof,
        final_fresh_readback: postSurface
      },
      zoomProof: zoom.proof,
      head,
      frameNumber,
      leaseIdentity,
      explorerThreadId: options.explorerThreadId,
      sourceVersion: boundIdentity.source_version,
      explorerGenerationId: boundIdentity.explorer_generation_id,
      sourcePath: options.sourcePath,
      sourceSha256: options.sourceSha256,
      configPath: options.configPath,
      configSha256: options.configSha256,
      worklistPath: options.worklistPath,
      worklistSha256: options.worklistSha256,
      firstCommit: accepted === 0,
      cutoverBinding: options.cutoverBinding,
      rolloverAfterCommit
    });
    await invokeFailureInjection(options.failureInjector, "before_broker_request", {
      prepared,
      head
    });
    const brokerCommit = options.commitBroker || commitThroughBrokerV4;
    const acceptedEnvelope = controller._lifecycle
      ? await controller._lifecycle.runOperation(
          "transport",
          "broker-transport",
          async () =>
            await controller._lifecycle.runOperation(
              "broker",
              "broker-request",
              async () =>
                await brokerCommit({
                  request: prepared.request,
                  headPath,
                  spoolRoot: config.paths.spool_root,
                  expectedPredecessor: head,
                  idempotencyKey: prepared.idempotencyKey
                })
            )
        )
      : await brokerCommit({
          request: prepared.request,
          headPath,
          spoolRoot: config.paths.spool_root,
          expectedPredecessor: head,
          idempotencyKey: prepared.idempotencyKey
        });
    const acceptedTerminalState = recordAcceptedBrokerCommit({
      controller,
      acceptedEnvelope,
      expectedPredecessor: head,
      idempotencyKey: prepared.idempotencyKey,
      item,
      worklist,
      commitContext: {
        surface: item.surface,
        zoom: item.zoom,
        criterion_family: item.criterion_family
      }
    });
    head = cloneJson(acceptedTerminalState.accepted_head);
    accepted = acceptedTerminalState.accepted_count;
    await persistAcceptedCommitTerminalState({
      controller,
      statusRoot: config.paths.status_root
    });
    await invokeFailureInjection(options.failureInjector, "after_broker_response", {
      acceptedEnvelope,
      prepared,
      head
    });
    if (accepted === 1) {
      const firstCommitProof = {
        schema: "capture-runtime-v4-004-0-first-commit-proof-v1",
        lease_identity: leaseIdentity,
        accepted_at: new Date().toISOString(),
        exact_starting_predecessor: options.expectedPredecessor,
        accepted_head: head,
        idempotency_key: prepared.idempotencyKey,
        broker_v4_response: acceptedEnvelope.raw_broker_response,
        correction_activation: prepared.request.metadata.correction_activation,
        surface: item.surface,
        zoom: item.zoom,
        criterion_family: item.criterion_family,
        immutable: true
      };
      const firstCommitBytes = Buffer.from(`${canonicalJson(firstCommitProof)}\n`);
      const firstCommitDigest = sha256(firstCommitBytes);
      const firstCommitPath =
        `${config.paths.stage_root}/FIRST_COMMIT_ACCEPTED-${leaseIdentity}-` +
        `${String(head.sequence).padStart(6, "0")}-${firstCommitDigest.slice(0, 12)}.json`;
      await writeOrVerifyImmutableStage(firstCommitPath, firstCommitBytes);
      controller.first_commit_proof = {
        path: firstCommitPath,
        sha256: firstCommitDigest
      };
    }
    controller.committed_postprocessing_recovery = {
      ...controller.committed_postprocessing_recovery,
      state: "POSTPROCESSING_COMPLETE",
      completed_at: new Date().toISOString(),
      worklist_action: "ADVANCED_EXACTLY_ONCE",
      retry_commit_forbidden: true
    };
    item.last_observed_surface_proof = postSurface;
    item.last_observed_zoom_proof = zoom.proof;
    item.last_same_family_content_digest = prepared.contentDigest;
    item.last_same_family_map_crop_path = prepared.cropDestination;
    item.extent_contribution = novelty.extent;
    item.defer_reason = null;
    item.state = "PENDING";
    item.attempts = 0;
    worklist.cursor = (index + 1) % worklist.items.length;
    controller.worklist_cursor = worklist.cursor;
    frameNumber += 1;
    lastAcceptedAt = Date.now();
    if (accepted === 1 && Date.now() > firstCommitDeadline) {
      throw new Error("SUCCESSOR_FIRST_COMMIT_MISSED_ACTIONABLE_DEADLINE");
    }
    if (rolloverAfterCommit) {
      return {
        status: "ROLLOVER_READY",
        predecessor_supervisor_identity: leaseIdentity,
        source_sha256: options.sourceSha256,
        launcher_sha256: options.launcherSha256,
        config_sha256: options.configSha256,
        worklist_sha256: options.worklistSha256,
        runtime_package_sha256: options.runtimePackageSha256,
        source_version: boundIdentity.source_version,
        explorer_generation_id: boundIdentity.explorer_generation_id,
        package_binding: options.packageBinding,
        terminal_journal_sequence: head.sequence,
        terminal_commit_sha256: head.commit_sha256,
        worklist,
        worklist_cursor: worklist.cursor,
        last_observed_surface: item.last_observed_surface_proof,
        last_observed_zoom: item.last_observed_zoom_proof,
        last_overlay: "NONE",
        last_connection: "CONNECTED",
        no_action_in_flight: true,
        no_background_promise_after_return: true,
        elapsed_ms: performance.now() - monotonicStarted
      };
    }
  }
  return {
    status: "PRECISELY_BLOCKED_HARD_ROLLOVER_WITHOUT_DURABLE_CHECKPOINT",
    lease_identity: leaseIdentity,
    terminal_head: head,
    worklist,
    no_action_in_flight: true,
    no_background_promise_after_return: true
  };
    }
  });
  } finally {
    ACTIVE_LIFECYCLE = previousLifecycle;
  }
}

export default runLease;
