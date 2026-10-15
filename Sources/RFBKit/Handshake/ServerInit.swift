import Foundation

/// Pixel format in which the server sends the framebuffer, 16 bytes on the wire (RFC 6143 section 7.4).
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

    /// 32 bits per pixel, bytes in B, G, R, X order in little-endian memory. Matches
    /// `MTLPixelFormat.bgra8Unorm` directly, so no color conversion is needed when uploading to the GPU.
    public static let bgra8888 = PixelFormat(
        bitsPerPixel: 32, depth: 24, isBigEndian: false, isTrueColour: true,
        redMax: 255, greenMax: 255, blueMax: 255, redShift: 16, greenShift: 8, blueShift: 0
    )

    /// 16 bits per pixel (5-6-5), little-endian: about 65-71% of the bytes of 32-bit on a real Mac stream (measured with two parallel
    /// connections, 15 seconds, same content), in exchange for quantized color (5-6 bit channels). Apple's server accepts it; **8 bit does not**
    /// (it closes the connection).
    public static let rgb565 = PixelFormat(
        bitsPerPixel: 16, depth: 16, isBigEndian: false, isTrueColour: true,
        redMax: 31, greenMax: 63, blueMax: 31, redShift: 11, greenShift: 5, blueShift: 0
    )

    /// How to decode pixels for a format the app supports; `nil` for any other format.
    var supportedLayout: WireLayout? {
        switch self {
        case .bgra8888: .bgra8888
        case .rgb565: .rgb565
        default: nil
        }
    }

    static let wireLength = 16

    public init(parsing data: Data) throws {
        guard data.count == Self.wireLength else { throw RFBError.malformed("PixelFormat must be 16 bytes, got \(data.count)") }
        let b = Array(data)
        guard [8, 16, 32].contains(b[0]) else { throw RFBError.malformed("invalid bits-per-pixel \(b[0])") }
        self.init(
            bitsPerPixel: b[0], depth: b[1], isBigEndian: b[2] != 0, isTrueColour: b[3] != 0,
            redMax: UInt16(b[4]) << 8 | UInt16(b[5]), greenMax: UInt16(b[6]) << 8 | UInt16(b[7]),
            blueMax: UInt16(b[8]) << 8 | UInt16(b[9]),
            redShift: b[10], greenShift: b[11], blueShift: b[12]
        )
    }

    /// The 16 bytes sent, including 3 trailing padding bytes.
    public var wireBytes: Data {
        Data([
            bitsPerPixel, depth, isBigEndian ? 1 : 0, isTrueColour ? 1 : 0,
            UInt8(redMax >> 8), UInt8(redMax & 0xFF), UInt8(greenMax >> 8), UInt8(greenMax & 0xFF),
            UInt8(blueMax >> 8), UInt8(blueMax & 0xFF),
            redShift, greenShift, blueShift, 0, 0, 0,
        ])
    }
}

/// Information the server sends once authentication is complete.
public struct ServerInit: Equatable, Sendable {
    public var width: UInt16
    public var height: UInt16
    public var pixelFormat: PixelFormat
    /// Machine/desktop name that the server declares itself.
    public var name: String

    public init(width: UInt16, height: UInt16, pixelFormat: PixelFormat = .bgra8888, name: String = "") {
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
        self.name = name
    }
}

extension Handshake {
    /// Cap on the desktop name length, so a server cannot send an absurd length to force us to allocate a lot of memory.
    private static let maxNameLength = 65_536

    /// Sends `ClientInit`, then reads `ServerInit`. Call after authentication succeeds.
    ///
    /// - Parameter shared: `true` lets other clients watch at the same time. `false` requests exclusive access
    ///   and may disconnect existing clients.
    public static func performInit(shared: Bool = true, over stream: some ByteStream) async throws -> ServerInit {
        try await stream.write(Data([shared ? 1 : 0]))

        let width = try await stream.readUInt16()
        let height = try await stream.readUInt16()
        let pixelFormat = try PixelFormat(parsing: try await stream.read(exactly: PixelFormat.wireLength))
        let nameLength = Int(try await stream.readUInt32())
        guard nameLength <= maxNameLength else { throw RFBError.malformed("desktop name is \(nameLength) bytes long") }
        let name = String(decoding: try await stream.read(exactly: nameLength), as: UTF8.self)
        return ServerInit(width: width, height: height, pixelFormat: pixelFormat, name: name)
    }
}

/// The two on-the-wire pixel formats that the decoder knows how to read.
enum WireLayout: Sendable {
    case bgra8888
    case rgb565

    var bytesPerPixel: Int { self == .bgra8888 ? 4 : 2 }
}
