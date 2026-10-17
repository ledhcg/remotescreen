import XCTest

extension XCUIApplication {
    /// Closes a bottom sheet by dragging it down, as a finger does.
    func dismissSheet() {
        let grabber = buttons["Sheet Grabber"]
        for _ in 0..<3 where grabber.exists {
            grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.1, thenDragTo: coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
            _ = grabber.waitForNonExistence(timeout: 2)
        }
        Thread.sleep(forTimeInterval: 0.5)
    }

    /// A button by its label. Some buttons (the items of a menu with an icon) have the icon's name as identifier, which a plain
    /// `buttons["label"]` would look at instead.
    func labelled(_ label: String) -> XCUIElement {
        buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    /// The options sheet: opens it with `opener` (`nil` when it is already open), sets the row `row` to `option` through its menu, and closes the sheet.
    func setOption(_ option: String, inRow row: String, opener: String? = "Options", file: StaticString = #filePath, line: UInt = #line) {
        if let opener { buttons[opener].firstMatch.tap() }
        let rowButton = labelled(row)
        XCTAssertTrue(rowButton.waitForExistence(timeout: 5), "no row '\(row)' in the sheet. Tree:\n\(debugDescription)", file: file, line: line)
        rowButton.tap()
        let choice = labelled(option)
        XCTAssertTrue(choice.waitForExistence(timeout: 5), "no option '\(option)'. Tree:\n\(debugDescription)", file: file, line: line)
        choice.tap()
        dismissSheet()
    }
}
