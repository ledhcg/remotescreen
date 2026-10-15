import XCTest

/// Luồng chọn máy và đăng nhập, không cần server: dùng cổng đóng (127.0.0.1:1) để có lỗi "từ chối" ngay lập tức.
final class ConnectionUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.textFields["address-field"].waitForExistence(timeout: 15), "không thấy ô địa chỉ:\n\(app.debugDescription)")
        return app
    }

    /// Chạm vào ô trước khi gõ: tiêu điểm tự động đến sau khi hộp thoại hiện một nhịp, gõ sớm hơn sẽ không có ô nào nhận.
    private func typeIntoPassword(_ app: XCUIApplication, _ text: String) {
        app.secureTextFields["login-password"].tap()
        app.typeText(text)
    }

    private func openLogin(_ app: XCUIApplication, address: String) {
        let field = app.textFields["address-field"]
        field.tap()
        field.typeText(address + "\n")
        XCTAssertTrue(app.secureTextFields["login-password"].waitForExistence(timeout: 10), "hộp thoại đăng nhập không hiện")
    }

    func testEmptyAddressExplainsInsteadOfDoingNothing() {
        let app = launch()
        app.textFields["address-field"].tap()
        app.typeText("\n")
        XCTAssertTrue(app.staticTexts["Nhập tên máy hoặc địa chỉ."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.secureTextFields["login-password"].exists, "địa chỉ rỗng không được mở hộp thoại")
    }

    func testBadPortIsReportedBeforeAnyNetworkAttempt() {
        let app = launch()
        app.textFields["address-field"].tap()
        app.typeText("mac.local:99999\n")
        XCTAssertTrue(app.staticTexts["Cổng phải là số từ 1 đến 65535."].waitForExistence(timeout: 5))
    }

    func testAddressOpensLoginAndConnectIsDisabledUntilPasswordIsTyped() {
        let app = launch()
        openLogin(app, address: "127.0.0.1:1")
        UIShots.save(app, "login-empty")
        let connect = app.buttons["login-connect"]
        XCTAssertTrue(connect.exists)
        XCTAssertFalse(connect.isEnabled, "chưa có mật khẩu thì không được bấm Kết nối")
        typeIntoPassword(app, "x")
        XCTAssertTrue(connect.isEnabled)
    }

    func testUsernameTypedInTheAddressIsPrefilled() {
        let app = launch()
        openLogin(app, address: "cuong@127.0.0.1:1")
        XCTAssertEqual(app.textFields["login-username"].value as? String, "cuong")
    }

    /// Lỗi phải hiện NGAY TRONG hộp thoại (nơi người dùng đang nhìn), và các ô giữ nguyên để sửa rồi thử lại.
    func testRefusedConnectionShowsTheErrorInsideTheSheet() {
        let app = launch()
        openLogin(app, address: "cuong@127.0.0.1:1")
        typeIntoPassword(app, "matkhau")
        app.buttons["login-connect"].tap()

        let message = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Mac từ chối kết nối'")).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 20), "lỗi không hiện trong hộp thoại:\n\(app.debugDescription)")
        UIShots.save(app, "login-refused")
        XCTAssertTrue(app.secureTextFields["login-password"].exists, "hộp thoại phải còn mở để sửa")
        XCTAssertEqual(app.textFields["login-username"].value as? String, "cuong")
        // Ô mật khẩu rỗng thì `value` là chữ gợi ý "Mật khẩu"; còn nội dung thì là các dấu chấm.
        XCTAssertNotEqual(app.secureTextFields["login-password"].value as? String, "Mật khẩu", "mật khẩu đã gõ bị mất sau lỗi")
        XCTAssertTrue(app.buttons["login-connect"].isEnabled, "phải thử lại được")
    }

    func testCancelClosesTheSheetAndLeavesNoStaleError() {
        let app = launch()
        openLogin(app, address: "127.0.0.1:1")
        app.buttons["Hủy"].tap()
        XCTAssertTrue(app.textFields["address-field"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.secureTextFields["login-password"].exists)
        XCTAssertFalse(app.alerts.firstMatch.exists, "hủy không được để lại hộp thoại lỗi")
    }
}
