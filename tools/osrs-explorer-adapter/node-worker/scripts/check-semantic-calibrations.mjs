#!/usr/bin/env node
import { loadSemanticCalibrationRegistry } from "../src/semantic-profile.mjs";

const registry = loadSemanticCalibrationRegistry({ requireAll: true });
process.stdout.write(`${JSON.stringify({
  status: "SEMANTIC_CALIBRATION_GATE_PASSED",
  surfaces: Object.keys(registry.surfaces),
  minimum_normalized_correlation: registry.minimum_normalized_correlation,
  minimum_correlation_separation: registry.minimum_correlation_separation,
})}\n`);
