import CoreGraphics
import Foundation

/// Rectangle in pixels, origin at the top-left corner.
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

/// Client-side framebuffer: 4 bytes per pixel in B, G, R, X memory order
/// (`PixelFormat.bgra8888`), rows stored contiguously with no padding.
public struct Framebuffer: Sendable {
    public static let bytesPerPixel = 4

    public private(set) var width: Int
    public private(set) var height: Int
    public private(set) var pixels: [UInt8]

    /// Per-dimension size cap. Real screens never exceed 16384 pixels, and this cap stops a server
    /// from forcing the client to allocate several GB with an absurd `DesktopSize`.
    public static let maxDimension = 16_384
    /// Total pixel cap (32 million pixels, 128 MB of framebuffer memory): enough for an 8K screen (33.2 million) but rejects 16384x16384 (a 1 GB allocation),
    /// which a malicious server could force again and again with each `DesktopSize`.
    public static let maxPixelCount = 32 << 20 // 8K (7680x4320) = 33.2 million pixels

    public init(width: Int, height: Int) throws {
        guard (1...Self.maxDimension).contains(width), (1...Self.maxDimension).contains(height),
              width * height <= Self.maxPixelCount else {
            throw RFBError.malformed("invalid framebuffer size \(width)x\(height)")
        }
        self.width = width
        self.height = height
        pixels = [UInt8](repeating: 0, count: width * height * Self.bytesPerPixel)
    }

    public var bounds: PixelRect { PixelRect(x: 0, y: 0, width: width, height: height) }

    /// `true` if `rect` lies entirely inside the framebuffer and has positive area.
    public func contains(_ rect: PixelRect) -> Bool {
        !rect.isEmpty && rect.x >= 0 && rect.y >= 0 && rect.x + rect.width <= width && rect.y + rect.height <= height
    }

    private func offset(x: Int, y: Int) -> Int { (y * width + x) * Self.bytesPerPixel }

    /// Writes consecutive BGRA pixels row by row into `rect`.
    public mutating func write(_ rect: PixelRect, bgra source: Data) throws {
        try source.withUnsafeBytes { try write(rect, bytes: $0) }
    }

    public mutating func write(_ rect: PixelRect, bgra source: [UInt8]) throws {
        try source.withUnsafeBytes { try write(rect, bytes: $0) }
    }

    /// Writes little-endian RGB565 pixels (16-bit Raw) into `rect`, expanding each pixel to 8-bit BGRA. 5- and 6-bit channels are expanded
    /// by repeating the high bits into the low bits (31 → 255, 63 → 255), so white stays white.
    mutating func writeRGB565(_ rect: PixelRect, source: Data) throws {
        guard contains(rect) else { throw RFBError.malformed("rectangle \(rect) is outside framebuffer \(width)x\(height)") }
        guard source.count == rect.width * rect.height * 2 else {
            throw RFBError.malformed("\(source.count) bytes of data do not match rectangle \(rect) at 16 bits")
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

    /// Write core: copies row by row with `memcpy`, no extra allocation.
    mutating func write(_ rect: PixelRect, bytes source: UnsafeRawBufferPointer) throws {
        guard contains(rect) else { throw RFBError.malformed("rectangle \(rect) is outside framebuffer \(width)x\(height)") }
        let rowBytes = rect.width * Self.bytesPerPixel
        guard source.count == rowBytes * rect.height, let sourceBase = source.baseAddress else {
            throw RFBError.malformed("\(source.count) bytes of data do not match rectangle \(rect)")
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

    /// Raw access to pixel memory so decoders can write directly, with no intermediary. The caller is responsible for
    /// keeping every write within `bounds` (see `ZRLEDecoder`). Call once per rectangle, because each call checks copy-on-write.
    mutating func withUnsafeMutablePixelBytes<R>(_ body: (UnsafeMutableRawBufferPointer) throws -> R) rethrows -> R {
        try pixels.withUnsafeMutableBytes(body)
    }

    /// Result of comparing two framebuffers of the same size.
    public struct Difference: Equatable, Sendable {
        /// Number of differing pixels (only the B, G, R channels are compared; the padding byte is ignored).
        public var count: Int
        /// Smallest rectangle containing every differing pixel, `nil` if identical.
        public var bounds: PixelRect?
    }

    /// One grid cell that contains differing pixels.
    public struct DifferenceCell: Equatable, Sendable {
        /// Region of the cell, clipped to the framebuffer edge.
        public var rect: PixelRect
        public var count: Int
    }

    /// Splits the framebuffer into a grid of `cellSize` squares and counts differing pixels in each cell, most differences first.
    /// Returns only cells that differ. Returns `nil` if the sizes differ. Use it to see where the differences are.
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

    /// Compares with `other`. Returns `nil` if the sizes differ.
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

    /// Copies a region to a new position within the same framebuffer (CopyRect).
    /// Source and destination may overlap; the result is as if the source were captured before writing.
    public mutating func copy(from source: PixelRect, toX x: Int, y: Int) throws {
        let destination = PixelRect(x: x, y: y, width: source.width, height: source.height)
        guard contains(source), contains(destination) else {
            throw RFBError.malformed("CopyRect \(source) → (\(x), \(y)) is outside framebuffer \(width)x\(height)")
        }
        let rowBytes = source.width * Self.bytesPerPixel
        let stride = width * Self.bytesPerPixel
        // Copy row by row with memmove (safe when source and destination overlap within a row). When the destination is BELOW the source,
        // go from the last row upward so source rows not yet copied are not overwritten. No copy is allocated, unlike the old approach.
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

    /// Color of one pixel as `(r, g, b)`, for tests and debugging.
    public func rgb(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8)? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        let index = offset(x: x, y: y)
        return (pixels[index + 2], pixels[index + 1], pixels[index])
    }

    /// sRGB image for saving or display. The fourth byte of each pixel is padding, not alpha.
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

/// Color conversion between formats. One single place, so Raw and ZRLE give the same result.
enum PixelConversion {
    /// RGB565 → `B | G << 8 | R << 16` (fourth byte 0). Expanded by repeating the high bits: 31 → 255, 63 → 255.
    /// Run of little-endian RGB565 → run of BGRA, 4 bytes per pixel (fourth byte 0).
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
