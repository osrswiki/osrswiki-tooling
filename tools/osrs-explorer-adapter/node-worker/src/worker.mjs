import fs from "node:fs";
import process from "node:process";
import sharp from "sharp";

import { writeImmutableBuffer, writeImmutableJson, resultDigest } from "./evidence.mjs";
import { reportFailedClaim } from "./failure-reporting.mjs";
import { requireLabVisualAcknowledgement } from "./lab-qualification.mjs";
import {
  localizeSemanticSurfaceScrollbar,
  observeSemanticSurfaceScrollbar,
  requireAuthorizedOSRSMap,
  requireAuthorizedOSRSSelector,
} from "./perception.mjs";
import { captureAuthorizedOSRSPostAction } from "./post-action-qualification.mjs";
import {
  RAW_SELECTOR_SCROLLBAR_CALIBRATION_KIND,
  RAW_SELECTOR_SCROLLBAR_RESET_KIND,
  rawOSRSQualificationMode,
  requireRawSelectorScrollbarCalibrationShape,
} from "./raw-selector-calibration.mjs";
import { executeRecoveryClaim, isRecoveryItem } from "./recovery.mjs";
import { request } from "./rpc.mjs";
import { executeSemanticMapCapture } from "./semantic-map-capture.mjs";
import { CONTENT_CROP, MAP_CROP, selectorScrollbarVector } from "./semantic-profile.mjs";
import { sha256 } from "./protocol.mjs";

// 0.35.3 is the reviewed-runtime pin. Keep the unnecessary decoders disabled
// per GHSA-f88m-g3jw-g9cj; this worker accepts only host-produced PNG captures.
sharp.block({ operation: ["VipsForeignLoadNsgif", "VipsForeignLoadTiff", "VipsForeignLoadVips"] });

const socketPath = required("OSRS_ADAPTER_SOCKET");
const capability = required("OSRS_ADAPTER_WORKER_CAPABILITY");
const expectedParentPID = Number(required("OSRS_ADAPTER_PARENT_PID"));
let stopping = false;
let activeJob = null;

process.on("SIGTERM", () => { stopping = true; });
process.on("SIGINT", () => { stopping = true; });

while (!stopping) {
  if (process.ppid !== expectedParentPID) break;
  let claimResponse;
  try {
    claimResponse = await request(socketPath, capability, "worker.claim");
  } catch (error) {
    if (stopping) break;
    if (/UNAUTHORIZED/.test(error.message)) break;
    if (/ADAPTER_NOT_RUNNING|QUEUE_UNAVAILABLE/.test(error.message)) {
      await delay(250);
      continue;
    }
    process.stderr.write(`${new Date().toISOString()} claim error: ${error.stack || error}\n`);
    await delay(500);
    continue;
  }
  const claim = claimResponse.queueClaim;
  if (!claim) {
    await delay(250);
    continue;
  }
  activeJob = claim.item.id;
  try {
    const summary = await executeClaim(claim);
    const reference = writeImmutableJson(
      claim.artifact_root,
      `worker/${claim.generation_id}/${claim.item.id}.json`,
      summary
    );
    await request(socketPath, capability, "worker.complete", {
      queue_generation: claim.generation_id,
      job_id: claim.item.id,
      success: true,
      result_path: reference.path,
      result_file_sha256: reference.sha256,
      result_digest: summary.result_digest
    });
  } catch (error) {
    process.stderr.write(`${new Date().toISOString()} item ${claim.item.id} failed: ${error.stack || error}\n`);
    try {
      await reportFailedClaim({
        claim,
        error,
        writeFailureEvidence: (record) => writeImmutableJson(
          claim.artifact_root,
          `worker/${claim.generation_id}/${claim.item.id}-failure.json`,
          record
        ),
        completeFailure: () => request(socketPath, capability, "worker.complete", {
          queue_generation: claim.generation_id,
          job_id: claim.item.id,
          success: false
        })
      });
    } catch (reportingError) {
      process.stderr.write(
        `${new Date().toISOString()} failure report ${claim.item.id} failed: ${reportingError.stack || reportingError}\n`
      );
    }
    break;
  } finally {
    activeJob = null;
  }
}

async function executeClaim(claim) {
  const deadline = Date.parse(claim.execution_deadline_at);
  const claimedAt = Date.parse(claim.claimed_at);
  if (!Number.isFinite(deadline)
      || !Number.isFinite(claimedAt)
      || deadline <= claimedAt
      || deadline - claimedAt > 120_000) {
    throw new Error("ITEM_EXECUTION_DEADLINE_INVALID");
  }
  assertBeforeDeadline(deadline);
  const startedAt = new Date().toISOString();
  const evidence = [];
  try {
    if (claim.item.kind === "semantic_map_capture") {
      const semantic = await executeSemanticMapCapture({
        claim,
        deadline,
        captureFrame: () => captureFrame(claim, deadline),
        performAction: async (operation, boundCapture) => {
          assertBeforeDeadline(deadline);
          const action = operation.kind === "click"
            ? {
                kind: "click",
                capture_id: boundCapture.captureIdentifier,
                point: operation.point,
                button: operation.button,
              }
            : operation.kind === "open_world_map"
              ? {
                  kind: "open_world_map",
                  capture_id: boundCapture.captureIdentifier,
                }
              : {
                kind: "drag",
                capture_id: boundCapture.captureIdentifier,
                from: operation.from,
                to: operation.to,
              };
          const response = await request(socketPath, capability, operation.kind, {
            queue_generation: claim.generation_id,
            job_id: claim.item.id,
            semantic_role: operation.semantic_role,
            action,
          });
          return response.inputEvidence;
        },
        writeMapCrop: async (bytes) => writeImmutableBuffer(
          claim.artifact_root,
          `worker/${claim.generation_id}/assets/${claim.item.id}-map.png`,
          bytes
        ),
        loadSameFamilyRaw: (item) => loadSameFamilyRaw(claim.artifact_root, item),
      });
      const summary = { ...semantic, started_at: startedAt };
      return { ...summary, result_digest: resultDigest(summary) };
    }
    if (isRecoveryItem(claim.item)) {
      const recovery = await executeRecoveryClaim({
        claim,
        deadline,
        captureFrame: () => captureFrame(claim, deadline),
        performAction: async (operation, boundCapture) => {
          assertBeforeDeadline(deadline);
          const action = operation.kind === "open_world_map"
            ? {
                kind: "open_world_map",
                capture_id: boundCapture.captureIdentifier
              }
            : {
                kind: "click",
                capture_id: boundCapture.captureIdentifier,
                point: operation.point,
                button: operation.button
              };
          const actionResponse = await request(socketPath, capability, operation.kind, {
            queue_generation: claim.generation_id,
            job_id: claim.item.id,
            action,
            event_source_mode: operation.event_source_mode,
            delivery_mode: operation.delivery_mode
          });
          assertBeforeDeadline(deadline);
          return actionResponse.inputEvidence;
        },
        isStopping: () => stopping
      });
      evidence.push(...recovery.evidence);
    } else {
      await executeStandardOperations(claim, deadline, evidence);
    }
  } catch (error) {
    if (!error.partialEvidence) error.partialEvidence = evidence;
    throw error;
  }
  const summary = {
    schema_version: 1,
    generation_id: claim.generation_id,
    item_id: claim.item.id,
    item_sha256: claim.item.item_sha256,
    started_at: startedAt,
    completed_at: new Date().toISOString(),
    evidence
  };
  assertBeforeDeadline(deadline);
  return { ...summary, result_digest: resultDigest(summary) };
}

async function loadSameFamilyRaw(artifactRoot, item) {
  const workerRoot = `${artifactRoot}/worker`;
  if (!fs.existsSync(workerRoot)) return null;
  const names = fs.readdirSync(workerRoot, { recursive: true, encoding: "utf8" })
    .filter((name) => name.endsWith(".json"))
    .sort()
    .reverse();
  for (const name of names) {
    let record;
    try {
      record = JSON.parse(fs.readFileSync(`${workerRoot}/${name}`, "utf8"));
    } catch {
      continue;
    }
    const requested = record?.requested_work;
    if (record?.schema_version !== 2
        || requested?.surface !== item.surface
        || requested?.zoom_percent !== item.zoom_percent
        || requested?.criterion_family !== item.criterion_family) continue;
    const crop = record.map_crop;
    if (!crop?.path || !crop?.sha256 || !fs.existsSync(crop.path)) {
      throw new Error("SEMANTIC_SAME_FAMILY_BASELINE_MISSING");
    }
    const bytes = fs.readFileSync(crop.path);
    if (sha256(bytes) !== crop.sha256) throw new Error("SEMANTIC_SAME_FAMILY_BASELINE_SHA256_MISMATCH");
    return sharp(bytes)
      .extract({
        left: CONTENT_CROP.left - MAP_CROP.left,
        top: CONTENT_CROP.top - MAP_CROP.top,
        width: CONTENT_CROP.width,
        height: CONTENT_CROP.height,
      })
      .removeAlpha()
      .raw()
      .toBuffer();
  }
  return null;
}

async function executeStandardOperations(claim, deadline, evidence) {
  let capture = null;
  try {
    requireRawSelectorScrollbarCalibrationShape({
      item: claim.item,
      targetBundleID: claim.selector?.bundleIdentifier,
    });
    for (const operation of claim.item.operations) {
      assertBeforeDeadline(deadline);
      if (stopping) throw new Error("WORKER_STOPPING");
      if (operation.kind === "capture") {
        capture = await captureFrame(claim, deadline);
        evidence.push({ kind: "capture", capture });
        continue;
      }
      if (!capture) {
        capture = await captureFrame(claim, deadline);
      }
      if (claim.selector?.bundleIdentifier === "com.jagex.osclient") {
        const beforeMode = rawOSRSQualificationMode(claim.item, operation.kind, "before");
        const classification = beforeMode === "selector"
          ? await requireAuthorizedOSRSSelector(capture.pngPath)
          : await requireAuthorizedOSRSMap(capture.pngPath);
        assertBeforeDeadline(deadline);
        evidence.push({ kind: "osrs_screen_qualification", classification });
        if ((claim.item.kind === RAW_SELECTOR_SCROLLBAR_CALIBRATION_KIND
              || claim.item.kind === RAW_SELECTOR_SCROLLBAR_RESET_KIND)
            && operation.kind === "drag") {
          const reset = claim.item.kind === RAW_SELECTOR_SCROLLBAR_RESET_KIND;
          const scrollbar = reset
            ? await observeSemanticSurfaceScrollbar(capture.pngPath, "Zanaris")
            : await localizeSemanticSurfaceScrollbar(capture.pngPath, "Zanaris", "top");
          if (reset && scrollbar.state === "top") {
            throw new Error("SELECTOR_CALIBRATION_RESET_ALREADY_AT_TOP");
          }
          const expected = selectorScrollbarVector(reset ? "top" : "bottom", scrollbar).delivered;
          if (!samePoint(operation.from, expected.from) || !samePoint(operation.to, expected.to)) {
            throw new Error("SELECTOR_CALIBRATION_DRAG_DOES_NOT_MATCH_PIXEL_GEOMETRY");
          }
          evidence.push({ kind: "selector_scrollbar_pixel_proof", phase: "before_drag", scrollbar });
        }
      }
      const action = operation.kind === "click"
        ? {
            kind: "click",
            capture_id: capture.captureIdentifier,
            point: operation.point,
            button: operation.button
          }
        : {
            kind: "drag",
            capture_id: capture.captureIdentifier,
            from: operation.from,
            to: operation.to
          };
      const beforeAction = capture;
      assertBeforeDeadline(deadline);
      const actionResponse = await request(socketPath, capability, operation.kind, {
        queue_generation: claim.generation_id,
        job_id: claim.item.id,
        action,
        event_source_mode: operation.event_source_mode,
        delivery_mode: operation.delivery_mode
      });
      assertBeforeDeadline(deadline);
      evidence.push({
        kind: operation.kind,
        event_source_mode: operation.event_source_mode || "private_state",
        delivery_mode: operation.delivery_mode || "background_pid",
        input_evidence: actionResponse.inputEvidence
      });
      if (claim.selector?.bundleIdentifier === "com.jagex.osclient") {
        const afterMode = rawOSRSQualificationMode(claim.item, operation.kind, "after");
        capture = await captureAuthorizedOSRSPostAction({
          captureFrame: () => captureFrame(claim, deadline),
          classify: afterMode === "selector"
            ? requireAuthorizedOSRSSelector
            : requireAuthorizedOSRSMap,
          recordEvidence: (entry) => evidence.push(entry)
        });
        if (afterMode === "selector" && beforeAction.pngSHA256 === capture.pngSHA256) {
          throw new Error("SELECTOR_CALIBRATION_ACTION_PRODUCED_UNCHANGED_FRAME");
        }
        if (claim.item.kind === RAW_SELECTOR_SCROLLBAR_CALIBRATION_KIND
            || claim.item.kind === RAW_SELECTOR_SCROLLBAR_RESET_KIND) {
          const anchor = claim.item.kind === RAW_SELECTOR_SCROLLBAR_RESET_KIND
            ? "top"
            : operation.kind === "click" ? "top" : "bottom";
          const scrollbar = await localizeSemanticSurfaceScrollbar(
            capture.pngPath,
            "Zanaris",
            anchor
          );
          evidence.push({
            kind: "selector_scrollbar_pixel_proof",
            phase: operation.kind === "click" ? "after_open" : "after_drag",
            scrollbar,
          });
        }
      } else {
        capture = await captureFrame(claim, deadline);
        evidence.push({ kind: "post_capture", capture });
      }
      if (claim.selector?.titleContains === "Explorer Adapter Lab Target") {
        requireLabVisualAcknowledgement(beforeAction, capture, operation);
      }
    }
  } catch (error) {
    error.partialEvidence = evidence;
    throw error;
  }
}

function samePoint(first, second) {
  return first?.x === second?.x && first?.y === second?.y;
}

async function captureFrame(claim, deadline) {
  assertBeforeDeadline(deadline);
  const response = await request(socketPath, capability, "capture", {
    queue_generation: claim.generation_id,
    job_id: claim.item.id
  });
  assertBeforeDeadline(deadline);
  const capture = response.capture;
  if (!capture || !fs.existsSync(capture.pngPath)) throw new Error("CAPTURE_EVIDENCE_MISSING");
  const metadata = await sharp(capture.pngPath).metadata();
  assertBeforeDeadline(deadline);
  if (metadata.width !== capture.pixelWidth || metadata.height !== capture.pixelHeight) {
    throw new Error("CAPTURE_DIMENSION_MISMATCH");
  }
  return capture;
}

function assertBeforeDeadline(deadline) {
  if (Date.now() >= deadline) throw new Error("ITEM_EXECUTION_DEADLINE_EXCEEDED");
}

function required(name) {
  const value = process.env[name];
  if (!value) throw new Error(`${name}_REQUIRED`);
  return value;
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}
