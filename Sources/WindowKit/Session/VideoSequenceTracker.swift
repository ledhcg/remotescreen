import Foundation
import LinkProtocol

/// Follows the `sequence` numbers of one window's `video.frame`s (they wrap at 2^32). A gap means frames were lost on the way;
/// the client then sends `video.lost` so the helper repairs the stream from a long-term reference or a key frame.
public struct VideoSequenceTracker: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        /// The frame is the one expected (or the first of the stream).
        case inOrder
        /// Frames `first...last` (wrapping) never arrived.
        case gap(first: UInt32, last: UInt32)
        /// A frame older than one already seen (reordering or a repeat): do not decode it.
        case stale
    }

    private var expected: UInt32?

    public init() {}

    public mutating func observe(sequence: UInt32) -> Outcome {
        guard let expected else {
            self.expected = sequence &+ 1
            return .inOrder
        }
        // Signed distance on the wrapping circle: positive = ahead of what we expected.
        let distance = Int32(bitPattern: sequence &- expected)
        if distance == 0 {
            self.expected = sequence &+ 1
            return .inOrder
        }
        if distance > 0 {
            self.expected = sequence &+ 1
            return .gap(first: expected, last: sequence &- 1)
        }
        return .stale
    }

    /// The stream restarted (new `video.config`, new subscription): the next frame starts a new run.
    public mutating func reset() { expected = nil }

    /// Tokens to acknowledge for a frame. The helper keeps a long-term reference for every key and LTR frame and may only use one
    /// that this client has confirmed it decoded. The token is the frame's own sequence number.
    public static func ackTokens(for flags: LinkVideoFrameFlags, sequence: UInt32) -> [UInt32] {
        flags.contains(.key) || flags.contains(.ltr) ? [sequence] : []
    }
}
