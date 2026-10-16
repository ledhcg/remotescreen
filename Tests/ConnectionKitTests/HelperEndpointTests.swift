import Foundation
import Testing
@testable import ConnectionKit

@Suite("SavedConnection: helper endpoint")
struct HelperEndpointTests {
    /// A file written by the app before App Mode existed (no `helper` key).
    private static let legacyJSON = """
    {
      "items" : [
        {
          "id" : "11111111-2222-3333-4444-555555555555",
          "lastUsed" : 700000000,
          "name" : "Office Mac",
          "target" : { "host" : { "_0" : "mac.local", "port" : 5900 } },
          "username" : "alice"
        },
        {
          "id" : "66666666-7777-8888-9999-000000000000",
          "name" : "Studio",
          "target" : { "bonjour" : { "domain" : "local.", "name" : "Studio", "type" : "_rfb._tcp" } },
          "username" : ""
        }
      ]
    }
    """

    @Test func legacyFilesDecodeWithoutAHelperAndRoundTrip() throws {
        let list = try JSONDecoder().decode(ConnectionList.self, from: Data(Self.legacyJSON.utf8))
        #expect(list.items.count == 2)
        #expect(list.items.allSatisfy { $0.helper == nil })
        #expect(list.items[0].name == "Office Mac")
        #expect(list.items[0].target == .host("mac.local", port: 5900))
        #expect(list.items[0].lastUsed == Date(timeIntervalSinceReferenceDate: 700_000_000))

        let encoded = try JSONEncoder().encode(list)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("helper"), "an unpaired computer must not write a helper key")
        #expect(try JSONDecoder().decode(ConnectionList.self, from: encoded) == list)
    }

    @Test func pairedHelperRoundTrips() throws {
        let helper = HelperEndpoint(
            identityHash: String(repeating: "ab", count: 32), lastKnownHost: "10.0.0.2", lastKnownPort: 5901,
            bonjourName: "mac", pairedAt: Date(timeIntervalSinceReferenceDate: 800_000_000)
        )
        let list = ConnectionList([
            SavedConnection(name: "A", target: .host("mac.local", port: 5900), username: "alice", helper: helper),
        ])
        let decoded = try JSONDecoder().decode(ConnectionList.self, from: JSONEncoder().encode(list))
        #expect(decoded == list)
        #expect(decoded.items[0].helper == helper)
    }

    @Test func helperWithOnlyRequiredFieldsDecodes() throws {
        let json = #"{"identityHash":"00","pairedAt":1}"#
        let helper = try JSONDecoder().decode(HelperEndpoint.self, from: Data(json.utf8))
        #expect(helper.lastKnownHost == nil && helper.lastKnownPort == nil && helper.bonjourName == nil)
    }
}

@Suite struct HelperEndpointCandidateTests {
    @Test func lastWorkingAddressComesFirstThenTheOthersOnce() {
        let endpoint = HelperEndpoint(
            identityHash: String(repeating: "a", count: 64), lastKnownHost: "10.0.0.2", lastKnownPort: 7361, pairedAt: Date(),
            otherHosts: ["mac.local", "10.0.0.2", "100.64.1.2", "MAC.local", ""])
        #expect(endpoint.candidateHosts == ["10.0.0.2", "mac.local", "100.64.1.2"])
    }

    @Test func candidatesAreBounded() {
        let many = (0..<20).map { "10.0.0.\($0)" } + [String(repeating: "x", count: 300)]
        let endpoint = HelperEndpoint(identityHash: "", lastKnownHost: nil, pairedAt: Date(), otherHosts: many)
        #expect(endpoint.candidateHosts.count == HelperEndpoint.maxHosts)
        #expect(endpoint.candidateHosts.allSatisfy { $0.utf8.count <= 253 })
    }

    @Test func filesWithoutOtherHostsStillDecode() throws {
        let json = #"{"identityHash":"ab","lastKnownHost":"mac.local","lastKnownPort":7361,"pairedAt":0}"#
        let endpoint = try JSONDecoder().decode(HelperEndpoint.self, from: Data(json.utf8))
        #expect(endpoint.otherHosts == nil)
        #expect(endpoint.candidateHosts == ["mac.local"])
    }
}
