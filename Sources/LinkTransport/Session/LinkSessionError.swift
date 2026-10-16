import Foundation
import LinkProtocol

/// Why a link session ended or could not start.
///
/// `LinkTransport` does not depend on `SessionKit`. The app bridges this type to its reconnect policy through
/// `isPermanent`: a permanent error must not be retried automatically, because only the user can fix it (pair again, update
/// an app, approve on the Mac).
public enum LinkSessionError: Error, Equatable, Sendable {
    /// The two sides share no protocol version. `LinkNegotiationResult` says which side must update.
    case versionMismatch(LinkNegotiationResult)
    /// The Mac does not know this iPad: never paired, or revoked on the Mac.
    case notAuthorized
    /// The Mac presented a certificate that is not the one pinned for this computer.
    case pinMismatch
    /// The Mac refused the pairing.
    case pairingDenied(LinkPairDenyReason)
    /// Pairing failed locally (bad QR payload, expired code, malformed answer).
    case pairingFailed(String)
    /// The user compared the six-digit codes and said they differ.
    case sasRejected
    /// The person at the Mac declined the session.
    case approvalDenied
    /// Another connection from the same device took over.
    case sessionReplaced
    case helperShuttingDown
    /// The peer sent something the protocol does not allow.
    case protocolViolation(String)
    /// The peer closed with a code we have no specific case for.
    case peerClosed(LinkCloseCode)
    /// Network failure, handshake failure, connection lost.
    case transport(String)
    case timeout
    /// A local send queue is full.
    case queueFull
    /// Closed on our side.
    case closed

    /// Whether automatic reconnection is pointless. See the type documentation.
    public var isPermanent: Bool {
        switch self {
        case .versionMismatch, .notAuthorized, .pinMismatch, .pairingDenied, .pairingFailed, .sasRejected, .approvalDenied,
             .sessionReplaced:
            return true
        case .peerClosed(let code):
            return [LinkCloseCode.versionMismatch, .notAuthorized, .approvalDenied, .sessionReplaced].contains(code)
        case .helperShuttingDown, .protocolViolation, .transport, .timeout, .queueFull, .closed:
            return false
        }
    }

    /// The error a received `close` stands for.
    static func fromPeerClose(_ code: LinkCloseCode) -> LinkSessionError {
        switch code {
        case .normal: .closed
        case .notAuthorized: .notAuthorized
        case .approvalDenied: .approvalDenied
        case .sessionReplaced: .sessionReplaced
        case .helperShuttingDown: .helperShuttingDown
        case .protocolViolation, .unsupportedMessage: .protocolViolation("peer reported a protocol violation")
        default: .peerClosed(code)
        }
    }

    /// The close code to send for a local failure.
    var closeCode: LinkCloseCode {
        switch self {
        case .versionMismatch: .versionMismatch
        case .notAuthorized: .notAuthorized
        case .approvalDenied, .sasRejected: .approvalDenied
        case .protocolViolation: .protocolViolation
        case .sessionReplaced: .sessionReplaced
        case .helperShuttingDown: .helperShuttingDown
        case .closed: .normal
        case .peerClosed(let code): code
        default: .internalError
        }
    }
}

extension LinkError {
    var asSessionError: LinkSessionError {
        switch self {
        case .unsupportedMessage: .protocolViolation("unsupported message")
        default: .protocolViolation("malformed message")
        }
    }
}
