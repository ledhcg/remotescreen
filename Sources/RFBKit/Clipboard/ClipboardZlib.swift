import CZlib
import Foundation

/// zlib một lần (không giữ trạng thái giữa các lần gọi), dùng cho clipboard của Apple.
enum ClipboardZlib {
    /// Nén như server Apple: zlib mức 9 (header `78 da`), kết thúc bằng `Z_SYNC_FLUSH` và **không đóng luồng**.
    /// Quan sát được trên payload thật của `screensharingd`; bắt chước nó để bên nhận (agent trên Mac) gặp đúng dạng quen thuộc.
    static func deflate(_ input: Data) throws -> Data {
        var stream = z_stream()
        guard deflateInit_(&stream, 9, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw RFBError.malformed("không khởi tạo được bộ nén zlib")
        }
        defer { deflateEnd(&stream) }

        var output = [UInt8](repeating: 0, count: Int(deflateBound(&stream, uLong(input.count))) + 64)
        var status = Z_OK
        let written: Int = try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            stream.next_in = UnsafeMutablePointer(mutating: raw.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(raw.count)
            return try output.withUnsafeMutableBytes { buffer in
                stream.next_out = buffer.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(buffer.count)
                status = CZlib.deflate(&stream, Z_SYNC_FLUSH)
                guard status == Z_OK, stream.avail_in == 0 else { throw RFBError.malformed("nén zlib lỗi \(status)") }
                return buffer.count - Int(stream.avail_out)
            }
        }
        return Data(output[0..<written])
    }

    /// Giải nén tới `maxOutput` byte. Chấp nhận cả luồng đã đóng lẫn chưa đóng (server Apple gửi dạng chưa đóng).
    /// Vượt trần là lỗi, để dữ liệu nén độc hại không ép client cấp phát bộ nhớ vô hạn.
    static func inflate(_ input: Data, maxOutput: Int) throws -> Data {
        var stream = z_stream()
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw RFBError.malformed("không khởi tạo được zlib")
        }
        defer { inflateEnd(&stream) }

        var output = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            stream.next_in = UnsafeMutablePointer(mutating: raw.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(raw.count)
            while true {
                var produced = 0
                let status: Int32 = chunk.withUnsafeMutableBytes { buffer in
                    stream.next_out = buffer.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(buffer.count)
                    let result = CZlib.inflate(&stream, Z_SYNC_FLUSH)
                    produced = buffer.count - Int(stream.avail_out)
                    return result
                }
                output.append(contentsOf: chunk[0..<produced])
                if output.count > maxOutput { throw RFBError.malformed("clipboard giải nén vượt trần \(maxOutput) byte") }
                switch status {
                case Z_STREAM_END: return
                case Z_OK: if stream.avail_in == 0 && stream.avail_out != 0 { return }
                case Z_BUF_ERROR: if stream.avail_in == 0 { return } else { throw RFBError.malformed("zlib không tiến triển được") }
                default: throw RFBError.malformed("lỗi zlib \(status)")
                }
            }
        }
        return output
    }
}
