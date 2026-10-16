import Foundation

/// Remote mouse cursor image, received via the Cursor pseudo-encoding (-239).
///
/// The server separates the cursor from the framebuffer so the client draws it on its own, which lets the cursor move smoothly
/// without waiting for a screen update.
public struct CursorImage: Equatable, Sendable {
    public var width: Int
    public var height: Int
    /// Hot spot: the position in the image that coincides with the cursor coordinates.
    public var hotspotX: Int
    public var hotspotY: Int
    /// BGRA, 4 bytes per pixel. An opaque pixel is `[B, G, R, 255]`, a transparent pixel is `[0, 0, 0, 0]`.
    public var bgra: [UInt8]
    /// Image pixels per cursor pixel. 1 for cursors from the server; a locally drawn cursor is rasterized at a higher density so it stays
    /// sharp when shown large. Width, height and hotspot are in image pixels; divide by `scale` for the cursor's own size.
    public var scale = 1

    public var isEmpty: Bool { width == 0 || height == 0 }

    /// Per-dimension cap: stops a server from forcing the client to allocate a lot of memory with an absurd cursor image.
    public static let maxDimension = 1024

    /// Builds from wire data: `width * height` BGRA pixels (4 bytes, in the client's pixel format)
    /// then a 1-bit-per-pixel mask, each row padded to a byte, high bit first, 1 meaning opaque.
    init(width: Int, height: Int, hotspotX: Int, hotspotY: Int, pixels: Data, mask: Data) throws {
        guard width <= Self.maxDimension, height <= Self.maxDimension else {
            throw RFBError.malformed("cursor \(width)x\(height) is too large")
        }
        let maskRowBytes = (width + 7) / 8
        guard pixels.count == width * height * 4, mask.count == maskRowBytes * height else {
            throw RFBError.malformed("cursor data does not match size \(width)x\(height)")
        }
        self.width = width
        self.height = height
        self.hotspotX = hotspotX
        self.hotspotY = hotspotY

        var output = [UInt8](repeating: 0, count: width * height * 4)
        let pixelBase = pixels.startIndex
        let maskBase = mask.startIndex
        for y in 0..<height {
            for x in 0..<width {
                let opaque = (mask[maskBase + y * maskRowBytes + x / 8] >> UInt8(7 - x % 8)) & 1 == 1
                guard opaque else { continue }
                let index = (y * width + x) * 4
                output[index] = pixels[pixelBase + index]
                output[index + 1] = pixels[pixelBase + index + 1]
                output[index + 2] = pixels[pixelBase + index + 2]
                output[index + 3] = 255
            }
        }
        bgra = output
    }

    /// Builds from ready-made BGRA (the format of `bgra`). Returns `nil` if the byte count does not match the size or is too large.
    public init?(width: Int, height: Int, hotspotX: Int, hotspotY: Int, bgra: [UInt8], scale: Int = 1) {
        guard width >= 0, height >= 0, width <= Self.maxDimension, height <= Self.maxDimension, scale >= 1,
              bgra.count == width * height * 4 else { return nil }
        self.width = width
        self.height = height
        self.hotspotX = hotspotX
        self.hotspotY = hotspotY
        self.bgra = bgra
        self.scale = scale
    }

    static let empty = CursorImage(emptyWithHotspotX: 0, y: 0)

    /// Arrow with a black outline and white fill, hot spot at the tip. Used until the server sends a real cursor image
    /// (Apple sends it only when the image changes, so it may be missing at the start of a session).
    public static let defaultArrow: CursorImage = {
        // `X` black outline, `#` white fill, `.` transparent.
        let art = [
            "X..........",
            "XX.........",
            "X#X........",
            "X##X.......",
            "X###X......",
            "X####X.....",
            "X#####X....",
            "X######X...",
            "X#######X..",
            "X########X.",
            "X#####XXXXX",
            "X##X##X....",
            "X#X.X##X...",
            "XX..X##X...",
            "X....X##X..",
            ".....X##X..",
            "......XX...",
        ]
        var pixels: [UInt8] = []
        for row in art {
            for symbol in row {
                switch symbol {
                case "X": pixels += [0, 0, 0, 255]
                case "#": pixels += [255, 255, 255, 255]
                default: pixels += [0, 0, 0, 0]
                }
            }
        }
        return CursorImage(width: art[0].count, height: art.count, hotspotX: 0, hotspotY: 0, bgra: pixels) ?? .empty
    }()

    private init(emptyWithHotspotX x: Int, y: Int) {
        width = 0
        height = 0
        hotspotX = x
        hotspotY = y
        bgra = []
    }
}
