import Foundation
import Localization
import RFBKit
import Testing
@testable import SessionKit

/// Checks the Vietnamese translations of SessionKit and ConnectionKit: real messages come back in Vietnamese, and every
/// `tr("…")` key used in the sources has a non-empty entry in the matching `vi.lproj/Localizable.strings`.
@Suite("Localization: Vietnamese tables", .serialized)
struct LocalizationTests {
    init() { Localization.forcedLanguage = "en" }

    /// `<repo>/` derived from this file's path (`Tests/SessionKitTests/LocalizationTests.swift`).
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test func vietnameseTableTranslatesRealMessages() {
        // Looks the Vietnamese table up explicitly: no shared state, so it cannot race with suites that force English.
        func vi(_ key: String) -> String { Localization.string(key, bundle: localizationBundle, language: "vi") }
        #expect(vi("The server closed the connection.") == "Máy chủ đã đóng kết nối.")
        #expect(vi("Signed in with a VNC password (weak). Use only on a trusted network.") == "Đăng nhập bằng mật khẩu VNC (yếu). Chỉ dùng trên mạng tin cậy.")
        #expect(vi("A string that has no translation") == "A string that has no translation", "a missing key falls back to the English key")
    }

    @Test func englishIsTheSourceLanguage() {
        #expect(ConnectionFailureMessage.text(for: RFBError.connectionClosed, hasUsername: true) == "The server closed the connection.")
    }

    @Test(arguments: ["SessionKit", "ConnectionKit"])
    func everyTranslationKeyHasAVietnameseEntry(package: String) throws {
        let table = try Self.parseStrings(at: Self.root.appendingPathComponent("Sources/\(package)/Resources/vi.lproj/Localizable.strings"))
        let keys = try Self.trKeys(in: Self.root.appendingPathComponent("Sources/\(package)"))
        #expect(!keys.isEmpty || package == "ConnectionKit")
        for key in keys {
            let value = table[key]
            #expect(value?.isEmpty == false, "missing Vietnamese entry in \(package): \(key)")
        }
        for key in table.keys {
            #expect(keys.contains(key), "unused Vietnamese entry in \(package): \(key)")
        }
    }

    // MARK: - Helpers

    /// Unescapes the subset of escapes used in `.strings` files.
    private static func unescape(_ text: String) -> String {
        var result = ""
        var iterator = text.makeIterator()
        while let character = iterator.next() {
            guard character == "\\", let next = iterator.next() else { result.append(character); continue }
            switch next {
            case "n": result.append("\n")
            case "t": result.append("\t")
            default: result.append(next)
            }
        }
        return result
    }

    private static func parseStrings(at url: URL) throws -> [String: String] {
        let text = try String(contentsOf: url, encoding: .utf8)
        let pattern = try NSRegularExpression(pattern: #"^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";\s*$"#, options: [.anchorsMatchLines])
        var table: [String: String] = [:]
        let whole = NSRange(text.startIndex..., in: text)
        for match in pattern.matches(in: text, range: whole) {
            guard let key = Range(match.range(at: 1), in: text), let value = Range(match.range(at: 2), in: text) else { continue }
            table[unescape(String(text[key]))] = unescape(String(text[value]))
        }
        return table
    }

    private static func trKeys(in directory: URL) throws -> Set<String> {
        let pattern = try NSRegularExpression(pattern: #"tr\(\s*"((?:[^"\\]|\\.)*)""#)
        var keys: Set<String> = []
        let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)!
        for case let file as URL in files where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let range = Range(match.range(at: 1), in: text) { keys.insert(unescape(String(text[range]))) }
            }
        }
        return keys
    }
}
