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
        let points = RemoteScreenPoints(screen: screen, remote: remote)
        let value = screen.value as? String ?? ""
        // The whole Mac screen still fits inside the view (a zoom would make it larger than the view on some axis).
        let rect = points.contentRect
        XCTAssertTrue(rect.width <= screen.frame.width + 1 && rect.height <= screen.frame.height + 1, "pinch must not zoom the viewport: \(value)")
        XCTAssertEqual(rect.width / rect.height, remote.width / remote.height, accuracy: 0.01, "\(value)")

        // The connection is still alive after message 23: a tap must reach the server.
        points.point(250, 300).tap()
        Thread.sleep(forTimeInterval: 1.5)
    }
}
