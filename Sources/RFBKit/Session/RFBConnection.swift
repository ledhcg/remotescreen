import Foundation
import Network
import os

/// Runs `operation` with a time limit and a **deterministic error result**.
///
/// On timeout, `onTimeout` is called first (to close the stream, since reads through `NWConnection` are not cancelled with the `Task`),
/// and then the error is always `RFBError.timedOut`. Without a distinguishing flag, the "stream closed" error caused by `onTimeout`
/// itself could leak out in place of the timeout error, depending on which branch finishes first.
func withDeadline<T: Sendable>(
    _ timeout: Duration,
    onTimeout: @escaping @Sendable () async -> Void,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let fired = OSAllocatedUnfairLock(initialState: false)
    do {
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: timeout)
                fired.withLock { $0 = true }
                await onTimeout()
                throw RFBError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw RFBError.timedOut }
            return result
        }
    } catch {
        if fired.withLock({ $0 }) { throw RFBError.timedOut }
        throw error
    }
}

/// Opens a complete RFB connection: TCP, handshake, security type selection, authentication and `ServerInit`.
public enum RFBConnection {
    /// Picks a usable security type. Returns `nil` if the server offers no suitable type.
    ///
    /// - With an account name: **only** Apple Remote Desktop (type 30). No downgrade to VNC Authentication or None, because the server
    ///   (or a man in the middle) may offer only a weaker type: the DES response to the challenge could then be cracked offline, and
    ///   the user would think they are logging in with an account. To use a VNC password, the user must leave the account
    ///   name blank; that is their explicit choice.
    /// - Without an account name: VNC Authentication, then None. None is chosen last, so a server that allows both a password
    ///   and no password still gets authenticated.
    public static func chooseSecurityType(from offered: [RFBSecurityType], hasUsername: Bool) -> RFBSecurityType? {
        let preference: [RFBSecurityType] = hasUsername
            ? [.appleRemoteDesktop]
            : [.vncAuthentication, .noAuthentication]
        return preference.first(where: offered.contains)
    }

    /// Connects to `host:port` and returns a ready session (`SetEncodings` not yet sent).
    ///
    /// - Parameters:
    ///   - timeout: total time allowed for TCP, handshake, authentication and `ServerInit`.
    ///   - networkPatience: how long to wait when there is no network path yet or the Local Network permission has not been granted (the iOS dialog
    ///     is waiting for the user). Should be smaller than `timeout`, otherwise a real network error would be replaced by `timedOut`.
    public static func open(
        host: String,
        port: UInt16 = 5900,
        credentials: RFBCredentials,
        shared: Bool = true,
        timeout: Duration = .seconds(30),
        networkPatience: Duration = .seconds(20),
        pixelFormat: PixelFormat = .bgra8888
    ) async throws -> RFBSession {
        try await open(
            over: NWByteStream(host: host, port: port), credentials: credentials, shared: shared,
            timeout: timeout, networkPatience: networkPatience, pixelFormat: pixelFormat
        )
    }

    /// Like `open(host:port:...)` but connects to an arbitrary endpoint, for example a Bonjour service.
    public static func open(
        endpoint: NWEndpoint,
        credentials: RFBCredentials,
        shared: Bool = true,
        timeout: Duration = .seconds(30),
        networkPatience: Duration = .seconds(20),
        pixelFormat: PixelFormat = .bgra8888
    ) async throws -> RFBSession {
        try await open(
            over: NWByteStream(endpoint: endpoint), credentials: credentials, shared: shared,
            timeout: timeout, networkPatience: networkPatience, pixelFormat: pixelFormat
        )
    }

    private static func open(
        over stream: NWByteStream,
        credentials: RFBCredentials,
        shared: Bool,
        timeout: Duration,
        networkPatience: Duration,
        pixelFormat: PixelFormat
    ) async throws -> RFBSession {
        do {
            // Reads through NWConnection do not stop on their own when the Task is cancelled; on cancellation (the user taps Cancel), close the stream so pending reads
            // exit immediately instead of hanging until the server replies.
            let (info, flavor, securityType) = try await withTaskCancellationHandler {
                try await withDeadline(timeout, onTimeout: { await stream.close() }) {
                try await stream.connect(waitingPatience: networkPatience)
                let hello = try await Handshake.readServerHello(over: stream)
                guard let type = chooseSecurityType(from: hello.securityTypes, hasUsername: !credentials.username.isEmpty) else {
                    throw RFBError.noCompatibleSecurityType(offered: hello.securityTypes)
                }
                try await Handshake.selectSecurityType(type, version: hello.negotiatedVersion, over: stream)
                try await Authenticator.authenticate(
                    type: type, version: hello.negotiatedVersion, credentials: credentials, over: stream
                )
                let info = try await Handshake.performInit(shared: shared, over: stream)
                return (info, ServerFlavor(serverVersion: hello.serverVersion), type)
                }
            } onCancel: {
                Task { await stream.close() }
            }
            return try RFBSession(stream: stream, serverInfo: info, flavor: flavor, pipelinesUpdateRequests: true, pixelFormat: pixelFormat, securityType: securityType)
        } catch {
            await stream.close()
            throw error
        }
    }
}
