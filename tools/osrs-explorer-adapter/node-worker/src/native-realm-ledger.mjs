import { canonicalJson, sha256 } from "./protocol.mjs";

export const NATIVE_REALM_LEDGER_SCHEMA_VERSION = 1;
export const NATIVE_REALM_LEDGER_STATES = Object.freeze([
  "planned",
  "accepted_in_sandbox",
  "canonically_exported",
  "failed",
  "revoked",
]);

export function createNativeRealmCoverageLedger({ queue, plan, createdAt = new Date().toISOString() }) {
  if (queue?.schema_version !== 2 || queue.execution_profile !== "semantic_map_capture_v1") {
    throw new Error("NATIVE_REALM_LEDGER_QUEUE_INVALID");
  }
  const items = queue.items.map((item, order) => ({
    order,
    item_id: item.id,
    item_sha256: item.item_sha256,
    realm_id: item.realm_id,
    selector_index: item.selector_index,
    surface: item.surface,
    zoom_percent: item.zoom_percent,
    capture_center: item.capture_center,
    coverage_cell: item.coverage_cell,
    state: "planned",
    accepted_result_digest: null,
    canonical_export_digest: null,
    failed_reason: null,
    predecessor_item_id: order === 0 ? null : queue.items[order - 1].id,
    updated_at: createdAt,
  }));
  const ledger = {
    schema_version: NATIVE_REALM_LEDGER_SCHEMA_VERSION,
    ledger_version: "native-realm-production-coverage-ledger-v1",
    catalog_version: plan.catalog_version,
    planner_version: plan.planner_version,
    queue_generation_id: queue.generation_id,
    queue_policy_digest: queue.policy_digest,
    queue_item_count: queue.items.length,
    created_at: createdAt,
    updated_at: createdAt,
    items,
    summary: summarizeLedgerItems(items),
    history: [{
      event: "ledger_created",
      at: createdAt,
      queue_generation_id: queue.generation_id,
      queue_item_count: queue.items.length,
    }],
  };
  return verifyNativeRealmCoverageLedger(ledger, queue);
}

export function verifyNativeRealmCoverageLedger(ledger, queue = null) {
  if (ledger?.schema_version !== NATIVE_REALM_LEDGER_SCHEMA_VERSION
      || ledger.ledger_version !== "native-realm-production-coverage-ledger-v1"
      || !Array.isArray(ledger.items)
      || ledger.queue_item_count !== ledger.items.length) {
    throw new Error("NATIVE_REALM_LEDGER_INVALID");
  }
  let predecessor = null;
  ledger.items.forEach((item, order) => {
    if (item.order !== order
        || item.predecessor_item_id !== predecessor
        || !NATIVE_REALM_LEDGER_STATES.includes(item.state)
        || item.realm_id?.startsWith("other-map-")
        || item.realm_id?.startsWith("cache-special-region:")
        || item.selector_index < 0
        || item.selector_index >= 47) {
      throw new Error(`NATIVE_REALM_LEDGER_ITEM_INVALID:${item.item_id}`);
    }
    predecessor = item.item_id;
  });
  const summary = summarizeLedgerItems(ledger.items);
  if (canonicalJson(summary) !== canonicalJson(ledger.summary)) {
    throw new Error("NATIVE_REALM_LEDGER_SUMMARY_INVALID");
  }
  if (queue) {
    if (queue.items.length !== ledger.items.length
        || queue.generation_id !== ledger.queue_generation_id
        || queue.policy_digest !== ledger.queue_policy_digest) {
      throw new Error("NATIVE_REALM_LEDGER_QUEUE_BINDING_INVALID");
    }
    for (const [index, item] of queue.items.entries()) {
      const row = ledger.items[index];
      if (row.item_id !== item.id
          || row.item_sha256 !== item.item_sha256
          || row.realm_id !== item.realm_id
          || row.zoom_percent !== item.zoom_percent) {
        throw new Error(`NATIVE_REALM_LEDGER_QUEUE_ITEM_BINDING_INVALID:${item.id}`);
      }
    }
  }
  return ledger;
}

export function applyNativeRealmLedgerEvent(
  ledger,
  event,
  now = new Date().toISOString()
) {
  const next = structuredClone(verifyNativeRealmCoverageLedger(ledger));
  const row = next.items.find((candidate) => candidate.item_id === event?.item_id);
  if (!row) throw new Error(`NATIVE_REALM_LEDGER_EVENT_ITEM_UNKNOWN:${event?.item_id}`);
  if (event.item_sha256 !== row.item_sha256) {
    throw new Error(`NATIVE_REALM_LEDGER_EVENT_SHA_MISMATCH:${event.item_id}`);
  }
  if ((event.predecessor_item_id ?? null) !== row.predecessor_item_id) {
    throw new Error(`NATIVE_REALM_LEDGER_PREDECESSOR_MISMATCH:${event.item_id}`);
  }
  if (row.state === "failed" || row.state === "revoked") {
    requireExactTerminalReplay(next, row, event);
    return next;
  }
  const priorState = row.state;
  if (event.event === "accepted_in_sandbox") {
    const resultDigest = requiredDigest(event.result_digest, "RESULT_DIGEST");
    if (row.state === "canonically_exported") return next;
    if (row.state === "accepted_in_sandbox") {
      if (row.accepted_result_digest !== resultDigest) {
        throw new Error(`NATIVE_REALM_LEDGER_ACCEPTANCE_REPLAY_MISMATCH:${event.item_id}`);
      }
      return next;
    }
    if (row.state !== "planned" && row.state !== "accepted_in_sandbox") {
      throw new Error(`NATIVE_REALM_LEDGER_ACCEPTANCE_STATE_INVALID:${event.item_id}:${row.state}`);
    }
    row.state = "accepted_in_sandbox";
    row.accepted_result_digest = resultDigest;
  } else if (event.event === "canonically_exported") {
    const exportDigest = requiredDigest(event.export_digest, "EXPORT_DIGEST");
    if (row.state === "canonically_exported") {
      if (row.canonical_export_digest !== exportDigest) {
        throw new Error(`NATIVE_REALM_LEDGER_EXPORT_REPLAY_MISMATCH:${event.item_id}`);
      }
      return next;
    }
    if (row.state !== "accepted_in_sandbox") {
      throw new Error(`NATIVE_REALM_LEDGER_EXPORT_STATE_INVALID:${event.item_id}:${row.state}`);
    }
    row.state = "canonically_exported";
    row.canonical_export_digest = exportDigest;
  } else if (event.event === "failed" || event.event === "revoked") {
    if (row.state === "canonically_exported") {
      throw new Error(`NATIVE_REALM_LEDGER_TERMINAL_EXPORT_REVOKE_FORBIDDEN:${event.item_id}`);
    }
    row.state = event.event;
    row.failed_reason = String(event.reason || "").slice(0, 240);
    if (!row.failed_reason) throw new Error(`NATIVE_REALM_LEDGER_${event.event.toUpperCase()}_REASON_REQUIRED`);
  } else {
    throw new Error(`NATIVE_REALM_LEDGER_EVENT_UNSUPPORTED:${event?.event}`);
  }
  row.updated_at = now;
  next.updated_at = now;
  next.summary = summarizeLedgerItems(next.items);
  next.history.push({
    event: event.event,
    at: now,
    item_id: row.item_id,
    prior_state: priorState,
    state: row.state,
    event_sha256: sha256(canonicalJson(event)),
  });
  return verifyNativeRealmCoverageLedger(next);
}

export function nextNativeRealmLedgerItem(ledger) {
  const verified = verifyNativeRealmCoverageLedger(ledger);
  return verified.items.find((item) => item.state === "planned") ?? null;
}

export function summarizeLedgerItems(items) {
  const summary = {
    planned: 0,
    accepted_in_sandbox: 0,
    canonically_exported: 0,
    failed: 0,
    revoked: 0,
    remaining: 0,
    terminal: 0,
    total: items.length,
  };
  for (const item of items) {
    summary[item.state] += 1;
    if (item.state === "planned") summary.remaining += 1;
    if (item.state === "canonically_exported" || item.state === "failed" || item.state === "revoked") {
      summary.terminal += 1;
    }
  }
  return summary;
}

function requiredDigest(value, label) {
  if (typeof value !== "string" || !/^[a-f0-9]{64}$/.test(value)) {
    throw new Error(`NATIVE_REALM_LEDGER_${label}_INVALID`);
  }
  return value;
}

function requireExactTerminalReplay(ledger, row, event) {
  const reason = String(event.reason || "").slice(0, 240);
  const terminalEvents = ledger.history.filter((entry) =>
    entry.item_id === row.item_id && (entry.state === "failed" || entry.state === "revoked")
  );
  const recorded = terminalEvents.length === 1 ? terminalEvents[0] : null;
  const exactReplay = event.event === row.state
    && reason.length > 0
    && row.failed_reason === reason
    && recorded?.event === row.state
    && recorded.state === row.state
    && recorded.at === row.updated_at
    && recorded.event_sha256 === sha256(canonicalJson(event));
  if (!exactReplay) {
    throw new Error(`NATIVE_REALM_LEDGER_TERMINAL_IMMUTABLE:${event.item_id}:${row.state}`);
  }
}
