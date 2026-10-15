import CoreGraphics
import Foundation
import InputKit
import LinkProtocol
import Testing
@testable import WindowKit

@Suite("WindowCoordinateSpace")
struct WindowCoordinateSpaceTests {
    private func space(
        window: CGSize = CGSize(width: 800, height: 600), mode: WindowFitMode = .fit,
        view: CGSize = CGSize(width: 1000, height: 1000), scale: Double = 2, zoom: Double = 1, pan: CGPoint = .zero, surfaces: [CGRect] = []
    ) -> WindowCoordinateSpace {
        WindowCoordinateSpace(windowSize: window, backingScale: scale, viewSize: view, fitMode: mode, zoom: zoom, pan: pan, surfaces: surfaces)
    }

    @Test func fitLetterboxesAndCentres() {
        let s = space()
        #expect(s.scale == 1.25) // min(1000/800, 1000/600) = 1.25
        #expect(s.contentRect == CGRect(x: 0, y: 125, width: 1000, height: 750))
        #expect(s.windowPoint(forView: CGPoint(x: 500, y: 500)) == CGPoint(x: 400, y: 300))
        // The letterbox border is outside the window.
        #expect(s.windowPoint(forView: CGPoint(x: 500, y: 50), clamped: false) == nil)
        #expect(s.remotePixel(forView: CGPoint(x: 500, y: 50), clamped: false) == nil)
    }

    @Test func fillCoversTheView() {
        let s = space(mode: .fill)
        #expect(s.scale == 1000.0 / 600.0)
        #expect(s.contentRect.width >= 1000 && s.contentRect.height == 1000)
        // The crop is symmetric: the view centre is the window centre.
        let centre = s.windowPoint(forView: CGPoint(x: 500, y: 500))
        #expect(abs(centre.x - 400) < 1e-9 && abs(centre.y - 300) < 1e-9)
    }

    @Test func actualIsOnePointPerPoint() {
        let s = space(mode: .actual, view: CGSize(width: 1200, height: 800))
        #expect(s.scale == 1)
        #expect(s.windowPoint(forView: CGPoint(x: 200, y: 100)) == CGPoint(x: 0, y: 0))
        #expect(s.pointsPerRemotePixel == 1)
    }

    @Test(arguments: [WindowFitMode.fit, .fill, .actual], [1.0, 2.0])
    func roundTripsViewWindowView(mode: WindowFitMode, backing: Double) {
      for zoom in [1.0, 2.5, 0.5] {
       for pan in [CGPoint.zero, CGPoint(x: 40, y: -30), CGPoint(x: 5000, y: 5000)] {
        let s = space(mode: mode, scale: backing, zoom: zoom, pan: pan)
        for view in [CGPoint(x: 0, y: 0), CGPoint(x: 333.3, y: 777.7), CGPoint(x: 999, y: 1)] {
            let window = s.windowPoint(forView: view)
            let back = s.viewPoint(forWindow: window)
            #expect(abs(back.x - view.x) < 1e-9 && abs(back.y - view.y) < 1e-9)
        }
        for window in [CGPoint(x: 0, y: 0), CGPoint(x: 799.5, y: 12.25), CGPoint(x: 400, y: 300)] {
            let view = s.viewPoint(forWindow: window)
            let back = s.windowPoint(forView: view)
            #expect(abs(back.x - window.x) < 1e-9 && abs(back.y - window.y) < 1e-9)
        }
       }
      }
    }

    @Test func backingScaleSizesTheStreamButNotTheMapping() {
        let one = space(scale: 1), two = space(scale: 2)
        #expect(one.pixelSize == CGSize(width: 800, height: 600))
        #expect(two.pixelSize == CGSize(width: 1600, height: 1200))
        #expect(one.windowPoint(forView: CGPoint(x: 250, y: 300)) == two.windowPoint(forView: CGPoint(x: 250, y: 300)))
    }

    @Test func panIsLimitedToTheContentAndIgnoredWhenItFits() {
        var s = space(zoom: 2)
        // Content is 2000 x 1500 in a 1000 x 1000 view: pan is limited to half the overflow.
        s.pan(by: CGPoint(x: 9999, y: -9999))
        #expect(s.effectivePan == CGPoint(x: 500, y: -250))
        #expect(s.contentRect.minX <= 0 && s.contentRect.maxX >= 1000 && s.contentRect.minY <= 0 && s.contentRect.maxY >= 1000)
        let fits = space(pan: CGPoint(x: 100, y: 100))
        #expect(fits.effectivePan == .zero)
    }

    @Test func zoomAnchorKeepsThePointUnderTheFinger() {
        var s = space()
        let anchor = CGPoint(x: 700, y: 400)
        let before = s.windowPoint(forView: anchor)
        s.setZoom(3, anchoredAtView: anchor)
        let after = s.windowPoint(forView: anchor)
        #expect(abs(before.x - after.x) < 1e-9 && abs(before.y - after.y) < 1e-9)
        #expect(s.zoom == 3 && s.isZoomed)
        s.resetZoom()
        #expect(s.zoom == 1 && s.pan == .zero)
    }

    @Test func zoomIsClampedAndNaNIsHarmless() {
        var s = space()
        s.setZoom(1e9)
        #expect(s.zoom == 16)
        s.setZoom(-5)
        #expect(s.zoom == 0.1)
        s.setZoom(.nan)
        #expect(s.zoom == 1)
        s.pan(by: CGPoint(x: CGFloat.nan, y: CGFloat.infinity))
        #expect(s.effectivePan.x.isFinite && s.effectivePan.y.isFinite)
    }

    @Test func clampingKeepsPointsInsideTheWindow() {
        let s = space()
        #expect(s.windowPoint(forView: CGPoint(x: -500, y: -500), clamped: true) == LinkPoint(x: 0, y: 0))
        #expect(s.windowPoint(forView: CGPoint(x: 9999, y: 9999), clamped: true) == LinkPoint(x: 800, y: 600))
        let pixel = s.remotePixel(forView: CGPoint(x: 9999, y: 9999), clamped: true)
        #expect(pixel?.x == 799 && pixel?.y == 599, "the far edge rounds to the last pixel, not past it")
        let nan = s.remotePixel(forView: CGPoint(x: CGFloat.nan, y: 0), clamped: true)
        #expect(nan == nil)
    }

    @Test func surfacesExtendTheHitArea() {
        let menu = CGRect(x: 700, y: 500, width: 300, height: 400) // sticks out of the 800 x 600 window
        let s = space(mode: .actual, view: CGSize(width: 2000, height: 2000), surfaces: [menu])
        let origin = s.contentOrigin
        let inMenu = CGPoint(x: origin.x + 900, y: origin.y + 800)
        #expect(s.contains(windowPoint: CGPoint(x: 900, y: 800)))
        #expect(s.windowPoint(forView: inMenu, clamped: false) == LinkPoint(x: 900, y: 800))
        #expect(s.windowPoint(forView: inMenu, clamped: true) == LinkPoint(x: 900, y: 800), "inside a surface nothing is clamped")
        #expect(!s.contains(windowPoint: CGPoint(x: 900, y: 100)))
        #expect(s.remotePixel(forView: CGPoint(x: origin.x + 900, y: origin.y + 800), clamped: false)?.x == 900)
    }

    @Test func invalidSizesMapNothing() {
        for bad in [space(window: CGSize(width: 0, height: 600)), space(view: CGSize(width: CGFloat.nan, height: 10)), space(window: CGSize(width: -1, height: -1))] {
            #expect(!bad.isValid)
            #expect(bad.windowPoint(forView: CGPoint(x: 5, y: 5), clamped: true) == nil)
            #expect(bad.remotePixel(forView: CGPoint(x: 5, y: 5), clamped: true) == nil)
            #expect(!bad.contains(windowPoint: .zero))
        }
    }

    @Test func conformsToRemoteCoordinateSpaceForTouchMapper() {
        let s = space(mode: .actual, view: CGSize(width: 800, height: 600))
        #expect(s.remoteSize == CGSize(width: 800, height: 600))
        var mapper = TouchMapper(policy: TouchPolicy())
        let output = mapper.handle(.tap(CGPoint(x: 100, y: 50), count: 1), in: s, isZoomed: false)
        #expect(!output.intents.isEmpty)
        guard case .pointer(let at, _, _)? = output.intents.first else {
            Issue.record("expected a pointer intent first")
            return
        }
        #expect(at == RemotePoint(x: 100, y: 50))
    }
}

@Suite("InputRouter")
struct InputRouterTests {
    // 800 x 600 window shown at 1:1 in an 800 x 600 view, so view points equal window points.
    private let space = WindowCoordinateSpace(
        windowSize: CGSize(width: 800, height: 600), viewSize: CGSize(width: 800, height: 600), fitMode: .actual,
        surfaces: [CGRect(x: 700, y: 500, width: 200, height: 200)]
    )

    private func route(_ router: inout InputRouter, _ x: Double, _ y: Double, _ buttons: PointerButtons = []) -> RoutedPointer? {
        router.route(viewPoint: CGPoint(x: x, y: y), buttons: buttons, in: space)
    }

    @Test func hoverInsideIsDeliveredOutsideIsDropped() {
        var router = InputRouter()
        #expect(route(&router, 10, 10)?.point == LinkPoint(x: 10, y: 10))
        #expect(route(&router, -5, 10) == nil)
        #expect(!router.isCapturing)
    }

    @Test func dragStartedInsideIsCapturedAndClampedUntilRelease() {
        var router = InputRouter()
        #expect(route(&router, 100, 100, .left)?.isCaptured == true)
        #expect(route(&router, -50, 100, .left)?.point == LinkPoint(x: 0, y: 100))
        #expect(route(&router, 5000, 5000, .left)?.point == LinkPoint(x: 800, y: 600))
        let release = route(&router, 900, 900)
        #expect(release?.buttons == [] && release?.point == LinkPoint(x: 800, y: 600), "the release reaches the app")
        #expect(!router.isCapturing)
        #expect(route(&router, 900, 900) == nil, "hover outside is dropped again")
    }

    @Test func gestureStartedOutsideIsDroppedEvenWhenItEntersTheWindow() {
        var router = InputRouter()
        #expect(route(&router, -20, 50, .left) == nil)
        #expect(route(&router, 50, 50, .left) == nil, "dragging in from outside must not click inside")
        #expect(route(&router, 50, 50) == nil, "the release is dropped too")
        #expect(route(&router, 50, 50, .left)?.isCaptured == true, "a new press inside works")
    }

    @Test func surfacesCountAsInside() {
        var router = InputRouter()
        let hit = route(&router, 850, 650, .left) // outside the window, inside the menu
        #expect(hit?.point == LinkPoint(x: 850, y: 650))
        #expect(router.isCapturing)
    }

    @Test func unclampedCaptureContinuesPastTheEdge() {
        var router = InputRouter(policy: .captureUnclamped)
        _ = route(&router, 100, 100, .left)
        #expect(route(&router, -300, 900, .left)?.point == LinkPoint(x: -300, y: 900))
        #expect(route(&router, -300, 900)?.buttons == [])
        #expect(route(&router, -300, 900, .left) == nil, "a new press outside is still dropped")
    }

    @Test func dropOutsideReleasesAtTheEdgeAndIgnoresTheRest() {
        var router = InputRouter(policy: .dropOutside)
        _ = route(&router, 100, 100, .left)
        let cut = route(&router, -10, 100, .left)
        #expect(cut?.buttons == [] && cut?.point == LinkPoint(x: 0, y: 100))
        #expect(route(&router, -20, 100, .left) == nil)
        #expect(route(&router, 100, 100, .left) == nil, "coming back with the button still down does not resume")
        _ = route(&router, 100, 100)
        #expect(route(&router, 100, 100, .left)?.isCaptured == true)
    }

    @Test func clampAlwaysDeliversEverything() {
        var router = InputRouter(policy: .clampAlways)
        #expect(route(&router, -40, 1000)?.point == LinkPoint(x: 0, y: 600))
        #expect(route(&router, -40, 1000, .left)?.point == LinkPoint(x: 0, y: 600))
    }

    @Test func cancelForgetsTheGesture() {
        var router = InputRouter()
        _ = route(&router, 100, 100, .left)
        router.cancel()
        #expect(!router.isCapturing)
    }

    @Test func invalidInputIsDropped() {
        var router = InputRouter()
        #expect(route(&router, .nan, 1) == nil)
        let invalid = WindowCoordinateSpace(windowSize: .zero, viewSize: .zero)
        #expect(router.route(viewPoint: .zero, buttons: [], in: invalid) == nil)
    }
}
