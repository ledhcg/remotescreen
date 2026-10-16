import XCTest

/// End-to-end input test: the app in the simulator connects to a fake RFB server (Tools/mock-rfb-server), the test taps, drags and types,
/// then a Python script checks the events the server received. This test does NOT assert event contents itself because it
/// cannot see the server side; it only ensures the actions run. The assertions live in `verify_input.py`.
///
/// Run via: Tools/mock-rfb-server/run_input_test.sh
final class InputUITests: XCTestCase {
    /// Screen size of the fake server.
    private let remote = CGSize(width: 800, height: 600)

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testTouchGesturesAndTypingReachTheServer() throws {
        let app = XCUIApplication()
        // The toolbar moves off the centre line: `twoFingerTap()` puts one finger at the top centre, which on an iPad is the toolbar.
        app.launchEnvironment = ["RFB_HOST": "127.0.0.1", "RFB_PORT": "5959", "SCREON_TOOLBAR_ALIGN": "trailing"]
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        // The element type of a view with `allowsDirectInteraction` is not fixed, so look it up by identifier across all types.
        let screen = app.descendants(matching: .any).matching(identifier: "screon").firstMatch
        XCTAssertTrue(screen.waitForExistence(timeout: 30), "remote screen view not found. Element tree:\n\(app.debugDescription)")
        Thread.sleep(forTimeInterval: 4) // wait for the connection, the first frame and the layout to settle

        // A point on the fake "Mac screen" (Mac pixels) → normalized coordinates in the view, following the exact fit-in-the-middle placement.
        let frame = screen.frame
        let scale = min(frame.width / remote.width, frame.height / remote.height)
        let origin = CGPoint(x: (frame.width - remote.width * scale) / 2, y: (frame.height - remote.height * scale) / 2)
        func point(_ x: Double, _ y: Double) -> XCUICoordinate {
            screen.coordinate(withNormalizedOffset: CGVector(
                dx: (origin.x + x * scale) / frame.width, dy: (origin.y + y * scale) / frame.height
            ))
        }

        // 1. One-finger tap → left click at the touch point.
        point(100, 450).tap()
        Thread.sleep(forTimeInterval: 0.6)
        point(700, 520).tap()
        Thread.sleep(forTimeInterval: 0.6)

        // 2. Two-finger tap in the middle → right click.
        screen.twoFingerTap()
        Thread.sleep(forTimeInterval: 0.6)

        // 3. Press and hold then drag → drag-and-drop with the left button.
        point(200, 350).press(forDuration: 0.8, thenDragTo: point(600, 500))
        Thread.sleep(forTimeInterval: 0.6)

        // 4. Double tap → two clicks.
        point(300, 250).doubleTap()
        Thread.sleep(forTimeInterval: 0.6)

        // 5. Keyboard: turn on the on-screen keyboard then type "Ab" and Return.
        app.buttons["Keyboard"].tap()
        Thread.sleep(forTimeInterval: 1)
        app.typeText("Ab\n")
        Thread.sleep(forTimeInterval: 1)
    }
}
