import Foundation
import Network
import RFBKit
import Localization
import Testing
@testable import SessionKit

@Suite("ConnectionFailureMessage: errors become guidance")
struct ConnectionFailureMessageTests {
    init() { Localization.forcedLanguage = "en" }

    private func text(_ error: Error, user: Bool = true) -> String {
        ConnectionFailureMessage.text(for: error, hasUsername: user)
    }

    @Test func wrongPasswordWithAUserNamesTheAccountRequirement() {
        let message = text(RFBError.authenticationFailed(reason: ""))
        #expect(message.contains("username or password"))
        #expect(message.contains("Screen Sharing"))
    }

    /// An error users really hit: leaving the name empty and getting a message that does not say what is missing. It must point to exactly what to do.
    @Test func blankUsernameIsCalledOutBecauseMacsNeedAnAccountName() {
        let message = text(RFBError.authenticationFailed(reason: ""), user: false)
        #expect(message.contains("macOS account name"))
        #expect(!message.contains("Wrong username or password"), "must not blame the name when the user has not entered one")
    }

    @Test func macOfferingOnlyAccountLoginAsksForTheUsername() {
        let error = RFBError.noCompatibleSecurityType(offered: [.appleRemoteDesktop])
        #expect(text(error, user: false).contains("Enter the username"))
    }

    @Test func unsupportedAuthWithAUsernameStaysGeneric() {
        let error = RFBError.noCompatibleSecurityType(offered: [.appleRemoteDesktop])
        #expect(text(error, user: true).contains("does not support"))
    }

    @Test func refusedDowngradeExplainsHowToUseWeakAuthOnPurpose() {
        let error = RFBError.noCompatibleSecurityType(offered: [.vncAuthentication])
        let message = text(error, user: true)
        #expect(message.contains("leave the username empty"))
        #expect(message.contains("does not switch"))
    }

    @Test(arguments: [NWError.posix(.ENETDOWN), .posix(.ENETUNREACH), .posix(.EHOSTUNREACH), .dns(-65570)])
    func noRouteTellsWhatToCheckAndKeepsTheCode(error: NWError) {
        let message = text(error)
        #expect(message.contains("Local Network"))
        #expect(message.contains("code"))
        #expect(!message.contains("iPad"), "must work for iPhone as well")
    }

    @Test func refusedPointsAtScreenSharingSetting() {
        #expect(text(NWError.posix(.ECONNREFUSED)).contains("Turn on Screen Sharing"))
    }

    @Test func timeoutsAreNotBlamedOnTheCredentials() {
        #expect(!text(RFBError.timedOut).contains("password"))
        #expect(!text(NWError.posix(.ETIMEDOUT)).contains("password"))
    }

    @Test func giveUpMessagesNameTheMachineAndTheAttempts() {
        let exhausted = ConnectionFailureMessage.giveUp(
            .attemptsExhausted, error: RFBError.connectionClosed, name: "Mac mini", attempts: 6, hasUsername: true
        )
        #expect(exhausted.contains("Mac mini"))
        #expect(exhausted.contains("6 attempts"))
        let auth = ConnectionFailureMessage.giveUp(
            .authenticationFailed, error: RFBError.authenticationFailed(reason: ""), name: "Mac mini", attempts: 1, hasUsername: true
        )
        #expect(auth.contains("no longer accepted"))
    }
}
