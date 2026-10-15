import XCTest

/// Sidebar phím bổ trợ kiểu Sidecar, đầu-cuối với server giả. Bài này chỉ thao tác (và kiểm bố cục); `verify_sidebar.py` đọc
/// log của server để khẳng định thứ tự phím và cú nhấp.
///
/// "Giữ ⌘ bằng một tay, chạm bằng tay kia" XCUITest không tạo được (không có hai cú chạm độc lập cùng lúc): kiểm tay trên iPad.
final class SidebarUITests: XCTestCase {
    private let remote = CGSize(width: 800, height: 600)

    func testModifierKeysUndoEscapeAndHiding() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment = [
            "RFB_HOST": "127.0.0.1", "RFB_PORT": "5959", "RFB_SIDEBAR": "leading", "RFB_DEFAULTS_SUITE": "sidebar-ui-test",
        ]
        app.launch()
        let screen = app.descendants(matching: .any).matching(identifier: "remoteScreen").firstMatch
        XCTAssertTrue(screen.waitForExistence(timeout: 30), "không vào được phiên:\n\(app.debugDescription)")
        let command = app.buttons["Command"]
        XCTAssertTrue(command.waitForExistence(timeout: 10), "sidebar không hiện")
        Thread.sleep(forTimeInterval: 3)

        // Sidebar nằm cạnh màn hình Mac, không đè lên.
        let sidebarRight = command.frame.maxX
        XCTAssertGreaterThanOrEqual(screen.frame.minX, sidebarRight - 1, "màn hình Mac phải bắt đầu sau sidebar")
        let widthWithSidebar = screen.frame.width

        func point(_ x: Double, _ y: Double) -> XCUICoordinate {
            let frame = screen.frame
            let scale = min(frame.width / remote.width, frame.height / remote.height)
            let origin = CGPoint(x: (frame.width - remote.width * scale) / 2, y: (frame.height - remote.height * scale) / 2)
            return screen.coordinate(withNormalizedOffset: CGVector(
                dx: (origin.x + x * scale) / frame.width, dy: (origin.y + y * scale) / frame.height
            ))
        }

        // 1. Chạm ⌘ một lần: dính cho MỘT cú nhấp, rồi tự nhả.
        command.tap()
        XCTAssertEqual(command.value as? String, "Dính cho thao tác kế tiếp")
        point(150, 150).tap()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(command.value as? String, "", "⌘ dính phải nhả sau cú nhấp")

        // 2. Chạm hai lần: khóa qua hai cú nhấp, chạm lại thì mở.
        command.doubleTap()
        XCTAssertEqual(command.value as? String, "Đang khóa")
        point(550, 150).tap()
        Thread.sleep(forTimeInterval: 0.8)
        point(550, 450).tap()
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertEqual(command.value as? String, "Đang khóa", "khóa thì không nhả sau cú nhấp")
        command.tap()
        XCTAssertEqual(command.value as? String, "")
        Thread.sleep(forTimeInterval: 0.5)

        // 3. Hoàn tác (⌘Z) và Escape.
        app.buttons["Hoàn tác"].tap()
        Thread.sleep(forTimeInterval: 0.5)
        app.buttons["Escape"].tap()
        Thread.sleep(forTimeInterval: 0.5)

        // 4. Ẩn sidebar từ menu: màn hình Mac rộng ra, phím ⌘ biến mất.
        app.buttons["Tùy chọn"].tap()
        app.buttons["Ẩn sidebar"].tap()
        XCTAssertTrue(command.waitForNonExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1)
        XCTAssertGreaterThan(screen.frame.width, widthWithSidebar + 20, "ẩn sidebar thì màn hình Mac phải rộng ra")
        Thread.sleep(forTimeInterval: 1)
    }
}
