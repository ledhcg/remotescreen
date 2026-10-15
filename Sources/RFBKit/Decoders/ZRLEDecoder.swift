import Foundation

/// Giải mã ZRLE (RFC 6143 mục 7.7.6): zlib liên tục, chia hình chữ nhật thành tile 64×64.
///
/// Hỗ trợ hai định dạng pixel ta đặt bằng `SetPixelFormat`: `bgra8888` (CPIXEL 3 byte B, G, R, khớp bộ nhớ của `Framebuffer`)
/// và `rgb565` (CPIXEL 2 byte, theo RFC 6143 CPIXEL bằng cỡ pixel khi không phải 32 bit, được mở rộng thành BGRA khi giải mã).
struct ZRLEDecoder {
    static let tileSize = 64
    private let inflater: InflateStream
    private let layout: WireLayout

    init(layout: WireLayout = .bgra8888) throws {
        inflater = try InflateStream()
        self.layout = layout
    }

    /// Trần đầu ra sau giải nén cho một hình chữ nhật. Trường hợp tệ nhất là RLE mà mỗi pixel là một
    /// lượt chạy dài 1, tốn 4 byte (CPIXEL + độ dài). Thêm phần dư cho tiêu đề và bảng màu của từng tile.
    static func maxInflatedSize(for rect: PixelRect) -> Int {
        let tiles = ((rect.width + tileSize - 1) / tileSize) * ((rect.height + tileSize - 1) / tileSize)
        return rect.width * rect.height * 4 + tiles * 400 + 64
    }

    /// Trần dung lượng nén cho một hình chữ nhật (deflate có thể phình nhẹ với dữ liệu không nén được).
    static func maxCompressedSize(for rect: PixelRect) -> Int {
        rect.width * rect.height * 5 + 4096
    }

    func decode(rect: PixelRect, compressed: Data, into framebuffer: inout Framebuffer) throws {
        guard framebuffer.contains(rect) else {
            throw RFBError.malformed("hình chữ nhật ZRLE \(rect) nằm ngoài framebuffer")
        }
        // Giải nén vào bộ đệm dùng lại rồi giải mã tile thẳng từ đó, không sao chép trung gian.
        try inflater.withInflated(compressed, maxOutput: Self.maxInflatedSize(for: rect)) { inflated in
            try Self.decodeTiles(buffer: inflated, rect: rect, layout: layout, into: &framebuffer)
        }
    }

    /// Giải mã các tile từ dữ liệu **đã giải nén**. Tách riêng để test không cần zlib.
    static func decodeTiles(_ bytes: [UInt8], rect: PixelRect, layout: WireLayout = .bgra8888, into framebuffer: inout Framebuffer) throws {
        try bytes.withUnsafeBufferPointer { try decodeTiles(buffer: $0, rect: rect, layout: layout, into: &framebuffer) }
    }

    /// Chọn bộ đọc CPIXEL một lần cho cả hình chữ nhật, để vòng lặp pixel được chuyên biệt hóa (không rẽ nhánh theo từng pixel).
    static func decodeTiles(buffer: UnsafeBufferPointer<UInt8>, rect: PixelRect, layout: WireLayout, into framebuffer: inout Framebuffer) throws {
        switch layout {
        case .bgra8888: try decodeTiles(BGR24.self, buffer: buffer, rect: rect, into: &framebuffer)
        case .rgb565: try decodeTiles(RGB565.self, buffer: buffer, rect: rect, into: &framebuffer)
        }
    }

    /// Lõi giải mã. Mọi truy cập bộ nhớ đều được kiểm tra biên **tường minh** trước khi thực hiện (không dựa vào kiểm tra
    /// của `Array`, vốn là thứ làm cách viết cũ chậm: 65% thời gian giải mã nằm ở đó). Hai bất biến giữ cho nó an toàn:
    ///  - đọc: `Reader` chỉ trả dữ liệu sau khi so `position + n <= count`;
    ///  - ghi: `rect` nằm trong framebuffer (kiểm ở đây), mỗi tile nằm trong `rect`, và mỗi lượt ghi nằm trong tile.
    static func decodeTiles<P: CPixelReader>(
        _: P.Type, buffer: UnsafeBufferPointer<UInt8>, rect: PixelRect, into framebuffer: inout Framebuffer
    ) throws {
        guard framebuffer.contains(rect) else {
            throw RFBError.malformed("hình chữ nhật ZRLE \(rect) nằm ngoài framebuffer")
        }
        let strideBytes = framebuffer.width * Framebuffer.bytesPerPixel
        try framebuffer.withUnsafeMutablePixelBytes { pixels in
            guard let framebufferBase = pixels.baseAddress else { return }
            // Palette tối đa 127 màu (RLE có palette) nằm trên stack, dùng lại cho mọi tile.
            try withUnsafeTemporaryAllocation(of: UInt32.self, capacity: 128) { palette in
                var reader = TileReader<P>(buffer: buffer)
                var tileY = 0
                while tileY < rect.height {
                    let tileHeight = min(tileSize, rect.height - tileY)
                    var tileX = 0
                    while tileX < rect.width {
                        let tileWidth = min(tileSize, rect.width - tileX)
                        let origin = framebufferBase + (rect.y + tileY) * strideBytes + (rect.x + tileX) * Framebuffer.bytesPerPixel
                        try reader.decodeTile(
                            width: tileWidth, height: tileHeight, into: origin, strideBytes: strideBytes, palette: palette.baseAddress!
                        )
                        tileX += tileWidth
                    }
                    tileY += tileHeight
                }
                guard reader.isAtEnd else {
                    throw RFBError.malformed("ZRLE còn \(reader.remaining) byte thừa sau tile cuối, luồng bị lệch")
                }
            }
        }
    }

    // MARK: - Đọc từng tile

    /// Pixel trong bộ nhớ là B, G, R, 0 (little-endian): một `UInt32` bằng `b | g << 8 | r << 16`.
    private struct TileReader<P: CPixelReader> {
        let base: UnsafePointer<UInt8>?
        let count: Int
        var position = 0

        init(buffer: UnsafeBufferPointer<UInt8>) {
            base = buffer.baseAddress
            count = buffer.count
        }

        var remaining: Int { count - position }
        var isAtEnd: Bool { remaining == 0 }

        private func truncated() -> RFBError { RFBError.malformed("dữ liệu ZRLE bị cắt cụt") }

        @inline(__always)
        mutating func byte() throws -> UInt8 {
            guard position < count, let base else { throw truncated() }
            defer { position += 1 }
            return base[position]
        }

        /// Một CPIXEL, đổi thành từ 32-bit đúng thứ tự bộ nhớ của framebuffer.
        @inline(__always)
        mutating func pixel() throws -> UInt32 {
            guard count - position >= P.size, let base else { throw truncated() }
            defer { position += P.size }
            return P.read(base + position)
        }

        /// Độ dài lượt chạy: 1 cộng tổng các byte, byte 255 nghĩa là còn tiếp.
        @inline(__always)
        mutating func runLength() throws -> Int {
            var length = 1
            while true {
                let next = try byte()
                length += Int(next)
                if next != 255 { return length }
            }
        }

        /// Ghi `pixelCount` pixel liên tiếp (theo thứ tự quét hàng của tile) bắt đầu từ chỉ số `start`, cùng một màu.
        @inline(__always)
        private func fillRun(
            _ value: UInt32, start: Int, count: Int, width: Int, origin: UnsafeMutableRawPointer, strideBytes: Int
        ) {
            var row = start / width
            var column = start % width
            var left = count
            while left > 0 {
                let n = min(left, width - column)
                let line = origin + row * strideBytes + column * 4
                for index in 0..<n { line.storeBytes(of: value, toByteOffset: index * 4, as: UInt32.self) }
                left -= n
                row += 1
                column = 0
            }
        }

        mutating func decodeTile(
            width: Int, height: Int, into origin: UnsafeMutableRawPointer, strideBytes: Int, palette: UnsafeMutablePointer<UInt32>
        ) throws {
            let sub = try byte()
            let isRLE = sub & 0x80 != 0
            let paletteSize = Int(sub & 0x7F)
            let pixelCount = width * height

            switch (isRLE, paletteSize) {
            case (false, 0): // raw: một CPIXEL mỗi pixel
                guard remaining >= pixelCount * P.size, let base else { throw truncated() }
                var source = base + position
                for y in 0..<height {
                    let line = origin + y * strideBytes
                    for x in 0..<width {
                        line.storeBytes(of: P.read(source), toByteOffset: x * 4, as: UInt32.self)
                        source += P.size
                    }
                }
                position += pixelCount * P.size

            case (false, 1): // một màu
                let solid = try pixel()
                fillRun(solid, start: 0, count: pixelCount, width: width, origin: origin, strideBytes: strideBytes)

            case (false, 2...16): // palette đóng gói bit
                try readPalette(paletteSize, into: palette)
                let bits = paletteSize == 2 ? 1 : (paletteSize <= 4 ? 2 : 4)
                let rowBytes = (width * bits + 7) / 8
                guard remaining >= rowBytes * height, let base else { throw truncated() }
                let mask = UInt8((1 << bits) - 1)
                for y in 0..<height {
                    let row = base + position
                    let line = origin + y * strideBytes
                    for x in 0..<width {
                        let bitOffset = x * bits
                        let shift = UInt8(8 - bits - (bitOffset % 8))
                        let index = Int((row[bitOffset / 8] >> shift) & mask)
                        guard index < paletteSize else { throw RFBError.malformed("chỉ số palette \(index) vượt cỡ \(paletteSize)") }
                        line.storeBytes(of: palette[index], toByteOffset: x * 4, as: UInt32.self)
                    }
                    position += rowBytes
                }

            case (true, 0): // RLE thường
                var filled = 0
                while filled < pixelCount {
                    let colour = try pixel()
                    let run = try runLength()
                    guard filled + run <= pixelCount else { throw overrun(filled, run, pixelCount) }
                    fillRun(colour, start: filled, count: run, width: width, origin: origin, strideBytes: strideBytes)
                    filled += run
                }

            case (true, 2...127): // RLE có palette
                try readPalette(paletteSize, into: palette)
                var filled = 0
                while filled < pixelCount {
                    let entry = try byte()
                    let index = Int(entry & 0x7F)
                    guard index < paletteSize else { throw RFBError.malformed("chỉ số palette \(index) vượt cỡ \(paletteSize)") }
                    let run = entry & 0x80 != 0 ? try runLength() : 1
                    guard filled + run <= pixelCount else { throw overrun(filled, run, pixelCount) }
                    fillRun(palette[index], start: filled, count: run, width: width, origin: origin, strideBytes: strideBytes)
                    filled += run
                }

            default: // 17..127 không dùng, 129 không dùng
                throw RFBError.malformed("subencoding ZRLE \(sub) không hợp lệ")
            }
        }

        private func overrun(_ start: Int, _ run: Int, _ total: Int) -> RFBError {
            RFBError.malformed("lượt chạy ZRLE vượt quá tile (\(start)+\(run) > \(total))")
        }

        /// `count` luôn ≤ 127 và `palette` có chỗ cho 128 phần tử.
        private mutating func readPalette(_ count: Int, into palette: UnsafeMutablePointer<UInt32>) throws {
            for index in 0..<count { palette[index] = try pixel() }
        }
    }
}

/// Đọc một CPIXEL từ luồng ZRLE và đổi thành từ 32-bit B | G << 8 | R << 16.
protocol CPixelReader {
    static var size: Int { get }
    /// `pointer` trỏ tới ít nhất `size` byte hợp lệ (người gọi đã kiểm tra).
    static func read(_ pointer: UnsafePointer<UInt8>) -> UInt32
}

/// 32 bit/pixel, độ sâu 24: CPIXEL là 3 byte B, G, R.
enum BGR24: CPixelReader {
    static var size: Int { 3 }
    @inline(__always)
    static func read(_ pointer: UnsafePointer<UInt8>) -> UInt32 {
        UInt32(pointer[0]) | UInt32(pointer[1]) << 8 | UInt32(pointer[2]) << 16
    }
}

/// 16 bit/pixel (5-6-5, little-endian): CPIXEL là 2 byte.
enum RGB565: CPixelReader {
    static var size: Int { 2 }
    @inline(__always)
    static func read(_ pointer: UnsafePointer<UInt8>) -> UInt32 {
        PixelConversion.bgra(fromRGB565: UInt32(pointer[0]) | UInt32(pointer[1]) << 8)
    }
}
