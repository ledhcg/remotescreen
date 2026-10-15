import Foundation
import Network
import Testing
@testable import RFBKit

@Suite("NWByteStream: waiting for the network and classifying errors")
struct NWByteStreamTests {
    @Test("Errors for network not up, no route, Local Network permission blocked: worth waiting for",
          arguments: [
              NWError.posix(.ENETDOWN),        // 50: error the user hit on an iPad
              NWError.posix(.ENETUNREACH),     // 51
              NWError.posix(.EHOSTUNREACH),    // 65
              NWError.dns(-65570),             // kDNSServiceErr_PolicyDenied: Local Network permission
          ])
    func recoverable(error: NWError) {
        #expect(NWByteStream.isRecoverableWaitingError(error))
    }

    @Test("Definitive network answers: do not wait",
          arguments: [
              NWError.posix(.ECONNREFUSED),    // Mac has Screen Sharing turned off
              NWError.posix(.ETIMEDOUT),
              NWError.posix(.ECONNRESET),
              NWError.dns(-65554),             // kDNSServiceErr_NoSuchRecord: mistyped host name
          ])
    func definitive(error: NWError) {
        #expect(!NWByteStream.isRecoverableWaitingError(error))
    }

    /// Required: whether `NWConnection` reports "connection refused" via `.failed` or `.waiting`, a user who allowed
    /// waiting 20 seconds must still see this error **immediately**, not after 20 seconds.
    @Test("Closed port: reports ECONNREFUSED immediately even when a long wait is allowed")
    func refusedIsImmediateEvenWithPatience() async throws {
        let port = try closedLoopbackPort()
        let stream = NWByteStream(host: "127.0.0.1", port: port)
        let started = ContinuousClock.now
        do {
            try await stream.connect(waitingPatience: .seconds(20))
            Issue.record("Must not connect successfully to a closed port")
        } catch let error as NWError {
            #expect(error == .posix(.ECONNREFUSED))
        }
        let elapsed = ContinuousClock.now - started
        #expect(elapsed < .seconds(5), "took \(elapsed): a definitive error was waited out like a transient one")
        await stream.close()
    }

    /// Finds a loopback port nobody is listening on: opens a listener to get a port, then closes it.
    private func closedLoopbackPort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        try #require(bound == 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        try #require(named == 0)
        return UInt16(bigEndian: address.sin_port)
    }
}

@Suite("NWParameters.rfbTCP")
struct RFBTCPParametersTests {
    private var tcp: NWProtocolTCP.Options? {
        NWParameters.rfbTCP.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options
    }

    @Test func disablesNagleSoSmallInputEventsAreNotDelayed() throws {
        #expect(try #require(tcp).noDelay)
    }

    @Test func enablesKeepaliveSoADeadPeerIsNoticedInAboutHalfAMinute() throws {
        let tcp = try #require(tcp)
        #expect(tcp.enableKeepalive)
        #expect(tcp.keepaliveIdle == 20)
        #expect(tcp.keepaliveInterval == 5)
        #expect(tcp.keepaliveCount == 3)
        #expect(tcp.keepaliveIdle + tcp.keepaliveInterval * tcp.keepaliveCount <= 40, "slowest detection is about 35 seconds")
    }

    @Test func aLiveConnectionStillWorksWithTheseParameters() async throws {
        // Use these very parameters to connect to a real listener inside the test process, to make sure they do not break the connection.
        let listener = try NWListener(using: .rfbTCP)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.send(content: Data("RFB 003.008\n".utf8), completion: .contentProcessed { _ in })
        }
        let ready = AsyncStream<UInt16> { continuation in
            listener.stateUpdateHandler = { state in
                if case .ready = state, let port = listener.port?.rawValue { continuation.yield(port); continuation.finish() }
            }
        }
        listener.start(queue: .global())
        defer { listener.cancel() }
        var portValue: UInt16 = 0
        for await value in ready { portValue = value }
        let stream = NWByteStream(host: "127.0.0.1", port: portValue)
        try await stream.connect()
        #expect(String(data: try await stream.read(exactly: 12), encoding: .utf8) == "RFB 003.008\n")
        await stream.close()
    }
}
