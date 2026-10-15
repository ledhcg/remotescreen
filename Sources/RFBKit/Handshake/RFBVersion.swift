import Foundation

/// RFB protocol version, for example `003.008`.
public struct RFBVersion: Equatable, Hashable, Comparable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int

    public init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    public static let v3_3 = RFBVersion(major: 3, minor: 3)
    public static let v3_7 = RFBVersion(major: 3, minor: 7)
    public static let v3_8 = RFBVersion(major: 3, minor: 8)

    /// The 12-byte string sent on the wire: `RFB 003.008\n`.
    public var wireString: String {
        func pad(_ n: Int) -> String { String(repeating: "0", count: max(0, 3 - String(n).count)) + String(n) }
        return "RFB \(pad(major)).\(pad(minor))\n"
    }

    public var description: String { String(wireString.dropLast()) }

    /// Parses exactly 12 bytes `RFB xxx.yyy\n`.
    public init(parsing data: Data) throws {
        let text = String(decoding: data, as: UTF8.self)
        let printable = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard data.count == 12, text.hasPrefix("RFB "), text.hasSuffix("\n"),
              let major = Int(text.dropFirst(4).prefix(3)),
              text.dropFirst(7).first == ".",
              let minor = Int(text.dropFirst(8).prefix(3))
        else { throw RFBError.invalidVersionString(printable) }
        self.init(major: major, minor: minor)
    }

    public static func < (lhs: RFBVersion, rhs: RFBVersion) -> Bool {
        (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
    }

    /// The version the client replies to the server with.
    ///
    /// A server may advertise a non-standard version. Apple sends `003.889`, and other
    /// clients all treat it as 3.8. We do the same: 3.8 or later → 3.8,
    /// 3.7 → 3.7, 3.4–3.6 → 3.3 (following the reference client's convention).
    public func negotiated() throws -> RFBVersion {
        guard major >= 3 else { throw RFBError.unsupportedVersion(self) }
        if major > 3 || minor >= 8 { return .v3_8 }
        if minor == 7 { return .v3_7 }
        return .v3_3
    }
}
