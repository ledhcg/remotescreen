import Foundation
import Network
import RFBKit
import Testing
@testable import SessionKit

@Suite("ReconnectPolicy")
struct ReconnectPolicyTests {
    private let policy = ReconnectPolicy.standard

    /// Transient errors: the network dropped, or the Mac slept or restarted.
    @Test(arguments: [
        RFBError.connectionClosed as Error,
        RFBError.timedOut,
        NWError.posix(.ENETDOWN),
        NWError.posix(.ECONNRESET),
        NWError.posix(.ECONNREFUSED), // the Mac is restarting or Screen Sharing is not on yet
        NWError.posix(.ETIMEDOUT),
        NWError.posix(.EHOSTUNREACH),
        NWError.dns(-65570),
        CancellationError(),
        URLError(.notConnectedToInternet),
    ])
    func transientErrorsAreRetried(error: Error) {
        #expect(policy.decision(after: error, attemptsMade: 0) == .retry(after: .milliseconds(500), attempt: 1))
    }

    /// Retrying these errors would only lock the account or loop pointlessly.
    @Test(arguments: [
        (RFBError.authenticationFailed(reason: "wrong password") as Error, ReconnectPolicy.GiveUpReason.authenticationFailed),
        (RFBError.serverRejected(reason: "too many connections"), .authenticationFailed),
        (RFBError.credentialTooLong(field: "password"), .authenticationFailed),
        (RFBError.unsupportedVersion(RFBVersion(major: 2, minor: 0)), .incompatible),
        (RFBError.invalidVersionString("xyz"), .incompatible),
        (RFBError.unsupportedSecurityType(RFBSecurityType(rawValue: 99)), .incompatible),
        (RFBError.noCompatibleSecurityType(offered: []), .incompatible),
        (RFBError.invalidKeyExchange("p"), .incompatible),
        (RFBError.unsupportedEncoding(RFBEncoding(rawValue: 12345)), .incompatible),
        (RFBError.malformed("bad data"), .incompatible),
    ])
    func permanentErrorsAreNeverRetried(error: Error, reason: ReconnectPolicy.GiveUpReason) {
        for attempts in 0...6 {
            #expect(policy.decision(after: error, attemptsMade: attempts) == .giveUp(reason))
        }
    }

    @Test func delaysGrowAndAttemptsAreNumberedFromOne() {
        let error = RFBError.connectionClosed
        let seen = (0..<6).map { policy.decision(after: error, attemptsMade: $0) }
        #expect(seen == [
            .retry(after: .milliseconds(500), attempt: 1), .retry(after: .seconds(2), attempt: 2),
            .retry(after: .seconds(4), attempt: 3), .retry(after: .seconds(8), attempt: 4),
            .retry(after: .seconds(15), attempt: 5), .retry(after: .seconds(30), attempt: 6),
        ])
    }

    @Test func givesUpWhenAttemptsRunOut() {
        #expect(policy.decision(after: RFBError.connectionClosed, attemptsMade: 6) == .giveUp(.attemptsExhausted))
        #expect(policy.decision(after: RFBError.connectionClosed, attemptsMade: 100) == .giveUp(.attemptsExhausted))
    }

    @Test func neverPolicyGivesUpAtOnce() {
        #expect(ReconnectPolicy.never.decision(after: RFBError.connectionClosed, attemptsMade: 0) == .giveUp(.attemptsExhausted))
        #expect(ReconnectPolicy.never.maxAttempts == 0)
    }

    @Test func customPolicyIsHonoured() {
        let custom = ReconnectPolicy(delays: [.seconds(1), .seconds(1)])
        #expect(custom.maxAttempts == 2)
        #expect(custom.decision(after: RFBError.timedOut, attemptsMade: 1) == .retry(after: .seconds(1), attempt: 2))
        #expect(custom.decision(after: RFBError.timedOut, attemptsMade: 2) == .giveUp(.attemptsExhausted))
    }

    @Test func negativeAttemptCountIsTreatedAsExhaustedNotACrash() {
        #expect(policy.decision(after: RFBError.timedOut, attemptsMade: -1) == .giveUp(.attemptsExhausted))
    }

    @Test func standardPolicyWaitsAboutAMinuteAndAHalfInTotal() {
        let total = policy.delays.reduce(Duration.zero, +)
        #expect(total == .milliseconds(59_500))
        #expect(policy.delays.first! < .seconds(1), "the first attempt must be almost immediate: most drops come from just returning from the background")
        #expect(policy.delays == policy.delays.sorted(), "delays must not decrease")
    }

    private struct LinkRevoked: PermanentConnectionFailure {
        var permanentReason: ReconnectPolicy.GiveUpReason { .authenticationFailed }
    }

    private struct LinkVersionMismatch: PermanentConnectionFailure {
        var permanentReason: ReconnectPolicy.GiveUpReason { .incompatible }
    }

    private struct LinkTransient: Error {}

    @Test func nonRFBErrorsCanDeclareThemselvesPermanent() {
        #expect(policy.decision(after: LinkRevoked(), attemptsMade: 0) == .giveUp(.authenticationFailed))
        #expect(policy.decision(after: LinkVersionMismatch(), attemptsMade: 2) == .giveUp(.incompatible))
    }

    @Test func otherNonRFBErrorsStayTransient() {
        #expect(policy.decision(after: LinkTransient(), attemptsMade: 0) == .retry(after: .milliseconds(500), attempt: 1))
    }
}
