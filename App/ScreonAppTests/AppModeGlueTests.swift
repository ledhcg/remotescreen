import ConnectionKit
import Foundation
import LinkProtocol
import LinkTransport
import SessionKit
import Testing
import WindowKit
@testable import ScreonApp

/// App-level glue of App Mode. The decisions themselves are tested in the packages; these check the bridges the app adds.
@Suite("App Mode glue")
struct AppModeGlueTests {
    @Test func permanentLinkErrorsStopTheReconnectPolicy() {
        let permanent: [LinkSessionError] = [
            .notAuthorized, .pinMismatch, .versionMismatch(.remoteTooOld(remoteMax: 0)), .sessionReplaced, .approvalDenied,
        ]
        for error in permanent {
            let decision = ReconnectPolicy.standard.decision(after: LinkFailure(error: error), attemptsMade: 0)
            guard case .giveUp = decision else {
                Issue.record("\(error) should stop reconnecting")
                continue
            }
        }
        #expect(ReconnectPolicy.standard.decision(after: LinkFailure(error: .versionMismatch(.remoteTooNew(remoteMin: 9))), attemptsMade: 0)
            == .giveUp(.incompatible))
        #expect(ReconnectPolicy.standard.decision(after: LinkFailure(error: .notAuthorized), attemptsMade: 0) == .giveUp(.authenticationFailed))
    }

    @Test func transientLinkErrorsAreRetried() {
        for error in [LinkSessionError.transport("x"), .timeout, .closed, .helperShuttingDown] {
            #expect(!error.isPermanent)
            guard case .retry = ReconnectPolicy.standard.decision(after: error, attemptsMade: 0) else {
                Issue.record("\(error) should be retried")
                continue
            }
        }
    }

    @Test func errorsMapToWhatTheWindowShows() {
        #expect(LinkSessionError.notAuthorized.failureKind == .deviceRevoked)
        #expect(LinkSessionError.pinMismatch.failureKind == .identityChanged)
        #expect(LinkSessionError.versionMismatch(.remoteTooOld(remoteMax: 0)).failureKind == .versionMismatch(.helper))
        #expect(LinkSessionError.versionMismatch(.remoteTooNew(remoteMin: 5)).failureKind == .versionMismatch(.screon))
        #expect(LinkSessionError.sessionReplaced.failureKind == .replaced)
        #expect(LinkSessionError.pairingDenied(.userDenied).failureKind == .denied)
        #expect(LinkSessionError.peerClosed(.notAuthorized).failureKind == .deviceRevoked)
        #expect(LinkSessionError.transport("x").failureKind == .connectionLost)
    }

    @Test @MainActor func typedTextKeepsLettersAsTextAndTurnsReturnAndTabIntoKeys() {
        #expect(AppWindowView.intents(forTyped: "tiếng Việt") == [.text("tiếng Việt")])
        let lines = AppWindowView.intents(forTyped: "a\nb")
        #expect(lines.first == .text("a"))
        #expect(lines.last == .text("b"))
        #expect(lines.count == 4) // text, Return down, Return up, text
        #expect(AppWindowView.intents(forTyped: "").isEmpty)
    }

    @Test func pairedMacPinsLiveInTheKeychainPerComputer() throws {
        let store = KeychainPairedMacStore(service: "com.ledinhcuong.screon.tests.\(UUID().uuidString)")
        let id = UUID().uuidString
        defer { store.remove(computerID: id) }
        #expect(store.mac(forComputer: id) == nil)
        let mac = PairedMac(computerID: id, spkiHash: Data(repeating: 7, count: 32), name: "mac.local", pairedAt: Date(timeIntervalSince1970: 1_000))
        try store.save(mac)
        #expect(store.mac(forComputer: id) == mac)
        try store.save(PairedMac(computerID: id, spkiHash: Data(repeating: 9, count: 32), name: "mac.local", pairedAt: mac.pairedAt))
        #expect(store.mac(forComputer: id)?.spkiHash == Data(repeating: 9, count: 32))
        store.remove(computerID: id)
        #expect(store.mac(forComputer: id) == nil)
    }
}
