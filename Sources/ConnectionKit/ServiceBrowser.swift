import Foundation
import Network
import Observation

/// Một máy tìm thấy qua Bonjour (dịch vụ `_rfb._tcp`: Chia sẻ màn hình của macOS, và máy chủ VNC khác).
public struct DiscoveredHost: Identifiable, Hashable, Sendable {
    public var name: String
    public var type: String
    public var domain: String

    public init(name: String, type: String = ServiceBrowser.serviceType, domain: String = "local.") {
        self.name = name
        self.type = type
        self.domain = domain
    }

    public var id: String { "\(name).\(type)\(domain)" }

    /// Đích để lưu và nối: theo dịch vụ, không phụ thuộc IP đổi theo DHCP.
    public var target: SavedConnection.Target { .bonjour(name: name, type: type, domain: domain) }
}

extension SavedConnection.Target {
    /// Điểm cuối để `NWConnection` nối tới. Dịch vụ Bonjour được hệ thống phân giải khi nối.
    public var endpoint: NWEndpoint {
        switch self {
        case .host(let host, let port):
            .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? .any)
        case .bonjour(let name, let type, let domain):
            .service(name: name, type: type, domain: domain, interface: nil)
        }
    }
}

/// Tìm máy trong mạng nội bộ bằng Bonjour.
///
/// Lần đầu chạy, iOS hỏi quyền **Mạng cục bộ**. Bị từ chối thì `denied` thành `true` và danh sách luôn rỗng.
@MainActor
@Observable
public final class ServiceBrowser {
    public nonisolated static let serviceType = "_rfb._tcp"

    public private(set) var hosts: [DiscoveredHost] = []
    /// `true` khi iOS chặn việc tìm máy vì chưa có quyền Mạng cục bộ.
    public private(set) var denied = false

    @ObservationIgnored private var browser: NWBrowser?
    /// Người dùng vẫn đang ở màn hình chọn máy: lỗi thì tự tìm lại thay vì để danh sách đứng im tới khi rời màn hình.
    @ObservationIgnored private var wantsBrowsing = false
    static let restartDelay: Duration = .seconds(3)

    public init() {}

    /// Chuyển kết quả của `NWBrowser` thành danh sách hiển thị: chỉ lấy dịch vụ Bonjour, bỏ trùng, xếp theo tên.
    nonisolated static func hosts(from endpoints: some Sequence<NWEndpoint>) -> [DiscoveredHost] {
        var seen = Set<DiscoveredHost>()
        for endpoint in endpoints {
            guard case let .service(name, type, domain, _) = endpoint else { continue }
            seen.insert(DiscoveredHost(name: name, type: type, domain: domain))
        }
        return seen.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func start() {
        wantsBrowsing = true
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = Self.hosts(from: results.map(\.endpoint))
            Task { @MainActor in self?.hosts = found }
        }
        browser.stateUpdateHandler = { [weak self] state in
            let isDenied: Bool
            switch state {
            case .failed(let error), .waiting(let error):
                if case .dns(let code) = error, code == -65570 { isDenied = true } else { isDenied = false }
            default:
                isDenied = false
            }
            let failed: Bool
            if case .failed = state { failed = true } else { failed = false }
            Task { @MainActor in
                self?.denied = isDenied
                if failed { self?.restartAfterFailure() }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    /// `NWBrowser` hỏng thì không tự chạy lại; `start()` cũng bỏ qua vì `browser` vẫn còn. Dọn nó rồi thử lại sau một lúc.
    private func restartAfterFailure() {
        browser?.cancel()
        browser = nil
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.restartDelay)
            guard let self, self.wantsBrowsing, self.browser == nil else { return }
            self.start()
        }
    }

    public func stop() {
        wantsBrowsing = false
        browser?.cancel()
        browser = nil
        hosts = []
    }
}
