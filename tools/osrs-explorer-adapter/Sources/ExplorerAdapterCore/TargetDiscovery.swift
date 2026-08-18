@preconcurrency import ScreenCaptureKit
import Foundation

public final class ResolvedTarget: @unchecked Sendable {
    public let descriptor: TargetWindowDescriptor
    let window: SCWindow

    init(descriptor: TargetWindowDescriptor, window: SCWindow) {
        self.descriptor = descriptor
        self.window = window
    }
}

public struct TargetDiscovery: Sendable {
    public init() {}

    public func resolve(_ selector: TargetSelector) async throws -> ResolvedTarget {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        let candidates = content.windows.filter { window in
            guard window.windowLayer == 0 else { return false }
            guard window.frame.width > 0, window.frame.height > 0 else { return false }
            if let bundleIdentifier = selector.bundleIdentifier,
               window.owningApplication?.bundleIdentifier != bundleIdentifier {
                return false
            }
            if let processIdentifier = selector.processIdentifier,
               window.owningApplication?.processID != processIdentifier {
                return false
            }
            guard TargetWindowSelection.acceptsPrimaryTitle(
                selectorBundleIdentifier: selector.bundleIdentifier,
                windowTitle: window.title
            ) else { return false }
            if let titleContains = selector.titleContains,
               !(window.title ?? "").localizedCaseInsensitiveContains(titleContains) {
                return false
            }
            return true
        }

        let selectedIndex = try TargetWindowSelection.selectedIndex(
            candidates.map(\.isOnScreen)
        )
        let window = candidates[selectedIndex]
        guard let application = window.owningApplication else {
            throw AdapterError.targetNotFound
        }
        let descriptor = TargetWindowDescriptor(
            bundleIdentifier: application.bundleIdentifier,
            processIdentifier: application.processID,
            windowIdentifier: window.windowID,
            title: window.title,
            frame: AdapterRect(window.frame),
            isOnScreen: window.isOnScreen
        )
        return ResolvedTarget(descriptor: descriptor, window: window)
    }
}

enum TargetWindowSelection {
    static func acceptsPrimaryTitle(
        selectorBundleIdentifier: String?,
        windowTitle: String?
    ) -> Bool {
        guard selectorBundleIdentifier == osrsTargetBundleIdentifier else { return true }
        return windowTitle == "Old School RuneScape"
    }

    static func selectedIndex(_ onScreenStates: [Bool]) throws -> Int {
        guard !onScreenStates.isEmpty else { throw AdapterError.targetNotFound }
        let visibleIndices = onScreenStates.indices.filter { onScreenStates[$0] }
        guard !visibleIndices.isEmpty else { throw AdapterError.targetNotOnScreen }
        guard visibleIndices.count == 1 else {
            throw AdapterError.targetAmbiguous(visibleIndices.count)
        }
        return visibleIndices[0]
    }
}
