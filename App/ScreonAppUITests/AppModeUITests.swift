import XCTest

/// End-to-end App Mode test: the app in the iPad simulator pairs with `Tools/mock-link-helper` (a fake Mac on 127.0.0.1), shows the
/// launcher, opens a window, sends a tap, text and a menu item, then closes the window. The helper's event log is checked afterwards by
/// `Tools/mock-link-helper/verify_appmode.py`; this test checks what the app shows.
///
/// Needs an iPad simulator with iOS 26 or later. Run via: Tools/mock-link-helper/run_appmode_test.sh
/// The helper's address and pairing payload come in the environment (`SCREON_MOCK_HOST`, `SCREON_MOCK_PORT`, `SCREON_MOCK_QR`).
final class AppModeUITests: XCTestCase {
    private var app: XCUIApplication!
    /// The pairing code works once. The first launch of the run pairs; the app keeps the pairing, so later launches only connect.
    nonisolated(unsafe) private static var didPair = false

    override func setUpWithError() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["SCREON_MOCK_HOST"], let port = environment["SCREON_MOCK_PORT"] else {
            throw XCTSkip("SCREON_MOCK_HOST / SCREON_MOCK_PORT not set: start Tools/mock-link-helper (run_appmode_test.sh does)")
        }
        app = XCUIApplication()
        // TCP+TLS: client-initiated one-way QUIC streams do not open in the simulator (see LinkPairing.transportPreference).
        var launch = ["LINK_HOST": host, "LINK_PORT": port, "LINK_OPEN": "launcher", "LINK_TRANSPORT": "tcp"]
        if !Self.didPair, let qr = environment["SCREON_MOCK_QR"], !qr.isEmpty {
            launch["LINK_PAIRING"] = qr
            Self.didPair = true
        }
        app.launchEnvironment = launch
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func waitForNonexistence(_ element: XCUIElement, timeout: TimeInterval, _ message: String) {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: timeout), .completed, message)
    }

    /// Opens a menu button and taps the item with this title (a SwiftUI menu shows its items as buttons).
    private func choose(_ item: String, in menu: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        menu.tap()
        let button = app.buttons[item].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), "menu item '\(item)' not found. Tree:\n\(app.debugDescription)", file: file, line: line)
        button.tap()
    }

    func testLauncherOpensAWindowAndInputReachesTheMac() throws {
        app.launch()

        // 1. Paired, connected: the launcher lists the three apps of the fake Mac.
        let launcher = element("launcher-list")
        XCTAssertTrue(launcher.waitForExistence(timeout: 90), "launcher did not appear. Tree:\n\(app.debugDescription)")
        let apps = ["com.example.notes", "com.example.draw", "com.example.terminal"]
        for bundle in apps {
            XCTAssertTrue(element("app-row-\(bundle)").waitForExistence(timeout: 30), "no row for \(bundle). Tree:\n\(app.debugDescription)")
        }

        // 2. Open a window: the scene appears and, once video arrives, the status overlay goes away.
        let row = element("app-row-com.example.notes")
        row.tap()
        let remote = element("remote-window")
        XCTAssertTrue(remote.waitForExistence(timeout: 30), "remote window did not open. Tree:\n\(app.debugDescription)")
        waitForNonexistence(element("window-status"), timeout: 60, "the window stayed on its placeholder (no video)")
        Thread.sleep(forTimeInterval: 1.5)  // let the layout and the first frames settle

        // 3. A tap inside the window is sent as a pointer event.
        remote.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5)).tap()
        Thread.sleep(forTimeInterval: 0.5)

        // 4. Text: turn the on-screen keyboard on, then type.
        choose("Keyboard", in: app.buttons["window-menu"].firstMatch)
        Thread.sleep(forTimeInterval: 1)
        app.typeText("hi")
        Thread.sleep(forTimeInterval: 0.5)

        // 5. Menu item: Menus > File > New is pressed on the Mac.
        let menus = app.buttons["menus-button"].firstMatch
        XCTAssertTrue(menus.waitForExistence(timeout: 10))
        menus.tap()
        let file = app.buttons["File"].firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 10), "menu tree did not load. Tree:\n\(app.debugDescription)")
        file.tap()
        let newItem = app.buttons["New"].firstMatch
        XCTAssertTrue(newItem.waitForExistence(timeout: 5), "File > New not found. Tree:\n\(app.debugDescription)")
        newItem.tap()
        Thread.sleep(forTimeInterval: 0.5)

        // 6. The Mac window is resized to the iPad window (setFrame), then closed on the Mac.
        choose("Resize Mac window to fit", in: app.buttons["window-menu"].firstMatch)
        Thread.sleep(forTimeInterval: 0.5)
        choose("Close Mac window", in: app.buttons["window-menu"].firstMatch)
        let status = element("window-status")
        XCTAssertTrue(status.waitForExistence(timeout: 15), "no placeholder after the Mac window closed")
        XCTAssertTrue(app.staticTexts["This window was closed on the Mac."].waitForExistence(timeout: 5))

        // 7. Closing the placeholder closes the iPad window.
        let close = app.buttons["Close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        waitForNonexistence(remote, timeout: 20, "the iPad window did not close")
    }

    func testAppsCanBeSearched() throws {
        app.launch()
        XCTAssertTrue(element("launcher-list").waitForExistence(timeout: 90))
        XCTAssertTrue(element("app-row-com.example.draw").waitForExistence(timeout: 30))
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("term")
        XCTAssertTrue(element("app-row-com.example.terminal").waitForExistence(timeout: 5))
        waitForNonexistence(element("app-row-com.example.draw"), timeout: 5, "search did not filter the list")
    }
}
