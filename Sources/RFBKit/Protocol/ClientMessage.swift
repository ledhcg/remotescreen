import Foundation

/// Messages the client sends to the server after the handshake completes (RFC 6143 section 7.5).
public enum ClientMessage: Equatable, Sendable {
    case setPixelFormat(PixelFormat)
    case setEncodings([RFBEncoding])
    case framebufferUpdateRequest(incremental: Bool, rect: PixelRect)
    /// `keysym` follows the X11 table (`keysymdef.h`).
    case keyEvent(isDown: Bool, keysym: UInt32)
    /// `buttons` is a bit mask: bit 0 left, bit 1 middle, bit 2 right, bits 3 to 6 for scrolling.
    case pointerEvent(buttons: UInt8, x: UInt16, y: UInt16)
    /// Clipboard contents. Standard RFB allows only Latin-1; characters outside this set are replaced.
    case clientCutText(String)
    /// Requests the Mac's clipboard (Apple message type 11). The server replies with a `ClipboardTransfer` carrying the same `token`.
    case clipboardRequest(token: UInt32)
    /// Sends the clipboard to the Mac (Apple message type 31).
    case clipboardSend(ClipboardTransfer)
    /// Asks Apple's server to scale the image down **for this viewer only** (message type 8, `HandleSetServerScalingMessage`), without changing the Mac's
    /// screen. The scale is in (0, 1]; the server replies with a `DesktopSize` carrying the new size (measured: 0.5 → 1280x720 from 2560x1440).
    /// Format: `[8][0][double IEEE 754 big-endian]`, 10 bytes.
    case appleServerScaling(Double)
    /// Apple's smooth scrolling and gestures (message type 23). Send only to Apple servers: other servers close the connection on an unknown type.
    case appleEvent(AppleInputEvent)

    /// Maximum number of encodings one `SetEncodings` message can carry (16-bit count field).
    static let maxEncodings = Int(UInt16.max)

    public var wireBytes: Data {
        var data = Data()
        switch self {
        case .setPixelFormat(let format):
            data.append(contentsOf: [0, 0, 0, 0])
            data.append(format.wireBytes)

        case .setEncodings(let encodings):
            let capped = encodings.prefix(Self.maxEncodings)
            data.append(contentsOf: [2, 0])
            data.appendBigEndian(UInt16(capped.count))
            for encoding in capped { data.appendBigEndian(UInt32(bitPattern: encoding.rawValue)) }

        case .framebufferUpdateRequest(let incremental, let rect):
            data.append(contentsOf: [3, incremental ? 1 : 0])
            data.appendBigEndian(UInt16(clamping: rect.x))
            data.appendBigEndian(UInt16(clamping: rect.y))
            data.appendBigEndian(UInt16(clamping: rect.width))
            data.appendBigEndian(UInt16(clamping: rect.height))

        case .keyEvent(let isDown, let keysym):
            data.append(contentsOf: [4, isDown ? 1 : 0, 0, 0])
            data.appendBigEndian(keysym)

        case .pointerEvent(let buttons, let x, let y):
            data.append(contentsOf: [5, buttons])
            data.appendBigEndian(x)
            data.appendBigEndian(y)

        case .clipboardRequest(let token):
            data.append(contentsOf: [11, 0, 0, 0])
            data.appendBigEndian(token)

        case .clipboardSend(let transfer):
            data.append(transfer.wireBytes)

        case .appleServerScaling(let scale):
            // The server rejects a scale ≤ 0 or > 1 (read from the binary): clamp so we never send a value it considers invalid.
            let clamped = scale.isFinite ? min(max(scale, 0.05), 1) : 1
            data.append(contentsOf: [8, 0])
            withUnsafeBytes(of: clamped.bitPattern.bigEndian) { data.append(contentsOf: $0) }

        case .appleEvent(let event):
            data.append(event.wireBytes)

        case .clientCutText(let text):
            let bytes = text.data(using: .isoLatin1, allowLossyConversion: true) ?? Data()
            data.append(contentsOf: [6, 0, 0, 0])
            data.appendBigEndian(UInt32(bytes.count))
            data.append(bytes)
        }
        return data
    }
}

extension Data {
    mutating func appendBigEndian(_ value: UInt16) {
        append(UInt8(value >> 8))
        append(UInt8(value & 0xFF))
    }

    mutating func appendBigEndian(_ value: UInt32) {
        for shift in stride(from: 24, through: 0, by: -8) { append(UInt8((value >> UInt32(shift)) & 0xFF)) }
    }
}
