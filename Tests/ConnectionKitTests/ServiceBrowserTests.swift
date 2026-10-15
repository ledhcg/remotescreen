import Foundation
import Network
import RFBKit
import Testing
@testable import ConnectionKit

@Suite("ServiceBrowser: lọc kết quả")
struct ServiceBrowserFilterTests {
    private func service(_ name: String, type: String = "_rfb._tcp", domain: String = "local.") -> NWEndpoint {
        .service(name: name, type: type, domain: domain, interface: nil)
    }

    @Test func keepsOnlyServicesDedupesAndSortsByName() {
        let endpoints: [NWEndpoint] = [
            service("Mac mini"), service("iMac"), service("Mac mini"), // trùng
            .hostPort(host: "1.2.3.4", port: 5900), // không phải dịch vụ Bonjour
        ]
        let hosts = ServiceBrowser.hosts(from: endpoints)
        #expect(hosts.map(\.name) == ["iMac", "Mac mini"])
    }

    @Test func sameNameOnDifferentDomainsAreDistinct() {
        let hosts = ServiceBrowser.hosts(from: [service("A", domain: "local."), service("A", domain: "example.com.")])
        #expect(hosts.count == 2)
    }

    @Test func emptyInputGivesEmptyList() {
        #expect(ServiceBrowser.hosts(from: [NWEndpoint]()).isEmpty)
    }

    @Test func discoveredHostMapsToABonjourTargetAndBackToAnEndpoint() {
        let host = DiscoveredHost(name: "Mac mini")
        #expect(host.target == .bonjour(name: "Mac mini", type: "_rfb._tcp", domain: "local."))
        #expect(host.target.endpoint == .service(name: "Mac mini", type: "_rfb._tcp", domain: "local.", interface: nil))
    }

    @Test func hostTargetMapsToHostAndPort() {
        let endpoint = SavedConnection.Target.host("mac.local", port: 5901).endpoint
        #expect(endpoint == .hostPort(host: "mac.local", port: 5901))
    }

    @Test func identityIsStableAndDistinguishesTypeAndDomain() {
        #expect(DiscoveredHost(name: "A").id == DiscoveredHost(name: "A").id)
        #expect(DiscoveredHost(name: "A").id != DiscoveredHost(name: "A", domain: "x.").id)
    }
}

/// Bonjour thật trên máy chạy test: một `NWListener` quảng bá dịch vụ giả rồi `ServiceBrowser` phải tìm ra nó.
/// Cần mDNSResponder (luôn có trên macOS). Dùng tên dịch vụ ngẫu nhiên nên không đụng máy thật nào.
@MainActor
@Suite("ServiceBrowser: Bonjour thật", .timeLimit(.minutes(1)))
struct ServiceBrowserLiveTests {
    private func advertise(name: String) async throws -> NWListener {
        let listener = try NWListener(using: .tcp)
        listener.service = NWListener.Service(name: name, type: ServiceBrowser.serviceType)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.send(content: Data("RFB 003.008\n".utf8), completion: .contentProcessed { _ in })
        }
        let ready = AsyncStream<Bool> { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: continuation.yield(true); continuation.finish()
                case .failed, .cancelled: continuation.yield(false); continuation.finish()
                default: break
                }
            }
        }
        listener.start(queue: .global())
        for await isReady in ready { try #require(isReady, "listener không khởi động được") }
        return listener
    }

    private func waitForHost(named name: String, in browser: ServiceBrowser, seconds: Int = 15) async -> DiscoveredHost? {
        for _ in 0..<(seconds * 10) {
            if let host = browser.hosts.first(where: { $0.name == name }) { return host }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    @Test func browserFindsAnAdvertisedServiceAndLosesItWhenItStops() async throws {
        let name = "RemoteScreenTest-\(UUID().uuidString.prefix(8))"
        let listener = try await advertise(name: name)
        defer { listener.cancel() }

        let browser = ServiceBrowser()
        browser.start()
        defer { browser.stop() }

        let host = await waitForHost(named: name, in: browser)
        #expect(host != nil, "không tìm thấy dịch vụ \(name) sau 15 giây. Đã thấy: \(browser.hosts.map(\.name))")
        #expect(host?.type == "_rfb._tcp")
        #expect(!browser.denied)

        listener.cancel()
        for _ in 0..<150 where browser.hosts.contains(where: { $0.name == name }) {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(!browser.hosts.contains { $0.name == name }, "dịch vụ đã tắt phải biến khỏi danh sách")
    }

    @Test func connectingThroughTheBonjourEndpointReachesTheService() async throws {
        let name = "RemoteScreenTest-\(UUID().uuidString.prefix(8))"
        let listener = try await advertise(name: name)
        defer { listener.cancel() }

        let target = DiscoveredHost(name: name).target
        let stream = NWByteStream(endpoint: target.endpoint)
        try await stream.connect(waitingPatience: .seconds(10))
        let hello = try await stream.read(exactly: 12)
        #expect(String(data: hello, encoding: .utf8) == "RFB 003.008\n")
        await stream.close()
    }
}
