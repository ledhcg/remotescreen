import Foundation

/// Why a link message could not be encoded or decoded.
///
/// Decoders throw this and never trap. The peer is untrusted: a hostile iPad can attack the helper, and a hostile or
/// spoofed Mac can attack the iPad. The session layer closes the connection on any of these.
public enum LinkError: Error, Equatable, Sendable {
    /// The bytes do not form a valid message: truncated, trailing bytes, bad enum value, invalid UTF-8, NaN coordinate...
    case malformed(String)
    /// A message type below `0x8000` that this build does not know. It cannot be skipped, so the connection must be closed.
    case unsupportedMessage(UInt16)
    /// A declared length or count is above its cap (`LinkLimits`). Raised before anything is buffered or allocated.
    case limitExceeded(String)
    /// The *sender* tried to encode a value the wire format cannot carry (string too long, wrong digest size...).
    case invalidValue(String)
}
