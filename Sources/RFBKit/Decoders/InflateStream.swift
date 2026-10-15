import CZlib
import Foundation

/// Giải nén zlib theo luồng, **giữ nguyên trạng thái giữa các lần gọi**.
///
/// ZRLE (và Zlib, Tight) dùng một luồng zlib duy nhất cho cả kết nối: mỗi hình chữ nhật là một đoạn
/// nối tiếp của luồng đó và có thể tham chiếu ngược dữ liệu của các hình chữ nhật trước. Vì vậy
/// một `InflateStream` phải sống suốt phiên, không được tạo mới cho từng hình chữ nhật.
///
/// Không an toàn khi dùng từ nhiều luồng. Thuộc về một `RFBSession` (actor).
final class InflateStream {
    private var stream = z_stream()
    private static let minimumGrowth = 64 * 1024
    /// Bộ đệm đầu ra dùng lại giữa các lần gọi: một hình chữ nhật 2560x1440 giải nén ra hàng chục MB, cấp phát và sao chép
    /// từng đoạn 64 KB cho mỗi cập nhật (cách cũ) chiếm khoảng một phần mười thời gian giải mã.
    private var scratch: UnsafeMutableRawPointer
    private var scratchCapacity: Int
    /// Bộ đệm phình quá mức này (sau một khung hình rất lớn) thì thu lại ở lần gọi kế tiếp.
    private static let retainedCapacity = 32 * 1024 * 1024

    init() throws {
        scratchCapacity = 1 << 20
        scratch = UnsafeMutableRawPointer.allocate(byteCount: scratchCapacity, alignment: 16)
        let status = inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else {
            scratch.deallocate()
            throw RFBError.malformed("không khởi tạo được zlib: \(status)")
        }
    }

    deinit {
        inflateEnd(&stream)
        scratch.deallocate()
    }

    /// Giải nén `input`, trả về toàn bộ đầu ra tương ứng dưới dạng mảng (bản sao).
    func inflate(_ input: Data, maxOutput: Int) throws -> [UInt8] {
        try withInflated(input, maxOutput: maxOutput) { Array($0) }
    }

    /// Giải nén `input` rồi đưa đầu ra cho `body` **mà không sao chép**. Vùng nhớ chỉ hợp lệ trong `body`
    /// (lần gọi sau ghi đè nó).
    ///
    /// - Parameter maxOutput: trần dung lượng đầu ra. Vượt trần là lỗi, để dữ liệu nén độc hại
    ///   (zip bomb) không ép client cấp phát bộ nhớ vô hạn.
    func withInflated<R>(_ input: Data, maxOutput: Int, _ body: (UnsafeBufferPointer<UInt8>) throws -> R) throws -> R {
        if scratchCapacity > Self.retainedCapacity { shrinkScratch() }
        var produced = 0

        try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            stream.next_in = UnsafeMutablePointer(mutating: raw.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(raw.count)
            defer { stream.next_in = nil; stream.avail_in = 0 }

            while true {
                if produced == scratchCapacity { try grow(toAtLeast: produced + Self.minimumGrowth, maxOutput: maxOutput) }
                let room = scratchCapacity - produced
                stream.next_out = (scratch + produced).assumingMemoryBound(to: Bytef.self)
                stream.avail_out = uInt(room)
                let status = CZlib.inflate(&stream, Z_SYNC_FLUSH)
                produced += room - Int(stream.avail_out)
                if produced > maxOutput { throw RFBError.malformed("dữ liệu giải nén vượt trần \(maxOutput) byte") }

                switch status {
                case Z_OK:
                    // Còn đầu vào hoặc bộ đệm vừa đầy: tiếp tục. Hết đầu vào và bộ đệm còn chỗ: xong.
                    if stream.avail_in == 0 && stream.avail_out != 0 { return }
                case Z_BUF_ERROR:
                    // Không còn gì để làm. Chỉ chấp nhận khi đã dùng hết đầu vào.
                    if stream.avail_in == 0 { return }
                    throw RFBError.malformed("zlib không tiến triển được (Z_BUF_ERROR)")
                case Z_STREAM_END:
                    throw RFBError.malformed("luồng zlib kết thúc sớm, server không được đóng luồng giữa phiên")
                default:
                    throw RFBError.malformed("lỗi zlib \(status)")
                }
            }
        }
        return try body(UnsafeBufferPointer(start: scratch.assumingMemoryBound(to: UInt8.self), count: produced))
    }

    /// Nới bộ đệm giữ nguyên phần đã ghi. Không bao giờ vượt `maxOutput` quá một đoạn, nên zip bomb không phình bộ nhớ.
    private func grow(toAtLeast needed: Int, maxOutput: Int) throws {
        guard needed <= maxOutput + Self.minimumGrowth * 2 else {
            throw RFBError.malformed("dữ liệu giải nén vượt trần \(maxOutput) byte")
        }
        let newCapacity = min(max(scratchCapacity * 2, needed), maxOutput + Self.minimumGrowth * 2)
        let replacement = UnsafeMutableRawPointer.allocate(byteCount: newCapacity, alignment: 16)
        replacement.copyMemory(from: scratch, byteCount: scratchCapacity)
        scratch.deallocate()
        scratch = replacement
        scratchCapacity = newCapacity
    }

    private func shrinkScratch() {
        scratch.deallocate()
        scratchCapacity = 1 << 20
        scratch = UnsafeMutableRawPointer.allocate(byteCount: scratchCapacity, alignment: 16)
    }
}
