#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";

import { canonicalJson, sha256, validateQueueManifest } from "../src/protocol.mjs";
import {
  semanticPilotItems,
  semanticScrollbarAtExactStop,
  semanticSurfaceNavigation,
} from "../src/semantic-profile.mjs";

const options = parseOptions(process.argv.slice(2));
for (const name of ["profile", "queue", "broker-root", "output"]) {
  if (!options[name]) throw new Error(`SEMANTIC_PILOT_OPTION_REQUIRED:${name}`);
}
for (const name of ["queue", "broker-root", "output"]) {
  if (!path.isAbsolute(options[name])) throw new Error(`SEMANTIC_PILOT_ABSOLUTE_PATH_REQUIRED:${name}`);
}

const queueBytes = immutableBytes(options.queue);
const queue = JSON.parse(queueBytes);
validateQueueManifest(queue);
if (queue.schema_version !== 2 || queue.execution_profile !== "semantic_map_capture_v1") {
  throw new Error("SEMANTIC_PILOT_QUEUE_PROFILE_INVALID");
}
validateProfileItems(options.profile, queue.items);

const commitsRoot = path.join(options["broker-root"], "commits");
const commitNames = fs.readdirSync(commitsRoot)
  .filter((name) => name.endsWith(".json"))
  .sort();
const commitRecords = [];
let globalPreviousDigest = "0".repeat(64);
for (const [index, name] of commitNames.entries()) {
  const commitPath = path.join(commitsRoot, name);
  const commitBytes = immutableBytes(commitPath);
  const commit = JSON.parse(commitBytes);
  if (commit.schema_version !== 1
      || commit.sandbox_only !== true
      || commit.sequence !== index + 1
      || commit.previous_commit_sha256 !== globalPreviousDigest
      || commit.broker_protocol?.protocol !== "osrs-capture-broker-v4") {
    throw new Error(`SEMANTIC_PILOT_ACCEPTANCE_CHAIN_INVALID:${name}`);
  }
  const commitDigest = sha256(commitBytes);
  commitRecords.push({ name, commit, commitBytes, commitDigest });
  globalPreviousDigest = commitDigest;
}

const head = JSON.parse(fs.readFileSync(path.join(options["broker-root"], "HEAD.json"), "utf8"));
if (head.sequence !== commitNames.length || head.commit_sha256 !== globalPreviousDigest) {
  throw new Error("SEMANTIC_PILOT_BROKER_HEAD_INVALID");
}

const itemByID = new Map(queue.items.map((item) => [item.id, item]));
const acceptedCommitByItemID = new Map();
for (const record of commitRecords) {
  const item = itemByID.get(record.commit.item_id);
  if (!item || record.commit.item_sha256 !== item.item_sha256) continue;
  if (acceptedCommitByItemID.has(item.id)) {
    throw new Error(`SEMANTIC_PILOT_DUPLICATE_ACCEPTANCE:${item.id}`);
  }
  acceptedCommitByItemID.set(item.id, record);
}
const phaseCommits = queue.items
  .map((item) => acceptedCommitByItemID.get(item.id))
  .filter(Boolean);
if (phaseCommits.length !== queue.items.length) {
  throw new Error(`SEMANTIC_PILOT_ACCEPTED_COUNT_MISMATCH:${phaseCommits.length}:${queue.items.length}`);
}
const acceptedIDs = new Set();
const elapsed = [];
const inputToPost = [];
const selectorDurations = [];
let bottomDragCount = 0;
let verifiedSurfaceResetCount = 0;
let previousPhaseSequence = null;

for (const { name, commit, commitBytes } of phaseCommits) {
  const item = itemByID.get(commit.item_id);
  if (!item
      || acceptedIDs.has(commit.item_id)
      || commit.item_sha256 !== item.item_sha256
      || (previousPhaseSequence !== null && commit.sequence <= previousPhaseSequence)) {
    throw new Error(`SEMANTIC_PILOT_ACCEPTANCE_CHAIN_INVALID:${name}`);
  }
  const resultBytes = immutableBytes(commit.result_path, commit.result_file_sha256);
  const result = JSON.parse(resultBytes);
  const withoutDigest = structuredClone(result);
  delete withoutDigest.result_digest;
  if (result.schema_version !== 2
      || result.execution_profile !== "semantic_map_capture_v1"
      || result.generation_id !== commit.generation_id
      || result.item_id !== item.id
      || result.item_sha256 !== item.item_sha256
      || sha256(canonicalJson(withoutDigest)) !== result.result_digest
      || result.result_digest !== commit.result_digest
      || result.requested_work?.surface !== item.surface
      || result.requested_work?.zoom_percent !== item.zoom_percent
      || result.requested_work?.criterion_family !== item.criterion_family
      || result.requested_work?.restore_after_capture !== item.restore_after_capture
      || result.surface_proof?.ready_gate?.passed !== true
      || !selectorNavigationPassed(result.surface_proof?.selector_navigation, item.surface)
      || result.zoom_proof?.observed_zoom_percent !== item.zoom_percent
      || result.pan_proof?.pre_gate?.passed !== true
      || result.pan_proof?.post_gate?.passed !== true
      || result.pan_proof?.fresh_gate?.passed !== true
      || result.pan_proof?.novelty?.passed !== true
      || result.restoration_proof?.required !== item.restore_after_capture
      || (item.restore_after_capture && result.restoration_proof?.delivered !== true)
      || !surfaceResetPassed(result.surface_reset_proof, item)) {
    throw new Error(`SEMANTIC_PILOT_RESULT_INVALID:${commit.item_id}`);
  }
  const itemElapsed = result.performance?.elapsed_milliseconds;
  const itemInputToPost = result.performance?.input_to_qualified_post_capture_milliseconds;
  const selectorDuration = result.performance?.selector_open_to_surface_qualified_milliseconds;
  if (!Number.isFinite(itemElapsed)
      || itemElapsed < 0
      || itemElapsed >= 120_000
      || !Number.isFinite(itemInputToPost)
      || itemInputToPost < 0
      || itemInputToPost >= 120_000
      || !Number.isFinite(selectorDuration)
      || selectorDuration < 0
      || selectorDuration >= 120_000) {
    throw new Error(`SEMANTIC_PILOT_PERFORMANCE_INVALID:${commit.item_id}`);
  }
  if ((result.recovery_history?.length ?? 0) === 0) elapsed.push(itemElapsed);
  inputToPost.push(itemInputToPost);
  selectorDurations.push(selectorDuration);
  bottomDragCount += result.surface_proof?.selector_navigation?.anchor === "bottom"
    ? result.surface_proof.selector_navigation.drags
    : 0;
  if (result.surface_reset_proof?.delivered === true) verifiedSurfaceResetCount += 1;
  acceptedIDs.add(commit.item_id);
  previousPhaseSequence = commit.sequence;
}

function selectorNavigationPassed(proof, surface) {
  const expected = semanticSurfaceNavigation(surface);
  return proof?.required === expected.required
    && proof?.mode === expected.mode
    && proof?.anchor === expected.anchor
    && proof?.maximum_drags === expected.maximum_drags
    && Number.isInteger(proof?.drags)
    && proof.drags === (proof.transitions?.length ?? -1)
    && (expected.required
      ? proof.drags === 1
          && proof.transitions[0]?.mode === "scrollbar_drag"
          && proof.transitions[0]?.anchor === "bottom"
          && semanticScrollbarAtExactStop(proof.transitions[0]?.post_drag_proof, "bottom")
          && proof.transitions[0]?.post_drag_proof?.selector_open === true
      : proof.drags === 0);
}

function surfaceResetPassed(proof, item) {
  const expected = item.surface === "Zanaris" && item.restore_after_capture === true;
  return proof?.required === expected
    && (expected
      ? proof.delivered === true
          && proof.requested_surface === "Gielinor Surface"
          && semanticScrollbarAtExactStop(proof.post_drag_proof, "top")
          && proof.ready_gate?.passed === true
      : proof?.delivered === false);
}

const noRecoveryP95 = percentile95(elapsed);
const inputToPostP95 = percentile95(inputToPost);
const selectorP95 = percentile95(selectorDurations);
if (noRecoveryP95 > 20_000) throw new Error(`SEMANTIC_PILOT_ITEM_P95_EXCEEDED:${noRecoveryP95}`);
if (inputToPostP95 > 2_000) throw new Error(`SEMANTIC_PILOT_INPUT_P95_EXCEEDED:${inputToPostP95}`);
if (options.profile === "terminal-realm-performance") {
  if (selectorDurations.length !== 20
      || bottomDragCount !== 20
      || verifiedSurfaceResetCount !== 20) {
    throw new Error(
      `SEMANTIC_TERMINAL_REALM_COUNTS_INVALID:${selectorDurations.length}:${bottomDragCount}:${verifiedSurfaceResetCount}`
    );
  }
  if (selectorP95 > 2_000) throw new Error(`SEMANTIC_SELECTOR_P95_EXCEEDED:${selectorP95}`);
  const maximumSelectorDuration = Math.max(...selectorDurations);
  if (maximumSelectorDuration > 3_000) {
    throw new Error(`SEMANTIC_SELECTOR_MAXIMUM_EXCEEDED:${maximumSelectorDuration}`);
  }
}

const report = {
  schema_version: 1,
  status: "SEMANTIC_PILOT_PHASE_ACCEPTED",
  profile: options.profile,
  generation_id: queue.generation_id,
  accepted_generation_ids: [...new Set(phaseCommits.map(({ commit }) => commit.generation_id))],
  queue_path: options.queue,
  queue_sha256: sha256(queueBytes),
  accepted_item_count: acceptedIDs.size,
  expected_item_count: queue.items.length,
  all_combinations_accepted: acceptedIDs.size === queue.items.length,
  performance: {
    no_recovery_item_p95_milliseconds: noRecoveryP95,
    input_to_qualified_post_capture_p95_milliseconds: inputToPostP95,
    selector_open_to_surface_qualified_p95_milliseconds: selectorP95,
    selector_open_to_surface_qualified_maximum_milliseconds: Math.max(...selectorDurations),
    hard_deadline_milliseconds: 120_000,
  },
  selector_certification: {
    bottom_drag_count: bottomDragCount,
    terminal_selection_count: options.profile === "terminal-realm-performance" ? acceptedIDs.size : 0,
    restored_capture_count: options.profile === "terminal-realm-performance"
      ? queue.items.filter((item) => item.restore_after_capture).length
      : 0,
    verified_gielinor_reset_count: verifiedSurfaceResetCount,
  },
  phase_commit_range: {
    first_sequence: phaseCommits[0]?.commit.sequence ?? null,
    last_sequence: phaseCommits.at(-1)?.commit.sequence ?? null,
  },
  sandbox_broker_head: head,
  verified_at: new Date().toISOString(),
};
writeImmutableJSON(options.output, report);
process.stdout.write(`${JSON.stringify(report)}\n`);

function validateProfileItems(profile, items) {
  const expected = semanticPilotItems(profile);
  if (items.length !== expected.length) {
    throw new Error(`SEMANTIC_PILOT_PROFILE_COUNT_INVALID:${profile}:${items.length}`);
  }
  for (const [index, item] of items.entries()) {
    const expectedItem = expected[index];
    if (combinationKey(item) !== combinationKey(expectedItem)
        || item.restore_after_capture !== expectedItem.restore_after_capture) {
      throw new Error(`SEMANTIC_PILOT_PROFILE_ITEM_INVALID:${profile}:${index + 1}`);
    }
  }
}

function combinationKey(item) {
  return [item.surface, item.zoom_percent, item.criterion_family].join("|");
}

function percentile95(values) {
  if (values.length === 0) return 0;
  const ordered = [...values].sort((first, second) => first - second);
  return ordered[Math.ceil(ordered.length * 0.95) - 1];
}

function immutableBytes(source, expectedSHA256) {
  const stat = fs.lstatSync(source);
  if (!stat.isFile() || stat.isSymbolicLink() || (stat.mode & 0o777) !== 0o444) {
    throw new Error(`SEMANTIC_PILOT_IMMUTABLE_FILE_REQUIRED:${source}`);
  }
  const bytes = fs.readFileSync(source);
  if (expectedSHA256 && sha256(bytes) !== expectedSHA256) {
    throw new Error(`SEMANTIC_PILOT_FILE_SHA256_MISMATCH:${source}`);
  }
  return bytes;
}

function writeImmutableJSON(destination, value) {
  fs.mkdirSync(path.dirname(destination), { recursive: true, mode: 0o700 });
  const descriptor = fs.openSync(destination, "wx", 0o600);
  try {
    fs.writeFileSync(descriptor, `${JSON.stringify(value, null, 2)}\n`);
    fs.fsyncSync(descriptor);
  } finally {
    fs.closeSync(descriptor);
  }
  fs.chmodSync(destination, 0o444);
}

function parseOptions(arguments_) {
  const result = {};
  for (let index = 0; index < arguments_.length; index += 2) {
    const argument = arguments_[index];
    const value = arguments_[index + 1];
    if (!argument?.startsWith("--") || !value) {
      throw new Error("SEMANTIC_PILOT_ARGUMENT_INVALID");
    }
    result[argument.slice(2)] = value;
  }
  return result;
}
