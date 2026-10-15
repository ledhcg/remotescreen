import CZlib
import Foundation

/// One-shot zlib (no state kept between calls), used for Apple's clipboard.
enum ClipboardZlib {
    /// Compresses like Apple's server: zlib level 9 (header `78 da`), ending with `Z_SYNC_FLUSH` and **not closing the stream**.
    /// Observed on real `screensharingd` payloads; imitate it so the receiver (the agent on the Mac) sees the familiar form.
    static func deflate(_ input: Data) throws -> Data {
        var stream = z_stream()
        guard deflateInit_(&stream, 9, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw RFBError.malformed("could not initialize the zlib compressor")
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
                guard status == Z_OK, stream.avail_in == 0 else { throw RFBError.malformed("zlib compression error \(status)") }
                return buffer.count - Int(stream.avail_out)
            }
        }
        return Data(output[0..<written])
    }

    /// Decompresses up to `maxOutput` bytes. Accepts both closed and unclosed streams (Apple's server sends the unclosed form).
    /// Exceeding the cap is an error, so malicious compressed data cannot force the client to allocate unbounded memory.
    static func inflate(_ input: Data, maxOutput: Int) throws -> Data {
        var stream = z_stream()
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw RFBError.malformed("could not initialize zlib")
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
                if output.count > maxOutput { throw RFBError.malformed("decompressed clipboard exceeds the cap of \(maxOutput) bytes") }
                switch status {
                case Z_STREAM_END: return
                case Z_OK: if stream.avail_in == 0 && stream.avail_out != 0 { return }
                case Z_BUF_ERROR: if stream.avail_in == 0 { return } else { throw RFBError.malformed("zlib made no progress") }
                default: throw RFBError.malformed("zlib error \(status)")
                }
            }
        }
        return output
    }
}
