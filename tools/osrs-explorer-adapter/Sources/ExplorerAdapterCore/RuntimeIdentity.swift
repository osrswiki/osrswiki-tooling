import Foundation

public struct WorkerRuntimeFile: Codable, Equatable, Sendable {
    public let path: String
    public let sha256: String
    public let size: Int
    public let mode: String
}

public struct WorkerRuntimeClosure: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let files: [WorkerRuntimeFile]
    public let closureSHA256: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case files
        case closureSHA256 = "closure_sha256"
    }
}

public struct WorkerRuntimeIdentity: Codable, Equatable, Sendable {
    public let nodeConfiguredPath: String
    public let nodeResolvedPath: String
    public let nodeSHA256: String
    public let nodeVersion: String
    public let workerRootPath: String
    public let workerEntryPointPath: String
    public let workerClosureManifestPath: String
    public let workerClosureManifestSHA256: String
    public let workerClosureSHA256: String
    public let workerFileCount: Int
    public let verifiedAt: String
}

public enum WorkerRuntimeIdentityVerifier {
    public static func verify(
        nodeExecutable: URL,
        workerRoot: URL,
        workerEntryPoint: URL,
        closureManifest: URL
    ) throws -> WorkerRuntimeIdentity {
        let normalizedRoot = workerRoot.resolvingSymlinksInPath().standardizedFileURL
        let normalizedEntry = workerEntryPoint.resolvingSymlinksInPath().standardizedFileURL
        guard normalizedEntry.path == normalizedRoot.appendingPathComponent("src/worker.mjs").path else {
            throw AdapterError.backgroundUnsupported("BUNDLED_WORKER_ENTRYPOINT_REQUIRED")
        }
        guard FileManager.default.isExecutableFile(atPath: nodeExecutable.path) else {
            throw AdapterError.backgroundUnsupported("NODE_EXECUTABLE_NOT_FOUND")
        }
        let resolvedNode = nodeExecutable.resolvingSymlinksInPath()
        let manifestData = try Data(contentsOf: closureManifest, options: .mappedIfSafe)
        let manifest = try JSONDecoder().decode(WorkerRuntimeClosure.self, from: manifestData)
        guard manifest.schemaVersion == 1, !manifest.files.isEmpty else {
            throw AdapterError.backgroundUnsupported("WORKER_CLOSURE_MANIFEST_INVALID")
        }

        let actualFiles = try describeFiles(in: normalizedRoot)
        guard Set(actualFiles.map(\.path)).count == actualFiles.count,
              Set(manifest.files.map(\.path)).count == manifest.files.count else {
            throw AdapterError.backgroundUnsupported("WORKER_RUNTIME_DUPLICATE_PATH")
        }
        let actualByPath = Dictionary(uniqueKeysWithValues: actualFiles.map { ($0.path, $0) })
        let manifestByPath = Dictionary(uniqueKeysWithValues: manifest.files.map { ($0.path, $0) })
        guard actualByPath == manifestByPath,
              actualFiles.count == manifest.files.count else {
            throw AdapterError.backgroundUnsupported("WORKER_RUNTIME_CLOSURE_MISMATCH")
        }
        let rawFiles: [[String: Any]] = manifest.files.map {
            ["path": $0.path, "sha256": $0.sha256, "size": $0.size, "mode": $0.mode]
        }
        let closureDigest = try CanonicalJSON.sha256(rawFiles)
        guard closureDigest == manifest.closureSHA256 else {
            throw AdapterError.backgroundUnsupported("WORKER_RUNTIME_DIGEST_MISMATCH")
        }
        let version = try nodeVersion(nodeExecutable)
        guard version.hasPrefix("v26.") else {
            throw AdapterError.backgroundUnsupported("NODE_26_REQUIRED:\(version)")
        }
        return WorkerRuntimeIdentity(
            nodeConfiguredPath: nodeExecutable.path,
            nodeResolvedPath: resolvedNode.path,
            nodeSHA256: try AdapterHashing.sha256(fileAt: resolvedNode),
            nodeVersion: version,
            workerRootPath: normalizedRoot.path,
            workerEntryPointPath: normalizedEntry.path,
            workerClosureManifestPath: closureManifest.standardizedFileURL.path,
            workerClosureManifestSHA256: AdapterHashing.sha256(manifestData),
            workerClosureSHA256: closureDigest,
            workerFileCount: actualFiles.count,
            verifiedAt: AdapterClock.now()
        )
    }

    public static func equivalentRuntime(
        _ lhs: WorkerRuntimeIdentity,
        _ rhs: WorkerRuntimeIdentity
    ) -> Bool {
        lhs.nodeConfiguredPath == rhs.nodeConfiguredPath
            && lhs.nodeResolvedPath == rhs.nodeResolvedPath
            && lhs.nodeSHA256 == rhs.nodeSHA256
            && lhs.nodeVersion == rhs.nodeVersion
            && lhs.workerRootPath == rhs.workerRootPath
            && lhs.workerEntryPointPath == rhs.workerEntryPointPath
            && lhs.workerClosureManifestPath == rhs.workerClosureManifestPath
            && lhs.workerClosureManifestSHA256 == rhs.workerClosureManifestSHA256
            && lhs.workerClosureSHA256 == rhs.workerClosureSHA256
            && lhs.workerFileCount == rhs.workerFileCount
    }

    private static func describeFiles(in root: URL) throws -> [WorkerRuntimeFile] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ) else {
            throw AdapterError.backgroundUnsupported("WORKER_RUNTIME_ENUMERATION_FAILED")
        }
        var files: [WorkerRuntimeFile] = []
        for case let url as URL in enumerator {
            if url.lastPathComponent == ".DS_Store" { continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw AdapterError.backgroundUnsupported("WORKER_RUNTIME_SYMLINK_FORBIDDEN")
            }
            guard values.isRegularFile == true else { continue }
            let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
            let rootPath = root.path + "/"
            guard resolvedURL.path.hasPrefix(rootPath) else {
                throw AdapterError.backgroundUnsupported("WORKER_RUNTIME_PATH_ESCAPE")
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: resolvedURL.path)
            let size = (attributes[.size] as? NSNumber)?.intValue ?? -1
            let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
            guard size >= 0, mode >= 0 else {
                throw AdapterError.backgroundUnsupported("WORKER_RUNTIME_METADATA_INVALID")
            }
            files.append(WorkerRuntimeFile(
                path: String(resolvedURL.path.dropFirst(rootPath.count)),
                sha256: try AdapterHashing.sha256(fileAt: resolvedURL),
                size: size,
                mode: String(format: "%04o", mode)
            ))
        }
        return files.sorted { $0.path < $1.path }
    }

    private static func nodeVersion(_ executable: URL) throws -> String {
        let probe = Process()
        let pipe = Pipe()
        probe.executableURL = executable
        probe.arguments = ["--version"]
        probe.standardOutput = pipe
        probe.standardError = pipe
        try probe.run()
        probe.waitUntilExit()
        let value = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard probe.terminationStatus == 0 else {
            throw AdapterError.backgroundUnsupported("NODE_VERSION_PROBE_FAILED:\(value)")
        }
        return value
    }
}
