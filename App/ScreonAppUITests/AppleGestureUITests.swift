import XCTest

/// Pinch and rotate sent to the Mac (Apple message 23), end to end with the fake server running `--apple` (announcing itself as `RFB 003.889`).
/// This test only performs the actions; `verify_gestures.py` reads the log to assert the server received the right messages and the connection stayed alive afterwards.
final class AppleGestureUITests: XCTestCase {
    private let remote = CGSize(width: 800, height: 600)

    func testPinchAndRotateAreSentToTheMac() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment = [
            "RFB_HOST": "127.0.0.1", "RFB_PORT": "5959", "RFB_PINCH_TO_MAC": "1", "RFB_SMOOTH_SCROLL": "1",
            "RFB_SIDEBAR": "hidden", "RFB_DEFAULTS_SUITE": "apple-gesture-ui-test",
        ]
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let screen = app.descendants(matching: .any).matching(identifier: "screon").firstMatch
        XCTAssertTrue(screen.waitForExistence(timeout: 30), "could not enter the session:\n\(app.debugDescription)")
        Thread.sleep(forTimeInterval: 3)

        screen.pinch(withScale: 2, velocity: 1)
        Thread.sleep(forTimeInterval: 1)
        screen.rotate(.pi / 4, withVelocity: 1)
        Thread.sleep(forTimeInterval: 1)

        // The iPad viewport must not zoom (the pinch went to the Mac): the accessibility value still reports the whole Mac screen fitting the frame.
        let frame = screen.frame
        let scale = min(frame.width / remote.width, frame.height / remote.height)
        let value = screen.value as? String ?? ""
        let shown = value.components(separatedBy: "shown at ").last?.components(separatedBy: "×").first.flatMap(Double.init) ?? 0
        XCTAssertEqual(shown, remote.width * scale, accuracy: 2, "pinch must not zoom the viewport: \(value)")

        // The connection is still alive after message 23: a tap must reach the server.
        let origin = CGPoint(x: (frame.width - remote.width * scale) / 2, y: (frame.height - remote.height * scale) / 2)
        screen.coordinate(withNormalizedOffset: CGVector(
            dx: (origin.x + 250 * scale) / frame.width, dy: (origin.y + 300 * scale) / frame.height
        )).tap()
        Thread.sleep(forTimeInterval: 1.5)
    }
}
