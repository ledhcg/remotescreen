import XCTest

/// Bàn phím cứng (iPad có Magic Keyboard / Smart Keyboard / bàn phím Bluetooth) đi tới server giả.
/// Bài này chỉ gõ; `verify_keys.py` đối chiếu keysym nhận được.
/// Chạy qua: Tools/mock-rfb-server/run_keyboard_test.sh
final class HardwareKeyboardUITests: XCTestCase {
    func testSpecialKeysAndModifiersReachTheServer() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment = ["RFB_HOST": "127.0.0.1", "RFB_PORT": "5959"]
        app.launch()
        let screen = app.descendants(matching: .any).matching(identifier: "remoteScreen").firstMatch
        XCTAssertTrue(screen.waitForExistence(timeout: 30))
        Thread.sleep(forTimeInterval: 4)

        // Chỉ các phím mà XCUITest tạo ra đáng tin. Return, Delete, Escape, Home, End, Page Up/Down, F-phím mà XCUITest gõ không
        // tới `pressesBegan` (hoặc sai mã) trên simulator, trong khi trên iPad thật gõ qua Device Hub thì tới đúng:
        // phần đó kiểm bằng tay, ghi trong docs/app-status.md.
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

        // Tổ hợp ⌘ mà menu hệ thống của iPadOS có thể giữ lại. Mac từ xa cần nhận hết. Xếp từ ít phá nhất tới nhiều nhất.
        for letter in ["z", "s", "o", "p", "f", "t", "n", "w"] {
            app.typeKey(letter, modifierFlags: .command)
            Thread.sleep(forTimeInterval: 0.4)
        }
        Thread.sleep(forTimeInterval: 1)
    }
}
