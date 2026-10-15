import Testing
@testable import HelperCore

@Suite struct HelperCoreSmokeTests {
    @Test func moduleLoads() { #expect(Bool(true)) }
}
