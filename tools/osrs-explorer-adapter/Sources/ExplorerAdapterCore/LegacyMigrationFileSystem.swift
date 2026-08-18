import Darwin
import Foundation

struct LegacyMigrationIOHooks {
    var afterRecordOpen: ((URL) throws -> Void)?
    var beforeMarkerPublish: ((URL) throws -> Void)?

    init(
        afterRecordOpen: ((URL) throws -> Void)? = nil,
        beforeMarkerPublish: ((URL) throws -> Void)? = nil
    ) {
        self.afterRecordOpen = afterRecordOpen
        self.beforeMarkerPublish = beforeMarkerPublish
    }
}

struct LegacyMigrationDirectoryEntry {
    let url: URL
    let name: String
    fileprivate let identity: LegacyMigrationFileIdentity
    fileprivate let parentIdentity: LegacyMigrationFileIdentity
}

final class LegacyMigrationFileSystem {
    static let maximumRecordBytes = 1 * 1024 * 1024
    static let maximumManifestBytes = 4 * 1024 * 1024
    static let maximumEventMembers = 512
    static let maximumWorkerMembers = 256
    static let maximumDirectoryMembers = 65_536

    let root: URL

    private let physicalRoot: URL
    private let rootDescriptor: Int32
    private let rootIdentity: LegacyMigrationFileIdentity
    private let hooks: LegacyMigrationIOHooks

    init(
        root: URL,
        createRoot: Bool = false,
        hooks: LegacyMigrationIOHooks = LegacyMigrationIOHooks()
    ) throws {
        let normalized = root.standardizedFileURL
        guard normalized.path.hasPrefix("/"), normalized.path != "/" else {
            throw Self.failure("ROOT_PATH_INVALID")
        }
        if createRoot, !FileManager.default.fileExists(atPath: normalized.path) {
            try FileManager.default.createDirectory(
                at: normalized,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        let resolved = try Self.resolvedExistingDirectory(normalized)
        var configuredMetadata = stat()
        guard lstat(normalized.path, &configuredMetadata) == 0,
              configuredMetadata.st_mode & S_IFMT == S_IFDIR else {
            throw Self.failure("ROOT_FINAL_COMPONENT_UNSAFE")
        }
        self.root = normalized
        physicalRoot = resolved
        self.hooks = hooks
        rootDescriptor = try Self.openAbsoluteDirectory(resolved, create: createRoot)
        do {
            rootIdentity = try Self.identity(
                descriptor: rootDescriptor,
                requiredType: S_IFDIR,
                code: "ROOT_NOT_DIRECTORY"
            )
            guard LegacyMigrationFileIdentity(configuredMetadata).isSameObject(as: rootIdentity) else {
                throw Self.failure("ROOT_BINDING_MISMATCH")
            }
            try verifyRootBinding()
        } catch {
            close(rootDescriptor)
            throw error
        }
    }

    deinit {
        close(rootDescriptor)
    }

    func enumerateImmutableRegularFiles(
        at directory: URL,
        maximumMembers: Int,
        allowMissing: Bool,
        code: String,
        allowedDirectoryNames: Set<String> = []
    ) throws -> [LegacyMigrationDirectoryEntry] {
        try verifyRootBinding()
        let components = try relativeComponents(for: directory, allowRoot: false)
        guard let opened = try openDirectory(
            components: components,
            create: false,
            allowMissing: allowMissing,
            code: code
        ) else { return [] }
        defer { close(opened.descriptor) }

        let streamDescriptor = dup(opened.descriptor)
        guard streamDescriptor >= 0, let stream = fdopendir(streamDescriptor) else {
            if streamDescriptor >= 0 { close(streamDescriptor) }
            throw Self.failure("\(code)_ENUMERATION_OPEN_FAILED:\(errno)")
        }
        defer { closedir(stream) }

        var entries: [LegacyMigrationDirectoryEntry] = []
        var memberCount = 0
        errno = 0
        while let pointer = readdir(stream) {
            let name = withUnsafePointer(to: pointer.pointee.d_name) { tuplePointer in
                tuplePointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            guard Self.validComponent(name) else {
                throw Self.failure("\(code)_MEMBER_NAME_INVALID")
            }
            guard memberCount < maximumMembers else {
                throw Self.failure("\(code)_MEMBER_LIMIT_EXCEEDED")
            }
            memberCount += 1
            var metadata = stat()
            guard fstatat(opened.descriptor, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw Self.failure("\(code)_MEMBER_INSPECTION_FAILED:\(errno)")
            }
            let identity = LegacyMigrationFileIdentity(metadata)
            if identity.fileType == S_IFDIR, allowedDirectoryNames.contains(name) {
                guard identity.permissions == 0o700 else {
                    throw Self.failure("\(code)_DIRECTORY_PERMISSIONS_INVALID:\(name)")
                }
                continue
            }
            guard identity.fileType == S_IFREG else {
                throw Self.failure("\(code)_MEMBER_TYPE_FORBIDDEN:\(name)")
            }
            guard identity.permissions == 0o444 else {
                throw Self.failure("\(code)_MEMBER_NOT_IMMUTABLE:\(name)")
            }
            guard identity.size >= 0, identity.size <= Self.maximumManifestBytes else {
                throw Self.failure("\(code)_MEMBER_TOO_LARGE:\(name)")
            }
            entries.append(
                LegacyMigrationDirectoryEntry(
                    url: directory.appendingPathComponent(name),
                    name: name,
                    identity: identity,
                    parentIdentity: opened.identity
                )
            )
        }
        guard errno == 0 else {
            throw Self.failure("\(code)_ENUMERATION_FAILED:\(errno)")
        }
        try requireUnchanged(
            descriptor: opened.descriptor,
            initial: opened.identity,
            code: "\(code)_DIRECTORY_CHANGED"
        )
        try verifyDirectoryBinding(
            components: components,
            expected: opened.identity,
            code: "\(code)_DIRECTORY_REBOUND"
        )
        try verifyRootBinding()
        return entries.sorted { $0.name < $1.name }
    }

    func readImmutableRecord(
        _ entry: LegacyMigrationDirectoryEntry,
        maximumBytes: Int = LegacyMigrationFileSystem.maximumRecordBytes,
        code: String
    ) throws -> Data {
        try readImmutableRecord(
            at: entry.url,
            expectedIdentity: entry.identity,
            expectedParentIdentity: entry.parentIdentity,
            maximumBytes: maximumBytes,
            code: code,
            allowMissingParent: false
        )
    }

    func readImmutableRecord(
        at url: URL,
        maximumBytes: Int = LegacyMigrationFileSystem.maximumRecordBytes,
        code: String
    ) throws -> Data {
        try readImmutableRecord(
            at: url,
            expectedIdentity: nil,
            expectedParentIdentity: nil,
            maximumBytes: maximumBytes,
            code: code,
            allowMissingParent: false
        )
    }

    func readImmutableRecordIfPresent(
        at url: URL,
        maximumBytes: Int = LegacyMigrationFileSystem.maximumRecordBytes,
        code: String
    ) throws -> Data? {
        do {
            return try readImmutableRecord(
                at: url,
                expectedIdentity: nil,
                expectedParentIdentity: nil,
                maximumBytes: maximumBytes,
                code: code,
                allowMissingParent: true
            )
        } catch let error as LegacyMigrationMissingFileError {
            _ = error
            return nil
        }
    }

    func publishImmutableRecord(
        _ data: Data,
        at destination: URL,
        maximumBytes: Int = LegacyMigrationFileSystem.maximumRecordBytes,
        code: String
    ) throws -> Bool {
        guard maximumBytes > 0, maximumBytes <= Self.maximumManifestBytes else {
            throw Self.failure("\(code)_MAXIMUM_INVALID")
        }
        guard data.count <= maximumBytes else {
            throw Self.failure("\(code)_TOO_LARGE")
        }
        try verifyRootBinding()
        let components = try relativeComponents(for: destination, allowRoot: false)
        guard components.count >= 2 else {
            throw Self.failure("\(code)_DESTINATION_INVALID")
        }
        let parentComponents = Array(components.dropLast())
        let name = components.last!
        guard let parent = try openDirectory(
            components: parentComponents,
            create: true,
            allowMissing: false,
            code: code
        ) else {
            throw Self.failure("\(code)_PARENT_MISSING")
        }
        defer { close(parent.descriptor) }

        let temporaryName = ".\(name).tmp-\(UUID().uuidString)"
        let temporaryDescriptor = openat(
            parent.descriptor,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard temporaryDescriptor >= 0 else {
            throw Self.failure("\(code)_TEMP_CREATE_FAILED:\(errno)")
        }
        var temporaryExists = true
        defer {
            close(temporaryDescriptor)
            if temporaryExists {
                _ = unlinkat(parent.descriptor, temporaryName, 0)
            }
        }

        try Self.writeAll(data, to: temporaryDescriptor, code: code)
        guard fsync(temporaryDescriptor) == 0,
              fchmod(temporaryDescriptor, mode_t(0o444)) == 0,
              fsync(temporaryDescriptor) == 0 else {
            throw Self.failure("\(code)_TEMP_SEAL_FAILED:\(errno)")
        }

        try hooks.beforeMarkerPublish?(destination)
        try verifyRootBinding()
        try verifyDirectoryBinding(
            components: parentComponents,
            expected: parent.identity,
            code: "\(code)_PARENT_REBOUND"
        )

        let renameResult = renameatx_np(
            parent.descriptor,
            temporaryName,
            parent.descriptor,
            name,
            UInt32(RENAME_EXCL)
        )
        if renameResult != 0 {
            if errno == EEXIST { return false }
            throw Self.failure("\(code)_PUBLISH_FAILED:\(errno)")
        }
        temporaryExists = false
        guard fsync(parent.descriptor) == 0 else {
            _ = unlinkat(parent.descriptor, name, 0)
            throw Self.failure("\(code)_PARENT_SYNC_FAILED:\(errno)")
        }
        do {
            try verifyRootBinding()
            try verifyDirectoryBinding(
                components: parentComponents,
                expected: parent.identity,
                code: "\(code)_PARENT_REBOUND_AFTER_PUBLISH"
            )
        } catch {
            _ = unlinkat(parent.descriptor, name, 0)
            _ = fsync(parent.descriptor)
            throw error
        }
        return true
    }

    private func readImmutableRecord(
        at url: URL,
        expectedIdentity: LegacyMigrationFileIdentity?,
        expectedParentIdentity: LegacyMigrationFileIdentity?,
        maximumBytes: Int,
        code: String,
        allowMissingParent: Bool
    ) throws -> Data {
        try verifyRootBinding()
        let components = try relativeComponents(for: url, allowRoot: false)
        guard let name = components.last else {
            throw Self.failure("\(code)_PATH_INVALID")
        }
        let parentComponents = Array(components.dropLast())
        guard let parent = try openDirectory(
            components: parentComponents,
            create: false,
            allowMissing: allowMissingParent,
            code: code
        ) else {
            throw LegacyMigrationMissingFileError()
        }
        defer { close(parent.descriptor) }
        if let expectedParentIdentity, expectedParentIdentity != parent.identity {
            throw Self.failure("\(code)_PARENT_IDENTITY_DRIFT")
        }

        let descriptor = openat(
            parent.descriptor,
            name,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        if descriptor < 0, errno == ENOENT {
            throw LegacyMigrationMissingFileError()
        }
        guard descriptor >= 0 else {
            throw Self.failure("\(code)_OPEN_FAILED:\(errno)")
        }
        defer { close(descriptor) }

        let initial = try Self.identity(
            descriptor: descriptor,
            requiredType: S_IFREG,
            code: "\(code)_NOT_REGULAR"
        )
        guard initial.permissions == 0o444 else {
            throw Self.failure("\(code)_NOT_IMMUTABLE")
        }
        guard initial.size >= 0, initial.size <= maximumBytes else {
            throw Self.failure("\(code)_TOO_LARGE")
        }
        if let expectedIdentity, expectedIdentity != initial {
            throw Self.failure("\(code)_IDENTITY_DRIFT")
        }

        try hooks.afterRecordOpen?(url)
        try verifyNameBinding(
            parentDescriptor: parent.descriptor,
            name: name,
            expected: initial,
            code: "\(code)_NAME_REBOUND"
        )

        var data = Data()
        data.reserveCapacity(Int(initial.size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                read(descriptor, $0.baseAddress, $0.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw Self.failure("\(code)_READ_FAILED:\(errno)")
            }
            if count == 0 { break }
            guard data.count + count <= maximumBytes else {
                throw Self.failure("\(code)_TOO_LARGE_DURING_READ")
            }
            data.append(contentsOf: buffer[0..<count])
        }
        guard data.count == Int(initial.size) else {
            throw Self.failure("\(code)_SIZE_DRIFT")
        }
        try requireUnchanged(descriptor: descriptor, initial: initial, code: "\(code)_CHANGED")
        try verifyNameBinding(
            parentDescriptor: parent.descriptor,
            name: name,
            expected: initial,
            code: "\(code)_NAME_REBOUND"
        )
        try requireUnchanged(
            descriptor: parent.descriptor,
            initial: parent.identity,
            code: "\(code)_PARENT_CHANGED"
        )
        try verifyDirectoryBinding(
            components: parentComponents,
            expected: parent.identity,
            code: "\(code)_PARENT_REBOUND"
        )
        try verifyRootBinding()
        return data
    }

    private func openDirectory(
        components: [String],
        create: Bool,
        allowMissing: Bool,
        code: String
    ) throws -> (descriptor: Int32, identity: LegacyMigrationFileIdentity)? {
        let initial = dup(rootDescriptor)
        guard initial >= 0 else { throw Self.failure("\(code)_ROOT_DUP_FAILED:\(errno)") }
        var current = initial
        for component in components {
            var next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0, errno == ENOENT, create {
                guard mkdirat(current, component, mode_t(0o700)) == 0 || errno == EEXIST else {
                    close(current)
                    throw Self.failure("\(code)_DIRECTORY_CREATE_FAILED:\(errno)")
                }
                next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            if next < 0, errno == ENOENT, allowMissing {
                close(current)
                return nil
            }
            guard next >= 0 else {
                close(current)
                throw Self.failure("\(code)_DIRECTORY_OPEN_FAILED:\(errno)")
            }
            close(current)
            current = next
        }
        do {
            let identity = try Self.identity(
                descriptor: current,
                requiredType: S_IFDIR,
                code: "\(code)_NOT_DIRECTORY"
            )
            return (current, identity)
        } catch {
            close(current)
            throw error
        }
    }

    private func verifyRootBinding() throws {
        var metadata = stat()
        guard lstat(physicalRoot.path, &metadata) == 0,
              LegacyMigrationFileIdentity(metadata).isSameObject(as: rootIdentity) else {
            throw Self.failure("ROOT_IDENTITY_DRIFT")
        }
    }

    private func verifyDirectoryBinding(
        components: [String],
        expected: LegacyMigrationFileIdentity,
        code: String
    ) throws {
        guard let opened = try openDirectory(
            components: components,
            create: false,
            allowMissing: false,
            code: code
        ) else { throw Self.failure(code) }
        defer { close(opened.descriptor) }
        guard opened.identity.isSameObject(as: expected) else { throw Self.failure(code) }
    }

    private func verifyNameBinding(
        parentDescriptor: Int32,
        name: String,
        expected: LegacyMigrationFileIdentity,
        code: String
    ) throws {
        var metadata = stat()
        guard fstatat(parentDescriptor, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0,
              LegacyMigrationFileIdentity(metadata) == expected else {
            throw Self.failure(code)
        }
    }

    private func requireUnchanged(
        descriptor: Int32,
        initial: LegacyMigrationFileIdentity,
        code: String
    ) throws {
        let current = try Self.identity(descriptor: descriptor, requiredType: nil, code: code)
        guard current == initial else { throw Self.failure(code) }
    }

    private func relativeComponents(for candidate: URL, allowRoot: Bool) throws -> [String] {
        let normalized = candidate.standardizedFileURL
        guard candidate.path == normalized.path,
              normalized.path.hasPrefix("/"),
              normalized.path == root.path || normalized.path.hasPrefix(root.path + "/") else {
            throw Self.failure("PATH_OUTSIDE_OR_NONCANONICAL:\(candidate.path)")
        }
        if normalized.path == root.path {
            guard allowRoot else { throw Self.failure("PATH_EQUALS_ROOT") }
            return []
        }
        let suffix = normalized.path.dropFirst(root.path.count + 1)
        let components = suffix.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty, components.allSatisfy(Self.validComponent) else {
            throw Self.failure("PATH_COMPONENT_INVALID")
        }
        return components
    }

    private static func openAbsoluteDirectory(_ url: URL, create: Bool) throws -> Int32 {
        var current = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard current >= 0 else { throw failure("ABSOLUTE_ROOT_OPEN_FAILED:\(errno)") }
        for component in url.path.split(separator: "/").map(String.init) {
            var next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0, errno == ENOENT, create {
                guard mkdirat(current, component, mode_t(0o700)) == 0 || errno == EEXIST else {
                    close(current)
                    throw failure("ROOT_CREATE_FAILED:\(errno)")
                }
                next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard next >= 0 else {
                close(current)
                throw failure("ROOT_OPEN_FAILED:\(component):\(errno)")
            }
            close(current)
            current = next
        }
        return current
    }

    private static func resolvedExistingDirectory(_ url: URL) throws -> URL {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(url.path, &buffer) != nil else {
            throw failure("ROOT_REALPATH_FAILED:\(errno)")
        }
        let end = buffer.firstIndex(of: 0) ?? buffer.endIndex
        let path = String(decoding: buffer[..<end].map(UInt8.init(bitPattern:)), as: UTF8.self)
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func identity(
        descriptor: Int32,
        requiredType: mode_t?,
        code: String
    ) throws -> LegacyMigrationFileIdentity {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw failure("\(code):\(errno)")
        }
        let identity = LegacyMigrationFileIdentity(metadata)
        if let requiredType, identity.fileType != requiredType {
            throw failure(code)
        }
        return identity
    }

    private static func writeAll(_ data: Data, to descriptor: Int32, code: String) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let count = write(descriptor, base.advanced(by: offset), rawBuffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw failure("\(code)_WRITE_FAILED:\(errno)") }
                offset += count
            }
        }
    }

    private static func validComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\0")
    }

    private static func failure(_ code: String) -> AdapterError {
        .queueRejected("LEGACY_GENERATION_STATE_MIGRATION_FAILED:\(code)")
    }
}

private struct LegacyMigrationMissingFileError: Error {}

private struct LegacyMigrationFileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
    let fileType: mode_t
    let permissions: mode_t
    let size: off_t
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int

    init(_ metadata: stat) {
        device = metadata.st_dev
        inode = metadata.st_ino
        fileType = metadata.st_mode & S_IFMT
        permissions = metadata.st_mode & 0o7777
        size = metadata.st_size
        modifiedSeconds = metadata.st_mtimespec.tv_sec
        modifiedNanoseconds = metadata.st_mtimespec.tv_nsec
        changedSeconds = metadata.st_ctimespec.tv_sec
        changedNanoseconds = metadata.st_ctimespec.tv_nsec
    }

    func isSameObject(as other: LegacyMigrationFileIdentity) -> Bool {
        device == other.device && inode == other.inode && fileType == other.fileType
    }
}
