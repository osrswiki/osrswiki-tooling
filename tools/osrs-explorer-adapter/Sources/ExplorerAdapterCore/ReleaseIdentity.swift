import Foundation

public enum AdapterReleaseIdentityReader {
    public static let bundleIdentifier = "com.omiyawaki.osrswiki.explorer-adapter"

    public static func read(bundle: Bundle) throws -> AdapterBuildIdentity {
        guard let bundleIdentifier = bundle.bundleIdentifier,
              let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let buildNumber = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              let sourceCommit = bundle.object(forInfoDictionaryKey: "OSRSAdapterSourceCommit") as? String,
              let certificateSHA256 = bundle.object(
                  forInfoDictionaryKey: "OSRSAdapterSigningCertificateSHA256"
              ) as? String else {
            throw AdapterError.backgroundUnsupported("RELEASE_IDENTITY_INFO_MISSING")
        }
        guard bundleIdentifier == self.bundleIdentifier,
              version == "0.2.0",
              sourceCommit.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil,
              certificateSHA256.range(of: "^[0-9A-F]{64}$", options: .regularExpression) != nil else {
            throw AdapterError.backgroundUnsupported("RELEASE_IDENTITY_INFO_INVALID")
        }
        let signatureOutput = try command(
            executable: "/usr/bin/codesign",
            arguments: ["-d", "-r-", "--verbose=4", bundle.bundleURL.path]
        )
        let signature = try parseCodeSignature(signatureOutput)
        guard signature.designatedRequirement.contains("identifier \"\(self.bundleIdentifier)\""),
              signature.designatedRequirement.contains("certificate leaf = H\"") else {
            throw AdapterError.backgroundUnsupported("RELEASE_DESIGNATED_REQUIREMENT_INVALID")
        }
        return AdapterBuildIdentity(
            bundleIdentifier: bundleIdentifier,
            version: version,
            buildNumber: buildNumber,
            sourceCommit: sourceCommit,
            signingCertificateSHA256: certificateSHA256,
            cdHash: signature.cdHash,
            designatedRequirement: signature.designatedRequirement
        )
    }

    public static func parseCodeSignature(
        _ output: String
    ) throws -> (cdHash: String, designatedRequirement: String) {
        guard let cdHash = firstCapture(in: output, pattern: "(?m)^CDHash=([^\\n]+)$"),
              let requirement = firstCapture(
                  in: output,
                  pattern: "(?m)^(?:designated|Designated Requirement) =>? ?([^\\n]+)$"
              ) else {
            throw AdapterError.backgroundUnsupported("CODE_SIGNATURE_IDENTITY_MISSING")
        }
        return (cdHash.trimmingCharacters(in: .whitespaces), requirement.trimmingCharacters(in: .whitespaces))
    }

    private static func command(executable: String, arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let value = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        guard process.terminationStatus == 0 else {
            throw AdapterError.backgroundUnsupported("CODE_SIGNATURE_IDENTITY_FAILED:\(value)")
        }
        return value
    }

    private static func firstCapture(in value: String, pattern: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                  in: value,
                  range: NSRange(value.startIndex..., in: value)
              ),
              let range = Range(match.range(at: 1), in: value) else { return nil }
        return String(value[range])
    }
}

public enum ControlPanelFallbackPolicy {
    public static func isTerminalRuntimeCondition(_ state: AdapterState) -> Bool {
        state == .faulted || state == .backgroundUnsupported
    }

    public static func shouldPresent(
        isStartup: Bool,
        statusItemReportedVisible: Bool,
        statusItemReachabilityConfirmed: Bool,
        permissionsGranted: Bool,
        terminalRuntimeCondition: Bool
    ) -> Bool {
        _ = statusItemReportedVisible
        return isStartup
            || !statusItemReachabilityConfirmed
            || !permissionsGranted
            || terminalRuntimeCondition
    }
}

public struct ControlPanelFallbackTracker: Sendable {
    private var statusItemReachabilityConfirmed = false
    private var menuFallbackPresented = false
    private var permissionsFallbackActive = false
    private var terminalRuntimeFallbackActive = false

    public init() {}

    public mutating func confirmStatusItemReachability() {
        statusItemReachabilityConfirmed = true
    }

    public mutating func shouldPresent(
        isStartup: Bool,
        statusItemReportedVisible: Bool,
        permissionsGranted: Bool,
        terminalRuntimeCondition: Bool
    ) -> Bool {
        let menuFallbackNeeded = ControlPanelFallbackPolicy.shouldPresent(
            isStartup: isStartup,
            statusItemReportedVisible: statusItemReportedVisible,
            statusItemReachabilityConfirmed: statusItemReachabilityConfirmed,
            permissionsGranted: true,
            terminalRuntimeCondition: false
        ) && !menuFallbackPresented
        let permissionsFallbackNeeded = !permissionsGranted
        let terminalRuntimeFallbackNeeded = terminalRuntimeCondition
        let result = menuFallbackNeeded
            || (permissionsFallbackNeeded && !permissionsFallbackActive)
            || (terminalRuntimeFallbackNeeded && !terminalRuntimeFallbackActive)
        menuFallbackPresented = menuFallbackPresented || menuFallbackNeeded
        permissionsFallbackActive = permissionsFallbackNeeded
        terminalRuntimeFallbackActive = terminalRuntimeFallbackNeeded
        return result
    }
}

public enum StableReleaseValidationState: Equatable, Sendable {
    case pending
    case validated
    case rejected
}

public enum LaunchAtLoginStartupPolicy {
    public static func permitsReconciliation(
        validationState: StableReleaseValidationState
    ) -> Bool {
        validationState == .validated
    }
}

public enum LaunchAtLoginServiceState: String, Sendable {
    case enabled
    case notRegistered = "not_registered"
    case notFound = "not_found"
    case requiresApproval = "requires_approval"
    case unknown
}

public enum LaunchAtLoginReconciliationAction: Equatable, Sendable {
    case none
    case register
    case unregister
    case awaitApproval
    case reportUnknown
}

public enum LaunchAtLoginPolicy {
    public static func reconcile(
        desired: Bool,
        status: LaunchAtLoginServiceState
    ) -> LaunchAtLoginReconciliationAction {
        switch (desired, status) {
        case (true, .enabled), (false, .notRegistered), (false, .notFound):
            return .none
        case (true, .notRegistered), (true, .notFound):
            return .register
        case (false, .enabled), (false, .requiresApproval):
            return .unregister
        case (true, .requiresApproval):
            return .awaitApproval
        case (_, .unknown):
            return .reportUnknown
        }
    }
}

public struct LaunchAtLoginIntentStore {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "launchAtLoginDesired") {
        self.defaults = defaults
        self.key = key
    }

    @discardableResult
    public func initialize(defaultValue: Bool = true) -> Bool {
        if defaults.object(forKey: key) == nil {
            defaults.set(defaultValue, forKey: key)
        }
        return defaults.bool(forKey: key)
    }

    public var desired: Bool {
        defaults.object(forKey: key) == nil ? initialize() : defaults.bool(forKey: key)
    }

    public func setDesired(_ value: Bool) {
        defaults.set(value, forKey: key)
    }
}
