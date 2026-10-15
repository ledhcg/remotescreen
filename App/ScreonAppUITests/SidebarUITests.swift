import XCTest

/// The Sidecar-style modifier-key sidebar, end to end with the fake server. This test only performs the actions (and checks layout); `verify_sidebar.py` reads
/// the server log to assert the order of keys and clicks.
///
/// "Hold ⌘ with one hand, tap with the other" cannot be produced by XCUITest (no two independent simultaneous touches): check by hand on an iPad.
final class SidebarUITests: XCTestCase {
    private let remote = CGSize(width: 800, height: 600)

    func testModifierKeysUndoEscapeAndHiding() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment = [
            "RFB_HOST": "127.0.0.1", "RFB_PORT": "5959", "RFB_SIDEBAR": "leading", "RFB_DEFAULTS_SUITE": "sidebar-ui-test",
        ]
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let screen = app.descendants(matching: .any).matching(identifier: "screon").firstMatch
        XCTAssertTrue(screen.waitForExistence(timeout: 30), "could not enter the session:\n\(app.debugDescription)")
        let command = app.buttons["Command"]
        XCTAssertTrue(command.waitForExistence(timeout: 10), "sidebar did not appear")
        Thread.sleep(forTimeInterval: 3)

        // The sidebar sits beside the Mac screen, not on top of it.
        let sidebarRight = command.frame.maxX
        XCTAssertGreaterThanOrEqual(screen.frame.minX, sidebarRight - 1, "the Mac screen must start after the sidebar")
        let widthWithSidebar = screen.frame.width

        func point(_ x: Double, _ y: Double) -> XCUICoordinate {
            let frame = screen.frame
            let scale = min(frame.width / remote.width, frame.height / remote.height)
            let origin = CGPoint(x: (frame.width - remote.width * scale) / 2, y: (frame.height - remote.height * scale) / 2)
            return screen.coordinate(withNormalizedOffset: CGVector(
                dx: (origin.x + x * scale) / frame.width, dy: (origin.y + y * scale) / frame.height
            ))
        }

        // 1. Tap ⌘ once: sticky for ONE click, then releases itself.
        command.tap()
        XCTAssertEqual(command.value as? String, "Sticky for next action")
        point(150, 150).tap()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(command.value as? String, "", "sticky ⌘ must release after the click")

        // 2. Tap twice: locked across two clicks, tap again to unlock.
        command.doubleTap()
        XCTAssertEqual(command.value as? String, "Locked")
        point(550, 150).tap()
        Thread.sleep(forTimeInterval: 0.8)
        point(550, 450).tap()
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertEqual(command.value as? String, "Locked", "a locked key must not release after a click")
        command.tap()
        XCTAssertEqual(command.value as? String, "")
        Thread.sleep(forTimeInterval: 0.5)

        // 3. Undo (⌘Z) and Escape.
        app.buttons["Undo"].tap()
        Thread.sleep(forTimeInterval: 0.5)
        app.buttons["Escape"].tap()
        Thread.sleep(forTimeInterval: 0.5)

        // 4. Hide the sidebar from the menu: the Mac screen widens, the ⌘ key disappears.
        app.buttons["Options"].tap()
        app.buttons["Hide sidebar"].tap()
        XCTAssertTrue(command.waitForNonExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1)
        XCTAssertGreaterThan(screen.frame.width, widthWithSidebar + 20, "hiding the sidebar must widen the Mac screen")
        Thread.sleep(forTimeInterval: 1)
    }
}
