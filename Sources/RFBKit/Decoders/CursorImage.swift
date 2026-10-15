import Foundation

/// Hình con trỏ chuột từ xa, nhận qua pseudo-encoding Cursor (-239).
///
/// Server tách con trỏ khỏi framebuffer để client vẽ riêng, nhờ đó con trỏ di chuyển mượt
/// mà không phải chờ cập nhật màn hình.
public struct CursorImage: Equatable, Sendable {
    public var width: Int
    public var height: Int
    /// Điểm nóng: vị trí trong hình trùng với tọa độ con trỏ.
    public var hotspotX: Int
    public var hotspotY: Int
    /// BGRA 4 byte mỗi pixel. Pixel đục là `[B, G, R, 255]`, pixel trong suốt là `[0, 0, 0, 0]`.
    public var bgra: [UInt8]

    public var isEmpty: Bool { width == 0 || height == 0 }

    /// Trần mỗi chiều: chặn server ép client cấp phát bộ nhớ lớn bằng một hình con trỏ vô lý.
    public static let maxDimension = 1024

    /// Dựng từ dữ liệu trên đường truyền: `width * height` pixel BGRA (4 byte, theo định dạng pixel của client)
    /// rồi mặt nạ 1 bit mỗi pixel, mỗi hàng đệm tới byte, bit cao trước, 1 nghĩa là đục.
    init(width: Int, height: Int, hotspotX: Int, hotspotY: Int, pixels: Data, mask: Data) throws {
        guard width <= Self.maxDimension, height <= Self.maxDimension else {
            throw RFBError.malformed("con trỏ \(width)x\(height) quá lớn")
        }
        let maskRowBytes = (width + 7) / 8
        guard pixels.count == width * height * 4, mask.count == maskRowBytes * height else {
            throw RFBError.malformed("dữ liệu con trỏ không khớp kích thước \(width)x\(height)")
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

    /// Dựng từ BGRA có sẵn (định dạng của `bgra`). Trả `nil` nếu số byte không khớp kích thước hoặc quá lớn.
    public init?(width: Int, height: Int, hotspotX: Int, hotspotY: Int, bgra: [UInt8]) {
        guard width >= 0, height >= 0, width <= Self.maxDimension, height <= Self.maxDimension,
              bgra.count == width * height * 4 else { return nil }
        self.width = width
        self.height = height
        self.hotspotX = hotspotX
        self.hotspotY = hotspotY
        self.bgra = bgra
    }

    static let empty = CursorImage(emptyWithHotspotX: 0, y: 0)

    /// Mũi tên viền đen ruột trắng, điểm nóng ở đỉnh. Dùng cho tới khi server gửi hình con trỏ thật
    /// (Apple chỉ gửi khi hình đổi, nên đầu phiên có thể chưa có).
    public static let defaultArrow: CursorImage = {
        // `X` viền đen, `#` ruột trắng, `.` trong suốt.
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
