import Foundation

/// Dữ liệu người dùng đang nhập trong form kết nối, chưa kiểm tra.
public struct ConnectionDraft: Equatable, Sendable {
    public var host = ""
    public var port = "5900"
    public var username = ""

    public init(host: String = "", port: String = "5900", username: String = "") {
        self.host = host
        self.port = port
        self.username = username
    }

    public enum Problem: Error, Equatable, Sendable {
        case emptyHost
        case invalidPort
    }

    public struct Validated: Equatable, Sendable {
        public var host: String
        public var port: UInt16
        /// Tên tài khoản nếu địa chỉ có dạng `tài-khoản@máy` (hoặc `vnc://tài-khoản@máy`), để điền sẵn vào ô đăng nhập.
        public var username: String?

        public init(host: String, port: UInt16, username: String? = nil) {
            self.host = host
            self.port = port
            self.username = username
        }
    }

    /// Chuẩn hóa và kiểm tra địa chỉ và cổng. Không lặng lẽ đổi cổng sai về 5900: `59OO` là lỗi, không phải 5900.
    ///
    /// Chấp nhận dán nguyên `vnc://máy:cổng`, và `máy:cổng` khi chỉ có đúng một dấu hai chấm (nhiều dấu hai chấm là IPv6).
    public func validated() -> Result<Validated, Problem> {
        var host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        var portText = port.trimmingCharacters(in: .whitespacesAndNewlines)

        if host.lowercased().hasPrefix("vnc://") { host.removeFirst("vnc://".count) }
        if let slash = host.firstIndex(of: "/") { host = String(host[..<slash]) } // bỏ đường dẫn thừa
        var typedUser: String?
        if let at = host.lastIndex(of: "@") { // "tài-khoản@máy": lấy tên để điền sẵn, phần còn lại là địa chỉ
            var user = host[..<at].trimmingCharacters(in: .whitespaces)
            // "tài-khoản:mật-khẩu@máy": KHÔNG đưa mật khẩu vào ô tên (nó sẽ hiện ra màn hình). Bỏ hẳn phần mật khẩu.
            if let colon = user.firstIndex(of: ":") { user = String(user[..<colon]) }
            typedUser = user.isEmpty ? nil : user
            host = String(host[host.index(after: at)...])
        }

        if host.hasPrefix("["), let close = host.firstIndex(of: "]") {
            // IPv6 trong ngoặc vuông, có thể kèm cổng: "[fe80::1]:5901".
            let rest = host[host.index(after: close)...]
            if rest.hasPrefix(":") { portText = String(rest.dropFirst()) } else if !rest.isEmpty { return .failure(.emptyHost) }
            host = String(host[host.index(after: host.startIndex)..<close])
        } else {
            let colons = host.filter { $0 == ":" }.count
            if colons == 1, let colon = host.firstIndex(of: ":") {
                portText = String(host[host.index(after: colon)...])
                host = String(host[..<colon])
            }
        }

        guard !host.isEmpty else { return .failure(.emptyHost) }
        if portText.isEmpty { portText = "5900" }
        guard let value = UInt16(portText), value > 0 else { return .failure(.invalidPort) }
        return .success(Validated(host: host, port: value, username: typedUser))
    }
}
