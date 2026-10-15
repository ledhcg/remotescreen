import CryptoKit
import Foundation
import Testing
@testable import RFBKit

@Suite("InflateStream (continuous zlib)")
struct InflateStreamTests {
    @Test func keepsDictionaryAcrossChunks() throws {
        let stream = try InflateStream()
        let first = try stream.inflate(Data(hex: ZlibVectors.continuationFirst), maxOutput: 1 << 20)
        #expect(Data(first) == Data(hex: ZlibVectors.text))

        // The second segment can only be decoded because it back-references data in the first.
        let second = try stream.inflate(Data(hex: ZlibVectors.continuationSecond), maxOutput: 1 << 20)
        #expect(Data(second) == Data(hex: ZlibVectors.continuationSecondExpected))
    }

    @Test func aFreshStreamCannotDecodeTheSecondChunk() throws {
        // This is exactly the bug that would occur if the decoder created a new zlib stream for each rectangle.
        let stream = try InflateStream()
        #expect(throws: RFBError.self) {
            try stream.inflate(Data(hex: ZlibVectors.continuationSecond), maxOutput: 1 << 20)
        }
    }

    @Test func outputLargerThanTheInternalBufferIsCompleteAndExact() throws {
        let output = try InflateStream().inflate(Data(hex: ZlibVectors.bigCompressed), maxOutput: 1 << 20)
        #expect(output.count == ZlibVectors.bigLength)
        #expect(output.count > 4 * 64 * 1024)
        #expect(Insecure.MD5.hash(data: output).map { String(format: "%02x", $0) }.joined() == ZlibVectors.bigMD5)
    }

    /// Design note: zlib checks Adler32 only at the end of the stream, and an RFB stream never ends, so a flipped
    /// bit mid-stream still decompresses to wrong data without any error. Detecting a desynchronized stream must rely on ZRLE's
    /// own checks (extra/missing bytes, a run exceeding the tile, a wrong palette index). Here we test only the structural
    /// zlib errors that the library really does catch.
    @Test func structurallyInvalidDataThrows() throws {
        #expect(throws: RFBError.self) {
            try InflateStream().inflate(Data(hex: ZlibVectors.corrupted), maxOutput: 1 << 20)
        }
    }

    @Test func outputCapStopsZipBombs() throws {
        let bomb = Data(hex: ZlibVectors.bomb)
        #expect(bomb.count < 4096)
        #expect(throws: RFBError.self) { try InflateStream().inflate(bomb, maxOutput: 1 << 20) }

        let allowed = try InflateStream().inflate(bomb, maxOutput: 4 << 20)
        #expect(allowed.count == ZlibVectors.bombLength)
        #expect(allowed.allSatisfy { $0 == 0 })
    }

    @Test func emptyInputProducesEmptyOutput() throws {
        #expect(try InflateStream().inflate(Data(), maxOutput: 100).isEmpty)
    }
}
