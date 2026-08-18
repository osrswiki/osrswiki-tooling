import Darwin
import Foundation

public enum ArtifactPathPolicy {
    public static func validateDescendant(
        _ candidate: URL,
        of root: URL
    ) throws -> URL {
        guard candidate.path.hasPrefix("/"), root.path.hasPrefix("/") else {
            throw AdapterError.queueRejected("ARTIFACT_ROOT_NOT_ABSOLUTE")
        }
        let normalizedRoot = root.standardizedFileURL
        let normalizedCandidate = candidate.standardizedFileURL
        guard normalizedCandidate.path != normalizedRoot.path,
              normalizedCandidate.path.hasPrefix(normalizedRoot.path + "/") else {
            throw AdapterError.queueRejected("ARTIFACT_ROOT_OUTSIDE_EVIDENCE_ROOT")
        }
        try rejectSymlinkComponents(from: normalizedRoot, to: normalizedCandidate)
        return normalizedCandidate
    }

    private static func rejectSymlinkComponents(from root: URL, to candidate: URL) throws {
        var current = root
        let relative = candidate.path.dropFirst(root.path.count + 1)
        for component in relative.split(separator: "/") {
            current.appendPathComponent(String(component))
            var metadata = stat()
            if lstat(current.path, &metadata) == 0 {
                guard metadata.st_mode & S_IFMT != S_IFLNK else {
                    throw AdapterError.queueRejected("ARTIFACT_PATH_SYMLINK_FORBIDDEN")
                }
                continue
            }
            guard errno == ENOENT else {
                throw AdapterError.queueRejected("ARTIFACT_PATH_INSPECTION_FAILED:\(errno)")
            }
            return
        }
    }
}
