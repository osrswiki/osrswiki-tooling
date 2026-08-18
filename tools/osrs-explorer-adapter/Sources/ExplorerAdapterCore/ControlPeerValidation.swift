import CryptoKit
import Darwin
import Foundation
import Security

public struct ControlPeerCodeIdentity: Equatable, Sendable {
    public let executablePath: String
    public let signingIdentifier: String
    public let signingCertificateSHA256: String
    public let hardenedRuntime: Bool
    public let codeValidityAccepted: Bool

    public init(
        executablePath: String,
        signingIdentifier: String,
        signingCertificateSHA256: String,
        hardenedRuntime: Bool,
        codeValidityAccepted: Bool
    ) {
        self.executablePath = executablePath
        self.signingIdentifier = signingIdentifier
        self.signingCertificateSHA256 = signingCertificateSHA256
        self.hardenedRuntime = hardenedRuntime
        self.codeValidityAccepted = codeValidityAccepted
    }
}

public enum ControlPeerValidationPolicy {
    public static let signingIdentifier = "com.omiyawaki.osrswiki.explorer-adapter.cli"

    public static func accepts(
        peer: UnixPeerIdentity,
        identity: ControlPeerCodeIdentity,
        expectedUserIdentifier: uid_t,
        expectedExecutablePath: String,
        expectedCertificateSHA256: String
    ) -> Bool {
        peer.effectiveUserIdentifier == expectedUserIdentifier
            && identity.codeValidityAccepted
            && identity.hardenedRuntime
            && identity.executablePath == expectedExecutablePath
            && identity.signingIdentifier == signingIdentifier
            && identity.signingCertificateSHA256.uppercased()
                == expectedCertificateSHA256.uppercased()
    }
}

public struct DesignatedCLIPeerValidator: @unchecked Sendable {
    private let expectedUserIdentifier: uid_t
    private let expectedExecutablePath: String
    private let expectedCertificateSHA256: String

    public init(
        expectedExecutablePath: URL,
        expectedCertificateSHA256: String,
        expectedUserIdentifier: uid_t = getuid()
    ) {
        self.expectedUserIdentifier = expectedUserIdentifier
        self.expectedExecutablePath = expectedExecutablePath.resolvingSymlinksInPath().path
        self.expectedCertificateSHA256 = expectedCertificateSHA256
    }

    public func accepts(_ peer: UnixPeerIdentity) -> Bool {
        guard let identity = try? ControlPeerIdentityReader.read(
            peer: peer
        ) else {
            return false
        }
        return ControlPeerValidationPolicy.accepts(
            peer: peer,
            identity: identity,
            expectedUserIdentifier: expectedUserIdentifier,
            expectedExecutablePath: expectedExecutablePath,
            expectedCertificateSHA256: expectedCertificateSHA256
        )
    }
}

enum ControlPeerIdentityReader {
    static func read(peer: UnixPeerIdentity) throws -> ControlPeerCodeIdentity {
        guard peer.auditToken.count == MemoryLayout<audit_token_t>.size else {
            throw AdapterError.unauthorized
        }
        var staticCode: SecCode?
        let attributes = [kSecGuestAttributeAudit: peer.auditToken as CFData] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &staticCode) == errSecSuccess,
              let staticCode else {
            throw AdapterError.unauthorized
        }
        let validityFlags = SecCSFlags(rawValue: kSecCSStrictValidate)
        let validity = SecCodeCheckValidity(staticCode, validityFlags, nil) == errSecSuccess
        var diskCode: SecStaticCode?
        guard SecCodeCopyStaticCode(staticCode, [], &diskCode) == errSecSuccess,
              let diskCode else {
            throw AdapterError.unauthorized
        }
        var rawInformation: CFDictionary?
        let informationFlags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(
            diskCode,
            informationFlags,
            &rawInformation
        ) == errSecSuccess,
        let information = rawInformation as? [CFString: Any],
        let identifier = information[kSecCodeInfoIdentifier] as? String,
        let certificates = information[kSecCodeInfoCertificates] as? [SecCertificate],
        let certificate = certificates.first,
        let flags = information[kSecCodeInfoFlags] as? NSNumber else {
            throw AdapterError.unauthorized
        }
        let certificateData = SecCertificateCopyData(certificate) as Data
        let certificateSHA256 = SHA256.hash(data: certificateData)
            .map { String(format: "%02X", $0) }
            .joined()
        return ControlPeerCodeIdentity(
            executablePath: try executablePath(peer.processIdentifier)
                .resolvingSymlinksInPath().path,
            signingIdentifier: identifier,
            signingCertificateSHA256: certificateSHA256,
            hardenedRuntime: flags.uint32Value & 0x0001_0000 != 0,
            codeValidityAccepted: validity
        )
    }

    private static func executablePath(_ processIdentifier: Int32) throws -> URL {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let count = proc_pidpath(processIdentifier, &buffer, UInt32(buffer.count))
        guard count > 0 else { throw AdapterError.unauthorized }
        let bytes = buffer.prefix(Int(count)).prefix { $0 != 0 }
        return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self))
    }

}
