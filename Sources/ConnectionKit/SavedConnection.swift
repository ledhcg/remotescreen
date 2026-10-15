import Foundation

/// Một máy đã lưu. Mật khẩu **không** nằm ở đây mà trong `SecretStore` (Keychain), khóa theo `id`.
public struct SavedConnection: Codable, Identifiable, Equatable, Sendable {
    /// Cách tìm máy: theo địa chỉ, hoặc theo dịch vụ Bonjour (không phụ thuộc IP đổi theo DHCP).
    public enum Target: Codable, Equatable, Sendable {
        case host(String, port: UInt16)
        case bonjour(name: String, type: String, domain: String)
    }

    public var id: UUID
    /// Tên hiển thị trong danh sách.
    public var name: String
    public var target: Target
    public var username: String
    public var lastUsed: Date?

    public init(id: UUID = UUID(), name: String, target: Target, username: String, lastUsed: Date? = nil) {
        self.id = id
        self.name = name
        self.target = target
        self.username = username
        self.lastUsed = lastUsed
    }

    /// Dòng phụ trong danh sách: địa chỉ hoặc loại dịch vụ.
    public var detail: String {
        switch target {
        case .host(let host, let port): port == 5900 ? host : "\(host):\(port)"
        case .bonjour(let name, _, _): name
        }
    }
}

/// Danh sách máy đã lưu. Thuần giá trị, nên mọi thay đổi test được không cần đĩa.
public struct ConnectionList: Codable, Equatable, Sendable {
    public private(set) var items: [SavedConnection]

    public init(_ items: [SavedConnection] = []) {
        self.items = items
    }

    /// Thêm mới, hoặc thay thế mục có cùng `id`.
    public mutating func upsert(_ connection: SavedConnection) {
        if let index = items.firstIndex(where: { $0.id == connection.id }) {
            items[index] = connection
        } else {
            items.append(connection)
        }
    }

    public mutating func remove(id: UUID) {
        items.removeAll { $0.id == id }
    }

    public mutating func markUsed(id: UUID, at date: Date) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].lastUsed = date
    }

    /// Mới dùng gần nhất lên đầu; máy chưa dùng bao giờ xếp sau, theo tên (không phân biệt hoa thường và dấu).
    public var sorted: [SavedConnection] {
        items.sorted { a, b in
            switch (a.lastUsed, b.lastUsed) {
            case let (x?, y?) where x != y: return x > y
            case (.some, .none): return true
            case (.none, .some): return false
            default: return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
    }
}
