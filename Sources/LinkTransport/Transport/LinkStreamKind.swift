import Foundation
import LinkProtocol

/// Which logical stream a byte stream carries. Every stream starts with a small preamble naming its kind, so the receiver
/// knows what it is before it reads the first message.
///
/// Preamble: `u8 kind` followed, for `.window`, by `u32 window id` (little-endian).
///
/// | kind | value | opened by | direction | carries |
/// |---|---|---|---|---|
/// | control | 1 | iPad | both | session, pairing, apps, windows, menus, clipboard, files, stats |
/// | input | 2 | iPad | iPad → Mac | `input.*` only |
/// | window | 3 | Mac | Mac → iPad | video, surface and cursor messages of one window |
/// | audio | 4 | Mac | Mac → iPad | audio messages |
public enum LinkStreamKind: Sendable, Hashable {
    case control
    case input
    case window(WindowID)
    case audio

    /// Longest possible preamble.
    public static let maxPreambleBytes = 5

    var kindByte: UInt8 {
        switch self {
        case .control: 1
        case .input: 2
        case .window: 3
        case .audio: 4
        }
    }

    /// The iPad opens control and input streams; the Mac opens window and audio streams.
    var openedByClient: Bool {
        switch self {
        case .control, .input: true
        case .window, .audio: false
        }
    }

    /// Whether the side that did *not* open the stream may write to it.
    var isBidirectional: Bool { self == .control }

    public var preamble: Data {
        var bytes = [kindByte]
        if case .window(let id) = self {
            var v = id.rawValue.littleEndian
            withUnsafeBytes(of: &v) { bytes.append(contentsOf: $0) }
        }
        return Data(bytes)
    }

    public enum PreambleResult: Equatable, Sendable {
        /// More bytes are needed.
        case needMore
        /// A complete preamble of `consumed` bytes.
        case complete(LinkStreamKind, consumed: Int)
        /// The first byte is not a known kind.
        case invalid
    }

    public static func parsePreamble(_ bytes: some Collection<UInt8>) -> PreambleResult {
        guard let first = bytes.first else { return .needMore }
        switch first {
        case 1: return .complete(.control, consumed: 1)
        case 2: return .complete(.input, consumed: 1)
        case 4: return .complete(.audio, consumed: 1)
        case 3:
            guard bytes.count >= 5 else { return .needMore }
            let b = Array(bytes.prefix(5))
            let id = UInt32(b[1]) | UInt32(b[2]) << 8 | UInt32(b[3]) << 16 | UInt32(b[4]) << 24
            return .complete(.window(WindowID(rawValue: id)), consumed: 5)
        default: return .invalid
        }
    }
}
