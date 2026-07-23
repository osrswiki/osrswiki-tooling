#!/usr/bin/env swift

import Foundation

func repositoryRoot(startingAt start: URL) -> URL? {
    var current = start
    while current.pathComponents.count > 1 {
        let script = current.appendingPathComponent("scripts/ios/generate-settings-preview-assets.sh")
        let project = current.appendingPathComponent("platforms/ios/osrswiki.xcodeproj")
        if FileManager.default.isExecutableFile(atPath: script.path),
           FileManager.default.fileExists(atPath: project.path) {
            return current
        }
        current.deleteLastPathComponent()
    }
    return nil
}

let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

guard let root = repositoryRoot(startingAt: cwd) else {
    fputs("Could not locate repository root containing scripts/ios/generate-settings-preview-assets.sh\n", stderr)
    exit(1)
}

let script = root.appendingPathComponent("scripts/ios/generate-settings-preview-assets.sh")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/bin/zsh")
process.arguments = [script.path] + Array(CommandLine.arguments.dropFirst())
process.currentDirectoryURL = root
process.standardInput = FileHandle.standardInput
process.standardOutput = FileHandle.standardOutput
process.standardError = FileHandle.standardError

do {
    try process.run()
    process.waitUntilExit()
    exit(process.terminationStatus)
} catch {
    fputs("Failed to run \(script.path): \(error)\n", stderr)
    exit(1)
}
