import XCTest

/// Chụp màn hình app sau một cú chạm để script `Tools/mock-rfb-server/verify_cursor.py` kiểm tra con trỏ có hiện đúng
/// chỗ không. Bài test này không tự khẳng định pixel: nó chỉ thao tác và lưu ảnh ra đường dẫn trong `CURSOR_SHOT`.
///
/// Chạy qua: Tools/mock-rfb-server/run_cursor_test.sh
final class CursorUITests: XCTestCase {
    private let remote = CGSize(width: 800, height: 600)

    func testCursorAppearsWhereTheServerPutsItsMarker() throws {
        let app = XCUIApplication()
        app.launchEnvironment = ["RFB_HOST": "127.0.0.1", "RFB_PORT": "5959"]
        app.launch()

        let screen = app.descendants(matching: .any).matching(identifier: "remoteScreen").firstMatch
        XCTAssertTrue(screen.waitForExistence(timeout: 30), "không thấy view màn hình từ xa")
        Thread.sleep(forTimeInterval: 4)

        let frame = screen.frame
        let scale = min(frame.width / remote.width, frame.height / remote.height)
        let origin = CGPoint(x: (frame.width - remote.width * scale) / 2, y: (frame.height - remote.height * scale) / 2)
        func point(_ x: Double, _ y: Double) -> XCUICoordinate {
            screen.coordinate(withNormalizedOffset: CGVector(
                dx: (origin.x + x * scale) / frame.width, dy: (origin.y + y * scale) / frame.height
            ))
        }

        // Chạm xa chữ thập trắng ở giữa, vì chữ thập có pixel trắng giống ruột con trỏ.
        point(560, 140).tap()
        Thread.sleep(forTimeInterval: 1.5)

        let png = XCUIScreen.main.screenshot().pngRepresentation
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = "cursor-after-tap"
        attachment.lifetime = .keepAlways
        add(attachment)

        if let path = ProcessInfo.processInfo.environment["CURSOR_SHOT"] {
            try png.write(to: URL(fileURLWithPath: path))
        }
    }
}
