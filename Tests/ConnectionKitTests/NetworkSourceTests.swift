import Foundation
import Localization
import Network
import Testing
@testable import ConnectionKit

@Suite("Network source: LAN or Tailscale", .timeLimit(.minutes(1)))
struct NetworkSourceTests {
    init() { Localization.forcedLanguage = "en" }

    private let sampleDevices = Data("""
    {"devices": [
      {"id": "1", "hostname": "mac-mini", "name": "mac-mini.tail1234.ts.net", "addresses": ["fd7a:115c:a1e0::1", "100.101.102.103"], "os": "macOS"},
      {"id": "2", "hostname": "iphone", "name": "iphone.tail1234.ts.net.", "addresses": ["100.64.0.9"], "os": "iOS"},
      {"id": "3", "hostname": "no-address", "addresses": [], "os": "macOS"},
      {"id": "4", "hostname": "lan-only", "addresses": ["192.168.1.9"], "os": "macOS"},
      {"id": "1", "hostname": "duplicate", "addresses": ["100.64.0.2"], "os": "macOS"},
      {"hostname": "no-id", "addresses": ["100.64.0.3"], "os": "macOS"}
    ]}
    """.utf8)

    // MARK: Source of a computer

    @Test func theSourceIsReadOffTheAddress() {
        #expect(NetworkSource(host: "100.101.102.103") == .tailscale)
        #expect(NetworkSource(host: "mac-mini.tail1234.ts.net") == .tailscale)
        #expect(NetworkSource(host: "192.168.1.5") == .lan)
        #expect(NetworkSource(host: "mac.local") == .lan)
        #expect(NetworkSource(target: .bonjour(name: "Mac", type: "_rfb._tcp", domain: "local.")) == .lan)
    }

    @Test func aSavedComputerKeepsItsSourceAndOldFilesDeriveIt() throws {
        let oldFile = Data("""
        {"id": "\(UUID().uuidString)", "name": "Old", "username": "alice", "target": {"host": {"_0": "100.64.1.2", "port": 5900}}}
        """.utf8)
        let old = try JSONDecoder().decode(SavedConnection.self, from: oldFile)
        #expect(old.networkSource == nil)
        #expect(old.network == .tailscale, "derived from the address")

        var stored = SavedConnection(name: "Mac", target: .host("mac.local", port: 5900), username: "alice", networkSource: .tailscale)
        #expect(stored.network == .tailscale, "the saved source wins over the address")
        stored.networkSource = nil
        #expect(stored.network == .lan)
        let again = try JSONDecoder().decode(SavedConnection.self, from: JSONEncoder().encode(SavedConnection(
            name: "Mac", target: .host("mac.local", port: 5900), username: "alice", networkSource: .tailscale)))
        #expect(again.networkSource == .tailscale)
    }

    @MainActor @Test func rememberingStoresTheNetworkItWasFoundOn() throws {
        let model = ConnectionsModel(store: ConnectionStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("network-source-\(UUID().uuidString).json")), secrets: InMemorySecretStore())
        model.remember(target: .host("100.101.102.103", port: 5900), username: "alice", password: "s3cret", name: "Mini")
        #expect(model.saved.first?.networkSource == .tailscale)
        model.remember(target: .host("10.0.0.2", port: 5900), username: "alice", password: "s3cret", name: "Studio", network: .tailscale)
        #expect(model.saved.first { $0.name == "Studio" }?.networkSource == .tailscale, "an explicit source wins")
        // Reconnecting keeps what was saved.
        model.remember(target: .host("100.101.102.103", port: 5900), username: "alice", password: "s3cret", name: "Mini")
        #expect(model.saved.filter { $0.name == "Mini" }.count == 1)
    }

    // MARK: Tailnet devices

    @Test func theDeviceListIsReadAndCleaned() throws {
        let devices = try TailscaleAPI.parse(sampleDevices)
        #expect(devices.map(\.hostname) == ["iphone", "mac-mini"], "no address, no id, a duplicate id and a LAN address are skipped")
        let mini = try #require(devices.first { $0.hostname == "mac-mini" })
        #expect(mini.address == "100.101.102.103", "IPv4 first")
        #expect(mini.addresses == ["100.101.102.103", "fd7a:115c:a1e0::1"])
        #expect(mini.canBeSharedScreen)
        #expect(mini.target == .host("100.101.102.103", port: 5900))
        #expect(devices.first { $0.hostname == "iphone" }?.dnsName == "iphone.tail1234.ts.net", "the trailing dot goes")
        #expect(devices.first { $0.hostname == "iphone" }?.canBeSharedScreen == false)
    }

    @Test func garbageAndHugeAnswersAreRejected() throws {
        #expect(throws: TailscaleAPI.Failure.unexpectedResponse) { try TailscaleAPI.parse(Data("nope".utf8)) }
        #expect(throws: TailscaleAPI.Failure.unexpectedResponse) { try TailscaleAPI.parse(Data("{\"devices\": 3}".utf8)) }
        #expect(throws: TailscaleAPI.Failure.unexpectedResponse) { try TailscaleAPI.parse(Data(count: 9 << 20)) }
        let many = "{\"devices\": [" + (0..<(TailscaleAPI.maxDevices + 50)).map {
            "{\"id\": \"\($0)\", \"hostname\": \"h\($0)\", \"addresses\": [\"100.64.\($0 / 250).\($0 % 250 + 1)\"], \"os\": \"macOS\"}"
        }.joined(separator: ",") + "]}"
        #expect(try TailscaleAPI.parse(Data(many.utf8)).count == TailscaleAPI.maxDevices)
    }

    @Test func aDeviceMatchesASavedComputerByAddressNameOrHelperHost() throws {
        let device = try #require(try TailscaleAPI.parse(sampleDevices).first { $0.hostname == "mac-mini" })
        #expect(device.matches(SavedConnection(name: "A", target: .host("100.101.102.103", port: 5900), username: "")))
        #expect(device.matches(SavedConnection(name: "B", target: .host("Mac-Mini.tail1234.ts.net", port: 5900), username: "")))
        let viaHelper = SavedConnection(
            name: "C", target: .bonjour(name: "Mac", type: "_rfb._tcp", domain: "local."), username: "",
            helper: HelperEndpoint(identityHash: String(repeating: "a", count: 64), lastKnownHost: "mac.local", pairedAt: Date(),
                                   otherHosts: ["100.101.102.103"]))
        #expect(device.matches(viaHelper))
        #expect(!device.matches(SavedConnection(name: "D", target: .host("100.64.9.9", port: 5900), username: "")))
    }

    // MARK: The list

    @Test func tailnetMacsAreListedOnlyWhenTheyAnswerAndAreNotSaved() throws {
        let devices = try TailscaleAPI.parse(sampleDevices)
        let answered: Set<ProbeTarget> = [ProbeTarget(host: "100.101.102.103", port: 5900), ProbeTarget(host: "100.64.0.9", port: 5900)]
        var sections = ComputerList.sections(saved: [], discovered: [], tailnet: devices, reachable: answered)
        #expect(sections.tailnet.map(\.name) == ["mac-mini"], "an iPhone is not a screen to share, and a silent Mac is not offered")
        #expect(sections.tailnet.first?.network == .tailscale)
        #expect(sections.tailnet.first?.isOnline == true)
        #expect(!sections.isEmpty)

        let saved = [SavedConnection(name: "Mini", target: .host("100.101.102.103", port: 5900), username: "alice")]
        sections = ComputerList.sections(saved: saved, discovered: [], tailnet: devices, reachable: answered)
        #expect(sections.tailnet.isEmpty, "already saved")
        #expect(sections.saved.first?.isOnline == true, "its address answered")
        #expect(sections.saved.first?.network == .tailscale)
    }

    @Test func aSavedComputerIsOnlineWhenAnyOfItsAddressesAnswers() {
        let helper = HelperEndpoint(identityHash: String(repeating: "b", count: 64), lastKnownHost: "192.168.1.5", pairedAt: Date(),
                                    otherHosts: ["100.64.5.5"])
        let saved = SavedConnection(name: "Mac", target: .bonjour(name: "Mac", type: "_rfb._tcp", domain: "local."), username: "alice", helper: helper)
        #expect(saved.probeTargets() == [ProbeTarget(host: "192.168.1.5", port: 5900), ProbeTarget(host: "100.64.5.5", port: 5900)])
        let off = ComputerList.sections(saved: [saved], discovered: [], reachable: [])
        #expect(off.saved.first?.isOnline == false)
        let viaTailscale = ComputerList.sections(saved: [saved], discovered: [], reachable: [ProbeTarget(host: "100.64.5.5", port: 5900)])
        #expect(viaTailscale.saved.first?.isOnline == true)
    }

    @Test func probeTargetsAreBounded() {
        let helper = HelperEndpoint(identityHash: String(repeating: "c", count: 64), lastKnownHost: "10.0.0.1", pairedAt: Date(),
                                    otherHosts: (2...8).map { "10.0.0.\($0)" })
        let saved = SavedConnection(name: "Mac", target: .host("10.0.0.1", port: 5900), username: "", helper: helper)
        #expect(saved.probeTargets().count == 4)
        #expect(saved.probeTargets(maxProbes: 2).count == 2)
        #expect(Set(saved.probeTargets()).count == 4, "no duplicate")
    }

    // MARK: Probing

    private func listen() async throws -> (NWListener, UInt16) {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { $0.cancel() }
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
        var up = false
        for await value in ready { up = value }
        let port = try #require(listener.port?.rawValue)
        try #require(up)
        return (listener, port)
    }

    @Test func aListeningPortIsReachableAndAClosedOneIsNot() async throws {
        let (listener, port) = try await listen()
        #expect(await HostReachability.isReachable(ProbeTarget(host: "127.0.0.1", port: port), timeout: .seconds(3)))
        listener.cancel()
        try await Task.sleep(for: .milliseconds(200))
        #expect(await !HostReachability.isReachable(ProbeTarget(host: "127.0.0.1", port: port), timeout: .seconds(3)))
        #expect(await !HostReachability.isReachable(ProbeTarget(host: "", port: 5900)))
        #expect(await !HostReachability.isReachable(ProbeTarget(host: "127.0.0.1", port: 0)))
    }

    @Test func aProbeThatNeverAnswersEndsAtTheTimeout() async {
        // 192.0.2.0/24 is reserved for documentation: nothing answers, and no route exists on most machines.
        let start = ContinuousClock.now
        let answered = await HostReachability.isReachable(ProbeTarget(host: "192.0.2.1", port: 5900), timeout: .milliseconds(400))
        #expect(!answered)
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @MainActor @Test func theMonitorKeepsWhatAnsweredAndHonoursTheGate() async {
        let up = ProbeTarget(host: "10.0.0.1", port: 5900)
        let down = ProbeTarget(host: "10.0.0.2", port: 5900)
        let gated = ProbeTarget(host: "100.64.0.1", port: 5900)
        let probed = ProbedLog()
        let monitor = ReachabilityMonitor(interval: .seconds(60), probe: { target, _ in
            await probed.add(target)
            return target != down
        })
        monitor.isProbeAllowed = { $0 != gated }
        monitor.setTargets([up, down, gated])
        await monitor.refresh()
        #expect(monitor.reachable == [up])
        #expect(monitor.checked == [up, down, gated])
        #expect(await !probed.all.contains(gated), "a gated target is never probed")

        monitor.setTargets([up])
        #expect(monitor.reachable == [up])
        #expect(monitor.checked == [up], "targets that left are forgotten")
    }

    @MainActor @Test func theMonitorNeverRunsMoreProbesThanItsLimitAtOnce() async {
        let targets = Set((1...20).map { ProbeTarget(host: "10.1.0.\($0)", port: 5900) })
        let gauge = ConcurrencyGauge()
        let monitor = ReachabilityMonitor(interval: .seconds(60), maxConcurrent: 3, probe: { _, _ in
            await gauge.enter()
            try? await Task.sleep(for: .milliseconds(10))
            await gauge.leave()
            return true
        })
        monitor.setTargets(targets)
        await monitor.refresh()
        #expect(await gauge.peak <= 3)
        #expect(monitor.reachable == targets)
    }
}

private actor ProbedLog {
    private(set) var all: [ProbeTarget] = []
    func add(_ target: ProbeTarget) { all.append(target) }
}

private actor ConcurrencyGauge {
    private var running = 0
    private(set) var peak = 0
    func enter() { running += 1; peak = max(peak, running) }
    func leave() { running -= 1 }
}
