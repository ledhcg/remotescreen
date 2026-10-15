import XCTest

/// Chụp màn hình simulator để xem bằng mắt khi chỉnh giao diện. Chỉ ghi khi biến `TEST_RUNNER_SHOT_DIR` được đặt.
/// Ảnh chỉ chứa giao diện app trên simulator (server giả), không có màn hình Mac thật.
enum UIShots {
    static func save(_ app: XCUIApplication, _ name: String) {
        guard let directory = ProcessInfo.processInfo.environment["SHOT_DIR"] else { return }
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }
}
