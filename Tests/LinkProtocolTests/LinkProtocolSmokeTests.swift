import Testing
@testable import LinkProtocol

@Suite struct LinkProtocolSmokeTests {
    @Test func moduleLoads() { #expect(Bool(true)) }
}
