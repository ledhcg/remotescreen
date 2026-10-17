import XCTest

/// The computer list: deleting asks first, each row has quick actions (Screen Sharing, App Mode), and Tailscale computers say so.
/// Each test starts from its own private list (`SCREON_STORE_NAME` / `SCREON_SEED`, see `DebugComputers`). The mock server is
/// on 127.0.0.1:5959 (Tools/mock-rfb-server/run_ui_test.sh).
final class ComputerListUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// `network` fixes what the app sees (`DEBUG` only): the simulator shares the Mac's network, and with it the Mac's own Tailscale.
    private func launch(seed: String, network: String = "wifi") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = ["SCREON_STORE_NAME": "ui-\(UUID().uuidString).json", "SCREON_SEED": seed, "SCREON_NETWORK": network]
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.textFields["address-field"].waitForExistence(timeout: 15), "list not shown:\n\(app.debugDescription)")
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Polls until `condition` holds (the list updates a beat after what causes it).
    private func wait(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return condition()
    }

    func testDeletingAsksFirstAndCancelKeepsTheComputer() {
        let app = launch(seed: #"[{"name": "Studio", "host": "127.0.0.1", "port": 1}]"#)
        let row = element(app, "computer.Studio")
        XCTAssertTrue(row.waitForExistence(timeout: 10))

        row.swipeLeft(velocity: .fast) // a full, fast swipe must not delete: it reveals the button
        app.buttons["Delete"].firstMatch.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "no confirmation:\n\(app.debugDescription)")
        XCTAssertTrue(alert.staticTexts["Delete “Studio”?"].exists)
        UIShots.save(app, "delete-confirmation")
        alert.buttons["Cancel"].tap()
        XCTAssertFalse(app.alerts.firstMatch.exists)
        XCTAssertTrue(element(app, "computer.Studio").exists, "Cancel must keep the computer")

        row.press(forDuration: 1.2) // the context menu has the same confirmation
        app.buttons["Delete"].firstMatch.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        app.alerts.firstMatch.buttons["Delete"].tap()
        XCTAssertTrue(wait(timeout: 10) { !element(app, "computer.Studio").exists }, "the computer was not deleted")
    }

    func testAPairedComputerSaysWhatDeletingLeavesOnTheMac() {
        let app = launch(seed: #"[{"name": "Studio", "host": "127.0.0.1", "port": 1, "paired": true}]"#)
        let row = element(app, "computer.Studio")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.press(forDuration: 1.2)
        app.buttons["Delete"].firstMatch.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS 'still lists this device as paired'")).firstMatch.exists)
        alert.buttons["Cancel"].tap()
    }

    func testEveryRowHasQuickActionsAndAnUnpairedOneLeadsToTheSetup() throws {
        let app = launch(seed: #"[{"name": "Studio", "host": "127.0.0.1", "port": 1}]"#)
        XCTAssertTrue(element(app, "computer.Studio").waitForExistence(timeout: 10))
        let screen = element(app, "screen.Studio")
        XCTAssertTrue(screen.exists, "Screen Sharing quick action")
        let appMode = element(app, "app-mode.Studio")
        guard appMode.exists else { throw XCTSkip("App Mode needs iOS 26") }
        XCTAssertEqual(appMode.label, "Set up App Mode for Studio", "a computer without App Mode leads to the setup")
        UIShots.save(app, "computer-list-quick-actions")
        appMode.tap()
        XCTAssertTrue(element(app, "pairing-method").waitForExistence(timeout: 10), "the setup sheet did not open:\n\(app.debugDescription)")
    }

    func testTheScreenQuickActionOpensTheLoginLikeTheRow() {
        let app = launch(seed: #"[{"name": "Studio", "host": "127.0.0.1", "port": 1}]"#)
        let screen = element(app, "screen.Studio")
        XCTAssertTrue(screen.waitForExistence(timeout: 10))
        screen.tap()
        XCTAssertTrue(app.secureTextFields["login-password"].waitForExistence(timeout: 10), "no password was saved, so the login opens")
    }

    func testAPairedComputerOffersItsAppModeWindows() throws {
        let app = launch(seed: #"[{"name": "Studio", "host": "127.0.0.1", "port": 1, "paired": true}]"#)
        let appMode = element(app, "app-mode.Studio")
        guard appMode.waitForExistence(timeout: 10) else { throw XCTSkip("App Mode needs iOS 26") }
        XCTAssertEqual(appMode.label, "Open App Mode windows of Studio")
    }

    func testTailscaleComputersAreMarkedAndSayWhenTailscaleIsOff() {
        let app = launch(seed: #"[{"name": "Remote", "host": "100.101.102.103", "port": 5959}, {"name": "Home", "host": "127.0.0.1", "port": 5959}]"#)
        let remote = element(app, "computer.Remote")
        XCTAssertTrue(remote.waitForExistence(timeout: 10))
        XCTAssertTrue(remote.label.contains("Tailscale"), "label: \(remote.label)")
        XCTAssertTrue(remote.label.contains("Tailscale is not connected"), "a Tailscale computer says why it is not available: \(remote.label)")
        XCTAssertTrue(element(app, "computer.Home").label.contains("Local network"))
        UIShots.save(app, "computer-list-tailscale")
    }

    func testWithTailscaleConnectedItSaysTailscaleAndNotThatItIsOff() {
        let app = launch(seed: #"[{"name": "Remote", "host": "100.101.102.103", "port": 5959}]"#, network: "tailscale")
        let remote = element(app, "computer.Remote")
        XCTAssertTrue(remote.waitForExistence(timeout: 10))
        XCTAssertTrue(remote.label.contains("Tailscale"), "label: \(remote.label)")
        XCTAssertFalse(remote.label.contains("not connected"), "Tailscale is connected: \(remote.label)")
    }

    func testOfflineMarksNothingAvailable() {
        let app = launch(seed: #"[{"name": "Home", "host": "127.0.0.1", "port": 5959}]"#, network: "offline")
        let home = element(app, "computer.Home")
        XCTAssertTrue(home.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 4) // longer than a probe: without a network none is made
        XCTAssertTrue(home.label.contains("not seen"), "label: \(home.label)")
    }

    func testAComputerThatAnswersIsMarkedAvailable() {
        let app = launch(seed: #"[{"name": "Home", "host": "127.0.0.1", "port": 5959}]"#)
        let home = element(app, "computer.Home")
        XCTAssertTrue(home.waitForExistence(timeout: 10))
        // The probe runs when the list appears.
        XCTAssertTrue(wait(timeout: 20) { home.label.contains("available") }, "label: \(home.label)")
    }
}
