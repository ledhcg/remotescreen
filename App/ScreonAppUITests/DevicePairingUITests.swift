import XCTest

/// App Mode pairing through the real UI, run on a physical iPad against a Screon Helper on a real Mac (only when the maintainer
/// asks; never in CI). Skipped unless the environment names what to test:
///
/// - `SCREON_DEVICE_COMPUTER`: the saved computer's name in the list (its row identifier is `computer.<name>`).
/// - `SCREON_DEVICE_PAIR_LINK`: the link from the helper's "Copy Link" button, for "Paste link".
/// - `SCREON_DEVICE_PAIR_HOST` and `SCREON_DEVICE_PAIR_PORT`: the address the helper shows, for "Pair with code". The person at
///   the Mac compares the digits and approves there; the test answers "The codes match" on the iPad.
///
/// Pass them with `TEST_RUNNER_` prefixes to `xcodebuild test`.
final class DevicePairingUITests: XCTestCase {
    private var app: XCUIApplication!
    private var computer = ""

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard let name = ProcessInfo.processInfo.environment["SCREON_DEVICE_COMPUTER"], !name.isEmpty else {
            throw XCTSkip("SCREON_DEVICE_COMPUTER not set: device pairing tests run only on request")
        }
        computer = name
        app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func attachScreenshot(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Opens "Set up App Mode" (or "Pair App Mode again…") from the computer's context menu and picks a method.
    private func openPairing(method: String) {
        app.launch()
        let row = element("computer.\(computer)")
        XCTAssertTrue(row.waitForExistence(timeout: 20), "no row for \(computer). Tree:\n\(app.debugDescription)")
        row.press(forDuration: 1.2)
        let again = app.buttons["Pair App Mode again…"].firstMatch
        let setUp = app.buttons["Set up App Mode…"].firstMatch
        if again.waitForExistence(timeout: 5) { again.tap() } else {
            XCTAssertTrue(setUp.waitForExistence(timeout: 5), "no App Mode pairing item in the menu")
            setUp.tap()
        }
        let picker = element("pairing-method")
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "pairing sheet did not open")
        picker.buttons[method].firstMatch.tap()
    }

    /// The sheet closes when pairing succeeded; an error row means it failed.
    private func expectPaired(timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element("pairing-error").exists {
                attachScreenshot("pairing failed")
                XCTFail("pairing failed: \(element("pairing-error").label)")
                return
            }
            if !element("pairing-method").exists && !element("pairing-working").exists && !element("pairing-code").exists {
                attachScreenshot("paired")
                return
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        attachScreenshot("pairing timed out")
        XCTFail("pairing did not finish in \(Int(timeout)) s")
    }

    func testPairWithPastedLink() throws {
        guard let link = ProcessInfo.processInfo.environment["SCREON_DEVICE_PAIR_LINK"], !link.isEmpty else {
            throw XCTSkip("SCREON_DEVICE_PAIR_LINK not set")
        }
        openPairing(method: "Paste link")
        let field = element("pairing-link")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(link)
        attachScreenshot("link entered")
        app.buttons["Pair"].firstMatch.tap()
        expectPaired(timeout: 90)
    }

    func testPairWithCode() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["SCREON_DEVICE_PAIR_HOST"], let port = environment["SCREON_DEVICE_PAIR_PORT"] else {
            throw XCTSkip("SCREON_DEVICE_PAIR_HOST / SCREON_DEVICE_PAIR_PORT not set")
        }
        openPairing(method: "Pair with code")
        let hostField = element("pairing-host")
        XCTAssertTrue(hostField.waitForExistence(timeout: 5))
        hostField.tap()
        hostField.typeText(host)
        let portField = element("pairing-port")
        portField.tap()
        portField.typeText(port)
        app.buttons["Show code"].firstMatch.tap()
        let code = element("pairing-code")
        XCTAssertTrue(code.waitForExistence(timeout: 60), "no six-digit code. Tree:\n\(app.debugDescription)")
        attachScreenshot("code \(code.label)")
        print("SCREON_DEVICE_SAS_CODE=\(code.label)")
        element("pairing-match").tap()
        // The person at the Mac compares the digits and approves with Touch ID or the password.
        expectPaired(timeout: 150)
    }
}
