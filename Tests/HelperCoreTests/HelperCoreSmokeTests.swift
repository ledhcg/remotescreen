import Testing
@testable import HelperCore

@Suite(.timeLimit(.minutes(2))) struct HelperCoreSmokeTests {
    @Test func moduleLoads() { #expect(Bool(true)) }
}
