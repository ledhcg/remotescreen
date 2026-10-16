import ConnectionKit
import Foundation
import LinkProtocol
import LinkTransport
import Security
import UIKit

// Everything the app needs from the link's pairing API lives in this one file, so a change in `LinkTransport` pairing
// touches only here. The views and `AppModeConnection` call `LinkPairing`, never the pairing types directly.

/// The pins of paired Macs, one Keychain item per saved computer.
///
/// A pin is a public hash, not a secret, but it decides who this iPad trusts, so it lives in the Keychain (not in the JSON file next to
/// the saved computers, where a stray edit or restore could swap it). `AfterFirstUnlock` lets a reconnect work in the background.
struct KeychainPairedMacStore: PairedMacStore {
    let service: String

    init(service: String = "com.ledinhcuong.screon.paired-mac") { self.service = service }

    private func query(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id]
    }

    func mac(forComputer id: String) -> PairedMac? {
        var request = query(id)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(PairedMac.self, from: data)
    }

    func save(_ mac: PairedMac) throws {
        let data = try JSONEncoder().encode(mac)
        let status = SecItemUpdate(query(mac.computerID) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var add = query(mac.computerID)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(add as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        default:
            throw KeychainError(status: status)
        }
    }

    func remove(computerID: String) {
        SecItemDelete(query(computerID) as CFDictionary)
    }
}

/// What a successful pairing leaves behind for the saved computer.
struct PairingOutcome: Sendable, Equatable {
    var macName: String
    /// SHA-256 of the Mac's certificate key, lowercase hex.
    var identityHash: String
    var host: String
    var port: UInt16
    var pairedAt: Date

    var helperEndpoint: HelperEndpoint {
        HelperEndpoint(identityHash: identityHash, lastKnownHost: host, lastKnownPort: port, pairedAt: pairedAt)
    }
}

@available(iOS 26, *)
@MainActor
enum LinkPairing {
    static let identityLabel = "ipad"
    static let identityStore = KeychainIdentityStore()
    static let pairedMacs = KeychainPairedMacStore()

    // MARK: Identity and configuration

    static func identity() throws -> LinkSecIdentity {
        _ = try identityStore.loadOrCreate(role: .ipad, label: identityLabel)
        return LinkSecIdentity(try identityStore.secIdentity(label: identityLabel))
    }

    /// What this iPad can do, so the helper picks codecs and surfaces it can show.
    static var capabilities: LinkCapabilities { [.hevc, .h264, .ltr, .surfaces, .cursorShapes, .tablet] }

    /// `capabilities` plus what depends on the person's choices for this computer and on what this build can do: sound, files, rich
    /// clipboard types, and 10-bit video only when allowed.
    static func capabilities(for settings: AppModeSettings) -> LinkCapabilities {
        var result = capabilities.union([.clipboardRich, .files])
        if settings.playAudio { result.insert(.audio) }
        if settings.allowMain10 { result.insert(.main10) }
        return result
    }

    static var sceneLimits: LinkSceneLimits {
        LinkSceneLimits(maxWindows: 16, maxStreams: 32, maxPixelWidth: 4096, maxPixelHeight: 4096, maxFramesPerSecond: 120)
    }

    private static func configuration(
        mode: LinkClientMode, computerID: UUID, pin: Data?, sas: (@Sendable (String) async -> Bool)? = nil,
        settings: AppModeSettings = .standard
    ) throws -> LinkClientConfiguration {
        LinkClientConfiguration(
            identity: try identity(), deviceName: UIDevice.current.name, capabilities: capabilities(for: settings), sceneLimits: sceneLimits,
            mode: mode, pinnedMacSPKIHash: pin, transport: transportPreference, sasConfirmation: sas, pairedMacStore: pairedMacs,
            computerID: computerID.uuidString
        )
    }

    /// QUIC with TCP+TLS as the fallback. DEBUG builds can force TCP with `LINK_TRANSPORT=tcp`: in the iOS simulator, opening a
    /// client-initiated one-way QUIC stream (the input stream) fails with "Network is down", so the UI tests use TCP+TLS.
    private static var transportPreference: LinkTransportPreference {
        #if DEBUG
        if ProcessInfo.processInfo.environment["LINK_TRANSPORT"] == "tcp" { return .tcp }
        #endif
        return .automatic
    }

    /// Configuration for connecting to an already paired Mac. Throws `LinkSessionError.notAuthorized` when this iPad holds no pin for
    /// the computer: it has to be paired (again) first.
    static func reconnectConfiguration(
        computerID: UUID, resume: LinkResumeCredentials?, settings: AppModeSettings = .standard
    ) throws -> LinkClientConfiguration {
        guard let pinned = pairedMacs.mac(forComputer: computerID.uuidString) else { throw LinkSessionError.notAuthorized }
        return try configuration(mode: .reconnect(resume), computerID: computerID, pin: pinned.spkiHash, settings: settings)
    }

    static func isPaired(computerID: UUID) -> Bool { pairedMacs.mac(forComputer: computerID.uuidString) != nil }

    static func unpair(computerID: UUID) { pairedMacs.remove(computerID: computerID.uuidString) }

    // MARK: Pairing

    /// Pairs by the content of the QR code (or the link pasted instead). Tries the host hints of the code in order. Returns when the
    /// person at the Mac has approved the pairing.
    ///
    /// - Parameter addressOverride: connect here instead of the addresses in the code (test hooks only).
    static func pair(
        qrText: String, computerID: UUID, addressOverride: (host: String, port: UInt16?)? = nil
    ) async throws -> PairingOutcome {
        var payload = try PairingQRPayload.parse(qrText.trimmingCharacters(in: .whitespacesAndNewlines))
        if let addressOverride {
            payload.hostHints = [addressOverride.host]
            if let port = addressOverride.port { payload.port = port }
        }
        var lastError: Error = LinkSessionError.transport("no address")
        for host in payload.hostHints {
            do {
                let configuration = try configuration(
                    mode: .pairWithQR(payload), computerID: computerID, pin: payload.macSPKIHash)
                return try await finishPairing(host: host, port: payload.port, configuration: configuration)
            } catch let error as LinkSessionError where error.isPermanent {
                throw error // wrong code, refused, expired: another address will not change that
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// Pairs without a camera: the Mac and this iPad each show six digits. `confirm` is asked with this iPad's digits and answers
    /// whether the Mac shows the same.
    static func pairWithCode(
        host: String, port: UInt16, computerID: UUID, confirm: @escaping @Sendable (String) async -> Bool
    ) async throws -> PairingOutcome {
        let configuration = try configuration(mode: .pairWithSAS, computerID: computerID, pin: nil, sas: confirm)
        return try await finishPairing(host: host, port: port, configuration: configuration)
    }

    private static func finishPairing(host: String, port: UInt16, configuration: LinkClientConfiguration) async throws -> PairingOutcome {
        let connection = try await LinkConnection.connect(to: LinkEndpoint(host: host, port: port), configuration: configuration)
        defer { Task { await connection.close() } }
        let hash = connection.macSPKIHash
        let name = connection.newlyPairedMac?.name ?? connection.session.macName
        return PairingOutcome(
            macName: name, identityHash: hash.map { String(format: "%02x", $0) }.joined(), host: host, port: port,
            pairedAt: connection.newlyPairedMac?.pairedAt ?? Date()
        )
    }

    // MARK: Messages

    /// A sentence for a pairing error that the person can act on.
    static func message(for error: Error) -> String {
        if let error = error as? PairingError {
            switch error {
            case .expired: return String(localized: "This pairing code has expired. Show a new one on the Mac.")
            case .malformedPayload, .invalidInput: return String(localized: "This is not a Screon pairing code.")
            default: return String(localized: "The pairing code was not accepted.")
            }
        }
        if let error = error as? LinkSessionError {
            switch error {
            case .pinMismatch: return String(localized: "The Mac that answered is not the one in the pairing code.")
            case .pairingDenied(.userDenied), .approvalDenied: return String(localized: "The pairing was declined on the Mac.")
            case .pairingDenied(.expired): return String(localized: "This pairing code has expired. Show a new one on the Mac.")
            case .pairingDenied(.tooManyAttempts): return String(localized: "Too many attempts. Wait a moment and show a new code on the Mac.")
            case .pairingDenied: return String(localized: "The Mac did not accept the pairing.")
            case .sasRejected: return String(localized: "The codes did not match, so nothing was paired.")
            case .versionMismatch: return String(localized: "Screon and Screon Helper need to be updated to work together.")
            case .timeout: return String(localized: "The Mac did not answer. Check that Screon Helper is running and on the same network.")
            case .notAuthorized: return String(localized: "The Mac does not know this device yet. Pair it first.")
            default: return String(localized: "Could not reach the Mac. Check that Screon Helper is running and on the same network.")
            }
        }
        return String(localized: "Pairing failed.")
    }
}
