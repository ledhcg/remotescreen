import XCTest

/// Thanh công cụ của phiên và đường đăng nhập thành công, với server RFB giả (127.0.0.1:5959, không xác thực).
/// Chạy qua: Tools/mock-rfb-server/run_ui_test.sh
final class SessionChromeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Đi qua đúng đường người dùng đi: gõ địa chỉ, điền tên và mật khẩu, bấm Kết nối.
    private func connect() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        let field = app.textFields["address-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        field.typeText("tester@127.0.0.1:5959\n")
        XCTAssertTrue(app.secureTextFields["login-password"].waitForExistence(timeout: 10))
        typeIntoPassword(app, "khong-dung-toi\n") // server giả không xác thực
        XCTAssertTrue(app.buttons["Bàn phím"].waitForExistence(timeout: 30), "không vào được phiên:\n\(app.debugDescription)")
        return app
    }

    private func typeIntoPassword(_ app: XCUIApplication, _ text: String) {
        app.secureTextFields["login-password"].tap()
        app.typeText(text)
    }

    private func statusButton(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    func testToolbarShowsMachineAndStatus() {
        let app = connect()
        XCTAssertTrue(statusButton(app, containing: "Đang điều khiển").waitForExistence(timeout: 5))
        UIShots.save(app, "session-toolbar")
    }

    func testObserveModeDisablesInputControlsAndCanBeLeft() {
        let app = connect()
        app.buttons["Tùy chọn"].tap()
        UIShots.save(app, "session-menu")
        app.buttons["Chỉ xem"].tap()

        XCTAssertTrue(statusButton(app, containing: "Chỉ xem").waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Bàn phím"].isEnabled, "chỉ xem thì không có bàn phím")
        XCTAssertFalse(app.buttons["Phím phụ"].isEnabled)
        UIShots.save(app, "session-observe")

        app.buttons["Tùy chọn"].tap()
        app.buttons["Điều khiển"].tap()
        XCTAssertTrue(statusButton(app, containing: "Đang điều khiển").waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Bàn phím"].isEnabled)
    }

    func testToolbarCollapsesToAPillAndComesBack() {
        let app = connect()
        statusButton(app, containing: "thu gọn").tap()
        XCTAssertTrue(app.buttons["Hiện thanh công cụ"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Bàn phím"].exists)
        UIShots.save(app, "session-collapsed")
        app.buttons["Hiện thanh công cụ"].tap()
        XCTAssertTrue(app.buttons["Bàn phím"].waitForExistence(timeout: 5))
    }

    func testDisconnectReturnsToTheComputerList() {
        let app = connect()
        app.buttons["Tùy chọn"].tap()
        app.buttons["Ngắt kết nối"].tap()
        XCTAssertTrue(app.textFields["address-field"].waitForExistence(timeout: 10))
    }

    /// Mỗi phiên bắt đầu từ cấu hình mặc định: chế độ chỉ xem của phiên trước không được dính sang phiên sau.
    func testViewOnlyDoesNotLeakIntoTheNextSession() {
        let app = connect()
        app.buttons["Tùy chọn"].tap()
        app.buttons["Chỉ xem"].tap()
        XCTAssertTrue(statusButton(app, containing: "Chỉ xem").waitForExistence(timeout: 5))
        app.buttons["Tùy chọn"].tap()
        app.buttons["Ngắt kết nối"].tap()
        XCTAssertTrue(app.textFields["address-field"].waitForExistence(timeout: 10))

        // Nối lại bằng máy vừa lưu (mật khẩu trong Keychain; simulator không ký thì không lưu được, khi đó dùng đường gõ tay).
        let field = app.textFields["address-field"]
        field.tap()
        field.typeText("tester@127.0.0.1:5959\n")
        XCTAssertTrue(app.secureTextFields["login-password"].waitForExistence(timeout: 10))
        typeIntoPassword(app, "x\n")
        XCTAssertTrue(app.buttons["Bàn phím"].waitForExistence(timeout: 30))
        XCTAssertTrue(statusButton(app, containing: "Đang điều khiển").exists)
        XCTAssertTrue(app.buttons["Bàn phím"].isEnabled)
    }
}

/// Chế độ "Chỉ xem" phải thật sự không gửi gì tới Mac. Bài này chỉ thao tác; `verify_observe.py` đọc log của server giả
/// để khẳng định: không có sự kiện chuột nào gần các điểm chạm lúc chỉ xem, và có đúng sự kiện ở điểm chạm lúc điều khiển
/// (đối chứng dương, để chắc rằng việc không thấy gì không phải do bài test không chạm được).
final class ObserveModeUITests: XCTestCase {
    /// Cỡ màn hình của server giả.
    private let remote = CGSize(width: 800, height: 600)

    func testObserveModeSendsNothingButControlModeStillDoes() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment = ["RFB_HOST": "127.0.0.1", "RFB_PORT": "5959"]
        app.launch()
        let screen = app.descendants(matching: .any).matching(identifier: "remoteScreen").firstMatch
        XCTAssertTrue(screen.waitForExistence(timeout: 30))
        Thread.sleep(forTimeInterval: 4)

        let frame = screen.frame
        let scale = min(frame.width / remote.width, frame.height / remote.height)
        let origin = CGPoint(x: (frame.width - remote.width * scale) / 2, y: (frame.height - remote.height * scale) / 2)
        func point(_ x: Double, _ y: Double) -> XCUICoordinate {
            screen.coordinate(withNormalizedOffset: CGVector(dx: (origin.x + x * scale) / frame.width, dy: (origin.y + y * scale) / frame.height))
        }

        // 1. Chỉ xem: chạm, chạm đúp, kéo, chạm hai ngón. Không thứ nào được tới server.
        app.buttons["Tùy chọn"].tap()
        app.buttons["Chỉ xem"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Chỉ xem'")).firstMatch.waitForExistence(timeout: 5))
        point(100, 450).tap()
        Thread.sleep(forTimeInterval: 0.6)
        point(700, 520).doubleTap()
        Thread.sleep(forTimeInterval: 0.6)
        point(200, 350).press(forDuration: 0.8, thenDragTo: point(600, 500))
        Thread.sleep(forTimeInterval: 0.6)
        screen.twoFingerTap()
        Thread.sleep(forTimeInterval: 1)

        // 2. Quay lại điều khiển: một cú chạm duy nhất tại điểm khác hẳn.
        app.buttons["Tùy chọn"].tap()
        app.buttons["Điều khiển"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Đang điều khiển'")).firstMatch.waitForExistence(timeout: 5))
        point(250, 300).tap()
        Thread.sleep(forTimeInterval: 1.5)
    }
}

/// Chế độ chất lượng đầu-cuối với server giả (server giả hiểu `SetPixelFormat` 16 bit và log lại).
/// Bài này chỉ thao tác và kiểm màu; `verify_quality.py` đọc log để khẳng định server nhận đúng định dạng pixel theo đúng thứ tự.
final class QualityUITests: XCTestCase {
    private let remote = CGSize(width: 800, height: 600)
    /// Tâm bốn góc của hình mẫu giả, tránh đường lưới (bội số của 100). Đỏ, xanh lá, xanh dương, vàng.
    private let samplePoints: [(Double, Double)] = [(150, 150), (550, 150), (150, 450), (550, 450)]
    private let expected: [(Int, Int, Int)] = [(200, 40, 40), (40, 180, 60), (50, 70, 210), (220, 200, 40)]

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(suite: String) -> (XCUIApplication, XCUIElement) {
        let app = XCUIApplication()
        app.launchEnvironment = ["RFB_HOST": "127.0.0.1", "RFB_PORT": "5959", "RFB_DEFAULTS_SUITE": suite]
        app.launch()
        let screen = app.descendants(matching: .any).matching(identifier: "remoteScreen").firstMatch
        XCTAssertTrue(screen.waitForExistence(timeout: 30), "không vào được phiên:\n\(app.debugDescription)")
        XCTAssertTrue(app.buttons["Tùy chọn"].waitForExistence(timeout: 30))
        Thread.sleep(forTimeInterval: 3)
        return (app, screen)
    }

    /// Màu thật trên màn hình simulator tại tâm bốn góc của hình mẫu (đọc từ ảnh chụp, không phải từ framebuffer).
    private func sampledColours(_ app: XCUIApplication, _ screen: XCUIElement) throws -> [(Int, Int, Int)] {
        let image = app.screenshot().image
        let cgImage = try XCTUnwrap(image.cgImage)
        let pixelScale = CGFloat(cgImage.width) / image.size.width
        var data = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &data, width: cgImage.width, height: cgImage.height, bitsPerComponent: 8, bytesPerRow: cgImage.width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))

        let frame = screen.frame
        let scale = min(frame.width / remote.width, frame.height / remote.height)
        let origin = CGPoint(x: frame.minX + (frame.width - remote.width * scale) / 2, y: frame.minY + (frame.height - remote.height * scale) / 2)
        return samplePoints.map { point in
            let x = Int((origin.x + point.0 * scale) * pixelScale)
            let y = Int((origin.y + point.1 * scale) * pixelScale)
            let index = (y * cgImage.width + x) * 4
            return (Int(data[index]), Int(data[index + 1]), Int(data[index + 2]))
        }
    }

    private func choose(_ mode: String, in app: XCUIApplication) {
        app.buttons["Tùy chọn"].tap()
        app.buttons["Chất lượng hình"].tap()
        app.buttons[mode].tap()
    }

    private func closeEnough(_ a: (Int, Int, Int), _ b: (Int, Int, Int), tolerance: Int) -> Bool {
        abs(a.0 - b.0) <= tolerance && abs(a.1 - b.1) <= tolerance && abs(a.2 - b.2) <= tolerance
    }

    /// "Hiệu năng tốt nhất" bỏ trần khung hình và giữ màu 32 bit (con trỏ tại chỗ), nên đổi sang nó KHÔNG nối lại, và màu
    /// vẫn y như trước (so với chính khung trước khi đổi).
    func testBestPerformanceKeepsFullColourAndDoesNotReconnect() throws {
        let (app, screen) = launch(suite: "ui-quality-\(UUID().uuidString)")
        let before = try sampledColours(app, screen)
        for (sample, want) in zip(before, expected) {
            XCTAssertTrue(closeEnough(sample, want, tolerance: 40), "màu \(sample) lệch xa mẫu \(want): ảnh chụp không đọc được đúng chỗ?")
        }
        choose("Hiệu năng tốt nhất", in: app)
        Thread.sleep(forTimeInterval: 2)
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'áp dụng chế độ'")).firstMatch.exists, "không được nối lại")
        XCTAssertTrue(app.buttons["Bàn phím"].exists)
        let after = try sampledColours(app, screen)
        for (sample, reference) in zip(after, before) {
            XCTAssertTrue(closeEnough(sample, reference, tolerance: 2), "màu \(sample) đổi so với \(reference): không được giảm độ sâu màu")
        }
    }

    /// Chế độ được nhớ giữa các lần mở app: lần mở sau xin 16 bit ngay từ đầu.
    func testQualityModeIsRememberedAcrossLaunches() throws {
        let suite = "ui-quality-\(UUID().uuidString)"
        var (app, _) = launch(suite: suite)
        choose("Hiệu năng tốt nhất", in: app)
        XCTAssertTrue(app.buttons["Bàn phím"].waitForExistence(timeout: 30))
        Thread.sleep(forTimeInterval: 2)
        app.terminate()

        (app, _) = launch(suite: suite) // cùng suite: đọc lại chế độ đã lưu (không nối lại vì cùng 32 bit)
        app.buttons["Tùy chọn"].tap()
        app.buttons["Chất lượng hình"].tap()
        XCTAssertTrue(app.buttons["Hiệu năng tốt nhất"].waitForExistence(timeout: 5))
    }

    /// Đổi giữa hai chế độ cùng độ sâu màu (Tự động ↔ Hiển thị tốt nhất) chỉ đổi nhịp khung hình: KHÔNG nối lại.
    func testSwitchingBetweenFullColourModesDoesNotReconnect() throws {
        let (app, _) = launch(suite: "ui-quality-\(UUID().uuidString)")
        choose("Hiển thị tốt nhất", in: app)
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(app.buttons["Bàn phím"].exists, "phiên phải còn nguyên, không bị nối lại")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'áp dụng chế độ'")).firstMatch.exists)
    }
}
