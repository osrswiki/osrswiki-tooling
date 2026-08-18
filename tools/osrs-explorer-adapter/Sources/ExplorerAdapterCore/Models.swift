import CoreGraphics
import Foundation

public let osrsTargetBundleIdentifier = "com.jagex.osclient"
public let osrsAdapterEventTag: Int64 = 0x4F535253

public enum AdapterState: String, Codable, Sendable {
    case starting = "STARTING"
    case permissionsRequired = "PERMISSIONS_REQUIRED"
    case readyIdle = "READY_IDLE"
    case running = "RUNNING"
    case pausedByUser = "PAUSED_BY_USER"
    case pausedTargetTouched = "PAUSED_TARGET_TOUCHED"
    case backgroundUnsupported = "BACKGROUND_UNSUPPORTED_AWAITING_OSAMU"
    case faulted = "FAULTED"
}

public enum MouseButton: String, Codable, Sendable {
    case left
    case right
}

public enum EventSourceMode: String, Codable, CaseIterable, Sendable {
    case privateState = "private_state"
    case combinedSessionState = "combined_session_state"
    case hidSystemState = "hid_system_state"
}

public enum InputDeliveryMode: String, Codable, CaseIterable, Sendable {
    case backgroundPid = "background_pid"
    case foregroundPid = "foreground_pid"
    case foregroundGlobal = "foreground_global"

    public var requiresForegroundLease: Bool {
        self != .backgroundPid
    }
}

public struct AdapterPoint: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct AdapterRect: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(_ rect: CGRect) {
        self.init(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height)
    }

    public var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

public struct TargetSelector: Codable, Equatable, Sendable {
    public let bundleIdentifier: String?
    public let processIdentifier: Int32?
    public let titleContains: String?

    public init(
        bundleIdentifier: String? = nil,
        processIdentifier: Int32? = nil,
        titleContains: String? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.titleContains = titleContains
    }

    public static let osrs = TargetSelector(bundleIdentifier: osrsTargetBundleIdentifier)
}

public struct TargetWindowDescriptor: Codable, Equatable, Sendable {
    public let bundleIdentifier: String?
    public let processIdentifier: Int32
    public let windowIdentifier: UInt32
    public let title: String?
    public let frame: AdapterRect
    public let isOnScreen: Bool

    public init(
        bundleIdentifier: String?,
        processIdentifier: Int32,
        windowIdentifier: UInt32,
        title: String?,
        frame: AdapterRect,
        isOnScreen: Bool
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.windowIdentifier = windowIdentifier
        self.title = title
        self.frame = frame
        self.isOnScreen = isOnScreen
    }
}

public struct CaptureEvidence: Codable, Equatable, Sendable {
    public let captureIdentifier: String
    public let target: TargetWindowDescriptor
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let pngPath: String
    public let pngSHA256: String
    public let capturedAt: String

    public init(
        captureIdentifier: String,
        target: TargetWindowDescriptor,
        pixelWidth: Int,
        pixelHeight: Int,
        pngPath: String,
        pngSHA256: String,
        capturedAt: String
    ) {
        self.captureIdentifier = captureIdentifier
        self.target = target
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.pngPath = pngPath
        self.pngSHA256 = pngSHA256
        self.capturedAt = capturedAt
    }
}

public enum PrivilegedAction: Codable, Equatable, Sendable {
    case click(captureIdentifier: String, point: AdapterPoint, button: MouseButton)
    case drag(captureIdentifier: String, from: AdapterPoint, to: AdapterPoint)
    case openWorldMap(captureIdentifier: String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case captureIdentifier = "capture_id"
        case point
        case button
        case from
        case to
    }

    private enum Kind: String, Codable {
        case click
        case drag
        case openWorldMap = "open_world_map"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .click:
            self = .click(
                captureIdentifier: try container.decode(String.self, forKey: .captureIdentifier),
                point: try container.decode(AdapterPoint.self, forKey: .point),
                button: try container.decode(MouseButton.self, forKey: .button)
            )
        case .drag:
            self = .drag(
                captureIdentifier: try container.decode(String.self, forKey: .captureIdentifier),
                from: try container.decode(AdapterPoint.self, forKey: .from),
                to: try container.decode(AdapterPoint.self, forKey: .to)
            )
        case .openWorldMap:
            self = .openWorldMap(
                captureIdentifier: try container.decode(String.self, forKey: .captureIdentifier)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .click(captureIdentifier, point, button):
            try container.encode(Kind.click, forKey: .kind)
            try container.encode(captureIdentifier, forKey: .captureIdentifier)
            try container.encode(point, forKey: .point)
            try container.encode(button, forKey: .button)
        case let .drag(captureIdentifier, from, to):
            try container.encode(Kind.drag, forKey: .kind)
            try container.encode(captureIdentifier, forKey: .captureIdentifier)
            try container.encode(from, forKey: .from)
            try container.encode(to, forKey: .to)
        case let .openWorldMap(captureIdentifier):
            try container.encode(Kind.openWorldMap, forKey: .kind)
            try container.encode(captureIdentifier, forKey: .captureIdentifier)
        }
    }
}

public struct AdapterRequest: Codable, Sendable {
    public let id: String
    public let method: String
    public let capability: String?
    public let selector: TargetSelector?
    public let queueManifestPath: String?
    public let queueManifestSHA256: String?
    public let action: PrivilegedAction?
    public let semanticRole: SemanticActionRole?
    public let eventSourceMode: EventSourceMode?
    public let deliveryMode: InputDeliveryMode?
    public let jobIdentifier: String?
    public let queueGeneration: String?
    public let success: Bool?
    public let resultPath: String?
    public let resultFileSHA256: String?
    public let resultDigest: String?

    public init(
        id: String = UUID().uuidString,
        method: String,
        capability: String? = nil,
        selector: TargetSelector? = nil,
        queueManifestPath: String? = nil,
        queueManifestSHA256: String? = nil,
        action: PrivilegedAction? = nil,
        semanticRole: SemanticActionRole? = nil,
        eventSourceMode: EventSourceMode? = nil,
        deliveryMode: InputDeliveryMode? = nil,
        jobIdentifier: String? = nil,
        queueGeneration: String? = nil,
        success: Bool? = nil,
        resultPath: String? = nil,
        resultFileSHA256: String? = nil,
        resultDigest: String? = nil
    ) {
        self.id = id
        self.method = method
        self.capability = capability
        self.selector = selector
        self.queueManifestPath = queueManifestPath
        self.queueManifestSHA256 = queueManifestSHA256
        self.action = action
        self.semanticRole = semanticRole
        self.eventSourceMode = eventSourceMode
        self.deliveryMode = deliveryMode
        self.jobIdentifier = jobIdentifier
        self.queueGeneration = queueGeneration
        self.success = success
        self.resultPath = resultPath
        self.resultFileSHA256 = resultFileSHA256
        self.resultDigest = resultDigest
    }

    enum CodingKeys: String, CodingKey {
        case id
        case method
        case capability
        case selector
        case queueManifestPath = "queue_manifest_path"
        case queueManifestSHA256 = "queue_manifest_sha256"
        case action
        case semanticRole = "semantic_role"
        case eventSourceMode = "event_source_mode"
        case deliveryMode = "delivery_mode"
        case jobIdentifier = "job_id"
        case queueGeneration = "queue_generation"
        case success
        case resultPath = "result_path"
        case resultFileSHA256 = "result_file_sha256"
        case resultDigest = "result_digest"
    }
}

public struct AdapterResponse: Codable, Sendable {
    public let id: String
    public let ok: Bool
    public let state: AdapterState
    public let error: String?
    public let status: AdapterStatus?
    public let capture: CaptureEvidence?
    public let queueClaim: QueueClaim?
    public let inputEvidence: EvidenceReference?
    public let diagnostics: AdapterDiagnostics?
    public let message: String?

    public init(
        id: String,
        ok: Bool,
        state: AdapterState,
        error: String? = nil,
        status: AdapterStatus? = nil,
        capture: CaptureEvidence? = nil,
        queueClaim: QueueClaim? = nil,
        inputEvidence: EvidenceReference? = nil,
        diagnostics: AdapterDiagnostics? = nil,
        message: String? = nil
    ) {
        self.id = id
        self.ok = ok
        self.state = state
        self.error = error
        self.status = status
        self.capture = capture
        self.queueClaim = queueClaim
        self.inputEvidence = inputEvidence
        self.diagnostics = diagnostics
        self.message = message
    }
}

public struct AdapterBuildIdentity: Codable, Equatable, Sendable {
    public let bundleIdentifier: String
    public let version: String
    public let buildNumber: String
    public let sourceCommit: String
    public let signingCertificateSHA256: String
    public let cdHash: String
    public let designatedRequirement: String

    public init(
        bundleIdentifier: String,
        version: String,
        buildNumber: String,
        sourceCommit: String,
        signingCertificateSHA256: String,
        cdHash: String,
        designatedRequirement: String
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.buildNumber = buildNumber
        self.sourceCommit = sourceCommit
        self.signingCertificateSHA256 = signingCertificateSHA256
        self.cdHash = cdHash
        self.designatedRequirement = designatedRequirement
    }

    enum CodingKeys: String, CodingKey {
        case bundleIdentifier = "bundle_identifier"
        case version
        case buildNumber = "build_number"
        case sourceCommit = "source_commit"
        case signingCertificateSHA256 = "signing_certificate_sha256"
        case cdHash = "cdhash"
        case designatedRequirement = "designated_requirement"
    }
}

public struct AdapterHostStatus: Codable, Equatable, Sendable {
    public let instanceIdentifier: String?
    public let buildIdentity: AdapterBuildIdentity?
    public let installPath: String?
    public let menuVisible: Bool
    public let loginItemRegistered: Bool
    public let loginItemState: String
    public let workerProcessIdentifier: Int32?
    public let workerHealthy: Bool
    public let inFlightPhase: String?

    public init(
        instanceIdentifier: String? = nil,
        buildIdentity: AdapterBuildIdentity? = nil,
        installPath: String? = nil,
        menuVisible: Bool = false,
        loginItemRegistered: Bool = false,
        loginItemState: String = "unknown",
        workerProcessIdentifier: Int32? = nil,
        workerHealthy: Bool = false,
        inFlightPhase: String? = nil
    ) {
        self.instanceIdentifier = instanceIdentifier
        self.buildIdentity = buildIdentity
        self.installPath = installPath
        self.menuVisible = menuVisible
        self.loginItemRegistered = loginItemRegistered
        self.loginItemState = loginItemState
        self.workerProcessIdentifier = workerProcessIdentifier
        self.workerHealthy = workerHealthy
        self.inFlightPhase = inFlightPhase
    }

    enum CodingKeys: String, CodingKey {
        case instanceIdentifier = "instance_id"
        case buildIdentity = "build_identity"
        case installPath = "install_path"
        case menuVisible = "menu_visible"
        case loginItemRegistered = "login_item_registered"
        case loginItemState = "login_item_state"
        case workerProcessIdentifier = "worker_pid"
        case workerHealthy = "worker_healthy"
        case inFlightPhase = "in_flight_phase"
    }
}

public struct AdapterDiagnostics: Codable, Equatable, Sendable {
    public let runtimeRoot: String
    public let socketPath: String
    public let lockPath: String
    public let socketPresent: Bool
    public let lockHeld: Bool
    public let targetWindowBound: Bool
    public let workerClosureVerified: Bool

    public init(
        runtimeRoot: String,
        socketPath: String,
        lockPath: String,
        socketPresent: Bool,
        lockHeld: Bool,
        targetWindowBound: Bool,
        workerClosureVerified: Bool
    ) {
        self.runtimeRoot = runtimeRoot
        self.socketPath = socketPath
        self.lockPath = lockPath
        self.socketPresent = socketPresent
        self.lockHeld = lockHeld
        self.targetWindowBound = targetWindowBound
        self.workerClosureVerified = workerClosureVerified
    }

    enum CodingKeys: String, CodingKey {
        case runtimeRoot = "runtime_root"
        case socketPath = "socket_path"
        case lockPath = "lock_path"
        case socketPresent = "socket_present"
        case lockHeld = "lock_held"
        case targetWindowBound = "target_window_bound"
        case workerClosureVerified = "worker_closure_verified"
    }
}

public struct AdapterStatus: Codable, Equatable, Sendable {
    public let state: AdapterState
    public let enabled: Bool
    public let target: TargetWindowDescriptor?
    public let activeQueueGeneration: String?
    public let activeItemIdentifier: String?
    public let lastError: String?
    public let permissions: PermissionSnapshot
    public let host: AdapterHostStatus

    public init(
        state: AdapterState,
        enabled: Bool,
        target: TargetWindowDescriptor?,
        activeQueueGeneration: String?,
        activeItemIdentifier: String?,
        lastError: String?,
        permissions: PermissionSnapshot,
        host: AdapterHostStatus = AdapterHostStatus()
    ) {
        self.state = state
        self.enabled = enabled
        self.target = target
        self.activeQueueGeneration = activeQueueGeneration
        self.activeItemIdentifier = activeItemIdentifier
        self.lastError = lastError
        self.permissions = permissions
        self.host = host
    }
}

public enum AdapterError: Error, CustomStringConvertible, Sendable {
    case permissionRequired(String)
    case targetNotFound
    case targetAmbiguous(Int)
    case targetNotOnScreen
    case staleCapture
    case actionNotAllowed(String)
    case invariantViolation([String], EvidenceReference)
    case malformedRequest(String)
    case backgroundUnsupported(String)
    case foregroundLeaseFailed(String, EvidenceReference)
    case unauthorized
    case queueRejected(String)
    case queueUnavailable

    public var description: String {
        switch self {
        case let .permissionRequired(permission): return "PERMISSION_REQUIRED:\(permission)"
        case .targetNotFound: return "TARGET_NOT_FOUND"
        case let .targetAmbiguous(count): return "TARGET_AMBIGUOUS:\(count)"
        case .targetNotOnScreen: return "TARGET_NOT_ON_SCREEN"
        case .staleCapture: return "STALE_CAPTURE"
        case let .actionNotAllowed(reason): return "ACTION_NOT_ALLOWED:\(reason)"
        case let .invariantViolation(violations, evidence):
            return "FOCUS_INVARIANT_VIOLATION:\(violations.joined(separator: ",")):EVIDENCE=\(evidence.path)#sha256=\(evidence.sha256)"
        case let .malformedRequest(reason): return "MALFORMED_REQUEST:\(reason)"
        case let .backgroundUnsupported(reason): return "BACKGROUND_UNSUPPORTED:\(reason)"
        case let .foregroundLeaseFailed(reason, evidence):
            return "FOREGROUND_LEASE_FAILED:\(reason):EVIDENCE=\(evidence.path)#sha256=\(evidence.sha256)"
        case .unauthorized: return "UNAUTHORIZED"
        case let .queueRejected(reason): return "QUEUE_REJECTED:\(reason)"
        case .queueUnavailable: return "QUEUE_UNAVAILABLE"
        }
    }
}
