import ApplicationServices
import CoreGraphics
import Foundation

public struct PermissionSnapshot: Codable, Equatable, Sendable {
    public let screenRecording: Bool
    public let accessibility: Bool
    public let inputMonitoring: Bool

    public init(screenRecording: Bool, accessibility: Bool, inputMonitoring: Bool) {
        self.screenRecording = screenRecording
        self.accessibility = accessibility
        self.inputMonitoring = inputMonitoring
    }

    public var allRequiredGranted: Bool {
        screenRecording && accessibility && inputMonitoring
    }
}

public enum AdapterPermissions {
    public static func snapshot() -> PermissionSnapshot {
        PermissionSnapshot(
            screenRecording: CGPreflightScreenCaptureAccess(),
            accessibility: AXIsProcessTrusted(),
            inputMonitoring: CGPreflightListenEventAccess()
        )
    }

    @discardableResult
    public static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    public static func requestAccessibilityPrompt() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    @discardableResult
    public static func requestInputMonitoring() -> Bool {
        CGRequestListenEventAccess()
    }
}
