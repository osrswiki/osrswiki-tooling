import Darwin
import Foundation

public struct QueueRuntimeSnapshot: Sendable {
    public let generationIdentifier: String?
    public let activeItemIdentifier: String?
    public let isDrained: Bool
    public let isCanceled: Bool
}

enum QueueCancellationPhase: String, Sendable {
    case afterIntentPublication
    case afterRevocationPublication
    case beforeEventPublication
    case afterEventPublication
    case beforeRuntimeClear
}

struct QueueCancellationHooks: Sendable {
    var reach: @Sendable (QueueCancellationPhase) throws -> Void

    init(reach: @escaping @Sendable (QueueCancellationPhase) throws -> Void = { _ in }) {
        self.reach = reach
    }
}

public struct AuthorizedInputConfiguration: Equatable, Sendable {
    public let eventSourceMode: EventSourceMode
    public let deliveryMode: InputDeliveryMode
}

private struct SemanticActionProgress: Sendable {
    var recoveryTryAgainDelivered = false
    var recoverySteamSignInDelivered = false
    var recoveryClickToPlayDelivered = false
    var recoveryOpenWorldMapDelivered = false
    var selectorOpened = false
    var surfaceScrollbarDrags = 0
    var surfaceSelected = false
    var surfaceResetSelectorOpened = false
    var surfaceResetScrollbarDrags = 0
    var surfaceReset = false
    var coverageResetSelectorOpened = false
    var coverageResetScrollbarDrags = 0
    var coverageResetSelected = false
    var coverageMapClosed = false
    var coverageMapReopened = false
    var zoomMinusClicks = 0
    var zoomPlusClicks = 0
    var coverageAnchorDrags = 0
    var coveragePanDrags = 0
    var panDelivered = false
    var restorationDelivered = false
}

public actor QueueStore {
    public static let itemExecutionDeadlineSeconds: TimeInterval = 120
    // Keep the host gate aligned with the worker's two 5-pixel novelty cells.
    private static let semanticMinimumPanReferenceDisplacement = 10.0

    private let broker: SandboxResultBroker
    private let hostEvidenceRoot: URL
    private let revocationStore: EvidenceStore
    private let itemExecutionDeadlineSeconds: TimeInterval
    private let now: @Sendable () -> Date
    private let cancellationHooks: QueueCancellationHooks
    private let durableHostEvidenceConfigured: Bool
    private var active: ValidatedQueueManifest?
    private var activeUse: GenerationUse?
    private var activationEvidenceRecorded = false
    private var nextIndex = 0
    private var inFlight: QueueItem?
    private var nextActionIndex = 0
    private var semanticProgress = SemanticActionProgress()
    private var pendingSemanticRole: SemanticActionRole?
    private var completedItemHashes: [String: String] = [:]
    private var canceled = false
    private var inFlightClaimedAt: Date?
    private var inFlightDeadlineAt: Date?

    public init(
        acceptanceRoot: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("osrs-adapter-broker-\(UUID().uuidString)"),
        hostEvidenceRoot: URL? = nil,
        itemExecutionDeadlineSeconds: TimeInterval = QueueStore.itemExecutionDeadlineSeconds,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.hostEvidenceRoot = hostEvidenceRoot ?? FileManager.default.temporaryDirectory
        revocationStore = EvidenceStore(
            root: hostEvidenceRoot ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("osrs-adapter-queue-state-\(UUID().uuidString)")
        )
        self.itemExecutionDeadlineSeconds = itemExecutionDeadlineSeconds
        self.now = now
        cancellationHooks = QueueCancellationHooks()
        durableHostEvidenceConfigured = hostEvidenceRoot != nil
        broker = SandboxResultBroker(
            root: acceptanceRoot,
            hostEvidenceRoot: self.hostEvidenceRoot
        )
    }

    init(
        acceptanceRoot: URL,
        hostEvidenceRoot: URL,
        itemExecutionDeadlineSeconds: TimeInterval = QueueStore.itemExecutionDeadlineSeconds,
        now: @escaping @Sendable () -> Date = { Date() },
        cancellationHooks: QueueCancellationHooks
    ) {
        self.hostEvidenceRoot = hostEvidenceRoot
        revocationStore = EvidenceStore(root: hostEvidenceRoot)
        self.itemExecutionDeadlineSeconds = itemExecutionDeadlineSeconds
        self.now = now
        self.cancellationHooks = cancellationHooks
        durableHostEvidenceConfigured = true
        broker = SandboxResultBroker(root: acceptanceRoot, hostEvidenceRoot: hostEvidenceRoot)
    }

    public func prepare() throws {
        if durableHostEvidenceConfigured {
            try recoverCancellationTransactions()
        }
    }

    public func activate(fileAt url: URL, expectedSHA256: String) async throws -> QueueManifest {
        try await activate(
            fileAt: url,
            expectedSHA256: expectedSHA256,
            recordLifecycleEvidence: false
        )
    }

    func activateForHostUI(fileAt url: URL, expectedSHA256: String) async throws -> QueueManifest {
        try await activate(
            fileAt: url,
            expectedSHA256: expectedSHA256,
            recordLifecycleEvidence: true
        )
    }

    private func activate(
        fileAt url: URL,
        expectedSHA256: String,
        recordLifecycleEvidence: Bool
    ) async throws -> QueueManifest {
        if durableHostEvidenceConfigured {
            try recoverCancellationTransactions()
            try LegacyGenerationStateMigrator(
                evidenceRoot: hostEvidenceRoot,
                stateStore: revocationStore
            ).migrate()
        }
        if let active, !isTerminal {
            throw AdapterError.queueRejected("ACTIVE_GENERATION_EXISTS:\(active.manifest.generationIdentifier)")
        }
        var validated = try QueueManifestValidator.validate(
            fileAt: url,
            expectedSHA256: expectedSHA256,
            hostEvidenceRoot: hostEvidenceRoot
        )
        if recordLifecycleEvidence {
            validated = try adoptHostUIManifest(validated)
        }
        guard !isGenerationRevoked(validated.manifest.generationIdentifier) else {
            throw AdapterError.queueRejected(
                "GENERATION_REVOKED_REQUIRES_FRESH_IDENTIFIER:\(validated.manifest.generationIdentifier)"
            )
        }
        guard !isGenerationUsed(validated.manifest.generationIdentifier) else {
            throw AdapterError.queueRejected(
                "GENERATION_USED_REQUIRES_FRESH_IDENTIFIER:\(validated.manifest.generationIdentifier)"
            )
        }
        completedItemHashes = try await broker.acceptedItemHashes()
        for item in validated.manifest.items {
            if let priorHash = completedItemHashes[item.id], priorHash != item.itemSHA256 {
                throw AdapterError.queueRejected("ITEM_ID_HASH_CONFLICT:\(item.id)")
            }
            if let superseded = item.supersedesItemIdentifier {
                guard completedItemHashes[superseded] != nil else {
                    throw AdapterError.queueRejected("SUPERSEDED_ITEM_NOT_ACCEPTED:\(superseded)")
                }
                for lineageIdentifier in item.repairLineage ?? [] {
                    guard completedItemHashes[lineageIdentifier] != nil else {
                        throw AdapterError.queueRejected(
                            "REPAIR_LINEAGE_ITEM_NOT_ACCEPTED:\(lineageIdentifier)"
                        )
                    }
                }
            }
        }
        let generationUse = try recordGenerationUse(validated)
        if recordLifecycleEvidence {
            try ensureActivationEvent(for: validated, use: generationUse)
        }
        active = validated
        activeUse = generationUse
        activationEvidenceRecorded = recordLifecycleEvidence
        nextIndex = 0
        inFlight = nil
        nextActionIndex = 0
        semanticProgress = SemanticActionProgress()
        pendingSemanticRole = nil
        canceled = false
        inFlightClaimedAt = nil
        inFlightDeadlineAt = nil
        return validated.manifest
    }

    private func adoptHostUIManifest(
        _ validated: ValidatedQueueManifest
    ) throws -> ValidatedQueueManifest {
        let sourceURL = URL(fileURLWithPath: validated.sourcePath)
        let data = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
        guard AdapterHashing.sha256(data) == validated.fileSHA256 else {
            throw AdapterError.queueRejected("MANIFEST_CHANGED_DURING_ADOPTION")
        }
        let destination = hostEvidenceRoot
            .appendingPathComponent(
                validated.manifest.generationIdentifier,
                isDirectory: true
            )
            .appendingPathComponent("operator", isDirectory: true)
            .appendingPathComponent(
                "\(validated.manifest.generationIdentifier).json"
            )
        let stateIO = try LegacyMigrationFileSystem(
            root: hostEvidenceRoot,
            createRoot: true
        )
        if let existing = try stateIO.readImmutableRecordIfPresent(
            at: destination,
            maximumBytes: LegacyMigrationFileSystem.maximumManifestBytes,
            code: "OPERATOR_MANIFEST"
        ) {
            guard existing == data else {
                throw AdapterError.queueRejected("OPERATOR_MANIFEST_CONFLICT")
            }
        } else {
            let published = try stateIO.publishImmutableRecord(
                data,
                at: destination,
                maximumBytes: LegacyMigrationFileSystem.maximumManifestBytes,
                code: "OPERATOR_MANIFEST"
            )
            guard published else {
                throw AdapterError.queueRejected("OPERATOR_MANIFEST_PUBLICATION_FAILED")
            }
        }
        return try QueueManifestValidator.validate(
            data: data,
            sourceURL: destination,
            expectedSHA256: validated.fileSHA256,
            hostEvidenceRoot: hostEvidenceRoot
        )
    }

    public func claim() throws -> QueueClaim? {
        guard let manifest = active?.manifest, !canceled else {
            throw AdapterError.queueUnavailable
        }
        if let inFlight {
            try requireWithinItemDeadline(
                generationIdentifier: manifest.generationIdentifier,
                itemIdentifier: inFlight.id
            )
            return QueueClaim(
                generationIdentifier: manifest.generationIdentifier,
                selector: manifest.selector,
                artifactRoot: manifest.artifactRoot,
                item: inFlight,
                claimedAt: try claimTimestamp(inFlightClaimedAt),
                executionDeadlineAt: try claimTimestamp(inFlightDeadlineAt)
            )
        }
        while nextIndex < manifest.items.count,
              completedItemHashes[manifest.items[nextIndex].id]
                == manifest.items[nextIndex].itemSHA256 {
            nextIndex += 1
        }
        guard nextIndex < manifest.items.count else { return nil }
        let item = manifest.items[nextIndex]
        inFlight = item
        nextActionIndex = 0
        semanticProgress = SemanticActionProgress()
        pendingSemanticRole = nil
        let claimedAt = now()
        let deadlineAt = claimedAt.addingTimeInterval(itemExecutionDeadlineSeconds)
        inFlightClaimedAt = claimedAt
        inFlightDeadlineAt = deadlineAt
        try requireWithinItemDeadline(
            generationIdentifier: manifest.generationIdentifier,
            itemIdentifier: item.id
        )
        return QueueClaim(
            generationIdentifier: manifest.generationIdentifier,
            selector: manifest.selector,
            artifactRoot: manifest.artifactRoot,
            item: item,
            claimedAt: AdapterClock.string(from: claimedAt),
            executionDeadlineAt: AdapterClock.string(from: deadlineAt)
        )
    }

    public func authorize(
        generationIdentifier: String,
        itemIdentifier: String,
        action: PrivilegedAction,
        semanticRole: SemanticActionRole? = nil,
        capture: CaptureEvidence? = nil,
        requestedEventSourceMode: EventSourceMode?,
        requestedDeliveryMode: InputDeliveryMode?
    ) throws -> AuthorizedInputConfiguration {
        guard let manifest = active?.manifest,
              manifest.generationIdentifier == generationIdentifier,
              let inFlight,
              inFlight.id == itemIdentifier else {
            throw AdapterError.queueRejected("ACTION_BINDING_MISMATCH")
        }
        try requireWithinItemDeadline(
            generationIdentifier: generationIdentifier,
            itemIdentifier: itemIdentifier
        )
        if manifest.executionProfile == .semanticMapCaptureV1 {
            guard let semanticRole, let capture else {
                throw AdapterError.queueRejected("SEMANTIC_ROLE_AND_CAPTURE_REQUIRED")
            }
            guard (requestedEventSourceMode ?? .combinedSessionState) == .combinedSessionState else {
                throw AdapterError.queueRejected("SEMANTIC_EVENT_SOURCE_MODE_FORBIDDEN")
            }
            guard (requestedDeliveryMode ?? .foregroundGlobal) == .foregroundGlobal else {
                throw AdapterError.queueRejected("SEMANTIC_DELIVERY_MODE_FORBIDDEN")
            }
            try authorizeSemanticAction(
                action,
                role: semanticRole,
                item: inFlight,
                capture: capture
            )
            pendingSemanticRole = semanticRole
            return AuthorizedInputConfiguration(
                eventSourceMode: .combinedSessionState,
                deliveryMode: .foregroundGlobal
            )
        }
        guard semanticRole == nil else {
            throw AdapterError.queueRejected("SEMANTIC_ROLE_FOR_RAW_QUEUE")
        }
        let actions = inFlight.operations.filter { $0.kind != .capture }
        guard actions.indices.contains(nextActionIndex) else {
            throw AdapterError.queueRejected("UNAUTHORIZED_EXTRA_ACTION")
        }
        let expected = actions[nextActionIndex]
        guard actionMatches(action, operation: expected) else {
            throw AdapterError.queueRejected("ACTION_DOES_NOT_MATCH_QUEUE")
        }
        let expectedMode = expected.eventSourceMode ?? .privateState
        guard (requestedEventSourceMode ?? .privateState) == expectedMode else {
            throw AdapterError.queueRejected("EVENT_SOURCE_MODE_DOES_NOT_MATCH_QUEUE")
        }
        let expectedDeliveryMode = expected.deliveryMode ?? .backgroundPid
        guard (requestedDeliveryMode ?? .backgroundPid) == expectedDeliveryMode else {
            throw AdapterError.queueRejected("DELIVERY_MODE_DOES_NOT_MATCH_QUEUE")
        }
        return AuthorizedInputConfiguration(
            eventSourceMode: expectedMode,
            deliveryMode: expectedDeliveryMode
        )
    }

    public func recordActionCompleted(
        generationIdentifier: String,
        itemIdentifier: String
    ) throws {
        guard let manifest = active?.manifest,
              manifest.generationIdentifier == generationIdentifier,
              let inFlight,
              inFlight.id == itemIdentifier else {
            throw AdapterError.queueRejected("ACTION_COMPLETION_BINDING_MISMATCH")
        }
        try requireWithinItemDeadline(
            generationIdentifier: generationIdentifier,
            itemIdentifier: itemIdentifier
        )
        let actionCount = inFlight.operations.filter { $0.kind != .capture }.count
        if manifest.executionProfile == .semanticMapCaptureV1 {
            guard let pendingSemanticRole else {
                throw AdapterError.queueRejected("SEMANTIC_ACTION_NOT_AUTHORIZED")
            }
            completeSemanticAction(pendingSemanticRole)
            self.pendingSemanticRole = nil
            return
        }
        guard nextActionIndex < actionCount else {
            throw AdapterError.queueRejected("UNAUTHORIZED_EXTRA_ACTION_COMPLETION")
        }
        nextActionIndex += 1
    }

    public func complete(
        generationIdentifier: String,
        itemIdentifier: String,
        success: Bool,
        resultPath: String? = nil,
        resultFileSHA256: String? = nil,
        resultDigest: String? = nil
    ) async throws {
        guard let manifest = active?.manifest,
              manifest.generationIdentifier == generationIdentifier else {
            throw AdapterError.queueRejected("GENERATION_MISMATCH")
        }
        guard let manifestItem = manifest.items.first(where: { $0.id == itemIdentifier }) else {
            throw AdapterError.queueRejected("ITEM_NOT_IN_ACTIVE_GENERATION")
        }
        guard let inFlight else {
            guard success else {
                throw AdapterError.queueRejected("IN_FLIGHT_ITEM_MISMATCH")
            }
            if completedItemHashes[itemIdentifier] != nil {
                guard let resultPath, let resultFileSHA256, let resultDigest else {
                    throw AdapterError.queueRejected("RESULT_BINDING_REQUIRED")
                }
                _ = try await broker.accept(
                    generationIdentifier: generationIdentifier,
                    item: manifestItem,
                    artifactRoot: manifest.artifactRoot,
                    resultPath: resultPath,
                    resultFileSHA256: resultFileSHA256,
                    resultDigest: resultDigest
                )
                return
            }
            throw AdapterError.queueRejected("IN_FLIGHT_ITEM_MISMATCH")
        }
        guard inFlight.id == itemIdentifier else {
            throw AdapterError.queueRejected("IN_FLIGHT_ITEM_MISMATCH")
        }
        try requireWithinItemDeadline(
            generationIdentifier: generationIdentifier,
            itemIdentifier: itemIdentifier
        )
        guard success else {
            try revokeActiveGeneration(reason: "ITEM_FAILED:\(itemIdentifier)")
            throw AdapterError.queueRejected("ITEM_FAILED_REQUIRES_PAUSE")
        }
        if manifest.executionProfile == .semanticMapCaptureV1 {
            guard semanticItemComplete(inFlight) else {
                throw AdapterError.queueRejected("SEMANTIC_ITEM_ACTIONS_NOT_COMPLETED")
            }
        } else {
            let actionCount = inFlight.operations.filter { $0.kind != .capture }.count
            guard nextActionIndex == actionCount else {
                throw AdapterError.queueRejected("ITEM_ACTIONS_NOT_COMPLETED")
            }
        }
        guard let resultPath, let resultFileSHA256, let resultDigest else {
            throw AdapterError.queueRejected("RESULT_BINDING_REQUIRED")
        }
        _ = try await broker.accept(
            generationIdentifier: generationIdentifier,
            item: inFlight,
            artifactRoot: manifest.artifactRoot,
            resultPath: resultPath,
            resultFileSHA256: resultFileSHA256,
            resultDigest: resultDigest
        )
        completedItemHashes[itemIdentifier] = inFlight.itemSHA256
        self.inFlight = nil
        inFlightClaimedAt = nil
        inFlightDeadlineAt = nil
        nextActionIndex = 0
        semanticProgress = SemanticActionProgress()
        pendingSemanticRole = nil
        nextIndex += 1
    }

    public func cancel(generationIdentifier: String?) throws {
        guard let active else { return }
        if let generationIdentifier,
           generationIdentifier != active.manifest.generationIdentifier {
            throw AdapterError.queueRejected("GENERATION_MISMATCH")
        }
        try cancelActiveGeneration(reason: "QUEUE_CANCELED")
    }

    public func cancelJob(itemIdentifier: String?) throws {
        guard let inFlight else { return }
        if let itemIdentifier, itemIdentifier != inFlight.id {
            throw AdapterError.queueRejected("IN_FLIGHT_ITEM_MISMATCH")
        }
        try cancelActiveGeneration(reason: "ITEM_CANCELED:\(inFlight.id)")
    }

    public func revokeInFlightGeneration(reason: String) throws {
        guard let inFlight else { return }
        try revokeActiveGeneration(reason: "\(reason):\(inFlight.id)")
    }

    public func permits(_ kind: QueueOperationKind) -> Bool {
        active?.manifest.allowedOperations.contains(kind) == true
    }

    public func snapshot() -> QueueRuntimeSnapshot {
        QueueRuntimeSnapshot(
            generationIdentifier: active?.manifest.generationIdentifier,
            activeItemIdentifier: inFlight?.id,
            isDrained: isDrained,
            isCanceled: canceled
        )
    }

    public var isDrained: Bool {
        guard let manifest = active?.manifest else { return true }
        return !canceled && inFlight == nil && nextIndex >= manifest.items.count
    }

    private var isTerminal: Bool {
        canceled || isDrained
    }

    private func actionMatches(
        _ action: PrivilegedAction,
        operation: QueueOperation
    ) -> Bool {
        switch (operation.kind, action) {
        case let (.click, .click(_, point, button)):
            return operation.point == point && operation.button == button
        case let (.drag, .drag(_, from, to)):
            return operation.from == from && operation.to == to
        case (.openWorldMap, .openWorldMap):
            return true
        default:
            return false
        }
    }

    private func authorizeSemanticAction(
        _ action: PrivilegedAction,
        role: SemanticActionRole,
        item: QueueItem,
        capture: CaptureEvidence
    ) throws {
        guard pendingSemanticRole == nil,
              capture.pixelWidth > 0,
              capture.pixelHeight > 0,
              semanticActionCaptureIdentifier(action) == capture.captureIdentifier else {
            throw AdapterError.queueRejected("SEMANTIC_CAPTURE_BINDING_MISMATCH")
        }
        let targetPlusClicks = semanticZoomAscentCount(item.zoomPercent)
        let surfaceDragLimit = semanticSurfaceDragLimit(item)
        switch role {
        case .recoveryTryAgain:
            guard !semanticProgress.recoveryTryAgainDelivered,
                  !semanticProgress.recoverySteamSignInDelivered,
                  !semanticProgress.recoveryClickToPlayDelivered,
                  !semanticProgress.recoveryOpenWorldMapDelivered,
                  !semanticProgress.selectorOpened,
                  semanticClick(action, inside: referenceRect(300, 300, 468, 370), capture: capture) else {
                throw AdapterError.queueRejected("SEMANTIC_RECOVERY_TRY_AGAIN_ACTION_INVALID")
            }
        case .recoverySteamSignIn:
            guard !semanticProgress.recoverySteamSignInDelivered,
                  !semanticProgress.recoveryClickToPlayDelivered,
                  !semanticProgress.recoveryOpenWorldMapDelivered,
                  !semanticProgress.selectorOpened,
                  semanticClick(action, inside: referenceRect(300, 240, 468, 310), capture: capture) else {
                throw AdapterError.queueRejected("SEMANTIC_RECOVERY_STEAM_SIGN_IN_ACTION_INVALID")
            }
        case .recoveryClickToPlay:
            guard !semanticProgress.recoveryClickToPlayDelivered,
                  !semanticProgress.recoveryOpenWorldMapDelivered,
                  !semanticProgress.selectorOpened,
                  semanticClick(action, inside: referenceRect(320, 330, 470, 390), capture: capture) else {
                throw AdapterError.queueRejected("SEMANTIC_RECOVERY_CLICK_TO_PLAY_ACTION_INVALID")
            }
        case .recoveryOpenWorldMap:
            guard !semanticProgress.recoveryOpenWorldMapDelivered,
                  !semanticProgress.selectorOpened,
                  case .openWorldMap = action else {
                throw AdapterError.queueRejected("SEMANTIC_RECOVERY_OPEN_WORLD_MAP_ACTION_INVALID")
            }
        case .surfaceSelectorOpen:
            let initialOpen = !semanticProgress.selectorOpened
                && (!semanticResetRelativeCoverageItem(item)
                    || semanticProgress.coverageResetSelected)
                && (!semanticReopenResetCoverageItem(item)
                    || semanticProgress.coverageMapReopened)
            let resetOpen = semanticSurfaceResetRequired(item)
                && semanticProgress.restorationDelivered
                && !semanticProgress.surfaceResetSelectorOpened
            guard (initialOpen || resetOpen),
                  semanticClick(action, inside: referenceRect(315, 630, 385, 700), capture: capture) else {
                throw AdapterError.queueRejected("SEMANTIC_SURFACE_SELECTOR_ACTION_INVALID")
            }
        case .surfaceSelectorScrollbarDrag:
            let resetting = semanticProgress.surfaceResetSelectorOpened
            let initialDrag = semanticProgress.selectorOpened
                && !semanticProgress.surfaceSelected
                && surfaceDragLimit == 1
                && semanticProgress.surfaceScrollbarDrags == 0
                && semanticInitialSurfaceScrollbarDrag(action, item: item, capture: capture)
            let resetDrag = resetting
                && !semanticProgress.surfaceReset
                && semanticProgress.surfaceResetScrollbarDrags == 0
                && semanticScrollbarDrag(action, toward: .top, capture: capture)
            guard initialDrag || resetDrag else {
                throw AdapterError.queueRejected("SEMANTIC_SURFACE_SCROLL_ACTION_INVALID")
            }
        case .surfaceOptionSelect:
            let resetting = semanticProgress.surfaceResetSelectorOpened
                && !semanticProgress.surfaceReset
            let initialSelection = semanticProgress.selectorOpened
                && !semanticProgress.surfaceSelected
                && (surfaceDragLimit == 0
                    ? semanticProgress.surfaceScrollbarDrags == 0
                    : semanticProgress.surfaceScrollbarDrags == 1)
                && semanticClick(
                    action,
                    inside: semanticSurfaceOptionRect(item),
                    capture: capture
                )
            let resetSelection = resetting
                && semanticProgress.surfaceResetScrollbarDrags == 1
                && semanticClick(
                    action,
                    inside: semanticSurfaceOptionRect(.gielinorSurface),
                    capture: capture
                )
            guard initialSelection || resetSelection else {
                throw AdapterError.queueRejected("SEMANTIC_SURFACE_OPTION_ACTION_INVALID")
            }
        case .zoomMinus:
            guard semanticProgress.surfaceSelected,
                  semanticProgress.zoomPlusClicks == 0,
                  !semanticProgress.panDelivered,
                  semanticProgress.zoomMinusClicks < 8,
                  semanticClick(action, inside: referenceRect(404, 648, 438, 672), capture: capture) else {
                throw AdapterError.queueRejected("SEMANTIC_ZOOM_MINUS_ACTION_INVALID")
            }
        case .zoomPlus:
            guard semanticProgress.surfaceSelected,
                  semanticProgress.zoomMinusClicks >= 2,
                  semanticProgress.zoomPlusClicks < targetPlusClicks,
                  !semanticProgress.panDelivered,
                  semanticClick(action, inside: referenceRect(440, 648, 478, 672), capture: capture) else {
                throw AdapterError.queueRejected("SEMANTIC_ZOOM_PLUS_ACTION_INVALID")
            }
        case .coverageResetSelectorOpen:
            guard semanticResetRelativeCoverageItem(item),
                  !semanticProgress.selectorOpened,
                  !semanticProgress.coverageResetSelectorOpened,
                  !semanticProgress.coverageResetSelected,
                  semanticClick(action, inside: referenceRect(315, 630, 385, 700), capture: capture) else {
                throw AdapterError.queueRejected("SEMANTIC_COVERAGE_RESET_SELECTOR_ACTION_INVALID")
            }
        case .coverageResetScrollbarDrag:
            guard semanticResetRelativeCoverageItem(item),
                  semanticProgress.coverageResetSelectorOpened,
                  !semanticProgress.coverageResetSelected,
                  semanticProgress.coverageResetScrollbarDrags == 0,
                  semanticProductionScrollbarDrag(
                    action,
                    selectorIndex: 0,
                    capture: capture
                  ) else {
                throw AdapterError.queueRejected("SEMANTIC_COVERAGE_RESET_SCROLL_ACTION_INVALID")
            }
        case .coverageResetOptionSelect:
            guard semanticResetRelativeCoverageItem(item),
                  semanticProgress.coverageResetSelectorOpened,
                  !semanticProgress.coverageResetSelected,
                  semanticProgress.coverageResetScrollbarDrags <= 1,
                  semanticClick(
                    action,
                    inside: semanticSurfaceOptionRect(semanticCoverageResetSurface(item)),
                    capture: capture
                  ) else {
                throw AdapterError.queueRejected("SEMANTIC_COVERAGE_RESET_OPTION_ACTION_INVALID")
            }
        case .coverageMapClose:
            guard semanticReopenResetCoverageItem(item),
                  !semanticProgress.selectorOpened,
                  !semanticProgress.coverageMapClosed,
                  !semanticProgress.coverageMapReopened,
                  semanticClick(action, inside: referenceRect(486, 35, 516, 70), capture: capture) else {
                throw AdapterError.queueRejected("SEMANTIC_COVERAGE_MAP_CLOSE_ACTION_INVALID")
            }
        case .coverageMapReopen:
            guard semanticReopenResetCoverageItem(item),
                  semanticProgress.coverageMapClosed,
                  !semanticProgress.coverageMapReopened,
                  !semanticProgress.selectorOpened,
                  case .openWorldMap = action else {
                throw AdapterError.queueRejected("SEMANTIC_COVERAGE_MAP_REOPEN_ACTION_INVALID")
            }
        case .coverageAnchor:
            let requiredAttempts = item.plannerVersion == "native-realm-coverage-planner-v8"
                ? (item.coverageCell?.anchorAttemptBudget ?? -1)
                : 40
            guard (item.plannerVersion == "native-realm-coverage-planner-v2"
                    || item.plannerVersion == "native-realm-coverage-planner-v8"),
                  semanticProgress.surfaceSelected,
                  semanticProgress.zoomMinusClicks >= 2,
                  semanticProgress.zoomMinusClicks <= 8,
                  semanticProgress.zoomPlusClicks == targetPlusClicks,
                  semanticProgress.coveragePanDrags == 0,
                  semanticProgress.coverageAnchorDrags < requiredAttempts,
                  semanticCoverageAnchorDrag(
                    action,
                    capture: capture,
                    plannerVersion: item.plannerVersion
                  ) else {
                throw AdapterError.queueRejected("SEMANTIC_COVERAGE_ANCHOR_ACTION_INVALID")
            }
        case .coveragePan:
            let expectedCoveragePans = semanticCoverageExpectedPanCount(item)
            guard semanticNativeCoverageItem(item),
                  semanticProgress.surfaceSelected,
                  semanticProgress.zoomMinusClicks >= 2,
                  semanticProgress.zoomMinusClicks <= 8,
                  semanticProgress.zoomPlusClicks == targetPlusClicks,
                  expectedCoveragePans >= 0,
                  semanticProgress.coveragePanDrags < expectedCoveragePans,
                  semanticCoveragePanDrag(action, item: item, capture: capture) else {
                throw AdapterError.queueRejected("SEMANTIC_COVERAGE_PAN_ACTION_INVALID")
            }
        case .pan:
            guard !semanticNativeCoverageItem(item),
                  semanticProgress.surfaceSelected,
                  semanticProgress.zoomMinusClicks >= 2,
                  semanticProgress.zoomMinusClicks <= 8,
                  semanticProgress.zoomPlusClicks == targetPlusClicks,
                  !semanticProgress.panDelivered,
                  semanticDrag(action, matches: semanticPanVector(item.criterionFamily), capture: capture) else {
                throw AdapterError.queueRejected("SEMANTIC_PAN_ACTION_INVALID")
            }
        case .restore:
            guard item.restoreAfterCapture == true,
                  semanticProgress.panDelivered,
                  !semanticProgress.restorationDelivered,
                  semanticMeasuredRestoreDrag(
                    action,
                    family: item.criterionFamily,
                    capture: capture
                  ) else {
                throw AdapterError.queueRejected("SEMANTIC_RESTORE_ACTION_INVALID")
            }
        }
    }

    private func completeSemanticAction(_ role: SemanticActionRole) {
        switch role {
        case .recoveryTryAgain:
            semanticProgress.recoveryTryAgainDelivered = true
        case .recoverySteamSignIn:
            semanticProgress.recoverySteamSignInDelivered = true
        case .recoveryClickToPlay:
            semanticProgress.recoveryClickToPlayDelivered = true
        case .recoveryOpenWorldMap:
            semanticProgress.recoveryOpenWorldMapDelivered = true
        case .surfaceSelectorOpen:
            if semanticProgress.selectorOpened {
                semanticProgress.surfaceResetSelectorOpened = true
            } else {
                semanticProgress.selectorOpened = true
            }
        case .surfaceSelectorScrollbarDrag:
            if semanticProgress.surfaceResetSelectorOpened {
                semanticProgress.surfaceResetScrollbarDrags += 1
            } else {
                semanticProgress.surfaceScrollbarDrags += 1
            }
        case .surfaceOptionSelect:
            if semanticProgress.surfaceResetSelectorOpened {
                semanticProgress.surfaceReset = true
            } else {
                semanticProgress.surfaceSelected = true
            }
        case .zoomMinus:
            semanticProgress.zoomMinusClicks += 1
        case .zoomPlus:
            semanticProgress.zoomPlusClicks += 1
        case .coverageResetSelectorOpen:
            semanticProgress.coverageResetSelectorOpened = true
        case .coverageResetScrollbarDrag:
            semanticProgress.coverageResetScrollbarDrags += 1
        case .coverageResetOptionSelect:
            semanticProgress.coverageResetSelected = true
        case .coverageMapClose:
            semanticProgress.coverageMapClosed = true
        case .coverageMapReopen:
            semanticProgress.coverageMapReopened = true
        case .coverageAnchor:
            semanticProgress.coverageAnchorDrags += 1
        case .coveragePan:
            semanticProgress.coveragePanDrags += 1
        case .pan:
            semanticProgress.panDelivered = true
        case .restore:
            semanticProgress.restorationDelivered = true
        }
    }

    private func semanticItemComplete(_ item: QueueItem) -> Bool {
        let baseComplete = semanticProgress.selectorOpened
            && semanticProgress.surfaceSelected
            && semanticProgress.zoomMinusClicks >= 2
            && semanticProgress.zoomMinusClicks <= 8
            && semanticProgress.zoomPlusClicks == semanticZoomAscentCount(item.zoomPercent)
            && (item.restoreAfterCapture != true || semanticProgress.restorationDelivered)
            && (!semanticSurfaceResetRequired(item) || semanticProgress.surfaceReset)
            && pendingSemanticRole == nil
        if semanticNativeCoverageItem(item) {
            if item.plannerVersion == "native-realm-coverage-planner-v8" {
                return baseComplete
                    && semanticProgress.coverageAnchorDrags
                        == item.coverageCell?.anchorAttemptBudget
                    && semanticProgress.coveragePanDrags == semanticCoverageExpectedPanCount(item)
                    && !semanticProgress.panDelivered
            }
            if semanticReopenResetCoverageItem(item) {
                return baseComplete
                    && semanticProgress.coverageMapClosed
                    && semanticProgress.coverageMapReopened
                    && semanticProgress.coveragePanDrags == semanticCoverageExpectedPanCount(item)
                    && semanticProgress.coverageAnchorDrags == 0
                    && !semanticProgress.panDelivered
            }
            if semanticResetRelativeCoverageItem(item) {
                return baseComplete
                    && semanticProgress.coverageResetSelected
                    && semanticProgress.coveragePanDrags == semanticCoverageExpectedPanCount(item)
                    && semanticProgress.coverageAnchorDrags == 0
                    && !semanticProgress.panDelivered
            }
            let groupStart = item.coverageCell?.row == 0 && item.coverageCell?.column == 0
            let navigationComplete = groupStart
                ? semanticProgress.coverageAnchorDrags > 0
                : semanticProgress.coverageAnchorDrags > 0 || semanticProgress.coveragePanDrags > 0
            return baseComplete && navigationComplete && !semanticProgress.panDelivered
        }
        return baseComplete && semanticProgress.panDelivered
    }

    private func semanticZoomAscentCount(_ zoomPercent: Double?) -> Int {
        [37.5, 50, 75, 100, 200].firstIndex(of: zoomPercent ?? -1) ?? -1
    }

    private func semanticActionCaptureIdentifier(_ action: PrivilegedAction) -> String {
        switch action {
        case let .click(captureIdentifier, _, _),
             let .drag(captureIdentifier, _, _),
             let .openWorldMap(captureIdentifier):
            return captureIdentifier
        }
    }

    private struct ReferenceVector {
        let from: AdapterPoint
        let to: AdapterPoint

        var reversed: ReferenceVector { ReferenceVector(from: to, to: from) }
    }

    private func semanticPanVector(_ family: SemanticCriterionFamily?) -> ReferenceVector {
        switch family {
        case .eastwardTopology:
            return ReferenceVector(from: AdapterPoint(x: 430, y: 300), to: AdapterPoint(x: 90, y: 300))
        case .southwardTopology:
            return ReferenceVector(from: AdapterPoint(x: 260, y: 560), to: AdapterPoint(x: 260, y: 150))
        case .westwardBoundary:
            return ReferenceVector(from: AdapterPoint(x: 90, y: 300), to: AdapterPoint(x: 430, y: 300))
        case .northwardDetail:
            return ReferenceVector(from: AdapterPoint(x: 260, y: 150), to: AdapterPoint(x: 260, y: 560))
        case .centerDetail:
            return ReferenceVector(from: AdapterPoint(x: 420, y: 520), to: AdapterPoint(x: 150, y: 210))
        case nil:
            return ReferenceVector(from: AdapterPoint(x: -1, y: -1), to: AdapterPoint(x: -1, y: -1))
        }
    }

    private func semanticSurfaceOptionRect(_ item: QueueItem) -> AdapterRect {
        if item.realmID != nil, item.selectorIndex != nil {
            // The client may snap the scrollbar to a neighboring valid top index.
            // Realm identity is bound by fresh localization and broker validation.
            return referenceRect(166, 533, 349, 645)
        }
        return semanticSurfaceOptionRect(item.surface)
    }

    private func semanticSurfaceOptionRect(_ surface: SemanticMapSurface?) -> AdapterRect {
        switch surface {
        case .gielinorSurface:
            return referenceRect(166, 526, 349, 545)
        case .ancientCavern:
            return referenceRect(166, 544, 349, 563)
        case .ardougneUnderground:
            return referenceRect(166, 578, 349, 597)
        case .asgarniaIceCave:
            return referenceRect(166, 596, 349, 615)
        case .zanaris:
            return referenceRect(166, 631, 339, 650)
        case nil:
            return referenceRect(-1, -1, -1, -1)
        default:
            return referenceRect(-1, -1, -1, -1)
        }
    }

    private func semanticSurfaceDragLimit(_ item: QueueItem) -> Int {
        if item.realmID != nil, let selectorIndex = item.selectorIndex {
            return selectorIndex >= 8 ? 1 : 0
        }
        return item.surface == .zanaris ? 1 : 0
    }

    private func semanticSurfaceResetRequired(_ item: QueueItem) -> Bool {
        item.surface == .zanaris && item.restoreAfterCapture == true
    }

    private func semanticNativeCoverageItem(_ item: QueueItem) -> Bool {
        item.plannerVersion == "native-realm-coverage-planner-v2"
            || item.plannerVersion == "native-realm-coverage-planner-v3"
            || item.plannerVersion == "native-realm-coverage-planner-v4"
            || item.plannerVersion == "native-realm-coverage-planner-v5"
            || item.plannerVersion == "native-realm-coverage-planner-v6"
            || item.plannerVersion == "native-realm-coverage-planner-v7"
            || item.plannerVersion == "native-realm-coverage-planner-v8"
            || item.plannerVersion == "native-realm-coverage-planner-v9"
            || item.plannerVersion == "native-realm-coverage-planner-v10"
            || item.plannerVersion == "native-realm-coverage-planner-v11"
            || item.plannerVersion == "native-realm-coverage-planner-v12"
            || item.plannerVersion == "native-realm-coverage-planner-v13"
            || item.plannerVersion == "native-realm-coverage-planner-v14"
    }

    private func semanticResetRelativeCoverageItem(_ item: QueueItem) -> Bool {
        item.plannerVersion == "native-realm-coverage-planner-v3"
            || item.plannerVersion == "native-realm-coverage-planner-v4"
            || item.plannerVersion == "native-realm-coverage-planner-v5"
            || item.plannerVersion == "native-realm-coverage-planner-v6"
            || item.plannerVersion == "native-realm-coverage-planner-v7"
    }

    private func semanticReopenResetCoverageItem(_ item: QueueItem) -> Bool {
        item.plannerVersion == "native-realm-coverage-planner-v9"
            || item.plannerVersion == "native-realm-coverage-planner-v10"
            || item.plannerVersion == "native-realm-coverage-planner-v11"
            || item.plannerVersion == "native-realm-coverage-planner-v12"
            || item.plannerVersion == "native-realm-coverage-planner-v13"
            || item.plannerVersion == "native-realm-coverage-planner-v14"
    }

    private func semanticCoverageResetSurface(_ item: QueueItem) -> SemanticMapSurface {
        item.surface == .gielinorSurface ? .ancientCavern : .gielinorSurface
    }

    private func semanticCoverageExpectedPanCount(_ item: QueueItem) -> Int {
        if item.plannerVersion == "native-realm-coverage-planner-v2" { return 40 }
        guard semanticResetRelativeCoverageItem(item)
                || item.plannerVersion == "native-realm-coverage-planner-v8"
                || semanticReopenResetCoverageItem(item),
              let from = item.coverageCell?.resetCenter,
              let to = item.captureCenter,
              let zoom = item.zoomPercent else { return -1 }
        let dx = Int(((from.x - to.x) * zoom / 100).rounded())
        let dy = Int(((to.y - from.y) * zoom / 100).rounded())
        if hypot(Double(dx), Double(dy)) < Self.semanticMinimumPanReferenceDisplacement {
            return 0
        }
        return max(
            Int(ceil(Double(abs(dx)) / 240)),
            Int(ceil(Double(abs(dy)) / 400))
        )
    }

    private func referenceRect(_ left: Double, _ top: Double, _ right: Double, _ bottom: Double) -> AdapterRect {
        AdapterRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    private func semanticClick(
        _ action: PrivilegedAction,
        inside reference: AdapterRect,
        capture: CaptureEvidence
    ) -> Bool {
        guard case let .click(_, point, button) = action, button == .left else { return false }
        let rect = scale(reference, capture: capture)
        return pointIsInsidePixelAlignedRect(point, rect: rect)
    }

    private func semanticDrag(
        _ action: PrivilegedAction,
        matches reference: ReferenceVector,
        capture: CaptureEvidence
    ) -> Bool {
        guard case let .drag(_, from, to) = action else { return false }
        let mapRegion = scale(referenceRect(4, 70, 474, 630), capture: capture)
        guard point(from, isInside: mapRegion), point(to, isInside: mapRegion) else {
            return false
        }
        let deliveredFrom = unscale(from, capture: capture)
        let deliveredTo = unscale(to, capture: capture)
        let tolerance = 0.75
        for fractionPercent in stride(from: 100, through: 5, by: -5) {
            let fraction = Double(fractionPercent) / 100
            let expectedTo = AdapterPoint(
                x: reference.from.x + floor((reference.to.x - reference.from.x) * fraction + 0.5),
                y: reference.from.y + floor((reference.to.y - reference.from.y) * fraction + 0.5)
            )
            guard hypot(
                expectedTo.x - reference.from.x,
                expectedTo.y - reference.from.y
            ) >= Self.semanticMinimumPanReferenceDisplacement else {
                continue
            }
            let fromTranslation = AdapterPoint(
                x: deliveredFrom.x - reference.from.x,
                y: deliveredFrom.y - reference.from.y
            )
            let toTranslation = AdapterPoint(
                x: deliveredTo.x - expectedTo.x,
                y: deliveredTo.y - expectedTo.y
            )
            if abs(fromTranslation.x) <= 36 + tolerance,
               abs(fromTranslation.y) <= 36 + tolerance,
               pointsNear(fromTranslation, toTranslation, tolerance: tolerance) {
                return true
            }
        }
        return false
    }

    private func semanticCoverageAnchorDrag(
        _ action: PrivilegedAction,
        capture: CaptureEvidence,
        plannerVersion: String?
    ) -> Bool {
        guard case let .drag(_, from, to) = action else { return false }
        let deliveredFrom = unscale(from, capture: capture)
        let deliveredTo = unscale(to, capture: capture)
        let expectedFrom = plannerVersion == "native-realm-coverage-planner-v8"
            ? AdapterPoint(x: 190, y: 503)
            : AdapterPoint(x: 40, y: 590)
        let expectedTo = plannerVersion == "native-realm-coverage-planner-v8"
            ? AdapterPoint(x: 430, y: 103)
            : AdapterPoint(x: 440, y: 90)
        let tolerance = 0.75
        if plannerVersion != "native-realm-coverage-planner-v8" {
            return pointsNear(deliveredFrom, expectedFrom, tolerance: tolerance)
                && pointsNear(deliveredTo, expectedTo, tolerance: tolerance)
        }
        let fromTranslation = AdapterPoint(
            x: deliveredFrom.x - expectedFrom.x,
            y: deliveredFrom.y - expectedFrom.y
        )
        let toTranslation = AdapterPoint(
            x: deliveredTo.x - expectedTo.x,
            y: deliveredTo.y - expectedTo.y
        )
        return abs(fromTranslation.x) <= 36 + tolerance
            && abs(fromTranslation.y) <= 36 + tolerance
            && pointsNear(fromTranslation, toTranslation, tolerance: tolerance)
    }

    private func semanticCoveragePanDrag(
        _ action: PrivilegedAction,
        item: QueueItem,
        capture: CaptureEvidence
    ) -> Bool {
        guard case let .drag(_, from, to) = action else { return false }
        let resetRelative = semanticResetRelativeCoverageItem(item)
            || item.plannerVersion == "native-realm-coverage-planner-v8"
            || semanticReopenResetCoverageItem(item)
        let coverageCrop = item.coverageCell?.coverageCrop
        let mapRegion = scale(
            coverageCrop.map {
                referenceRect(
                    Double($0.left),
                    Double($0.top),
                    Double($0.left + $0.width),
                    Double($0.top + $0.height)
                )
            } ?? (resetRelative
                ? referenceRect(178, 35, 488, 515)
                : referenceRect(4, 70, 474, 630)),
            capture: capture
        )
        guard point(from, isInside: mapRegion), point(to, isInside: mapRegion) else {
            return false
        }
        let deliveredFrom = unscale(from, capture: capture)
        let deliveredTo = unscale(to, capture: capture)
        let dx = deliveredTo.x - deliveredFrom.x
        let dy = deliveredTo.y - deliveredFrom.y
        guard abs(dx) <= (resetRelative ? 240.75 : 400.75),
              abs(dy) <= (resetRelative ? 400.75 : 500.75),
              hypot(dx, dy) >= Self.semanticMinimumPanReferenceDisplacement else {
            return false
        }
        let expectedFrom = AdapterPoint(
            x: coverageCrop.map {
                dx >= 0 ? Double($0.left + 12) : Double($0.left + $0.width - 12)
            } ?? (resetRelative ? (dx >= 0 ? 190 : 476) : (dx >= 0 ? 40 : 440)),
            y: coverageCrop.map {
                dy >= 0 ? Double($0.top + 12) : Double($0.top + $0.height - 12)
            } ?? (resetRelative ? (dy >= 0 ? 47 : 503) : (dy >= 0 ? 90 : 590))
        )
        let translation = AdapterPoint(
            x: deliveredFrom.x - expectedFrom.x,
            y: deliveredFrom.y - expectedFrom.y
        )
        let deliveredToTranslation = AdapterPoint(
            x: deliveredTo.x - (expectedFrom.x + dx),
            y: deliveredTo.y - (expectedFrom.y + dy)
        )
        let tolerance = 0.75
        return abs(translation.x) <= 36 + tolerance
            && abs(translation.y) <= 36 + tolerance
            && pointsNear(translation, deliveredToTranslation, tolerance: tolerance)
    }

    private func semanticMeasuredRestoreDrag(
        _ action: PrivilegedAction,
        family: SemanticCriterionFamily?,
        capture: CaptureEvidence
    ) -> Bool {
        guard case let .drag(_, from, to) = action else { return false }
        let maximum = semanticPanVector(family).reversed
        let maximumFrom = scale(maximum.from, capture: capture)
        let maximumTo = scale(maximum.to, capture: capture)
        let maximumDelta = AdapterPoint(
            x: maximumTo.x - maximumFrom.x,
            y: maximumTo.y - maximumFrom.y
        )
        let deliveredDelta = AdapterPoint(x: to.x - from.x, y: to.y - from.y)
        let crossAxisTolerance = max(
            3,
            5 * max(
                Double(capture.pixelWidth) / 768,
                Double(capture.pixelHeight) / 839
            )
        )
        let mapRegion = scale(referenceRect(4, 70, 474, 630), capture: capture)
        return point(from, isInside: mapRegion)
            && point(to, isInside: mapRegion)
            && measuredRestoreAxis(
                deliveredDelta.x,
                maximum: maximumDelta.x,
                crossAxisTolerance: crossAxisTolerance
            )
            && measuredRestoreAxis(
                deliveredDelta.y,
                maximum: maximumDelta.y,
                crossAxisTolerance: crossAxisTolerance
            )
            && hypot(deliveredDelta.x, deliveredDelta.y) >= crossAxisTolerance * 2
    }

    private func measuredRestoreAxis(
        _ delivered: Double,
        maximum: Double,
        crossAxisTolerance: Double
    ) -> Bool {
        if abs(maximum) <= 3 {
            return abs(delivered) <= crossAxisTolerance
        }
        return delivered == 0
            || (delivered.sign == maximum.sign && abs(delivered) <= abs(maximum) + 3)
    }

    private enum SemanticScrollbarAnchor: Equatable {
        case top
        case bottom
    }

    private func semanticScrollbarDrag(
        _ action: PrivilegedAction,
        toward anchor: SemanticScrollbarAnchor,
        capture: CaptureEvidence
    ) -> Bool {
        guard case let .drag(_, from, to) = action else { return false }
        let track = scale(referenceRect(342, 543, 356, 629), capture: capture)
        let expectedStart = scale(
            anchor == .bottom
                ? referenceRect(342, 543, 356, 559)
                : referenceRect(342, 613, 356, 629),
            capture: capture
        )
        let expectedStop = scale(
            anchor == .bottom
                ? AdapterPoint(x: 349, y: 628)
                : AdapterPoint(x: 349, y: 543),
            capture: capture
        )
        let movesInExpectedDirection = anchor == .bottom
            ? to.y - from.y >= 50 * Double(capture.pixelHeight) / 839
            : from.y - to.y >= 50 * Double(capture.pixelHeight) / 839
        return pointIsInsidePixelAlignedRect(from, rect: expectedStart)
            && pointIsInsidePixelAlignedRect(from, rect: track)
            && pointIsInsidePixelAlignedRect(to, rect: track)
            && abs(from.x - to.x) <= 3
            && pointsNear(to, expectedStop, tolerance: 3)
            && movesInExpectedDirection
    }

    private func semanticInitialSurfaceScrollbarDrag(
        _ action: PrivilegedAction,
        item: QueueItem,
        capture: CaptureEvidence
    ) -> Bool {
        if item.realmID == nil {
            return semanticScrollbarDrag(action, toward: .bottom, capture: capture)
        }
        guard let selectorIndex = item.selectorIndex else { return false }
        return semanticProductionScrollbarDrag(
            action,
            selectorIndex: selectorIndex,
            capture: capture
        )
    }

    private func semanticProductionScrollbarDrag(
        _ action: PrivilegedAction,
        selectorIndex: Int,
        capture: CaptureEvidence
    ) -> Bool {
        guard case let .drag(_, from, to) = action else { return false }
        let track = scale(referenceRect(342, 543, 356, 629), capture: capture)
        let referenceFrom = unscale(from, capture: capture)
        let observedThumbTop = max(543, min(613, Int((referenceFrom.y - 8).rounded())))
        let currentTopIndex = Int(
            (Double(observedThumbTop - 543) * 39.0 / 70.0).rounded(.up)
        )
        let targetBounds = productionTargetThumbTopBounds(
            selectorIndex: selectorIndex,
            currentTopIndex: currentTopIndex
        )
        let targetTop = Double(targetBounds.lowerBound)
        let exactTopStop = targetTop == 543 && from.y > scale(
            AdapterPoint(x: 349, y: targetTop),
            capture: capture
        ).y
        let baseExpectedTarget = scale(
            AdapterPoint(x: 349, y: exactTopStop ? targetTop : targetTop + 8),
            capture: capture
        )
        let transferDirection = baseExpectedTarget.y == from.y
            ? 0.0
            : (baseExpectedTarget.y > from.y ? 1.0 : -1.0)
        let sourcePixelScale = max(1, (Double(capture.pixelHeight) / 839).rounded())
        let transferPixelCount = Double(
            targetBounds.upperBound - targetBounds.lowerBound + 1
        )
        let transferOffset = transferDirection * (sourcePixelScale + transferPixelCount - 1)
        let expectedTarget = exactTopStop
            ? baseExpectedTarget
            : AdapterPoint(
                x: baseExpectedTarget.x,
                y: baseExpectedTarget.y + transferOffset
            )
        let deliveredDelta = to.y - from.y
        let expectedDelta = expectedTarget.y - from.y
        return pointIsInsidePixelAlignedRect(from, rect: track)
            && pointIsInsidePixelAlignedRect(to, rect: track)
            && abs(from.x - to.x) <= 3
            && pointsNear(to, expectedTarget, tolerance: 3)
            && abs(deliveredDelta) >= 1
            && deliveredDelta * expectedDelta > 0
    }

    private func productionTargetThumbTopBounds(
        selectorIndex: Int,
        currentTopIndex: Int
    ) -> ClosedRange<Int> {
        let topIndex = productionTargetTopIndex(
            selectorIndex: selectorIndex,
            currentTopIndex: currentTopIndex
        )
        return productionThumbTopBounds(visibleTopIndex: topIndex)
    }

    private func productionTargetTopIndex(
        selectorIndex: Int,
        currentTopIndex: Int
    ) -> Int {
        let visibleRowCount = 8
        let maxTopIndex = 39
        let centeredTopIndex = max(0, min(maxTopIndex, selectorIndex - visibleRowCount / 2))
        let minimumTopIndex = max(0, selectorIndex - visibleRowCount + 1)
        let maximumTopIndex = min(selectorIndex, maxTopIndex)
        let direction = centeredTopIndex == currentTopIndex
            ? 0
            : (centeredTopIndex > currentTopIndex ? 1 : -1)

        return (minimumTopIndex...maximumTopIndex).min { left, right in
            let leftBounds = productionThumbTopBounds(visibleTopIndex: left)
            let rightBounds = productionThumbTopBounds(visibleTopIndex: right)
            let leftWidth = leftBounds.upperBound - leftBounds.lowerBound + 1
            let rightWidth = rightBounds.upperBound - rightBounds.lowerBound + 1
            if leftWidth != rightWidth { return leftWidth > rightWidth }

            let leftCenterDistance = abs(left - centeredTopIndex)
            let rightCenterDistance = abs(right - centeredTopIndex)
            if leftCenterDistance != rightCenterDistance {
                return leftCenterDistance < rightCenterDistance
            }

            return direction == 0 ? left < right : left > right
        } ?? centeredTopIndex
    }

    private func productionThumbTopBounds(visibleTopIndex: Int) -> ClosedRange<Int> {
        let maxTopIndex = 39
        if visibleTopIndex == maxTopIndex { return 613...613 }
        let matchingTops = (543...613).filter { observedTop in
            Int(
                (Double(observedTop - 543) * Double(maxTopIndex) / 70.0).rounded(.up)
            ) == visibleTopIndex
        }
        return (matchingTops.first ?? 543)...(matchingTops.last ?? 543)
    }

    private func scale(_ point: AdapterPoint, capture: CaptureEvidence) -> AdapterPoint {
        AdapterPoint(
            x: point.x * Double(capture.pixelWidth) / 768,
            y: point.y * Double(capture.pixelHeight) / 839
        )
    }

    private func unscale(_ point: AdapterPoint, capture: CaptureEvidence) -> AdapterPoint {
        AdapterPoint(
            x: point.x * 768 / Double(capture.pixelWidth),
            y: point.y * 839 / Double(capture.pixelHeight)
        )
    }

    private func scale(_ rect: AdapterRect, capture: CaptureEvidence) -> AdapterRect {
        AdapterRect(
            x: rect.x * Double(capture.pixelWidth) / 768,
            y: rect.y * Double(capture.pixelHeight) / 839,
            width: rect.width * Double(capture.pixelWidth) / 768,
            height: rect.height * Double(capture.pixelHeight) / 839
        )
    }

    private func point(_ point: AdapterPoint, isInside rect: AdapterRect) -> Bool {
        point.x >= rect.x && point.x <= rect.x + rect.width
            && point.y >= rect.y && point.y <= rect.y + rect.height
    }

    private func pointIsInsidePixelAlignedRect(_ point: AdapterPoint, rect: AdapterRect) -> Bool {
        point.x >= floor(rect.x) && point.x <= ceil(rect.x + rect.width)
            && point.y >= floor(rect.y) && point.y <= ceil(rect.y + rect.height)
    }

    private func pointsNear(_ first: AdapterPoint, _ second: AdapterPoint, tolerance: Double) -> Bool {
        abs(first.x - second.x) <= tolerance && abs(first.y - second.y) <= tolerance
    }

    private func requireWithinItemDeadline(
        generationIdentifier: String,
        itemIdentifier: String
    ) throws {
        guard let manifest = active?.manifest,
              manifest.generationIdentifier == generationIdentifier,
              let inFlight,
              inFlight.id == itemIdentifier else {
            throw AdapterError.queueRejected("ITEM_DEADLINE_BINDING_MISMATCH")
        }
        guard let deadline = inFlightDeadlineAt, now() < deadline else {
            try revokeActiveGeneration(reason: "ITEM_EXECUTION_DEADLINE_EXCEEDED:\(itemIdentifier)")
            throw AdapterError.queueRejected("ITEM_EXECUTION_DEADLINE_EXCEEDED")
        }
    }

    private func revokeActiveGeneration(reason: String) throws {
        guard let generationIdentifier = active?.manifest.generationIdentifier else { return }
        let relativePath = revocationPath(generationIdentifier)
        let destination = revocationStore.root.appendingPathComponent(relativePath)
        if !FileManager.default.fileExists(atPath: destination.path) {
            _ = try revocationStore.writeImmutable(
                GenerationRevocation(
                    schemaVersion: 1,
                    generationIdentifier: generationIdentifier,
                    reason: reason,
                    revokedAt: AdapterClock.string(from: now())
                ),
                relativePath: relativePath
            )
        }
        canceled = true
        inFlight = nil
        inFlightClaimedAt = nil
        inFlightDeadlineAt = nil
        nextActionIndex = 0
        semanticProgress = SemanticActionProgress()
        pendingSemanticRole = nil
    }

    private func cancelActiveGeneration(reason: String) throws {
        guard let active, let activeUse else {
            throw AdapterError.queueRejected("QUEUE_CANCELLATION_ACTIVE_BINDING_MISSING")
        }
        guard activationEvidenceRecorded else {
            try revokeActiveGeneration(reason: reason)
            clearActiveRuntimeState()
            return
        }
        let generationIdentifier = active.manifest.generationIdentifier
        let intentURL = cancellationIntentURL(generationIdentifier)
        let stateIO = try LegacyMigrationFileSystem(root: hostEvidenceRoot, createRoot: true)
        let intent: QueueCancellationIntent
        if let data = try stateIO.readImmutableRecordIfPresent(
            at: intentURL,
            code: "CANCELLATION_INTENT"
        ) {
            intent = try decodeCancellationIntent(data)
            try validateCancellationIntent(intent, active: active, use: activeUse)
        } else {
            let existingRevocation = try readRevocation(
                generationIdentifier: generationIdentifier,
                using: stateIO
            )
            let requestedAt = AdapterClock.string(from: now())
            intent = QueueCancellationIntent(
                schemaVersion: 1,
                generationIdentifier: generationIdentifier,
                manifestPath: active.sourcePath,
                manifestSHA256: active.fileSHA256,
                policyDigest: active.manifest.policyDigest,
                activatedAt: activeUse.activatedAt,
                cancellationReason: reason,
                requestedAt: requestedAt,
                priorItemIdentifier: inFlight?.id ?? "",
                priorNextIndex: nextIndex,
                priorNextActionIndex: nextActionIndex,
                priorClaimedAt: inFlightClaimedAt.map(AdapterClock.string(from:)) ?? "",
                priorDeadlineAt: inFlightDeadlineAt.map(AdapterClock.string(from:)) ?? "",
                revocationReason: existingRevocation?.reason ?? reason,
                revokedAt: existingRevocation?.revokedAt ?? requestedAt
            )
            let data = try encoded(intent)
            let published = try stateIO.publishImmutableRecord(
                data,
                at: intentURL,
                code: "CANCELLATION_INTENT"
            )
            guard published else {
                throw AdapterError.queueRejected(
                    "QUEUE_CANCELLATION_INTENT_PUBLICATION_RACE:\(generationIdentifier)"
                )
            }
        }
        try cancellationHooks.reach(.afterIntentPublication)
        try ensureRevocation(for: intent, using: stateIO)
        canceled = true
        inFlight = nil
        inFlightClaimedAt = nil
        inFlightDeadlineAt = nil
        nextActionIndex = 0
        semanticProgress = SemanticActionProgress()
        pendingSemanticRole = nil
        try cancellationHooks.reach(.afterRevocationPublication)
        try cancellationHooks.reach(.beforeEventPublication)
        try ensureCancellationEvent(for: intent, using: stateIO)
        try cancellationHooks.reach(.afterEventPublication)
        try cancellationHooks.reach(.beforeRuntimeClear)
        clearActiveRuntimeState()
    }

    private func recoverCancellationTransactions() throws {
        var metadata = stat()
        if lstat(hostEvidenceRoot.path, &metadata) != 0 {
            if errno == ENOENT { return }
            throw AdapterError.queueRejected("QUEUE_CANCELLATION_RECOVERY_ROOT_FAILED:\(errno)")
        }
        let stateIO = try LegacyMigrationFileSystem(root: hostEvidenceRoot)
        let directory = hostEvidenceRoot.appendingPathComponent(
            "cancellation-intents",
            isDirectory: true
        )
        let entries = try stateIO.enumerateImmutableRegularFiles(
            at: directory,
            maximumMembers: LegacyMigrationFileSystem.maximumEventMembers,
            allowMissing: true,
            code: "CANCELLATION_INTENTS"
        )
        for entry in entries {
            guard entry.name.hasSuffix(".json") else {
                throw AdapterError.queueRejected(
                    "QUEUE_CANCELLATION_RECOVERY_MEMBER_UNSUPPORTED:\(entry.name)"
                )
            }
            let data = try stateIO.readImmutableRecord(entry, code: "CANCELLATION_INTENT")
            let intent = try decodeCancellationIntent(data)
            guard entry.name == "\(intent.generationIdentifier).json" else {
                throw AdapterError.queueRejected(
                    "QUEUE_CANCELLATION_RECOVERY_FILENAME_BINDING_INVALID:\(entry.name)"
                )
            }
            try ensureRevocation(for: intent, using: stateIO)
            try ensureCancellationEvent(for: intent, using: stateIO)
        }
    }

    private func ensureRevocation(
        for intent: QueueCancellationIntent,
        using stateIO: LegacyMigrationFileSystem
    ) throws {
        let destination = revocationStore.root.appendingPathComponent(
            revocationPath(intent.generationIdentifier)
        )
        let expected = GenerationRevocation(
            schemaVersion: 1,
            generationIdentifier: intent.generationIdentifier,
            reason: intent.revocationReason,
            revokedAt: intent.revokedAt
        )
        let expectedData = try encoded(expected)
        if let existing = try stateIO.readImmutableRecordIfPresent(
            at: destination,
            code: "CANCELLATION_REVOCATION"
        ) {
            guard existing == expectedData else {
                throw AdapterError.queueRejected(
                    "QUEUE_CANCELLATION_REVOCATION_CONFLICT:\(intent.generationIdentifier)"
                )
            }
            return
        }
        let published = try stateIO.publishImmutableRecord(
            expectedData,
            at: destination,
            code: "CANCELLATION_REVOCATION"
        )
        if !published {
            guard let existing = try stateIO.readImmutableRecordIfPresent(
                at: destination,
                code: "CANCELLATION_REVOCATION"
            ), existing == expectedData else {
                throw AdapterError.queueRejected(
                    "QUEUE_CANCELLATION_REVOCATION_PUBLICATION_FAILED:\(intent.generationIdentifier)"
                )
            }
        }
    }

    private func ensureCancellationEvent(
        for intent: QueueCancellationIntent,
        using stateIO: LegacyMigrationFileSystem
    ) throws {
        let intentData = try encoded(intent)
        let event = QueueCancellationEvent(
            schemaVersion: 1,
            event: "queue_canceled",
            generationIdentifier: intent.generationIdentifier,
            manifestPath: intent.manifestPath,
            manifestSHA256: intent.manifestSHA256,
            policyDigest: intent.policyDigest,
            activatedAt: intent.activatedAt,
            cancellationReason: intent.cancellationReason,
            recordedAt: intent.requestedAt,
            priorItemIdentifier: intent.priorItemIdentifier,
            priorNextIndex: intent.priorNextIndex,
            priorNextActionIndex: intent.priorNextActionIndex,
            priorClaimedAt: intent.priorClaimedAt,
            priorDeadlineAt: intent.priorDeadlineAt,
            revocationReason: intent.revocationReason,
            revokedAt: intent.revokedAt,
            cancellationIntentSHA256: AdapterHashing.sha256(intentData)
        )
        let expectedData = try encoded(event)
        let destination = hostEvidenceRoot
            .appendingPathComponent("events", isDirectory: true)
            .appendingPathComponent("queue-canceled-\(intent.generationIdentifier).json")
        if let existing = try stateIO.readImmutableRecordIfPresent(
            at: destination,
            code: "CANCELLATION_EVENT"
        ) {
            guard existing == expectedData else {
                throw AdapterError.queueRejected(
                    "QUEUE_CANCELLATION_EVENT_CONFLICT:\(intent.generationIdentifier)"
                )
            }
            return
        }
        let published = try stateIO.publishImmutableRecord(
            expectedData,
            at: destination,
            code: "CANCELLATION_EVENT"
        )
        if !published {
            guard let existing = try stateIO.readImmutableRecordIfPresent(
                at: destination,
                code: "CANCELLATION_EVENT"
            ), existing == expectedData else {
                throw AdapterError.queueRejected(
                    "QUEUE_CANCELLATION_EVENT_PUBLICATION_FAILED:\(intent.generationIdentifier)"
                )
            }
        }
    }

    private func ensureActivationEvent(
        for validated: ValidatedQueueManifest,
        use: GenerationUse
    ) throws {
        let stateIO = try LegacyMigrationFileSystem(root: hostEvidenceRoot, createRoot: true)
        let event = QueueActivationEvent(
            event: "queue_activated",
            generationIdentifier: validated.manifest.generationIdentifier,
            manifestPath: validated.sourcePath,
            manifestSHA256: validated.fileSHA256,
            recordedAt: use.activatedAt
        )
        let expectedData = try encoded(event)
        let destination = hostEvidenceRoot
            .appendingPathComponent("events", isDirectory: true)
            .appendingPathComponent(
                "queue-activated-\(validated.manifest.generationIdentifier).json"
            )
        if let existing = try stateIO.readImmutableRecordIfPresent(
            at: destination,
            code: "QUEUE_ACTIVATION_EVENT"
        ) {
            guard existing == expectedData else {
                throw AdapterError.queueRejected(
                    "QUEUE_ACTIVATION_EVENT_CONFLICT:\(validated.manifest.generationIdentifier)"
                )
            }
            return
        }
        let published = try stateIO.publishImmutableRecord(
            expectedData,
            at: destination,
            code: "QUEUE_ACTIVATION_EVENT"
        )
        guard published else {
            throw AdapterError.queueRejected(
                "QUEUE_ACTIVATION_EVENT_PUBLICATION_FAILED:\(validated.manifest.generationIdentifier)"
            )
        }
    }

    private func readRevocation(
        generationIdentifier: String,
        using stateIO: LegacyMigrationFileSystem
    ) throws -> GenerationRevocation? {
        let destination = revocationStore.root.appendingPathComponent(
            revocationPath(generationIdentifier)
        )
        guard let data = try stateIO.readImmutableRecordIfPresent(
            at: destination,
            code: "CANCELLATION_REVOCATION"
        ) else { return nil }
        guard LegacySchemaVersionDecoder.decodeRawSchemaVersion(in: data) == 1,
              let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(raw.keys) == ["schema_version", "generation_id", "reason", "revoked_at"] else {
            throw AdapterError.queueRejected(
                "QUEUE_CANCELLATION_REVOCATION_INVALID:\(generationIdentifier)"
            )
        }
        let decoder = JSONDecoder()
        let value = try decoder.decode(GenerationRevocation.self, from: data)
        guard value.schemaVersion == 1,
              value.generationIdentifier == generationIdentifier,
              !value.reason.isEmpty,
              AdapterClock.date(from: value.revokedAt) != nil else {
            throw AdapterError.queueRejected(
                "QUEUE_CANCELLATION_REVOCATION_INVALID:\(generationIdentifier)"
            )
        }
        return value
    }

    private func decodeCancellationIntent(_ data: Data) throws -> QueueCancellationIntent {
        let expectedKeys: Set<String> = [
            "schema_version", "generation_id", "manifest_path", "manifest_sha256",
            "policy_digest", "activated_at", "cancellation_reason", "requested_at",
            "prior_item_id", "prior_next_index", "prior_next_action_index",
            "prior_claimed_at", "prior_deadline_at", "revocation_reason", "revoked_at"
        ]
        guard LegacySchemaVersionDecoder.decodeRawSchemaVersion(in: data) == 1,
              let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(raw.keys) == expectedKeys else {
            throw AdapterError.queueRejected("QUEUE_CANCELLATION_INTENT_SCHEMA_INVALID")
        }
        let intent = try JSONDecoder().decode(QueueCancellationIntent.self, from: data)
        guard intent.schemaVersion == 1,
              validIdentifier(intent.generationIdentifier),
              !intent.manifestPath.isEmpty,
              validDigest(intent.manifestSHA256),
              validDigest(intent.policyDigest),
              AdapterClock.date(from: intent.activatedAt) != nil,
              !intent.cancellationReason.isEmpty,
              AdapterClock.date(from: intent.requestedAt) != nil,
              intent.priorNextIndex >= 0,
              intent.priorNextActionIndex >= 0,
              intent.priorClaimedAt.isEmpty || AdapterClock.date(from: intent.priorClaimedAt) != nil,
              intent.priorDeadlineAt.isEmpty || AdapterClock.date(from: intent.priorDeadlineAt) != nil,
              !intent.revocationReason.isEmpty,
              let activatedAt = AdapterClock.date(from: intent.activatedAt),
              let requestedAt = AdapterClock.date(from: intent.requestedAt),
              let revokedAt = AdapterClock.date(from: intent.revokedAt),
              requestedAt >= activatedAt,
              revokedAt >= activatedAt,
              revokedAt <= requestedAt else {
            throw AdapterError.queueRejected("QUEUE_CANCELLATION_INTENT_INVALID")
        }
        return intent
    }

    private func validateCancellationIntent(
        _ intent: QueueCancellationIntent,
        active: ValidatedQueueManifest,
        use: GenerationUse
    ) throws {
        guard intent.generationIdentifier == active.manifest.generationIdentifier,
              intent.manifestPath == active.sourcePath,
              intent.manifestSHA256 == active.fileSHA256,
              intent.policyDigest == active.manifest.policyDigest,
              intent.activatedAt == use.activatedAt else {
            throw AdapterError.queueRejected(
                "QUEUE_CANCELLATION_INTENT_BINDING_INVALID:\(active.manifest.generationIdentifier)"
            )
        }
    }

    private func clearActiveRuntimeState() {
        active = nil
        activeUse = nil
        activationEvidenceRecorded = false
        nextIndex = 0
        inFlight = nil
        nextActionIndex = 0
        semanticProgress = SemanticActionProgress()
        pendingSemanticRole = nil
        canceled = false
        inFlightClaimedAt = nil
        inFlightDeadlineAt = nil
    }

    private func cancellationIntentURL(_ generationIdentifier: String) -> URL {
        hostEvidenceRoot
            .appendingPathComponent("cancellation-intents", isDirectory: true)
            .appendingPathComponent("\(generationIdentifier).json")
    }

    private func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    private func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { byte in
            (byte >= 65 && byte <= 90)
                || (byte >= 97 && byte <= 122)
                || (byte >= 48 && byte <= 57)
                || byte == 46 || byte == 95 || byte == 45
        }
    }

    private func validDigest(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }
    }

    private func recordGenerationUse(_ validated: ValidatedQueueManifest) throws -> GenerationUse {
        let generationUse = GenerationUse(
            schemaVersion: 1,
            generationIdentifier: validated.manifest.generationIdentifier,
            manifestSHA256: validated.fileSHA256,
            policyDigest: validated.manifest.policyDigest,
            activatedAt: AdapterClock.string(from: now())
        )
        _ = try revocationStore.writeImmutable(
            generationUse,
            relativePath: generationUsePath(validated.manifest.generationIdentifier)
        )
        return generationUse
    }

    private func isGenerationRevoked(_ generationIdentifier: String) -> Bool {
        FileManager.default.fileExists(
            atPath: revocationStore.root.appendingPathComponent(
                revocationPath(generationIdentifier)
            ).path
        )
    }

    private func isGenerationUsed(_ generationIdentifier: String) -> Bool {
        FileManager.default.fileExists(
            atPath: revocationStore.root.appendingPathComponent(
                generationUsePath(generationIdentifier)
            ).path
        )
    }

    private func revocationPath(_ generationIdentifier: String) -> String {
        "revoked-generations/\(generationIdentifier).json"
    }

    private func generationUsePath(_ generationIdentifier: String) -> String {
        "used-generations/\(generationIdentifier).json"
    }

    private func claimTimestamp(_ date: Date?) throws -> String {
        guard let date else {
            throw AdapterError.queueRejected("ITEM_DEADLINE_STATE_INVALID")
        }
        return AdapterClock.string(from: date)
    }
}

private struct GenerationUse: Codable, Sendable {
    let schemaVersion: Int
    let generationIdentifier: String
    let manifestSHA256: String
    let policyDigest: String
    let activatedAt: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case generationIdentifier = "generation_id"
        case manifestSHA256 = "manifest_sha256"
        case policyDigest = "policy_digest"
        case activatedAt = "activated_at"
    }
}

private struct GenerationRevocation: Codable, Sendable {
    let schemaVersion: Int
    let generationIdentifier: String
    let reason: String
    let revokedAt: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case generationIdentifier = "generation_id"
        case reason
        case revokedAt = "revoked_at"
    }
}

private struct QueueCancellationIntent: Codable, Sendable {
    let schemaVersion: Int
    let generationIdentifier: String
    let manifestPath: String
    let manifestSHA256: String
    let policyDigest: String
    let activatedAt: String
    let cancellationReason: String
    let requestedAt: String
    let priorItemIdentifier: String
    let priorNextIndex: Int
    let priorNextActionIndex: Int
    let priorClaimedAt: String
    let priorDeadlineAt: String
    let revocationReason: String
    let revokedAt: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case generationIdentifier = "generation_id"
        case manifestPath = "manifest_path"
        case manifestSHA256 = "manifest_sha256"
        case policyDigest = "policy_digest"
        case activatedAt = "activated_at"
        case cancellationReason = "cancellation_reason"
        case requestedAt = "requested_at"
        case priorItemIdentifier = "prior_item_id"
        case priorNextIndex = "prior_next_index"
        case priorNextActionIndex = "prior_next_action_index"
        case priorClaimedAt = "prior_claimed_at"
        case priorDeadlineAt = "prior_deadline_at"
        case revocationReason = "revocation_reason"
        case revokedAt = "revoked_at"
    }
}

private struct QueueActivationEvent: Codable, Sendable {
    let event: String
    let generationIdentifier: String
    let manifestPath: String
    let manifestSHA256: String
    let recordedAt: String

    enum CodingKeys: String, CodingKey {
        case event
        case generationIdentifier = "generation_id"
        case manifestPath = "manifest_path"
        case manifestSHA256 = "manifest_sha256"
        case recordedAt = "recorded_at"
    }
}

private struct QueueCancellationEvent: Codable, Sendable {
    let schemaVersion: Int
    let event: String
    let generationIdentifier: String
    let manifestPath: String
    let manifestSHA256: String
    let policyDigest: String
    let activatedAt: String
    let cancellationReason: String
    let recordedAt: String
    let priorItemIdentifier: String
    let priorNextIndex: Int
    let priorNextActionIndex: Int
    let priorClaimedAt: String
    let priorDeadlineAt: String
    let revocationReason: String
    let revokedAt: String
    let cancellationIntentSHA256: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case event
        case generationIdentifier = "generation_id"
        case manifestPath = "manifest_path"
        case manifestSHA256 = "manifest_sha256"
        case policyDigest = "policy_digest"
        case activatedAt = "activated_at"
        case cancellationReason = "cancellation_reason"
        case recordedAt = "recorded_at"
        case priorItemIdentifier = "prior_item_id"
        case priorNextIndex = "prior_next_index"
        case priorNextActionIndex = "prior_next_action_index"
        case priorClaimedAt = "prior_claimed_at"
        case priorDeadlineAt = "prior_deadline_at"
        case revocationReason = "revocation_reason"
        case revokedAt = "revoked_at"
        case cancellationIntentSHA256 = "cancellation_intent_sha256"
    }
}
