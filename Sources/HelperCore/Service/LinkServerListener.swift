#if os(macOS)
import Foundation
import LinkProtocol
import LinkTransport

/// The pairing-specific part of the listener configuration.
///
/// This type and `LinkServerListener.makeConfiguration` are the only places in the service layer that know about the
/// pairing-specific parts of `LinkServerConfiguration` (approval handler, ask-before-each-session). When the pairing API
/// changes, adapt them and nothing else. Pairing windows are opened on `server` (`openPairingWindow(method:)`, or showing a QR
/// code via `makePairingQRPayload`) when the person at the Mac asks to pair a device.
public struct HelperPairingSettings: Sendable {
    /// The helper's well-known port, so a paired iPad reconnects after the helper restarts. Another free port is used when it
    /// is taken.
    public static let defaultPort: UInt16 = 7361
    public var identity: LinkSecIdentity
    public var macName: String
    public var pairedDevices: any PairedDeviceStore
    /// Local approval on the Mac (LocalAuthentication). Return true to approve.
    public var approvalHandler: @Sendable (PairingApprovalRequest) async -> Bool
    public var askBeforeEachSession: @Sendable () -> Bool
    public var port: UInt16
    public var enableQUIC: Bool
    public var enableTCP: Bool
    public var loopbackOnly: Bool
    public var advertiseBonjour: Bool
    public var maxSessions: Int
    public var displays: @Sendable () -> [LinkDisplayInfo]

    public init(
        identity: LinkSecIdentity, macName: String, pairedDevices: any PairedDeviceStore,
        approvalHandler: @escaping @Sendable (PairingApprovalRequest) async -> Bool,
        askBeforeEachSession: @escaping @Sendable () -> Bool = { false },
        port: UInt16 = HelperPairingSettings.defaultPort, enableQUIC: Bool = true, enableTCP: Bool = true, loopbackOnly: Bool = false,
        advertiseBonjour: Bool = true, maxSessions: Int = HelperServiceOptions.defaultMaxSessions,
        displays: @escaping @Sendable () -> [LinkDisplayInfo] = { [] }
    ) {
        self.identity = identity; self.macName = macName; self.pairedDevices = pairedDevices
        self.approvalHandler = approvalHandler; self.askBeforeEachSession = askBeforeEachSession
        self.port = port; self.enableQUIC = enableQUIC; self.enableTCP = enableTCP
        self.loopbackOnly = loopbackOnly; self.advertiseBonjour = advertiseBonjour; self.maxSessions = maxSessions
        self.displays = displays
    }
}

/// `HelperListener` on top of `LinkServer`.
public final class LinkServerListener: HelperListener, Sendable {
    /// The underlying server, for pairing (`makePairingQRPayload`, `revoke`, the ledger).
    public let server: LinkServer
    public let connections: AsyncStream<any HelperConnection>
    private let continuation: AsyncStream<any HelperConnection>.Continuation
    private let pump = PumpBox()

    /// Capabilities this helper offers.
    public static func capabilities(audio: Bool) -> LinkCapabilities {
        var caps: LinkCapabilities = [.stage, .gestures, .tablet, .clipboardRich, .files, .menus, .ltr, .hevc, .h264, .cursorShapes]
        if audio { caps.insert(.audio) }
        return caps
    }

    /// `snapshotProvider` stays nil: `HelperSession` sends the snapshot itself, right after it subscribed to changes.
    public static func makeConfiguration(_ settings: HelperPairingSettings, audio: Bool) -> LinkServerConfiguration {
        var configuration = LinkServerConfiguration(
            identity: settings.identity, macName: settings.macName, capabilities: capabilities(audio: audio),
            pairedDevices: settings.pairedDevices, approvalHandler: settings.approvalHandler, displays: settings.displays,
            snapshotProvider: nil, askBeforeEachSession: settings.askBeforeEachSession,
            port: settings.port, enableQUIC: settings.enableQUIC,
            enableTCP: settings.enableTCP, loopbackOnly: settings.loopbackOnly, advertiseBonjour: settings.advertiseBonjour,
            maxSessions: settings.maxSessions)
        configuration.fallBackToAnyPort = settings.port != 0
        return configuration
    }

    public init(server: LinkServer) {
        self.server = server
        (connections, continuation) = AsyncStream<any HelperConnection>.makeStream(bufferingPolicy: .bufferingOldest(16))
    }

    public convenience init(settings: HelperPairingSettings, audio: Bool = false) throws {
        try self.init(server: LinkServer(configuration: Self.makeConfiguration(settings, audio: audio)))
    }

    public func start() async throws -> UInt16 {
        let endpoint = try await server.start()
        let source = server.connections
        let continuation = continuation
        pump.set(Task {
            for await connection in source { continuation.yield(LinkServerHelperConnection(connection)) }
            continuation.finish()
        })
        return endpoint.port
    }

    public func stop() async {
        await server.stop()
        pump.cancel()
        continuation.finish()
    }

    public func disconnectAll(code: LinkCloseCode) async { await server.disconnectAll(code: code) }

    private final class PumpBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: Task<Void, Never>?
        func set(_ new: Task<Void, Never>) { lock.withLock { task = new } }
        func cancel() { lock.withLock { task?.cancel(); task = nil } }
    }
}

/// `HelperConnection` on top of `LinkServerConnection`.
public final class LinkServerHelperConnection: HelperConnection, Sendable {
    public let info: HelperConnectionInfo
    private let connection: LinkServerConnection

    public init(_ connection: LinkServerConnection) {
        self.connection = connection
        let ready = connection.session
        info = HelperConnectionInfo(
            sessionID: ready.sessionID, deviceName: ready.deviceName, deviceID: ready.deviceSPKIHash,
            capabilities: ready.capabilities, sceneLimits: ready.clientHello.sceneLimits, resumed: ready.resumed,
            lastStateVersion: ready.lastStateVersion)
    }

    public func send(_ message: LinkMessage) async throws { try await connection.send(message) }
    public func finishWindowStream(_ window: WindowID) async { await connection.finishWindowStream(window) }
    public func close(code: LinkCloseCode, reason: String) async { await connection.close(code: code, reason: reason) }

    public func run(handler: any HelperConnectionHandler) async {
        let connection = connection
        await withTaskGroup(of: Void.self) { group in
            let control = connection.controlMessages
            group.addTask {
                for await message in control { await handler.handleControl(message) }
            }
            group.addTask {
                await withTaskGroup(of: Void.self) { inputs in
                    for await event in connection.events {
                        switch event {
                        case .streamOpened(.input, let inbox):
                            inputs.addTask { for await message in inbox { await handler.handleInput(message) } }
                        case .streamOpened, .streamFinished:
                            break
                        case .videoBackpressure(let window, let dropped, let needsKeyframe):
                            await handler.handleEvent(.videoBackpressure(window: window, droppedFrames: dropped, needsKeyframe: needsKeyframe))
                        case .closed(let error):
                            await handler.handleEvent(.closed(reason: error.map { String(describing: $0) }))
                        }
                    }
                }
            }
        }
    }
}
#endif
