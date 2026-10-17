import UIKit
import XCTest

/// The three display modes (fit, fill, native pixels) and the automatic adaptation on rotation, checked with **real pixels** from the simulator screenshot,
/// with the fake server (800x600 four-color sample image). Run via: Tools/mock-rfb-server/run_ui_test.sh
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
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let screen = app.descendants(matching: .any).matching(identifier: "screon").firstMatch
        XCTAssertTrue(screen.waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["Options"].waitForExistence(timeout: 30))
        Thread.sleep(forTimeInterval: 3)
        return (app, screen)
    }

    /// A screenshot rotated to the displayed orientation (redrawn through UIKit to apply `imageOrientation`), read in point coordinates.
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
        app.setOption(label, inRow: "Display")
        Thread.sleep(forTimeInterval: 1.5)
    }

    /// Two points that distinguish the three modes on a portrait iPhone (the view is taller than wide, the Mac picture 4:3):
    /// - `side`: right at the left edge, slightly above center. Fit and fill: picture. Native pixels (small picture in the middle): black.
    /// - `top`: near the top edge. Fit (black bars top and bottom) and native pixels: black. Fill: picture.
    private func probes(_ screen: XCUIElement) -> (side: CGPoint, top: CGPoint, centre: CGPoint) {
        let f = screen.frame
        return (CGPoint(x: f.minX + 20, y: f.midY - 30), CGPoint(x: f.midX - 80, y: f.minY + 40), CGPoint(x: f.midX - 40, y: f.midY - 30))
    }

    func testEachModePlacesTheMacScreenDifferently() throws {
        let (app, screen) = launch(suite: "ui-display-\(UUID().uuidString)")
        let p = probes(screen)

        var snap = try Snapshot(app) // default: fit to screen
        XCTAssertTrue(snap.isContent(p.side), "fit to screen: the picture touches the left edge")
        XCTAssertTrue(snap.isBlack(p.top), "fit to screen: black bars at the top")

        choose("Fill screen", in: app)
        snap = try Snapshot(app)
        UIShots.save(app, "display-fill")
        XCTAssertTrue(snap.isContent(p.side) && snap.isContent(p.top), "fill: no black bars left")

        choose("Native pixels (1:1)", in: app)
        snap = try Snapshot(app)
        UIShots.save(app, "display-native")
        XCTAssertTrue(snap.isBlack(p.side) && snap.isBlack(p.top), "native pixels: the small 800x600-pixel picture sits in the middle")
        XCTAssertTrue(snap.isContent(p.centre), "native pixels: the picture is still visible in the middle")
    }

    func testTheChosenModeIsRememberedAcrossLaunches() throws {
        let suite = "ui-display-\(UUID().uuidString)"
        var (app, screen) = launch(suite: suite)
        choose("Native pixels (1:1)", in: app)
        app.terminate()
        (app, screen) = launch(suite: suite)
        let snap = try Snapshot(app)
        XCTAssertTrue(snap.isBlack(probes(screen).side), "after relaunch it is still native pixels")
    }

    /// The displayed size, read from the view's accessibility value ("… shown at WIDTH×HEIGHT points").
    private func shownSize(_ screen: XCUIElement) throws -> CGSize {
        let value = try XCTUnwrap(screen.value as? String)
        let match = try XCTUnwrap(value.firstMatch(of: /shown at (\d+)×(\d+) points/), "accessibility value: \(value)")
        return CGSize(width: Double(match.1)!, height: Double(match.2)!)
    }

    /// Auto-adaptation: rotating to landscape in fit mode makes the picture stretch to the new height (up to the system margins, black bars at the sides);
    /// in portrait it touches the left and right edges. The displayed size is read via accessibility: XCUITest landscape screenshots are not orientation-normalized.
    func testFitAdaptsWhenTheDeviceRotates() throws {
        let (_, screen) = launch(suite: "ui-display-\(UUID().uuidString)")
        let portrait = try shownSize(screen)
        XCTAssertEqual(portrait.width, screen.frame.width, accuracy: 2, "portrait: the picture touches the left and right edges")

        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 2.5)
        let frame = screen.frame
        XCTAssertGreaterThan(frame.width, frame.height, "the view must be landscape after rotating")
        let landscape = try shownSize(screen)
        // The picture fills the height between the system margins (it stays clear of the home indicator), so not quite the frame.
        XCTAssertGreaterThan(landscape.height, frame.height * 0.9, "landscape: the picture uses the full height")
        XCTAssertLessThanOrEqual(landscape.height, frame.height + 1)
        XCTAssertLessThan(landscape.width, frame.width - 10, "landscape: black bars remain on both sides (4:3 picture)")
        let rect = RemoteScreenPoints(screen: screen, remote: CGSize(width: 800, height: 600)).contentRect
        XCTAssertTrue(rect.minX >= 0 && rect.minY >= 0 && rect.maxX <= frame.width + 1 && rect.maxY <= frame.height + 1, "inside the view: \(rect)")
        XCTAssertGreaterThan(landscape.height, portrait.height, "the picture is larger in landscape")
    }

    /// The fake server is not Apple: "match device resolution" must behave like fit to screen (no Apple-specific message is sent).
    func testDeviceResolutionFallsBackToFitOnNonAppleServers() throws {
        let (app, screen) = launch(suite: "ui-display-\(UUID().uuidString)")
        let before = try shownSize(screen)
        choose("Match device resolution", in: app)
        let after = try shownSize(screen)
        XCTAssertEqual(after.width, before.width, accuracy: 1)
        XCTAssertEqual(after.height, before.height, accuracy: 1)
    }
}
