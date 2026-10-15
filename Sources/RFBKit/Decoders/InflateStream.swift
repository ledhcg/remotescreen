import CZlib
import Foundation

/// Streaming zlib decompression that **keeps its state between calls**.
///
/// ZRLE (and Zlib, Tight) use a single zlib stream for the whole connection: each rectangle is a consecutive
/// segment of that stream and may refer back to the data of earlier rectangles. So
/// an `InflateStream` must live for the whole session and must not be recreated for each rectangle.
///
/// Not safe to use from multiple threads. Belongs to one `RFBSession` (actor).
final class InflateStream {
    private var stream = z_stream()
    private static let minimumGrowth = 64 * 1024
    /// Output buffer reused between calls: a 2560x1440 rectangle decompresses to tens of MB, and allocating and copying
    /// 64 KB chunks for every update (the old approach) took about a tenth of the decode time.
    private var scratch: UnsafeMutableRawPointer
    private var scratchCapacity: Int
    /// If the buffer has grown excessively (after a very large frame), it shrinks again on the next call.
    private static let retainedCapacity = 32 * 1024 * 1024

    init() throws {
        scratchCapacity = 1 << 20
        scratch = UnsafeMutableRawPointer.allocate(byteCount: scratchCapacity, alignment: 16)
        let status = inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else {
            scratch.deallocate()
            throw RFBError.malformed("could not initialize zlib: \(status)")
        }
    }

    deinit {
        inflateEnd(&stream)
        scratch.deallocate()
    }

    /// Decompresses `input` and returns all the corresponding output as an array (a copy).
    func inflate(_ input: Data, maxOutput: Int) throws -> [UInt8] {
        try withInflated(input, maxOutput: maxOutput) { Array($0) }
    }

    /// Decompresses `input` then hands the output to `body` **without copying**. The memory is valid only inside `body`
    /// (the next call overwrites it).
    ///
    /// - Parameter maxOutput: cap on the output size. Exceeding it is an error, so malicious compressed data
    ///   (a zip bomb) cannot force the client to allocate unbounded memory.
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
                if produced > maxOutput { throw RFBError.malformed("decompressed data exceeds the cap of \(maxOutput) bytes") }

                switch status {
                case Z_OK:
                    // Input remains or the buffer just filled: continue. Input exhausted and buffer has room: done.
                    if stream.avail_in == 0 && stream.avail_out != 0 { return }
                case Z_BUF_ERROR:
                    // Nothing left to do. Accept only if all input has been consumed.
                    if stream.avail_in == 0 { return }
                    throw RFBError.malformed("zlib made no progress (Z_BUF_ERROR)")
                case Z_STREAM_END:
                    throw RFBError.malformed("zlib stream ended early, the server must not close the stream mid-session")
                default:
                    throw RFBError.malformed("zlib error \(status)")
                }
            }
        }
        return try body(UnsafeBufferPointer(start: scratch.assumingMemoryBound(to: UInt8.self), count: produced))
    }

    /// Grows the buffer, keeping what has been written. Never goes past `maxOutput` by more than one chunk, so a zip bomb cannot balloon memory.
    private func grow(toAtLeast needed: Int, maxOutput: Int) throws {
        guard needed <= maxOutput + Self.minimumGrowth * 2 else {
            throw RFBError.malformed("decompressed data exceeds the cap of \(maxOutput) bytes")
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
