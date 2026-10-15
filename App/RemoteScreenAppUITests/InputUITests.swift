import XCTest

/// Kiểm thử nhập liệu đầu-cuối: app trong simulator nối tới server RFB giả (Tools/mock-rfb-server), bài test chạm, kéo và gõ,
/// rồi một script Python đối chiếu các sự kiện server nhận được. Bài test này KHÔNG tự khẳng định nội dung sự kiện vì nó
/// không thấy được phía server; nó chỉ bảo đảm các thao tác chạy được. Phần khẳng định nằm ở `verify_input.py`.
///
/// Chạy qua: Tools/mock-rfb-server/run_input_test.sh
final class InputUITests: XCTestCase {
    /// Cỡ màn hình của server giả.
    private let remote = CGSize(width: 800, height: 600)

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testTouchGesturesAndTypingReachTheServer() throws {
        let app = XCUIApplication()
        app.launchEnvironment = ["RFB_HOST": "127.0.0.1", "RFB_PORT": "5959"]
        app.launch()

        // Loại phần tử của một view có `allowsDirectInteraction` không cố định, nên tìm theo định danh ở mọi loại.
        let screen = app.descendants(matching: .any).matching(identifier: "remoteScreen").firstMatch
        XCTAssertTrue(screen.waitForExistence(timeout: 30), "không thấy view màn hình từ xa. Cây phần tử:\n\(app.debugDescription)")
        Thread.sleep(forTimeInterval: 4) // chờ kết nối, khung hình đầu và bố cục ổn định

        // Điểm trên "màn hình Mac" giả (pixel Mac) → toạ độ chuẩn hóa trong view, theo đúng phép đặt vừa khít ở giữa.
        let frame = screen.frame
        let scale = min(frame.width / remote.width, frame.height / remote.height)
        let origin = CGPoint(x: (frame.width - remote.width * scale) / 2, y: (frame.height - remote.height * scale) / 2)
        func point(_ x: Double, _ y: Double) -> XCUICoordinate {
            screen.coordinate(withNormalizedOffset: CGVector(
                dx: (origin.x + x * scale) / frame.width, dy: (origin.y + y * scale) / frame.height
            ))
        }

        // 1. Chạm một ngón → nhấp trái tại điểm chạm.
        point(100, 450).tap()
        Thread.sleep(forTimeInterval: 0.6)
        point(700, 520).tap()
        Thread.sleep(forTimeInterval: 0.6)

        // 2. Chạm hai ngón ở giữa → nhấp phải.
        screen.twoFingerTap()
        Thread.sleep(forTimeInterval: 0.6)

        // 3. Nhấn giữ rồi kéo → kéo-thả bằng nút trái.
        point(200, 350).press(forDuration: 0.8, thenDragTo: point(600, 500))
        Thread.sleep(forTimeInterval: 0.6)

        // 4. Chạm đúp → hai lần nhấp.
        point(300, 250).doubleTap()
        Thread.sleep(forTimeInterval: 0.6)

        // 5. Bàn phím: bật bàn phím ảo rồi gõ "Ab" và Return.
        app.buttons["Bàn phím"].tap()
        Thread.sleep(forTimeInterval: 1)
        app.typeText("Ab\n")
        Thread.sleep(forTimeInterval: 1)
    }
}
