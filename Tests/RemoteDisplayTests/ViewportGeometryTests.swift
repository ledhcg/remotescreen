import CoreGraphics
import Foundation
import Testing
@testable import RemoteDisplay

/// So sánh số thực với sai số nhỏ.
private func close(_ a: Double, _ b: Double, _ tolerance: Double = 1e-9) -> Bool { abs(a - b) <= tolerance }
private func close(_ a: CGRect, _ b: CGRect, _ tolerance: Double = 1e-9) -> Bool {
    close(a.minX, b.minX, tolerance) && close(a.minY, b.minY, tolerance) &&
        close(a.width, b.width, tolerance) && close(a.height, b.height, tolerance)
}

@Suite("ViewportGeometry: tỉ lệ và vị trí")
struct ViewportScaleTests {
    // Màn hình Mac thật của máy này và khung nhìn kiểu iPhone dọc.
    private let mac = CGSize(width: 2048, height: 1152)

    @Test func fitLetterboxesPortraitPhone() {
        let geometry = ViewportGeometry(remoteSize: mac, viewSize: CGSize(width: 390, height: 844))
        // scale = min(390/2048, 844/1152) = 390/2048. Chiều cao nội dung = 1152 * 390/2048 = 219.375, căn giữa theo y.
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
        #expect(close(rect.midX, 195)) // căn giữa theo trục tràn
        geometry.pan(by: CGPoint(x: 100_000, y: 0)) // kéo hết cỡ sang phải
        #expect(close(geometry.contentRect.minX, 0)) // mép trái nội dung chạm mép trái khung nhìn
    }

    @Test func pixelPerfectMapsOneRemotePixelToOneDevicePixel() {
        let geometry = ViewportGeometry(remoteSize: mac, viewSize: CGSize(width: 1024, height: 768), scaleMode: .pixelPerfect(screenScale: 2))
        #expect(close(geometry.scale, 0.5)) // 1 pixel Mac = 0,5 point = 1 pixel thiết bị khi màn hình 2x
        #expect(close(geometry.contentRect.width, 1024))
    }

    @Test func degenerateSizesDoNotProduceNonsense() {
        let geometry = ViewportGeometry(remoteSize: .zero, viewSize: CGSize(width: 100, height: 100))
        #expect(geometry.scale == 1)
        #expect(geometry.remotePixel(forView: CGPoint(x: 5, y: 5), clamped: true) == nil)
    }
}

@Suite("ViewportGeometry: đổi tọa độ")
struct ViewportMappingTests {
    private let geometry = ViewportGeometry(remoteSize: CGSize(width: 2000, height: 1000), viewSize: CGSize(width: 1000, height: 600))
    // scale 0,5; nội dung 1000×500 nằm ở y = 50...550

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
        let inBlackBar = CGPoint(x: 500, y: 20) // phía trên nội dung
        #expect(geometry.remotePixel(forView: inBlackBar, clamped: false) == nil)
        let clamped = geometry.remotePixel(forView: inBlackBar, clamped: true)
        #expect(clamped?.y == 0) // kẹp vào mép trên
        #expect(clamped?.x == 1000)
    }

    @Test func offScreenPointsClampToTheLastPixel() {
        let far = geometry.remotePixel(forView: CGPoint(x: 5000, y: 5000), clamped: true)
        #expect(far?.x == 1999)
        #expect(far?.y == 999)
    }
}

@Suite("ViewportGeometry: phóng và kéo")
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
        #expect(close(geometry.contentRect, make().contentRect)) // về lại đúng vị trí ban đầu
    }

    @Test func panCannotRevealEmptySpaceBeyondTheEdges() {
        var geometry = make()
        geometry.zoom(by: 4, around: CGPoint(x: 500, y: 300)) // nội dung 4000×2000 trong khung 1000×600

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
        #expect(rect.minX <= 0 && rect.maxX >= 600) // vẫn phủ kín khung nhìn mới theo chiều ngang
        #expect(rect.minY <= 0 && rect.maxY >= 1000 || rect.height < 1000) // và không lộ khoảng trống nếu nội dung đủ lớn
    }

    @Test func normalizedRectFlipsTheYAxisForMetal() {
        let geometry = make() // nội dung ở y = 50...550 trong khung cao 600
        let rect = geometry.normalizedDeviceRect
        #expect(abs(rect.x - -1) < 1e-6 && abs(rect.z - 1) < 1e-6)
        // Trục y của khung nhìn hướng xuống, của Metal hướng lên: mép trên (y=50) → 1 - 2*50/600, mép dưới (y=550) → 1 - 2*550/600.
        #expect(abs(rect.w - Float(1 - 100.0 / 600)) < 1e-6)
        #expect(abs(rect.y - Float(1 - 1100.0 / 600)) < 1e-6)
        #expect(rect.w > rect.y) // trên > dưới
    }
}

@Suite("DisplayMode: vừa, lấp đầy, điểm ảnh gốc")
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
        #expect(abs(rect.width - iPadLandscape.width) < 0.001, "chạm hai mép theo chiều ngang")
    }

    @Test func fillCoversTheWholeViewWithNoBlackBars() {
        let rect = geometry(.fill, view: iPadLandscape).contentRect
        #expect(rect.minX <= 0 && rect.minY <= 0)
        #expect(rect.maxX >= iPadLandscape.width && rect.maxY >= iPadLandscape.height)
    }

    @Test func nativeMapsOneMacPixelToOneDevicePixel() {
        let g = geometry(.native, view: iPadLandscape, scale: 2)
        #expect(g.scale == 0.5, "0,5 point mỗi pixel Mac = 1 pixel thiết bị trên màn hình 2x")
        #expect(g.contentRect.width == 1280, "2560 pixel Mac = 2560 pixel iPad = 1280 point")
        let iPhone = geometry(.native, view: CGSize(width: 393, height: 852), scale: 3)
        #expect(abs(iPhone.scale - 1.0 / 3) < 1e-12)
    }

    /// "Tự thích ứng": xoay iPad thì chế độ vừa màn hình tính lại tỉ lệ từ cỡ mới, vẫn thấy toàn bộ màn hình Mac.
    @Test func rotatingRecomputesTheScaleForTheNewSize() {
        var g = geometry(.fit, view: iPadLandscape)
        let landscapeScale = g.scale
        g.updateViewSize(iPadPortrait)
        #expect(g.scale < landscapeScale, "dọc thì hẹp hơn nên thu nhỏ hơn")
        let rect = g.contentRect
        #expect(abs(rect.width - iPadPortrait.width) < 0.001)
        #expect(rect.minY > 0, "dọc thì có viền đen trên dưới, màn hình Mac nằm giữa")
    }

    @Test func nativeScaleDoesNotChangeWhenRotating() {
        var g = geometry(.native, view: iPadLandscape)
        g.updateViewSize(iPadPortrait)
        #expect(g.scale == 0.5, "điểm ảnh gốc không phụ thuộc cỡ khung nhìn")
    }

    @Test func modesRoundTripThroughTheirStoredName() {
        for mode in DisplayMode.allCases { #expect(DisplayMode(rawValue: mode.rawValue) == mode) }
        #expect(DisplayMode(rawValue: "lạ") == nil)
        #expect(DisplayMode.default == .fit)
    }
}

@Suite("DisplayMode.device: thu nhỏ phía server theo độ phân giải thiết bị")
struct DeviceDisplayModeTests {
    private let mac = CGSize(width: 2560, height: 1440)

    @Test func iPadAir4LandscapeAsksForTheWidthRatio() throws {
        // 1180x820 point x2 = 2360x1640 pixel. Chiều ngang hẹp hơn: 2360/2560 = 0,921875.
        let scale = try #require(DisplayMode.device.serverScale(remote: mac, viewPixels: CGSize(width: 2360, height: 1640)))
        #expect(scale == 2360.0 / 2560.0)
    }

    @Test func iPhonePortraitShrinksTheStreamToAboutAFifth() throws {
        let scale = try #require(DisplayMode.device.serverScale(remote: mac, viewPixels: CGSize(width: 1179, height: 2556)))
        #expect(abs(scale - 1179.0 / 2560.0) < 1e-12)
        #expect(scale * scale < 0.22, "số pixel còn chưa tới 22%")
    }

    @Test func neverAsksTheServerToEnlarge() {
        // Thiết bị lớn hơn Mac (iPad Pro 12,9 inch với Mac 1920x1080): giữ nguyên 1, để client tự phóng.
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
