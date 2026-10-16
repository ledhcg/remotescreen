import Foundation
import Localization
import Testing
@testable import SessionKit

@Suite("Network conditions: Tailscale, prechecks, host order, recovery")
struct NetworkConditionsTests {
    init() { Localization.forcedLanguage = "en" }

    private let wifi = NetworkSnapshot(isOnline: true, link: .wifi)
    private let cellular = NetworkSnapshot(isOnline: true, link: .cellular)
    private let wifiTailscale = NetworkSnapshot(isOnline: true, link: .wifi, tailscaleAddress: "100.101.102.103")
    private let cellularTailscale = NetworkSnapshot(isOnline: true, link: .cellular, tailscaleAddress: "100.101.102.103")

    // MARK: Tailscale addresses

    @Test func recognisesTailscaleAddressesAndNames() {
        for host in ["100.64.0.1", "100.127.255.254", "100.100.100.100", "fd7a:115c:a1e0::1", "[fd7a:115c:a1e0:ab12::3]",
                     "mac.tail1234.ts.net", "Mac.Tail1234.TS.NET", "mac.tail1234.ts.net."] {
            #expect(TailscaleNetwork.isTailscaleHost(host), "\(host)")
        }
        for host in ["100.63.255.255", "100.128.0.1", "10.0.0.2", "192.168.1.5", "mac.local", "fd7a:115c:a1e1::1",
                     "fe80::1", "ts.net.example.com", "", "100.64.0", "not an address"] {
            #expect(!TailscaleNetwork.isTailscaleHost(host), "\(host)")
        }
    }

    @Test func findsTheDeviceAddressOnATunnelOnly() {
        let interfaces: [(name: String, address: String)] = [
            ("en0", "192.168.1.20"), ("en0", "100.70.0.1"), // a CGNAT carrier address on Wi-Fi is not Tailscale
            ("utun3", "fd7a:115c:a1e0::9"), ("utun3", "100.90.1.2"), ("utun4", "10.8.0.2"),
        ]
        #expect(TailscaleNetwork.deviceAddress(in: interfaces) == "100.90.1.2") // IPv4 preferred
        #expect(TailscaleNetwork.deviceAddress(in: [("utun3", "fd7a:115c:a1e0::9")]) == "fd7a:115c:a1e0::9")
        #expect(TailscaleNetwork.deviceAddress(in: [("en0", "100.70.0.1"), ("utun1", "10.8.0.2")]) == nil)
    }

    @Test func listsRunningInterfacesWithoutLoopback() {
        let interfaces = TailscaleNetwork.runningInterfaceAddresses()
        #expect(!interfaces.contains { $0.name.hasPrefix("lo") })
        #expect(interfaces.allSatisfy { !$0.address.isEmpty && !$0.address.contains("%") })
    }

    // MARK: Prechecks

    @Test func precheckExplainsWhyAConnectionCannotWork() {
        #expect(NetworkPrecheck.problem(host: "10.0.0.2", network: .offline, useTailscale: true) == .offline)
        #expect(NetworkPrecheck.problem(host: "10.0.0.2", network: wifi, useTailscale: false) == nil)
        #expect(NetworkPrecheck.problem(host: "100.64.1.2", network: wifi, useTailscale: true) == .tailscaleNotConnected(host: "100.64.1.2"))
        #expect(NetworkPrecheck.problem(host: "100.64.1.2", network: wifiTailscale, useTailscale: false) == .tailscaleTurnedOff(host: "100.64.1.2"))
        #expect(NetworkPrecheck.problem(host: "mac.tail1.ts.net", network: wifiTailscale, useTailscale: true) == nil)
    }

    @Test func precheckMessagesSayWhatToDo() {
        #expect(NetworkPrecheck.message(for: .offline).contains("offline"))
        #expect(NetworkPrecheck.message(for: .tailscaleNotConnected(host: "100.64.1.2")).hasPrefix("100.64.1.2 is a Tailscale address"))
        #expect(NetworkPrecheck.message(for: .tailscaleTurnedOff(host: "100.64.1.2")).contains("turned off"))
    }

    // MARK: Host order

    private let hosts = ["192.168.1.5", "mac.local", "100.90.1.2", "mac.tail1.ts.net"]

    @Test func tailscaleHostsAreSkippedWhenTheyCannotAnswer() {
        #expect(HostOrdering.order(hosts, network: wifi, useTailscale: true) == ["192.168.1.5", "mac.local"])
        #expect(HostOrdering.order(hosts, network: wifiTailscale, useTailscale: false) == ["192.168.1.5", "mac.local"])
    }

    @Test func onWifiWithTailscaleTheLastWorkingAddressStaysFirst() {
        #expect(HostOrdering.order(hosts, network: wifiTailscale, useTailscale: true) == hosts)
    }

    @Test func onMobileDataTailscaleGoesFirst() {
        #expect(HostOrdering.order(hosts, network: cellularTailscale, useTailscale: true)
            == ["100.90.1.2", "mac.tail1.ts.net", "192.168.1.5", "mac.local"])
    }

    // MARK: Recovery

    @Test func aLiveSessionReconnectsWhenTheLinkChanges() {
        #expect(NetworkRecovery.action(before: wifi, after: cellular, outage: nil, session: .live, viaTailscale: false) == .reconnect)
    }

    @Test func aShortDropOnTheSameLinkIsLeftToTheTransport() {
        #expect(NetworkRecovery.action(before: wifi, after: wifi, outage: .seconds(1), session: .live, viaTailscale: false) == .none)
        #expect(NetworkRecovery.action(before: wifi, after: wifi, outage: .seconds(5), session: .live, viaTailscale: false) == .reconnect)
        #expect(NetworkRecovery.action(before: wifi, after: wifi, outage: nil, session: .live, viaTailscale: false) == .none)
    }

    @Test func throughTailscaleOnlyTheTunnelMatters() {
        #expect(NetworkRecovery.action(before: wifiTailscale, after: cellularTailscale, outage: nil, session: .live, viaTailscale: true) == .none)
        #expect(NetworkRecovery.action(before: cellular, after: cellularTailscale, outage: nil, session: .live, viaTailscale: true) == .reconnect)
        #expect(NetworkRecovery.action(before: wifiTailscale, after: wifiTailscale, outage: .seconds(10), session: .live, viaTailscale: true) == .reconnect)
    }

    @Test func aWaitingReconnectRetriesAtOnceAndNothingHappensOffline() {
        #expect(NetworkRecovery.action(before: wifi, after: wifi, outage: .seconds(1), session: .waitingToRetry, viaTailscale: false) == .retryNow)
        #expect(NetworkRecovery.action(before: wifi, after: .offline, outage: nil, session: .live, viaTailscale: false) == .none)
        #expect(NetworkRecovery.action(before: wifi, after: cellular, outage: nil, session: .inactive, viaTailscale: false) == .none)
    }
}
