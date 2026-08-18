import Darwin
import Foundation

public struct UnixPeerIdentity: Equatable, Sendable {
    public let processIdentifier: Int32
    public let effectiveUserIdentifier: uid_t
    public let effectiveGroupIdentifier: gid_t
    public let auditToken: Data

    public init(
        processIdentifier: Int32,
        effectiveUserIdentifier: uid_t,
        effectiveGroupIdentifier: gid_t,
        auditToken: Data = Data()
    ) {
        self.processIdentifier = processIdentifier
        self.effectiveUserIdentifier = effectiveUserIdentifier
        self.effectiveGroupIdentifier = effectiveGroupIdentifier
        self.auditToken = auditToken
    }
}

public final class UnixSocketServer: @unchecked Sendable {
    public typealias Handler = @Sendable (AdapterRequest) async -> AdapterResponse
    public typealias PeerValidator = @Sendable (UnixPeerIdentity) -> Bool

    private let path: String
    private let requestTimeoutMilliseconds: Int32
    private let peerValidator: PeerValidator
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var activeClients: Set<Int32> = []
    private var task: Task<Void, Never>?

    public init(
        path: String,
        requestTimeoutMilliseconds: Int32 = 2_000,
        peerValidator: @escaping PeerValidator = { _ in true }
    ) {
        precondition(requestTimeoutMilliseconds > 0)
        self.path = path
        self.requestTimeoutMilliseconds = requestTimeoutMilliseconds
        self.peerValidator = peerValidator
    }

    public func start(handler: @escaping Handler) throws {
        let server = socket(AF_UNIX, SOCK_STREAM, 0)
        guard server >= 0 else { throw socketError("SOCKET_CREATE") }
        do {
            try suppressSIGPIPE(on: server)
            try withUnixSocketAddress(path: path) { address, length in
                guard Darwin.bind(server, address, length) == 0 else {
                    throw socketError("SOCKET_BIND")
                }
            }
            guard chmod(path, 0o600) == 0 else { throw socketError("SOCKET_CHMOD") }
            guard Darwin.listen(server, 8) == 0 else { throw socketError("SOCKET_LISTEN") }
        } catch {
            Darwin.close(server)
            throw error
        }
        lock.lock()
        descriptor = server
        lock.unlock()
        task = Task.detached(priority: .utility) { [weak self] in
            await self?.acceptLoop(server: server, handler: handler)
        }
    }

    public func stop() {
        lock.lock()
        let server = descriptor
        descriptor = -1
        let clients = activeClients
        activeClients.removeAll()
        lock.unlock()
        if server >= 0 {
            Darwin.shutdown(server, SHUT_RDWR)
            Darwin.close(server)
        }
        for client in clients {
            Darwin.shutdown(client, SHUT_RDWR)
            Darwin.close(client)
        }
        task?.cancel()
        task = nil
        unlink(path)
    }

    deinit {
        stop()
    }

    private func acceptLoop(server: Int32, handler: @escaping Handler) async {
        while !Task.isCancelled {
            let client = Darwin.accept(server, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            do {
                try suppressSIGPIPE(on: client)
            } catch {
                Darwin.shutdown(client, SHUT_RDWR)
                Darwin.close(client)
                continue
            }
            guard register(client: client, for: server) else {
                Darwin.shutdown(client, SHUT_RDWR)
                Darwin.close(client)
                return
            }
            defer { closeRegisteredClient(client) }
            let response: AdapterResponse
            do {
                let peer = try unixPeerIdentity(client)
                guard peerValidator(peer) else {
                    throw AdapterError.unauthorized
                }
                let data = try readLine(
                    from: client,
                    maximumBytes: 1_048_576,
                    timeoutMilliseconds: requestTimeoutMilliseconds
                )
                let request = try JSONDecoder().decode(AdapterRequest.self, from: data)
                response = await handler(request)
            } catch {
                response = AdapterResponse(
                    id: "invalid",
                    ok: false,
                    state: .faulted,
                    error: "MALFORMED_REQUEST:\(error)"
                )
            }
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                var data = try encoder.encode(response)
                data.append(0x0A)
                try writeAll(data, to: client)
            } catch {
                // The caller may disappear; no input work is scheduled from this path.
            }
        }
    }

    private func register(client: Int32, for server: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor == server else { return false }
        activeClients.insert(client)
        return true
    }

    private func closeRegisteredClient(_ client: Int32) {
        lock.lock()
        let owned = activeClients.remove(client) != nil
        lock.unlock()
        guard owned else { return }
        Darwin.shutdown(client, SHUT_RDWR)
        Darwin.close(client)
    }
}

private func unixPeerIdentity(_ descriptor: Int32) throws -> UnixPeerIdentity {
    var processIdentifier: pid_t = 0
    var processIdentifierLength = socklen_t(MemoryLayout.size(ofValue: processIdentifier))
    guard getsockopt(
        descriptor,
        SOL_LOCAL,
        LOCAL_PEERPID,
        &processIdentifier,
        &processIdentifierLength
    ) == 0 else {
        throw socketError("SOCKET_PEER_PID")
    }
    var userIdentifier: uid_t = 0
    var groupIdentifier: gid_t = 0
    guard getpeereid(descriptor, &userIdentifier, &groupIdentifier) == 0 else {
        throw socketError("SOCKET_PEER_CREDENTIALS")
    }
    var auditToken = audit_token_t()
    var auditTokenLength = socklen_t(MemoryLayout<audit_token_t>.size)
    guard getsockopt(
        descriptor,
        SOL_LOCAL,
        LOCAL_PEERTOKEN,
        &auditToken,
        &auditTokenLength
    ) == 0,
    auditTokenLength == MemoryLayout<audit_token_t>.size else {
        throw socketError("SOCKET_PEER_AUDIT_TOKEN")
    }
    let auditTokenData = withUnsafeBytes(of: &auditToken) { Data($0) }
    return UnixPeerIdentity(
        processIdentifier: processIdentifier,
        effectiveUserIdentifier: userIdentifier,
        effectiveGroupIdentifier: groupIdentifier,
        auditToken: auditTokenData
    )
}

public enum UnixSocketClient {
    public static func send(_ request: AdapterRequest, to path: String) throws -> AdapterResponse {
        let client = socket(AF_UNIX, SOCK_STREAM, 0)
        guard client >= 0 else { throw socketError("SOCKET_CREATE") }
        defer { Darwin.close(client) }
        try suppressSIGPIPE(on: client)
        try withUnixSocketAddress(path: path) { address, length in
            guard Darwin.connect(client, address, length) == 0 else {
                throw socketError("SOCKET_CONNECT")
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(request)
        data.append(0x0A)
        try writeAll(data, to: client)
        let response = try readLine(
            from: client,
            maximumBytes: 1_048_576,
            timeoutMilliseconds: 15_000
        )
        return try JSONDecoder().decode(AdapterResponse.self, from: response)
    }
}

private func withUnixSocketAddress<T>(
    path: String,
    body: (UnsafePointer<sockaddr>, socklen_t) throws -> T
) throws -> T {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8) + [0]
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard bytes.count <= capacity else {
        throw AdapterError.malformedRequest("SOCKET_PATH_TOO_LONG")
    }
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
        raw.initializeMemory(as: UInt8.self, repeating: 0)
        bytes.withUnsafeBytes { source in
            raw.copyBytes(from: source)
        }
    }
    let length = socklen_t(MemoryLayout<sa_family_t>.size + bytes.count)
    address.sun_len = UInt8(length)
    return try withUnsafePointer(to: &address) { pointer in
        try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            try body($0, length)
        }
    }
}

private func readLine(
    from descriptor: Int32,
    maximumBytes: Int,
    timeoutMilliseconds: Int32
) throws -> Data {
    var result = Data()
    var byte: UInt8 = 0
    let deadline = DispatchTime.now().uptimeNanoseconds
        + UInt64(timeoutMilliseconds) * 1_000_000
    while result.count < maximumBytes {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline else {
            throw AdapterError.backgroundUnsupported("SOCKET_READ_TIMEOUT")
        }
        let remainingMilliseconds = max(
            1,
            Int32(min(UInt64(Int32.max), (deadline - now + 999_999) / 1_000_000))
        )
        var pollDescriptor = pollfd(
            fd: descriptor,
            events: Int16(POLLIN | POLLHUP | POLLERR),
            revents: 0
        )
        let ready = Darwin.poll(&pollDescriptor, 1, remainingMilliseconds)
        if ready == 0 {
            throw AdapterError.backgroundUnsupported("SOCKET_READ_TIMEOUT")
        }
        if ready < 0 {
            if errno == EINTR { continue }
            throw socketError("SOCKET_POLL")
        }
        let count = Darwin.recv(descriptor, &byte, 1, 0)
        if count == 0 { break }
        if count < 0 {
            if errno == EINTR { continue }
            throw socketError("SOCKET_READ")
        }
        if byte == 0x0A { return result }
        result.append(byte)
    }
    guard result.count < maximumBytes else {
        throw AdapterError.malformedRequest("REQUEST_TOO_LARGE")
    }
    guard !result.isEmpty else {
        throw AdapterError.malformedRequest("EMPTY_REQUEST")
    }
    return result
}

private func writeAll(_ data: Data, to descriptor: Int32) throws {
    try data.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        var offset = 0
        while offset < raw.count {
            let count = Darwin.send(descriptor, base.advanced(by: offset), raw.count - offset, 0)
            if count < 0 {
                if errno == EINTR { continue }
                throw socketError("SOCKET_WRITE")
            }
            offset += count
        }
    }
}

private func suppressSIGPIPE(on descriptor: Int32) throws {
    var enabled: Int32 = 1
    guard setsockopt(
        descriptor,
        SOL_SOCKET,
        SO_NOSIGPIPE,
        &enabled,
        socklen_t(MemoryLayout.size(ofValue: enabled))
    ) == 0 else {
        throw socketError("SOCKET_NOSIGPIPE")
    }
}

private func socketError(_ operation: String) -> AdapterError {
    AdapterError.backgroundUnsupported("\(operation):\(String(cString: strerror(errno)))")
}
