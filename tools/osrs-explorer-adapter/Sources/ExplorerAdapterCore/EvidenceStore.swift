import Foundation

public struct EvidenceReference: Codable, Equatable, Sendable {
    public let path: String
    public let sha256: String
}

public struct EvidenceStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public func writeImmutable<T: Encodable & Sendable>(
        _ value: T,
        relativePath: String
    ) throws -> EvidenceReference {
        let destination = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).tmp-\(UUID().uuidString)")
        guard FileManager.default.createFile(
            atPath: temporary.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw AdapterError.backgroundUnsupported("EVIDENCE_CREATE_FAILED")
        }
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o444],
            ofItemAtPath: temporary.path
        )
        do {
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        return EvidenceReference(
            path: destination.path,
            sha256: AdapterHashing.sha256(data)
        )
    }
}
