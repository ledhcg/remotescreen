import Foundation
import Observation

/// Danh sách máy đã lưu cùng mật khẩu của chúng. Danh sách nằm trong file JSON, mật khẩu trong `SecretStore` (Keychain).
@MainActor
@Observable
public final class ConnectionsModel {
    public private(set) var list: ConnectionList
    /// Lỗi lưu gần nhất, để giao diện báo cho người dùng (việc lưu diễn ra sau khi kết nối nên không có chỗ ném lỗi tới).
    public var lastError: String?

    @ObservationIgnored private let store: ConnectionStore
    @ObservationIgnored private let secrets: SecretStore

    public init(store: ConnectionStore, secrets: SecretStore) {
        self.store = store
        self.secrets = secrets
        list = store.load()
    }

    /// Theo thứ tự hiển thị: mới dùng gần nhất lên đầu.
    public var saved: [SavedConnection] { list.sorted }

    /// Lưu hoặc cập nhật một máy.
    ///
    /// - Parameter password: `nil` giữ nguyên mật khẩu đang có; chuỗi rỗng xóa nó; chuỗi khác thì thay.
    /// - Throws: nếu ghi file thất bại, trạng thái trong bộ nhớ **không đổi** (không hiện một máy mà lần mở sau sẽ mất).
    public func save(_ connection: SavedConnection, password: String?) throws {
        var updated = list
        updated.upsert(connection)
        try store.save(updated)
        list = updated
        guard let password else { return }
        if password.isEmpty {
            try secrets.removePassword(for: connection.id)
        } else {
            try secrets.setPassword(password, for: connection.id)
        }
    }

    /// Máy đã lưu có cùng đích và tài khoản, để kết nối lại không tạo thêm bản sao.
    public func matching(target: SavedConnection.Target, username: String) -> SavedConnection? {
        list.items.first { $0.target == target && $0.username == username }
    }

    /// Máy đã lưu ứng với một đích, bất kể tài khoản. Nếu có nhiều tài khoản thì lấy cái dùng gần nhất. Dùng để điền sẵn
    /// tên tài khoản khi người dùng chạm một máy trong danh sách Bonjour mà họ từng đăng nhập.
    public func connection(for target: SavedConnection.Target) -> SavedConnection? {
        saved.first { $0.target == target }
    }

    /// Ghi nhớ một máy vừa kết nối thành công: cập nhật nếu đã có cùng đích và tài khoản (không tạo bản sao), rồi đưa nó
    /// lên đầu danh sách. Lỗi lưu không ném mà vào `lastError`, vì việc này diễn ra sau khi kết nối, không còn nơi nhận lỗi.
    public func remember(target: SavedConnection.Target, username: String, password: String, name: String) {
        let connection = matching(target: target, username: username)
            ?? SavedConnection(name: name, target: target, username: username)
        do {
            try save(connection, password: password)
            markUsed(connection)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Xóa máy và mật khẩu của nó, để Keychain không giữ lại rác.
    public func delete(_ connection: SavedConnection) throws {
        var updated = list
        updated.remove(id: connection.id)
        try store.save(updated)
        list = updated
        try secrets.removePassword(for: connection.id)
    }

    public func password(for connection: SavedConnection) -> String? {
        (try? secrets.password(for: connection.id)) ?? nil
    }

    /// Ghi nhận vừa kết nối, để máy này lên đầu danh sách. Lỗi ghi file bị bỏ qua: đây chỉ là thứ tự hiển thị.
    public func markUsed(_ connection: SavedConnection, at date: Date = Date()) {
        var updated = list
        updated.markUsed(id: connection.id, at: date)
        guard (try? store.save(updated)) != nil else { return }
        list = updated
    }
}
