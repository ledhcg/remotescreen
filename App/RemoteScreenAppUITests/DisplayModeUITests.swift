import UIKit
import XCTest

/// Ba chế độ hiển thị (vừa, lấp đầy, điểm ảnh gốc) và việc tự thích ứng khi xoay máy, kiểm bằng **điểm ảnh thật** trên ảnh chụp
/// simulator, với server giả (hình mẫu 800x600 bốn màu). Chạy qua: Tools/mock-rfb-server/run_ui_test.sh
final class DisplayModeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    private func launch(suite: String) -> (XCUIApplication, XCUIElement) {
        let app = XCUIApplication()
        app.launchEnvironment = ["RFB_HOST": "127.0.0.1", "RFB_PORT": "5959", "RFB_DEFAULTS_SUITE": suite]
        app.launch()
        let screen = app.descendants(matching: .any).matching(identifier: "remoteScreen").firstMatch
        XCTAssertTrue(screen.waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["Tùy chọn"].waitForExistence(timeout: 30))
        Thread.sleep(forTimeInterval: 3)
        return (app, screen)
    }

    /// Ảnh chụp đã xoay đúng chiều đang hiển thị (vẽ lại qua UIKit để áp dụng `imageOrientation`), đọc theo toạ độ point.
    private struct Snapshot {
        let pixels: [UInt8]
        let width: Int
        let scale: CGFloat

        init(_ app: XCUIApplication) throws {
            let shot = app.screenshot().image
            let format = UIGraphicsImageRendererFormat()
            format.scale = shot.scale
            let upright = UIGraphicsImageRenderer(size: shot.size, format: format).image { _ in shot.draw(at: .zero) }
            let cg = try XCTUnwrap(upright.cgImage)
            var data = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
            let context = try XCTUnwrap(CGContext(
                data: &data, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            pixels = data
            width = cg.width
            scale = CGFloat(cg.width) / shot.size.width
        }

        func isBlack(_ point: CGPoint) -> Bool { channels(point).max()! < 25 }
        func isContent(_ point: CGPoint) -> Bool { channels(point).max()! > 60 }

        func channels(_ point: CGPoint) -> [Int] {
            let index = (Int(point.y * scale) * width + Int(point.x * scale)) * 4
            return [Int(pixels[index]), Int(pixels[index + 1]), Int(pixels[index + 2])]
        }
    }

    private func choose(_ label: String, in app: XCUIApplication) {
        app.buttons["Tùy chọn"].tap()
        app.buttons[label].tap()
        Thread.sleep(forTimeInterval: 1.5)
    }

    /// Hai điểm phân biệt được ba chế độ trên iPhone dọc (khung nhìn cao hơn rộng, hình Mac 4:3):
    /// - `side`: sát mép trái, trên tâm một chút. Vừa và lấp đầy: có hình. Điểm ảnh gốc (hình nhỏ ở giữa): đen.
    /// - `top`: gần mép trên. Vừa (viền đen trên dưới) và điểm ảnh gốc: đen. Lấp đầy: có hình.
    private func probes(_ screen: XCUIElement) -> (side: CGPoint, top: CGPoint, centre: CGPoint) {
        let f = screen.frame
        return (CGPoint(x: f.minX + 20, y: f.midY - 30), CGPoint(x: f.midX - 80, y: f.minY + 40), CGPoint(x: f.midX - 40, y: f.midY - 30))
    }

    func testEachModePlacesTheMacScreenDifferently() throws {
        let (app, screen) = launch(suite: "ui-display-\(UUID().uuidString)")
        let p = probes(screen)

        var snap = try Snapshot(app) // mặc định: vừa màn hình
        XCTAssertTrue(snap.isContent(p.side), "vừa màn hình: hình chạm mép trái")
        XCTAssertTrue(snap.isBlack(p.top), "vừa màn hình: có viền đen phía trên")

        choose("Lấp đầy màn hình", in: app)
        snap = try Snapshot(app)
        UIShots.save(app, "display-fill")
        XCTAssertTrue(snap.isContent(p.side) && snap.isContent(p.top), "lấp đầy: không còn viền đen")

        choose("Điểm ảnh gốc (1:1)", in: app)
        snap = try Snapshot(app)
        UIShots.save(app, "display-native")
        XCTAssertTrue(snap.isBlack(p.side) && snap.isBlack(p.top), "điểm ảnh gốc: hình 800x600 pixel nhỏ, nằm giữa")
        XCTAssertTrue(snap.isContent(p.centre), "điểm ảnh gốc: vẫn thấy hình ở giữa")
    }

    func testTheChosenModeIsRememberedAcrossLaunches() throws {
        let suite = "ui-display-\(UUID().uuidString)"
        var (app, screen) = launch(suite: suite)
        choose("Điểm ảnh gốc (1:1)", in: app)
        app.terminate()
        (app, screen) = launch(suite: suite)
        let snap = try Snapshot(app)
        XCTAssertTrue(snap.isBlack(probes(screen).side), "mở lại vẫn ở điểm ảnh gốc")
    }

    /// Cỡ đang hiển thị, đọc từ giá trị trợ năng của view ("… hiển thị RỘNG×CAO điểm").
    private func shownSize(_ screen: XCUIElement) throws -> CGSize {
        let value = try XCTUnwrap(screen.value as? String)
        let match = try XCTUnwrap(value.firstMatch(of: /hiển thị (\d+)×(\d+) điểm/), "giá trị trợ năng: \(value)")
        return CGSize(width: Double(match.1)!, height: Double(match.2)!)
    }

    /// Tự thích ứng: xoay ngang ở chế độ vừa màn hình thì hình giãn theo chiều cao mới (chạm mép trên dưới, viền đen hai bên);
    /// dọc thì chạm mép trái phải. Đọc cỡ hiển thị qua trợ năng: ảnh chụp ngang của XCUITest không được chuẩn hóa hướng.
    func testFitAdaptsWhenTheDeviceRotates() throws {
        let (_, screen) = launch(suite: "ui-display-\(UUID().uuidString)")
        let portrait = try shownSize(screen)
        XCTAssertEqual(portrait.width, screen.frame.width, accuracy: 2, "dọc: hình chạm hai mép trái phải")

        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 2.5)
        let frame = screen.frame
        XCTAssertGreaterThan(frame.width, frame.height, "khung nhìn phải nằm ngang sau khi xoay")
        let landscape = try shownSize(screen)
        XCTAssertEqual(landscape.height, frame.height, accuracy: 2, "ngang: hình chạm mép trên dưới")
        XCTAssertLessThan(landscape.width, frame.width - 10, "ngang: còn viền đen hai bên (hình 4:3)")
        XCTAssertGreaterThan(landscape.height, portrait.height, "ngang thì hình lớn hơn")
    }

    /// Server giả không phải Apple: "theo độ phân giải thiết bị" phải cư xử như vừa màn hình (không gửi message riêng của Apple).
    func testDeviceResolutionFallsBackToFitOnNonAppleServers() throws {
        let (app, screen) = launch(suite: "ui-display-\(UUID().uuidString)")
        let before = try shownSize(screen)
        choose("Theo độ phân giải thiết bị", in: app)
        let after = try shownSize(screen)
        XCTAssertEqual(after.width, before.width, accuracy: 1)
        XCTAssertEqual(after.height, before.height, accuracy: 1)
    }
}
