import Darwin
import Foundation

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: atomic-replace.swift SOURCE DESTINATION\n".utf8))
    exit(64)
}

let source = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
let destination = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
let fileManager = FileManager.default

guard source.deletingLastPathComponent() == destination.deletingLastPathComponent() else {
    FileHandle.standardError.write(Data("ATOMIC_REPLACE_REQUIRES_SAME_PARENT\n".utf8))
    exit(65)
}

let result: Int32
if fileManager.fileExists(atPath: destination.path) {
    result = source.path.withCString { sourcePath in
        destination.path.withCString { destinationPath in
            renameatx_np(AT_FDCWD, sourcePath, AT_FDCWD, destinationPath, UInt32(RENAME_SWAP))
        }
    }
} else {
    result = rename(source.path, destination.path)
}

guard result == 0 else {
    FileHandle.standardError.write(Data("ATOMIC_REPLACE_FAILED:\(String(cString: strerror(errno)))\n".utf8))
    exit(66)
}

if fileManager.fileExists(atPath: source.path) {
    try fileManager.removeItem(at: source)
}
