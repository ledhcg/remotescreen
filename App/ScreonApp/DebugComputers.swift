#if DEBUG
import ConnectionKit
import Foundation

/// UI tests: a private list of computers, so a test never sees (or leaves) what another one saved.
///
/// - `SCREON_STORE_NAME`: file name in the app's temporary directory; the list starts empty each launch, and passwords are kept in
///   memory (an unsigned simulator build cannot use the Keychain).
/// - `SCREON_SEED`: JSON array of `{"name", "host", "port"?, "network"?: "lan"|"tailscale", "paired"?: true}` computers to start with.
enum DebugComputers {
    private struct Seed: Decodable {
        var name: String
        var host: String
        var port: UInt16?
        var network: NetworkSource?
        var paired: Bool?
    }

    @MainActor
    static func model() -> ConnectionsModel? {
        let environment = ProcessInfo.processInfo.environment
        guard let name = environment["SCREON_STORE_NAME"] else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        let model = ConnectionsModel(store: ConnectionStore(fileURL: url), secrets: InMemorySecretStore())
        let seeds = environment["SCREON_SEED"].flatMap { try? JSONDecoder().decode([Seed].self, from: Data($0.utf8)) } ?? []
        for seed in seeds {
            let helper = seed.paired == true
                ? HelperEndpoint(identityHash: String(repeating: "a", count: 64), lastKnownHost: seed.host, lastKnownPort: 7361, pairedAt: Date())
                : nil
            let connection = SavedConnection(
                name: seed.name, target: .host(seed.host, port: seed.port ?? 5900), username: "alice", helper: helper,
                networkSource: seed.network)
            try? model.save(connection, password: nil)
        }
        return model
    }
}
#endif
