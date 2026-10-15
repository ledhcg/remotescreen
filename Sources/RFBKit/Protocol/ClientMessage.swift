import Foundation

/// Message client gửi tới server sau khi handshake xong (RFC 6143 mục 7.5).
public enum ClientMessage: Equatable, Sendable {
    case setPixelFormat(PixelFormat)
    case setEncodings([RFBEncoding])
    case framebufferUpdateRequest(incremental: Bool, rect: PixelRect)
    /// `keysym` theo bảng X11 (`keysymdef.h`).
    case keyEvent(isDown: Bool, keysym: UInt32)
    /// `buttons` là mặt nạ bit: bit 0 trái, bit 1 giữa, bit 2 phải, bit 3 đến 6 cho cuộn.
    case pointerEvent(buttons: UInt8, x: UInt16, y: UInt16)
    /// Nội dung clipboard. RFB chuẩn chỉ cho Latin-1, ký tự ngoài bảng này bị thay thế.
    case clientCutText(String)
    /// Xin clipboard của Mac (message loại 11 của Apple). Server trả lời bằng một `ClipboardTransfer` mang lại đúng `token`.
    case clipboardRequest(token: UInt32)
    /// Gửi clipboard lên Mac (message loại 31 của Apple).
    case clipboardSend(ClipboardTransfer)
    /// Nhờ server Apple thu nhỏ hình **cho riêng người xem này** (message loại 8, `HandleSetServerScalingMessage`), không đổi màn
    /// hình Mac. Tỉ lệ trong (0, 1]; server trả lời bằng một `DesktopSize` mang cỡ mới (đo được: 0,5 → 1280x720 từ 2560x1440).
    /// Định dạng: `[8][0][double IEEE 754 big-endian]`, 10 byte.
    case appleServerScaling(Double)
    /// Cuộn mượt và cử chỉ riêng của Apple (message loại 23). Chỉ gửi cho server Apple: server khác đóng kết nối khi gặp loại lạ.
    case appleEvent(AppleInputEvent)

    /// Tối đa số encoding một message `SetEncodings` mang được (trường đếm 16-bit).
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
            // Server từ chối tỉ lệ ≤ 0 hoặc > 1 (đọc từ binary): kẹp lại để không bao giờ gửi giá trị nó coi là sai.
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
