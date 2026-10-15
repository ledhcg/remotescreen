import Foundation

/// Validation of the file name in `file.begin`. The helper never builds a path from a name it has not passed through here:
/// files only ever land in its inbox folder.
public enum LinkFileName {
    /// Returns `name` unchanged when it is a plain file name, otherwise throws.
    ///
    /// Rejected: empty, longer than `LinkLimits.maxFileNameBytes` UTF-8 bytes, `/`, `\`, `:`, `..` or any dot-prefixed name
    /// (hidden files, `.` and `..`), control characters (including NUL, newline, DEL), bidirectional override characters,
    /// names ending in a space or dot, zero-width and other invisible format characters, and names that begin with a
    /// combining mark.
    ///
    /// Every check works on Unicode scalars, the unit the file system sees, never on `Character`s: `String.hasPrefix(".")`
    /// compares grapheme clusters, so `".\u{301}"` would pass it while still creating a dot-prefixed file.
    public static func validated(_ name: String) throws -> String {
        let scalars = name.unicodeScalars
        guard let first = scalars.first else { throw LinkError.malformed("empty file name") }
        // The last base scalar: trailing combining marks must not hide a final dot or space.
        let last = scalars.reversed().first { !$0.properties.isGraphemeExtend } ?? first
        guard name.utf8.count <= LinkLimits.maxFileNameBytes else {
            throw LinkError.limitExceeded("file name is \(name.utf8.count) bytes, limit \(LinkLimits.maxFileNameBytes)")
        }
        guard first != ".", last != ".", last != " " else {
            throw LinkError.malformed("file name starts with a dot or ends with a dot or space")
        }
        guard !first.properties.isGraphemeExtend else {
            throw LinkError.malformed("file name starts with a combining mark")
        }
        for scalar in scalars {
            switch scalar.value {
            case 0x2F, 0x5C, 0x3A: throw LinkError.malformed("file name contains a path separator")
            case 0x00...0x1F, 0x7F...0x9F: throw LinkError.malformed("file name contains a control character")
            case 0x200E...0x200F, 0x202A...0x202E, 0x2066...0x2069: throw LinkError.malformed("file name contains a bidirectional control")
            case 0x200B...0x200D, 0x2060...0x2064, 0xFEFF, 0xFFF9...0xFFFB:
                throw LinkError.malformed("file name contains an invisible format character")
            default: continue
            }
        }
        return name
    }

    public static func isValid(_ name: String) -> Bool { (try? validated(name)) != nil }
}
