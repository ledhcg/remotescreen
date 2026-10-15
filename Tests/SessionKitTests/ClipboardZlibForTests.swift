import CZlib
import Foundation

/// Nén zlib một lần cho test (RFBKit giữ bộ nén thật ở dạng nội bộ).
enum ClipboardZlibForTests {
    static func deflate(_ input: Data) throws -> Data {
        var bound = compressBound(uLong(input.count))
        var output = [UInt8](repeating: 0, count: Int(bound))
        let status = input.withUnsafeBytes { raw in
            compress2(&output, &bound, raw.bindMemory(to: Bytef.self).baseAddress, uLong(input.count), 9)
        }
        guard status == Z_OK else { throw CocoaError(.fileWriteUnknown) }
        return Data(output[0..<Int(bound)])
    }
}
