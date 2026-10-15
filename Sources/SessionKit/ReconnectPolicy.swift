import Foundation
import RFBKit

/// When to try reconnecting after a connection is lost, and when to stop.
///
/// This is an **experience decision**, not only a technical one: retrying often and for long keeps the session seamless but
/// wastes battery and network calling a Mac that is off; retrying little makes the user tap Reconnect more. The default below
/// is a reasonable choice that is easy to adjust.
public struct ReconnectPolicy: Equatable, Sendable {
    /// Delay before each attempt. When the array runs out, give up. The first is very short: most drops happen because the app
    /// just returned from the background, the old connection is dead, and a new one usually comes up right away.
    public var delays: [Duration]

    public init(delays: [Duration]) {
        self.delays = delays
    }

    /// 0.5 s, 2 s, 4 s, 8 s, 15 s, 30 s: about a minute and a half of waiting in total, enough for a Mac to wake or Wi-Fi to rejoin.
    public static let standard = ReconnectPolicy(delays: [
        .milliseconds(500), .seconds(2), .seconds(4), .seconds(8), .seconds(15), .seconds(30),
    ])

    /// No retries: a lost connection is reported immediately.
    public static let never = ReconnectPolicy(delays: [])

    public var maxAttempts: Int { delays.count }

    public enum GiveUpReason: Equatable, Sendable {
        /// Wrong username or password (or the server refused): retrying would only lock the account.
        case authenticationFailed
        /// Incompatible server: wrong version, unknown authentication type, unknown encoding, or malformed protocol data.
        case incompatible
        /// All allowed attempts have been used.
        case attemptsExhausted
    }

    public enum Decision: Equatable, Sendable {
        /// Wait `delay`, then make attempt number `attempt` (counted from 1).
        case retry(after: Duration, attempt: Int)
        case giveUp(GiveUpReason)
    }

    /// - Parameters:
    ///   - error: the error that dropped the connection or made the last attempt fail.
    ///   - attemptsMade: number of retries already made (0 at the first drop).
    public func decision(after error: Error, attemptsMade: Int) -> Decision {
        if let reason = Self.permanentReason(for: error) { return .giveUp(reason) }
        guard attemptsMade >= 0, attemptsMade < delays.count else { return .giveUp(.attemptsExhausted) }
        return .retry(after: delays[attemptsMade], attempt: attemptsMade + 1)
    }

    /// Errors where retrying is certainly useless (or harmful), unlike a transient network error.
    static func permanentReason(for error: Error) -> GiveUpReason? {
        guard let error = error as? RFBError else { return nil } // network error (NWError, POSIX, cancellation): transient
        switch error {
        case .authenticationFailed, .serverRejected, .credentialTooLong:
            return .authenticationFailed
        case .invalidVersionString, .unsupportedVersion, .unsupportedSecurityType, .invalidKeyExchange,
             .unsupportedEncoding, .noCompatibleSecurityType, .malformed:
            return .incompatible
        case .connectionClosed, .timedOut:
            return nil
        }
    }
}
