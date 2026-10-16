import Foundation
import Network
import Testing
@testable import LinkTransport

@Suite struct PairingAdmissionTests {
    @Test func windowOpensExpiresAndCloses() {
        let clock = TestClock()
        let admission = PairingAdmission(clock: clock.clock)
        #expect(!admission.isOpen)
        admission.open()
        #expect(admission.isOpen)
        clock.advance(PairingAdmission.defaultWindow - 1)
        #expect(admission.isOpen)
        clock.advance(2)
        #expect(!admission.isOpen)
        admission.open(duration: 30)
        admission.close()
        #expect(!admission.isOpen)
    }

    @Test func aSuccessClosesTheWindowAndStalesRunningHandshakes() {
        let admission = PairingAdmission(clock: TestClock().clock)
        admission.open()
        let before = admission.epoch
        admission.recordPairingSuccess()
        #expect(!admission.isOpen)
        #expect(admission.epoch == before + 1)
    }

    @Test func sasNeedsAnOpenWindow() {
        let admission = PairingAdmission(clock: TestClock().clock)
        #expect(throws: PairingAdmissionError.windowClosed) { try admission.beginSAS(source: "a") }
    }

    @Test func globalCeilingStopsManyAddresses() throws {
        let admission = PairingAdmission(clock: TestClock().clock)
        admission.open()
        for i in 0..<PairingAdmission.maxSASAttemptsGlobal { try admission.beginSAS(source: "s\(i)") }
        #expect(throws: PairingAdmissionError.tooManySASAttempts) { try admission.beginSAS(source: "another") }
    }

    @Test func remoteAddressKeysAreStableAndCoarse() {
        let v4 = NWEndpoint.hostPort(host: NWEndpoint.Host("10.0.0.7"), port: 1234)
        let v4Other = NWEndpoint.hostPort(host: NWEndpoint.Host("10.0.0.7"), port: 9)
        #expect(LinkRemoteAddress.key(for: v4) == LinkRemoteAddress.key(for: v4Other))
        #expect(LinkRemoteAddress.key(for: v4) == "v4:10.0.0.7")
        // Two addresses in one /64 are the same source.
        let a = NWEndpoint.hostPort(host: NWEndpoint.Host("fd00:1:2:3::1"), port: 1)
        let b = NWEndpoint.hostPort(host: NWEndpoint.Host("fd00:1:2:3:aaaa:bbbb:cccc:dddd"), port: 1)
        let c = NWEndpoint.hostPort(host: NWEndpoint.Host("fd00:1:2:4::1"), port: 1)
        #expect(LinkRemoteAddress.key(for: a) == LinkRemoteAddress.key(for: b))
        #expect(LinkRemoteAddress.key(for: a) != LinkRemoteAddress.key(for: c))
        #expect(LinkRemoteAddress.key(for: nil) == LinkRemoteAddress.unknown)
    }
}
