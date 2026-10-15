import CoreGraphics
import Foundation
import RFBKit
import Testing
@testable import RemoteDisplay

@Suite("CursorPlacement: vị trí và kích thước con trỏ")
struct CursorPlacementTests {
    /// Con trỏ 10×20, điểm nóng ở (2, 3).
    private let cursor = CursorImage(
        width: 10, height: 20, hotspotX: 2, hotspotY: 3, bgra: [UInt8](repeating: 255, count: 10 * 20 * 4)
    )!

    /// Màn hình Mac 1000×500 vào khung nhìn 500×250: tỉ lệ 0,5 point/pixel.
    private func geometry(zoom: Double = 1) -> ViewportGeometry {
        var geometry = ViewportGeometry(remoteSize: CGSize(width: 1000, height: 500), viewSize: CGSize(width: 500, height: 250))
        if zoom != 1 { geometry.setZoom(zoom, around: CGPoint(x: 250, y: 125)) }
        return geometry
    }

    @Test func smallScreenScaleIsRaisedSoTheCursorStaysVisible() {
        // Tỉ lệ thật 0,5 point/pixel: con trỏ cao 20 pixel chỉ còn 10 point. Nâng lên tối thiểu 20 point = 1 point/pixel.
        #expect(CursorPlacement.pointsPerCursorPixel(for: cursor, geometry: geometry()) == 1)
    }

    @Test func hugeZoomIsCappedSoTheCursorDoesNotCoverTheScreen() {
        // Phóng 16 lần: tỉ lệ thật 8 point/pixel, nhưng con trỏ kẹp ở 48 point cho cạnh dài (20 pixel) = 2,4 point/pixel.
        #expect(CursorPlacement.pointsPerCursorPixel(for: cursor, geometry: geometry(zoom: 16)) == 2.4)
    }

    @Test func midRangeScaleIsKeptTrue() {
        // 1,5 point/pixel → cao 30 point, nằm trong 20...48 nên giữ nguyên tỉ lệ thật.
        var geometry = ViewportGeometry(remoteSize: CGSize(width: 1000, height: 500), viewSize: CGSize(width: 1500, height: 750))
        geometry.reset()
        #expect(CursorPlacement.pointsPerCursorPixel(for: cursor, geometry: geometry) == 1.5)
    }

    @Test func hotspotLandsOnTheCentreOfThePointerPixel() {
        let geometry = geometry()
        let rect = CursorPlacement.viewRect(for: cursor, pointer: (400, 200), geometry: geometry)
        // Pixel Mac (400, 200) có tâm (400,5; 200,5) → khung nhìn (200,25; 100,25). Trừ điểm nóng (2, 3) × 1 point/pixel.
        #expect(abs(rect.minX - 198.25) < 1e-9)
        #expect(abs(rect.minY - 97.25) < 1e-9)
        #expect(rect.width == 10 && rect.height == 20)
        // Kiểm lại: điểm nóng trong hình chữ nhật trùng với tâm pixel.
        let hotspot = CGPoint(x: rect.minX + 2, y: rect.minY + 3)
        let expected = geometry.viewPoint(forRemote: CGPoint(x: 400.5, y: 200.5))
        #expect(abs(hotspot.x - expected.x) < 1e-9 && abs(hotspot.y - expected.y) < 1e-9)
    }

    @Test func letterboxOffsetIsRespected() {
        // Khung nhìn cao hơn nội dung nên có viền: nội dung bắt đầu tại y = 50.
        let geometry = ViewportGeometry(remoteSize: CGSize(width: 1000, height: 500), viewSize: CGSize(width: 500, height: 350))
        let rect = CursorPlacement.viewRect(for: cursor, pointer: (0, 0), geometry: geometry)
        #expect(abs((rect.minY + 3) - (50 + 0.25)) < 1e-9)
    }

    @Test func normalizedRectMatchesTheScreenRectConvention() {
        // Toàn khung nhìn phải ra (-1, -1, 1, 1), giống `normalizedDeviceRect` của màn hình.
        let full = CursorPlacement.normalizedDeviceRect(viewRect: CGRect(x: 0, y: 0, width: 500, height: 250), viewSize: CGSize(width: 500, height: 250))
        #expect(full == SIMD4<Float>(-1, -1, 1, 1))
        // Nửa trên của khung nhìn: dưới = 0, trên = 1.
        let top = CursorPlacement.normalizedDeviceRect(viewRect: CGRect(x: 0, y: 0, width: 500, height: 125), viewSize: CGSize(width: 500, height: 250))
        #expect(top == SIMD4<Float>(-1, 0, 1, 1))
        #expect(geometry().normalizedDeviceRect == SIMD4<Float>(-1, -1, 1, 1))
    }
}
