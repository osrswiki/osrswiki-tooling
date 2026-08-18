import Darwin
import Foundation

public enum AdapterInstanceDisposition: Sendable {
    case primary(AdapterInstanceLock)
    case secondary
}

public final class AdapterInstanceLock: @unchecked Sendable {
    public static let showControlsNotification = Notification.Name(
        "com.omiyawaki.osrswiki.explorer-adapter.show-controls"
    )

    public let instanceIdentifier: String
    public let path: URL

    private let descriptor: Int32
    private let canonicalRoot: URL
    private let stateLock = NSLock()
    private var released = false

    private init(descriptor: Int32, paths: AdapterRuntimePaths, instanceIdentifier: String) throws {
        self.descriptor = descriptor
        self.instanceIdentifier = instanceIdentifier
        path = paths.lock
        canonicalRoot = paths.root.standardizedFileURL
        try writeOwnerRecord()
    }

    deinit {
        release()
    }

    public static func acquire(
        paths: AdapterRuntimePaths,
        instanceIdentifier: String = UUID().uuidString.lowercased()
    ) throws -> AdapterInstanceDisposition {
        try FileManager.default.createDirectory(
            at: paths.root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: paths.root.path
        )
        let descriptor = Darwin.open(paths.lock.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw AdapterError.backgroundUnsupported("INSTANCE_LOCK_OPEN_FAILED:\(posixError())")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let lockError = errno
            Darwin.close(descriptor)
            if lockError == EWOULDBLOCK || lockError == EAGAIN {
                return .secondary
            }
            throw AdapterError.backgroundUnsupported(
                "INSTANCE_LOCK_ACQUIRE_FAILED:\(String(cString: strerror(lockError)))"
            )
        }
        do {
            return .primary(try AdapterInstanceLock(
                descriptor: descriptor,
                paths: paths,
                instanceIdentifier: instanceIdentifier
            ))
        } catch {
            flock(descriptor, LOCK_UN)
            Darwin.close(descriptor)
            throw error
        }
    }

    @discardableResult
    public static func requestControls(
        paths: AdapterRuntimePaths,
        requestIdentifier: String = UUID().uuidString.lowercased()
    ) throws -> String {
        let requestMarker = try markerURL(
            directory: paths.showControlsRequests,
            requestIdentifier: requestIdentifier,
            pathExtension: "request"
        )
        let acknowledgementMarker = try markerURL(
            directory: paths.showControlsAcknowledgements,
            requestIdentifier: requestIdentifier,
            pathExtension: "ack"
        )
        try prepareMarkerDirectory(paths.showControlsRequests)
        try prepareMarkerDirectory(paths.showControlsAcknowledgements)
        guard !FileManager.default.fileExists(atPath: acknowledgementMarker.path) else {
            throw AdapterError.malformedRequest("SECOND_LAUNCH_REQUEST_ID_REUSED")
        }
        let request: [String: Any] = [
            "schema_version": 1,
            "request_id": requestIdentifier,
            "requested_at": AdapterClock.now()
        ]
        var data = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        data.append(0x0A)
        try writeExclusive(data, to: requestMarker)
        return requestIdentifier
    }

    @discardableResult
    public func acknowledgeControlsRequests(paths: AdapterRuntimePaths) throws -> [String] {
        guard owns(paths: paths) else { throw AdapterError.unauthorized }
        try Self.prepareMarkerDirectory(paths.showControlsRequests)
        try Self.prepareMarkerDirectory(paths.showControlsAcknowledgements)
        let requests = try FileManager.default.contentsOfDirectory(
            at: paths.showControlsRequests,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "request" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var acknowledged: [String] = []
        for requestMarker in requests {
            let markerIdentifier = requestMarker.deletingPathExtension().lastPathComponent
            let data = try Data(contentsOf: requestMarker)
            guard let request = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  request["schema_version"] as? Int == 1,
                  let requestIdentifier = request["request_id"] as? String,
                  requestIdentifier == markerIdentifier else {
                throw AdapterError.malformedRequest("SECOND_LAUNCH_REQUEST_INVALID")
            }
            let acknowledgement = try Self.markerURL(
                directory: paths.showControlsAcknowledgements,
                requestIdentifier: requestIdentifier,
                pathExtension: "ack"
            )
            let acknowledgementData = Data((requestIdentifier + "\n").utf8)
            if FileManager.default.fileExists(atPath: acknowledgement.path) {
                guard try Data(contentsOf: acknowledgement) == acknowledgementData else {
                    throw AdapterError.malformedRequest("SECOND_LAUNCH_ACK_COLLISION")
                }
            } else {
                try Self.writeExclusive(acknowledgementData, to: acknowledgement)
            }
            try FileManager.default.removeItem(at: requestMarker)
            acknowledged.append(requestIdentifier)
        }
        return acknowledged
    }

    public static func waitForControlsAcknowledgement(
        requestIdentifier: String,
        paths: AdapterRuntimePaths,
        timeoutMilliseconds: Int = 2_000,
        pollMilliseconds: Int = 10,
        observe: () -> Void = {}
    ) -> Bool {
        precondition(timeoutMilliseconds >= 0)
        precondition(pollMilliseconds > 0)
        let deadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(timeoutMilliseconds) * 1_000_000
        guard let acknowledgementURL = try? markerURL(
            directory: paths.showControlsAcknowledgements,
            requestIdentifier: requestIdentifier,
            pathExtension: "ack"
        ) else { return false }
        repeat {
            observe()
            if let acknowledgement = try? String(
                contentsOf: acknowledgementURL,
                encoding: .utf8
            ).trimmingCharacters(in: .whitespacesAndNewlines),
            acknowledgement == requestIdentifier {
                return true
            }
            if DispatchTime.now().uptimeNanoseconds >= deadline { return false }
            Thread.sleep(forTimeInterval: Double(pollMilliseconds) / 1_000)
        } while true
    }

    public func owns(paths: AdapterRuntimePaths) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return !released && canonicalRoot == paths.root.standardizedFileURL
    }

    public func release() {
        stateLock.lock()
        guard !released else {
            stateLock.unlock()
            return
        }
        released = true
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
        stateLock.unlock()
    }

    private func writeOwnerRecord() throws {
        let owner: [String: Any] = [
            "schema_version": 1,
            "instance_id": instanceIdentifier,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "started_at": AdapterClock.now()
        ]
        var data = try JSONSerialization.data(
            withJSONObject: owner,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        data.append(0x0A)
        guard ftruncate(descriptor, 0) == 0, lseek(descriptor, 0, SEEK_SET) == 0 else {
            throw AdapterError.backgroundUnsupported("INSTANCE_LOCK_RECORD_RESET_FAILED:\(posixError())")
        }
        let written = data.withUnsafeBytes { raw in
            Darwin.write(descriptor, raw.baseAddress, raw.count)
        }
        guard written == data.count, fsync(descriptor) == 0 else {
            throw AdapterError.backgroundUnsupported("INSTANCE_LOCK_RECORD_WRITE_FAILED:\(posixError())")
        }
        guard fchmod(descriptor, 0o600) == 0 else {
            throw AdapterError.backgroundUnsupported("INSTANCE_LOCK_CHMOD_FAILED:\(posixError())")
        }
    }

    private static func prepareMarkerDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
    }

    private static func markerURL(
        directory: URL,
        requestIdentifier: String,
        pathExtension: String
    ) throws -> URL {
        guard requestIdentifier.range(
            of: "^[a-z0-9][a-z0-9-]{0,127}$",
            options: .regularExpression
        ) != nil else {
            throw AdapterError.malformedRequest("SECOND_LAUNCH_REQUEST_ID_INVALID")
        }
        return directory
            .appendingPathComponent(requestIdentifier, isDirectory: false)
            .appendingPathExtension(pathExtension)
    }

    private static func writeExclusive(_ data: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).tmp-\(UUID().uuidString.lowercased())"
        )
        let descriptor = Darwin.open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
            0o600
        )
        guard descriptor >= 0 else {
            throw AdapterError.backgroundUnsupported("SECOND_LAUNCH_MARKER_CREATE_FAILED:\(posixError())")
        }
        var published = false
        defer {
            Darwin.close(descriptor)
            if !published { Darwin.unlink(temporary.path) }
        }
        var offset = 0
        let completed = data.withUnsafeBytes { bytes -> Bool in
            guard let baseAddress = bytes.baseAddress else { return data.isEmpty }
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        guard completed, fsync(descriptor) == 0 else {
            throw AdapterError.backgroundUnsupported("SECOND_LAUNCH_MARKER_WRITE_FAILED:\(posixError())")
        }
        guard renamex_np(temporary.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw AdapterError.backgroundUnsupported("SECOND_LAUNCH_MARKER_PUBLISH_FAILED:\(posixError())")
        }
        published = true
    }
}

private func posixError() -> String {
    String(cString: strerror(errno))
}
