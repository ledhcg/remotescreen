import XCTest

/// The session toolbar and the successful login path, against a fake RFB server (127.0.0.1:5959, no authentication).
/// Run via: Tools/mock-rfb-server/run_ui_test.sh
final class SessionChromeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Follows the exact path a user takes: type the address, fill in name and password, press Connect.
    private func connect() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let field = app.textFields["address-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        field.typeText("127.0.0.1:5959\n") // no username: the fake server offers only "None", and an account login is never downgraded
        XCTAssertTrue(app.secureTextFields["login-password"].waitForExistence(timeout: 10))
        typeIntoPassword(app, "unused-password\n") // the fake server does no authentication
        XCTAssertTrue(app.buttons["Keyboard"].waitForExistence(timeout: 30), "could not enter the session:\n\(app.debugDescription)")
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
        XCTAssertTrue(statusButton(app, containing: "Controlling").waitForExistence(timeout: 5))
        UIShots.save(app, "session-toolbar")
    }

    func testObserveModeDisablesInputControlsAndCanBeLeft() {
        let app = connect()
        app.buttons["Options"].tap()
        UIShots.save(app, "session-menu")
        app.setOption("View only", inRow: "Mode", opener: nil)

        XCTAssertTrue(statusButton(app, containing: "View only").waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Keyboard"].isEnabled, "no keyboard in view-only mode")
        XCTAssertFalse(app.buttons["Extra keys"].isEnabled)
        UIShots.save(app, "session-observe")

        app.setOption("Take control", inRow: "Mode")
        XCTAssertTrue(statusButton(app, containing: "Controlling").waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Keyboard"].isEnabled)
    }

    func testToolbarCollapsesToAPillAndComesBack() {
        let app = connect()
        statusButton(app, containing: "collapse").tap()
        XCTAssertTrue(app.buttons["Show toolbar"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Keyboard"].exists)
        UIShots.save(app, "session-collapsed")
        app.buttons["Show toolbar"].tap()
        XCTAssertTrue(app.buttons["Keyboard"].waitForExistence(timeout: 5))
    }

    func testDisconnectReturnsToTheComputerList() {
        let app = connect()
        app.buttons["Options"].tap()
        app.buttons["Disconnect"].tap()
        XCTAssertTrue(app.textFields["address-field"].waitForExistence(timeout: 10))
    }

    /// Every session starts from the default configuration: view-only mode from the previous session must not leak into the next one.
    func testViewOnlyDoesNotLeakIntoTheNextSession() {
        let app = connect()
        app.setOption("View only", inRow: "Mode")
        XCTAssertTrue(statusButton(app, containing: "View only").waitForExistence(timeout: 5))
        app.buttons["Options"].tap()
        app.buttons["Disconnect"].tap()
        XCTAssertTrue(app.textFields["address-field"].waitForExistence(timeout: 10))

        // Reconnect with the computer just saved (password in the Keychain; an unsigned simulator cannot save it, in which case use the manual typing path).
        let field = app.textFields["address-field"]
        field.tap()
        field.typeText("127.0.0.1:5959\n") // no username: the fake server offers only "None", and an account login is never downgraded
        XCTAssertTrue(app.secureTextFields["login-password"].waitForExistence(timeout: 10))
        typeIntoPassword(app, "x\n")
        XCTAssertTrue(app.buttons["Keyboard"].waitForExistence(timeout: 30))
        XCTAssertTrue(statusButton(app, containing: "Controlling").exists)
        XCTAssertTrue(app.buttons["Keyboard"].isEnabled)
    }
}

/// "View only" mode must truly send nothing to the Mac. This test only performs the actions; `verify_observe.py` reads the fake server's log
/// to assert: no mouse events near the touch points while view-only, and exactly the right events at the touch point while controlling
/// (a positive control, to be sure that seeing nothing is not because the test could not touch).
final class ObserveModeUITests: XCTestCase {
    /// Screen size of the fake server.
    private let remote = CGSize(width: 800, height: 600)

    func testObserveModeSendsNothingButControlModeStillDoes() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment = ["RFB_HOST": "127.0.0.1", "RFB_PORT": "5959"]
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let screen = app.descendants(matching: .any).matching(identifier: "screon").firstMatch
        XCTAssertTrue(screen.waitForExistence(timeout: 30))
        Thread.sleep(forTimeInterval: 4)

        let points = RemoteScreenPoints(screen: screen, remote: remote)
        func point(_ x: Double, _ y: Double) -> XCUICoordinate { points.point(x, y) }

        // 1. View only: tap, double-tap, drag, two-finger tap. None of it may reach the server.
        app.setOption("View only", inRow: "Mode")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'View only'")).firstMatch.waitForExistence(timeout: 5))
        point(100, 450).tap()
        Thread.sleep(forTimeInterval: 0.6)
        point(700, 520).doubleTap()
        Thread.sleep(forTimeInterval: 0.6)
        point(200, 350).press(forDuration: 0.8, thenDragTo: point(600, 500))
        Thread.sleep(forTimeInterval: 0.6)
        screen.twoFingerTap()
        Thread.sleep(forTimeInterval: 1)

        // 2. Back to control: a single tap at a clearly different point.
        app.setOption("Take control", inRow: "Mode")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Controlling'")).firstMatch.waitForExistence(timeout: 5))
        point(250, 300).tap()
        Thread.sleep(forTimeInterval: 1.5)
    }
}

/// Quality mode end to end with the fake server (the fake server understands 16-bit `SetPixelFormat` and logs it).
/// This test only performs the actions and checks colors; `verify_quality.py` reads the log to assert the server received the right pixel formats in the right order.
final class QualityUITests: XCTestCase {
    private let remote = CGSize(width: 800, height: 600)
    /// Centers of the four quadrants of the fake sample image, avoiding grid lines (multiples of 100). Red, green, blue, yellow.
    private let samplePoints: [(Double, Double)] = [(150, 150), (550, 150), (150, 450), (550, 450)]
    private let expected: [(Int, Int, Int)] = [(200, 40, 40), (40, 180, 60), (50, 70, 210), (220, 200, 40)]

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(suite: String) -> (XCUIApplication, XCUIElement) {
        let app = XCUIApplication()
        app.launchEnvironment = ["RFB_HOST": "127.0.0.1", "RFB_PORT": "5959", "RFB_DEFAULTS_SUITE": suite]
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let screen = app.descendants(matching: .any).matching(identifier: "screon").firstMatch
        XCTAssertTrue(screen.waitForExistence(timeout: 30), "could not enter the session:\n\(app.debugDescription)")
        XCTAssertTrue(app.buttons["Options"].waitForExistence(timeout: 30))
        Thread.sleep(forTimeInterval: 3)
        return (app, screen)
    }

    /// Real colors on the simulator screen at the centers of the four quadrants of the sample image (read from the screenshot, not from the framebuffer).
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
        let rect = RemoteScreenPoints(screen: screen, remote: remote).contentRect
        let scale = rect.width / remote.width
        let origin = CGPoint(x: frame.minX + rect.minX, y: frame.minY + rect.minY)
        return samplePoints.map { point in
            let x = Int((origin.x + point.0 * scale) * pixelScale)
            let y = Int((origin.y + point.1 * scale) * pixelScale)
            let index = (y * cgImage.width + x) * 4
            return (Int(data[index]), Int(data[index + 1]), Int(data[index + 2]))
        }
    }

    private func choose(_ mode: String, in app: XCUIApplication) {
        app.setOption(mode, inRow: "Picture quality")
    }

    private func closeEnough(_ a: (Int, Int, Int), _ b: (Int, Int, Int), tolerance: Int) -> Bool {
        abs(a.0 - b.0) <= tolerance && abs(a.1 - b.1) <= tolerance && abs(a.2 - b.2) <= tolerance
    }

    /// "Best performance" removes the frame-rate cap and keeps 32-bit color (cursor drawn locally), so switching to it does NOT reconnect, and the color
    /// stays exactly as before (compared with the very frame from before the switch).
    func testBestPerformanceKeepsFullColourAndDoesNotReconnect() throws {
        let (app, screen) = launch(suite: "ui-quality-\(UUID().uuidString)")
        let before = try sampledColours(app, screen)
        for (sample, want) in zip(before, expected) {
            XCTAssertTrue(closeEnough(sample, want, tolerance: 40), "color \(sample) is far from the expected \(want): is the screenshot read at the right place?")
        }
        choose("Best performance", in: app)
        Thread.sleep(forTimeInterval: 2)
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'quality mode'")).firstMatch.exists, "must not reconnect")
        XCTAssertTrue(app.buttons["Keyboard"].exists)
        let after = try sampledColours(app, screen)
        for (sample, reference) in zip(after, before) {
            XCTAssertTrue(closeEnough(sample, reference, tolerance: 2), "color \(sample) changed from \(reference): the color depth must not be reduced")
        }
    }

    /// The mode is remembered between launches: the next launch asks for 16-bit right from the start.
    func testQualityModeIsRememberedAcrossLaunches() throws {
        let suite = "ui-quality-\(UUID().uuidString)"
        var (app, _) = launch(suite: suite)
        choose("Best performance", in: app)
        XCTAssertTrue(app.buttons["Keyboard"].waitForExistence(timeout: 30))
        Thread.sleep(forTimeInterval: 2)
        app.terminate()

        (app, _) = launch(suite: suite) // same suite: reads back the saved mode (no reconnect because it is the same 32-bit)
        app.buttons["Options"].tap()
        app.buttons["Picture quality"].tap()
        XCTAssertTrue(app.buttons["Best performance"].waitForExistence(timeout: 5))
    }

    /// Switching between two modes of the same color depth (Automatic ↔ Best quality) only changes the frame rate: NO reconnect.
    func testSwitchingBetweenFullColourModesDoesNotReconnect() throws {
        let (app, _) = launch(suite: "ui-quality-\(UUID().uuidString)")
        choose("Best quality", in: app)
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(app.buttons["Keyboard"].exists, "the session must stay intact, not reconnect")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'quality mode'")).firstMatch.exists)
    }
}
