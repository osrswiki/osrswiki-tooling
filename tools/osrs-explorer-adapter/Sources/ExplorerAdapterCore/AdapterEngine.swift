import Foundation

public enum AdapterRequestRole: Sendable {
    case control
    case hostUI
    case worker
}

public actor AdapterEngine {
    public nonisolated let foregroundInterferenceRegistry = ForegroundInterferenceRegistry()
    private nonisolated let activeInputGateRegistry = ActiveInputGateRegistry()

    private let capabilities: AdapterCapabilities
    private let queueStore: QueueStore
    private let discovery: TargetDiscovery
    private let captureService: CaptureService
    private let inputService: BackgroundInputService
    private let evidenceStore: EvidenceStore
    private let actionHooks: InputActionHooks

    private var state: AdapterState = .starting
    private var enabled = false
    private var enableGeneration: UInt64 = 0
    private var lastError: String?
    private var target: TargetWindowDescriptor?
    private var latestCapture: CaptureEvidence?
    private var activeGate: InputCancellationGate?
    private var foregroundLeaseActive = false
    private var hostStatus = AdapterHostStatus()
    private var diagnostics: AdapterDiagnostics?

    public init(
        capabilities: AdapterCapabilities,
        evidenceRoot: URL,
        queueStore: QueueStore? = nil,
        discovery: TargetDiscovery = TargetDiscovery(),
        actionHooks: InputActionHooks = InputActionHooks()
    ) {
        self.capabilities = capabilities
        self.queueStore = queueStore ?? QueueStore(
            acceptanceRoot: evidenceRoot.appendingPathComponent("sandbox-broker-v4"),
            hostEvidenceRoot: evidenceRoot
        )
        self.discovery = discovery
        self.actionHooks = actionHooks
        captureService = CaptureService(discovery: discovery, evidenceRoot: evidenceRoot)
        evidenceStore = EvidenceStore(root: evidenceRoot)
        inputService = BackgroundInputService(
            monitor: FocusInvariantMonitor(),
            evidenceStore: EvidenceStore(root: evidenceRoot),
            foregroundInterferenceRegistry: foregroundInterferenceRegistry,
            hooks: actionHooks
        )
    }

    public func prepare() async {
        do {
            try await queueStore.prepare()
        } catch {
            state = .faulted
            enabled = false
            lastError = "QUEUE_CANCELLATION_RECOVERY_FAILED:\(error)"
            invalidateQueueLifecycle(reason: "QUEUE_CANCELLATION_RECOVERY_FAILED")
            return
        }
        let permissions = AdapterPermissions.snapshot()
        state = permissions.allRequiredGranted ? .readyIdle : .permissionsRequired
        enabled = false
        invalidateAction(reason: "ADAPTER_PREPARED_DISABLED")
    }

    public func handle(
        _ request: AdapterRequest,
        role transportRole: AdapterRequestRole
    ) async -> AdapterResponse {
        do {
            let role = try authorize(request, transportRole: transportRole)
            switch (role, request.method) {
            case (_, "status"):
                return try await response(for: request.id)
            case (.control, "diagnostics"):
                return AdapterResponse(
                    id: request.id,
                    ok: true,
                    state: state,
                    status: await status(),
                    diagnostics: diagnostics
                )
            case (.hostUI, "queue.activate"):
                guard let path = request.queueManifestPath,
                      let digest = request.queueManifestSHA256 else {
                    throw AdapterError.malformedRequest("QUEUE_PATH_AND_SHA256_REQUIRED")
                }
                _ = try await queueStore.activateForHostUI(
                    fileAt: URL(fileURLWithPath: path),
                    expectedSHA256: digest
                )
                latestCapture = nil
                if enabled { state = .running }
                return try await response(for: request.id, message: "QUEUE_ACTIVATED")
            case (.hostUI, "queue.cancel"):
                invalidateQueueLifecycle()
                enabled = false
                state = .pausedByUser
                try await queueStore.cancel(generationIdentifier: request.queueGeneration)
                try await requireQueueCleared()
                return try await response(for: request.id, message: "QUEUE_CANCELED")
            case (.hostUI, "pause"):
                await pauseByUser()
                return try await response(for: request.id, message: "PAUSED")
            case (.hostUI, "job.cancel"):
                invalidateQueueLifecycle()
                enabled = false
                state = .pausedByUser
                try await queueStore.cancelJob(itemIdentifier: request.jobIdentifier)
                try await requireQueueCleared()
                return try await response(for: request.id, message: "JOB_CANCELED")
            case (.worker, "worker.claim"):
                guard enabled, state == .running else {
                    return try await response(for: request.id, message: "IDLE")
                }
                let claim = try await queueStore.claim()
                if claim == nil { state = .readyIdle }
                return try await response(for: request.id, queueClaim: claim)
            case (.worker, "capture"):
                let claim = try await requireClaim(request)
                let capture = try await captureService.capture(
                    selector: claim.selector,
                    evidenceDirectory: URL(fileURLWithPath: claim.artifactRoot)
                )
                target = capture.target
                latestCapture = capture
                return try await response(for: request.id, capture: capture)
            case (.worker, "click"), (.worker, "drag"), (.worker, "open_world_map"):
                let gate = try beginAction()
                defer {
                    foregroundInterferenceRegistry.end(gate)
                    activeInputGateRegistry.end(gate)
                    if activeGate === gate { activeGate = nil }
                    foregroundLeaseActive = false
                }
                let claim = try await requireClaim(request)
                try await actionHooks.revalidate(.claim, gate: gate)
                try validateAction(gate)
                try gate.bindExecutionDeadline(claim.executionDeadlineAt)
                guard let action = request.action else {
                    throw AdapterError.malformedRequest("ACTION_REQUIRED")
                }
                let requiredKind: QueueOperationKind
                switch request.method {
                case "click": requiredKind = .click
                case "drag": requiredKind = .drag
                case "open_world_map": requiredKind = .openWorldMap
                default: throw AdapterError.actionNotAllowed("METHOD_FORBIDDEN:\(request.method)")
                }
                let permitted = await queueStore.permits(requiredKind)
                try validateAction(gate)
                guard permitted else {
                    throw AdapterError.actionNotAllowed("OPERATION_NOT_AUTHORIZED")
                }
                guard let capture = latestCapture else { throw AdapterError.staleCapture }
                let inputConfiguration = try await queueStore.authorize(
                    generationIdentifier: claim.generationIdentifier,
                    itemIdentifier: claim.item.id,
                    action: action,
                    semanticRole: request.semanticRole,
                    capture: capture,
                    requestedEventSourceMode: request.eventSourceMode,
                    requestedDeliveryMode: request.deliveryMode
                )
                try await actionHooks.revalidate(.authorization, gate: gate)
                try validateAction(gate)
                try CaptureFreshnessPolicy.validate(capturedAt: capture.capturedAt)
                let current = try await discovery.resolve(claim.selector).descriptor
                try await actionHooks.revalidate(.discovery, gate: gate)
                try validateAction(gate)
                guard current.processIdentifier == capture.target.processIdentifier,
                      current.windowIdentifier == capture.target.windowIdentifier,
                      current.frame == capture.target.frame else {
                    latestCapture = nil
                    throw AdapterError.staleCapture
                }
                foregroundLeaseActive = inputConfiguration.deliveryMode.requiresForegroundLease
                if foregroundLeaseActive {
                    foregroundInterferenceRegistry.begin(gate)
                }
                let result = try await inputService.perform(
                    action,
                    capture: capture,
                    cancellationGate: gate,
                    preferredEventSourceMode: inputConfiguration.eventSourceMode,
                    deliveryMode: inputConfiguration.deliveryMode
                )
                try validateAction(gate)
                try await queueStore.recordActionCompleted(
                    generationIdentifier: claim.generationIdentifier,
                    itemIdentifier: claim.item.id
                )
                try validateAction(gate)
                latestCapture = nil
                return try await response(
                    for: request.id,
                    inputEvidence: result.evidenceReference
                )
            case (.worker, "worker.complete"):
                guard let generation = request.queueGeneration,
                      let item = request.jobIdentifier,
                      let success = request.success else {
                    throw AdapterError.malformedRequest("COMPLETION_FIELDS_REQUIRED")
                }
                try await queueStore.complete(
                    generationIdentifier: generation,
                    itemIdentifier: item,
                    success: success,
                    resultPath: request.resultPath,
                    resultFileSHA256: request.resultFileSHA256,
                    resultDigest: request.resultDigest
                )
                latestCapture = nil
                if await queueStore.isDrained { state = .readyIdle }
                return try await response(for: request.id, message: "ITEM_COMPLETED")
            default:
                throw AdapterError.actionNotAllowed("METHOD_FORBIDDEN:\(request.method)")
            }
        } catch {
            let adapterError = error as? AdapterError
            transition(after: adapterError)
            return AdapterResponse(
                id: request.id,
                ok: false,
                state: state,
                error: String(describing: error),
                status: await status()
            )
        }
    }

    public func enableFromMenu() async {
        guard AdapterPermissions.snapshot().allRequiredGranted else {
            state = .permissionsRequired
            enabled = false
            invalidateAction(reason: "INPUT_PERMISSION_REQUIRED")
            return
        }
        enableGeneration &+= 1
        let generation = enableGeneration
        enabled = true
        let queue = await queueStore.snapshot()
        guard enabled, enableGeneration == generation else { return }
        state = queue.generationIdentifier == nil || queue.isDrained ? .readyIdle : .running
        lastError = nil
    }

    public func operatorEnableFailed(reason: String) async {
        invalidateAction(reason: reason)
        enabled = false
        state = .faulted
        lastError = "CONTROL_WINDOW_HANDOFF_FAILED:\(reason)"
        try? recordEvent(
            [
                "event": "control_window_enable_failed",
                "reason": reason,
                "recorded_at": AdapterClock.now()
            ],
            name: "control-window-enable-failed-\(UUID().uuidString.lowercased())"
        )
    }

    public func resumeFromMenu() async {
        guard state == .pausedByUser || state == .pausedTargetTouched else { return }
        await enableFromMenu()
    }

    public func pauseByUser() async {
        invalidateAction()
        enabled = false
        state = .pausedByUser
    }

    public func pauseForTargetTouch(reason: String) async {
        guard state == .running || state == .readyIdle else { return }
        invalidateAction()
        enabled = false
        state = .pausedTargetTouched
        lastError = reason
    }

    public func pauseForUserInterference(reason: String) async {
        invalidateAction(reason: reason)
        enabled = false
        state = .pausedTargetTouched
        lastError = reason
    }

    public func workerDidTerminate(status: Int32?) async {
        invalidateAction(reason: "WORKER_TERMINATED")
        enabled = false
        let baseReason = "WORKER_TERMINATED:\(status.map(String.init) ?? "UNKNOWN")"
        let reason = await revokeInFlightGenerationForHostFailure(reason: baseReason)
        if state != .faulted {
            state = .faulted
            lastError = reason
        } else if lastError == nil {
            lastError = reason
        }
        try? recordEvent(
            [
                "event": "worker_terminated",
                "reason": reason,
                "recorded_at": AdapterClock.now()
            ],
            name: "worker-terminated-\(UUID().uuidString.lowercased())"
        )
    }

    public func runtimeDidFail(reason: String) async {
        invalidateAction(reason: reason)
        enabled = false
        let reason = await revokeInFlightGenerationForHostFailure(reason: reason)
        if state != .faulted {
            state = .faulted
            lastError = reason
        } else if lastError == nil {
            lastError = reason
        }
        try? recordEvent(
            [
                "event": "runtime_failed",
                "reason": reason,
                "recorded_at": AdapterClock.now()
            ],
            name: "runtime-failed-\(UUID().uuidString.lowercased())"
        )
    }

    public func refreshPermissionState() async {
        let permissions = AdapterPermissions.snapshot()
        guard !permissions.allRequiredGranted,
              state != .permissionsRequired,
              state != .faulted,
              state != .backgroundUnsupported else { return }
        invalidateAction(reason: "PERMISSION_LOST")
        enabled = false
        state = .permissionsRequired
        let missing = [
            permissions.accessibility ? nil : "ACCESSIBILITY",
            permissions.inputMonitoring ? nil : "INPUT_MONITORING",
            permissions.screenRecording ? nil : "SCREEN_RECORDING"
        ].compactMap { $0 }
        lastError = "PERMISSION_LOST:\(missing.joined(separator: ","))"
        try? recordEvent(
            [
                "event": "permission_lost",
                "missing": missing.joined(separator: ","),
                "recorded_at": AdapterClock.now()
            ],
            name: "permission-lost-\(UUID().uuidString.lowercased())"
        )
    }

    public func isForegroundLeaseActive() -> Bool {
        foregroundLeaseActive
    }

    public func updateHostStatus(
        _ hostStatus: AdapterHostStatus,
        diagnostics: AdapterDiagnostics
    ) {
        self.hostStatus = hostStatus
        self.diagnostics = diagnostics
    }

    public func emergencyStop() async {
        invalidateQueueLifecycle()
        enabled = false
        state = .pausedByUser
        lastError = "EMERGENCY_STOP"
        do {
            try await queueStore.cancel(generationIdentifier: nil)
            try await requireQueueCleared()
        } catch {
            state = .faulted
            lastError = "EMERGENCY_STOP_QUEUE_CANCELLATION_FAILED:\(error)"
        }
    }

    public nonisolated func invalidateActionsSynchronouslyForTermination() {
        activeInputGateRegistry.invalidateAllAndClose(reason: "APPLICATION_TERMINATING")
    }

    public func status() async -> AdapterStatus {
        let queue = await queueStore.snapshot()
        return AdapterStatus(
            state: state,
            enabled: enabled,
            target: target,
            activeQueueGeneration: queue.generationIdentifier,
            activeItemIdentifier: queue.activeItemIdentifier,
            lastError: lastError,
            permissions: AdapterPermissions.snapshot(),
            host: hostStatus
        )
    }

    private func authorize(
        _ request: AdapterRequest,
        transportRole: AdapterRequestRole
    ) throws -> AdapterRequestRole {
        switch transportRole {
        case .control, .hostUI:
            guard request.capability == nil else { throw AdapterError.unauthorized }
            return transportRole
        case .worker:
            guard request.capability == capabilities.worker else {
                throw AdapterError.unauthorized
            }
            return .worker
        }
    }

    private func requireRunning() throws {
        guard enabled, state == .running else {
            throw AdapterError.actionNotAllowed("ADAPTER_NOT_RUNNING")
        }
    }

    private func beginAction() throws -> InputCancellationGate {
        try requireRunning()
        guard activeGate == nil else {
            throw AdapterError.actionNotAllowed("ACTION_ALREADY_IN_FLIGHT")
        }
        let gate = InputCancellationGate(enableGeneration: enableGeneration)
        guard activeInputGateRegistry.register(gate) else {
            throw AdapterError.actionNotAllowed("APPLICATION_TERMINATING")
        }
        activeGate = gate
        return gate
    }

    private func validateAction(_ gate: InputCancellationGate) throws {
        guard enabled,
              state == .running,
              activeGate === gate,
              gate.enableGeneration == enableGeneration else {
            gate.invalidate(reason: "ADAPTER_GENERATION_INVALIDATED")
            throw AdapterError.actionNotAllowed("ADAPTER_GENERATION_INVALIDATED")
        }
        try gate.checkValid()
    }

    private func requireClaim(_ request: AdapterRequest) async throws -> QueueClaim {
        try requireRunning()
        guard let jobIdentifier = request.jobIdentifier,
              let generation = request.queueGeneration,
              let claim = try await queueStore.claim(),
              claim.item.id == jobIdentifier,
              claim.generationIdentifier == generation else {
            throw AdapterError.queueRejected("CLAIM_BINDING_MISMATCH")
        }
        return claim
    }

    private func response(
        for id: String,
        capture: CaptureEvidence? = nil,
        queueClaim: QueueClaim? = nil,
        inputEvidence: EvidenceReference? = nil,
        message: String? = nil
    ) async throws -> AdapterResponse {
        AdapterResponse(
            id: id,
            ok: true,
            state: state,
            status: await status(),
            capture: capture,
            queueClaim: queueClaim,
            inputEvidence: inputEvidence,
            message: message
        )
    }

    private func transition(after error: AdapterError?) {
        guard let error else {
            state = .faulted
            enabled = false
            lastError = "UNEXPECTED_ERROR"
            invalidateAction()
            return
        }
        let wasPausedForInterference = state == .pausedTargetTouched
        if !wasPausedForInterference { lastError = error.description }
        switch error {
        case .permissionRequired:
            state = .permissionsRequired
            enabled = false
        case .backgroundUnsupported, .invariantViolation:
            state = .backgroundUnsupported
            enabled = false
        case .foregroundLeaseFailed:
            if !wasPausedForInterference { state = .faulted }
            enabled = false
        case .staleCapture, .targetNotFound, .targetAmbiguous, .targetNotOnScreen:
            state = .faulted
            enabled = false
        case .queueRejected where error.description.contains("ITEM_FAILED_REQUIRES_PAUSE")
            || error.description.contains("ITEM_EXECUTION_DEADLINE_EXCEEDED")
            || error.description.contains("QUEUE_CANCELLATION"):
            if state != .backgroundUnsupported {
                state = .faulted
            }
            enabled = false
        default:
            break
        }
        if !enabled { invalidateAction() }
    }

    private func invalidateAction(reason: String = "ACTION_CANCELED") {
        enableGeneration &+= 1
        activeGate?.invalidate(reason: reason)
        activeGate = nil
        latestCapture = nil
    }

    private func invalidateQueueLifecycle(reason: String = "QUEUE_CANCELED") {
        invalidateAction(reason: reason)
        target = nil
        foregroundLeaseActive = false
    }

    private func requireQueueCleared() async throws {
        let queue = await queueStore.snapshot()
        guard queue.generationIdentifier == nil,
              queue.activeItemIdentifier == nil else {
            throw AdapterError.queueRejected("QUEUE_CANCELLATION_RUNTIME_CLEAR_FAILED")
        }
    }

    private func revokeInFlightGenerationForHostFailure(reason: String) async -> String {
        do {
            try await queueStore.revokeInFlightGeneration(reason: reason)
            return reason
        } catch {
            return "\(reason):REVOCATION_PERSISTENCE_FAILED:\(error)"
        }
    }

    private func refreshTarget(selector: TargetSelector) async {
        target = try? await discovery.resolve(selector).descriptor
    }

    private func recordEvent(_ value: [String: String], name: String) throws {
        _ = try evidenceStore.writeImmutable(value, relativePath: "events/\(name).json")
    }
}
