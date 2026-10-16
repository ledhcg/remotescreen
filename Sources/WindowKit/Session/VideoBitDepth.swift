import Foundation
import LinkProtocol

/// Bit depth of a stream, read from its parameter sets, so a Main 10 HEVC stream is decoded to 10-bit pictures and nothing else is.
public enum VideoBitDepth {
    /// 10 when the HEVC SPS says profile Main 10 (`general_profile_idc` 2, or a compatibility flag for it); 8 for everything else,
    /// including H.264 and any parameter set that is too short or not an SPS. Never traps on hostile input.
    public static func bitDepth(codec: LinkVideoCodec, parameterSets: [Data]) -> Int {
        guard codec == .hevc else { return 8 }
        for set in parameterSets {
            let bytes = [UInt8](set.prefix(16))
            // NAL header (2 bytes), then vps id / max sub layers (1 byte), then profile space, tier, profile idc (1 byte),
            // then 32 compatibility flags (4 bytes).
            guard bytes.count >= 8, (bytes[0] >> 1) & 0x3F == 33 else { continue }
            let profile = bytes[3] & 0x1F
            let compatibility = UInt32(bytes[4]) << 24 | UInt32(bytes[5]) << 16 | UInt32(bytes[6]) << 8 | UInt32(bytes[7])
            let main10Flag = compatibility & (1 << (31 - 2)) != 0
            return profile == 2 || (profile != 1 && main10Flag) ? 10 : 8
        }
        return 8
    }
}
