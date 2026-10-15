import CoreGraphics
import Foundation
import RFBKit

/// Đặt hình con trỏ của Mac lên khung nhìn: vị trí theo điểm nóng và kích thước dễ nhìn.
///
/// Thuần toán học, không phụ thuộc Metal, nên test được mà không cần GPU.
public enum CursorPlacement {
    /// Chiều lớn nhất của con trỏ khi hiển thị, tính bằng point, nằm trong khoảng này bất kể mức thu phóng.
    ///
    /// Nếu vẽ đúng tỉ lệ với màn hình Mac thì trên iPhone (Mac 2048 pixel thu vào ~390 point) một con trỏ 32 pixel chỉ
    /// còn khoảng 6 point, gần như vô hình, còn ở mức phóng 16 lần thì to hơn 500 point. Kẹp lại để lúc nào cũng thấy rõ
    /// mà không che mất nội dung.
    public static let displayPointRange: ClosedRange<Double> = 20...48

    /// Số point cho mỗi pixel của hình con trỏ.
    public static func pointsPerCursorPixel(for cursor: CursorImage, geometry: ViewportGeometry) -> Double {
        let longest = Double(max(cursor.width, cursor.height))
        guard longest > 0 else { return geometry.scale }
        return min(max(geometry.scale, displayPointRange.lowerBound / longest), displayPointRange.upperBound / longest)
    }

    /// Hình chữ nhật của con trỏ trong khung nhìn (point, gốc ở góc trên trái) khi con trỏ ở pixel `pointer` của Mac.
    /// Điểm nóng của hình trùng với tâm pixel đó.
    public static func viewRect(
        for cursor: CursorImage, pointer: (x: Int, y: Int), geometry: ViewportGeometry
    ) -> CGRect {
        let unit = pointsPerCursorPixel(for: cursor, geometry: geometry)
        let hotspotInView = geometry.viewPoint(forRemote: CGPoint(x: Double(pointer.x) + 0.5, y: Double(pointer.y) + 0.5))
        return CGRect(
            x: hotspotInView.x - Double(cursor.hotspotX) * unit,
            y: hotspotInView.y - Double(cursor.hotspotY) * unit,
            width: Double(cursor.width) * unit,
            height: Double(cursor.height) * unit
        )
    }

    /// Cùng hình chữ nhật đó trong toạ độ chuẩn hóa của thiết bị, `(trái, dưới, phải, trên)`, trục y hướng LÊN,
    /// đúng khuôn của `ViewportGeometry.normalizedDeviceRect`.
    public static func normalizedDeviceRect(viewRect rect: CGRect, viewSize: CGSize) -> SIMD4<Float> {
        guard viewSize.width > 0, viewSize.height > 0 else { return SIMD4(0, 0, 0, 0) }
        return SIMD4(
            Float(2 * rect.minX / viewSize.width - 1),
            Float(1 - 2 * rect.maxY / viewSize.height),
            Float(2 * rect.maxX / viewSize.width - 1),
            Float(1 - 2 * rect.minY / viewSize.height)
        )
    }
}
