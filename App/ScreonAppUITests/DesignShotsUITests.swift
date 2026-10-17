import XCTest

/// The main screens, photographed for a look at the design system (`SHOT_DIR`, see `UIShots`), with a few checks that they are all
/// there. Needs the mock server on 127.0.0.1:5959 (Tools/mock-rfb-server/run_ui_test.sh).
final class DesignShotsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func testTheComputerListWithEveryKindOfRow() {
        let seed = """
        [{"name": "Mac mini", "host": "127.0.0.1", "port": 5959, "paired": true},
         {"name": "Studio", "host": "10.0.0.7", "port": 1},
         {"name": "Remote Mac", "host": "100.101.102.103", "port": 5900, "paired": true}]
        """
        let app = XCUIApplication()
        app.launchEnvironment = ["SCREON_STORE_NAME": "shots-\(UUID().uuidString).json", "SCREON_SEED": seed]
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(element(app, "computer.Mac mini").waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 4) // the probe of the saved addresses
        UIShots.save(app, "list")
        XCTAssertTrue(element(app, "screen.Remote Mac").exists)

        app.buttons["network-settings"].tap()
        XCTAssertTrue(element(app, "network-status").waitForExistence(timeout: 5), "the network settings did not open")
        UIShots.save(app, "network-settings")
        app.swipeUp() // the token field is below the fold of a lazy list
        XCTAssertTrue(element(app, "tailscale-token").waitForExistence(timeout: 5), "no field for the Tailscale token")
        UIShots.save(app, "network-settings-bottom")
    }

    func testTheSessionChromeWithKeysBarAndMenu() {
        let app = XCUIApplication()
        app.launchEnvironment = [
            "RFB_HOST": "127.0.0.1", "RFB_PORT": "5959", "RFB_SIDEBAR": "hidden",
            "RFB_DEFAULTS_SUITE": "design-shots-\(UUID().uuidString)",
        ]
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.buttons["Options"].waitForExistence(timeout: 30))
        Thread.sleep(forTimeInterval: 3)
        app.buttons["Extra keys"].tap()
        XCTAssertTrue(app.buttons["Escape"].waitForExistence(timeout: 5), "the extra-keys bar did not open")
        UIShots.save(app, "session-keys")
        app.buttons["Options"].tap()
        Thread.sleep(forTimeInterval: 1)
        UIShots.save(app, "session-options")
        app.swipeUp() // the sheet is taller than its first stop: the rest of it, down to the Disconnect button
        Thread.sleep(forTimeInterval: 1)
        UIShots.save(app, "session-options-end")
    }

    func testTheSessionWithTheSidebar() {
        let app = XCUIApplication()
        app.launchEnvironment = [
            "RFB_HOST": "127.0.0.1", "RFB_PORT": "5959", "RFB_SIDEBAR": "leading",
            "RFB_DEFAULTS_SUITE": "design-shots-\(UUID().uuidString)",
        ]
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.buttons["Command"].waitForExistence(timeout: 30))
        Thread.sleep(forTimeInterval: 3)
        UIShots.save(app, "session-sidebar")
    }
}
