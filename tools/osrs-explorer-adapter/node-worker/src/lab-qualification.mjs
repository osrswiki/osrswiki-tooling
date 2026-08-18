export function requireLabVisualAcknowledgement(before, after, operation) {
  if (!before?.pngSHA256 || !after?.pngSHA256) {
    throw new Error("LAB_VISUAL_ACK_CAPTURE_MISSING");
  }
  if (before.pngSHA256 === after.pngSHA256) {
    const mode = operation?.event_source_mode || "private_state";
    throw new Error(`LAB_VISUAL_ACK_MISSING:${operation?.kind || "unknown"}:${mode}`);
  }
}
