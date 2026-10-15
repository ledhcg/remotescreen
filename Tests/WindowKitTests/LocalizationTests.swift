import Foundation
import Localization
import Testing
@testable import WindowKit

/// Every `tr("…")` key used in WindowKit has a non-empty Vietnamese entry, and the table has no unused entries.
@Suite("Localization: WindowKit Vietnamese table", .serialized)
struct LocalizationTests {
    init() { Localization.forcedLanguage = "en" }

    /// `<repo>/` derived from this file's path (`Tests/WindowKitTests/LocalizationTests.swift`).
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test func englishIsTheSourceLanguage() {
        #expect(SceneBindingState.windowClosed(reopenHint: WindowMatchQuery(bundleID: "b", title: "t", indexHint: 0)).placeholderMessage
            == "This window was closed on the Mac.")
    }

    @Test func everyTranslationKeyHasAVietnameseEntry() throws {
        let table = try Self.parseStrings(at: Self.root.appendingPathComponent("Sources/WindowKit/Resources/vi.lproj/Localizable.strings"))
        let keys = try Self.trKeys(in: Self.root.appendingPathComponent("Sources/WindowKit"))
        #expect(!keys.isEmpty)
        for key in keys {
            #expect(table[key]?.isEmpty == false, "missing Vietnamese entry in WindowKit: \(key)")
        }
        for key in table.keys {
            #expect(keys.contains(key), "unused Vietnamese entry in WindowKit: \(key)")
        }
    }

    // MARK: - Helpers

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
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let key = Range(match.range(at: 1), in: text), let value = Range(match.range(at: 2), in: text) else { continue }
            table[unescape(String(text[key]))] = unescape(String(text[value]))
        }
        return table
    }

    private static func trKeys(in directory: URL) throws -> Set<String> {
        let pattern = try NSRegularExpression(pattern: #"\btr\(\s*"((?:[^"\\]|\\.)*)""#)
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
