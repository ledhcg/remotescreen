import Foundation

/// Validation of the file name in `file.begin`. The helper never builds a path from a name it has not passed through here:
/// files only ever land in its inbox folder.
public enum LinkFileName {
    /// Returns `name` unchanged when it is a plain file name, otherwise throws.
    ///
    /// Rejected: empty, longer than `LinkLimits.maxFileNameBytes` UTF-8 bytes, `/`, `\`, `:`, `..` or any dot-prefixed name
    /// (hidden files, `.` and `..`), control characters (including NUL, newline, DEL), bidirectional override characters,
    /// and names ending in a space or dot.
    public static func validated(_ name: String) throws -> String {
        guard !name.isEmpty else { throw LinkError.malformed("empty file name") }
        guard name.utf8.count <= LinkLimits.maxFileNameBytes else {
            throw LinkError.limitExceeded("file name is \(name.utf8.count) bytes, limit \(LinkLimits.maxFileNameBytes)")
        }
        guard !name.hasPrefix("."), !name.hasSuffix("."), !name.hasSuffix(" ") else {
            throw LinkError.malformed("file name starts with a dot or ends with a dot or space")
        }
        for scalar in name.unicodeScalars {
            switch scalar.value {
            case 0x2F, 0x5C, 0x3A: throw LinkError.malformed("file name contains a path separator")
            case 0x00...0x1F, 0x7F...0x9F: throw LinkError.malformed("file name contains a control character")
            case 0x200E...0x200F, 0x202A...0x202E, 0x2066...0x2069: throw LinkError.malformed("file name contains a bidirectional control")
            default: continue
            }
        }
        return name
    }

    public static func isValid(_ name: String) -> Bool { (try? validated(name)) != nil }
}
