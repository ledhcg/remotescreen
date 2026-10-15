import Foundation

/// Định dạng pixel mà server gửi framebuffer, 16 byte trên đường truyền (RFC 6143 mục 7.4).
public struct PixelFormat: Equatable, Sendable {
    public var bitsPerPixel: UInt8
    public var depth: UInt8
    public var isBigEndian: Bool
    public var isTrueColour: Bool
    public var redMax: UInt16
    public var greenMax: UInt16
    public var blueMax: UInt16
    public var redShift: UInt8
    public var greenShift: UInt8
    public var blueShift: UInt8

    public init(
        bitsPerPixel: UInt8, depth: UInt8, isBigEndian: Bool, isTrueColour: Bool,
        redMax: UInt16, greenMax: UInt16, blueMax: UInt16,
        redShift: UInt8, greenShift: UInt8, blueShift: UInt8
    ) {
        self.bitsPerPixel = bitsPerPixel
        self.depth = depth
        self.isBigEndian = isBigEndian
        self.isTrueColour = isTrueColour
        self.redMax = redMax
        self.greenMax = greenMax
        self.blueMax = blueMax
        self.redShift = redShift
        self.greenShift = greenShift
        self.blueShift = blueShift
    }

    /// 32 bit mỗi pixel, byte theo thứ tự B, G, R, X trong bộ nhớ little-endian. Khớp trực tiếp với
    /// `MTLPixelFormat.bgra8Unorm` nên không phải đổi màu khi đưa lên GPU.
    public static let bgra8888 = PixelFormat(
        bitsPerPixel: 32, depth: 24, isBigEndian: false, isTrueColour: true,
        redMax: 255, greenMax: 255, blueMax: 255, redShift: 16, greenShift: 8, blueShift: 0
    )

    /// 16 bit mỗi pixel (5-6-5), little-endian: bằng khoảng 65-71% số byte của 32 bit trên luồng thật của Mac (đo hai kết nối song
    /// song, 15 giây, cùng nội dung), đổi lại màu bị lượng tử hóa (kênh 5-6 bit). Server Apple chấp nhận; **8 bit thì không**
    /// (đóng kết nối).
    public static let rgb565 = PixelFormat(
        bitsPerPixel: 16, depth: 16, isBigEndian: false, isTrueColour: true,
        redMax: 31, greenMax: 63, blueMax: 31, redShift: 11, greenShift: 5, blueShift: 0
    )

    /// Cách giải mã pixel của một định dạng mà app hỗ trợ; `nil` nếu định dạng khác.
    var supportedLayout: WireLayout? {
        switch self {
        case .bgra8888: .bgra8888
        case .rgb565: .rgb565
        default: nil
        }
    }

    static let wireLength = 16

    public init(parsing data: Data) throws {
        guard data.count == Self.wireLength else { throw RFBError.malformed("PixelFormat phải 16 byte, nhận \(data.count)") }
        let b = Array(data)
        guard [8, 16, 32].contains(b[0]) else { throw RFBError.malformed("bits-per-pixel \(b[0]) không hợp lệ") }
        self.init(
            bitsPerPixel: b[0], depth: b[1], isBigEndian: b[2] != 0, isTrueColour: b[3] != 0,
            redMax: UInt16(b[4]) << 8 | UInt16(b[5]), greenMax: UInt16(b[6]) << 8 | UInt16(b[7]),
            blueMax: UInt16(b[8]) << 8 | UInt16(b[9]),
            redShift: b[10], greenShift: b[11], blueShift: b[12]
        )
    }

    /// 16 byte gửi đi, gồm 3 byte đệm cuối.
    public var wireBytes: Data {
        Data([
            bitsPerPixel, depth, isBigEndian ? 1 : 0, isTrueColour ? 1 : 0,
            UInt8(redMax >> 8), UInt8(redMax & 0xFF), UInt8(greenMax >> 8), UInt8(greenMax & 0xFF),
            UInt8(blueMax >> 8), UInt8(blueMax & 0xFF),
            redShift, greenShift, blueShift, 0, 0, 0,
        ])
    }
}

/// Thông tin server gửi sau khi xác thực xong.
public struct ServerInit: Equatable, Sendable {
    public var width: UInt16
    public var height: UInt16
    public var pixelFormat: PixelFormat
    /// Tên máy/desktop do server tự khai báo.
    public var name: String

    public init(width: UInt16, height: UInt16, pixelFormat: PixelFormat = .bgra8888, name: String = "") {
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
        self.name = name
    }
}

extension Handshake {
    /// Trần độ dài tên desktop, chặn server gửi độ dài vô lý để ép ta cấp phát bộ nhớ lớn.
    private static let maxNameLength = 65_536

    /// Gửi `ClientInit` rồi đọc `ServerInit`. Gọi sau khi xác thực thành công.
    ///
    /// - Parameter shared: `true` cho phép các client khác cùng xem. `false` yêu cầu độc quyền
    ///   và có thể ngắt các client hiện có.
    public static func performInit(shared: Bool = true, over stream: some ByteStream) async throws -> ServerInit {
        try await stream.write(Data([shared ? 1 : 0]))

        let width = try await stream.readUInt16()
        let height = try await stream.readUInt16()
        let pixelFormat = try PixelFormat(parsing: try await stream.read(exactly: PixelFormat.wireLength))
        let nameLength = Int(try await stream.readUInt32())
        guard nameLength <= maxNameLength else { throw RFBError.malformed("tên desktop dài \(nameLength) byte") }
        let name = String(decoding: try await stream.read(exactly: nameLength), as: UTF8.self)
        return ServerInit(width: width, height: height, pixelFormat: pixelFormat, name: name)
    }
}

/// Hai định dạng pixel trên đường truyền mà bộ giải mã biết đọc.
enum WireLayout: Sendable {
    case bgra8888
    case rgb565

    var bytesPerPixel: Int { self == .bgra8888 ? 4 : 2 }
}
