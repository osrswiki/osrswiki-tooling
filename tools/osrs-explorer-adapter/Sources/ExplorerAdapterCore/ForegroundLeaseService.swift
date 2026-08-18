import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

public struct ForegroundRestorationStep: Codable, Sendable {
    public let processIdentifier: Int32
    public let activationSucceeded: Bool
    public let becameFrontmost: Bool
    public let windowOwnerBecameLeading: Bool
    public let failure: String?
}

public struct ForegroundLeaseEvidence: Codable, Sendable {
    public let leaseIdentifier: String
    public let deliveryMode: InputDeliveryMode
    public let previousProcessIdentifier: Int32
    public let targetProcessIdentifier: Int32
    public let startedAt: String
    public let completedAt: String
    public let durationMilliseconds: Double
    public let before: FocusInvariantSnapshot
    public let targetActive: FocusInvariantSnapshot?
    public let after: FocusInvariantSnapshot
    public let targetActivationSucceeded: Bool
    public let priorApplicationRestored: Bool
    public let cursorRestored: Bool
    public let activeSpacePreserved: Bool
    public let windowOrderRestored: Bool
    public let targetWindowRankRestored: Bool
    public let restorableTargetWindowRankRestored: Bool
    public let restorationPlan: [Int32]
    public let restorationSteps: [ForegroundRestorationStep]
    public let userInterferenceReason: String?
    public let restorationInvariant: FocusInvariantResult
    public let failure: String?
}

struct ForegroundLeaseExecution: Sendable {
    let evidence: ForegroundLeaseEvidence
    let failure: String?
}

public struct ForegroundLeaseService: Sendable {
    private let monitor: FocusInvariantMonitor

    public init(monitor: FocusInvariantMonitor) {
        self.monitor = monitor
    }

    func perform(
        target: TargetWindowDescriptor,
        deliveryMode: InputDeliveryMode,
        cancellationGate: InputCancellationGate,
        operation: @Sendable () async throws -> Void
    ) async -> ForegroundLeaseExecution {
        let leaseIdentifier = UUID().uuidString.lowercased()
        let startedAt = AdapterClock.now()
        let started = DispatchTime.now().uptimeNanoseconds
        let before = monitor.snapshot(targetWindowIdentifier: target.windowIdentifier)
        let previousProcessIdentifier = before.frontmostProcessIdentifier ?? 0
        var targetActive: FocusInvariantSnapshot?
        var failure: String?
        var activationSucceeded = false
        var restorationSteps: [ForegroundRestorationStep] = []
        let restorationPlan = before.uniqueRestorableProcessIdentifiersAboveTarget(
            excluding: [target.processIdentifier]
        )
        let unrestorableProcessIdentifiers = await unrestorableProcessIdentifiers(
            in: restorationPlan
        )
        do {
            try cancellationGate.checkValid()
        } catch {
            failure = String(describing: error)
        }

        if failure != nil {
            // Restoration still runs below if activation began before cancellation.
        } else if previousProcessIdentifier == 0 {
            failure = "PRIOR_FRONTMOST_APPLICATION_UNKNOWN"
        } else if previousProcessIdentifier == target.processIdentifier {
            failure = "TARGET_ALREADY_FRONTMOST_NO_RESTORE_ANCHOR"
        } else if !target.isOnScreen {
            failure = "TARGET_NOT_ON_CURRENT_SPACE"
        } else if !unrestorableProcessIdentifiers.isEmpty {
            failure = "UNRESTORABLE_WINDOW_OWNER_PIDS:\(unrestorableProcessIdentifiers.map(String.init).joined(separator: ","))"
        } else {
            do {
                try cancellationGate.checkValid()
                let activated = await activate(target: target)
                try cancellationGate.checkValid()
                guard activated else {
                    throw AdapterError.actionNotAllowed("TARGET_ACTIVATION_FAILED")
                }
                try await waitForFrontmost(
                    processIdentifier: target.processIdentifier,
                    cancellationGate: cancellationGate
                )
                try await waitForLeadingApplicationWindow(
                    processIdentifier: target.processIdentifier,
                    targetWindowIdentifier: target.windowIdentifier,
                    cancellationGate: cancellationGate
                )
                targetActive = monitor.snapshot(targetWindowIdentifier: target.windowIdentifier)
                guard targetActive?.frontmostProcessIdentifier == target.processIdentifier else {
                    throw AdapterError.actionNotAllowed("TARGET_DID_NOT_BECOME_FRONTMOST")
                }
                guard targetActive?.focusedProcessIdentifier == target.processIdentifier else {
                    throw AdapterError.actionNotAllowed("TARGET_DID_NOT_BECOME_FOCUSED")
                }
                guard targetActive?.activeSpaceChangeCount == before.activeSpaceChangeCount else {
                    throw AdapterError.actionNotAllowed("ACTIVE_SPACE_CHANGED_DURING_ACTIVATION")
                }
                activationSucceeded = true
                try cancellationGate.checkValid()
                try await operation()
                try cancellationGate.checkValid()
            } catch {
                failure = String(describing: error)
            }
        }

        try? await Task.sleep(for: .milliseconds(20))
        let interferenceReason = cancellationGate.currentInvalidReason()

        let currentFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if currentFrontmost == target.processIdentifier {
            for processIdentifier in restorationPlan.reversed() {
                let step = await restore(
                    processIdentifier: processIdentifier,
                    targetWindowIdentifier: target.windowIdentifier,
                    requireLeadingWindow: true
                )
                restorationSteps.append(step)
            }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != previousProcessIdentifier {
                let step = await restore(
                    processIdentifier: previousProcessIdentifier,
                    targetWindowIdentifier: target.windowIdentifier,
                    requireLeadingWindow: false
                )
                restorationSteps.append(step)
            }
        } else if currentFrontmost != previousProcessIdentifier {
            failure = append(failure, "EXTERNAL_FRONTMOST_CHANGE_DURING_LEASE")
        }

        if deliveryMode == .foregroundGlobal {
            let expected = CGPoint(x: before.cursor.x, y: before.cursor.y)
            do {
                try CursorRestorationRunner.restoreIfAuthorized(
                    cancellationGate: cancellationGate,
                    expectedPosition: expected,
                    currentPosition: { CGEvent(source: nil)?.location ?? .zero },
                    restore: { _ = CGWarpMouseCursorPosition($0) }
                )
            } catch {
                failure = append(failure, "CURSOR_RESTORATION_DENIED:\(error)")
            }
        }

        let after = await waitForRestoration(
            before: before,
            targetWindowIdentifier: target.windowIdentifier
        )
        let restoration = monitor.evaluateForegroundRestoration(before: before, after: after)
        failure = Self.finalRestorationFailure(
            existingFailure: failure,
            restorationSteps: restorationSteps,
            restoration: restoration
        )
        if let interferenceReason {
            failure = append(failure, "USER_INTERFERENCE:\(interferenceReason)")
        }
        let completed = DispatchTime.now().uptimeNanoseconds
        let duration = Double(completed - started) / 1_000_000
        let evidence = ForegroundLeaseEvidence(
            leaseIdentifier: leaseIdentifier,
            deliveryMode: deliveryMode,
            previousProcessIdentifier: previousProcessIdentifier,
            targetProcessIdentifier: target.processIdentifier,
            startedAt: startedAt,
            completedAt: AdapterClock.now(),
            durationMilliseconds: duration,
            before: before,
            targetActive: targetActive,
            after: after,
            targetActivationSucceeded: activationSucceeded,
            priorApplicationRestored: FocusInvariantMonitor
                .frontmostProcessRestorationPreserved(before: before, after: after)
                && FocusInvariantMonitor.focusedProcessRestorationPreserved(
                    before: before,
                    after: after
                ),
            cursorRestored: FocusInvariantMonitor.cursorPositionsEquivalent(
                before.cursor,
                after.cursor
            ),
            activeSpacePreserved: after.activeSpaceChangeCount == before.activeSpaceChangeCount,
            windowOrderRestored: after.orderedWindowIdentifiers == before.orderedWindowIdentifiers,
            targetWindowRankRestored: FocusInvariantMonitor.targetWindowPositionPreserved(
                beforeIdentifiers: before.orderedWindowIdentifiers,
                beforeRank: before.targetWindowRank,
                afterIdentifiers: after.orderedWindowIdentifiers,
                afterRank: after.targetWindowRank
            ),
            restorableTargetWindowRankRestored: FocusInvariantMonitor
                .restorationTargetPositionPreserved(before: before, after: after),
            restorationPlan: restorationPlan,
            restorationSteps: restorationSteps,
            userInterferenceReason: interferenceReason,
            restorationInvariant: restoration,
            failure: failure
        )
        return ForegroundLeaseExecution(evidence: evidence, failure: failure)
    }

    @MainActor
    private func activate(target: TargetWindowDescriptor) -> Bool {
        guard activate(processIdentifier: target.processIdentifier) else { return false }
        let application = AXUIElementCreateApplication(target.processIdentifier)
        _ = AXUIElementSetAttributeValue(
            application,
            kAXFrontmostAttribute as CFString,
            kCFBooleanTrue
        )
        _ = Self.raiseTargetWindow(in: application, target: target)
        return true
    }

    @MainActor
    private func activate(processIdentifier: Int32) -> Bool {
        NSRunningApplication(processIdentifier: processIdentifier)?.activate(
            options: [.activateAllWindows]
        ) == true
    }

    private static func raiseTargetWindow(
        in application: AXUIElement,
        target: TargetWindowDescriptor
    ) -> Bool {
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXWindowsAttribute as CFString,
            &windowsValue
        ) == .success,
        let windows = windowsValue as? [AXUIElement],
        let window = windows.first(where: {
            targetWindowMatches(
                title: stringAttribute($0, name: kAXTitleAttribute),
                frame: frame(of: $0),
                target: target
            )
        }) else {
            return false
        }
        return AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success
    }

    static func targetWindowMatches(
        title: String?,
        frame: CGRect?,
        target: TargetWindowDescriptor
    ) -> Bool {
        guard title == target.title, let frame else { return false }
        let expected = target.frame.cgRect
        return abs(frame.minX - expected.minX) <= 1
            && abs(frame.minY - expected.minY) <= 1
            && abs(frame.width - expected.width) <= 1
            && abs(frame.height - expected.height) <= 1
    }

    private static func stringAttribute(
        _ element: AXUIElement,
        name: String
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            name as CFString,
            &value
        ) == .success else { return nil }
        return value as? String
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXPositionAttribute as CFString,
            &positionValue
        ) == .success,
        AXUIElementCopyAttributeValue(
            element,
            kAXSizeAttribute as CFString,
            &sizeValue
        ) == .success,
        let positionValue,
        let sizeValue,
        CFGetTypeID(positionValue) == AXValueGetTypeID(),
        CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: point, size: size)
    }

    private func waitForFrontmost(
        processIdentifier: Int32,
        cancellationGate: InputCancellationGate
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + 800_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            try cancellationGate.checkValid()
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier { return }
            try await Task.sleep(for: .milliseconds(10))
            try cancellationGate.checkValid()
        }
        throw AdapterError.actionNotAllowed("FOREGROUND_ACTIVATION_TIMEOUT")
    }

    private func waitForFrontmostWithoutCancellation(processIdentifier: Int32) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + 800_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private func waitForLeadingApplicationWindow(
        processIdentifier: Int32,
        targetWindowIdentifier: UInt32,
        cancellationGate: InputCancellationGate
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + 800_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            try cancellationGate.checkValid()
            let snapshot = monitor.snapshot(targetWindowIdentifier: targetWindowIdentifier)
            if snapshot.orderedRestorableWindowProcessIdentifiers.first == processIdentifier {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
            try cancellationGate.checkValid()
        }
        throw AdapterError.actionNotAllowed("FOREGROUND_WINDOW_ORDER_TIMEOUT")
    }

    private func waitForLeadingApplicationWindowWithoutCancellation(
        processIdentifier: Int32,
        targetWindowIdentifier: UInt32
    ) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + 800_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            let snapshot = monitor.snapshot(targetWindowIdentifier: targetWindowIdentifier)
            if snapshot.orderedRestorableWindowProcessIdentifiers.first == processIdentifier {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    @MainActor
    private func unrestorableProcessIdentifiers(in processIdentifiers: [Int32]) -> [Int32] {
        let adapterProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        return processIdentifiers.filter { processIdentifier in
            guard processIdentifier != adapterProcessIdentifier,
                  let application = NSRunningApplication(processIdentifier: processIdentifier) else {
                return true
            }
            return application.isTerminated
        }
    }

    private func restore(
        processIdentifier: Int32,
        targetWindowIdentifier: UInt32,
        requireLeadingWindow: Bool
    ) async -> ForegroundRestorationStep {
        guard await activate(processIdentifier: processIdentifier) else {
            return ForegroundRestorationStep(
                processIdentifier: processIdentifier,
                activationSucceeded: false,
                becameFrontmost: false,
                windowOwnerBecameLeading: false,
                failure: "RESTORATION_ACTIVATION_FAILED:\(processIdentifier)"
            )
        }
        let becameFrontmost = await waitForFrontmostWithoutCancellation(
            processIdentifier: processIdentifier
        )
        let windowOwnerBecameLeading: Bool
        if requireLeadingWindow {
            windowOwnerBecameLeading = await waitForLeadingApplicationWindowWithoutCancellation(
                processIdentifier: processIdentifier,
                targetWindowIdentifier: targetWindowIdentifier
            )
        } else {
            windowOwnerBecameLeading = true
        }
        let failure: String?
        if !becameFrontmost {
            failure = "RESTORATION_FRONTMOST_TIMEOUT:\(processIdentifier)"
        } else if !windowOwnerBecameLeading {
            failure = "RESTORATION_WINDOW_ORDER_TIMEOUT:\(processIdentifier)"
        } else {
            failure = nil
        }
        return ForegroundRestorationStep(
            processIdentifier: processIdentifier,
            activationSucceeded: true,
            becameFrontmost: becameFrontmost,
            windowOwnerBecameLeading: windowOwnerBecameLeading,
            failure: failure
        )
    }

    private func waitForRestoration(
        before: FocusInvariantSnapshot,
        targetWindowIdentifier: UInt32
    ) async -> FocusInvariantSnapshot {
        let deadline = DispatchTime.now().uptimeNanoseconds + 400_000_000
        var snapshot = monitor.snapshot(targetWindowIdentifier: targetWindowIdentifier)
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if monitor.evaluateForegroundRestoration(before: before, after: snapshot).passed {
                return snapshot
            }
            try? await Task.sleep(for: .milliseconds(10))
            snapshot = monitor.snapshot(targetWindowIdentifier: targetWindowIdentifier)
        }
        return snapshot
    }

    private func append(_ existing: String?, _ value: String) -> String {
        existing.map { "\($0);\(value)" } ?? value
    }

    static func finalRestorationFailure(
        existingFailure: String?,
        restorationSteps: [ForegroundRestorationStep],
        restoration: FocusInvariantResult
    ) -> String? {
        guard !restoration.passed else { return existingFailure }
        let stepFailures = restorationSteps.compactMap(\.failure)
        return (stepFailures + restoration.violations).reduce(existingFailure) { failure, reason in
            failure.map { "\($0);\(reason)" } ?? reason
        }
    }
}
