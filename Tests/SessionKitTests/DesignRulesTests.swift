import Foundation
import Testing

/// `.claude/rules/design-system.md` as a test: the app's UI code may not go around `DesignSystem.swift`. It reads the app's own sources,
/// so a change that brings the old look back (frosted grey bars, hard corners, blue icons) fails here instead of on someone's iPad.
@Suite("Design system rules", .timeLimit(.minutes(1)))
struct DesignRulesTests {
    private static let appDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("App/ScreonApp")

    /// Every Swift file of the app with its lines, except the design system itself (it is where these things are allowed to be made).
    private static func sources() throws -> [(name: String, lines: [String])] {
        let files = FileManager.default.enumerator(at: appDirectory, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        try #require(!files.isEmpty, "the app sources were not found at \(appDirectory.path)")
        return try files.filter { $0.lastPathComponent != "DesignSystem.swift" }.map {
            ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8).components(separatedBy: "\n"))
        }
    }

    private static func offences(_ matches: (String, [String], Int) -> Bool) throws -> [String] {
        try sources().flatMap { file in
            file.lines.indices.compactMap { index -> String? in
                let line = file.lines[index].trimmingCharacters(in: .whitespaces)
                guard !line.hasPrefix("//") else { return nil } // a comment may say what it replaced
                return matches(line, file.lines, index) ? "\(file.name):\(index + 1): \(line)" : nil
            }
        }
    }

    @Test func noFrostedGlassOverARemoteScreen() throws {
        let found = try Self.offences { line, _, _ in
            [".ultraThinMaterial", ".thinMaterial", ".regularMaterial", ".thickMaterial", "UIBlurEffect"].contains { line.contains($0) }
        }
        #expect(found.isEmpty, "use chromePill()/chromeBanner()/chromeCard() instead:\n\(found.joined(separator: "\n"))")
    }

    @Test func everyCornerIsContinuous() throws {
        let swiftUI = try Self.offences { line, _, _ in
            line.contains("RoundedRectangle(cornerRadius:") && !line.contains(".continuous")
        }
        #expect(swiftUI.isEmpty, "add `style: .continuous`:\n\(swiftUI.joined(separator: "\n"))")
        let uiKit = try Self.offences { line, lines, index in
            guard line.contains("layer.cornerRadius") else { return false }
            return !lines[max(0, index - 3)...min(lines.count - 1, index + 3)].contains { $0.contains("cornerCurve") }
        }
        #expect(uiKit.isEmpty, "set `layer.cornerCurve = .continuous` beside it:\n\(uiKit.joined(separator: "\n"))")
    }

    @Test func noRawBlueAndNoGlobalTint() throws {
        let found = try Self.offences { line, _, _ in
            line.contains("Color.blue") || line.contains(".foregroundStyle(.blue)") || line.contains(".tint(.blue)")
        }
        #expect(found.isEmpty, "the accent is Theme.accent, used for selection only; a global tint paints menu icons:\n\(found.joined(separator: "\n"))")
        let globalTint = try Self.offences { line, _, _ in line.contains(".tint(Theme.accent)") }
        #expect(globalTint.isEmpty, "do not tint a whole screen with the accent; a menu inside it would paint its icons blue:\n\(globalTint.joined(separator: "\n"))")
    }

    @Test func theDesignSystemFileExistsAndIsWhatTheRuleSays() throws {
        let text = try String(contentsOf: Self.appDirectory.appendingPathComponent("DesignSystem.swift"), encoding: .utf8)
        for needed in ["enum Theme", "ChromeRoundButtonStyle", "KeyCapStyle", "QuickActionStyle", "chromeSheet", "static let hit: CGFloat = 44"] {
            #expect(text.contains(needed), "DesignSystem.swift lost `\(needed)`")
        }
    }
}
