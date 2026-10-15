import XCTest

/// Hardware keyboard (iPad with Magic Keyboard / Smart Keyboard / Bluetooth keyboard) reaching the fake server.
/// This test only types; `verify_keys.py` checks the keysyms received.
/// Run via: Tools/mock-rfb-server/run_keyboard_test.sh
final class HardwareKeyboardUITests: XCTestCase {
    func testSpecialKeysAndModifiersReachTheServer() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment = ["RFB_HOST": "127.0.0.1", "RFB_PORT": "5959"]
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let screen = app.descendants(matching: .any).matching(identifier: "screon").firstMatch
        XCTAssertTrue(screen.waitForExistence(timeout: 30))
        Thread.sleep(forTimeInterval: 4)

        // Only keys that XCUITest generates reliably. Return, Delete, Escape, Home, End, Page Up/Down and F-keys typed by XCUITest do not
        // reach `pressesBegan` (or have wrong codes) on the simulator, while on a real iPad typing via Device Hub they arrive correctly:
        // that part is checked by hand, recorded in docs/app-status.md.
        let steps: [(XCUIKeyboardKey, XCUIElement.KeyModifierFlags)] = [
            (.tab, []), (.upArrow, []), (.downArrow, []), (.leftArrow, []), (.rightArrow, []),
        ]
        for (key, modifiers) in steps {
            app.typeKey(key, modifierFlags: modifiers)
            Thread.sleep(forTimeInterval: 0.4)
        }
        app.typeKey("c", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.4)
        app.typeKey("c", modifierFlags: .control)
        Thread.sleep(forTimeInterval: 0.4)
        app.typeKey("x", modifierFlags: .option)
        Thread.sleep(forTimeInterval: 0.4)
        app.typeKey("a", modifierFlags: [.command, .shift])
        Thread.sleep(forTimeInterval: 0.4)

        // ⌘ combinations that the iPadOS system menu may capture. The remote Mac needs to receive them all. Ordered from least to most disruptive.
        for letter in ["z", "s", "o", "p", "f", "t", "n", "w"] {
            app.typeKey(letter, modifierFlags: .command)
            Thread.sleep(forTimeInterval: 0.4)
        }
        Thread.sleep(forTimeInterval: 1)
    }
}
