import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import HelperCore
import LinkProtocol
import LinkTransport
import Observation
import os
import ServiceManagement

enum PermissionKind: CaseIterable {
    case accessibility, postEvents, screenRecording
}

enum LocalNetworkNote {
    /// There is no query API for Local Network. `listening` is the closest signal: the listener started.
    case unknown, listening
}

struct PermissionSnapshot: Equatable {
    var accessibility = false
    var postEvents = false
    var screenRecording = false

    var allGranted: Bool { accessibility && postEvents && screenRecording }
    func isGranted(_ kind: PermissionKind) -> Bool {
        switch kind {
        case .accessibility: accessibility
        case .postEvents: postEvents
        case .screenRecording: screenRecording
        }
    }
}

enum PairingState: Equatable {
    case idle
    /// `link` is the text the QR code holds, for "Copy Link" (an iPad without a usable camera pastes it).
    case qr(image: NSImage?, link: String, expiry: Date)
    case sas(expiry: Date)
    case paired(name: String)
    case failed
}

enum UpdateState: Equatable {
    case idle
    case checking
    case upToDate
    case available(version: String, releaseURL: URL)
    case needsNewerMacOS(version: String)
    case notConfigured
    case failed
}

enum SettingsKey {
    static let askBeforeEachSession = "askBeforeEachSession"
    static let useVirtualStage = "useVirtualStage"
    static let audioEnabled = "audioEnabled"
    static let checkUpdatesAutomatically = "checkUpdatesAutomatically"
    static let onboardingDone = "onboardingDone"
    static let lastUpdateCheck = "lastUpdateCheck"
}

/// The helper's state, for the menu bar UI. Owns the `HelperService`, the link listener and the paired-device store.
@MainActor @Observable
final class HelperModel {
    static let shared = HelperModel()
    static let identityLabel = "link"
    static let identityTagPrefix = "app.screon.helper.identity"

    // MARK: Published state

    private(set) var status = HelperStatus()
    private(set) var startError: String?
    private(set) var pairedDevices: [PairedDevice] = []
    private(set) var pairing: PairingState = .idle
    private(set) var permissions = PermissionSnapshot()
    private(set) var update: UpdateState = .idle
    private(set) var loginItemStatus: SMAppService.Status = .notRegistered
    private(set) var loginItemError = false
    /// A setting that needs the service to restart changed while an iPad was connected.
    private(set) var restartPending = false

    var askBeforeEachSession: Bool { didSet { UserDefaults.standard.set(askBeforeEachSession, forKey: SettingsKey.askBeforeEachSession) } }
    var useVirtualStage: Bool {
        didSet {
            UserDefaults.standard.set(useVirtualStage, forKey: SettingsKey.useVirtualStage)
            serviceSettingChanged()
        }
    }
    var audioEnabled: Bool {
        didSet {
            UserDefaults.standard.set(audioEnabled, forKey: SettingsKey.audioEnabled)
            serviceSettingChanged()
        }
    }
    var checkUpdatesAutomatically: Bool {
        didSet { UserDefaults.standard.set(checkUpdatesAutomatically, forKey: SettingsKey.checkUpdatesAutomatically) }
    }

    // MARK: Collaborators

    let windows = WindowPresenter()
    @ObservationIgnored private let approvals = ApprovalCenter()
    @ObservationIgnored private let log = Logger(subsystem: "app.screon.helper", category: "app")
    @ObservationIgnored private var service: HelperService?
    @ObservationIgnored private var listener: LinkServerListener?
    @ObservationIgnored private var store: FilePairedDeviceStore?
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var permissionTask: Task<Void, Never>?
    @ObservationIgnored private var pairingTask: Task<Void, Never>?
    @ObservationIgnored private var pairingBaseline: Set<Data> = []
    @ObservationIgnored private var restarting = false

    private init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            SettingsKey.askBeforeEachSession: false,  // decision 5: approval only at first pairing
            SettingsKey.useVirtualStage: true,
            SettingsKey.audioEnabled: false,
            SettingsKey.checkUpdatesAutomatically: true,
        ])
        askBeforeEachSession = defaults.bool(forKey: SettingsKey.askBeforeEachSession)
        useVirtualStage = defaults.bool(forKey: SettingsKey.useVirtualStage)
        audioEnabled = defaults.bool(forKey: SettingsKey.audioEnabled)
        checkUpdatesAutomatically = defaults.bool(forKey: SettingsKey.checkUpdatesAutomatically)
    }

    // MARK: Lifecycle

    func launch() async {
        refreshLoginItem()
        refreshPermissions()
        startPermissionPolling()
        await startService()
        if !UserDefaults.standard.bool(forKey: SettingsKey.onboardingDone) { showOnboarding() }
        if checkUpdatesAutomatically { await checkForUpdatesIfDue() }
    }

    /// Stops listening, disconnects iPads and puts every window back. Safe to call twice.
    func shutdown() async {
        pairingTask?.cancel()
        statusTask?.cancel()
        permissionTask?.cancel()
        await listener?.server.closePairingWindow()
        await service?.stop()
        service = nil
        listener = nil
    }

    private func startService() async {
        startError = nil
        do {
            let storeURL = try FilePairedDeviceStore.defaultURL()
            let store = store ?? FilePairedDeviceStore(url: storeURL)
            self.store = store
            refreshPairedDevices()

            // The file-based keychain: the data-protection keychain needs a provisioning profile that a Developer ID app
            // distributed outside the App Store does not have.
            let identities = KeychainIdentityStore(tagPrefix: Self.identityTagPrefix, useDataProtectionKeychain: false)
            _ = try identities.loadOrCreate(role: .helper, label: Self.identityLabel)
            let identity = LinkSecIdentity(try identities.secIdentity(label: Self.identityLabel))

            let approvals = approvals
            let settings = HelperPairingSettings(
                identity: identity, macName: Host.current().localizedName ?? "Mac", pairedDevices: store,
                approvalHandler: { request in await approvals.request(request) },
                askBeforeEachSession: { UserDefaults.standard.bool(forKey: SettingsKey.askBeforeEachSession) })
            let listener = try LinkServerListener(settings: settings, audio: false)
            var options = HelperServiceOptions()
            if !useVirtualStage { options.stageDisplay = nil }
            // Audio stays off on the wire until HelperCore gets an Opus encoder (`HelperDependencies.audio`); the switch is kept
            // so the setting survives that change.
            options.audioEnabled = audioEnabled
            let service = HelperService(dependencies: try .live(listener: listener), options: options)
            self.listener = listener
            self.service = service
            observeStatus(of: service)
            try await service.start()
#if DEBUG
            await writeDebugPairingPayload(server: listener.server)
#endif
        } catch {
            log.error("could not start the service: \(String(describing: error), privacy: .public)")
            startError = String(describing: error)
        }
    }

#if DEBUG
    /// Debug builds only: `SCREON_HELPER_QR_OUT=<file>` writes the pairing link there (the same text the QR code holds), so a
    /// device test can pair through the app's DEBUG `LINK_PAIRING` hook without a camera. Never compiled into Release.
    private func writeDebugPairingPayload(server: LinkServer) async {
        guard let path = ProcessInfo.processInfo.environment["SCREON_HELPER_QR_OUT"], !path.isEmpty else { return }
        do {
            let payload = try await server.makePairingQRPayload(hostHints: HostHints.current())
            try Data(try payload.encoded().utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
            log.fault("SCREON_HELPER_QR_OUT: wrote a pairing link (debug build only)")
        } catch {
            log.error("could not write the debug pairing link: \(String(describing: error), privacy: .public)")
        }
    }
#endif

    /// Stops and starts the service again (settings that are read at start, or a retry after a failure).
    func restartService() async {
        guard !restarting else { return }
        restarting = true
        defer { restarting = false }
        statusTask?.cancel()
        await listener?.server.closePairingWindow()
        await service?.stop()
        service = nil
        listener = nil
        pairing = .idle
        restartPending = false
        await startService()
    }

    private func serviceSettingChanged() {
        guard service != nil else { return }
        if status.sessions.isEmpty {
            Task { await restartService() }
        } else {
            restartPending = true
        }
    }

    private func observeStatus(of service: HelperService) {
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            for await next in await service.statusUpdates() {
                guard let self else { return }
                if next.accessibility != self.status.accessibility || next.screenRecording != self.status.screenRecording {
                    self.log.info("permissions: accessibility \(String(describing: next.accessibility), privacy: .public), screen recording \(String(describing: next.screenRecording), privacy: .public)")
                }
                self.status = next
                self.refreshPairedDevices()
                if next.sessions.isEmpty && self.restartPending { await self.restartService() }
            }
        }
    }

    // MARK: Sessions and devices

    func disconnect(sessionID: UInt64) {
        Task { await service?.disconnect(sessionID: sessionID) }
    }

    func disconnectAll() {
        Task { await service?.disconnectAll() }
    }

    func restoreWindows() {
        Task { await service?.restoreWindows() }
    }

    func refreshPairedDevices() {
        let devices = store?.all() ?? []
        if devices != pairedDevices { pairedDevices = devices }
        if case .qr = pairing, hasNewDevice(devices) { devicePaired(devices) }
        if case .sas = pairing, hasNewDevice(devices) { devicePaired(devices) }
    }

    private func hasNewDevice(_ devices: [PairedDevice]) -> Bool {
        devices.contains { !pairingBaseline.contains($0.spkiHash) }
    }

    private func devicePaired(_ devices: [PairedDevice]) {
        let name = devices.last { !pairingBaseline.contains($0.spkiHash) }?.name ?? ""
        pairingTask?.cancel()
        pairing = .paired(name: name)
        Task {
            try? await Task.sleep(for: .seconds(2))
            if case .paired = pairing { windows.close(id: WindowID.pairing) }
        }
    }

    func rename(_ device: PairedDevice, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do { _ = try store?.rename(spkiHash: device.spkiHash, to: trimmed) } catch {
            log.error("rename failed: \(String(describing: error), privacy: .public)")
        }
        refreshPairedDevices()
    }

    /// Removes the pairing and closes the device's live sessions.
    func revoke(_ device: PairedDevice) {
        Task {
            do {
                if let server = listener?.server {
                    _ = try await server.revoke(deviceSPKIHash: device.spkiHash)
                } else {
                    _ = try store?.revoke(spkiHash: device.spkiHash)
                }
            } catch {
                log.error("revoke failed: \(String(describing: error), privacy: .public)")
            }
            refreshPairedDevices()
        }
    }

    // MARK: Pairing

    func beginQRPairing() {
        guard let server = listener?.server else { return }
        startPairing()
        pairing = .idle
        Task {
            do {
                let payload = try await server.makePairingQRPayload(hostHints: HostHints.current())
                let link = try payload.encoded()
                pairing = .qr(image: QRCode.image(for: link), link: link, expiry: payload.expiry)
                watchPairingExpiry(payload.expiry)
            } catch {
                log.error("could not create a pairing code: \(String(describing: error), privacy: .public)")
                pairing = .failed
            }
        }
    }

    /// Where an iPad reaches this Mac, for typing into "Pair with code": the first host hint (the `.local` name, else a LAN
    /// address) and the listening port.
    var pairingAddress: (host: String, port: UInt16)? {
        guard let port = status.listeningPort, let host = HostHints.current().first else { return nil }
        return (host, port)
    }

    func copyPairingLink() {
        guard case .qr(_, let link, _) = pairing else { return }
        NSPasteboard.general.clearContents()
        // Transient: clipboard managers should not keep a pairing secret around after it expires.
        NSPasteboard.general.setString(link, forType: .string)
        NSPasteboard.general.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
    }

    func beginSASPairing() {
        guard let server = listener?.server else { return }
        startPairing()
        let duration = PairingAdmission.defaultWindow
        Task {
            await server.openPairingWindow(method: .sas, duration: duration)
            let expiry = Date().addingTimeInterval(duration)
            pairing = .sas(expiry: expiry)
            watchPairingExpiry(expiry)
        }
    }

    private func startPairing() {
        pairingBaseline = Set(pairedDevices.map(\.spkiHash))
        windows.show(id: WindowID.pairing, title: String(localized: "Pair a New iPad"), onClose: { [weak self] in self?.cancelPairing() }) {
            PairingView(model: self)
        }
    }

    private func watchPairingExpiry(_ expiry: Date) {
        pairingTask?.cancel()
        pairingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.refreshPairedDevices()
                if Date() >= expiry {
                    switch self.pairing {
                    case .qr, .sas: self.pairing = .failed
                    default: break
                    }
                    return
                }
            }
        }
    }

    /// Closes the SAS window, burns the QR offers on screen and cancels approvals still waiting.
    func cancelPairing() {
        pairingTask?.cancel()
        pairing = .idle
        guard let server = listener?.server else { return }
        Task { await server.closePairingWindow() }
    }

    // MARK: Permissions

    func refreshPermissions() {
        let probe = SystemPermissionProbe()
        let next = PermissionSnapshot(
            accessibility: probe.state(of: .accessibility) == .granted,
            postEvents: CGPreflightPostEventAccess(),
            screenRecording: probe.state(of: .screenRecording) == .granted)
        if next != permissions { permissions = next }
    }

    private func startPermissionPolling() {
        permissionTask?.cancel()
        permissionTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.refreshPermissions()
            }
        }
    }

    func request(_ kind: PermissionKind) {
        switch kind {
        case .accessibility:
            // "AXTrustedCheckOptionPrompt" is the value of kAXTrustedCheckOptionPrompt.
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        case .postEvents:
            _ = CGRequestPostEventAccess()
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
        }
        refreshPermissions()
    }

    var localNetworkNote: LocalNetworkNote { status.isRunning ? .listening : .unknown }

    enum SettingsPane: String {
        case accessibility = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case screenRecording = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        case localNetwork = "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork"
    }

    func openSettings(_ pane: SettingsPane) {
        if let url = URL(string: pane.rawValue) { NSWorkspace.shared.open(url) }
    }

    func showOnboarding() {
        refreshPermissions()
        windows.show(id: WindowID.onboarding, title: String(localized: "Set Up Screon Helper")) {
            OnboardingView(model: self)
        }
    }

    func finishOnboarding() {
        UserDefaults.standard.set(true, forKey: SettingsKey.onboardingDone)
        windows.close(id: WindowID.onboarding)
    }

    /// Some grants only take effect in a new process. The new instance waits for this one to exit (`--relaunch`).
    func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; exec /usr/bin/open -n \"$0\" --args --relaunch", Bundle.main.bundlePath]
        try? process.run()
        NSApp.terminate(nil)
    }

    // MARK: Login item

    func refreshLoginItem() {
        loginItemStatus = SMAppService.mainApp.status
    }

    var launchAtLogin: Bool { loginItemStatus == .enabled || loginItemStatus == .requiresApproval }

    func setLaunchAtLogin(_ enabled: Bool) {
        loginItemError = false
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            log.error("login item change failed: \(String(describing: error), privacy: .public)")
            loginItemError = true
        }
        refreshLoginItem()
    }

    func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }

    // MARK: Updates

    private var updateChecker: UpdateChecker? {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let urlText = info["ScreonUpdateManifestURL"] as? String, let url = URL(string: urlText) else { return nil }
        let key = (info["ScreonUpdatePublicKey"] as? String) ?? ""
        return UpdateChecker(manifestURL: url, publicKeyBase64: key) { try await HTTPSFetcher.fetch($0, maxBytes: $1) }
    }

    private func checkForUpdatesIfDue() async {
        let last = UserDefaults.standard.double(forKey: SettingsKey.lastUpdateCheck)
        guard Date().timeIntervalSince1970 - last > 24 * 3600 else { return }
        await checkForUpdates()
    }

    func checkForUpdates() async {
        guard update != .checking else { return }
        guard let checker = updateChecker else { update = .notConfigured; return }
        let info = Bundle.main.infoDictionary ?? [:]
        guard let current = SemanticVersion((info["CFBundleShortVersionString"] as? String) ?? "") else { update = .failed; return }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let macOS = SemanticVersion(major: os.majorVersion, minor: os.minorVersion, patch: os.patchVersion)
        update = .checking
        do {
            switch try await checker.check(current: current, macOS: macOS) {
            case .upToDate: update = .upToDate
            case .available(let manifest): update = .available(version: manifest.version.description, releaseURL: manifest.releaseURL)
            case .requiresNewerMacOS(let manifest): update = .needsNewerMacOS(version: manifest.version.description)
            }
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: SettingsKey.lastUpdateCheck)
        } catch UpdateError.notConfigured {
            update = .notConfigured
        } catch {
            log.error("update check failed: \(String(describing: error), privacy: .public)")
            update = .failed
        }
    }

    // MARK: Derived

    var versionString: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = (info["CFBundleShortVersionString"] as? String) ?? "?"
        let build = (info["CFBundleVersion"] as? String) ?? "?"
        return "\(version) (\(build))"
    }

    var menuBarSymbol: String {
        if !status.issues.isEmpty || startError != nil { return "exclamationmark.triangle" }
        return status.sessions.isEmpty ? "display" : "ipad.and.iphone"
    }
}

enum WindowID {
    static let onboarding = "onboarding"
    static let pairing = "pairing"
}
