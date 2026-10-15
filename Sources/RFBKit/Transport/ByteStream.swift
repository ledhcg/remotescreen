import Foundation

/// Bidirectional byte stream that the RFB protocol runs on.
///
/// Separated from Network.framework so the handshake and decoders can be tested with in-memory
/// data, with no network or real server.
public protocol ByteStream: Sendable {
    /// Reads exactly `count` bytes. Throws `RFBError.connectionClosed` if the stream closes early.
    func read(exactly count: Int) async throws -> Data
    /// Reads whatever is available, at least 1 and at most `maxCount` bytes. Used when the
    /// response length is not known (protocol discovery). Throws `RFBError.connectionClosed` if the stream closes.
    func readSome(maxCount: Int) async throws -> Data
    func write(_ data: Data) async throws
    func close() async
}

public enum RFBError: Error, Equatable, Sendable {
    case connectionClosed
    case invalidVersionString(String)
    case unsupportedVersion(RFBVersion)
    case serverRejected(reason: String)
    case malformed(String)
    case unsupportedSecurityType(RFBSecurityType)
    case authenticationFailed(reason: String)
    case invalidKeyExchange(String)
    case credentialTooLong(field: String)
    /// The server sent an encoding the client cannot decode yet. It cannot be skipped because the data length is unknown.
    case unsupportedEncoding(RFBEncoding)
    /// The server offers no security type that the client supports and has enough credentials to use.
    case noCompatibleSecurityType(offered: [RFBSecurityType])
    case timedOut
}

extension ByteStream {
    public func readUInt8() async throws -> UInt8 {
        guard let byte = try await read(exactly: 1).first else { throw RFBError.connectionClosed }
        return byte
    }

    public func readUInt16() async throws -> UInt16 {
        try await read(exactly: 2).reduce(UInt16(0)) { $0 << 8 | UInt16($1) }
    }

    public func readUInt32() async throws -> UInt32 {
        try await read(exactly: 4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }
}
