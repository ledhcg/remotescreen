import Foundation

/// Result of the greeting step: the version and the list of security types the server allows.
public struct ServerHello: Equatable, Sendable {
    public let serverVersion: RFBVersion
    public let negotiatedVersion: RFBVersion
    public let securityTypes: [RFBSecurityType]
}

public enum Handshake {
    /// Limit on the length of the rejection reason, so a faulty server cannot make us allocate unbounded memory.
    private static let maxReasonLength = 4096

    /// Runs the handshake up to the end of the security type listing.
    ///
    /// This function does **not** choose any security type and does not authenticate. Use it to discover
    /// what the server supports without needing a password.
    public static func readServerHello(over stream: some ByteStream) async throws -> ServerHello {
        let server = try RFBVersion(parsing: try await stream.read(exactly: 12))
        let negotiated = try server.negotiated()
        try await stream.write(Data(negotiated.wireString.utf8))

        let types: [RFBSecurityType]
        if negotiated == .v3_3 {
            // 3.3: the server chooses and sends a 32-bit number; 0 means rejection.
            let raw = try await stream.read(exactly: 4)
            let value = raw.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            if value == 0 { throw RFBError.serverRejected(reason: try await readReason(from: stream)) }
            guard let byte = UInt8(exactly: value) else {
                throw RFBError.malformed("security type 3.3 out of range: \(value)")
            }
            types = [RFBSecurityType(rawValue: byte)]
        } else {
            // 3.7 and later: a 1-byte count, followed by one byte per type; a count of 0 means rejection.
            guard let count = try await stream.read(exactly: 1).first else { throw RFBError.connectionClosed }
            if count == 0 { throw RFBError.serverRejected(reason: try await readReason(from: stream)) }
            let bytes = try await stream.read(exactly: Int(count))
            types = bytes.map { RFBSecurityType(rawValue: $0) }
        }
        return ServerHello(serverVersion: server, negotiatedVersion: negotiated, securityTypes: types)
    }

    /// Sends the security type choice (1 byte, applies to 3.7 and later).
    ///
    /// After this call the server starts the authentication step specific to that type. The function only selects,
    /// and does not send credentials.
    public static func selectSecurityType(_ type: RFBSecurityType, over stream: some ByteStream) async throws {
        try await stream.write(Data([type.rawValue]))
    }

    /// Like the above but based on the negotiated version: in RFB 3.3 the server chooses the type itself and the client sends **no** byte
    /// (sending an extra one would shift the authentication step by a byte).
    public static func selectSecurityType(_ type: RFBSecurityType, version: RFBVersion, over stream: some ByteStream) async throws {
        guard version != .v3_3 else { return }
        try await selectSecurityType(type, over: stream)
    }

    /// Reads the reason string: a 4-byte length (big-endian) followed by UTF-8 content.
    static func readReason(from stream: some ByteStream) async throws -> String {
        let lengthBytes = try await stream.read(exactly: 4)
        let length = Int(lengthBytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        guard length <= maxReasonLength else { throw RFBError.malformed("rejection reason is \(length) bytes long") }
        return String(decoding: try await stream.read(exactly: length), as: UTF8.self)
    }
}
