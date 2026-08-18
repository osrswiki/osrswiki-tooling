import AppKit
import Foundation
import ImageIO
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers

public struct CaptureService: Sendable {
    private let discovery: TargetDiscovery
    private let evidenceRoot: URL

    public init(
        discovery: TargetDiscovery = TargetDiscovery(),
        evidenceRoot: URL = FileManager.default.temporaryDirectory
    ) {
        self.discovery = discovery
        self.evidenceRoot = evidenceRoot
    }

    public func capture(
        selector: TargetSelector,
        evidenceDirectory: URL
    ) async throws -> CaptureEvidence {
        let evidenceDirectory = try ArtifactPathPolicy.validateDescendant(
            evidenceDirectory,
            of: evidenceRoot
        )
        guard CGPreflightScreenCaptureAccess() else {
            throw AdapterError.permissionRequired("SCREEN_RECORDING")
        }
        let resolved = try await discovery.resolve(selector)
        let scale = captureScale(for: resolved.descriptor.frame.cgRect)
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(resolved.window.frame.width * scale))
        configuration.height = max(1, Int(resolved.window.frame.height * scale))
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.ignoreShadowsSingleWindow = true

        let filter = SCContentFilter(desktopIndependentWindow: resolved.window)
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
        let identifier = UUID().uuidString.lowercased()
        let capturesDirectory = evidenceDirectory.appendingPathComponent("captures", isDirectory: true)
        try FileManager.default.createDirectory(
            at: capturesDirectory,
            withIntermediateDirectories: true
        )
        _ = try ArtifactPathPolicy.validateDescendant(capturesDirectory, of: evidenceRoot)
        let destination = capturesDirectory.appendingPathComponent("\(identifier).png")
        _ = try ArtifactPathPolicy.validateDescendant(destination, of: evidenceRoot)
        try writeImmutablePNG(image, to: destination)
        let digest = try AdapterHashing.sha256(fileAt: destination)
        return CaptureEvidence(
            captureIdentifier: identifier,
            target: resolved.descriptor,
            pixelWidth: image.width,
            pixelHeight: image.height,
            pngPath: destination.path,
            pngSHA256: digest,
            capturedAt: AdapterClock.now()
        )
    }

    private func captureScale(for frame: CGRect) -> CGFloat {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.first(where: { $0.frame.contains(center) })?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
    }

    private func writeImmutablePNG(_ image: CGImage, to destination: URL) throws {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw AdapterError.backgroundUnsupported("PNG_DESTINATION_EXISTS")
        }
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).tmp-\(UUID().uuidString)")
        guard fileManager.createFile(
            atPath: temporary.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw AdapterError.backgroundUnsupported("PNG_TEMPORARY_CREATE_FAILED")
        }
        do {
            try writePNG(image, to: temporary)
            let handle = try FileHandle(forWritingTo: temporary)
            try handle.synchronize()
            try handle.close()
            try fileManager.moveItem(at: temporary, to: destination)
            try fileManager.setAttributes(
                [.posixPermissions: 0o444],
                ofItemAtPath: destination.path
            )
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    private func writePNG(_ image: CGImage, to destination: URL) throws {
        guard let writer = CGImageDestinationCreateWithURL(
            destination as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw AdapterError.backgroundUnsupported("PNG_DESTINATION_CREATE_FAILED")
        }
        CGImageDestinationAddImage(writer, image, nil)
        guard CGImageDestinationFinalize(writer) else {
            throw AdapterError.backgroundUnsupported("PNG_FINALIZE_FAILED")
        }
    }
}

public enum CaptureFreshnessPolicy {
    public static let maximumAge: TimeInterval = 3

    public static func validate(
        capturedAt: String,
        now: Date = Date(),
        maximumAge: TimeInterval = maximumAge
    ) throws {
        guard let captured = AdapterClock.date(from: capturedAt),
              now.timeIntervalSince(captured) >= 0,
              now.timeIntervalSince(captured) <= maximumAge else {
            throw AdapterError.staleCapture
        }
    }
}
