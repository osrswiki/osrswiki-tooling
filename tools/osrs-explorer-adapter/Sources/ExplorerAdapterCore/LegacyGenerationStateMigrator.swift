import Darwin
import Foundation

struct LegacyGenerationStateMigrator {
    private let evidenceRoot: URL
    private let stateStore: EvidenceStore
    private let hooks: LegacyMigrationIOHooks

    init(
        evidenceRoot: URL,
        stateStore: EvidenceStore,
        fileManager _: FileManager = .default,
        hooks: LegacyMigrationIOHooks = LegacyMigrationIOHooks()
    ) {
        self.evidenceRoot = evidenceRoot.standardizedFileURL
        self.stateStore = stateStore
        self.hooks = hooks
    }

    func migrate() throws {
        var rootMetadata = stat()
        if lstat(evidenceRoot.path, &rootMetadata) != 0 {
            if errno == ENOENT { return }
            throw migrationError("EVIDENCE_ROOT_INSPECTION_FAILED:\(errno)")
        }
        let evidenceIO = try LegacyMigrationFileSystem(root: evidenceRoot, hooks: hooks)
        let events = try discoverEvents(using: evidenceIO)
        guard !events.activations.isEmpty || !events.cancellations.isEmpty else { return }

        let activationGroups = Dictionary(grouping: events.activations, by: \.generationIdentifier)
        for (generationIdentifier, records) in activationGroups where records.count != 1 {
            throw migrationError("ACTIVATION_AMBIGUOUS:\(generationIdentifier)")
        }
        let cancellationGroups = Dictionary(grouping: events.cancellations, by: \.generationIdentifier)
        for (generationIdentifier, records) in cancellationGroups where records.count != 1 {
            throw migrationError("CANCELLATION_AMBIGUOUS:\(generationIdentifier)")
        }
        for generationIdentifier in cancellationGroups.keys where activationGroups[generationIdentifier] == nil {
            throw migrationError("CANCELLATION_WITHOUT_ACTIVATION:\(generationIdentifier)")
        }

        let stateIO = try LegacyMigrationFileSystem(
            root: stateStore.root,
            createRoot: true,
            hooks: hooks
        )
        // A generation already sealed by bound use and item-failure revocation markers is
        // permanently ineligible. Avoid rescanning its potentially large current-generation
        // worker evidence as legacy input while retaining full validation for partial histories.
        let migrations = try activationGroups.keys.sorted().compactMap {
            generationIdentifier -> Migration? in
            guard let activation = activationGroups[generationIdentifier]?.first else {
                throw migrationError("ACTIVATION_MISSING:\(generationIdentifier)")
            }
            let validated = try validateActivation(activation, using: evidenceIO)
            let existing = Migration(activation: activation, manifest: validated, terminal: nil)
            let useURL = markerURL(directory: "used-generations", migration: existing)
            let revocationURL = markerURL(
                directory: "revoked-generations",
                migration: existing
            )
            if let useData = try stateIO.readImmutableRecordIfPresent(
                at: useURL,
                code: "USE_MARKER"
            ), let revocationData = try stateIO.readImmutableRecordIfPresent(
                at: revocationURL,
                code: "REVOCATION_MARKER"
            ), let terminal = try closedItemFailureTerminal(
                from: revocationData,
                migration: existing
            ) {
                try validateUseMarker(useData, migration: existing)
                try validateChronology(activation: activation, terminal: terminal)
                try validateRevocationMarker(
                    revocationData,
                    migration: existing,
                    terminal: terminal
                )
                return nil
            }
            let failures = try discoverFailures(for: validated, using: evidenceIO)
            guard failures.count <= 1 else {
                throw migrationError("FAILURE_AMBIGUOUS:\(generationIdentifier)")
            }
            let cancellation = cancellationGroups[generationIdentifier]?.first
            if let cancellation {
                try validateCancellation(
                    cancellation,
                    activation: activation,
                    manifest: validated
                )
            }
            guard failures.isEmpty || cancellation == nil || cancellation?.isBound == true else {
                throw migrationError("TERMINAL_EVIDENCE_AMBIGUOUS:\(generationIdentifier)")
            }
            let terminal = cancellation.flatMap { $0.isBound ? Terminal.cancellation($0) : nil }
                ?? failures.first.map(Terminal.failure)
                ?? cancellation.map(Terminal.cancellation)
            if let terminal {
                try validateChronology(activation: activation, terminal: terminal)
            }
            return Migration(activation: activation, manifest: validated, terminal: terminal)
        }

        // Contradictory pre-existing marker state also fails before any new marker is published.
        let plans = try migrations.map { try markerPlan(for: $0, using: stateIO) }
        for plan in plans {
            // A failed revocation write still leaves the generation durably one-use.
            if !plan.useExists {
                try publishUse(for: plan.migration, using: stateIO)
            }
            if let terminal = plan.migration.terminal, !plan.revocationExists {
                try publishRevocation(for: plan.migration, terminal: terminal, using: stateIO)
            }
        }
    }

    private func discoverEvents(
        using fileSystem: LegacyMigrationFileSystem
    ) throws -> (activations: [Activation], cancellations: [Cancellation]) {
        let eventsRoot = evidenceRoot.appendingPathComponent("events", isDirectory: true)
        let entries = try fileSystem.enumerateImmutableRegularFiles(
            at: eventsRoot,
            maximumMembers: LegacyMigrationFileSystem.maximumDirectoryMembers,
            allowMissing: true,
            code: "EVENTS"
        )
        var activations: [Activation] = []
        var cancellations: [Cancellation] = []
        for entry in entries {
            guard entry.name.hasSuffix(".json") else {
                throw migrationError("EVENT_MEMBER_UNSUPPORTED:\(entry.name)")
            }
            let data = try fileSystem.readImmutableRecord(entry, code: "EVENT_RECORD")
            guard let inspection = LegacySchemaVersionDecoder.inspectRawJSON(data) else {
                throw migrationError("EVIDENCE_MALFORMED:\(entry.name)")
            }
            let raw = try jsonObject(data, name: entry.name)
            switch raw["event"] as? String {
            case "queue_activated":
                guard activations.count + cancellations.count
                        < LegacyMigrationFileSystem.maximumEventMembers else {
                    throw migrationError("EVENTS_MEMBER_LIMIT_EXCEEDED")
                }
                let activation = try decodeActivation(raw)
                guard entry.name == "queue-activated-\(activation.generationIdentifier).json" else {
                    throw migrationError("ACTIVATION_FILENAME_BINDING_INVALID:\(entry.name)")
                }
                activations.append(activation)
            case "queue_canceled":
                guard activations.count + cancellations.count
                        < LegacyMigrationFileSystem.maximumEventMembers else {
                    throw migrationError("EVENTS_MEMBER_LIMIT_EXCEEDED")
                }
                let cancellation = try decodeCancellation(
                    raw,
                    lexicalSchemaVersion: inspection.schemaVersion
                )
                guard entry.name == "queue-canceled-\(cancellation.generationIdentifier).json" else {
                    throw migrationError("CANCELLATION_FILENAME_BINDING_INVALID:\(entry.name)")
                }
                cancellations.append(cancellation)
            default:
                if entry.name.hasPrefix("queue-activated-") || entry.name.hasPrefix("queue-canceled-") {
                    throw migrationError("EVENT_FILENAME_SEMANTICS_INVALID:\(entry.name)")
                }
            }
        }
        return (activations, cancellations)
    }

    private func validateActivation(
        _ activation: Activation,
        using fileSystem: LegacyMigrationFileSystem
    ) throws -> ValidatedQueueManifest {
        guard validDigest(activation.manifestSHA256) else {
            throw migrationError("ACTIVATION_MANIFEST_SHA256_INVALID:\(activation.generationIdentifier)")
        }
        let manifestURL = URL(fileURLWithPath: activation.manifestPath)
        guard manifestURL.path == activation.manifestPath,
              manifestURL.standardizedFileURL.path == activation.manifestPath else {
            throw migrationError("ACTIVATION_MANIFEST_PATH_NOT_CANONICAL:\(activation.generationIdentifier)")
        }
        let validationURL: URL
        if isWithinEvidenceRoot(manifestURL) {
            validationURL = manifestURL
        } else {
            validationURL = evidenceRoot
                .appendingPathComponent(activation.generationIdentifier, isDirectory: true)
                .appendingPathComponent("operator", isDirectory: true)
                .appendingPathComponent("\(activation.generationIdentifier).json")
        }
        let data = try fileSystem.readImmutableRecord(
            at: validationURL,
            maximumBytes: LegacyMigrationFileSystem.maximumManifestBytes,
            code: "LEGACY_MANIFEST"
        )
        let validated = try QueueManifestValidator.validate(
            data: data,
            sourceURL: validationURL,
            expectedSHA256: activation.manifestSHA256,
            hostEvidenceRoot: evidenceRoot,
            allowHistoricalNativeRealmCatalog: true
        )
        guard [1, 2].contains(validated.manifest.schemaVersion),
              validated.manifest.generationIdentifier == activation.generationIdentifier,
              validated.fileSHA256 == activation.manifestSHA256 else {
            throw migrationError("ACTIVATION_MANIFEST_BINDING_MISMATCH:\(activation.generationIdentifier)")
        }
        return validated
    }

    private func isWithinEvidenceRoot(_ candidate: URL) -> Bool {
        let rootComponents = evidenceRoot.standardizedFileURL.pathComponents
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        return candidateComponents.count > rootComponents.count
            && candidateComponents.prefix(rootComponents.count).elementsEqual(rootComponents)
    }

    private func validateCancellation(
        _ cancellation: Cancellation,
        activation: Activation,
        manifest: ValidatedQueueManifest
    ) throws {
        guard cancellation.generationIdentifier == activation.generationIdentifier else {
            throw migrationError("CANCELLATION_ACTIVATION_BINDING_INVALID")
        }
        guard cancellation.isBound else { return }
        guard cancellation.manifestPath == activation.manifestPath,
              cancellation.manifestSHA256 == activation.manifestSHA256,
              cancellation.policyDigest == manifest.manifest.policyDigest,
              cancellation.activatedAt == activation.recordedAt,
              validDigest(cancellation.cancellationIntentSHA256),
              cancellation.priorNextIndex >= 0,
              cancellation.priorNextActionIndex >= 0,
              cancellation.priorItemIdentifier.isEmpty
                || manifest.manifest.items.contains(where: {
                    $0.id == cancellation.priorItemIdentifier
                }),
              cancellation.priorClaimedAt.isEmpty
                || validTimestamp(cancellation.priorClaimedAt),
              cancellation.priorDeadlineAt.isEmpty
                || validTimestamp(cancellation.priorDeadlineAt),
              let recordedAt = AdapterClock.date(from: cancellation.recordedAt),
              let revokedAt = AdapterClock.date(from: cancellation.revokedAt),
              let activatedAt = AdapterClock.date(from: activation.recordedAt),
              recordedAt >= activatedAt,
              revokedAt >= activatedAt,
              revokedAt <= recordedAt else {
            throw migrationError(
                "CANCELLATION_ACTIVATION_BINDING_INVALID:\(cancellation.generationIdentifier)"
            )
        }
    }

    private func discoverFailures(
        for validated: ValidatedQueueManifest,
        using fileSystem: LegacyMigrationFileSystem
    ) throws -> [Failure] {
        let generationIdentifier = validated.manifest.generationIdentifier
        let workerRoot = URL(fileURLWithPath: validated.manifest.artifactRoot, isDirectory: true)
            .appendingPathComponent("worker", isDirectory: true)
            .appendingPathComponent(generationIdentifier, isDirectory: true)
        let maximumResultMembers = validated.manifest.items.count + 1
        let entries = try fileSystem.enumerateImmutableRegularFiles(
            at: workerRoot,
            maximumMembers: maximumResultMembers,
            allowMissing: true,
            code: "WORKER_EVIDENCE",
            allowedDirectoryNames: ["assets"]
        )
        let assetEntries = try fileSystem.enumerateImmutableRegularFiles(
            at: workerRoot.appendingPathComponent("assets", isDirectory: true),
            maximumMembers: validated.manifest.items.count,
            allowMissing: true,
            code: "WORKER_ASSETS"
        )
        for entry in assetEntries {
            guard validated.manifest.items.contains(where: {
                entry.name == "\($0.id)-map.png"
            }) else {
                throw migrationError("WORKER_ASSET_BINDING_INVALID:\(entry.name)")
            }
            _ = try fileSystem.readImmutableRecord(
                entry,
                maximumBytes: LegacyMigrationFileSystem.maximumManifestBytes,
                code: "WORKER_ASSET"
            )
        }
        var failures: [Failure] = []
        for entry in entries where entry.name.hasSuffix(".json") {
            let data = try fileSystem.readImmutableRecord(entry, code: "WORKER_RECORD")
            if try isSemanticResult(
                entryName: entry.name,
                data: data,
                validated: validated
            ) {
                continue
            }
            let failureName = entry.name.hasSuffix("-failure.json")
            guard let inspection = LegacySchemaVersionDecoder.inspectRawJSON(data) else {
                throw migrationError(
                    failureName ? "FAILURE_SCHEMA_INVALID" : "EVIDENCE_MALFORMED:\(entry.name)"
                )
            }
            guard inspection.topLevelKeys.contains("failed_at") || failureName else { continue }
            guard let lexicalSchemaVersion = inspection.schemaVersion else {
                throw migrationError("FAILURE_SCHEMA_INVALID")
            }
            let raw = try jsonObject(data, name: entry.name)
            let failure = try decodeFailure(raw, lexicalSchemaVersion: lexicalSchemaVersion)
            guard entry.name == "\(failure.itemIdentifier)-failure.json",
                  failure.generationIdentifier == generationIdentifier,
                  validated.manifest.items.contains(where: { $0.id == failure.itemIdentifier }) else {
                throw migrationError("FAILURE_BINDING_MISMATCH:\(generationIdentifier)")
            }
            failures.append(failure)
        }
        return failures
    }

    private func isSemanticResult(
        entryName: String,
        data: Data,
        validated: ValidatedQueueManifest
    ) throws -> Bool {
        guard validated.manifest.executionProfile == .semanticMapCaptureV1,
              let item = validated.manifest.items.first(where: {
                  entryName == "\($0.id).json"
              }) else { return false }
        guard let inspection = LegacySchemaVersionDecoder.inspectAnyRawJSON(data),
              inspection.schemaVersion == 2,
              !inspection.topLevelKeys.contains("failed_at") else {
            throw migrationError("EVIDENCE_MALFORMED:\(entryName)")
        }
        let raw = try jsonObject(data, name: entryName)
        guard raw["execution_profile"] as? String
                == QueueExecutionProfile.semanticMapCaptureV1.rawValue,
              raw["generation_id"] as? String
                == validated.manifest.generationIdentifier,
              raw["item_id"] as? String == item.id,
              raw["item_sha256"] as? String == item.itemSHA256,
              let resultDigest = raw["result_digest"] as? String,
              validDigest(resultDigest) else {
            throw migrationError("EVIDENCE_MALFORMED:\(entryName)")
        }
        return true
    }

    private func markerPlan(
        for migration: Migration,
        using fileSystem: LegacyMigrationFileSystem
    ) throws -> MarkerPlan {
        let useURL = markerURL(directory: "used-generations", migration: migration)
        let useData = try fileSystem.readImmutableRecordIfPresent(at: useURL, code: "USE_MARKER")
        if let useData { try validateUseMarker(useData, migration: migration) }

        let revocationURL = markerURL(directory: "revoked-generations", migration: migration)
        let revocationData = try fileSystem.readImmutableRecordIfPresent(
            at: revocationURL,
            code: "REVOCATION_MARKER"
        )
        switch (migration.terminal, revocationData) {
        case let (.some(terminal), .some(data)):
            try validateRevocationMarker(data, migration: migration, terminal: terminal)
        case (.none, .some):
            throw migrationError(
                "REVOCATION_MARKER_WITHOUT_TERMINAL:\(migration.activation.generationIdentifier)"
            )
        default:
            break
        }
        return MarkerPlan(
            migration: migration,
            useExists: useData != nil,
            revocationExists: revocationData != nil
        )
    }

    private func publishUse(
        for migration: Migration,
        using fileSystem: LegacyMigrationFileSystem
    ) throws {
        let destination = markerURL(directory: "used-generations", migration: migration)
        let marker = LegacyGenerationUse(
            schemaVersion: 1,
            generationIdentifier: migration.activation.generationIdentifier,
            manifestSHA256: migration.manifest.fileSHA256,
            policyDigest: migration.manifest.manifest.policyDigest,
            activatedAt: migration.activation.recordedAt
        )
        do {
            let data = try encoded(marker)
            _ = try fileSystem.publishImmutableRecord(data, at: destination, code: "USE_MARKER")
            guard let published = try fileSystem.readImmutableRecordIfPresent(
                at: destination,
                code: "USE_MARKER"
            ) else {
                throw migrationError("USE_MARKER_MISSING_AFTER_PUBLICATION")
            }
            try validateUseMarker(published, migration: migration)
        } catch {
            throw migrationError("USE_MARKER_PUBLICATION_FAILED:\(migration.activation.generationIdentifier)")
        }
    }

    private func publishRevocation(
        for migration: Migration,
        terminal: Terminal,
        using fileSystem: LegacyMigrationFileSystem
    ) throws {
        let destination = markerURL(directory: "revoked-generations", migration: migration)
        let marker = LegacyGenerationRevocation(
            schemaVersion: 1,
            generationIdentifier: migration.activation.generationIdentifier,
            reason: terminal.reason,
            revokedAt: terminal.timestamp
        )
        do {
            let data = try encoded(marker)
            _ = try fileSystem.publishImmutableRecord(data, at: destination, code: "REVOCATION_MARKER")
            guard let published = try fileSystem.readImmutableRecordIfPresent(
                at: destination,
                code: "REVOCATION_MARKER"
            ) else {
                throw migrationError("REVOCATION_MARKER_MISSING_AFTER_PUBLICATION")
            }
            try validateRevocationMarker(published, migration: migration, terminal: terminal)
        } catch {
            throw migrationError(
                "REVOCATION_MARKER_PUBLICATION_FAILED:\(migration.activation.generationIdentifier)"
            )
        }
    }

    private func validateUseMarker(_ data: Data, migration: Migration) throws {
        guard let lexicalSchemaVersion = LegacySchemaVersionDecoder.decodeRawSchemaVersion(in: data) else {
            throw migrationError("USE_MARKER_BINDING_INVALID:\(migration.activation.generationIdentifier)")
        }
        let raw = try jsonObject(data, name: "use-marker")
        try requireExactKeys(
            raw,
            ["schema_version", "generation_id", "manifest_sha256", "policy_digest", "activated_at"],
            code: "USE_MARKER_SCHEMA_INVALID"
        )
        guard LegacySchemaVersionDecoder.decode(
            lexicalVersion: lexicalSchemaVersion,
            structuredValue: raw["schema_version"]
        ) == 1,
              raw["generation_id"] as? String == migration.activation.generationIdentifier,
              raw["manifest_sha256"] as? String == migration.manifest.fileSHA256,
              raw["policy_digest"] as? String == migration.manifest.manifest.policyDigest,
              raw["activated_at"] as? String == migration.activation.recordedAt else {
            throw migrationError("USE_MARKER_BINDING_INVALID:\(migration.activation.generationIdentifier)")
        }
    }

    private func validateRevocationMarker(
        _ data: Data,
        migration: Migration,
        terminal: Terminal
    ) throws {
        guard let lexicalSchemaVersion = LegacySchemaVersionDecoder.decodeRawSchemaVersion(in: data) else {
            throw migrationError(
                "REVOCATION_MARKER_BINDING_INVALID:\(migration.activation.generationIdentifier)"
            )
        }
        let raw = try jsonObject(data, name: "revocation-marker")
        try requireExactKeys(
            raw,
            ["schema_version", "generation_id", "reason", "revoked_at"],
            code: "REVOCATION_MARKER_SCHEMA_INVALID"
        )
        guard LegacySchemaVersionDecoder.decode(
            lexicalVersion: lexicalSchemaVersion,
            structuredValue: raw["schema_version"]
        ) == 1,
              raw["generation_id"] as? String == migration.activation.generationIdentifier,
              let reason = raw["reason"] as? String,
              let revokedAt = raw["revoked_at"] as? String,
              terminal.acceptsRevocationMarker(reason: reason, revokedAt: revokedAt) else {
            throw migrationError(
                "REVOCATION_MARKER_BINDING_INVALID:\(migration.activation.generationIdentifier)"
            )
        }
    }

    private func closedItemFailureTerminal(
        from data: Data,
        migration: Migration
    ) throws -> Terminal? {
        guard let lexicalSchemaVersion = LegacySchemaVersionDecoder.decodeRawSchemaVersion(
            in: data
        ) else { return nil }
        let raw = try jsonObject(data, name: "revocation-marker")
        guard Set(raw.keys) == ["schema_version", "generation_id", "reason", "revoked_at"],
              LegacySchemaVersionDecoder.decode(
                lexicalVersion: lexicalSchemaVersion,
                structuredValue: raw["schema_version"]
              ) == 1,
              raw["generation_id"] as? String == migration.activation.generationIdentifier,
              let reason = raw["reason"] as? String,
              let revokedAt = raw["revoked_at"] as? String,
              AdapterClock.date(from: revokedAt) != nil else {
            return nil
        }
        let prefixes = ["ITEM_FAILED:", "LEGACY_ITEM_FAILED:"]
        guard let prefix = prefixes.first(where: { reason.hasPrefix($0) }) else { return nil }
        let itemIdentifier = String(reason.dropFirst(prefix.count))
        guard migration.manifest.manifest.items.contains(where: { $0.id == itemIdentifier }) else {
            return nil
        }
        return .failure(
            Failure(
                generationIdentifier: migration.activation.generationIdentifier,
                itemIdentifier: itemIdentifier,
                failedAt: revokedAt
            )
        )
    }

    private func validateChronology(activation: Activation, terminal: Terminal) throws {
        guard let activatedAt = AdapterClock.date(from: activation.recordedAt),
              let terminalAt = AdapterClock.date(from: terminal.timestamp),
              terminalAt >= activatedAt else {
            throw migrationError("TERMINAL_PRECEDES_ACTIVATION:\(activation.generationIdentifier)")
        }
    }

    private func markerURL(directory: String, migration: Migration) -> URL {
        stateStore.root
            .appendingPathComponent(directory, isDirectory: true)
            .appendingPathComponent("\(migration.activation.generationIdentifier).json")
    }

    private func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    private func decodeActivation(_ raw: [String: Any]) throws -> Activation {
        try requireExactKeys(
            raw,
            ["event", "generation_id", "manifest_path", "manifest_sha256", "recorded_at"],
            code: "ACTIVATION_SCHEMA_INVALID"
        )
        guard raw["event"] as? String == "queue_activated",
              let generationIdentifier = raw["generation_id"] as? String,
              validIdentifier(generationIdentifier),
              let manifestPath = raw["manifest_path"] as? String,
              !manifestPath.isEmpty,
              let manifestSHA256 = raw["manifest_sha256"] as? String,
              let recordedAt = raw["recorded_at"] as? String,
              validTimestamp(recordedAt) else {
            throw migrationError("ACTIVATION_SCHEMA_INVALID")
        }
        return Activation(
            generationIdentifier: generationIdentifier,
            manifestPath: manifestPath,
            manifestSHA256: manifestSHA256,
            recordedAt: recordedAt
        )
    }

    private func decodeCancellation(
        _ raw: [String: Any],
        lexicalSchemaVersion: Int?
    ) throws -> Cancellation {
        let legacyKeys: Set<String> = ["event", "generation_id", "recorded_at"]
        let boundKeys: Set<String> = [
            "schema_version", "event", "generation_id", "manifest_path",
            "manifest_sha256", "policy_digest", "activated_at", "cancellation_reason",
            "recorded_at", "prior_item_id", "prior_next_index",
            "prior_next_action_index", "prior_claimed_at", "prior_deadline_at",
            "revocation_reason", "revoked_at", "cancellation_intent_sha256"
        ]
        guard raw["event"] as? String == "queue_canceled",
              let generationIdentifier = raw["generation_id"] as? String,
              validIdentifier(generationIdentifier),
              let recordedAt = raw["recorded_at"] as? String,
              validTimestamp(recordedAt) else {
            throw migrationError("CANCELLATION_SCHEMA_INVALID")
        }
        if Set(raw.keys) == legacyKeys {
            return Cancellation(
                generationIdentifier: generationIdentifier,
                recordedAt: recordedAt
            )
        }
        guard Set(raw.keys) == boundKeys,
              LegacySchemaVersionDecoder.decode(
                lexicalVersion: lexicalSchemaVersion,
                structuredValue: raw["schema_version"]
              ) == 1,
              let manifestPath = raw["manifest_path"] as? String,
              !manifestPath.isEmpty,
              let manifestSHA256 = raw["manifest_sha256"] as? String,
              validDigest(manifestSHA256),
              let policyDigest = raw["policy_digest"] as? String,
              validDigest(policyDigest),
              let activatedAt = raw["activated_at"] as? String,
              validTimestamp(activatedAt),
              let cancellationReason = raw["cancellation_reason"] as? String,
              !cancellationReason.isEmpty,
              let priorItemIdentifier = raw["prior_item_id"] as? String,
              priorItemIdentifier.isEmpty || validIdentifier(priorItemIdentifier),
              let priorNextIndex = exactNonnegativeInteger(raw["prior_next_index"]),
              let priorNextActionIndex = exactNonnegativeInteger(
                raw["prior_next_action_index"]
              ),
              let priorClaimedAt = raw["prior_claimed_at"] as? String,
              let priorDeadlineAt = raw["prior_deadline_at"] as? String,
              let revocationReason = raw["revocation_reason"] as? String,
              !revocationReason.isEmpty,
              let revokedAt = raw["revoked_at"] as? String,
              validTimestamp(revokedAt),
              let cancellationIntentSHA256 = raw["cancellation_intent_sha256"] as? String,
              validDigest(cancellationIntentSHA256) else {
            throw migrationError("CANCELLATION_SCHEMA_INVALID")
        }
        return Cancellation(
            generationIdentifier: generationIdentifier,
            recordedAt: recordedAt,
            manifestPath: manifestPath,
            manifestSHA256: manifestSHA256,
            policyDigest: policyDigest,
            activatedAt: activatedAt,
            cancellationReason: cancellationReason,
            priorItemIdentifier: priorItemIdentifier,
            priorNextIndex: priorNextIndex,
            priorNextActionIndex: priorNextActionIndex,
            priorClaimedAt: priorClaimedAt,
            priorDeadlineAt: priorDeadlineAt,
            revocationReason: revocationReason,
            revokedAt: revokedAt,
            cancellationIntentSHA256: cancellationIntentSHA256
        )
    }

    private func decodeFailure(
        _ raw: [String: Any],
        lexicalSchemaVersion: Int?
    ) throws -> Failure {
        try requireExactKeys(
            raw,
            ["schema_version", "generation_id", "item_id", "error", "evidence", "failed_at"],
            code: "FAILURE_SCHEMA_INVALID"
        )
        guard LegacySchemaVersionDecoder.decode(
            lexicalVersion: lexicalSchemaVersion,
            structuredValue: raw["schema_version"]
        ) == 1,
              let generationIdentifier = raw["generation_id"] as? String,
              validIdentifier(generationIdentifier),
              let itemIdentifier = raw["item_id"] as? String,
              validIdentifier(itemIdentifier),
              nonempty(raw["error"] as? String),
              raw["evidence"] is [Any],
              let failedAt = raw["failed_at"] as? String,
              validTimestamp(failedAt) else {
            throw migrationError("FAILURE_SCHEMA_INVALID")
        }
        return Failure(
            generationIdentifier: generationIdentifier,
            itemIdentifier: itemIdentifier,
            failedAt: failedAt
        )
    }

    private func jsonObject(_ data: Data, name: String) throws -> [String: Any] {
        do {
            guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw migrationError("EVIDENCE_NOT_OBJECT:\(name)")
            }
            return raw
        } catch let error as AdapterError {
            throw error
        } catch {
            throw migrationError("EVIDENCE_MALFORMED:\(name)")
        }
    }

    private func requireExactKeys(_ raw: [String: Any], _ keys: Set<String>, code: String) throws {
        guard Set(raw.keys) == keys else { throw migrationError(code) }
    }

    private func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { byte in
            (byte >= 65 && byte <= 90)
                || (byte >= 97 && byte <= 122)
                || (byte >= 48 && byte <= 57)
                || byte == 46
                || byte == 95
                || byte == 45
        }
    }

    private func validDigest(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }
    }

    private func validTimestamp(_ value: String?) -> Bool {
        value.flatMap(AdapterClock.date(from:)) != nil
    }

    private func nonempty(_ value: String?) -> Bool {
        value?.isEmpty == false
    }

    private func exactNonnegativeInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        var decoded = 0
        guard CFNumberGetValue(number, .cfIndexType, &decoded),
              decoded >= 0,
              NSNumber(value: decoded).compare(number) == .orderedSame else { return nil }
        return decoded
    }

    private func migrationError(_ code: String) -> AdapterError {
        .queueRejected("LEGACY_GENERATION_STATE_MIGRATION_FAILED:\(code)")
    }
}

enum LegacySchemaVersionDecoder {
    static func decodeRawSchemaVersion(in data: Data) -> Int? {
        inspectRawJSON(data)?.schemaVersion
    }

    static func inspectRawJSON(_ data: Data) -> LegacyRawJSONInspection? {
        var scanner = LegacyJSONSchemaScanner(data: data)
        return try? scanner.inspectTopLevelObject(requiredSchemaVersion: 1)
    }

    static func inspectAnyRawJSON(_ data: Data) -> LegacyRawJSONInspection? {
        var scanner = LegacyJSONSchemaScanner(data: data)
        return try? scanner.inspectTopLevelObject(requiredSchemaVersion: nil)
    }

    static func decode(lexicalVersion: Int?, structuredValue: Any?) -> Int? {
        guard let lexicalVersion,
              let structuredVersion = decode(structuredValue),
              lexicalVersion == structuredVersion else { return nil }
        return lexicalVersion
    }

    static func decode(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }

        var decoded = 0
        guard CFNumberGetValue(number, .cfIndexType, &decoded),
              decoded > 0,
              NSNumber(value: decoded).compare(number) == .orderedSame else { return nil }
        return decoded
    }
}

struct LegacyRawJSONInspection {
    let schemaVersion: Int?
    let topLevelKeys: Set<String>
}

private struct LegacyJSONSchemaScanner {
    private enum Value {
        case number(Range<Int>)
        case other
    }

    private enum ScanError: Error {
        case invalidJSON
    }

    private static let maximumDepth = 64

    private let bytes: [UInt8]
    private var index = 0
    private var schemaToken: Range<Int>?
    private var topLevelKeys: Set<String> = []

    init(data: Data) {
        bytes = Array(data)
    }

    mutating func inspectTopLevelObject(
        requiredSchemaVersion: Int?
    ) throws -> LegacyRawJSONInspection {
        guard String(bytes: bytes, encoding: .utf8) != nil else {
            throw ScanError.invalidJSON
        }
        skipWhitespace()
        try parseObject(depth: 0, captureSchema: true)
        skipWhitespace()
        guard index == bytes.count else { throw ScanError.invalidJSON }
        var schemaVersion: Int?
        if let schemaToken {
            guard let exactVersion = exactPositiveInteger(in: schemaToken),
                  requiredSchemaVersion.map({ $0 == exactVersion }) ?? true else {
                throw ScanError.invalidJSON
            }
            schemaVersion = exactVersion
        }
        return LegacyRawJSONInspection(
            schemaVersion: schemaVersion,
            topLevelKeys: topLevelKeys
        )
    }

    private mutating func parseValue(depth: Int) throws -> Value {
        guard depth <= Self.maximumDepth,
              let byte = currentByte else { throw ScanError.invalidJSON }
        switch byte {
        case 0x7B: // {
            try parseObject(depth: depth, captureSchema: false)
            return .other
        case 0x5B: // [
            try parseArray(depth: depth)
            return .other
        case 0x22: // "
            _ = try parseString()
            return .other
        case 0x74: // true
            try consumeLiteral("true")
            return .other
        case 0x66: // false
            try consumeLiteral("false")
            return .other
        case 0x6E: // null
            try consumeLiteral("null")
            return .other
        case 0x2D, 0x30...0x39:
            return .number(try parseNumber())
        default:
            throw ScanError.invalidJSON
        }
    }

    private mutating func parseObject(depth: Int, captureSchema: Bool) throws {
        guard depth <= Self.maximumDepth else { throw ScanError.invalidJSON }
        try consume(0x7B)
        skipWhitespace()
        if consumeIfPresent(0x7D) { return }

        while true {
            let keyToken = try parseString()
            let key = captureSchema ? try decodeString(keyToken) : nil
            if let key {
                guard topLevelKeys.insert(key).inserted else {
                    throw ScanError.invalidJSON
                }
            }
            skipWhitespace()
            try consume(0x3A)
            skipWhitespace()
            let value = try parseValue(depth: depth + 1)
            if key == "schema_version" {
                guard schemaToken == nil,
                      case let .number(token) = value else {
                    throw ScanError.invalidJSON
                }
                schemaToken = token
            }
            skipWhitespace()
            if consumeIfPresent(0x7D) { return }
            try consume(0x2C)
            skipWhitespace()
        }
    }

    private mutating func parseArray(depth: Int) throws {
        guard depth <= Self.maximumDepth else { throw ScanError.invalidJSON }
        try consume(0x5B)
        skipWhitespace()
        if consumeIfPresent(0x5D) { return }

        while true {
            _ = try parseValue(depth: depth + 1)
            skipWhitespace()
            if consumeIfPresent(0x5D) { return }
            try consume(0x2C)
            skipWhitespace()
        }
    }

    private mutating func parseString() throws -> Range<Int> {
        let start = index
        try consume(0x22)
        while let byte = currentByte {
            switch byte {
            case 0x22:
                index += 1
                return start..<index
            case 0x5C:
                index += 1
                guard let escape = currentByte else { throw ScanError.invalidJSON }
                index += 1
                if escape == 0x75 {
                    let codeUnit = try parseUnicodeEscapeCodeUnit()
                    if (0xD800...0xDBFF).contains(codeUnit) {
                        try consume(0x5C)
                        try consume(0x75)
                        let lowSurrogate = try parseUnicodeEscapeCodeUnit()
                        guard (0xDC00...0xDFFF).contains(lowSurrogate) else {
                            throw ScanError.invalidJSON
                        }
                    } else if (0xDC00...0xDFFF).contains(codeUnit) {
                        throw ScanError.invalidJSON
                    }
                } else if ![0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74].contains(escape) {
                    throw ScanError.invalidJSON
                }
            case 0x00...0x1F:
                throw ScanError.invalidJSON
            default:
                index += 1
            }
        }
        throw ScanError.invalidJSON
    }

    private mutating func parseUnicodeEscapeCodeUnit() throws -> UInt16 {
        var codeUnit: UInt16 = 0
        for _ in 0..<4 {
            guard let byte = currentByte,
                  let value = hexadecimalValue(byte) else { throw ScanError.invalidJSON }
            codeUnit = (codeUnit << 4) | value
            index += 1
        }
        return codeUnit
    }

    private mutating func parseNumber() throws -> Range<Int> {
        let start = index
        _ = consumeIfPresent(0x2D)
        guard let integerStart = currentByte else { throw ScanError.invalidJSON }
        if integerStart == 0x30 {
            index += 1
            if let next = currentByte, isDigit(next) { throw ScanError.invalidJSON }
        } else if (0x31...0x39).contains(integerStart) {
            repeat { index += 1 } while currentByte.map(isDigit) == true
        } else {
            throw ScanError.invalidJSON
        }

        if consumeIfPresent(0x2E) {
            guard currentByte.map(isDigit) == true else { throw ScanError.invalidJSON }
            repeat { index += 1 } while currentByte.map(isDigit) == true
        }

        if currentByte == 0x65 || currentByte == 0x45 {
            index += 1
            if currentByte == 0x2B || currentByte == 0x2D { index += 1 }
            guard currentByte.map(isDigit) == true else { throw ScanError.invalidJSON }
            repeat { index += 1 } while currentByte.map(isDigit) == true
        }
        return start..<index
    }

    private mutating func consumeLiteral(_ literal: StaticString) throws {
        for byte in literal.withUTF8Buffer({ Array($0) }) {
            try consume(byte)
        }
    }

    private mutating func consume(_ byte: UInt8) throws {
        guard currentByte == byte else { throw ScanError.invalidJSON }
        index += 1
    }

    private mutating func consumeIfPresent(_ byte: UInt8) -> Bool {
        guard currentByte == byte else { return false }
        index += 1
        return true
    }

    private mutating func skipWhitespace() {
        while let byte = currentByte, [0x20, 0x09, 0x0A, 0x0D].contains(byte) {
            index += 1
        }
    }

    private func decodeString(_ range: Range<Int>) throws -> String {
        let token = Data(bytes[range])
        guard let value = try? JSONSerialization.jsonObject(
            with: token,
            options: .fragmentsAllowed
        ) as? String else { throw ScanError.invalidJSON }
        return value
    }

    private func exactPositiveInteger(in range: Range<Int>) -> Int? {
        let token = Array(bytes[range])
        var cursor = 0
        guard token.first != 0x2D else { return nil }

        var coefficient: [UInt8] = []
        while cursor < token.count, isDigit(token[cursor]) {
            coefficient.append(token[cursor] - 0x30)
            cursor += 1
        }
        var fractionalDigits = 0
        if cursor < token.count, token[cursor] == 0x2E {
            cursor += 1
            while cursor < token.count, isDigit(token[cursor]) {
                coefficient.append(token[cursor] - 0x30)
                fractionalDigits += 1
                cursor += 1
            }
        }

        var exponent = 0
        if cursor < token.count, token[cursor] == 0x65 || token[cursor] == 0x45 {
            cursor += 1
            var exponentIsNegative = false
            if cursor < token.count, token[cursor] == 0x2B || token[cursor] == 0x2D {
                exponentIsNegative = token[cursor] == 0x2D
                cursor += 1
            }
            var magnitude = 0
            while cursor < token.count, isDigit(token[cursor]) {
                let digit = Int(token[cursor] - 0x30)
                let (scaled, multiplyOverflow) = magnitude.multipliedReportingOverflow(by: 10)
                let (advanced, addOverflow) = scaled.addingReportingOverflow(digit)
                guard !multiplyOverflow, !addOverflow else { return nil }
                magnitude = advanced
                cursor += 1
            }
            exponent = exponentIsNegative ? -magnitude : magnitude
        }
        guard cursor == token.count else { return nil }

        let leadingZeros = coefficient.prefix(while: { $0 == 0 }).count
        coefficient.removeFirst(leadingZeros)
        guard !coefficient.isEmpty else { return nil }
        let (scale, scaleOverflow) = exponent.subtractingReportingOverflow(fractionalDigits)
        guard !scaleOverflow else { return nil }

        if scale < 0 {
            guard scale != Int.min else { return nil }
            let requiredTrailingZeros = -scale
            guard requiredTrailingZeros <= coefficient.count,
                  coefficient.suffix(requiredTrailingZeros).allSatisfy({ $0 == 0 }) else { return nil }
            coefficient.removeLast(requiredTrailingZeros)
        } else {
            let (digitCount, digitCountOverflow) = coefficient.count.addingReportingOverflow(scale)
            guard !digitCountOverflow,
                  digitCount <= String(Int.max).count else { return nil }
        }

        guard !coefficient.isEmpty else { return nil }
        var result = 0
        for digit in coefficient {
            let (scaled, multiplyOverflow) = result.multipliedReportingOverflow(by: 10)
            let (advanced, addOverflow) = scaled.addingReportingOverflow(Int(digit))
            guard !multiplyOverflow, !addOverflow else { return nil }
            result = advanced
        }
        if scale > 0 {
            for _ in 0..<scale {
                let (scaled, overflow) = result.multipliedReportingOverflow(by: 10)
                guard !overflow else { return nil }
                result = scaled
            }
        }
        return result > 0 ? result : nil
    }

    private var currentByte: UInt8? {
        index < bytes.count ? bytes[index] : nil
    }

    private func isDigit(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte)
    }

    private func hexadecimalValue(_ byte: UInt8) -> UInt16? {
        switch byte {
        case 0x30...0x39: return UInt16(byte - 0x30)
        case 0x41...0x46: return UInt16(byte - 0x41 + 10)
        case 0x61...0x66: return UInt16(byte - 0x61 + 10)
        default: return nil
        }
    }
}

private struct Activation {
    let generationIdentifier: String
    let manifestPath: String
    let manifestSHA256: String
    let recordedAt: String
}

private struct Cancellation {
    let generationIdentifier: String
    let recordedAt: String
    let manifestPath: String
    let manifestSHA256: String
    let policyDigest: String
    let activatedAt: String
    let cancellationReason: String
    let priorItemIdentifier: String
    let priorNextIndex: Int
    let priorNextActionIndex: Int
    let priorClaimedAt: String
    let priorDeadlineAt: String
    let revocationReason: String
    let revokedAt: String
    let cancellationIntentSHA256: String

    init(
        generationIdentifier: String,
        recordedAt: String,
        manifestPath: String = "",
        manifestSHA256: String = "",
        policyDigest: String = "",
        activatedAt: String = "",
        cancellationReason: String = "",
        priorItemIdentifier: String = "",
        priorNextIndex: Int = 0,
        priorNextActionIndex: Int = 0,
        priorClaimedAt: String = "",
        priorDeadlineAt: String = "",
        revocationReason: String = "",
        revokedAt: String = "",
        cancellationIntentSHA256: String = ""
    ) {
        self.generationIdentifier = generationIdentifier
        self.recordedAt = recordedAt
        self.manifestPath = manifestPath
        self.manifestSHA256 = manifestSHA256
        self.policyDigest = policyDigest
        self.activatedAt = activatedAt
        self.cancellationReason = cancellationReason
        self.priorItemIdentifier = priorItemIdentifier
        self.priorNextIndex = priorNextIndex
        self.priorNextActionIndex = priorNextActionIndex
        self.priorClaimedAt = priorClaimedAt
        self.priorDeadlineAt = priorDeadlineAt
        self.revocationReason = revocationReason
        self.revokedAt = revokedAt
        self.cancellationIntentSHA256 = cancellationIntentSHA256
    }

    var isBound: Bool { !manifestSHA256.isEmpty }
}

private struct Failure {
    let generationIdentifier: String
    let itemIdentifier: String
    let failedAt: String
}

private struct Migration {
    let activation: Activation
    let manifest: ValidatedQueueManifest
    let terminal: Terminal?
}

private struct MarkerPlan {
    let migration: Migration
    let useExists: Bool
    let revocationExists: Bool
}

private enum Terminal {
    case failure(Failure)
    case cancellation(Cancellation)

    var reason: String {
        switch self {
        case let .failure(failure): return "LEGACY_ITEM_FAILED:\(failure.itemIdentifier)"
        case let .cancellation(cancellation):
            return cancellation.isBound ? cancellation.revocationReason : "LEGACY_QUEUE_CANCELED"
        }
    }

    var timestamp: String {
        switch self {
        case let .failure(failure): return failure.failedAt
        case let .cancellation(cancellation):
            return cancellation.isBound ? cancellation.revokedAt : cancellation.recordedAt
        }
    }

    func acceptsRevocationMarker(reason: String, revokedAt: String) -> Bool {
        if reason == self.reason, revokedAt == timestamp {
            return true
        }
        guard case let .failure(failure) = self,
              reason == "ITEM_FAILED:\(failure.itemIdentifier)",
              let failedAt = AdapterClock.date(from: failure.failedAt),
              let revokedAtDate = AdapterClock.date(from: revokedAt) else {
            return false
        }
        return revokedAtDate >= failedAt
    }
}

private struct LegacyGenerationUse: Codable {
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

private struct LegacyGenerationRevocation: Codable {
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
