import Testing
@testable import LinkTransport

@Suite struct LinkTransportSmokeTests {
    @Test func moduleLoads() { #expect(Bool(true)) }
}
