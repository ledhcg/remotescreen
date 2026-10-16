#if os(macOS)
import Foundation
import LinkProtocol

/// What the service layer needs to know about one established link session.
public struct HelperConnectionInfo: Sendable, Equatable {
    public var sessionID: UInt64
    /// Sanitised by the handshake; still untrusted text.
    public var deviceName: String
    /// SHA-256 of the iPad certificate's SPKI.
    public var deviceID: Data
    /// Capabilities both sides agreed on.
    public var capabilities: LinkCapabilities
    public var sceneLimits: LinkSceneLimits
    public var resumed: Bool
    public var lastStateVersion: UInt64?

    public init(
        sessionID: UInt64, deviceName: String, deviceID: Data, capabilities: LinkCapabilities, sceneLimits: LinkSceneLimits,
        resumed: Bool = false, lastStateVersion: UInt64? = nil
    ) {
        self.sessionID = sessionID; self.deviceName = deviceName; self.deviceID = deviceID; self.capabilities = capabilities
        self.sceneLimits = sceneLimits; self.resumed = resumed; self.lastStateVersion = lastStateVersion
    }
}

/// Things that happen to a connection besides messages.
public enum HelperConnectionEvent: Sendable, Equatable {
    /// The outbound video queue of a window dropped frames. With `needsKeyframe` the stream is undecodable until a key frame.
    case videoBackpressure(window: WindowID, droppedFrames: Int, needsKeyframe: Bool)
    /// The connection ended; `reason` is a short developer-facing description (nil for a clean close).
    case closed(reason: String?)
}

/// Receives what arrives on a connection. `HelperSession` implements it. The connection waits for each call to return, so a
/// slow handler slows the sender down (back pressure) instead of building a queue.
public protocol HelperConnectionHandler: Sendable {
    /// A message from the control stream (everything except input).
    func handleControl(_ message: LinkMessage) async
    /// A message from the input stream.
    func handleInput(_ message: LinkMessage) async
    func handleEvent(_ event: HelperConnectionEvent) async
}

/// One connected iPad, as seen by the service. The real implementation wraps `LinkServerConnection`
/// (`LinkServerHelperConnection`); tests use a fake.
public protocol HelperConnection: Sendable {
    var info: HelperConnectionInfo { get }
    /// Sends on the stream the message belongs to (window media opens that window's stream). Throws when the connection is
    /// closed or a control queue overflowed; video never throws, it drops and reports back pressure.
    func send(_ message: LinkMessage) async throws
    /// Ends a window's video stream after what is queued has been written.
    func finishWindowStream(_ window: WindowID) async
    func close(code: LinkCloseCode, reason: String) async
    /// Feeds `handler` until the connection ends (the last call is `handleEvent(.closed)` when the transport reports it).
    func run(handler: any HelperConnectionHandler) async
}

/// The helper's listener. The real implementation is `LinkServerListener`; tests use a fake. Pairing is not part of this
/// protocol: the app talks to the concrete listener for QR codes and revocation.
public protocol HelperListener: Sendable {
    /// Established, authorised sessions.
    var connections: AsyncStream<any HelperConnection> { get }
    /// Starts listening and returns the port.
    func start() async throws -> UInt16
    func stop() async
    func disconnectAll(code: LinkCloseCode) async
}
#endif
