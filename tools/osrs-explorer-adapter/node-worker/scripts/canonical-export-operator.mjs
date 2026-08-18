#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";

import { canonicalJson } from "../src/protocol.mjs";
import {
  deriveIdempotencyKey,
  sha256,
  verifyBrokerV4Envelope,
} from "../derived/reviewed-v4/runtime/explorer-v4-runtime.mjs";

const options = parseOptions(process.argv.slice(2));
for (const name of [
  "result", "sandbox-acceptance", "sandbox-broker-root", "head", "stage-root", "batch-root", "spool-root",
  "explorer-thread-id", "output",
]) {
  if (!options[name]) throw new Error(`CANONICAL_EXPORT_OPTION_REQUIRED:${name}`);
}
for (const name of [
  "result", "sandbox-acceptance", "sandbox-broker-root", "head", "stage-root", "batch-root", "spool-root", "output",
]) {
  if (!path.isAbsolute(options[name])) throw new Error(`CANONICAL_EXPORT_ABSOLUTE_PATH_REQUIRED:${name}`);
}

const resultBytes = immutableBytes(options.result, { allowWritable: false });
const result = JSON.parse(resultBytes);
validateSemanticResult(result, options.result);
const acceptanceBytes = immutableBytes(options["sandbox-acceptance"], { allowWritable: false });
const acceptance = JSON.parse(acceptanceBytes);
validateSandboxAcceptance(acceptance, options.result, resultBytes, result);
validateSandboxAcceptanceChain(
  options["sandbox-broker-root"],
  options["sandbox-acceptance"],
  sha256(acceptanceBytes)
);
const headBytes = immutableBytes(options.head, { allowWritable: false });
const predecessor = JSON.parse(headBytes);
if (!Number.isInteger(predecessor.sequence)
    || !/^[a-f0-9]{64}$/.test(predecessor.commit_sha256 || "")) {
  throw new Error("CANONICAL_EXPORT_HEAD_INVALID");
}

const frame = result.pan_proof.fresh_frame;
const crop = result.map_crop;
const fullBytes = immutableBytes(frame.pngPath, { expectedSHA256: frame.pngSHA256 });
const cropBytes = immutableBytes(crop.path, { expectedSHA256: crop.sha256 });
const criterionFamilyKey = [
  result.requested_work.surface,
  result.requested_work.zoom_percent,
  result.requested_work.criterion_family,
].join("|");
const idempotencyKey = deriveIdempotencyKey({
  predecessor,
  frameDigest: frame.pngSHA256,
  criterionFamilyKey,
  explorerThreadId: options["explorer-thread-id"],
});
const base = [
  String(predecessor.sequence + 1).padStart(6, "0"),
  slug(result.requested_work.surface),
  `z${String(result.requested_work.zoom_percent).replace(".", "_")}`,
  result.requested_work.criterion_family,
  idempotencyKey.slice(0, 10),
  "semantic-adapter",
].join("_");
const fullStage = path.join(options["stage-root"], `${base}-full.png`);
const cropStage = path.join(options["stage-root"], `${base}-map.png`);
writeOrVerifyImmutable(fullStage, fullBytes);
writeOrVerifyImmutable(cropStage, cropBytes);

const metadata = {
  schema: "osrs-map-capture-semantic-adapter-v2",
  explorer_thread_id: options["explorer-thread-id"],
  captured_at: frame.capturedAt,
  surface: result.requested_work.surface,
  true_zoom_percent: result.requested_work.zoom_percent,
  criterion_family_key: criterionFamilyKey,
  target_identity: result.target_identity,
  surface_readback_proof: result.surface_proof,
  canonical_zoom_readback_proof: result.zoom_proof,
  novelty_proof: result.pan_proof.novelty,
  semantic_result: {
    path: options.result,
    sha256: sha256(resultBytes),
    result_digest: result.result_digest,
  },
  sandbox_acceptance: {
    path: options["sandbox-acceptance"],
    sha256: sha256(acceptanceBytes),
    sequence: acceptance.sequence,
  },
  full_client: { path: path.join(options["batch-root"], "raw/full-client", `${base}.png`), sha256: frame.pngSHA256, bytes: fullBytes.length },
  map_crop: { path: path.join(options["batch-root"], "raw/map-crops", `${base}_map.png`), sha256: crop.sha256, bytes: cropBytes.length },
  broker_continuity: {
    protocol: "osrs-capture-broker-v4",
    idempotency_key: idempotencyKey,
    expected_predecessor: predecessor,
    expected_accepted_sequence: predecessor.sequence + 1,
  },
  requirement_id: "SEMANTIC_MAP_CAPTURE_V1_FULL_MOTION_REPLACEMENT",
  black_frame: false,
  immutable: true,
};
const request = {
  op: "commit",
  explorer_thread_id: options["explorer-thread-id"],
  full_stage: fullStage,
  crop_stage: cropStage,
  full_dest: metadata.full_client.path,
  crop_dest: metadata.map_crop.path,
  meta_dest: path.join(options["batch-root"], "meta", `${base}.json`),
  full_sha256: frame.pngSHA256,
  crop_sha256: crop.sha256,
  metadata,
  captured_at: frame.capturedAt,
  surface: result.requested_work.surface,
  zoom: result.requested_work.zoom_percent,
  gesture_id: `semantic-adapter-${idempotencyKey.slice(0, 24)}`,
  requirement_id: metadata.requirement_id,
  criterion_family_key: criterionFamilyKey,
  idempotency_key: idempotencyKey,
  expected_predecessor: predecessor,
};
const exportPackage = {
  schema_version: 1,
  protocol: "osrs-semantic-canonical-export-v1",
  semantic_result: metadata.semantic_result,
  idempotency_key: idempotencyKey,
  expected_predecessor: predecessor,
  request,
  prepared_at: new Date().toISOString(),
  execute_requested: options.execute === true,
};
writeImmutableJSON(options.output, exportPackage);

if (!options.execute) {
  process.stdout.write(`${JSON.stringify({
    status: "CANONICAL_EXPORT_PREPARED_NOT_SUBMITTED",
    output: options.output,
    idempotency_key: idempotencyKey,
    expected_predecessor: predecessor,
  })}\n`);
  process.exit(0);
}

const currentHead = JSON.parse(immutableBytes(options.head, { allowWritable: false }));
if (canonicalJson(currentHead) !== canonicalJson(predecessor)) {
  throw new Error("CANONICAL_EXPORT_PREDECESSOR_CHANGED_BEFORE_REQUEST");
}
const requestID = `broker-v4-${idempotencyKey}`;
const requestPath = path.join(options["spool-root"], "requests", `${requestID}.json`);
const responsePath = path.join(options["spool-root"], "responses", `${requestID}.json`);
try {
  writeExclusiveJSON(requestPath, request);
} catch (error) {
  if (error?.code === "EEXIST") {
    throw new Error("CANONICAL_EXPORT_REQUEST_ALREADY_EXISTS_RECONCILE_DONT_RESUBMIT");
  }
  throw error;
}
const response = waitForResponse(responsePath, 30_000);
if (!response) throw new Error("CANONICAL_EXPORT_UNCERTAIN_DO_NOT_RESUBMIT");
if (response.ok !== true) throw new Error(`CANONICAL_EXPORT_BROKER_REJECTED:${response.error}`);

const acceptedHeadBytes = immutableBytes(options.head, { allowWritable: false });
const acceptedHead = JSON.parse(acceptedHeadBytes);
if (acceptedHead.sequence !== predecessor.sequence + 1) {
  throw new Error("CANONICAL_EXPORT_ACCEPTED_HEAD_SEQUENCE_MISMATCH");
}
const commitBytes = immutableBytes(acceptedHead.commit_path, { allowWritable: false });
const commit = JSON.parse(commitBytes);
const acceptedMetadata = JSON.parse(immutableBytes(commit.metadata.path, { allowWritable: false }));
const envelopeExpectedPredecessor = predecessorIdentity(predecessor);
const envelopeCommit = normalizeReviewedCommitProtocol(commit, response.protocol);
const envelope = verifyBrokerV4Envelope({
  expectedPredecessor: envelopeExpectedPredecessor,
  idempotencyKey,
  explorerThreadId: options["explorer-thread-id"],
  response,
  head: acceptedHead,
  commit: envelopeCommit,
  metadata: acceptedMetadata,
  observedCommitSha256: sha256(commitBytes),
});
if (!envelope.passed || commit.full_client?.sha256 !== frame.pngSHA256) {
  throw new Error(`CANONICAL_EXPORT_ACCEPTED_ENVELOPE_INVALID:${envelope.failures.join(",")}`);
}
const acceptedPath = `${options.output}.accepted.json`;
writeImmutableJSON(acceptedPath, {
  schema_version: 1,
  status: "CANONICAL_EXPORT_ACCEPTED",
  idempotency_key: idempotencyKey,
  expected_predecessor: predecessor,
  accepted_head: acceptedHead,
  accepted_commit_sha256: sha256(commitBytes),
  accepted_at: new Date().toISOString(),
});
process.stdout.write(`${JSON.stringify({
  status: "CANONICAL_EXPORT_ACCEPTED",
  accepted_path: acceptedPath,
  accepted_sequence: acceptedHead.sequence,
  accepted_commit_sha256: acceptedHead.commit_sha256,
})}\n`);

function validateSemanticResult(value, sourcePath) {
  if (value?.schema_version !== 2
      || value.execution_profile !== "semantic_map_capture_v1"
      || value.pan_proof?.fresh_gate?.passed !== true
      || value.pan_proof?.novelty?.passed !== true
      || value.map_crop?.width !== 516
      || value.map_crop?.height !== 641) {
    throw new Error("CANONICAL_EXPORT_SEMANTIC_RESULT_INVALID");
  }
  const withoutDigest = structuredClone(value);
  delete withoutDigest.result_digest;
  if (sha256(canonicalJson(withoutDigest)) !== value.result_digest) {
    throw new Error(`CANONICAL_EXPORT_RESULT_DIGEST_MISMATCH:${sourcePath}`);
  }
}

function predecessorIdentity(value) {
  return {
    sequence: value.sequence,
    commit_sha256: value.commit_sha256,
  };
}

function normalizeReviewedCommitProtocol(commit, responseProtocol) {
  const brokerProtocol = commit?.broker_protocol;
  if (brokerProtocol?.protocol !== undefined) return commit;
  if (brokerProtocol?.schema_version !== 1 || responseProtocol !== "osrs-capture-broker-v4") {
    return commit;
  }
  return {
    ...commit,
    broker_protocol: {
      ...brokerProtocol,
      protocol: responseProtocol,
    },
  };
}

function validateSandboxAcceptance(value, resultPath, resultBytes, result) {
  if (value?.schema_version !== 1
      || value.sandbox_only !== true
      || value.broker_protocol?.protocol !== "osrs-capture-broker-v4"
      || value.generation_id !== result.generation_id
      || value.item_id !== result.item_id
      || value.item_sha256 !== result.item_sha256
      || value.result_path !== resultPath
      || value.result_file_sha256 !== sha256(resultBytes)
      || value.result_digest !== result.result_digest) {
    throw new Error("CANONICAL_EXPORT_SANDBOX_ACCEPTANCE_INVALID");
  }
}

function validateSandboxAcceptanceChain(root, acceptancePath, acceptanceSHA256) {
  const commitsRoot = path.join(root, "commits");
  const expectedAcceptancePath = fs.realpathSync(acceptancePath);
  if (path.dirname(expectedAcceptancePath) !== fs.realpathSync(commitsRoot)) {
    throw new Error("CANONICAL_EXPORT_SANDBOX_ACCEPTANCE_PATH_INVALID");
  }
  const names = fs.readdirSync(commitsRoot)
    .filter((name) => name.endsWith(".json"))
    .sort();
  let previous = "0".repeat(64);
  let found = false;
  for (const [index, name] of names.entries()) {
    const commitPath = path.join(commitsRoot, name);
    const bytes = immutableBytes(commitPath, { allowWritable: false });
    const commit = JSON.parse(bytes);
    const digest = sha256(bytes);
    if (commit.schema_version !== 1
        || commit.sandbox_only !== true
        || commit.sequence !== index + 1
        || commit.previous_commit_sha256 !== previous
        || commit.broker_protocol?.protocol !== "osrs-capture-broker-v4") {
      throw new Error(`CANONICAL_EXPORT_SANDBOX_CHAIN_INVALID:${name}`);
    }
    if (fs.realpathSync(commitPath) === expectedAcceptancePath) {
      if (digest !== acceptanceSHA256) {
        throw new Error("CANONICAL_EXPORT_SANDBOX_ACCEPTANCE_DIGEST_INVALID");
      }
      found = true;
    }
    previous = digest;
  }
  const head = JSON.parse(fs.readFileSync(path.join(root, "HEAD.json"), "utf8"));
  if (!found || head.sequence !== names.length || head.commit_sha256 !== previous) {
    throw new Error("CANONICAL_EXPORT_SANDBOX_HEAD_INVALID");
  }
}

function immutableBytes(sourcePath, { expectedSHA256, allowWritable = false } = {}) {
  const stat = fs.lstatSync(sourcePath);
  if (!stat.isFile() || stat.isSymbolicLink() || (!allowWritable && (stat.mode & 0o777) !== 0o444)) {
    throw new Error(`CANONICAL_EXPORT_IMMUTABLE_FILE_REQUIRED:${sourcePath}`);
  }
  const bytes = fs.readFileSync(sourcePath);
  if (expectedSHA256 && sha256(bytes) !== expectedSHA256) {
    throw new Error(`CANONICAL_EXPORT_SHA256_MISMATCH:${sourcePath}`);
  }
  return bytes;
}

function writeOrVerifyImmutable(destination, bytes) {
  fs.mkdirSync(path.dirname(destination), { recursive: true, mode: 0o700 });
  if (fs.existsSync(destination)) {
    const existing = immutableBytes(destination, { allowWritable: false });
    if (!existing.equals(bytes)) throw new Error(`CANONICAL_EXPORT_STAGE_COLLISION:${destination}`);
    return;
  }
  const descriptor = fs.openSync(destination, "wx", 0o600);
  try {
    fs.writeFileSync(descriptor, bytes);
    fs.fsyncSync(descriptor);
  } finally {
    fs.closeSync(descriptor);
  }
  fs.chmodSync(destination, 0o444);
}

function writeImmutableJSON(destination, value) {
  writeExclusive(destination, Buffer.from(`${JSON.stringify(value, null, 2)}\n`), 0o444);
}

function writeExclusiveJSON(destination, value) {
  writeExclusive(destination, Buffer.from(`${JSON.stringify(value)}\n`), 0o444);
}

function writeExclusive(destination, bytes, finalMode) {
  fs.mkdirSync(path.dirname(destination), { recursive: true, mode: 0o700 });
  const descriptor = fs.openSync(destination, "wx", 0o600);
  try {
    fs.writeFileSync(descriptor, bytes);
    fs.fsyncSync(descriptor);
  } finally {
    fs.closeSync(descriptor);
  }
  fs.chmodSync(destination, finalMode);
}

function waitForResponse(responsePath, timeoutMilliseconds) {
  const deadline = Date.now() + timeoutMilliseconds;
  while (Date.now() < deadline) {
    if (fs.existsSync(responsePath)) return JSON.parse(fs.readFileSync(responsePath, "utf8"));
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 50);
  }
  return null;
}

function slug(value) {
  return value.toLowerCase().replace(/[^a-z0-9]+/g, "_").replace(/^_|_$/g, "");
}

function parseOptions(arguments_) {
  const result = { execute: false };
  for (let index = 0; index < arguments_.length; index += 1) {
    const argument = arguments_[index];
    if (argument === "--execute") {
      result.execute = true;
      continue;
    }
    if (!argument.startsWith("--")) throw new Error(`CANONICAL_EXPORT_ARGUMENT_INVALID:${argument}`);
    const name = argument.slice(2);
    const value = arguments_[++index];
    if (!value || value.startsWith("--")) throw new Error(`CANONICAL_EXPORT_OPTION_VALUE_REQUIRED:${name}`);
    result[name] = value;
  }
  return result;
}
