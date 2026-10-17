import Foundation
import Testing
@testable import ConnectionKit

/// Answers requests of a test `URLSession` from a closure; nothing leaves the machine.
private final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        do {
            let (status, body) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}

/// One suite, run serially: the stub handler is shared state.
@Suite("Tailscale API", .serialized, .timeLimit(.minutes(1)))
struct TailscaleAPITests {
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }

    private let body = Data(#"{"devices":[{"id":"9","hostname":"mac","addresses":["100.64.0.7"],"os":"macOS"}]}"#.utf8)

    @Test func theTokenTravelsInTheHeaderOnlyAndToTailscaleOnly() async throws {
        let seen = LockedBox<URLRequest?>(nil)
        StubProtocol.handler = { request in seen.value = request; return (200, self.body) }
        let devices = try await TailscaleAPI.devices(token: "tskey-api-test-token", session: session())
        #expect(devices.map(\.hostname) == ["mac"])
        let request = try #require(seen.value)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tskey-api-test-token")
        #expect(request.url?.host == "api.tailscale.com" && request.url?.scheme == "https")
        #expect(request.url?.absoluteString.contains("tskey") == false, "never in the URL")
        #expect(request.httpMethod == "GET")
    }

    @Test func aBadTokenAndOtherFailuresAreTold() async {
        StubProtocol.handler = { _ in (401, Data()) }
        await #expect(throws: TailscaleAPI.Failure.unauthorized) { try await TailscaleAPI.devices(token: "x", session: session()) }
        StubProtocol.handler = { _ in (403, Data()) }
        await #expect(throws: TailscaleAPI.Failure.unauthorized) { try await TailscaleAPI.devices(token: "x", session: session()) }
        StubProtocol.handler = { _ in (500, Data()) }
        await #expect(throws: TailscaleAPI.Failure.unexpectedResponse) { try await TailscaleAPI.devices(token: "x", session: session()) }
        StubProtocol.handler = { _ in (200, Data("<html>".utf8)) }
        await #expect(throws: TailscaleAPI.Failure.unexpectedResponse) { try await TailscaleAPI.devices(token: "x", session: session()) }
        StubProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        await #expect(throws: TailscaleAPI.Failure.network) { try await TailscaleAPI.devices(token: "x", session: session()) }
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
