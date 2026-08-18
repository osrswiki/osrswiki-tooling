import Foundation
import Security

public struct AdapterRuntimePaths: Sendable {
    public let root: URL
    public let lock: URL
    public let socket: URL
    public let controlSocket: URL
    public let showControlsRequests: URL
    public let showControlsAcknowledgements: URL

    public init(root: URL) {
        self.root = root
        lock = root.appendingPathComponent("adapter.lock")
        socket = root.appendingPathComponent("worker.sock")
        controlSocket = root.appendingPathComponent("control.sock")
        showControlsRequests = root.appendingPathComponent("show-controls-requests", isDirectory: true)
        showControlsAcknowledgements = root.appendingPathComponent(
            "show-controls-acknowledgements",
            isDirectory: true
        )
    }

    public static func stable(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> Self {
        Self(root: homeDirectory
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("OSRS Explorer Adapter", isDirectory: true)
            .appendingPathComponent("runtime", isDirectory: true))
    }
}

public struct AdapterCapabilities: Sendable {
    public let worker: String

    public init(worker: String) {
        self.worker = worker
    }
}

public enum CapabilityStore {
    public static func createFresh(
        at paths: AdapterRuntimePaths,
        ownedBy instanceLock: AdapterInstanceLock
    ) throws -> AdapterCapabilities {
        guard instanceLock.owns(paths: paths) else {
            throw AdapterError.unauthorized
        }
        try FileManager.default.createDirectory(
            at: paths.root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try enforceDirectoryMode(paths.root)
        for socket in [paths.socket, paths.controlSocket] {
            if FileManager.default.fileExists(atPath: socket.path) {
                try FileManager.default.removeItem(at: socket)
            }
        }
        return AdapterCapabilities(worker: try token())
    }

    private static func token() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw AdapterError.backgroundUnsupported("CAPABILITY_RANDOM_FAILED")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func enforceDirectoryMode(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
    }
}
