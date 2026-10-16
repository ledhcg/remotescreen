import CoreGraphics
import Foundation
import Testing
@testable import RemoteDisplay

/// Compares floating-point numbers with a small tolerance.
private func close(_ a: Double, _ b: Double, _ tolerance: Double = 1e-9) -> Bool { abs(a - b) <= tolerance }
private func close(_ a: CGRect, _ b: CGRect, _ tolerance: Double = 1e-9) -> Bool {
    close(a.minX, b.minX, tolerance) && close(a.minY, b.minY, tolerance) &&
        close(a.width, b.width, tolerance) && close(a.height, b.height, tolerance)
}

@Suite("ViewportGeometry: scale and position")
struct ViewportScaleTests {
    // This machine's real Mac screen and a portrait iPhone-style viewport.
    private let mac = CGSize(width: 2048, height: 1152)

    @Test func fitLetterboxesPortraitPhone() {
        let geometry = ViewportGeometry(remoteSize: mac, viewSize: CGSize(width: 390, height: 844))
        // scale = min(390/2048, 844/1152) = 390/2048. Content height = 1152 * 390/2048 = 219.375, centered on y.
        #expect(close(geometry.scale, 390.0 / 2048))
        #expect(close(geometry.contentRect, CGRect(x: 0, y: (844 - 219.375) / 2, width: 390, height: 219.375)))
    }

    @Test func fitUsesTheWholeViewWhenAspectRatiosMatch() {
        let geometry = ViewportGeometry(remoteSize: CGSize(width: 1600, height: 900), viewSize: CGSize(width: 800, height: 450))
        #expect(close(geometry.contentRect, CGRect(x: 0, y: 0, width: 800, height: 450)))
        #expect(geometry.normalizedDeviceRect == SIMD4<Float>(-1, -1, 1, 1))
    }

    @Test func fillCoversTheViewAndOverflowsTheLongAxis() {
        var geometry = ViewportGeometry(remoteSize: mac, viewSize: CGSize(width: 390, height: 844), scaleMode: .fill)
        #expect(close(geometry.scale, 844.0 / 1152))
        let rect = geometry.contentRect
        #expect(close(rect.height, 844))
        #expect(rect.width > 390)
        #expect(close(rect.midX, 195)) // centered on the overflow-free axis
        geometry.pan(by: CGPoint(x: 100_000, y: 0)) // drag all the way to the right
        #expect(close(geometry.contentRect.minX, 0)) // the content's left edge touches the viewport's left edge
    }

    @Test func pixelPerfectMapsOneRemotePixelToOneDevicePixel() {
        let geometry = ViewportGeometry(remoteSize: mac, viewSize: CGSize(width: 1024, height: 768), scaleMode: .pixelPerfect(screenScale: 2))
        #expect(close(geometry.scale, 0.5)) // 1 Mac pixel = 0.5 point = 1 device pixel on a 2x screen
        #expect(close(geometry.contentRect.width, 1024))
    }

    @Test func degenerateSizesDoNotProduceNonsense() {
        let geometry = ViewportGeometry(remoteSize: .zero, viewSize: CGSize(width: 100, height: 100))
        #expect(geometry.scale == 1)
        #expect(geometry.remotePixel(forView: CGPoint(x: 5, y: 5), clamped: true) == nil)
    }
}

@Suite("ViewportGeometry: coordinate conversion")
struct ViewportMappingTests {
    private let geometry = ViewportGeometry(remoteSize: CGSize(width: 2000, height: 1000), viewSize: CGSize(width: 1000, height: 600))
    // scale 0.5; the 1000×500 content sits at y = 50...550

    @Test func centreMapsToCentre() {
        let pixel = geometry.remotePixel(forView: CGPoint(x: 500, y: 300), clamped: false)
        #expect(pixel?.x == 1000)
        #expect(pixel?.y == 500)
    }

    @Test func cornersMapToCornersAndRoundTrip() {
        #expect(geometry.remotePixel(forView: CGPoint(x: 0, y: 50), clamped: false)?.x == 0)
        #expect(geometry.remotePixel(forView: CGPoint(x: 0, y: 50), clamped: false)?.y == 0)
        #expect(geometry.remotePixel(forView: CGPoint(x: 999.9, y: 549.9), clamped: false)?.x == 1999)
        #expect(geometry.remotePixel(forView: CGPoint(x: 999.9, y: 549.9), clamped: false)?.y == 999)

        let remote = CGPoint(x: 777, y: 333)
        let back = geometry.remotePoint(forView: geometry.viewPoint(forRemote: remote))
        #expect(close(back.x, remote.x) && close(back.y, remote.y))
    }

    @Test func touchingTheLetterboxIsIgnoredOrClampedDependingOnMode() {
        let inBlackBar = CGPoint(x: 500, y: 20) // above the content
        #expect(geometry.remotePixel(forView: inBlackBar, clamped: false) == nil)
        let clamped = geometry.remotePixel(forView: inBlackBar, clamped: true)
        #expect(clamped?.y == 0) // clamped to the top edge
        #expect(clamped?.x == 1000)
    }

    @Test func offScreenPointsClampToTheLastPixel() {
        let far = geometry.remotePixel(forView: CGPoint(x: 5000, y: 5000), clamped: true)
        #expect(far?.x == 1999)
        #expect(far?.y == 999)
    }
}

@Suite("ViewportGeometry: zoom and pan")
struct ViewportZoomTests {
    private func make() -> ViewportGeometry {
        ViewportGeometry(remoteSize: CGSize(width: 2000, height: 1000), viewSize: CGSize(width: 1000, height: 600))
    }

    @Test func zoomKeepsThePointUnderTheFingerFixed() {
        var geometry = make()
        let focus = CGPoint(x: 300, y: 200)
        let before = geometry.remotePoint(forView: focus)

        geometry.zoom(by: 2, around: focus)

        let after = geometry.remotePoint(forView: focus)
        #expect(close(after.x, before.x) && close(after.y, before.y))
        #expect(close(geometry.zoom, 2))
        #expect(close(geometry.scale, 1.0))
    }

    @Test func zoomIsCappedAtBothEnds() {
        var geometry = make()
        geometry.zoom(by: 1000, around: CGPoint(x: 500, y: 300))
        #expect(geometry.zoom == ViewportGeometry.zoomRange.upperBound)
        geometry.zoom(by: 0.000_001, around: CGPoint(x: 500, y: 300))
        #expect(geometry.zoom == ViewportGeometry.zoomRange.lowerBound)
        #expect(close(geometry.contentRect, make().contentRect)) // back to exactly the original position
    }

    @Test func panCannotRevealEmptySpaceBeyondTheEdges() {
        var geometry = make()
        geometry.zoom(by: 4, around: CGPoint(x: 500, y: 300)) // content is 4000×2000 in a 1000×600 frame

        geometry.pan(by: CGPoint(x: 1_000_000, y: 1_000_000))
        #expect(close(geometry.contentRect.minX, 0) && close(geometry.contentRect.minY, 0))

        geometry.pan(by: CGPoint(x: -1_000_000, y: -1_000_000))
        #expect(close(geometry.contentRect.maxX, 1000) && close(geometry.contentRect.maxY, 600))
    }

    @Test func panIsIgnoredWhileTheContentFitsInsideTheView() {
        var geometry = make()
        geometry.pan(by: CGPoint(x: 300, y: 300))
        #expect(close(geometry.contentRect, make().contentRect))
        #expect(geometry.pan == .zero)
    }

    @Test func zoomingOutRecentresTheContent() {
        var geometry = make()
        geometry.zoom(by: 4, around: CGPoint(x: 100, y: 100))
        geometry.pan(by: CGPoint(x: 500, y: 500))
        geometry.reset()
        #expect(close(geometry.contentRect, make().contentRect))
    }

    @Test func rotatingTheDeviceKeepsPanValid() {
        var geometry = make()
        geometry.zoom(by: 4, around: CGPoint(x: 500, y: 300))
        geometry.pan(by: CGPoint(x: -1_000_000, y: -1_000_000))
        geometry.updateViewSize(CGSize(width: 600, height: 1000))
        let rect = geometry.contentRect
        #expect(rect.minX <= 0 && rect.maxX >= 600) // still covers the new viewport horizontally
        #expect(rect.minY <= 0 && rect.maxY >= 1000 || rect.height < 1000) // and shows no empty space if the content is large enough
    }

    @Test func normalizedRectFlipsTheYAxisForMetal() {
        let geometry = make() // content at y = 50...550 in a 600-tall frame
        let rect = geometry.normalizedDeviceRect
        #expect(abs(rect.x - -1) < 1e-6 && abs(rect.z - 1) < 1e-6)
        // The viewport's y axis points down, Metal's points up: top edge (y=50) → 1 - 2*50/600, bottom edge (y=550) → 1 - 2*550/600.
        #expect(abs(rect.w - Float(1 - 100.0 / 600)) < 1e-6)
        #expect(abs(rect.y - Float(1 - 1100.0 / 600)) < 1e-6)
        #expect(rect.w > rect.y) // top > bottom
    }
}

@Suite("DisplayMode: fit, fill, native pixels")
struct DisplayModeTests {
    private let mac = CGSize(width: 2560, height: 1440)
    private let iPadLandscape = CGSize(width: 1180, height: 820) // iPad Air 4, point
    private let iPadPortrait = CGSize(width: 820, height: 1180)

    private func geometry(_ mode: DisplayMode, view: CGSize, scale: Double = 2) -> ViewportGeometry {
        ViewportGeometry(remoteSize: mac, viewSize: view, scaleMode: mode.scaleMode(screenScale: scale))
    }

    @Test func fitShowsTheWholeMacScreenInsideTheView() {
        let rect = geometry(.fit, view: iPadLandscape).contentRect
        #expect(rect.width <= iPadLandscape.width + 0.001 && rect.height <= iPadLandscape.height + 0.001)
        #expect(abs(rect.width - iPadLandscape.width) < 0.001, "touches both edges horizontally")
    }

    @Test func fillCoversTheWholeViewWithNoBlackBars() {
        let rect = geometry(.fill, view: iPadLandscape).contentRect
        #expect(rect.minX <= 0 && rect.minY <= 0)
        #expect(rect.maxX >= iPadLandscape.width && rect.maxY >= iPadLandscape.height)
    }

    @Test func nativeMapsOneMacPixelToOneDevicePixel() {
        let g = geometry(.native, view: iPadLandscape, scale: 2)
        #expect(g.scale == 0.5, "0.5 point per Mac pixel = 1 device pixel on a 2x screen")
        #expect(g.contentRect.width == 1280, "2560 pixel Mac = 2560 pixel iPad = 1280 point")
        let iPhone = geometry(.native, view: CGSize(width: 393, height: 852), scale: 3)
        #expect(abs(iPhone.scale - 1.0 / 3) < 1e-12)
    }

    /// "Adapts automatically": rotating the iPad makes fit mode recompute the scale from the new size, still showing the whole Mac screen.
    @Test func rotatingRecomputesTheScaleForTheNewSize() {
        var g = geometry(.fit, view: iPadLandscape)
        let landscapeScale = g.scale
        g.updateViewSize(iPadPortrait)
        #expect(g.scale < landscapeScale, "portrait is narrower so it scales down more")
        let rect = g.contentRect
        #expect(abs(rect.width - iPadPortrait.width) < 0.001)
        #expect(rect.minY > 0, "portrait has black bars above and below, the Mac screen sits in the middle")
    }

    @Test func nativeScaleDoesNotChangeWhenRotating() {
        var g = geometry(.native, view: iPadLandscape)
        g.updateViewSize(iPadPortrait)
        #expect(g.scale == 0.5, "native pixels do not depend on the viewport size")
    }

    @Test func modesRoundTripThroughTheirStoredName() {
        for mode in DisplayMode.allCases { #expect(DisplayMode(rawValue: mode.rawValue) == mode) }
        #expect(DisplayMode(rawValue: "unknown") == nil)
        #expect(DisplayMode.default == .fit)
    }
}

@Suite("DisplayMode.device: server-side shrinking to the device resolution")
struct DeviceDisplayModeTests {
    private let mac = CGSize(width: 2560, height: 1440)

    @Test func iPadAir4LandscapeAsksForTheWidthRatio() throws {
        // 1180x820 points x2 = 2360x1640 pixels. The width is narrower: 2360/2560 = 0.921875.
        let scale = try #require(DisplayMode.device.serverScale(remote: mac, viewPixels: CGSize(width: 2360, height: 1640)))
        #expect(scale == 2360.0 / 2560.0)
    }

    @Test func iPhonePortraitShrinksTheStreamToAboutAFifth() throws {
        let scale = try #require(DisplayMode.device.serverScale(remote: mac, viewPixels: CGSize(width: 1179, height: 2556)))
        #expect(abs(scale - 1179.0 / 2560.0) < 1e-12)
        #expect(scale * scale < 0.22, "pixel count is under 22%")
    }

    @Test func neverAsksTheServerToEnlarge() {
        // Device larger than the Mac (12.9-inch iPad Pro with a 1920x1080 Mac): stays at 1, let the client zoom itself.
        #expect(DisplayMode.device.serverScale(remote: CGSize(width: 1920, height: 1080), viewPixels: CGSize(width: 2732, height: 2048)) == 1)
    }

    @Test func otherModesDoNotUseServerScaling() {
        for mode in [DisplayMode.fit, .fill, .native] {
            #expect(mode.serverScale(remote: mac, viewPixels: CGSize(width: 1000, height: 800)) == nil)
        }
        #expect(DisplayMode.device.serverScale(remote: .zero, viewPixels: CGSize(width: 1, height: 1)) == nil)
    }

    @Test func deviceModeDisplaysTheScaledImageWithFit() {
        #expect(DisplayMode.device.scaleMode(screenScale: 2) == .fit)
    }
}

@Suite("ViewportGeometry: system insets")
struct ViewportInsetTests {
    private let mac = CGSize(width: 2048, height: 1152)
    // A landscape iPhone with a Dynamic Island and a home indicator.
    private let phone = CGSize(width: 852, height: 393)
    private let phoneInsets = ViewportInsets(top: 0, left: 59, bottom: 21, right: 59)

    @Test func fitKeepsTheWholeScreenInsideTheInsets() {
        var geometry = ViewportGeometry(remoteSize: mac, viewSize: phone)
        geometry.updateInsets(phoneInsets)
        let rect = geometry.contentRect
        // Safe area 734×372: height-limited, scale 372/1152.
        #expect(close(geometry.scale, 372.0 / 1152))
        #expect(close(rect.minY, 0))
        #expect(close(rect.maxY, 372))
        #expect(rect.minX >= 59 && rect.maxX <= 852 - 59)
        #expect(close(rect.midX, 426)) // centred between equal side insets
    }

    @Test func fitIgnoresDragsWhenItFits() {
        var geometry = ViewportGeometry(remoteSize: mac, viewSize: phone)
        geometry.updateInsets(phoneInsets)
        let before = geometry.contentRect
        geometry.pan(by: CGPoint(x: 300, y: 300))
        #expect(close(geometry.contentRect, before))
    }

    @Test func fillCanBeDraggedSoCoveredEdgesComeIntoView() {
        var geometry = ViewportGeometry(remoteSize: mac, viewSize: phone, scaleMode: .fill)
        geometry.updateInsets(phoneInsets)
        // Fill still covers the whole device screen at rest.
        #expect(close(geometry.contentRect.width, 852))
        #expect(close(geometry.contentRect.minX, 0))
        // Dragging right moves the Mac's left edge out from under the Dynamic Island, and no further.
        geometry.pan(by: CGPoint(x: 100_000, y: 0))
        #expect(close(geometry.contentRect.minX, 59))
        // Dragging up brings the Mac's bottom edge (the Dock) above the home indicator.
        geometry.pan(by: CGPoint(x: 0, y: -100_000))
        #expect(close(geometry.contentRect.maxY, 393 - 21))
        // Dragging back responds at once, with no dead zone left over from the earlier overshoot.
        geometry.pan(by: CGPoint(x: -10, y: 0))
        #expect(close(geometry.contentRect.minX, 49))
    }

    @Test func zeroInsetsBehaveAsBefore() {
        var geometry = ViewportGeometry(remoteSize: mac, viewSize: CGSize(width: 390, height: 844), scaleMode: .fill)
        geometry.updateInsets(.zero)
        geometry.pan(by: CGPoint(x: -100_000, y: 0))
        #expect(close(geometry.contentRect.maxX, 390))
    }

    /// The view has size 0 before its first layout; the native-pixels mode computes the geometry right then (app launch).
    @Test(arguments: [ViewportGeometry.ScaleMode.fit, .fill, .pixelPerfect(screenScale: 3), .points])
    func aViewNotLaidOutYetDoesNotHang(mode: ViewportGeometry.ScaleMode) {
        var geometry = ViewportGeometry(remoteSize: CGSize(width: 800, height: 600), viewSize: .zero, scaleMode: mode)
        _ = geometry.contentRect
        geometry.updateInsets(ViewportInsets(top: 10, left: 0, bottom: 10, right: 0))
        _ = geometry.contentRect
        geometry.pan(by: CGPoint(x: 5, y: 5))
        _ = geometry.normalizedDeviceRect
        geometry.updateViewSize(CGSize(width: 390, height: 844))
        #expect(geometry.contentRect.width > 0)
    }

    @Test func insetsThatCoverEverythingAreIgnored() {
        var geometry = ViewportGeometry(remoteSize: mac, viewSize: CGSize(width: 100, height: 100))
        geometry.updateInsets(ViewportInsets(top: 60, left: 60, bottom: 60, right: 60))
        #expect(close(geometry.contentRect.width, 100))
    }

    @Test func touchesMapThroughTheInsetLayout() {
        var geometry = ViewportGeometry(remoteSize: mac, viewSize: phone)
        geometry.updateInsets(phoneInsets)
        let rect = geometry.contentRect
        let pixel = geometry.remotePixel(forView: CGPoint(x: rect.minX + 0.1, y: rect.minY + 0.1), clamped: false)
        #expect(pixel?.x == 0 && pixel?.y == 0) // the Mac's top-left corner (Apple menu) is reachable
        #expect(geometry.remotePixel(forView: CGPoint(x: 10, y: 10), clamped: false) == nil) // under the island: not the Mac
    }
}

@Suite("ViewportInsets: rounded display corners")
struct RoundedCornerInsetTests {
    private let pad = CGSize(width: 1180, height: 820)

    @Test func wideMacOnALandscapeIPadGrowsTopAndBottom() {
        // 16:10 Mac on a 1.44 iPad: the picture is letterboxed top and bottom, so growing those insets costs nothing.
        let insets = ViewportInsets.zero.avoidingRoundedCorners(radius: 18, edges: .all, viewSize: pad, contentAspect: 1.6)
        #expect(insets == ViewportInsets(top: 18, left: 0, bottom: 18, right: 0))
    }

    @Test func tallContentGrowsTheSides() {
        let insets = ViewportInsets.zero.avoidingRoundedCorners(radius: 18, edges: .all, viewSize: pad, contentAspect: 1.2)
        #expect(insets == ViewportInsets(top: 0, left: 18, bottom: 0, right: 18))
    }

    @Test func aCornerAlreadyClearedBySafeAreaIsLeftAlone() {
        // Portrait iPhone: the Dynamic Island inset clears the top corners; only the bottom ones need room.
        let safe = ViewportInsets(top: 59, left: 0, bottom: 34, right: 0)
        let insets = safe.avoidingRoundedCorners(radius: 47, edges: .all, viewSize: CGSize(width: 393, height: 852), contentAspect: 1.6)
        #expect(insets == ViewportInsets(top: 59, left: 0, bottom: 47, right: 0))
    }

    @Test func onlyCornersOnTheDisplayAreRounded() {
        // The sidebar sits on the left: the view's left edge is inside the display, so only the right-hand corners are rounded.
        let insets = ViewportInsets.zero.avoidingRoundedCorners(
            radius: 18, edges: [.top, .bottom, .right], viewSize: CGSize(width: 1100, height: 820), contentAspect: 1.2)
        #expect(insets == ViewportInsets(top: 0, left: 0, bottom: 0, right: 18))
    }

    @Test func noRadiusChangesNothing() {
        let safe = ViewportInsets(top: 24, left: 0, bottom: 20, right: 0)
        #expect(safe.avoidingRoundedCorners(radius: 0, edges: .all, viewSize: pad, contentAspect: 1.6) == safe)
    }
}
