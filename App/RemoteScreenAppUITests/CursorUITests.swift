import XCTest

/// Takes an app screenshot after a tap so the script `Tools/mock-rfb-server/verify_cursor.py` can check the cursor appears in the right
/// place. This test does not assert pixels itself: it only performs the actions and saves the image to the path in `CURSOR_SHOT`.
///
/// Run via: Tools/mock-rfb-server/run_cursor_test.sh
final class CursorUITests: XCTestCase {
    private let remote = CGSize(width: 800, height: 600)

    func testCursorAppearsWhereTheServerPutsItsMarker() throws {
        let app = XCUIApplication()
        app.launchEnvironment = ["RFB_HOST": "127.0.0.1", "RFB_PORT": "5959"]
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        let screen = app.descendants(matching: .any).matching(identifier: "remoteScreen").firstMatch
        XCTAssertTrue(screen.waitForExistence(timeout: 30), "remote screen view not found")
        Thread.sleep(forTimeInterval: 4)

        let frame = screen.frame
        let scale = min(frame.width / remote.width, frame.height / remote.height)
        let origin = CGPoint(x: (frame.width - remote.width * scale) / 2, y: (frame.height - remote.height * scale) / 2)
        func point(_ x: Double, _ y: Double) -> XCUICoordinate {
            screen.coordinate(withNormalizedOffset: CGVector(
                dx: (origin.x + x * scale) / frame.width, dy: (origin.y + y * scale) / frame.height
            ))
        }

        // Tap away from the white crosshair in the middle, because the crosshair has white pixels like the cursor's fill.
        point(560, 140).tap()
        Thread.sleep(forTimeInterval: 1.5)

        let png = XCUIScreen.main.screenshot().pngRepresentation
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = "cursor-after-tap"
        attachment.lifetime = .keepAlways
        add(attachment)

        if let path = ProcessInfo.processInfo.environment["CURSOR_SHOT"] {
            try png.write(to: URL(fileURLWithPath: path))
        }
    }
}
