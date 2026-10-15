import Foundation

/// Phiên bản giao thức RFB, ví dụ `003.008`.
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

    /// Chuỗi 12 byte gửi trên đường truyền: `RFB 003.008\n`.
    public var wireString: String {
        func pad(_ n: Int) -> String { String(repeating: "0", count: max(0, 3 - String(n).count)) + String(n) }
        return "RFB \(pad(major)).\(pad(minor))\n"
    }

    public var description: String { String(wireString.dropLast()) }

    /// Phân tích đúng 12 byte `RFB xxx.yyy\n`.
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

    /// Phiên bản client sẽ trả lời server.
    ///
    /// Server có thể quảng cáo phiên bản không chuẩn. Apple gửi `003.889`, và các
    /// client khác đều xử lý nó như 3.8. Ta làm tương tự: 3.8 trở lên → 3.8,
    /// 3.7 → 3.7, 3.4–3.6 → 3.3 (theo thông lệ của client tham chiếu).
    public func negotiated() throws -> RFBVersion {
        guard major >= 3 else { throw RFBError.unsupportedVersion(self) }
        if major > 3 || minor >= 8 { return .v3_8 }
        if minor == 7 { return .v3_7 }
        return .v3_3
    }
}
