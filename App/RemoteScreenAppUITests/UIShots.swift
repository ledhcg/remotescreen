import XCTest

/// Captures simulator screenshots for visual inspection while tuning the UI. Only writes when the `TEST_RUNNER_SHOT_DIR` variable is set.
/// Images contain only the app UI in the simulator (fake server), not a real Mac screen.
enum UIShots {
    static func save(_ app: XCUIApplication, _ name: String) {
        guard let directory = ProcessInfo.processInfo.environment["SHOT_DIR"] else { return }
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }
}
