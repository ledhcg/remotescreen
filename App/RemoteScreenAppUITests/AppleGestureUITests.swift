import XCTest

/// Chụm và xoay gửi lên Mac (message 23 của Apple), đầu-cuối với server giả chạy `--apple` (tự xưng `RFB 003.889`).
/// Bài này chỉ thao tác; `verify_gestures.py` đọc log để khẳng định server nhận đúng message và kết nối vẫn sống sau đó.
final class AppleGestureUITests: XCTestCase {
    private let remote = CGSize(width: 800, height: 600)

    func testPinchAndRotateAreSentToTheMac() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment = [
            "RFB_HOST": "127.0.0.1", "RFB_PORT": "5959", "RFB_PINCH_TO_MAC": "1", "RFB_SMOOTH_SCROLL": "1",
            "RFB_SIDEBAR": "hidden", "RFB_DEFAULTS_SUITE": "apple-gesture-ui-test",
        ]
        app.launch()
        let screen = app.descendants(matching: .any).matching(identifier: "remoteScreen").firstMatch
        XCTAssertTrue(screen.waitForExistence(timeout: 30), "không vào được phiên:\n\(app.debugDescription)")
        Thread.sleep(forTimeInterval: 3)

        screen.pinch(withScale: 2, velocity: 1)
        Thread.sleep(forTimeInterval: 1)
        screen.rotate(.pi / 4, withVelocity: 1)
        Thread.sleep(forTimeInterval: 1)

        // Khung nhìn iPad không được phóng (chụm đã đi lên Mac): giá trị trợ năng vẫn báo cả màn hình Mac vừa khung.
        let frame = screen.frame
        let scale = min(frame.width / remote.width, frame.height / remote.height)
        let value = screen.value as? String ?? ""
        let shown = value.components(separatedBy: "hiển thị ").last?.components(separatedBy: "×").first.flatMap(Double.init) ?? 0
        XCTAssertEqual(shown, remote.width * scale, accuracy: 2, "chụm không được phóng khung nhìn: \(value)")

        // Kết nối vẫn sống sau message 23: một cú chạm phải tới server.
        let origin = CGPoint(x: (frame.width - remote.width * scale) / 2, y: (frame.height - remote.height * scale) / 2)
        screen.coordinate(withNormalizedOffset: CGVector(
            dx: (origin.x + 250 * scale) / frame.width, dy: (origin.y + 300 * scale) / frame.height
        )).tap()
        Thread.sleep(forTimeInterval: 1.5)
    }
}
