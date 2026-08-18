import Foundation

public struct NodeWorkerConfiguration: Sendable {
    public let nodeExecutable: URL
    public let workerEntryPoint: URL
    public let socketPath: String
    public let workerCapability: String
    public let logDirectory: URL
    public let expectedRuntimeIdentity: WorkerRuntimeIdentity?

    public init(
        nodeExecutable: URL,
        workerEntryPoint: URL,
        socketPath: String,
        workerCapability: String,
        logDirectory: URL,
        expectedRuntimeIdentity: WorkerRuntimeIdentity? = nil
    ) {
        self.nodeExecutable = nodeExecutable
        self.workerEntryPoint = workerEntryPoint
        self.socketPath = socketPath
        self.workerCapability = workerCapability
        self.logDirectory = logDirectory
        self.expectedRuntimeIdentity = expectedRuntimeIdentity
    }
}

public enum NodeWorkerEnvironmentPolicy {
    public static func sanitized(
        from environment: [String: String] = ProcessInfo.processInfo.environment,
        socketPath: String,
        workerCapability: String,
        parentProcessIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier
    ) -> [String: String] {
        var result: [String: String] = [
            "PATH": "/usr/bin:/bin",
            "OSRS_ADAPTER_SOCKET": socketPath,
            "OSRS_ADAPTER_WORKER_CAPABILITY": workerCapability,
            "OSRS_ADAPTER_PARENT_PID": String(parentProcessIdentifier)
        ]
        for key in ["HOME", "TMPDIR", "LANG", "LC_ALL"] {
            if let value = environment[key] { result[key] = value }
        }
        return result
    }
}

public actor NodeWorkerSupervisor {
    private var process: Process?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private(set) public var lastTerminationStatus: Int32?

    public init() {}

    public func start(_ configuration: NodeWorkerConfiguration) throws {
        guard process?.isRunning != true else { return }
        let version = try nodeVersion(configuration.nodeExecutable)
        guard version.hasPrefix("v26.") else {
            throw AdapterError.backgroundUnsupported("NODE_26_REQUIRED:\(version)")
        }
        if let expected = configuration.expectedRuntimeIdentity {
            let current = try WorkerRuntimeIdentityVerifier.verify(
                nodeExecutable: configuration.nodeExecutable,
                workerRoot: URL(fileURLWithPath: expected.workerRootPath),
                workerEntryPoint: configuration.workerEntryPoint,
                closureManifest: URL(fileURLWithPath: expected.workerClosureManifestPath)
            )
            guard WorkerRuntimeIdentityVerifier.equivalentRuntime(expected, current) else {
                throw AdapterError.backgroundUnsupported("WORKER_RUNTIME_IDENTITY_CHANGED")
            }
        }
        try FileManager.default.createDirectory(
            at: configuration.logDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let stdout = try openLog(configuration.logDirectory.appendingPathComponent("worker.stdout.log"))
        let stderr = try openLog(configuration.logDirectory.appendingPathComponent("worker.stderr.log"))
        let child = Process()
        child.executableURL = configuration.nodeExecutable
        child.arguments = [configuration.workerEntryPoint.path]
        child.currentDirectoryURL = configuration.workerEntryPoint.deletingLastPathComponent()
            .deletingLastPathComponent()
        child.environment = NodeWorkerEnvironmentPolicy.sanitized(
            socketPath: configuration.socketPath,
            workerCapability: configuration.workerCapability
        )
        child.standardOutput = stdout
        child.standardError = stderr
        child.terminationHandler = { [weak self] terminated in
            Task { await self?.recordTermination(terminated.terminationStatus) }
        }
        try child.run()
        process = child
        stdoutHandle = stdout
        stderrHandle = stderr
        lastTerminationStatus = nil
    }

    public func stop() async {
        guard let process else { return }
        if process.isRunning {
            process.terminate()
            let waiter = ProcessWaiter(process)
            await Task.detached(priority: .utility) {
                waiter.waitUntilExit()
            }.value
        }
        self.process = nil
        try? stdoutHandle?.close()
        try? stderrHandle?.close()
        stdoutHandle = nil
        stderrHandle = nil
    }

    public func isRunning() -> Bool {
        process?.isRunning == true
    }

    public func processIdentifier() -> Int32? {
        guard process?.isRunning == true else { return nil }
        return process?.processIdentifier
    }

    private func recordTermination(_ status: Int32) {
        lastTerminationStatus = status
        process = nil
        try? stdoutHandle?.close()
        try? stderrHandle?.close()
        stdoutHandle = nil
        stderrHandle = nil
    }

    private func nodeVersion(_ executable: URL) throws -> String {
        let probe = Process()
        let pipe = Pipe()
        probe.executableURL = executable
        probe.arguments = ["--version"]
        probe.standardOutput = pipe
        probe.standardError = pipe
        try probe.run()
        probe.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let value = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard probe.terminationStatus == 0 else {
            throw AdapterError.backgroundUnsupported("NODE_VERSION_PROBE_FAILED:\(value)")
        }
        return value
    }

    private func openLog(_ url: URL) throws -> FileHandle {
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(
                atPath: url.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw AdapterError.backgroundUnsupported("WORKER_LOG_CREATE_FAILED")
            }
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        return handle
    }
}

private final class ProcessWaiter: @unchecked Sendable {
    private let process: Process

    init(_ process: Process) {
        self.process = process
    }

    func waitUntilExit() {
        process.waitUntilExit()
    }
}
