import AppKit
import Foundation
import Darwin
import XCTest
@testable import ExplorerAdapterCore

final class ExplorerAdapterCoreTests: XCTestCase {
    func testForegroundLeaseMatchesTheExactDynamicTargetWindow() {
        let target = TargetWindowDescriptor(
            bundleIdentifier: osrsTargetBundleIdentifier,
            processIdentifier: 41,
            windowIdentifier: 73,
            title: "Old School RuneScape",
            frame: AdapterRect(x: 122, y: 35, width: 807, height: 861),
            isOnScreen: true
        )
        XCTAssertTrue(
            ForegroundLeaseService.targetWindowMatches(
                title: target.title,
                frame: CGRect(x: 122.5, y: 34.5, width: 807, height: 861),
                target: target
            )
        )
        XCTAssertFalse(
            ForegroundLeaseService.targetWindowMatches(
                title: "Window",
                frame: CGRect(x: 122, y: 35, width: 807, height: 861),
                target: target
            )
        )
        XCTAssertFalse(
            ForegroundLeaseService.targetWindowMatches(
                title: target.title,
                frame: CGRect(x: 122, y: 35, width: 786, height: 861),
                target: target
            )
        )
    }

    func testStableRuntimePathsUseApplicationSupport() {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        let paths = AdapterRuntimePaths.stable(homeDirectory: home)

        XCTAssertEqual(
            paths.root.path,
            "/Users/tester/Library/Application Support/OSRS Explorer Adapter/runtime"
        )
        XCTAssertEqual(paths.lock.lastPathComponent, "adapter.lock")
        XCTAssertEqual(paths.socket.lastPathComponent, "worker.sock")
        XCTAssertEqual(paths.controlSocket.lastPathComponent, "control.sock")
        XCTAssertEqual(paths.showControlsRequests.lastPathComponent, "show-controls-requests")
        XCTAssertEqual(
            paths.showControlsAcknowledgements.lastPathComponent,
            "show-controls-acknowledgements"
        )
    }

    func testSingleInstanceLockRejectsSecondOwnerAndAllowsLaterOwner() throws {
        let root = temporaryDirectory().appendingPathComponent("instance-lock-\(UUID().uuidString)")
        let paths = AdapterRuntimePaths(root: root)
        let firstDisposition = try AdapterInstanceLock.acquire(
            paths: paths,
            instanceIdentifier: "first-instance"
        )
        guard case let .primary(first) = firstDisposition else {
            return XCTFail("first launch did not acquire the instance lock")
        }
        XCTAssertTrue(first.owns(paths: paths))

        let secondDisposition = try AdapterInstanceLock.acquire(
            paths: paths,
            instanceIdentifier: "second-instance"
        )
        guard case .secondary = secondDisposition else {
            return XCTFail("second launch unexpectedly acquired the instance lock")
        }

        first.release()
        let thirdDisposition = try AdapterInstanceLock.acquire(
            paths: paths,
            instanceIdentifier: "third-instance"
        )
        guard case let .primary(third) = thirdDisposition else {
            return XCTFail("lock was not available after the owner released it")
        }
        defer { third.release() }
        XCTAssertTrue(third.owns(paths: paths))
    }

    func testSecondLaunchControlRequestPersistsUntilLockOwnerConsumesIt() throws {
        let root = temporaryDirectory().appendingPathComponent("handoff-\(UUID().uuidString)")
        let paths = AdapterRuntimePaths(root: root)
        guard case let .primary(instanceLock) = try AdapterInstanceLock.acquire(paths: paths) else {
            return XCTFail("instance lock unavailable")
        }
        defer { instanceLock.release() }

        let requestIdentifier = try AdapterInstanceLock.requestControls(
            paths: paths,
            requestIdentifier: "request-one"
        )
        let requestMarker = paths.showControlsRequests.appendingPathComponent(
            "request-one.request"
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: requestMarker.path))
        XCTAssertEqual(
            try instanceLock.acknowledgeControlsRequests(paths: paths),
            [requestIdentifier]
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: requestMarker.path))
        XCTAssertEqual(try instanceLock.acknowledgeControlsRequests(paths: paths), [])
        XCTAssertTrue(AdapterInstanceLock.waitForControlsAcknowledgement(
            requestIdentifier: requestIdentifier,
            paths: paths,
            timeoutMilliseconds: 0
        ))
        XCTAssertThrowsError(try AdapterInstanceLock.requestControls(
            paths: paths,
            requestIdentifier: requestIdentifier
        ))
    }

    func testSecondLaunchDroppedNotificationUsesIndependentMarkerObservation() throws {
        let paths = AdapterRuntimePaths(
            root: temporaryDirectory().appendingPathComponent("dropped-notification-\(UUID().uuidString)")
        )
        guard case let .primary(instanceLock) = try AdapterInstanceLock.acquire(paths: paths) else {
            return XCTFail("instance lock unavailable")
        }
        defer { instanceLock.release() }
        let requestIdentifier = try AdapterInstanceLock.requestControls(paths: paths)
        var observed = false

        let acknowledged = AdapterInstanceLock.waitForControlsAcknowledgement(
            requestIdentifier: requestIdentifier,
            paths: paths,
            timeoutMilliseconds: 100,
            pollMilliseconds: 1,
            observe: {
                guard !observed else { return }
                observed = true
                _ = try? instanceLock.acknowledgeControlsRequests(paths: paths)
            }
        )

        XCTAssertTrue(acknowledged)
        XCTAssertTrue(observed)
    }

    func testSecondLaunchBusyPrimaryReturnsNoAcknowledgement() throws {
        let paths = AdapterRuntimePaths(
            root: temporaryDirectory().appendingPathComponent("busy-primary-\(UUID().uuidString)")
        )
        guard case let .primary(instanceLock) = try AdapterInstanceLock.acquire(paths: paths) else {
            return XCTFail("instance lock unavailable")
        }
        defer { instanceLock.release() }
        let requestIdentifier = try AdapterInstanceLock.requestControls(paths: paths)

        XCTAssertFalse(AdapterInstanceLock.waitForControlsAcknowledgement(
            requestIdentifier: requestIdentifier,
            paths: paths,
            timeoutMilliseconds: 5,
            pollMilliseconds: 1
        ))
    }

    func testSecondLaunchAcknowledgementSurvivesStartupFault() throws {
        let paths = AdapterRuntimePaths(
            root: temporaryDirectory().appendingPathComponent("startup-fault-\(UUID().uuidString)")
        )
        guard case let .primary(instanceLock) = try AdapterInstanceLock.acquire(paths: paths) else {
            return XCTFail("instance lock unavailable")
        }
        defer { instanceLock.release() }
        let requestIdentifier = try AdapterInstanceLock.requestControls(paths: paths)

        XCTAssertEqual(
            try instanceLock.acknowledgeControlsRequests(paths: paths),
            [requestIdentifier]
        )
        XCTAssertTrue(AdapterInstanceLock.waitForControlsAcknowledgement(
            requestIdentifier: requestIdentifier,
            paths: paths,
            timeoutMilliseconds: 0
        ))
    }

    func testConcurrentSecondLaunchesReceiveOnlyTheirOwnAcknowledgements() async throws {
        let paths = AdapterRuntimePaths(
            root: temporaryDirectory().appendingPathComponent("concurrent-launches-\(UUID().uuidString)")
        )
        guard case let .primary(instanceLock) = try AdapterInstanceLock.acquire(paths: paths) else {
            return XCTFail("instance lock unavailable")
        }
        defer { instanceLock.release() }
        let requestIdentifiers = (0..<32).map { "request-\($0)" }

        try await withThrowingTaskGroup(of: String.self) { group in
            for requestIdentifier in requestIdentifiers {
                group.addTask {
                    try AdapterInstanceLock.requestControls(
                        paths: paths,
                        requestIdentifier: requestIdentifier
                    )
                }
            }
            var created: Set<String> = []
            for try await requestIdentifier in group { created.insert(requestIdentifier) }
            XCTAssertEqual(created, Set(requestIdentifiers))
        }

        XCTAssertEqual(
            Set(try instanceLock.acknowledgeControlsRequests(paths: paths)),
            Set(requestIdentifiers)
        )
        for requestIdentifier in requestIdentifiers {
            XCTAssertTrue(AdapterInstanceLock.waitForControlsAcknowledgement(
                requestIdentifier: requestIdentifier,
                paths: paths,
                timeoutMilliseconds: 0
            ))
            let acknowledgement = paths.showControlsAcknowledgements
                .appendingPathComponent(requestIdentifier)
                .appendingPathExtension("ack")
            XCTAssertEqual(
                try String(contentsOf: acknowledgement, encoding: .utf8),
                "\(requestIdentifier)\n"
            )
        }
    }

    func testCapabilityRefreshRequiresLockAndLeavesNoFilesystemBearer() throws {
        let root = temporaryDirectory().appendingPathComponent("runtime-\(UUID().uuidString)")
        let paths = AdapterRuntimePaths(root: root)
        guard case let .primary(instanceLock) = try AdapterInstanceLock.acquire(paths: paths) else {
            return XCTFail("instance lock unavailable")
        }
        defer { instanceLock.release() }
        try Data("stale".utf8).write(to: paths.socket)
        try Data("stale".utf8).write(to: paths.controlSocket)

        let capabilities = try CapabilityStore.createFresh(at: paths, ownedBy: instanceLock)

        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.socket.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.controlSocket.path))
        XCTAssertEqual(capabilities.worker.count, 64)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: paths.root.path)
            .contains(where: { $0.hasSuffix(".capability") }))
        let attributes = try FileManager.default.attributesOfItem(atPath: paths.root.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testControlPanelFallbackPolicyCoversRequiredAutomaticReasons() {
        XCTAssertTrue(ControlPanelFallbackPolicy.shouldPresent(
            isStartup: true,
            statusItemReportedVisible: true,
            statusItemReachabilityConfirmed: true,
            permissionsGranted: true,
            terminalRuntimeCondition: false
        ))
        XCTAssertTrue(ControlPanelFallbackPolicy.shouldPresent(
            isStartup: false,
            statusItemReportedVisible: false,
            statusItemReachabilityConfirmed: false,
            permissionsGranted: true,
            terminalRuntimeCondition: false
        ))
        XCTAssertTrue(ControlPanelFallbackPolicy.shouldPresent(
            isStartup: false,
            statusItemReportedVisible: true,
            statusItemReachabilityConfirmed: true,
            permissionsGranted: false,
            terminalRuntimeCondition: false
        ))
        XCTAssertTrue(ControlPanelFallbackPolicy.shouldPresent(
            isStartup: false,
            statusItemReportedVisible: true,
            statusItemReachabilityConfirmed: true,
            permissionsGranted: true,
            terminalRuntimeCondition: true
        ))
        XCTAssertFalse(ControlPanelFallbackPolicy.shouldPresent(
            isStartup: false,
            statusItemReportedVisible: true,
            statusItemReachabilityConfirmed: true,
            permissionsGranted: true,
            terminalRuntimeCondition: false
        ))
        XCTAssertTrue(ControlPanelFallbackPolicy.shouldPresent(
            isStartup: false,
            statusItemReportedVisible: true,
            statusItemReachabilityConfirmed: false,
            permissionsGranted: true,
            terminalRuntimeCondition: false
        ))
    }

    func testControlPanelFallbackTrackerDoesNotReopenWithoutANewReason() {
        var tracker = ControlPanelFallbackTracker()
        XCTAssertTrue(tracker.shouldPresent(
            isStartup: true,
            statusItemReportedVisible: true,
            permissionsGranted: true,
            terminalRuntimeCondition: false
        ))
        XCTAssertFalse(tracker.shouldPresent(
            isStartup: false,
            statusItemReportedVisible: true,
            permissionsGranted: true,
            terminalRuntimeCondition: false
        ))
        tracker.confirmStatusItemReachability()
        XCTAssertTrue(tracker.shouldPresent(
            isStartup: false,
            statusItemReportedVisible: true,
            permissionsGranted: false,
            terminalRuntimeCondition: false
        ))
        XCTAssertFalse(tracker.shouldPresent(
            isStartup: false,
            statusItemReportedVisible: true,
            permissionsGranted: false,
            terminalRuntimeCondition: false
        ))
        XCTAssertFalse(tracker.shouldPresent(
            isStartup: false,
            statusItemReportedVisible: true,
            permissionsGranted: true,
            terminalRuntimeCondition: false
        ))
        XCTAssertTrue(tracker.shouldPresent(
            isStartup: false,
            statusItemReportedVisible: true,
            permissionsGranted: true,
            terminalRuntimeCondition: true
        ))
        XCTAssertFalse(tracker.shouldPresent(
            isStartup: false,
            statusItemReportedVisible: true,
            permissionsGranted: true,
            terminalRuntimeCondition: true
        ))
    }

    func testBackgroundUnsupportedRestoresPanelOnceWithoutRefreshLoop() {
        XCTAssertTrue(ControlPanelFallbackPolicy.isTerminalRuntimeCondition(.backgroundUnsupported))
        var tracker = ControlPanelFallbackTracker()
        tracker.confirmStatusItemReachability()
        XCTAssertTrue(tracker.shouldPresent(
            isStartup: false,
            statusItemReportedVisible: true,
            permissionsGranted: true,
            terminalRuntimeCondition: ControlPanelFallbackPolicy.isTerminalRuntimeCondition(
                .backgroundUnsupported
            )
        ))
        XCTAssertFalse(tracker.shouldPresent(
            isStartup: false,
            statusItemReportedVisible: true,
            permissionsGranted: true,
            terminalRuntimeCondition: ControlPanelFallbackPolicy.isTerminalRuntimeCondition(
                .backgroundUnsupported
            )
        ))
    }

    func testCodeSignatureIdentityParserRequiresCDHashAndRequirement() throws {
        let parsed = try AdapterReleaseIdentityReader.parseCodeSignature("""
        Executable=/Users/tester/Applications/OSRS Explorer Adapter.app/Contents/MacOS/osrs-explorer-adapter
        CDHash=0123456789abcdef
        designated => anchor apple generic and identifier "com.omiyawaki.osrswiki.explorer-adapter"
        """)

        XCTAssertEqual(parsed.cdHash, "0123456789abcdef")
        XCTAssertTrue(parsed.designatedRequirement.contains("com.omiyawaki.osrswiki.explorer-adapter"))
        XCTAssertThrowsError(try AdapterReleaseIdentityReader.parseCodeSignature("CDHash=only"))
    }

    func testEngineAlwaysStartsDisabled() async {
        let engine = AdapterEngine(
            capabilities: AdapterCapabilities(worker: "worker"),
            evidenceRoot: temporaryDirectory().appendingPathComponent("disabled-start")
        )

        await engine.prepare()

        let status = await engine.status()
        XCTAssertFalse(status.enabled)
    }

    func testReparentedWorkerSpawnedCLIIsDeniedAllMutatingControlMethods() async throws {
        let engine = AdapterEngine(
            capabilities: AdapterCapabilities(worker: "worker"),
            evidenceRoot: temporaryDirectory().appendingPathComponent("diagnostics")
        )
        let diagnostics = AdapterDiagnostics(
            runtimeRoot: "/runtime",
            socketPath: "/runtime/adapter.sock",
            lockPath: "/runtime/adapter.lock",
            socketPresent: true,
            lockHeld: true,
            targetWindowBound: false,
            workerClosureVerified: true
        )
        await engine.updateHostStatus(
            AdapterHostStatus(instanceIdentifier: "instance-1"),
            diagnostics: diagnostics
        )

        let accepted = await engine.handle(
            AdapterRequest(method: "diagnostics"),
            role: .control
        )
        XCTAssertTrue(accepted.ok)
        XCTAssertEqual(accepted.diagnostics, diagnostics)
        XCTAssertEqual(accepted.status?.host.instanceIdentifier, "instance-1")

        let rejected = await engine.handle(
            AdapterRequest(method: "diagnostics", capability: "worker"),
            role: .worker
        )
        XCTAssertFalse(rejected.ok)
        XCTAssertTrue(rejected.error?.contains("METHOD_FORBIDDEN") == true)

        for method in ["pause", "queue.activate", "queue.cancel", "job.cancel"] {
            let workerSpawnableControlRequest = await engine.handle(
                AdapterRequest(method: method),
                role: .control
            )
            XCTAssertFalse(workerSpawnableControlRequest.ok, method)
            XCTAssertTrue(
                workerSpawnableControlRequest.error?.contains("METHOD_FORBIDDEN") == true,
                method
            )
        }
        XCTAssertEqual(try ControlCLIRequestFactory.make(arguments: []).method, "status")
        XCTAssertEqual(
            try ControlCLIRequestFactory.make(arguments: ["diagnostics"]).method,
            "diagnostics"
        )
        for command in ["pause", "queue-activate", "queue-cancel", "job-cancel"] {
            XCTAssertThrowsError(try ControlCLIRequestFactory.make(arguments: [command]))
        }
        let visibleHostGesture = await engine.handle(
            AdapterRequest(method: "pause"),
            role: .hostUI
        )
        XCTAssertTrue(visibleHostGesture.ok)
        XCTAssertEqual(visibleHostGesture.message, "PAUSED")
    }

    func testReadOnlyControlPeerPolicyRequiresExactDesignatedCLIIdentity() {
        let peer = UnixPeerIdentity(
            processIdentifier: 99,
            effectiveUserIdentifier: 501,
            effectiveGroupIdentifier: 20
        )
        let expectedPath = "/Applications/OSRS Explorer Adapter.app/Contents/MacOS/osrs-explorerctl"
        let certificate = String(repeating: "A", count: 64)
        let cli = ControlPeerCodeIdentity(
            executablePath: expectedPath,
            signingIdentifier: ControlPeerValidationPolicy.signingIdentifier,
            signingCertificateSHA256: certificate,
            hardenedRuntime: true,
            codeValidityAccepted: true
        )

        XCTAssertTrue(ControlPeerValidationPolicy.accepts(
            peer: peer,
            identity: cli,
            expectedUserIdentifier: 501,
            expectedExecutablePath: expectedPath,
            expectedCertificateSHA256: certificate
        ))
        let wrongCertificate = ControlPeerCodeIdentity(
            executablePath: expectedPath,
            signingIdentifier: ControlPeerValidationPolicy.signingIdentifier,
            signingCertificateSHA256: String(repeating: "B", count: 64),
            hardenedRuntime: true,
            codeValidityAccepted: true
        )
        XCTAssertFalse(ControlPeerValidationPolicy.accepts(
            peer: peer,
            identity: wrongCertificate,
            expectedUserIdentifier: 501,
            expectedExecutablePath: expectedPath,
            expectedCertificateSHA256: certificate
        ))
    }

    func testLaunchAtLoginOptOutSurvivesRelaunchAndFailedCancellation() {
        let suite = "osrs-explorer-adapter-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let firstLaunch = LaunchAtLoginIntentStore(defaults: defaults)
        XCTAssertTrue(firstLaunch.initialize())
        firstLaunch.setDesired(false)
        XCTAssertEqual(
            LaunchAtLoginPolicy.reconcile(desired: firstLaunch.desired, status: .enabled),
            .unregister
        )
        let relaunchedAfterFailedUnregister = LaunchAtLoginIntentStore(defaults: defaults)
        XCTAssertFalse(relaunchedAfterFailedUnregister.desired)
        XCTAssertEqual(
            LaunchAtLoginPolicy.reconcile(
                desired: relaunchedAfterFailedUnregister.desired,
                status: .requiresApproval
            ),
            .unregister
        )
        XCTAssertEqual(
            LaunchAtLoginPolicy.reconcile(desired: false, status: .notRegistered),
            .none
        )
        XCTAssertEqual(
            LaunchAtLoginPolicy.reconcile(desired: true, status: .requiresApproval),
            .awaitApproval
        )
        XCTAssertEqual(
            LaunchAtLoginPolicy.reconcile(desired: true, status: .notFound),
            .register
        )
    }

    func testCandidatePathRuntimeRejectionHasNoLaunchAtLoginReconciliationAuthority() {
        let candidatePathValidationStates: [StableReleaseValidationState] = [.pending, .rejected]

        XCTAssertEqual(
            candidatePathValidationStates.filter {
                LaunchAtLoginStartupPolicy.permitsReconciliation(validationState: $0)
            }.count,
            0
        )
        XCTAssertTrue(LaunchAtLoginStartupPolicy.permitsReconciliation(
            validationState: .validated
        ))
    }

    func testWorkerEnvironmentDropsNodeAndDynamicLoaderOverrides() {
        let sanitized = NodeWorkerEnvironmentPolicy.sanitized(
            from: [
                "HOME": "/Users/tester",
                "TMPDIR": "/tmp/tester",
                "NODE_OPTIONS": "--import=/tmp/untrusted.mjs",
                "NODE_PATH": "/tmp/untrusted-modules",
                "DYLD_INSERT_LIBRARIES": "/tmp/untrusted.dylib",
                "OSRS_ADAPTER_WORKER": "/tmp/untrusted-worker.mjs"
            ],
            socketPath: "/runtime/adapter.sock",
            workerCapability: "worker-capability",
            parentProcessIdentifier: 42
        )

        XCTAssertEqual(sanitized["HOME"], "/Users/tester")
        XCTAssertEqual(sanitized["TMPDIR"], "/tmp/tester")
        XCTAssertEqual(sanitized["PATH"], "/usr/bin:/bin")
        XCTAssertEqual(sanitized["OSRS_ADAPTER_SOCKET"], "/runtime/adapter.sock")
        XCTAssertEqual(sanitized["OSRS_ADAPTER_PARENT_PID"], "42")
        XCTAssertNil(sanitized["NODE_OPTIONS"])
        XCTAssertNil(sanitized["NODE_PATH"])
        XCTAssertNil(sanitized["DYLD_INSERT_LIBRARIES"])
        XCTAssertNil(sanitized["OSRS_ADAPTER_WORKER"])
    }

    func testControlEnableHandoffCandidatesAreRegularWindowOrderedAndUnique() {
        let snapshot = FocusInvariantSnapshot(
            capturedAt: "2026-08-01T00:00:00Z",
            frontmostProcessIdentifier: 90,
            focusedProcessIdentifier: 90,
            cursor: AdapterPoint(x: 1, y: 2),
            orderedWindowIdentifiers: [1, 2, 3, 4, 5],
            orderedWindowProcessIdentifiers: [90, 30, 40, 30, 50],
            orderedRestorableWindowIdentifiers: [2, 3, 4, 5],
            orderedRestorableWindowProcessIdentifiers: [30, 40, 30, 50],
            targetWindowRank: 4,
            targetRestorableWindowRank: 3,
            activeSpaceChangeCount: 0
        )

        XCTAssertEqual(
            ControlEnableHandoffPolicy.candidateProcessIdentifiers(
                snapshot: snapshot,
                excluding: [40]
            ),
            [30, 50]
        )
    }

    func testCanonicalJSONMatchesNodeNumberFormattingForOSRSMetrics() throws {
        let value: [String: Any] = [
            "a": 24.034671438649518,
            "b": 46.770343393580745,
            "c": 0.631578947368421,
            "d": 1e-7,
            "e": 1e-6,
            "f": 1e20,
            "g": 1e21,
            "h": -0.0,
            "i": 24.0
        ]

        XCTAssertEqual(
            String(decoding: try CanonicalJSON.data(value), as: UTF8.self),
            "{\"a\":24.034671438649518,\"b\":46.770343393580745,\"c\":0.631578947368421,\"d\":1e-7,\"e\":0.000001,\"f\":100000000000000000000,\"g\":1e+21,\"h\":0,\"i\":24}"
        )
    }

    func testCanonicalJSONMatchesNodeForObservedOSRSMetricRounding() throws {
        let value: [String: Any] = [
            "close_orange_fraction": 0.024930747922437674
        ]

        XCTAssertEqual(
            String(decoding: try CanonicalJSON.data(value), as: UTF8.self),
            "{\"close_orange_fraction\":0.024930747922437674}"
        )
    }

    func testCanonicalJSONHandlesProductionManifestNumericVolume() throws {
        let values: [Any] = (0..<25_000).map { index in
            Double(index) / 16.0
        }

        let data = try CanonicalJSON.data(["values": values])
        let decoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let decodedValues = try XCTUnwrap(decoded["values"] as? [NSNumber])

        XCTAssertEqual(decodedValues.count, values.count)
        XCTAssertEqual(decodedValues.first?.doubleValue, 0)
        XCTAssertEqual(decodedValues.last?.doubleValue, 1_562.4375)
    }

    func testCanonicalJSONDataDigestPreservesObservedOSRSNumberLexeme() throws {
        let data = Data(
            #"{"result_digest":"worker-digest","value":0.0006872517026106611}"#.utf8
        )
        let expected = AdapterHashing.sha256(
            Data(#"{"value":0.0006872517026106611}"#.utf8)
        )

        XCTAssertEqual(
            try CanonicalJSON.sha256(
                jsonObjectData: data,
                removingTopLevelKey: "result_digest"
            ),
            expected
        )

        var foundationObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        foundationObject.removeValue(forKey: "result_digest")
        XCTAssertNotEqual(try CanonicalJSON.sha256(foundationObject), expected)
    }

    func testTargetSelectionIgnoresHiddenSupportWindows() throws {
        XCTAssertEqual(
            try TargetWindowSelection.selectedIndex([false, false, true, false]),
            2
        )
    }

    func testTargetSelectionRejectsMultipleVisibleWindows() {
        XCTAssertThrowsError(try TargetWindowSelection.selectedIndex([true, false, true])) {
            XCTAssertEqual(String(describing: $0), "TARGET_AMBIGUOUS:2")
        }
    }

    func testTargetSelectionDistinguishesHiddenFromMissing() {
        XCTAssertThrowsError(try TargetWindowSelection.selectedIndex([false, false])) {
            XCTAssertEqual(String(describing: $0), "TARGET_NOT_ON_SCREEN")
        }
        XCTAssertThrowsError(try TargetWindowSelection.selectedIndex([])) {
            XCTAssertEqual(String(describing: $0), "TARGET_NOT_FOUND")
        }
    }

    func testTargetSelectionRequiresExactOSRSPrimaryWindowTitle() {
        XCTAssertTrue(TargetWindowSelection.acceptsPrimaryTitle(
            selectorBundleIdentifier: osrsTargetBundleIdentifier,
            windowTitle: "Old School RuneScape"
        ))
        XCTAssertFalse(TargetWindowSelection.acceptsPrimaryTitle(
            selectorBundleIdentifier: osrsTargetBundleIdentifier,
            windowTitle: "Window"
        ))
        XCTAssertTrue(TargetWindowSelection.acceptsPrimaryTitle(
            selectorBundleIdentifier: "com.example.lab",
            windowTitle: nil
        ))
    }

    func testWindowHitTestIgnoresCoveredTargetCoordinates() {
        let point = AdapterPoint(x: 300, y: 300)
        let entries = [
            WindowHitTestEntry(
                processIdentifier: 11,
                layer: 0,
                alpha: 1,
                bounds: AdapterRect(x: 100, y: 100, width: 400, height: 400)
            ),
            WindowHitTestEntry(
                processIdentifier: 22,
                layer: 0,
                alpha: 1,
                bounds: AdapterRect(x: 200, y: 200, width: 400, height: 400)
            )
        ]

        XCTAssertEqual(
            WindowHitTester.topmostProcessIdentifier(at: point, entries: entries),
            11
        )
    }

    func testWindowHitTestFindsTargetWhenItIsTopmost() {
        let point = AdapterPoint(x: 300, y: 300)
        let entries = [
            WindowHitTestEntry(
                processIdentifier: 22,
                layer: 0,
                alpha: 1,
                bounds: AdapterRect(x: 200, y: 200, width: 400, height: 400)
            ),
            WindowHitTestEntry(
                processIdentifier: 11,
                layer: 0,
                alpha: 1,
                bounds: AdapterRect(x: 100, y: 100, width: 400, height: 400)
            )
        ]

        XCTAssertEqual(
            WindowHitTester.topmostProcessIdentifier(at: point, entries: entries),
            22
        )
    }

    func testForegroundInterferenceInvalidatesActiveGateSynchronously() throws {
        let registry = ForegroundInterferenceRegistry()
        let gate = InputCancellationGate(permissionsGranted: { true })

        XCTAssertFalse(registry.hasActiveLease())
        registry.begin(gate)
        XCTAssertTrue(registry.hasActiveLease())
        XCTAssertTrue(registry.invalidateActive(reason: "USER_INPUT"))
        XCTAssertThrowsError(try gate.checkValid())
        XCTAssertEqual(gate.currentInvalidReason(), "USER_INPUT")
        registry.end(gate)
        XCTAssertFalse(registry.hasActiveLease())
    }

    func testCancellationGateAllowsSamePhaseFocusLossInvalidationWithoutDeadlock() throws {
        let gate = InputCancellationGate(permissionsGranted: { true })

        XCTAssertThrowsError(try gate.performIfValid {
            gate.invalidate(reason: "TARGET_LOST_FOCUS_DURING_INPUT")
            throw AdapterError.actionNotAllowed("TARGET_LOST_FOCUS_DURING_INPUT")
        }) { error in
            XCTAssertTrue(String(describing: error).contains("TARGET_LOST_FOCUS_DURING_INPUT"))
        }
        XCTAssertEqual(gate.currentInvalidReason(), "TARGET_LOST_FOCUS_DURING_INPUT")
    }

    func testTerminationSynchronouslyInvalidatesAllGatesAndRejectsRacingRegistration() {
        let registry = ActiveInputGateRegistry()
        let first = InputCancellationGate(permissionsGranted: { true })
        let second = InputCancellationGate(permissionsGranted: { true })
        XCTAssertTrue(registry.register(first))
        XCTAssertTrue(registry.register(second))
        XCTAssertEqual(registry.activeCount, 2)

        registry.invalidateAllAndClose(reason: "APPLICATION_TERMINATING")

        XCTAssertEqual(registry.activeCount, 0)
        XCTAssertThrowsError(try first.checkValid())
        XCTAssertThrowsError(try second.checkValid())
        let racing = InputCancellationGate(permissionsGranted: { true })
        XCTAssertFalse(registry.register(racing))
        XCTAssertThrowsError(try racing.checkValid())
        XCTAssertEqual(racing.currentInvalidReason(), "APPLICATION_TERMINATING")
    }

    func testClickCancellationAfterMouseDownPostsCleanupMouseUp() async throws {
        let gate = InputCancellationGate(permissionsGranted: { true })
        var phases: [ClickInputPhase] = []

        do {
            try await InputSequenceRunner.runClick(
                cancellationGate: gate,
                movesCursor: false,
                pause: { _ in gate.invalidate(reason: "USER_INPUT") },
                post: { phases.append($0) }
            )
            XCTFail("cancellation between click phases must stop the sequence")
        } catch {
            XCTAssertTrue(String(describing: error).contains("USER_INPUT"))
        }

        XCTAssertEqual(phases, [.down, .cleanupUp])
    }

    func testWorldMapControlClickUsesGameFrameTiming() async throws {
        let gate = InputCancellationGate(permissionsGranted: { true })
        var phases: [ClickInputPhase] = []
        var pauses: [Int] = []

        try await InputSequenceRunner.runClick(
            cancellationGate: gate,
            movesCursor: false,
            pressMilliseconds: 40,
            postUpSettleMilliseconds: 120,
            pause: { pauses.append($0) },
            post: { phases.append($0) }
        )

        XCTAssertEqual(phases, [.down, .up])
        XCTAssertEqual(pauses, [40, 120])
    }

    func testWorldMapControlGeometryScalesReviewedPointIntoLiveCapture() throws {
        XCTAssertEqual(
            try WorldMapControlGeometry.sourcePoint(pixelWidth: 768, pixelHeight: 839),
            AdapterPoint(x: 707, y: 169)
        )
        let livePoint = try WorldMapControlGeometry.sourcePoint(
            pixelWidth: 1614,
            pixelHeight: 1722
        )
        XCTAssertEqual(livePoint.x, 707.0 * 1614.0 / 768.0, accuracy: 0.000_001)
        XCTAssertEqual(livePoint.y, 169.0 * 1722.0 / 839.0, accuracy: 0.000_001)
    }

    func testWorldMapControlGeometryRejectsInvalidCapture() {
        XCTAssertThrowsError(
            try WorldMapControlGeometry.sourcePoint(pixelWidth: 0, pixelHeight: 839)
        )
        XCTAssertThrowsError(
            try WorldMapControlGeometry.sourcePoint(pixelWidth: 768, pixelHeight: 0)
        )
    }

    func testDragCancellationBetweenStepsStopsLateWorkAndPostsCleanupMouseUp() async throws {
        let gate = InputCancellationGate(permissionsGranted: { true })
        var phases: [DragInputPhase] = []
        var pauses = 0

        do {
            try await InputSequenceRunner.runDrag(
                cancellationGate: gate,
                movesCursor: false,
                pause: { _ in
                    pauses += 1
                    if pauses == 3 { gate.invalidate(reason: "USER_INPUT") }
                },
                post: { phases.append($0) }
            )
            XCTFail("cancellation between drag steps must stop the sequence")
        } catch {
            XCTAssertTrue(String(describing: error).contains("USER_INPUT"))
        }

        XCTAssertEqual(
            phases,
            [
                .down,
                .primed,
                .dragged(step: 1, progress: 1.0 / 36.0),
                .dragged(step: 2, progress: 2.0 / 36.0),
                .cleanupUp(lastStep: 2, totalSteps: 36)
            ]
        )
    }

    func testDragPrimesAtExactStartBeforeMovement() async throws {
        let gate = InputCancellationGate(permissionsGranted: { true })
        var phases: [DragInputPhase] = []

        try await InputSequenceRunner.runDrag(
            cancellationGate: gate,
            movesCursor: false,
            steps: 2,
            pause: { _ in },
            post: { phases.append($0) }
        )

        XCTAssertEqual(
            phases,
            [
                .down,
                .primed,
                .dragged(step: 1, progress: 0.5),
                .dragged(step: 2, progress: 1),
                .settled,
                .up
            ]
        )
    }

    func testShortDragUsesReducedInterpolationWithoutChangingLongPanBudget() {
        XCTAssertEqual(InputSequenceRunner.recommendedDragSteps(forDistance: 0), 24)
        XCTAssertEqual(InputSequenceRunner.recommendedDragSteps(forDistance: 100), 24)
        XCTAssertEqual(InputSequenceRunner.recommendedDragSteps(forDistance: 100.01), 36)
        XCTAssertEqual(InputSequenceRunner.recommendedDragSteps(forDistance: 340), 36)
    }

    func testDragSettlesAtEndpointBeforeMouseUp() async throws {
        let gate = InputCancellationGate(permissionsGranted: { true })
        var phases: [DragInputPhase] = []
        var pauses: [Int] = []

        try await InputSequenceRunner.runDrag(
            cancellationGate: gate,
            movesCursor: false,
            steps: 3,
            pause: { pauses.append($0) },
            post: { phases.append($0) }
        )

        XCTAssertEqual(
            phases,
            [
                .down,
                .primed,
                .dragged(step: 1, progress: 1.0 / 3.0),
                .dragged(step: 2, progress: 2.0 / 3.0),
                .dragged(step: 3, progress: 1),
                .settled,
                .up
            ]
        )
        XCTAssertEqual(pauses.last, 16)
    }

    func testLongDragRetainsEndpointBeforeMouseUpForAFullDisplayCycle() async throws {
        let gate = InputCancellationGate(permissionsGranted: { true })
        var phases: [DragInputPhase] = []
        var pauses: [Int] = []

        try await InputSequenceRunner.runDrag(
            cancellationGate: gate,
            movesCursor: false,
            steps: 36,
            pause: { pauses.append($0) },
            post: { phases.append($0) }
        )

        XCTAssertEqual(phases.suffix(3), [.settlingProbe, .settled, .up])
        XCTAssertEqual(pauses.suffix(2), [8, 32])
        XCTAssertEqual(pauses.last, 32)
    }

    func testDragCleanupFailureIsTerminal() async throws {
        let gate = InputCancellationGate(permissionsGranted: { true })

        do {
            try await InputSequenceRunner.runDrag(
                cancellationGate: gate,
                movesCursor: false,
                pause: { _ in gate.invalidate(reason: "USER_INPUT") },
                post: { phase in
                    if case .cleanupUp = phase {
                        throw AdapterError.actionNotAllowed("GLOBAL_BUTTON_RELEASE_UNCONFIRMED")
                    }
                }
            )
            XCTFail("unconfirmed cleanup must replace the interrupted action failure")
        } catch {
            XCTAssertTrue(String(describing: error).contains("INPUT_CLEANUP_FAILED"))
            XCTAssertTrue(String(describing: error).contains("GLOBAL_BUTTON_RELEASE_UNCONFIRMED"))
        }
    }

    func testInjectedPauseAtClaimAuthorizationAndDiscoveryEmitsNothing() async throws {
        for injectedPoint in [
            InputActionSuspensionPoint.claim,
            .authorization,
            .discovery
        ] {
            let gate = InputCancellationGate(permissionsGranted: { true })
            let hooks = InputActionHooks { point, gate in
                if point == injectedPoint {
                    gate.invalidate(reason: "INJECTED_PAUSE_\(point.rawValue)")
                }
            }
            var phases: [ClickInputPhase] = []
            var buttonDown = false

            do {
                try await hooks.revalidate(.claim, gate: gate)
                try await hooks.revalidate(.authorization, gate: gate)
                try await hooks.revalidate(.discovery, gate: gate)
                try await InputSequenceRunner.runClick(
                    cancellationGate: gate,
                    movesCursor: false,
                    pause: { _ in },
                    post: { phase in
                        phases.append(phase)
                        if phase == .down { buttonDown = true }
                        if phase == .up || phase == .cleanupUp { buttonDown = false }
                    }
                )
                XCTFail("injected pause at \(injectedPoint.rawValue) must stop input")
            } catch {
                XCTAssertTrue(String(describing: error).contains("INJECTED_PAUSE"))
            }
            XCTAssertTrue(phases.isEmpty)
            XCTAssertFalse(buttonDown)
        }
    }

    func testInjectedPauseImmediatelyBeforeAXPressEmitsNothing() async throws {
        let gate = InputCancellationGate(permissionsGranted: { true })
        let hooks = InputActionHooks { point, gate in
            if point == .beforeAccessibilityPress {
                gate.invalidate(reason: "INJECTED_PAUSE_BEFORE_AX_PRESS")
            }
        }
        var emitted = false

        do {
            _ = try await AccessibilityPressEmissionRunner.run(
                cancellationGate: gate,
                hooks: hooks
            ) {
                emitted = true
            }
            XCTFail("AX press must not emit after pause")
        } catch {
            XCTAssertTrue(String(describing: error).contains("INJECTED_PAUSE_BEFORE_AX_PRESS"))
        }
        XCTAssertFalse(emitted)
    }

    func testInjectedPauseImmediatelyBeforeCGEmissionEmitsNothingAndReleasesButton() async throws {
        let gate = InputCancellationGate(permissionsGranted: { true })
        let hooks = InputActionHooks { point, gate in
            if point == .beforeCGEvent {
                gate.invalidate(reason: "INJECTED_PAUSE_BEFORE_CG_EVENT")
            }
        }
        var phases: [ClickInputPhase] = []
        var buttonDown = false

        do {
            try await InputSequenceRunner.runClick(
                cancellationGate: gate,
                movesCursor: false,
                pause: { _ in },
                beforeEmission: { _ in
                    try await hooks.revalidate(.beforeCGEvent, gate: gate)
                },
                post: { phase in
                    phases.append(phase)
                    if phase == .down { buttonDown = true }
                    if phase == .up || phase == .cleanupUp { buttonDown = false }
                }
            )
            XCTFail("CG input must not emit after pause")
        } catch {
            XCTAssertTrue(String(describing: error).contains("INJECTED_PAUSE_BEFORE_CG_EVENT"))
        }
        XCTAssertTrue(phases.isEmpty)
        XCTAssertFalse(buttonDown)
    }

    func testEmissionGateChecksPermissionAndDeadlineImmediately() throws {
        var permissionEmission = false
        let permissionGate = InputCancellationGate(permissionsGranted: { false })
        XCTAssertThrowsError(try permissionGate.performEmission {
            permissionEmission = true
        })
        XCTAssertFalse(permissionEmission)

        let clock = TestClock(Date(timeIntervalSince1970: 100))
        let deadlineGate = InputCancellationGate(
            permissionsGranted: { true },
            now: { clock.value }
        )
        try deadlineGate.bindExecutionDeadline(AdapterClock.string(
            from: Date(timeIntervalSince1970: 101)
        ))
        clock.value = Date(timeIntervalSince1970: 102)
        var deadlineEmission = false
        XCTAssertThrowsError(try deadlineGate.performEmission {
            deadlineEmission = true
        })
        XCTAssertFalse(deadlineEmission)
    }

    func testCursorRestorationChecksCancellationPermissionAndDeadlineAtWarpBoundary() throws {
        let expected = CGPoint(x: 10, y: 20)

        let canceled = InputCancellationGate(permissionsGranted: { true })
        canceled.invalidate(reason: "CANCELED_IMMEDIATELY_BEFORE_CURSOR_RESTORE")
        var canceledWarp = false
        XCTAssertThrowsError(try CursorRestorationRunner.restoreIfAuthorized(
            cancellationGate: canceled,
            expectedPosition: expected,
            currentPosition: { .zero },
            restore: { _ in canceledWarp = true }
        ))
        XCTAssertFalse(canceledWarp)

        let permissionLost = InputCancellationGate(permissionsGranted: { false })
        var permissionWarp = false
        XCTAssertThrowsError(try CursorRestorationRunner.restoreIfAuthorized(
            cancellationGate: permissionLost,
            expectedPosition: expected,
            currentPosition: { .zero },
            restore: { _ in permissionWarp = true }
        ))
        XCTAssertFalse(permissionWarp)

        let clock = TestClock(Date(timeIntervalSince1970: 100))
        let expired = InputCancellationGate(
            permissionsGranted: { true },
            now: { clock.value }
        )
        try expired.bindExecutionDeadline(AdapterClock.string(
            from: Date(timeIntervalSince1970: 101)
        ))
        clock.value = Date(timeIntervalSince1970: 101)
        var deadlineWarp = false
        XCTAssertThrowsError(try CursorRestorationRunner.restoreIfAuthorized(
            cancellationGate: expired,
            expectedPosition: expected,
            currentPosition: { .zero },
            restore: { _ in deadlineWarp = true }
        ))
        XCTAssertFalse(deadlineWarp)
    }

    func testCoordinateTransformMapsRetinaCaptureToWindow() throws {
        let point = try CoordinateTransform.screenPoint(
            imagePoint: AdapterPoint(x: 400, y: 300),
            pixelWidth: 800,
            pixelHeight: 600,
            windowFrame: AdapterRect(x: 100, y: 200, width: 400, height: 300)
        )
        XCTAssertEqual(point.x, 300)
        XCTAssertEqual(point.y, 350)
    }

    func testCoordinateTransformRejectsOutsidePoint() {
        XCTAssertThrowsError(try CoordinateTransform.screenPoint(
            imagePoint: AdapterPoint(x: 800, y: 10),
            pixelWidth: 800,
            pixelHeight: 600,
            windowFrame: AdapterRect(x: 0, y: 0, width: 400, height: 300)
        ))
    }

    func testCanonicalJSONMatchesNodeForAbsolutePath() throws {
        let data = try CanonicalJSON.data([
            "artifact_root": "/tmp/osrs-adapter-lab",
            "schema_version": 1
        ])
        XCTAssertEqual(
            String(decoding: data, as: UTF8.self),
            #"{"artifact_root":"/tmp/osrs-adapter-lab","schema_version":1}"#
        )
    }

    func testQueueValidationAndIdempotentCompletion() async throws {
        let fixture = try makeQueueFixture()
        let validated = try QueueManifestValidator.validate(
            fileAt: fixture.url,
            expectedSHA256: fixture.sha256,
            hostEvidenceRoot: temporaryDirectory()
        )
        XCTAssertEqual(validated.manifest.generationIdentifier, "generation-001")
        let store = QueueStore()
        _ = try await store.activate(fileAt: fixture.url, expectedSHA256: fixture.sha256)
        let claimed = try await store.claim()
        let claim = try XCTUnwrap(claimed)
        XCTAssertEqual(claim.item.id, "item-001")
        let sameClaim = try await store.claim()
        XCTAssertEqual(sameClaim?.item.id, "item-001")
        _ = try await store.authorize(
            generationIdentifier: "generation-001",
            itemIdentifier: "item-001",
            action: .click(
                captureIdentifier: "capture-001",
                point: AdapterPoint(x: 100, y: 100),
                button: .left
            ),
            requestedEventSourceMode: .privateState,
            requestedDeliveryMode: .foregroundPid
        )
        try await store.recordActionCompleted(
            generationIdentifier: "generation-001",
            itemIdentifier: "item-001"
        )
        let result = try writeWorkerResult(for: claim)
        try await store.complete(
            generationIdentifier: "generation-001",
            itemIdentifier: "item-001",
            success: true,
            resultPath: result.path,
            resultFileSHA256: result.fileSHA256,
            resultDigest: result.resultDigest
        )
        try await store.complete(
            generationIdentifier: "generation-001",
            itemIdentifier: "item-001",
            success: true,
            resultPath: result.path,
            resultFileSHA256: result.fileSHA256,
            resultDigest: result.resultDigest
        )
        let nextClaim = try await store.claim()
        let drained = await store.isDrained
        XCTAssertNil(nextClaim)
        XCTAssertTrue(drained)
    }

    func testSemanticQueueV2IsStrictAndRawQueueV1RemainsCompatible() throws {
        let hostRoot = temporaryDirectory().appendingPathComponent("semantic-manifest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: hostRoot, withIntermediateDirectories: true)
        let semantic = try writeQueue(semanticQueueObject(hostEvidenceRoot: hostRoot))
        let validated = try QueueManifestValidator.validate(
            fileAt: semantic.url,
            expectedSHA256: semantic.sha256,
            hostEvidenceRoot: hostRoot
        )
        XCTAssertEqual(validated.manifest.schemaVersion, 2)
        XCTAssertEqual(validated.manifest.executionProfile, .semanticMapCaptureV1)
        XCTAssertEqual(validated.manifest.items.first?.operations, [])
        XCTAssertEqual(validated.manifest.items.first?.surface, .gielinorSurface)
        XCTAssertTrue(validated.manifest.allowedOperations.contains(.openWorldMap))

        var legacySemanticObject = try semanticQueueObject(hostEvidenceRoot: hostRoot)
        legacySemanticObject["generation_id"] = "legacy-semantic-generation"
        legacySemanticObject["allowed_operations"] = ["capture", "click", "drag"]
        let legacySemantic = try writeQueue(legacySemanticObject)
        let legacyValidated = try QueueManifestValidator.validate(
            fileAt: legacySemantic.url,
            expectedSHA256: legacySemantic.sha256,
            hostEvidenceRoot: hostRoot
        )
        XCTAssertEqual(
            Set(legacyValidated.manifest.allowedOperations),
            Set([.capture, .click, .drag])
        )

        var injected = try semanticQueueObject(hostEvidenceRoot: hostRoot)
        var injectedItems = injected["items"] as! [[String: Any]]
        injectedItems[0]["from"] = ["x": 430, "y": 300]
        injected["items"] = injectedItems
        let injectedFixture = try writeQueue(injected)
        XCTAssertThrowsError(try QueueManifestValidator.validate(
            fileAt: injectedFixture.url,
            expectedSHA256: injectedFixture.sha256,
            hostEvidenceRoot: hostRoot
        )) { error in
            XCTAssertTrue(String(describing: error).contains("SEMANTIC_ITEM_INVALID"))
        }

        let raw = try makeQueueFixture()
        let rawValidated = try QueueManifestValidator.validate(
            fileAt: raw.url,
            expectedSHA256: raw.sha256,
            hostEvidenceRoot: temporaryDirectory()
        )
        XCTAssertEqual(rawValidated.manifest.schemaVersion, 1)
        XCTAssertNil(rawValidated.manifest.executionProfile)
    }

    func testNativeRealmProductionQueueValidationRejectsExcludedWorklists() throws {
        let hostRoot = temporaryDirectory()
            .appendingPathComponent("native-production-manifest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: hostRoot, withIntermediateDirectories: true)
        let production = try writeQueue(nativeRealmProductionQueueObject(
            hostEvidenceRoot: hostRoot,
            surface: "Ardent Ocean Underground",
            realmID: "cache-world-map:ardent-ocean-underground",
            selectorIndex: 2
        ))
        let validated = try QueueManifestValidator.validate(
            fileAt: production.url,
            expectedSHA256: production.sha256,
            hostEvidenceRoot: hostRoot
        )
        XCTAssertEqual(validated.manifest.schemaVersion, 2)
        XCTAssertEqual(validated.manifest.items.first?.surface?.rawValue, "Ardent Ocean Underground")
        XCTAssertEqual(validated.manifest.items.first?.realmID, "cache-world-map:ardent-ocean-underground")
        XCTAssertEqual(validated.manifest.items.first?.selectorIndex, 2)
        XCTAssertEqual(validated.manifest.items.first?.captureCenter?.x, 1586.7)

        for mutate in [
            { (items: inout [[String: Any]]) in items[0]["realm_id"] = "other-map-123" },
            { (items: inout [[String: Any]]) in items[0]["realm_id"] = "cache-special-region:37" },
            { (items: inout [[String: Any]]) in items[0]["selector_index"] = 50 },
            { (items: inout [[String: Any]]) in items[0]["catalog_version"] = "native-selector-catalog-v0" },
            { (items: inout [[String: Any]]) in items[0].removeValue(forKey: "coverage_cell") }
        ] {
            var changed = try nativeRealmProductionQueueObject(
                hostEvidenceRoot: hostRoot,
                surface: "Ardent Ocean Underground",
                realmID: "cache-world-map:ardent-ocean-underground",
                selectorIndex: 2
            )
            var items = changed["items"] as! [[String: Any]]
            mutate(&items)
            changed["items"] = items
            let fixture = try writeQueue(changed)
            XCTAssertThrowsError(try QueueManifestValidator.validate(
                fileAt: fixture.url,
                expectedSHA256: fixture.sha256,
                hostEvidenceRoot: hostRoot
            )) { error in
                XCTAssertTrue(String(describing: error).contains("NATIVE_REALM_PRODUCTION_ITEM_INVALID"))
            }
        }
    }

    func testNativeRealmProductionQueueValidationHandlesFullCaptureVolume() throws {
        let hostRoot = temporaryDirectory()
            .appendingPathComponent("native-production-volume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: hostRoot, withIntermediateDirectories: true)
        var queue = try nativeRealmProductionQueueObject(
            hostEvidenceRoot: hostRoot,
            surface: "Gielinor Surface",
            realmID: "surface-gielinor",
            selectorIndex: 0
        )
        let template = try XCTUnwrap((queue["items"] as? [[String: Any]])?.first)
        queue["generation_id"] = "native-production-volume"
        queue["items"] = (0..<799).map { index in
            var item = template
            item["id"] = "native-production-volume-\(index)"
            return item
        }

        let fixture = try writeQueue(queue)
        let validated = try QueueManifestValidator.validate(
            fileAt: fixture.url,
            expectedSHA256: fixture.sha256,
            hostEvidenceRoot: hostRoot
        )

        XCTAssertEqual(validated.manifest.items.count, 799)
    }

    func testHistoricalNativeRealmCatalogIsAcceptedOnlyDuringLegacyMigration() throws {
        let hostRoot = temporaryDirectory()
            .appendingPathComponent("historical-native-catalog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: hostRoot, withIntermediateDirectories: true)
        var queue = try nativeRealmProductionQueueObject(
            hostEvidenceRoot: hostRoot,
            surface: "Zanaris",
            realmID: "cache-world-map:zanaris",
            selectorIndex: 49
        )
        var items = try XCTUnwrap(queue["items"] as? [[String: Any]])
        items[0]["catalog_version"] = "native-selector-catalog-v1"
        queue["items"] = items
        let fixture = try writeQueue(queue)
        let data = try Data(contentsOf: fixture.url)

        XCTAssertThrowsError(try QueueManifestValidator.validate(
            fileAt: fixture.url,
            expectedSHA256: fixture.sha256,
            hostEvidenceRoot: hostRoot
        ))
        XCTAssertNoThrow(try QueueManifestValidator.validate(
            data: data,
            sourceURL: fixture.url,
            expectedSHA256: fixture.sha256,
            hostEvidenceRoot: hostRoot,
            allowHistoricalNativeRealmCatalog: true
        ))
    }

    func testGeneratedNativeRealmProductionQueueMatchesHostValidator() throws {
        guard let queuePath = ProcessInfo.processInfo.environment["OSRS_NATIVE_REALM_QUEUE_PATH"] else {
            throw XCTSkip("OSRS_NATIVE_REALM_QUEUE_PATH is not set")
        }
        let queueURL = URL(fileURLWithPath: queuePath)
        let data = try Data(contentsOf: queueURL)
        let raw = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let artifactRoot = try XCTUnwrap(raw["artifact_root"] as? String)
        var hostEvidenceRoot = URL(fileURLWithPath: artifactRoot)
        for _ in 0..<3 {
            hostEvidenceRoot.deleteLastPathComponent()
        }

        let validated = try QueueManifestValidator.validate(
            fileAt: queueURL,
            expectedSHA256: AdapterHashing.sha256(data),
            hostEvidenceRoot: hostEvidenceRoot
        )

        XCTAssertEqual(validated.manifest.items.count, 617)
        XCTAssertEqual(validated.manifest.items.last?.surface?.rawValue, "Zanaris")
    }

    func testResetRelativeNativeCoverageHostRequiresResetAndExactPanBudget() async throws {
        let hostRoot = temporaryDirectory()
            .appendingPathComponent("native-reset-relative-host-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: hostRoot, withIntermediateDirectories: true)
        let fixture = try writeQueue(nativeRealmResetRelativeQueueObject(
            hostEvidenceRoot: hostRoot,
            plannerVersion: "native-realm-coverage-planner-v4"
        ))
        let store = QueueStore(
            acceptanceRoot: hostRoot.appendingPathComponent("broker"),
            hostEvidenceRoot: hostRoot
        )
        _ = try await store.activate(fileAt: fixture.url, expectedSHA256: fixture.sha256)
        let claimed = try await store.claim()
        let claim = try XCTUnwrap(claimed)

        let premature = try semanticCapture("premature-target", root: hostRoot)
        do {
            _ = try await store.authorize(
                generationIdentifier: claim.generationIdentifier,
                itemIdentifier: claim.item.id,
                action: .click(
                    captureIdentifier: premature.captureIdentifier,
                    point: AdapterPoint(x: 350, y: 665),
                    button: .left
                ),
                semanticRole: .surfaceSelectorOpen,
                capture: premature,
                requestedEventSourceMode: nil,
                requestedDeliveryMode: nil
            )
            XCTFail("target selection must not precede the coverage reset")
        } catch {
            XCTAssertTrue(String(describing: error).contains("SEMANTIC_SURFACE_SELECTOR_ACTION_INVALID"))
        }

        for (role, action, capture) in [
            (
                SemanticActionRole.coverageResetSelectorOpen,
                PrivilegedAction.click(
                    captureIdentifier: "reset-open",
                    point: AdapterPoint(x: 350, y: 665),
                    button: .left
                ),
                try semanticCapture("reset-open", root: hostRoot)
            ),
            (
                .coverageResetOptionSelect,
                .click(
                    captureIdentifier: "reset-option",
                    point: AdapterPoint(x: 250, y: 552),
                    button: .left
                ),
                try semanticCapture("reset-option", root: hostRoot)
            ),
            (
                .surfaceSelectorOpen,
                .click(
                    captureIdentifier: "target-open",
                    point: AdapterPoint(x: 350, y: 665),
                    button: .left
                ),
                try semanticCapture("target-open", root: hostRoot)
            ),
            (
                .surfaceOptionSelect,
                .click(
                    captureIdentifier: "target-option",
                    point: AdapterPoint(x: 250, y: 535),
                    button: .left
                ),
                try semanticCapture("target-option", root: hostRoot)
            ),
            (
                .zoomMinus,
                .click(
                    captureIdentifier: "minus-1",
                    point: AdapterPoint(x: 420, y: 660),
                    button: .left
                ),
                try semanticCapture("minus-1", root: hostRoot)
            ),
            (
                .zoomMinus,
                .click(
                    captureIdentifier: "minus-2",
                    point: AdapterPoint(x: 420, y: 660),
                    button: .left
                ),
                try semanticCapture("minus-2", root: hostRoot)
            ),
            (
                .coveragePan,
                .drag(
                    captureIdentifier: "coverage-pan-1",
                    from: AdapterPoint(x: 190, y: 503),
                    to: AdapterPoint(x: 384, y: 479)
                ),
                try semanticCapture("coverage-pan-1", root: hostRoot)
            ),
            (
                .coveragePan,
                .drag(
                    captureIdentifier: "coverage-pan-2",
                    from: AdapterPoint(x: 190, y: 503),
                    to: AdapterPoint(x: 384, y: 479)
                ),
                try semanticCapture("coverage-pan-2", root: hostRoot)
            ),
            (
                .coveragePan,
                .drag(
                    captureIdentifier: "coverage-pan-3",
                    from: AdapterPoint(x: 190, y: 503),
                    to: AdapterPoint(x: 383, y: 479)
                ),
                try semanticCapture("coverage-pan-3", root: hostRoot)
            ),
        ] {
            try await authorizeAndComplete(
                store,
                claim: claim,
                role: role,
                action: action,
                capture: capture
            )
        }

        let extra = try semanticCapture("coverage-pan-extra", root: hostRoot)
        do {
            _ = try await store.authorize(
                generationIdentifier: claim.generationIdentifier,
                itemIdentifier: claim.item.id,
                action: .drag(
                    captureIdentifier: extra.captureIdentifier,
                    from: AdapterPoint(x: 190, y: 503),
                    to: AdapterPoint(x: 383, y: 479)
                ),
                semanticRole: .coveragePan,
                capture: extra,
                requestedEventSourceMode: nil,
                requestedDeliveryMode: nil
            )
            XCTFail("coverage pan budget must be exact")
        } catch {
            XCTAssertTrue(String(describing: error).contains("SEMANTIC_COVERAGE_PAN_ACTION_INVALID"))
        }
    }

    func testBoundedAnchorNativeCoverageHostRequiresExactAnchorBudget() async throws {
        let hostRoot = temporaryDirectory()
            .appendingPathComponent("native-bounded-anchor-host-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: hostRoot, withIntermediateDirectories: true)
        let fixture = try writeQueue(nativeRealmResetRelativeQueueObject(
            hostEvidenceRoot: hostRoot,
            plannerVersion: "native-realm-coverage-planner-v8"
        ))
        let store = QueueStore(
            acceptanceRoot: hostRoot.appendingPathComponent("broker"),
            hostEvidenceRoot: hostRoot
        )
        _ = try await store.activate(fileAt: fixture.url, expectedSHA256: fixture.sha256)
        let claimed = try await store.claim()
        let claim = try XCTUnwrap(claimed)

        for (role, action, capture) in [
            (
                SemanticActionRole.surfaceSelectorOpen,
                PrivilegedAction.click(
                    captureIdentifier: "target-open",
                    point: AdapterPoint(x: 350, y: 665),
                    button: .left
                ),
                try semanticCapture("target-open", root: hostRoot)
            ),
            (
                .surfaceOptionSelect,
                .click(
                    captureIdentifier: "target-option",
                    point: AdapterPoint(x: 250, y: 535),
                    button: .left
                ),
                try semanticCapture("target-option", root: hostRoot)
            ),
            (
                .zoomMinus,
                .click(
                    captureIdentifier: "minus-1",
                    point: AdapterPoint(x: 420, y: 660),
                    button: .left
                ),
                try semanticCapture("minus-1", root: hostRoot)
            ),
            (
                .zoomMinus,
                .click(
                    captureIdentifier: "minus-2",
                    point: AdapterPoint(x: 420, y: 660),
                    button: .left
                ),
                try semanticCapture("minus-2", root: hostRoot)
            ),
            (
                .coverageAnchor,
                .drag(
                    captureIdentifier: "anchor-1",
                    from: AdapterPoint(x: 190, y: 503),
                    to: AdapterPoint(x: 430, y: 103)
                ),
                try semanticCapture("anchor-1", root: hostRoot)
            ),
            (
                .coverageAnchor,
                .drag(
                    captureIdentifier: "anchor-2",
                    from: AdapterPoint(x: 190, y: 503),
                    to: AdapterPoint(x: 430, y: 103)
                ),
                try semanticCapture("anchor-2", root: hostRoot)
            )
        ] {
            try await authorizeAndComplete(
                store,
                claim: claim,
                role: role,
                action: action,
                capture: capture
            )
        }

        let extra = try semanticCapture("anchor-extra", root: hostRoot)
        do {
            _ = try await store.authorize(
                generationIdentifier: claim.generationIdentifier,
                itemIdentifier: claim.item.id,
                action: .drag(
                    captureIdentifier: extra.captureIdentifier,
                    from: AdapterPoint(x: 190, y: 503),
                    to: AdapterPoint(x: 430, y: 103)
                ),
                semanticRole: .coverageAnchor,
                capture: extra,
                requestedEventSourceMode: nil,
                requestedDeliveryMode: nil
            )
            XCTFail("bounded anchor attempts must match the queue budget exactly")
        } catch {
            XCTAssertTrue(String(describing: error).contains("SEMANTIC_COVERAGE_ANCHOR_ACTION_INVALID"))
        }
    }

    func testReopenResetNativeCoverageHostRequiresCloseThenReopen() async throws {
        let hostRoot = temporaryDirectory()
            .appendingPathComponent("native-reopen-reset-host-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: hostRoot, withIntermediateDirectories: true)
        let fixture = try writeQueue(nativeRealmResetRelativeQueueObject(
            hostEvidenceRoot: hostRoot,
            plannerVersion: "native-realm-coverage-planner-v9"
        ))
        let store = QueueStore(
            acceptanceRoot: hostRoot.appendingPathComponent("broker"),
            hostEvidenceRoot: hostRoot
        )
        _ = try await store.activate(fileAt: fixture.url, expectedSHA256: fixture.sha256)
        let claimed = try await store.claim()
        let claim = try XCTUnwrap(claimed)

        let premature = try semanticCapture("reopen-premature-selector", root: hostRoot)
        do {
            _ = try await store.authorize(
                generationIdentifier: claim.generationIdentifier,
                itemIdentifier: claim.item.id,
                action: .click(
                    captureIdentifier: premature.captureIdentifier,
                    point: AdapterPoint(x: 350, y: 665),
                    button: .left
                ),
                semanticRole: .surfaceSelectorOpen,
                capture: premature,
                requestedEventSourceMode: nil,
                requestedDeliveryMode: nil
            )
            XCTFail("surface selection must not precede the close/reopen reset")
        } catch {
            XCTAssertTrue(String(describing: error).contains("SEMANTIC_SURFACE_SELECTOR_ACTION_INVALID"))
        }

        try await authorizeAndComplete(
            store,
            claim: claim,
            role: .coverageMapClose,
            action: .click(
                captureIdentifier: "coverage-map-close",
                point: AdapterPoint(x: 500, y: 50),
                button: .left
            ),
            capture: try semanticCapture("coverage-map-close", root: hostRoot)
        )

        let closeAgain = try semanticCapture("coverage-map-close-again", root: hostRoot)
        do {
            _ = try await store.authorize(
                generationIdentifier: claim.generationIdentifier,
                itemIdentifier: claim.item.id,
                action: .click(
                    captureIdentifier: closeAgain.captureIdentifier,
                    point: AdapterPoint(x: 500, y: 50),
                    button: .left
                ),
                semanticRole: .coverageMapClose,
                capture: closeAgain,
                requestedEventSourceMode: nil,
                requestedDeliveryMode: nil
            )
            XCTFail("a production item may close the map only once")
        } catch {
            XCTAssertTrue(String(describing: error).contains("SEMANTIC_COVERAGE_MAP_CLOSE_ACTION_INVALID"))
        }

        try await authorizeAndComplete(
            store,
            claim: claim,
            role: .coverageMapReopen,
            action: .openWorldMap(captureIdentifier: "coverage-map-reopen"),
            capture: try semanticCapture("coverage-map-reopen", root: hostRoot)
        )
        try await authorizeAndComplete(
            store,
            claim: claim,
            role: .surfaceSelectorOpen,
            action: .click(
                captureIdentifier: "reopen-target-selector",
                point: AdapterPoint(x: 350, y: 665),
                button: .left
            ),
            capture: try semanticCapture("reopen-target-selector", root: hostRoot)
        )
    }

    func testNativeRealmProductionSelectorAuthorizationUsesDynamicRowsAndThumbTargets() async throws {
        let hostRoot = temporaryDirectory()
            .appendingPathComponent("native-production-selector-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: hostRoot, withIntermediateDirectories: true)

        let visibleFixture = try writeQueue(nativeRealmProductionQueueObject(
            hostEvidenceRoot: hostRoot,
            surface: "Ardougne Underground",
            realmID: "cache-world-map:ardougne-underground",
            selectorIndex: 3
        ))
        let visibleStore = QueueStore(
            acceptanceRoot: hostRoot.appendingPathComponent("visible-broker"),
            hostEvidenceRoot: hostRoot
        )
        _ = try await visibleStore.activate(fileAt: visibleFixture.url, expectedSHA256: visibleFixture.sha256)
        let visibleClaimed = try await visibleStore.claim()
        let visibleClaim = try XCTUnwrap(visibleClaimed)
        XCTAssertEqual(visibleClaim.item.realmID, "cache-world-map:ardougne-underground")
        XCTAssertEqual(visibleClaim.item.selectorIndex, 3)
        try await authorizeAndComplete(
            visibleStore,
            claim: visibleClaim,
            role: .surfaceSelectorOpen,
            action: .click(
                captureIdentifier: "visible-selector",
                point: AdapterPoint(x: 350, y: 665),
                button: .left
            ),
            capture: try semanticCapture("visible-selector", root: hostRoot)
        )
        try await authorizeAndComplete(
            visibleStore,
            claim: visibleClaim,
            role: .surfaceOptionSelect,
            action: .click(
                captureIdentifier: "visible-option",
                point: AdapterPoint(x: 250, y: 577),
                button: .left
            ),
            capture: try semanticCapture("visible-option", root: hostRoot)
        )

        let dwarvenFixture = try writeQueue(nativeRealmProductionQueueObject(
            hostEvidenceRoot: hostRoot,
            surface: "Dwarven Mines",
            realmID: "cache-world-map:dwarven-mines",
            selectorIndex: 8
        ))
        let dwarvenStore = QueueStore(
            acceptanceRoot: hostRoot.appendingPathComponent("dwarven-broker"),
            hostEvidenceRoot: hostRoot
        )
        _ = try await dwarvenStore.activate(
            fileAt: dwarvenFixture.url,
            expectedSHA256: dwarvenFixture.sha256
        )
        let dwarvenClaimed = try await dwarvenStore.claim()
        let dwarvenClaim = try XCTUnwrap(dwarvenClaimed)
        let dwarvenSelector = try semanticCapture(
            "dwarven-selector",
            root: hostRoot,
            pixelWidth: 1_614,
            pixelHeight: 1_722
        )
        try await authorizeAndComplete(
            dwarvenStore,
            claim: dwarvenClaim,
            role: .surfaceSelectorOpen,
            action: .click(
                captureIdentifier: dwarvenSelector.captureIdentifier,
                point: AdapterPoint(x: 733, y: 1_346),
                button: .left
            ),
            capture: dwarvenSelector
        )
        let dwarvenDrag = try semanticCapture(
            "dwarven-drag",
            root: hostRoot,
            pixelWidth: 1_614,
            pixelHeight: 1_722
        )
        try await authorizeAndComplete(
            dwarvenStore,
            claim: dwarvenClaim,
            role: .surfaceSelectorScrollbarDrag,
            action: .drag(
                captureIdentifier: dwarvenDrag.captureIdentifier,
                from: AdapterPoint(x: 733, y: 1_131),
                to: AdapterPoint(x: 733, y: 1_148)
            ),
            capture: dwarvenDrag
        )

        let snappedFixture = try writeQueue(nativeRealmProductionQueueObject(
            hostEvidenceRoot: hostRoot,
            surface: "Feldip Hills Underground",
            realmID: "cache-world-map:feldip-underground",
            selectorIndex: 9
        ))
        let snappedStore = QueueStore(
            acceptanceRoot: hostRoot.appendingPathComponent("snapped-broker"),
            hostEvidenceRoot: hostRoot
        )
        _ = try await snappedStore.activate(
            fileAt: snappedFixture.url,
            expectedSHA256: snappedFixture.sha256
        )
        let snappedClaimed = try await snappedStore.claim()
        let snappedClaim = try XCTUnwrap(snappedClaimed)
        let snappedSelector = try semanticCapture(
            "snapped-selector",
            root: hostRoot,
            pixelWidth: 1_614,
            pixelHeight: 1_722
        )
        try await authorizeAndComplete(
            snappedStore,
            claim: snappedClaim,
            role: .surfaceSelectorOpen,
            action: .click(
                captureIdentifier: snappedSelector.captureIdentifier,
                point: AdapterPoint(x: 733, y: 1_346),
                button: .left
            ),
            capture: snappedSelector
        )
        let snappedDrag = try semanticCapture(
            "snapped-drag",
            root: hostRoot,
            pixelWidth: 1_614,
            pixelHeight: 1_722
        )
        try await authorizeAndComplete(
            snappedStore,
            claim: snappedClaim,
            role: .surfaceSelectorScrollbarDrag,
            action: .drag(
                captureIdentifier: snappedDrag.captureIdentifier,
                from: AdapterPoint(x: 733, y: 1_131),
                to: AdapterPoint(x: 733, y: 1_154)
            ),
            capture: snappedDrag
        )

        let keldagrimFixture = try writeQueue(nativeRealmProductionQueueObject(
            hostEvidenceRoot: hostRoot,
            surface: "Keldagrim",
            realmID: "cache-world-map:keldagrim",
            selectorIndex: 15
        ))
        let keldagrimStore = QueueStore(
            acceptanceRoot: hostRoot.appendingPathComponent("keldagrim-broker"),
            hostEvidenceRoot: hostRoot
        )
        _ = try await keldagrimStore.activate(
            fileAt: keldagrimFixture.url,
            expectedSHA256: keldagrimFixture.sha256
        )
        let keldagrimClaimed = try await keldagrimStore.claim()
        let keldagrimClaim = try XCTUnwrap(keldagrimClaimed)
        let keldagrimSelector = try semanticCapture(
            "keldagrim-selector",
            root: hostRoot,
            pixelWidth: 1_614,
            pixelHeight: 1_722
        )
        try await authorizeAndComplete(
            keldagrimStore,
            claim: keldagrimClaim,
            role: .surfaceSelectorOpen,
            action: .click(
                captureIdentifier: keldagrimSelector.captureIdentifier,
                point: AdapterPoint(x: 733, y: 1_346),
                button: .left
            ),
            capture: keldagrimSelector
        )
        let keldagrimDrag = try semanticCapture(
            "keldagrim-drag",
            root: hostRoot,
            pixelWidth: 1_614,
            pixelHeight: 1_722
        )
        try await authorizeAndComplete(
            keldagrimStore,
            claim: keldagrimClaim,
            role: .surfaceSelectorScrollbarDrag,
            action: .drag(
                captureIdentifier: keldagrimDrag.captureIdentifier,
                from: AdapterPoint(x: 733, y: 1_131),
                to: AdapterPoint(x: 733, y: 1_172)
            ),
            capture: keldagrimDrag
        )

        let misthalinFixture = try writeQueue(nativeRealmProductionQueueObject(
            hostEvidenceRoot: hostRoot,
            surface: "Misthalin Underground",
            realmID: "cache-world-map:misthalin-underground",
            selectorIndex: 21
        ))
        let misthalinStore = QueueStore(
            acceptanceRoot: hostRoot.appendingPathComponent("misthalin-broker"),
            hostEvidenceRoot: hostRoot
        )
        _ = try await misthalinStore.activate(
            fileAt: misthalinFixture.url,
            expectedSHA256: misthalinFixture.sha256
        )
        let misthalinClaimed = try await misthalinStore.claim()
        let misthalinClaim = try XCTUnwrap(misthalinClaimed)
        let misthalinSelector = try semanticCapture(
            "misthalin-selector",
            root: hostRoot,
            pixelWidth: 1_614,
            pixelHeight: 1_722
        )
        try await authorizeAndComplete(
            misthalinStore,
            claim: misthalinClaim,
            role: .surfaceSelectorOpen,
            action: .click(
                captureIdentifier: misthalinSelector.captureIdentifier,
                point: AdapterPoint(x: 733, y: 1_346),
                button: .left
            ),
            capture: misthalinSelector
        )
        let misthalinDrag = try semanticCapture(
            "misthalin-drag",
            root: hostRoot,
            pixelWidth: 1_614,
            pixelHeight: 1_722
        )
        try await authorizeAndComplete(
            misthalinStore,
            claim: misthalinClaim,
            role: .surfaceSelectorScrollbarDrag,
            action: .drag(
                captureIdentifier: misthalinDrag.captureIdentifier,
                from: AdapterPoint(x: 733, y: 1_131),
                to: AdapterPoint(x: 733, y: 1_195)
            ),
            capture: misthalinDrag
        )
        let misthalinOption = try semanticCapture(
            "misthalin-option",
            root: hostRoot,
            pixelWidth: 1_614,
            pixelHeight: 1_722
        )
        try await authorizeAndComplete(
            misthalinStore,
            claim: misthalinClaim,
            role: .surfaceOptionSelect,
            action: .click(
                captureIdentifier: misthalinOption.captureIdentifier,
                point: AdapterPoint(x: 540, y: 1_300),
                button: .left
            ),
            capture: misthalinOption
        )

        let offscreenFixture = try writeQueue(nativeRealmProductionQueueObject(
            hostEvidenceRoot: hostRoot,
            surface: "Zanaris",
            realmID: "cache-world-map:zanaris",
            selectorIndex: 46
        ))
        let offscreenStore = QueueStore(
            acceptanceRoot: hostRoot.appendingPathComponent("offscreen-broker"),
            hostEvidenceRoot: hostRoot
        )
        _ = try await offscreenStore.activate(fileAt: offscreenFixture.url, expectedSHA256: offscreenFixture.sha256)
        let offscreenClaimed = try await offscreenStore.claim()
        let offscreenClaim = try XCTUnwrap(offscreenClaimed)
        let selector = try semanticCapture(
            "offscreen-selector",
            root: hostRoot,
            pixelWidth: 1_536,
            pixelHeight: 1_678
        )
        try await authorizeAndComplete(
            offscreenStore,
            claim: offscreenClaim,
            role: .surfaceSelectorOpen,
            action: .click(
                captureIdentifier: selector.captureIdentifier,
                point: AdapterPoint(x: 700, y: 1_330),
                button: .left
            ),
            capture: selector
        )
        let drag = try semanticCapture(
            "offscreen-drag",
            root: hostRoot,
            pixelWidth: 1_536,
            pixelHeight: 1_678
        )
        try await authorizeAndComplete(
            offscreenStore,
            claim: offscreenClaim,
            role: .surfaceSelectorScrollbarDrag,
            action: .drag(
                captureIdentifier: drag.captureIdentifier,
                from: AdapterPoint(x: 698, y: 1_102),
                to: AdapterPoint(x: 698, y: 1_242)
            ),
            capture: drag
        )
        let option = try semanticCapture(
            "offscreen-option",
            root: hostRoot,
            pixelWidth: 1_536,
            pixelHeight: 1_678
        )
        try await authorizeAndComplete(
            offscreenStore,
            claim: offscreenClaim,
            role: .surfaceOptionSelect,
            action: .click(
                captureIdentifier: option.captureIdentifier,
                point: AdapterPoint(x: 500, y: 1_266),
                button: .left
            ),
            capture: option
        )
    }

    func testNativeRealmCoverageResetScrollbarUsesLiveTargetTransform() async throws {
        let hostRoot = temporaryDirectory()
            .appendingPathComponent("native-production-reset-scrollbar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: hostRoot, withIntermediateDirectories: true)
        var queue = try nativeRealmResetRelativeQueueObject(
            hostEvidenceRoot: hostRoot,
            plannerVersion: "native-realm-coverage-planner-v4"
        )
        var item = try XCTUnwrap((queue["items"] as? [[String: Any]])?.first)
        item["id"] = "native-production-v4-cam-torum"
        item["surface"] = "Cam Torum"
        item["realm_id"] = "cache-world-map:cam-torum"
        item["selector_index"] = 7
        queue["items"] = [item]

        let fixture = try writeQueue(queue)
        let store = QueueStore(
            acceptanceRoot: hostRoot.appendingPathComponent("broker"),
            hostEvidenceRoot: hostRoot
        )
        _ = try await store.activate(fileAt: fixture.url, expectedSHA256: fixture.sha256)
        let claimed = try await store.claim()
        let claim = try XCTUnwrap(claimed)

        let selector = try semanticCapture(
            "coverage-reset-selector",
            root: hostRoot,
            pixelWidth: 1_614,
            pixelHeight: 1_722
        )
        try await authorizeAndComplete(
            store,
            claim: claim,
            role: .coverageResetSelectorOpen,
            action: .click(
                captureIdentifier: selector.captureIdentifier,
                point: AdapterPoint(x: 733, y: 1_346),
                button: .left
            ),
            capture: selector
        )

        let drag = try semanticCapture(
            "coverage-reset-scrollbar",
            root: hostRoot,
            pixelWidth: 1_614,
            pixelHeight: 1_722
        )
        try await authorizeAndComplete(
            store,
            claim: claim,
            role: .coverageResetScrollbarDrag,
            action: .drag(
                captureIdentifier: drag.captureIdentifier,
                from: AdapterPoint(x: 733, y: 1_149),
                to: AdapterPoint(x: 733, y: 1_114)
            ),
            capture: drag
        )
    }

    func testCanceledSemanticQueueV2MigratesAcrossRestartBeforeFreshActivation() async throws {
        let hostRoot = temporaryDirectory().appendingPathComponent("semantic-restart-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: hostRoot, withIntermediateDirectories: true)

        var canceledObject = try semanticQueueObject(hostEvidenceRoot: hostRoot)
        let canceledGeneration = "semantic-generation-canceled"
        canceledObject["generation_id"] = canceledGeneration
        canceledObject["artifact_root"] = hostRoot
            .appendingPathComponent(canceledGeneration, isDirectory: true).path
        let canceled = try writeQueue(canceledObject)
        let initialStore = QueueStore(
            acceptanceRoot: hostRoot.appendingPathComponent("broker"),
            hostEvidenceRoot: hostRoot
        )
        _ = try await initialStore.activateForHostUI(
            fileAt: canceled.url,
            expectedSHA256: canceled.sha256
        )
        try await initialStore.cancel(generationIdentifier: canceledGeneration)

        var successorObject = try semanticQueueObject(hostEvidenceRoot: hostRoot)
        let successorGeneration = "semantic-generation-successor"
        successorObject["generation_id"] = successorGeneration
        successorObject["artifact_root"] = hostRoot
            .appendingPathComponent(successorGeneration, isDirectory: true).path
        let successor = try writeQueue(successorObject)
        let restartedStore = QueueStore(
            acceptanceRoot: hostRoot.appendingPathComponent("broker"),
            hostEvidenceRoot: hostRoot
        )
        let activated = try await restartedStore.activateForHostUI(
            fileAt: successor.url,
            expectedSHA256: successor.sha256
        )

        XCTAssertEqual(activated.generationIdentifier, successorGeneration)
        XCTAssertEqual(
            try fileMode(at: hostRoot.appendingPathComponent("used-generations/\(canceledGeneration).json")),
            0o444
        )
        XCTAssertEqual(
            try fileMode(at: hostRoot.appendingPathComponent("revoked-generations/\(canceledGeneration).json")),
            0o444
        )
    }

    func testLegacyMigrationTreatsValidSemanticResultV2AsNonterminalEvidence() async throws {
        let hostRoot = temporaryDirectory()
            .appendingPathComponent("semantic-result-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: hostRoot, withIntermediateDirectories: true)
        var initialObject = try semanticQueueObject(hostEvidenceRoot: hostRoot)
        let initialGeneration = "semantic-result-generation"
        let initialArtifactRoot = hostRoot.appendingPathComponent(initialGeneration)
        initialObject["generation_id"] = initialGeneration
        initialObject["artifact_root"] = initialArtifactRoot.path
        let initial = try writeQueue(initialObject)
        let initialValidated = try QueueManifestValidator.validate(
            fileAt: initial.url,
            expectedSHA256: initial.sha256,
            hostEvidenceRoot: hostRoot
        )
        let item = try XCTUnwrap(initialValidated.manifest.items.first)
        let initialStore = QueueStore(
            acceptanceRoot: hostRoot.appendingPathComponent("broker"),
            hostEvidenceRoot: hostRoot
        )
        _ = try await initialStore.activateForHostUI(
            fileAt: initial.url,
            expectedSHA256: initial.sha256
        )
        try writeImmutableJSON(
            [
                "schema_version": 2,
                "execution_profile": "semantic_map_capture_v1",
                "generation_id": initialGeneration,
                "item_id": item.id,
                "item_sha256": item.itemSHA256,
                "result_digest": String(repeating: "a", count: 64)
            ],
            to: initialArtifactRoot
                .appendingPathComponent("worker/\(initialGeneration)/\(item.id).json")
        )

        var successorObject = try semanticQueueObject(hostEvidenceRoot: hostRoot)
        let successorGeneration = "semantic-result-successor"
        successorObject["generation_id"] = successorGeneration
        successorObject["artifact_root"] = hostRoot
            .appendingPathComponent(successorGeneration).path
        let successor = try writeQueue(successorObject)
        let restartedStore = QueueStore(
            acceptanceRoot: hostRoot.appendingPathComponent("broker"),
            hostEvidenceRoot: hostRoot
        )

        let activated = try await restartedStore.activateForHostUI(
            fileAt: successor.url,
            expectedSHA256: successor.sha256
        )
        XCTAssertEqual(activated.generationIdentifier, successorGeneration)
    }

    func testLegacyMigrationRejectsMismatchedSemanticResultV2() async throws {
        let hostRoot = temporaryDirectory()
            .appendingPathComponent("semantic-result-mismatch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: hostRoot, withIntermediateDirectories: true)
        var initialObject = try semanticQueueObject(hostEvidenceRoot: hostRoot)
        let initialGeneration = "semantic-result-mismatch-generation"
        let initialArtifactRoot = hostRoot.appendingPathComponent(initialGeneration)
        initialObject["generation_id"] = initialGeneration
        initialObject["artifact_root"] = initialArtifactRoot.path
        let initial = try writeQueue(initialObject)
        let initialValidated = try QueueManifestValidator.validate(
            fileAt: initial.url,
            expectedSHA256: initial.sha256,
            hostEvidenceRoot: hostRoot
        )
        let item = try XCTUnwrap(initialValidated.manifest.items.first)
        let initialStore = QueueStore(hostEvidenceRoot: hostRoot)
        _ = try await initialStore.activateForHostUI(
            fileAt: initial.url,
            expectedSHA256: initial.sha256
        )
        try writeImmutableJSON(
            [
                "schema_version": 2,
                "execution_profile": "semantic_map_capture_v1",
                "generation_id": initialGeneration,
                "item_id": "different-item",
                "item_sha256": item.itemSHA256,
                "result_digest": String(repeating: "a", count: 64)
            ],
            to: initialArtifactRoot
                .appendingPathComponent("worker/\(initialGeneration)/\(item.id).json")
        )

        var successorObject = try semanticQueueObject(hostEvidenceRoot: hostRoot)
        successorObject["generation_id"] = "semantic-result-mismatch-successor"
        let successor = try writeQueue(successorObject)
        let restartedStore = QueueStore(hostEvidenceRoot: hostRoot)

        do {
            _ = try await restartedStore.activateForHostUI(
                fileAt: successor.url,
                expectedSHA256: successor.sha256
            )
            XCTFail("mismatched semantic result must fail migration")
        } catch {
            XCTAssertTrue(String(describing: error).contains(
                "EVIDENCE_MALFORMED:\(item.id).json"
            ))
        }
    }

    func testSemanticQueueEnforcesSurfaceZoomPanAndRestoreSequence() async throws {
        let hostRoot = temporaryDirectory().appendingPathComponent("semantic-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: hostRoot, withIntermediateDirectories: true)
        let fixture = try writeQueue(semanticQueueObject(hostEvidenceRoot: hostRoot))
        let store = QueueStore(
            acceptanceRoot: hostRoot.appendingPathComponent("broker"),
            hostEvidenceRoot: hostRoot
        )
        _ = try await store.activate(fileAt: fixture.url, expectedSHA256: fixture.sha256)
        let claimed = try await store.claim()
        let claim = try XCTUnwrap(claimed)

        func deliver(
            _ role: SemanticActionRole,
            _ action: PrivilegedAction,
            capture: CaptureEvidence
        ) async throws {
            let configuration = try await store.authorize(
                generationIdentifier: claim.generationIdentifier,
                itemIdentifier: claim.item.id,
                action: action,
                semanticRole: role,
                capture: capture,
                requestedEventSourceMode: nil,
                requestedDeliveryMode: nil
            )
            XCTAssertEqual(configuration.eventSourceMode, .combinedSessionState)
            XCTAssertEqual(configuration.deliveryMode, .foregroundGlobal)
            try await store.recordActionCompleted(
                generationIdentifier: claim.generationIdentifier,
                itemIdentifier: claim.item.id
            )
        }

        let selector = try semanticCapture("selector", root: hostRoot)
        do {
            _ = try await store.authorize(
                generationIdentifier: claim.generationIdentifier,
                itemIdentifier: claim.item.id,
                action: .click(captureIdentifier: selector.captureIdentifier, point: AdapterPoint(x: 350, y: 665), button: .left),
                semanticRole: .surfaceSelectorOpen,
                capture: selector,
                requestedEventSourceMode: .privateState,
                requestedDeliveryMode: .backgroundPid
            )
            XCTFail("semantic actions must use the fixed foreground delivery configuration")
        } catch {
            XCTAssertTrue(String(describing: error).contains("SEMANTIC_EVENT_SOURCE_MODE_FORBIDDEN"))
        }
        do {
            _ = try await store.authorize(
                generationIdentifier: claim.generationIdentifier,
                itemIdentifier: claim.item.id,
                action: .click(captureIdentifier: selector.captureIdentifier, point: AdapterPoint(x: 350, y: 665), button: .left),
                semanticRole: .surfaceSelectorOpen,
                capture: selector,
                requestedEventSourceMode: .combinedSessionState,
                requestedDeliveryMode: .backgroundPid
            )
            XCTFail("semantic actions must not fall back to PID-directed background delivery")
        } catch {
            XCTAssertTrue(String(describing: error).contains("SEMANTIC_DELIVERY_MODE_FORBIDDEN"))
        }
        try await deliver(
            .surfaceSelectorOpen,
            .click(captureIdentifier: selector.captureIdentifier, point: AdapterPoint(x: 350, y: 665), button: .left),
            capture: selector
        )
        let wrongSurface = try semanticCapture("wrong-surface", root: hostRoot)
        do {
            _ = try await store.authorize(
                generationIdentifier: claim.generationIdentifier,
                itemIdentifier: claim.item.id,
                action: .click(captureIdentifier: wrongSurface.captureIdentifier, point: AdapterPoint(x: 250, y: 560), button: .left),
                semanticRole: .surfaceOptionSelect,
                capture: wrongSurface,
                requestedEventSourceMode: nil,
                requestedDeliveryMode: nil
            )
            XCTFail("a semantic item must authorize only its requested surface row")
        } catch {
            XCTAssertTrue(String(describing: error).contains("SEMANTIC_SURFACE_OPTION_ACTION_INVALID"))
        }
        let surface = try semanticCapture("surface", root: hostRoot)
        try await deliver(
            .surfaceOptionSelect,
            .click(captureIdentifier: surface.captureIdentifier, point: AdapterPoint(x: 250, y: 542), button: .left),
            capture: surface
        )
        for index in 1...2 {
            let capture = try semanticCapture("minus-\(index)", root: hostRoot)
            try await deliver(
                .zoomMinus,
                .click(captureIdentifier: capture.captureIdentifier, point: AdapterPoint(x: 420, y: 660), button: .left),
                capture: capture
            )
        }
        for index in 1...2 {
            let capture = try semanticCapture("plus-\(index)", root: hostRoot)
            try await deliver(
                .zoomPlus,
                .click(captureIdentifier: capture.captureIdentifier, point: AdapterPoint(x: 460, y: 660), button: .left),
                capture: capture
            )
        }
        let pan = try semanticCapture("pan", root: hostRoot)
        do {
            _ = try await store.authorize(
                generationIdentifier: claim.generationIdentifier,
                itemIdentifier: claim.item.id,
                action: .drag(
                    captureIdentifier: pan.captureIdentifier,
                    from: AdapterPoint(x: 467, y: 300),
                    to: AdapterPoint(x: 127, y: 300)
                ),
                semanticRole: .pan,
                capture: pan,
                requestedEventSourceMode: nil,
                requestedDeliveryMode: nil
            )
            XCTFail("semantic pan translation must remain within 36 reviewed pixels")
        } catch {
            XCTAssertTrue(String(describing: error).contains("SEMANTIC_PAN_ACTION_INVALID"))
        }
        do {
            _ = try await store.authorize(
                generationIdentifier: claim.generationIdentifier,
                itemIdentifier: claim.item.id,
                action: .drag(
                    captureIdentifier: pan.captureIdentifier,
                    from: AdapterPoint(x: 450, y: 300),
                    to: AdapterPoint(x: 262, y: 300)
                ),
                semanticRole: .pan,
                capture: pan,
                requestedEventSourceMode: nil,
                requestedDeliveryMode: nil
            )
            XCTFail("semantic pan fractions must remain 5-percent quantized")
        } catch {
            XCTAssertTrue(String(describing: error).contains("SEMANTIC_PAN_ACTION_INVALID"))
        }
        try await deliver(
            .pan,
            .drag(captureIdentifier: pan.captureIdentifier, from: AdapterPoint(x: 450, y: 308), to: AdapterPoint(x: 246, y: 308)),
            capture: pan
        )
        let restore = try semanticCapture("restore", root: hostRoot)
        do {
            _ = try await store.authorize(
                generationIdentifier: claim.generationIdentifier,
                itemIdentifier: claim.item.id,
                action: .drag(
                    captureIdentifier: restore.captureIdentifier,
                    from: AdapterPoint(x: 70, y: 300),
                    to: AdapterPoint(x: 30, y: 300)
                ),
                semanticRole: .restore,
                capture: restore,
                requestedEventSourceMode: nil,
                requestedDeliveryMode: nil
            )
            XCTFail("measured restoration must remain opposite the delivered pan")
        } catch {
            XCTAssertTrue(String(describing: error).contains("SEMANTIC_RESTORE_ACTION_INVALID"))
        }
        try await deliver(
            .restore,
            .drag(captureIdentifier: restore.captureIdentifier, from: AdapterPoint(x: 246, y: 300), to: AdapterPoint(x: 450, y: 300)),
            capture: restore
        )
        do {
            try await store.complete(
                generationIdentifier: claim.generationIdentifier,
                itemIdentifier: claim.item.id,
                success: true
            )
            XCTFail("semantic completion still requires its immutable result")
        } catch {
            XCTAssertTrue(String(describing: error).contains("RESULT_BINDING_REQUIRED"))
        }
    }

    func testSemanticRecoveryRolesAreCaptureBoundOrderedAndSingleUse() async throws {
        let hostRoot = temporaryDirectory()
            .appendingPathComponent("semantic-recovery-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: hostRoot, withIntermediateDirectories: true)
        let fixture = try writeQueue(semanticQueueObject(hostEvidenceRoot: hostRoot))
        let store = QueueStore(
            acceptanceRoot: hostRoot.appendingPathComponent("broker"),
            hostEvidenceRoot: hostRoot
        )
        _ = try await store.activate(fileAt: fixture.url, expectedSHA256: fixture.sha256)
        let claimed = try await store.claim()
        let claim = try XCTUnwrap(claimed)

        func deliver(
            _ role: SemanticActionRole,
            _ action: PrivilegedAction,
            capture: CaptureEvidence
        ) async throws {
            _ = try await store.authorize(
                generationIdentifier: claim.generationIdentifier,
                itemIdentifier: claim.item.id,
                action: action,
                semanticRole: role,
                capture: capture,
                requestedEventSourceMode: nil,
                requestedDeliveryMode: nil
            )
            try await store.recordActionCompleted(
                generationIdentifier: claim.generationIdentifier,
                itemIdentifier: claim.item.id
            )
        }

        let tryAgain = try semanticCapture("recovery-try-again", root: hostRoot)
        try await deliver(
            .recoveryTryAgain,
            .click(
                captureIdentifier: tryAgain.captureIdentifier,
                point: AdapterPoint(x: 384, y: 335),
                button: .left
            ),
            capture: tryAgain
        )
        let duplicate = try semanticCapture("recovery-try-again-duplicate", root: hostRoot)
        do {
            _ = try await store.authorize(
                generationIdentifier: claim.generationIdentifier,
                itemIdentifier: claim.item.id,
                action: .click(
                    captureIdentifier: duplicate.captureIdentifier,
                    point: AdapterPoint(x: 384, y: 335),
                    button: .left
                ),
                semanticRole: .recoveryTryAgain,
                capture: duplicate,
                requestedEventSourceMode: nil,
                requestedDeliveryMode: nil
            )
            XCTFail("a semantic recovery transition must be single use")
        } catch {
            XCTAssertTrue(String(describing: error).contains(
                "SEMANTIC_RECOVERY_TRY_AGAIN_ACTION_INVALID"
            ))
        }

        let steam = try semanticCapture("recovery-steam", root: hostRoot)
        try await deliver(
            .recoverySteamSignIn,
            .click(
                captureIdentifier: steam.captureIdentifier,
                point: AdapterPoint(x: 383, y: 274),
                button: .left
            ),
            capture: steam
        )
        let clickToPlay = try semanticCapture("recovery-click-to-play", root: hostRoot)
        try await deliver(
            .recoveryClickToPlay,
            .click(
                captureIdentifier: clickToPlay.captureIdentifier,
                point: AdapterPoint(x: 395, y: 360),
                button: .left
            ),
            capture: clickToPlay
        )
        let openMap = try semanticCapture("recovery-open-map", root: hostRoot)
        try await deliver(
            .recoveryOpenWorldMap,
            .openWorldMap(captureIdentifier: openMap.captureIdentifier),
            capture: openMap
        )

        let staleSteam = try semanticCapture("recovery-stale-steam", root: hostRoot)
        do {
            _ = try await store.authorize(
                generationIdentifier: claim.generationIdentifier,
                itemIdentifier: claim.item.id,
                action: .click(
                    captureIdentifier: staleSteam.captureIdentifier,
                    point: AdapterPoint(x: 383, y: 274),
                    button: .left
                ),
                semanticRole: .recoverySteamSignIn,
                capture: staleSteam,
                requestedEventSourceMode: nil,
                requestedDeliveryMode: nil
            )
            XCTFail("semantic recovery must reject a transition after a later state")
        } catch {
            XCTAssertTrue(String(describing: error).contains(
                "SEMANTIC_RECOVERY_STEAM_SIGN_IN_ACTION_INVALID"
            ))
        }

        let selector = try semanticCapture("recovery-selector", root: hostRoot)
        try await deliver(
            .surfaceSelectorOpen,
            .click(
                captureIdentifier: selector.captureIdentifier,
                point: AdapterPoint(x: 350, y: 665),
                button: .left
            ),
            capture: selector
        )
        let lateRecovery = try semanticCapture("recovery-after-selector", root: hostRoot)
        do {
            _ = try await store.authorize(
                generationIdentifier: claim.generationIdentifier,
                itemIdentifier: claim.item.id,
                action: .openWorldMap(captureIdentifier: lateRecovery.captureIdentifier),
                semanticRole: .recoveryOpenWorldMap,
                capture: lateRecovery,
                requestedEventSourceMode: nil,
                requestedDeliveryMode: nil
            )
            XCTFail("recovery actions must finish before semantic map work begins")
        } catch {
            XCTAssertTrue(String(describing: error).contains(
                "SEMANTIC_RECOVERY_OPEN_WORLD_MAP_ACTION_INVALID"
            ))
        }
    }

    func testSemanticSurfaceOptionAcceptsPixelAlignedDynamicCapturePoints() async throws {
        for (surface, optionPoint) in [
            (SemanticMapSurface.ancientCavern, AdapterPoint(x: 540, y: 1_121)),
            (SemanticMapSurface.ardougneUnderground, AdapterPoint(x: 540, y: 1_190)),
            (SemanticMapSurface.asgarniaIceCave, AdapterPoint(x: 540, y: 1_227))
        ] {
            try await assertSemanticSurfaceOptionAcceptsPixelAlignedDynamicCapturePoint(
                surface: surface,
                optionPoint: optionPoint
            )
        }
    }

    func testSemanticQueueAcceptsSparsePanFractionAtLiveCaptureGeometry() async throws {
        let hostRoot = temporaryDirectory()
            .appendingPathComponent("semantic-live-sparse-pan-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: hostRoot, withIntermediateDirectories: true)
        let fixture = try writeQueue(semanticQueueObject(
            hostEvidenceRoot: hostRoot,
            surface: SemanticMapSurface.ancientCavern.rawValue,
            zoomPercent: 37.5,
            criterionFamily: SemanticCriterionFamily.southwardTopology.rawValue
        ))
        let store = QueueStore(
            acceptanceRoot: hostRoot.appendingPathComponent("broker"),
            hostEvidenceRoot: hostRoot
        )
        _ = try await store.activate(fileAt: fixture.url, expectedSHA256: fixture.sha256)
        let claimed = try await store.claim()
        let claim = try XCTUnwrap(claimed)

        func deliver(
            _ role: SemanticActionRole,
            _ action: PrivilegedAction,
            capture: CaptureEvidence
        ) async throws {
            _ = try await store.authorize(
                generationIdentifier: claim.generationIdentifier,
                itemIdentifier: claim.item.id,
                action: action,
                semanticRole: role,
                capture: capture,
                requestedEventSourceMode: nil,
                requestedDeliveryMode: nil
            )
            try await store.recordActionCompleted(
                generationIdentifier: claim.generationIdentifier,
                itemIdentifier: claim.item.id
            )
        }

        func liveCapture(_ identifier: String) throws -> CaptureEvidence {
            try semanticCapture(identifier, root: hostRoot, pixelWidth: 1_614, pixelHeight: 1_722)
        }

        let selector = try liveCapture("live-sparse-selector")
        try await deliver(
            .surfaceSelectorOpen,
            .click(
                captureIdentifier: selector.captureIdentifier,
                point: AdapterPoint(x: 735, y: 1_365),
                button: .left
            ),
            capture: selector
        )
        let surface = try liveCapture("live-sparse-surface")
        try await deliver(
            .surfaceOptionSelect,
            .click(
                captureIdentifier: surface.captureIdentifier,
                point: AdapterPoint(x: 540, y: 1_121),
                button: .left
            ),
            capture: surface
        )
        for index in 1...2 {
            let capture = try liveCapture("live-sparse-minus-\(index)")
            try await deliver(
                .zoomMinus,
                .click(
                    captureIdentifier: capture.captureIdentifier,
                    point: AdapterPoint(x: 883, y: 1_354),
                    button: .left
                ),
                capture: capture
            )
        }
        let pan = try liveCapture("live-sparse-pan")
        try await deliver(
            .pan,
            .drag(
                captureIdentifier: pan.captureIdentifier,
                from: AdapterPoint(x: 534, y: 1_133),
                to: AdapterPoint(x: 534, y: 628)
            ),
            capture: pan
        )
    }

    func testSemanticQueueAcceptsTwoCellCenterDetailPanAtLiveCaptureGeometry() async throws {
        let hostRoot = temporaryDirectory()
            .appendingPathComponent("semantic-live-two-cell-pan-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: hostRoot, withIntermediateDirectories: true)
        let fixture = try writeQueue(semanticQueueObject(
            hostEvidenceRoot: hostRoot,
            surface: SemanticMapSurface.gielinorSurface.rawValue,
            zoomPercent: 37.5,
            criterionFamily: SemanticCriterionFamily.centerDetail.rawValue
        ))
        let store = QueueStore(
            acceptanceRoot: hostRoot.appendingPathComponent("broker"),
            hostEvidenceRoot: hostRoot
        )
        _ = try await store.activate(fileAt: fixture.url, expectedSHA256: fixture.sha256)
        let claimed = try await store.claim()
        let claim = try XCTUnwrap(claimed)

        func deliver(
            _ role: SemanticActionRole,
            _ action: PrivilegedAction,
            capture: CaptureEvidence
        ) async throws {
            _ = try await store.authorize(
                generationIdentifier: claim.generationIdentifier,
                itemIdentifier: claim.item.id,
                action: action,
                semanticRole: role,
                capture: capture,
                requestedEventSourceMode: nil,
                requestedDeliveryMode: nil
            )
            try await store.recordActionCompleted(
                generationIdentifier: claim.generationIdentifier,
                itemIdentifier: claim.item.id
            )
        }

        func liveCapture(_ identifier: String) throws -> CaptureEvidence {
            try semanticCapture(identifier, root: hostRoot, pixelWidth: 1_614, pixelHeight: 1_722)
        }

        let selector = try liveCapture("live-two-cell-selector")
        try await deliver(
            .surfaceSelectorOpen,
            .click(
                captureIdentifier: selector.captureIdentifier,
                point: AdapterPoint(x: 735, y: 1_365),
                button: .left
            ),
            capture: selector
        )
        let surface = try liveCapture("live-two-cell-surface")
        try await deliver(
            .surfaceOptionSelect,
            .click(
                captureIdentifier: surface.captureIdentifier,
                point: AdapterPoint(x: 540, y: 1_099),
                button: .left
            ),
            capture: surface
        )
        for index in 1...2 {
            let capture = try liveCapture("live-two-cell-minus-\(index)")
            try await deliver(
                .zoomMinus,
                .click(
                    captureIdentifier: capture.captureIdentifier,
                    point: AdapterPoint(x: 883, y: 1_354),
                    button: .left
                ),
                capture: capture
            )
        }
        let pan = try liveCapture("live-two-cell-pan")
        try await deliver(
            .pan,
            .drag(
                captureIdentifier: pan.captureIdentifier,
                from: AdapterPoint(x: 883, y: 1_067),
                to: AdapterPoint(x: 855, y: 1_036)
            ),
            capture: pan
        )
    }

    private func assertSemanticSurfaceOptionAcceptsPixelAlignedDynamicCapturePoint(
        surface: SemanticMapSurface,
        optionPoint: AdapterPoint
    ) async throws {
        let hostRoot = temporaryDirectory()
            .appendingPathComponent("semantic-dynamic-option-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: hostRoot, withIntermediateDirectories: true)
        let fixture = try writeQueue(semanticQueueObject(
            hostEvidenceRoot: hostRoot,
            surface: surface.rawValue
        ))
        let store = QueueStore(
            acceptanceRoot: hostRoot.appendingPathComponent("broker"),
            hostEvidenceRoot: hostRoot
        )
        _ = try await store.activate(fileAt: fixture.url, expectedSHA256: fixture.sha256)
        let claimed = try await store.claim()
        let claim = try XCTUnwrap(claimed)

        let selector = try semanticCapture(
            "dynamic-selector",
            root: hostRoot,
            pixelWidth: 1_614,
            pixelHeight: 1_722
        )
        _ = try await store.authorize(
            generationIdentifier: claim.generationIdentifier,
            itemIdentifier: claim.item.id,
            action: .click(
                captureIdentifier: selector.captureIdentifier,
                point: AdapterPoint(x: 735, y: 1_365),
                button: .left
            ),
            semanticRole: .surfaceSelectorOpen,
            capture: selector,
            requestedEventSourceMode: nil,
            requestedDeliveryMode: nil
        )
        try await store.recordActionCompleted(
            generationIdentifier: claim.generationIdentifier,
            itemIdentifier: claim.item.id
        )

        let option = try semanticCapture(
            "dynamic-ancient-option",
            root: hostRoot,
            pixelWidth: 1_614,
            pixelHeight: 1_722
        )
        _ = try await store.authorize(
            generationIdentifier: claim.generationIdentifier,
            itemIdentifier: claim.item.id,
            action: .click(
                captureIdentifier: option.captureIdentifier,
                point: optionPoint,
                button: .left
            ),
            semanticRole: .surfaceOptionSelect,
            capture: option,
            requestedEventSourceMode: nil,
            requestedDeliveryMode: nil
        )
    }

    func testSemanticQueueRequiresOneScrollbarDragAndRestoresTopStateForZanaris() async throws {
        let hostRoot = temporaryDirectory().appendingPathComponent("semantic-terminal-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: hostRoot, withIntermediateDirectories: true)
        var queue = try semanticQueueObject(hostEvidenceRoot: hostRoot)
        var items = queue["items"] as! [[String: Any]]
        items[0]["surface"] = SemanticMapSurface.zanaris.rawValue
        items[0]["zoom_percent"] = 37.5
        items[0]["criterion_family"] = SemanticCriterionFamily.centerDetail.rawValue
        items[0]["restore_after_capture"] = true
        queue["items"] = items
        let fixture = try writeQueue(queue)
        let store = QueueStore(
            acceptanceRoot: hostRoot.appendingPathComponent("broker"),
            hostEvidenceRoot: hostRoot
        )
        _ = try await store.activate(fileAt: fixture.url, expectedSHA256: fixture.sha256)
        let claimed = try await store.claim()
        let claim = try XCTUnwrap(claimed)

        func deliver(
            _ role: SemanticActionRole,
            _ action: PrivilegedAction,
            capture: CaptureEvidence
        ) async throws {
            _ = try await store.authorize(
                generationIdentifier: claim.generationIdentifier,
                itemIdentifier: claim.item.id,
                action: action,
                semanticRole: role,
                capture: capture,
                requestedEventSourceMode: nil,
                requestedDeliveryMode: nil
            )
            try await store.recordActionCompleted(
                generationIdentifier: claim.generationIdentifier,
                itemIdentifier: claim.item.id
            )
        }

        let selector = try semanticCapture("terminal-selector", root: hostRoot)
        try await deliver(
            .surfaceSelectorOpen,
            .click(
                captureIdentifier: selector.captureIdentifier,
                point: AdapterPoint(x: 350, y: 665),
                button: .left
            ),
            capture: selector
        )

        let prematureOption = try semanticCapture("terminal-premature-option", root: hostRoot)
        do {
            _ = try await store.authorize(
                generationIdentifier: claim.generationIdentifier,
                itemIdentifier: claim.item.id,
                action: .click(
                    captureIdentifier: prematureOption.captureIdentifier,
                    point: AdapterPoint(x: 250, y: 640),
                    button: .left
                ),
                semanticRole: .surfaceOptionSelect,
                capture: prematureOption,
                requestedEventSourceMode: nil,
                requestedDeliveryMode: nil
            )
            XCTFail("Zanaris must not be selectable before the bottom scrollbar drag")
        } catch {
            XCTAssertTrue(String(describing: error).contains("SEMANTIC_SURFACE_OPTION_ACTION_INVALID"))
        }

        let bottomDrag = try semanticCapture("terminal-bottom-drag", root: hostRoot)
        try await deliver(
            .surfaceSelectorScrollbarDrag,
            .drag(
                captureIdentifier: bottomDrag.captureIdentifier,
                from: AdapterPoint(x: 349, y: 551),
                to: AdapterPoint(x: 349, y: 628)
            ),
            capture: bottomDrag
        )

        let overBudget = try semanticCapture("terminal-second-drag", root: hostRoot)
        do {
            _ = try await store.authorize(
                generationIdentifier: claim.generationIdentifier,
                itemIdentifier: claim.item.id,
                action: .drag(
                    captureIdentifier: overBudget.captureIdentifier,
                    from: AdapterPoint(x: 349, y: 551),
                    to: AdapterPoint(x: 349, y: 628)
                ),
                semanticRole: .surfaceSelectorScrollbarDrag,
                capture: overBudget,
                requestedEventSourceMode: nil,
                requestedDeliveryMode: nil
            )
            XCTFail("selector navigation must reject a second drag in one opening")
        } catch {
            XCTAssertTrue(String(describing: error).contains("SEMANTIC_SURFACE_SCROLL_ACTION_INVALID"))
        }

        let option = try semanticCapture("terminal-option", root: hostRoot)
        try await deliver(
            .surfaceOptionSelect,
            .click(
                captureIdentifier: option.captureIdentifier,
                point: AdapterPoint(x: 250, y: 640),
                button: .left
            ),
            capture: option
        )

        for index in 1...2 {
            let capture = try semanticCapture("terminal-minus-\(index)", root: hostRoot)
            try await deliver(
                .zoomMinus,
                .click(
                    captureIdentifier: capture.captureIdentifier,
                    point: AdapterPoint(x: 420, y: 660),
                    button: .left
                ),
                capture: capture
            )
        }
        let pan = try semanticCapture("terminal-pan", root: hostRoot)
        try await deliver(
            .pan,
            .drag(
                captureIdentifier: pan.captureIdentifier,
                from: AdapterPoint(x: 420, y: 520),
                to: AdapterPoint(x: 150, y: 210)
            ),
            capture: pan
        )
        let restore = try semanticCapture("terminal-restore", root: hostRoot)
        try await deliver(
            .restore,
            .drag(
                captureIdentifier: restore.captureIdentifier,
                from: AdapterPoint(x: 86, y: 113),
                to: AdapterPoint(x: 356, y: 423)
            ),
            capture: restore
        )
        let resetSelector = try semanticCapture("terminal-reset-selector", root: hostRoot)
        try await deliver(
            .surfaceSelectorOpen,
            .click(
                captureIdentifier: resetSelector.captureIdentifier,
                point: AdapterPoint(x: 350, y: 665),
                button: .left
            ),
            capture: resetSelector
        )
        let topDrag = try semanticCapture(
            "terminal-top-drag",
            root: hostRoot,
            pixelWidth: 1_614,
            pixelHeight: 1_722
        )
        try await deliver(
            .surfaceSelectorScrollbarDrag,
            .drag(
                captureIdentifier: topDrag.captureIdentifier,
                from: AdapterPoint(x: 733, y: 1_275),
                to: AdapterPoint(x: 733, y: 1_114)
            ),
            capture: topDrag
        )
        let gielinorOption = try semanticCapture("terminal-gielinor-option", root: hostRoot)
        try await deliver(
            .surfaceOptionSelect,
            .click(
                captureIdentifier: gielinorOption.captureIdentifier,
                point: AdapterPoint(x: 250, y: 542),
                button: .left
            ),
            capture: gielinorOption
        )
        do {
            try await store.complete(
                generationIdentifier: claim.generationIdentifier,
                itemIdentifier: claim.item.id,
                success: true
            )
            XCTFail("semantic completion still requires its immutable result")
        } catch {
            XCTAssertTrue(String(describing: error).contains("RESULT_BINDING_REQUIRED"))
        }
    }

    func testSemanticBrokerRequiresExactPixelScrollbarStops() async throws {
        let broker = SandboxResultBroker(root: temporaryDirectory())

        func proof(anchor: String) -> [String: Any] {
            let top = anchor == "top" ? 543 : 613
            let bottom = top + 16
            let topClearance = top - 543
            let bottomClearance = 629 - bottom
            return [
                "target": "SEMANTIC_SURFACE_SCROLLBAR_THUMB",
                "anchor": anchor,
                "state": anchor,
                "selector_open": true,
                "thumb_at_stop": true,
                "exactly_one_target": true,
                "pixel_resolution": 1,
                "coordinate_semantics": "LEFT_TOP_INCLUSIVE_RIGHT_BOTTOM_EXCLUSIVE",
                "stop_tolerance_pixels": 0,
                "normalized_correlation": 0.95,
                "distinct_second_correlation": 0.80,
                "correlation_separation": 0.15,
                "normalized_click_point": [
                    "x": 349, "y": anchor == "top" ? 551 : 621
                ],
                "normalized_observed_bbox": [
                    "left": 342, "top": top, "right": 356, "bottom": bottom
                ],
                "normalized_up_button_bbox": [
                    "left": 342, "top": 529, "right": 356, "bottom": 543
                ],
                "normalized_down_button_bbox": [
                    "left": 342, "top": 629, "right": 356, "bottom": 643
                ],
                "up_button_correlation": 0.95,
                "up_button_distinct_second_correlation": 0.80,
                "down_button_correlation": 0.95,
                "down_button_distinct_second_correlation": 0.80,
                "top_clearance_pixels": topClearance,
                "bottom_clearance_pixels": bottomClearance,
                "remaining_travel_to_top_pixels": topClearance,
                "remaining_travel_to_bottom_pixels": bottomClearance,
                "travel_range_pixels": 70,
                "top_stop_thumb_top_bounds": ["minimum": 543, "maximum": 543],
                "bottom_stop_thumb_top_bounds": ["minimum": 613, "maximum": 613],
                "normalized_track_bbox": [
                    "left": 342, "top": 543, "right": 356, "bottom": 629
                ],
                "source_frame_geometry": ["width": 768, "height": 839],
                "source_track_bbox": [
                    "left": 342, "top": 543, "right": 356, "bottom": 629
                ],
                "source_observed_bbox": [
                    "left": 342, "top": top, "right": 356, "bottom": bottom
                ],
                "source_click_point": ["x": 349, "y": anchor == "top" ? 551 : 621],
                "source_top_clearance_pixels": topClearance,
                "source_bottom_clearance_pixels": bottomClearance
            ]
        }

        let topPassed = await broker.semanticScrollbarProofPassed(proof(anchor: "top"), anchor: "top")
        let bottomPassed = await broker.semanticScrollbarProofPassed(
            proof(anchor: "bottom"),
            anchor: "bottom"
        )
        XCTAssertTrue(topPassed)
        XCTAssertTrue(bottomPassed)

        var shiftedTop = proof(anchor: "top")
        shiftedTop["normalized_up_button_bbox"] = [
            "left": 344, "top": 532, "right": 358, "bottom": 546
        ]
        shiftedTop["normalized_track_bbox"] = [
            "left": 344, "top": 546, "right": 358, "bottom": 632
        ]
        shiftedTop["normalized_observed_bbox"] = [
            "left": 344, "top": 546, "right": 358, "bottom": 562
        ]
        shiftedTop["normalized_down_button_bbox"] = [
            "left": 344, "top": 632, "right": 358, "bottom": 646
        ]
        shiftedTop["top_stop_thumb_top_bounds"] = ["minimum": 546, "maximum": 546]
        shiftedTop["bottom_stop_thumb_top_bounds"] = ["minimum": 616, "maximum": 616]
        shiftedTop["normalized_click_point"] = ["x": 351, "y": 554]
        shiftedTop["source_track_bbox"] = [
            "left": 344, "top": 546, "right": 358, "bottom": 632
        ]
        shiftedTop["source_observed_bbox"] = [
            "left": 344, "top": 546, "right": 358, "bottom": 562
        ]
        shiftedTop["source_click_point"] = ["x": 351, "y": 554]
        let shiftedTopPassed = await broker.semanticScrollbarProofPassed(
            shiftedTop,
            anchor: "top"
        )
        XCTAssertTrue(shiftedTopPassed)

        var nearBottom = proof(anchor: "bottom")
        nearBottom["state"] = "intermediate"
        nearBottom["normalized_observed_bbox"] = [
            "left": 342, "top": 612, "right": 356, "bottom": 628
        ]
        nearBottom["source_observed_bbox"] = [
            "left": 342, "top": 612, "right": 356, "bottom": 628
        ]
        nearBottom["normalized_click_point"] = ["x": 349, "y": 620]
        nearBottom["source_click_point"] = ["x": 349, "y": 620]
        nearBottom["top_clearance_pixels"] = 69
        nearBottom["bottom_clearance_pixels"] = 1
        nearBottom["remaining_travel_to_top_pixels"] = 69
        nearBottom["remaining_travel_to_bottom_pixels"] = 1
        nearBottom["source_top_clearance_pixels"] = 69
        nearBottom["source_bottom_clearance_pixels"] = 1
        let nearBottomPassed = await broker.semanticScrollbarProofPassed(
            nearBottom,
            anchor: "bottom"
        )
        XCTAssertFalse(nearBottomPassed)
    }

    func testSemanticZoomMinusBudgetStopsAtEight() async throws {
        let hostRoot = temporaryDirectory().appendingPathComponent("semantic-budget-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: hostRoot, withIntermediateDirectories: true)
        var queue = try semanticQueueObject(hostEvidenceRoot: hostRoot)
        var items = queue["items"] as! [[String: Any]]
        items[0]["zoom_percent"] = 37.5
        queue["items"] = items
        let fixture = try writeQueue(queue)
        let store = QueueStore(
            acceptanceRoot: hostRoot.appendingPathComponent("broker"),
            hostEvidenceRoot: hostRoot
        )
        _ = try await store.activate(fileAt: fixture.url, expectedSHA256: fixture.sha256)
        let claimed = try await store.claim()
        let claim = try XCTUnwrap(claimed)

        for (role, point) in [
            (SemanticActionRole.surfaceSelectorOpen, AdapterPoint(x: 350, y: 665)),
            (.surfaceOptionSelect, AdapterPoint(x: 250, y: 542))
        ] {
            let capture = try semanticCapture(role.rawValue, root: hostRoot)
            _ = try await store.authorize(
                generationIdentifier: claim.generationIdentifier,
                itemIdentifier: claim.item.id,
                action: .click(captureIdentifier: capture.captureIdentifier, point: point, button: .left),
                semanticRole: role,
                capture: capture,
                requestedEventSourceMode: nil,
                requestedDeliveryMode: nil
            )
            try await store.recordActionCompleted(
                generationIdentifier: claim.generationIdentifier,
                itemIdentifier: claim.item.id
            )
        }
        for index in 1...8 {
            let capture = try semanticCapture("budget-minus-\(index)", root: hostRoot)
            _ = try await store.authorize(
                generationIdentifier: claim.generationIdentifier,
                itemIdentifier: claim.item.id,
                action: .click(captureIdentifier: capture.captureIdentifier, point: AdapterPoint(x: 420, y: 660), button: .left),
                semanticRole: .zoomMinus,
                capture: capture,
                requestedEventSourceMode: nil,
                requestedDeliveryMode: nil
            )
            try await store.recordActionCompleted(
                generationIdentifier: claim.generationIdentifier,
                itemIdentifier: claim.item.id
            )
        }
        let ninth = try semanticCapture("budget-minus-9", root: hostRoot)
        do {
            _ = try await store.authorize(
                generationIdentifier: claim.generationIdentifier,
                itemIdentifier: claim.item.id,
                action: .click(captureIdentifier: ninth.captureIdentifier, point: AdapterPoint(x: 420, y: 660), button: .left),
                semanticRole: .zoomMinus,
                capture: ninth,
                requestedEventSourceMode: nil,
                requestedDeliveryMode: nil
            )
            XCTFail("the semantic zoom-minus budget must stop at eight")
        } catch {
            XCTAssertTrue(String(describing: error).contains("SEMANTIC_ZOOM_MINUS_ACTION_INVALID"))
        }
    }

    func testSemanticBrokerAcceptsExactResultAndRejectsReusedFreshCapture() async throws {
        let acceptedRoot = temporaryDirectory().appendingPathComponent("semantic-broker-accepted-\(UUID().uuidString)")
        let accepted = try semanticBrokerFixture(root: acceptedRoot, reuseFreshCapture: false)
        let acceptedBroker = SandboxResultBroker(
            root: acceptedRoot.appendingPathComponent("broker"),
            hostEvidenceRoot: acceptedRoot
        )
        let acceptedReference = try await acceptedBroker.accept(
            generationIdentifier: "semantic-generation",
            item: accepted.item,
            artifactRoot: accepted.artifactRoot.path,
            resultPath: accepted.resultPath,
            resultFileSHA256: accepted.resultFileSHA256,
            resultDigest: accepted.resultDigest
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: acceptedReference.path))
        let replayReference = try await acceptedBroker.accept(
            generationIdentifier: "semantic-generation",
            item: accepted.item,
            artifactRoot: accepted.artifactRoot.path,
            resultPath: accepted.resultPath,
            resultFileSHA256: accepted.resultFileSHA256,
            resultDigest: accepted.resultDigest
        )
        XCTAssertEqual(replayReference, acceptedReference)
        let liveLoadCount = await acceptedBroker.fullStateLoadCountForTesting()
        XCTAssertEqual(liveLoadCount, 1)

        let restartedBroker = SandboxResultBroker(
            root: acceptedRoot.appendingPathComponent("broker"),
            hostEvidenceRoot: acceptedRoot
        )
        let restartedHashes = try await restartedBroker.acceptedItemHashes()
        XCTAssertEqual(restartedHashes[accepted.item.id], accepted.item.itemSHA256)
        let restartedLoadCount = await restartedBroker.fullStateLoadCountForTesting()
        XCTAssertEqual(restartedLoadCount, 1)

        let recoveredRoot = temporaryDirectory()
            .appendingPathComponent("semantic-broker-recovered-\(UUID().uuidString)")
        let recovered = try semanticBrokerFixture(
            root: recoveredRoot,
            reuseFreshCapture: false,
            includeRecovery: true
        )
        let recoveredReference = try await SandboxResultBroker(
            root: recoveredRoot.appendingPathComponent("broker"),
            hostEvidenceRoot: recoveredRoot
        ).accept(
            generationIdentifier: "semantic-generation",
            item: recovered.item,
            artifactRoot: recovered.artifactRoot.path,
            resultPath: recovered.resultPath,
            resultFileSHA256: recovered.resultFileSHA256,
            resultDigest: recovered.resultDigest
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: recoveredReference.path))

        let rejectedRoot = temporaryDirectory().appendingPathComponent("semantic-broker-rejected-\(UUID().uuidString)")
        let rejected = try semanticBrokerFixture(root: rejectedRoot, reuseFreshCapture: true)
        do {
            _ = try await SandboxResultBroker(
                root: rejectedRoot.appendingPathComponent("broker"),
                hostEvidenceRoot: rejectedRoot
            ).accept(
                generationIdentifier: "semantic-generation",
                item: rejected.item,
                artifactRoot: rejected.artifactRoot.path,
                resultPath: rejected.resultPath,
                resultFileSHA256: rejected.resultFileSHA256,
                resultDigest: rejected.resultDigest
            )
            XCTFail("a post frame reused as the fresh commit gate must fail closed")
        } catch {
            XCTAssertTrue(String(describing: error).contains("SEMANTIC_FRESH_CAPTURE_UNPROVEN"))
        }
    }

    func testSemanticBrokerAcceptsBoundSparseZoomProofAndRejectsThresholdMiss() async throws {
        func sparseProofTransition(_ transition: inout [String: Any], centerDisplacement: Double) {
            let before = transition["before_capture"] as! [String: Any]
            let after = transition["after_capture"] as! [String: Any]
            transition["mean_abs_difference"] = 0.56
            transition["evidence_mode"] = "sparse_map_scale_growth_v1"
            transition["sparse_scale_proof"] = [
                "passed": true,
                "evidence_mode": "sparse_map_scale_growth_v1",
                "before_capture_sha256": before["pngSHA256"]!,
                "after_capture_sha256": after["pngSHA256"]!,
                "before": [
                    "informative_pixel_count": 1_008,
                    "informative_fraction": 0.0071,
                    "chromatic_pixel_count": 902
                ],
                "after": [
                    "informative_pixel_count": 1_352,
                    "informative_fraction": 0.0095,
                    "chromatic_pixel_count": 1_243
                ],
                "growth": [
                    "informative_pixel_ratio": 1.34,
                    "chromatic_pixel_ratio": 1.37,
                    "width_ratio": 1.17,
                    "height_ratio": 1.17,
                    "center_displacement_pixels": centerDisplacement
                ],
                "thresholds": [
                    "minimum_informative_pixels": 64,
                    "minimum_chromatic_pixels": 8,
                    "maximum_informative_fraction": 0.2,
                    "minimum_linear_growth": 1.08,
                    "maximum_linear_growth": 2.5,
                    "minimum_support_growth": 1.15,
                    "maximum_center_displacement_pixels": 5
                ]
            ]
        }

        let acceptedRoot = temporaryDirectory()
            .appendingPathComponent("semantic-broker-sparse-zoom-accepted-\(UUID().uuidString)")
        let accepted = try semanticBrokerFixture(
            root: acceptedRoot,
            reuseFreshCapture: false,
            nativeRealm: (
                surface: "Sunset Ocean Underground",
                realmID: "cache-world-map:sunset-ocean-underground",
                selectorIndex: 2
            ),
            zoomTransitionMutation: { transitions in
                sparseProofTransition(&transitions[2], centerDisplacement: 1.93)
            }
        )
        _ = try await SandboxResultBroker(
            root: acceptedRoot.appendingPathComponent("broker"),
            hostEvidenceRoot: acceptedRoot
        ).accept(
            generationIdentifier: "semantic-generation",
            item: accepted.item,
            artifactRoot: accepted.artifactRoot.path,
            resultPath: accepted.resultPath,
            resultFileSHA256: accepted.resultFileSHA256,
            resultDigest: accepted.resultDigest
        )

        let rejectedRoot = temporaryDirectory()
            .appendingPathComponent("semantic-broker-sparse-zoom-rejected-\(UUID().uuidString)")
        let rejected = try semanticBrokerFixture(
            root: rejectedRoot,
            reuseFreshCapture: false,
            nativeRealm: (
                surface: "Sunset Ocean Underground",
                realmID: "cache-world-map:sunset-ocean-underground",
                selectorIndex: 2
            ),
            zoomTransitionMutation: { transitions in
                sparseProofTransition(&transitions[2], centerDisplacement: 5.01)
            }
        )
        do {
            _ = try await SandboxResultBroker(
                root: rejectedRoot.appendingPathComponent("broker"),
                hostEvidenceRoot: rejectedRoot
            ).accept(
                generationIdentifier: "semantic-generation",
                item: rejected.item,
                artifactRoot: rejected.artifactRoot.path,
                resultPath: rejected.resultPath,
                resultFileSHA256: rejected.resultFileSHA256,
                resultDigest: rejected.resultDigest
            )
            XCTFail("a sparse zoom proof beyond the fixed center bound must fail closed")
        } catch {
            XCTAssertTrue(String(describing: error).contains("SEMANTIC_ZOOM_ASCENT_UNPROVEN"))
        }
    }

    func testSemanticBrokerBindsNativeRealmProductionRequestedWork() async throws {
        let acceptedRoot = temporaryDirectory()
            .appendingPathComponent("semantic-broker-native-accepted-\(UUID().uuidString)")
        let accepted = try semanticBrokerFixture(
            root: acceptedRoot,
            reuseFreshCapture: false,
            nativeRealm: (
                surface: "Ardent Ocean Underground",
                realmID: "cache-world-map:ardent-ocean-underground",
                selectorIndex: 2
            )
        )
        let acceptedReference = try await SandboxResultBroker(
            root: acceptedRoot.appendingPathComponent("broker"),
            hostEvidenceRoot: acceptedRoot
        ).accept(
            generationIdentifier: "semantic-generation",
            item: accepted.item,
            artifactRoot: accepted.artifactRoot.path,
            resultPath: accepted.resultPath,
            resultFileSHA256: accepted.resultFileSHA256,
            resultDigest: accepted.resultDigest
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: acceptedReference.path))

        let visibleBoundaryRoot = temporaryDirectory()
            .appendingPathComponent("semantic-broker-native-visible-boundary-\(UUID().uuidString)")
        let visibleBoundary = try semanticBrokerFixture(
            root: visibleBoundaryRoot,
            reuseFreshCapture: false,
            nativeRealm: (
                surface: "Cam Torum",
                realmID: "cache-world-map:cam-torum",
                selectorIndex: 6
            )
        )
        let visibleBoundaryReference = try await SandboxResultBroker(
            root: visibleBoundaryRoot.appendingPathComponent("broker"),
            hostEvidenceRoot: visibleBoundaryRoot
        ).accept(
            generationIdentifier: "semantic-generation",
            item: visibleBoundary.item,
            artifactRoot: visibleBoundary.artifactRoot.path,
            resultPath: visibleBoundary.resultPath,
            resultFileSHA256: visibleBoundary.resultFileSHA256,
            resultDigest: visibleBoundary.resultDigest
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: visibleBoundaryReference.path))

        let rejectedRoot = temporaryDirectory()
            .appendingPathComponent("semantic-broker-native-rejected-\(UUID().uuidString)")
        let rejected = try semanticBrokerFixture(
            root: rejectedRoot,
            reuseFreshCapture: false,
            nativeRealm: (
                surface: "Ardent Ocean Underground",
                realmID: "cache-world-map:ardent-ocean-underground",
                selectorIndex: 2
            ),
            requestedRealmIDOverride: "other-map-123"
        )
        do {
            _ = try await SandboxResultBroker(
                root: rejectedRoot.appendingPathComponent("broker"),
                hostEvidenceRoot: rejectedRoot
            ).accept(
                generationIdentifier: "semantic-generation",
                item: rejected.item,
                artifactRoot: rejected.artifactRoot.path,
                resultPath: rejected.resultPath,
                resultFileSHA256: rejected.resultFileSHA256,
                resultDigest: rejected.resultDigest
            )
            XCTFail("production requested_work must be bound to the queue item realm id")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains("SEMANTIC_PRODUCTION_REQUEST_BINDING_INVALID")
            )
        }

        let wrongRowRoot = temporaryDirectory()
            .appendingPathComponent("semantic-broker-native-wrong-row-\(UUID().uuidString)")
        let wrongRow = try semanticBrokerFixture(
            root: wrongRowRoot,
            reuseFreshCapture: false,
            nativeRealm: (
                surface: "Ardent Ocean Underground",
                realmID: "cache-world-map:ardent-ocean-underground",
                selectorIndex: 2
            ),
            optionVisibleTopIndexOverride: 1
        )
        do {
            _ = try await SandboxResultBroker(
                root: wrongRowRoot.appendingPathComponent("broker"),
                hostEvidenceRoot: wrongRowRoot
            ).accept(
                generationIdentifier: "semantic-generation",
                item: wrongRow.item,
                artifactRoot: wrongRow.artifactRoot.path,
                resultPath: wrongRow.resultPath,
                resultFileSHA256: wrongRow.resultFileSHA256,
                resultDigest: wrongRow.resultDigest
            )
            XCTFail("production option rows must be bound to the measured thumb pixel")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains("SEMANTIC_PRODUCTION_OPTION_BINDING_INVALID")
            )
        }
    }

    func testSemanticBrokerRejectsNativeRealmWithoutExactCalibratedReadback() async throws {
        let root = temporaryDirectory()
            .appendingPathComponent("semantic-broker-native-readback-rejected-\(UUID().uuidString)")
        let fixture = try semanticBrokerFixture(
            root: root,
            reuseFreshCapture: false,
            nativeRealm: (
                surface: "God Wars Dungeon",
                realmID: "cache-world-map:godwars",
                selectorIndex: 12
            ),
            requestedWorkMutation: { _ in }
        )
        var result = try jsonObject(at: URL(fileURLWithPath: fixture.resultPath))
        for key in ["surface_proof", "zoom_proof", "pan_proof", "restoration_proof"] {
            guard var proof = result[key] as? [String: Any] else { continue }
            for gateKey in ["gate", "surface_gate", "target_gate", "fresh_gate"] {
                if var gate = proof[gateKey] as? [String: Any],
                   var readback = gate["surface_readback"] as? [String: Any] {
                    readback["surface"] = "Kebos Underground"
                    gate["surface_readback"] = readback
                    proof[gateKey] = gate
                }
            }
            result[key] = proof
        }
        let data = try CanonicalJSON.data(result)
        try replaceImmutableData(data, at: URL(fileURLWithPath: fixture.resultPath))
        do {
            _ = try await SandboxResultBroker(
                root: root.appendingPathComponent("broker"),
                hostEvidenceRoot: root
            ).accept(
                generationIdentifier: "semantic-generation",
                item: fixture.item,
                artifactRoot: fixture.artifactRoot.path,
                resultPath: fixture.resultPath,
                resultFileSHA256: AdapterHashing.sha256(data),
                resultDigest: try CanonicalJSON.sha256(result)
            )
            XCTFail("native realm gates must bind exact calibrated surface readback")
        } catch {
            XCTAssertTrue(String(describing: error).contains("QUEUE_REJECTED"))
        }
    }

    func testSemanticBrokerMapsSnappedScrollbarPixelsToExactProductionRows() async throws {
        let root = temporaryDirectory()
            .appendingPathComponent("semantic-broker-snapped-scrollbar-\(UUID().uuidString)")
        let broker = SandboxResultBroker(root: root, hostEvidenceRoot: root)

        XCTAssertEqual(
            broker.semanticProductionTargetThumbTopBounds(selectorIndex: 0),
            543...543
        )
        XCTAssertEqual(
            broker.semanticProductionTargetThumbTopBounds(selectorIndex: 5),
            545...546
        )
        XCTAssertEqual(
            broker.semanticProductionTargetThumbTopBounds(selectorIndex: 6),
            545...546
        )
        XCTAssertEqual(
            broker.semanticProductionTargetThumbTopBounds(selectorIndex: 7),
            547...548
        )
        XCTAssertEqual(
            broker.semanticProductionTargetThumbTopBounds(selectorIndex: 9),
            552...553
        )
        XCTAssertEqual(
            broker.semanticProductionTargetThumbTopBounds(selectorIndex: 41),
            608...609
        )
        XCTAssertEqual(
            broker.semanticProductionTargetThumbTopBounds(selectorIndex: 44),
            610...611
        )
        XCTAssertEqual(
            broker.semanticProductionTargetThumbTopBounds(selectorIndex: 46),
            613...613
        )
        XCTAssertNil(broker.semanticProductionTargetThumbTopBounds(selectorIndex: -1))
        XCTAssertTrue(
            broker.semanticProductionScrollbarMakesSelectorVisible(
                selectorIndex: 10,
                observedTop: 557
            )
        )
        XCTAssertTrue(
            broker.semanticProductionScrollbarMakesSelectorVisible(
                selectorIndex: 10,
                observedTop: 559
            )
        )
        XCTAssertFalse(
            broker.semanticProductionScrollbarMakesSelectorVisible(
                selectorIndex: 10,
                observedTop: 562
            )
        )
        XCTAssertFalse(
            broker.semanticProductionScrollbarMakesSelectorVisible(
                selectorIndex: 47,
                observedTop: 613
            )
        )
        XCTAssertEqual(
            broker.semanticProductionOptionTop(selectorIndex: 8, observedTop: 550),
            590
        )
        XCTAssertEqual(
            broker.semanticProductionOptionTop(selectorIndex: 13, observedTop: 558),
            598
        )
        XCTAssertNil(
            broker.semanticProductionOptionTop(selectorIndex: 47, observedTop: 558)
        )
        XCTAssertEqual(
            broker.semanticProductionOptionTop(selectorIndex: 38, observedTop: 603),
            597
        )
        let tolnaWindow = try XCTUnwrap(
            broker.semanticProductionCatalogWindowMatch(
                widths: [115, 128, 106, 48, 54, 75, 131, 111],
                heights: [11, 11, 12, 10, 8, 11, 11, 11]
            )
        )
        XCTAssertEqual(tolnaWindow.topIndex, 34)
        XCTAssertEqual(tolnaWindow.score, 0.9275, accuracy: 0.000_001)
        XCTAssertGreaterThanOrEqual(
            tolnaWindow.score - tolnaWindow.secondScore,
            0.08
        )
        let clippedTolnaWindow = try XCTUnwrap(
            broker.semanticProductionCatalogWindowMatch(
                widths: [128, 106, 48, 54, 75, 131, 111],
                heights: [11, 11, 10, 11, 11, 12, 11]
            )
        )
        XCTAssertEqual(clippedTolnaWindow.topIndex, 35)
        XCTAssertEqual(clippedTolnaWindow.score, 0.9225, accuracy: 0.000_001)
        XCTAssertGreaterThanOrEqual(
            clippedTolnaWindow.score - clippedTolnaWindow.secondScore,
            0.08
        )

        let delivered = broker.semanticProductionDeliveredScrollbarTarget(
            normalizedTarget: AdapterPoint(x: 349, y: 561),
            targetTop: 553,
            normalizedObservedTop: 543,
            sourceWidth: 1_614,
            sourceHeight: 1_722,
            sourceClickY: 1_131,
            sourceObservedTop: 1_114
        )
        XCTAssertEqual(delivered.x, 733)
        XCTAssertEqual(delivered.y, 1_156)
        XCTAssertEqual(
            broker.semanticProductionScrollbarTransferPixelCount(targetTop: 553),
            2
        )

        let camTorum = broker.semanticProductionDeliveredScrollbarTarget(
            normalizedTarget: AdapterPoint(x: 349, y: 556),
            targetTop: 548,
            normalizedObservedTop: 543,
            sourceWidth: 1_614,
            sourceHeight: 1_722,
            sourceClickY: 1_131,
            sourceObservedTop: 1_114
        )
        XCTAssertEqual(camTorum.x, 733)
        XCTAssertEqual(camTorum.y, 1_146)
        XCTAssertTrue(broker.semanticProductionScrollbarMovementAccepted(
            targetTop: 548,
            normalizedObservedTop: 543,
            deliveredFromY: 1_131,
            deliveredToY: camTorum.y
        ))
        XCTAssertLessThan(abs(camTorum.y - 1_131), 8 * 1_722.0 / 839.0)
        XCTAssertFalse(broker.semanticProductionScrollbarMovementAccepted(
            targetTop: 543,
            normalizedObservedTop: 543,
            deliveredFromY: 1_131,
            deliveredToY: 1_131
        ))
        XCTAssertFalse(broker.semanticProductionScrollbarMovementAccepted(
            targetTop: 548,
            normalizedObservedTop: 543,
            deliveredFromY: 1_131,
            deliveredToY: 1_131
        ))

        let dorgeshKaan = broker.semanticProductionDeliveredScrollbarTarget(
            normalizedTarget: AdapterPoint(x: 349, y: 562),
            targetTop: 554,
            normalizedObservedTop: 543,
            sourceWidth: 1_614,
            sourceHeight: 1_722,
            sourceClickY: 1_131,
            sourceObservedTop: 1_114
        )
        XCTAssertEqual(dorgeshKaan.x, 733)
        XCTAssertEqual(dorgeshKaan.y, 1_158)
        XCTAssertEqual(
            broker.semanticProductionScrollbarTransferPixelCount(targetTop: 554),
            2
        )

        let feldip = broker.semanticProductionDeliveredScrollbarTarget(
            normalizedTarget: AdapterPoint(x: 349, y: 566),
            targetTop: 558,
            normalizedObservedTop: 543,
            sourceWidth: 1_614,
            sourceHeight: 1_722,
            sourceClickY: 1_131,
            sourceObservedTop: 1_114
        )
        XCTAssertEqual(feldip.x, 733)
        XCTAssertEqual(feldip.y, 1_166)
        XCTAssertEqual(
            broker.semanticProductionScrollbarTransferPixelCount(targetTop: 558),
            2
        )
    }

    func testResetRelativeNativeCoverageBrokerBindsResetAndVectorProof() async throws {
        let acceptedRoot = temporaryDirectory()
            .appendingPathComponent("native-reset-relative-broker-accepted-\(UUID().uuidString)")
        let accepted = try resetRelativeCoverageBrokerFixture(root: acceptedRoot)
        _ = try await SandboxResultBroker(
            root: acceptedRoot.appendingPathComponent("broker"),
            hostEvidenceRoot: acceptedRoot
        ).accept(
            generationIdentifier: "native-v3-generation",
            item: accepted.item,
            artifactRoot: accepted.artifactRoot.path,
            resultPath: accepted.resultPath,
            resultFileSHA256: accepted.resultFileSHA256,
            resultDigest: accepted.resultDigest
        )

        let rejectedRoot = temporaryDirectory()
            .appendingPathComponent("native-reset-relative-broker-rejected-\(UUID().uuidString)")
        let rejected = try resetRelativeCoverageBrokerFixture(
            root: rejectedRoot,
            deliveredDXOverride: 1
        )
        do {
            _ = try await SandboxResultBroker(
                root: rejectedRoot.appendingPathComponent("broker"),
                hostEvidenceRoot: rejectedRoot
            ).accept(
                generationIdentifier: "native-v3-generation",
                item: rejected.item,
                artifactRoot: rejected.artifactRoot.path,
                resultPath: rejected.resultPath,
                resultFileSHA256: rejected.resultFileSHA256,
                resultDigest: rejected.resultDigest
            )
            XCTFail("reset-relative coverage must bind the delivered vector sum")
        } catch {
            XCTAssertTrue(String(describing: error).contains("NATIVE_REALM_COVERAGE_RESULT_INVALID"))
        }

        let cropRejectedRoot = temporaryDirectory()
            .appendingPathComponent("native-reset-relative-broker-crop-rejected-\(UUID().uuidString)")
        let cropRejected = try resetRelativeCoverageBrokerFixture(
            root: cropRejectedRoot,
            sourceCropLeftOverride: 177
        )
        do {
            _ = try await SandboxResultBroker(
                root: cropRejectedRoot.appendingPathComponent("broker"),
                hostEvidenceRoot: cropRejectedRoot
            ).accept(
                generationIdentifier: "native-v3-generation",
                item: cropRejected.item,
                artifactRoot: cropRejected.artifactRoot.path,
                resultPath: cropRejected.resultPath,
                resultFileSHA256: cropRejected.resultFileSHA256,
                resultDigest: cropRejected.resultDigest
            )
            XCTFail("native coverage must bind the unobscured crop origin")
        } catch {
            XCTAssertTrue(String(describing: error).contains("NATIVE_REALM_COVERAGE_STRUCTURE_INVALID"))
        }
    }

    func testReopenResetNativeCoverageBrokerBindsFreshNoMapTransition() async throws {
        let acceptedRoot = temporaryDirectory()
            .appendingPathComponent("native-reopen-reset-broker-accepted-\(UUID().uuidString)")
        let accepted = try resetRelativeCoverageBrokerFixture(
            root: acceptedRoot,
            plannerVersion: "native-realm-coverage-planner-v9"
        )
        _ = try await SandboxResultBroker(
            root: acceptedRoot.appendingPathComponent("broker"),
            hostEvidenceRoot: acceptedRoot
        ).accept(
            generationIdentifier: "native-v3-generation",
            item: accepted.item,
            artifactRoot: accepted.artifactRoot.path,
            resultPath: accepted.resultPath,
            resultFileSHA256: accepted.resultFileSHA256,
            resultDigest: accepted.resultDigest
        )

        let rejectedRoot = temporaryDirectory()
            .appendingPathComponent("native-reopen-reset-broker-rejected-\(UUID().uuidString)")
        let rejected = try resetRelativeCoverageBrokerFixture(
            root: rejectedRoot,
            plannerVersion: "native-realm-coverage-planner-v9",
            closedRecoveryStateOverride: "MAP_READY"
        )
        do {
            _ = try await SandboxResultBroker(
                root: rejectedRoot.appendingPathComponent("broker"),
                hostEvidenceRoot: rejectedRoot
            ).accept(
                generationIdentifier: "native-v3-generation",
                item: rejected.item,
                artifactRoot: rejected.artifactRoot.path,
                resultPath: rejected.resultPath,
                resultFileSHA256: rejected.resultFileSHA256,
                resultDigest: rejected.resultDigest
            )
            XCTFail("map reopen reset must prove the intervening no-map frame")
        } catch {
            XCTAssertTrue(String(describing: error).contains("NATIVE_REALM_COVERAGE_RESET_INVALID"))
        }
    }

    func testV10NativeCoverageBrokerRequiresInteriorMapContentProof() async throws {
        let acceptedRoot = temporaryDirectory()
            .appendingPathComponent("native-v10-content-accepted-\(UUID().uuidString)")
        let accepted = try resetRelativeCoverageBrokerFixture(
            root: acceptedRoot,
            plannerVersion: "native-realm-coverage-planner-v10"
        )
        _ = try await SandboxResultBroker(
            root: acceptedRoot.appendingPathComponent("broker"),
            hostEvidenceRoot: acceptedRoot
        ).accept(
            generationIdentifier: "native-v3-generation",
            item: accepted.item,
            artifactRoot: accepted.artifactRoot.path,
            resultPath: accepted.resultPath,
            resultFileSHA256: accepted.resultFileSHA256,
            resultDigest: accepted.resultDigest
        )

        let rejectedRoot = temporaryDirectory()
            .appendingPathComponent("native-v10-content-rejected-\(UUID().uuidString)")
        let rejected = try resetRelativeCoverageBrokerFixture(
            root: rejectedRoot,
            plannerVersion: "native-realm-coverage-planner-v10",
            targetContentInformativeOverride: 0
        )
        do {
            _ = try await SandboxResultBroker(
                root: rejectedRoot.appendingPathComponent("broker"),
                hostEvidenceRoot: rejectedRoot
            ).accept(
                generationIdentifier: "native-v3-generation",
                item: rejected.item,
                artifactRoot: rejected.artifactRoot.path,
                resultPath: rejected.resultPath,
                resultFileSHA256: rejected.resultFileSHA256,
                resultDigest: rejected.resultDigest
            )
            XCTFail("v10 native coverage must reject an empty target crop")
        } catch {
            XCTAssertTrue(String(describing: error).contains("NATIVE_REALM_COVERAGE_RESULT_INVALID"))
        }
    }

    func testV11NativeCoverageBrokerAcceptsStructuralGrayscaleContentProof() async throws {
        let root = temporaryDirectory()
            .appendingPathComponent("native-v11-grayscale-content-\(UUID().uuidString)")
        let fixture = try resetRelativeCoverageBrokerFixture(
            root: root,
            plannerVersion: "native-realm-coverage-planner-v11",
            targetContentChromaticOverride: 0,
            contentEvidenceMode: "native_crop_interior_content_v2"
        )
        _ = try await SandboxResultBroker(
            root: root.appendingPathComponent("broker"),
            hostEvidenceRoot: root
        ).accept(
            generationIdentifier: "native-v3-generation",
            item: fixture.item,
            artifactRoot: fixture.artifactRoot.path,
            resultPath: fixture.resultPath,
            resultFileSHA256: fixture.resultFileSHA256,
            resultDigest: fixture.resultDigest
        )
    }

    func testNativeCoverageBrokerMatchesJavaScriptNegativeHalfRounding() {
        XCTAssertEqual(SandboxResultBroker.javaScriptRoundedInteger(-731.5), -731)
        XCTAssertEqual(SandboxResultBroker.javaScriptRoundedInteger(-731.51), -732)
        XCTAssertEqual(SandboxResultBroker.javaScriptRoundedInteger(2_082.25), 2_082)
        XCTAssertEqual(SandboxResultBroker.javaScriptRoundedInteger(2_082.5), 2_083)
    }

    func testNativeCoverageBrokerAcceptsBoundedSafeAnchorTranslation() {
        let broker = SandboxResultBroker(root: temporaryDirectory())
        let firstVector: [String: Any] = [
            "reference_delta": ["dx": -235, "dy": -52],
            "anchor_translation": ["x": 0, "y": 2],
            "reference": [
                "from": ["x": 440, "y": 592],
                "to": ["x": 205, "y": 540]
            ]
        ]
        let secondVector: [String: Any] = [
            "reference_delta": ["dx": -236, "dy": -53],
            "anchor_translation": ["x": -8, "y": 2],
            "reference": [
                "from": ["x": 432, "y": 592],
                "to": ["x": 196, "y": 539]
            ]
        ]
        var outOfBounds = firstVector
        outOfBounds["anchor_translation"] = ["x": 0, "y": 38]
        var unbound = firstVector
        unbound["reference"] = [
            "from": ["x": 440, "y": 590],
            "to": ["x": 205, "y": 538]
        ]

        let firstAccepted = broker.semanticCoverageVector(firstVector, dx: -235, dy: -52)
        let secondAccepted = broker.semanticCoverageVector(secondVector, dx: -236, dy: -53)
        let outOfBoundsAccepted = broker.semanticCoverageVector(outOfBounds, dx: -235, dy: -52)
        let unboundAccepted = broker.semanticCoverageVector(unbound, dx: -235, dy: -52)

        XCTAssertTrue(firstAccepted)
        XCTAssertTrue(secondAccepted)
        XCTAssertFalse(outOfBoundsAccepted)
        XCTAssertFalse(unboundAccepted)

        let resetRelativeVector: [String: Any] = [
            "reference_delta": ["dx": -235, "dy": -52],
            "anchor_translation": ["x": 0, "y": 2],
            "reference": [
                "from": ["x": 476, "y": 505],
                "to": ["x": 241, "y": 453]
            ]
        ]
        XCTAssertTrue(
            broker.semanticResetRelativeCoverageVector(
                resetRelativeVector,
                dx: -235,
                dy: -52
            )
        )
        XCTAssertFalse(
            broker.semanticResetRelativeCoverageVector(firstVector, dx: -235, dy: -52)
        )

        let realmCrop = SemanticCoverageCrop(left: 4, top: 70, width: 512, height: 550)
        let realmAnchor: [String: Any] = [
            "reference_delta": ["dx": 240, "dy": -400],
            "anchor_translation": ["x": 0, "y": 0],
            "reference": [
                "from": ["x": 16, "y": 608],
                "to": ["x": 256, "y": 208]
            ]
        ]
        XCTAssertTrue(
            broker.semanticResetRelativeCoverageVector(
                realmAnchor,
                dx: 240,
                dy: -400,
                coverageCrop: realmCrop
            )
        )
        XCTAssertFalse(
            broker.semanticResetRelativeCoverageVector(
                realmAnchor,
                dx: 240,
                dy: -400
            )
        )

        let surfaceCrop = SemanticCoverageCrop(left: 178, top: 70, width: 338, height: 550)
        let surfaceAnchor: [String: Any] = [
            "reference_delta": ["dx": -240, "dy": 400],
            "anchor_translation": ["x": 0, "y": 0],
            "reference": [
                "from": ["x": 504, "y": 82],
                "to": ["x": 264, "y": 482]
            ]
        ]
        XCTAssertTrue(
            broker.semanticResetRelativeCoverageVector(
                surfaceAnchor,
                dx: -240,
                dy: 400,
                coverageCrop: surfaceCrop
            )
        )

        let movementProof: [String: Any] = [
            "mean_abs_difference": 4.2,
            "displacement_proof": [
                "passed": true,
                "evidence_mode": "native_crop_expected_neighborhood",
                "expected_reference_delta": ["dx": -235, "dy": -52],
                "delivered_reference_delta": ["dx": -234, "dy": -50],
                "tolerance_reference_pixels": 10,
                "mean_abs_difference": 4.2,
                "mean_abs_minimum": 2.5,
                "aligned_mean_abs": 3.0,
                "aligned_mean_abs_maximum": 25,
                "informative_coverage": 0.9,
                "informative_coverage_minimum": 0.5
            ]
        ]
        XCTAssertTrue(
            broker.semanticResetRelativeCoverageMovementProof(
                movementProof,
                expectedDX: -235,
                expectedDY: -52
            )
        )
        var sparseBoundary = movementProof
        var sparseBoundaryProof = sparseBoundary["displacement_proof"] as! [String: Any]
        sparseBoundaryProof["informative_coverage"] = 0.55
        sparseBoundary["displacement_proof"] = sparseBoundaryProof
        XCTAssertTrue(
            broker.semanticResetRelativeCoverageMovementProof(
                sparseBoundary,
                expectedDX: -235,
                expectedDY: -52
            )
        )
        sparseBoundaryProof["informative_coverage"] = 0.49
        sparseBoundary["displacement_proof"] = sparseBoundaryProof
        XCTAssertFalse(
            broker.semanticResetRelativeCoverageMovementProof(
                sparseBoundary,
                expectedDX: -235,
                expectedDY: -52
            )
        )
        let boundaryTurnover: [String: Any] = [
            "mean_abs_difference": 5.3,
            "displacement_proof": [
                "passed": true,
                "evidence_mode": "native_crop_boundary_turnover",
                "alignment_selection_mode": "directional_boundary_turnover",
                "expected_reference_delta": ["dx": -235, "dy": -52],
                "delivered_reference_delta": ["dx": -235, "dy": -52],
                "tolerance_reference_pixels": 10,
                "mean_abs_difference": 5.3,
                "mean_abs_minimum": 2.5,
                "source_changed_pixel_count": 534,
                "destination_changed_pixel_count": 1_721,
                "source_exit_fraction": 1.0,
                "destination_entry_fraction": 1.0,
                "aligned_shared_pixel_count": 0,
                "minimum_changed_pixel_count": 64,
                "minimum_turnover_fraction": 0.75,
                "maximum_shared_pixel_count": 63
            ]
        ]
        XCTAssertTrue(
            broker.semanticResetRelativeCoverageMovementProof(
                boundaryTurnover,
                expectedDX: -235,
                expectedDY: -52
            )
        )
        var sparseSourceExit = boundaryTurnover
        var sparseSourceExitProof = sparseSourceExit["displacement_proof"] as! [String: Any]
        sparseSourceExitProof["evidence_mode"] = "native_crop_source_boundary_exit"
        sparseSourceExitProof["alignment_selection_mode"] = "directional_source_boundary_exit"
        sparseSourceExitProof["destination_changed_pixel_count"] = 51
        sparseSourceExitProof["destination_informative_pixel_count"] = 242
        sparseSourceExitProof["source_exit_fraction"] = 0.998
        sparseSourceExitProof["aligned_shared_pixel_count"] = 11
        sparseSourceExitProof["minimum_sparse_changed_pixel_count"] = 16
        sparseSourceExitProof["minimum_destination_informative_pixel_count"] = 32
        sparseSourceExitProof["minimum_sparse_turnover_fraction"] = 0.5
        sparseSourceExit["displacement_proof"] = sparseSourceExitProof
        XCTAssertTrue(
            broker.semanticResetRelativeCoverageMovementProof(
                sparseSourceExit,
                expectedDX: -235,
                expectedDY: -52
            )
        )
        sparseSourceExitProof["destination_informative_pixel_count"] = 31
        sparseSourceExit["displacement_proof"] = sparseSourceExitProof
        XCTAssertFalse(
            broker.semanticResetRelativeCoverageMovementProof(
                sparseSourceExit,
                expectedDX: -235,
                expectedDY: -52
            )
        )
        var weakBoundary = boundaryTurnover
        var weakBoundaryProof = weakBoundary["displacement_proof"] as! [String: Any]
        weakBoundaryProof["destination_changed_pixel_count"] = 63
        weakBoundary["displacement_proof"] = weakBoundaryProof
        XCTAssertFalse(
            broker.semanticResetRelativeCoverageMovementProof(
                weakBoundary,
                expectedDX: -235,
                expectedDY: -52
            )
        )
        var noOp = movementProof
        noOp["mean_abs_difference"] = 0.5
        XCTAssertFalse(
            broker.semanticResetRelativeCoverageMovementProof(
                noOp,
                expectedDX: -235,
                expectedDY: -52
            )
        )
    }

    func testSemanticBrokerRejectsChangedNativeRealmCapturePositionBindings() async throws {
        let mutations: [(name: String, mutate: (inout [String: Any]) -> Void)] = [
            (
                name: "capture-center-x-mismatch",
                mutate: { requested in
                    var center = requested["capture_center"] as! [String: Any]
                    center["x"] = 1_234.5
                    requested["capture_center"] = center
                }
            ),
            (
                name: "capture-center-partial",
                mutate: { requested in
                    var center = requested["capture_center"] as! [String: Any]
                    center.removeValue(forKey: "y")
                    requested["capture_center"] = center
                }
            ),
            (
                name: "capture-center-boolean",
                mutate: { requested in
                    var center = requested["capture_center"] as! [String: Any]
                    center["x"] = true
                    requested["capture_center"] = center
                }
            ),
            (
                name: "coverage-cell-row-mismatch",
                mutate: { requested in
                    var cell = requested["coverage_cell"] as! [String: Any]
                    cell["row"] = 1
                    requested["coverage_cell"] = cell
                }
            ),
            (
                name: "coverage-cell-column-mismatch",
                mutate: { requested in
                    var cell = requested["coverage_cell"] as! [String: Any]
                    cell["column"] = 1
                    requested["coverage_cell"] = cell
                }
            ),
            (
                name: "coverage-cell-boolean",
                mutate: { requested in
                    var cell = requested["coverage_cell"] as! [String: Any]
                    cell["row"] = false
                    requested["coverage_cell"] = cell
                }
            ),
            (
                name: "capture-bounds-mismatch",
                mutate: { requested in
                    var cell = requested["coverage_cell"] as! [String: Any]
                    var bounds = cell["capture_bounds"] as! [String: Any]
                    bounds["max_x"] = 2_214.3
                    cell["capture_bounds"] = bounds
                    requested["coverage_cell"] = cell
                }
            ),
            (
                name: "coverage-cell-partial",
                mutate: { requested in
                    var cell = requested["coverage_cell"] as! [String: Any]
                    cell.removeValue(forKey: "capture_bounds")
                    requested["coverage_cell"] = cell
                }
            ),
            (
                name: "coverage-cell-malformed",
                mutate: { requested in
                    requested["coverage_cell"] = "not-an-object"
                }
            ),
        ]

        for mutation in mutations {
            let root = temporaryDirectory()
                .appendingPathComponent("semantic-broker-native-\(mutation.name)-\(UUID().uuidString)")
            let fixture = try semanticBrokerFixture(
                root: root,
                reuseFreshCapture: false,
                nativeRealm: (
                    surface: "Ardent Ocean Underground",
                    realmID: "cache-world-map:ardent-ocean-underground",
                    selectorIndex: 2
                ),
                requestedWorkMutation: mutation.mutate
            )
            do {
                _ = try await SandboxResultBroker(
                    root: root.appendingPathComponent("broker"),
                    hostEvidenceRoot: root
                ).accept(
                    generationIdentifier: "semantic-generation",
                    item: fixture.item,
                    artifactRoot: fixture.artifactRoot.path,
                    resultPath: fixture.resultPath,
                    resultFileSHA256: fixture.resultFileSHA256,
                    resultDigest: fixture.resultDigest
                )
                XCTFail("production requested_work accepted \(mutation.name)")
            } catch {
                XCTAssertTrue(
                    String(describing: error).contains(
                        "SEMANTIC_PRODUCTION_REQUEST_BINDING_INVALID"
                    ),
                    "unexpected error for \(mutation.name): \(error)"
                )
            }
        }
    }

    func testSemanticBrokerAcceptsBoundedPanAnchorTranslation() async throws {
        let root = temporaryDirectory().appendingPathComponent("semantic-broker-anchor-\(UUID().uuidString)")
        let fixture = try semanticBrokerFixture(
            root: root,
            reuseFreshCapture: false,
            panAnchorX: -10,
            panAnchorY: 8
        )
        let reference = try await SandboxResultBroker(
            root: root.appendingPathComponent("broker"),
            hostEvidenceRoot: root
        ).accept(
            generationIdentifier: "semantic-generation",
            item: fixture.item,
            artifactRoot: fixture.artifactRoot.path,
            resultPath: fixture.resultPath,
            resultFileSHA256: fixture.resultFileSHA256,
            resultDigest: fixture.resultDigest
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: reference.path))
    }

    func testSemanticBrokerAcceptsBoundedSparsePanAndRejectsFabricatedRetention() async throws {
        let acceptedRoot = temporaryDirectory()
            .appendingPathComponent("semantic-broker-sparse-accepted-\(UUID().uuidString)")
        let accepted = try semanticBrokerFixture(
            root: acceptedRoot,
            reuseFreshCapture: false,
            measuredForwardDX: -34,
            restorationDX: -34,
            panProfileFractionPercent: 50
        )
        _ = try await SandboxResultBroker(
            root: acceptedRoot.appendingPathComponent("broker"),
            hostEvidenceRoot: acceptedRoot
        ).accept(
            generationIdentifier: "semantic-generation",
            item: accepted.item,
            artifactRoot: accepted.artifactRoot.path,
            resultPath: accepted.resultPath,
            resultFileSHA256: accepted.resultFileSHA256,
            resultDigest: accepted.resultDigest
        )

        let midpointRoot = temporaryDirectory()
            .appendingPathComponent("semantic-broker-snap-midpoint-\(UUID().uuidString)")
        let midpoint = try semanticBrokerFixture(
            root: midpointRoot,
            reuseFreshCapture: false,
            measuredForwardDX: -66,
            restorationDX: -67,
            expectedForwardDX: -68,
            expectedForwardDY: 0
        )
        _ = try await SandboxResultBroker(
            root: midpointRoot.appendingPathComponent("broker"),
            hostEvidenceRoot: midpointRoot
        ).accept(
            generationIdentifier: "semantic-generation",
            item: midpoint.item,
            artifactRoot: midpoint.artifactRoot.path,
            resultPath: midpoint.resultPath,
            resultFileSHA256: midpoint.resultFileSHA256,
            resultDigest: midpoint.resultDigest
        )

        let rejectedRoot = temporaryDirectory()
            .appendingPathComponent("semantic-broker-sparse-rejected-\(UUID().uuidString)")
        let rejected = try semanticBrokerFixture(
            root: rejectedRoot,
            reuseFreshCapture: false,
            measuredForwardDX: -34,
            restorationDX: -34,
            panProfileFractionPercent: 50,
            retainedInformativePixels: 199
        )
        do {
            _ = try await SandboxResultBroker(
                root: rejectedRoot.appendingPathComponent("broker"),
                hostEvidenceRoot: rejectedRoot
            ).accept(
                generationIdentifier: "semantic-generation",
                item: rejected.item,
                artifactRoot: rejected.artifactRoot.path,
                resultPath: rejected.resultPath,
                resultFileSHA256: rejected.resultFileSHA256,
                resultDigest: rejected.resultDigest
            )
            XCTFail("sparse motion with fabricated sub-threshold retention must fail closed")
        } catch {
            XCTAssertTrue(String(describing: error).contains("SEMANTIC_PAN_PROOF_INVALID"))
        }
    }

    func testSemanticBrokerAcceptsNearProfileRestorationSnapAndRejectsDistantSnap() async throws {
        let acceptedRoot = temporaryDirectory()
            .appendingPathComponent("semantic-broker-snap-accepted-\(UUID().uuidString)")
        let accepted = try semanticBrokerFixture(
            root: acceptedRoot,
            reuseFreshCapture: false,
            measuredForwardDX: -67,
            restorationDX: -68
        )
        _ = try await SandboxResultBroker(
            root: acceptedRoot.appendingPathComponent("broker"),
            hostEvidenceRoot: acceptedRoot
        ).accept(
            generationIdentifier: "semantic-generation",
            item: accepted.item,
            artifactRoot: accepted.artifactRoot.path,
            resultPath: accepted.resultPath,
            resultFileSHA256: accepted.resultFileSHA256,
            resultDigest: accepted.resultDigest
        )

        let rejectedRoot = temporaryDirectory()
            .appendingPathComponent("semantic-broker-snap-rejected-\(UUID().uuidString)")
        let rejected = try semanticBrokerFixture(
            root: rejectedRoot,
            reuseFreshCapture: false,
            measuredForwardDX: -60,
            restorationDX: -68
        )
        do {
            _ = try await SandboxResultBroker(
                root: rejectedRoot.appendingPathComponent("broker"),
                hostEvidenceRoot: rejectedRoot
            ).accept(
                generationIdentifier: "semantic-generation",
                item: rejected.item,
                artifactRoot: rejected.artifactRoot.path,
                resultPath: rejected.resultPath,
                resultFileSHA256: rejected.resultFileSHA256,
                resultDigest: rejected.resultDigest
            )
            XCTFail("a restoration vector outside the fixed snap tolerance must fail closed")
        } catch {
            XCTAssertTrue(String(describing: error).contains("SEMANTIC_RESTORATION_UNPROVEN"))
        }
    }

    func testSemanticBrokerAcceptsRestorationSnapToDeliveredSparseProfile() async throws {
        let root = temporaryDirectory()
            .appendingPathComponent("semantic-broker-delivered-snap-\(UUID().uuidString)")
        let fixture = try semanticBrokerFixture(
            root: root,
            reuseFreshCapture: false,
            measuredForwardDX: -60,
            restorationDX: -61,
            panProfileFractionPercent: 90,
            expectedForwardDX: -61,
            expectedForwardDY: 0
        )
        _ = try await SandboxResultBroker(
            root: root.appendingPathComponent("broker"),
            hostEvidenceRoot: root
        ).accept(
            generationIdentifier: "semantic-generation",
            item: fixture.item,
            artifactRoot: fixture.artifactRoot.path,
            resultPath: fixture.resultPath,
            resultFileSHA256: fixture.resultFileSHA256,
            resultDigest: fixture.resultDigest
        )
    }

    func testQueueBindsExactActionAndEventSourceMode() async throws {
        let fixture = try makeQueueFixture()
        let store = QueueStore()
        _ = try await store.activate(fileAt: fixture.url, expectedSHA256: fixture.sha256)
        let claimed = try await store.claim()
        let claim = try XCTUnwrap(claimed)
        XCTAssertEqual(claim.item.id, "item-001")

        do {
            _ = try await store.authorize(
                generationIdentifier: "generation-001",
                itemIdentifier: "item-001",
                action: .click(
                    captureIdentifier: "capture-001",
                    point: AdapterPoint(x: 101, y: 100),
                    button: .left
                ),
                requestedEventSourceMode: .privateState,
                requestedDeliveryMode: .foregroundPid
            )
            XCTFail("mismatched coordinates must be rejected")
        } catch {
            XCTAssertTrue(String(describing: error).contains("ACTION_DOES_NOT_MATCH_QUEUE"))
        }

        let configuration = try await store.authorize(
            generationIdentifier: "generation-001",
            itemIdentifier: "item-001",
            action: .click(
                captureIdentifier: "capture-001",
                point: AdapterPoint(x: 100, y: 100),
                button: .left
            ),
            requestedEventSourceMode: .privateState,
            requestedDeliveryMode: .foregroundPid
        )
        XCTAssertEqual(configuration.eventSourceMode, .privateState)
        XCTAssertEqual(configuration.deliveryMode, .foregroundPid)
        try await store.recordActionCompleted(
            generationIdentifier: "generation-001",
            itemIdentifier: "item-001"
        )
        let result = try writeWorkerResult(for: claim)
        try await store.complete(
            generationIdentifier: "generation-001",
            itemIdentifier: "item-001",
            success: true,
            resultPath: result.path,
            resultFileSHA256: result.fileSHA256,
            resultDigest: result.resultDigest
        )
    }

    func testQueueRejectsCompletionWithUnconsumedAction() async throws {
        let fixture = try makeQueueFixture()
        let store = QueueStore()
        _ = try await store.activate(fileAt: fixture.url, expectedSHA256: fixture.sha256)
        _ = try await store.claim()
        do {
            try await store.complete(
                generationIdentifier: "generation-001",
                itemIdentifier: "item-001",
                success: true
            )
            XCTFail("an item cannot complete before its exact actions")
        } catch {
            XCTAssertTrue(String(describing: error).contains("ITEM_ACTIONS_NOT_COMPLETED"))
        }
    }

    func testQueueRejectsMismatchedDeliveryMode() async throws {
        let fixture = try makeQueueFixture()
        let store = QueueStore()
        _ = try await store.activate(fileAt: fixture.url, expectedSHA256: fixture.sha256)
        _ = try await store.claim()
        do {
            _ = try await store.authorize(
                generationIdentifier: "generation-001",
                itemIdentifier: "item-001",
                action: .click(
                    captureIdentifier: "capture-001",
                    point: AdapterPoint(x: 100, y: 100),
                    button: .left
                ),
                requestedEventSourceMode: .privateState,
                requestedDeliveryMode: .foregroundGlobal
            )
            XCTFail("mismatched delivery mode must be rejected")
        } catch {
            XCTAssertTrue(String(describing: error).contains("DELIVERY_MODE_DOES_NOT_MATCH_QUEUE"))
        }
    }

    func testFocusInvariantDetectsCursorChange() {
        let before = FocusInvariantSnapshot(
            capturedAt: "before",
            frontmostProcessIdentifier: 1,
            focusedProcessIdentifier: 1,
            cursor: AdapterPoint(x: 10, y: 20),
            orderedWindowIdentifiers: [1, 2],
            targetWindowRank: 1,
            activeSpaceChangeCount: 0
        )
        let after = FocusInvariantSnapshot(
            capturedAt: "after",
            frontmostProcessIdentifier: 1,
            focusedProcessIdentifier: 1,
            cursor: AdapterPoint(x: 11, y: 20),
            orderedWindowIdentifiers: [1, 2],
            targetWindowRank: 1,
            activeSpaceChangeCount: 0
        )
        let result = FocusInvariantMonitor().evaluate(before: before, after: after)
        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.violations, ["PHYSICAL_CURSOR_CHANGED"])
    }

    func testForegroundRestorationRejectsTargetRankChange() {
        let before = FocusInvariantSnapshot(
            capturedAt: "before",
            frontmostProcessIdentifier: 1,
            focusedProcessIdentifier: 1,
            cursor: AdapterPoint(x: 10, y: 20),
            orderedWindowIdentifiers: [1, 2, 3],
            targetWindowRank: 2,
            activeSpaceChangeCount: 0
        )
        let after = FocusInvariantSnapshot(
            capturedAt: "after",
            frontmostProcessIdentifier: 1,
            focusedProcessIdentifier: 1,
            cursor: AdapterPoint(x: 10, y: 20),
            orderedWindowIdentifiers: [1, 3, 2],
            targetWindowRank: 1,
            activeSpaceChangeCount: 0
        )
        let result = FocusInvariantMonitor().evaluateForegroundRestoration(
            before: before,
            after: after
        )
        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.violations, ["TARGET_WINDOW_RANK_NOT_RESTORED"])
    }

    func testForegroundRestorationAllowsSubpixelCursorWarpQuantization() {
        let before = FocusInvariantSnapshot(
            capturedAt: "before",
            frontmostProcessIdentifier: 1,
            focusedProcessIdentifier: 1,
            cursor: AdapterPoint(x: 767.194_702_148_437_5, y: 619.563_232_421_875),
            orderedWindowIdentifiers: [1, 2],
            targetWindowRank: 1,
            activeSpaceChangeCount: 0
        )
        let after = FocusInvariantSnapshot(
            capturedAt: "after",
            frontmostProcessIdentifier: 1,
            focusedProcessIdentifier: 1,
            cursor: AdapterPoint(x: 767, y: 619),
            orderedWindowIdentifiers: [1, 2],
            targetWindowRank: 1,
            activeSpaceChangeCount: 0
        )

        let result = FocusInvariantMonitor().evaluateForegroundRestoration(
            before: before,
            after: after
        )

        XCTAssertTrue(result.passed)
        XCTAssertTrue(result.violations.isEmpty)
    }

    func testForegroundRestorationContinuesPastIntermediateWindowOwnerTimeout() {
        let snapshot = FocusInvariantSnapshot(
            capturedAt: "restored",
            frontmostProcessIdentifier: 11,
            focusedProcessIdentifier: 11,
            cursor: AdapterPoint(x: 10, y: 20),
            orderedWindowIdentifiers: [1, 2, 3, 4],
            orderedWindowProcessIdentifiers: [11, 22, 33, 44],
            orderedRestorableWindowIdentifiers: [1, 2, 3, 4],
            orderedRestorableWindowProcessIdentifiers: [11, 22, 33, 44],
            targetWindowRank: 3,
            targetRestorableWindowRank: 3,
            activeSpaceChangeCount: 0
        )
        let intermediateTimeout = ForegroundRestorationStep(
            processIdentifier: 22,
            activationSucceeded: true,
            becameFrontmost: true,
            windowOwnerBecameLeading: false,
            failure: "RESTORATION_WINDOW_ORDER_TIMEOUT:22"
        )
        let restored = FocusInvariantResult(
            passed: true,
            violations: [],
            before: snapshot,
            after: snapshot
        )

        XCTAssertNil(ForegroundLeaseService.finalRestorationFailure(
            existingFailure: nil,
            restorationSteps: [intermediateTimeout],
            restoration: restored
        ))
    }

    func testForegroundRestorationReportsIntermediateTimeoutWhenFinalInvariantFails() {
        let before = FocusInvariantSnapshot(
            capturedAt: "before",
            frontmostProcessIdentifier: 11,
            focusedProcessIdentifier: 11,
            cursor: AdapterPoint(x: 10, y: 20),
            orderedWindowIdentifiers: [1, 2, 3, 4],
            orderedWindowProcessIdentifiers: [11, 22, 33, 44],
            orderedRestorableWindowIdentifiers: [1, 2, 3, 4],
            orderedRestorableWindowProcessIdentifiers: [11, 22, 33, 44],
            targetWindowRank: 3,
            targetRestorableWindowRank: 3,
            activeSpaceChangeCount: 0
        )
        let after = FocusInvariantSnapshot(
            capturedAt: "after",
            frontmostProcessIdentifier: 22,
            focusedProcessIdentifier: 22,
            cursor: AdapterPoint(x: 10, y: 20),
            orderedWindowIdentifiers: [2, 1, 3, 4],
            orderedWindowProcessIdentifiers: [22, 11, 33, 44],
            orderedRestorableWindowIdentifiers: [2, 1, 3, 4],
            orderedRestorableWindowProcessIdentifiers: [22, 11, 33, 44],
            targetWindowRank: 3,
            targetRestorableWindowRank: 3,
            activeSpaceChangeCount: 0
        )
        let intermediateTimeout = ForegroundRestorationStep(
            processIdentifier: 22,
            activationSucceeded: true,
            becameFrontmost: true,
            windowOwnerBecameLeading: false,
            failure: "RESTORATION_WINDOW_ORDER_TIMEOUT:22"
        )
        let failed = FocusInvariantResult(
            passed: false,
            violations: ["PRIOR_FRONTMOST_PROCESS_NOT_RESTORED"],
            before: before,
            after: after
        )

        XCTAssertEqual(
            ForegroundLeaseService.finalRestorationFailure(
                existingFailure: nil,
                restorationSteps: [intermediateTimeout],
                restoration: failed
            ),
            "RESTORATION_WINDOW_ORDER_TIMEOUT:22;PRIOR_FRONTMOST_PROCESS_NOT_RESTORED"
        )
    }

    func testForegroundRestorationPlanDeduplicatesOwnersInFrontToBackOrder() {
        let snapshot = FocusInvariantSnapshot(
            capturedAt: "before",
            frontmostProcessIdentifier: 11,
            focusedProcessIdentifier: 11,
            cursor: AdapterPoint(x: 10, y: 20),
            orderedWindowIdentifiers: [1, 2, 3, 4, 5],
            orderedWindowProcessIdentifiers: [11, 11, 22, 44, 55],
            orderedRestorableWindowIdentifiers: [1, 2, 3, 4, 5],
            orderedRestorableWindowProcessIdentifiers: [11, 11, 22, 44, 55],
            targetWindowRank: 3,
            targetRestorableWindowRank: 3,
            activeSpaceChangeCount: 0
        )

        XCTAssertEqual(
            snapshot.uniqueRestorableProcessIdentifiersAboveTarget(excluding: [44]),
            [11, 22]
        )
    }

    func testForegroundRestorationPlanFailsClosedWithoutOwnerCoverage() {
        let snapshot = FocusInvariantSnapshot(
            capturedAt: "before",
            frontmostProcessIdentifier: 11,
            focusedProcessIdentifier: 11,
            cursor: AdapterPoint(x: 10, y: 20),
            orderedWindowIdentifiers: [1, 2, 3],
            orderedWindowProcessIdentifiers: [11],
            targetWindowRank: 2,
            activeSpaceChangeCount: 0
        )

        XCTAssertTrue(snapshot.uniqueRestorableProcessIdentifiersAboveTarget(excluding: []).isEmpty)
    }

    func testForegroundRestorationIgnoresTransientAccessoryWindowRank() {
        let before = FocusInvariantSnapshot(
            capturedAt: "before",
            frontmostProcessIdentifier: 11,
            focusedProcessIdentifier: 11,
            cursor: AdapterPoint(x: 10, y: 20),
            orderedWindowIdentifiers: [90, 1, 2],
            orderedWindowProcessIdentifiers: [99, 11, 44],
            orderedRestorableWindowIdentifiers: [1, 2],
            orderedRestorableWindowProcessIdentifiers: [11, 44],
            targetWindowRank: 2,
            targetRestorableWindowRank: 1,
            activeSpaceChangeCount: 0
        )
        let after = FocusInvariantSnapshot(
            capturedAt: "after",
            frontmostProcessIdentifier: 11,
            focusedProcessIdentifier: 11,
            cursor: AdapterPoint(x: 10, y: 20),
            orderedWindowIdentifiers: [1, 2],
            orderedWindowProcessIdentifiers: [11, 44],
            orderedRestorableWindowIdentifiers: [1, 2],
            orderedRestorableWindowProcessIdentifiers: [11, 44],
            targetWindowRank: 1,
            targetRestorableWindowRank: 1,
            activeSpaceChangeCount: 0
        )

        XCTAssertTrue(FocusInvariantMonitor().evaluateForegroundRestoration(
            before: before,
            after: after
        ).passed)
    }

    func testForegroundRestorationAllowsUnrelatedRegularWindowToDisappear() {
        let before = FocusInvariantSnapshot(
            capturedAt: "before",
            frontmostProcessIdentifier: 11,
            focusedProcessIdentifier: 11,
            cursor: AdapterPoint(x: 10, y: 20),
            orderedWindowIdentifiers: [1, 2, 3, 4],
            orderedWindowProcessIdentifiers: [11, 22, 33, 44],
            orderedRestorableWindowIdentifiers: [1, 2, 3, 4],
            orderedRestorableWindowProcessIdentifiers: [11, 22, 33, 44],
            targetWindowRank: 3,
            targetRestorableWindowRank: 3,
            activeSpaceChangeCount: 0
        )
        let after = FocusInvariantSnapshot(
            capturedAt: "after",
            frontmostProcessIdentifier: 11,
            focusedProcessIdentifier: 11,
            cursor: AdapterPoint(x: 10, y: 20),
            orderedWindowIdentifiers: [1, 2, 4],
            orderedWindowProcessIdentifiers: [11, 22, 44],
            orderedRestorableWindowIdentifiers: [1, 2, 4],
            orderedRestorableWindowProcessIdentifiers: [11, 22, 44],
            targetWindowRank: 2,
            targetRestorableWindowRank: 2,
            activeSpaceChangeCount: 0
        )

        XCTAssertTrue(FocusInvariantMonitor().evaluateForegroundRestoration(
            before: before,
            after: after
        ).passed)
    }

    func testForegroundRestorationAllowsExistingOwnerWindowsToRegroupAboveTarget() {
        let before = FocusInvariantSnapshot(
            capturedAt: "before",
            frontmostProcessIdentifier: 11,
            focusedProcessIdentifier: 11,
            cursor: AdapterPoint(x: 10, y: 20),
            orderedWindowIdentifiers: [1, 2, 3, 4, 5, 6],
            orderedWindowProcessIdentifiers: [11, 22, 44, 44, 22, 55],
            orderedRestorableWindowIdentifiers: [1, 2, 3, 4, 5, 6],
            orderedRestorableWindowProcessIdentifiers: [11, 22, 44, 44, 22, 55],
            targetWindowRank: 3,
            targetRestorableWindowRank: 3,
            activeSpaceChangeCount: 0
        )
        let after = FocusInvariantSnapshot(
            capturedAt: "after",
            frontmostProcessIdentifier: 11,
            focusedProcessIdentifier: 11,
            cursor: AdapterPoint(x: 10, y: 20),
            orderedWindowIdentifiers: [1, 2, 5, 3, 4, 6],
            orderedWindowProcessIdentifiers: [11, 22, 22, 44, 44, 55],
            orderedRestorableWindowIdentifiers: [1, 2, 5, 3, 4, 6],
            orderedRestorableWindowProcessIdentifiers: [11, 22, 22, 44, 44, 55],
            targetWindowRank: 4,
            targetRestorableWindowRank: 4,
            activeSpaceChangeCount: 0
        )

        XCTAssertTrue(FocusInvariantMonitor().evaluateForegroundRestoration(
            before: before,
            after: after
        ).passed)
    }

    func testForegroundRestorationAllowsLeasedTargetToSettleHigherBehindFrontmostApp() {
        let before = FocusInvariantSnapshot(
            capturedAt: "before",
            frontmostProcessIdentifier: 11,
            focusedProcessIdentifier: 11,
            cursor: AdapterPoint(x: 10, y: 20),
            orderedWindowIdentifiers: [1, 2, 3, 4, 5, 6],
            orderedWindowProcessIdentifiers: [11, 22, 33, 44, 55, 66],
            orderedRestorableWindowIdentifiers: [1, 2, 3, 4, 5, 6],
            orderedRestorableWindowProcessIdentifiers: [11, 22, 33, 44, 55, 66],
            targetWindowRank: 3,
            targetRestorableWindowRank: 3,
            activeSpaceChangeCount: 0
        )
        let after = FocusInvariantSnapshot(
            capturedAt: "after",
            frontmostProcessIdentifier: 11,
            focusedProcessIdentifier: 11,
            cursor: AdapterPoint(x: 10, y: 20),
            orderedWindowIdentifiers: [1, 4, 2, 3, 5, 6],
            orderedWindowProcessIdentifiers: [11, 44, 22, 33, 55, 66],
            orderedRestorableWindowIdentifiers: [1, 4, 2, 3, 5, 6],
            orderedRestorableWindowProcessIdentifiers: [11, 44, 22, 33, 55, 66],
            targetWindowRank: 1,
            targetRestorableWindowRank: 1,
            activeSpaceChangeCount: 0
        )

        XCTAssertTrue(FocusInvariantMonitor().evaluateForegroundRestoration(
            before: before,
            after: after
        ).passed)
    }

    func testForegroundRestorationAllowsSplitSystemFocusToConsolidateOnFrontmostOwner() {
        let before = FocusInvariantSnapshot(
            capturedAt: "before",
            frontmostProcessIdentifier: 11,
            focusedProcessIdentifier: 22,
            cursor: AdapterPoint(x: 10, y: 20),
            orderedWindowIdentifiers: [1, 2],
            orderedWindowProcessIdentifiers: [33, 44],
            orderedRestorableWindowIdentifiers: [1, 2],
            orderedRestorableWindowProcessIdentifiers: [33, 44],
            targetWindowRank: 0,
            targetRestorableWindowRank: 0,
            activeSpaceChangeCount: 0
        )
        let after = FocusInvariantSnapshot(
            capturedAt: "after",
            frontmostProcessIdentifier: 11,
            focusedProcessIdentifier: 11,
            cursor: AdapterPoint(x: 10, y: 20),
            orderedWindowIdentifiers: [1, 2],
            orderedWindowProcessIdentifiers: [33, 44],
            orderedRestorableWindowIdentifiers: [1, 2],
            orderedRestorableWindowProcessIdentifiers: [33, 44],
            targetWindowRank: 0,
            targetRestorableWindowRank: 0,
            activeSpaceChangeCount: 0
        )

        XCTAssertTrue(FocusInvariantMonitor().evaluateForegroundRestoration(
            before: before,
            after: after
        ).passed)
    }

    func testForegroundRestorationRejectsThirdPartyFocusAfterSplitSystemFocus() {
        let before = FocusInvariantSnapshot(
            capturedAt: "before",
            frontmostProcessIdentifier: 11,
            focusedProcessIdentifier: 22,
            cursor: AdapterPoint(x: 10, y: 20),
            orderedWindowIdentifiers: [1, 2],
            orderedWindowProcessIdentifiers: [33, 44],
            orderedRestorableWindowIdentifiers: [1, 2],
            orderedRestorableWindowProcessIdentifiers: [33, 44],
            targetWindowRank: 0,
            targetRestorableWindowRank: 0,
            activeSpaceChangeCount: 0
        )
        let after = FocusInvariantSnapshot(
            capturedAt: "after",
            frontmostProcessIdentifier: 11,
            focusedProcessIdentifier: 55,
            cursor: AdapterPoint(x: 10, y: 20),
            orderedWindowIdentifiers: [1, 2],
            orderedWindowProcessIdentifiers: [33, 44],
            orderedRestorableWindowIdentifiers: [1, 2],
            orderedRestorableWindowProcessIdentifiers: [33, 44],
            targetWindowRank: 0,
            targetRestorableWindowRank: 0,
            activeSpaceChangeCount: 0
        )

        XCTAssertEqual(
            FocusInvariantMonitor().evaluateForegroundRestoration(
                before: before,
                after: after
            ).violations,
            ["PRIOR_FOCUSED_PROCESS_NOT_RESTORED"]
        )
    }

    func testForegroundRestorationUsesFirstSurvivingOwnerWhenFrontmostAppTerminates() {
        let before = FocusInvariantSnapshot(
            capturedAt: "before",
            frontmostProcessIdentifier: 11,
            focusedProcessIdentifier: nil,
            cursor: AdapterPoint(x: 10, y: 20),
            orderedWindowIdentifiers: [1, 2, 3, 4],
            orderedWindowProcessIdentifiers: [11, 22, 33, 44],
            orderedRestorableWindowIdentifiers: [1, 2, 3, 4],
            orderedRestorableWindowProcessIdentifiers: [11, 22, 33, 44],
            targetWindowRank: 3,
            targetRestorableWindowRank: 3,
            activeSpaceChangeCount: 0
        )
        let after = FocusInvariantSnapshot(
            capturedAt: "after",
            frontmostProcessIdentifier: 22,
            focusedProcessIdentifier: 22,
            cursor: AdapterPoint(x: 10, y: 20),
            orderedWindowIdentifiers: [2, 3, 4],
            orderedWindowProcessIdentifiers: [22, 33, 44],
            orderedRestorableWindowIdentifiers: [2, 3, 4],
            orderedRestorableWindowProcessIdentifiers: [22, 33, 44],
            targetWindowRank: 2,
            targetRestorableWindowRank: 2,
            activeSpaceChangeCount: 0
        )

        XCTAssertTrue(FocusInvariantMonitor().evaluateForegroundRestoration(
            before: before,
            after: after
        ).passed)
    }

    func testForegroundRestorationRejectsSkippingFirstSurvivingOwner() {
        let before = FocusInvariantSnapshot(
            capturedAt: "before",
            frontmostProcessIdentifier: 11,
            focusedProcessIdentifier: nil,
            cursor: AdapterPoint(x: 10, y: 20),
            orderedWindowIdentifiers: [1, 2, 3, 4],
            orderedWindowProcessIdentifiers: [11, 22, 33, 44],
            orderedRestorableWindowIdentifiers: [1, 2, 3, 4],
            orderedRestorableWindowProcessIdentifiers: [11, 22, 33, 44],
            targetWindowRank: 3,
            targetRestorableWindowRank: 3,
            activeSpaceChangeCount: 0
        )
        let after = FocusInvariantSnapshot(
            capturedAt: "after",
            frontmostProcessIdentifier: 33,
            focusedProcessIdentifier: 33,
            cursor: AdapterPoint(x: 10, y: 20),
            orderedWindowIdentifiers: [3, 2, 4],
            orderedWindowProcessIdentifiers: [33, 22, 44],
            orderedRestorableWindowIdentifiers: [3, 2, 4],
            orderedRestorableWindowProcessIdentifiers: [33, 22, 44],
            targetWindowRank: 2,
            targetRestorableWindowRank: 2,
            activeSpaceChangeCount: 0
        )

        let result = FocusInvariantMonitor().evaluateForegroundRestoration(
            before: before,
            after: after
        )
        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.violations.contains("PRIOR_FRONTMOST_PROCESS_NOT_RESTORED"))
    }

    func testForegroundRestorationAllowsTargetSupportWindowReplacement() {
        let before = FocusInvariantSnapshot(
            capturedAt: "before",
            frontmostProcessIdentifier: 11,
            focusedProcessIdentifier: 11,
            cursor: AdapterPoint(x: 10, y: 20),
            orderedWindowIdentifiers: [1, 2, 3, 4],
            orderedWindowProcessIdentifiers: [11, 44, 44, 55],
            orderedRestorableWindowIdentifiers: [1, 2, 3, 4],
            orderedRestorableWindowProcessIdentifiers: [11, 44, 44, 55],
            targetWindowRank: 2,
            targetRestorableWindowRank: 2,
            activeSpaceChangeCount: 0
        )
        let after = FocusInvariantSnapshot(
            capturedAt: "after",
            frontmostProcessIdentifier: 11,
            focusedProcessIdentifier: 11,
            cursor: AdapterPoint(x: 10, y: 20),
            orderedWindowIdentifiers: [1, 9, 3, 4],
            orderedWindowProcessIdentifiers: [11, 44, 44, 55],
            orderedRestorableWindowIdentifiers: [1, 9, 3, 4],
            orderedRestorableWindowProcessIdentifiers: [11, 44, 44, 55],
            targetWindowRank: 2,
            targetRestorableWindowRank: 2,
            activeSpaceChangeCount: 0
        )

        XCTAssertTrue(FocusInvariantMonitor().evaluateForegroundRestoration(
            before: before,
            after: after
        ).passed)
    }

    func testForegroundRestorationRejectsNewRegularWindowInsertion() {
        let before = FocusInvariantSnapshot(
            capturedAt: "before",
            frontmostProcessIdentifier: 11,
            focusedProcessIdentifier: 11,
            cursor: AdapterPoint(x: 10, y: 20),
            orderedWindowIdentifiers: [1, 4],
            orderedWindowProcessIdentifiers: [11, 44],
            orderedRestorableWindowIdentifiers: [1, 4],
            orderedRestorableWindowProcessIdentifiers: [11, 44],
            targetWindowRank: 1,
            targetRestorableWindowRank: 1,
            activeSpaceChangeCount: 0
        )
        let after = FocusInvariantSnapshot(
            capturedAt: "after",
            frontmostProcessIdentifier: 11,
            focusedProcessIdentifier: 11,
            cursor: AdapterPoint(x: 10, y: 20),
            orderedWindowIdentifiers: [1, 2, 4],
            orderedWindowProcessIdentifiers: [11, 22, 44],
            orderedRestorableWindowIdentifiers: [1, 2, 4],
            orderedRestorableWindowProcessIdentifiers: [11, 22, 44],
            targetWindowRank: 2,
            targetRestorableWindowRank: 2,
            activeSpaceChangeCount: 0
        )

        let result = FocusInvariantMonitor().evaluateForegroundRestoration(
            before: before,
            after: after
        )
        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.violations, ["TARGET_WINDOW_RANK_NOT_RESTORED"])
    }

    func testQueueRejectsKeyboardOperation() throws {
        var fixture = try queueObject()
        fixture["allowed_operations"] = ["capture", "keyboard"]
        let written = try writeQueue(fixture)
        XCTAssertThrowsError(try QueueManifestValidator.validate(
            fileAt: written.url,
            expectedSHA256: written.sha256,
            hostEvidenceRoot: temporaryDirectory()
        ))
    }

    func testQueueAcceptsOnlyHostOwnedWorldMapControlShape() async throws {
        let hostRoot = temporaryDirectory().appendingPathComponent("world-map-shortcut-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: hostRoot, withIntermediateDirectories: true)
        var item: [String: Any] = [
            "id": "open-map-001",
            "kind": "osrs-recovery-v1-GAMEPLAY_NO_MAP",
            "operations": [
                ["kind": "capture"],
                [
                    "kind": "open_world_map",
                    "event_source_mode": "combined_session_state",
                    "delivery_mode": "foreground_global"
                ]
            ]
        ]
        item["item_sha256"] = try CanonicalJSON.sha256(item)
        var queue: [String: Any] = [
            "schema_version": 1,
            "generation_id": "world-map-shortcut-generation",
            "target_bundle_id": osrsTargetBundleIdentifier,
            "allowed_operations": ["capture", "open_world_map"],
            "artifact_root": hostRoot.appendingPathComponent("artifacts").path,
            "items": [item]
        ]
        queue["policy_digest"] = try CanonicalJSON.sha256(queue)
        let fixture = try writeQueue(queue, finalize: false)
        let validated = try QueueManifestValidator.validate(
            fileAt: fixture.url,
            expectedSHA256: fixture.sha256,
            hostEvidenceRoot: hostRoot
        )
        XCTAssertEqual(validated.manifest.items[0].operations[1].kind, .openWorldMap)
        let store = QueueStore(
            acceptanceRoot: hostRoot.appendingPathComponent("broker"),
            hostEvidenceRoot: hostRoot
        )
        _ = try await store.activate(fileAt: fixture.url, expectedSHA256: fixture.sha256)
        let claimed = try await store.claim()
        let claim = try XCTUnwrap(claimed)
        let capture = try semanticCapture("open-world-map", root: hostRoot)
        let configuration = try await store.authorize(
            generationIdentifier: claim.generationIdentifier,
            itemIdentifier: claim.item.id,
            action: .openWorldMap(captureIdentifier: capture.captureIdentifier),
            capture: capture,
            requestedEventSourceMode: .combinedSessionState,
            requestedDeliveryMode: .foregroundGlobal
        )
        XCTAssertEqual(configuration.eventSourceMode, .combinedSessionState)
        XCTAssertEqual(configuration.deliveryMode, .foregroundGlobal)
        try await store.recordActionCompleted(
            generationIdentifier: claim.generationIdentifier,
            itemIdentifier: claim.item.id
        )

        for injected in [
            ["key_code": 4],
            ["modifiers": ["control"]]
        ] as [[String: Any]] {
            var changed = queue
            var items = changed["items"] as! [[String: Any]]
            var operations = items[0]["operations"] as! [[String: Any]]
            injected.forEach { operations[1][$0.key] = $0.value }
            items[0]["operations"] = operations
            changed["items"] = items
            let rejected = try writeQueue(changed)
            XCTAssertThrowsError(try QueueManifestValidator.validate(
                fileAt: rejected.url,
                expectedSHA256: rejected.sha256,
                hostEvidenceRoot: hostRoot
            )) { error in
                XCTAssertTrue(String(describing: error).contains("WORLD_MAP_SHORTCUT_BOUNDARY_INVALID"))
            }
        }
    }

    func testRepairRequiresLineage() throws {
        var fixture = try queueObject()
        var items = fixture["items"] as! [[String: Any]]
        items[0]["supersedes_item_id"] = "prior-item"
        items[0].removeValue(forKey: "item_sha256")
        items[0]["item_sha256"] = try CanonicalJSON.sha256(items[0])
        fixture["items"] = items
        fixture.removeValue(forKey: "policy_digest")
        fixture["policy_digest"] = try CanonicalJSON.sha256(fixture)
        let written = try writeQueue(fixture, finalize: false)
        XCTAssertThrowsError(try QueueManifestValidator.validate(
            fileAt: written.url,
            expectedSHA256: written.sha256,
            hostEvidenceRoot: temporaryDirectory()
        ))
    }

    func testRepairLineageMustContainSupersededItem() throws {
        var fixture = try queueObject()
        var items = fixture["items"] as! [[String: Any]]
        items[0]["supersedes_item_id"] = "prior-item"
        items[0]["repair_lineage"] = ["different-item"]
        fixture["items"] = items
        let written = try writeQueue(fixture)

        XCTAssertThrowsError(try QueueManifestValidator.validate(
            fileAt: written.url,
            expectedSHA256: written.sha256,
            hostEvidenceRoot: temporaryDirectory()
        ))
    }

    func testArtifactRootMustRemainUnderHostEvidenceRootWithoutSymlinks() throws {
        let hostRoot = temporaryDirectory().appendingPathComponent("host-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: hostRoot, withIntermediateDirectories: true)
        var outsideQueue = try queueObject()
        outsideQueue["artifact_root"] = hostRoot.deletingLastPathComponent()
            .appendingPathComponent("outside-\(UUID().uuidString)").path
        let outside = try writeQueue(outsideQueue)
        XCTAssertThrowsError(try QueueManifestValidator.validate(
            fileAt: outside.url,
            expectedSHA256: outside.sha256,
            hostEvidenceRoot: hostRoot
        )) { error in
            XCTAssertTrue(String(describing: error).contains("ARTIFACT_ROOT_OUTSIDE_EVIDENCE_ROOT"))
        }

        let real = hostRoot.appendingPathComponent("real")
        let linked = hostRoot.appendingPathComponent("linked")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: real)
        var linkedQueue = try queueObject()
        linkedQueue["artifact_root"] = linked.appendingPathComponent("proof").path
        let linkedFixture = try writeQueue(linkedQueue)
        XCTAssertThrowsError(try QueueManifestValidator.validate(
            fileAt: linkedFixture.url,
            expectedSHA256: linkedFixture.sha256,
            hostEvidenceRoot: hostRoot
        )) { error in
            XCTAssertTrue(String(describing: error).contains("ARTIFACT_PATH_SYMLINK_FORBIDDEN"))
        }
    }

    func testQueueCountsAndExecutionDurationAreBounded() async throws {
        var tooManyOperations = try queueObject()
        var items = tooManyOperations["items"] as! [[String: Any]]
        items[0]["operations"] = Array(repeating: ["kind": "capture"], count: 33)
        tooManyOperations["items"] = items
        let fixture = try writeQueue(tooManyOperations)
        XCTAssertThrowsError(try QueueManifestValidator.validate(
            fileAt: fixture.url,
            expectedSHA256: fixture.sha256,
            hostEvidenceRoot: temporaryDirectory()
        ))

        let store = QueueStore(itemExecutionDeadlineSeconds: 0)
        let valid = try makeQueueFixture()
        _ = try await store.activate(fileAt: valid.url, expectedSHA256: valid.sha256)
        do {
            _ = try await store.claim()
            XCTFail("an immediately expired item must fail closed")
        } catch {
            XCTAssertTrue(String(describing: error).contains("ITEM_EXECUTION_DEADLINE_EXCEEDED"))
        }
    }

    func testCaptureFreshnessRejectsExpiredOrFutureFrames() throws {
        let now = Date()
        XCTAssertNoThrow(try CaptureFreshnessPolicy.validate(
            capturedAt: AdapterClock.string(from: now.addingTimeInterval(-1)),
            now: now
        ))
        XCTAssertThrowsError(try CaptureFreshnessPolicy.validate(
            capturedAt: AdapterClock.string(from: now.addingTimeInterval(-4)),
            now: now
        ))
        XCTAssertThrowsError(try CaptureFreshnessPolicy.validate(
            capturedAt: AdapterClock.string(from: now.addingTimeInterval(1)),
            now: now
        ))
    }

    func testForegroundInterferenceRegistryScopesInputEmission() throws {
        let registry = ForegroundInterferenceRegistry()
        let gate = InputCancellationGate()
        registry.begin(gate)
        XCTAssertTrue(registry.hasActiveLease())
        XCTAssertFalse(registry.hasActiveInputEmission())
        registry.beginInputEmission(gate)
        XCTAssertTrue(registry.hasActiveInputEmission())
        XCTAssertTrue(registry.invalidateActive(reason: "FOCUS_CHANGED"))
        XCTAssertThrowsError(try gate.checkValid())
        registry.endInputEmission(gate)
        registry.end(gate)
        XCTAssertFalse(registry.hasActiveLease())
    }

    func testWorkerRuntimeIdentityRejectsClosureMutation() throws {
        let node = URL(fileURLWithPath: "/opt/homebrew/bin/node")
        guard FileManager.default.isExecutableFile(atPath: node.path) else {
            throw XCTSkip("Node 26 is unavailable at the production path")
        }
        let container = temporaryDirectory().appendingPathComponent("runtime-\(UUID().uuidString)")
        let root = container.appendingPathComponent("node-worker")
        let source = root.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let worker = source.appendingPathComponent("worker.mjs")
        try Data("setInterval(() => {}, 1000);\n".utf8).write(to: worker)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: worker.path)
        let file = WorkerRuntimeFile(
            path: "src/worker.mjs",
            sha256: try AdapterHashing.sha256(fileAt: worker),
            size: try Data(contentsOf: worker).count,
            mode: "0644"
        )
        let raw: [[String: Any]] = [[
            "path": file.path,
            "sha256": file.sha256,
            "size": file.size,
            "mode": file.mode
        ]]
        let manifest = WorkerRuntimeClosure(
            schemaVersion: 1,
            files: [file],
            closureSHA256: try CanonicalJSON.sha256(raw)
        )
        let manifestURL = container.appendingPathComponent("WORKER_RUNTIME_CLOSURE.json")
        try JSONEncoder().encode(manifest).write(to: manifestURL)
        let identity = try WorkerRuntimeIdentityVerifier.verify(
            nodeExecutable: node,
            workerRoot: root,
            workerEntryPoint: worker,
            closureManifest: manifestURL
        )
        XCTAssertEqual(identity.workerFileCount, 1)
        try Data("throw new Error('mutated');\n".utf8).write(to: worker)
        XCTAssertThrowsError(try WorkerRuntimeIdentityVerifier.verify(
            nodeExecutable: node,
            workerRoot: root,
            workerEntryPoint: worker,
            closureManifest: manifestURL
        ))
    }

    func testLaterGenerationSkipsAcceptedDuplicateAndClaimsRepair() async throws {
        let store = QueueStore()
        let initial = try writeQueue(try queueObject())
        _ = try await store.activate(fileAt: initial.url, expectedSHA256: initial.sha256)
        let initialClaimValue = try await store.claim()
        let initialClaim = try XCTUnwrap(initialClaimValue)
        _ = try await store.authorize(
            generationIdentifier: "generation-001",
            itemIdentifier: "item-001",
            action: .click(
                captureIdentifier: "capture-001",
                point: AdapterPoint(x: 100, y: 100),
                button: .left
            ),
            requestedEventSourceMode: .privateState,
            requestedDeliveryMode: .foregroundPid
        )
        try await store.recordActionCompleted(
            generationIdentifier: "generation-001",
            itemIdentifier: "item-001"
        )
        let initialResult = try writeWorkerResult(for: initialClaim)
        try await store.complete(
            generationIdentifier: "generation-001",
            itemIdentifier: "item-001",
            success: true,
            resultPath: initialResult.path,
            resultFileSHA256: initialResult.fileSHA256,
            resultDigest: initialResult.resultDigest
        )

        var duplicate = try queueObject()
        duplicate["generation_id"] = "generation-002"
        let duplicateFixture = try writeQueue(duplicate)
        _ = try await store.activate(
            fileAt: duplicateFixture.url,
            expectedSHA256: duplicateFixture.sha256
        )
        let duplicateClaim = try await store.claim()
        XCTAssertNil(duplicateClaim)

        var repair = try queueObject()
        repair["generation_id"] = "generation-003"
        var repairItems = repair["items"] as! [[String: Any]]
        repairItems[0]["id"] = "repair-001"
        repairItems[0]["supersedes_item_id"] = "item-001"
        repairItems[0]["repair_lineage"] = ["item-001"]
        repair["items"] = repairItems
        let repairFixture = try writeQueue(repair)
        _ = try await store.activate(
            fileAt: repairFixture.url,
            expectedSHA256: repairFixture.sha256
        )
        let repairClaim = try await store.claim()
        XCTAssertEqual(repairClaim?.item.id, "repair-001")
    }

    func testFailedItemDurablyRequiresFreshGenerationIdentifier() async throws {
        let hostEvidenceRoot = temporaryDirectory()
            .appendingPathComponent("failed-generation-\(UUID().uuidString)")
        let acceptanceRoot = hostEvidenceRoot.appendingPathComponent("broker")
        let firstStore = QueueStore(
            acceptanceRoot: acceptanceRoot,
            hostEvidenceRoot: hostEvidenceRoot
        )
        var firstObject = try queueObject()
        firstObject["artifact_root"] = hostEvidenceRoot.appendingPathComponent("worker").path
        let first = try writeQueue(firstObject)
        _ = try await firstStore.activate(fileAt: first.url, expectedSHA256: first.sha256)
        let failedClaimValue = try await firstStore.claim()
        let failedClaim = try XCTUnwrap(failedClaimValue)

        do {
            try await firstStore.complete(
                generationIdentifier: failedClaim.generationIdentifier,
                itemIdentifier: failedClaim.item.id,
                success: false
            )
            XCTFail("a failed item must revoke its generation")
        } catch {
            XCTAssertTrue(String(describing: error).contains("ITEM_FAILED_REQUIRES_PAUSE"))
        }
        do {
            _ = try await firstStore.claim()
            XCTFail("a failed generation must not remain claimable")
        } catch {
            XCTAssertTrue(String(describing: error).contains("QUEUE_UNAVAILABLE"))
        }
        let revocation = hostEvidenceRoot
            .appendingPathComponent("revoked-generations/generation-001.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: revocation.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: revocation.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o444)

        let restartedStore = QueueStore(
            acceptanceRoot: acceptanceRoot,
            hostEvidenceRoot: hostEvidenceRoot
        )
        do {
            _ = try await restartedStore.activate(fileAt: first.url, expectedSHA256: first.sha256)
            XCTFail("a revoked generation must not reactivate after restart")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains(
                    "GENERATION_REVOKED_REQUIRES_FRESH_IDENTIFIER:generation-001"
                )
            )
        }

        var successor = firstObject
        successor["generation_id"] = "generation-002"
        let successorFixture = try writeQueue(successor)
        _ = try await restartedStore.activate(
            fileAt: successorFixture.url,
            expectedSHA256: successorFixture.sha256
        )
        let successorClaim = try await restartedStore.claim()
        XCTAssertEqual(successorClaim?.generationIdentifier, "generation-002")
        XCTAssertEqual(successorClaim?.item.id, failedClaim.item.id)
    }

    func testFreshGenerationCanFollowRuntimeFailureEvidence() async throws {
        let hostEvidenceRoot = temporaryDirectory()
            .appendingPathComponent("runtime-failure-successor-\(UUID().uuidString)")
        let acceptanceRoot = hostEvidenceRoot.appendingPathComponent("broker")
        let artifactRoot = hostEvidenceRoot.appendingPathComponent("artifacts")
        var firstObject = try queueObject()
        firstObject["artifact_root"] = artifactRoot.path
        let first = try writeQueue(firstObject)
        let firstStore = QueueStore(
            acceptanceRoot: acceptanceRoot,
            hostEvidenceRoot: hostEvidenceRoot
        )
        _ = try await firstStore.activate(fileAt: first.url, expectedSHA256: first.sha256)
        let claimValue = try await firstStore.claim()
        let claim = try XCTUnwrap(claimValue)
        let failureURL = artifactRoot
            .appendingPathComponent("worker/\(claim.generationIdentifier)")
            .appendingPathComponent("\(claim.item.id)-failure.json")
        try writeImmutableJSON(
            [
                "schema_version": 1,
                "generation_id": claim.generationIdentifier,
                "item_id": claim.item.id,
                "failed_at": "2026-08-05T07:58:17.277Z"
            ],
            to: failureURL
        )

        do {
            try await firstStore.complete(
                generationIdentifier: claim.generationIdentifier,
                itemIdentifier: claim.item.id,
                success: false
            )
            XCTFail("a failed item must revoke its generation")
        } catch {
            XCTAssertTrue(String(describing: error).contains("ITEM_FAILED_REQUIRES_PAUSE"))
        }

        var successorObject = firstObject
        successorObject["generation_id"] = "generation-002"
        let successor = try writeQueue(successorObject)
        let restartedStore = QueueStore(
            acceptanceRoot: acceptanceRoot,
            hostEvidenceRoot: hostEvidenceRoot
        )
        _ = try await restartedStore.activate(
            fileAt: successor.url,
            expectedSHA256: successor.sha256
        )
        let successorClaim = try await restartedStore.claim()
        XCTAssertEqual(successorClaim?.generationIdentifier, "generation-002")
    }

    func testActivatedGenerationIsDurablyOneUseBeforeFirstClaim() async throws {
        let hostEvidenceRoot = temporaryDirectory()
            .appendingPathComponent("used-generation-\(UUID().uuidString)")
        let acceptanceRoot = hostEvidenceRoot.appendingPathComponent("broker")
        var queue = try queueObject()
        queue["generation_id"] = "generation-hard-loss"
        queue["artifact_root"] = hostEvidenceRoot.appendingPathComponent("worker").path
        let fixture = try writeQueue(queue)
        let store = QueueStore(
            acceptanceRoot: acceptanceRoot,
            hostEvidenceRoot: hostEvidenceRoot
        )

        _ = try await store.activate(fileAt: fixture.url, expectedSHA256: fixture.sha256)

        let useRecord = hostEvidenceRoot
            .appendingPathComponent("used-generations/generation-hard-loss.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: useRecord.path))
        let mode = try FileManager.default.attributesOfItem(atPath: useRecord.path)[.posixPermissions]
            as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o444)

        let restartedStore = QueueStore(
            acceptanceRoot: acceptanceRoot,
            hostEvidenceRoot: hostEvidenceRoot
        )
        do {
            _ = try await restartedStore.activate(
                fileAt: fixture.url,
                expectedSHA256: fixture.sha256
            )
            XCTFail("an activated generation must not be reusable after hard process loss")
        } catch {
            XCTAssertTrue(String(describing: error).contains(
                "GENERATION_USED_REQUIRES_FRESH_IDENTIFIER:generation-hard-loss"
            ))
        }
    }

    func testDeadlineExpiryAtEveryQueueTransitionDurablyRevokesGeneration() async throws {
        for phase in ["claim", "authorize", "action-completion", "failure", "success"] {
            let hostEvidenceRoot = temporaryDirectory()
                .appendingPathComponent("deadline-\(phase)-\(UUID().uuidString)")
            let acceptanceRoot = hostEvidenceRoot.appendingPathComponent("broker")
            let generation = "generation-deadline-\(phase)"
            var queue = try queueObject()
            queue["generation_id"] = generation
            queue["artifact_root"] = hostEvidenceRoot.appendingPathComponent("worker").path
            let fixture = try writeQueue(queue)
            let clock = TestClock(Date(timeIntervalSince1970: 1_000))
            let store = QueueStore(
                acceptanceRoot: acceptanceRoot,
                hostEvidenceRoot: hostEvidenceRoot,
                itemExecutionDeadlineSeconds: phase == "claim" ? 0 : 10,
                now: { clock.value }
            )
            _ = try await store.activate(fileAt: fixture.url, expectedSHA256: fixture.sha256)

            var claim: QueueClaim?
            if phase != "claim" {
                let claimed = try await store.claim()
                claim = try XCTUnwrap(claimed)
                if phase == "action-completion" || phase == "success" {
                    _ = try await store.authorize(
                        generationIdentifier: generation,
                        itemIdentifier: "item-001",
                        action: .click(
                            captureIdentifier: "capture-001",
                            point: AdapterPoint(x: 100, y: 100),
                            button: .left
                        ),
                        requestedEventSourceMode: .privateState,
                        requestedDeliveryMode: .foregroundPid
                    )
                }
                if phase == "success" {
                    try await store.recordActionCompleted(
                        generationIdentifier: generation,
                        itemIdentifier: "item-001"
                    )
                }
                clock.value = clock.value.addingTimeInterval(11)
            }

            do {
                switch phase {
                case "claim":
                    _ = try await store.claim()
                case "authorize":
                    _ = try await store.authorize(
                        generationIdentifier: generation,
                        itemIdentifier: "item-001",
                        action: .click(
                            captureIdentifier: "capture-001",
                            point: AdapterPoint(x: 100, y: 100),
                            button: .left
                        ),
                        requestedEventSourceMode: .privateState,
                        requestedDeliveryMode: .foregroundPid
                    )
                case "action-completion":
                    try await store.recordActionCompleted(
                        generationIdentifier: generation,
                        itemIdentifier: "item-001"
                    )
                case "failure":
                    try await store.complete(
                        generationIdentifier: generation,
                        itemIdentifier: "item-001",
                        success: false
                    )
                case "success":
                    let result = try writeWorkerResult(for: try XCTUnwrap(claim))
                    try await store.complete(
                        generationIdentifier: generation,
                        itemIdentifier: "item-001",
                        success: true,
                        resultPath: result.path,
                        resultFileSHA256: result.fileSHA256,
                        resultDigest: result.resultDigest
                    )
                default:
                    XCTFail("unknown deadline phase")
                }
                XCTFail("deadline phase \(phase) must fail closed")
            } catch {
                XCTAssertTrue(
                    String(describing: error).contains("ITEM_EXECUTION_DEADLINE_EXCEEDED"),
                    "unexpected \(phase) error: \(error)"
                )
            }

            let revocation = hostEvidenceRoot
                .appendingPathComponent("revoked-generations/\(generation).json")
            XCTAssertTrue(FileManager.default.fileExists(atPath: revocation.path), phase)
            let mode = try FileManager.default.attributesOfItem(
                atPath: revocation.path
            )[.posixPermissions] as? NSNumber
            XCTAssertEqual(mode?.intValue, 0o444, phase)

            let restartedStore = QueueStore(
                acceptanceRoot: acceptanceRoot,
                hostEvidenceRoot: hostEvidenceRoot
            )
            do {
                _ = try await restartedStore.activate(
                    fileAt: fixture.url,
                    expectedSHA256: fixture.sha256
                )
                XCTFail("deadline phase \(phase) must remain revoked after restart")
            } catch {
                XCTAssertTrue(String(describing: error).contains(
                    "GENERATION_REVOKED_REQUIRES_FRESH_IDENTIFIER:\(generation)"
                ))
            }
        }
    }

    func testWorkerLossAtEveryInFlightPhaseDurablyRevokesGeneration() async throws {
        for phase in ["before-input", "after-input-emission", "after-input-evidence", "before-failure-rpc"] {
            let hostEvidenceRoot = temporaryDirectory()
                .appendingPathComponent("worker-loss-\(phase)-\(UUID().uuidString)")
            let acceptanceRoot = hostEvidenceRoot.appendingPathComponent("broker")
            let generation = "generation-worker-loss-\(phase)"
            var queue = try queueObject()
            queue["generation_id"] = generation
            queue["artifact_root"] = hostEvidenceRoot.appendingPathComponent("worker").path
            let fixture = try writeQueue(queue)
            let store = QueueStore(
                acceptanceRoot: acceptanceRoot,
                hostEvidenceRoot: hostEvidenceRoot
            )
            _ = try await store.activate(fileAt: fixture.url, expectedSHA256: fixture.sha256)
            _ = try await store.claim()
            if phase != "before-input" {
                _ = try await store.authorize(
                    generationIdentifier: generation,
                    itemIdentifier: "item-001",
                    action: .click(
                        captureIdentifier: "capture-001",
                        point: AdapterPoint(x: 100, y: 100),
                        button: .left
                    ),
                    requestedEventSourceMode: .privateState,
                    requestedDeliveryMode: .foregroundPid
                )
            }
            if phase == "after-input-evidence" || phase == "before-failure-rpc" {
                try await store.recordActionCompleted(
                    generationIdentifier: generation,
                    itemIdentifier: "item-001"
                )
            }

            let engine = AdapterEngine(
                capabilities: AdapterCapabilities(worker: "worker"),
                evidenceRoot: hostEvidenceRoot,
                queueStore: store
            )
            await engine.workerDidTerminate(status: 9)

            let revocation = hostEvidenceRoot
                .appendingPathComponent("revoked-generations/\(generation).json")
            XCTAssertTrue(FileManager.default.fileExists(atPath: revocation.path), phase)
            let restartedStore = QueueStore(
                acceptanceRoot: acceptanceRoot,
                hostEvidenceRoot: hostEvidenceRoot
            )
            do {
                _ = try await restartedStore.activate(
                    fileAt: fixture.url,
                    expectedSHA256: fixture.sha256
                )
                XCTFail("worker-loss phase \(phase) must remain revoked after restart")
            } catch {
                XCTAssertTrue(String(describing: error).contains(
                    "GENERATION_REVOKED_REQUIRES_FRESH_IDENTIFIER:\(generation)"
                ))
            }
        }
    }

    func testSocketLossRevokesInFlightGenerationBeforeRecovery() async throws {
        let hostEvidenceRoot = temporaryDirectory()
            .appendingPathComponent("socket-loss-active-\(UUID().uuidString)")
        let acceptanceRoot = hostEvidenceRoot.appendingPathComponent("broker")
        var queue = try queueObject()
        queue["generation_id"] = "generation-socket-loss"
        queue["artifact_root"] = hostEvidenceRoot.appendingPathComponent("worker").path
        let fixture = try writeQueue(queue)
        let store = QueueStore(
            acceptanceRoot: acceptanceRoot,
            hostEvidenceRoot: hostEvidenceRoot
        )
        _ = try await store.activate(fileAt: fixture.url, expectedSHA256: fixture.sha256)
        _ = try await store.claim()
        let engine = AdapterEngine(
            capabilities: AdapterCapabilities(worker: "worker"),
            evidenceRoot: hostEvidenceRoot,
            queueStore: store
        )

        await engine.runtimeDidFail(reason: "CONTROL_SOCKET_MISSING")

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: hostEvidenceRoot
                .appendingPathComponent("revoked-generations/generation-socket-loss.json").path
        ))
    }

    func testQueueAndJobCancellationRemainRevokedAcrossRestart() async throws {
        for cancellation in ["queue", "job"] {
            let hostEvidenceRoot = temporaryDirectory()
                .appendingPathComponent("cancel-\(cancellation)-\(UUID().uuidString)")
            let acceptanceRoot = hostEvidenceRoot.appendingPathComponent("broker")
            let generation = "generation-cancel-\(cancellation)"
            var queue = try queueObject()
            queue["generation_id"] = generation
            queue["artifact_root"] = hostEvidenceRoot.appendingPathComponent("worker").path
            let fixture = try writeQueue(queue)
            let store = QueueStore(
                acceptanceRoot: acceptanceRoot,
                hostEvidenceRoot: hostEvidenceRoot
            )
            _ = try await store.activate(fileAt: fixture.url, expectedSHA256: fixture.sha256)
            if cancellation == "job" {
                _ = try await store.claim()
                try await store.cancelJob(itemIdentifier: "item-001")
            } else {
                try await store.cancel(generationIdentifier: generation)
            }

            let restartedStore = QueueStore(
                acceptanceRoot: acceptanceRoot,
                hostEvidenceRoot: hostEvidenceRoot
            )
            do {
                _ = try await restartedStore.activate(
                    fileAt: fixture.url,
                    expectedSHA256: fixture.sha256
                )
                XCTFail("\(cancellation) cancellation must remain revoked after restart")
            } catch {
                XCTAssertTrue(String(describing: error).contains(
                    "GENERATION_REVOKED_REQUIRES_FRESH_IDENTIFIER:\(generation)"
                ))
            }
        }
    }

    func testQueueCancellationPublishesBoundImmutableEventAndClearsRuntimeState() async throws {
        let hostEvidenceRoot = temporaryDirectory()
            .appendingPathComponent("cancel-transaction-\(UUID().uuidString)")
        let generation = "generation-cancel-transaction"
        let fixture = try makeCancellationQueueFixture(
            hostEvidenceRoot: hostEvidenceRoot,
            generationIdentifier: generation
        )
        let store = QueueStore(
            acceptanceRoot: hostEvidenceRoot.appendingPathComponent("broker"),
            hostEvidenceRoot: hostEvidenceRoot
        )
        _ = try await store.activateForHostUI(
            fileAt: fixture.url,
            expectedSHA256: fixture.sha256
        )
        _ = try await store.claim()
        try await store.cancel(generationIdentifier: generation)

        let snapshot = await store.snapshot()
        XCTAssertNil(snapshot.generationIdentifier)
        XCTAssertNil(snapshot.activeItemIdentifier)
        XCTAssertTrue(snapshot.isDrained)
        XCTAssertFalse(snapshot.isCanceled)

        let eventURL = hostEvidenceRoot
            .appendingPathComponent("events/queue-canceled-\(generation).json")
        let intentURL = hostEvidenceRoot
            .appendingPathComponent("cancellation-intents/\(generation).json")
        let revocationURL = hostEvidenceRoot
            .appendingPathComponent("revoked-generations/\(generation).json")
        for url in [eventURL, intentURL, revocationURL] {
            XCTAssertEqual(try fileMode(at: url), 0o444)
        }
        let event = try jsonObject(at: eventURL)
        XCTAssertEqual(event["schema_version"] as? Int, 1)
        XCTAssertEqual(event["event"] as? String, "queue_canceled")
        XCTAssertEqual(event["generation_id"] as? String, generation)
        XCTAssertEqual(
            event["manifest_path"] as? String,
            hostEvidenceRoot
                .appendingPathComponent(generation, isDirectory: true)
                .appendingPathComponent("operator", isDirectory: true)
                .appendingPathComponent("\(generation).json").path
        )
        XCTAssertEqual(event["manifest_sha256"] as? String, fixture.sha256)
        XCTAssertEqual(event["cancellation_reason"] as? String, "QUEUE_CANCELED")
        XCTAssertEqual(event["prior_item_id"] as? String, "item-001")
        XCTAssertEqual(event["revocation_reason"] as? String, "QUEUE_CANCELED")
        XCTAssertEqual(
            event["cancellation_intent_sha256"] as? String,
            AdapterHashing.sha256(try Data(contentsOf: intentURL))
        )

        let eventHash = AdapterHashing.sha256(try Data(contentsOf: eventURL))
        try await store.cancel(generationIdentifier: generation)
        XCTAssertEqual(eventHash, AdapterHashing.sha256(try Data(contentsOf: eventURL)))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: eventURL.deletingLastPathComponent(),
                includingPropertiesForKeys: nil
            ).filter { $0.lastPathComponent == eventURL.lastPathComponent }.count,
            1
        )
    }

    func testCancellationCrashBoundariesRecoverBeforeFreshActivation() async throws {
        for phase in [
            QueueCancellationPhase.afterIntentPublication,
            .afterRevocationPublication,
            .beforeEventPublication,
            .afterEventPublication,
            .beforeRuntimeClear
        ] {
            let hostEvidenceRoot = temporaryDirectory()
                .appendingPathComponent("cancel-crash-\(phase.rawValue)-\(UUID().uuidString)")
            let generation = "generation-cancel-\(phase.rawValue.lowercased())"
            let fixture = try makeCancellationQueueFixture(
                hostEvidenceRoot: hostEvidenceRoot,
                generationIdentifier: generation
            )
            let store = QueueStore(
                acceptanceRoot: hostEvidenceRoot.appendingPathComponent("broker"),
                hostEvidenceRoot: hostEvidenceRoot,
                cancellationHooks: QueueCancellationHooks { reached in
                    if reached == phase { throw InjectedCancellationFailure() }
                }
            )
            _ = try await store.activateForHostUI(
                fileAt: fixture.url,
                expectedSHA256: fixture.sha256
            )
            _ = try await store.claim()
            do {
                try await store.cancel(generationIdentifier: generation)
                XCTFail("\(phase.rawValue) must interrupt cancellation")
            } catch {
                XCTAssertTrue(error is InjectedCancellationFailure)
            }

            let restarted = QueueStore(
                acceptanceRoot: hostEvidenceRoot.appendingPathComponent("broker"),
                hostEvidenceRoot: hostEvidenceRoot
            )
            try await restarted.prepare()
            XCTAssertEqual(
                try fileMode(at: hostEvidenceRoot.appendingPathComponent(
                    "revoked-generations/\(generation).json"
                )),
                0o444
            )
            XCTAssertEqual(
                try fileMode(at: hostEvidenceRoot.appendingPathComponent(
                    "events/queue-canceled-\(generation).json"
                )),
                0o444
            )
            do {
                _ = try await restarted.activate(
                    fileAt: fixture.url,
                    expectedSHA256: fixture.sha256
                )
                XCTFail("\(phase.rawValue) must leave the failed generation one-use")
            } catch {
                XCTAssertTrue(String(describing: error).contains(
                    "GENERATION_REVOKED_REQUIRES_FRESH_IDENTIFIER:\(generation)"
                ))
            }
        }
    }

    func testCancellationEventFailureAndRuntimeClearFailureFailClosed() async throws {
        for phase in [
            QueueCancellationPhase.beforeEventPublication,
            .beforeRuntimeClear
        ] {
            let hostEvidenceRoot = temporaryDirectory()
                .appendingPathComponent("cancel-failure-\(phase.rawValue)-\(UUID().uuidString)")
            let generation = "generation-failure-\(phase.rawValue.lowercased())"
            let fixture = try makeCancellationQueueFixture(
                hostEvidenceRoot: hostEvidenceRoot,
                generationIdentifier: generation
            )
            let store = QueueStore(
                acceptanceRoot: hostEvidenceRoot.appendingPathComponent("broker"),
                hostEvidenceRoot: hostEvidenceRoot,
                cancellationHooks: QueueCancellationHooks { reached in
                    if reached == phase { throw InjectedCancellationFailure() }
                }
            )
            _ = try await store.activateForHostUI(
                fileAt: fixture.url,
                expectedSHA256: fixture.sha256
            )
            _ = try await store.claim()
            do {
                try await store.cancel(generationIdentifier: generation)
                XCTFail("\(phase.rawValue) must fail closed")
            } catch {
                XCTAssertTrue(error is InjectedCancellationFailure)
            }
            let snapshot = await store.snapshot()
            XCTAssertEqual(snapshot.generationIdentifier, generation)
            XCTAssertNil(snapshot.activeItemIdentifier)
            XCTAssertTrue(snapshot.isCanceled)
            do {
                _ = try await store.claim()
                XCTFail("a failed cancellation must prohibit further claims")
            } catch {
                XCTAssertTrue(String(describing: error).contains("QUEUE_UNAVAILABLE"))
            }
        }
    }

    func testCancellationRejectsWrongGenerationAndAcceptsFreshSuccessor() async throws {
        let hostEvidenceRoot = temporaryDirectory()
            .appendingPathComponent("cancel-successor-\(UUID().uuidString)")
        let failedGeneration = "generation-cancel-old"
        let failed = try makeCancellationQueueFixture(
            hostEvidenceRoot: hostEvidenceRoot,
            generationIdentifier: failedGeneration
        )
        let store = QueueStore(
            acceptanceRoot: hostEvidenceRoot.appendingPathComponent("broker"),
            hostEvidenceRoot: hostEvidenceRoot
        )
        _ = try await store.activateForHostUI(
            fileAt: failed.url,
            expectedSHA256: failed.sha256
        )
        do {
            try await store.cancel(generationIdentifier: "another-generation")
            XCTFail("a mismatched generation must not be canceled")
        } catch {
            XCTAssertTrue(String(describing: error).contains("GENERATION_MISMATCH"))
        }
        let retainedSnapshot = await store.snapshot()
        XCTAssertEqual(retainedSnapshot.generationIdentifier, failedGeneration)
        try await store.cancel(generationIdentifier: failedGeneration)

        let restarted = QueueStore(
            acceptanceRoot: hostEvidenceRoot.appendingPathComponent("broker"),
            hostEvidenceRoot: hostEvidenceRoot
        )
        let successor = try makeCancellationQueueFixture(
            hostEvidenceRoot: hostEvidenceRoot,
            generationIdentifier: "generation-cancel-successor"
        )
        let manifest = try await restarted.activate(
            fileAt: successor.url,
            expectedSHA256: successor.sha256
        )
        XCTAssertEqual(manifest.generationIdentifier, "generation-cancel-successor")
    }

    func testCancellationRecoveryRejectsConflictingImmutableEvent() async throws {
        let hostEvidenceRoot = temporaryDirectory()
            .appendingPathComponent("cancel-conflict-\(UUID().uuidString)")
        let generation = "generation-cancel-conflict"
        let fixture = try makeCancellationQueueFixture(
            hostEvidenceRoot: hostEvidenceRoot,
            generationIdentifier: generation
        )
        let store = QueueStore(
            acceptanceRoot: hostEvidenceRoot.appendingPathComponent("broker"),
            hostEvidenceRoot: hostEvidenceRoot
        )
        _ = try await store.activateForHostUI(
            fileAt: fixture.url,
            expectedSHA256: fixture.sha256
        )
        try await store.cancel(generationIdentifier: generation)
        let eventURL = hostEvidenceRoot
            .appendingPathComponent("events/queue-canceled-\(generation).json")
        var event = try jsonObject(at: eventURL)
        event["generation_id"] = "different-generation"
        try replaceImmutableJSON(event, at: eventURL)

        let restarted = QueueStore(
            acceptanceRoot: hostEvidenceRoot.appendingPathComponent("broker"),
            hostEvidenceRoot: hostEvidenceRoot
        )
        do {
            try await restarted.prepare()
            XCTFail("conflicting cancellation evidence must fail closed")
        } catch {
            XCTAssertTrue(String(describing: error).contains("CANCELLATION_EVENT_CONFLICT"))
        }
    }

    func testCancellationRecoveryRejectsMalformedIntentBeforeFurtherPublication() async throws {
        let hostEvidenceRoot = temporaryDirectory()
            .appendingPathComponent("cancel-intent-malformed-\(UUID().uuidString)")
        let generation = "generation-cancel-intent-malformed"
        let fixture = try makeCancellationQueueFixture(
            hostEvidenceRoot: hostEvidenceRoot,
            generationIdentifier: generation
        )
        let store = QueueStore(
            acceptanceRoot: hostEvidenceRoot.appendingPathComponent("broker"),
            hostEvidenceRoot: hostEvidenceRoot
        )
        _ = try await store.activateForHostUI(
            fileAt: fixture.url,
            expectedSHA256: fixture.sha256
        )
        try await store.cancel(generationIdentifier: generation)
        let intentURL = hostEvidenceRoot
            .appendingPathComponent("cancellation-intents/\(generation).json")
        var intent = try jsonObject(at: intentURL)
        intent["unexpected"] = "forbidden"
        try replaceImmutableJSON(intent, at: intentURL)

        let restarted = QueueStore(
            acceptanceRoot: hostEvidenceRoot.appendingPathComponent("broker"),
            hostEvidenceRoot: hostEvidenceRoot
        )
        do {
            try await restarted.prepare()
            XCTFail("a malformed cancellation intent must fail closed")
        } catch {
            XCTAssertTrue(String(describing: error).contains(
                "QUEUE_CANCELLATION_INTENT_SCHEMA_INVALID"
            ))
        }
    }

    func testCancelWithoutActiveQueueIsAnIdempotentNoOp() async throws {
        let hostEvidenceRoot = temporaryDirectory()
            .appendingPathComponent("cancel-empty-\(UUID().uuidString)")
        let store = QueueStore(
            acceptanceRoot: hostEvidenceRoot.appendingPathComponent("broker"),
            hostEvidenceRoot: hostEvidenceRoot
        )
        try await store.cancel(generationIdentifier: nil)
        try await store.cancelJob(itemIdentifier: nil)
        let snapshot = await store.snapshot()
        XCTAssertNil(snapshot.generationIdentifier)
        XCTAssertNil(snapshot.activeItemIdentifier)
        XCTAssertTrue(snapshot.isDrained)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: hostEvidenceRoot.appendingPathComponent("events").path
        ))
    }

    func testAdapterEngineCancellationReportsOnlyAfterQueueBindingsClear() async throws {
        let hostEvidenceRoot = temporaryDirectory()
            .appendingPathComponent("engine-cancel-\(UUID().uuidString)")
        let generation = "generation-engine-cancel"
        let fixture = try makeCancellationQueueFixture(
            hostEvidenceRoot: hostEvidenceRoot,
            generationIdentifier: generation
        )
        let engine = AdapterEngine(
            capabilities: AdapterCapabilities(worker: "worker"),
            evidenceRoot: hostEvidenceRoot
        )
        let activated = await engine.handle(
            AdapterRequest(
                method: "queue.activate",
                queueManifestPath: fixture.url.path,
                queueManifestSHA256: fixture.sha256
            ),
            role: .hostUI
        )
        XCTAssertTrue(activated.ok)
        XCTAssertEqual(activated.status?.activeQueueGeneration, generation)

        let canceled = await engine.handle(
            AdapterRequest(method: "queue.cancel", queueGeneration: generation),
            role: .hostUI
        )
        XCTAssertTrue(canceled.ok)
        XCTAssertEqual(canceled.message, "QUEUE_CANCELED")
        XCTAssertNil(canceled.status?.activeQueueGeneration)
        XCTAssertNil(canceled.status?.activeItemIdentifier)
        XCTAssertNil(canceled.status?.target)
        let eventURL = hostEvidenceRoot
            .appendingPathComponent("events/queue-canceled-\(generation).json")
        XCTAssertEqual(try fileMode(at: eventURL), 0o444)
    }

    func testLegacyC3MigrationPublishesImmutableUseAndRevocationBeforeRejectingActivation() async throws {
        let fixture = try writeLegacyGenerationFixture()
        let useMarker = fixture.hostEvidenceRoot
            .appendingPathComponent("used-generations/\(fixture.generationIdentifier).json")
        let revocationMarker = fixture.hostEvidenceRoot
            .appendingPathComponent("revoked-generations/\(fixture.generationIdentifier).json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: useMarker.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: revocationMarker.path))

        let store = QueueStore(
            acceptanceRoot: fixture.hostEvidenceRoot.appendingPathComponent("broker"),
            hostEvidenceRoot: fixture.hostEvidenceRoot
        )
        do {
            _ = try await store.activate(
                fileAt: fixture.manifestURL,
                expectedSHA256: fixture.manifestSHA256
            )
            XCTFail("the exact failed legacy C3 generation must never reactivate")
        } catch {
            XCTAssertTrue(String(describing: error).contains(
                "GENERATION_REVOKED_REQUIRES_FRESH_IDENTIFIER:\(fixture.generationIdentifier)"
            ), "unexpected migration error: \(error)")
        }

        for marker in [useMarker, revocationMarker] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
            let mode = try FileManager.default.attributesOfItem(
                atPath: marker.path
            )[.posixPermissions] as? NSNumber
            XCTAssertEqual(mode?.intValue, 0o444)
        }
        let use = try jsonObject(at: useMarker)
        XCTAssertEqual(use["manifest_sha256"] as? String, fixture.manifestSHA256)
        XCTAssertEqual(use["activated_at"] as? String, "2026-08-04T05:08:59.475Z")
        let revocation = try jsonObject(at: revocationMarker)
        XCTAssertEqual(revocation["reason"] as? String, "LEGACY_ITEM_FAILED:ancient-37_5-east")
        XCTAssertEqual(revocation["revoked_at"] as? String, "2026-08-04T05:09:08.551Z")

        let originalUseBytes = try Data(contentsOf: useMarker)
        let originalRevocationBytes = try Data(contentsOf: revocationMarker)

        let restartedStore = QueueStore(
            acceptanceRoot: fixture.hostEvidenceRoot.appendingPathComponent("broker"),
            hostEvidenceRoot: fixture.hostEvidenceRoot
        )
        do {
            _ = try await restartedStore.activate(
                fileAt: fixture.manifestURL,
                expectedSHA256: fixture.manifestSHA256
            )
            XCTFail("the migrated revocation must survive restart")
        } catch {
            XCTAssertTrue(String(describing: error).contains(
                "GENERATION_REVOKED_REQUIRES_FRESH_IDENTIFIER:\(fixture.generationIdentifier)"
            ), "unexpected migration error: \(error)")
        }
        XCTAssertEqual(try Data(contentsOf: useMarker), originalUseBytes)
        XCTAssertEqual(try Data(contentsOf: revocationMarker), originalRevocationBytes)

        var successor = try jsonObject(at: fixture.manifestURL)
        successor["generation_id"] = "adapter-fresh-successor"
        let successorFixture = try writeQueue(successor)
        _ = try await restartedStore.activate(
            fileAt: successorFixture.url,
            expectedSHA256: successorFixture.sha256
        )
        let claim = try await restartedStore.claim()
        XCTAssertEqual(claim?.generationIdentifier, "adapter-fresh-successor")
        XCTAssertEqual(claim?.item.id, "ancient-37_5-east")
    }

    func testLegacyMigrationAcceptsExpectedImmutableSemanticMapAssets() async throws {
        let fixture = try writeLegacyGenerationFixture(suffix: "semantic-assets")
        let assetRoot = fixture.hostEvidenceRoot
            .appendingPathComponent(fixture.generationIdentifier)
            .appendingPathComponent("worker")
            .appendingPathComponent(fixture.generationIdentifier)
            .appendingPathComponent("assets")
        try FileManager.default.createDirectory(
            at: assetRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: assetRoot.path
        )
        let asset = assetRoot.appendingPathComponent("ancient-37_5-east-map.png")
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: asset, options: .withoutOverwriting)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o444],
            ofItemAtPath: asset.path
        )

        let store = QueueStore(hostEvidenceRoot: fixture.hostEvidenceRoot)
        do {
            _ = try await store.activate(
                fileAt: fixture.manifestURL,
                expectedSHA256: fixture.manifestSHA256
            )
            XCTFail("the failed generation must remain revoked")
        } catch {
            XCTAssertTrue(String(describing: error).contains(
                "GENERATION_REVOKED_REQUIRES_FRESH_IDENTIFIER"
            ), "unexpected migration error: \(error)")
        }
        XCTAssertTrue(legacyMarkerExists(fixture, directory: "used-generations"))
        XCTAssertTrue(legacyMarkerExists(fixture, directory: "revoked-generations"))
    }

    func testLegacyMigrationRejectsUnexpectedWorkerEvidenceDirectory() async throws {
        let fixture = try writeLegacyGenerationFixture(suffix: "unexpected-directory")
        let unexpected = fixture.hostEvidenceRoot
            .appendingPathComponent(fixture.generationIdentifier)
            .appendingPathComponent("worker")
            .appendingPathComponent(fixture.generationIdentifier)
            .appendingPathComponent("unexpected")
        try FileManager.default.createDirectory(
            at: unexpected,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let store = QueueStore(hostEvidenceRoot: fixture.hostEvidenceRoot)
        do {
            _ = try await store.activate(
                fileAt: fixture.manifestURL,
                expectedSHA256: fixture.manifestSHA256
            )
            XCTFail("unexpected worker evidence directories must fail closed")
        } catch {
            XCTAssertTrue(String(describing: error).contains(
                "WORKER_EVIDENCE_MEMBER_TYPE_FORBIDDEN:unexpected"
            ), "unexpected migration error: \(error)")
        }
        XCTAssertFalse(legacyMarkerExists(fixture, directory: "used-generations"))
        XCTAssertFalse(legacyMarkerExists(fixture, directory: "revoked-generations"))
    }

    func testLegacySchemaVersionDecoderRequiresAnExactPositiveInteger() throws {
        let decodedInteger = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(#"{"schema_version":1}"#.utf8)
            ) as? [String: Any]
        )
        let decodedIntegralFloat = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(#"{"schema_version":1.0}"#.utf8)
            ) as? [String: Any]
        )
        let decodedFractional = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(#"{"schema_version":1.5}"#.utf8)
            ) as? [String: Any]
        )
        let decodedBoolean = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(#"{"schema_version":true}"#.utf8)
            ) as? [String: Any]
        )
        let decodedOutOfRange = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(#"{"schema_version":9223372036854775808}"#.utf8)
            ) as? [String: Any]
        )

        XCTAssertEqual(LegacySchemaVersionDecoder.decode(decodedInteger["schema_version"]), 1)
        XCTAssertEqual(LegacySchemaVersionDecoder.decode(decodedIntegralFloat["schema_version"]), 1)
        XCTAssertNil(LegacySchemaVersionDecoder.decode(decodedFractional["schema_version"]))
        XCTAssertNil(LegacySchemaVersionDecoder.decode(decodedBoolean["schema_version"]))
        XCTAssertNil(LegacySchemaVersionDecoder.decode(decodedOutOfRange["schema_version"]))
        XCTAssertEqual(LegacySchemaVersionDecoder.decode(NSNumber(value: 2)), 2)

        let invalidValues: [(String, Any?)] = [
            ("missing", nil),
            ("boolean", NSNumber(value: true)),
            ("fractional", NSNumber(value: 1.5)),
            ("zero", NSNumber(value: 0)),
            ("negative", NSNumber(value: -1)),
            ("nan", NSNumber(value: Double.nan)),
            ("positive-infinity", NSNumber(value: Double.infinity)),
            ("negative-infinity", NSNumber(value: -Double.infinity)),
            ("out-of-range", NSNumber(value: UInt64(Int.max) + 1)),
            ("string", "1")
        ]
        for (name, value) in invalidValues {
            XCTAssertNil(LegacySchemaVersionDecoder.decode(value), name)
        }
    }

    func testLegacyRawSchemaVersionDecoderUsesExactNumberLexemesAndSafeStructure() {
        let accepted = [
            #"{"schema_version":1}"#,
            #"{"schema_version":1.0}"#,
            #"{"schema_version":1e0}"#,
            #"{"schema_version":0.1e1}"#,
            #"{ "other" : [1, {"schema_version": 1.5}], "schema_version" : 10e-1 }"#,
            #"{"text":"escaped \"schema_version\": 1.5", "schema_\u0076ersion":1}"#
        ]
        for json in accepted {
            XCTAssertEqual(
                LegacySchemaVersionDecoder.decodeRawSchemaVersion(in: Data(json.utf8)),
                1,
                json
            )
        }

        let rejected = [
            #"{"schema_version":1.00000000000000001}"#,
            #"{"schema_version":1.0000000000000000000000000000000000001}"#,
            #"{"schema_version":1.0000000000000000000000000000000000000000000000001}"#,
            #"{"schema_version":0.99999999999999999}"#,
            #"{"schema_version":0.9999999999999999999999999999999999999999999999999}"#,
            #"{"schema_version":0}"#,
            #"{"schema_version":-1}"#,
            #"{"schema_version":2}"#,
            #"{"schema_version":1e99999999999999999999}"#,
            #"{"schema_version":1e-99999999999999999999}"#,
            #"{"schema_version":1.0e-9223372036854775807}"#,
            #"{"schema_version":9223372036854775808}"#,
            #"{"schema_version":true}"#,
            #"{"schema_version":null}"#,
            #"{"schema_version":"1"}"#,
            #"{"schema_version":[1]}"#,
            #"{"schema_version":{"value":1}}"#,
            #"{"schema_version":1,"schema_\u0076ersion":1}"#,
            #"{"nested":{"schema_version":1}}"#,
            #"{"similarly_named_schema_version":1}"#,
            #"{"schema_version":1.}"#,
            #"{"schema_version":01}"#,
            #"{"schema_version":1} trailing"#,
            #"[ {"schema_version":1} ]"#
        ]
        for json in rejected {
            XCTAssertNil(
                LegacySchemaVersionDecoder.decodeRawSchemaVersion(in: Data(json.utf8)),
                json
            )
        }

        for value in [Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertNil(LegacySchemaVersionDecoder.decode(
                lexicalVersion: 1,
                structuredValue: NSNumber(value: value)
            ))
        }
    }

    func testLegacyRawSchemaVersionDecoderValidatesUnicodeSurrogatesInEveryString() {
        let accepted = [
            #"{"schema_version":1,"emoji\uD83D\uDE00":0}"#,
            #"{"schema_version":1,"value":"\uD83D\uDE00"}"#,
            #"{"schema_version":1,"nested":{"key\uD83D\uDE00":"value\uD83D\uDE00"}}"#,
            #"{"schema_version":1,"nested":["\uD83D\uDE00"]}"#,
            #"{"schema_version":1,"value":"\uD83D\uDE00\uD834\uDD1E"}"#,
            #"{"schema_version":1,"value":"\u0061\uD83D\uDE00\n"}"#
        ]
        for json in accepted {
            XCTAssertEqual(
                LegacySchemaVersionDecoder.decodeRawSchemaVersion(in: Data(json.utf8)),
                1,
                json
            )
        }

        let rejected = [
            #"{"schema_version":1,"\uD800":0}"#,
            #"{"schema_version":1,"\uDC00":0}"#,
            #"{"schema_version":1,"value":"\uD800"}"#,
            #"{"schema_version":1,"value":"\uDC00"}"#,
            #"{"schema_version":1,"nested":{"\uD800":0}}"#,
            #"{"schema_version":1,"nested":{"\uDC00":0}}"#,
            #"{"schema_version":1,"nested":{"value":"\uD800"}}"#,
            #"{"schema_version":1,"nested":{"value":"\uDC00"}}"#,
            #"{"schema_version":1,"nested":["\uD800"]}"#,
            #"{"schema_version":1,"nested":["\uDC00"]}"#,
            #"{"schema_version":1,"value":"\u0061\uD800\n"}"#,
            #"{"schema_version":1,"value":"\uDC00\uD800"}"#,
            #"{"schema_version":1,"value":"\uD800x\uDC00"}"#,
            #"{"schema_version":1,"value":"\uD800\n\uDC00"}"#,
            #"{"schema_version":1,"value":"\uD800\xDC00"}"#,
            #"{"schema_version":1,"value":"\uD800\uD800"}"#,
            #"{"schema_version":1,"value":"\uD800\u0000"}"#,
            #"{"schema_version":1,"value":"\uD800\uZZZZ"}"#
        ]
        for json in rejected {
            XCTAssertNil(
                LegacySchemaVersionDecoder.decodeRawSchemaVersion(in: Data(json.utf8)),
                json
            )
        }
    }

    func testLegacyMigrationRejectsMalformedUnrelatedWorkerUnicodeBeforeMarkerPublication() async throws {
        let malformedRecords = [
            #"{"schema_version":1,"message":"\uD800"}"#,
            #"{"schema_version":1,"nested":{"telemetry":["\uDC00"]}}"#
        ]
        for (index, record) in malformedRecords.enumerated() {
            let fixture = try writeLegacyGenerationFixture(
                suffix: "malformed-unrelated-unicode-\(index)"
            )
            let failureURL = try XCTUnwrap(fixture.failureURL)
            let telemetryURL = failureURL.deletingLastPathComponent()
                .appendingPathComponent("telemetry.json")
            try writeImmutableData(Data(record.utf8), to: telemetryURL)

            let store = QueueStore(hostEvidenceRoot: fixture.hostEvidenceRoot)
            do {
                _ = try await store.activate(
                    fileAt: fixture.manifestURL,
                    expectedSHA256: fixture.manifestSHA256
                )
                XCTFail("malformed unrelated worker JSON must fail migration")
            } catch {
                XCTAssertTrue(String(describing: error).contains(
                    "LEGACY_GENERATION_STATE_MIGRATION_FAILED"
                ), "case \(index): \(error)")
            }
            XCTAssertFalse(legacyMarkerExists(fixture, directory: "used-generations"))
            XCTAssertFalse(legacyMarkerExists(fixture, directory: "revoked-generations"))
        }
    }

    func testLegacyMigrationAcceptsExactOneLexemesAtEverySchemaBoundary() async throws {
        let tokens = ["1", "1.0", "1e0"]
        for boundary in LegacySchemaBoundary.allCases {
            for (index, token) in tokens.enumerated() {
                let fixture = try writeLegacyGenerationFixture(
                    suffix: "\(boundary.rawValue)-accepted-\(index)"
                )
                try installLegacySchemaEvidence(
                    for: boundary,
                    fixture: fixture,
                    schemaMembers: #""schema_version": \#(token),"#
                )
                let store = QueueStore(hostEvidenceRoot: fixture.hostEvidenceRoot)
                do {
                    _ = try await store.activate(
                        fileAt: fixture.manifestURL,
                        expectedSHA256: fixture.manifestSHA256
                    )
                    XCTFail("legacy generation must remain revoked")
                } catch {
                    XCTAssertTrue(String(describing: error).contains(
                        "GENERATION_REVOKED_REQUIRES_FRESH_IDENTIFIER"
                    ), "\(boundary.rawValue) \(token): \(error)")
                }
                XCTAssertTrue(legacyMarkerExists(fixture, directory: "used-generations"))
                XCTAssertTrue(legacyMarkerExists(fixture, directory: "revoked-generations"))
            }
        }
    }

    func testLegacyMigrationRejectsLossyAndUnsupportedLexemesAtEverySchemaBoundary() async throws {
        let tokens = [
            "1.00000000000000001",
            "1.0000000000000000000000000000000000001",
            "1.0000000000000000000000000000000000000000000000001",
            "0.99999999999999999",
            "0.9999999999999999999999999999999999999999999999999",
            "0",
            "-1",
            "2",
            "1e99999999999999999999",
            "1e-99999999999999999999",
            "9223372036854775808",
            "true",
            "null",
            #""1""#,
            "[1]",
            #"{"value":1}"#
        ]
        for boundary in LegacySchemaBoundary.allCases {
            for (index, token) in tokens.enumerated() {
                let fixture = try writeLegacyGenerationFixture(
                    suffix: "\(boundary.rawValue)-rejected-\(index)"
                )
                try installLegacySchemaEvidence(
                    for: boundary,
                    fixture: fixture,
                    schemaMembers: #""schema_version": \#(token),"#
                )
                let store = QueueStore(hostEvidenceRoot: fixture.hostEvidenceRoot)
                do {
                    _ = try await store.activate(
                        fileAt: fixture.manifestURL,
                        expectedSHA256: fixture.manifestSHA256
                    )
                    XCTFail("invalid schema token must fail closed")
                } catch {
                    XCTAssertTrue(String(describing: error).contains(
                        "LEGACY_GENERATION_STATE_MIGRATION_FAILED"
                    ), "\(boundary.rawValue) \(token): \(error)")
                }
                assertNoLegacyMarkerPublication(for: boundary, fixture: fixture)
            }
        }
    }

    func testLegacyMigrationRejectsDuplicateMissingAndMalformedSchemaAtEveryBoundary() async throws {
        let schemaMembers = [
            #""schema_version": 1, "schema_\u0076ersion": 1,"#,
            "",
            #""schema_version": 1.,"#
        ]
        for boundary in LegacySchemaBoundary.allCases {
            for (index, members) in schemaMembers.enumerated() {
                let fixture = try writeLegacyGenerationFixture(
                    suffix: "\(boundary.rawValue)-structure-\(index)"
                )
                try installLegacySchemaEvidence(
                    for: boundary,
                    fixture: fixture,
                    schemaMembers: members
                )
                let store = QueueStore(hostEvidenceRoot: fixture.hostEvidenceRoot)
                do {
                    _ = try await store.activate(
                        fileAt: fixture.manifestURL,
                        expectedSHA256: fixture.manifestSHA256
                    )
                    XCTFail("invalid schema structure must fail closed")
                } catch {
                    XCTAssertTrue(String(describing: error).contains(
                        "LEGACY_GENERATION_STATE_MIGRATION_FAILED"
                    ), "\(boundary.rawValue) case \(index): \(error)")
                }
                assertNoLegacyMarkerPublication(for: boundary, fixture: fixture)
            }
        }
    }

    func testLegacyMigrationRejectsFractionalFailureSchemaBeforeMarkerPublication() async throws {
        let fixture = try writeLegacyGenerationFixture(suffix: "fractional-failure-schema")
        let failureURL = try XCTUnwrap(fixture.failureURL)
        var failure = try jsonObject(at: failureURL)
        failure["schema_version"] = 1.5
        try replaceImmutableJSON(failure, at: failureURL)

        let store = QueueStore(hostEvidenceRoot: fixture.hostEvidenceRoot)
        do {
            _ = try await store.activate(
                fileAt: fixture.manifestURL,
                expectedSHA256: fixture.manifestSHA256
            )
            XCTFail("fractional failure schema must fail closed")
        } catch {
            XCTAssertTrue(String(describing: error).contains("FAILURE_SCHEMA_INVALID"))
        }
        XCTAssertFalse(legacyMarkerExists(fixture, directory: "used-generations"))
        XCTAssertFalse(legacyMarkerExists(fixture, directory: "revoked-generations"))
    }

    func testLegacyMigrationRejectsFractionalExistingUseMarker() async throws {
        let fixture = try writeLegacyGenerationFixture(suffix: "fractional-use-marker-schema")
        let validated = try QueueManifestValidator.validate(
            fileAt: fixture.manifestURL,
            expectedSHA256: fixture.manifestSHA256,
            hostEvidenceRoot: fixture.hostEvidenceRoot
        )
        try writeImmutableJSON(
            [
                "schema_version": 1.5,
                "generation_id": fixture.generationIdentifier,
                "manifest_sha256": fixture.manifestSHA256,
                "policy_digest": validated.manifest.policyDigest,
                "activated_at": "2026-08-04T05:08:59.475Z"
            ],
            to: legacyMarkerURL(fixture, directory: "used-generations")
        )

        let store = QueueStore(hostEvidenceRoot: fixture.hostEvidenceRoot)
        do {
            _ = try await store.activate(
                fileAt: fixture.manifestURL,
                expectedSHA256: fixture.manifestSHA256
            )
            XCTFail("fractional used-marker schema must fail closed")
        } catch {
            XCTAssertTrue(String(describing: error).contains("USE_MARKER_BINDING_INVALID"))
        }
        XCTAssertFalse(legacyMarkerExists(fixture, directory: "revoked-generations"))
    }

    func testLegacyMigrationSkipsWorkerVolumeForAlreadyRevokedGeneration() async throws {
        let fixture = try writeLegacyGenerationFixture(suffix: "already-revoked-worker-volume")
        let validated = try QueueManifestValidator.validate(
            fileAt: fixture.manifestURL,
            expectedSHA256: fixture.manifestSHA256,
            hostEvidenceRoot: fixture.hostEvidenceRoot
        )
        try writeImmutableJSON(
            [
                "schema_version": 1,
                "generation_id": fixture.generationIdentifier,
                "manifest_sha256": fixture.manifestSHA256,
                "policy_digest": validated.manifest.policyDigest,
                "activated_at": "2026-08-04T05:08:59.475Z"
            ],
            to: legacyMarkerURL(fixture, directory: "used-generations")
        )
        try writeImmutableJSON(
            [
                "schema_version": 1,
                "generation_id": fixture.generationIdentifier,
                "reason": "ITEM_FAILED:ancient-37_5-east",
                "revoked_at": "2026-08-04T05:09:08.551Z"
            ],
            to: legacyMarkerURL(fixture, directory: "revoked-generations")
        )
        let workerRoot = try XCTUnwrap(fixture.failureURL).deletingLastPathComponent()
        for index in 0..<LegacyMigrationFileSystem.maximumWorkerMembers {
            try writeImmutableJSON(
                ["event": "current_generation_evidence", "index": index],
                to: workerRoot.appendingPathComponent("current-\(index).json")
            )
        }

        let store = QueueStore(hostEvidenceRoot: fixture.hostEvidenceRoot)
        do {
            _ = try await store.activate(
                fileAt: fixture.manifestURL,
                expectedSHA256: fixture.manifestSHA256
            )
            XCTFail("an already-revoked generation must remain ineligible")
        } catch {
            let description = String(describing: error)
            XCTAssertTrue(description.contains(
                "GENERATION_REVOKED_REQUIRES_FRESH_IDENTIFIER:\(fixture.generationIdentifier)"
            ))
            XCTAssertFalse(description.contains("WORKER_EVIDENCE_MEMBER_LIMIT_EXCEEDED"))
        }
        XCTAssertTrue(legacyMarkerExists(fixture, directory: "revoked-generations"))
    }

    func testLegacyMigrationScalesWorkerVolumeToValidatedManifest() async throws {
        let hostEvidenceRoot = temporaryDirectory()
            .appendingPathComponent("legacy-production-volume-\(UUID().uuidString)")
        let generationIdentifier = "legacy-production-volume"
        let artifactRoot = hostEvidenceRoot
            .appendingPathComponent(generationIdentifier, isDirectory: true)
        var queue = try nativeRealmProductionQueueObject(
            hostEvidenceRoot: hostEvidenceRoot,
            surface: "Gielinor Surface",
            realmID: "surface-gielinor",
            selectorIndex: 0
        )
        queue["generation_id"] = generationIdentifier
        queue["artifact_root"] = artifactRoot.path
        let baseItem = try XCTUnwrap((queue["items"] as? [[String: Any]])?.first)
        queue["items"] = (0..<300).map { index in
            var item = baseItem
            item["id"] = "native-production-volume-\(index)"
            return item
        }

        let temporaryManifest = try writeQueue(queue)
        let manifestURL = artifactRoot
            .appendingPathComponent("operator", isDirectory: true)
            .appendingPathComponent("\(generationIdentifier).json")
        try writeImmutableData(try Data(contentsOf: temporaryManifest.url), to: manifestURL)
        let manifestSHA256 = AdapterHashing.sha256(try Data(contentsOf: manifestURL))
        try writeImmutableJSON(
            [
                "event": "queue_activated",
                "generation_id": generationIdentifier,
                "manifest_path": manifestURL.path,
                "manifest_sha256": manifestSHA256,
                "recorded_at": "2026-08-04T05:08:59.475Z"
            ],
            to: hostEvidenceRoot
                .appendingPathComponent("events", isDirectory: true)
                .appendingPathComponent("queue-activated-\(generationIdentifier).json")
        )
        let validated = try QueueManifestValidator.validate(
            fileAt: manifestURL,
            expectedSHA256: manifestSHA256,
            hostEvidenceRoot: hostEvidenceRoot
        )
        let workerRoot = artifactRoot
            .appendingPathComponent("worker", isDirectory: true)
            .appendingPathComponent(generationIdentifier, isDirectory: true)
        let assetsRoot = workerRoot.appendingPathComponent("assets", isDirectory: true)
        for item in validated.manifest.items {
            try writeImmutableJSON(
                [
                    "schema_version": 2,
                    "execution_profile": "semantic_map_capture_v1",
                    "generation_id": generationIdentifier,
                    "item_id": item.id,
                    "item_sha256": item.itemSHA256,
                    "result_digest": String(repeating: "a", count: 64)
                ],
                to: workerRoot.appendingPathComponent("\(item.id).json")
            )
            try writeImmutableData(
                Data([0x89, 0x50, 0x4E, 0x47]),
                to: assetsRoot.appendingPathComponent("\(item.id)-map.png")
            )
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: assetsRoot.path
        )

        var freshQueue = try queueObject()
        freshQueue["generation_id"] = "fresh-after-production-volume"
        freshQueue["artifact_root"] = hostEvidenceRoot
            .appendingPathComponent("fresh-output", isDirectory: true).path
        let freshManifest = try writeQueue(freshQueue)
        let store = QueueStore(hostEvidenceRoot: hostEvidenceRoot)
        _ = try await store.activate(
            fileAt: freshManifest.url,
            expectedSHA256: freshManifest.sha256
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: hostEvidenceRoot
            .appendingPathComponent("used-generations", isDirectory: true)
            .appendingPathComponent("\(generationIdentifier).json").path))
    }

    func testLegacyMigrationRejectsFractionalExistingRevocationMarker() async throws {
        let fixture = try writeLegacyGenerationFixture(suffix: "fractional-revocation-marker-schema")
        try writeImmutableJSON(
            [
                "schema_version": 1.5,
                "generation_id": fixture.generationIdentifier,
                "reason": "LEGACY_ITEM_FAILED:ancient-37_5-east",
                "revoked_at": "2026-08-04T05:09:08.551Z"
            ],
            to: legacyMarkerURL(fixture, directory: "revoked-generations")
        )

        let store = QueueStore(hostEvidenceRoot: fixture.hostEvidenceRoot)
        do {
            _ = try await store.activate(
                fileAt: fixture.manifestURL,
                expectedSHA256: fixture.manifestSHA256
            )
            XCTFail("fractional revocation-marker schema must fail closed")
        } catch {
            XCTAssertTrue(String(describing: error).contains("REVOCATION_MARKER_BINDING_INVALID"))
        }
        XCTAssertFalse(legacyMarkerExists(fixture, directory: "used-generations"))
    }

    func testLegacyCancellationEvidenceDurablyRevokesGeneration() async throws {
        let fixture = try writeLegacyGenerationFixture(includeFailure: false)
        let cancellationURL = fixture.hostEvidenceRoot
            .appendingPathComponent("events/queue-canceled-\(fixture.generationIdentifier).json")
        try writeImmutableJSON(
            [
                "event": "queue_canceled",
                "generation_id": fixture.generationIdentifier,
                "recorded_at": "2026-08-04T05:10:00.000Z"
            ],
            to: cancellationURL
        )
        let store = QueueStore(hostEvidenceRoot: fixture.hostEvidenceRoot)

        do {
            _ = try await store.activate(
                fileAt: fixture.manifestURL,
                expectedSHA256: fixture.manifestSHA256
            )
            XCTFail("a proven legacy cancellation must revoke the generation")
        } catch {
            XCTAssertTrue(String(describing: error).contains(
                "GENERATION_REVOKED_REQUIRES_FRESH_IDENTIFIER:\(fixture.generationIdentifier)"
            ))
        }
        let marker = fixture.hostEvidenceRoot
            .appendingPathComponent("revoked-generations/\(fixture.generationIdentifier).json")
        let raw = try jsonObject(at: marker)
        XCTAssertEqual(raw["reason"] as? String, "LEGACY_QUEUE_CANCELED")
    }

    func testBoundCancellationEvidenceCanCloseAPreviouslyFailedGeneration() async throws {
        let fixture = try writeLegacyGenerationFixture(suffix: "bound-cancel-after-failure")
        let validated = try QueueManifestValidator.validate(
            fileAt: fixture.manifestURL,
            expectedSHA256: fixture.manifestSHA256,
            hostEvidenceRoot: fixture.hostEvidenceRoot
        )
        let eventURL = fixture.hostEvidenceRoot
            .appendingPathComponent("events/queue-canceled-\(fixture.generationIdentifier).json")
        try writeImmutableJSON(
            [
                "schema_version": 1,
                "event": "queue_canceled",
                "generation_id": fixture.generationIdentifier,
                "manifest_path": fixture.manifestURL.path,
                "manifest_sha256": fixture.manifestSHA256,
                "policy_digest": validated.manifest.policyDigest,
                "activated_at": "2026-08-04T05:08:59.475Z",
                "cancellation_reason": "QUEUE_CANCELED",
                "recorded_at": "2026-08-04T05:10:00.000Z",
                "prior_item_id": "ancient-37_5-east",
                "prior_next_index": 0,
                "prior_next_action_index": 0,
                "prior_claimed_at": "2026-08-04T05:09:00.000Z",
                "prior_deadline_at": "2026-08-04T05:11:00.000Z",
                "revocation_reason": "ITEM_FAILED:ancient-37_5-east",
                "revoked_at": "2026-08-04T05:09:08.551Z",
                "cancellation_intent_sha256": String(repeating: "a", count: 64)
            ],
            to: eventURL
        )

        try LegacyGenerationStateMigrator(
            evidenceRoot: fixture.hostEvidenceRoot,
            stateStore: EvidenceStore(root: fixture.hostEvidenceRoot)
        ).migrate()
        let revocation = try jsonObject(at: legacyMarkerURL(
            fixture,
            directory: "revoked-generations"
        ))
        XCTAssertEqual(
            revocation["reason"] as? String,
            "ITEM_FAILED:ancient-37_5-east"
        )
        XCTAssertEqual(try fileMode(at: eventURL), 0o444)
    }

    func testHostUIActivationAdoptsExternalManifestBeforePublishingEvidence() async throws {
        let hostEvidenceRoot = temporaryDirectory()
            .appendingPathComponent("host-ui-adoption-\(UUID().uuidString)")
        let generationIdentifier = "host-ui-adoption-generation"
        var queue = try queueObject()
        queue["generation_id"] = generationIdentifier
        queue["artifact_root"] = hostEvidenceRoot
            .appendingPathComponent(generationIdentifier, isDirectory: true).path
        let external = try writeQueue(queue)
        let expectedData = try Data(contentsOf: external.url)
        let store = QueueStore(hostEvidenceRoot: hostEvidenceRoot)

        _ = try await store.activateForHostUI(
            fileAt: external.url,
            expectedSHA256: external.sha256
        )

        let canonical = hostEvidenceRoot
            .appendingPathComponent(generationIdentifier, isDirectory: true)
            .appendingPathComponent("operator", isDirectory: true)
            .appendingPathComponent("\(generationIdentifier).json")
        XCTAssertEqual(try Data(contentsOf: canonical), expectedData)
        XCTAssertEqual(try fileMode(at: canonical), 0o444)
        let activation = try jsonObject(at: hostEvidenceRoot.appendingPathComponent(
            "events/queue-activated-\(generationIdentifier).json"
        ))
        XCTAssertEqual(activation["manifest_path"] as? String, canonical.path)
        XCTAssertEqual(activation["manifest_sha256"] as? String, external.sha256)
    }

    func testLegacyMigrationUsesCanonicalOperatorCopyForExternalActivationPath() throws {
        let fixture = try writeLegacyGenerationFixture(suffix: "external-with-canonical-copy")
        let manifestData = try Data(contentsOf: fixture.manifestURL)
        let outside = temporaryDirectory()
            .appendingPathComponent("outside-legacy-\(UUID().uuidString).json")
        try writeImmutableData(manifestData, to: outside)
        var activation = try jsonObject(at: fixture.activationURL)
        activation["manifest_path"] = outside.path
        try replaceImmutableJSON(activation, at: fixture.activationURL)
        let canonical = fixture.hostEvidenceRoot
            .appendingPathComponent(fixture.generationIdentifier, isDirectory: true)
            .appendingPathComponent("operator", isDirectory: true)
            .appendingPathComponent("\(fixture.generationIdentifier).json")
        try writeImmutableData(manifestData, to: canonical)

        try LegacyGenerationStateMigrator(
            evidenceRoot: fixture.hostEvidenceRoot,
            stateStore: EvidenceStore(root: fixture.hostEvidenceRoot)
        ).migrate()

        XCTAssertTrue(legacyMarkerExists(fixture, directory: "used-generations"))
        XCTAssertTrue(legacyMarkerExists(fixture, directory: "revoked-generations"))
    }

    func testLegacyMigrationRejectsTamperedHashWritableEvidenceAndBindingMismatches() async throws {
        for scenario in [
            "tampered-hash",
            "writable-activation",
            "writable-manifest",
            "writable-failure",
            "generation-mismatch",
            "failure-mismatch",
            "malformed-failure"
        ] {
            let fixture = try writeLegacyGenerationFixture(suffix: scenario)
            switch scenario {
            case "tampered-hash":
                var activation = try jsonObject(at: fixture.activationURL)
                activation["manifest_sha256"] = String(repeating: "0", count: 64)
                try replaceImmutableJSON(activation, at: fixture.activationURL)
            case "writable-activation":
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o644],
                    ofItemAtPath: fixture.activationURL.path
                )
            case "writable-manifest":
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o644],
                    ofItemAtPath: fixture.manifestURL.path
                )
            case "writable-failure":
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o644],
                    ofItemAtPath: try XCTUnwrap(fixture.failureURL).path
                )
            case "generation-mismatch":
                var activation = try jsonObject(at: fixture.activationURL)
                activation["generation_id"] = "different-generation"
                try replaceImmutableJSON(activation, at: fixture.activationURL)
            case "failure-mismatch":
                let failureURL = try XCTUnwrap(fixture.failureURL)
                var failure = try jsonObject(at: failureURL)
                failure["generation_id"] = "different-generation"
                try replaceImmutableJSON(failure, at: failureURL)
            case "malformed-failure":
                let failureURL = try XCTUnwrap(fixture.failureURL)
                var failure = try jsonObject(at: failureURL)
                failure["schema_version"] = 2
                try replaceImmutableJSON(failure, at: failureURL)
            default:
                XCTFail("unexpected scenario")
            }

            let store = QueueStore(hostEvidenceRoot: fixture.hostEvidenceRoot)
            do {
                _ = try await store.activate(
                    fileAt: fixture.manifestURL,
                    expectedSHA256: fixture.manifestSHA256
                )
                XCTFail("legacy migration scenario \(scenario) must fail closed")
            } catch {
                XCTAssertTrue(
                    String(describing: error).contains("QUEUE_REJECTED"),
                    "unexpected \(scenario) error: \(error)"
                )
            }
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: fixture.hostEvidenceRoot
                    .appendingPathComponent("used-generations/\(fixture.generationIdentifier).json").path
            ))
        }
    }

    func testLegacyMigrationRejectsPathEscapeDuplicatesAndMalformedEvidence() async throws {
        for scenario in ["path-escape", "duplicate", "malformed"] {
            let fixture = try writeLegacyGenerationFixture(suffix: scenario)
            switch scenario {
            case "path-escape":
                let outside = temporaryDirectory()
                    .appendingPathComponent("outside-legacy-\(UUID().uuidString).json")
                try Data(contentsOf: fixture.manifestURL).write(to: outside)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o444],
                    ofItemAtPath: outside.path
                )
                var activation = try jsonObject(at: fixture.activationURL)
                activation["manifest_path"] = outside.path
                try replaceImmutableJSON(activation, at: fixture.activationURL)
            case "duplicate":
                let duplicate = fixture.hostEvidenceRoot
                    .appendingPathComponent("events/untrusted-name.json")
                try writeImmutableJSON(try jsonObject(at: fixture.activationURL), to: duplicate)
            case "malformed":
                try replaceImmutableJSON(
                    [
                        "event": "queue_activated",
                        "generation_id": fixture.generationIdentifier
                    ],
                    at: fixture.activationURL
                )
            default:
                XCTFail("unexpected scenario")
            }

            let store = QueueStore(hostEvidenceRoot: fixture.hostEvidenceRoot)
            do {
                _ = try await store.activate(
                    fileAt: fixture.manifestURL,
                    expectedSHA256: fixture.manifestSHA256
                )
                XCTFail("legacy migration scenario \(scenario) must fail closed")
            } catch {
                XCTAssertTrue(String(describing: error).contains(
                    "LEGACY_GENERATION_STATE_MIGRATION_FAILED"
                ))
            }
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: fixture.hostEvidenceRoot
                    .appendingPathComponent("used-generations/\(fixture.generationIdentifier).json").path
            ))
        }
    }

    func testLegacyMigrationMarkerPublicationFailurePreventsQueueAcceptance() async throws {
        for markerKind in ["use", "revocation"] {
            let fixture = try writeLegacyGenerationFixture(suffix: "\(markerKind)-marker-publication")
            let directory = markerKind == "use" ? "used-generations" : "revoked-generations"
            let blockingPath = fixture.hostEvidenceRoot.appendingPathComponent(directory)
            try FileManager.default.createDirectory(
                at: blockingPath,
                withIntermediateDirectories: true
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o555],
                ofItemAtPath: blockingPath.path
            )
            let store = QueueStore(hostEvidenceRoot: fixture.hostEvidenceRoot)

            do {
                _ = try await store.activate(
                    fileAt: fixture.manifestURL,
                    expectedSHA256: fixture.manifestSHA256
                )
                XCTFail("\(markerKind) marker publication failure must prevent activation")
            } catch {
                let expected = markerKind == "use"
                    ? "USE_MARKER_PUBLICATION_FAILED"
                    : "REVOCATION_MARKER_PUBLICATION_FAILED"
                XCTAssertTrue(String(describing: error).contains(expected))
            }
            let snapshot = await store.snapshot()
            XCTAssertNil(snapshot.generationIdentifier)
            let useMarker = fixture.hostEvidenceRoot
                .appendingPathComponent("used-generations/\(fixture.generationIdentifier).json")
            XCTAssertEqual(
                FileManager.default.fileExists(atPath: useMarker.path),
                markerKind == "revocation"
            )
        }
    }

    func testLegacyMigrationRejectsTerminalEvidenceBeforeActivationWithoutPublishingMarkers() async throws {
        for terminalKind in ["failure", "cancellation"] {
            let fixture = try writeLegacyGenerationFixture(
                suffix: "terminal-before-\(terminalKind)",
                includeFailure: terminalKind == "failure"
            )
            if terminalKind == "failure" {
                let failureURL = try XCTUnwrap(fixture.failureURL)
                var failure = try jsonObject(at: failureURL)
                failure["failed_at"] = "2026-08-04T05:08:00.000Z"
                try replaceImmutableJSON(failure, at: failureURL)
            } else {
                try writeImmutableJSON(
                    [
                        "event": "queue_canceled",
                        "generation_id": fixture.generationIdentifier,
                        "recorded_at": "2026-08-04T05:08:00.000Z"
                    ],
                    to: fixture.hostEvidenceRoot.appendingPathComponent(
                        "events/queue-canceled-\(fixture.generationIdentifier).json"
                    )
                )
            }

            let store = QueueStore(hostEvidenceRoot: fixture.hostEvidenceRoot)
            do {
                _ = try await store.activate(
                    fileAt: fixture.manifestURL,
                    expectedSHA256: fixture.manifestSHA256
                )
                XCTFail("\(terminalKind) before activation must fail closed")
            } catch {
                XCTAssertTrue(String(describing: error).contains(
                    "LEGACY_GENERATION_STATE_MIGRATION_FAILED:TERMINAL_PRECEDES_ACTIVATION"
                ))
            }
            XCTAssertFalse(legacyMarkerExists(fixture, directory: "used-generations"))
            XCTAssertFalse(legacyMarkerExists(fixture, directory: "revoked-generations"))
        }
    }

    func testLegacyMigrationBindsEveryExistingMarkerFieldExactly() async throws {
        let useFields: [(String, Any)] = [
            ("schema_version", 2),
            ("generation_id", "different-generation"),
            ("manifest_sha256", String(repeating: "0", count: 64)),
            ("policy_digest", String(repeating: "1", count: 64)),
            ("activated_at", "2026-08-04T05:09:00.000Z")
        ]
        for (field, value) in useFields {
            let fixture = try writeLegacyGenerationFixture(suffix: "use-marker-\(field)")
            let validated = try QueueManifestValidator.validate(
                fileAt: fixture.manifestURL,
                expectedSHA256: fixture.manifestSHA256,
                hostEvidenceRoot: fixture.hostEvidenceRoot
            )
            var marker: [String: Any] = [
                "schema_version": 1,
                "generation_id": fixture.generationIdentifier,
                "manifest_sha256": fixture.manifestSHA256,
                "policy_digest": validated.manifest.policyDigest,
                "activated_at": "2026-08-04T05:08:59.475Z"
            ]
            marker[field] = value
            try writeImmutableJSON(
                marker,
                to: legacyMarkerURL(fixture, directory: "used-generations")
            )

            let store = QueueStore(hostEvidenceRoot: fixture.hostEvidenceRoot)
            do {
                _ = try await store.activate(
                    fileAt: fixture.manifestURL,
                    expectedSHA256: fixture.manifestSHA256
                )
                XCTFail("mismatched used-marker field \(field) must fail closed")
            } catch {
                XCTAssertTrue(String(describing: error).contains("USE_MARKER_BINDING_INVALID"))
            }
            XCTAssertFalse(legacyMarkerExists(fixture, directory: "revoked-generations"))
        }

        let revocationFields: [(String, Any)] = [
            ("schema_version", 2),
            ("generation_id", "different-generation"),
            ("reason", "LEGACY_QUEUE_CANCELED"),
            ("revoked_at", "2026-08-04T05:09:09.000Z")
        ]
        for (field, value) in revocationFields {
            let fixture = try writeLegacyGenerationFixture(suffix: "revocation-marker-\(field)")
            var marker: [String: Any] = [
                "schema_version": 1,
                "generation_id": fixture.generationIdentifier,
                "reason": "LEGACY_ITEM_FAILED:ancient-37_5-east",
                "revoked_at": "2026-08-04T05:09:08.551Z"
            ]
            marker[field] = value
            try writeImmutableJSON(
                marker,
                to: legacyMarkerURL(fixture, directory: "revoked-generations")
            )

            let store = QueueStore(hostEvidenceRoot: fixture.hostEvidenceRoot)
            do {
                _ = try await store.activate(
                    fileAt: fixture.manifestURL,
                    expectedSHA256: fixture.manifestSHA256
                )
                XCTFail("mismatched revoked-marker field \(field) must fail closed")
            } catch {
                XCTAssertTrue(String(describing: error).contains(
                    "REVOCATION_MARKER_BINDING_INVALID"
                ))
            }
            XCTAssertFalse(legacyMarkerExists(fixture, directory: "used-generations"))
        }
    }

    func testLegacyMigrationRejectsBoundedUnsupportedAndOversizedRecords() async throws {
        for scenario in ["fifo", "oversized", "symlink", "excessive-members"] {
            let fixture = try writeLegacyGenerationFixture(suffix: scenario)
            let eventsRoot = fixture.hostEvidenceRoot.appendingPathComponent("events")
            switch scenario {
            case "fifo":
                let fifo = eventsRoot.appendingPathComponent("blocked.json")
                XCTAssertEqual(mkfifo(fifo.path, mode_t(0o444)), 0)
            case "oversized":
                let oversized = eventsRoot.appendingPathComponent("oversized.json")
                let data = Data(
                    repeating: 0x20,
                    count: LegacyMigrationFileSystem.maximumRecordBytes + 1
                )
                try data.write(to: oversized, options: .withoutOverwriting)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o444],
                    ofItemAtPath: oversized.path
                )
            case "symlink":
                try FileManager.default.createSymbolicLink(
                    at: eventsRoot.appendingPathComponent("linked.json"),
                    withDestinationURL: fixture.activationURL
                )
            case "excessive-members":
                for index in 0..<LegacyMigrationFileSystem.maximumEventMembers {
                    var activation = try jsonObject(at: fixture.activationURL)
                    let generationIdentifier = "\(fixture.generationIdentifier)-overflow-\(index)"
                    activation["generation_id"] = generationIdentifier
                    try writeImmutableJSON(
                        activation,
                        to: eventsRoot.appendingPathComponent(
                            "queue-activated-\(generationIdentifier).json"
                        )
                    )
                }
            default:
                XCTFail("unexpected scenario")
            }

            let started = Date()
            let store = QueueStore(hostEvidenceRoot: fixture.hostEvidenceRoot)
            do {
                _ = try await store.activate(
                    fileAt: fixture.manifestURL,
                    expectedSHA256: fixture.manifestSHA256
                )
                XCTFail("\(scenario) must fail closed")
            } catch {
                XCTAssertTrue(String(describing: error).contains(
                    "LEGACY_GENERATION_STATE_MIGRATION_FAILED"
                ))
            }
            XCTAssertLessThan(Date().timeIntervalSince(started), 2.0)
            XCTAssertFalse(legacyMarkerExists(fixture, directory: "used-generations"))
            XCTAssertFalse(legacyMarkerExists(fixture, directory: "revoked-generations"))
        }

        let deviceFileSystem = try LegacyMigrationFileSystem(
            root: URL(fileURLWithPath: "/dev", isDirectory: true)
        )
        XCTAssertThrowsError(try deviceFileSystem.readImmutableRecord(
            at: URL(fileURLWithPath: "/dev/null"),
            code: "DEVICE_PROBE"
        )) { error in
            XCTAssertTrue(String(describing: error).contains("DEVICE_PROBE_NOT_REGULAR"))
        }
    }

    func testLegacyMigrationAllowsUnrelatedImmutableEventsBeyondSemanticLimit() async throws {
        let fixture = try writeLegacyGenerationFixture(
            suffix: "unrelated-event-volume",
            includeFailure: false
        )
        let eventsRoot = fixture.hostEvidenceRoot.appendingPathComponent("events")
        for index in 0..<LegacyMigrationFileSystem.maximumEventMembers {
            try writeImmutableJSON(
                ["event": "worker_terminated", "index": index],
                to: eventsRoot.appendingPathComponent("worker-terminated-\(index).json")
            )
        }

        try LegacyGenerationStateMigrator(
            evidenceRoot: fixture.hostEvidenceRoot,
            stateStore: EvidenceStore(root: fixture.hostEvidenceRoot)
        ).migrate()

        XCTAssertTrue(legacyMarkerExists(fixture, directory: "used-generations"))
        XCTAssertFalse(legacyMarkerExists(fixture, directory: "revoked-generations"))
    }

    func testOperatorManifestPublicationUsesExplicitManifestLimit() throws {
        let root = temporaryDirectory().appendingPathComponent(
            "operator-manifest-publication-\(UUID().uuidString)"
        )
        let destination = root
            .appendingPathComponent("generation", isDirectory: true)
            .appendingPathComponent("operator", isDirectory: true)
            .appendingPathComponent("generation.json")
        let fileSystem = try LegacyMigrationFileSystem(root: root, createRoot: true)
        let data = Data(
            repeating: 0x20,
            count: LegacyMigrationFileSystem.maximumRecordBytes + 1
        )

        XCTAssertThrowsError(try fileSystem.publishImmutableRecord(
            data,
            at: destination,
            code: "GENERIC_RECORD"
        )) { error in
            XCTAssertTrue(String(describing: error).contains("GENERIC_RECORD_TOO_LARGE"))
        }

        XCTAssertTrue(try fileSystem.publishImmutableRecord(
            data,
            at: destination,
            maximumBytes: LegacyMigrationFileSystem.maximumManifestBytes,
            code: "OPERATOR_MANIFEST"
        ))
        XCTAssertEqual(
            try fileSystem.readImmutableRecord(
                at: destination,
                maximumBytes: LegacyMigrationFileSystem.maximumManifestBytes,
                code: "OPERATOR_MANIFEST"
            ),
            data
        )
    }

    func testLegacyMigrationRejectsDescriptorNameSwapBeforeDecoding() throws {
        let fixture = try writeLegacyGenerationFixture(suffix: "descriptor-swap")
        var replacement = try jsonObject(at: fixture.activationURL)
        replacement["generation_id"] = "replacement-generation"
        var replacementData = try JSONSerialization.data(
            withJSONObject: replacement,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        replacementData.append(0x0A)
        let activationURL = fixture.activationURL
        let hooks = LegacyMigrationIOHooks(afterRecordOpen: { openedURL in
            guard openedURL == activationURL else { return }
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: activationURL.path
            )
            try FileManager.default.removeItem(at: activationURL)
            try replacementData.write(to: activationURL, options: .withoutOverwriting)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o444],
                ofItemAtPath: activationURL.path
            )
        })

        XCTAssertThrowsError(try LegacyGenerationStateMigrator(
            evidenceRoot: fixture.hostEvidenceRoot,
            stateStore: EvidenceStore(root: fixture.hostEvidenceRoot),
            hooks: hooks
        ).migrate()) { error in
            XCTAssertTrue(String(describing: error).contains("EVENT_RECORD_NAME_REBOUND"))
        }
        XCTAssertFalse(legacyMarkerExists(fixture, directory: "used-generations"))
        XCTAssertFalse(legacyMarkerExists(fixture, directory: "revoked-generations"))
    }

    func testLegacyMigrationRejectsManifestSwapBeforeDigestValidation() throws {
        let fixture = try writeLegacyGenerationFixture(suffix: "manifest-descriptor-swap")
        let manifestURL = fixture.manifestURL
        let replacementData = Data("{}\n".utf8)
        let hooks = LegacyMigrationIOHooks(afterRecordOpen: { openedURL in
            guard openedURL.path == manifestURL.path else { return }
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: manifestURL.path
            )
            try FileManager.default.removeItem(at: manifestURL)
            try replacementData.write(to: manifestURL, options: .withoutOverwriting)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o444],
                ofItemAtPath: manifestURL.path
            )
        })

        XCTAssertThrowsError(try LegacyGenerationStateMigrator(
            evidenceRoot: fixture.hostEvidenceRoot,
            stateStore: EvidenceStore(root: fixture.hostEvidenceRoot),
            hooks: hooks
        ).migrate()) { error in
            XCTAssertTrue(String(describing: error).contains("LEGACY_MANIFEST_NAME_REBOUND"))
        }
        XCTAssertFalse(legacyMarkerExists(fixture, directory: "used-generations"))
        XCTAssertFalse(legacyMarkerExists(fixture, directory: "revoked-generations"))
    }

    func testLegacyMigrationParentReplacementCannotRedirectMarkerPublication() throws {
        let fixture = try writeLegacyGenerationFixture(suffix: "parent-replacement")
        let usedDirectory = fixture.hostEvidenceRoot.appendingPathComponent("used-generations")
        let outsideDirectory = temporaryDirectory()
            .appendingPathComponent("redirected-used-\(UUID().uuidString)")
        let generationIdentifier = fixture.generationIdentifier
        let hooks = LegacyMigrationIOHooks(beforeMarkerPublish: { destination in
            guard destination.deletingLastPathComponent().path == usedDirectory.path else { return }
            try FileManager.default.moveItem(at: usedDirectory, to: outsideDirectory)
            try FileManager.default.createDirectory(at: usedDirectory, withIntermediateDirectories: false)
        })

        XCTAssertThrowsError(try LegacyGenerationStateMigrator(
            evidenceRoot: fixture.hostEvidenceRoot,
            stateStore: EvidenceStore(root: fixture.hostEvidenceRoot),
            hooks: hooks
        ).migrate()) { error in
            XCTAssertTrue(String(describing: error).contains("USE_MARKER_PUBLICATION_FAILED"))
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: usedDirectory.appendingPathComponent("\(generationIdentifier).json").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: outsideDirectory.appendingPathComponent("\(generationIdentifier).json").path
        ))
    }

    func testLegacyMigrationNoReplacePublicationPreservesRacingMarker() throws {
        let fixture = try writeLegacyGenerationFixture(suffix: "no-replace-race")
        let destination = legacyMarkerURL(fixture, directory: "used-generations")
        let racingMarker: [String: Any] = [
            "schema_version": 1,
            "generation_id": fixture.generationIdentifier,
            "manifest_sha256": String(repeating: "0", count: 64),
            "policy_digest": String(repeating: "1", count: 64),
            "activated_at": "2026-08-04T05:08:59.475Z"
        ]
        var racingBytes = try JSONSerialization.data(
            withJSONObject: racingMarker,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        racingBytes.append(0x0A)
        let hooks = LegacyMigrationIOHooks(beforeMarkerPublish: { markerURL in
            guard markerURL.path == destination.path else { return }
            try racingBytes.write(to: destination, options: .withoutOverwriting)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o444],
                ofItemAtPath: destination.path
            )
        })

        XCTAssertThrowsError(try LegacyGenerationStateMigrator(
            evidenceRoot: fixture.hostEvidenceRoot,
            stateStore: EvidenceStore(root: fixture.hostEvidenceRoot),
            hooks: hooks
        ).migrate()) { error in
            XCTAssertTrue(String(describing: error).contains("USE_MARKER_PUBLICATION_FAILED"))
        }
        XCTAssertEqual(try Data(contentsOf: destination), racingBytes)
        XCTAssertFalse(legacyMarkerExists(fixture, directory: "revoked-generations"))
    }

    func testLaterGenerationRejectsAcceptedIdentifierWithDifferentHash() async throws {
        let store = QueueStore()
        let initial = try writeQueue(try queueObject())
        _ = try await store.activate(fileAt: initial.url, expectedSHA256: initial.sha256)
        let initialClaimValue = try await store.claim()
        let initialClaim = try XCTUnwrap(initialClaimValue)
        _ = try await store.authorize(
            generationIdentifier: "generation-001",
            itemIdentifier: "item-001",
            action: .click(
                captureIdentifier: "capture-001",
                point: AdapterPoint(x: 100, y: 100),
                button: .left
            ),
            requestedEventSourceMode: .privateState,
            requestedDeliveryMode: .foregroundPid
        )
        try await store.recordActionCompleted(
            generationIdentifier: "generation-001",
            itemIdentifier: "item-001"
        )
        let initialResult = try writeWorkerResult(for: initialClaim)
        try await store.complete(
            generationIdentifier: "generation-001",
            itemIdentifier: "item-001",
            success: true,
            resultPath: initialResult.path,
            resultFileSHA256: initialResult.fileSHA256,
            resultDigest: initialResult.resultDigest
        )

        var conflict = try queueObject()
        conflict["generation_id"] = "generation-002"
        var items = conflict["items"] as! [[String: Any]]
        var operations = items[0]["operations"] as! [[String: Any]]
        operations[1]["point"] = ["x": 101, "y": 100]
        items[0]["operations"] = operations
        conflict["items"] = items
        let fixture = try writeQueue(conflict)

        do {
            _ = try await store.activate(fileAt: fixture.url, expectedSHA256: fixture.sha256)
            XCTFail("a completed identifier cannot be rebound to different work")
        } catch {
            XCTAssertTrue(String(describing: error).contains("ITEM_ID_HASH_CONFLICT:item-001"))
        }
    }

    func testAcceptedHistorySurvivesRestartAndPreservesRepairAuthority() async throws {
        let acceptanceRoot = temporaryDirectory()
            .appendingPathComponent("broker-restart-\(UUID().uuidString)")
        let initialObject = try queueObject()
        let initial = try writeQueue(initialObject)
        let firstStore = QueueStore(acceptanceRoot: acceptanceRoot)
        _ = try await firstStore.activate(fileAt: initial.url, expectedSHA256: initial.sha256)
        let initialClaimValue = try await firstStore.claim()
        let claim = try XCTUnwrap(initialClaimValue)
        _ = try await firstStore.authorize(
            generationIdentifier: claim.generationIdentifier,
            itemIdentifier: claim.item.id,
            action: .click(
                captureIdentifier: "capture-001",
                point: AdapterPoint(x: 100, y: 100),
                button: .left
            ),
            requestedEventSourceMode: .privateState,
            requestedDeliveryMode: .foregroundPid
        )
        try await firstStore.recordActionCompleted(
            generationIdentifier: claim.generationIdentifier,
            itemIdentifier: claim.item.id
        )
        let result = try writeWorkerResult(for: claim)
        try await firstStore.complete(
            generationIdentifier: claim.generationIdentifier,
            itemIdentifier: claim.item.id,
            success: true,
            resultPath: result.path,
            resultFileSHA256: result.fileSHA256,
            resultDigest: result.resultDigest
        )

        var duplicateObject = initialObject
        duplicateObject["generation_id"] = "generation-002"
        let duplicate = try writeQueue(duplicateObject)
        let restartedStore = QueueStore(acceptanceRoot: acceptanceRoot)
        _ = try await restartedStore.activate(
            fileAt: duplicate.url,
            expectedSHA256: duplicate.sha256
        )
        let duplicateClaim = try await restartedStore.claim()
        XCTAssertNil(duplicateClaim)

        var repairObject = initialObject
        repairObject["generation_id"] = "generation-003"
        var repairItems = repairObject["items"] as! [[String: Any]]
        repairItems[0]["id"] = "repair-001"
        repairItems[0]["supersedes_item_id"] = "item-001"
        repairItems[0]["repair_lineage"] = ["item-001"]
        repairObject["items"] = repairItems
        let repair = try writeQueue(repairObject)
        _ = try await restartedStore.activate(fileAt: repair.url, expectedSHA256: repair.sha256)
        let repairClaim = try await restartedStore.claim()
        XCTAssertEqual(repairClaim?.item.id, "repair-001")

        let headPath = acceptanceRoot.appendingPathComponent("HEAD.json")
        let headMode = try FileManager.default.attributesOfItem(atPath: headPath.path)[.posixPermissions]
            as? NSNumber
        XCTAssertEqual(headMode?.intValue, 0o600)
        let commitURLs = try FileManager.default.contentsOfDirectory(
            at: acceptanceRoot.appendingPathComponent("commits"),
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(commitURLs.count, 1)
        let commitMode = try FileManager.default.attributesOfItem(
            atPath: try XCTUnwrap(commitURLs.first).path
        )[.posixPermissions] as? NSNumber
        XCTAssertEqual(commitMode?.intValue, 0o444)
    }

    func testResultDigestMismatchFailsClosedBeforeAcceptance() async throws {
        let acceptanceRoot = temporaryDirectory()
            .appendingPathComponent("broker-digest-\(UUID().uuidString)")
        let store = QueueStore(acceptanceRoot: acceptanceRoot)
        let fixture = try makeQueueFixture()
        _ = try await store.activate(fileAt: fixture.url, expectedSHA256: fixture.sha256)
        let claimed = try await store.claim()
        let claim = try XCTUnwrap(claimed)
        _ = try await store.authorize(
            generationIdentifier: "generation-001",
            itemIdentifier: "item-001",
            action: .click(
                captureIdentifier: "capture-001",
                point: AdapterPoint(x: 100, y: 100),
                button: .left
            ),
            requestedEventSourceMode: .privateState,
            requestedDeliveryMode: .foregroundPid
        )
        try await store.recordActionCompleted(
            generationIdentifier: claim.generationIdentifier,
            itemIdentifier: claim.item.id
        )
        let result = try writeWorkerResult(for: claim)
        do {
            try await store.complete(
                generationIdentifier: claim.generationIdentifier,
                itemIdentifier: claim.item.id,
                success: true,
                resultPath: result.path,
                resultFileSHA256: result.fileSHA256,
                resultDigest: String(repeating: "f", count: 64)
            )
            XCTFail("a mismatched semantic result digest must not be accepted")
        } catch {
            XCTAssertTrue(String(describing: error).contains("RESULT_IDENTITY_INVALID"))
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: acceptanceRoot.appendingPathComponent("HEAD.json").path
        ))
    }

    func testMutableWorkerResultFailsClosedBeforeAcceptance() async throws {
        let acceptanceRoot = temporaryDirectory()
            .appendingPathComponent("broker-mode-\(UUID().uuidString)")
        let store = QueueStore(acceptanceRoot: acceptanceRoot)
        let fixture = try makeQueueFixture()
        _ = try await store.activate(fileAt: fixture.url, expectedSHA256: fixture.sha256)
        let claimed = try await store.claim()
        let claim = try XCTUnwrap(claimed)
        _ = try await store.authorize(
            generationIdentifier: "generation-001",
            itemIdentifier: "item-001",
            action: .click(
                captureIdentifier: "capture-001",
                point: AdapterPoint(x: 100, y: 100),
                button: .left
            ),
            requestedEventSourceMode: .privateState,
            requestedDeliveryMode: .foregroundPid
        )
        try await store.recordActionCompleted(
            generationIdentifier: claim.generationIdentifier,
            itemIdentifier: claim.item.id
        )
        let result = try writeWorkerResult(for: claim)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: result.path
        )

        do {
            try await store.complete(
                generationIdentifier: claim.generationIdentifier,
                itemIdentifier: claim.item.id,
                success: true,
                resultPath: result.path,
                resultFileSHA256: result.fileSHA256,
                resultDigest: result.resultDigest
            )
            XCTFail("a mutable worker result must not be accepted")
        } catch {
            XCTAssertTrue(String(describing: error).contains("BROKER_IMMUTABLE_FILE_REQUIRED"))
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: acceptanceRoot.appendingPathComponent("HEAD.json").path
        ))
    }

    func testBrokerAcceptsImmutableInputEvidenceUnderDeclaredHostRoot() async throws {
        let hostEvidenceRoot = temporaryDirectory()
            .appendingPathComponent("host-evidence-\(UUID().uuidString)")
        let store = QueueStore(
            acceptanceRoot: hostEvidenceRoot.appendingPathComponent("broker"),
            hostEvidenceRoot: hostEvidenceRoot
        )
        var queue = try queueObject()
        queue["artifact_root"] = hostEvidenceRoot.appendingPathComponent("worker").path
        let fixture = try writeQueue(queue)
        _ = try await store.activate(fileAt: fixture.url, expectedSHA256: fixture.sha256)
        let claimed = try await store.claim()
        let claim = try XCTUnwrap(claimed)
        _ = try await store.authorize(
            generationIdentifier: "generation-001",
            itemIdentifier: "item-001",
            action: .click(
                captureIdentifier: "capture-001",
                point: AdapterPoint(x: 100, y: 100),
                button: .left
            ),
            requestedEventSourceMode: .privateState,
            requestedDeliveryMode: .foregroundPid
        )
        try await store.recordActionCompleted(
            generationIdentifier: claim.generationIdentifier,
            itemIdentifier: claim.item.id
        )
        let input = try EvidenceStore(root: hostEvidenceRoot).writeImmutable(
            ["outcome": "COMPLETED"],
            relativePath: "input/accepted.json"
        )
        let result = try writeWorkerResult(
            for: claim,
            evidence: [[
                "kind": "click",
                "input_evidence": ["path": input.path, "sha256": input.sha256]
            ]]
        )

        try await store.complete(
            generationIdentifier: claim.generationIdentifier,
            itemIdentifier: claim.item.id,
            success: true,
            resultPath: result.path,
            resultFileSHA256: result.fileSHA256,
            resultDigest: result.resultDigest
        )
        let snapshot = await store.snapshot()
        XCTAssertTrue(snapshot.isDrained)
    }

    func testBrokerRejectsInputEvidenceOutsideDeclaredRoots() async throws {
        let hostEvidenceRoot = temporaryDirectory()
            .appendingPathComponent("host-evidence-\(UUID().uuidString)")
        let outsideRoot = temporaryDirectory()
            .appendingPathComponent("outside-evidence-\(UUID().uuidString)")
        let store = QueueStore(
            acceptanceRoot: hostEvidenceRoot.appendingPathComponent("broker"),
            hostEvidenceRoot: hostEvidenceRoot
        )
        var queue = try queueObject()
        queue["artifact_root"] = hostEvidenceRoot.appendingPathComponent("worker").path
        let fixture = try writeQueue(queue)
        _ = try await store.activate(fileAt: fixture.url, expectedSHA256: fixture.sha256)
        let claimed = try await store.claim()
        let claim = try XCTUnwrap(claimed)
        _ = try await store.authorize(
            generationIdentifier: "generation-001",
            itemIdentifier: "item-001",
            action: .click(
                captureIdentifier: "capture-001",
                point: AdapterPoint(x: 100, y: 100),
                button: .left
            ),
            requestedEventSourceMode: .privateState,
            requestedDeliveryMode: .foregroundPid
        )
        try await store.recordActionCompleted(
            generationIdentifier: claim.generationIdentifier,
            itemIdentifier: claim.item.id
        )
        let input = try EvidenceStore(root: outsideRoot).writeImmutable(
            ["outcome": "COMPLETED"],
            relativePath: "input/rejected.json"
        )
        let result = try writeWorkerResult(
            for: claim,
            evidence: [[
                "kind": "click",
                "input_evidence": ["path": input.path, "sha256": input.sha256]
            ]]
        )

        do {
            try await store.complete(
                generationIdentifier: claim.generationIdentifier,
                itemIdentifier: claim.item.id,
                success: true,
                resultPath: result.path,
                resultFileSHA256: result.fileSHA256,
                resultDigest: result.resultDigest
            )
            XCTFail("input evidence outside both declared roots must be rejected")
        } catch {
            XCTAssertTrue(String(describing: error).contains("INPUT_EVIDENCE_INVALID"))
        }
    }

    func testRepairRejectsUnacceptedSupersededItem() async throws {
        let store = QueueStore()
        var repair = try queueObject()
        repair["generation_id"] = "generation-repair"
        var items = repair["items"] as! [[String: Any]]
        items[0]["id"] = "repair-001"
        items[0]["supersedes_item_id"] = "missing-item"
        items[0]["repair_lineage"] = ["missing-item"]
        repair["items"] = items
        let fixture = try writeQueue(repair)

        do {
            _ = try await store.activate(fileAt: fixture.url, expectedSHA256: fixture.sha256)
            XCTFail("repair work must reference accepted predecessor work")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains("SUPERSEDED_ITEM_NOT_ACCEPTED:missing-item")
            )
        }
    }

    func testEvidenceWriteIsImmutable() throws {
        let root = temporaryDirectory().appendingPathComponent("evidence-\(UUID().uuidString)")
        let store = EvidenceStore(root: root)
        let reference = try store.writeImmutable(
            ["state": "ready"],
            relativePath: "status/ready.json"
        )
        XCTAssertEqual(reference.sha256, try AdapterHashing.sha256(fileAt: URL(fileURLWithPath: reference.path)))
        let attributes = try FileManager.default.attributesOfItem(atPath: reference.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o444)
        XCTAssertThrowsError(try store.writeImmutable(
            ["state": "changed"],
            relativePath: "status/ready.json"
        ))
    }

    func testUnixSocketRoundTrip() async throws {
        let root = temporaryDirectory()
        let socket = root.appendingPathComponent("adapter-\(UUID().uuidString.prefix(8)).sock")
        let server = UnixSocketServer(path: socket.path)
        try server.start { request in
            AdapterResponse(id: request.id, ok: true, state: .readyIdle, message: "ok")
        }
        defer { server.stop() }
        let response = try await Task.detached {
            try UnixSocketClient.send(AdapterRequest(method: "status"), to: socket.path)
        }.value
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.message, "ok")
        let attributes = try FileManager.default.attributesOfItem(atPath: socket.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testUnixSocketStalledPartialRequestDoesNotBlockLaterClient() async throws {
        let root = temporaryDirectory()
        let socket = root.appendingPathComponent("adapter-\(UUID().uuidString.prefix(8)).sock")
        let server = UnixSocketServer(path: socket.path, requestTimeoutMilliseconds: 100)
        try server.start { request in
            AdapterResponse(id: request.id, ok: true, state: .readyIdle, message: "ok")
        }
        defer { server.stop() }

        let stalled = try connectRawUnixSocket(path: socket.path)
        defer { Darwin.close(stalled) }
        var partialRequest: UInt8 = 0x7B
        XCTAssertEqual(Darwin.send(stalled, &partialRequest, 1, 0), 1)

        let started = ContinuousClock.now
        let response = try await Task.detached {
            try UnixSocketClient.send(AdapterRequest(method: "status"), to: socket.path)
        }.value
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.message, "ok")
        XCTAssertLessThan(started.duration(to: .now), .seconds(1))
    }

    func testUnixSocketDisconnectedClientDoesNotTerminateServer() async throws {
        let root = temporaryDirectory()
        let socket = root.appendingPathComponent("adapter-\(UUID().uuidString.prefix(8)).sock")
        let server = UnixSocketServer(path: socket.path)
        try server.start { request in
            try? await Task.sleep(for: .milliseconds(100))
            return AdapterResponse(id: request.id, ok: true, state: .readyIdle, message: "ok")
        }
        defer { server.stop() }

        let disconnected = try connectRawUnixSocket(path: socket.path)
        var request = try JSONEncoder().encode(AdapterRequest(method: "status"))
        request.append(0x0A)
        let sent = request.withUnsafeBytes { raw in
            Darwin.send(disconnected, raw.baseAddress, raw.count, 0)
        }
        XCTAssertEqual(sent, request.count)
        Darwin.shutdown(disconnected, SHUT_RDWR)
        Darwin.close(disconnected)
        try await Task.sleep(for: .milliseconds(200))

        let response = try await Task.detached {
            try UnixSocketClient.send(AdapterRequest(method: "status"), to: socket.path)
        }.value
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.message, "ok")
    }

    func testUnixSocketStopClosesStalledAcceptedClient() async throws {
        let root = temporaryDirectory()
        let socket = root.appendingPathComponent("adapter-\(UUID().uuidString.prefix(8)).sock")
        let server = UnixSocketServer(path: socket.path, requestTimeoutMilliseconds: 5_000)
        try server.start { request in
            AdapterResponse(id: request.id, ok: true, state: .readyIdle)
        }
        let stalled = try connectRawUnixSocket(path: socket.path)
        defer { Darwin.close(stalled) }
        var partialRequest: UInt8 = 0x7B
        XCTAssertEqual(Darwin.send(stalled, &partialRequest, 1, 0), 1)
        try await Task.sleep(for: .milliseconds(20))

        let started = ContinuousClock.now
        server.stop()
        XCTAssertLessThan(started.duration(to: .now), .seconds(1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: socket.path))
    }

    func testInstallTransactionRejectsLiveInstanceLockWithoutReplacement() throws {
        let root = temporaryDirectory().appendingPathComponent("live-install-lock-\(UUID().uuidString)")
        let staging = root.appendingPathComponent("staging.app")
        let destination = root.appendingPathComponent("stable.app")
        let lock = root.appendingPathComponent("adapter.lock")
        try writeReleaseMarker("new", to: staging)
        try writeReleaseMarker("old", to: destination)
        FileManager.default.createFile(atPath: lock.path, contents: Data())
        let descriptor = Darwin.open(lock.path, O_RDWR | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { Darwin.close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        defer { flock(descriptor, LOCK_UN) }

        let result = try runInstallTransaction(
            staging: staging,
            destination: destination,
            lock: lock
        )

        XCTAssertEqual(result.status, 73, result.output)
        XCTAssertEqual(try releaseMarker(at: destination), "old")
        XCTAssertEqual(try releaseMarker(at: staging), "new")
    }

    func testInstallTransactionRollsBackInjectedMidInstallFailure() throws {
        let root = temporaryDirectory().appendingPathComponent("install-rollback-\(UUID().uuidString)")
        let staging = root.appendingPathComponent("staging.app")
        let destination = root.appendingPathComponent("stable.app")
        let lock = root.appendingPathComponent("adapter.lock")
        try writeReleaseMarker("new", to: staging)
        try writeReleaseMarker("old", to: destination)

        let result = try runInstallTransaction(
            staging: staging,
            destination: destination,
            lock: lock
        )

        XCTAssertEqual(result.status, 69, result.output)
        XCTAssertEqual(try releaseMarker(at: destination), "old")
        XCTAssertEqual(try releaseMarker(at: staging), "new")
    }

    func testUnexpectedWorkerTerminationFailsClosed() async {
        let engine = AdapterEngine(
            capabilities: AdapterCapabilities(worker: "worker"),
            evidenceRoot: temporaryDirectory().appendingPathComponent("worker-termination")
        )

        await engine.workerDidTerminate(status: 9)
        let status = await engine.status()

        XCTAssertEqual(status.state, .faulted)
        XCTAssertFalse(status.enabled)
        XCTAssertEqual(status.lastError, "WORKER_TERMINATED:9")
    }

    func testNodeWorkerSupervisorRestartsAfterUnexpectedTermination() async throws {
        let node = URL(fileURLWithPath: "/opt/homebrew/bin/node")
        guard FileManager.default.isExecutableFile(atPath: node.path) else {
            throw XCTSkip("Node 26 is unavailable at the production path")
        }
        let root = temporaryDirectory().appendingPathComponent("worker-restart-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let marker = root.appendingPathComponent("first-run-complete")
        let worker = root.appendingPathComponent("worker.mjs")
        let source = """
        import fs from "node:fs";
        const marker = \(String(reflecting: marker.path));
        if (!fs.existsSync(marker)) {
          fs.writeFileSync(marker, "done");
          process.exit(7);
        }
        setInterval(() => {}, 1000);
        """
        try source.write(to: worker, atomically: true, encoding: .utf8)
        let configuration = NodeWorkerConfiguration(
            nodeExecutable: node,
            workerEntryPoint: worker,
            socketPath: root.appendingPathComponent("unused.sock").path,
            workerCapability: "test-capability",
            logDirectory: root.appendingPathComponent("logs")
        )
        let supervisor = NodeWorkerSupervisor()

        try await supervisor.start(configuration)
        var attempts = 0
        while await supervisor.isRunning(), attempts < 50 {
            try await Task.sleep(for: .milliseconds(20))
            attempts += 1
        }
        let stoppedAfterFailure = await !supervisor.isRunning()
        let firstStatus = await supervisor.lastTerminationStatus
        XCTAssertTrue(stoppedAfterFailure)
        XCTAssertEqual(firstStatus, 7)

        try await supervisor.start(configuration)
        let runningAfterRestart = await supervisor.isRunning()
        XCTAssertTrue(runningAfterRestart)
        await supervisor.stop()
        let stoppedAfterCleanup = await !supervisor.isRunning()
        XCTAssertTrue(stoppedAfterCleanup)
    }

    func testSocketLossFailsClosed() async {
        let engine = AdapterEngine(
            capabilities: AdapterCapabilities(worker: "worker"),
            evidenceRoot: temporaryDirectory().appendingPathComponent("socket-loss")
        )

        await engine.runtimeDidFail(reason: "CONTROL_SOCKET_MISSING")
        let status = await engine.status()

        XCTAssertEqual(status.state, .faulted)
        XCTAssertFalse(status.enabled)
        XCTAssertEqual(status.lastError, "CONTROL_SOCKET_MISSING")
    }

    private func makeQueueFixture() throws -> (url: URL, sha256: String) {
        try writeQueue(try queueObject(), finalize: false)
    }

    private func makeCancellationQueueFixture(
        hostEvidenceRoot: URL,
        generationIdentifier: String
    ) throws -> (url: URL, sha256: String) {
        var queue = try queueObject()
        queue["generation_id"] = generationIdentifier
        queue["artifact_root"] = hostEvidenceRoot
            .appendingPathComponent(generationIdentifier, isDirectory: true).path
        let temporary = try writeQueue(queue)
        let destination = hostEvidenceRoot
            .appendingPathComponent("queue", isDirectory: true)
            .appendingPathComponent("\(generationIdentifier).json")
        let data = try Data(contentsOf: temporary.url)
        try writeImmutableData(data, to: destination)
        return (destination, AdapterHashing.sha256(data))
    }

    private struct LegacyGenerationFixture {
        let hostEvidenceRoot: URL
        let generationIdentifier: String
        let manifestURL: URL
        let manifestSHA256: String
        let activationURL: URL
        let failureURL: URL?
    }

    private enum LegacySchemaBoundary: String, CaseIterable {
        case failure
        case use
        case revocation
    }

    private func legacyMarkerURL(
        _ fixture: LegacyGenerationFixture,
        directory: String
    ) -> URL {
        fixture.hostEvidenceRoot
            .appendingPathComponent(directory, isDirectory: true)
            .appendingPathComponent("\(fixture.generationIdentifier).json")
    }

    private func legacyMarkerExists(
        _ fixture: LegacyGenerationFixture,
        directory: String
    ) -> Bool {
        FileManager.default.fileExists(atPath: legacyMarkerURL(fixture, directory: directory).path)
    }

    private func writeLegacyGenerationFixture(
        suffix: String? = nil,
        includeFailure: Bool = true
    ) throws -> LegacyGenerationFixture {
        let generationIdentifier = "adapter-c3-transition-20260804T044611Z"
            + (suffix.map { "-\($0)" } ?? "")
        let hostEvidenceRoot = temporaryDirectory()
            .appendingPathComponent("legacy-c3-\(suffix ?? "exact")-\(UUID().uuidString)")
        let artifactRoot = hostEvidenceRoot.appendingPathComponent(generationIdentifier)
        var queue = try queueObject()
        queue["generation_id"] = generationIdentifier
        queue["artifact_root"] = artifactRoot.path
        var items = queue["items"] as! [[String: Any]]
        items[0]["id"] = "ancient-37_5-east"
        queue["items"] = items
        let temporaryManifest = try writeQueue(queue)
        let manifestURL = artifactRoot
            .appendingPathComponent("queue")
            .appendingPathComponent("\(generationIdentifier).json")
        try FileManager.default.createDirectory(
            at: manifestURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let manifestData = try Data(contentsOf: temporaryManifest.url)
        try manifestData.write(to: manifestURL, options: .withoutOverwriting)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o444],
            ofItemAtPath: manifestURL.path
        )
        let manifestSHA256 = AdapterHashing.sha256(manifestData)

        let activationURL = hostEvidenceRoot
            .appendingPathComponent("events/queue-activated-\(generationIdentifier).json")
        try writeImmutableJSON(
            [
                "event": "queue_activated",
                "generation_id": generationIdentifier,
                "manifest_path": manifestURL.path,
                "manifest_sha256": manifestSHA256,
                "recorded_at": "2026-08-04T05:08:59.475Z"
            ],
            to: activationURL
        )

        var failureURL: URL?
        if includeFailure {
            let destination = artifactRoot
                .appendingPathComponent("worker")
                .appendingPathComponent(generationIdentifier)
                .appendingPathComponent("ancient-37_5-east-failure.json")
            try writeImmutableJSON(
                [
                    "schema_version": 1,
                    "generation_id": generationIdentifier,
                    "item_id": "ancient-37_5-east",
                    "error": "Error: UNSUPPORTED_OSRS_CAPTURE_ASPECT_RATIO",
                    "evidence": [["kind": "capture"]],
                    "failed_at": "2026-08-04T05:09:08.551Z"
                ],
                to: destination
            )
            failureURL = destination
        }

        return LegacyGenerationFixture(
            hostEvidenceRoot: hostEvidenceRoot,
            generationIdentifier: generationIdentifier,
            manifestURL: manifestURL,
            manifestSHA256: manifestSHA256,
            activationURL: activationURL,
            failureURL: failureURL
        )
    }

    private func writeImmutableJSON(_ value: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var data = try JSONSerialization.data(
            withJSONObject: value,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        data.append(0x0A)
        try data.write(to: url, options: .withoutOverwriting)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o444],
            ofItemAtPath: url.path
        )
    }

    private func installLegacySchemaEvidence(
        for boundary: LegacySchemaBoundary,
        fixture: LegacyGenerationFixture,
        schemaMembers: String
    ) throws {
        switch boundary {
        case .failure:
            let destination = try XCTUnwrap(fixture.failureURL)
            try replaceImmutableData(
                Data(#"""
                {
                  \#(schemaMembers)
                  "generation_id": "\#(fixture.generationIdentifier)",
                  "item_id": "ancient-37_5-east",
                  "error": "Error: schema_version text in a string",
                  "evidence": [{"kind":"capture","nested":{"schema_version":1.5}}],
                  "failed_at": "2026-08-04T05:09:08.551Z"
                }
                """#.utf8),
                at: destination
            )
        case .use:
            let validated = try QueueManifestValidator.validate(
                fileAt: fixture.manifestURL,
                expectedSHA256: fixture.manifestSHA256,
                hostEvidenceRoot: fixture.hostEvidenceRoot
            )
            try writeImmutableData(
                Data(#"""
                {
                  \#(schemaMembers)
                  "generation_id": "\#(fixture.generationIdentifier)",
                  "manifest_sha256": "\#(fixture.manifestSHA256)",
                  "policy_digest": "\#(validated.manifest.policyDigest)",
                  "activated_at": "2026-08-04T05:08:59.475Z"
                }
                """#.utf8),
                to: legacyMarkerURL(fixture, directory: "used-generations")
            )
        case .revocation:
            try writeImmutableData(
                Data(#"""
                {
                  \#(schemaMembers)
                  "generation_id": "\#(fixture.generationIdentifier)",
                  "reason": "LEGACY_ITEM_FAILED:ancient-37_5-east",
                  "revoked_at": "2026-08-04T05:09:08.551Z"
                }
                """#.utf8),
                to: legacyMarkerURL(fixture, directory: "revoked-generations")
            )
        }
    }

    private func assertNoLegacyMarkerPublication(
        for boundary: LegacySchemaBoundary,
        fixture: LegacyGenerationFixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if boundary != .use {
            XCTAssertFalse(
                legacyMarkerExists(fixture, directory: "used-generations"),
                file: file,
                line: line
            )
        }
        if boundary != .revocation {
            XCTAssertFalse(
                legacyMarkerExists(fixture, directory: "revoked-generations"),
                file: file,
                line: line
            )
        }
    }

    private func writeImmutableData(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .withoutOverwriting)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o444],
            ofItemAtPath: url.path
        )
    }

    private func fileMode(at url: URL) throws -> Int {
        let value = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
        return try XCTUnwrap(value as? NSNumber).intValue
    }

    private func replaceImmutableData(_ data: Data, at url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
        try FileManager.default.removeItem(at: url)
        try writeImmutableData(data, to: url)
    }

    private func replaceImmutableJSON(_ value: [String: Any], at url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
        try FileManager.default.removeItem(at: url)
        try writeImmutableJSON(value, to: url)
    }

    private func jsonObject(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func semanticQueueObject(
        hostEvidenceRoot: URL,
        surface: String = SemanticMapSurface.gielinorSurface.rawValue,
        zoomPercent: Double = 75,
        criterionFamily: String = SemanticCriterionFamily.eastwardTopology.rawValue
    ) throws -> [String: Any] {
        let item: [String: Any] = [
            "id": "semantic-item-001",
            "kind": "semantic_map_capture",
            "surface": surface,
            "zoom_percent": zoomPercent,
            "criterion_family": criterionFamily,
            "restore_after_capture": true
        ]
        return [
            "schema_version": 2,
            "execution_profile": "semantic_map_capture_v1",
            "generation_id": "semantic-generation",
            "target_bundle_id": osrsTargetBundleIdentifier,
            "allowed_operations": ["capture", "click", "drag", "open_world_map"],
            "artifact_root": hostEvidenceRoot.appendingPathComponent("worker-output").path,
            "items": [item]
        ]
    }

    private func nativeRealmProductionQueueObject(
        hostEvidenceRoot: URL,
        surface: String,
        realmID: String,
        selectorIndex: Int,
        zoomPercent: Double = 37.5
    ) throws -> [String: Any] {
        let cell = nativeRealmCoverageCellObject(zoomPercent: zoomPercent)
        let item: [String: Any] = [
            "id": "native-production-\(selectorIndex)",
            "kind": "semantic_map_capture",
            "catalog_version": "native-selector-catalog-v4",
            "planner_version": "native-realm-coverage-planner-v1",
            "realm_id": realmID,
            "selector_index": selectorIndex,
            "surface": surface,
            "zoom_percent": zoomPercent,
            "criterion_family": SemanticCriterionFamily.centerDetail.rawValue,
            "restore_after_capture": false,
            "capture_center": nativeRealmCaptureCenterObject(zoomPercent: zoomPercent),
            "coverage_cell": cell
        ]
        return [
            "schema_version": 2,
            "execution_profile": "semantic_map_capture_v1",
            "generation_id": "native-production-generation-\(selectorIndex)",
            "target_bundle_id": osrsTargetBundleIdentifier,
            "allowed_operations": ["capture", "click", "drag", "open_world_map"],
            "artifact_root": hostEvidenceRoot
                .appendingPathComponent("native-production-\(selectorIndex)-output").path,
            "items": [item]
        ]
    }

    private func nativeRealmResetRelativeQueueObject(
        hostEvidenceRoot: URL,
        plannerVersion: String = "native-realm-coverage-planner-v3"
    ) throws -> [String: Any] {
        var cell: [String: Any] = [
            "row": 0,
            "column": 0,
            "realm_bounds": ["min_x": 0, "min_y": 0, "max_x": 3072, "max_y": 2176],
            "capture_bounds": ["min_x": 0, "min_y": 0, "max_x": 1376, "max_y": 1560],
            "viewport": [
                "width": 1376,
                "height": 1560,
                "zoom_percent": 37.5,
                "overlap_fraction": 0.2
            ],
            "coverage_plane": 0,
            "reset_center": ["x": 2237.25, "y": 971.5]
        ]
        if plannerVersion == "native-realm-coverage-planner-v8" {
            cell["anchor_attempt_budget"] = 2
        }
        let item: [String: Any] = [
            "id": "native-production-v3-gielinor-first",
            "kind": "semantic_map_capture",
            "catalog_version": "native-selector-catalog-v4",
            "planner_version": plannerVersion,
            "realm_id": "surface-gielinor",
            "selector_index": 0,
            "surface": "Gielinor Surface",
            "zoom_percent": 37.5,
            "criterion_family": SemanticCriterionFamily.centerDetail.rawValue,
            "restore_after_capture": false,
            "capture_center": ["x": 688, "y": 780],
            "coverage_cell": cell
        ]
        return [
            "schema_version": 2,
            "execution_profile": "semantic_map_capture_v1",
            "generation_id": "native-production-v3-generation",
            "target_bundle_id": osrsTargetBundleIdentifier,
            "allowed_operations": ["capture", "click", "drag", "open_world_map"],
            "artifact_root": hostEvidenceRoot.appendingPathComponent("native-production-v3-output").path,
            "items": [item]
        ]
    }

    private func nativeRealmCoverageCellObject(zoomPercent: Double) -> [String: Any] {
        let viewportWidth = roundedTenth(470 * 100 / zoomPercent)
        let viewportHeight = roundedTenth(560 * 100 / zoomPercent)
        return [
            "row": 0,
            "column": 0,
            "realm_bounds": [
                "min_x": 960,
                "min_y": 2048,
                "max_x": 4032,
                "max_y": 4224
            ],
            "capture_bounds": [
                "min_x": 960,
                "min_y": 2048,
                "max_x": roundedTenth(960 + viewportWidth),
                "max_y": roundedTenth(2048 + viewportHeight)
            ],
            "viewport": [
                "width": viewportWidth,
                "height": viewportHeight,
                "zoom_percent": zoomPercent,
                "overlap_fraction": 0.2
            ]
        ]
    }

    private func nativeRealmCaptureCenterObject(zoomPercent: Double) -> [String: Any] {
        let viewportWidth = roundedTenth(470 * 100 / zoomPercent)
        let viewportHeight = roundedTenth(560 * 100 / zoomPercent)
        return [
            "x": roundedTenth((960 + roundedTenth(960 + viewportWidth)) / 2),
            "y": roundedTenth((2048 + roundedTenth(2048 + viewportHeight)) / 2)
        ]
    }

    private func roundedTenth(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }

    private func semanticCapture(
        _ identifier: String,
        root: URL,
        pixelWidth: Int = 768,
        pixelHeight: Int = 839
    ) throws -> CaptureEvidence {
        let destination = root.appendingPathComponent("captures/\(identifier).png")
        let data = Data("semantic-capture-\(identifier)".utf8)
        try writeImmutableData(data, to: destination)
        return CaptureEvidence(
            captureIdentifier: identifier,
            target: TargetWindowDescriptor(
                bundleIdentifier: osrsTargetBundleIdentifier,
                processIdentifier: 41,
                windowIdentifier: 73,
                title: "Old School RuneScape",
                frame: AdapterRect(x: 0, y: 0, width: 768, height: 839),
                isOnScreen: true
            ),
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            pngPath: destination.path,
            pngSHA256: AdapterHashing.sha256(data),
            capturedAt: "2026-08-05T00:00:00.000Z"
        )
    }

    private func authorizeAndComplete(
        _ store: QueueStore,
        claim: QueueClaim,
        role: SemanticActionRole,
        action: PrivilegedAction,
        capture: CaptureEvidence
    ) async throws {
        let configuration = try await store.authorize(
            generationIdentifier: claim.generationIdentifier,
            itemIdentifier: claim.item.id,
            action: action,
            semanticRole: role,
            capture: capture,
            requestedEventSourceMode: nil,
            requestedDeliveryMode: nil
        )
        XCTAssertEqual(configuration.eventSourceMode, .combinedSessionState)
        XCTAssertEqual(configuration.deliveryMode, .foregroundGlobal)
        try await store.recordActionCompleted(
            generationIdentifier: claim.generationIdentifier,
            itemIdentifier: claim.item.id
        )
    }

    private func resetRelativeCoverageBrokerFixture(
        root: URL,
        deliveredDXOverride: Int? = nil,
        sourceCropLeftOverride: Int? = nil,
        plannerVersion: String = "native-realm-coverage-planner-v3",
        closedRecoveryStateOverride: String? = nil,
        targetContentInformativeOverride: Int? = nil,
        targetContentChromaticOverride: Int? = nil,
        contentEvidenceMode: String = "native_crop_interior_content_v1"
    ) throws -> (
        item: QueueItem,
        artifactRoot: URL,
        resultPath: String,
        resultFileSHA256: String,
        resultDigest: String
    ) {
        let artifactRoot = root.appendingPathComponent("artifacts")
        try FileManager.default.createDirectory(at: artifactRoot, withIntermediateDirectories: true)
        let center = SemanticCaptureCenter(x: 32, y: 64)
        let bounds = SemanticBounds(minX: 0, minY: 0, maxX: 64, maxY: 128)
        let captureBounds = SemanticBounds(minX: -656, minY: -716, maxX: 720, maxY: 844)
        let viewport = SemanticCoverageViewport(
            width: 1376,
            height: 1560,
            zoomPercent: 37.5,
            overlapFraction: 0.2
        )
        let cell = SemanticCoverageCell(
            row: 0,
            column: 0,
            realmBounds: bounds,
            captureBounds: captureBounds,
            viewport: viewport,
            coveragePlane: 1,
            resetCenter: center
        )
        let itemObject: [String: Any] = [
            "id": "native-v3-ancient",
            "kind": "semantic_map_capture",
            "catalog_version": "native-selector-catalog-v4",
            "planner_version": plannerVersion,
            "realm_id": "cache-world-map:ancient-cavern",
            "selector_index": 1,
            "surface": "Ancient Cavern",
            "zoom_percent": 37.5,
            "criterion_family": "center_detail",
            "restore_after_capture": false,
            "capture_center": ["x": 32, "y": 64],
            "coverage_cell": [
                "row": 0,
                "column": 0,
                "realm_bounds": ["min_x": 0, "min_y": 0, "max_x": 64, "max_y": 128],
                "capture_bounds": ["min_x": -656, "min_y": -716, "max_x": 720, "max_y": 844],
                "viewport": [
                    "width": 1376,
                    "height": 1560,
                    "zoom_percent": 37.5,
                    "overlap_fraction": 0.2
                ],
                "coverage_plane": 1,
                "reset_center": ["x": 32, "y": 64]
            ]
        ]
        let itemSHA256 = try CanonicalJSON.sha256(itemObject)
        let item = QueueItem(
            id: "native-v3-ancient",
            kind: "semantic_map_capture",
            itemSHA256: itemSHA256,
            surface: .ancientCavern,
            realmID: "cache-world-map:ancient-cavern",
            catalogVersion: "native-selector-catalog-v4",
            plannerVersion: plannerVersion,
            selectorIndex: 1,
            captureCenter: center,
            coverageCell: cell,
            zoomPercent: 37.5,
            criterionFamily: .centerDetail,
            restoreAfterCapture: false
        )

        func captureObject(_ identifier: String) throws -> [String: Any] {
            let capture = try semanticCapture(identifier, root: artifactRoot)
            let data = try JSONEncoder().encode(capture)
            return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        let resetSelector = try captureObject("v3-reset-selector")
        let resetReady = try captureObject("v3-reset-ready")
        let beforeClose = try captureObject("v9-before-close")
        let closedMap = try captureObject("v9-closed-map")
        let reopenedMap = try captureObject("v9-reopened-map")
        let targetSelector = try captureObject("v3-target-selector")
        let targetReady = try captureObject("v3-target-ready")
        let zoomBefore1 = try captureObject("v3-zoom-before-1")
        let zoomAfter1 = try captureObject("v3-zoom-after-1")
        let zoomBefore2 = try captureObject("v3-zoom-before-2")
        let zoomAfter2 = try captureObject("v3-zoom-after-2")
        let targetFrame = try captureObject("v3-target-frame")
        let freshFrame = try captureObject("v3-fresh-frame")
        func gate(_ surface: String) -> [String: Any] {
            [
                "passed": true,
                "requested_surface": surface,
                "observed_surface": surface,
                "nonblack": true,
                "surface_readback": [
                    "surface": surface,
                    "exact_match": true,
                    "normalized_correlation": 0.91,
                    "correlation_separation": 0.11
                ]
            ]
        }
        func navigation(selectorIndex: Int? = nil) -> [String: Any] {
            var value: [String: Any] = [
                "required": false,
                "mode": NSNull(),
                "anchor": NSNull(),
                "maximum_drags": 0,
                "drags": 0,
                "transitions": []
            ]
            if let selectorIndex {
                value.merge([
                    "catalog_version": "native-selector-catalog-v4",
                    "selector_index": selectorIndex,
                    "visible_top_index": 0,
                    "visible_row_index": selectorIndex,
                    "target_thumb_top": 543
                ]) { _, new in new }
            }
            return value
        }
        func option(
            _ surface: String,
            realmID: String? = nil,
            selectorIndex: Int? = nil
        ) -> [String: Any] {
            var value: [String: Any] = [
                "target": "SEMANTIC_SURFACE_OPTION:\(surface)",
                "exactly_one_target": true,
                "normalized_correlation": 0.93,
                "distinct_second_correlation": 0.80
            ]
            if let realmID, let selectorIndex {
                let top = 533 + selectorIndex * 14
                value.merge([
                    "selector_catalog_version": "native-selector-catalog-v4",
                    "realm_id": realmID,
                    "selector_index": selectorIndex,
                    "visible_top_index": 0,
                    "visible_row_index": selectorIndex,
                    "normalized_observed_bbox": [
                        "left": 166, "top": top, "right": 349, "bottom": top + 14
                    ],
                    "normalized_click_point": ["x": 257, "y": top + 7],
                    "proof_method": "NATIVE_SELECTOR_CATALOG_CONTINUOUS_GEOMETRY_V4"
                ]) { _, new in new }
            }
            return value
        }

        let reopenReset = plannerVersion == "native-realm-coverage-planner-v9"
            || plannerVersion == "native-realm-coverage-planner-v10"
            || plannerVersion == "native-realm-coverage-planner-v11"
        let rolesAndCaptures: [(String, String)] = (reopenReset ? [
            (SemanticActionRole.coverageMapClose.rawValue, "v9-before-close"),
            (SemanticActionRole.coverageMapReopen.rawValue, "v9-closed-map"),
        ] : [
            (SemanticActionRole.coverageResetSelectorOpen.rawValue, "v3-reset-open-action"),
            (SemanticActionRole.coverageResetOptionSelect.rawValue, "v3-reset-selector"),
        ]) + [
            (
                SemanticActionRole.surfaceSelectorOpen.rawValue,
                reopenReset ? "v9-reopened-map" : "v3-reset-ready"
            ),
            (SemanticActionRole.surfaceOptionSelect.rawValue, "v3-target-selector"),
            (SemanticActionRole.zoomMinus.rawValue, "v3-zoom-before-1"),
            (SemanticActionRole.zoomMinus.rawValue, "v3-zoom-before-2"),
        ]
        var actions: [[String: Any]] = []
        for (index, entry) in rolesAndCaptures.enumerated() {
            let inputURL = artifactRoot.appendingPathComponent("input/v3-action-\(index).json")
            let inputData = Data("{\"outcome\":\"COMPLETED\",\"ordinal\":\(index)}\n".utf8)
            try writeImmutableData(inputData, to: inputURL)
            var operation: [String: Any] = ["kind": "click"]
            if entry.0 == SemanticActionRole.coverageMapClose.rawValue {
                operation["point"] = ["x": 500, "y": 50]
                operation["button"] = "left"
            } else if entry.0 == SemanticActionRole.coverageMapReopen.rawValue {
                operation = ["kind": "open_world_map"]
            }
            actions.append([
                "role": entry.0,
                "capture_id": entry.1,
                "operation": operation,
                "input_evidence": ["path": inputURL.path, "sha256": AdapterHashing.sha256(inputData)]
            ])
        }
        let mapURL = artifactRoot.appendingPathComponent("assets/native-v3-ancient-map.png")
        let mapData = Data("native-v3-map-crop".utf8)
        try writeImmutableData(mapData, to: mapURL)

        let requestedWork = itemObject.merging(["item_sha256": itemSHA256]) { current, _ in current }
        var result: [String: Any] = [
            "schema_version": 2,
            "execution_profile": "semantic_map_capture_v1",
            "generation_id": "native-v3-generation",
            "item_id": item.id,
            "item_sha256": itemSHA256,
            "target_identity": [
                "bundle_identifier": osrsTargetBundleIdentifier,
                "process_identifier": 41,
                "window_identifier": 73
            ],
            "requested_work": requestedWork.filter { $0.key != "id" && $0.key != "kind" && $0.key != "item_sha256" },
            "coverage_reset_proof": reopenReset ? [
                "mode": "map_close_reopen",
                "before_close_capture": beforeClose,
                "close_localization": [
                    "target": "SEMANTIC_MAP_CLOSE_CONTROL",
                    "exactly_one_target": true,
                    "normalized_observed_bbox": ["left": 486, "top": 35, "right": 516, "bottom": 70],
                    "normalized_click_point": ["x": 500, "y": 50],
                    "source_click_point": ["x": 500, "y": 50]
                ],
                "closed_capture": closedMap,
                "closed_classification": [
                    "recovery_state": closedRecoveryStateOverride ?? "GAMEPLAY_NO_MAP",
                    "connection": "CONNECTED",
                    "committable": false
                ],
                "reopened_capture": reopenedMap,
                "reopened_gate": gate("Gielinor Surface")
            ] : [
                "reset_surface": "Gielinor Surface",
                "selector_capture": resetSelector,
                "selector_localization": ["target": "SEMANTIC_SURFACE_SELECTOR"],
                "selector_navigation": navigation(),
                "option_capture": resetSelector,
                "option_localization": option("Gielinor Surface"),
                "ready_capture": resetReady,
                "ready_gate": gate("Gielinor Surface")
            ],
            "surface_proof": [
                "requested_surface": "Ancient Cavern",
                "selector_capture": targetSelector,
                "selector_localization": ["target": "SEMANTIC_SURFACE_SELECTOR"],
                "selector_navigation": navigation(selectorIndex: 1),
                "option_capture": targetSelector,
                "option_localization": option(
                    "Ancient Cavern",
                    realmID: "cache-world-map:ancient-cavern",
                    selectorIndex: 1
                ),
                "ready_capture": targetReady,
                "ready_gate": gate("Ancient Cavern")
            ],
            "zoom_proof": [
                "requested_zoom_percent": 37.5,
                "observed_zoom_percent": 37.5,
                "minimum": ["clicks": 2, "consecutive_no_transition_clicks": 2],
                "ascent_clicks": 0,
                "transitions": [
                    [
                        "direction": "minus", "ordinal": 1,
                        "before_capture": zoomBefore1, "after_capture": zoomAfter1,
                        "mean_abs_difference": 0.4, "scale_transition": false
                    ],
                    [
                        "direction": "minus", "ordinal": 2,
                        "before_capture": zoomBefore2, "after_capture": zoomAfter2,
                        "mean_abs_difference": 0.3, "scale_transition": false
                    ]
                ]
            ],
            "coverage_navigation": [
                "planner_version": plannerVersion,
                "mode": reopenReset ? "map_reopen_relative" : "reset_relative",
                "source_center": ["x": 32, "y": 64],
                "target_center": ["x": 32, "y": 64],
                "target_cell": ["row": 0, "column": 0],
                "reference_delta": ["dx": 0, "dy": 0],
                "delivered_reference_delta": ["dx": deliveredDXOverride ?? 0, "dy": 0],
                "target_tolerance_reference_pixels": 10,
                "movement": ["action_count": 0, "transitions": []],
                "target_frame": targetFrame,
                "target_gate": gate("Ancient Cavern"),
                "target_content_proof": [
                    "passed": true,
                    "evidence_mode": contentEvidenceMode,
                    "informative_pixel_count": targetContentInformativeOverride ?? 100,
                    "chromatic_pixel_count": targetContentChromaticOverride ?? 50,
                    "structural_edge_pixel_count": 100,
                    "minimum_informative_pixel_count": 64,
                    "minimum_chromatic_pixel_count": 8,
                    "minimum_structural_edge_pixel_count": 64,
                    "structural_edge_threshold": 3,
                    "interior_margin_pixels": 2
                ],
                "fresh_frame": freshFrame,
                "fresh_gate": gate("Ancient Cavern"),
                "fresh_content_proof": [
                    "passed": true,
                    "evidence_mode": contentEvidenceMode,
                    "informative_pixel_count": 100,
                    "chromatic_pixel_count": 50,
                    "structural_edge_pixel_count": 100,
                    "minimum_informative_pixel_count": 64,
                    "minimum_chromatic_pixel_count": 8,
                    "minimum_structural_edge_pixel_count": 64,
                    "structural_edge_threshold": 3,
                    "interior_margin_pixels": 2
                ],
                "nonblack": true
            ],
            "restoration_proof": ["required": false, "delivered": false],
            "surface_reset_proof": ["required": false, "delivered": false],
            "recovery_history": [],
            "action_history": actions,
            "map_crop": [
                "path": mapURL.path,
                "sha256": AdapterHashing.sha256(mapData),
                "source_crop": [
                    "left": sourceCropLeftOverride ?? 178,
                    "top": 35,
                    "width": 310,
                    "height": 480
                ],
                "width": 310,
                "height": 480
            ],
            "performance": [
                "elapsed_milliseconds": 1_000,
                "input_to_qualified_post_capture_milliseconds": 100,
                "selector_open_to_surface_qualified_milliseconds": 50,
                "hard_deadline_milliseconds": 120_000
            ],
            "completed_at": "2026-08-11T00:00:00.000Z",
            "evidence": []
        ]
        let resultDigest = try CanonicalJSON.sha256(result)
        result["result_digest"] = resultDigest
        let resultURL = artifactRoot
            .appendingPathComponent("worker/native-v3-generation/native-v3-ancient.json")
        try writeImmutableJSON(result, to: resultURL)
        return (
            item,
            artifactRoot,
            resultURL.path,
            AdapterHashing.sha256(try Data(contentsOf: resultURL)),
            resultDigest
        )
    }

    private func semanticBrokerFixture(
        root: URL,
        reuseFreshCapture: Bool,
        measuredForwardDX: Int = -68,
        measuredForwardDY: Int = 0,
        restorationDX: Int = -68,
        restorationDY: Int = 0,
        panAnchorX: Int = 0,
        panAnchorY: Int = 0,
        panProfileFractionPercent: Int = 100,
        retainedInformativePixels: Int = 300,
        expectedForwardDX: Int? = nil,
        expectedForwardDY: Int? = nil,
        includeRecovery: Bool = false,
        nativeRealm: (surface: String, realmID: String, selectorIndex: Int)? = nil,
        requestedRealmIDOverride: String? = nil,
        optionVisibleTopIndexOverride: Int? = nil,
        requestedWorkMutation: ((inout [String: Any]) -> Void)? = nil,
        zoomTransitionMutation: ((inout [[String: Any]]) -> Void)? = nil
    ) throws -> (
        item: QueueItem,
        artifactRoot: URL,
        resultPath: String,
        resultFileSHA256: String,
        resultDigest: String
    ) {
        let artifactRoot = root.appendingPathComponent("artifacts")
        try FileManager.default.createDirectory(at: artifactRoot, withIntermediateDirectories: true)
        let surfaceName = nativeRealm?.surface ?? "Gielinor Surface"
        var itemObject: [String: Any] = [
            "id": "semantic-item-001",
            "kind": "semantic_map_capture",
            "surface": surfaceName,
            "zoom_percent": 75,
            "criterion_family": "eastward_topology",
            "restore_after_capture": true
        ]
        if let nativeRealm {
            itemObject["catalog_version"] = "native-selector-catalog-v4"
            itemObject["planner_version"] = "native-realm-coverage-planner-v1"
            itemObject["realm_id"] = nativeRealm.realmID
            itemObject["selector_index"] = nativeRealm.selectorIndex
            itemObject["capture_center"] = nativeRealmCaptureCenterObject(zoomPercent: 75)
            itemObject["coverage_cell"] = nativeRealmCoverageCellObject(zoomPercent: 75)
        }
        let itemSHA256 = try CanonicalJSON.sha256(itemObject)
        itemObject["item_sha256"] = itemSHA256
        let nativeBounds = SemanticBounds(minX: 960, minY: 2048, maxX: 4032, maxY: 4224)
        let nativeCenter = nativeRealm == nil
            ? nil
            : nativeRealmCaptureCenterObject(zoomPercent: 75)
        let item = QueueItem(
            id: "semantic-item-001",
            kind: "semantic_map_capture",
            itemSHA256: itemSHA256,
            surface: SemanticMapSurface(rawValue: surfaceName),
            realmID: nativeRealm?.realmID,
            catalogVersion: nativeRealm == nil ? nil : "native-selector-catalog-v4",
            plannerVersion: nativeRealm == nil ? nil : "native-realm-coverage-planner-v1",
            selectorIndex: nativeRealm?.selectorIndex,
            captureCenter: nativeCenter.map {
                SemanticCaptureCenter(x: $0["x"] as! Double, y: $0["y"] as! Double)
            },
            coverageCell: nativeRealm == nil ? nil : SemanticCoverageCell(
                row: 0,
                column: 0,
                realmBounds: nativeBounds,
                captureBounds: SemanticBounds(minX: 960, minY: 2048, maxX: 1586.7, maxY: 2794.7),
                viewport: SemanticCoverageViewport(
                    width: 626.7,
                    height: 746.7,
                    zoomPercent: 75,
                    overlapFraction: 0.2
                )
            ),
            zoomPercent: 75,
            criterionFamily: .eastwardTopology,
            restoreAfterCapture: true
        )

        func captureObject(_ identifier: String) throws -> [String: Any] {
            let capture = try semanticCapture(identifier, root: artifactRoot)
            let data = try JSONEncoder().encode(capture)
            return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        let selector = try captureObject("selector")
        let ready = try captureObject("surface-ready")
        let zoomBefore1 = try captureObject("zoom-before-1")
        let zoomAfter1 = try captureObject("zoom-after-1")
        let zoomBefore2 = try captureObject("zoom-before-2")
        let zoomAfter2 = try captureObject("zoom-after-2")
        let pre = try captureObject("pre")
        let post = try captureObject("post")
        let fresh = reuseFreshCapture ? post : try captureObject("fresh")
        let restored = try captureObject("restored")
        let recoveryBefore = includeRecovery ? try captureObject("recovery-before") : nil
        let recoveryAfter = includeRecovery ? try captureObject("recovery-after") : nil

        var gate: [String: Any] = [
            "passed": true,
            "requested_surface": surfaceName,
            "observed_surface": surfaceName,
            "nonblack": true
        ]
        if nativeRealm != nil {
            gate["surface_readback"] = [
                "surface": surfaceName,
                "exact_match": true,
                "normalized_correlation": 0.91,
                "correlation_separation": 0.11
            ]
        }
        let panDeltaX = Int(floor((-340.0 * Double(panProfileFractionPercent) / 100.0) + 0.5))
        let panToX = 430 + panDeltaX
        var forwardVector: [String: Any] = [
            "reference_frame": ["width": 768, "height": 839],
            "reference": ["from": ["x": 430, "y": 300], "to": ["x": 90, "y": 300]],
            "anchor_translation": ["x": panAnchorX, "y": panAnchorY],
            "translated_reference": [
                "from": ["x": 430 + panAnchorX, "y": 300 + panAnchorY],
                "to": ["x": panToX + panAnchorX, "y": 300 + panAnchorY]
            ],
            "delivered": [
                "from": ["x": 430 + panAnchorX, "y": 300 + panAnchorY],
                "to": ["x": panToX + panAnchorX, "y": 300 + panAnchorY]
            ]
        ]
        if panProfileFractionPercent < 100 {
            forwardVector["profile_fraction_percent"] = panProfileFractionPercent
            forwardVector["sparse_retention"] = [
                "strategy": "KEEP_VISIBLE_INFORMATIVE_SUPPORT",
                "profile_fraction_percent": panProfileFractionPercent,
                "projected_displacement_reference": ["x": panDeltaX, "y": 0],
                "original_informative_pixels": 1000,
                "original_chromatic_pixels": 500,
                "retained_informative_pixels": retainedInformativePixels,
                "retained_chromatic_pixels": 150,
                "minimum_retained_informative_pixels": 200,
                "minimum_retained_chromatic_pixels": 100,
                "retained_fraction": Double(retainedInformativePixels) / 1000.0
            ]
        }
        let measuredMagnitude = hypot(Double(measuredForwardDX), Double(measuredForwardDY))
        let restorationToX = 70 - restorationDX * 5
        let restorationToY = 300 - restorationDY * 5
        var inverseVector: [String: Any] = [
            "reference_frame": ["width": 768, "height": 839],
            "measurement_kind": "MEASURED_EFFECTIVE_FORWARD_DISPLACEMENT",
            "displacement_cell_size_reference_pixels": 5,
            "measured_forward_displacement": [
                "dx": measuredForwardDX,
                "dy": measuredForwardDY,
                "error": 0,
                "magnitude_cells": measuredMagnitude,
                "cell_size_reference_pixels": 5
            ],
            "restoration_displacement": [
                "x": restorationDX,
                "y": restorationDY
            ],
            "anchor_proof": [
                "reference_point": ["x": 70, "y": 300],
                "local_informative_pixels": 121,
                "neighborhood_pixels": 121,
                "gradient_risk": 0,
                "selection_strategy": "LOWEST_GRADIENT_NEAREST_FEASIBLE_CENTER"
            ],
            "reference": [
                "from": ["x": 70, "y": 300],
                "to": ["x": restorationToX, "y": restorationToY]
            ],
            "delivered": [
                "from": ["x": 70, "y": 300],
                "to": ["x": restorationToX, "y": restorationToY]
            ]
        ]
        if let expectedForwardDX, let expectedForwardDY {
            inverseVector["expected_forward_displacement"] = [
                "dx": expectedForwardDX,
                "dy": expectedForwardDY
            ]
        }
        var roles = [
            "surface_selector_open", "surface_option_select", "zoom_minus", "zoom_minus",
            "zoom_plus", "zoom_plus", "pan", "restore"
        ]
        if includeRecovery {
            roles.insert(SemanticActionRole.recoveryOpenWorldMap.rawValue, at: 0)
        }
        var actions: [[String: Any]] = []
        for (index, role) in roles.enumerated() {
            let inputURL = artifactRoot.appendingPathComponent("input/action-\(index).json")
            let inputData = Data("{\"outcome\":\"COMPLETED\",\"ordinal\":\(index)}\n".utf8)
            try writeImmutableData(inputData, to: inputURL)
            var operation: [String: Any] = [
                "kind": role == SemanticActionRole.recoveryOpenWorldMap.rawValue
                    ? "open_world_map"
                    : role == "pan" || role == "restore" ? "drag" : "click"
            ]
            if role == "pan" {
                operation["from"] = ["x": 430 + panAnchorX, "y": 300 + panAnchorY]
                operation["to"] = ["x": panToX + panAnchorX, "y": 300 + panAnchorY]
            }
            actions.append([
                "role": role,
                "capture_id": role == SemanticActionRole.recoveryOpenWorldMap.rawValue
                    ? recoveryBefore!["captureIdentifier"] as! String
                    : role == SemanticActionRole.surfaceOptionSelect.rawValue
                        ? selector["captureIdentifier"] as! String
                        : "action-capture-\(index)",
                "operation": operation,
                "input_evidence": ["path": inputURL.path, "sha256": AdapterHashing.sha256(inputData)]
            ])
        }
        let mapURL = artifactRoot.appendingPathComponent("assets/semantic-item-001-map.png")
        let mapData = Data("immutable-map-crop".utf8)
        try writeImmutableData(mapData, to: mapURL)

        var requestedWork: [String: Any] = [
            "surface": surfaceName,
            "zoom_percent": 75,
            "criterion_family": "eastward_topology",
            "restore_after_capture": true
        ]
        if let nativeRealm {
            requestedWork["catalog_version"] = "native-selector-catalog-v4"
            requestedWork["planner_version"] = "native-realm-coverage-planner-v1"
            requestedWork["realm_id"] = requestedRealmIDOverride ?? nativeRealm.realmID
            requestedWork["selector_index"] = nativeRealm.selectorIndex
            requestedWork["capture_center"] = nativeRealmCaptureCenterObject(zoomPercent: 75)
            requestedWork["coverage_cell"] = nativeRealmCoverageCellObject(zoomPercent: 75)
        }
        requestedWorkMutation?(&requestedWork)

        var optionLocalization: [String: Any] = [
            "target": "SEMANTIC_SURFACE_OPTION:\(surfaceName)",
            "exactly_one_target": true,
            "normalized_correlation": 0.91,
            "distinct_second_correlation": 0.80
        ]
        if let nativeRealm {
            let visibleTop = optionVisibleTopIndexOverride ?? 0
            let row = nativeRealm.selectorIndex - visibleTop
            let top = 533 + row * 14
            optionLocalization.merge([
                "selector_catalog_version": "native-selector-catalog-v4",
                "realm_id": nativeRealm.realmID,
                "selector_index": nativeRealm.selectorIndex,
                "visible_top_index": visibleTop,
                "visible_row_index": row,
                "normalized_observed_bbox": [
                    "left": 166, "top": top, "right": 349, "bottom": top + 14
                ],
                "normalized_click_point": ["x": 257, "y": top + 7],
                "proof_method": "NATIVE_SELECTOR_CATALOG_CONTINUOUS_GEOMETRY_V4"
            ]) { _, new in new }
        }

        var selectorNavigation: [String: Any] = [
            "required": false,
            "mode": NSNull(),
            "anchor": NSNull(),
            "maximum_drags": 0,
            "drags": 0,
            "transitions": []
        ]
        if let nativeRealm {
            selectorNavigation.merge([
                "catalog_version": "native-selector-catalog-v4",
                "selector_index": nativeRealm.selectorIndex,
                "visible_top_index": 0,
                "visible_row_index": nativeRealm.selectorIndex,
                "target_thumb_top": 543
            ]) { _, new in new }
        }

        var zoomTransitions: [[String: Any]] = [
            ["direction": "minus", "mean_abs_difference": 0.5, "scale_transition": false, "before_capture": zoomBefore1, "after_capture": zoomAfter1],
            ["direction": "minus", "mean_abs_difference": 0.4, "scale_transition": false, "before_capture": zoomBefore2, "after_capture": zoomAfter2],
            ["direction": "plus", "mean_abs_difference": 1.5, "scale_transition": true, "observed_zoom_percent": 50, "before_capture": zoomAfter1, "after_capture": zoomBefore2],
            ["direction": "plus", "mean_abs_difference": 1.6, "scale_transition": true, "observed_zoom_percent": 75, "before_capture": zoomAfter2, "after_capture": ready]
        ]
        zoomTransitionMutation?(&zoomTransitions)

        var result: [String: Any] = [
            "schema_version": 2,
            "execution_profile": "semantic_map_capture_v1",
            "generation_id": "semantic-generation",
            "item_id": "semantic-item-001",
            "item_sha256": itemSHA256,
            "target_identity": [
                "bundle_identifier": osrsTargetBundleIdentifier,
                "process_identifier": 41,
                "window_identifier": 73
            ],
            "requested_work": requestedWork,
            "surface_proof": [
                "requested_surface": surfaceName,
                "selector_capture": selector,
                "option_capture": selector,
                "selector_navigation": selectorNavigation,
                "option_localization": optionLocalization,
                "ready_capture": ready,
                "ready_gate": gate
            ],
            "zoom_proof": [
                "requested_zoom_percent": 75,
                "observed_zoom_percent": 75,
                "minimum": ["clicks": 2, "consecutive_no_transition_clicks": 2],
                "ascent_clicks": 2,
                "transitions": zoomTransitions
            ],
            "pan_proof": [
                "criterion_family": "eastward_topology",
                "vector": forwardVector,
                "pre_frame": pre,
                "post_frame": post,
                "fresh_frame": fresh,
                "pre_gate": gate,
                "post_gate": gate,
                "fresh_gate": gate,
                "novelty": [
                    "passed": true,
                    "pre_post_mean_abs": 3.5,
                    "same_family_mean_abs": NSNull(),
                    "displacement": [
                        "delivered": true,
                        "magnitude_cells": 3,
                        "expected_displacement": [
                            "dx": expectedForwardDX ?? measuredForwardDX,
                            "dy": expectedForwardDY ?? measuredForwardDY
                        ]
                    ],
                    "extent": ["contribution_mean_abs": 2.5]
                ]
            ],
            "restoration_proof": [
                "required": true,
                "delivered": true,
                "displacement_cells": 0.5,
                "ready": gate,
                "frame": restored,
                "measured_forward_displacement": [
                    "dx": measuredForwardDX,
                    "dy": measuredForwardDY,
                    "error": 0,
                    "magnitude_cells": measuredMagnitude,
                    "cell_size_reference_pixels": 5
                ],
                "inverse_vector": inverseVector
            ],
            "surface_reset_proof": [
                "required": false,
                "delivered": false
            ],
            "recovery_history": includeRecovery ? [[
                "ordinal": 1,
                "state": "GAMEPLAY_NO_MAP",
                "observed_state": "MAP_READY",
                "action_role": SemanticActionRole.recoveryOpenWorldMap.rawValue,
                "before_capture": recoveryBefore!,
                "after_capture": recoveryAfter!,
                "before_classification": ["recovery_state": "GAMEPLAY_NO_MAP"],
                "after_classification": [
                    "connection": "CONNECTED",
                    "map_shell": "FLOATING_MAP_OPEN",
                    "overlay": "NONE",
                    "map_content": "NONBLACK_CONTENT",
                    "committable": true
                ]
            ]] : [],
            "action_history": actions,
            "map_crop": [
                "path": mapURL.path,
                "sha256": AdapterHashing.sha256(mapData),
                "width": 516,
                "height": 641
            ],
            "performance": [
                "elapsed_milliseconds": 12_000,
                "input_to_qualified_post_capture_milliseconds": 1_500,
                "selector_open_to_surface_qualified_milliseconds": 500,
                "hard_deadline_milliseconds": 120_000
            ]
        ]
        let resultDigest = try CanonicalJSON.sha256(result)
        result["result_digest"] = resultDigest
        let resultURL = artifactRoot
            .appendingPathComponent("worker/semantic-generation/semantic-item-001.json")
        try writeImmutableJSON(result, to: resultURL)
        let resultData = try Data(contentsOf: resultURL)
        return (
            item,
            artifactRoot,
            resultURL.path,
            AdapterHashing.sha256(resultData),
            resultDigest
        )
    }

    private func writeWorkerResult(
        for claim: QueueClaim,
        evidence: [[String: Any]] = [["kind": "test_evidence"]]
    ) throws -> (path: String, fileSHA256: String, resultDigest: String) {
        var result: [String: Any] = [
            "schema_version": 1,
            "generation_id": claim.generationIdentifier,
            "item_id": claim.item.id,
            "item_sha256": claim.item.itemSHA256,
            "started_at": "2026-08-01T00:00:00.000Z",
            "completed_at": "2026-08-01T00:00:01.000Z",
            "evidence": evidence
        ]
        let resultDigest = try CanonicalJSON.sha256(result)
        result["result_digest"] = resultDigest
        var data = try JSONSerialization.data(
            withJSONObject: result,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        data.append(0x0A)
        let destination = URL(fileURLWithPath: claim.artifactRoot)
            .appendingPathComponent("worker")
            .appendingPathComponent(claim.generationIdentifier)
            .appendingPathComponent("\(claim.item.id).json")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: destination, options: .withoutOverwriting)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o444],
            ofItemAtPath: destination.path
        )
        return (destination.path, AdapterHashing.sha256(data), resultDigest)
    }

    private func queueObject() throws -> [String: Any] {
        var item: [String: Any] = [
            "id": "item-001",
            "kind": "lab",
            "operations": [
                ["kind": "capture"],
                [
                    "kind": "click",
                    "point": ["x": 100, "y": 100],
                    "button": "left",
                    "event_source_mode": "private_state",
                    "delivery_mode": "foreground_pid"
                ]
            ]
        ]
        item["item_sha256"] = try CanonicalJSON.sha256(item)
        var queue: [String: Any] = [
            "schema_version": 1,
            "generation_id": "generation-001",
            "target_kind": "lab",
            "target_title_contains": "Explorer Adapter Lab Target",
            "allowed_operations": ["capture", "click", "drag"],
            "artifact_root": temporaryDirectory()
                .appendingPathComponent("artifacts-\(UUID().uuidString)").path,
            "items": [item]
        ]
        queue["policy_digest"] = try CanonicalJSON.sha256(queue)
        return queue
    }

    private func writeQueue(
        _ input: [String: Any],
        finalize: Bool = true
    ) throws -> (url: URL, sha256: String) {
        var queue = input
        if finalize {
            if var items = queue["items"] as? [[String: Any]] {
                for index in items.indices {
                    items[index].removeValue(forKey: "item_sha256")
                    items[index]["item_sha256"] = try CanonicalJSON.sha256(items[index])
                }
                queue["items"] = items
            }
            queue.removeValue(forKey: "policy_digest")
            queue["policy_digest"] = try CanonicalJSON.sha256(queue)
        }
        let data = try JSONSerialization.data(withJSONObject: queue, options: [.prettyPrinted, .sortedKeys])
        let url = temporaryDirectory().appendingPathComponent("queue-\(UUID().uuidString).json")
        try data.write(to: url)
        return (url, AdapterHashing.sha256(data))
    }

    private func temporaryDirectory() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("osrs-explorer-adapter-tests", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeReleaseMarker(_ value: String, to app: URL) throws {
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try value.write(to: app.appendingPathComponent("release"), atomically: true, encoding: .utf8)
    }

    private func releaseMarker(at app: URL) throws -> String {
        try String(contentsOf: app.appendingPathComponent("release"), encoding: .utf8)
    }

    private func runInstallTransaction(
        staging: URL,
        destination: URL,
        lock: URL
    ) throws -> (status: Int32, output: String) {
        let adapterRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        process.arguments = [
            adapterRoot.appendingPathComponent("scripts/install-transaction.swift").path,
            staging.path,
            destination.path,
            lock.path,
            adapterRoot.appendingPathComponent("scripts/verify-installed-bundle.mjs").path,
            "/opt/homebrew/bin/node",
            "/tmp/build",
            adapterRoot.path,
            String(repeating: "a", count: 40),
            "/tmp/signing-policy.json",
            "--inject-post-swap-failure"
        ]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }

    private func connectRawUnixSocket(path: String) throws -> Int32 {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw AdapterError.backgroundUnsupported("TEST_SOCKET_CREATE")
        }
        do {
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8) + [0]
            let capacity = MemoryLayout.size(ofValue: address.sun_path)
            guard bytes.count <= capacity else {
                throw AdapterError.malformedRequest("SOCKET_PATH_TOO_LONG")
            }
            withUnsafeMutableBytes(of: &address.sun_path) { raw in
                raw.initializeMemory(as: UInt8.self, repeating: 0)
                bytes.withUnsafeBytes { raw.copyBytes(from: $0) }
            }
            let length = socklen_t(MemoryLayout<sa_family_t>.size + bytes.count)
            address.sun_len = UInt8(length)
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, length)
                }
            }
            guard connected == 0 else {
                throw AdapterError.backgroundUnsupported("TEST_SOCKET_CONNECT")
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }
}

private final class TestClock: @unchecked Sendable {
    var value: Date

    init(_ value: Date) {
        self.value = value
    }
}

private struct InjectedCancellationFailure: Error {}
