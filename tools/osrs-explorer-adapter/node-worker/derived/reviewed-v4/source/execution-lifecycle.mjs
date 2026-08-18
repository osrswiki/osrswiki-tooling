import crypto from "node:crypto";

const COUNTER_KEYS = Object.freeze([
  "root_promises",
  "timers",
  "ui_operations",
  "policy_calls",
  "transport_calls",
  "broker_requests",
  "finalizer_requests",
  "transport_close_barriers",
  "listener_callbacks",
  "descendant_resources"
]);

function serializedReason(reason) {
  if (!reason) return null;
  return {
    name: reason?.name || "Error",
    message: String(reason?.message || reason),
    code: reason?.code || null
  };
}

function abortError(stage, reason = null) {
  const error = new Error(
    `PRECISELY_BLOCKED_LIFECYCLE_ABORTED:${stage}:` +
      `${String(reason?.message || reason || "unspecified")}`
  );
  error.name = "LifecycleAbortError";
  error.code = "LIFECYCLE_ABORTED";
  return error;
}

export class ExecutionLifecycle {
  constructor({
    assertActiveExecutionContext,
    identity,
    now = Date.now
  }) {
    if (typeof assertActiveExecutionContext !== "function") {
      throw new Error("ACTIVE_EXECUTION_CONTEXT_GUARD_REQUIRED");
    }
    this.identity = identity;
    this.assertActiveExecutionContext = assertActiveExecutionContext;
    this.now = now;
    this.abortController = new AbortController();
    this.admissionOpen = true;
    this.controllerActive = true;
    this.aborted = false;
    this.abortReason = null;
    this.finalizerReceipt = null;
    this.reservationReceipt = null;
    this.counters = Object.fromEntries(COUNTER_KEYS.map((key) => [key, 0]));
    this.inFlight = new Map();
    this.callbackRegistrations = new Map();
    this.unprovenDescendants = new Map();
    this.callbackErrors = [];
    this.resourceErrors = [];
    this.lateCallbacks = 0;
    this.drainCompleted = false;
  }

  get signal() {
    return this.abortController.signal;
  }

  setReservationReceipt(receipt) {
    if (!receipt?.reservation_id || !receipt?.reservation_sha256) {
      throw new Error("FINALIZER_RESERVATION_RECEIPT_INVALID");
    }
    this.reservationReceipt = structuredClone(receipt);
  }

  async assertContext(stage) {
    if (!this.admissionOpen || this.aborted) {
      throw abortError(stage, this.abortReason);
    }
    try {
      await this.assertActiveExecutionContext(stage);
    } catch (error) {
      this.abort(error);
      const wrapped = new Error(
        `PRECISELY_BLOCKED_EXECUTION_CONTEXT_LOST:${stage}:` +
          `${String(error?.message || error)}`
      );
      wrapped.name = "ExecutionContextLostError";
      wrapped.code = "EXECUTION_CONTEXT_LOST";
      wrapped.cause = error;
      throw wrapped;
    }
  }

  closeAdmission(reason = null) {
    if (!this.admissionOpen) return false;
    this.admissionOpen = false;
    if (reason && !this.abortReason) this.abortReason = reason;
    return true;
  }

  abort(reason) {
    this.closeAdmission(reason);
    if (!this.aborted) {
      this.aborted = true;
      this.abortReason = reason || this.abortReason || new Error("LIFECYCLE_ABORT");
      this.abortController.abort(this.abortReason);
    }
  }

  markControllerInactive() {
    this.controllerActive = false;
  }

  _counterFor(kind) {
    if (kind === "root") return "root_promises";
    if (kind === "timer") return "timers";
    if (kind === "ui") return "ui_operations";
    if (kind === "policy") return "policy_calls";
    if (kind === "transport") return "transport_calls";
    if (kind === "broker") return "broker_requests";
    if (kind === "finalizer") return "finalizer_requests";
    if (kind === "transport-close") return "transport_close_barriers";
    if (kind === "callback") return "listener_callbacks";
    if (kind === "descendant") return "descendant_resources";
    throw new Error(`UNKNOWN_LIFECYCLE_OPERATION_KIND:${kind}`);
  }

  _trackPromise(kind, label, promise, {
    terminalResource = false,
    recordFailure = false,
    alreadyCounted = false
  } = {}) {
    const counter = this._counterFor(kind);
    const id = `${this.identity}:${label}:${crypto.randomBytes(8).toString("hex")}`;
    if (!alreadyCounted) this.counters[counter] += 1;
    const tracked = Promise.resolve(promise)
      .catch((error) => {
        if (recordFailure) {
          this.resourceErrors.push({
            id,
            kind,
            label,
            terminal_resource: terminalResource,
            error
          });
        }
        throw error;
      })
      .finally(() => {
        this.inFlight.delete(id);
        this.counters[counter] -= 1;
      });
    this.inFlight.set(id, {
      id,
      kind,
      label,
      promise: tracked,
      terminalResource
    });
    return tracked;
  }

  trackDescendant(label, promise, { terminalResource = false } = {}) {
    return this._trackPromise("descendant", label, promise, {
      terminalResource,
      recordFailure: true
    });
  }

  trackTransportClose(label, promise) {
    return this._trackPromise("transport-close", label, promise, {
      terminalResource: true,
      recordFailure: true
    });
  }

  registerUnprovenDescendant(label, { terminalResource = false } = {}) {
    const id = `${this.identity}:${label}:${crypto.randomBytes(8).toString("hex")}`;
    this.counters.descendant_resources += 1;
    this.unprovenDescendants.set(id, {
      id,
      label,
      terminalResource
    });
    let settled = false;
    return {
      id,
      track: (promise) => {
        if (settled) {
          throw new Error(`DESCENDANT_PROOF_ALREADY_SETTLED:${label}`);
        }
        settled = true;
        this.unprovenDescendants.delete(id);
        return this._trackPromise("descendant", label, promise, {
          terminalResource,
          recordFailure: true,
          alreadyCounted: true
        });
      },
      proveClosed: () => {
        if (settled) return false;
        settled = true;
        this.unprovenDescendants.delete(id);
        this.counters.descendant_resources -= 1;
        return true;
      }
    };
  }

  registerCallback(label, callback, { terminalResource = false } = {}) {
    if (typeof callback !== "function") {
      throw new Error(`LIFECYCLE_CALLBACK_REQUIRED:${label}`);
    }
    const id = `${this.identity}:${label}:${crypto.randomBytes(8).toString("hex")}`;
    let active = true;
    this.counters.listener_callbacks += 1;
    const registration = {
      id,
      label,
      terminalResource
    };
    this.callbackRegistrations.set(id, registration);
    const release = () => {
      if (!active) return false;
      active = false;
      this.callbackRegistrations.delete(id);
      this.counters.listener_callbacks -= 1;
      return true;
    };
    const listener = (...args) => {
      if (!active) {
        this.lateCallbacks += 1;
        return undefined;
      }
      if (!this.controllerActive || this.drainCompleted) {
        this.lateCallbacks += 1;
      }
      try {
        const result = callback(...args);
        if (result && typeof result.then === "function") {
          return this.trackDescendant(`callback:${label}`, result, {
            terminalResource
          });
        }
        return result;
      } catch (error) {
        this.callbackErrors.push({
          id,
          label,
          terminal_resource: terminalResource,
          error
        });
        return undefined;
      }
    };
    return { id, listener, release };
  }

  recordCallbackError(label, error, { terminalResource = false } = {}) {
    this.callbackErrors.push({
      id: `${this.identity}:${label}:${crypto.randomBytes(8).toString("hex")}`,
      label,
      terminal_resource: terminalResource,
      error
    });
  }

  createTrackedTimer(milliseconds, label, {
    terminalResource = false
  } = {}) {
    let settle;
    let handle;
    let settled = false;
    const completion = new Promise((resolve) => {
      settle = resolve;
    });
    const callback = this.registerCallback(
      `${label}:callback`,
      () => {
        if (settled) return;
        settled = true;
        callback.release();
        settle({ timed_out: true, cancelled: false });
      },
      { terminalResource }
    );
    handle = setTimeout(callback.listener, milliseconds);
    const promise = this._trackPromise("timer", label, completion, {
      terminalResource
    });
    return {
      promise,
      cancel: () => {
        if (settled) return false;
        settled = true;
        clearTimeout(handle);
        callback.release();
        settle({ timed_out: false, cancelled: true });
        return true;
      }
    };
  }

  async runOperation(kind, label, operation, {
    requireContextAfter = true,
    allowAfterAdmissionClose = false
  } = {}) {
    if (!allowAfterAdmissionClose) await this.assertContext(`${label}:before`);
    if (!allowAfterAdmissionClose && !this.admissionOpen) {
      throw abortError(`${label}:admission`, this.abortReason);
    }
    const tracked = this._trackPromise(
      kind,
      label,
      Promise.resolve().then(() => operation(this.signal))
    );
    const result = await tracked;
    if (requireContextAfter && !allowAfterAdmissionClose) {
      await this.assertContext(`${label}:after`);
    }
    return result;
  }

  async delay(milliseconds, label = "delay") {
    return await this.runOperation(
      "timer",
      label,
      (signal) =>
        new Promise((resolve, reject) => {
          if (signal.aborted) {
            reject(abortError(label, signal.reason));
            return;
          }
          const timer = this.createTrackedTimer(milliseconds, `${label}:timer`);
          const abortRegistration = this.registerCallback(
            `${label}:abort`,
            () => {
              timer.cancel();
              abortRegistration.release();
              reject(abortError(label, signal.reason));
            }
          );
          const finish = async () => {
            const outcome = await timer.promise;
            abortRegistration.release();
            signal.removeEventListener("abort", abortRegistration.listener);
            if (outcome.timed_out) resolve();
          };
          signal.addEventListener("abort", abortRegistration.listener, {
            once: true
          });
          finish().catch((error) => {
            timer.cancel();
            abortRegistration.release();
            reject(abortError(label, signal.reason));
          });
        })
    );
  }

  async drain({ allowTerminalResources = false } = {}) {
    for (let pass = 0; pass < 64; pass += 1) {
      const current = [...this.inFlight.values()]
        .filter((entry) => !allowTerminalResources || !entry.terminalResource)
        .map((entry) => entry.promise);
      if (current.length) await Promise.allSettled(current);
      await Promise.resolve();
      await new Promise((resolve) => setImmediate(resolve));
      const remaining = [...this.inFlight.values()].filter(
        (entry) => !allowTerminalResources || !entry.terminalResource
      );
      const unproven = [...this.unprovenDescendants.values()].filter(
        (entry) => !allowTerminalResources || !entry.terminalResource
      );
      const callbacks = [...this.callbackRegistrations.values()].filter(
        (entry) => !allowTerminalResources || !entry.terminalResource
      );
      if (unproven.length) {
        throw new Error(
          `PRECISELY_BLOCKED_LIFECYCLE_DESCENDANT_UNPROVEN:${unproven
            .map((entry) => entry.label)
            .sort()
            .join(",")}`
        );
      }
      if (!remaining.length && callbacks.length) {
        throw new Error(
          `PRECISELY_BLOCKED_LIFECYCLE_CALLBACKS_ATTACHED:${callbacks
            .map((entry) => entry.label)
            .sort()
            .join(",")}`
        );
      }
      if (!remaining.length && !callbacks.length) break;
      if (pass === 63) {
        throw new Error("PRECISELY_BLOCKED_LIFECYCLE_DRAIN_NOT_QUIESCENT");
      }
    }
    const callbackFailures = this.callbackErrors.filter(
      (entry) => !allowTerminalResources || !entry.terminal_resource
    );
    if (callbackFailures.length) {
      const error = new Error(
        `PRECISELY_BLOCKED_LIFECYCLE_CALLBACK_ERROR:${callbackFailures[0].label}`
      );
      error.code = "LIFECYCLE_CALLBACK_ERROR";
      error.cause = callbackFailures[0].error;
      throw error;
    }
    const resourceFailures = this.resourceErrors.filter(
      (entry) => !allowTerminalResources || !entry.terminal_resource
    );
    if (resourceFailures.length) {
      const error = new Error(
        `PRECISELY_BLOCKED_LIFECYCLE_DESCENDANT_ERROR:${resourceFailures[0].label}`
      );
      error.code = "LIFECYCLE_DESCENDANT_ERROR";
      error.cause = resourceFailures[0].error;
      throw error;
    }
    const terminalResourcesRemain =
      [...this.inFlight.values()].some((entry) => entry.terminalResource) ||
      [...this.callbackRegistrations.values()].some(
        (entry) => entry.terminalResource
      ) ||
      [...this.unprovenDescendants.values()].some(
        (entry) => entry.terminalResource
      );
    if (!allowTerminalResources || !terminalResourcesRemain) {
      this.drainCompleted = true;
    }
  }

  setFinalizerReceipt(receipt) {
    if (
      receipt?.ok !== true ||
      receipt?.mode !== "0444" ||
      receipt?.readback_verified !== true ||
      typeof receipt?.record_sha256 !== "string"
    ) {
      throw new Error("FINALIZER_DURABLE_RECEIPT_INVALID");
    }
    this.finalizerReceipt = structuredClone(receipt);
  }

  measuredQuiescence() {
    const counters = structuredClone(this.counters);
    const zero = Object.values(counters).every((value) => value === 0);
    const callbackErrors = this.callbackErrors.map((entry) => ({
      label: entry.label,
      error: serializedReason(entry.error)
    }));
    const resourceErrors = this.resourceErrors.map((entry) => ({
      kind: entry.kind,
      label: entry.label,
      error: serializedReason(entry.error)
    }));
    return {
      schema_version: 1,
      measured_at: new Date(this.now()).toISOString(),
      counters,
      in_flight_ids: [...this.inFlight.keys()].sort(),
      callback_registration_ids: [...this.callbackRegistrations.keys()].sort(),
      unproven_descendant_ids: [...this.unprovenDescendants.keys()].sort(),
      late_callbacks: this.lateCallbacks,
      callback_errors: callbackErrors,
      resource_errors: resourceErrors,
      admission_open: this.admissionOpen,
      controller_active: this.controllerActive,
      abort_observed: this.aborted,
      abort_reason: serializedReason(this.abortReason),
      reservation_receipt_present: Boolean(this.reservationReceipt),
      finalizer_receipt_present: Boolean(this.finalizerReceipt),
      drain_completed: this.drainCompleted,
      zero_outstanding:
        zero &&
        this.inFlight.size === 0 &&
        this.callbackRegistrations.size === 0 &&
        this.unprovenDescendants.size === 0,
      no_background_promise_after_return:
        zero &&
        this.inFlight.size === 0 &&
        this.callbackRegistrations.size === 0 &&
        this.unprovenDescendants.size === 0 &&
        this.lateCallbacks === 0 &&
        callbackErrors.length === 0 &&
        resourceErrors.length === 0 &&
        this.drainCompleted &&
        Boolean(this.reservationReceipt)
    };
  }
}

export function createExecutionLifecycle(options) {
  return new ExecutionLifecycle(options);
}
