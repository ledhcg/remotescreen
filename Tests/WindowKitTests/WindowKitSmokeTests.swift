import Testing
@testable import WindowKit

@Suite struct WindowKitSmokeTests {
    @Test func moduleLoads() { #expect(Bool(true)) }
}
