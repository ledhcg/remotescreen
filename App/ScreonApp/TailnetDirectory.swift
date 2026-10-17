import ConnectionKit
import Foundation
import Observation
import Security
import SessionKit

/// The Tailscale API token, in the device Keychain: `WhenUnlockedThisDeviceOnly`, never synced, never in a file, a log or a URL.
struct TailscaleTokenStore {
    private let service = "com.ledinhcuong.screon.tailscale"
    private let account = "api-token"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    func token() -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func setToken(_ token: String) throws {
        let data = Data(token.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(add as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        default:
            throw KeychainError(status: status)
        }
    }

    func removeToken() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

/// The devices of the user's tailnet, read from the Tailscale API with the token the user saved. Empty without a token.
///
/// The list is only worth having while Tailscale is connected on this device and the user allows it, so a refresh is skipped otherwise
/// (and what is held is dropped), and it is read again when Tailscale comes up.
@MainActor
@Observable
final class TailnetDirectory {
    static let shared = TailnetDirectory()

    enum Status: Equatable {
        /// No token saved.
        case notConfigured
        case idle
        case loading
        case loaded(Date)
        case failed(TailscaleAPI.Failure)
    }

    private(set) var devices: [TailnetDevice] = []
    private(set) var status: Status = .notConfigured

    @ObservationIgnored private let store = TailscaleTokenStore()
    @ObservationIgnored private var task: Task<Void, Never>?
    /// A list read less than this long ago is still good: opening the list screen again does not call the API again.
    @ObservationIgnored private let freshFor: TimeInterval = 60

    private init() {
        status = store.token() == nil ? .notConfigured : .idle
    }

    var hasToken: Bool { status != .notConfigured }

    /// Saves the token (an empty one removes it) and reads the list at once.
    func setToken(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try store.removeToken()
            task?.cancel()
            devices = []
            status = .notConfigured
        } else {
            try store.setToken(trimmed)
            status = .idle
            refresh(force: true)
        }
    }

    /// Reads the list when it is useful: a token is saved, the user allows Tailscale, and Tailscale is connected on this device.
    func refresh(force: Bool = false) {
        guard let token = store.token() else {
            devices = []
            status = .notConfigured
            return
        }
        guard NetworkPreferences.useTailscale, NetworkMonitor.shared.snapshot.usesTailscale else {
            task?.cancel()
            devices = []
            status = .idle
            return
        }
        if case .loading = status { return }
        if !force, case .loaded(let date) = status, Date().timeIntervalSince(date) < freshFor { return }
        status = .loading
        task = Task { [weak self] in
            do {
                let found = try await TailscaleAPI.devices(token: token)
                guard !Task.isCancelled else { return }
                self?.devices = found
                self?.status = .loaded(Date())
            } catch let failure as TailscaleAPI.Failure {
                guard !Task.isCancelled else { return }
                self?.status = .failed(failure)
            } catch {
                guard !Task.isCancelled else { return }
                self?.status = .failed(.network)
            }
        }
    }
}
