import Foundation

/// Every cap of the link protocol, in one place. A length or count read from the wire is compared against these before
/// anything is buffered, allocated or indexed.
public enum LinkLimits {
    // MARK: Framing

    /// Size of the frame header: `u16 type | u32 length`.
    public static let frameHeaderBytes = 6
    /// Largest payload of an ordinary control message.
    public static let maxControlMessageBytes = 1 << 20
    /// Largest `video.frame` payload (one access unit) and largest `surface.snapshot` image.
    public static let maxVideoAccessUnitBytes = 8 << 20
    /// Largest payload of an unknown *ignorable* message. It is skipped without buffering, but still bounded.
    public static let maxIgnorablePayloadBytes = 16 << 20
    /// Types at or above this value are ignorable: an unknown one is skipped by its length.
    public static let ignorableTypeThreshold: UInt16 = 0x8000
    /// Headroom for the fixed fields in front of a large blob (ids, flags, type string).
    static let blobMessageOverhead = 1024

    // MARK: Strings (UTF-8 bytes, not characters)

    public static let maxTitleBytes = 1024
    public static let maxNameBytes = 256
    public static let maxDeviceNameBytes = 256
    public static let maxBundleIDBytes = 255
    public static let maxReasonBytes = 256
    public static let maxFileNameBytes = 255
    public static let maxMenuTitleBytes = 256
    public static let maxKeyEquivalentBytes = 16
    /// Pasteboard type identifier (UTI-like).
    public static let maxClipboardTypeBytes = 255
    /// `input.text`.
    public static let maxTextInputBytes = 1024

    // MARK: Counts

    public static let maxWindowsPerSnapshot = 1024
    public static let maxApps = 4096
    public static let maxDisplays = 16
    public static let maxWindowsInOrder = 1024
    public static let maxStatsWindows = 1024
    public static let maxClipboardTypes = 32
    public static let maxParameterSets = 8
    public static let maxParameterSetBytes = 4096
    public static let maxLTRTokens = 64

    // MARK: Menus

    public static let maxMenuDepth = 6
    public static let maxMenuItemsPerLevel = 500
    /// Across the whole tree, so 6 levels of 500 cannot multiply out.
    public static let maxMenuItemsTotal = 5000

    // MARK: Binary payloads

    public static let maxIconPNGBytes = 256 << 10
    public static let maxIconPixelSize: UInt16 = 1024
    public static let maxCursorPNGBytes = 64 << 10
    public static let maxSurfaceImageBytes = maxVideoAccessUnitBytes
    public static let maxAudioPacketBytes = 16 << 10
    public static let maxFileChunkBytes = 1 << 20
    public static let maxFileBytes: UInt64 = 2 << 30
    public static let maxClipboardBytes = 16 << 20

    /// Snapshot and app lists are bigger than ordinary control messages (thousands of entries with names).
    public static let maxListMessageBytes = 4 << 20
    public static let maxMenuTreeMessageBytes = 2 << 20

    // MARK: Numbers

    /// Largest window or surface dimension in pixels.
    public static let maxPixelDimension: UInt32 = 16384
    public static let maxFramesPerSecond: UInt16 = 240
    /// Largest absolute Mac coordinate or size in points. Rejects absurd values that would overflow later arithmetic.
    public static let maxCoordinate: Double = 1_000_000
    public static let maxScale: Double = 16
    public static let minSampleRate: UInt32 = 8_000
    public static let maxSampleRate: UInt32 = 192_000
    public static let maxAudioChannels: UInt8 = 8

    /// Payload cap for a known message type, or `nil` when the type is unknown (see `LinkMessageType`).
    public static func maxPayloadBytes(forType type: UInt16) -> Int? {
        guard let known = LinkMessageType(rawValue: type) else { return nil }
        switch known {
        case .snapshot, .appsItems: return maxListMessageBytes
        case .menuTree: return maxMenuTreeMessageBytes
        case .videoFrame, .surfaceSnapshot: return maxVideoAccessUnitBytes + blobMessageOverhead
        case .clipboardData: return maxClipboardBytes + blobMessageOverhead
        case .fileChunk: return maxFileChunkBytes + blobMessageOverhead
        default: return maxControlMessageBytes
        }
    }
}
