export async function reportFailedClaim({
  claim,
  error,
  writeFailureEvidence,
  completeFailure
}) {
  let evidenceError = null;
  try {
    writeFailureEvidence({
      schema_version: 1,
      generation_id: claim.generation_id,
      item_id: claim.item.id,
      error: String(error?.stack || error),
      evidence: error?.partialEvidence || [],
      failed_at: new Date().toISOString()
    });
  } catch (caught) {
    evidenceError = caught;
  }

  let completionError = null;
  try {
    await completeFailure();
  } catch (caught) {
    completionError = caught;
  }

  if (completionError) throw completionError;
  if (evidenceError) throw evidenceError;
}
