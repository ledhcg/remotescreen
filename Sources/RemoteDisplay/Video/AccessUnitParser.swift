import Foundation

/// Validates the length-prefixed NAL structure of an access unit received from the network before it reaches VideoToolbox, which would trust
/// the lengths. Server data is hostile: every length is checked against the bytes that remain.
enum AccessUnitParser {
    /// Largest access unit accepted (a 4K key frame at a high bitrate is far below this).
    static let maxAccessUnitSize = 16 * 1024 * 1024
    /// Most NAL units in one access unit (slices, SEI, parameter sets).
    static let maxNALUnits = 1024
    static let maxParameterSetSize = 4096
    static let maxParameterSets = 16
    static let maxDimension = 16384
    static let maxPixels = 32 * 1024 * 1024

    enum Failure: Error, Equatable {
        case empty
        case tooLarge
        case truncatedLength
        case zeroLengthNAL
        case lengthExceedsData
        case tooManyNALUnits
        case forbiddenBit
    }

    /// Returns the number of NAL units, or throws if the structure is not exactly `[length][NAL]...` covering all bytes.
    static func validate(_ bytes: UnsafeRawBufferPointer, lengthSize: Int) -> Result<Int, Failure> {
        guard (1...4).contains(lengthSize) else { return .failure(.truncatedLength) }
        let total = bytes.count
        guard total > 0 else { return .failure(.empty) }
        guard total <= maxAccessUnitSize else { return .failure(.tooLarge) }
        var offset = 0
        var count = 0
        while offset < total {
            guard total - offset >= lengthSize else { return .failure(.truncatedLength) }
            var length = 0
            for i in 0..<lengthSize { length = (length << 8) | Int(bytes[offset + i]) }
            offset += lengthSize
            guard length > 0 else { return .failure(.zeroLengthNAL) }
            guard length <= total - offset else { return .failure(.lengthExceedsData) }
            // forbidden_zero_bit is the top bit of the first NAL header byte in both H.264 and HEVC.
            guard bytes[offset] & 0x80 == 0 else { return .failure(.forbiddenBit) }
            offset += length
            count += 1
            guard count <= maxNALUnits else { return .failure(.tooManyNALUnits) }
        }
        return .success(count)
    }

    static func validate(_ data: Data, lengthSize: Int) -> Result<Int, Failure> {
        data.withUnsafeBytes { validate($0, lengthSize: lengthSize) }
    }

    static func validateDimensions(width: Int, height: Int) -> Bool {
        width > 0 && height > 0 && width <= maxDimension && height <= maxDimension && width * height <= maxPixels
    }

    static func validate(_ config: VideoStreamConfig) throws {
        guard (1...4).contains(config.nalLengthSize) else { throw VideoStreamError.invalidNALLengthSize(config.nalLengthSize) }
        guard config.bitDepth == 8 || config.bitDepth == 10 else { throw VideoStreamError.invalidBitDepth(config.bitDepth) }
        let minimum = config.codec == .hevc ? 3 : 2
        guard config.parameterSets.count >= minimum, config.parameterSets.count <= maxParameterSets else {
            throw VideoStreamError.invalidParameterSets("expected \(minimum)...\(maxParameterSets) parameter sets, got \(config.parameterSets.count)")
        }
        for set in config.parameterSets {
            guard !set.isEmpty, set.count <= maxParameterSetSize else {
                throw VideoStreamError.invalidParameterSets("parameter set of \(set.count) bytes")
            }
            guard set[set.startIndex] & 0x80 == 0 else { throw VideoStreamError.invalidParameterSets("forbidden bit set") }
        }
    }
}
