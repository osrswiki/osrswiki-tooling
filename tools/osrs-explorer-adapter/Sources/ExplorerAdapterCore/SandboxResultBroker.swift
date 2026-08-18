import Darwin
import Foundation

public struct SandboxBrokerProtocolBinding: Codable, Equatable, Sendable {
    public let protocolName: String
    public let idempotencyKey: String
    public let expectedPredecessor: SandboxBrokerPredecessor

    enum CodingKeys: String, CodingKey {
        case protocolName = "protocol"
        case idempotencyKey = "idempotency_key"
        case expectedPredecessor = "expected_predecessor"
    }
}

public struct SandboxBrokerPredecessor: Codable, Equatable, Sendable {
    public let sequence: Int
    public let commitSHA256: String

    enum CodingKeys: String, CodingKey {
        case sequence
        case commitSHA256 = "commit_sha256"
    }
}

public struct SandboxAcceptedResultCommit: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let sandboxOnly: Bool
    public let sequence: Int
    public let previousCommitSHA256: String
    public let generationIdentifier: String
    public let itemIdentifier: String
    public let itemSHA256: String
    public let resultPath: String
    public let resultFileSHA256: String
    public let resultDigest: String
    public let acceptedAt: String
    public let brokerProtocol: SandboxBrokerProtocolBinding

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case sandboxOnly = "sandbox_only"
        case sequence
        case previousCommitSHA256 = "previous_commit_sha256"
        case generationIdentifier = "generation_id"
        case itemIdentifier = "item_id"
        case itemSHA256 = "item_sha256"
        case resultPath = "result_path"
        case resultFileSHA256 = "result_file_sha256"
        case resultDigest = "result_digest"
        case acceptedAt = "accepted_at"
        case brokerProtocol = "broker_protocol"
    }
}

public struct SandboxBrokerHead: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let protocolName: String
    public let sandboxOnly: Bool
    public let sequence: Int
    public let commitSHA256: String
    public let commitPath: String
    public let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case protocolName = "protocol"
        case sandboxOnly = "sandbox_only"
        case sequence
        case commitSHA256 = "commit_sha256"
        case commitPath = "commit_path"
        case updatedAt = "updated_at"
    }
}

public actor SandboxResultBroker {
    public static let protocolName = "osrs-capture-broker-v4"
    private static let zeroDigest = String(repeating: "0", count: 64)

    static func javaScriptRoundedInteger(_ value: Double) -> Int {
        Int(floor(value + 0.5))
    }

    private struct State {
        let head: SandboxBrokerHead?
        let commitsByItem: [String: (SandboxAcceptedResultCommit, EvidenceReference)]
    }

    private struct SemanticRecoveryAction {
        let role: String
        let captureIdentifier: String
    }

    private let root: URL
    private let hostEvidenceRoot: URL?
    private var cachedState: State?
    private var fullStateLoadCount = 0

    public init(root: URL, hostEvidenceRoot: URL? = nil) {
        self.root = root
        self.hostEvidenceRoot = hostEvidenceRoot
    }

    public func acceptedItemHashes() throws -> [String: String] {
        try currentState().commitsByItem.mapValues { $0.0.itemSHA256 }
    }

    public func accept(
        generationIdentifier: String,
        item: QueueItem,
        artifactRoot: String,
        resultPath: String,
        resultFileSHA256: String,
        resultDigest: String
    ) throws -> EvidenceReference {
        try validateResult(
            generationIdentifier: generationIdentifier,
            item: item,
            artifactRoot: artifactRoot,
            resultPath: resultPath,
            resultFileSHA256: resultFileSHA256,
            resultDigest: resultDigest
        )

        let state = try currentState()
        if let existing = state.commitsByItem[item.id] {
            guard existing.0.itemSHA256 == item.itemSHA256,
                  existing.0.resultPath == resultPath,
                  existing.0.resultFileSHA256 == resultFileSHA256,
                  existing.0.resultDigest == resultDigest else {
                throw AdapterError.queueRejected("BROKER_IDEMPOTENCY_COLLISION:\(item.id)")
            }
            return existing.1
        }

        let predecessor = SandboxBrokerPredecessor(
            sequence: state.head?.sequence ?? 0,
            commitSHA256: state.head?.commitSHA256 ?? Self.zeroDigest
        )
        let idempotencyKey = try CanonicalJSON.sha256([
            "generation_id": generationIdentifier,
            "item_id": item.id,
            "item_sha256": item.itemSHA256,
            "result_digest": resultDigest
        ])
        let commit = SandboxAcceptedResultCommit(
            schemaVersion: 1,
            sandboxOnly: true,
            sequence: predecessor.sequence + 1,
            previousCommitSHA256: predecessor.commitSHA256,
            generationIdentifier: generationIdentifier,
            itemIdentifier: item.id,
            itemSHA256: item.itemSHA256,
            resultPath: resultPath,
            resultFileSHA256: resultFileSHA256,
            resultDigest: resultDigest,
            acceptedAt: AdapterClock.now(),
            brokerProtocol: SandboxBrokerProtocolBinding(
                protocolName: Self.protocolName,
                idempotencyKey: idempotencyKey,
                expectedPredecessor: predecessor
            )
        )
        let writtenReference = try EvidenceStore(root: root).writeImmutable(
            commit,
            relativePath: String(
                format: "commits/%06d-%@-%@.json",
                commit.sequence,
                generationIdentifier,
                item.id
            )
        )
        let reference = EvidenceReference(
            path: URL(fileURLWithPath: writtenReference.path)
                .resolvingSymlinksInPath().path,
            sha256: writtenReference.sha256
        )
        let head = SandboxBrokerHead(
            schemaVersion: 1,
            protocolName: Self.protocolName,
            sandboxOnly: true,
            sequence: commit.sequence,
            commitSHA256: reference.sha256,
            commitPath: reference.path,
            updatedAt: AdapterClock.now()
        )
        try writeHead(head)

        try validatePostAccept(commit: commit, reference: reference, head: head)
        var commitsByItem = state.commitsByItem
        commitsByItem[item.id] = (commit, reference)
        cachedState = State(head: head, commitsByItem: commitsByItem)
        return reference
    }

    func fullStateLoadCountForTesting() -> Int {
        fullStateLoadCount
    }

    private func currentState() throws -> State {
        if let cachedState {
            try validateCachedState(cachedState)
            return cachedState
        }
        let state = try loadState()
        cachedState = state
        return state
    }

    private func loadState() throws -> State {
        fullStateLoadCount += 1
        let fileManager = FileManager.default
        let commitsRoot = root.appendingPathComponent("commits", isDirectory: true)
        let headPath = root.appendingPathComponent("HEAD.json")
        let commitURLs = try fileManager.fileExists(atPath: commitsRoot.path)
            ? fileManager.contentsOfDirectory(
                at: commitsRoot,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            : []

        guard fileManager.fileExists(atPath: headPath.path) else {
            guard commitURLs.isEmpty else {
                throw AdapterError.queueRejected("BROKER_HEAD_MISSING_WITH_COMMITS")
            }
            return State(head: nil, commitsByItem: [:])
        }
        let headData = try Data(contentsOf: headPath, options: .mappedIfSafe)
        let head = try JSONDecoder().decode(SandboxBrokerHead.self, from: headData)
        guard head.schemaVersion == 1,
              head.protocolName == Self.protocolName,
              head.sandboxOnly,
              head.sequence == commitURLs.count else {
            throw AdapterError.queueRejected("BROKER_HEAD_INVALID")
        }

        var previousDigest = Self.zeroDigest
        var commitsByItem: [String: (SandboxAcceptedResultCommit, EvidenceReference)] = [:]
        for (index, url) in commitURLs.enumerated() {
            try requireImmutableRegularFile(url, expectedSHA256: nil)
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let digest = AdapterHashing.sha256(data)
            let commit = try JSONDecoder().decode(SandboxAcceptedResultCommit.self, from: data)
            guard commit.schemaVersion == 1,
                  commit.sandboxOnly,
                  commit.sequence == index + 1,
                  commit.previousCommitSHA256 == previousDigest,
                  commit.brokerProtocol.protocolName == Self.protocolName,
                  commit.brokerProtocol.expectedPredecessor.sequence == index,
                  commit.brokerProtocol.expectedPredecessor.commitSHA256 == previousDigest else {
                throw AdapterError.queueRejected("BROKER_COMMIT_CHAIN_INVALID:\(url.lastPathComponent)")
            }
            guard commitsByItem[commit.itemIdentifier] == nil else {
                throw AdapterError.queueRejected("BROKER_DUPLICATE_ACCEPTED_ITEM:\(commit.itemIdentifier)")
            }
            commitsByItem[commit.itemIdentifier] = (
                commit,
                EvidenceReference(
                    path: url.resolvingSymlinksInPath().path,
                    sha256: digest
                )
            )
            previousDigest = digest
        }
        let recordedCommitPath = URL(fileURLWithPath: head.commitPath)
            .resolvingSymlinksInPath().path
        let observedCommitPath = commitURLs.last?.resolvingSymlinksInPath().path
        guard head.commitSHA256 == previousDigest,
              recordedCommitPath == observedCommitPath else {
            throw AdapterError.queueRejected("BROKER_HEAD_COMMIT_MISMATCH")
        }
        return State(head: head, commitsByItem: commitsByItem)
    }

    private func validateCachedState(_ state: State) throws {
        let fileManager = FileManager.default
        let commitsRoot = root.appendingPathComponent("commits", isDirectory: true)
        let headPath = root.appendingPathComponent("HEAD.json")
        let commitCount = try fileManager.fileExists(atPath: commitsRoot.path)
            ? fileManager.contentsOfDirectory(
                at: commitsRoot,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension == "json" }.count
            : 0

        guard let expectedHead = state.head else {
            guard !fileManager.fileExists(atPath: headPath.path), commitCount == 0 else {
                throw AdapterError.queueRejected("BROKER_CACHED_STATE_DIVERGED")
            }
            return
        }
        guard fileManager.fileExists(atPath: headPath.path),
              commitCount == expectedHead.sequence else {
            throw AdapterError.queueRejected("BROKER_CACHED_STATE_DIVERGED")
        }
        let headData = try Data(contentsOf: headPath, options: .mappedIfSafe)
        let observedHead = try JSONDecoder().decode(SandboxBrokerHead.self, from: headData)
        guard observedHead == expectedHead,
              let last = state.commitsByItem.values.first(where: {
                  $0.1.path == expectedHead.commitPath
              }) else {
            throw AdapterError.queueRejected("BROKER_CACHED_STATE_DIVERGED")
        }
        try requireImmutableRegularFile(
            URL(fileURLWithPath: last.1.path),
            expectedSHA256: last.1.sha256
        )
    }

    private func validatePostAccept(
        commit: SandboxAcceptedResultCommit,
        reference: EvidenceReference,
        head: SandboxBrokerHead
    ) throws {
        let headPath = root.appendingPathComponent("HEAD.json")
        let headData = try Data(contentsOf: headPath, options: .mappedIfSafe)
        let observedHead = try JSONDecoder().decode(SandboxBrokerHead.self, from: headData)
        let commitURL = URL(fileURLWithPath: reference.path)
        try requireImmutableRegularFile(commitURL, expectedSHA256: reference.sha256)
        let commitData = try Data(contentsOf: commitURL, options: .mappedIfSafe)
        let observedCommit = try JSONDecoder().decode(
            SandboxAcceptedResultCommit.self,
            from: commitData
        )
        guard observedHead == head,
              observedCommit == commit,
              commit.previousCommitSHA256 == commit.brokerProtocol.expectedPredecessor.commitSHA256,
              commit.sequence == commit.brokerProtocol.expectedPredecessor.sequence + 1 else {
            throw AdapterError.queueRejected("BROKER_POST_ACCEPT_READBACK_FAILED")
        }
    }

    private func validateResult(
        generationIdentifier: String,
        item: QueueItem,
        artifactRoot: String,
        resultPath: String,
        resultFileSHA256: String,
        resultDigest: String
    ) throws {
        let expected = URL(fileURLWithPath: artifactRoot)
            .appendingPathComponent("worker")
            .appendingPathComponent(generationIdentifier)
            .appendingPathComponent("\(item.id).json")
            .standardizedFileURL
        let resultURL = URL(fileURLWithPath: resultPath).standardizedFileURL
        guard resultURL.path == expected.path else {
            throw AdapterError.queueRejected("RESULT_PATH_MISMATCH")
        }
        try requireImmutableRegularFile(resultURL, expectedSHA256: resultFileSHA256)
        let data = try Data(contentsOf: resultURL, options: .mappedIfSafe)
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              raw["generation_id"] as? String == generationIdentifier,
              raw["item_id"] as? String == item.id,
              raw["item_sha256"] as? String == item.itemSHA256,
              raw["result_digest"] as? String == resultDigest else {
            throw AdapterError.queueRejected("RESULT_IDENTITY_INVALID")
        }
        if item.kind == "semantic_map_capture" {
            try validateSemanticResult(
                raw,
                item: item,
                artifactRoot: artifactRoot
            )
        } else {
            guard raw["schema_version"] as? Int == 1,
                  let evidence = raw["evidence"] as? [[String: Any]],
                  !evidence.isEmpty else {
                throw AdapterError.queueRejected("RESULT_IDENTITY_INVALID")
            }
            for entry in evidence {
                if let capture = entry["capture"] as? [String: Any] {
                    try validateCapture(capture, artifactRoot: artifactRoot)
                }
                if let input = entry["input_evidence"] as? [String: Any] {
                    try validateReference(
                        path: input["path"] as? String,
                        sha256: input["sha256"] as? String,
                        artifactRoot: artifactRoot,
                        error: "INPUT_EVIDENCE_INVALID"
                    )
                }
            }
        }
        guard try CanonicalJSON.sha256(
            jsonObjectData: data,
            removingTopLevelKey: "result_digest"
        ) == resultDigest else {
            throw AdapterError.queueRejected("RESULT_DIGEST_MISMATCH")
        }
    }

    private func validateSemanticResult(
        _ raw: [String: Any],
        item: QueueItem,
        artifactRoot: String
    ) throws {
        guard raw["schema_version"] as? Int == 2,
              raw["execution_profile"] as? String == QueueExecutionProfile.semanticMapCaptureV1.rawValue,
              let requested = raw["requested_work"] as? [String: Any],
              requested["surface"] as? String == item.surface?.rawValue,
              number(requested["zoom_percent"]) == item.zoomPercent,
              requested["criterion_family"] as? String == item.criterionFamily?.rawValue,
              requested["restore_after_capture"] as? Bool == item.restoreAfterCapture,
              let target = raw["target_identity"] as? [String: Any],
              target["bundle_identifier"] as? String == osrsTargetBundleIdentifier,
              let processIdentifier = number(target["process_identifier"]),
              processIdentifier > 0,
              let windowIdentifier = number(target["window_identifier"]),
              windowIdentifier > 0 else {
            throw AdapterError.queueRejected("SEMANTIC_RESULT_IDENTITY_INVALID")
        }
        try validateSemanticProductionRequestedWork(requested, item: item)

        guard let surface = raw["surface_proof"] as? [String: Any],
              surface["requested_surface"] as? String == item.surface?.rawValue,
              let readyGate = surface["ready_gate"] as? [String: Any],
              semanticGatePassed(readyGate, item: item),
              let option = surface["option_localization"] as? [String: Any],
              option["target"] as? String == "SEMANTIC_SURFACE_OPTION:\(item.surface?.rawValue ?? "")",
              option["exactly_one_target"] as? Bool == true,
              let optionCorrelation = number(option["normalized_correlation"]),
              optionCorrelation >= 0.72,
              let secondCorrelation = number(option["distinct_second_correlation"]),
              optionCorrelation - secondCorrelation >= 0.08,
              let selectorCapture = surface["selector_capture"] as? [String: Any],
              let optionCapture = surface["option_capture"] as? [String: Any],
              let navigation = surface["selector_navigation"] as? [String: Any],
              let navigationRequired = navigation["required"] as? Bool,
              let navigationMaximum = integer(navigation["maximum_drags"]),
              let surfaceScrollbarDrags = integer(navigation["drags"]),
              let navigationTransitions = navigation["transitions"] as? [[String: Any]],
              let readyCapture = surface["ready_capture"] as? [String: Any] else {
            throw AdapterError.queueRejected("SEMANTIC_SURFACE_PROOF_INVALID")
        }
        let expectedDragLimit = semanticSurfaceDragLimit(item)
        guard navigationRequired == (expectedDragLimit > 0),
              navigationMaximum == expectedDragLimit,
              navigationTransitions.count == surfaceScrollbarDrags,
              surfaceScrollbarDrags == expectedDragLimit,
              (expectedDragLimit == 0
                ? navigation["mode"] is NSNull && navigation["anchor"] is NSNull
                : navigation["mode"] as? String == "scrollbar_drag"
                    && semanticNavigationAnchorAllowed(navigation["anchor"] as? String, item: item)) else {
            throw AdapterError.queueRejected("SEMANTIC_SELECTOR_NAVIGATION_INVALID")
        }
        try validateSemanticCapture(
            selectorCapture,
            target: target,
            artifactRoot: artifactRoot
        )
        try validateSemanticCapture(optionCapture, target: target, artifactRoot: artifactRoot)
        try validateSemanticCapture(readyCapture, target: target, artifactRoot: artifactRoot)
        var navigationCaptureIdentifier = selectorCapture["captureIdentifier"] as? String
        for (index, transition) in navigationTransitions.enumerated() {
            guard integer(transition["ordinal"]) == index + 1,
                  transition["mode"] as? String == "scrollbar_drag",
                  let transitionAnchor = transition["anchor"] as? String,
                  semanticNavigationAnchorAllowed(transitionAnchor, item: item),
                  let before = transition["before_capture"] as? [String: Any],
                  let after = transition["after_capture"] as? [String: Any],
                  let localization = transition["scrollbar_localization"] as? [String: Any],
                  let postDragProof = transition["post_drag_proof"] as? [String: Any],
                  let vector = transition["vector"] as? [String: Any],
                  semanticSelectorScrollbarProofAccepted(
                    localization,
                    anchor: item.realmID == nil ? "top" : "current",
                    item: item
                  ),
                  semanticSelectorScrollbarProofAccepted(postDragProof, anchor: transitionAnchor, item: item),
                  semanticSelectorScrollbarVectorAccepted(
                    vector,
                    anchor: transitionAnchor,
                    localization: localization,
                    item: item
                  ),
                  before["captureIdentifier"] as? String == navigationCaptureIdentifier,
                  before["pngSHA256"] as? String != after["pngSHA256"] as? String else {
                throw AdapterError.queueRejected("SEMANTIC_SELECTOR_NAVIGATION_INVALID")
            }
            try validateSemanticCapture(before, target: target, artifactRoot: artifactRoot)
            try validateSemanticCapture(after, target: target, artifactRoot: artifactRoot)
            navigationCaptureIdentifier = after["captureIdentifier"] as? String
        }
        guard optionCapture["captureIdentifier"] as? String == navigationCaptureIdentifier else {
            throw AdapterError.queueRejected("SEMANTIC_SELECTOR_NAVIGATION_INVALID")
        }
        guard semanticProductionOptionBindingPassed(
            option,
            navigation: navigation,
            transitions: navigationTransitions,
            item: item
        ) else {
            throw AdapterError.queueRejected("SEMANTIC_PRODUCTION_OPTION_BINDING_INVALID")
        }

        guard let zoom = raw["zoom_proof"] as? [String: Any],
              number(zoom["requested_zoom_percent"]) == item.zoomPercent,
              number(zoom["observed_zoom_percent"]) == item.zoomPercent,
              let minimum = zoom["minimum"] as? [String: Any],
              let minusClicks = integer(minimum["clicks"]),
              minusClicks >= 2, minusClicks <= 8,
              let noTransitions = integer(minimum["consecutive_no_transition_clicks"]),
              noTransitions == 2,
              let ascentClicks = integer(zoom["ascent_clicks"]),
              ascentClicks == semanticZoomIndex(item.zoomPercent),
              let transitions = zoom["transitions"] as? [[String: Any]],
              transitions.count == minusClicks + ascentClicks else {
            throw AdapterError.queueRejected("SEMANTIC_ZOOM_PROOF_INVALID")
        }
        for (index, transition) in transitions.enumerated() {
            guard let direction = transition["direction"] as? String,
                  let difference = number(transition["mean_abs_difference"]),
                  let scaleTransition = transition["scale_transition"] as? Bool,
                  let before = transition["before_capture"] as? [String: Any],
                  let after = transition["after_capture"] as? [String: Any] else {
                throw AdapterError.queueRejected("SEMANTIC_ZOOM_TRANSITION_INVALID")
            }
            if index < minusClicks {
                guard direction == "minus",
                      scaleTransition == (difference >= 1.25) else {
                    throw AdapterError.queueRejected("SEMANTIC_ZOOM_MINIMUM_UNPROVEN")
                }
            } else {
                let ascentIndex = index - minusClicks
                let expectedZoom = [50.0, 75.0, 100.0, 200.0][ascentIndex]
                let denseTransition = difference >= 1.25
                let sparseTransition = semanticSparseZoomScaleProofPassed(
                    transition,
                    before: before,
                    after: after,
                    item: item
                )
                guard direction == "plus",
                      denseTransition || sparseTransition,
                      scaleTransition,
                      number(transition["observed_zoom_percent"]) == expectedZoom else {
                    throw AdapterError.queueRejected("SEMANTIC_ZOOM_ASCENT_UNPROVEN")
                }
            }
            try validateSemanticCapture(before, target: target, artifactRoot: artifactRoot)
            try validateSemanticCapture(after, target: target, artifactRoot: artifactRoot)
        }
        guard transitions.prefix(minusClicks).suffix(2).allSatisfy({
            $0["direction"] as? String == "minus"
                && number($0["mean_abs_difference"]).map { $0 < 1.25 } == true
                && $0["scale_transition"] as? Bool == false
        }) else {
            throw AdapterError.queueRejected("SEMANTIC_ZOOM_MINIMUM_UNPROVEN")
        }

        if item.plannerVersion == "native-realm-coverage-planner-v8" {
            try validateBoundedAnchorNativeCoverageResult(
                raw,
                item: item,
                target: target,
                artifactRoot: artifactRoot,
                surfaceScrollbarDrags: surfaceScrollbarDrags,
                minusClicks: minusClicks,
                ascentClicks: ascentClicks
            )
            return
        }
        if [
            "native-realm-coverage-planner-v3",
            "native-realm-coverage-planner-v4",
            "native-realm-coverage-planner-v5",
            "native-realm-coverage-planner-v6",
            "native-realm-coverage-planner-v7",
            "native-realm-coverage-planner-v9",
            "native-realm-coverage-planner-v10",
            "native-realm-coverage-planner-v11",
            "native-realm-coverage-planner-v12",
            "native-realm-coverage-planner-v13",
            "native-realm-coverage-planner-v14"
        ].contains(item.plannerVersion ?? "") {
            try validateResetRelativeNativeCoverageResult(
                raw,
                item: item,
                target: target,
                artifactRoot: artifactRoot,
                surfaceScrollbarDrags: surfaceScrollbarDrags,
                minusClicks: minusClicks,
                ascentClicks: ascentClicks
            )
            return
        }
        if item.plannerVersion == "native-realm-coverage-planner-v2" {
            try validateNativeCoverageResult(
                raw,
                item: item,
                target: target,
                artifactRoot: artifactRoot,
                surfaceScrollbarDrags: surfaceScrollbarDrags,
                minusClicks: minusClicks,
                ascentClicks: ascentClicks
            )
            return
        }

        guard let pan = raw["pan_proof"] as? [String: Any],
              pan["criterion_family"] as? String == item.criterionFamily?.rawValue,
              let vector = pan["vector"] as? [String: Any],
              semanticVectorMatches(vector, family: item.criterionFamily, reversed: false),
              let preFrame = pan["pre_frame"] as? [String: Any],
              let postFrame = pan["post_frame"] as? [String: Any],
              let freshFrame = pan["fresh_frame"] as? [String: Any],
              let preGate = pan["pre_gate"] as? [String: Any],
              let postGate = pan["post_gate"] as? [String: Any],
              let freshGate = pan["fresh_gate"] as? [String: Any],
              semanticGatePassed(preGate, item: item),
              semanticGatePassed(postGate, item: item),
              semanticGatePassed(freshGate, item: item),
              let novelty = pan["novelty"] as? [String: Any],
              novelty["passed"] as? Bool == true,
              let prePost = number(novelty["pre_post_mean_abs"]), prePost >= 2.5,
              semanticSameFamilyPassed(novelty["same_family_mean_abs"]),
              let displacement = novelty["displacement"] as? [String: Any],
              displacement["delivered"] as? Bool == true,
              let magnitude = number(displacement["magnitude_cells"]), magnitude >= 2,
              semanticScaledNoveltyMatches(displacement, vector: vector),
              let extent = novelty["extent"] as? [String: Any],
              let contribution = number(extent["contribution_mean_abs"]), contribution >= 2 else {
            throw AdapterError.queueRejected("SEMANTIC_PAN_PROOF_INVALID")
        }
        for capture in [preFrame, postFrame, freshFrame] {
            try validateSemanticCapture(capture, target: target, artifactRoot: artifactRoot)
        }
        let captureIdentifiers = [preFrame, postFrame, freshFrame].compactMap {
            $0["captureIdentifier"] as? String
        }
        guard captureIdentifiers.count == 3,
              captureIdentifiers.allSatisfy({ !$0.isEmpty }),
              Set(captureIdentifiers).count == 3,
              preFrame["pngSHA256"] as? String != freshFrame["pngSHA256"] as? String else {
            throw AdapterError.queueRejected("SEMANTIC_FRESH_CAPTURE_UNPROVEN")
        }

        guard let restoration = raw["restoration_proof"] as? [String: Any],
              restoration["required"] as? Bool == item.restoreAfterCapture else {
            throw AdapterError.queueRejected("SEMANTIC_RESTORATION_PROOF_INVALID")
        }
        if item.restoreAfterCapture == true {
            guard restoration["delivered"] as? Bool == true,
                  let restorationResidual = number(restoration["displacement_cells"]),
                  restorationResidual <= 1,
                  let ready = restoration["ready"] as? [String: Any],
                  semanticGatePassed(ready, item: item),
                  let frame = restoration["frame"] as? [String: Any],
                  let inverse = restoration["inverse_vector"] as? [String: Any],
                  semanticVectorMatches(
                    inverse,
                    family: item.criterionFamily,
                    reversed: true,
                    expectedForwardDisplacement: displacement["expected_displacement"] as? [String: Any]
                  ),
                  semanticRestorationMeasurementMatches(inverse, restoration: restoration) else {
                throw AdapterError.queueRejected("SEMANTIC_RESTORATION_UNPROVEN")
            }
            try validateSemanticCapture(frame, target: target, artifactRoot: artifactRoot)
        } else if restoration["delivered"] as? Bool != false {
            throw AdapterError.queueRejected("SEMANTIC_UNREQUESTED_RESTORATION")
        }

        let resetRequired = semanticSurfaceResetRequired(item)
        guard let surfaceReset = raw["surface_reset_proof"] as? [String: Any],
              surfaceReset["required"] as? Bool == resetRequired else {
            throw AdapterError.queueRejected("SEMANTIC_SURFACE_RESET_PROOF_INVALID")
        }
        var resetActionCaptures: (String, String, String)?
        if resetRequired {
            let restorationFrame = restoration["frame"] as? [String: Any]
            guard surfaceReset["delivered"] as? Bool == true,
                  surfaceReset["requested_surface"] as? String == SemanticMapSurface.gielinorSurface.rawValue,
                  let sourceCapture = surfaceReset["source_capture"] as? [String: Any],
                  let resetSelectorCapture = surfaceReset["selector_capture"] as? [String: Any],
                  let resetPostDragCapture = surfaceReset["post_drag_capture"] as? [String: Any],
                  let resetReadyCapture = surfaceReset["ready_capture"] as? [String: Any],
                  let resetLocalization = surfaceReset["scrollbar_localization"] as? [String: Any],
                  let resetVector = surfaceReset["vector"] as? [String: Any],
                  let resetPostProof = surfaceReset["post_drag_proof"] as? [String: Any],
                  let resetOption = surfaceReset["option_localization"] as? [String: Any],
                  resetOption["target"] as? String == "SEMANTIC_SURFACE_OPTION:Gielinor Surface",
                  resetOption["exactly_one_target"] as? Bool == true,
                  let resetOptionCorrelation = number(resetOption["normalized_correlation"]),
                  resetOptionCorrelation >= 0.72,
                  let resetSecondCorrelation = number(resetOption["distinct_second_correlation"]),
                  resetOptionCorrelation - resetSecondCorrelation >= 0.08,
                  semanticScrollbarProofPassed(resetLocalization, anchor: "bottom"),
                  semanticScrollbarProofPassed(resetPostProof, anchor: "top"),
                  semanticScrollbarVectorMatches(resetVector, anchor: "top", localization: resetLocalization),
                  resetSelectorCapture["pngSHA256"] as? String != resetPostDragCapture["pngSHA256"] as? String,
                  let resetReady = surfaceReset["ready_gate"] as? [String: Any],
                  semanticGatePassed(resetReady, surface: .gielinorSurface),
                  sourceCapture["captureIdentifier"] as? String
                    == restorationFrame?["captureIdentifier"] as? String,
                  let sourceCaptureIdentifier = sourceCapture["captureIdentifier"] as? String,
                  let resetSelectorCaptureIdentifier = resetSelectorCapture["captureIdentifier"] as? String,
                  let resetPostDragCaptureIdentifier = resetPostDragCapture["captureIdentifier"] as? String else {
                throw AdapterError.queueRejected("SEMANTIC_SURFACE_RESET_UNPROVEN")
            }
            for capture in [sourceCapture, resetSelectorCapture, resetPostDragCapture, resetReadyCapture] {
                try validateSemanticCapture(capture, target: target, artifactRoot: artifactRoot)
            }
            resetActionCaptures = (
                sourceCaptureIdentifier,
                resetSelectorCaptureIdentifier,
                resetPostDragCaptureIdentifier
            )
        } else if surfaceReset["delivered"] as? Bool != false {
            throw AdapterError.queueRejected("SEMANTIC_UNREQUESTED_SURFACE_RESET")
        }

        guard let recoveryHistory = raw["recovery_history"] as? [[String: Any]] else {
            throw AdapterError.queueRejected("SEMANTIC_RECOVERY_HISTORY_INVALID")
        }
        let recoveryActions = try validateSemanticRecoveryHistory(
            recoveryHistory,
            target: target,
            artifactRoot: artifactRoot
        )
        guard let actions = raw["action_history"] as? [[String: Any]],
                  semanticActionRolesMatch(
                    actions,
                    recoveryActionRoles: recoveryActions.map(\.role),
                    surfaceScrollbarDrags: surfaceScrollbarDrags,
                    minusClicks: minusClicks,
                ascentClicks: ascentClicks,
                restored: item.restoreAfterCapture == true,
                surfaceReset: resetRequired
              ),
              let mapCrop = raw["map_crop"] as? [String: Any],
              integer(mapCrop["width"]) == 516,
              integer(mapCrop["height"]) == 641,
              let performance = raw["performance"] as? [String: Any],
              let elapsed = number(performance["elapsed_milliseconds"]),
              elapsed >= 0, elapsed < 120_000,
              let inputToPost = number(performance["input_to_qualified_post_capture_milliseconds"]),
              inputToPost >= 0, inputToPost < 120_000,
              let selectorDuration = number(performance["selector_open_to_surface_qualified_milliseconds"]),
              selectorDuration >= 0,
              (!resetRequired || selectorDuration <= 3_000),
              integer(performance["hard_deadline_milliseconds"]) == 120_000 else {
            throw AdapterError.queueRejected("SEMANTIC_RESULT_STRUCTURE_INVALID")
        }
        guard let panAction = actions.first(where: {
            $0["role"] as? String == SemanticActionRole.pan.rawValue
        }), semanticActionMatchesVector(panAction, vector: vector) else {
            throw AdapterError.queueRejected("SEMANTIC_PAN_ACTION_BINDING_INVALID")
        }
        var actionCaptureIdentifiers = Set<String>()
        for (index, action) in actions.enumerated() {
            guard let captureIdentifier = action["capture_id"] as? String,
                  !captureIdentifier.isEmpty,
                  actionCaptureIdentifiers.insert(captureIdentifier).inserted,
                  let input = action["input_evidence"] as? [String: Any] else {
                throw AdapterError.queueRejected("SEMANTIC_INPUT_EVIDENCE_INVALID")
            }
            try validateReference(
                path: input["path"] as? String,
                sha256: input["sha256"] as? String,
                artifactRoot: artifactRoot,
                error: "SEMANTIC_INPUT_EVIDENCE_INVALID"
            )
            if index < recoveryActions.count {
                guard captureIdentifier == recoveryActions[index].captureIdentifier else {
                    throw AdapterError.queueRejected("SEMANTIC_RECOVERY_ACTION_BINDING_INVALID")
                }
                continue
            }
            let semanticIndex = index - recoveryActions.count
            if semanticIndex > 0 && semanticIndex <= surfaceScrollbarDrags {
                let transitionBefore = navigationTransitions[semanticIndex - 1]["before_capture"] as? [String: Any]
                let expectedCaptureIdentifier = transitionBefore?["captureIdentifier"] as? String
                guard captureIdentifier == expectedCaptureIdentifier else {
                    throw AdapterError.queueRejected("SEMANTIC_SELECTOR_NAVIGATION_ACTION_BINDING_INVALID")
                }
            } else if semanticIndex == surfaceScrollbarDrags + 1 {
                guard captureIdentifier == optionCapture["captureIdentifier"] as? String else {
                    throw AdapterError.queueRejected("SEMANTIC_SELECTOR_NAVIGATION_ACTION_BINDING_INVALID")
                }
            }
        }
        if let resetActionCaptures {
            let resetStartIndex = actions.count - 3
            guard resetStartIndex >= 0,
                  actions[resetStartIndex]["capture_id"] as? String == resetActionCaptures.0,
                  actions[resetStartIndex + 1]["capture_id"] as? String == resetActionCaptures.1,
                  actions[resetStartIndex + 2]["capture_id"] as? String == resetActionCaptures.2 else {
                throw AdapterError.queueRejected("SEMANTIC_SURFACE_RESET_ACTION_BINDING_INVALID")
            }
        }
        try validateReference(
            path: mapCrop["path"] as? String,
            sha256: mapCrop["sha256"] as? String,
            artifactRoot: artifactRoot,
            error: "SEMANTIC_MAP_CROP_INVALID"
        )
    }

    private func validateResetRelativeNativeCoverageResult(
        _ raw: [String: Any],
        item: QueueItem,
        target: [String: Any],
        artifactRoot: String,
        surfaceScrollbarDrags: Int,
        minusClicks: Int,
        ascentClicks: Int
    ) throws {
        guard item.restoreAfterCapture == false,
              let reset = raw["coverage_reset_proof"] as? [String: Any] else {
            throw AdapterError.queueRejected("NATIVE_REALM_COVERAGE_RESET_INVALID")
        }
        let reopenReset = item.plannerVersion == "native-realm-coverage-planner-v9"
            || item.plannerVersion == "native-realm-coverage-planner-v10"
            || item.plannerVersion == "native-realm-coverage-planner-v11"
            || item.plannerVersion == "native-realm-coverage-planner-v12"
            || item.plannerVersion == "native-realm-coverage-planner-v13"
            || item.plannerVersion == "native-realm-coverage-planner-v14"
        var resetDrags = 0
        var resetActionCaptureIdentifiers: (close: String, reopen: String, selector: String)?
        var resetCloseSourcePoint: (x: Double, y: Double)?
        if reopenReset {
            guard reset["mode"] as? String == "map_close_reopen",
                  let before = reset["before_close_capture"] as? [String: Any],
                  let localization = reset["close_localization"] as? [String: Any],
                  localization["target"] as? String == "SEMANTIC_MAP_CLOSE_CONTROL",
                  localization["exactly_one_target"] as? Bool == true,
                  let normalizedBox = localization["normalized_observed_bbox"] as? [String: Any],
                  number(normalizedBox["left"]) == 486,
                  number(normalizedBox["top"]) == 35,
                  number(normalizedBox["right"]) == 516,
                  number(normalizedBox["bottom"]) == 70,
                  let normalizedPoint = localization["normalized_click_point"] as? [String: Any],
                  number(normalizedPoint["x"]) == 500,
                  number(normalizedPoint["y"]) == 50,
                  let sourcePoint = localization["source_click_point"] as? [String: Any],
                  let sourceX = number(sourcePoint["x"]),
                  let sourceY = number(sourcePoint["y"]),
                  let closed = reset["closed_capture"] as? [String: Any],
                  let closedClassification = reset["closed_classification"] as? [String: Any],
                  closedClassification["recovery_state"] as? String == "GAMEPLAY_NO_MAP",
                  closedClassification["connection"] as? String == "CONNECTED",
                  closedClassification["committable"] as? Bool == false,
                  let reopened = reset["reopened_capture"] as? [String: Any],
                  let reopenedIdentifier = reopened["captureIdentifier"] as? String,
                  let reopenedGate = reset["reopened_gate"] as? [String: Any],
                  semanticGatePassed(reopenedGate, surface: .gielinorSurface),
                  let beforeIdentifier = before["captureIdentifier"] as? String,
                  let closedIdentifier = closed["captureIdentifier"] as? String,
                  beforeIdentifier != closedIdentifier,
                  before["pngSHA256"] as? String != closed["pngSHA256"] as? String,
                  closed["pngSHA256"] as? String != reopened["pngSHA256"] as? String else {
                throw AdapterError.queueRejected("NATIVE_REALM_COVERAGE_RESET_INVALID")
            }
            try validateSemanticCapture(before, target: target, artifactRoot: artifactRoot)
            try validateSemanticCapture(closed, target: target, artifactRoot: artifactRoot)
            try validateSemanticCapture(reopened, target: target, artifactRoot: artifactRoot)
            resetActionCaptureIdentifiers = (
                beforeIdentifier,
                closedIdentifier,
                reopenedIdentifier
            )
            resetCloseSourcePoint = (sourceX, sourceY)
        } else {
            let resetSurface: SemanticMapSurface = item.surface == .gielinorSurface
                ? .ancientCavern
                : .gielinorSurface
            guard reset["reset_surface"] as? String == resetSurface.rawValue,
                  let resetSelector = reset["selector_capture"] as? [String: Any],
                  let resetOptionCapture = reset["option_capture"] as? [String: Any],
                  let resetReadyCapture = reset["ready_capture"] as? [String: Any],
                  let resetOption = reset["option_localization"] as? [String: Any],
                  resetOption["target"] as? String == "SEMANTIC_SURFACE_OPTION:\(resetSurface.rawValue)",
                  resetOption["exactly_one_target"] as? Bool == true,
                  let resetCorrelation = number(resetOption["normalized_correlation"]),
                  resetCorrelation >= 0.72,
                  let resetSecond = number(resetOption["distinct_second_correlation"]),
                  resetCorrelation - resetSecond >= 0.08,
                  let resetGate = reset["ready_gate"] as? [String: Any],
                  semanticGatePassed(resetGate, surface: resetSurface),
                  let resetNavigation = reset["selector_navigation"] as? [String: Any],
                  let resetRequired = resetNavigation["required"] as? Bool,
                  let resetMaximum = integer(resetNavigation["maximum_drags"]),
                  let parsedResetDrags = integer(resetNavigation["drags"]),
                  let resetTransitions = resetNavigation["transitions"] as? [[String: Any]],
                  resetMaximum == (resetRequired ? 1 : 0),
                  parsedResetDrags == (resetRequired ? 1 : 0),
                  resetTransitions.count == parsedResetDrags else {
                throw AdapterError.queueRejected("NATIVE_REALM_COVERAGE_RESET_INVALID")
            }
            resetDrags = parsedResetDrags
            for capture in [resetSelector, resetOptionCapture, resetReadyCapture] {
                try validateSemanticCapture(capture, target: target, artifactRoot: artifactRoot)
            }
            if let transition = resetTransitions.first {
                guard integer(transition["ordinal"]) == 1,
                      transition["mode"] as? String == "scrollbar_drag",
                      let before = transition["before_capture"] as? [String: Any],
                      let after = transition["after_capture"] as? [String: Any],
                      let localization = transition["scrollbar_localization"] as? [String: Any],
                      let post = transition["post_drag_proof"] as? [String: Any],
                      semanticScrollbarGeometryPassed(localization),
                      semanticScrollbarGeometryPassed(post),
                      let observed = post["normalized_observed_bbox"] as? [String: Any],
                      number(observed["top"]) == 543,
                      let vector = transition["vector"] as? [String: Any],
                      number(vector["target_thumb_top"]) == 543,
                      before["captureIdentifier"] as? String
                        == resetSelector["captureIdentifier"] as? String,
                      before["pngSHA256"] as? String != after["pngSHA256"] as? String,
                      resetOptionCapture["captureIdentifier"] as? String
                        == after["captureIdentifier"] as? String else {
                    throw AdapterError.queueRejected("NATIVE_REALM_COVERAGE_RESET_INVALID")
                }
                try validateSemanticCapture(before, target: target, artifactRoot: artifactRoot)
                try validateSemanticCapture(after, target: target, artifactRoot: artifactRoot)
            } else if resetOptionCapture["captureIdentifier"] as? String
                        != resetSelector["captureIdentifier"] as? String {
                throw AdapterError.queueRejected("NATIVE_REALM_COVERAGE_RESET_INVALID")
            }
        }

        guard let navigation = raw["coverage_navigation"] as? [String: Any],
              navigation["planner_version"] as? String == item.plannerVersion,
              navigation["mode"] as? String == (reopenReset ? "map_reopen_relative" : "reset_relative"),
              navigation["nonblack"] as? Bool == true,
              integer(navigation["target_tolerance_reference_pixels"]) == 10,
              let sourceCenter = navigation["source_center"] as? [String: Any],
              let resetCenter = item.coverageCell?.resetCenter,
              semanticCenter(sourceCenter, matches: resetCenter),
              let targetCenter = navigation["target_center"] as? [String: Any],
              semanticCenter(targetCenter, matches: item.captureCenter),
              let referenceDelta = navigation["reference_delta"] as? [String: Any],
              let deliveredDelta = navigation["delivered_reference_delta"] as? [String: Any],
              let expectedDelta = semanticResetRelativeCoverageDelta(item),
              integer(referenceDelta["dx"]) == expectedDelta.0,
              integer(referenceDelta["dy"]) == expectedDelta.1,
              integer(deliveredDelta["dx"]) == expectedDelta.0,
              integer(deliveredDelta["dy"]) == expectedDelta.1,
              let movement = navigation["movement"] as? [String: Any],
              let movementCount = integer(movement["action_count"]),
              let transitions = movement["transitions"] as? [[String: Any]],
              transitions.count == movementCount,
              movementCount == semanticResetRelativeCoveragePanCount(expectedDelta),
              let targetFrame = navigation["target_frame"] as? [String: Any],
              let freshFrame = navigation["fresh_frame"] as? [String: Any],
              let targetGate = navigation["target_gate"] as? [String: Any],
              let freshGate = navigation["fresh_gate"] as? [String: Any],
              semanticGatePassed(targetGate, item: item),
              semanticGatePassed(freshGate, item: item),
              !["native-realm-coverage-planner-v10", "native-realm-coverage-planner-v11", "native-realm-coverage-planner-v12", "native-realm-coverage-planner-v13", "native-realm-coverage-planner-v14"]
                .contains(item.plannerVersion ?? "")
                || semanticNativeCoverageContentProof(
                    navigation["target_content_proof"] as? [String: Any]
                ),
              !["native-realm-coverage-planner-v10", "native-realm-coverage-planner-v11", "native-realm-coverage-planner-v12", "native-realm-coverage-planner-v13", "native-realm-coverage-planner-v14"]
                .contains(item.plannerVersion ?? "")
                || semanticNativeCoverageContentProof(
                    navigation["fresh_content_proof"] as? [String: Any]
                ),
              let targetIdentifier = targetFrame["captureIdentifier"] as? String,
              let freshIdentifier = freshFrame["captureIdentifier"] as? String,
              !targetIdentifier.isEmpty,
              !freshIdentifier.isEmpty,
              targetIdentifier != freshIdentifier else {
            throw AdapterError.queueRejected("NATIVE_REALM_COVERAGE_RESULT_INVALID")
        }
        try validateSemanticCapture(targetFrame, target: target, artifactRoot: artifactRoot)
        try validateSemanticCapture(freshFrame, target: target, artifactRoot: artifactRoot)

        var deliveredDX = 0
        var deliveredDY = 0
        for (index, transition) in transitions.enumerated() {
            guard integer(transition["ordinal"]) == index + 1,
                  let before = transition["before_capture"] as? [String: Any],
                  let after = transition["after_capture"] as? [String: Any],
                  let vector = transition["vector"] as? [String: Any],
                  let delta = vector["reference_delta"] as? [String: Any],
                  let dx = integer(delta["dx"]),
                  let dy = integer(delta["dy"]),
                  semanticResetRelativeCoverageVector(
                    vector,
                    dx: dx,
                    dy: dy,
                    coverageCrop: item.coverageCell?.coverageCrop
                  ),
                  semanticResetRelativeCoverageMovementProof(
                    transition,
                    expectedDX: dx,
                    expectedDY: dy
                  ),
                  before["captureIdentifier"] as? String
                    != after["captureIdentifier"] as? String else {
                throw AdapterError.queueRejected("NATIVE_REALM_COVERAGE_MOVEMENT_INVALID")
            }
            deliveredDX += dx
            deliveredDY += dy
            try validateSemanticCapture(before, target: target, artifactRoot: artifactRoot)
            try validateSemanticCapture(after, target: target, artifactRoot: artifactRoot)
        }
        guard deliveredDX == expectedDelta.0, deliveredDY == expectedDelta.1 else {
            throw AdapterError.queueRejected("NATIVE_REALM_COVERAGE_VECTOR_SUM_INVALID")
        }

        guard let recoveryHistory = raw["recovery_history"] as? [[String: Any]],
              let actions = raw["action_history"] as? [[String: Any]],
              let mapCrop = raw["map_crop"] as? [String: Any],
              semanticNativeCoverageMapCropMatches(mapCrop, item: item),
              let performance = raw["performance"] as? [String: Any],
              let elapsed = number(performance["elapsed_milliseconds"]),
              elapsed >= 0, elapsed < 120_000,
              integer(performance["hard_deadline_milliseconds"]) == 120_000 else {
            throw AdapterError.queueRejected("NATIVE_REALM_COVERAGE_STRUCTURE_INVALID")
        }
        let recoveryActions = try validateSemanticRecoveryHistory(
            recoveryHistory,
            target: target,
            artifactRoot: artifactRoot
        )
        var expectedRoles = recoveryActions.map(\.role)
        if reopenReset {
            expectedRoles.append(SemanticActionRole.coverageMapClose.rawValue)
            expectedRoles.append(SemanticActionRole.coverageMapReopen.rawValue)
        } else {
            expectedRoles.append(SemanticActionRole.coverageResetSelectorOpen.rawValue)
            expectedRoles.append(contentsOf: Array(
                repeating: SemanticActionRole.coverageResetScrollbarDrag.rawValue,
                count: resetDrags
            ))
            expectedRoles.append(SemanticActionRole.coverageResetOptionSelect.rawValue)
        }
        expectedRoles.append(SemanticActionRole.surfaceSelectorOpen.rawValue)
        expectedRoles.append(contentsOf: Array(
            repeating: SemanticActionRole.surfaceSelectorScrollbarDrag.rawValue,
            count: surfaceScrollbarDrags
        ))
        expectedRoles.append(SemanticActionRole.surfaceOptionSelect.rawValue)
        expectedRoles.append(contentsOf: Array(repeating: SemanticActionRole.zoomMinus.rawValue, count: minusClicks))
        expectedRoles.append(contentsOf: Array(repeating: SemanticActionRole.zoomPlus.rawValue, count: ascentClicks))
        expectedRoles.append(contentsOf: Array(repeating: SemanticActionRole.coveragePan.rawValue, count: movementCount))
        guard actions.compactMap({ $0["role"] as? String }) == expectedRoles else {
            throw AdapterError.queueRejected("NATIVE_REALM_COVERAGE_ACTION_ORDER_INVALID")
        }
        if let identifiers = resetActionCaptureIdentifiers,
           let point = resetCloseSourcePoint {
            let offset = recoveryActions.count
            guard actions[offset]["capture_id"] as? String == identifiers.close,
                  actions[offset + 1]["capture_id"] as? String == identifiers.reopen,
                  actions[offset + 2]["capture_id"] as? String == identifiers.selector,
                  let closeOperation = actions[offset]["operation"] as? [String: Any],
                  closeOperation["kind"] as? String == "click",
                  let closePoint = closeOperation["point"] as? [String: Any],
                  number(closePoint["x"]) == point.x,
                  number(closePoint["y"]) == point.y,
                  let reopenOperation = actions[offset + 1]["operation"] as? [String: Any],
                  Set(reopenOperation.keys) == Set(["kind"]),
                  reopenOperation["kind"] as? String == "open_world_map" else {
                throw AdapterError.queueRejected("NATIVE_REALM_COVERAGE_RESET_ACTION_BINDING_INVALID")
            }
        }
        var identifiers = Set<String>()
        for action in actions {
            guard let identifier = action["capture_id"] as? String,
                  !identifier.isEmpty,
                  identifiers.insert(identifier).inserted,
                  let input = action["input_evidence"] as? [String: Any] else {
                throw AdapterError.queueRejected("SEMANTIC_INPUT_EVIDENCE_INVALID")
            }
            try validateReference(
                path: input["path"] as? String,
                sha256: input["sha256"] as? String,
                artifactRoot: artifactRoot,
                error: "SEMANTIC_INPUT_EVIDENCE_INVALID"
            )
        }
        try validateReference(
            path: mapCrop["path"] as? String,
            sha256: mapCrop["sha256"] as? String,
            artifactRoot: artifactRoot,
            error: "SEMANTIC_MAP_CROP_INVALID"
        )
    }

    private func semanticNativeCoverageContentProof(_ proof: [String: Any]?) -> Bool {
        guard let proof,
              proof["passed"] as? Bool == true,
              let evidenceMode = proof["evidence_mode"] as? String,
              let informative = integer(proof["informative_pixel_count"]),
              informative >= 64,
              let chromatic = integer(proof["chromatic_pixel_count"]),
              integer(proof["minimum_informative_pixel_count"]) == 64,
              integer(proof["minimum_chromatic_pixel_count"]) == 8,
              integer(proof["interior_margin_pixels"]) == 2 else {
            return false
        }
        if evidenceMode == "native_crop_interior_content_v1" {
            return chromatic >= 8
        }
        guard evidenceMode == "native_crop_interior_content_v2",
              let structuralEdges = integer(proof["structural_edge_pixel_count"]),
              integer(proof["minimum_structural_edge_pixel_count"]) == 64,
              integer(proof["structural_edge_threshold"]) == 3 else {
            return false
        }
        return chromatic >= 8 || structuralEdges >= 64
    }

    private func validateBoundedAnchorNativeCoverageResult(
        _ raw: [String: Any],
        item: QueueItem,
        target: [String: Any],
        artifactRoot: String,
        surfaceScrollbarDrags: Int,
        minusClicks: Int,
        ascentClicks: Int
    ) throws {
        guard item.restoreAfterCapture == false,
              raw["coverage_reset_proof"] is NSNull,
              let navigation = raw["coverage_navigation"] as? [String: Any],
              navigation["planner_version"] as? String == item.plannerVersion,
              navigation["mode"] as? String == "bounded_anchor",
              navigation["nonblack"] as? Bool == true,
              integer(navigation["target_tolerance_reference_pixels"]) == 10,
              let sourceCenter = navigation["source_center"] as? [String: Any],
              let resetCenter = item.coverageCell?.resetCenter,
              semanticCenter(sourceCenter, matches: resetCenter),
              let targetCenter = navigation["target_center"] as? [String: Any],
              semanticCenter(targetCenter, matches: item.captureCenter),
              let referenceDelta = navigation["reference_delta"] as? [String: Any],
              let deliveredDelta = navigation["delivered_reference_delta"] as? [String: Any],
              let expectedDelta = semanticResetRelativeCoverageDelta(item),
              integer(referenceDelta["dx"]) == expectedDelta.0,
              integer(referenceDelta["dy"]) == expectedDelta.1,
              integer(deliveredDelta["dx"]) == expectedDelta.0,
              integer(deliveredDelta["dy"]) == expectedDelta.1,
              let anchor = navigation["anchor"] as? [String: Any],
              anchor["required"] as? Bool == true,
              let expectedAnchorAttempts = item.coverageCell?.anchorAttemptBudget,
              integer(anchor["attempt_budget"]) == expectedAnchorAttempts,
              integer(anchor["attempts"]) == expectedAnchorAttempts,
              integer(anchor["consecutive_no_transition_proofs"]) == 2,
              let anchorTransitions = anchor["transitions"] as? [[String: Any]],
              anchorTransitions.count == expectedAnchorAttempts,
              anchorTransitions.suffix(2).allSatisfy({
                $0["transitioned"] as? Bool == false
                    && number($0["mean_abs_difference"]).map { $0 < 1.25 } == true
              }),
              let movement = navigation["movement"] as? [String: Any],
              let movementCount = integer(movement["action_count"]),
              let transitions = movement["transitions"] as? [[String: Any]],
              transitions.count == movementCount,
              movementCount == semanticResetRelativeCoveragePanCount(expectedDelta),
              let targetFrame = navigation["target_frame"] as? [String: Any],
              let freshFrame = navigation["fresh_frame"] as? [String: Any],
              let targetGate = navigation["target_gate"] as? [String: Any],
              let freshGate = navigation["fresh_gate"] as? [String: Any],
              semanticGatePassed(targetGate, item: item),
              semanticGatePassed(freshGate, item: item),
              let targetIdentifier = targetFrame["captureIdentifier"] as? String,
              let freshIdentifier = freshFrame["captureIdentifier"] as? String,
              !targetIdentifier.isEmpty,
              !freshIdentifier.isEmpty,
              targetIdentifier != freshIdentifier else {
            throw AdapterError.queueRejected("NATIVE_REALM_COVERAGE_ANCHOR_RESULT_INVALID")
        }
        try validateSemanticCapture(targetFrame, target: target, artifactRoot: artifactRoot)
        try validateSemanticCapture(freshFrame, target: target, artifactRoot: artifactRoot)

        for (index, transition) in anchorTransitions.enumerated() {
            guard integer(transition["ordinal"]) == index + 1,
                  let before = transition["before_capture"] as? [String: Any],
                  let after = transition["after_capture"] as? [String: Any],
                  let vector = transition["vector"] as? [String: Any],
                  let difference = number(transition["mean_abs_difference"]),
                  difference >= 0,
                  transition["transitioned"] as? Bool == (difference >= 1.25),
                  semanticResetRelativeCoverageVector(
                    vector,
                    dx: 240,
                    dy: -400,
                    coverageCrop: item.coverageCell?.coverageCrop
                  ),
                  before["captureIdentifier"] as? String
                    != after["captureIdentifier"] as? String else {
                throw AdapterError.queueRejected("NATIVE_REALM_COVERAGE_ANCHOR_INVALID")
            }
            if index > 0 {
                guard let priorAfter = anchorTransitions[index - 1]["after_capture"]
                        as? [String: Any],
                      priorAfter["captureIdentifier"] as? String
                        == before["captureIdentifier"] as? String else {
                    throw AdapterError.queueRejected("NATIVE_REALM_COVERAGE_ANCHOR_CHAIN_INVALID")
                }
            }
            try validateSemanticCapture(before, target: target, artifactRoot: artifactRoot)
            try validateSemanticCapture(after, target: target, artifactRoot: artifactRoot)
        }

        var deliveredDX = 0
        var deliveredDY = 0
        for (index, transition) in transitions.enumerated() {
            guard integer(transition["ordinal"]) == index + 1,
                  let before = transition["before_capture"] as? [String: Any],
                  let after = transition["after_capture"] as? [String: Any],
                  let vector = transition["vector"] as? [String: Any],
                  let delta = vector["reference_delta"] as? [String: Any],
                  let dx = integer(delta["dx"]),
                  let dy = integer(delta["dy"]),
                  semanticResetRelativeCoverageVector(
                    vector,
                    dx: dx,
                    dy: dy,
                    coverageCrop: item.coverageCell?.coverageCrop
                  ),
                  semanticResetRelativeCoverageMovementProof(
                    transition,
                    expectedDX: dx,
                    expectedDY: dy
                  ),
                  before["captureIdentifier"] as? String
                    != after["captureIdentifier"] as? String else {
                throw AdapterError.queueRejected("NATIVE_REALM_COVERAGE_MOVEMENT_INVALID")
            }
            deliveredDX += dx
            deliveredDY += dy
            try validateSemanticCapture(before, target: target, artifactRoot: artifactRoot)
            try validateSemanticCapture(after, target: target, artifactRoot: artifactRoot)
        }
        guard deliveredDX == expectedDelta.0, deliveredDY == expectedDelta.1 else {
            throw AdapterError.queueRejected("NATIVE_REALM_COVERAGE_VECTOR_SUM_INVALID")
        }

        guard let recoveryHistory = raw["recovery_history"] as? [[String: Any]],
              let actions = raw["action_history"] as? [[String: Any]],
              let mapCrop = raw["map_crop"] as? [String: Any],
              semanticNativeCoverageMapCropMatches(mapCrop, item: item),
              let performance = raw["performance"] as? [String: Any],
              let elapsed = number(performance["elapsed_milliseconds"]),
              elapsed >= 0, elapsed < 120_000,
              integer(performance["hard_deadline_milliseconds"]) == 120_000 else {
            throw AdapterError.queueRejected("NATIVE_REALM_COVERAGE_STRUCTURE_INVALID")
        }
        let recoveryActions = try validateSemanticRecoveryHistory(
            recoveryHistory,
            target: target,
            artifactRoot: artifactRoot
        )
        var expectedRoles = recoveryActions.map(\.role)
        expectedRoles.append(SemanticActionRole.surfaceSelectorOpen.rawValue)
        expectedRoles.append(contentsOf: Array(
            repeating: SemanticActionRole.surfaceSelectorScrollbarDrag.rawValue,
            count: surfaceScrollbarDrags
        ))
        expectedRoles.append(SemanticActionRole.surfaceOptionSelect.rawValue)
        expectedRoles.append(contentsOf: Array(repeating: SemanticActionRole.zoomMinus.rawValue, count: minusClicks))
        expectedRoles.append(contentsOf: Array(repeating: SemanticActionRole.zoomPlus.rawValue, count: ascentClicks))
        expectedRoles.append(contentsOf: Array(
            repeating: SemanticActionRole.coverageAnchor.rawValue,
            count: expectedAnchorAttempts
        ))
        expectedRoles.append(contentsOf: Array(repeating: SemanticActionRole.coveragePan.rawValue, count: movementCount))
        guard actions.compactMap({ $0["role"] as? String }) == expectedRoles else {
            throw AdapterError.queueRejected("NATIVE_REALM_COVERAGE_ACTION_ORDER_INVALID")
        }
        let anchorActionOffset = recoveryActions.count
            + 1
            + surfaceScrollbarDrags
            + 1
            + minusClicks
            + ascentClicks
        for (index, transition) in anchorTransitions.enumerated() {
            guard let before = transition["before_capture"] as? [String: Any],
                  actions[anchorActionOffset + index]["capture_id"] as? String
                    == before["captureIdentifier"] as? String else {
                throw AdapterError.queueRejected("NATIVE_REALM_COVERAGE_ANCHOR_ACTION_BINDING_INVALID")
            }
        }
        let movementActionOffset = anchorActionOffset + expectedAnchorAttempts
        for (index, transition) in transitions.enumerated() {
            guard let before = transition["before_capture"] as? [String: Any],
                  actions[movementActionOffset + index]["capture_id"] as? String
                    == before["captureIdentifier"] as? String else {
                throw AdapterError.queueRejected("NATIVE_REALM_COVERAGE_MOVEMENT_ACTION_BINDING_INVALID")
            }
        }
        let finalNavigationCapture = movementCount > 0
            ? transitions.last?["after_capture"] as? [String: Any]
            : anchorTransitions.last?["after_capture"] as? [String: Any]
        guard finalNavigationCapture?["captureIdentifier"] as? String == targetIdentifier else {
            throw AdapterError.queueRejected("NATIVE_REALM_COVERAGE_TARGET_BINDING_INVALID")
        }
        var identifiers = Set<String>()
        for action in actions {
            guard let identifier = action["capture_id"] as? String,
                  !identifier.isEmpty,
                  identifiers.insert(identifier).inserted,
                  let input = action["input_evidence"] as? [String: Any] else {
                throw AdapterError.queueRejected("SEMANTIC_INPUT_EVIDENCE_INVALID")
            }
            try validateReference(
                path: input["path"] as? String,
                sha256: input["sha256"] as? String,
                artifactRoot: artifactRoot,
                error: "SEMANTIC_INPUT_EVIDENCE_INVALID"
            )
        }
        try validateReference(
            path: mapCrop["path"] as? String,
            sha256: mapCrop["sha256"] as? String,
            artifactRoot: artifactRoot,
            error: "SEMANTIC_MAP_CROP_INVALID"
        )
    }

    private func semanticResetRelativeCoverageDelta(_ item: QueueItem) -> (Int, Int)? {
        guard let from = item.coverageCell?.resetCenter,
              let to = item.captureCenter,
              let zoom = item.zoomPercent else { return nil }
        let delta = (
            Self.javaScriptRoundedInteger((from.x - to.x) * zoom / 100),
            Self.javaScriptRoundedInteger((to.y - from.y) * zoom / 100)
        )
        return hypot(Double(delta.0), Double(delta.1)) < 10 ? (0, 0) : delta
    }

    private func semanticResetRelativeCoveragePanCount(_ delta: (Int, Int)) -> Int {
        if delta.0 == 0 && delta.1 == 0 { return 0 }
        return max(
            Int(ceil(Double(abs(delta.0)) / 240)),
            Int(ceil(Double(abs(delta.1)) / 400))
        )
    }

    private func validateNativeCoverageResult(
        _ raw: [String: Any],
        item: QueueItem,
        target: [String: Any],
        artifactRoot: String,
        surfaceScrollbarDrags: Int,
        minusClicks: Int,
        ascentClicks: Int
    ) throws {
        guard item.restoreAfterCapture == false,
              let navigation = raw["coverage_navigation"] as? [String: Any],
              navigation["planner_version"] as? String == "native-realm-coverage-planner-v2",
              navigation["nonblack"] as? Bool == true,
              let mode = navigation["mode"] as? String,
              mode == "anchored" || mode == "chained",
              let sourceCenter = navigation["source_center"] as? [String: Any],
              let targetCenter = navigation["target_center"] as? [String: Any],
              semanticCenter(targetCenter, matches: item.captureCenter),
              let expectedSource = semanticCoverageSourceCenter(item: item, mode: mode),
              semanticCenter(sourceCenter, matches: expectedSource),
              let referenceDelta = navigation["reference_delta"] as? [String: Any],
              let deliveredDelta = navigation["delivered_reference_delta"] as? [String: Any],
              let expectedDelta = semanticCoverageReferenceDelta(
                from: expectedSource,
                to: item.captureCenter,
                zoomPercent: item.zoomPercent
              ),
              integer(referenceDelta["dx"]) == expectedDelta.0,
              integer(referenceDelta["dy"]) == expectedDelta.1,
              integer(deliveredDelta["dx"]) == expectedDelta.0,
              integer(deliveredDelta["dy"]) == expectedDelta.1,
              let anchor = navigation["anchor"] as? [String: Any],
              let anchorRequired = anchor["required"] as? Bool,
              anchorRequired == (mode == "anchored"),
              let anchorAttempts = integer(anchor["attempts"]),
              let anchorTransitions = anchor["transitions"] as? [[String: Any]],
              anchorTransitions.count == anchorAttempts,
              let movement = navigation["movement"] as? [String: Any],
              let movementCount = integer(movement["action_count"]),
              let movementTransitions = movement["transitions"] as? [[String: Any]],
              movementTransitions.count == movementCount,
              let targetFrame = navigation["target_frame"] as? [String: Any],
              let freshFrame = navigation["fresh_frame"] as? [String: Any],
              let targetGate = navigation["target_gate"] as? [String: Any],
              let freshGate = navigation["fresh_gate"] as? [String: Any],
              semanticGatePassed(targetGate, item: item),
              semanticGatePassed(freshGate, item: item),
              let targetIdentifier = targetFrame["captureIdentifier"] as? String,
              let freshIdentifier = freshFrame["captureIdentifier"] as? String,
              !targetIdentifier.isEmpty,
              !freshIdentifier.isEmpty,
              targetIdentifier != freshIdentifier else {
            throw AdapterError.queueRejected("NATIVE_REALM_COVERAGE_RESULT_INVALID")
        }
        try validateSemanticCapture(targetFrame, target: target, artifactRoot: artifactRoot)
        try validateSemanticCapture(freshFrame, target: target, artifactRoot: artifactRoot)

        if mode == "anchored" {
            guard anchorAttempts >= 2,
                  anchorAttempts <= 40,
                  integer(anchor["consecutive_no_transition_proofs"]) == 2,
                  anchorTransitions.suffix(2).allSatisfy({
                    $0["transitioned"] as? Bool == false
                        && number($0["mean_abs_difference"]).map { $0 < 1.25 } == true
                  }) else {
                throw AdapterError.queueRejected("NATIVE_REALM_COVERAGE_ANCHOR_INVALID")
            }
        } else {
            guard anchorAttempts == 0,
                  anchorTransitions.isEmpty,
                  integer(anchor["consecutive_no_transition_proofs"]) == 0,
                  let predecessor = navigation["predecessor_item_id"] as? String,
                  !predecessor.isEmpty,
                  let digest = navigation["predecessor_result_digest"] as? String,
                  digest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
                throw AdapterError.queueRejected("NATIVE_REALM_COVERAGE_CHAIN_INVALID")
            }
        }

        var deliveredDX = 0
        var deliveredDY = 0
        for (index, transition) in anchorTransitions.enumerated() {
            guard integer(transition["ordinal"]) == index + 1,
                  let before = transition["before_capture"] as? [String: Any],
                  let after = transition["after_capture"] as? [String: Any],
                  let vector = transition["vector"] as? [String: Any],
                  semanticCoverageVector(vector, dx: 400, dy: -500),
                  before["captureIdentifier"] as? String != after["captureIdentifier"] as? String else {
                throw AdapterError.queueRejected("NATIVE_REALM_COVERAGE_ANCHOR_INVALID")
            }
            try validateSemanticCapture(before, target: target, artifactRoot: artifactRoot)
            try validateSemanticCapture(after, target: target, artifactRoot: artifactRoot)
        }
        for (index, transition) in movementTransitions.enumerated() {
            guard integer(transition["ordinal"]) == index + 1,
                  let before = transition["before_capture"] as? [String: Any],
                  let after = transition["after_capture"] as? [String: Any],
                  let vector = transition["vector"] as? [String: Any],
                  let delta = vector["reference_delta"] as? [String: Any],
                  let dx = integer(delta["dx"]),
                  let dy = integer(delta["dy"]),
                  semanticCoverageVector(vector, dx: dx, dy: dy),
                  let difference = number(transition["mean_abs_difference"]),
                  difference >= 2.5,
                  before["captureIdentifier"] as? String != after["captureIdentifier"] as? String else {
                throw AdapterError.queueRejected("NATIVE_REALM_COVERAGE_MOVEMENT_INVALID")
            }
            deliveredDX += dx
            deliveredDY += dy
            try validateSemanticCapture(before, target: target, artifactRoot: artifactRoot)
            try validateSemanticCapture(after, target: target, artifactRoot: artifactRoot)
        }
        guard deliveredDX == expectedDelta.0, deliveredDY == expectedDelta.1 else {
            throw AdapterError.queueRejected("NATIVE_REALM_COVERAGE_VECTOR_SUM_INVALID")
        }

        guard let recoveryHistory = raw["recovery_history"] as? [[String: Any]],
              let actions = raw["action_history"] as? [[String: Any]],
              let mapCrop = raw["map_crop"] as? [String: Any],
              integer(mapCrop["width"]) == 516,
              integer(mapCrop["height"]) == 641,
              let performance = raw["performance"] as? [String: Any],
              let elapsed = number(performance["elapsed_milliseconds"]),
              elapsed >= 0, elapsed < 120_000,
              integer(performance["hard_deadline_milliseconds"]) == 120_000 else {
            throw AdapterError.queueRejected("NATIVE_REALM_COVERAGE_STRUCTURE_INVALID")
        }
        let recoveryActions = try validateSemanticRecoveryHistory(
            recoveryHistory,
            target: target,
            artifactRoot: artifactRoot
        )
        var expectedRoles = recoveryActions.map(\.role) + [SemanticActionRole.surfaceSelectorOpen.rawValue]
        expectedRoles.append(contentsOf: Array(
            repeating: SemanticActionRole.surfaceSelectorScrollbarDrag.rawValue,
            count: surfaceScrollbarDrags
        ))
        expectedRoles.append(SemanticActionRole.surfaceOptionSelect.rawValue)
        expectedRoles.append(contentsOf: Array(repeating: SemanticActionRole.zoomMinus.rawValue, count: minusClicks))
        expectedRoles.append(contentsOf: Array(repeating: SemanticActionRole.zoomPlus.rawValue, count: ascentClicks))
        expectedRoles.append(contentsOf: Array(repeating: SemanticActionRole.coverageAnchor.rawValue, count: anchorAttempts))
        expectedRoles.append(contentsOf: Array(repeating: SemanticActionRole.coveragePan.rawValue, count: movementCount))
        guard actions.compactMap({ $0["role"] as? String }) == expectedRoles else {
            throw AdapterError.queueRejected("NATIVE_REALM_COVERAGE_ACTION_ORDER_INVALID")
        }
        var actionCaptureIdentifiers = Set<String>()
        for action in actions {
            guard let captureIdentifier = action["capture_id"] as? String,
                  !captureIdentifier.isEmpty,
                  actionCaptureIdentifiers.insert(captureIdentifier).inserted,
                  let input = action["input_evidence"] as? [String: Any] else {
                throw AdapterError.queueRejected("SEMANTIC_INPUT_EVIDENCE_INVALID")
            }
            try validateReference(
                path: input["path"] as? String,
                sha256: input["sha256"] as? String,
                artifactRoot: artifactRoot,
                error: "SEMANTIC_INPUT_EVIDENCE_INVALID"
            )
        }
        try validateReference(
            path: mapCrop["path"] as? String,
            sha256: mapCrop["sha256"] as? String,
            artifactRoot: artifactRoot,
            error: "SEMANTIC_MAP_CROP_INVALID"
        )
    }

    private func semanticCenter(
        _ raw: [String: Any],
        matches expected: SemanticCaptureCenter?
    ) -> Bool {
        guard let expected else { return false }
        return number(raw["x"]) == expected.x && number(raw["y"]) == expected.y
    }

    private func semanticCoverageSourceCenter(
        item: QueueItem,
        mode: String
    ) -> SemanticCaptureCenter? {
        guard let cell = item.coverageCell else { return nil }
        if mode == "anchored" {
            return SemanticCaptureCenter(
                x: roundedTenth(cell.realmBounds.minX + cell.viewport.width / 2),
                y: roundedTenth(cell.realmBounds.minY + cell.viewport.height / 2)
            )
        }
        let xStarts = semanticCoverageStarts(
            minimum: cell.realmBounds.minX,
            maximum: cell.realmBounds.maxX,
            viewport: cell.viewport.width
        )
        let yStarts = semanticCoverageStarts(
            minimum: cell.realmBounds.minY,
            maximum: cell.realmBounds.maxY,
            viewport: cell.viewport.height
        )
        guard cell.row < yStarts.count, cell.column < xStarts.count else { return nil }
        var row = cell.row
        var column: Int
        if row.isMultiple(of: 2) {
            if cell.column > 0 { column = cell.column - 1 }
            else { row -= 1; column = 0 }
        } else if cell.column < xStarts.count - 1 {
            column = cell.column + 1
        } else {
            row -= 1
            column = xStarts.count - 1
        }
        guard row >= 0, row < yStarts.count else { return nil }
        return SemanticCaptureCenter(
            x: roundedTenth(xStarts[column] + cell.viewport.width / 2),
            y: roundedTenth(yStarts[row] + cell.viewport.height / 2)
        )
    }

    private func semanticCoverageReferenceDelta(
        from: SemanticCaptureCenter,
        to: SemanticCaptureCenter?,
        zoomPercent: Double?
    ) -> (Int, Int)? {
        guard let to, let zoomPercent else { return nil }
        return (
            Int(((from.x - to.x) * zoomPercent / 100).rounded()),
            Int(((to.y - from.y) * zoomPercent / 100).rounded())
        )
    }

    private func semanticCoverageStarts(
        minimum: Double,
        maximum: Double,
        viewport: Double
    ) -> [Double] {
        let span = maximum - minimum
        if span <= viewport {
            return [roundedTenth((minimum + maximum - viewport) / 2)]
        }
        let step = max(1, roundedTenth(viewport * 0.8))
        var starts = [minimum]
        var current = minimum
        while roundedTenth(current + viewport) < maximum {
            let next = min(roundedTenth(current + step), roundedTenth(maximum - viewport))
            if next <= current { break }
            starts.append(next)
            current = next
        }
        return starts
    }

    private func roundedTenth(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }

    nonisolated func semanticCoverageVector(_ raw: [String: Any], dx: Int, dy: Int) -> Bool {
        guard abs(dx) <= 400, abs(dy) <= 500, hypot(Double(dx), Double(dy)) >= 10,
              let delta = raw["reference_delta"] as? [String: Any],
              integer(delta["dx"]) == dx,
              integer(delta["dy"]) == dy,
              let translation = raw["anchor_translation"] as? [String: Any],
              let translationX = integer(translation["x"]),
              let translationY = integer(translation["y"]),
              abs(translationX) <= 36,
              abs(translationY) <= 36,
              let reference = raw["reference"] as? [String: Any],
              let from = reference["from"] as? [String: Any],
              let to = reference["to"] as? [String: Any] else { return false }
        let expectedX = (dx >= 0 ? 40 : 440) + translationX
        let expectedY = (dy >= 0 ? 90 : 590) + translationY
        return integer(from["x"]) == expectedX
            && integer(from["y"]) == expectedY
            && integer(to["x"]) == expectedX + dx
            && integer(to["y"]) == expectedY + dy
    }

    nonisolated func semanticResetRelativeCoverageVector(
        _ raw: [String: Any],
        dx: Int,
        dy: Int,
        coverageCrop: SemanticCoverageCrop? = nil
    ) -> Bool {
        guard abs(dx) <= 240, abs(dy) <= 400, hypot(Double(dx), Double(dy)) >= 10,
              let delta = raw["reference_delta"] as? [String: Any],
              integer(delta["dx"]) == dx,
              integer(delta["dy"]) == dy,
              let translation = raw["anchor_translation"] as? [String: Any],
              let translationX = integer(translation["x"]),
              let translationY = integer(translation["y"]),
              abs(translationX) <= 36,
              abs(translationY) <= 36,
              let reference = raw["reference"] as? [String: Any],
              let from = reference["from"] as? [String: Any],
              let to = reference["to"] as? [String: Any] else { return false }
        let crop = coverageCrop
            ?? SemanticCoverageCrop(left: 178, top: 35, width: 310, height: 480)
        let expectedX = (dx >= 0 ? crop.left + 12 : crop.left + crop.width - 12)
            + translationX
        let expectedY = (dy >= 0 ? crop.top + 12 : crop.top + crop.height - 12)
            + translationY
        let toX = expectedX + dx
        let toY = expectedY + dy
        return integer(from["x"]) == expectedX
            && integer(from["y"]) == expectedY
            && integer(to["x"]) == toX
            && integer(to["y"]) == toY
            && expectedX >= crop.left + 6
            && expectedX < crop.left + crop.width - 6
            && expectedY >= crop.top + 6
            && expectedY < crop.top + crop.height - 6
            && toX >= crop.left + 6
            && toX < crop.left + crop.width - 6
            && toY >= crop.top + 6
            && toY < crop.top + crop.height - 6
    }

    nonisolated func semanticResetRelativeCoverageMovementProof(
        _ transition: [String: Any],
        expectedDX: Int,
        expectedDY: Int
    ) -> Bool {
        guard let difference = number(transition["mean_abs_difference"]),
              difference >= 2.5,
              let proof = transition["displacement_proof"] as? [String: Any],
              proof["passed"] as? Bool == true,
              let expected = proof["expected_reference_delta"] as? [String: Any],
              integer(expected["dx"]) == expectedDX,
              integer(expected["dy"]) == expectedDY,
              let delivered = proof["delivered_reference_delta"] as? [String: Any],
              let deliveredDX = integer(delivered["dx"]),
              let deliveredDY = integer(delivered["dy"]),
              abs(deliveredDX - expectedDX) <= 10,
              abs(deliveredDY - expectedDY) <= 10,
              integer(proof["tolerance_reference_pixels"]) == 10,
              let recordedDifference = number(proof["mean_abs_difference"]),
              abs(recordedDifference - difference) < 0.000_000_001,
              number(proof["mean_abs_minimum"]) == 2.5 else {
            return false
        }
        if proof["evidence_mode"] as? String == "native_crop_expected_neighborhood" {
            guard let aligned = number(proof["aligned_mean_abs"]),
                  aligned <= 25,
                  number(proof["aligned_mean_abs_maximum"]) == 25,
                  let informative = number(proof["informative_coverage"]),
                  informative >= 0.5,
                  number(proof["informative_coverage_minimum"]) == 0.5 else {
                return false
            }
            return true
        }
        if proof["evidence_mode"] as? String == "native_crop_source_boundary_exit" {
            guard proof["alignment_selection_mode"] as? String == "directional_source_boundary_exit",
                  let sourceChanged = integer(proof["source_changed_pixel_count"]),
                  sourceChanged >= 64,
                  let destinationChanged = integer(proof["destination_changed_pixel_count"]),
                  destinationChanged >= 16,
                  let destinationInformative = integer(proof["destination_informative_pixel_count"]),
                  destinationInformative >= 32,
                  let sourceExitFraction = number(proof["source_exit_fraction"]),
                  sourceExitFraction >= 0.5,
                  let alignedShared = integer(proof["aligned_shared_pixel_count"]),
                  alignedShared <= 63,
                  integer(proof["minimum_changed_pixel_count"]) == 64,
                  integer(proof["minimum_sparse_changed_pixel_count"]) == 16,
                  integer(proof["minimum_destination_informative_pixel_count"]) == 32,
                  number(proof["minimum_sparse_turnover_fraction"]) == 0.5,
                  number(proof["minimum_turnover_fraction"]) == 0.75,
                  integer(proof["maximum_shared_pixel_count"]) == 63 else {
                return false
            }
            return true
        }
        guard proof["evidence_mode"] as? String == "native_crop_boundary_turnover",
              proof["alignment_selection_mode"] as? String == "directional_boundary_turnover",
              let sourceChanged = integer(proof["source_changed_pixel_count"]),
              sourceChanged >= 64,
              let destinationChanged = integer(proof["destination_changed_pixel_count"]),
              destinationChanged >= 64,
              let sourceExitFraction = number(proof["source_exit_fraction"]),
              sourceExitFraction >= 0.75,
              let destinationEntryFraction = number(proof["destination_entry_fraction"]),
              destinationEntryFraction >= 0.75,
              let alignedShared = integer(proof["aligned_shared_pixel_count"]),
              alignedShared <= 63,
              integer(proof["minimum_changed_pixel_count"]) == 64,
              number(proof["minimum_turnover_fraction"]) == 0.75,
              integer(proof["maximum_shared_pixel_count"]) == 63 else {
            return false
        }
        return true
    }

    private func semanticActionRolesMatch(
        _ actions: [[String: Any]],
        recoveryActionRoles: [String],
        surfaceScrollbarDrags: Int,
        minusClicks: Int,
        ascentClicks: Int,
        restored: Bool,
        surfaceReset: Bool
    ) -> Bool {
        var expected = recoveryActionRoles + [
            SemanticActionRole.surfaceSelectorOpen.rawValue
        ]
        expected.append(contentsOf: Array(
            repeating: SemanticActionRole.surfaceSelectorScrollbarDrag.rawValue,
            count: surfaceScrollbarDrags
        ))
        expected.append(SemanticActionRole.surfaceOptionSelect.rawValue)
        expected.append(contentsOf: Array(repeating: SemanticActionRole.zoomMinus.rawValue, count: minusClicks))
        expected.append(contentsOf: Array(repeating: SemanticActionRole.zoomPlus.rawValue, count: ascentClicks))
        expected.append(SemanticActionRole.pan.rawValue)
        if restored { expected.append(SemanticActionRole.restore.rawValue) }
        if surfaceReset {
            expected.append(SemanticActionRole.surfaceSelectorOpen.rawValue)
            expected.append(SemanticActionRole.surfaceSelectorScrollbarDrag.rawValue)
            expected.append(SemanticActionRole.surfaceOptionSelect.rawValue)
        }
        return actions.compactMap { $0["role"] as? String } == expected
    }

    private func validateSemanticRecoveryHistory(
        _ history: [[String: Any]],
        target: [String: Any],
        artifactRoot: String
    ) throws -> [SemanticRecoveryAction] {
        guard history.count <= 6 else {
            throw AdapterError.queueRejected("SEMANTIC_RECOVERY_HISTORY_INVALID")
        }
        if history.isEmpty { return [] }
        let downstream: [String: Set<String>] = [
            "TRY_AGAIN": ["STEAM_SIGN_IN", "CONNECTING", "CLICK_TO_PLAY", "GAMEPLAY_NO_MAP", "MAP_READY"],
            "STEAM_SIGN_IN": ["CONNECTING", "CLICK_TO_PLAY", "GAMEPLAY_NO_MAP", "MAP_READY"],
            "CONNECTING": ["CLICK_TO_PLAY", "GAMEPLAY_NO_MAP", "MAP_READY"],
            "CLICK_TO_PLAY": ["GAMEPLAY_NO_MAP", "MAP_READY"],
            "GAMEPLAY_NO_MAP": ["MAP_READY"],
        ]
        let roles: [String: String] = [
            "TRY_AGAIN": SemanticActionRole.recoveryTryAgain.rawValue,
            "STEAM_SIGN_IN": SemanticActionRole.recoverySteamSignIn.rawValue,
            "CLICK_TO_PLAY": SemanticActionRole.recoveryClickToPlay.rawValue,
            "GAMEPLAY_NO_MAP": SemanticActionRole.recoveryOpenWorldMap.rawValue,
        ]
        var previousObservedState: String?
        var actions: [SemanticRecoveryAction] = []
        for (index, transition) in history.enumerated() {
            guard integer(transition["ordinal"]) == index + 1,
                  let state = transition["state"] as? String,
                  let allowed = downstream[state],
                  let observed = transition["observed_state"] as? String,
                  allowed.contains(observed),
                  previousObservedState == nil || previousObservedState == state,
                  let before = transition["before_capture"] as? [String: Any],
                  let after = transition["after_capture"] as? [String: Any],
                  let beforeIdentifier = before["captureIdentifier"] as? String,
                  let afterIdentifier = after["captureIdentifier"] as? String,
                  beforeIdentifier != afterIdentifier,
                  before["pngSHA256"] as? String != after["pngSHA256"] as? String else {
                throw AdapterError.queueRejected("SEMANTIC_RECOVERY_HISTORY_INVALID")
            }
            try validateSemanticCapture(before, target: target, artifactRoot: artifactRoot)
            try validateSemanticCapture(after, target: target, artifactRoot: artifactRoot)
            let suppliedRole = transition["action_role"] as? String
            if let expectedRole = roles[state] {
                guard suppliedRole == expectedRole else {
                    throw AdapterError.queueRejected("SEMANTIC_RECOVERY_ROLE_INVALID")
                }
                actions.append(SemanticRecoveryAction(
                    role: expectedRole,
                    captureIdentifier: beforeIdentifier
                ))
            } else if suppliedRole != nil {
                throw AdapterError.queueRejected("SEMANTIC_RECOVERY_ROLE_INVALID")
            }
            previousObservedState = observed
        }
        guard previousObservedState == "MAP_READY" else {
            throw AdapterError.queueRejected("SEMANTIC_RECOVERY_INCOMPLETE")
        }
        return actions
    }

    private func validateSemanticProductionRequestedWork(
        _ requested: [String: Any],
        item: QueueItem
    ) throws {
        if item.realmID == nil {
            return
        }
        guard requested["realm_id"] as? String == item.realmID,
              requested["catalog_version"] as? String == item.catalogVersion,
              requested["planner_version"] as? String == item.plannerVersion,
              integer(requested["selector_index"]) == item.selectorIndex,
              let expectedCenter = item.captureCenter,
              let captureCenter = requested["capture_center"] as? [String: Any],
              semanticCaptureCenterMatches(captureCenter, expected: expectedCenter),
              let expectedCell = item.coverageCell,
              let coverageCell = requested["coverage_cell"] as? [String: Any],
              semanticCoverageCellMatches(coverageCell, expected: expectedCell) else {
            throw AdapterError.queueRejected("SEMANTIC_PRODUCTION_REQUEST_BINDING_INVALID")
        }
    }

    private func semanticCaptureCenterMatches(
        _ value: [String: Any],
        expected: SemanticCaptureCenter
    ) -> Bool {
        Set(value.keys) == ["x", "y"]
            && semanticNumber(value["x"], equals: expected.x)
            && semanticNumber(value["y"], equals: expected.y)
    }

    private func semanticCoverageCellMatches(
        _ value: [String: Any],
        expected: SemanticCoverageCell
    ) -> Bool {
        var expectedKeys: Set<String> = [
            "row", "column", "realm_bounds", "capture_bounds", "viewport"
        ]
        if expected.coveragePlane != nil { expectedKeys.insert("coverage_plane") }
        if expected.coverageCrop != nil { expectedKeys.insert("coverage_crop") }
        if expected.resetCenter != nil { expectedKeys.insert("reset_center") }
        if expected.anchorAttemptBudget != nil { expectedKeys.insert("anchor_attempt_budget") }
        guard Set(value.keys) == expectedKeys,
           semanticInteger(value["row"], equals: expected.row),
           semanticInteger(value["column"], equals: expected.column),
           let realmBounds = value["realm_bounds"] as? [String: Any],
           semanticBoundsMatch(realmBounds, expected: expected.realmBounds),
           let captureBounds = value["capture_bounds"] as? [String: Any],
           semanticBoundsMatch(captureBounds, expected: expected.captureBounds),
           let viewport = value["viewport"] as? [String: Any],
           semanticOptionalCoverageCrop(value["coverage_crop"], equals: expected.coverageCrop),
           semanticOptionalInteger(value["coverage_plane"], equals: expected.coveragePlane),
           semanticOptionalCenter(value["reset_center"], equals: expected.resetCenter),
           semanticOptionalInteger(
            value["anchor_attempt_budget"],
            equals: expected.anchorAttemptBudget
           ) else {
            return false
        }
        var viewportKeys: Set<String> = ["width", "height"]
        if expected.viewport.zoomPercent != nil {
            viewportKeys.insert("zoom_percent")
        }
        if expected.viewport.overlapFraction != nil {
            viewportKeys.insert("overlap_fraction")
        }
        return Set(viewport.keys) == viewportKeys
            && semanticNumber(viewport["width"], equals: expected.viewport.width)
            && semanticNumber(viewport["height"], equals: expected.viewport.height)
            && semanticOptionalNumber(
                viewport["zoom_percent"],
                equals: expected.viewport.zoomPercent
            )
            && semanticOptionalNumber(
                viewport["overlap_fraction"],
                equals: expected.viewport.overlapFraction
            )
    }

    private func semanticOptionalCoverageCrop(
        _ value: Any?,
        equals expected: SemanticCoverageCrop?
    ) -> Bool {
        guard let expected else { return value == nil }
        guard let crop = value as? [String: Any],
              Set(crop.keys) == ["left", "top", "width", "height"] else { return false }
        return integer(crop["left"]) == expected.left
            && integer(crop["top"]) == expected.top
            && integer(crop["width"]) == expected.width
            && integer(crop["height"]) == expected.height
    }

    private func semanticNativeCoverageMapCropMatches(
        _ mapCrop: [String: Any],
        item: QueueItem
    ) -> Bool {
        let expected = item.coverageCell?.coverageCrop
            ?? SemanticCoverageCrop(left: 178, top: 35, width: 310, height: 480)
        guard let sourceCrop = mapCrop["source_crop"] as? [String: Any],
              Set(sourceCrop.keys) == ["left", "top", "width", "height"] else { return false }
        return integer(sourceCrop["left"]) == expected.left
            && integer(sourceCrop["top"]) == expected.top
            && integer(sourceCrop["width"]) == expected.width
            && integer(sourceCrop["height"]) == expected.height
            && integer(mapCrop["width"]) == expected.width
            && integer(mapCrop["height"]) == expected.height
    }

    private func semanticBoundsMatch(
        _ value: [String: Any],
        expected: SemanticBounds
    ) -> Bool {
        Set(value.keys) == ["min_x", "min_y", "max_x", "max_y"]
            && semanticNumber(value["min_x"], equals: expected.minX)
            && semanticNumber(value["min_y"], equals: expected.minY)
            && semanticNumber(value["max_x"], equals: expected.maxX)
            && semanticNumber(value["max_y"], equals: expected.maxY)
    }

    private func semanticNumber(_ value: Any?, equals expected: Double) -> Bool {
        !semanticIsBoolean(value) && number(value) == expected
    }

    private func semanticOptionalNumber(_ value: Any?, equals expected: Double?) -> Bool {
        guard let expected else { return value == nil }
        return semanticNumber(value, equals: expected)
    }

    private func semanticOptionalInteger(_ value: Any?, equals expected: Int?) -> Bool {
        guard let expected else { return value == nil }
        return semanticInteger(value, equals: expected)
    }

    private func semanticOptionalCenter(
        _ value: Any?,
        equals expected: SemanticCaptureCenter?
    ) -> Bool {
        guard let expected else { return value == nil }
        guard let center = value as? [String: Any] else { return false }
        return semanticCaptureCenterMatches(center, expected: expected)
    }

    private func semanticInteger(_ value: Any?, equals expected: Int) -> Bool {
        !semanticIsBoolean(value) && integer(value) == expected
    }

    private func semanticIsBoolean(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else {
            return value is Bool
        }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
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

    private func validateCapture(_ capture: [String: Any], artifactRoot: String) throws {
        try validateReference(
            path: capture["pngPath"] as? String,
            sha256: capture["pngSHA256"] as? String,
            artifactRoot: artifactRoot,
            error: "CAPTURE_EVIDENCE_INVALID"
        )
    }

    private func validateSemanticCapture(
        _ capture: [String: Any],
        target: [String: Any],
        artifactRoot: String
    ) throws {
        guard let captureTarget = capture["target"] as? [String: Any],
              captureTarget["bundleIdentifier"] as? String == target["bundle_identifier"] as? String,
              number(captureTarget["processIdentifier"]) == number(target["process_identifier"]),
              number(captureTarget["windowIdentifier"]) == number(target["window_identifier"]),
              let width = integer(capture["pixelWidth"]), width > 0,
              let height = integer(capture["pixelHeight"]), height > 0 else {
            throw AdapterError.queueRejected("SEMANTIC_CAPTURE_TARGET_INVALID")
        }
        try validateCapture(capture, artifactRoot: artifactRoot)
    }

    private func semanticGatePassed(_ gate: [String: Any], item: QueueItem) -> Bool {
        if item.realmID != nil {
            guard let surface = item.surface?.rawValue,
                  let readback = gate["surface_readback"] as? [String: Any],
                  readback["exact_match"] as? Bool == true,
                  readback["surface"] as? String == surface,
                  number(readback["normalized_correlation"]).map({ $0 >= 0.72 }) == true,
                  number(readback["correlation_separation"]).map({ $0 >= 0.08 }) == true else {
                return false
            }
        }
        return semanticGatePassed(gate, surface: item.surface)
    }

    private func semanticSparseZoomScaleProofPassed(
        _ transition: [String: Any],
        before: [String: Any],
        after: [String: Any],
        item: QueueItem
    ) -> Bool {
        guard item.realmID != nil,
              transition["evidence_mode"] as? String == "sparse_map_scale_growth_v1",
              let proof = transition["sparse_scale_proof"] as? [String: Any],
              proof["passed"] as? Bool == true,
              proof["evidence_mode"] as? String == "sparse_map_scale_growth_v1",
              proof["before_capture_sha256"] as? String == before["pngSHA256"] as? String,
              proof["after_capture_sha256"] as? String == after["pngSHA256"] as? String,
              let beforeMetrics = proof["before"] as? [String: Any],
              let afterMetrics = proof["after"] as? [String: Any],
              let growth = proof["growth"] as? [String: Any],
              let thresholds = proof["thresholds"] as? [String: Any],
              number(beforeMetrics["informative_pixel_count"]).map({ $0 >= 64 }) == true,
              number(afterMetrics["informative_pixel_count"]).map({ $0 >= 64 }) == true,
              number(beforeMetrics["chromatic_pixel_count"]).map({ $0 >= 8 }) == true,
              number(afterMetrics["chromatic_pixel_count"]).map({ $0 >= 8 }) == true,
              number(beforeMetrics["informative_fraction"]).map({ $0 <= 0.2 }) == true,
              number(afterMetrics["informative_fraction"]).map({ $0 <= 0.2 }) == true,
              number(growth["width_ratio"]).map({ $0 >= 1.08 && $0 <= 2.5 }) == true,
              number(growth["height_ratio"]).map({ $0 >= 1.08 && $0 <= 2.5 }) == true,
              number(growth["informative_pixel_ratio"]).map({ $0 >= 1.15 }) == true,
              number(growth["chromatic_pixel_ratio"]).map({ $0 >= 1.15 }) == true,
              number(growth["center_displacement_pixels"]).map({ $0 <= 5 }) == true,
              number(thresholds["minimum_informative_pixels"]) == 64,
              number(thresholds["minimum_chromatic_pixels"]) == 8,
              number(thresholds["maximum_informative_fraction"]) == 0.2,
              number(thresholds["minimum_linear_growth"]) == 1.08,
              number(thresholds["maximum_linear_growth"]) == 2.5,
              number(thresholds["minimum_support_growth"]) == 1.15,
              number(thresholds["maximum_center_displacement_pixels"]) == 5 else {
            return false
        }
        return true
    }

    private func semanticNavigationAnchorAllowed(_ anchor: String?, item: QueueItem) -> Bool {
        if item.realmID != nil {
            return anchor == "bottom" || anchor == "position"
        }
        return anchor == "bottom"
    }

    private func semanticSelectorScrollbarProofAccepted(
        _ proof: [String: Any],
        anchor: String,
        item: QueueItem
    ) -> Bool {
        if item.realmID == nil {
            return semanticScrollbarProofPassed(proof, anchor: anchor)
        }
        guard semanticScrollbarGeometryPassed(proof) else {
            return false
        }
        if anchor == "current" {
            return true
        }
        guard let selectorIndex = item.selectorIndex,
              let observed = proof["normalized_observed_bbox"] as? [String: Any],
              let observedTop = integer(observed["top"]) else {
            return false
        }
        if anchor == "bottom" {
            return observedTop == 613
        }
        return semanticProductionScrollbarMakesSelectorVisible(
            selectorIndex: selectorIndex,
            observedTop: observedTop
        )
    }

    nonisolated func semanticProductionScrollbarMakesSelectorVisible(
        selectorIndex: Int,
        observedTop: Int
    ) -> Bool {
        guard (0..<47).contains(selectorIndex), (543...613).contains(observedTop) else {
            return false
        }
        let visibleRows = 8
        let maxTopIndex = 47 - visibleRows
        let visibleTopIndex = Int(
            (Double(observedTop - 543) * Double(maxTopIndex) / 70.0).rounded(.up)
        )
        return selectorIndex >= visibleTopIndex
            && selectorIndex < visibleTopIndex + visibleRows
    }

    private func semanticProductionOptionBindingPassed(
        _ option: [String: Any],
        navigation: [String: Any],
        transitions: [[String: Any]],
        item: QueueItem
    ) -> Bool {
        guard let realmID = item.realmID, let selectorIndex = item.selectorIndex else {
            return true
        }
        let observedTop: Int?
        if let post = transitions.last?["post_drag_proof"] as? [String: Any],
           let observed = post["normalized_observed_bbox"] as? [String: Any] {
            observedTop = integer(observed["top"])
        } else {
            observedTop = integer(navigation["target_thumb_top"])
        }
        guard let observedTop,
              (543...613).contains(observedTop),
              option["selector_catalog_version"] as? String == item.catalogVersion,
              option["realm_id"] as? String == realmID,
              integer(option["selector_index"]) == selectorIndex else {
            return false
        }
        let visibleRows = 8
        let visibleTopIndex = Int(
            (Double(observedTop - 543) * Double(47 - visibleRows) / 70.0).rounded(.up)
        )
        let geometricRow = selectorIndex - visibleTopIndex
        guard (0..<visibleRows).contains(geometricRow),
              let box = option["normalized_observed_bbox"] as? [String: Any],
              let click = option["normalized_click_point"] as? [String: Any] else {
            return false
        }
        guard let expectedTop = semanticProductionOptionTop(
            selectorIndex: selectorIndex,
            observedTop: observedTop
        ) else {
            return false
        }
        let proofMethod = option["proof_method"] as? String
        switch proofMethod {
        case "NATIVE_SELECTOR_CATALOG_CONTINUOUS_GEOMETRY_V2":
            return integer(option["visible_top_index"]) == visibleTopIndex
                && integer(option["visible_row_index"]) == geometricRow
                && integer(box["left"]) == 166
                && integer(box["top"]) == expectedTop
                && integer(box["right"]) == 349
                && integer(box["bottom"]) == expectedTop + 14
                && integer(click["x"]) == 257
                && integer(click["y"]) == expectedTop + 2
        case "NATIVE_SELECTOR_CATALOG_CONTINUOUS_GEOMETRY_V3":
            return integer(option["visible_top_index"]) == visibleTopIndex
                && integer(option["visible_row_index"]) == geometricRow
                && integer(box["left"]) == 166
                && integer(box["top"]) == expectedTop
                && integer(box["right"]) == 349
                && integer(box["bottom"]) == expectedTop + 14
                && integer(click["x"]) == 257
                && integer(click["y"]) == expectedTop + 7
        case "NATIVE_SELECTOR_CATALOG_CONTINUOUS_GEOMETRY_V4":
            return integer(option["visible_top_index"]) == visibleTopIndex
                && integer(option["visible_row_index"]) == geometricRow
                && integer(box["left"]) == 166
                && integer(box["top"]) == expectedTop
                && integer(box["right"]) == 349
                && integer(box["bottom"]) == expectedTop + 14
                && integer(click["x"]) == 257
                && integer(click["y"]) == expectedTop + 7
        case "NATIVE_SELECTOR_CATALOG_PIXEL_ROW_V4":
            guard let measuredTopIndex = integer(option["visible_top_index"]),
                  let measuredRow = integer(option["visible_row_index"]),
                  measuredTopIndex + measuredRow == selectorIndex,
                  abs(measuredTopIndex - visibleTopIndex) <= 1,
                  (0..<visibleRows).contains(measuredRow),
                  integer(option["pixel_row_ordinal"]) == measuredRow,
                  integer(option["detected_row_count"]) == visibleRows,
                  let predicted = option["geometry_predicted_bbox"] as? [String: Any],
                  integer(predicted["left"]) == 166,
                  integer(predicted["top"]) == expectedTop,
                  integer(predicted["right"]) == 349,
                  integer(predicted["bottom"]) == expectedTop + 14,
                  let observedTop = integer(box["top"]),
                  let observedBottom = integer(box["bottom"]),
                  observedTop >= 533,
                  observedBottom <= 645,
                  observedBottom > observedTop,
                  integer(box["left"]) == 166,
                  integer(box["right"]) == 349,
                  integer(click["x"]) == 257,
                  let clickY = integer(click["y"]),
                  clickY == (observedTop + observedBottom) / 2,
                  abs(clickY - (expectedTop + 7)) <= 7,
                  integer(option["geometric_click_delta_y"]) == clickY - (expectedTop + 7),
                  let pixelText = option["pixel_text_bbox"] as? [String: Any],
                  integer(pixelText["top"]) == observedTop,
                  integer(pixelText["bottom"]) == observedBottom else {
                return false
            }
            return true
        case "NATIVE_SELECTOR_CATALOG_PIXEL_WINDOW_V5":
            guard let measuredTopIndex = integer(option["visible_top_index"]),
                  let measuredRow = integer(option["visible_row_index"]),
                  measuredTopIndex + measuredRow == selectorIndex,
                  abs(measuredTopIndex - visibleTopIndex) <= 1,
                  let detectedRowCount = integer(option["detected_row_count"]),
                  (7...visibleRows).contains(detectedRowCount),
                  (0..<detectedRowCount).contains(measuredRow),
                  integer(option["pixel_row_ordinal"]) == measuredRow,
                  let metrics = option["observed_row_metrics"] as? [[String: Any]],
                  metrics.count == detectedRowCount,
                  metrics.enumerated().allSatisfy({ ordinal, metric in
                      integer(metric["ordinal"]) == ordinal
                          && (1...176).contains(integer(metric["width"]) ?? 0)
                          && (4...14).contains(integer(metric["height"]) ?? 0)
                  }) else {
                return false
            }
            let widths = metrics.compactMap { integer($0["width"]) }
            let heights = metrics.compactMap { integer($0["height"]) }
            guard let catalogMatch = semanticProductionCatalogWindowMatch(
                      widths: widths,
                      heights: heights
                  ),
                  measuredTopIndex == catalogMatch.topIndex,
                  let score = number(option["catalog_window_score"]),
                  let secondScore = number(option["catalog_window_second_score"]),
                  let separation = number(option["catalog_window_separation"]),
                  score >= 0.72,
                  separation >= 0.08,
                  abs(score - catalogMatch.score) < 0.000_001,
                  abs(secondScore - catalogMatch.secondScore) < 0.000_001,
                  abs((score - secondScore) - separation) < 0.000_001,
                  let predicted = option["geometry_predicted_bbox"] as? [String: Any],
                  integer(predicted["left"]) == 166,
                  integer(predicted["top"]) == expectedTop,
                  integer(predicted["right"]) == 349,
                  integer(predicted["bottom"]) == expectedTop + 14,
                  let observedTop = integer(box["top"]),
                  let observedBottom = integer(box["bottom"]),
                  observedTop >= 533,
                  observedBottom <= 645,
                  observedBottom > observedTop,
                  integer(box["left"]) == 166,
                  integer(box["right"]) == 349,
                  integer(click["x"]) == 257,
                  let clickY = integer(click["y"]),
                  clickY == (observedTop + observedBottom) / 2,
                  abs(clickY - (expectedTop + 7)) <= 16,
                  integer(option["geometric_click_delta_y"]) == clickY - (expectedTop + 7),
                  let pixelText = option["pixel_text_bbox"] as? [String: Any],
                  integer(pixelText["top"]) == observedTop,
                  integer(pixelText["bottom"]) == observedBottom else {
                return false
            }
            return true
        default:
            return false
        }
    }

    nonisolated func semanticProductionOptionTop(
        selectorIndex: Int,
        observedTop: Int
    ) -> Int? {
        guard (0..<47).contains(selectorIndex), (543...613).contains(observedTop) else {
            return nil
        }
        let maximumContentOffset = Double((47 - 8) * 14)
        let contentOffset = Double(observedTop - 543) * maximumContentOffset / 70.0
        return Int((Double(533 + selectorIndex * 14) - contentOffset).rounded())
    }

    nonisolated func semanticProductionCatalogWindowMatch(
        widths: [Int],
        heights: [Int]
    ) -> (topIndex: Int, score: Double, secondScore: Double)? {
        guard (7...8).contains(widths.count), heights.count == widths.count else {
            return nil
        }
        // RuneScape 10 measurements for the reviewed 47-entry selector catalog.
        let catalogRowMetrics = [
            (74, 9), (70, 9), (128, 11), (109, 11), (85, 11), (81, 9), (51, 9),
            (66, 11), (70, 9), (112, 11), (120, 11), (107, 11), (90, 11), (93, 11),
            (46, 11), (140, 11), (103, 11), (93, 9), (84, 9), (79, 9), (103, 11),
            (46, 9), (50, 9), (108, 11), (105, 9), (42, 11), (137, 11), (61, 9),
            (46, 9), (112, 11), (109, 11), (93, 9), (143, 11), (103, 11), (114, 11),
            (130, 11), (101, 11), (48, 11), (50, 9), (72, 11), (133, 11), (108, 11),
            (91, 11), (134, 11), (101, 11), (92, 11), (34, 9),
        ]
        let matches: [(topIndex: Int, score: Double)] =
            (0...(catalogRowMetrics.count - widths.count))
            .map { topIndex in
                let error = widths.indices.reduce(0) { partial, row in
                    let expected = catalogRowMetrics[topIndex + row]
                    return partial
                        + abs(widths[row] - expected.0)
                        + 3 * abs(heights[row] - expected.1)
                }
                return (topIndex, max(0, 1 - Double(error) / 400))
            }
            .sorted { left, right in
                left.score == right.score
                    ? left.topIndex < right.topIndex
                    : left.score > right.score
            }
        guard matches.count >= 2 else {
            return nil
        }
        return (matches[0].topIndex, matches[0].score, matches[1].score)
    }

    private func semanticSelectorScrollbarVectorAccepted(
        _ vector: [String: Any],
        anchor: String,
        localization: [String: Any],
        item: QueueItem
    ) -> Bool {
        if item.realmID == nil {
            return semanticScrollbarVectorMatches(vector, anchor: anchor, localization: localization)
        }
        guard let selectorIndex = item.selectorIndex,
              let observed = localization["normalized_observed_bbox"] as? [String: Any],
              let observedTop = number(observed["top"]),
              let targetTop = semanticProductionTargetThumbTop(
                  selectorIndex: selectorIndex,
                  observedTop: observedTop
              ),
              number(vector["target_thumb_top"]) == targetTop,
              let reference = vector["reference"] as? [String: Any],
              let referenceFrom = reference["from"] as? [String: Any],
              let referenceTo = reference["to"] as? [String: Any],
              let delivered = vector["delivered"] as? [String: Any],
              let deliveredFrom = delivered["from"] as? [String: Any],
              let deliveredTo = delivered["to"] as? [String: Any],
              let normalizedFrom = localization["normalized_click_point"] as? [String: Any],
              let sourceFrom = localization["source_click_point"] as? [String: Any],
              let track = localization["normalized_track_bbox"] as? [String: Any],
              let trackLeft = number(track["left"]),
              let trackRight = number(track["right"]),
              number(track["top"]) != nil,
              number(track["bottom"]) != nil,
              let observedBottom = number(observed["bottom"]),
              let sourceTrack = localization["source_track_bbox"] as? [String: Any],
              number(sourceTrack["left"]) != nil,
              number(sourceTrack["top"]) != nil,
              number(sourceTrack["right"]) != nil,
              number(sourceTrack["bottom"]) != nil,
              let sourceObserved = localization["source_observed_bbox"] as? [String: Any],
              let sourceObservedTop = number(sourceObserved["top"]),
              number(sourceObserved["bottom"]) != nil,
              let sourceFrame = localization["source_frame_geometry"] as? [String: Any],
              let sourceWidth = number(sourceFrame["width"]),
              let sourceHeight = number(sourceFrame["height"]),
              let sourceClickY = number(sourceFrom["y"]) else {
            return false
        }
        let expectedReferenceTo = AdapterPoint(
            x: ((trackLeft + trackRight) / 2).rounded(.down),
            y: targetTop + ((observedBottom - observedTop) / 2).rounded(.down)
        )
        let expectedDeliveredTo = semanticProductionDeliveredScrollbarTarget(
            normalizedTarget: expectedReferenceTo,
            targetTop: targetTop,
            normalizedObservedTop: observedTop,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            sourceClickY: sourceClickY,
            sourceObservedTop: sourceObservedTop
        )
        let deliveredFromY = number(deliveredFrom["y"])
        let deliveredToY = number(deliveredTo["y"])
        return number(referenceFrom["x"]) == number(normalizedFrom["x"])
            && number(referenceFrom["y"]) == number(normalizedFrom["y"])
            && number(referenceTo["x"]) == expectedReferenceTo.x
            && number(referenceTo["y"]) == expectedReferenceTo.y
            && number(deliveredFrom["x"]) == number(sourceFrom["x"])
            && number(deliveredFrom["y"]) == number(sourceFrom["y"])
            && number(deliveredTo["x"]) == expectedDeliveredTo.x
            && number(deliveredTo["y"]) == expectedDeliveredTo.y
            && semanticProductionScrollbarMovementAccepted(
                targetTop: targetTop,
                normalizedObservedTop: observedTop,
                deliveredFromY: deliveredFromY,
                deliveredToY: deliveredToY
            )
    }

    private func semanticProductionTargetThumbTop(
        selectorIndex: Int,
        observedTop: Double
    ) -> Double? {
        let currentTopIndex = Int(
            ((observedTop - 543) * 39 / 70).rounded(.up)
        )
        return semanticProductionTargetThumbTopBounds(
            selectorIndex: selectorIndex,
            currentTopIndex: currentTopIndex
        ).map { Double($0.lowerBound) }
    }

    nonisolated func semanticProductionTargetThumbTopBounds(
        selectorIndex: Int,
        currentTopIndex: Int = 0
    ) -> ClosedRange<Int>? {
        guard (0..<47).contains(selectorIndex) else { return nil }
        let targetTopIndex = semanticProductionStableTargetVisibleTopIndex(
            selectorIndex: selectorIndex,
            currentTopIndex: currentTopIndex
        )
        return semanticProductionThumbTopBounds(topIndex: targetTopIndex)
    }

    nonisolated private func semanticProductionThumbTopBounds(
        topIndex: Int
    ) -> ClosedRange<Int>? {
        let maxTopIndex = 39
        guard (0...maxTopIndex).contains(topIndex) else { return nil }
        if topIndex == maxTopIndex { return 613...613 }
        let matchingTops = (543...613).filter { observedTop in
            let inferredTopIndex = Int(
                (Double(observedTop - 543) * Double(maxTopIndex) / 70.0).rounded(.up)
            )
            return inferredTopIndex == topIndex
        }
        guard let minimum = matchingTops.first, let maximum = matchingTops.last else {
            return nil
        }
        return minimum...maximum
    }

    nonisolated func semanticProductionTargetVisibleTopIndex(
        selectorIndex: Int
    ) -> Int {
        max(0, min(39, selectorIndex - 4))
    }

    nonisolated private func semanticProductionStableTargetVisibleTopIndex(
        selectorIndex: Int,
        currentTopIndex: Int
    ) -> Int {
        let centeredTopIndex = semanticProductionTargetVisibleTopIndex(selectorIndex: selectorIndex)
        let minimumTopIndex = max(0, selectorIndex - 7)
        let maximumTopIndex = min(selectorIndex, 39)
        let direction = centeredTopIndex == currentTopIndex
            ? 0
            : (centeredTopIndex > currentTopIndex ? 1 : -1)

        return (minimumTopIndex...maximumTopIndex).min { left, right in
            guard let leftBounds = semanticProductionThumbTopBounds(topIndex: left),
                  let rightBounds = semanticProductionThumbTopBounds(topIndex: right) else {
                return left < right
            }
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

    nonisolated func semanticProductionDeliveredScrollbarTarget(
        normalizedTarget: AdapterPoint,
        targetTop: Double,
        normalizedObservedTop: Double,
        sourceWidth: Double,
        sourceHeight: Double,
        sourceClickY: Double,
        sourceObservedTop: Double
    ) -> AdapterPoint {
        let sourcePixelScale = max(1, (sourceHeight / 839).rounded())
        let transferPixelCount = semanticProductionScrollbarTransferPixelCount(
            targetTop: targetTop
        )
        let transferDirection = targetTop == normalizedObservedTop
            ? 0.0
            : (targetTop > normalizedObservedTop ? 1.0 : -1.0)
        return AdapterPoint(
            x: (normalizedTarget.x * sourceWidth / 768).rounded(),
            y: (targetTop * sourceHeight / 839).rounded()
                + sourceClickY - sourceObservedTop
                + transferDirection * (sourcePixelScale + transferPixelCount)
        )
    }

    nonisolated func semanticProductionScrollbarTransferPixelCount(
        targetTop: Double
    ) -> Double {
        let maxTopIndex = 39
        let targetTopIndex = Int(
            ((targetTop - 543) * Double(maxTopIndex) / 70).rounded(.up)
        )
        guard let bounds = semanticProductionThumbTopBounds(topIndex: targetTopIndex) else {
            return 1
        }
        return Double(bounds.upperBound - bounds.lowerBound + 1)
    }

    nonisolated func semanticProductionScrollbarMovementAccepted(
        targetTop: Double,
        normalizedObservedTop: Double,
        deliveredFromY: Double?,
        deliveredToY: Double?
    ) -> Bool {
        guard let deliveredFromY, let deliveredToY else { return false }
        return targetTop != normalizedObservedTop && deliveredToY != deliveredFromY
    }

    private func semanticScrollbarGeometryPassed(_ proof: [String: Any]) -> Bool {
        guard let track = proof["normalized_track_bbox"] as? [String: Any],
              let trackLeft = number(track["left"]),
              let trackTop = number(track["top"]),
              let trackRight = number(track["right"]),
              let trackBottom = number(track["bottom"]),
              trackLeft >= 330,
              trackTop >= 525,
              trackRight <= 365,
              trackBottom <= 655,
              trackRight - trackLeft == 14,
              trackBottom - trackTop == 86,
              let observed = proof["normalized_observed_bbox"] as? [String: Any],
              number(observed["left"]) == trackLeft,
              let observedTop = number(observed["top"]),
              number(observed["right"]) == trackRight,
              let observedBottom = number(observed["bottom"]),
              observedBottom - observedTop == 16,
              observedTop >= trackTop,
              observedBottom <= trackBottom,
              let upButton = proof["normalized_up_button_bbox"] as? [String: Any],
              number(upButton["left"]) == trackLeft,
              number(upButton["right"]) == trackRight,
              let upTop = number(upButton["top"]),
              let upBottom = number(upButton["bottom"]),
              upBottom == trackTop,
              upBottom - upTop == 14,
              let downButton = proof["normalized_down_button_bbox"] as? [String: Any],
              number(downButton["left"]) == trackLeft,
              number(downButton["right"]) == trackRight,
              let downTop = number(downButton["top"]),
              let downBottom = number(downButton["bottom"]),
              downTop == trackBottom,
              downBottom - downTop == 14,
              proof["target"] as? String == "SEMANTIC_SURFACE_SCROLLBAR_THUMB",
              proof["selector_open"] as? Bool == true,
              proof["exactly_one_target"] as? Bool == true,
              number(proof["pixel_resolution"]) == 1,
              proof["coordinate_semantics"] as? String
                == "LEFT_TOP_INCLUSIVE_RIGHT_BOTTOM_EXCLUSIVE",
              number(proof["stop_tolerance_pixels"]) == 0,
              let correlation = number(proof["normalized_correlation"]),
              correlation >= 0.72,
              let second = number(proof["distinct_second_correlation"]),
              correlation - second >= 0.08,
              let recordedSeparation = number(proof["correlation_separation"]),
              abs(recordedSeparation - (correlation - second)) < 0.000_000_001,
              semanticScrollbarButtonProofPassed(proof, direction: "up"),
              semanticScrollbarButtonProofPassed(proof, direction: "down"),
              semanticScrollbarBoundsMatch(
                proof,
                top: trackTop,
                bottom: trackBottom - 16
              ),
              proof["source_click_point"] is [String: Any],
              proof["source_frame_geometry"] is [String: Any],
              semanticScrollbarTrackMatches(proof) else {
            return false
        }
        let state = proof["state"] as? String
        let expectedState = observedTop == trackTop
            ? "top"
            : (observedBottom == trackBottom ? "bottom" : "intermediate")
        let expectedTopClearance = observedTop - trackTop
        let expectedBottomClearance = trackBottom - observedBottom
        return proof["anchor"] as? String == expectedState
            && state == expectedState
            && proof["thumb_at_stop"] as? Bool == (expectedState != "intermediate")
            && number(proof["top_clearance_pixels"]) == expectedTopClearance
            && number(proof["bottom_clearance_pixels"]) == expectedBottomClearance
            && number(proof["remaining_travel_to_top_pixels"]) == expectedTopClearance
            && number(proof["remaining_travel_to_bottom_pixels"]) == expectedBottomClearance
            && number(proof["travel_range_pixels"]) == 70
    }

    private func semanticGatePassed(
        _ gate: [String: Any],
        surface: SemanticMapSurface?
    ) -> Bool {
        gate["passed"] as? Bool == true
            && gate["requested_surface"] as? String == surface?.rawValue
            && gate["observed_surface"] as? String == surface?.rawValue
            && gate["nonblack"] as? Bool == true
    }

    func semanticScrollbarProofPassed(
        _ proof: [String: Any],
        anchor: String
    ) -> Bool {
        guard anchor == "top" || anchor == "bottom",
              let track = proof["normalized_track_bbox"] as? [String: Any],
              let trackLeft = number(track["left"]),
              let trackTop = number(track["top"]),
              let trackRight = number(track["right"]),
              let trackBottom = number(track["bottom"]),
              trackLeft >= 330,
              trackTop >= 525,
              trackRight <= 365,
              trackBottom <= 655,
              trackRight - trackLeft == 14,
              trackBottom - trackTop == 86,
              let observed = proof["normalized_observed_bbox"] as? [String: Any],
              number(observed["left"]) == trackLeft,
              let observedTop = number(observed["top"]),
              number(observed["right"]) == trackRight,
              let observedBottom = number(observed["bottom"]),
              observedBottom - observedTop == 16,
              let upButton = proof["normalized_up_button_bbox"] as? [String: Any],
              number(upButton["left"]) == trackLeft,
              number(upButton["right"]) == trackRight,
              let upTop = number(upButton["top"]),
              let upBottom = number(upButton["bottom"]),
              upBottom == trackTop,
              upBottom - upTop == 14,
              let downButton = proof["normalized_down_button_bbox"] as? [String: Any],
              number(downButton["left"]) == trackLeft,
              number(downButton["right"]) == trackRight,
              let downTop = number(downButton["top"]),
              let downBottom = number(downButton["bottom"]),
              downTop == trackBottom,
              downBottom - downTop == 14,
              proof["target"] as? String == "SEMANTIC_SURFACE_SCROLLBAR_THUMB",
              proof["anchor"] as? String == anchor,
              proof["state"] as? String == anchor,
              proof["selector_open"] as? Bool == true,
              proof["thumb_at_stop"] as? Bool == true,
              proof["exactly_one_target"] as? Bool == true,
              number(proof["pixel_resolution"]) == 1,
              proof["coordinate_semantics"] as? String
                == "LEFT_TOP_INCLUSIVE_RIGHT_BOTTOM_EXCLUSIVE",
              number(proof["stop_tolerance_pixels"]) == 0,
              let correlation = number(proof["normalized_correlation"]),
              correlation >= 0.72,
              let second = number(proof["distinct_second_correlation"]),
              correlation - second >= 0.08,
              let recordedSeparation = number(proof["correlation_separation"]),
              abs(recordedSeparation - (correlation - second)) < 0.000_000_001,
              semanticScrollbarButtonProofPassed(proof, direction: "up"),
              semanticScrollbarButtonProofPassed(proof, direction: "down") else {
            return false
        }
        let expectedTop = anchor == "top" ? trackTop : trackBottom - 16
        let expectedBottom = expectedTop + 16
        let expectedTopClearance = expectedTop - trackTop
        let expectedBottomClearance = trackBottom - expectedBottom
        guard observedTop == expectedTop,
              observedBottom == expectedBottom,
              number(proof["top_clearance_pixels"]) == expectedTopClearance,
              number(proof["bottom_clearance_pixels"]) == expectedBottomClearance,
              number(proof["remaining_travel_to_top_pixels"]) == expectedTopClearance,
              number(proof["remaining_travel_to_bottom_pixels"]) == expectedBottomClearance,
              number(proof["travel_range_pixels"]) == 70,
              semanticScrollbarBoundsMatch(
                proof,
                top: trackTop,
                bottom: trackBottom - 16
              ),
              proof["source_click_point"] is [String: Any],
              proof["source_frame_geometry"] is [String: Any],
              semanticScrollbarTrackMatches(proof) else {
            return false
        }
        return true
    }

    private func semanticScrollbarButtonProofPassed(
        _ proof: [String: Any],
        direction: String
    ) -> Bool {
        guard let correlation = number(proof["\(direction)_button_correlation"]),
              correlation >= 0.72,
              let second = number(proof["\(direction)_button_distinct_second_correlation"]),
              correlation - second >= 0.08 else {
            return false
        }
        return true
    }

    private func semanticScrollbarBoundsMatch(
        _ proof: [String: Any],
        top expectedTop: Double,
        bottom expectedBottom: Double
    ) -> Bool {
        guard let top = proof["top_stop_thumb_top_bounds"] as? [String: Any],
              number(top["minimum"]) == expectedTop,
              number(top["maximum"]) == expectedTop,
              let bottom = proof["bottom_stop_thumb_top_bounds"] as? [String: Any],
              number(bottom["minimum"]) == expectedBottom,
              number(bottom["maximum"]) == expectedBottom else {
            return false
        }
        return true
    }

    private func semanticScrollbarTrackMatches(_ proof: [String: Any]) -> Bool {
        guard let normalized = proof["normalized_track_bbox"] as? [String: Any],
              let normalizedLeft = number(normalized["left"]),
              let normalizedTop = number(normalized["top"]),
              let normalizedRight = number(normalized["right"]),
              let normalizedBottom = number(normalized["bottom"]),
              let source = proof["source_track_bbox"] as? [String: Any],
              let geometry = proof["source_frame_geometry"] as? [String: Any],
              let width = number(geometry["width"]),
              let height = number(geometry["height"]),
              let left = number(source["left"]),
              let top = number(source["top"]),
              let right = number(source["right"]),
              let bottom = number(source["bottom"]),
              left == (normalizedLeft * width / 768).rounded(),
              top == (normalizedTop * height / 839).rounded(),
              right == (normalizedRight * width / 768).rounded(),
              bottom == (normalizedBottom * height / 839).rounded(),
              let normalizedPoint = proof["normalized_click_point"] as? [String: Any],
              let normalizedX = number(normalizedPoint["x"]),
              let normalizedY = number(normalizedPoint["y"]),
              let point = proof["source_click_point"] as? [String: Any],
              let x = number(point["x"]),
              let y = number(point["y"]),
              let observed = proof["source_observed_bbox"] as? [String: Any],
              let observedLeft = number(observed["left"]),
              let observedTop = number(observed["top"]),
              let observedRight = number(observed["right"]),
              let observedBottom = number(observed["bottom"]),
              let normalizedObserved = proof["normalized_observed_bbox"] as? [String: Any],
              let normalizedObservedLeft = number(normalizedObserved["left"]),
              let normalizedObservedTop = number(normalizedObserved["top"]),
              let normalizedObservedRight = number(normalizedObserved["right"]),
              let normalizedObservedBottom = number(normalizedObserved["bottom"]),
              observedLeft == (normalizedObservedLeft * width / 768).rounded(),
              observedTop == (normalizedObservedTop * height / 839).rounded(),
              observedRight == (normalizedObservedRight * width / 768).rounded(),
              observedBottom == (normalizedObservedBottom * height / 839).rounded(),
              x == (normalizedX * width / 768).rounded(),
              y == (normalizedY * height / 839).rounded(),
              number(proof["source_top_clearance_pixels"]) == observedTop - top,
              number(proof["source_bottom_clearance_pixels"]) == bottom - observedBottom else {
            return false
        }
        return x >= left && x < right && y >= top && y < bottom
    }

    private func semanticScrollbarVectorMatches(
        _ vector: [String: Any],
        anchor: String,
        localization: [String: Any]
    ) -> Bool {
        guard anchor == "top" || anchor == "bottom",
              let reference = vector["reference"] as? [String: Any],
              let referenceFrom = reference["from"] as? [String: Any],
              let referenceTo = reference["to"] as? [String: Any],
              let delivered = vector["delivered"] as? [String: Any],
              let deliveredFrom = delivered["from"] as? [String: Any],
              let deliveredTo = delivered["to"] as? [String: Any],
              let localizedFrom = localization["source_click_point"] as? [String: Any],
              let normalizedFrom = localization["normalized_click_point"] as? [String: Any],
              let track = localization["normalized_track_bbox"] as? [String: Any],
              let trackLeft = number(track["left"]),
              let trackTop = number(track["top"]),
              let trackRight = number(track["right"]),
              let trackBottom = number(track["bottom"]),
              let sourceTrack = localization["source_track_bbox"] as? [String: Any],
              let sourceTrackLeft = number(sourceTrack["left"]),
              let sourceTrackTop = number(sourceTrack["top"]),
              let sourceTrackRight = number(sourceTrack["right"]),
              let sourceTrackBottom = number(sourceTrack["bottom"]) else {
            return false
        }
        let expectedReferenceTo = AdapterPoint(
            x: ((trackLeft + trackRight) / 2).rounded(.down),
            y: anchor == "bottom" ? trackBottom - 1 : trackTop
        )
        let expectedDeliveredTo = AdapterPoint(
            x: ((sourceTrackLeft + sourceTrackRight) / 2).rounded(.down),
            y: anchor == "bottom" ? sourceTrackBottom - 1 : sourceTrackTop
        )
        return number(referenceFrom["x"]) == number(normalizedFrom["x"])
            && number(referenceFrom["y"]) == number(normalizedFrom["y"])
            && number(referenceTo["x"]) == expectedReferenceTo.x
            && number(referenceTo["y"]) == expectedReferenceTo.y
            && number(deliveredFrom["x"]) == number(localizedFrom["x"])
            && number(deliveredFrom["y"]) == number(localizedFrom["y"])
            && number(deliveredTo["x"]) == expectedDeliveredTo.x
            && number(deliveredTo["y"]) == expectedDeliveredTo.y
    }

    private func semanticSameFamilyPassed(_ value: Any?) -> Bool {
        value is NSNull || (number(value).map { $0 >= 2.5 } ?? false)
    }

    private func semanticZoomIndex(_ value: Double?) -> Int {
        [37.5, 50, 75, 100, 200].firstIndex(of: value ?? -1) ?? -1
    }

    private func semanticVectorMatches(
        _ vector: [String: Any],
        family: SemanticCriterionFamily?,
        reversed: Bool,
        expectedForwardDisplacement: [String: Any]? = nil
    ) -> Bool {
        let expected: (AdapterPoint, AdapterPoint)
        switch family {
        case .eastwardTopology:
            expected = (AdapterPoint(x: 430, y: 300), AdapterPoint(x: 90, y: 300))
        case .southwardTopology:
            expected = (AdapterPoint(x: 260, y: 560), AdapterPoint(x: 260, y: 150))
        case .westwardBoundary:
            expected = (AdapterPoint(x: 90, y: 300), AdapterPoint(x: 430, y: 300))
        case .northwardDetail:
            expected = (AdapterPoint(x: 260, y: 150), AdapterPoint(x: 260, y: 560))
        case .centerDetail:
            expected = (AdapterPoint(x: 420, y: 520), AdapterPoint(x: 150, y: 210))
        case nil:
            return false
        }
        guard let reference = vector["reference"] as? [String: Any],
              let from = reference["from"] as? [String: Any],
              let to = reference["to"] as? [String: Any] else { return false }
        if reversed,
           vector["measurement_kind"] as? String == "MEASURED_EFFECTIVE_FORWARD_DISPLACEMENT" {
            return semanticMeasuredInverseVector(
                vector,
                referenceFrom: from,
                referenceTo: to,
                expectedForward: expected,
                expectedForwardDisplacement: expectedForwardDisplacement
            )
        }
        let expectedFrom = reversed ? expected.1 : expected.0
        let expectedTo = reversed ? expected.0 : expected.1
        guard number(from["x"]) == expectedFrom.x
            && number(from["y"]) == expectedFrom.y
            && number(to["x"]) == expectedTo.x
            && number(to["y"]) == expectedTo.y else {
            return false
        }
        if reversed { return true }
        let profileFraction = integer(vector["profile_fraction_percent"]) ?? 100
        guard profileFraction >= 5,
              profileFraction <= 100,
              profileFraction % 5 == 0,
              (profileFraction == 100) == (vector["profile_fraction_percent"] == nil),
              let translation = vector["anchor_translation"] as? [String: Any],
              let translationX = integer(translation["x"]),
              let translationY = integer(translation["y"]),
              abs(translationX) <= 36,
              abs(translationY) <= 36,
              let translated = vector["translated_reference"] as? [String: Any],
              let translatedFrom = translated["from"] as? [String: Any],
              let translatedTo = translated["to"] as? [String: Any],
              let scaledToX = scaledMotionCoordinate(
                from: expectedFrom.x,
                to: expectedTo.x,
                profileFraction: profileFraction
              ),
              let scaledToY = scaledMotionCoordinate(
                from: expectedFrom.y,
                to: expectedTo.y,
                profileFraction: profileFraction
              ),
              number(translatedFrom["x"]) == expectedFrom.x + Double(translationX),
              number(translatedFrom["y"]) == expectedFrom.y + Double(translationY),
              number(translatedTo["x"]) == scaledToX + Double(translationX),
              number(translatedTo["y"]) == scaledToY + Double(translationY),
              hypot(scaledToX - expectedFrom.x, scaledToY - expectedFrom.y) >= 10 else {
            return false
        }
        if profileFraction < 100 {
            guard let retention = vector["sparse_retention"] as? [String: Any],
                  semanticSparseRetentionMatches(
                    retention,
                    profileFraction: profileFraction,
                    projectedX: scaledToX - expectedFrom.x,
                    projectedY: scaledToY - expectedFrom.y
                  ) else { return false }
        } else if vector["sparse_retention"] != nil {
            return false
        }
        for point in [translatedFrom, translatedTo] {
            guard let x = number(point["x"]), let y = number(point["y"]),
                  x > 4, x < 474, y > 70, y < 630 else { return false }
        }
        return true
    }

    private func scaledMotionCoordinate(
        from: Double,
        to: Double,
        profileFraction: Int
    ) -> Double? {
        guard profileFraction >= 5, profileFraction <= 100 else { return nil }
        return from + floor(((to - from) * Double(profileFraction) / 100) + 0.5)
    }

    private func semanticSparseRetentionMatches(
        _ retention: [String: Any],
        profileFraction: Int,
        projectedX: Double,
        projectedY: Double
    ) -> Bool {
        guard retention["strategy"] as? String == "KEEP_VISIBLE_INFORMATIVE_SUPPORT",
              integer(retention["profile_fraction_percent"]) == profileFraction,
              let projected = retention["projected_displacement_reference"] as? [String: Any],
              number(projected["x"]) == projectedX,
              number(projected["y"]) == projectedY,
              let originalInformative = integer(retention["original_informative_pixels"]),
              let originalChromatic = integer(retention["original_chromatic_pixels"]),
              let retainedInformative = integer(retention["retained_informative_pixels"]),
              let retainedChromatic = integer(retention["retained_chromatic_pixels"]),
              let minimumInformative = integer(retention["minimum_retained_informative_pixels"]),
              let minimumChromatic = integer(retention["minimum_retained_chromatic_pixels"]),
              originalInformative >= 64,
              originalChromatic >= 8,
              minimumInformative == max(64, Int(ceil(Double(originalInformative) * 0.2))),
              minimumChromatic == max(8, Int(ceil(Double(originalChromatic) * 0.2))),
              retainedInformative >= minimumInformative,
              retainedInformative <= originalInformative,
              retainedChromatic >= minimumChromatic,
              retainedChromatic <= originalChromatic,
              let retainedFraction = number(retention["retained_fraction"]),
              abs(retainedFraction - Double(retainedInformative) / Double(originalInformative)) < 1e-9 else {
            return false
        }
        return true
    }

    private func semanticScaledNoveltyMatches(
        _ displacement: [String: Any],
        vector: [String: Any]
    ) -> Bool {
        guard vector["profile_fraction_percent"] != nil else { return true }
        guard let translated = vector["translated_reference"] as? [String: Any],
              let from = translated["from"] as? [String: Any],
              let to = translated["to"] as? [String: Any],
              let fromX = number(from["x"]), let fromY = number(from["y"]),
              let toX = number(to["x"]), let toY = number(to["y"]),
              let expected = displacement["expected_displacement"] as? [String: Any],
              number(expected["dx"]) == ((toX - fromX) / 5).rounded(),
              number(expected["dy"]) == ((toY - fromY) / 5).rounded() else {
            return false
        }
        return true
    }

    private func semanticActionMatchesVector(
        _ action: [String: Any],
        vector: [String: Any]
    ) -> Bool {
        guard let operation = action["operation"] as? [String: Any],
              operation["kind"] as? String == "drag",
              let operationFrom = operation["from"] as? [String: Any],
              let operationTo = operation["to"] as? [String: Any],
              let delivered = vector["delivered"] as? [String: Any],
              let deliveredFrom = delivered["from"] as? [String: Any],
              let deliveredTo = delivered["to"] as? [String: Any] else {
            return false
        }
        return number(operationFrom["x"]) == number(deliveredFrom["x"])
            && number(operationFrom["y"]) == number(deliveredFrom["y"])
            && number(operationTo["x"]) == number(deliveredTo["x"])
            && number(operationTo["y"]) == number(deliveredTo["y"])
    }

    private func semanticMeasuredInverseVector(
        _ vector: [String: Any],
        referenceFrom: [String: Any],
        referenceTo: [String: Any],
        expectedForward: (AdapterPoint, AdapterPoint),
        expectedForwardDisplacement: [String: Any]?
    ) -> Bool {
        guard integer(vector["displacement_cell_size_reference_pixels"]) == 5,
              let frame = vector["reference_frame"] as? [String: Any],
              integer(frame["width"]) == 768,
              integer(frame["height"]) == 839,
              let measured = vector["measured_forward_displacement"] as? [String: Any],
              let dx = integer(measured["dx"]),
              let dy = integer(measured["dy"]),
              let restoration = vector["restoration_displacement"] as? [String: Any],
              let restorationDX = integer(restoration["x"]),
              let restorationDY = integer(restoration["y"]),
              let fromX = integer(referenceFrom["x"]),
              let fromY = integer(referenceFrom["y"]),
              let toX = integer(referenceTo["x"]),
              let toY = integer(referenceTo["y"]),
              let anchor = vector["anchor_proof"] as? [String: Any],
              let anchorPoint = anchor["reference_point"] as? [String: Any],
              integer(anchorPoint["x"]) == fromX,
              integer(anchorPoint["y"]) == fromY,
              let localInformativePixels = integer(anchor["local_informative_pixels"]),
              let neighborhoodPixels = integer(anchor["neighborhood_pixels"]),
              localInformativePixels >= 25,
              neighborhoodPixels == 121,
              localInformativePixels <= neighborhoodPixels,
              anchor["selection_strategy"] as? String == "LOWEST_GRADIENT_NEAREST_FEASIBLE_CENTER",
              let gradientRisk = number(anchor["gradient_risk"]),
              gradientRisk >= 0,
              toX - fromX == -restorationDX * 5,
              toY - fromY == -restorationDY * 5,
              hypot(Double(dx), Double(dy)) >= 2 else {
            return false
        }
        let maximumDX = Int(abs(expectedForward.1.x - expectedForward.0.x) / 5)
        let maximumDY = Int(abs(expectedForward.1.y - expectedForward.0.y) / 5)
        let expectedDXSign = Int((expectedForward.1.x - expectedForward.0.x).sign == .minus ? -1 : 1)
        let expectedDYSign = Int((expectedForward.1.y - expectedForward.0.y).sign == .minus ? -1 : 1)
        let suppliedExpectedDX = integer(expectedForwardDisplacement?["dx"])
        let suppliedExpectedDY = integer(expectedForwardDisplacement?["dy"])
        if let vectorExpected = vector["expected_forward_displacement"] as? [String: Any] {
            guard let vectorExpectedDX = integer(vectorExpected["dx"]),
                  let vectorExpectedDY = integer(vectorExpected["dy"]),
                  vectorExpectedDX == suppliedExpectedDX,
                  vectorExpectedDY == suppliedExpectedDY else {
                return false
            }
        }
        let xPassed = maximumDX == 0
            ? abs(dx) <= 1
            : abs(dx) <= maximumDX && (dx == 0 || dx.signum() == expectedDXSign)
        let yPassed = maximumDY == 0
            ? abs(dy) <= 1
            : abs(dy) <= maximumDY && (dy == 0 || dy.signum() == expectedDYSign)
        return xPassed && yPassed
            && semanticRestorationAxisPassed(
                measured: dx,
                restoration: restorationDX,
                maximum: maximumDX,
                expectedSign: expectedDXSign,
                expected: suppliedExpectedDX
            )
            && semanticRestorationAxisPassed(
                measured: dy,
                restoration: restorationDY,
                maximum: maximumDY,
                expectedSign: expectedDYSign,
                expected: suppliedExpectedDY
            )
            && fromX > 4 && fromX < 474 && fromY > 70 && fromY < 630
            && toX > 4 && toX < 474 && toY > 70 && toY < 630
    }

    private func semanticRestorationAxisPassed(
        measured: Int,
        restoration: Int,
        maximum: Int,
        expectedSign: Int,
        expected: Int?
    ) -> Bool {
        guard maximum > 0 else { return restoration == measured }
        if restoration == measured { return true }
        if let expected,
           abs(expected) <= maximum,
           (expected == 0 || expected.signum() == expectedSign),
           abs(expected - measured) <= 2,
           restoration == measured + (expected - measured).signum() {
            return true
        }
        return maximum - abs(measured) <= 2
            && restoration == expectedSign * maximum
    }

    private func semanticRestorationMeasurementMatches(
        _ vector: [String: Any],
        restoration: [String: Any]
    ) -> Bool {
        guard vector["measurement_kind"] as? String
                == "MEASURED_EFFECTIVE_FORWARD_DISPLACEMENT" else {
            return true
        }
        guard let vectorMeasurement = vector["measured_forward_displacement"] as? [String: Any],
              let proofMeasurement = restoration["measured_forward_displacement"] as? [String: Any],
              integer(vectorMeasurement["cell_size_reference_pixels"]) == 5,
              integer(proofMeasurement["cell_size_reference_pixels"]) == 5 else {
            return false
        }
        return integer(vectorMeasurement["dx"]) == integer(proofMeasurement["dx"])
            && integer(vectorMeasurement["dy"]) == integer(proofMeasurement["dy"])
            && integer(vectorMeasurement["cell_size_reference_pixels"])
                == integer(proofMeasurement["cell_size_reference_pixels"])
    }

    nonisolated private func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    nonisolated private func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        let integer = number.intValue
        return number.doubleValue == Double(integer) ? integer : nil
    }

    private func validateReference(
        path: String?,
        sha256: String?,
        artifactRoot: String,
        error: String
    ) throws {
        guard let path, let sha256 else { throw AdapterError.queueRejected(error) }
        let allowedRoots = [URL(fileURLWithPath: artifactRoot), hostEvidenceRoot]
            .compactMap { $0?.resolvingSymlinksInPath().path }
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard allowedRoots.contains(where: { root in
            url.path == root || url.path.hasPrefix(root + "/")
        }) else {
            throw AdapterError.queueRejected(error)
        }
        try requireImmutableRegularFile(url, expectedSHA256: sha256)
    }

    private func requireImmutableRegularFile(
        _ url: URL,
        expectedSHA256: String?
    ) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o444 else {
            throw AdapterError.queueRejected("BROKER_IMMUTABLE_FILE_REQUIRED:\(url.path)")
        }
        if let expectedSHA256,
           try AdapterHashing.sha256(fileAt: url) != expectedSHA256.lowercased() {
            throw AdapterError.queueRejected("BROKER_FILE_SHA256_MISMATCH:\(url.path)")
        }
    }

    private func writeHead(_ head: SandboxBrokerHead) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(head)
        data.append(0x0A)
        let destination = root.appendingPathComponent("HEAD.json")
        let temporary = root.appendingPathComponent(".HEAD.json.tmp-\(UUID().uuidString)")
        guard fileManager.createFile(
            atPath: temporary.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw AdapterError.queueRejected("BROKER_HEAD_CREATE_FAILED")
        }
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            let result = temporary.path.withCString { source in
                destination.path.withCString { target in rename(source, target) }
            }
            guard result == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: destination.path
            )
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }
}
