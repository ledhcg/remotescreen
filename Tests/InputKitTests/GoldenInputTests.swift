import Foundation
import Testing

/// Pins the exact RFB messages the input pipeline produces for a broad corpus of scenarios. The expected text was recorded from the
/// pipeline *before* it was split into protocol-neutral intents and `RFBInputEncoder`; any difference means wire behavior changed.
@Suite("Golden RFB input output")
struct GoldenInputTests {
    @Test func everyScenarioMatchesTheRecordedOutput() {
        let scenarios = goldenScenarios()
        #expect(scenarios.count == goldenExpected.count, "scenario set changed: re-record only if the wire behavior change is intended")
        for (name, lines) in scenarios {
            let expected = goldenExpected[name]
            #expect(expected != nil, "no recorded output for \(name)")
            #expect(lines == expected, "scenario \(name) differs")
        }
    }

    /// Set `GOLDEN_RECORD=<path>` to write the current output (used once, before the refactor).
    @Test func recordWhenAsked() throws {
        guard let path = ProcessInfo.processInfo.environment["GOLDEN_RECORD"] else { return }
        var text = "// Recorded RFB output for GoldenInputCorpus. Generated; see GoldenInputTests.\n\nlet goldenExpected: [String: [String]] = [\n"
        for (name, lines) in goldenScenarios() {
            text += "    \(name.debugDescription): [\n"
            for line in lines { text += "        \(line.debugDescription),\n" }
            text += "    ],\n"
        }
        text += "]\n"
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
