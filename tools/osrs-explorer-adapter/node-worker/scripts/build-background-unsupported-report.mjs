import { execFileSync, spawnSync } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import process from "node:process";

const options = parseArguments(process.argv.slice(2));
for (const required of ["artifact-root", "worktree", "adapter-app", "osrs-app", "output"]) {
  if (!options[required]) throw new Error(`--${required} required`);
}

const artifactRoot = path.resolve(options["artifact-root"]);
const worktree = path.resolve(options.worktree);
const adapterApp = path.resolve(options["adapter-app"]);
const osrsApp = path.resolve(options["osrs-app"]);
const outputDirectory = path.resolve(options.output);
const toolRoot = path.join(worktree, "tools/osrs-explorer-adapter");
const transitionPath = path.join(artifactRoot, "evidence/PROGRAM_TRANSITION_AND_CANONICAL_BASELINE.json");

if (fs.existsSync(outputDirectory)) throw new Error(`OUTPUT_EXISTS:${outputDirectory}`);
fs.mkdirSync(outputDirectory, { recursive: true, mode: 0o700 });

const matrixSpecifications = [
  matrix("left_click", "private_state", "queues/lab-private-state-003.json", "lab/private-state-003/worker/lab-private-state-003/private-state-item-003-failure.json"),
  matrix("left_click", "combined_session_state", "queues/lab-combined-session-002.json", "lab/combined-session-002/worker/lab-combined-session-002/combined-session-item-002-failure.json"),
  matrix("left_click", "hid_system_state", "queues/lab-hid-system-001.json", "lab/hid-system-001/worker/lab-hid-system-001/hid-system-item-001-failure.json"),
  matrix("right_click", "private_state", "queues/lab-private-right-001.json", "lab/private-right-001/worker/lab-private-right-001/private-right-item-001-failure.json"),
  matrix("right_click", "combined_session_state", "queues/lab-combined-right-001.json", "lab/combined-right-001/worker/lab-combined-right-001/combined-right-item-001-failure.json"),
  matrix("right_click", "hid_system_state", "queues/lab-hid-right-001.json", "lab/hid-right-001/worker/lab-hid-right-001/hid-right-item-001-failure.json"),
  matrix("drag", "private_state", "queues/lab-private-drag-001.json", "lab/private-drag-001/worker/lab-private-drag-001/private-drag-item-001-failure.json"),
  matrix("drag", "combined_session_state", "queues/lab-combined-drag-001.json", "lab/combined-drag-001/worker/lab-combined-drag-001/combined-drag-item-001-failure.json"),
  matrix("drag", "hid_system_state", "queues/lab-hid-drag-001.json", "lab/hid-drag-001/worker/lab-hid-drag-001/hid-drag-item-001-failure.json")
];

const matrixResults = matrixSpecifications.map(validateMatrixResult);
const axResult = validateAXResult();
const captureResult = validateCaptureResult();
const targetEventLog = validateTargetEventLog();
const canonical = validateCanonicalHead();
const tccRows = readTCCRows();
const adapterIdentity = appIdentity(adapterApp);
const labTargetIdentity = appIdentity(path.join(path.dirname(adapterApp), "Explorer Adapter Lab Target.app"));
const labCoverIdentity = appIdentity(path.join(path.dirname(adapterApp), "Explorer Adapter Lab Cover.app"));
const osrsIdentity = appIdentity(osrsApp);

for (const row of tccRows) {
  assert(row.auth_value === 2, `TCC_NOT_GRANTED:${row.service}`);
  assert(row.csreq.endsWith(adapterIdentity.cdhash.toUpperCase()), `TCC_IDENTITY_MISMATCH:${row.service}`);
}

const sourceSumsPath = path.join(outputDirectory, "SOURCE_SHA256SUMS");
const sourceSums = sourceManifest();
writeExclusive(sourceSumsPath, sourceSums);

const report = {
  schema_version: 1,
  status: "BACKGROUND_UNSUPPORTED_AWAITING_OSAMU",
  generated_at: new Date().toISOString(),
  authority: {
    supported_public_macos_apis_only: true,
    osrs_input_exercised: false,
    foreground_activation_exercised: false,
    global_event_posting_exercised: false,
    private_api_exercised: false,
    client_injection_exercised: false,
    virtualization_exercised: false,
    fallback_authorized: false
  },
  conclusion: {
    capture: "SUPPORTED_FOR_INACTIVE_FULLY_COVERED_WINDOW",
    accessibility_press: "SUPPORTED_FOR_EXPOSED_AX_PRESS_ELEMENT",
    pid_directed_core_graphics: "UNSUPPORTED_FOR_REQUIRED_BACKGROUND_LEFT_CLICK_RIGHT_CLICK_AND_DRAG",
    osrs_capability_proof: "NOT_ATTEMPTED_MANDATORY_LAB_GATE_FAILED",
    full_explorer_rollout: "FORBIDDEN_PENDING_OSAMU_DECISION",
    reason: "CGEventPostToPid preserved foreground invariants for every tested source/action pair but delivered no event and produced no visual change in the inactive covered laboratory target. AXPress succeeded only for an exposed semantic button and cannot provide the required arbitrary-coordinate right-click and drag workflow."
  },
  classification: {
    capture_failure: false,
    laboratory_event_rejection: true,
    osrs_event_rejection: false,
    focus_violation_in_final_matrix: false,
    visual_verification_failure: true,
    unresolved_ambiguity: false,
    preliminary_invalid_runs: [
      {
        generation_id: "lab-private-state-001",
        classification: "INVALIDATED_BY_1_79742431640625_PIXEL_EXTERNAL_CURSOR_DRIFT",
        evidence: evidenceReference("lab/private-state-001/worker/lab-private-state-001/private-state-item-001-failure.json")
      },
      {
        generation_id: "lab-private-state-002",
        classification: "INVALIDATED_BY_HOST_SELF_EVENT_TOUCH_FILTER",
        disposition: "repo_owned_filter_corrected_before_final_matrix"
      },
      {
        generation_id: "lab-combined-session-001",
        classification: "CANCELED_UNCLAIMED_AFTER_PREDECESSOR_WORKER_TERMINATED"
      }
    ]
  },
  tested_apis: [
    {
      api: "ScreenCaptureKit SCStream",
      configuration: "SCContentFilter desktopIndependentWindow; audio disabled; target inactive and fully covered",
      result: "PASS"
    },
    {
      api: "AXUIElementPerformAction",
      configuration: "kAXPressAction on the deepest press-capable element containing the captured coordinate",
      result: "PASS_FOR_EXPOSED_BUTTON_ONLY"
    },
    {
      api: "CGEventPostToPid",
      configuration: "leftMouseDown/up, rightMouseDown/up, and 12-step leftMouseDragged sequence",
      event_source_states: ["private_state", "combined_session_state", "hid_system_state"],
      result: "FAIL_TARGET_DELIVERY_ALL_9_CASES"
    }
  ],
  coordinate_transform: {
    formula: {
      screen_x: "window_x + image_x / pixel_width * window_width",
      screen_y: "window_y + image_y / pixel_height * window_height"
    },
    capture_pixels: { width: 1280, height: 1024 },
    target_frame_points: { x: 240, y: 392, width: 640, height: 512 },
    points: {
      left_click_image: { x: 300, y: 400 },
      left_click_screen: { x: 390, y: 592 },
      right_click_image: { x: 900, y: 700 },
      right_click_screen: { x: 690, y: 742 },
      drag_from_image: { x: 300, y: 600 },
      drag_from_screen: { x: 390, y: 692 },
      drag_to_image: { x: 950, y: 750 },
      drag_to_screen: { x: 715, y: 767 },
      ax_press_image: { x: 200, y: 170 },
      ax_press_screen: { x: 340, y: 477 }
    }
  },
  capture_qualification: captureResult,
  accessibility_qualification: axResult,
  core_graphics_negative_matrix: matrixResults,
  target_event_log: targetEventLog,
  identities: {
    host: {
      sw_vers: command("sw_vers", []),
      uname: command("uname", ["-a"]),
      xcode: command("xcodebuild", ["-version"]),
      swift: command("swift", ["--version"]),
      node: { executable: process.execPath, version: process.version },
      architecture: process.arch
    },
    adapter: adapterIdentity,
    laboratory_target: labTargetIdentity,
    laboratory_cover: labCoverIdentity,
    osrs_client: {
      ...osrsIdentity,
      interaction_attempted: false,
      runtime_process_started_by_research: false
    },
    permissions: tccRows,
    window_and_process: {
      laboratory_target: matrixResults[0].target,
      target_event_process_id: targetEventLog.records[0].process_id,
      final_matrix_frontmost_process_ids: unique(matrixResults.flatMap(({ focus_invariant }) => [focus_invariant.before.frontmostProcessIdentifier, focus_invariant.after.frontmostProcessIdentifier])),
      final_matrix_focused_process_ids: unique(matrixResults.flatMap(({ focus_invariant }) => [focus_invariant.before.focusedProcessIdentifier, focus_invariant.after.focusedProcessIdentifier])),
      target_window_ids: unique(matrixResults.map(({ target }) => target.windowIdentifier)),
      target_window_ranks: unique(matrixResults.flatMap(({ focus_invariant }) => [focus_invariant.before.targetWindowRank, focus_invariant.after.targetWindowRank])),
      ordered_window_traces_are_embedded_per_matrix_case: true,
      laboratory_cover_geometry_points: { x: 220, y: 372, width: 680, height: 552 },
      target_geometry_points: { x: 240, y: 392, width: 640, height: 512 },
      target_fully_inside_cover: true
    }
  },
  invariants: summarizeInvariants(matrixResults, axResult),
  canonical_head_post_research: canonical,
  source_provenance: {
    worktree,
    branch: command("git", ["-C", worktree, "branch", "--show-current"]),
    commit: command("git", ["-C", worktree, "rev-parse", "HEAD"]),
    status: command("git", ["-C", worktree, "status", "--short"]),
    source_sha256sums: reference(sourceSumsPath)
  },
  reproduction: {
    build: "cd tools/osrs-explorer-adapter && ./scripts/build-apps.sh <artifact-root>/build/apps",
    tests: [
      "cd tools/osrs-explorer-adapter && swift test",
      "cd tools/osrs-explorer-adapter/node-worker && npm test"
    ],
    queue_generator: "node tools/osrs-explorer-adapter/node-worker/scripts/create-lab-queue.mjs --output <queue> --artifact-root <case-root> --generation <generation> --mode <left-click|right-click|drag|ax> --item-id <item> --event-source-mode <private_state|combined_session_state|hid_system_state> [...coordinates]",
    activation: "osrs-explorerctl --runtime-root /tmp/osrs-explorer-adapter-501 queue-activate <queue> <sha256>; select Enable or Resume (manual) from the adapter menu",
    exact_queue_manifests: matrixResults.map(({ queue_manifest }) => queue_manifest),
    ax_queue_manifest: axResult.queue_manifest
  },
  evidence_closure: {
    report_root: outputDirectory,
    matrix_case_count: matrixResults.length,
    expected_matrix_case_count: 9,
    all_matrix_invariants_passed: matrixResults.every(({ focus_invariant }) => focus_invariant.passed),
    all_matrix_visual_acks_missing: matrixResults.every(({ visual_changed }) => !visual_changed),
    all_matrix_target_events_missing: targetEventLog.core_graphics_event_count === 0,
    ax_visual_ack_passed: axResult.visual_changed,
    ax_target_event_count: targetEventLog.ax_event_count,
    residual_adapter_lab_worker_processes: processMatches()
  },
  unexecuted_options: [
    {
      option: "ISOLATED_GUI_OR_VM",
      executed: false,
      risk: "Separate desktop/session complexity, capture plumbing, resource cost, and account-policy review.",
      expected_effort: "medium_to_high",
      decision_required: "Osamu must explicitly authorize after reviewing this report."
    },
    {
      option: "PRIVATE_API_RESEARCH",
      executed: false,
      risk: "Unsupported behavior, OS updates can break it, signing/notarization risk, and a larger security surface.",
      expected_effort: "high",
      decision_required: "Osamu must explicitly authorize after reviewing this report."
    },
    {
      option: "FOREGROUND_FOCUS_LEASING",
      executed: false,
      risk: "Interrupts normal machine use, can misroute input, changes z-order/focus, and violates the preferred full-background requirement.",
      expected_effort: "low_to_medium",
      decision_required: "Osamu must explicitly authorize after reviewing this report."
    }
  ],
  next_action: "PAUSE_ALL_ADAPTER_AND_EXPLORER_WORK_UNTIL_OSAMU_SELECTS_A_DIRECTION"
};

assert(report.evidence_closure.matrix_case_count === 9, "MATRIX_COUNT_MISMATCH");
assert(report.evidence_closure.all_matrix_invariants_passed, "MATRIX_INVARIANT_FAILURE");
assert(report.evidence_closure.all_matrix_visual_acks_missing, "UNEXPECTED_MATRIX_VISUAL_ACK");
assert(report.evidence_closure.all_matrix_target_events_missing, "UNEXPECTED_MATRIX_TARGET_EVENT");
assert(report.evidence_closure.ax_visual_ack_passed, "AX_VISUAL_ACK_MISSING");
assert(report.evidence_closure.ax_target_event_count === 1, "AX_TARGET_EVENT_COUNT_MISMATCH");
assert(report.evidence_closure.residual_adapter_lab_worker_processes.length === 0, "RUNTIME_NOT_QUIESCENT");

const reportPath = path.join(outputDirectory, "BACKGROUND_UNSUPPORTED_REPORT.json");
const markdownPath = path.join(outputDirectory, "STATUS_REPORT.md");
writeExclusive(reportPath, `${JSON.stringify(report, null, 2)}\n`);
writeExclusive(markdownPath, markdown(report));

const sumsPath = path.join(outputDirectory, "SHA256SUMS");
const reportMembers = [reportPath, markdownPath, sourceSumsPath];
const sums = reportMembers
  .map((file) => `${sha256File(file)}  ${path.basename(file)}`)
  .sort()
  .join("\n") + "\n";
writeExclusive(sumsPath, sums);

for (const file of [...reportMembers, sumsPath]) fs.chmodSync(file, 0o444);
fs.chmodSync(outputDirectory, 0o555);

process.stdout.write(`${JSON.stringify({
  status: report.status,
  report: reference(reportPath),
  markdown: reference(markdownPath),
  source_sha256sums: reference(sourceSumsPath),
  sha256sums: reference(sumsPath)
})}\n`);

function matrix(action, source, queue, result) {
  return { action, source, queue, result };
}

function validateMatrixResult(specification) {
  const queuePath = path.join(artifactRoot, specification.queue);
  const resultPath = path.join(artifactRoot, specification.result);
  const queue = readJson(queuePath);
  const result = readJson(resultPath);
  const initial = result.evidence.find(({ kind }) => kind === "capture")?.capture;
  const actionEvidence = result.evidence.find(({ kind }) => kind === actionKind(specification.action));
  const post = result.evidence.find(({ kind }) => kind === "post_capture")?.capture;
  assert(initial && post && actionEvidence?.input_evidence, `INCOMPLETE_CASE:${specification.action}:${specification.source}`);
  assert(result.error.includes(`LAB_VISUAL_ACK_MISSING:${actionKind(specification.action)}:${specification.source}`), `WRONG_FAILURE:${resultPath}`);
  verifyCapture(initial);
  verifyCapture(post);
  const inputPath = actionEvidence.input_evidence.path;
  assert(sha256File(inputPath) === actionEvidence.input_evidence.sha256, `INPUT_HASH_MISMATCH:${inputPath}`);
  const input = readJson(inputPath);
  assert(input.mechanism === "CG_EVENT_POST_TO_PID", `WRONG_MECHANISM:${inputPath}`);
  assert(input.eventSourceMode === specification.source, `WRONG_EVENT_SOURCE:${inputPath}`);
  assert(input.focusInvariant.passed, `FOCUS_INVARIANT_FAILED:${inputPath}`);
  assert(initial.pngSHA256 === post.pngSHA256, `UNEXPECTED_VISUAL_CHANGE:${resultPath}`);
  return {
    action: specification.action,
    event_source_mode: specification.source,
    outcome: "TARGET_EVENT_AND_VISUAL_ACK_MISSING",
    queue_manifest: reference(queuePath),
    queue_policy_digest: queue.policy_digest,
    item_sha256: queue.items[0].item_sha256,
    failure: evidenceReference(specification.result),
    exact_error: result.error,
    initial_capture: captureReference(initial),
    post_capture: captureReference(post),
    visual_changed: initial.pngSHA256 !== post.pngSHA256,
    input_evidence: reference(inputPath),
    focus_invariant: input.focusInvariant,
    target: input.target,
    requested_action: input.action,
    event_sequence: eventSequence(specification.action)
  };
}

function validateAXResult() {
  const queuePath = path.join(artifactRoot, "queues/lab-ax-press-001.json");
  const resultPath = path.join(artifactRoot, "lab/ax-press-001/worker/lab-ax-press-001/ax-press-item-001.json");
  const queue = readJson(queuePath);
  const result = readJson(resultPath);
  const initial = result.evidence.find(({ kind }) => kind === "capture")?.capture;
  const actionEvidence = result.evidence.find(({ kind }) => kind === "click");
  const post = result.evidence.find(({ kind }) => kind === "post_capture")?.capture;
  assert(initial && post && actionEvidence?.input_evidence, "AX_RESULT_INCOMPLETE");
  verifyCapture(initial);
  verifyCapture(post);
  const inputPath = actionEvidence.input_evidence.path;
  assert(sha256File(inputPath) === actionEvidence.input_evidence.sha256, "AX_INPUT_HASH_MISMATCH");
  const input = readJson(inputPath);
  assert(input.mechanism === "AX_PRESS", "AX_MECHANISM_MISMATCH");
  assert(input.focusInvariant.passed, "AX_FOCUS_INVARIANT_FAILED");
  assert(initial.pngSHA256 !== post.pngSHA256, "AX_VISUAL_STATE_UNCHANGED");
  return {
    outcome: "PASS_BACKGROUND_AX_PRESS",
    queue_manifest: reference(queuePath),
    result: reference(resultPath),
    input_evidence: reference(inputPath),
    initial_capture: captureReference(initial),
    post_capture: captureReference(post),
    visual_changed: true,
    focus_invariant: input.focusInvariant,
    target: input.target
  };
}

function validateCaptureResult() {
  const resultPath = path.join(artifactRoot, "lab/capture-002/worker/lab-capture-002/capture-item-001.json");
  const result = readJson(resultPath);
  const capture = result.evidence.find(({ kind }) => kind === "capture")?.capture;
  assert(capture, "CAPTURE_RESULT_INCOMPLETE");
  verifyCapture(capture);
  return {
    outcome: "PASS_INACTIVE_FULLY_COVERED_CAPTURE",
    result: reference(resultPath),
    capture: captureReference(capture),
    target_was_inactive: true,
    target_was_fully_covered: true,
    minimized_or_hidden_required: false
  };
}

function validateTargetEventLog() {
  const logPath = path.join(artifactRoot, "lab/events-hardened.jsonl");
  const records = fs.readFileSync(logPath, "utf8").trim().split("\n").map(JSON.parse);
  const cgEvents = records.filter(({ kind }) => /mouse/.test(kind));
  const axEvents = records.filter(({ kind }) => kind === "ax_button_press");
  assert(records[0]?.kind === "target_started", "TARGET_START_EVENT_MISSING");
  assert(records.every(({ app_is_active }) => app_is_active === false), "TARGET_BECAME_ACTIVE");
  assert(cgEvents.length === 0, "UNEXPECTED_CG_TARGET_EVENT");
  assert(axEvents.length === 1, "AX_EVENT_COUNT_MISMATCH");
  return {
    log: reference(logPath),
    records,
    core_graphics_event_count: cgEvents.length,
    ax_event_count: axEvents.length,
    target_remained_inactive: true
  };
}

function validateCanonicalHead() {
  const transition = readJson(transitionPath);
  const expected = transition.canonical_head;
  const head = readJson(expected.path);
  const stat = fs.statSync(expected.path);
  const actual = {
    path: expected.path,
    sequence: head.sequence,
    commit_sha256: head.commit_sha256,
    sha256: sha256File(expected.path),
    mode: (stat.mode & 0o777).toString(8).padStart(4, "0"),
    inode: stat.ino,
    size: stat.size,
    verified_at: new Date().toISOString()
  };
  for (const field of ["sequence", "commit_sha256", "sha256", "mode", "inode", "size"]) {
    assert(actual[field] === expected[field], `CANONICAL_HEAD_CHANGED:${field}`);
  }
  return { ...actual, unchanged_from_transition: true, transition: reference(transitionPath) };
}

function readTCCRows() {
  const database = "/Library/Application Support/com.apple.TCC/TCC.db";
  const query = "SELECT service,client,auth_value,datetime(last_modified,'unixepoch','localtime') AS modified,hex(csreq) AS csreq FROM access WHERE client='com.omiyawaki.osrswiki.explorer-adapter' ORDER BY service";
  const rows = JSON.parse(execFileSync("sqlite3", ["-json", database, query], { encoding: "utf8" }) || "[]");
  assert(rows.some(({ service }) => service === "kTCCServiceAccessibility"), "ACCESSIBILITY_TCC_MISSING");
  assert(rows.some(({ service }) => service === "kTCCServiceScreenCapture"), "SCREEN_CAPTURE_TCC_MISSING");
  return rows;
}

function appIdentity(appPath) {
  const plist = path.join(appPath, "Contents/Info.plist");
  const executableName = plistRaw(plist, "CFBundleExecutable") || path.basename(appPath, ".app");
  const executable = executableName
    ? path.join(appPath, "Contents/MacOS", executableName)
    : findSingleExecutable(path.join(appPath, "Contents/MacOS"));
  const codesign = commandCombined("codesign", ["-dvvv", appPath]);
  const cdhash = codesign.match(/^CDHash=([0-9a-f]+)$/mi)?.[1];
  const full = codesign.match(/^CandidateCDHashFull sha256=([0-9a-f]+)$/mi)?.[1];
  assert(cdhash, `CDHASH_MISSING:${appPath}`);
  return {
    path: appPath,
    bundle_identifier: plistRaw(plist, "CFBundleIdentifier"),
    short_version: plistRaw(plist, "CFBundleShortVersionString"),
    bundle_version: plistRaw(plist, "CFBundleVersion"),
    executable,
    executable_sha256: sha256File(executable),
    executable_size: fs.statSync(executable).size,
    architecture: command("file", [executable]),
    cdhash,
    candidate_cdhash_full_sha256: full,
    team_identifier: codesign.match(/^TeamIdentifier=(.+)$/mi)?.[1] ?? null,
    codesign_details: codesign
  };
}

function sourceManifest() {
  const files = command("git", ["-C", worktree, "ls-files", "tools/osrs-explorer-adapter"])
    .split("\n")
    .filter(Boolean)
    .sort();
  assert(files.length > 0, "SOURCE_FILES_MISSING");
  return files.map((relative) => `${sha256File(path.join(worktree, relative))}  ${relative}`).join("\n") + "\n";
}

function summarizeInvariants(matrixResults, ax) {
  const traces = [...matrixResults.map(({ focus_invariant }) => focus_invariant), ax.focus_invariant];
  return {
    trace_count: traces.length,
    frontmost_pid_preserved: traces.every((trace) => trace.before.frontmostProcessIdentifier === trace.after.frontmostProcessIdentifier),
    focused_pid_preserved: traces.every((trace) => trace.before.focusedProcessIdentifier === trace.after.focusedProcessIdentifier),
    window_order_preserved: traces.every((trace) => JSON.stringify(trace.before.orderedWindowIdentifiers) === JSON.stringify(trace.after.orderedWindowIdentifiers)),
    active_space_preserved: traces.every((trace) => trace.before.activeSpaceChangeCount === trace.after.activeSpaceChangeCount),
    physical_cursor_preserved: traces.every((trace) => trace.before.cursor.x === trace.after.cursor.x && trace.before.cursor.y === trace.after.cursor.y),
    target_rank_preserved: traces.every((trace) => trace.before.targetWindowRank === trace.after.targetWindowRank),
    timestamped_traces: traces
  };
}

function markdown(report) {
  const matrixLines = report.core_graphics_negative_matrix.map((entry) =>
    `| ${entry.action} | ${entry.event_source_mode} | no target event or pixel change | pass |`
  ).join("\n");
  return `# Background Adapter Pause Report

Status: \`${report.status}\`

## Result

Covered ScreenCaptureKit capture works, and AX can press an exposed semantic button while the target stays inactive. The required arbitrary-coordinate background input does not work: all nine \`CGEventPostToPid\` action/source combinations preserved focus, z-order, Space, and cursor position but produced no target event and no visual change.

The OSRS proof was not attempted because the mandatory laboratory gate failed. No foreground, VM, private API, injection, or global-posting fallback was tested.

| Action | Event source | Target result | Foreground invariants |
| --- | --- | --- | --- |
${matrixLines}

## What Passed

- Inactive, fully covered 1280x1024 ScreenCaptureKit capture.
- Background \`AXUIElementPerformAction(kAXPressAction)\` with a fresh visual acknowledgement.
- All final action traces preserved frontmost PID, focused PID, ordered windows, active Space, target rank, and physical cursor.
- Canonical sequence ${report.canonical_head_post_research.sequence}, commit \`${report.canonical_head_post_research.commit_sha256}\`, HEAD hash \`${report.canonical_head_post_research.sha256}\`, and mode \`${report.canonical_head_post_research.mode}\` remain unchanged.

## Why Work Paused

AXPress is limited to exposed accessibility actions and does not provide the coordinate right-click and drag primitives required by the map workflow. PID-directed Core Graphics events were accepted by the host but were not delivered to the inactive covered target under any public event-source state tested.

## Unexecuted Options

- Isolated GUI or VM operation: medium-to-high effort and separate policy/resource review.
- Private API research: high effort, unsupported, brittle, and security/signing risk.
- Foreground focus leasing: lower effort but interrupts normal use and violates the preferred background requirement.

No option above is authorized. Osamu must review this packet and explicitly select a direction before work resumes.
`;
}

function eventSequence(action) {
  if (action === "left_click") return ["leftMouseDown", "leftMouseUp"];
  if (action === "right_click") return ["rightMouseDown", "rightMouseUp"];
  return ["leftMouseDown", "12 x leftMouseDragged at 8 ms intervals", "leftMouseUp"];
}

function actionKind(action) {
  return action === "drag" ? "drag" : "click";
}

function verifyCapture(capture) {
  assert(fs.existsSync(capture.pngPath), `CAPTURE_MISSING:${capture.pngPath}`);
  assert(sha256File(capture.pngPath) === capture.pngSHA256, `CAPTURE_HASH_MISMATCH:${capture.pngPath}`);
  assert(capture.pixelWidth === 1280 && capture.pixelHeight === 1024, `CAPTURE_DIMENSION_MISMATCH:${capture.pngPath}`);
}

function captureReference(capture) {
  return {
    capture_identifier: capture.captureIdentifier,
    captured_at: capture.capturedAt,
    png: reference(capture.pngPath),
    pixel_width: capture.pixelWidth,
    pixel_height: capture.pixelHeight,
    target: capture.target
  };
}

function evidenceReference(relative) {
  return reference(path.join(artifactRoot, relative));
}

function reference(file) {
  return { path: file, sha256: sha256File(file), size: fs.statSync(file).size };
}

function processMatches() {
  const output = command("ps", ["-ax", "-o", "pid=,ppid=,command="]);
  const rows = output.split("\n").flatMap((line) => {
    const match = line.match(/^\s*(\d+)\s+(\d+)\s+(.+)$/);
    return match ? [{ pid: Number(match[1]), ppid: Number(match[2]), command: match[3] }] : [];
  });
  const rowsByPid = new Map(rows.map((row) => [row.pid, row]));
  const excludedPids = new Set([process.pid]);
  let ancestorPid = process.ppid;
  while (ancestorPid > 0 && !excludedPids.has(ancestorPid)) {
    excludedPids.add(ancestorPid);
    ancestorPid = rowsByPid.get(ancestorPid)?.ppid ?? 0;
  }

  return rows
    .filter((row) => !excludedPids.has(row.pid))
    .filter((row) => /OSRS Explorer Adapter|Explorer Adapter Lab|node-worker\/src\/worker\.mjs/.test(row.command))
    .map((row) => `${row.pid} ${row.ppid} ${row.command}`);
}

function plistRaw(plist, key) {
  const result = spawnSync("plutil", ["-extract", key, "raw", "-o", "-", plist], { encoding: "utf8" });
  return result.status === 0 ? result.stdout.trim() : "";
}

function findSingleExecutable(directory) {
  const entries = fs.readdirSync(directory)
    .map((name) => path.join(directory, name))
    .filter((entry) => fs.statSync(entry).isFile() && (fs.statSync(entry).mode & 0o111));
  assert(entries.length === 1, `EXECUTABLE_AMBIGUOUS:${directory}`);
  return entries[0];
}

function command(executable, arguments_) {
  return execFileSync(executable, arguments_, { encoding: "utf8" }).trim();
}

function commandCombined(executable, arguments_) {
  const result = spawnSync(executable, arguments_, { encoding: "utf8" });
  assert(result.status === 0, `COMMAND_FAILED:${executable}:${result.stderr}`);
  return `${result.stdout}${result.stderr}`.trim();
}

function unique(values) {
  return [...new Set(values)];
}

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

function sha256File(file) {
  return crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex");
}

function writeExclusive(destination, data) {
  fs.writeFileSync(destination, data, { flag: "wx", mode: 0o444 });
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function parseArguments(arguments_) {
  const result = {};
  for (let index = 0; index < arguments_.length; index += 2) {
    const key = arguments_[index];
    if (!key?.startsWith("--") || !arguments_[index + 1]) throw new Error(`invalid argument ${key}`);
    result[key.slice(2)] = arguments_[index + 1];
  }
  return result;
}
