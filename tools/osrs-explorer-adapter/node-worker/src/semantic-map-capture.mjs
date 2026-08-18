import sharp from "sharp";

import { evaluateNovelty, meanDifference } from "../derived/reviewed-v4/runtime/explorer-v4-runtime.mjs";
import { captureAuthorizedOSRSPostAction } from "./post-action-qualification.mjs";
import {
  classifyCapture,
  classifySemanticPostCloseCapture,
  localizeSemanticCoverageMapClose,
  localizeSemanticMapClose,
  localizeSemanticSurfaceOption,
  localizeSemanticSurfaceScrollbar,
  observeSemanticSurfaceScrollbar,
  localizeSemanticSurfaceSelector,
  localizeSemanticZoom,
  proveSemanticCoverageReadiness,
  proveSemanticMapReadiness,
  requireAuthorizedOSRSCoverageMap,
  requireAuthorizedOSRSMap,
} from "./perception.mjs";
import { executeInlineSemanticRecovery } from "./recovery.mjs";
import {
  coverageAnchorCenter,
  coverageReferenceChunks,
  coverageReferenceDelta,
  NATIVE_REALM_COVERAGE_CHUNK_LIMITS,
  NATIVE_REALM_COVERAGE_PLANNER_VERSION,
} from "./native-realm-coverage.mjs";
import {
  CONTENT_CROP,
  DISPLACEMENT_CELL_SIZE,
  isRepeatedTerminalRealmPerformanceCycle,
  MAP_ACTION_REGION,
  MAP_CROP,
  NATIVE_COVERAGE_CROP,
  MOTION_ANCHOR_TRANSLATION_MAXIMUM,
  MOTION_VECTORS,
  NOVELTY_THRESHOLDS,
  REVIEWED_FRAME,
  loadSemanticCalibrationRegistry,
  measuredInverseMotionVector,
  motionVector,
  normalizedPoint,
  restorationDisplacementForMotion,
  selectorScrollbarVector,
  semanticScrollbarAtExactStop,
  semanticScrollbarLandingAccepted,
  semanticSurfaceNavigation,
  validateSemanticQueueItem,
} from "./semantic-profile.mjs";

const zoomLadder = Object.freeze([37.5, 50, 75, 100, 200]);
const RESET_RELATIVE_COVERAGE_PLANNER_VERSIONS = new Set([
  "native-realm-coverage-planner-v3",
  "native-realm-coverage-planner-v9",
  NATIVE_REALM_COVERAGE_PLANNER_VERSION,
]);
const BOUNDARY_ANCHORED_COVERAGE_PLANNER_VERSIONS = new Set([
  "native-realm-coverage-planner-v8",
]);
const CLOSE_REOPEN_COVERAGE_PLANNER_VERSIONS = new Set([
  "native-realm-coverage-planner-v9",
  NATIVE_REALM_COVERAGE_PLANNER_VERSION,
]);
const SPARSE_RETENTION_MINIMUM_FRACTION = 0.2;
const SPARSE_RETENTION_MINIMUM_INFORMATIVE_PIXELS = 64;
const SPARSE_RETENTION_MINIMUM_CHROMATIC_PIXELS = 8;
const PAN_SETTLE_MILLISECONDS = 250;
const ZOOM_TRANSITION_OBSERVATION_ATTEMPTS = 3;
const SPARSE_ZOOM_MINIMUM_INFORMATIVE_PIXELS = 64;
const SPARSE_ZOOM_MINIMUM_CHROMATIC_PIXELS = 8;
const SPARSE_ZOOM_MAXIMUM_INFORMATIVE_FRACTION = 0.2;
const SPARSE_ZOOM_MINIMUM_LINEAR_GROWTH = 1.08;
const SPARSE_ZOOM_MAXIMUM_LINEAR_GROWTH = 2.5;
const SPARSE_ZOOM_MINIMUM_SUPPORT_GROWTH = 1.15;
const SPARSE_ZOOM_MAXIMUM_CENTER_DISPLACEMENT = 5;
const NATIVE_COVERAGE_ACTION_MARGIN = 12;
const NATIVE_COVERAGE_DISPLACEMENT_TOLERANCE = 10;
const NATIVE_COVERAGE_ALIGNMENT_MEAN_ABS_MAXIMUM = 25;
const NATIVE_COVERAGE_INFORMATIVE_COVERAGE_MINIMUM = 0.5;
const NATIVE_COVERAGE_EXPECTATION_BIAS_PER_HALF_PIXEL = 0.01;
const NATIVE_COVERAGE_EDGE_MINIMUM = 3;
const NATIVE_COVERAGE_MINIMUM_EDGE_PIXELS = 64;
const NATIVE_COVERAGE_BOUNDARY_MINIMUM_CHANGED_PIXELS = 64;
const NATIVE_COVERAGE_BOUNDARY_MINIMUM_SPARSE_CHANGED_PIXELS = 16;
const NATIVE_COVERAGE_BOUNDARY_MINIMUM_SPARSE_INFORMATIVE_PIXELS = 32;
const NATIVE_COVERAGE_BOUNDARY_MINIMUM_SPARSE_TURNOVER_FRACTION = 0.5;
const NATIVE_COVERAGE_BOUNDARY_MINIMUM_TURNOVER_FRACTION = 0.75;
const NATIVE_COVERAGE_BOUNDARY_MAXIMUM_SHARED_PIXELS = 63;
const NATIVE_COVERAGE_CONTENT_MINIMUM_INFORMATIVE_PIXELS = 64;
const NATIVE_COVERAGE_CONTENT_MINIMUM_CHROMATIC_PIXELS = 8;
const NATIVE_COVERAGE_CONTENT_MINIMUM_STRUCTURAL_EDGE_PIXELS = 64;

export async function executeSemanticMapCapture({
  claim,
  deadline,
  captureFrame,
  performAction,
  writeMapCrop,
  loadSameFamilyRaw = async () => null,
  wait = delay,
  perception = defaultPerception,
  analysis = defaultAnalysis,
  recoverInitialMap = recoverInitialSemanticMap,
}) {
  const item = validateSemanticQueueItem(claim.item);
  const semanticCoverageCrop = item.realm_id
    ? item.coverage_cell?.coverage_crop ?? NATIVE_COVERAGE_CROP
    : NATIVE_COVERAGE_CROP;
  const evidence = [];
  const actionHistory = [];
  const zoomTransitions = [];
  const started = performance.now();

  await perception.requireSemanticCalibrationGate();
  let capture = await captureFrame();
  assertDeadline(deadline);
  const closeReopenCoverage = CLOSE_REOPEN_COVERAGE_PLANNER_VERSIONS.has(
    item.planner_version
  );
  const recovery = await recoverInitialMap({
    initialCapture: capture,
    coverageSurface: closeReopenCoverage ? item.surface : null,
    deadline,
    captureFrame,
    performAction,
    wait,
    perception,
  });
  capture = recovery.capture;
  const initialClassification = recovery.classification;
  actionHistory.push(...recovery.actions);
  evidence.push(...recovery.evidence);
  evidence.push({ kind: "semantic_qualification", capture, classification: initialClassification });

  const productionSelector = item.realm_id !== undefined || item.catalog_version !== undefined;
  let coverageResetProof = null;
  if (closeReopenCoverage) {
    const beforeClose = capture;
    const localizeClose = perception.localizeSemanticCoverageMapClose
      ?? perception.localizeSemanticMapClose;
    const closeLocalization = await localizeClose(beforeClose.pngPath, item.surface);
    actionHistory.push(await act({
      role: "coverage_map_close",
      kind: "click",
      point: closeLocalization.source_click_point,
      button: "left",
      capture: beforeClose,
      performAction,
    }));
    const closedCapture = await captureAuthorizedOSRSPostAction({
      captureFrame,
      classify: async (pngPath) => {
        const classification = await (
          perception.classifySemanticPostCloseCapture
          ?? perception.classifyCapture
        )(pngPath);
        if (classification.recovery_state !== "GAMEPLAY_NO_MAP"
            || classification.connection !== "CONNECTED"
            || classification.committable !== false) {
          throw new Error("SEMANTIC_COVERAGE_MAP_CLOSE_UNPROVEN");
        }
        return classification;
      },
      recordEvidence: () => {},
      attempts: 6,
      intervalMilliseconds: 250,
      wait,
    });
    if (closedCapture.pngSHA256 === beforeClose.pngSHA256) {
      throw new Error("SEMANTIC_COVERAGE_MAP_CLOSE_NO_TRANSITION");
    }
    const closedClassification = await (
      perception.classifySemanticPostCloseCapture
      ?? perception.classifyCapture
    )(closedCapture.pngPath);
    actionHistory.push(await act({
      role: "coverage_map_reopen",
      kind: "open_world_map",
      capture: closedCapture,
      performAction,
    }));
    capture = await captureReadyAfterControl({
      captureFrame,
      surface: "Gielinor Surface",
      label: "COVERAGE_MAP_REOPEN",
      perception,
      wait,
    });
    if (capture.pngSHA256 === closedCapture.pngSHA256) {
      throw new Error("SEMANTIC_COVERAGE_MAP_REOPEN_NO_TRANSITION");
    }
    coverageResetProof = {
      mode: "map_close_reopen",
      before_close_capture: beforeClose,
      close_localization: closeLocalization,
      closed_capture: closedCapture,
      closed_classification: closedClassification,
      reopened_capture: capture,
      reopened_gate: await proveReady(
        capture,
        "Gielinor Surface",
        "COVERAGE_MAP_REOPEN",
        perception
      ),
    };
  } else if (RESET_RELATIVE_COVERAGE_PLANNER_VERSIONS.has(item.planner_version)
      && !BOUNDARY_ANCHORED_COVERAGE_PLANNER_VERSIONS.has(item.planner_version)) {
    const resetSurface = item.surface === "Gielinor Surface"
      ? "Ancient Cavern"
      : "Gielinor Surface";
    const reset = await selectSemanticSurface({
      capture,
      surface: resetSurface,
      productionSelector: true,
      deadline,
      captureFrame,
      performAction,
      perception,
      actionHistory,
      roles: {
        open: "coverage_reset_selector_open",
        drag: "coverage_reset_scrollbar_drag",
        select: "coverage_reset_option_select",
      },
      label: "COVERAGE_RESET_SURFACE",
    });
    capture = reset.readyCapture;
    coverageResetProof = {
      reset_surface: resetSurface,
      selector_capture: reset.selectorCapture,
      selector_localization: reset.selector,
      selector_navigation: {
        ...reset.navigationPlan,
        drags: reset.navigationTransitions.length,
        transitions: reset.navigationTransitions,
      },
      option_capture: reset.optionCapture,
      option_localization: reset.option,
      ready_capture: reset.readyCapture,
      ready_gate: reset.readyGate,
    };
  }

  const targetSelection = await selectSemanticSurface({
    capture,
    surface: item.surface,
    productionSelector,
    deadline,
    captureFrame,
    performAction,
    perception,
    actionHistory,
    roles: {
      open: "surface_selector_open",
      drag: "surface_selector_scrollbar_drag",
      select: "surface_option_select",
    },
    label: "SURFACE",
  });
  capture = targetSelection.readyCapture;
  const {
    selector,
    selectorCapture,
    navigationPlan,
    navigationTransitions,
    optionCapture,
    option,
    readyCapture: surfaceReadyCapture,
    readyGate: surfaceGate,
    navigationStarted: selectorNavigationStarted,
    qualifiedAt: selectorQualified,
  } = targetSelection;

  let consecutiveMinimumProofs = 0;
  let minusClicks = 0;
  while (minusClicks < 8 && consecutiveMinimumProofs < 2) {
    assertDeadline(deadline);
    const before = capture;
    const beforeRaw = await analysis.contentRaw(before.pngPath);
    const minus = await perception.localizeSemanticZoom(before.pngPath, "minus");
    actionHistory.push(await act({
      role: "zoom_minus",
      kind: "click",
      point: minus.source_click_point,
      button: "left",
      capture: before,
      performAction,
    }));
    minusClicks += 1;
    await wait(250);
    capture = await captureReadyAfterControl({
      captureFrame,
      surface: item.surface,
      label: `ZOOM_MINUS_${minusClicks}`,
      perception,
      wait,
    });
    const difference = analysis.meanDifference(beforeRaw, await analysis.contentRaw(capture.pngPath));
    const transitioned = difference >= NOVELTY_THRESHOLDS.zoom_transition_mean_abs_minimum;
    consecutiveMinimumProofs = transitioned ? 0 : consecutiveMinimumProofs + 1;
    zoomTransitions.push({
      direction: "minus",
      ordinal: minusClicks,
      before_capture: before,
      after_capture: capture,
      mean_abs_difference: difference,
      scale_transition: transitioned,
    });
  }
  if (consecutiveMinimumProofs < 2) throw new Error("SEMANTIC_ZOOM_MINIMUM_UNPROVEN");

  const ascentCount = zoomLadder.indexOf(item.zoom_percent);
  if (ascentCount < 0) throw new Error("SEMANTIC_ZOOM_UNSUPPORTED");
  for (let index = 0; index < ascentCount; index += 1) {
    assertDeadline(deadline);
    const before = capture;
    const beforeRaw = await analysis.contentRaw(before.pngPath);
    const beforeSparseRaw = item.realm_id
      && analysis.nativeContentRaw && analysis.sparseZoomScaleProof
      ? await analysis.nativeContentRaw(before.pngPath, semanticCoverageCrop)
      : null;
    const plus = await perception.localizeSemanticZoom(before.pngPath, "plus");
    actionHistory.push(await act({
      role: "zoom_plus",
      kind: "click",
      point: plus.source_click_point,
      button: "left",
      capture: before,
      performAction,
    }));
    const transition = await captureZoomTransitionAfterControl({
      beforeRaw,
      beforeSparseRaw,
      captureFrame,
      surface: item.surface,
      label: `ZOOM_PLUS_${index + 1}`,
      perception,
      wait,
      analysis,
      coverageCrop: semanticCoverageCrop,
    });
    capture = transition.capture;
    const difference = transition.mean_abs_difference;
    if (!transition.scale_transition) {
      throw new Error(`SEMANTIC_ZOOM_ASCENT_TRANSITION_UNPROVEN:${index + 1}`);
    }
    zoomTransitions.push({
      direction: "plus",
      ordinal: index + 1,
      before_capture: before,
      after_capture: capture,
      mean_abs_difference: difference,
      scale_transition: transition.scale_transition,
      evidence_mode: transition.evidence_mode,
      ...(transition.sparse_scale_proof
        ? {
          sparse_scale_proof: {
            ...transition.sparse_scale_proof,
            before_capture_sha256: before.pngSHA256,
            after_capture_sha256: capture.pngSHA256,
          },
        }
        : {}),
      observed_zoom_percent: zoomLadder[index + 1],
      transition_observation_count: transition.observation_count,
    });
  }

  if (RESET_RELATIVE_COVERAGE_PLANNER_VERSIONS.has(item.planner_version)
      || BOUNDARY_ANCHORED_COVERAGE_PLANNER_VERSIONS.has(item.planner_version)) {
    return executeNativeCoverageCapture({
      claim,
      item,
      capture,
      deadline,
      captureFrame,
      performAction,
      writeMapCrop,
      wait,
      perception,
      analysis,
      evidence,
      actionHistory,
      recovery,
      selector,
      selectorCapture,
      navigationPlan,
      navigationTransitions,
      optionCapture,
      option,
      surfaceReadyCapture,
      surfaceGate,
      minusClicks,
      consecutiveMinimumProofs,
      ascentCount,
      zoomTransitions,
      started,
      selectorNavigationStarted,
      selectorQualified,
      coverageResetProof,
    });
  }

  // Let transient zoom-button hover chrome clear before sealing the pan baseline.
  await wait(250);
  const preFrame = await captureReadyAfterControl({
    captureFrame,
    surface: item.surface,
    label: "PRE_GATE",
    perception,
    wait,
  });
  const preGate = await proveReady(preFrame, item.surface, "PRE_GATE", perception);
  const vector = analysis.safeMotionVector
    ? await analysis.safeMotionVector(
      preFrame.pngPath,
      item.criterion_family,
      frameGeometry(preFrame)
    )
    : motionVector(item.criterion_family, frameGeometry(preFrame));
  const expectedDisplacement = expectedDisplacementFromMotionVector(vector);
  const panInputStarted = performance.now();
  actionHistory.push(await act({
    role: "pan",
    kind: "drag",
    from: vector.delivered.from,
    to: vector.delivered.to,
    capture: preFrame,
    performAction,
  }));
  // Input delivery returns only after the drag is complete and foreground state
  // is restored. Keep a short render settle without consuming the 2 s live gate.
  await wait(PAN_SETTLE_MILLISECONDS);
  const postFrame = await captureFrame();
  const postGate = await proveReady(postFrame, item.surface, "POST_GATE", perception);
  const postQualified = performance.now();
  const freshFrame = await captureFrame();
  const freshGate = await proveReady(freshFrame, item.surface, "FRESH_COMMIT_GATE", perception);
  assertSameTarget([preFrame, postFrame, freshFrame]);

  const preRaw = await analysis.contentRaw(preFrame.pngPath);
  const freshRaw = await analysis.contentRaw(freshFrame.pngPath);
  // The terminal selector benchmark deliberately repeats one restored scene.
  // Keep every within-cycle novelty gate, but do not compare a cycle to the
  // identical accepted cycle immediately before it.
  const sameFamilyRaw = isRepeatedTerminalRealmPerformanceCycle(item)
    ? null
    : await loadSameFamilyRaw(item);
  const novelty = analysis.evaluateNovelty({
    preRaw,
    postRaw: freshRaw,
    sameFamilyRaw,
    width: CONTENT_CROP.width,
    height: CONTENT_CROP.height,
    thresholds: NOVELTY_THRESHOLDS,
    criterionFamily: item.criterion_family,
    expectedDisplacement,
  });
  if (!novelty.passed) throw new Error("SEMANTIC_NOVELTY_GATE_FAILED");

  const cropBytes = await analysis.mapCrop(freshFrame.pngPath);
  const mapCropReference = await writeMapCrop(cropBytes);
  let restorationProof = {
    required: item.restore_after_capture,
    delivered: false,
    displacement_cells: null,
    ready: null,
    frame: null,
  };
  let restoredFrameForReset = null;
  if (item.restore_after_capture) {
    const measuredForwardDisplacement = await analysis.displacementBetween(
      preFrame.pngPath,
      freshFrame.pngPath,
      item.criterion_family,
      expectedDisplacement
    );
    const restorationDisplacement = restorationDisplacementForMotion(
      item.criterion_family,
      measuredForwardDisplacement,
      expectedDisplacement
    );
    const anchorProof = await analysis.restorationReferenceAnchor(
      freshFrame.pngPath,
      { dx: restorationDisplacement.x, dy: restorationDisplacement.y }
    );
    const inverse = measuredInverseMotionVector(
      item.criterion_family,
      frameGeometry(freshFrame),
      measuredForwardDisplacement,
      anchorProof.reference_point,
      expectedDisplacement
    );
    inverse.anchor_proof = anchorProof;
    actionHistory.push(await act({
      role: "restore",
      kind: "drag",
      from: inverse.delivered.from,
      to: inverse.delivered.to,
      capture: freshFrame,
      performAction,
    }));
    await wait(900);
    const restoredFrame = await captureFrame();
    restoredFrameForReset = restoredFrame;
    const restoredGate = await proveReady(restoredFrame, item.surface, "RESTORE_GATE", perception);
    const restoredDisplacement = await analysis.displacementBetween(
      preFrame.pngPath,
      restoredFrame.pngPath
    );
    if (restoredDisplacement.magnitude_cells > NOVELTY_THRESHOLDS.restored_displacement_maximum_cells) {
      throw new Error("SEMANTIC_RESTORATION_DISPLACEMENT_EXCEEDED");
    }
    restorationProof = {
      required: true,
      delivered: true,
      inverse_vector: inverse,
      measured_forward_displacement: measuredForwardDisplacement,
      displacement_cells: restoredDisplacement.magnitude_cells,
      displacement: restoredDisplacement,
      ready: restoredGate,
      frame: restoredFrame,
    };
  }

  const resetRequired = item.surface === "Zanaris" && item.restore_after_capture === true;
  let surfaceResetProof = {
    required: resetRequired,
    delivered: false,
  };
  if (resetRequired) {
    if (!restoredFrameForReset) throw new Error("SEMANTIC_SURFACE_RESET_REQUIRES_RESTORED_FRAME");
    const resetSelector = await perception.localizeSemanticSurfaceSelector(restoredFrameForReset.pngPath);
    actionHistory.push(await act({
      role: "surface_selector_open",
      kind: "click",
      point: resetSelector.source_click_point,
      button: "left",
      capture: restoredFrameForReset,
      performAction,
    }));
    const resetSelectorCapture = await captureFrame();
    const bottomControl = await perception.localizeSemanticSurfaceScrollbar(
      resetSelectorCapture.pngPath,
      item.surface,
      "bottom"
    );
    const resetVector = selectorScrollbarVector("top", bottomControl);
    actionHistory.push(await act({
      role: "surface_selector_scrollbar_drag",
      kind: "drag",
      from: resetVector.delivered.from,
      to: resetVector.delivered.to,
      capture: resetSelectorCapture,
      performAction,
    }));
    const resetOptionCapture = await captureFrame();
    if (resetOptionCapture.pngSHA256 === resetSelectorCapture.pngSHA256) {
      throw new Error("SEMANTIC_SELECTOR_RESET_NO_TRANSITION");
    }
    const topProof = await perception.localizeSemanticSurfaceScrollbar(
      resetOptionCapture.pngPath,
      item.surface,
      "top"
    );
    if (!semanticScrollbarAtExactStop(topProof, "top")) {
      throw new Error("SEMANTIC_SELECTOR_SCROLLBAR_TOP_UNPROVEN");
    }
    const resetOption = await perception.localizeSemanticSurfaceOption(
      resetOptionCapture.pngPath,
      "Gielinor Surface"
    );
    actionHistory.push(await act({
      role: "surface_option_select",
      kind: "click",
      point: resetOption.source_click_point,
      button: "left",
      capture: resetOptionCapture,
      performAction,
    }));
    const resetReadyCapture = await captureFrame();
    const resetReadyGate = await proveReady(
      resetReadyCapture,
      "Gielinor Surface",
      "SURFACE_RESET",
      perception
    );
    surfaceResetProof = {
      required: true,
      delivered: true,
      requested_surface: "Gielinor Surface",
      source_capture: restoredFrameForReset,
      selector_capture: resetSelectorCapture,
      scrollbar_localization: bottomControl,
      vector: resetVector,
      post_drag_capture: resetOptionCapture,
      post_drag_proof: topProof,
      option_localization: resetOption,
      ready_capture: resetReadyCapture,
      ready_gate: resetReadyGate,
    };
  }

  assertDeadline(deadline);
  return {
    schema_version: 2,
    execution_profile: "semantic_map_capture_v1",
    generation_id: claim.generation_id,
    item_id: item.id,
    item_sha256: item.item_sha256,
    target_identity: targetIdentity(freshFrame),
    requested_work: {
      surface: item.surface,
      realm_id: item.realm_id ?? null,
      selector_index: item.selector_index ?? null,
      catalog_version: item.catalog_version ?? null,
      planner_version: item.planner_version ?? null,
      capture_center: item.capture_center ?? null,
      coverage_cell: item.coverage_cell ?? null,
      zoom_percent: item.zoom_percent,
      criterion_family: item.criterion_family,
      restore_after_capture: item.restore_after_capture,
    },
    surface_proof: {
      requested_surface: item.surface,
      selector_capture: selectorCapture,
      selector_localization: selector,
      selector_navigation: {
        ...navigationPlan,
        drags: navigationTransitions.length,
        transitions: navigationTransitions,
      },
      option_capture: optionCapture,
      option_localization: option,
      ready_capture: surfaceReadyCapture,
      ready_gate: surfaceGate,
    },
    zoom_proof: {
      requested_zoom_percent: item.zoom_percent,
      observed_zoom_percent: item.zoom_percent,
      minimum: {
        clicks: minusClicks,
        consecutive_no_transition_clicks: consecutiveMinimumProofs,
      },
      ascent_clicks: ascentCount,
      transitions: zoomTransitions,
    },
    pan_proof: {
      criterion_family: item.criterion_family,
      vector,
      pre_frame: preFrame,
      post_frame: postFrame,
      fresh_frame: freshFrame,
      pre_gate: preGate,
      post_gate: postGate,
      fresh_gate: freshGate,
      novelty,
    },
    restoration_proof: restorationProof,
    surface_reset_proof: surfaceResetProof,
    recovery_history: recovery.history,
    action_history: actionHistory,
    map_crop: { ...mapCropReference, width: MAP_CROP.width, height: MAP_CROP.height },
    performance: {
      elapsed_milliseconds: performance.now() - started,
      input_to_qualified_post_capture_milliseconds: postQualified - panInputStarted,
      selector_open_to_surface_qualified_milliseconds: selectorQualified - selectorNavigationStarted,
      hard_deadline_milliseconds: 120_000,
    },
    completed_at: new Date().toISOString(),
    evidence,
  };
}

async function selectSemanticSurface({
  capture,
  surface,
  productionSelector,
  deadline,
  captureFrame,
  performAction,
  perception,
  actionHistory,
  roles,
  label,
}) {
  const selector = await perception.localizeSemanticSurfaceSelector(capture.pngPath);
  actionHistory.push(await act({
    role: roles.open,
    kind: "click",
    point: selector.source_click_point,
    button: "left",
    capture,
    performAction,
  }));
  const selectorCapture = await captureFrame();
  const navigationStarted = performance.now();
  const navigationTransitions = [];
  let optionCapture = selectorCapture;
  let option;
  let navigationPlan;
  if (productionSelector) {
    const before = optionCapture;
    const control = await perception.observeSemanticSurfaceScrollbar(before.pngPath, surface);
    navigationPlan = semanticSurfaceNavigation(surface, control);
    if (navigationPlan.required) {
      assertDeadline(deadline);
      const vector = selectorScrollbarVector(navigationPlan, control);
      actionHistory.push(await act({
        role: roles.drag,
        kind: "drag",
        from: vector.delivered.from,
        to: vector.delivered.to,
        capture: before,
        performAction,
      }));
      const after = await captureFrame();
      if (after.pngSHA256 === before.pngSHA256) {
        throw new Error("SEMANTIC_SELECTOR_SCROLLBAR_NO_TRANSITION");
      }
      const postDragProof = await perception.observeSemanticSurfaceScrollbar(after.pngPath, surface);
      if (!semanticScrollbarLandingAccepted(postDragProof, navigationPlan, surface)) {
        throw new Error("SEMANTIC_SELECTOR_SCROLLBAR_POSITION_UNPROVEN");
      }
      navigationTransitions.push({
        ordinal: 1,
        mode: "scrollbar_drag",
        anchor: navigationPlan.anchor,
        before_capture: before,
        after_capture: after,
        scrollbar_localization: control,
        post_drag_proof: postDragProof,
        vector,
      });
      optionCapture = after;
    }
    option = await perception.localizeSemanticSurfaceOption(
      optionCapture.pngPath,
      surface,
      { nativeCatalog: true }
    );
  } else {
    navigationPlan = semanticSurfaceNavigation(surface);
    if (navigationPlan.required) {
      assertDeadline(deadline);
      const before = optionCapture;
      const control = await perception.localizeSemanticSurfaceScrollbar(
        before.pngPath,
        surface,
        "top"
      );
      const vector = selectorScrollbarVector("bottom", control);
      actionHistory.push(await act({
        role: roles.drag,
        kind: "drag",
        from: vector.delivered.from,
        to: vector.delivered.to,
        capture: before,
        performAction,
      }));
      const after = await captureFrame();
      if (after.pngSHA256 === before.pngSHA256) {
        throw new Error("SEMANTIC_SELECTOR_SCROLLBAR_NO_TRANSITION");
      }
      const postDragProof = await perception.localizeSemanticSurfaceScrollbar(
        after.pngPath,
        surface,
        "bottom"
      );
      if (!semanticScrollbarAtExactStop(postDragProof, "bottom")) {
        throw new Error("SEMANTIC_SELECTOR_SCROLLBAR_BOTTOM_UNPROVEN");
      }
      navigationTransitions.push({
        ordinal: 1,
        mode: "scrollbar_drag",
        anchor: "bottom",
        before_capture: before,
        after_capture: after,
        scrollbar_localization: control,
        post_drag_proof: postDragProof,
        vector,
      });
      optionCapture = after;
    }
    option = await perception.localizeSemanticSurfaceOption(optionCapture.pngPath, surface);
  }
  actionHistory.push(await act({
    role: roles.select,
    kind: "click",
    point: option.source_click_point,
    button: "left",
    capture: optionCapture,
    performAction,
  }));
  const readyCapture = await captureFrame();
  const readyGate = await proveReady(readyCapture, surface, label, perception);
  return {
    selector,
    selectorCapture,
    navigationPlan,
    navigationTransitions,
    optionCapture,
    option,
    readyCapture,
    readyGate,
    navigationStarted,
    qualifiedAt: performance.now(),
  };
}

async function executeNativeCoverageCapture({
  claim,
  item,
  capture: initialCapture,
  deadline,
  captureFrame,
  performAction,
  writeMapCrop,
  wait,
  perception,
  analysis,
  evidence,
  actionHistory,
  recovery,
  selector,
  selectorCapture,
  navigationPlan,
  navigationTransitions,
  optionCapture,
  option,
  surfaceReadyCapture,
  surfaceGate,
  minusClicks,
  consecutiveMinimumProofs,
  ascentCount,
  zoomTransitions,
  started,
  selectorNavigationStarted,
  selectorQualified,
  coverageResetProof,
}) {
  let capture = initialCapture;
  const navigationStarted = performance.now();
  const sourceCenter = coverageAnchorCenter(item);
  const coverageCrop = item.coverage_cell?.coverage_crop
    ?? NATIVE_COVERAGE_CROP;
  const anchorTransitions = [];
  const anchorAttempts = BOUNDARY_ANCHORED_COVERAGE_PLANNER_VERSIONS.has(item.planner_version)
    ? item.coverage_cell.anchor_attempt_budget
    : 0;
  for (let index = 0; index < anchorAttempts; index += 1) {
    assertDeadline(deadline);
    const before = capture;
    const beforeRaw = await (analysis.nativeContentRaw ?? analysis.contentRaw)(
      before.pngPath,
      coverageCrop
    );
    const vector = await (analysis.safeNativeCoverageVector ?? safeNativeCoverageVector)(
      before.pngPath,
      NATIVE_REALM_COVERAGE_ANCHOR_DELTA,
      frameGeometry(before),
      coverageCrop
    );
    actionHistory.push(await act({
      role: "coverage_anchor",
      kind: "drag",
      from: vector.delivered.from,
      to: vector.delivered.to,
      capture: before,
      performAction,
    }));
    await wait(PAN_SETTLE_MILLISECONDS);
    capture = await captureFrame();
    assertSameTarget([before, capture]);
    const difference = analysis.meanDifference(
      beforeRaw,
      await (analysis.nativeContentRaw ?? analysis.contentRaw)(capture.pngPath, coverageCrop)
    );
    anchorTransitions.push({
      ordinal: index + 1,
      before_capture: before,
      after_capture: capture,
      vector,
      mean_abs_difference: difference,
      transitioned: difference >= NOVELTY_THRESHOLDS.zoom_transition_mean_abs_minimum,
    });
  }
  if (anchorAttempts > 0 && !anchorTransitions.slice(-2).every(
    ({ transitioned, mean_abs_difference: difference }) =>
      transitioned === false
        && difference < NOVELTY_THRESHOLDS.zoom_transition_mean_abs_minimum
  )) {
    throw new Error("NATIVE_REALM_COVERAGE_ANCHOR_UNPROVEN");
  }

  const targetDelta = coverageReferenceDelta(
    sourceCenter,
    item.capture_center,
    item.zoom_percent
  );
  const chunks = coverageReferenceChunks(targetDelta);
  const movementTransitions = [];
  for (const [index, chunk] of chunks.entries()) {
    assertDeadline(deadline);
    const planningCapture = capture;
    const vector = await (analysis.safeNativeCoverageVector ?? safeNativeCoverageVector)(
      planningCapture.pngPath,
      chunk,
      frameGeometry(planningCapture),
      coverageCrop
    );
    const before = await captureFrame();
    assertSameTarget([planningCapture, before]);
    const beforeRaw = await (analysis.nativeContentRaw ?? analysis.contentRaw)(
      before.pngPath,
      coverageCrop
    );
    actionHistory.push(await act({
      role: "coverage_pan",
      kind: "drag",
      from: vector.delivered.from,
      to: vector.delivered.to,
      capture: before,
      performAction,
    }));
    await wait(PAN_SETTLE_MILLISECONDS);
    capture = await captureFrame();
    assertSameTarget([before, capture]);
    const difference = analysis.meanDifference(
      beforeRaw,
      await (analysis.nativeContentRaw ?? analysis.contentRaw)(capture.pngPath, coverageCrop)
    );
    const displacement = await (
      analysis.nativeCoverageDisplacementBetween ?? nativeCoverageDisplacementBetween
    )(before.pngPath, capture.pngPath, chunk, coverageCrop);
    const movementProof = requireNativeCoverageMovement({
      meanAbsDifference: difference,
      displacement,
      expectedReferenceDelta: chunk,
    });
    movementTransitions.push({
      ordinal: index + 1,
      before_capture: before,
      after_capture: capture,
      vector,
      mean_abs_difference: difference,
      displacement_proof: movementProof,
    });
  }

  const targetFrame = capture;
  const targetContentProof = requireNativeCoverageContent(
    await (analysis.nativeContentRaw ?? analysis.contentRaw)(targetFrame.pngPath, coverageCrop),
    coverageCrop
  );
  const targetGate = await proveCoverageReady(
    targetFrame,
    item.surface,
    "COVERAGE_TARGET",
    perception,
    targetContentProof
  );
  const freshFrame = await captureFrame();
  const freshContentProof = requireNativeCoverageContent(
    await (analysis.nativeContentRaw ?? analysis.contentRaw)(freshFrame.pngPath, coverageCrop),
    coverageCrop
  );
  const freshGate = await proveCoverageReady(
    freshFrame,
    item.surface,
    "COVERAGE_FRESH",
    perception,
    freshContentProof
  );
  assertSameTarget([targetFrame, freshFrame]);
  const cropBytes = await (analysis.nativeMapCrop ?? analysis.mapCrop)(
    freshFrame.pngPath,
    coverageCrop
  );
  const mapCropReference = await writeMapCrop(cropBytes);
  const actionDX = movementTransitions.reduce(
    (sum, transition) => sum + transition.vector.reference_delta.dx,
    0
  );
  const actionDY = movementTransitions.reduce(
    (sum, transition) => sum + transition.vector.reference_delta.dy,
    0
  );
  if (actionDX !== targetDelta.dx || actionDY !== targetDelta.dy) {
    throw new Error("NATIVE_REALM_COVERAGE_VECTOR_SUM_MISMATCH");
  }
  assertDeadline(deadline);
  return {
    schema_version: 2,
    execution_profile: "semantic_map_capture_v1",
    generation_id: claim.generation_id,
    item_id: item.id,
    item_sha256: item.item_sha256,
    target_identity: targetIdentity(freshFrame),
    requested_work: {
      surface: item.surface,
      realm_id: item.realm_id,
      selector_index: item.selector_index,
      catalog_version: item.catalog_version,
      planner_version: item.planner_version,
      capture_center: item.capture_center,
      coverage_cell: item.coverage_cell,
      zoom_percent: item.zoom_percent,
      criterion_family: item.criterion_family,
      restore_after_capture: item.restore_after_capture,
    },
    surface_proof: {
      requested_surface: item.surface,
      selector_capture: selectorCapture,
      selector_localization: selector,
      selector_navigation: {
        ...navigationPlan,
        drags: navigationTransitions.length,
        transitions: navigationTransitions,
      },
      option_capture: optionCapture,
      option_localization: option,
      ready_capture: surfaceReadyCapture,
      ready_gate: surfaceGate,
    },
    zoom_proof: {
      requested_zoom_percent: item.zoom_percent,
      observed_zoom_percent: item.zoom_percent,
      minimum: {
        clicks: minusClicks,
        consecutive_no_transition_clicks: consecutiveMinimumProofs,
      },
      ascent_clicks: ascentCount,
      transitions: zoomTransitions,
    },
    coverage_navigation: {
      planner_version: item.planner_version,
      mode: anchorAttempts > 0
        ? "bounded_anchor"
        : CLOSE_REOPEN_COVERAGE_PLANNER_VERSIONS.has(item.planner_version)
          ? "map_reopen_relative"
          : "reset_relative",
      source_center: sourceCenter,
      target_center: item.capture_center,
      target_cell: {
        row: item.coverage_cell.row,
        column: item.coverage_cell.column,
      },
      reference_delta: targetDelta,
      delivered_reference_delta: { dx: actionDX, dy: actionDY },
      target_tolerance_reference_pixels: 10,
      anchor: {
        required: anchorAttempts > 0,
        attempt_budget: anchorAttempts,
        attempts: anchorTransitions.length,
        consecutive_no_transition_proofs: anchorAttempts > 0 ? 2 : 0,
        transitions: anchorTransitions,
      },
      movement: {
        action_count: movementTransitions.length,
        transitions: movementTransitions,
      },
      target_frame: targetFrame,
      target_gate: targetGate,
      target_content_proof: targetContentProof,
      fresh_frame: freshFrame,
      fresh_gate: freshGate,
      fresh_content_proof: freshContentProof,
      nonblack: targetGate.nonblack === true
        && freshGate.nonblack === true
        && targetContentProof.passed === true
        && freshContentProof.passed === true,
    },
    coverage_reset_proof: coverageResetProof,
    restoration_proof: { required: false, delivered: false },
    surface_reset_proof: { required: false, delivered: false },
    recovery_history: recovery.history,
    action_history: actionHistory,
    map_crop: {
      ...mapCropReference,
      source_crop: coverageCrop,
      width: coverageCrop.width,
      height: coverageCrop.height,
    },
    performance: {
      elapsed_milliseconds: performance.now() - started,
      input_to_qualified_post_capture_milliseconds: performance.now() - navigationStarted,
      selector_open_to_surface_qualified_milliseconds: selectorQualified - selectorNavigationStarted,
      hard_deadline_milliseconds: 120_000,
    },
    completed_at: new Date().toISOString(),
    evidence,
  };
}

export async function safeNativeCoverageVector(
  pngPath,
  referenceDelta,
  geometry,
  coverageCrop = NATIVE_COVERAGE_CROP
) {
  const raw = await normalizedImage(pngPath).removeAlpha().raw().toBuffer();
  return nativeCoverageVector(
    referenceDelta,
    geometry,
    selectSafeCoverageTranslation(raw, referenceDelta, coverageCrop),
    coverageCrop
  );
}

export function nativeCoverageVector(
  referenceDelta,
  geometry,
  translation = { x: 0, y: 0 },
  coverageCrop = NATIVE_COVERAGE_CROP
) {
  if (!Number.isInteger(referenceDelta?.dx) || !Number.isInteger(referenceDelta?.dy)
      || Math.abs(referenceDelta.dx) > NATIVE_REALM_COVERAGE_CHUNK_LIMITS.x
      || Math.abs(referenceDelta.dy) > NATIVE_REALM_COVERAGE_CHUNK_LIMITS.y
      || Math.hypot(referenceDelta.dx, referenceDelta.dy) < 10) {
    throw new Error("NATIVE_REALM_COVERAGE_VECTOR_INVALID");
  }
  if (!Number.isInteger(translation?.x) || !Number.isInteger(translation?.y)
      || Math.abs(translation.x) > MOTION_ANCHOR_TRANSLATION_MAXIMUM
      || Math.abs(translation.y) > MOTION_ANCHOR_TRANSLATION_MAXIMUM) {
    throw new Error("NATIVE_REALM_COVERAGE_TRANSLATION_INVALID");
  }
  const baseFrom = nativeCoverageBaseAnchor(referenceDelta, coverageCrop);
  const from = {
    x: baseFrom.x + translation.x,
    y: baseFrom.y + translation.y,
  };
  const to = { x: from.x + referenceDelta.dx, y: from.y + referenceDelta.dy };
  if (![from, to].every((point) => motionAnchorInsideNativeCoverageMap(point, coverageCrop))) {
    throw new Error("NATIVE_REALM_COVERAGE_VECTOR_OUT_OF_BOUNDS");
  }
  return {
    reference_frame: REVIEWED_FRAME,
    reference_delta: referenceDelta,
    anchor_translation: translation,
    reference: { from, to },
    delivered: {
      from: normalizedPoint(from, geometry),
      to: normalizedPoint(to, geometry),
    },
  };
}

async function act({ role, capture, performAction, ...operation }) {
  const inputEvidence = await performAction({ ...operation, semantic_role: role }, capture);
  return {
    role,
    capture_id: capture.captureIdentifier,
    operation,
    input_evidence: inputEvidence,
  };
}

async function recoverInitialSemanticMap({
  initialCapture,
  coverageSurface,
  deadline,
  captureFrame,
  performAction,
  wait,
  perception,
}) {
  try {
    const classification = await requireInitialSemanticMap({
      pngPath: initialCapture.pngPath,
      coverageSurface,
      perception,
    });
    return {
      capture: initialCapture,
      classification,
      evidence: [],
      history: [],
      actions: [],
    };
  } catch (initialError) {
    const recovered = await executeInlineSemanticRecovery({
      initialCapture,
      deadline,
      captureFrame,
      performAction,
      classify: perception.classifyCapture ?? classifyCapture,
      wait,
    });
    const classification = await perception.requireAuthorizedOSRSMap(recovered.capture.pngPath);
    return { ...recovered, classification, initial_error: initialError.message };
  }
}

async function requireInitialSemanticMap({ pngPath, coverageSurface, perception }) {
  if (coverageSurface === null || coverageSurface === undefined) {
    return perception.requireAuthorizedOSRSMap(pngPath);
  }
  try {
    return await perception.requireAuthorizedOSRSMap(pngPath);
  } catch {
    // A resumed endpoint cell can be intentionally sparse. In that case the
    // exact surface label and map shell are the qualification boundary.
  }
  const requireCoverage = perception.requireAuthorizedOSRSCoverageMap
    ?? requireAuthorizedOSRSCoverageMap;
  return requireCoverage(pngPath, coverageSurface);
}

async function proveReady(capture, surface, label, perception) {
  const proof = await perception.proveSemanticMapReadiness(capture.pngPath, surface);
  if (!proof.passed) throw new Error(`SEMANTIC_${label}_FAILED`);
  return proof;
}

async function proveCoverageReady(capture, surface, label, perception, contentProof) {
  const prove = perception.proveSemanticCoverageReadiness
    ?? perception.proveSemanticMapReadiness;
  const proof = await prove(capture.pngPath, surface);
  const delegatedContentPassed = proof.coverage_content_delegated === true
    && contentProof?.passed === true;
  if (!proof.passed || (proof.nonblack !== true && !delegatedContentPassed)) {
    throw new Error(`SEMANTIC_${label}_FAILED`);
  }
  return {
    ...proof,
    nonblack: true,
    coverage_content_passed: contentProof?.passed === true,
  };
}

async function captureReadyAfterControl({ captureFrame, surface, label, perception, wait }) {
  return captureAuthorizedOSRSPostAction({
    captureFrame,
    classify: async (pngPath) => {
      const proof = await perception.proveSemanticMapReadiness(pngPath, surface);
      if (!proof.passed) throw new Error(`SEMANTIC_${label}_FAILED`);
      return proof;
    },
    recordEvidence: () => {},
    attempts: 3,
    intervalMilliseconds: 250,
    wait,
  });
}

async function captureZoomTransitionAfterControl({
  beforeRaw,
  beforeSparseRaw,
  captureFrame,
  surface,
  label,
  perception,
  wait,
  analysis,
  coverageCrop = NATIVE_COVERAGE_CROP,
}) {
  let capture;
  let difference = 0;
  let sparseScaleProof = null;
  for (let observation = 1; observation <= ZOOM_TRANSITION_OBSERVATION_ATTEMPTS; observation += 1) {
    await wait(250);
    capture = await captureReadyAfterControl({ captureFrame, surface, label, perception, wait });
    difference = analysis.meanDifference(beforeRaw, await analysis.contentRaw(capture.pngPath));
    if (difference >= NOVELTY_THRESHOLDS.zoom_transition_mean_abs_minimum) {
      return {
        capture,
        mean_abs_difference: difference,
        scale_transition: true,
        evidence_mode: "full_content_mean_abs",
        observation_count: observation,
      };
    }
    if (beforeSparseRaw && analysis.nativeContentRaw && analysis.sparseZoomScaleProof) {
      sparseScaleProof = analysis.sparseZoomScaleProof(
        beforeSparseRaw,
        await analysis.nativeContentRaw(capture.pngPath, coverageCrop),
        coverageCrop.width,
        coverageCrop.height
      );
      if (sparseScaleProof.passed) {
        return {
          capture,
          mean_abs_difference: difference,
          scale_transition: true,
          evidence_mode: sparseScaleProof.evidence_mode,
          sparse_scale_proof: sparseScaleProof,
          observation_count: observation,
        };
      }
    }
  }
  return {
    capture,
    mean_abs_difference: difference,
    scale_transition: false,
    evidence_mode: "unproven",
    ...(sparseScaleProof ? { sparse_scale_proof: sparseScaleProof } : {}),
    observation_count: ZOOM_TRANSITION_OBSERVATION_ATTEMPTS,
  };
}

function assertSameTarget(captures) {
  const first = targetIdentity(captures[0]);
  for (const capture of captures.slice(1)) {
    const current = targetIdentity(capture);
    if (JSON.stringify(current) !== JSON.stringify(first)) {
      throw new Error("SEMANTIC_TARGET_IDENTITY_CHANGED");
    }
  }
}

function targetIdentity(capture) {
  return {
    bundle_identifier: capture.target.bundleIdentifier,
    process_identifier: capture.target.processIdentifier,
    window_identifier: capture.target.windowIdentifier,
  };
}

function frameGeometry(capture) {
  return { width: capture.pixelWidth, height: capture.pixelHeight };
}

function normalizedImage(pngPath) {
  return sharp(pngPath).resize(REVIEWED_FRAME.width, REVIEWED_FRAME.height, { fit: "fill" });
}

async function contentRaw(pngPath) {
  return normalizedImage(pngPath).extract(CONTENT_CROP).removeAlpha().raw().toBuffer();
}

async function mapCrop(pngPath) {
  return normalizedImage(pngPath).extract(MAP_CROP).png().toBuffer();
}

async function nativeMapCrop(pngPath, coverageCrop = NATIVE_COVERAGE_CROP) {
  return normalizedImage(pngPath).extract(coverageCrop).png().toBuffer();
}

async function nativeContentRaw(pngPath, coverageCrop = NATIVE_COVERAGE_CROP) {
  return normalizedImage(pngPath)
    .extract(coverageCrop)
    .removeAlpha()
    .raw()
    .toBuffer();
}

export function requireNativeCoverageContent(raw, coverageCrop = NATIVE_COVERAGE_CROP) {
  if (raw?.length !== coverageCrop.width * coverageCrop.height * 3) {
    throw new Error("NATIVE_REALM_COVERAGE_CONTENT_FRAME_INVALID");
  }
  const stats = sparseFrameStats(raw, coverageCrop.width, coverageCrop.height);
  const structuralEdgePixelCount = structuralEdgePixels(
    raw,
    coverageCrop.width,
    coverageCrop.height
  );
  if (stats.informative_pixel_count < NATIVE_COVERAGE_CONTENT_MINIMUM_INFORMATIVE_PIXELS
      || (
        stats.chromatic_pixel_count < NATIVE_COVERAGE_CONTENT_MINIMUM_CHROMATIC_PIXELS
        && structuralEdgePixelCount < NATIVE_COVERAGE_CONTENT_MINIMUM_STRUCTURAL_EDGE_PIXELS
      )) {
    throw new Error("NATIVE_REALM_COVERAGE_TARGET_CONTENT_UNPROVEN");
  }
  return {
    passed: true,
    evidence_mode: "native_crop_interior_content_v2",
    ...stats,
    structural_edge_pixel_count: structuralEdgePixelCount,
    minimum_informative_pixel_count: NATIVE_COVERAGE_CONTENT_MINIMUM_INFORMATIVE_PIXELS,
    minimum_chromatic_pixel_count: NATIVE_COVERAGE_CONTENT_MINIMUM_CHROMATIC_PIXELS,
    minimum_structural_edge_pixel_count: NATIVE_COVERAGE_CONTENT_MINIMUM_STRUCTURAL_EDGE_PIXELS,
    structural_edge_threshold: NATIVE_COVERAGE_EDGE_MINIMUM,
    interior_margin_pixels: 2,
  };
}

function structuralEdgePixels(raw, width, height) {
  const gradient = luminanceGradient(raw, width, height);
  const margin = 2;
  let count = 0;
  for (let y = margin; y < height - margin; y += 1) {
    for (let x = margin; x < width - margin; x += 1) {
      if (gradient[y * width + x] >= NATIVE_COVERAGE_EDGE_MINIMUM) count += 1;
    }
  }
  return count;
}

async function nativeCoverageDisplacementRaw(pngPath, coverageCrop = NATIVE_COVERAGE_CROP) {
  const normalizedCrop = await normalizedImage(pngPath)
    .extract(coverageCrop)
    .png()
    .toBuffer();
  return sharp(normalizedCrop)
    .resize(
      Math.round(coverageCrop.width / 2),
      Math.round(coverageCrop.height / 2)
    )
    .removeAlpha()
    .raw()
    .toBuffer();
}

export async function nativeCoverageDisplacementBetween(
  firstPath,
  secondPath,
  expectedReferenceDelta,
  coverageCrop = NATIVE_COVERAGE_CROP
) {
  if (!Number.isInteger(expectedReferenceDelta?.dx)
      || !Number.isInteger(expectedReferenceDelta?.dy)
      || Math.hypot(expectedReferenceDelta.dx, expectedReferenceDelta.dy) < 10) {
    throw new Error("NATIVE_REALM_COVERAGE_DISPLACEMENT_EXPECTATION_INVALID");
  }
  const width = Math.round(coverageCrop.width / 2);
  const height = Math.round(coverageCrop.height / 2);
  const [first, second] = await Promise.all([
    nativeCoverageDisplacementRaw(firstPath, coverageCrop),
    nativeCoverageDisplacementRaw(secondPath, coverageCrop),
  ]);
  const firstEdges = luminanceGradient(first, width, height);
  const secondEdges = luminanceGradient(second, width, height);
  const expected = {
    dx: Math.round(expectedReferenceDelta.dx / 2),
    dy: Math.round(expectedReferenceDelta.dy / 2),
  };
  const xBounds = halfResolutionDisplacementBounds(
    expectedReferenceDelta.dx,
    NATIVE_COVERAGE_DISPLACEMENT_TOLERANCE
  );
  const yBounds = halfResolutionDisplacementBounds(
    expectedReferenceDelta.dy,
    NATIVE_COVERAGE_DISPLACEMENT_TOLERANCE
  );
  let best;
  try {
    best = bestDisplacement({
      first,
      second,
      width,
      height,
      minimumDX: xBounds.minimum,
      maximumDX: xBounds.maximum,
      minimumDY: yBounds.minimum,
      maximumDY: yBounds.maximum,
      minimumInformativePixels: 64,
      expectedDX: expected.dx,
      expectedDY: expected.dy,
      expectationBiasPerPixel: NATIVE_COVERAGE_EXPECTATION_BIAS_PER_HALF_PIXEL,
      firstEdges,
      secondEdges,
      minimumEdgePixels: NATIVE_COVERAGE_MINIMUM_EDGE_PIXELS,
    });
  } catch (error) {
    if (error?.message !== "SEMANTIC_DISPLACEMENT_UNPROVEN") throw error;
    const turnover = nativeCoverageBoundaryTurnover({
      first,
      second,
      width,
      height,
      expectedDX: expected.dx,
      expectedDY: expected.dy,
    });
    if (!turnover) throw error;
    return {
      evidence_mode: turnover.evidence_mode ?? "native_crop_boundary_turnover",
      expected_reference_delta: expectedReferenceDelta,
      delivered_reference_delta: { ...expectedReferenceDelta },
      tolerance_reference_pixels: NATIVE_COVERAGE_DISPLACEMENT_TOLERANCE,
      alignment_selection_mode: turnover.alignment_selection_mode ?? "directional_boundary_turnover",
      ...turnover,
    };
  }
  if (best.error > NATIVE_COVERAGE_ALIGNMENT_MEAN_ABS_MAXIMUM
      || best.informative_coverage < NATIVE_COVERAGE_INFORMATIVE_COVERAGE_MINIMUM) {
    const turnover = nativeCoverageBoundaryTurnover({
      first,
      second,
      width,
      height,
      expectedDX: expected.dx,
      expectedDY: expected.dy,
    });
    if (turnover) {
      return {
        evidence_mode: turnover.evidence_mode ?? "native_crop_boundary_turnover",
        expected_reference_delta: expectedReferenceDelta,
        delivered_reference_delta: { ...expectedReferenceDelta },
        tolerance_reference_pixels: NATIVE_COVERAGE_DISPLACEMENT_TOLERANCE,
        alignment_selection_mode: turnover.alignment_selection_mode ?? "directional_boundary_turnover",
        ...turnover,
      };
    }
  }
  return {
    evidence_mode: "native_crop_expected_neighborhood",
    expected_reference_delta: expectedReferenceDelta,
    delivered_reference_delta: { dx: best.dx * 2, dy: best.dy * 2 },
    tolerance_reference_pixels: NATIVE_COVERAGE_DISPLACEMENT_TOLERANCE,
    aligned_mean_abs: best.error,
    informative_coverage: best.informative_coverage,
    informative_pixel_count: best.informative_pixel_count,
    distinct_score_separation: best.distinct_score_separation,
    expectation_bias_per_half_pixel: NATIVE_COVERAGE_EXPECTATION_BIAS_PER_HALF_PIXEL,
    alignment_selection_mode: best.alignment_selection_mode,
    edge_aligned_mean_abs: best.edge_error,
    edge_informative_coverage: best.edge_informative_coverage,
    edge_informative_pixel_count: best.edge_informative_pixel_count,
  };
}

export function halfResolutionDisplacementBounds(expectedReferenceDelta, toleranceReferencePixels) {
  if (!Number.isInteger(expectedReferenceDelta)
      || !Number.isInteger(toleranceReferencePixels)
      || toleranceReferencePixels < 0) {
    throw new Error("NATIVE_REALM_COVERAGE_DISPLACEMENT_BOUNDS_INVALID");
  }
  return {
    minimum: Math.ceil((expectedReferenceDelta - toleranceReferencePixels) / 2),
    maximum: Math.floor((expectedReferenceDelta + toleranceReferencePixels) / 2),
  };
}

export function requireNativeCoverageMovement({
  meanAbsDifference,
  displacement,
  expectedReferenceDelta,
}) {
  if (!Number.isFinite(meanAbsDifference)
      || meanAbsDifference < NOVELTY_THRESHOLDS.pre_post_mean_abs_minimum) {
    throw new Error("NATIVE_REALM_COVERAGE_PAN_NO_OP");
  }
  const delivered = displacement?.delivered_reference_delta;
  const expected = displacement?.expected_reference_delta;
  const sharedDisplacementValid = displacement?.evidence_mode === "native_crop_expected_neighborhood"
    && Number.isFinite(displacement?.aligned_mean_abs)
    && displacement.aligned_mean_abs <= NATIVE_COVERAGE_ALIGNMENT_MEAN_ABS_MAXIMUM
    && Number.isFinite(displacement?.informative_coverage)
    && displacement.informative_coverage >= NATIVE_COVERAGE_INFORMATIVE_COVERAGE_MINIMUM;
  const boundaryTurnoverValid = displacement?.evidence_mode === "native_crop_boundary_turnover"
    && displacement?.alignment_selection_mode === "directional_boundary_turnover"
    && Number.isInteger(displacement?.source_changed_pixel_count)
    && displacement.source_changed_pixel_count >= NATIVE_COVERAGE_BOUNDARY_MINIMUM_CHANGED_PIXELS
    && Number.isInteger(displacement?.destination_changed_pixel_count)
    && displacement.destination_changed_pixel_count >= NATIVE_COVERAGE_BOUNDARY_MINIMUM_CHANGED_PIXELS
    && Number.isFinite(displacement?.source_exit_fraction)
    && displacement.source_exit_fraction
      >= NATIVE_COVERAGE_BOUNDARY_MINIMUM_SPARSE_TURNOVER_FRACTION
    && Number.isFinite(displacement?.destination_entry_fraction)
    && displacement.destination_entry_fraction >= NATIVE_COVERAGE_BOUNDARY_MINIMUM_TURNOVER_FRACTION
    && Number.isInteger(displacement?.aligned_shared_pixel_count)
    && displacement.aligned_shared_pixel_count <= NATIVE_COVERAGE_BOUNDARY_MAXIMUM_SHARED_PIXELS
    && displacement?.minimum_changed_pixel_count
      === NATIVE_COVERAGE_BOUNDARY_MINIMUM_CHANGED_PIXELS
    && displacement?.minimum_turnover_fraction
      === NATIVE_COVERAGE_BOUNDARY_MINIMUM_TURNOVER_FRACTION
    && displacement?.maximum_shared_pixel_count
      === NATIVE_COVERAGE_BOUNDARY_MAXIMUM_SHARED_PIXELS;
  const sourceBoundaryExitValid = displacement?.evidence_mode === "native_crop_source_boundary_exit"
    && displacement?.alignment_selection_mode === "directional_source_boundary_exit"
    && Number.isInteger(displacement?.source_changed_pixel_count)
    && displacement.source_changed_pixel_count >= NATIVE_COVERAGE_BOUNDARY_MINIMUM_CHANGED_PIXELS
    && Number.isInteger(displacement?.destination_changed_pixel_count)
    && displacement.destination_changed_pixel_count
      >= NATIVE_COVERAGE_BOUNDARY_MINIMUM_SPARSE_CHANGED_PIXELS
    && Number.isInteger(displacement?.destination_informative_pixel_count)
    && displacement.destination_informative_pixel_count
      >= NATIVE_COVERAGE_BOUNDARY_MINIMUM_SPARSE_INFORMATIVE_PIXELS
    && Number.isFinite(displacement?.source_exit_fraction)
    && displacement.source_exit_fraction >= NATIVE_COVERAGE_BOUNDARY_MINIMUM_TURNOVER_FRACTION
    && Number.isInteger(displacement?.aligned_shared_pixel_count)
    && displacement.aligned_shared_pixel_count <= NATIVE_COVERAGE_BOUNDARY_MAXIMUM_SHARED_PIXELS
    && displacement?.minimum_sparse_changed_pixel_count
      === NATIVE_COVERAGE_BOUNDARY_MINIMUM_SPARSE_CHANGED_PIXELS
    && displacement?.minimum_destination_informative_pixel_count
      === NATIVE_COVERAGE_BOUNDARY_MINIMUM_SPARSE_INFORMATIVE_PIXELS
    && displacement?.minimum_sparse_turnover_fraction
      === NATIVE_COVERAGE_BOUNDARY_MINIMUM_SPARSE_TURNOVER_FRACTION;
  if ((!sharedDisplacementValid && !boundaryTurnoverValid && !sourceBoundaryExitValid)
      || !Number.isInteger(delivered?.dx)
      || !Number.isInteger(delivered?.dy)
      || expected?.dx !== expectedReferenceDelta?.dx
      || expected?.dy !== expectedReferenceDelta?.dy
      || displacement?.tolerance_reference_pixels !== NATIVE_COVERAGE_DISPLACEMENT_TOLERANCE
      || Math.abs(delivered.dx - expectedReferenceDelta.dx) > NATIVE_COVERAGE_DISPLACEMENT_TOLERANCE
      || Math.abs(delivered.dy - expectedReferenceDelta.dy) > NATIVE_COVERAGE_DISPLACEMENT_TOLERANCE) {
    throw new Error("NATIVE_REALM_COVERAGE_DISPLACEMENT_UNPROVEN");
  }
  return {
    ...displacement,
    passed: true,
    mean_abs_difference: meanAbsDifference,
    mean_abs_minimum: NOVELTY_THRESHOLDS.pre_post_mean_abs_minimum,
    ...(sharedDisplacementValid ? {
      aligned_mean_abs_maximum: NATIVE_COVERAGE_ALIGNMENT_MEAN_ABS_MAXIMUM,
      informative_coverage_minimum: NATIVE_COVERAGE_INFORMATIVE_COVERAGE_MINIMUM,
    } : {}),
  };
}

function nativeCoverageBoundaryTurnover({
  first,
  second,
  width,
  height,
  expectedDX,
  expectedDY,
}) {
  // At a sparse map boundary, the expected pan can replace every visible map
  // pixel, leaving no shared support for the ordinary alignment proof.
  const margin = 2;
  let sourceChanged = 0;
  let destinationChanged = 0;
  let sourceExited = 0;
  let destinationEntered = 0;
  let alignedShared = 0;
  let destinationInformative = 0;
  for (let y = margin; y < height - margin; y += 1) {
    for (let x = margin; x < width - margin; x += 1) {
      const offset = (y * width + x) * 3;
      if (informativePixel(second, offset)) destinationInformative += 1;
      const changed = (
        Math.abs(first[offset] - second[offset])
        + Math.abs(first[offset + 1] - second[offset + 1])
        + Math.abs(first[offset + 2] - second[offset + 2])
      ) / 3 >= NOVELTY_THRESHOLDS.pre_post_mean_abs_minimum;
      const sourceInformative = changed && informativePixel(first, offset);
      const destinationChangedInformative = changed && informativePixel(second, offset);
      if (sourceInformative) {
        sourceChanged += 1;
        const projectedX = x + expectedDX;
        const projectedY = y + expectedDY;
        if (projectedX < margin || projectedX >= width - margin
            || projectedY < margin || projectedY >= height - margin) {
          sourceExited += 1;
        }
      }
      if (destinationChangedInformative) {
        destinationChanged += 1;
        const sourceX = x - expectedDX;
        const sourceY = y - expectedDY;
        if (sourceX < margin || sourceX >= width - margin
            || sourceY < margin || sourceY >= height - margin) {
          destinationEntered += 1;
        }
      }
      const alignedX = x + expectedDX;
      const alignedY = y + expectedDY;
      if (!sourceInformative
          || alignedX < margin || alignedX >= width - margin
          || alignedY < margin || alignedY >= height - margin) continue;
      const alignedOffset = (alignedY * width + alignedX) * 3;
      if (informativePixel(second, alignedOffset)) alignedShared += 1;
    }
  }
  const sourceExitFraction = sourceExited / Math.max(1, sourceChanged);
  const destinationEntryFraction = destinationEntered / Math.max(1, destinationChanged);
  const sharedProof = {
    source_changed_pixel_count: sourceChanged,
    destination_changed_pixel_count: destinationChanged,
    destination_informative_pixel_count: destinationInformative,
    source_exit_pixel_count: sourceExited,
    destination_entry_pixel_count: destinationEntered,
    source_exit_fraction: sourceExitFraction,
    destination_entry_fraction: destinationEntryFraction,
    aligned_shared_pixel_count: alignedShared,
    minimum_changed_pixel_count: NATIVE_COVERAGE_BOUNDARY_MINIMUM_CHANGED_PIXELS,
    minimum_turnover_fraction: NATIVE_COVERAGE_BOUNDARY_MINIMUM_TURNOVER_FRACTION,
    maximum_shared_pixel_count: NATIVE_COVERAGE_BOUNDARY_MAXIMUM_SHARED_PIXELS,
  };
  if (sourceChanged >= NATIVE_COVERAGE_BOUNDARY_MINIMUM_CHANGED_PIXELS
      && destinationChanged >= NATIVE_COVERAGE_BOUNDARY_MINIMUM_CHANGED_PIXELS
      && sourceExitFraction >= NATIVE_COVERAGE_BOUNDARY_MINIMUM_TURNOVER_FRACTION
      && destinationEntryFraction >= NATIVE_COVERAGE_BOUNDARY_MINIMUM_TURNOVER_FRACTION
      && alignedShared <= NATIVE_COVERAGE_BOUNDARY_MAXIMUM_SHARED_PIXELS) {
    return sharedProof;
  }
  if (sourceChanged < NATIVE_COVERAGE_BOUNDARY_MINIMUM_CHANGED_PIXELS
      || destinationChanged < NATIVE_COVERAGE_BOUNDARY_MINIMUM_SPARSE_CHANGED_PIXELS
      || destinationInformative < NATIVE_COVERAGE_BOUNDARY_MINIMUM_SPARSE_INFORMATIVE_PIXELS
      || sourceExitFraction < NATIVE_COVERAGE_BOUNDARY_MINIMUM_SPARSE_TURNOVER_FRACTION
      || alignedShared > NATIVE_COVERAGE_BOUNDARY_MAXIMUM_SHARED_PIXELS) {
    return null;
  }
  return {
    ...sharedProof,
    evidence_mode: "native_crop_source_boundary_exit",
    alignment_selection_mode: "directional_source_boundary_exit",
    minimum_sparse_changed_pixel_count: NATIVE_COVERAGE_BOUNDARY_MINIMUM_SPARSE_CHANGED_PIXELS,
    minimum_destination_informative_pixel_count:
      NATIVE_COVERAGE_BOUNDARY_MINIMUM_SPARSE_INFORMATIVE_PIXELS,
    minimum_sparse_turnover_fraction:
      NATIVE_COVERAGE_BOUNDARY_MINIMUM_SPARSE_TURNOVER_FRACTION,
  };
}

export async function safeMotionVector(pngPath, family, geometry) {
  const [raw, content] = await Promise.all([
    normalizedImage(pngPath).removeAlpha().raw().toBuffer(),
    contentRaw(pngPath),
  ]);
  const retention = selectSparseMotionRetention(content, family);
  const profileFractionPercent = retention?.profile_fraction_percent ?? 100;
  const vector = motionVector(
    family,
    geometry,
    selectSafeMotionTranslation(raw, family, profileFractionPercent),
    profileFractionPercent
  );
  return retention ? { ...vector, sparse_retention: retention } : vector;
}

export function selectSafeMotionTranslation(raw, family, profileFractionPercent = 100) {
  const vector = MOTION_VECTORS[family];
  if (!vector || raw?.length !== REVIEWED_FRAME.width * REVIEWED_FRAME.height * 3) {
    throw new Error("SEMANTIC_MOTION_ANCHOR_FRAME_INVALID");
  }
  if (!Number.isInteger(profileFractionPercent)
      || profileFractionPercent < 5
      || profileFractionPercent > 100
      || profileFractionPercent % 5 !== 0) {
    throw new Error("SEMANTIC_MOTION_PROFILE_FRACTION_INVALID");
  }
  const scaledTo = scaledMotionEndpoint(vector, profileFractionPercent);
  return selectSafeVectorTranslation(raw, vector.from, scaledTo);
}

export function selectSafeCoverageTranslation(
  raw,
  referenceDelta,
  coverageCrop = NATIVE_COVERAGE_CROP
) {
  if (!Number.isInteger(referenceDelta?.dx) || !Number.isInteger(referenceDelta?.dy)
      || Math.abs(referenceDelta.dx) > NATIVE_REALM_COVERAGE_CHUNK_LIMITS.x
      || Math.abs(referenceDelta.dy) > NATIVE_REALM_COVERAGE_CHUNK_LIMITS.y
      || Math.hypot(referenceDelta.dx, referenceDelta.dy) < 10) {
    throw new Error("NATIVE_REALM_COVERAGE_VECTOR_INVALID");
  }
  const from = nativeCoverageBaseAnchor(referenceDelta, coverageCrop);
  return selectSafeVectorTranslation(
    raw,
    from,
    { x: from.x + referenceDelta.dx, y: from.y + referenceDelta.dy },
    (point) => motionAnchorInsideNativeCoverageMap(point, coverageCrop)
  );
}

function selectSafeVectorTranslation(
  raw,
  referenceFrom,
  referenceTo,
  inside = motionAnchorInsideMap
) {
  if (raw?.length !== REVIEWED_FRAME.width * REVIEWED_FRAME.height * 3) {
    throw new Error("SEMANTIC_MOTION_ANCHOR_FRAME_INVALID");
  }
  const candidates = [];
  for (let dy = -MOTION_ANCHOR_TRANSLATION_MAXIMUM;
    dy <= MOTION_ANCHOR_TRANSLATION_MAXIMUM; dy += 2) {
    for (let dx = -MOTION_ANCHOR_TRANSLATION_MAXIMUM;
      dx <= MOTION_ANCHOR_TRANSLATION_MAXIMUM; dx += 2) {
      const from = { x: referenceFrom.x + dx, y: referenceFrom.y + dy };
      const to = { x: referenceTo.x + dx, y: referenceTo.y + dy };
      if (![from, to].every(inside)) continue;
      const fromRisk = motionAnchorGradientRisk(raw, from);
      const toRisk = motionAnchorGradientRisk(raw, to);
      candidates.push({
        dx,
        dy,
        from_risk: fromRisk,
        to_risk: toRisk,
        combined_risk: fromRisk + toRisk,
        distance: Math.hypot(dx, dy),
      });
    }
  }
  candidates.sort((first, second) => first.distance - second.distance
    || first.combined_risk - second.combined_risk
    || first.dy - second.dy
    || first.dx - second.dx);
  const safe = candidates.find((candidate) =>
    candidate.from_risk <= 8 && candidate.to_risk <= 8
  );
  if (safe) return { x: safe.dx, y: safe.dy };
  candidates.sort((first, second) => first.combined_risk + first.distance * 0.15
    - (second.combined_risk + second.distance * 0.15)
    || first.distance - second.distance
    || first.dy - second.dy
    || first.dx - second.dx);
  const fallback = candidates[0];
  if (!fallback) throw new Error("SEMANTIC_MOTION_ANCHOR_UNAVAILABLE");
  return { x: fallback.dx, y: fallback.dy };
}

export function selectSparseMotionRetention(raw, family) {
  const vector = MOTION_VECTORS[family];
  if (!vector || raw?.length !== CONTENT_CROP.width * CONTENT_CROP.height * 3) {
    throw new Error("SEMANTIC_SPARSE_RETENTION_FRAME_INVALID");
  }
  const stats = sparseFrameStats(raw, CONTENT_CROP.width, CONTENT_CROP.height);
  if (!sparseFrameEligible(stats)) return null;

  const minimumInformative = Math.max(
    SPARSE_RETENTION_MINIMUM_INFORMATIVE_PIXELS,
    Math.ceil(stats.informative_pixel_count * SPARSE_RETENTION_MINIMUM_FRACTION)
  );
  const minimumChromatic = Math.max(
    SPARSE_RETENTION_MINIMUM_CHROMATIC_PIXELS,
    Math.ceil(stats.chromatic_pixel_count * SPARSE_RETENTION_MINIMUM_FRACTION)
  );
  for (let profileFractionPercent = 100; profileFractionPercent >= 5;
    profileFractionPercent -= 5) {
    const scaledTo = scaledMotionEndpoint(vector, profileFractionPercent);
    const projected = {
      x: scaledTo.x - vector.from.x,
      y: scaledTo.y - vector.from.y,
    };
    if (Math.hypot(projected.x, projected.y) < DISPLACEMENT_CELL_SIZE * 2) continue;
    const retained = projectedSparseSupport(raw, projected);
    if (retained.informative_pixel_count < minimumInformative
        || retained.chromatic_pixel_count < minimumChromatic) continue;
    if (profileFractionPercent === 100) return null;
    return {
      strategy: "KEEP_VISIBLE_INFORMATIVE_SUPPORT",
      profile_fraction_percent: profileFractionPercent,
      projected_displacement_reference: projected,
      original_informative_pixels: stats.informative_pixel_count,
      original_chromatic_pixels: stats.chromatic_pixel_count,
      retained_informative_pixels: retained.informative_pixel_count,
      retained_chromatic_pixels: retained.chromatic_pixel_count,
      minimum_retained_informative_pixels: minimumInformative,
      minimum_retained_chromatic_pixels: minimumChromatic,
      retained_fraction: retained.informative_pixel_count / stats.informative_pixel_count,
    };
  }
  throw new Error("SEMANTIC_SPARSE_MOTION_RETENTION_UNAVAILABLE");
}

function scaledMotionEndpoint(vector, profileFractionPercent) {
  return {
    x: vector.from.x + Math.round(
      ((vector.to.x - vector.from.x) * profileFractionPercent) / 100
    ),
    y: vector.from.y + Math.round(
      ((vector.to.y - vector.from.y) * profileFractionPercent) / 100
    ),
  };
}

function projectedSparseSupport(raw, projected) {
  const width = CONTENT_CROP.width;
  const height = CONTENT_CROP.height;
  const margin = 2;
  let informative = 0;
  let chromatic = 0;
  for (let y = margin; y < height - margin; y += 1) {
    const projectedY = y + projected.y;
    if (projectedY < margin || projectedY >= height - margin) continue;
    for (let x = margin; x < width - margin; x += 1) {
      const projectedX = x + projected.x;
      if (projectedX < margin || projectedX >= width - margin) continue;
      const offset = (y * width + x) * 3;
      if (!informativePixel(raw, offset)) continue;
      informative += 1;
      const maximum = Math.max(raw[offset], raw[offset + 1], raw[offset + 2]);
      const minimum = Math.min(raw[offset], raw[offset + 1], raw[offset + 2]);
      if (maximum - minimum >= 12) chromatic += 1;
    }
  }
  return {
    informative_pixel_count: informative,
    chromatic_pixel_count: chromatic,
  };
}

function motionAnchorInsideMap(point) {
  const margin = 6;
  return point.x >= MAP_ACTION_REGION.left + margin
    && point.x < MAP_ACTION_REGION.right - margin
    && point.y >= MAP_ACTION_REGION.top + margin
    && point.y < MAP_ACTION_REGION.bottom - margin;
}

function nativeCoverageBaseAnchor(referenceDelta, coverageCrop = NATIVE_COVERAGE_CROP) {
  return {
    x: referenceDelta.dx >= 0
      ? coverageCrop.left + NATIVE_COVERAGE_ACTION_MARGIN
      : coverageCrop.left + coverageCrop.width - NATIVE_COVERAGE_ACTION_MARGIN,
    y: referenceDelta.dy >= 0
      ? coverageCrop.top + NATIVE_COVERAGE_ACTION_MARGIN
      : coverageCrop.top + coverageCrop.height - NATIVE_COVERAGE_ACTION_MARGIN,
  };
}

function motionAnchorInsideNativeCoverageMap(point, coverageCrop = NATIVE_COVERAGE_CROP) {
  const margin = 6;
  return point.x >= coverageCrop.left + margin
    && point.x < coverageCrop.left + coverageCrop.width - margin
    && point.y >= coverageCrop.top + margin
    && point.y < coverageCrop.top + coverageCrop.height - margin;
}

function motionAnchorGradientRisk(raw, point) {
  const width = REVIEWED_FRAME.width;
  const height = REVIEWED_FRAME.height;
  const radius = 5;
  let sum = 0;
  let count = 0;
  for (let y = Math.max(0, point.y - radius); y <= Math.min(height - 2, point.y + radius); y += 1) {
    for (let x = Math.max(0, point.x - radius); x <= Math.min(width - 2, point.x + radius); x += 1) {
      const offset = (y * width + x) * 3;
      const right = offset + 3;
      const down = offset + width * 3;
      for (let channel = 0; channel < 3; channel += 1) {
        sum += Math.abs(raw[offset + channel] - raw[right + channel]);
        sum += Math.abs(raw[offset + channel] - raw[down + channel]);
        count += 2;
      }
    }
  }
  return sum / Math.max(1, count);
}

async function displacementRaw(pngPath, width, height) {
  const normalizedCrop = await normalizedImage(pngPath)
    .extract(CONTENT_CROP)
    .png()
    .toBuffer();
  return sharp(normalizedCrop)
    .resize(width, height)
    .removeAlpha()
    .raw()
    .toBuffer();
}

export async function displacementBetween(
  firstPath,
  secondPath,
  criterionFamily = null,
  expectedDisplacement = null
) {
  const coarse = { width: 47, height: 56 };
  const fine = { width: 94, height: 112 };
  const maximum = maximumDisplacementCells();
  const [coarseFirst, coarseSecond, fineFirst, fineSecond] = await Promise.all([
    displacementRaw(firstPath, coarse.width, coarse.height),
    displacementRaw(secondPath, coarse.width, coarse.height),
    displacementRaw(firstPath, fine.width, fine.height),
    displacementRaw(secondPath, fine.width, fine.height),
  ]);
  try {
    const coarseBest = bestDisplacement({
      first: coarseFirst,
      second: coarseSecond,
      width: coarse.width,
      height: coarse.height,
      minimumDX: -Math.ceil(maximum.x / 2),
      maximumDX: Math.ceil(maximum.x / 2),
      minimumDY: -Math.ceil(maximum.y / 2),
      maximumDY: Math.ceil(maximum.y / 2),
      minimumInformativePixels: 16,
    });
    const centerDX = coarseBest.dx * 2;
    const centerDY = coarseBest.dy * 2;
    const fineSearch = {
      first: fineFirst,
      second: fineSecond,
      width: fine.width,
      height: fine.height,
      minimumDX: Math.max(-maximum.x, centerDX - 4),
      maximumDX: Math.min(maximum.x, centerDX + 4),
      minimumDY: Math.max(-maximum.y, centerDY - 4),
      maximumDY: Math.min(maximum.y, centerDY + 4),
    };
    let fineBest;
    try {
      fineBest = bestDisplacement({
        ...fineSearch,
        minimumInformativePixels: 64,
      });
    } catch (error) {
      if (error?.message !== "SEMANTIC_DISPLACEMENT_UNPROVEN") throw error;
      const sparseBest = bestDisplacement({
        ...fineSearch,
        minimumInformativePixels: 48,
      });
      if (
        sparseBest.informative_coverage < 0.75 ||
        (sparseBest.distinct_score_separation !== null &&
          sparseBest.distinct_score_separation < 4)
      ) {
        throw new Error("SEMANTIC_DISPLACEMENT_UNPROVEN");
      }
      fineBest = { ...sparseBest, evidence_mode: "sparse_unique" };
    }
    return {
      ...fineBest,
      magnitude_cells: Math.hypot(fineBest.dx, fineBest.dy),
      cell_size_reference_pixels: DISPLACEMENT_CELL_SIZE,
    };
  } catch (error) {
    if (error?.message !== "SEMANTIC_DISPLACEMENT_UNPROVEN" || !criterionFamily) throw error;
    const expected = expectedFamilyDisplacement(criterionFamily, expectedDisplacement);
    const sparseBest = bestDisplacement({
      first: fineFirst,
      second: fineSecond,
      width: fine.width,
      height: fine.height,
      minimumDX: expected.dx - 4,
      maximumDX: expected.dx + 4,
      minimumDY: expected.dy - 4,
      maximumDY: expected.dy + 4,
      minimumInformativePixels: 8,
    });
    if (
      sparseBest.informative_coverage < 0.7 ||
      (sparseBest.distinct_score_separation !== null &&
        sparseBest.distinct_score_separation < 2)
    ) {
      throw new Error("SEMANTIC_DISPLACEMENT_UNPROVEN");
    }
    return {
      ...sparseBest,
      evidence_mode: "sparse_unique_clipped",
      expected_displacement: expected,
      magnitude_cells: Math.hypot(sparseBest.dx, sparseBest.dy),
      cell_size_reference_pixels: DISPLACEMENT_CELL_SIZE,
    };
  }
}

export function evaluateSemanticNovelty({
  preRaw,
  postRaw,
  sameFamilyRaw,
  width,
  height,
  thresholds,
  criterionFamily = null,
  expectedDisplacement = null,
}) {
  const novelty = evaluateNovelty({
    preRaw,
    postRaw,
    sameFamilyRaw,
    width,
    height,
    thresholds,
  });
  const contribution = measureSemanticExtentContribution({
    preRaw,
    postRaw,
    width,
    height,
    displacement: novelty.displacement,
  });
  const extent = {
    contribution_mean_abs: contribution,
    contributed: contribution >= thresholds.new_extent_mean_abs_minimum,
  };
  const denseResult = {
    ...novelty,
    displacement: expectedDisplacement
      ? { ...novelty.displacement, expected_displacement: expectedDisplacement }
      : novelty.displacement,
    passed:
      novelty.pre_post_mean_abs >= thresholds.pre_post_mean_abs_minimum &&
      (novelty.same_family_mean_abs === null ||
        novelty.same_family_mean_abs >= thresholds.same_family_mean_abs_minimum) &&
      novelty.displacement.delivered &&
      novelty.displacement.magnitude_cells >= thresholds.delivered_displacement_minimum_cells &&
      extent.contributed,
    extent,
  };
  if (denseResult.passed || !criterionFamily) return denseResult;

  const sparse = evaluateSparseSemanticNovelty({
    preRaw,
    postRaw,
    sameFamilyRaw,
    width,
    height,
    thresholds,
    criterionFamily,
    expectedDisplacement,
  });
  return sparse ?? denseResult;
}

function evaluateSparseSemanticNovelty({
  preRaw,
  postRaw,
  sameFamilyRaw,
  width,
  height,
  thresholds,
  criterionFamily,
  expectedDisplacement,
}) {
  const preStats = sparseFrameStats(preRaw, width, height);
  const postStats = sparseFrameStats(postRaw, width, height);
  if (!sparseFrameEligible(preStats) || !sparseFrameEligible(postStats)) return null;

  const expected = expectedFamilyDisplacement(criterionFamily, expectedDisplacement);
  const thumbnail = { width: 94, height: 112 };
  const first = informativeThumbnail(preRaw, width, height, thumbnail.width, thumbnail.height);
  const second = informativeThumbnail(postRaw, width, height, thumbnail.width, thumbnail.height);
  let displacement;
  try {
    displacement = bestDisplacement({
      first,
      second,
      width: thumbnail.width,
      height: thumbnail.height,
      minimumDX: expected.dx - 4,
      maximumDX: expected.dx + 4,
      minimumDY: expected.dy - 4,
      maximumDY: expected.dy + 4,
      minimumInformativePixels: 8,
    });
  } catch (error) {
    if (error?.message === "SEMANTIC_DISPLACEMENT_UNPROVEN") return null;
    throw error;
  }
  const magnitude = Math.hypot(displacement.dx, displacement.dy);
  const uniquelySupported = displacement.informative_coverage >= 0.7
    && (displacement.distinct_score_separation === null
      || displacement.distinct_score_separation >= 2);
  const prePost = informativeMeanDifference(preRaw, postRaw, width, height);
  const sameFamily = sameFamilyRaw
    ? informativeMeanDifference(sameFamilyRaw, postRaw, width, height)
    : null;
  const contribution = sparseExtentContribution({
    preRaw,
    postRaw,
    width,
    height,
    displacement,
  });
  const extent = {
    contribution_mean_abs: contribution,
    contributed: contribution >= thresholds.new_extent_mean_abs_minimum,
    evidence_mode: "sparse_informative_union",
  };
  const delivered = uniquelySupported
    && magnitude >= thresholds.delivered_displacement_minimum_cells;
  return {
    passed: prePost >= thresholds.pre_post_mean_abs_minimum
      && (sameFamily === null || sameFamily >= thresholds.same_family_mean_abs_minimum)
      && delivered
      && extent.contributed,
    pre_post_mean_abs: prePost,
    same_family_mean_abs: sameFamily,
    displacement: {
      ...displacement,
      delivered,
      magnitude_cells: magnitude,
      evidence_mode: "sparse_unique_clipped",
      expected_displacement: expected,
    },
    extent,
    evidence_mode: "sparse_unique_clipped",
    sparse_frame_metrics: { pre: preStats, post: postStats },
  };
}

function expectedDisplacementFromMotionVector(vector) {
  const from = vector?.translated_reference?.from;
  const to = vector?.translated_reference?.to;
  if (![from?.x, from?.y, to?.x, to?.y].every(Number.isInteger)) {
    throw new Error("SEMANTIC_MOTION_VECTOR_INVALID");
  }
  return {
    dx: Math.round((to.x - from.x) / DISPLACEMENT_CELL_SIZE),
    dy: Math.round((to.y - from.y) / DISPLACEMENT_CELL_SIZE),
  };
}

function expectedFamilyDisplacement(criterionFamily, supplied = null) {
  const vector = MOTION_VECTORS[criterionFamily];
  if (!vector) throw new Error("SEMANTIC_NOVELTY_FAMILY_INVALID");
  const maximum = {
    dx: Math.round((vector.to.x - vector.from.x) / DISPLACEMENT_CELL_SIZE),
    dy: Math.round((vector.to.y - vector.from.y) / DISPLACEMENT_CELL_SIZE),
  };
  if (supplied === null) return maximum;
  if (!Number.isInteger(supplied?.dx) || !Number.isInteger(supplied?.dy)
      || Math.hypot(supplied.dx, supplied.dy) < 2) {
    throw new Error("SEMANTIC_EXPECTED_DISPLACEMENT_INVALID");
  }
  for (const axis of ["dx", "dy"]) {
    if ((maximum[axis] === 0 && supplied[axis] !== 0)
        || Math.abs(supplied[axis]) > Math.abs(maximum[axis])
        || (supplied[axis] !== 0 && Math.sign(supplied[axis]) !== Math.sign(maximum[axis]))) {
      throw new Error("SEMANTIC_EXPECTED_DISPLACEMENT_OUT_OF_PROFILE");
    }
  }
  return supplied;
}

function sparseFrameStats(raw, width, height) {
  const margin = 2;
  let informative = 0;
  let chromatic = 0;
  const interiorPixels = Math.max(1, (width - margin * 2) * (height - margin * 2));
  for (let y = margin; y < height - margin; y += 1) {
    for (let x = margin; x < width - margin; x += 1) {
      const offset = (y * width + x) * 3;
      if (!informativePixel(raw, offset)) continue;
      informative += 1;
      const maximum = Math.max(raw[offset], raw[offset + 1], raw[offset + 2]);
      const minimum = Math.min(raw[offset], raw[offset + 1], raw[offset + 2]);
      if (maximum - minimum >= 12) chromatic += 1;
    }
  }
  return {
    informative_pixel_count: informative,
    informative_fraction: informative / interiorPixels,
    chromatic_pixel_count: chromatic,
    chromatic_fraction: chromatic / interiorPixels,
  };
}

function sparseFrameEligible(stats) {
  return stats.informative_pixel_count >= 64
    && stats.chromatic_pixel_count >= 8;
}

export function sparseZoomScaleProof(beforeRaw, afterRaw, width, height) {
  if (!Number.isInteger(width) || !Number.isInteger(height)
      || beforeRaw?.length !== width * height * 3
      || afterRaw?.length !== width * height * 3) {
    throw new Error("SEMANTIC_SPARSE_ZOOM_FRAME_INVALID");
  }
  const before = sparseZoomSupport(beforeRaw, width, height);
  const after = sparseZoomSupport(afterRaw, width, height);
  const growth = {
    informative_pixel_ratio: ratio(after.informative_pixel_count, before.informative_pixel_count),
    chromatic_pixel_ratio: ratio(after.chromatic_pixel_count, before.chromatic_pixel_count),
    width_ratio: ratio(after.bounds.width, before.bounds.width),
    height_ratio: ratio(after.bounds.height, before.bounds.height),
    center_displacement_pixels: Math.hypot(
      after.centroid.x - before.centroid.x,
      after.centroid.y - before.centroid.y
    ),
  };
  const eligible = before.informative_pixel_count >= SPARSE_ZOOM_MINIMUM_INFORMATIVE_PIXELS
    && after.informative_pixel_count >= SPARSE_ZOOM_MINIMUM_INFORMATIVE_PIXELS
    && before.chromatic_pixel_count >= SPARSE_ZOOM_MINIMUM_CHROMATIC_PIXELS
    && after.chromatic_pixel_count >= SPARSE_ZOOM_MINIMUM_CHROMATIC_PIXELS
    && before.informative_fraction <= SPARSE_ZOOM_MAXIMUM_INFORMATIVE_FRACTION
    && after.informative_fraction <= SPARSE_ZOOM_MAXIMUM_INFORMATIVE_FRACTION;
  const passed = eligible
    && growth.width_ratio >= SPARSE_ZOOM_MINIMUM_LINEAR_GROWTH
    && growth.width_ratio <= SPARSE_ZOOM_MAXIMUM_LINEAR_GROWTH
    && growth.height_ratio >= SPARSE_ZOOM_MINIMUM_LINEAR_GROWTH
    && growth.height_ratio <= SPARSE_ZOOM_MAXIMUM_LINEAR_GROWTH
    && growth.informative_pixel_ratio >= SPARSE_ZOOM_MINIMUM_SUPPORT_GROWTH
    && growth.chromatic_pixel_ratio >= SPARSE_ZOOM_MINIMUM_SUPPORT_GROWTH
    && growth.center_displacement_pixels <= SPARSE_ZOOM_MAXIMUM_CENTER_DISPLACEMENT;
  return {
    passed,
    evidence_mode: "sparse_map_scale_growth_v1",
    before,
    after,
    growth,
    thresholds: {
      minimum_informative_pixels: SPARSE_ZOOM_MINIMUM_INFORMATIVE_PIXELS,
      minimum_chromatic_pixels: SPARSE_ZOOM_MINIMUM_CHROMATIC_PIXELS,
      maximum_informative_fraction: SPARSE_ZOOM_MAXIMUM_INFORMATIVE_FRACTION,
      minimum_linear_growth: SPARSE_ZOOM_MINIMUM_LINEAR_GROWTH,
      maximum_linear_growth: SPARSE_ZOOM_MAXIMUM_LINEAR_GROWTH,
      minimum_support_growth: SPARSE_ZOOM_MINIMUM_SUPPORT_GROWTH,
      maximum_center_displacement_pixels: SPARSE_ZOOM_MAXIMUM_CENTER_DISPLACEMENT,
    },
  };
}

function sparseZoomSupport(raw, width, height) {
  const margin = 4;
  let informative = 0;
  let chromatic = 0;
  let sumX = 0;
  let sumY = 0;
  let left = width;
  let top = height;
  let right = -1;
  let bottom = -1;
  for (let y = margin; y < height - margin; y += 1) {
    for (let x = margin; x < width - margin; x += 1) {
      const offset = (y * width + x) * 3;
      if (!informativePixel(raw, offset)) continue;
      informative += 1;
      sumX += x;
      sumY += y;
      left = Math.min(left, x);
      top = Math.min(top, y);
      right = Math.max(right, x);
      bottom = Math.max(bottom, y);
      const maximum = Math.max(raw[offset], raw[offset + 1], raw[offset + 2]);
      const minimum = Math.min(raw[offset], raw[offset + 1], raw[offset + 2]);
      if (maximum - minimum >= 12) chromatic += 1;
    }
  }
  const interiorPixels = Math.max(1, (width - margin * 2) * (height - margin * 2));
  return {
    informative_pixel_count: informative,
    informative_fraction: informative / interiorPixels,
    chromatic_pixel_count: chromatic,
    bounds: {
      left,
      top,
      right,
      bottom,
      width: informative > 0 ? right - left + 1 : 0,
      height: informative > 0 ? bottom - top + 1 : 0,
    },
    centroid: {
      x: informative > 0 ? sumX / informative : -1,
      y: informative > 0 ? sumY / informative : -1,
    },
  };
}

function ratio(numerator, denominator) {
  return denominator > 0 ? numerator / denominator : 0;
}

function informativeThumbnail(raw, width, height, targetWidth, targetHeight) {
  const thumbnail = Buffer.alloc(targetWidth * targetHeight * 3);
  for (let targetY = 0; targetY < targetHeight; targetY += 1) {
    const sourceTop = Math.floor((targetY * height) / targetHeight);
    const sourceBottom = Math.max(sourceTop + 1, Math.floor(((targetY + 1) * height) / targetHeight));
    for (let targetX = 0; targetX < targetWidth; targetX += 1) {
      const sourceLeft = Math.floor((targetX * width) / targetWidth);
      const sourceRight = Math.max(sourceLeft + 1, Math.floor(((targetX + 1) * width) / targetWidth));
      const sums = [0, 0, 0];
      let count = 0;
      for (let y = sourceTop; y < sourceBottom; y += 1) {
        for (let x = sourceLeft; x < sourceRight; x += 1) {
          const offset = (y * width + x) * 3;
          sums[0] += raw[offset];
          sums[1] += raw[offset + 1];
          sums[2] += raw[offset + 2];
          count += 1;
        }
      }
      if (count === 0) continue;
      const targetOffset = (targetY * targetWidth + targetX) * 3;
      thumbnail[targetOffset] = Math.round(sums[0] / count);
      thumbnail[targetOffset + 1] = Math.round(sums[1] / count);
      thumbnail[targetOffset + 2] = Math.round(sums[2] / count);
    }
  }
  return thumbnail;
}

function informativeMeanDifference(first, second, width, height, region = null) {
  const bounds = region ?? { left: 2, top: 2, width: width - 4, height: height - 4 };
  let sum = 0;
  let count = 0;
  for (let y = bounds.top; y < bounds.top + bounds.height; y += 1) {
    for (let x = bounds.left; x < bounds.left + bounds.width; x += 1) {
      const offset = (y * width + x) * 3;
      if (!informativePixel(first, offset) && !informativePixel(second, offset)) continue;
      sum += Math.abs(first[offset] - second[offset]);
      sum += Math.abs(first[offset + 1] - second[offset + 1]);
      sum += Math.abs(first[offset + 2] - second[offset + 2]);
      count += 3;
    }
  }
  return sum / Math.max(1, count);
}

function sparseExtentContribution({ preRaw, postRaw, width, height, displacement }) {
  const contributions = [];
  if (Math.abs(displacement.dx) >= 2) {
    const edgeWidth = Math.max(
      2,
      Math.min(Math.floor(width / 3), Math.round((Math.abs(displacement.dx) * width) / 94))
    );
    for (const left of [2, width - edgeWidth - 2]) {
      contributions.push(informativeMeanDifference(preRaw, postRaw, width, height, {
        left,
        top: 2,
        width: edgeWidth,
        height: height - 4,
      }));
    }
  }
  if (Math.abs(displacement.dy) >= 2) {
    const edgeHeight = Math.max(
      2,
      Math.min(Math.floor(height / 3), Math.round((Math.abs(displacement.dy) * height) / 112))
    );
    for (const top of [2, height - edgeHeight - 2]) {
      contributions.push(informativeMeanDifference(preRaw, postRaw, width, height, {
        left: 2,
        top,
        width: width - 4,
        height: edgeHeight,
      }));
    }
  }
  return contributions.length === 0 ? 0 : Math.max(...contributions);
}

export function measureSemanticExtentContribution({
  preRaw,
  postRaw,
  width,
  height,
  displacement,
}) {
  const contributions = [];
  if (Math.abs(displacement.dx) >= 2) {
    const stripWidth = Math.max(
      2,
      Math.min(Math.floor(width / 3), Math.round((Math.abs(displacement.dx) * width) / 94))
    );
    for (const left of [0, width - stripWidth]) {
      contributions.push(edgeMeanDifference({
        preRaw,
        postRaw,
        width,
        left,
        top: 0,
        edgeWidth: stripWidth,
        edgeHeight: height,
      }));
    }
  }
  if (Math.abs(displacement.dy) >= 2) {
    const stripHeight = Math.max(
      2,
      Math.min(Math.floor(height / 3), Math.round((Math.abs(displacement.dy) * height) / 112))
    );
    for (const top of [0, height - stripHeight]) {
      contributions.push(edgeMeanDifference({
        preRaw,
        postRaw,
        width,
        left: 0,
        top,
        edgeWidth: width,
        edgeHeight: stripHeight,
      }));
    }
  }
  return contributions.length === 0 ? 0 : Math.max(...contributions);
}

function edgeMeanDifference({
  preRaw,
  postRaw,
  width,
  left,
  top,
  edgeWidth,
  edgeHeight,
}) {
  let sum = 0;
  let count = 0;
  for (let y = top; y < top + edgeHeight; y += 3) {
    for (let x = left; x < left + edgeWidth; x += 3) {
      const index = (y * width + x) * 3;
      sum += Math.abs(preRaw[index] - postRaw[index]);
      sum += Math.abs(preRaw[index + 1] - postRaw[index + 1]);
      sum += Math.abs(preRaw[index + 2] - postRaw[index + 2]);
      count += 3;
    }
  }
  return sum / Math.max(1, count);
}

export async function restorationReferenceAnchor(pngPath, displacement) {
  if (!Number.isInteger(displacement?.dx) || !Number.isInteger(displacement?.dy)) {
    throw new Error("SEMANTIC_RESTORATION_MEASUREMENT_INVALID");
  }
  const delta = {
    x: -displacement.dx * DISPLACEMENT_CELL_SIZE,
    y: -displacement.dy * DISPLACEMENT_CELL_SIZE,
  };
  const margin = 5;
  const minimum = {
    x: Math.max(MAP_ACTION_REGION.left + margin, MAP_ACTION_REGION.left + margin - delta.x),
    y: Math.max(MAP_ACTION_REGION.top + margin, MAP_ACTION_REGION.top + margin - delta.y),
  };
  const maximum = {
    x: Math.min(MAP_ACTION_REGION.right - margin, MAP_ACTION_REGION.right - margin - delta.x),
    y: Math.min(MAP_ACTION_REGION.bottom - margin, MAP_ACTION_REGION.bottom - margin - delta.y),
  };
  if (minimum.x > maximum.x || minimum.y > maximum.y) {
    throw new Error("SEMANTIC_RESTORATION_ANCHOR_RANGE_EMPTY");
  }
  const { data, info } = await normalizedImage(pngPath)
    .removeAlpha()
    .raw()
    .toBuffer({ resolveWithObject: true });
  const mask = new Uint8Array(info.width * info.height);
  for (let index = 0; index < mask.length; index += 1) {
    const offset = index * info.channels;
    mask[index] = informativePixel(data, offset) ? 1 : 0;
  }
  const integral = integralMask(mask, info.width, info.height);
  const center = {
    x: (minimum.x + maximum.x) / 2,
    y: (minimum.y + maximum.y) / 2,
  };
  const radius = 5;
  let best = null;
  const centralInset = {
    x: Math.floor((maximum.x - minimum.x) * 0.2),
    y: Math.floor((maximum.y - minimum.y) * 0.2),
  };
  const searchBounds = [
    {
      minimum: { x: minimum.x + centralInset.x, y: minimum.y + centralInset.y },
      maximum: { x: maximum.x - centralInset.x, y: maximum.y - centralInset.y },
    },
    { minimum, maximum },
  ];
  for (const bounds of searchBounds) {
    for (let y = bounds.minimum.y; y <= bounds.maximum.y; y += 1) {
      for (let x = bounds.minimum.x; x <= bounds.maximum.x; x += 1) {
        const informative = integralSum(
          integral,
          info.width + 1,
          Math.max(MAP_ACTION_REGION.left, x - radius),
          Math.max(MAP_ACTION_REGION.top, y - radius),
          Math.min(MAP_ACTION_REGION.right, x + radius + 1),
          Math.min(MAP_ACTION_REGION.bottom, y + radius + 1)
        );
        if (informative < 25) continue;
        const distance = Math.hypot(x - center.x, y - center.y);
        const gradientRisk = motionAnchorGradientRisk(data, { x, y });
        if (!best || gradientRisk < best.gradient_risk
            || (gradientRisk === best.gradient_risk && distance < best.center_distance)) {
          best = {
            reference_point: { x, y },
            local_informative_pixels: informative,
            neighborhood_pixels: (radius * 2 + 1) ** 2,
            center_distance: distance,
            gradient_risk: gradientRisk,
            selection_strategy: "LOWEST_GRADIENT_NEAREST_FEASIBLE_CENTER",
          };
        }
      }
    }
    if (best) break;
  }
  if (!best || best.local_informative_pixels < 25) {
    throw new Error("SEMANTIC_RESTORATION_MAP_ANCHOR_UNPROVEN");
  }
  return best;
}

function maximumDisplacementCells() {
  return Object.values(MOTION_VECTORS).reduce((maximum, vector) => ({
    x: Math.max(maximum.x, Math.abs(vector.to.x - vector.from.x) / DISPLACEMENT_CELL_SIZE),
    y: Math.max(maximum.y, Math.abs(vector.to.y - vector.from.y) / DISPLACEMENT_CELL_SIZE),
  }), { x: 0, y: 0 });
}

function bestDisplacement({
  first,
  second,
  width,
  height,
  minimumDX,
  maximumDX,
  minimumDY,
  maximumDY,
  minimumInformativePixels,
  expectedDX = null,
  expectedDY = null,
  expectationBiasPerPixel = 0,
  firstEdges = null,
  secondEdges = null,
  minimumEdgePixels = 0,
}) {
  const candidates = [];
  const edgeCandidates = [];
  for (let dy = minimumDY; dy <= maximumDY; dy += 1) {
    for (let dx = minimumDX; dx <= maximumDX; dx += 1) {
      let candidate = displacementCandidate(first, second, width, height, dx, dy);
      if (candidate.informative_pixel_count < minimumInformativePixels) continue;
      if (firstEdges && secondEdges) {
        const edgeCandidate = edgeDisplacementCandidate(
          firstEdges,
          secondEdges,
          width,
          height,
          dx,
          dy
        );
        candidate = {
          ...candidate,
          edge_error: edgeCandidate.error,
          edge_score: edgeCandidate.score,
          edge_informative_coverage: edgeCandidate.informative_coverage,
          edge_informative_pixel_count: edgeCandidate.informative_pixel_count,
        };
        if (edgeCandidate.informative_pixel_count >= minimumEdgePixels) {
          edgeCandidates.push(candidate);
        }
      }
      candidates.push(candidate);
    }
  }
  const useEdgeSelection = edgeCandidates.length > 0;
  const selectableCandidates = useEdgeSelection ? edgeCandidates : candidates;
  const selectionScore = (candidate) => (
    useEdgeSelection ? candidate.edge_score : candidate.score
  ) + (
    Number.isInteger(expectedDX) && Number.isInteger(expectedDY)
      ? Math.hypot(candidate.dx - expectedDX, candidate.dy - expectedDY)
        * expectationBiasPerPixel
      : 0
  );
  selectableCandidates.sort((firstCandidate, secondCandidate) =>
    selectionScore(firstCandidate) - selectionScore(secondCandidate)
  );
  const best = selectableCandidates[0];
  if (!best) throw new Error("SEMANTIC_DISPLACEMENT_UNPROVEN");
  const distinctSecond = selectableCandidates.find((candidate) =>
    Math.abs(candidate.dx - best.dx) > 1 || Math.abs(candidate.dy - best.dy) > 1
  );
  return {
    ...best,
    alignment_selection_mode: useEdgeSelection
      ? "edge_expected_neighborhood"
      : "raw_low_edge_fallback",
    selection_score: selectionScore(best),
    distinct_score_separation: distinctSecond
      ? selectionScore(distinctSecond) - selectionScore(best)
      : null,
  };
}

function luminanceGradient(data, width, height) {
  const luminance = new Float32Array(width * height);
  const gradient = new Float32Array(width * height);
  for (let index = 0; index < luminance.length; index += 1) {
    const offset = index * 3;
    luminance[index] = (
      data[offset] * 77 + data[offset + 1] * 150 + data[offset + 2] * 29
    ) / 256;
  }
  for (let y = 1; y < height - 1; y += 1) {
    for (let x = 1; x < width - 1; x += 1) {
      const index = y * width + x;
      gradient[index] = Math.abs(luminance[index + 1] - luminance[index - 1])
        + Math.abs(luminance[index + width] - luminance[index - width]);
    }
  }
  return gradient;
}

function edgeDisplacementCandidate(first, second, width, height, dx, dy) {
  const minimumX = Math.max(1, -dx + 1);
  const maximumX = Math.min(width - 1, width - dx - 1);
  const minimumY = Math.max(1, -dy + 1);
  const maximumY = Math.min(height - 1, height - dy - 1);
  let sum = 0;
  let intersection = 0;
  let union = 0;
  for (let y = minimumY; y < maximumY; y += 1) {
    for (let x = minimumX; x < maximumX; x += 1) {
      const firstIndex = y * width + x;
      const secondIndex = (y + dy) * width + x + dx;
      const firstInformative = first[firstIndex] >= NATIVE_COVERAGE_EDGE_MINIMUM;
      const secondInformative = second[secondIndex] >= NATIVE_COVERAGE_EDGE_MINIMUM;
      if (firstInformative || secondInformative) union += 1;
      if (!firstInformative || !secondInformative) continue;
      sum += Math.abs(first[firstIndex] - second[secondIndex]);
      intersection += 1;
    }
  }
  const error = sum / Math.max(1, intersection);
  const informativeCoverage = intersection / Math.max(1, union);
  return {
    dx,
    dy,
    error,
    score: error + (1 - informativeCoverage) * 30,
    informative_coverage: informativeCoverage,
    informative_pixel_count: intersection,
  };
}

function displacementCandidate(first, second, width, height, dx, dy) {
  const minimumX = Math.max(0, -dx);
  const maximumX = Math.min(width, width - dx);
  const minimumY = Math.max(0, -dy);
  const maximumY = Math.min(height, height - dy);
  let sum = 0;
  let intersection = 0;
  let union = 0;
  for (let y = minimumY; y < maximumY; y += 1) {
    for (let x = minimumX; x < maximumX; x += 1) {
      const firstOffset = (y * width + x) * 3;
      const secondOffset = ((y + dy) * width + x + dx) * 3;
      const firstInformative = informativePixel(first, firstOffset);
      const secondInformative = informativePixel(second, secondOffset);
      if (firstInformative || secondInformative) union += 1;
      if (!firstInformative || !secondInformative) continue;
      sum += Math.abs(first[firstOffset] - second[secondOffset])
        + Math.abs(first[firstOffset + 1] - second[secondOffset + 1])
        + Math.abs(first[firstOffset + 2] - second[secondOffset + 2]);
      intersection += 1;
    }
  }
  const error = sum / Math.max(1, intersection * 3);
  const informativeCoverage = intersection / Math.max(1, union);
  return {
    dx,
    dy,
    error,
    score: error + (1 - informativeCoverage) * 30,
    informative_coverage: informativeCoverage,
    informative_pixel_count: intersection,
  };
}

function informativePixel(data, offset) {
  return Math.max(data[offset], data[offset + 1], data[offset + 2]) > 25;
}

function integralMask(mask, width, height) {
  const stride = width + 1;
  const integral = new Uint32Array(stride * (height + 1));
  for (let y = 0; y < height; y += 1) {
    let row = 0;
    for (let x = 0; x < width; x += 1) {
      row += mask[y * width + x];
      integral[(y + 1) * stride + x + 1] = integral[y * stride + x + 1] + row;
    }
  }
  return integral;
}

function integralSum(integral, stride, left, top, right, bottom) {
  return integral[bottom * stride + right]
    - integral[top * stride + right]
    - integral[bottom * stride + left]
    + integral[top * stride + left];
}

function assertDeadline(deadline) {
  if (Date.now() >= deadline) throw new Error("ITEM_EXECUTION_DEADLINE_EXCEEDED");
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

const defaultPerception = Object.freeze({
  requireSemanticCalibrationGate: () => loadSemanticCalibrationRegistry({ requireAll: true }),
  classifyCapture,
  classifySemanticPostCloseCapture,
  localizeSemanticCoverageMapClose,
  localizeSemanticMapClose,
  requireAuthorizedOSRSCoverageMap,
  requireAuthorizedOSRSMap,
  localizeSemanticSurfaceSelector,
  localizeSemanticSurfaceOption,
  localizeSemanticSurfaceScrollbar,
  observeSemanticSurfaceScrollbar,
  localizeSemanticZoom,
  proveSemanticCoverageReadiness,
  proveSemanticMapReadiness,
});

const defaultAnalysis = Object.freeze({
  contentRaw,
  nativeContentRaw,
  mapCrop,
  nativeMapCrop,
  safeMotionVector,
  safeNativeCoverageVector,
  nativeCoverageDisplacementBetween,
  displacementBetween,
  restorationReferenceAnchor,
  evaluateNovelty: evaluateSemanticNovelty,
  sparseZoomScaleProof,
  meanDifference,
});
