import XCTest

/// The computer-picker and login flow, no server needed: uses a closed port (127.0.0.1:1) to get an immediate "refused" error.
final class ConnectionUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.textFields["address-field"].waitForExistence(timeout: 15), "address field not found:\n\(app.debugDescription)")
        return app
    }

    /// Tap the field before typing: focus arrives a beat after the dialog appears, and typing earlier would find no field to receive it.
    private func typeIntoPassword(_ app: XCUIApplication, _ text: String) {
        app.secureTextFields["login-password"].tap()
        app.typeText(text)
    }

    private func openLogin(_ app: XCUIApplication, address: String) {
        let field = app.textFields["address-field"]
        field.tap()
        field.typeText(address + "\n")
        XCTAssertTrue(app.secureTextFields["login-password"].waitForExistence(timeout: 10), "login dialog did not appear")
    }

    func testEmptyAddressExplainsInsteadOfDoingNothing() {
        let app = launch()
        app.textFields["address-field"].tap()
        app.typeText("\n")
        XCTAssertTrue(app.staticTexts["Enter a computer name or address."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.secureTextFields["login-password"].exists, "an empty address must not open the dialog")
    }

    func testBadPortIsReportedBeforeAnyNetworkAttempt() {
        let app = launch()
        app.textFields["address-field"].tap()
        app.typeText("mac.local:99999\n")
        XCTAssertTrue(app.staticTexts["The port must be a number from 1 to 65535."].waitForExistence(timeout: 5))
    }

    func testAddressOpensLoginAndConnectIsDisabledUntilPasswordIsTyped() {
        let app = launch()
        openLogin(app, address: "127.0.0.1:1")
        UIShots.save(app, "login-empty")
        let connect = app.buttons["login-connect"]
        XCTAssertTrue(connect.exists)
        XCTAssertFalse(connect.isEnabled, "Connect must be disabled until a password is typed")
        typeIntoPassword(app, "x")
        XCTAssertTrue(connect.isEnabled)
    }

    func testUsernameTypedInTheAddressIsPrefilled() {
        let app = launch()
        openLogin(app, address: "alice@127.0.0.1:1")
        XCTAssertEqual(app.textFields["login-username"].value as? String, "alice")
    }

    /// The error must appear RIGHT INSIDE the dialog (where the user is looking), and the fields stay as they are for correcting and retrying.
    func testRefusedConnectionShowsTheErrorInsideTheSheet() {
        let app = launch()
        openLogin(app, address: "alice@127.0.0.1:1")
        typeIntoPassword(app, "password123")
        app.buttons["login-connect"].tap()

        let message = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'refused the connection'")).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 20), "error did not appear in the dialog:\n\(app.debugDescription)")
        UIShots.save(app, "login-refused")
        XCTAssertTrue(app.secureTextFields["login-password"].exists, "the dialog must stay open for corrections")
        XCTAssertEqual(app.textFields["login-username"].value as? String, "alice")
        // An empty password field has the placeholder text "Password" as its `value`; typed content shows as dots.
        XCTAssertNotEqual(app.secureTextFields["login-password"].value as? String, "Password", "the typed password was lost after the error")
        XCTAssertTrue(app.buttons["login-connect"].isEnabled, "must be able to retry")
    }

    func testCancelClosesTheSheetAndLeavesNoStaleError() {
        let app = launch()
        openLogin(app, address: "127.0.0.1:1")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.textFields["address-field"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.secureTextFields["login-password"].exists)
        XCTAssertFalse(app.alerts.firstMatch.exists, "cancelling must not leave an error alert")
    }
}
