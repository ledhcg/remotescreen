import Foundation

/// What the user is typing in the connection form, not yet validated.
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
        /// Username if the address has the form `account@host` (or `vnc://account@host`), to prefill the login field.
        public var username: String?

        public init(host: String, port: UInt16, username: String? = nil) {
            self.host = host
            self.port = port
            self.username = username
        }
    }

    /// Normalises and validates the address and port. Does not silently turn a bad port into 5900: `59OO` is an error, not 5900.
    ///
    /// Accepts a pasted `vnc://host:port`, and `host:port` when there is exactly one colon (more colons means IPv6).
    public func validated() -> Result<Validated, Problem> {
        var host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        var portText = port.trimmingCharacters(in: .whitespacesAndNewlines)

        if host.lowercased().hasPrefix("vnc://") { host.removeFirst("vnc://".count) }
        if let slash = host.firstIndex(of: "/") { host = String(host[..<slash]) } // drop any trailing path
        var typedUser: String?
        if let at = host.lastIndex(of: "@") { // "account@host": take the name to prefill, the rest is the address
            var user = host[..<at].trimmingCharacters(in: .whitespaces)
            // "account:password@host": do NOT put the password in the name field (it would be shown on screen). Drop the password part entirely.
            if let colon = user.firstIndex(of: ":") { user = String(user[..<colon]) }
            typedUser = user.isEmpty ? nil : user
            host = String(host[host.index(after: at)...])
        }

        if host.hasPrefix("["), let close = host.firstIndex(of: "]") {
            // IPv6 in square brackets, possibly with a port: "[fe80::1]:5901".
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
