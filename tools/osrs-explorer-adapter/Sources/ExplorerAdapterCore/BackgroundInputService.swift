import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

public enum InputMechanism: String, Codable, Sendable {
    case accessibilityPress = "AX_PRESS"
    case pidDirectedEvent = "CG_EVENT_POST_TO_PID"
    case foregroundPidDirectedEvent = "FOREGROUND_CG_EVENT_POST_TO_PID"
    case foregroundGlobalEvent = "FOREGROUND_CG_EVENT_POST"
}

public struct InputActionEvidence: Codable, Sendable {
    public let actionIdentifier: String
    public let mechanism: InputMechanism
    public let eventSourceMode: EventSourceMode?
    public let deliveryMode: InputDeliveryMode
    public let target: TargetWindowDescriptor
    public let action: PrivilegedAction
    public let focusInvariant: FocusInvariantResult
    public let foregroundLease: ForegroundLeaseEvidence?
    public let outcome: String
    public let completedAt: String
}

public struct InputActionResult: Codable, Sendable {
    public let evidence: InputActionEvidence
    public let evidenceReference: EvidenceReference
}

public enum InputActionSuspensionPoint: String, Sendable {
    case claim
    case authorization
    case discovery
    case beforeAccessibilityPress
    case beforeCGEvent
}

public struct InputActionHooks: Sendable {
    public let pause: @Sendable (InputActionSuspensionPoint, InputCancellationGate) async -> Void

    public init(
        pause: @escaping @Sendable (
            InputActionSuspensionPoint,
            InputCancellationGate
        ) async -> Void = { _, _ in }
    ) {
        self.pause = pause
    }

    public func revalidate(
        _ point: InputActionSuspensionPoint,
        gate: InputCancellationGate
    ) async throws {
        await pause(point, gate)
        try gate.checkValid()
    }
}

public final class InputCancellationGate: @unchecked Sendable {
    // Event emission stays atomic against external cancellation, while a phase may
    // synchronously invalidate itself after detecting that the target lost focus.
    private let lock = NSRecursiveLock()
    public let enableGeneration: UInt64
    private let permissionsGranted: @Sendable () -> Bool
    private let now: @Sendable () -> Date
    private var valid = true
    private var invalidReason: String?
    private var deadline: Date?

    public init(
        enableGeneration: UInt64 = 0,
        permissionsGranted: @escaping @Sendable () -> Bool = {
            AdapterPermissions.snapshot().allRequiredGranted
        },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.enableGeneration = enableGeneration
        self.permissionsGranted = permissionsGranted
        self.now = now
    }

    public func bindExecutionDeadline(_ value: String) throws {
        guard let parsed = AdapterClock.date(from: value) else {
            throw AdapterError.queueRejected("ITEM_EXECUTION_DEADLINE_INVALID")
        }
        lock.lock()
        defer { lock.unlock() }
        guard deadline == nil else {
            throw AdapterError.queueRejected("ITEM_EXECUTION_DEADLINE_ALREADY_BOUND")
        }
        deadline = parsed
        try checkValidLocked(requireEmissionAuthorization: false)
    }

    public func invalidate(reason: String = "ACTION_CANCELED") {
        lock.lock()
        valid = false
        if invalidReason == nil { invalidReason = reason }
        lock.unlock()
    }

    public func checkValid(requireEmissionAuthorization: Bool = false) throws {
        lock.lock()
        defer { lock.unlock() }
        try checkValidLocked(requireEmissionAuthorization: requireEmissionAuthorization)
    }

    public func currentInvalidReason() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return invalidReason
    }

    public func performIfValid<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        try checkValidLocked(requireEmissionAuthorization: false)
        return try body()
    }

    public func performEmission<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        try checkValidLocked(requireEmissionAuthorization: true)
        return try body()
    }

    private func checkValidLocked(requireEmissionAuthorization: Bool) throws {
        guard valid else {
            throw AdapterError.actionNotAllowed(invalidReason ?? "ACTION_CANCELED")
        }
        if let deadline, now() >= deadline {
            valid = false
            invalidReason = "ITEM_EXECUTION_DEADLINE_EXCEEDED"
            throw AdapterError.actionNotAllowed("ITEM_EXECUTION_DEADLINE_EXCEEDED")
        }
        if requireEmissionAuthorization, !permissionsGranted() {
            valid = false
            invalidReason = "INPUT_PERMISSION_LOST"
            throw AdapterError.permissionRequired("INPUT_PERMISSION_LOST")
        }
    }
}

public final class ActiveInputGateRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var gates: [ObjectIdentifier: InputCancellationGate] = [:]
    private var closedReason: String?

    public init() {}

    @discardableResult
    public func register(_ gate: InputCancellationGate) -> Bool {
        lock.lock()
        if let closedReason {
            lock.unlock()
            gate.invalidate(reason: closedReason)
            return false
        }
        gates[ObjectIdentifier(gate)] = gate
        lock.unlock()
        return true
    }

    public func end(_ gate: InputCancellationGate) {
        lock.lock()
        gates.removeValue(forKey: ObjectIdentifier(gate))
        lock.unlock()
    }

    public func invalidateAllAndClose(reason: String) {
        lock.lock()
        if closedReason == nil { closedReason = reason }
        let active = Array(gates.values)
        gates.removeAll()
        let effectiveReason = closedReason ?? reason
        lock.unlock()
        for gate in active {
            gate.invalidate(reason: effectiveReason)
        }
    }

    public var activeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return gates.count
    }
}

public enum CursorRestorationRunner {
    @discardableResult
    public static func restoreIfAuthorized(
        cancellationGate: InputCancellationGate,
        expectedPosition: CGPoint,
        currentPosition: () -> CGPoint,
        restore: (CGPoint) -> Void
    ) throws -> Bool {
        try cancellationGate.performEmission {
            guard currentPosition() != expectedPosition else { return false }
            restore(expectedPosition)
            return true
        }
    }
}

public enum ClickInputPhase: Equatable, Sendable {
    case movedToPoint
    case down
    case up
    case cleanupUp
}

public enum DragInputPhase: Equatable, Sendable {
    case movedToStart
    case down
    case primed
    case dragged(step: Int, progress: Double)
    case settlingProbe
    case settled
    case up
    case cleanupUp(lastStep: Int, totalSteps: Int)
}

public enum InputSequenceRunner {
    public static func recommendedDragSteps(forDistance distance: CGFloat) -> Int {
        distance <= 100 ? 24 : 36
    }

    public static func runClick(
        cancellationGate: InputCancellationGate,
        movesCursor: Bool,
        pressMilliseconds: Int = 12,
        postUpSettleMilliseconds: Int = 0,
        pause: (Int) async throws -> Void,
        beforeEmission: (ClickInputPhase) async throws -> Void = { _ in },
        post: (ClickInputPhase) throws -> Void,
        isolation: isolated (any Actor)? = #isolation
    ) async throws {
        try cancellationGate.checkValid()
        if movesCursor {
            try await beforeEmission(.movedToPoint)
            try cancellationGate.performEmission { try post(.movedToPoint) }
            try await pause(8)
            try cancellationGate.checkValid()
        }
        var downPosted = false
        do {
            try await beforeEmission(.down)
            try cancellationGate.performEmission { try post(.down) }
            downPosted = true
            try await pause(pressMilliseconds)
            try cancellationGate.checkValid()
            try await beforeEmission(.up)
            try cancellationGate.performEmission { try post(.up) }
            downPosted = false
            if postUpSettleMilliseconds > 0 {
                try await pause(postUpSettleMilliseconds)
                try cancellationGate.checkValid()
            }
        } catch {
            if downPosted {
                do {
                    try post(.cleanupUp)
                } catch {
                    throw AdapterError.actionNotAllowed("INPUT_CLEANUP_FAILED:\(error)")
                }
            }
            throw error
        }
    }

    public static func runDrag(
        cancellationGate: InputCancellationGate,
        movesCursor: Bool,
        steps: Int = 36,
        pause: (Int) async throws -> Void,
        beforeEmission: (DragInputPhase) async throws -> Void = { _ in },
        post: (DragInputPhase) throws -> Void,
        isolation: isolated (any Actor)? = #isolation
    ) async throws {
        precondition(steps > 0)
        try cancellationGate.checkValid()
        if movesCursor {
            try await beforeEmission(.movedToStart)
            try cancellationGate.performEmission { try post(.movedToStart) }
            try await pause(8)
            try cancellationGate.checkValid()
        }
        var downPosted = false
        var lastStep = 0
        do {
            try await beforeEmission(.down)
            try cancellationGate.performEmission { try post(.down) }
            downPosted = true
            try await beforeEmission(.primed)
            try cancellationGate.performEmission { try post(.primed) }
            try await pause(8)
            try cancellationGate.checkValid()
            for step in 1...steps {
                let progress = Double(step) / Double(steps)
                let phase = DragInputPhase.dragged(step: step, progress: progress)
                try await beforeEmission(phase)
                try cancellationGate.performEmission {
                    try post(.dragged(step: step, progress: progress))
                }
                lastStep = step
                try await pause(8)
                try cancellationGate.checkValid()
            }
            if steps > 24 {
                try await beforeEmission(.settlingProbe)
                try cancellationGate.performEmission { try post(.settlingProbe) }
                try await pause(8)
                try cancellationGate.checkValid()
            }
            try await beforeEmission(.settled)
            try cancellationGate.performEmission { try post(.settled) }
            try await pause(steps > 24 ? 32 : 16)
            try cancellationGate.checkValid()
            try await beforeEmission(.up)
            try cancellationGate.performEmission { try post(.up) }
            downPosted = false
        } catch {
            if downPosted {
                do {
                    try post(.cleanupUp(lastStep: lastStep, totalSteps: steps))
                } catch {
                    throw AdapterError.actionNotAllowed("INPUT_CLEANUP_FAILED:\(error)")
                }
            }
            throw error
        }
    }
}

public enum AccessibilityPressEmissionRunner {
    public static func run<T>(
        cancellationGate: InputCancellationGate,
        hooks: InputActionHooks,
        emit: () throws -> T
    ) async throws -> T {
        try await hooks.revalidate(.beforeAccessibilityPress, gate: cancellationGate)
        return try cancellationGate.performEmission(emit)
    }
}

public actor BackgroundInputService {
    private let monitor: FocusInvariantMonitor
    private let evidenceStore: EvidenceStore
    private let foregroundLeaseService: ForegroundLeaseService
    private let foregroundInterferenceRegistry: ForegroundInterferenceRegistry?
    private let hooks: InputActionHooks

    public init(
        monitor: FocusInvariantMonitor,
        evidenceStore: EvidenceStore,
        foregroundInterferenceRegistry: ForegroundInterferenceRegistry? = nil,
        hooks: InputActionHooks = InputActionHooks()
    ) {
        self.monitor = monitor
        self.evidenceStore = evidenceStore
        self.foregroundInterferenceRegistry = foregroundInterferenceRegistry
        self.hooks = hooks
        foregroundLeaseService = ForegroundLeaseService(monitor: monitor)
    }

    public func perform(
        _ action: PrivilegedAction,
        capture: CaptureEvidence,
        cancellationGate: InputCancellationGate,
        preferredEventSourceMode: EventSourceMode = .privateState,
        deliveryMode: InputDeliveryMode = .backgroundPid
    ) async throws -> InputActionResult {
        try cancellationGate.checkValid()
        guard AXIsProcessTrusted() else {
            throw AdapterError.permissionRequired("ACCESSIBILITY")
        }
        if case .openWorldMap = action, deliveryMode != .foregroundGlobal {
            throw AdapterError.actionNotAllowed("WORLD_MAP_CONTROL_CLICK_REQUIRES_FOREGROUND_GLOBAL")
        }
        if deliveryMode == .backgroundPid {
            return try await performBackground(
                action,
                capture: capture,
                cancellationGate: cancellationGate,
                preferredEventSourceMode: preferredEventSourceMode
            )
        }
        return try await performForeground(
            action,
            capture: capture,
            cancellationGate: cancellationGate,
            preferredEventSourceMode: preferredEventSourceMode,
            deliveryMode: deliveryMode
        )
    }

    private func performBackground(
        _ action: PrivilegedAction,
        capture: CaptureEvidence,
        cancellationGate: InputCancellationGate,
        preferredEventSourceMode: EventSourceMode
    ) async throws -> InputActionResult {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier != capture.target.processIdentifier else {
            throw AdapterError.actionNotAllowed("TARGET_IS_FRONTMOST")
        }
        let before = monitor.snapshot(targetWindowIdentifier: capture.target.windowIdentifier)
        let mechanism: InputMechanism
        let sourceMode: EventSourceMode?

        switch action {
        case let .click(captureIdentifier, point, button):
            guard captureIdentifier == capture.captureIdentifier else {
                throw AdapterError.staleCapture
            }
            let screenPoint = try CoordinateTransform.screenPoint(
                imagePoint: point,
                pixelWidth: capture.pixelWidth,
                pixelHeight: capture.pixelHeight,
                windowFrame: capture.target.frame
            )
            if button == .left,
               try await AccessibilityActionService.press(
                processIdentifier: capture.target.processIdentifier,
                at: screenPoint,
                cancellationGate: cancellationGate,
                hooks: hooks
               ) {
                mechanism = .accessibilityPress
                sourceMode = nil
            } else {
                try await self.postClick(
                    processIdentifier: capture.target.processIdentifier,
                    point: screenPoint,
                    button: button,
                    cancellationGate: cancellationGate,
                    sourceMode: preferredEventSourceMode,
                    deliveryMode: .backgroundPid
                )
                mechanism = .pidDirectedEvent
                sourceMode = preferredEventSourceMode
            }
        case let .drag(captureIdentifier, from, to):
            guard captureIdentifier == capture.captureIdentifier else {
                throw AdapterError.staleCapture
            }
            let start = try CoordinateTransform.screenPoint(
                imagePoint: from,
                pixelWidth: capture.pixelWidth,
                pixelHeight: capture.pixelHeight,
                windowFrame: capture.target.frame
            )
            let end = try CoordinateTransform.screenPoint(
                imagePoint: to,
                pixelWidth: capture.pixelWidth,
                pixelHeight: capture.pixelHeight,
                windowFrame: capture.target.frame
            )
            try await postDrag(
                processIdentifier: capture.target.processIdentifier,
                from: start,
                to: end,
                cancellationGate: cancellationGate,
                sourceMode: preferredEventSourceMode,
                deliveryMode: .backgroundPid
            )
            mechanism = .pidDirectedEvent
            sourceMode = preferredEventSourceMode
        case .openWorldMap:
            throw AdapterError.actionNotAllowed("WORLD_MAP_SHORTCUT_REQUIRES_FOREGROUND_GLOBAL")
        }

        try await Task.sleep(for: .milliseconds(30))
        try cancellationGate.checkValid()
        let after = monitor.snapshot(targetWindowIdentifier: capture.target.windowIdentifier)
        let invariant = monitor.evaluate(before: before, after: after)
        let identifier = UUID().uuidString.lowercased()
        let evidence = InputActionEvidence(
            actionIdentifier: identifier,
            mechanism: mechanism,
            eventSourceMode: sourceMode,
            deliveryMode: .backgroundPid,
            target: capture.target,
            action: action,
            focusInvariant: invariant,
            foregroundLease: nil,
            outcome: "COMPLETED",
            completedAt: AdapterClock.now()
        )
        let reference = try evidenceStore.writeImmutable(
            evidence,
            relativePath: "input/\(identifier).json"
        )
        guard invariant.passed else {
            throw AdapterError.invariantViolation(invariant.violations, reference)
        }
        return InputActionResult(evidence: evidence, evidenceReference: reference)
    }

    private func performForeground(
        _ action: PrivilegedAction,
        capture: CaptureEvidence,
        cancellationGate: InputCancellationGate,
        preferredEventSourceMode: EventSourceMode,
        deliveryMode: InputDeliveryMode
    ) async throws -> InputActionResult {
        let mechanism: InputMechanism = deliveryMode == .foregroundPid
            ? .foregroundPidDirectedEvent
            : .foregroundGlobalEvent
        let execution = await foregroundLeaseService.perform(
            target: capture.target,
            deliveryMode: deliveryMode,
            cancellationGate: cancellationGate
        ) {
            self.foregroundInterferenceRegistry?.beginInputEmission(cancellationGate)
            defer {
                self.foregroundInterferenceRegistry?.endInputEmission(cancellationGate)
            }
            switch action {
            case let .click(captureIdentifier, point, button):
                guard captureIdentifier == capture.captureIdentifier else {
                    throw AdapterError.staleCapture
                }
                let screenPoint = try CoordinateTransform.screenPoint(
                    imagePoint: point,
                    pixelWidth: capture.pixelWidth,
                    pixelHeight: capture.pixelHeight,
                    windowFrame: capture.target.frame
                )
                try await self.postClick(
                    processIdentifier: capture.target.processIdentifier,
                    point: screenPoint,
                    button: button,
                    cancellationGate: cancellationGate,
                    sourceMode: preferredEventSourceMode,
                    deliveryMode: deliveryMode
                )
            case let .drag(captureIdentifier, from, to):
                guard captureIdentifier == capture.captureIdentifier else {
                    throw AdapterError.staleCapture
                }
                let start = try CoordinateTransform.screenPoint(
                    imagePoint: from,
                    pixelWidth: capture.pixelWidth,
                    pixelHeight: capture.pixelHeight,
                    windowFrame: capture.target.frame
                )
                let end = try CoordinateTransform.screenPoint(
                    imagePoint: to,
                    pixelWidth: capture.pixelWidth,
                    pixelHeight: capture.pixelHeight,
                    windowFrame: capture.target.frame
                )
                try await self.postDrag(
                    processIdentifier: capture.target.processIdentifier,
                    from: start,
                    to: end,
                    cancellationGate: cancellationGate,
                    sourceMode: preferredEventSourceMode,
                    deliveryMode: deliveryMode
                )
            case let .openWorldMap(captureIdentifier):
                guard captureIdentifier == capture.captureIdentifier else {
                    throw AdapterError.staleCapture
                }
                let imagePoint = try WorldMapControlGeometry.sourcePoint(
                    pixelWidth: capture.pixelWidth,
                    pixelHeight: capture.pixelHeight
                )
                let screenPoint = try CoordinateTransform.screenPoint(
                    imagePoint: imagePoint,
                    pixelWidth: capture.pixelWidth,
                    pixelHeight: capture.pixelHeight,
                    windowFrame: capture.target.frame
                )
                try await Task.sleep(for: .milliseconds(120))
                try cancellationGate.checkValid()
                try await self.hooks.revalidate(.beforeCGEvent, gate: cancellationGate)
                try await self.postClick(
                    processIdentifier: capture.target.processIdentifier,
                    point: screenPoint,
                    button: .left,
                    cancellationGate: cancellationGate,
                    sourceMode: preferredEventSourceMode,
                    deliveryMode: deliveryMode,
                    pressMilliseconds: 40,
                    postUpSettleMilliseconds: 120
                )
            }
        }
        let identifier = execution.evidence.leaseIdentifier
        let evidence = InputActionEvidence(
            actionIdentifier: identifier,
            mechanism: mechanism,
            eventSourceMode: preferredEventSourceMode,
            deliveryMode: deliveryMode,
            target: capture.target,
            action: action,
            focusInvariant: execution.evidence.restorationInvariant,
            foregroundLease: execution.evidence,
            outcome: execution.failure == nil ? "COMPLETED" : "FAILED",
            completedAt: AdapterClock.now()
        )
        let reference = try evidenceStore.writeImmutable(
            evidence,
            relativePath: "input/\(identifier).json"
        )
        if let failure = execution.failure {
            throw AdapterError.foregroundLeaseFailed(failure, reference)
        }
        return InputActionResult(evidence: evidence, evidenceReference: reference)
    }

    private func postClick(
        processIdentifier: Int32,
        point: CGPoint,
        button: MouseButton,
        cancellationGate: InputCancellationGate,
        sourceMode: EventSourceMode,
        deliveryMode: InputDeliveryMode,
        pressMilliseconds: Int = 12,
        postUpSettleMilliseconds: Int = 0
    ) async throws {
        let source = try eventSource(sourceMode, deliveryMode: deliveryMode)
        let downType: CGEventType = button == .left ? .leftMouseDown : .rightMouseDown
        let upType: CGEventType = button == .left ? .leftMouseUp : .rightMouseUp
        let cgButton: CGMouseButton = button == .left ? .left : .right
        guard let down = CGEvent(
            mouseEventSource: source,
            mouseType: downType,
            mouseCursorPosition: point,
            mouseButton: cgButton
        ), let up = CGEvent(
            mouseEventSource: source,
            mouseType: upType,
            mouseCursorPosition: point,
            mouseButton: cgButton
        ) else {
            throw eventCreationError(deliveryMode, "CG_EVENT_CREATE_FAILED")
        }
        tag(down)
        tag(up)
        let moved: CGEvent?
        if deliveryMode == .foregroundGlobal {
            guard let event = CGEvent(
                mouseEventSource: source,
                mouseType: .mouseMoved,
                mouseCursorPosition: point,
                mouseButton: .left
            ) else {
                throw eventCreationError(deliveryMode, "CG_MOVE_CREATE_FAILED")
            }
            tag(event)
            moved = event
        } else {
            moved = nil
        }
        try await InputSequenceRunner.runClick(
            cancellationGate: cancellationGate,
            movesCursor: moved != nil,
            pressMilliseconds: pressMilliseconds,
            postUpSettleMilliseconds: postUpSettleMilliseconds,
            pause: { milliseconds in
                try await Task.sleep(for: .milliseconds(milliseconds))
            },
            beforeEmission: { _ in
                try await self.hooks.revalidate(.beforeCGEvent, gate: cancellationGate)
            },
            post: { phase in
                let event: CGEvent
                switch phase {
                case .movedToPoint:
                    guard let moved else {
                        throw self.eventCreationError(deliveryMode, "CG_MOVE_SEQUENCE_INVALID")
                    }
                    event = moved
                case .down:
                    event = down
                case .up, .cleanupUp:
                    event = up
                }
                try self.post(
                    event,
                    processIdentifier: processIdentifier,
                    deliveryMode: deliveryMode,
                    cancellationGate: cancellationGate,
                    isCleanup: phase == .cleanupUp,
                    cleanupButton: phase == .cleanupUp ? cgButton : nil
                )
            }
        )
    }

    private func postDrag(
        processIdentifier: Int32,
        from: CGPoint,
        to: CGPoint,
        cancellationGate: InputCancellationGate,
        sourceMode: EventSourceMode,
        deliveryMode: InputDeliveryMode
    ) async throws {
        let source = try eventSource(sourceMode, deliveryMode: deliveryMode)
        let distance = hypot(to.x - from.x, to.y - from.y)
        try await InputSequenceRunner.runDrag(
            cancellationGate: cancellationGate,
            movesCursor: deliveryMode == .foregroundGlobal,
            steps: InputSequenceRunner.recommendedDragSteps(forDistance: distance),
            pause: { milliseconds in
                try await Task.sleep(for: .milliseconds(milliseconds))
            },
            beforeEmission: { _ in
                try await self.hooks.revalidate(.beforeCGEvent, gate: cancellationGate)
            },
            post: { phase in
                let type: CGEventType
                let point: CGPoint
                switch phase {
                case .movedToStart:
                    type = .mouseMoved
                    point = from
                case .down:
                    type = .leftMouseDown
                    point = from
                case .primed:
                    type = .leftMouseDragged
                    point = from
                case let .dragged(_, progress):
                    type = .leftMouseDragged
                    point = CGPoint(
                        x: from.x + (to.x - from.x) * CGFloat(progress),
                        y: from.y + (to.y - from.y) * CGFloat(progress)
                    )
                case .settlingProbe:
                    type = .leftMouseDragged
                    let distance = hypot(to.x - from.x, to.y - from.y)
                    point = distance > 0
                        ? CGPoint(
                            x: to.x + (from.x - to.x) / distance,
                            y: to.y + (from.y - to.y) / distance
                        )
                        : to
                case .settled:
                    type = .leftMouseDragged
                    point = to
                case .up:
                    type = .leftMouseUp
                    point = to
                case let .cleanupUp(lastStep, totalSteps):
                    let progress = CGFloat(lastStep) / CGFloat(totalSteps)
                    type = .leftMouseUp
                    point = CGPoint(
                        x: from.x + (to.x - from.x) * progress,
                        y: from.y + (to.y - from.y) * progress
                    )
                }
                guard let event = CGEvent(
                    mouseEventSource: source,
                    mouseType: type,
                    mouseCursorPosition: point,
                    mouseButton: .left
                ) else {
                    throw eventCreationError(deliveryMode, "CG_DRAG_EVENT_CREATE_FAILED")
                }
                tag(event)
                try post(
                    event,
                    processIdentifier: processIdentifier,
                    deliveryMode: deliveryMode,
                    cancellationGate: cancellationGate,
                    isCleanup: {
                        if case .cleanupUp = phase { return true }
                        return false
                    }(),
                    cleanupButton: {
                        if case .cleanupUp = phase { return .left }
                        return nil
                    }()
                )
            }
        )
    }

    private func post(
        _ event: CGEvent,
        processIdentifier: Int32,
        deliveryMode: InputDeliveryMode,
        cancellationGate: InputCancellationGate,
        isCleanup: Bool,
        cleanupButton: CGMouseButton? = nil,
        cleanupKeyCode: CGKeyCode? = nil
    ) throws {
        if deliveryMode.requiresForegroundLease, !isCleanup {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier else {
                let reason = "TARGET_LOST_FOCUS_DURING_INPUT"
                cancellationGate.invalidate(reason: reason)
                throw AdapterError.actionNotAllowed(reason)
            }
        }
        switch deliveryMode {
        case .backgroundPid, .foregroundPid:
            event.postToPid(processIdentifier)
        case .foregroundGlobal:
            event.post(tap: .cghidEventTap)
            if isCleanup {
                if let cleanupButton {
                    try confirmGlobalButtonReleased(cleanupButton)
                } else if let cleanupKeyCode {
                    try confirmGlobalKeyReleased(cleanupKeyCode)
                } else {
                    throw AdapterError.actionNotAllowed("INPUT_CLEANUP_CONTROL_MISSING")
                }
            }
        }
    }

    private func confirmGlobalButtonReleased(_ button: CGMouseButton) throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + 100_000_000
        repeat {
            if !CGEventSource.buttonState(.combinedSessionState, button: button) {
                return
            }
            Thread.sleep(forTimeInterval: 0.001)
        } while DispatchTime.now().uptimeNanoseconds < deadline
        throw AdapterError.actionNotAllowed("GLOBAL_BUTTON_RELEASE_UNCONFIRMED")
    }

    private func confirmGlobalKeyReleased(_ keyCode: CGKeyCode) throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + 100_000_000
        repeat {
            if !CGEventSource.keyState(.combinedSessionState, key: keyCode) {
                return
            }
            Thread.sleep(forTimeInterval: 0.001)
        } while DispatchTime.now().uptimeNanoseconds < deadline
        throw AdapterError.actionNotAllowed("GLOBAL_KEY_RELEASE_UNCONFIRMED")
    }

    private func eventSource(
        _ mode: EventSourceMode,
        deliveryMode: InputDeliveryMode
    ) throws -> CGEventSource {
        let state: CGEventSourceStateID
        switch mode {
        case .privateState: state = .privateState
        case .combinedSessionState: state = .combinedSessionState
        case .hidSystemState: state = .hidSystemState
        }
        guard let source = CGEventSource(stateID: state) else {
            throw eventCreationError(deliveryMode, "CG_EVENT_SOURCE_UNAVAILABLE:\(mode.rawValue)")
        }
        return source
    }

    private func eventCreationError(
        _ deliveryMode: InputDeliveryMode,
        _ reason: String
    ) -> AdapterError {
        deliveryMode == .backgroundPid
            ? .backgroundUnsupported(reason)
            : .actionNotAllowed(reason)
    }

    private func tag(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: osrsAdapterEventTag)
    }
}

private enum AccessibilityActionService {
    static func press(
        processIdentifier: Int32,
        at point: CGPoint,
        cancellationGate: InputCancellationGate,
        hooks: InputActionHooks
    ) async throws -> Bool {
        let application = AXUIElementCreateApplication(processIdentifier)
        var stack: [(AXUIElement, Int)] = [(application, 0)]
        var candidates: [(element: AXUIElement, depth: Int, area: CGFloat)] = []
        var visited = 0
        while let (element, depth) = stack.popLast(), visited < 512 {
            visited += 1
            if let frame = frame(of: element), frame.contains(point), supportsPress(element) {
                candidates.append((element, depth, frame.width * frame.height))
            }
            guard depth < 32 else { continue }
            for child in children(of: element) {
                stack.append((child, depth + 1))
            }
        }
        guard let candidate = candidates.sorted(by: {
            $0.depth == $1.depth ? $0.area < $1.area : $0.depth > $1.depth
        }).first else {
            return false
        }
        let result = try await AccessibilityPressEmissionRunner.run(
            cancellationGate: cancellationGate,
            hooks: hooks
        ) {
            AXUIElementPerformAction(candidate.element, kAXPressAction as CFString)
        }
        if result == .success { return true }
        if result == .actionUnsupported { return false }
        throw AdapterError.backgroundUnsupported("AX_PRESS_FAILED:\(result.rawValue)")
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &value
        ) == .success else {
            return []
        }
        return value as? [AXUIElement] ?? []
    }

    private static func supportsPress(_ element: AXUIElement) -> Bool {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success,
              let actions = names as? [String] else {
            return false
        }
        return actions.contains(kAXPressAction as String)
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
}
