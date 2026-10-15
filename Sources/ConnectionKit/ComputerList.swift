import Foundation

/// Một dòng trong màn hình chọn máy: máy đã lưu, hoặc máy mới tìm thấy trong mạng.
public struct ComputerRow: Identifiable, Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case saved(SavedConnection)
        case discovered(DiscoveredHost)
    }

    public var source: Source
    /// `true` khi Bonjour đang thấy máy này. Không thấy **không** có nghĩa là tắt: máy lưu theo địa chỉ thì ta không biết.
    public var isOnline: Bool

    public var id: String {
        switch source {
        case .saved(let connection): "saved-\(connection.id.uuidString)"
        case .discovered(let host): "found-\(host.id)"
        }
    }

    public var name: String {
        switch source {
        case .saved(let connection): connection.name
        case .discovered(let host): host.name
        }
    }

    /// Dòng phụ: `tài-khoản@máy` cho máy đã lưu, "Chia sẻ màn hình" cho máy mới thấy.
    public var subtitle: String {
        switch source {
        case .saved(let connection): connection.username.isEmpty ? connection.detail : "\(connection.username)@\(connection.detail)"
        case .discovered: "Chia sẻ màn hình"
        }
    }

    public var target: SavedConnection.Target {
        switch source {
        case .saved(let connection): connection.target
        case .discovered(let host): host.target
        }
    }
}

/// Ghép danh sách máy đã lưu với máy Bonjour thấy được thành hai nhóm hiển thị.
public enum ComputerList {
    public struct Sections: Equatable, Sendable {
        public var saved: [ComputerRow]
        public var nearby: [ComputerRow]
        public var isEmpty: Bool { saved.isEmpty && nearby.isEmpty }
    }

    /// - `saved`: giữ nguyên thứ tự đã cho (thường là mới dùng gần nhất lên đầu).
    /// - `nearby`: chỉ gồm máy **chưa** có trong danh sách đã lưu, để một máy không hiện hai lần.
    public static func sections(saved: [SavedConnection], discovered: [DiscoveredHost]) -> Sections {
        let discoveredKeys = Set(discovered.compactMap(\.target.bonjourKey))
        let savedKeys = Set(saved.compactMap(\.target.bonjourKey))
        return Sections(
            saved: saved.map { row in
                ComputerRow(source: .saved(row), isOnline: row.target.bonjourKey.map(discoveredKeys.contains) ?? false)
            },
            nearby: discovered
                .filter { !savedKeys.contains($0.target.bonjourKey ?? "") }
                .map { ComputerRow(source: .discovered($0), isOnline: true) }
        )
    }
}

private extension SavedConnection.Target {
    /// Khóa so sánh dịch vụ Bonjour; `nil` cho máy lưu theo địa chỉ (không so sánh được với dịch vụ).
    var bonjourKey: String? {
        if case .bonjour(let name, let type, let domain) = self { return "\(name).\(type)\(domain)" }
        return nil
    }
}
