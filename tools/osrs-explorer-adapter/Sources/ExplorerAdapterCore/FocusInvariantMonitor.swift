import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

public struct FocusInvariantSnapshot: Codable, Equatable, Sendable {
    public let capturedAt: String
    public let frontmostProcessIdentifier: Int32?
    public let focusedProcessIdentifier: Int32?
    public let cursor: AdapterPoint
    public let orderedWindowIdentifiers: [UInt32]
    public let orderedWindowProcessIdentifiers: [Int32]
    public let orderedRestorableWindowIdentifiers: [UInt32]
    public let orderedRestorableWindowProcessIdentifiers: [Int32]
    public let targetWindowRank: Int?
    public let targetRestorableWindowRank: Int?
    public let activeSpaceChangeCount: UInt64

    public init(
        capturedAt: String,
        frontmostProcessIdentifier: Int32?,
        focusedProcessIdentifier: Int32?,
        cursor: AdapterPoint,
        orderedWindowIdentifiers: [UInt32],
        orderedWindowProcessIdentifiers: [Int32] = [],
        orderedRestorableWindowIdentifiers: [UInt32] = [],
        orderedRestorableWindowProcessIdentifiers: [Int32] = [],
        targetWindowRank: Int?,
        targetRestorableWindowRank: Int? = nil,
        activeSpaceChangeCount: UInt64
    ) {
        self.capturedAt = capturedAt
        self.frontmostProcessIdentifier = frontmostProcessIdentifier
        self.focusedProcessIdentifier = focusedProcessIdentifier
        self.cursor = cursor
        self.orderedWindowIdentifiers = orderedWindowIdentifiers
        self.orderedWindowProcessIdentifiers = orderedWindowProcessIdentifiers
        self.orderedRestorableWindowIdentifiers = orderedRestorableWindowIdentifiers
        self.orderedRestorableWindowProcessIdentifiers = orderedRestorableWindowProcessIdentifiers
        self.targetWindowRank = targetWindowRank
        self.targetRestorableWindowRank = targetRestorableWindowRank
        self.activeSpaceChangeCount = activeSpaceChangeCount
    }

    func uniqueRestorableProcessIdentifiersAboveTarget(excluding excluded: Set<Int32>) -> [Int32] {
        let processIdentifiers: [Int32]
        let rank: Int?
        if let targetRestorableWindowRank {
            processIdentifiers = orderedRestorableWindowProcessIdentifiers
            rank = targetRestorableWindowRank
        } else {
            processIdentifiers = orderedWindowProcessIdentifiers
            rank = targetWindowRank
        }
        guard let rank, rank <= processIdentifiers.count else {
            return []
        }
        var seen = Set<Int32>()
        return processIdentifiers.prefix(rank).compactMap { processIdentifier in
            guard processIdentifier > 0,
                  !excluded.contains(processIdentifier),
                  seen.insert(processIdentifier).inserted else {
                return nil
            }
            return processIdentifier
        }
    }
}

public struct FocusInvariantResult: Codable, Equatable, Sendable {
    public let passed: Bool
    public let violations: [String]
    public let before: FocusInvariantSnapshot
    public let after: FocusInvariantSnapshot
}

public final class ActiveSpaceTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var count: UInt64 = 0
    private var observer: NSObjectProtocol?

    public init() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            lock.lock()
            count += 1
            lock.unlock()
        }
    }

    deinit {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    public func currentCount() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

public struct FocusInvariantMonitor: Sendable {
    static let cursorRestorationTolerance = 1.0

    private let spaceTracker: ActiveSpaceTracker

    public init(spaceTracker: ActiveSpaceTracker = ActiveSpaceTracker()) {
        self.spaceTracker = spaceTracker
    }

    public func snapshot(targetWindowIdentifier: UInt32) -> FocusInvariantSnapshot {
        let cursorLocation = CGEvent(source: nil)?.location ?? .zero
        let order = orderedWindows()
        let identifiers = order.map(\.windowIdentifier)
        let restorableOrder = order.filter(\.isRegularApplication)
        let restorableIdentifiers = restorableOrder.map(\.windowIdentifier)
        return FocusInvariantSnapshot(
            capturedAt: AdapterClock.now(),
            frontmostProcessIdentifier: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            focusedProcessIdentifier: focusedProcessIdentifier(),
            cursor: AdapterPoint(x: cursorLocation.x, y: cursorLocation.y),
            orderedWindowIdentifiers: identifiers,
            orderedWindowProcessIdentifiers: order.map(\.processIdentifier),
            orderedRestorableWindowIdentifiers: restorableIdentifiers,
            orderedRestorableWindowProcessIdentifiers: restorableOrder.map(\.processIdentifier),
            targetWindowRank: identifiers.firstIndex(of: targetWindowIdentifier),
            targetRestorableWindowRank: restorableIdentifiers.firstIndex(of: targetWindowIdentifier),
            activeSpaceChangeCount: spaceTracker.currentCount()
        )
    }

    public func evaluate(
        before: FocusInvariantSnapshot,
        after: FocusInvariantSnapshot
    ) -> FocusInvariantResult {
        var violations: [String] = []
        if before.frontmostProcessIdentifier != after.frontmostProcessIdentifier {
            violations.append("FRONTMOST_PROCESS_CHANGED")
        }
        if before.focusedProcessIdentifier != after.focusedProcessIdentifier {
            violations.append("FOCUSED_PROCESS_CHANGED")
        }
        if before.cursor != after.cursor {
            violations.append("PHYSICAL_CURSOR_CHANGED")
        }
        if before.targetWindowRank != after.targetWindowRank {
            violations.append("TARGET_WINDOW_RANK_CHANGED")
        }
        if before.orderedWindowIdentifiers != after.orderedWindowIdentifiers {
            violations.append("WINDOW_ORDER_CHANGED")
        }
        if before.activeSpaceChangeCount != after.activeSpaceChangeCount {
            violations.append("ACTIVE_SPACE_CHANGED")
        }
        return FocusInvariantResult(
            passed: violations.isEmpty,
            violations: violations,
            before: before,
            after: after
        )
    }

    public func evaluateForegroundRestoration(
        before: FocusInvariantSnapshot,
        after: FocusInvariantSnapshot
    ) -> FocusInvariantResult {
        var violations: [String] = []
        if !Self.frontmostProcessRestorationPreserved(before: before, after: after) {
            violations.append("PRIOR_FRONTMOST_PROCESS_NOT_RESTORED")
        }
        if !Self.focusedProcessRestorationPreserved(before: before, after: after) {
            violations.append("PRIOR_FOCUSED_PROCESS_NOT_RESTORED")
        }
        if !Self.cursorPositionsEquivalent(before.cursor, after.cursor) {
            violations.append("PHYSICAL_CURSOR_NOT_RESTORED")
        }
        if !Self.restorationTargetPositionPreserved(before: before, after: after) {
            violations.append("TARGET_WINDOW_RANK_NOT_RESTORED")
        }
        if before.activeSpaceChangeCount != after.activeSpaceChangeCount {
            violations.append("ACTIVE_SPACE_CHANGED_DURING_LEASE")
        }
        return FocusInvariantResult(
            passed: violations.isEmpty,
            violations: violations,
            before: before,
            after: after
        )
    }

    static func cursorPositionsEquivalent(_ before: AdapterPoint, _ after: AdapterPoint) -> Bool {
        abs(before.x - after.x) < cursorRestorationTolerance
            && abs(before.y - after.y) < cursorRestorationTolerance
    }

    static func focusedProcessRestorationPreserved(
        before: FocusInvariantSnapshot,
        after: FocusInvariantSnapshot
    ) -> Bool {
        guard let restoredFrontmost = restoredFrontmostProcessIdentifier(
            before: before,
            after: after
        ) else { return false }
        return after.focusedProcessIdentifier == before.focusedProcessIdentifier
            || after.focusedProcessIdentifier == restoredFrontmost
    }

    static func frontmostProcessRestorationPreserved(
        before: FocusInvariantSnapshot,
        after: FocusInvariantSnapshot
    ) -> Bool {
        after.frontmostProcessIdentifier == restoredFrontmostProcessIdentifier(
            before: before,
            after: after
        )
    }

    private static func restoredFrontmostProcessIdentifier(
        before: FocusInvariantSnapshot,
        after: FocusInvariantSnapshot
    ) -> Int32? {
        if before.frontmostProcessIdentifier == after.frontmostProcessIdentifier {
            return before.frontmostProcessIdentifier
        }
        let beforeProcesses = before.orderedRestorableWindowProcessIdentifiers.isEmpty
            ? before.orderedWindowProcessIdentifiers
            : before.orderedRestorableWindowProcessIdentifiers
        let afterProcesses = after.orderedRestorableWindowProcessIdentifiers.isEmpty
            ? after.orderedWindowProcessIdentifiers
            : after.orderedRestorableWindowProcessIdentifiers
        let afterSet = Set(afterProcesses)
        guard let originalFrontmost = before.frontmostProcessIdentifier,
              !afterSet.contains(originalFrontmost) else { return nil }
        return uniqueProcessOrder(beforeProcesses).first(where: afterSet.contains)
    }

    static func targetWindowPositionPreserved(
        beforeIdentifiers: [UInt32],
        beforeRank: Int?,
        afterIdentifiers: [UInt32],
        afterRank: Int?
    ) -> Bool {
        guard let beforeRank, let afterRank,
              beforeIdentifiers.indices.contains(beforeRank),
              afterIdentifiers.indices.contains(afterRank) else {
            return beforeRank == afterRank
        }
        let targetIdentifier = beforeIdentifiers[beforeRank]
        guard afterIdentifiers[afterRank] == targetIdentifier else { return false }

        let beforeSet = Set(beforeIdentifiers)
        let afterSet = Set(afterIdentifiers)
        guard afterSet.isSubset(of: beforeSet) else { return false }
        return beforeIdentifiers.filter(afterSet.contains) == afterIdentifiers
    }

    static func restorationTargetPositionPreserved(
        before: FocusInvariantSnapshot,
        after: FocusInvariantSnapshot
    ) -> Bool {
        if before.targetRestorableWindowRank != nil || after.targetRestorableWindowRank != nil {
            if before.orderedRestorableWindowIdentifiers.count
                == before.orderedRestorableWindowProcessIdentifiers.count,
                after.orderedRestorableWindowIdentifiers.count
                    == after.orderedRestorableWindowProcessIdentifiers.count {
                return targetApplicationPositionPreserved(
                    beforeIdentifiers: before.orderedRestorableWindowIdentifiers,
                    beforeProcessIdentifiers: before.orderedRestorableWindowProcessIdentifiers,
                    beforeRank: before.targetRestorableWindowRank,
                    afterIdentifiers: after.orderedRestorableWindowIdentifiers,
                    afterProcessIdentifiers: after.orderedRestorableWindowProcessIdentifiers,
                    afterRank: after.targetRestorableWindowRank
                )
            }
            return targetWindowPositionPreserved(
                beforeIdentifiers: before.orderedRestorableWindowIdentifiers,
                beforeRank: before.targetRestorableWindowRank,
                afterIdentifiers: after.orderedRestorableWindowIdentifiers,
                afterRank: after.targetRestorableWindowRank
            )
        }
        return targetWindowPositionPreserved(
            beforeIdentifiers: before.orderedWindowIdentifiers,
            beforeRank: before.targetWindowRank,
            afterIdentifiers: after.orderedWindowIdentifiers,
            afterRank: after.targetWindowRank
        )
    }

    static func targetApplicationPositionPreserved(
        beforeIdentifiers: [UInt32],
        beforeProcessIdentifiers: [Int32],
        beforeRank: Int?,
        afterIdentifiers: [UInt32],
        afterProcessIdentifiers: [Int32],
        afterRank: Int?
    ) -> Bool {
        guard let beforeRank, let afterRank,
              beforeIdentifiers.indices.contains(beforeRank),
              afterIdentifiers.indices.contains(afterRank),
              beforeProcessIdentifiers.indices.contains(beforeRank),
              afterProcessIdentifiers.indices.contains(afterRank) else {
            return beforeRank == afterRank
        }
        let targetIdentifier = beforeIdentifiers[beforeRank]
        let targetProcessIdentifier = beforeProcessIdentifiers[beforeRank]
        guard afterIdentifiers[afterRank] == targetIdentifier,
              afterProcessIdentifiers[afterRank] == targetProcessIdentifier else {
            return false
        }

        let beforeOrder = uniqueProcessOrder(beforeProcessIdentifiers)
        let afterOrder = uniqueProcessOrder(afterProcessIdentifiers)
        guard afterOrder.allSatisfy(Set(beforeOrder).contains) else { return false }

        let retainedBeforeOrder = beforeOrder.filter { $0 != targetProcessIdentifier }
        let retainedAfterOrder = afterOrder.filter { $0 != targetProcessIdentifier }
        let retainedAfterSet = Set(retainedAfterOrder)
        return retainedBeforeOrder.filter(retainedAfterSet.contains) == retainedAfterOrder
    }

    private static func uniqueProcessOrder(_ processIdentifiers: [Int32]) -> [Int32] {
        var seen = Set<Int32>()
        return processIdentifiers.filter { seen.insert($0).inserted }
    }

    private struct OrderedWindow {
        let windowIdentifier: UInt32
        let processIdentifier: Int32
        let isRegularApplication: Bool
    }

    private func orderedWindows() -> [OrderedWindow] {
        guard let raw = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
            as? [[String: Any]] else {
            return []
        }
        return raw.compactMap { row in
            guard let layer = row[kCGWindowLayer as String] as? Int, layer == 0 else { return nil }
            guard let windowIdentifier = (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let processIdentifier = (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else {
                return nil
            }
            return OrderedWindow(
                windowIdentifier: windowIdentifier,
                processIdentifier: processIdentifier,
                isRegularApplication: NSRunningApplication(
                    processIdentifier: processIdentifier
                )?.activationPolicy == .regular
            )
        }
    }

    private func focusedProcessIdentifier() -> Int32? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system,
            kAXFocusedApplicationAttribute as CFString,
            &value
        ) == .success,
        let application = value else {
            return nil
        }
        var pid: pid_t = 0
        guard AXUIElementGetPid(application as! AXUIElement, &pid) == .success else {
            return nil
        }
        return pid
    }
}
