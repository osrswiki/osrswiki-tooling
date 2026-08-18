export async function captureAuthorizedOSRSPostAction({
  captureFrame,
  classify,
  recordEvidence,
  attempts = 5,
  intervalMilliseconds = 250,
  wait = delay
}) {
  let lastError = null;
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    const capture = await captureFrame();
    recordEvidence({ kind: "post_capture", attempt, capture });
    try {
      const classification = await classify(capture.pngPath);
      recordEvidence({
        kind: "post_action_osrs_screen_qualification",
        attempt,
        classification
      });
      return capture;
    } catch (error) {
      lastError = error;
      recordEvidence({
        kind: "post_action_osrs_screen_rejection",
        attempt,
        error: String(error?.message || error)
      });
      if (attempt < attempts) await wait(intervalMilliseconds);
    }
  }
  throw new Error(
    `POST_ACTION_OSRS_SCREEN_UNQUALIFIED_AFTER_${attempts}:${String(lastError?.message || lastError)}`,
    { cause: lastError }
  );
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}
