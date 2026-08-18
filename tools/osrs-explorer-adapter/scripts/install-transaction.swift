import Darwin
import Foundation

guard CommandLine.arguments.count == 10 || CommandLine.arguments.count == 11 else {
    fail("usage: install-transaction.swift STAGING_APP DESTINATION_APP LOCK_PATH VERIFIER NODE BUILD SOURCE_ROOT SOURCE_COMMIT SIGNING_POLICY [--inject-post-swap-failure]", code: 64)
}

let staging = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
let destination = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
let lockPath = URL(fileURLWithPath: CommandLine.arguments[3]).standardizedFileURL
let verifier = URL(fileURLWithPath: CommandLine.arguments[4]).standardizedFileURL
let node = URL(fileURLWithPath: CommandLine.arguments[5]).standardizedFileURL
let verifierArguments = Array(CommandLine.arguments[6...9])
let injectFailure = CommandLine.arguments.count == 11
    && CommandLine.arguments[10] == "--inject-post-swap-failure"
let fileManager = FileManager.default

guard staging.deletingLastPathComponent() == destination.deletingLastPathComponent() else {
    fail("INSTALL_TRANSACTION_REQUIRES_SAME_PARENT", code: 65)
}
guard fileManager.fileExists(atPath: staging.path) else {
    fail("INSTALL_STAGING_APP_MISSING", code: 66)
}

let lockDescriptor = Darwin.open(lockPath.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
guard lockDescriptor >= 0 else {
    fail("INSTANCE_LOCK_OPEN_FAILED:\(posixError())", code: 67)
}
defer {
    flock(lockDescriptor, LOCK_UN)
    Darwin.close(lockDescriptor)
}
guard flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else {
    fail("ADAPTER_INSTANCE_LOCK_HELD", code: 73)
}

let hadDestination = fileManager.fileExists(atPath: destination.path)
guard replace(staging, destination, destinationExists: hadDestination) else {
    fail("INSTALL_ATOMIC_REPLACE_FAILED:\(posixError())", code: 68)
}
syncDirectory(destination.deletingLastPathComponent())

let verification = injectFailure
    ? (false, "INJECTED_POST_SWAP_FAILURE")
    : runVerifier(
        node: node,
        verifier: verifier,
        build: verifierArguments[0],
        installed: destination.path,
        sourceRoot: verifierArguments[1],
        sourceCommit: verifierArguments[2],
        signingPolicy: verifierArguments[3]
    )

guard verification.0 else {
    let rolledBack = hadDestination
        ? replace(staging, destination, destinationExists: true)
        : replace(destination, staging, destinationExists: false)
    syncDirectory(destination.deletingLastPathComponent())
    guard rolledBack else {
        fail("INSTALL_ROLLBACK_FAILED:\(verification.1):\(posixError())", code: 70)
    }
    fail("INSTALL_POST_VERIFY_FAILED:\(verification.1)", code: 69)
}

if hadDestination, fileManager.fileExists(atPath: staging.path) {
    do {
        try fileManager.removeItem(at: staging)
    } catch {
        fail("PRIOR_RELEASE_DISPOSITION_FAILED:\(error)", code: 71)
    }
}
syncDirectory(destination.deletingLastPathComponent())
FileHandle.standardOutput.write(Data("INSTALL_TRANSACTION_COMPLETE\n".utf8))

private func replace(_ source: URL, _ destination: URL, destinationExists: Bool) -> Bool {
    let result: Int32
    if destinationExists {
        result = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                renameatx_np(
                    AT_FDCWD,
                    sourcePath,
                    AT_FDCWD,
                    destinationPath,
                    UInt32(RENAME_SWAP)
                )
            }
        }
    } else {
        result = rename(source.path, destination.path)
    }
    return result == 0
}

private func runVerifier(
    node: URL,
    verifier: URL,
    build: String,
    installed: String,
    sourceRoot: String,
    sourceCommit: String,
    signingPolicy: String
) -> (Bool, String) {
    let process = Process()
    let output = Pipe()
    process.executableURL = node
    process.arguments = [
        verifier.path,
        build,
        installed,
        sourceRoot,
        sourceCommit,
        signingPolicy
    ]
    process.standardOutput = output
    process.standardError = output
    do {
        try process.run()
        process.waitUntilExit()
        let detail = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus == 0, detail)
    } catch {
        return (false, String(describing: error))
    }
}

private func syncDirectory(_ directory: URL) {
    let descriptor = Darwin.open(directory.path, O_RDONLY | O_CLOEXEC)
    guard descriptor >= 0 else { return }
    _ = fsync(descriptor)
    Darwin.close(descriptor)
}

private func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    Foundation.exit(code)
}

private func posixError() -> String {
    String(cString: strerror(errno))
}
