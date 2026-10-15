import CoreGraphics
import Foundation

/// Hình chữ nhật theo pixel, gốc tọa độ ở góc trên trái.
public struct PixelRect: Equatable, Hashable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var isEmpty: Bool { width <= 0 || height <= 0 }
}

/// Bộ đệm khung hình phía client: 4 byte mỗi pixel theo thứ tự B, G, R, X trong bộ nhớ
/// (`PixelFormat.bgra8888`), hàng liên tiếp không đệm.
public struct Framebuffer: Sendable {
    public static let bytesPerPixel = 4

    public private(set) var width: Int
    public private(set) var height: Int
    public private(set) var pixels: [UInt8]

    /// Trần kích thước mỗi chiều. Màn hình thật không vượt 16384 pixel, và trần này chặn server
    /// ép client cấp phát vài GB bằng một `DesktopSize` vô lý.
    public static let maxDimension = 16_384
    /// Trần tổng số pixel (32 triệu điểm, 128 MB bộ nhớ khung): đủ cho màn hình 8K (33,2 triệu) nhưng chặn 16384x16384 (1 GB một lần cấp phát),
    /// thứ một server độc hại có thể ép lặp lại với mỗi `DesktopSize`.
    public static let maxPixelCount = 32 << 20 // 8K (7680x4320) = 33,2 triệu điểm ảnh

    public init(width: Int, height: Int) throws {
        guard (1...Self.maxDimension).contains(width), (1...Self.maxDimension).contains(height),
              width * height <= Self.maxPixelCount else {
            throw RFBError.malformed("kích thước framebuffer \(width)x\(height) không hợp lệ")
        }
        self.width = width
        self.height = height
        pixels = [UInt8](repeating: 0, count: width * height * Self.bytesPerPixel)
    }

    public var bounds: PixelRect { PixelRect(x: 0, y: 0, width: width, height: height) }

    /// `true` nếu `rect` nằm hoàn toàn trong framebuffer và có diện tích dương.
    public func contains(_ rect: PixelRect) -> Bool {
        !rect.isEmpty && rect.x >= 0 && rect.y >= 0 && rect.x + rect.width <= width && rect.y + rect.height <= height
    }

    private func offset(x: Int, y: Int) -> Int { (y * width + x) * Self.bytesPerPixel }

    /// Ghi pixel BGRA liên tiếp theo từng hàng của `rect`.
    public mutating func write(_ rect: PixelRect, bgra source: Data) throws {
        try source.withUnsafeBytes { try write(rect, bytes: $0) }
    }

    public mutating func write(_ rect: PixelRect, bgra source: [UInt8]) throws {
        try source.withUnsafeBytes { try write(rect, bytes: $0) }
    }

    /// Ghi pixel RGB565 little-endian (Raw 16 bit) vào `rect`, mở rộng mỗi pixel thành BGRA 8 bit. Kênh 5 và 6 bit được mở rộng
    /// bằng cách lặp các bit cao xuống bit thấp (31 → 255, 63 → 255), để trắng vẫn là trắng.
    mutating func writeRGB565(_ rect: PixelRect, source: Data) throws {
        guard contains(rect) else { throw RFBError.malformed("hình chữ nhật \(rect) nằm ngoài framebuffer \(width)x\(height)") }
        guard source.count == rect.width * rect.height * 2 else {
            throw RFBError.malformed("dữ liệu \(source.count) byte không khớp hình chữ nhật \(rect) ở 16 bit")
        }
        let stride = width * Self.bytesPerPixel
        let first = offset(x: rect.x, y: rect.y)
        source.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
            pixels.withUnsafeMutableBytes { output in
                guard let inBase = input.baseAddress, let outBase = output.baseAddress else { return }
                for row in 0..<rect.height {
                    let line = outBase + first + row * stride
                    let src = inBase + row * rect.width * 2
                    for x in 0..<rect.width {
                        let value = UInt32(src.load(fromByteOffset: x * 2, as: UInt8.self)) | UInt32(src.load(fromByteOffset: x * 2 + 1, as: UInt8.self)) << 8
                        line.storeBytes(of: PixelConversion.bgra(fromRGB565: value), toByteOffset: x * 4, as: UInt32.self)
                    }
                }
            }
        }
    }

    /// Lõi ghi: sao chép từng hàng bằng `memcpy`, không cấp phát thêm.
    mutating func write(_ rect: PixelRect, bytes source: UnsafeRawBufferPointer) throws {
        guard contains(rect) else { throw RFBError.malformed("hình chữ nhật \(rect) nằm ngoài framebuffer \(width)x\(height)") }
        let rowBytes = rect.width * Self.bytesPerPixel
        guard source.count == rowBytes * rect.height, let sourceBase = source.baseAddress else {
            throw RFBError.malformed("dữ liệu \(source.count) byte không khớp hình chữ nhật \(rect)")
        }
        let stride = width * Self.bytesPerPixel
        let firstOffset = offset(x: rect.x, y: rect.y)
        pixels.withUnsafeMutableBytes { destination in
            guard let destinationBase = destination.baseAddress else { return }
            for row in 0..<rect.height {
                (destinationBase + firstOffset + row * stride)
                    .copyMemory(from: sourceBase + row * rowBytes, byteCount: rowBytes)
            }
        }
    }

    /// Truy cập thô vào bộ nhớ pixel để bộ giải mã ghi trực tiếp, không qua trung gian. Người gọi tự chịu trách nhiệm
    /// giữ mọi lần ghi trong `bounds` (xem `ZRLEDecoder`). Gọi một lần cho cả hình chữ nhật, vì mỗi lần gọi kiểm tra copy-on-write.
    mutating func withUnsafeMutablePixelBytes<R>(_ body: (UnsafeMutableRawBufferPointer) throws -> R) rethrows -> R {
        try pixels.withUnsafeMutableBytes(body)
    }

    /// Kết quả so sánh hai framebuffer cùng kích thước.
    public struct Difference: Equatable, Sendable {
        /// Số pixel khác nhau (chỉ so các kênh B, G, R, bỏ byte đệm).
        public var count: Int
        /// Hình chữ nhật nhỏ nhất chứa mọi pixel khác nhau, `nil` nếu giống hệt.
        public var bounds: PixelRect?
    }

    /// Một ô lưới có pixel khác nhau.
    public struct DifferenceCell: Equatable, Sendable {
        /// Vùng của ô, đã cắt theo mép framebuffer.
        public var rect: PixelRect
        public var count: Int
    }

    /// Chia framebuffer thành lưới ô vuông `cellSize` và đếm pixel khác nhau trong từng ô, ô nhiều nhất trước.
    /// Chỉ trả các ô có khác biệt. Trả `nil` nếu kích thước khác nhau. Dùng để xem khác biệt nằm ở đâu.
    public func differenceCells(from other: Framebuffer, cellSize: Int = 128) -> [DifferenceCell]? {
        guard width == other.width, height == other.height, cellSize > 0 else { return nil }
        let columns = (width + cellSize - 1) / cellSize
        let rows = (height + cellSize - 1) / cellSize
        var counts = [Int](repeating: 0, count: columns * rows)
        pixels.withUnsafeBytes { lhs in
            other.pixels.withUnsafeBytes { rhs in
                for y in 0..<height {
                    for x in 0..<width {
                        let index = (y * width + x) * Self.bytesPerPixel
                        if lhs[index] != rhs[index] || lhs[index + 1] != rhs[index + 1] || lhs[index + 2] != rhs[index + 2] {
                            counts[(y / cellSize) * columns + x / cellSize] += 1
                        }
                    }
                }
            }
        }
        return counts.enumerated()
            .filter { $0.element > 0 }
            .map { entry in
                let x = (entry.offset % columns) * cellSize
                let y = (entry.offset / columns) * cellSize
                let rect = PixelRect(x: x, y: y, width: min(cellSize, width - x), height: min(cellSize, height - y))
                return DifferenceCell(rect: rect, count: entry.element)
            }
            .sorted { $0.count > $1.count }
    }

    /// So sánh với `other`. Trả `nil` nếu kích thước khác nhau.
    public func difference(from other: Framebuffer) -> Difference? {
        guard width == other.width, height == other.height else { return nil }
        var count = 0
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        pixels.withUnsafeBytes { lhs in
            other.pixels.withUnsafeBytes { rhs in
                for y in 0..<height {
                    for x in 0..<width {
                        let index = (y * width + x) * Self.bytesPerPixel
                        if lhs[index] != rhs[index] || lhs[index + 1] != rhs[index + 1] || lhs[index + 2] != rhs[index + 2] {
                            count += 1
                            minX = min(minX, x); maxX = max(maxX, x)
                            minY = min(minY, y); maxY = max(maxY, y)
                        }
                    }
                }
            }
        }
        let bounds = count == 0 ? nil : PixelRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        return Difference(count: count, bounds: bounds)
    }

    /// Sao chép một vùng sang vị trí mới trong cùng framebuffer (CopyRect).
    /// Vùng nguồn và đích được phép chồng lên nhau, kết quả như thể nguồn được chụp trước khi ghi.
    public mutating func copy(from source: PixelRect, toX x: Int, y: Int) throws {
        let destination = PixelRect(x: x, y: y, width: source.width, height: source.height)
        guard contains(source), contains(destination) else {
            throw RFBError.malformed("CopyRect \(source) → (\(x), \(y)) nằm ngoài framebuffer \(width)x\(height)")
        }
        let rowBytes = source.width * Self.bytesPerPixel
        let stride = width * Self.bytesPerPixel
        // Sao chép từng hàng bằng memmove (an toàn khi nguồn và đích chồng nhau trong một hàng). Khi vùng đích nằm DƯỚI vùng nguồn
        // thì đi từ hàng cuối lên, để không ghi đè hàng nguồn chưa chép. Không cấp phát bản sao như cách cũ.
        let rows = Array(0..<source.height)
        let order = y > source.y ? rows.reversed() : rows
        pixels.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            for row in order {
                let from = (source.y + row) * stride + source.x * Self.bytesPerPixel
                let to = (y + row) * stride + x * Self.bytesPerPixel
                memmove(base + to, base + from, rowBytes)
            }
        }
    }

    /// Màu của một pixel dưới dạng `(r, g, b)`, phục vụ test và gỡ lỗi.
    public func rgb(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8)? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        let index = offset(x: x, y: y)
        return (pixels[index + 2], pixels[index + 1], pixels[index])
    }

    /// Ảnh sRGB để lưu hoặc hiển thị. Byte thứ tư của mỗi pixel là phần đệm, không phải độ trong suốt.
    public func makeCGImage() -> CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * Self.bytesPerPixel, space: colorSpace, bitmapInfo: info,
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }
}

/// Đổi màu giữa các định dạng. Một chỗ duy nhất, để Raw và ZRLE cho cùng một kết quả.
enum PixelConversion {
    /// RGB565 → `B | G << 8 | R << 16` (byte thứ tư 0). Mở rộng bằng cách lặp bit cao: 31 → 255, 63 → 255.
    /// Dải RGB565 little-endian → dải BGRA 4 byte mỗi pixel (byte thứ tư 0).
    static func bgra(fromRGB565Bytes data: Data) -> Data {
        var output = Data(count: data.count / 2 * 4)
        data.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { out in
                for index in 0..<(data.count / 2) {
                    let value = UInt32(input[index * 2]) | UInt32(input[index * 2 + 1]) << 8
                    out.storeBytes(of: bgra(fromRGB565: value), toByteOffset: index * 4, as: UInt32.self)
                }
            }
        }
        return output
    }

    @inline(__always)
    static func bgra(fromRGB565 value: UInt32) -> UInt32 {
        let r = (value >> 11) & 0x1F
        let g = (value >> 5) & 0x3F
        let b = value & 0x1F
        return ((b << 3) | (b >> 2)) | (((g << 2) | (g >> 4)) << 8) | (((r << 3) | (r >> 2)) << 16)
    }
}
