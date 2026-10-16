import Testing
@testable import LinkTransport

@Suite(.timeLimit(.minutes(2))) struct LinkTransportSmokeTests {
    @Test func moduleLoads() { #expect(Bool(true)) }
}
