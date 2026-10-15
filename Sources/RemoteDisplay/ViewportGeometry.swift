import CoreGraphics
import Foundation
import InputKit

/// Cách đặt màn hình từ xa vào khung nhìn: phóng to thu nhỏ, kéo và đổi tọa độ.
///
/// Thuần toán học, không phụ thuộc UIKit hay Metal, nên test được trên macOS.
/// Đơn vị của khung nhìn là **point** (gốc ở góc trên trái, y hướng xuống). Đơn vị của màn hình từ xa là pixel của Mac.
public struct ViewportGeometry: Equatable, Sendable {
    public enum ScaleMode: Equatable, Sendable {
        /// Vừa khít khung nhìn, giữ tỉ lệ, có viền đen nếu lệch tỉ lệ.
        case fit
        /// Lấp đầy khung nhìn, giữ tỉ lệ, cắt phần thừa.
        case fill
        /// 1 pixel Mac bằng 1 pixel thiết bị (`screenScale` là số pixel thiết bị trên mỗi point).
        case pixelPerfect(screenScale: Double)
        /// 1 pixel Mac bằng 1 point.
        case points
    }

    /// Mức phóng người dùng được phép, tính trên tỉ lệ cơ sở của `scaleMode`.
    public static let zoomRange: ClosedRange<Double> = 1...16

    public var remoteSize: CGSize
    public var viewSize: CGSize
    public var scaleMode: ScaleMode
    public private(set) var zoom: Double = 1
    /// Độ lệch của màn hình so với vị trí chính giữa, tính theo point. Luôn được kẹp trong `contentRect`.
    public private(set) var pan: CGPoint = .zero

    public init(remoteSize: CGSize, viewSize: CGSize, scaleMode: ScaleMode = .fit) {
        self.remoteSize = remoteSize
        self.viewSize = viewSize
        self.scaleMode = scaleMode
    }

    // MARK: - Tỉ lệ và hình chữ nhật hiển thị

    private var isDegenerate: Bool {
        remoteSize.width <= 0 || remoteSize.height <= 0 || viewSize.width <= 0 || viewSize.height <= 0
    }

    /// Số point trên mỗi pixel Mac khi `zoom == 1`.
    public var baseScale: Double {
        guard !isDegenerate else { return 1 }
        let widthRatio = viewSize.width / remoteSize.width
        let heightRatio = viewSize.height / remoteSize.height
        switch scaleMode {
        case .fit: return min(widthRatio, heightRatio)
        case .fill: return max(widthRatio, heightRatio)
        case .pixelPerfect(let screenScale): return screenScale > 0 ? 1 / screenScale : 1
        case .points: return 1
        }
    }

    /// Số point trên mỗi pixel Mac sau khi phóng.
    public var scale: Double { baseScale * zoom }

    /// Hình chữ nhật mà màn hình từ xa chiếm trong khung nhìn (có thể lớn hơn khung nhìn khi đã phóng).
    public var contentRect: CGRect {
        let size = CGSize(width: remoteSize.width * scale, height: remoteSize.height * scale)
        let centered = CGPoint(x: (viewSize.width - size.width) / 2, y: (viewSize.height - size.height) / 2)
        let offset = Self.clamp(pan, content: size, view: viewSize)
        return CGRect(origin: CGPoint(x: centered.x + offset.x, y: centered.y + offset.y), size: size)
    }

    /// Kẹp độ lệch: nếu màn hình nhỏ hơn khung nhìn theo một trục thì giữ ở giữa trục đó, nếu lớn hơn thì
    /// không cho kéo lộ khoảng trống ngoài mép.
    private static func clamp(_ pan: CGPoint, content: CGSize, view: CGSize) -> CGPoint {
        func axis(_ value: Double, content: Double, view: Double) -> Double {
            let overflow = content - view
            guard overflow > 0 else { return 0 }
            return min(max(value, -overflow / 2), overflow / 2)
        }
        return CGPoint(x: axis(pan.x, content: content.width, view: view.width),
                       y: axis(pan.y, content: content.height, view: view.height))
    }

    // MARK: - Thao tác

    /// Kéo nội dung theo `delta` (point).
    public mutating func pan(by delta: CGPoint) {
        pan = CGPoint(x: contentOffset.x + delta.x, y: contentOffset.y + delta.y)
        normalisePan()
    }

    /// Đặt mức phóng tuyệt đối, giữ điểm `focus` (trong khung nhìn) đứng yên trên màn hình từ xa.
    public mutating func setZoom(_ value: Double, around focus: CGPoint) {
        let anchor = remotePoint(forView: focus)
        zoom = min(max(value, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)

        let size = CGSize(width: remoteSize.width * scale, height: remoteSize.height * scale)
        let centered = CGPoint(x: (viewSize.width - size.width) / 2, y: (viewSize.height - size.height) / 2)
        let desiredOrigin = CGPoint(x: focus.x - anchor.x * scale, y: focus.y - anchor.y * scale)
        pan = CGPoint(x: desiredOrigin.x - centered.x, y: desiredOrigin.y - centered.y)
        normalisePan()
    }

    /// Nhân mức phóng với `factor` (dùng cho cử chỉ chụm), giữ `focus` đứng yên.
    public mutating func zoom(by factor: Double, around focus: CGPoint) {
        setZoom(zoom * factor, around: focus)
    }

    /// Về mức phóng cơ sở và căn giữa.
    public mutating func reset() {
        zoom = 1
        pan = .zero
    }

    /// Cập nhật kích thước khung nhìn (xoay máy, đổi cửa sổ), giữ pan hợp lệ.
    public mutating func updateViewSize(_ size: CGSize) {
        viewSize = size
        normalisePan()
    }

    /// Cập nhật kích thước màn hình từ xa (server đổi độ phân giải).
    public mutating func updateRemoteSize(_ size: CGSize) {
        remoteSize = size
        normalisePan()
    }

    private var contentOffset: CGPoint {
        let size = CGSize(width: remoteSize.width * scale, height: remoteSize.height * scale)
        return Self.clamp(pan, content: size, view: viewSize)
    }

    private mutating func normalisePan() {
        pan = contentOffset
    }

    // MARK: - Đổi tọa độ

    /// Điểm trong khung nhìn → điểm (thực) trên màn hình từ xa. Có thể nằm ngoài màn hình nếu chạm vào viền đen.
    public func remotePoint(forView point: CGPoint) -> CGPoint {
        let rect = contentRect
        let scale = self.scale
        return CGPoint(x: (point.x - rect.minX) / scale, y: (point.y - rect.minY) / scale)
    }

    /// Điểm trên màn hình từ xa → điểm trong khung nhìn.
    public func viewPoint(forRemote point: CGPoint) -> CGPoint {
        let rect = contentRect
        return CGPoint(x: rect.minX + point.x * scale, y: rect.minY + point.y * scale)
    }

    /// Pixel Mac dưới một điểm trong khung nhìn.
    /// - Parameter clamped: `true` kẹp vào mép màn hình khi điểm nằm ngoài (hợp với chế độ trackpad); `false` trả `nil`
    ///   khi điểm nằm ngoài (hợp với chạm trực tiếp, nơi chạm vào viền đen không nên điều khiển gì).
    public func remotePixel(forView point: CGPoint, clamped: Bool) -> (x: Int, y: Int)? {
        guard !isDegenerate else { return nil }
        let remote = remotePoint(forView: point)
        let x = Int(remote.x.rounded(.down))
        let y = Int(remote.y.rounded(.down))
        let maxX = Int(remoteSize.width) - 1
        let maxY = Int(remoteSize.height) - 1
        if (0...maxX).contains(x) && (0...maxY).contains(y) { return (x, y) }
        guard clamped else { return nil }
        return (min(max(x, 0), maxX), min(max(y, 0), maxY))
    }

    // MARK: - Cho GPU

    /// Hình chữ nhật của màn hình từ xa trong toạ độ chuẩn hóa của thiết bị (-1...1, trục y hướng LÊN):
    /// `(trái, dưới, phải, trên)`.
    public var normalizedDeviceRect: SIMD4<Float> {
        guard viewSize.width > 0, viewSize.height > 0 else { return SIMD4(-1, -1, 1, 1) }
        let rect = contentRect
        return SIMD4(
            Float(2 * rect.minX / viewSize.width - 1),
            Float(1 - 2 * rect.maxY / viewSize.height),
            Float(2 * rect.maxX / viewSize.width - 1),
            Float(1 - 2 * rect.minY / viewSize.height)
        )
    }
}

extension ViewportGeometry: RemoteCoordinateSpace {
    public var pointsPerRemotePixel: Double { scale }
}
