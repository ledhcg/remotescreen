import Foundation
import Testing
@testable import ConnectionKit

@Suite struct AppModeSettingsTests {
    static let legacy = """
    { "items": [ { "id": "6F1D8F52-8B0E-4F43-9F63-0D3F2E1A9B11", "name": "Studio", "username": "alice",
      "target": { "host": { "_0": "mac.local", "port": 5900 } } } ] }
    """

    private func connection(_ settings: AppModeSettings?) -> SavedConnection {
        SavedConnection(name: "Studio", target: .host("mac.local", port: 5900), username: "alice", appMode: settings)
    }

    @Test func aFileWithoutSettingsDecodesToStandardAndWritesNoKey() throws {
        let list = try JSONDecoder().decode(ConnectionList.self, from: Data(Self.legacy.utf8))
        #expect(list.items.first?.appMode == nil)
        #expect(list.items.first?.appModeSettings == .standard)
        #expect(!String(decoding: try JSONEncoder().encode(list), as: UTF8.self).contains("appMode"))
    }

    @Test func settingsRoundTrip() throws {
        let settings = AppModeSettings(qualityCap: .low, maxFramesPerSecond: 30, allowMain10: true, playAudio: false)
        let list = ConnectionList([connection(settings)])
        let decoded = try JSONDecoder().decode(ConnectionList.self, from: try JSONEncoder().encode(list))
        #expect(decoded == list)
        #expect(decoded.items[0].appModeSettings == settings)
    }

    @Test func missingUnknownOrWrongTypedKeysFallBackToDefaults() throws {
        func decode(_ json: String) throws -> AppModeSettings { try JSONDecoder().decode(AppModeSettings.self, from: Data(json.utf8)) }
        #expect(try decode("{}") == .standard)
        #expect(try decode(#"{"qualityCap":"ultra","maxFramesPerSecond":"fast","allowMain10":3,"playAudio":"yes"}"#) == .standard)
        #expect(try decode(#"{"qualityCap":"high","future":1}"#).qualityCap == .high)
    }

    @Test func frameRateIsCappedAndClamped() {
        #expect(AppModeSettings().effectiveFramesPerSecond(displayMaximum: 120) == 120)
        #expect(AppModeSettings(maxFramesPerSecond: 30).effectiveFramesPerSecond(displayMaximum: 120) == 30)
        #expect(AppModeSettings(maxFramesPerSecond: 90).effectiveFramesPerSecond(displayMaximum: 60) == 60)
        #expect(AppModeSettings(maxFramesPerSecond: 1).effectiveFramesPerSecond(displayMaximum: 60) == 15)
        #expect(AppModeSettings(maxFramesPerSecond: 100_000).effectiveFramesPerSecond(displayMaximum: 60) == 60)
        #expect(AppModeSettings(maxFramesPerSecond: -5).effectiveFramesPerSecond(displayMaximum: 0) == 15)
    }
}
