import Foundation
import JavaScriptCore

public enum QueueOperationKind: String, Codable, CaseIterable, Sendable {
    case capture
    case click
    case drag
    case openWorldMap = "open_world_map"
}

public enum QueueExecutionProfile: String, Codable, Sendable {
    case semanticMapCaptureV1 = "semantic_map_capture_v1"
}

public struct SemanticMapSurface: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let gielinorSurface = SemanticMapSurface(rawValue: "Gielinor Surface")
    public static let ancientCavern = SemanticMapSurface(rawValue: "Ancient Cavern")
    public static let ardougneUnderground = SemanticMapSurface(rawValue: "Ardougne Underground")
    public static let asgarniaIceCave = SemanticMapSurface(rawValue: "Asgarnia Ice Cave")
    public static let zanaris = SemanticMapSurface(rawValue: "Zanaris")

    public static let allCases: [SemanticMapSurface] = [
        .gielinorSurface,
        .ancientCavern,
        .ardougneUnderground,
        .asgarniaIceCave,
        .zanaris
    ]
}

public struct SemanticCaptureCenter: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
}

public struct SemanticBounds: Codable, Equatable, Sendable {
    public let minX: Double
    public let minY: Double
    public let maxX: Double
    public let maxY: Double

    enum CodingKeys: String, CodingKey {
        case minX = "min_x"
        case minY = "min_y"
        case maxX = "max_x"
        case maxY = "max_y"
    }
}

public struct SemanticCoverageViewport: Codable, Equatable, Sendable {
    public let width: Double
    public let height: Double
    public let zoomPercent: Double?
    public let overlapFraction: Double?

    enum CodingKeys: String, CodingKey {
        case width
        case height
        case zoomPercent = "zoom_percent"
        case overlapFraction = "overlap_fraction"
    }
}

public struct SemanticCoverageCrop: Codable, Equatable, Sendable {
    public let left: Int
    public let top: Int
    public let width: Int
    public let height: Int
}

public struct SemanticCoverageCell: Codable, Equatable, Sendable {
    public let row: Int
    public let column: Int
    public let realmBounds: SemanticBounds
    public let captureBounds: SemanticBounds
    public let viewport: SemanticCoverageViewport
    public let coverageCrop: SemanticCoverageCrop?
    public let coveragePlane: Int?
    public let resetCenter: SemanticCaptureCenter?
    public let anchorAttemptBudget: Int?

    public init(
        row: Int,
        column: Int,
        realmBounds: SemanticBounds,
        captureBounds: SemanticBounds,
        viewport: SemanticCoverageViewport,
        coverageCrop: SemanticCoverageCrop? = nil,
        coveragePlane: Int? = nil,
        resetCenter: SemanticCaptureCenter? = nil,
        anchorAttemptBudget: Int? = nil
    ) {
        self.row = row
        self.column = column
        self.realmBounds = realmBounds
        self.captureBounds = captureBounds
        self.viewport = viewport
        self.coverageCrop = coverageCrop
        self.coveragePlane = coveragePlane
        self.resetCenter = resetCenter
        self.anchorAttemptBudget = anchorAttemptBudget
    }

    enum CodingKeys: String, CodingKey {
        case row
        case column
        case realmBounds = "realm_bounds"
        case captureBounds = "capture_bounds"
        case viewport
        case coverageCrop = "coverage_crop"
        case coveragePlane = "coverage_plane"
        case resetCenter = "reset_center"
        case anchorAttemptBudget = "anchor_attempt_budget"
    }
}

public enum SemanticCriterionFamily: String, Codable, CaseIterable, Sendable {
    case eastwardTopology = "eastward_topology"
    case southwardTopology = "southward_topology"
    case westwardBoundary = "westward_boundary"
    case northwardDetail = "northward_detail"
    case centerDetail = "center_detail"
}

public enum SemanticActionRole: String, Codable, Sendable {
    case recoveryTryAgain = "recovery_try_again"
    case recoverySteamSignIn = "recovery_steam_sign_in"
    case recoveryClickToPlay = "recovery_click_to_play"
    case recoveryOpenWorldMap = "recovery_open_world_map"
    case surfaceSelectorOpen = "surface_selector_open"
    case surfaceSelectorScrollbarDrag = "surface_selector_scrollbar_drag"
    case surfaceOptionSelect = "surface_option_select"
    case zoomMinus = "zoom_minus"
    case zoomPlus = "zoom_plus"
    case coverageResetSelectorOpen = "coverage_reset_selector_open"
    case coverageResetScrollbarDrag = "coverage_reset_scrollbar_drag"
    case coverageResetOptionSelect = "coverage_reset_option_select"
    case coverageMapClose = "coverage_map_close"
    case coverageMapReopen = "coverage_map_reopen"
    case coverageAnchor = "coverage_anchor"
    case coveragePan = "coverage_pan"
    case pan
    case restore
}

public struct QueueOperation: Codable, Equatable, Sendable {
    public let kind: QueueOperationKind
    public let point: AdapterPoint?
    public let button: MouseButton?
    public let from: AdapterPoint?
    public let to: AdapterPoint?
    public let eventSourceMode: EventSourceMode?
    public let deliveryMode: InputDeliveryMode?

    public init(
        kind: QueueOperationKind,
        point: AdapterPoint? = nil,
        button: MouseButton? = nil,
        from: AdapterPoint? = nil,
        to: AdapterPoint? = nil,
        eventSourceMode: EventSourceMode? = nil,
        deliveryMode: InputDeliveryMode? = nil
    ) {
        self.kind = kind
        self.point = point
        self.button = button
        self.from = from
        self.to = to
        self.eventSourceMode = eventSourceMode
        self.deliveryMode = deliveryMode
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case point
        case button
        case from
        case to
        case eventSourceMode = "event_source_mode"
        case deliveryMode = "delivery_mode"
    }
}

public struct QueueItem: Codable, Equatable, Sendable {
    public let id: String
    public let kind: String
    public let itemSHA256: String
    public let operations: [QueueOperation]
    public let supersedesItemIdentifier: String?
    public let repairLineage: [String]?
    public let surface: SemanticMapSurface?
    public let realmID: String?
    public let catalogVersion: String?
    public let plannerVersion: String?
    public let selectorIndex: Int?
    public let captureCenter: SemanticCaptureCenter?
    public let coverageCell: SemanticCoverageCell?
    public let zoomPercent: Double?
    public let criterionFamily: SemanticCriterionFamily?
    public let restoreAfterCapture: Bool?

    public init(
        id: String,
        kind: String,
        itemSHA256: String,
        operations: [QueueOperation] = [],
        supersedesItemIdentifier: String? = nil,
        repairLineage: [String]? = nil,
        surface: SemanticMapSurface? = nil,
        realmID: String? = nil,
        catalogVersion: String? = nil,
        plannerVersion: String? = nil,
        selectorIndex: Int? = nil,
        captureCenter: SemanticCaptureCenter? = nil,
        coverageCell: SemanticCoverageCell? = nil,
        zoomPercent: Double? = nil,
        criterionFamily: SemanticCriterionFamily? = nil,
        restoreAfterCapture: Bool? = nil
    ) {
        self.id = id
        self.kind = kind
        self.itemSHA256 = itemSHA256
        self.operations = operations
        self.supersedesItemIdentifier = supersedesItemIdentifier
        self.repairLineage = repairLineage
        self.surface = surface
        self.realmID = realmID
        self.catalogVersion = catalogVersion
        self.plannerVersion = plannerVersion
        self.selectorIndex = selectorIndex
        self.captureCenter = captureCenter
        self.coverageCell = coverageCell
        self.zoomPercent = zoomPercent
        self.criterionFamily = criterionFamily
        self.restoreAfterCapture = restoreAfterCapture
    }

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case itemSHA256 = "item_sha256"
        case operations
        case supersedesItemIdentifier = "supersedes_item_id"
        case repairLineage = "repair_lineage"
        case surface
        case realmID = "realm_id"
        case catalogVersion = "catalog_version"
        case plannerVersion = "planner_version"
        case selectorIndex = "selector_index"
        case captureCenter = "capture_center"
        case coverageCell = "coverage_cell"
        case zoomPercent = "zoom_percent"
        case criterionFamily = "criterion_family"
        case restoreAfterCapture = "restore_after_capture"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(String.self, forKey: .kind)
        itemSHA256 = try container.decode(String.self, forKey: .itemSHA256)
        operations = try container.decodeIfPresent([QueueOperation].self, forKey: .operations) ?? []
        supersedesItemIdentifier = try container.decodeIfPresent(String.self, forKey: .supersedesItemIdentifier)
        repairLineage = try container.decodeIfPresent([String].self, forKey: .repairLineage)
        surface = try container.decodeIfPresent(SemanticMapSurface.self, forKey: .surface)
        realmID = try container.decodeIfPresent(String.self, forKey: .realmID)
        catalogVersion = try container.decodeIfPresent(String.self, forKey: .catalogVersion)
        plannerVersion = try container.decodeIfPresent(String.self, forKey: .plannerVersion)
        selectorIndex = try container.decodeIfPresent(Int.self, forKey: .selectorIndex)
        captureCenter = try container.decodeIfPresent(SemanticCaptureCenter.self, forKey: .captureCenter)
        coverageCell = try container.decodeIfPresent(SemanticCoverageCell.self, forKey: .coverageCell)
        zoomPercent = try container.decodeIfPresent(Double.self, forKey: .zoomPercent)
        criterionFamily = try container.decodeIfPresent(SemanticCriterionFamily.self, forKey: .criterionFamily)
        restoreAfterCapture = try container.decodeIfPresent(Bool.self, forKey: .restoreAfterCapture)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(itemSHA256, forKey: .itemSHA256)
        if !operations.isEmpty {
            try container.encode(operations, forKey: .operations)
        }
        try container.encodeIfPresent(supersedesItemIdentifier, forKey: .supersedesItemIdentifier)
        try container.encodeIfPresent(repairLineage, forKey: .repairLineage)
        try container.encodeIfPresent(surface, forKey: .surface)
        try container.encodeIfPresent(realmID, forKey: .realmID)
        try container.encodeIfPresent(catalogVersion, forKey: .catalogVersion)
        try container.encodeIfPresent(plannerVersion, forKey: .plannerVersion)
        try container.encodeIfPresent(selectorIndex, forKey: .selectorIndex)
        try container.encodeIfPresent(captureCenter, forKey: .captureCenter)
        try container.encodeIfPresent(coverageCell, forKey: .coverageCell)
        try container.encodeIfPresent(zoomPercent, forKey: .zoomPercent)
        try container.encodeIfPresent(criterionFamily, forKey: .criterionFamily)
        try container.encodeIfPresent(restoreAfterCapture, forKey: .restoreAfterCapture)
    }
}

public struct QueueManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let executionProfile: QueueExecutionProfile?
    public let generationIdentifier: String
    public let targetBundleIdentifier: String?
    public let targetKind: String?
    public let targetTitleContains: String?
    public let allowedOperations: [QueueOperationKind]
    public let artifactRoot: String
    public let items: [QueueItem]
    public let policyDigest: String

    public init(
        schemaVersion: Int,
        executionProfile: QueueExecutionProfile? = nil,
        generationIdentifier: String,
        targetBundleIdentifier: String?,
        targetKind: String?,
        targetTitleContains: String?,
        allowedOperations: [QueueOperationKind],
        artifactRoot: String,
        items: [QueueItem],
        policyDigest: String
    ) {
        self.schemaVersion = schemaVersion
        self.executionProfile = executionProfile
        self.generationIdentifier = generationIdentifier
        self.targetBundleIdentifier = targetBundleIdentifier
        self.targetKind = targetKind
        self.targetTitleContains = targetTitleContains
        self.allowedOperations = allowedOperations
        self.artifactRoot = artifactRoot
        self.items = items
        self.policyDigest = policyDigest
    }

    public var selector: TargetSelector {
        if targetKind == "lab" {
            return TargetSelector(titleContains: targetTitleContains ?? "Explorer Adapter Lab Target")
        }
        return TargetSelector(bundleIdentifier: targetBundleIdentifier)
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case executionProfile = "execution_profile"
        case generationIdentifier = "generation_id"
        case targetBundleIdentifier = "target_bundle_id"
        case targetKind = "target_kind"
        case targetTitleContains = "target_title_contains"
        case allowedOperations = "allowed_operations"
        case artifactRoot = "artifact_root"
        case items
        case policyDigest = "policy_digest"
    }
}

public struct QueueClaim: Codable, Equatable, Sendable {
    public let generationIdentifier: String
    public let selector: TargetSelector
    public let artifactRoot: String
    public let item: QueueItem
    public let claimedAt: String
    public let executionDeadlineAt: String

    public init(
        generationIdentifier: String,
        selector: TargetSelector,
        artifactRoot: String,
        item: QueueItem,
        claimedAt: String,
        executionDeadlineAt: String
    ) {
        self.generationIdentifier = generationIdentifier
        self.selector = selector
        self.artifactRoot = artifactRoot
        self.item = item
        self.claimedAt = claimedAt
        self.executionDeadlineAt = executionDeadlineAt
    }

    enum CodingKeys: String, CodingKey {
        case generationIdentifier = "generation_id"
        case selector
        case artifactRoot = "artifact_root"
        case item
        case claimedAt = "claimed_at"
        case executionDeadlineAt = "execution_deadline_at"
    }
}

public struct ValidatedQueueManifest: Sendable {
    public let manifest: QueueManifest
    public let fileSHA256: String
    public let sourcePath: String
}

public enum QueueManifestValidator {
    public static let maximumItemCount = 128
    public static let maximumSemanticProductionItemCount = 100_000
    public static let maximumOperationsPerItem = 32

    public static func validate(
        fileAt url: URL,
        expectedSHA256: String,
        hostEvidenceRoot: URL
    ) throws -> ValidatedQueueManifest {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try validate(
            data: data,
            sourceURL: url,
            expectedSHA256: expectedSHA256,
            hostEvidenceRoot: hostEvidenceRoot
        )
    }

    static func validate(
        data: Data,
        sourceURL url: URL,
        expectedSHA256: String,
        hostEvidenceRoot: URL,
        allowHistoricalNativeRealmCatalog: Bool = false
    ) throws -> ValidatedQueueManifest {
        let fileDigest = AdapterHashing.sha256(data)
        guard fileDigest == expectedSHA256.lowercased() else {
            throw AdapterError.queueRejected("MANIFEST_SHA256_MISMATCH")
        }
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AdapterError.queueRejected("MANIFEST_NOT_OBJECT")
        }
        let manifest = try JSONDecoder().decode(QueueManifest.self, from: data)
        guard manifest.schemaVersion == 1 || manifest.schemaVersion == 2 else {
            throw AdapterError.queueRejected("SCHEMA_UNSUPPORTED")
        }
        let isSemantic = manifest.schemaVersion == 2
        guard (isSemantic && manifest.executionProfile == .semanticMapCaptureV1)
            || (!isSemantic && manifest.executionProfile == nil) else {
            throw AdapterError.queueRejected("EXECUTION_PROFILE_INVALID")
        }
        guard validIdentifier(manifest.generationIdentifier) else {
            throw AdapterError.queueRejected("GENERATION_INVALID")
        }
        let isLab = manifest.targetKind == "lab"
        guard (isLab
            && manifest.targetBundleIdentifier == nil
            && manifest.targetTitleContains == "Explorer Adapter Lab Target")
            || (!isLab
                && manifest.targetBundleIdentifier == osrsTargetBundleIdentifier
                && manifest.targetTitleContains == nil) else {
            throw AdapterError.queueRejected("TARGET_FORBIDDEN")
        }
        guard !isSemantic || !isLab else {
            throw AdapterError.queueRejected("SEMANTIC_TARGET_FORBIDDEN")
        }
        guard !manifest.allowedOperations.isEmpty,
              manifest.allowedOperations.count <= QueueOperationKind.allCases.count,
              Set(manifest.allowedOperations).count == manifest.allowedOperations.count else {
            throw AdapterError.queueRejected("OPERATIONS_REQUIRED")
        }
        if isSemantic {
            let legacySemanticOperations: Set<QueueOperationKind> = [.capture, .click, .drag]
            let recoverySemanticOperations = legacySemanticOperations.union([.openWorldMap])
            let operations = Set(manifest.allowedOperations)
            guard operations == legacySemanticOperations || operations == recoverySemanticOperations else {
                throw AdapterError.queueRejected("SEMANTIC_OPERATIONS_INVALID")
            }
        }
        let maximumItems = isSemantic ? maximumSemanticProductionItemCount : maximumItemCount
        guard !manifest.items.isEmpty, manifest.items.count <= maximumItems else {
            throw AdapterError.queueRejected("ITEMS_REQUIRED")
        }
        guard URL(fileURLWithPath: manifest.artifactRoot).path == manifest.artifactRoot,
              manifest.artifactRoot.hasPrefix("/") else {
            throw AdapterError.queueRejected("ARTIFACT_ROOT_INVALID")
        }
        _ = try ArtifactPathPolicy.validateDescendant(
            URL(fileURLWithPath: manifest.artifactRoot),
            of: hostEvidenceRoot
        )

        var identifiers = Set<String>()
        guard let rawItems = raw["items"] as? [[String: Any]], rawItems.count == manifest.items.count else {
            throw AdapterError.queueRejected("ITEM_ENCODING_INVALID")
        }
        for (index, item) in manifest.items.enumerated() {
            guard validIdentifier(item.id) else {
                throw AdapterError.queueRejected("ITEM_ID_INVALID")
            }
            guard identifiers.insert(item.id).inserted else {
                throw AdapterError.queueRejected("ITEM_DUPLICATE")
            }
            if isSemantic {
                try validateSemanticItem(
                    item,
                    rawItem: rawItems[index],
                    allowHistoricalNativeRealmCatalog: allowHistoricalNativeRealmCatalog
                )
            } else {
                guard !item.operations.isEmpty,
                      item.operations.count <= maximumOperationsPerItem,
                      item.operations.allSatisfy({ manifest.allowedOperations.contains($0.kind) }) else {
                    throw AdapterError.queueRejected("ITEM_OPERATION_FORBIDDEN")
                }
                guard item.operations.allSatisfy(validOperation) else {
                    throw AdapterError.queueRejected("ITEM_OPERATION_INVALID")
                }
                if item.operations.contains(where: { $0.kind == .openWorldMap }) {
                    guard !isLab,
                          item.kind == "osrs-recovery-v1-GAMEPLAY_NO_MAP",
                          let rawOperations = rawItems[index]["operations"] as? [[String: Any]],
                          rawOperations.count == item.operations.count,
                          zip(item.operations, rawOperations).allSatisfy({ operation, rawOperation in
                              operation.kind != .openWorldMap || Set(rawOperation.keys).isSubset(of: [
                                  "kind", "event_source_mode", "delivery_mode"
                              ])
                          }) else {
                        throw AdapterError.queueRejected("WORLD_MAP_SHORTCUT_BOUNDARY_INVALID")
                    }
                }
            }
            if let superseded = item.supersedesItemIdentifier {
                guard superseded != item.id,
                      item.repairLineage?.isEmpty == false,
                      item.repairLineage?.contains(superseded) == true else {
                    throw AdapterError.queueRejected("REPAIR_LINEAGE_INVALID")
                }
            } else if item.repairLineage != nil {
                throw AdapterError.queueRejected("ORPHAN_REPAIR_LINEAGE")
            }
            var rawItem = rawItems[index]
            rawItem.removeValue(forKey: "item_sha256")
            let itemDigest = try CanonicalJSON.sha256(rawItem)
            guard itemDigest == item.itemSHA256 else {
                throw AdapterError.queueRejected("ITEM_SHA256_MISMATCH:\(item.id)")
            }
        }

        var rawPolicy = raw
        rawPolicy.removeValue(forKey: "policy_digest")
        let policyDigest = try CanonicalJSON.sha256(rawPolicy)
        guard policyDigest == manifest.policyDigest else {
            throw AdapterError.queueRejected("POLICY_DIGEST_MISMATCH")
        }
        return ValidatedQueueManifest(
            manifest: manifest,
            fileSHA256: fileDigest,
            sourcePath: url.path
        )
    }

    private static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { byte in
            (byte >= 65 && byte <= 90)
                || (byte >= 97 && byte <= 122)
                || (byte >= 48 && byte <= 57)
                || byte == 46
                || byte == 95
                || byte == 45
        }
    }

    private static func validateSemanticItem(
        _ item: QueueItem,
        rawItem: [String: Any],
        allowHistoricalNativeRealmCatalog: Bool
    ) throws {
        let allowedKeys: Set<String> = [
            "id", "kind", "item_sha256", "surface", "zoom_percent",
            "criterion_family", "restore_after_capture", "catalog_version",
            "planner_version", "realm_id", "selector_index", "capture_center",
            "coverage_cell"
        ]
        let production = item.realmID != nil
            || item.catalogVersion != nil
            || item.plannerVersion != nil
            || item.selectorIndex != nil
            || item.captureCenter != nil
            || item.coverageCell != nil
        guard Set(rawItem.keys).isSubset(of: allowedKeys),
              rawItem["operations"] == nil,
              item.operations.isEmpty,
              item.kind == "semantic_map_capture",
              let surface = item.surface,
              !surface.rawValue.isEmpty,
              let zoomPercent = item.zoomPercent,
              [37.5, 50, 75, 100, 200].contains(zoomPercent),
              item.criterionFamily != nil,
              item.restoreAfterCapture != nil,
              item.supersedesItemIdentifier == nil,
              item.repairLineage == nil else {
            throw AdapterError.queueRejected("SEMANTIC_ITEM_INVALID")
        }
        if production {
            try validateNativeRealmProductionItem(
                item,
                allowHistoricalNativeRealmCatalog: allowHistoricalNativeRealmCatalog
            )
        } else if !SemanticMapSurface.allCases.contains(surface) {
            throw AdapterError.queueRejected("SEMANTIC_ITEM_INVALID")
        }
    }

    private static func validateNativeRealmProductionItem(
        _ item: QueueItem,
        allowHistoricalNativeRealmCatalog: Bool
    ) throws {
        let catalogVersion = item.catalogVersion ?? ""
        let validCatalog = catalogVersion == "native-selector-catalog-v4"
            || (allowHistoricalNativeRealmCatalog
                && ["native-selector-catalog-v1", "native-selector-catalog-v2", "native-selector-catalog-v3"]
                    .contains(catalogVersion))
        let selectorLimit: Int
        switch catalogVersion {
        case "native-selector-catalog-v1": selectorLimit = 50
        case "native-selector-catalog-v2": selectorLimit = 49
        default: selectorLimit = 47
        }
        guard validCatalog,
              [
                "native-realm-coverage-planner-v1",
                "native-realm-coverage-planner-v2",
                "native-realm-coverage-planner-v3",
                "native-realm-coverage-planner-v4",
                "native-realm-coverage-planner-v5",
                "native-realm-coverage-planner-v6",
                "native-realm-coverage-planner-v7",
                "native-realm-coverage-planner-v8",
                "native-realm-coverage-planner-v9",
                "native-realm-coverage-planner-v10",
                "native-realm-coverage-planner-v11",
                "native-realm-coverage-planner-v12",
                "native-realm-coverage-planner-v13",
                "native-realm-coverage-planner-v14"
              ]
                .contains(item.plannerVersion ?? ""),
              let realmID = item.realmID,
              !realmID.isEmpty,
              realmID == "surface-gielinor" || realmID.hasPrefix("cache-world-map:"),
              !realmID.hasPrefix("other-map-"),
              !realmID.hasPrefix("cache-special-region:"),
              let selectorIndex = item.selectorIndex,
              selectorIndex >= 0,
              selectorIndex < selectorLimit,
              let center = item.captureCenter,
              center.x.isFinite,
              center.y.isFinite,
              let cell = item.coverageCell,
              cell.row >= 0,
              cell.column >= 0,
              validBounds(cell.realmBounds),
              validBounds(cell.captureBounds),
              cell.viewport.width.isFinite,
              cell.viewport.width > 0,
              cell.viewport.height.isFinite,
              cell.viewport.height > 0 else {
            throw AdapterError.queueRejected(
                "NATIVE_REALM_PRODUCTION_ITEM_INVALID:BASE:\(item.id)"
            )
        }
        if [
            "native-realm-coverage-planner-v3",
            "native-realm-coverage-planner-v4",
            "native-realm-coverage-planner-v5",
            "native-realm-coverage-planner-v6",
            "native-realm-coverage-planner-v7",
            "native-realm-coverage-planner-v8",
            "native-realm-coverage-planner-v9",
            "native-realm-coverage-planner-v10",
            "native-realm-coverage-planner-v11",
            "native-realm-coverage-planner-v12",
            "native-realm-coverage-planner-v13",
            "native-realm-coverage-planner-v14"
        ].contains(item.plannerVersion ?? "") {
            guard let plane = cell.coveragePlane,
                  plane >= 0,
                  let reset = cell.resetCenter,
                  reset.x.isFinite,
                  reset.y.isFinite,
                  semanticCenter(reset, inside: cell.realmBounds),
                  item.plannerVersion != "native-realm-coverage-planner-v8"
                    || ((cell.anchorAttemptBudget ?? 0) >= 2
                      && (cell.anchorAttemptBudget ?? 0) <= 40),
                  let captureCenter = item.captureCenter,
                  roundedTenth((cell.captureBounds.minX + cell.captureBounds.maxX) / 2)
                    == captureCenter.x,
                  roundedTenth((cell.captureBounds.minY + cell.captureBounds.maxY) / 2)
                    == captureCenter.y,
                  semanticCenter(captureCenter, inside: cell.realmBounds) else {
                throw AdapterError.queueRejected(
                    "NATIVE_REALM_PRODUCTION_ITEM_INVALID:PLANNER:\(item.id)"
                )
            }
            if item.plannerVersion == "native-realm-coverage-planner-v14" {
                let expectedCrop = item.realmID == "surface-gielinor"
                    ? SemanticCoverageCrop(left: 178, top: 70, width: 338, height: 550)
                    : SemanticCoverageCrop(left: 4, top: 70, width: 512, height: 550)
                guard cell.coverageCrop == expectedCrop,
                      cell.viewport.width == roundedTenth(
                        Double(expectedCrop.width) * 100 / (item.zoomPercent ?? 0)
                      ),
                      cell.viewport.height == roundedTenth(
                        Double(expectedCrop.height) * 100 / (item.zoomPercent ?? 0)
                      ) else {
                    throw AdapterError.queueRejected(
                        "NATIVE_REALM_PRODUCTION_ITEM_INVALID:CROP:\(item.id)"
                    )
                }
            }
        }
    }

    private static func semanticCenter(
        _ center: SemanticCaptureCenter,
        inside bounds: SemanticBounds
    ) -> Bool {
        center.x >= bounds.minX
            && center.x <= bounds.maxX
            && center.y >= bounds.minY
            && center.y <= bounds.maxY
    }

    private static func roundedTenth(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }

    private static func validBounds(_ bounds: SemanticBounds) -> Bool {
        bounds.minX.isFinite
            && bounds.minY.isFinite
            && bounds.maxX.isFinite
            && bounds.maxY.isFinite
            && bounds.minX < bounds.maxX
            && bounds.minY < bounds.maxY
    }

    private static func validOperation(_ operation: QueueOperation) -> Bool {
        switch operation.kind {
        case .capture:
            return operation.point == nil
                && operation.button == nil
                && operation.from == nil
                && operation.to == nil
                && operation.eventSourceMode == nil
                && operation.deliveryMode == nil
        case .click:
            return validPoint(operation.point)
                && operation.button != nil
                && operation.from == nil
                && operation.to == nil
        case .drag:
            return validPoint(operation.from)
                && validPoint(operation.to)
                && operation.point == nil
                && operation.button == nil
        case .openWorldMap:
            return operation.point == nil
                && operation.button == nil
                && operation.from == nil
                && operation.to == nil
                && operation.eventSourceMode == .combinedSessionState
                && operation.deliveryMode == .foregroundGlobal
        }
    }

    private static func validPoint(_ point: AdapterPoint?) -> Bool {
        guard let point else { return false }
        return point.x.isFinite && point.y.isFinite && point.x >= 0 && point.y >= 0
    }
}

public enum CanonicalJSON {
    private static let numberEncoder = ECMAScriptNumberEncoder()

    public static func data(_ value: Any) throws -> Data {
        Data(try string(value).utf8)
    }

    public static func sha256(_ value: Any) throws -> String {
        AdapterHashing.sha256(try data(value))
    }

    public static func sha256(
        jsonObjectData data: Data,
        removingTopLevelKey key: String
    ) throws -> String {
        guard let json = String(data: data, encoding: .utf8),
              let context = JSContext() else {
            throw AdapterError.queueRejected("CANONICAL_JSON_DATA_INVALID")
        }
        var exception: JSValue?
        context.exceptionHandler = { _, value in
            exception = value
        }
        context.setObject(json, forKeyedSubscript: "__osrsJSON" as NSString)
        context.setObject(key, forKeyedSubscript: "__osrsRemovedKey" as NSString)
        let script = """
        (() => {
          const canonicalJSON = (value) => {
            if (Array.isArray(value)) {
              return `[${value.map(canonicalJSON).join(",")}]`;
            }
            if (value && typeof value === "object") {
              return `{${Object.keys(value).sort().map((entryKey) =>
                `${JSON.stringify(entryKey)}:${canonicalJSON(value[entryKey])}`
              ).join(",")}}`;
            }
            return JSON.stringify(value);
          };
          const value = JSON.parse(__osrsJSON);
          if (!value || Array.isArray(value) || typeof value !== "object") {
            throw new Error("TOP_LEVEL_OBJECT_REQUIRED");
          }
          delete value[__osrsRemovedKey];
          return canonicalJSON(value);
        })()
        """
        guard let canonical = context.evaluateScript(script)?.toString(), exception == nil else {
            throw AdapterError.queueRejected("CANONICAL_JSON_DATA_INVALID")
        }
        return AdapterHashing.sha256(Data(canonical.utf8))
    }

    private static func string(_ value: Any) throws -> String {
        switch value {
        case let dictionary as [String: Any]:
            return "{" + (try dictionary.keys.sorted().map { key in
                try "\(quoted(key)):\(string(dictionary[key] as Any))"
            }).joined(separator: ",") + "}"
        case let array as [Any]:
            return "[" + (try array.map(string)).joined(separator: ",") + "]"
        case let string as String:
            return try quoted(string)
        case _ as NSNull:
            return "null"
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            if CFNumberIsFloatType(number) {
                return try canonicalDouble(number.doubleValue)
            }
            return number.stringValue
        default:
            throw AdapterError.queueRejected("CANONICAL_JSON_TYPE_UNSUPPORTED")
        }
    }

    private static func quoted(_ value: String) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: [value],
            options: [.withoutEscapingSlashes]
        )
        let encoded = String(decoding: data, as: UTF8.self)
        return String(encoded.dropFirst().dropLast())
    }

    // Use the public JavaScriptCore JSON.stringify implementation so the host
    // and Node worker share ECMAScript Number::toString formatting. Foundation
    // and String(Double) can choose a different last digit for some binary64
    // values, which would make otherwise valid worker results unverifiable.
    private static func canonicalDouble(_ value: Double) throws -> String {
        guard value.isFinite else {
            throw AdapterError.queueRejected("CANONICAL_JSON_NUMBER_NONFINITE")
        }
        return try numberEncoder.encode(value)
    }
}

private final class ECMAScriptNumberEncoder: @unchecked Sendable {
    private let lock = NSLock()
    private let context: JSContext?
    private let stringify: JSValue?

    init() {
        let context = JSContext()
        self.context = context
        stringify = context?.evaluateScript("(value) => JSON.stringify(value)")
    }

    func encode(_ value: Double) throws -> String {
        lock.lock()
        defer { lock.unlock() }

        guard let context, let stringify else {
            throw AdapterError.queueRejected("CANONICAL_JSON_NUMBER_CONTEXT_FAILED")
        }
        var exception: JSValue?
        context.exceptionHandler = { _, value in
            exception = value
        }
        defer { context.exceptionHandler = nil }
        guard let encoded = stringify.call(withArguments: [value])?.toString(), exception == nil else {
            throw AdapterError.queueRejected("CANONICAL_JSON_NUMBER_ENCODING_FAILED")
        }
        return encoded
    }
}
