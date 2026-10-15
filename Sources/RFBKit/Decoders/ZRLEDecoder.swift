import Foundation

/// ZRLE decoding (RFC 6143 section 7.7.6): continuous zlib, rectangle split into 64×64 tiles.
///
/// Supports the two pixel formats we set with `SetPixelFormat`: `bgra8888` (3-byte CPIXEL B, G, R, matching `Framebuffer` memory)
/// and `rgb565` (2-byte CPIXEL; per RFC 6143 CPIXEL equals the pixel size when not 32 bit, expanded to BGRA while decoding).
struct ZRLEDecoder {
    static let tileSize = 64
    private let inflater: InflateStream
    private let layout: WireLayout

    init(layout: WireLayout = .bgra8888) throws {
        inflater = try InflateStream()
        self.layout = layout
    }

    /// Cap on the decompressed output for one rectangle. The worst case is RLE where every pixel is a
    /// run of length 1, costing 4 bytes (CPIXEL + length). Plus headroom for each tile's header and palette.
    static func maxInflatedSize(for rect: PixelRect) -> Int {
        let tiles = ((rect.width + tileSize - 1) / tileSize) * ((rect.height + tileSize - 1) / tileSize)
        return rect.width * rect.height * 4 + tiles * 400 + 64
    }

    /// Cap on the compressed size for one rectangle (deflate can expand slightly on incompressible data).
    static func maxCompressedSize(for rect: PixelRect) -> Int {
        rect.width * rect.height * 5 + 4096
    }

    func decode(rect: PixelRect, compressed: Data, into framebuffer: inout Framebuffer) throws {
        guard framebuffer.contains(rect) else {
            throw RFBError.malformed("ZRLE rectangle \(rect) is outside the framebuffer")
        }
        // Decompress into a reused buffer, then decode tiles straight from it, with no intermediate copy.
        try inflater.withInflated(compressed, maxOutput: Self.maxInflatedSize(for: rect)) { inflated in
            try Self.decodeTiles(buffer: inflated, rect: rect, layout: layout, into: &framebuffer)
        }
    }

    /// Decodes tiles from **already decompressed** data. Split out so tests do not need zlib.
    static func decodeTiles(_ bytes: [UInt8], rect: PixelRect, layout: WireLayout = .bgra8888, into framebuffer: inout Framebuffer) throws {
        try bytes.withUnsafeBufferPointer { try decodeTiles(buffer: $0, rect: rect, layout: layout, into: &framebuffer) }
    }

    /// Picks the CPIXEL reader once per rectangle, so the pixel loop is specialized (no per-pixel branching).
    static func decodeTiles(buffer: UnsafeBufferPointer<UInt8>, rect: PixelRect, layout: WireLayout, into framebuffer: inout Framebuffer) throws {
        switch layout {
        case .bgra8888: try decodeTiles(BGR24.self, buffer: buffer, rect: rect, into: &framebuffer)
        case .rgb565: try decodeTiles(RGB565.self, buffer: buffer, rect: rect, into: &framebuffer)
        }
    }

    /// Decoding core. Every memory access is bounds-checked **explicitly** before it happens (not relying on the checks
    /// of `Array`, which is what made the old approach slow: 65% of decode time was spent there). Two invariants keep it safe:
    ///  - reads: `Reader` returns data only after checking `position + n <= count`;
    ///  - writes: `rect` is inside the framebuffer (checked here), each tile is inside `rect`, and each write is inside the tile.
    static func decodeTiles<P: CPixelReader>(
        _: P.Type, buffer: UnsafeBufferPointer<UInt8>, rect: PixelRect, into framebuffer: inout Framebuffer
    ) throws {
        guard framebuffer.contains(rect) else {
            throw RFBError.malformed("ZRLE rectangle \(rect) is outside the framebuffer")
        }
        let strideBytes = framebuffer.width * Framebuffer.bytesPerPixel
        try framebuffer.withUnsafeMutablePixelBytes { pixels in
            guard let framebufferBase = pixels.baseAddress else { return }
            // A palette of at most 127 colors (palette RLE) lives on the stack, reused for every tile.
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
                    throw RFBError.malformed("ZRLE has \(reader.remaining) extra bytes after the last tile, stream is out of sync")
                }
            }
        }
    }

    // MARK: - Reading each tile

    /// A pixel in memory is B, G, R, 0 (little-endian): a `UInt32` equal to `b | g << 8 | r << 16`.
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

        private func truncated() -> RFBError { RFBError.malformed("ZRLE data is truncated") }

        @inline(__always)
        mutating func byte() throws -> UInt8 {
            guard position < count, let base else { throw truncated() }
            defer { position += 1 }
            return base[position]
        }

        /// One CPIXEL, converted to a 32-bit word in the framebuffer's memory order.
        @inline(__always)
        mutating func pixel() throws -> UInt32 {
            guard count - position >= P.size, let base else { throw truncated() }
            defer { position += P.size }
            return P.read(base + position)
        }

        /// Run length: 1 plus the sum of the bytes; a byte of 255 means more follow.
        @inline(__always)
        mutating func runLength() throws -> Int {
            var length = 1
            while true {
                let next = try byte()
                length += Int(next)
                if next != 255 { return length }
            }
        }

        /// Writes `pixelCount` consecutive pixels (in the tile's row-scan order) starting at index `start`, all one color.
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
            case (false, 0): // raw: one CPIXEL per pixel
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

            case (false, 1): // single color
                let solid = try pixel()
                fillRun(solid, start: 0, count: pixelCount, width: width, origin: origin, strideBytes: strideBytes)

            case (false, 2...16): // bit-packed palette
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
                        guard index < paletteSize else { throw RFBError.malformed("palette index \(index) exceeds size \(paletteSize)") }
                        line.storeBytes(of: palette[index], toByteOffset: x * 4, as: UInt32.self)
                    }
                    position += rowBytes
                }

            case (true, 0): // plain RLE
                var filled = 0
                while filled < pixelCount {
                    let colour = try pixel()
                    let run = try runLength()
                    guard filled + run <= pixelCount else { throw overrun(filled, run, pixelCount) }
                    fillRun(colour, start: filled, count: run, width: width, origin: origin, strideBytes: strideBytes)
                    filled += run
                }

            case (true, 2...127): // palette RLE
                try readPalette(paletteSize, into: palette)
                var filled = 0
                while filled < pixelCount {
                    let entry = try byte()
                    let index = Int(entry & 0x7F)
                    guard index < paletteSize else { throw RFBError.malformed("palette index \(index) exceeds size \(paletteSize)") }
                    let run = entry & 0x80 != 0 ? try runLength() : 1
                    guard filled + run <= pixelCount else { throw overrun(filled, run, pixelCount) }
                    fillRun(palette[index], start: filled, count: run, width: width, origin: origin, strideBytes: strideBytes)
                    filled += run
                }

            default: // 17..127 unused, 129 unused
                throw RFBError.malformed("invalid ZRLE subencoding \(sub)")
            }
        }

        private func overrun(_ start: Int, _ run: Int, _ total: Int) -> RFBError {
            RFBError.malformed("ZRLE run exceeds the tile (\(start)+\(run) > \(total))")
        }

        /// `count` is always ≤ 127 and `palette` has room for 128 elements.
        private mutating func readPalette(_ count: Int, into palette: UnsafeMutablePointer<UInt32>) throws {
            for index in 0..<count { palette[index] = try pixel() }
        }
    }
}

/// Reads one CPIXEL from the ZRLE stream and converts it to the 32-bit word B | G << 8 | R << 16.
protocol CPixelReader {
    static var size: Int { get }
    /// `pointer` points to at least `size` valid bytes (the caller has checked).
    static func read(_ pointer: UnsafePointer<UInt8>) -> UInt32
}

/// 32 bits/pixel, depth 24: CPIXEL is 3 bytes B, G, R.
enum BGR24: CPixelReader {
    static var size: Int { 3 }
    @inline(__always)
    static func read(_ pointer: UnsafePointer<UInt8>) -> UInt32 {
        UInt32(pointer[0]) | UInt32(pointer[1]) << 8 | UInt32(pointer[2]) << 16
    }
}

/// 16 bits/pixel (5-6-5, little-endian): CPIXEL is 2 bytes.
enum RGB565: CPixelReader {
    static var size: Int { 2 }
    @inline(__always)
    static func read(_ pointer: UnsafePointer<UInt8>) -> UInt32 {
        PixelConversion.bgra(fromRGB565: UInt32(pointer[0]) | UInt32(pointer[1]) << 8)
    }
}
