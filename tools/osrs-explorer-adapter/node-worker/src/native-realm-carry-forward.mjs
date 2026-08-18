import fs from "node:fs";
import path from "node:path";
import sharp from "sharp";

import {
  proveSemanticCoverageReadiness,
  proveSemanticMapReadiness,
} from "./perception.mjs";
import { canonicalJson, sha256 } from "./protocol.mjs";
import { requireNativeCoverageContent } from "./semantic-map-capture.mjs";
import { REVIEWED_FRAME, nativeCoverageCropForSurface } from "./semantic-profile.mjs";

const ZERO_DIGEST = "0".repeat(64);

export async function validateNativeRealmCarryForward({ brokerRoot, queueItems }) {
  const commitsRoot = path.join(brokerRoot, "commits");
  const evidenceRoot = path.dirname(brokerRoot);
  const headPath = path.join(brokerRoot, "HEAD.json");
  const initialHeadBytes = regularFileBytes(headPath);
  const initialHead = JSON.parse(initialHeadBytes);
  const expectedByKey = new Map(queueItems.map((item) => [nativeRealmWorkKey(item), item]));
  const carriedByKey = new Map();
  const rejected = [];
  let previousCommitDigest = ZERO_DIGEST;

  const names = fs.readdirSync(commitsRoot)
    .filter((name) => name.endsWith(".json"))
    .sort();
  for (const [index, name] of names.entries()) {
    const commitPath = path.join(commitsRoot, name);
    const commitBytes = immutableBytes(commitPath);
    const commit = JSON.parse(commitBytes);
    if (commit.schema_version !== 1
        || commit.sandbox_only !== true
        || commit.sequence !== index + 1
        || commit.previous_commit_sha256 !== previousCommitDigest
        || commit.broker_protocol?.protocol !== "osrs-capture-broker-v4") {
      throw new Error(`NATIVE_REALM_CARRY_BROKER_CHAIN_INVALID:${name}`);
    }
    previousCommitDigest = sha256(commitBytes);
    if (!isNativeRealmCarrySourceItemID(commit.item_id)) continue;

    try {
      const resultBytes = immutableBytesInside(commit.result_path, evidenceRoot, commit.result_file_sha256);
      const result = JSON.parse(resultBytes);
      const withoutDigest = structuredClone(result);
      delete withoutDigest.result_digest;
      if (result.schema_version !== 2
          || result.execution_profile !== "semantic_map_capture_v1"
          || result.generation_id !== commit.generation_id
          || result.item_id !== commit.item_id
          || result.item_sha256 !== commit.item_sha256
          || result.result_digest !== commit.result_digest
          || sha256(canonicalJson(withoutDigest)) !== result.result_digest) {
        throw new Error("RESULT_BINDING_INVALID");
      }

      const key = nativeRealmWorkKey(result.requested_work);
      const target = expectedByKey.get(key);
      if (!target) throw new Error("WORK_NOT_IN_V14_PLAN");
      if (carriedByKey.has(key)) throw new Error("DUPLICATE_WORK_ACCEPTANCE");

      const captures = [
        ["surface_ready", result.surface_proof?.ready_capture],
        ["coverage_target", result.coverage_navigation?.target_frame],
        ["coverage_fresh", result.coverage_navigation?.fresh_frame],
      ];
      const coverageCrop = target.coverage_cell?.coverage_crop
        ?? nativeCoverageCropForSurface(target.surface);
      const captureProofs = [];
      for (const [role, capture] of captures) {
        if (!capture?.pngPath || !capture?.pngSHA256) {
          throw new Error(`CAPTURE_MISSING:${role}`);
        }
        immutableBytesInside(capture.pngPath, evidenceRoot, capture.pngSHA256);
        const coverageFrame = role !== "surface_ready";
        const proof = await (
          coverageFrame ? proveSemanticCoverageReadiness : proveSemanticMapReadiness
        )(capture.pngPath, target.surface);
        const contentProof = coverageFrame
          ? requireNativeCoverageContent(
            await nativeCoverageRaw(capture.pngPath, coverageCrop),
            coverageCrop
          )
          : null;
        if (!nativeRealmCarryCaptureAccepted({
          role,
          targetSurface: target.surface,
          readiness: proof,
          contentProof,
        })) {
          throw new Error(`EXACT_REALM_READBACK_REJECTED:${role}:${proof.observed_surface ?? "unknown"}`);
        }
        captureProofs.push({
          role,
          path: capture.pngPath,
          sha256: capture.pngSHA256,
          observed_surface: proof.observed_surface,
          normalized_correlation: proof.surface_readback.normalized_correlation,
          correlation_separation: proof.surface_readback.correlation_separation,
          ...(contentProof ? { coverage_content_proof: contentProof } : {}),
        });
      }
      if (new Set(captureProofs.map((proof) => proof.sha256)).size !== captureProofs.length) {
        throw new Error("CAPTURE_FRESHNESS_INVALID");
      }

      const mapCrop = result.map_crop;
      if (!mapCrop?.path
          || !mapCrop?.sha256
          || mapCrop.width !== coverageCrop.width
          || mapCrop.height !== coverageCrop.height
          || !nativeRealmCoverageCropMatches(mapCrop.source_crop, coverageCrop)) {
        throw new Error("MAP_CROP_INVALID");
      }
      immutableBytesInside(mapCrop.path, evidenceRoot, mapCrop.sha256);
      carriedByKey.set(key, {
        target_item_id: target.id,
        target_item_sha256: target.item_sha256,
        source_commit_sequence: commit.sequence,
        source_commit_path: commitPath,
        source_commit_sha256: sha256(commitBytes),
        source_generation_id: commit.generation_id,
        source_item_id: commit.item_id,
        source_item_sha256: commit.item_sha256,
        source_result_path: commit.result_path,
        source_result_file_sha256: commit.result_file_sha256,
        source_result_digest: commit.result_digest,
        requested_work: result.requested_work,
        capture_proofs: captureProofs,
        map_crop: mapCrop,
      });
    } catch (error) {
      rejected.push({
        sequence: commit.sequence,
        generation_id: commit.generation_id,
        item_id: commit.item_id,
        reason: String(error?.message ?? error),
      });
    }
  }

  const finalHeadBytes = regularFileBytes(headPath);
  if (!initialHeadBytes.equals(finalHeadBytes)) {
    throw new Error("NATIVE_REALM_CARRY_BROKER_HEAD_CHANGED_DURING_REVIEW");
  }
  const head = JSON.parse(finalHeadBytes);
  if (initialHead.sequence !== head.sequence
      || initialHead.commit_sha256 !== head.commit_sha256
      || head.sequence !== names.length
      || head.commit_sha256 !== previousCommitDigest) {
    throw new Error("NATIVE_REALM_CARRY_BROKER_HEAD_INVALID");
  }
  const carried = queueItems
    .map((item) => carriedByKey.get(nativeRealmWorkKey(item)))
    .filter(Boolean);
  const carriedIDs = new Set(carried.map((entry) => entry.target_item_id));
  const pending = queueItems.filter((item) => !carriedIDs.has(item.id));
  return {
    schema_version: 1,
    carry_profile: "native-realm-v14-to-v14-exact-crop-identity-v5",
    broker_head: head,
    broker_commit_count: names.length,
    expected_item_count: queueItems.length,
    carried_item_count: carried.length,
    pending_item_count: pending.length,
    rejected_acceptance_count: rejected.length,
    carried,
    rejected,
    pending,
  };
}

export function nativeRealmCarryCaptureAccepted({
  role,
  targetSurface,
  readiness,
  contentProof,
}) {
  const exactRealm = readiness?.passed === true
    && readiness.observed_surface === targetSurface
    && readiness.surface_readback?.exact_match === true
    && readiness.surface_readback?.normalized_correlation >= 0.72
    && readiness.surface_readback?.correlation_separation >= 0.08;
  if (!exactRealm) return false;
  if (role === "surface_ready") return readiness.nonblack === true;
  return (role === "coverage_target" || role === "coverage_fresh")
    && readiness.coverage_content_delegated === true
    && contentProof?.passed === true;
}

export function isNativeRealmCarrySourceItemID(itemID) {
  return typeof itemID === "string"
    && /^native-realm-production-v14-/.test(itemID);
}

export function nativeRealmWorkKey(value) {
  const requested = value?.requested_work ?? value;
  return canonicalJson({
    realm_id: requested.realm_id,
    surface: requested.surface,
    zoom_percent: requested.zoom_percent,
    criterion_family: requested.criterion_family,
    restore_after_capture: requested.restore_after_capture,
    capture_center: requested.capture_center,
    coverage_cell: requested.coverage_cell,
  });
}

export function nativeRealmCoverageCropMatches(observed, expected) {
  const keys = ["left", "top", "width", "height"];
  return observed !== null
    && expected !== null
    && typeof observed === "object"
    && typeof expected === "object"
    && Object.keys(observed).length === keys.length
    && Object.keys(expected).length === keys.length
    && keys.every((key) => Number.isInteger(observed[key]) && observed[key] === expected[key]);
}

function immutableBytesInside(filePath, root, expectedSHA256) {
  const resolvedRoot = `${fs.realpathSync(root)}${path.sep}`;
  const resolved = fs.realpathSync(filePath);
  if (!resolved.startsWith(resolvedRoot)) throw new Error("EVIDENCE_PATH_OUTSIDE_ROOT");
  return immutableBytes(resolved, expectedSHA256);
}

function immutableBytes(filePath, expectedSHA256 = null) {
  const stat = fs.lstatSync(filePath);
  if (!stat.isFile() || stat.isSymbolicLink() || (stat.mode & 0o222) !== 0) {
    throw new Error(`IMMUTABLE_FILE_REQUIRED:${filePath}`);
  }
  const bytes = fs.readFileSync(filePath);
  if (expectedSHA256 && sha256(bytes) !== expectedSHA256) {
    throw new Error(`FILE_DIGEST_MISMATCH:${filePath}`);
  }
  return bytes;
}

function regularFileBytes(filePath) {
  const stat = fs.lstatSync(filePath);
  if (!stat.isFile() || stat.isSymbolicLink()) {
    throw new Error(`REGULAR_FILE_REQUIRED:${filePath}`);
  }
  return fs.readFileSync(filePath);
}

async function nativeCoverageRaw(pngPath, coverageCrop) {
  return sharp(pngPath)
    .resize(REVIEWED_FRAME.width, REVIEWED_FRAME.height, { fit: "fill" })
    .extract(coverageCrop)
    .removeAlpha()
    .raw()
    .toBuffer();
}
