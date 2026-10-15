import Foundation

/// Lưu `ConnectionList` thành một file JSON.
public struct ConnectionStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Vị trí mặc định trong Application Support của app.
    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("connections.json")
    }

    /// Đọc danh sách. Chưa có file thì trả danh sách rỗng.
    ///
    /// File hỏng **không bị xóa**: nó được đổi tên thành `connections.corrupt-<thời điểm>.json` rồi trả danh sách rỗng,
    /// để người dùng không mất dữ liệu chỉ vì một lần ghi dở hay một phiên bản app cũ.
    public func load() -> ConnectionList {
        guard let data = try? Data(contentsOf: fileURL) else { return ConnectionList() }
        do {
            return try JSONDecoder().decode(ConnectionList.self, from: data)
        } catch {
            let stamp = Int(Date().timeIntervalSince1970)
            let backup = fileURL.deletingLastPathComponent()
                .appendingPathComponent("\(fileURL.deletingPathExtension().lastPathComponent).corrupt-\(stamp).json")
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            return ConnectionList()
        }
    }

    /// Ghi nguyên tử: hoặc file mới đầy đủ, hoặc file cũ nguyên vẹn, không bao giờ nửa vời.
    public func save(_ list: ConnectionList) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(list).write(to: fileURL, options: .atomic)
    }
}
