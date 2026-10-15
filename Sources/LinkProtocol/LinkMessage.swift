import Foundation

/// Every message of the link protocol (design §5 plus the additions in the implementation plan §5).
///
/// Direction is noted per case: C = iPad (client), H = Mac helper. Enums inside messages are closed: an unknown raw value
/// is `LinkError.malformed`. A message is encoded with `LinkFrameEncoder` and decoded with `LinkFrameDecoder`.
public enum LinkMessage: Sendable, Equatable {
    // MARK: Session

    /// C↔H.
    case hello(LinkHello)
    /// H→C.
    case welcome(LinkWelcome)
    /// C→H.
    case resume(LinkResume)
    /// H→C. Replaces all client state.
    case snapshot(LinkSnapshot)
    /// C↔H. The peer answers with `pong` carrying the same value.
    case ping(timestampMicros: UInt64)
    case pong(timestampMicros: UInt64)
    /// C→H.
    case stats(LinkStats)
    /// H→C.
    case status(LinkStatus)
    /// H→C: the user on the Mac must approve this session before anything else happens.
    case approvalRequired
    /// C↔H: the connection is about to be closed.
    case close(code: LinkCloseCode, reason: String)

    // MARK: Pairing

    /// C→H: proof of the QR secret, bound to the transcript (`docs/app-mode-implementation-plan.md` §6.2).
    case pairProve(LinkPairProve)
    /// H→C: fresh value to bind into the transcript when the TLS exporter is unavailable.
    case pairChallenge(LinkBytes32)
    /// H→C.
    case pairOK(LinkPairOK)
    /// H→C.
    case pairDenied(LinkPairDenyReason)
    /// C↔H: SHA-256 of the ephemeral X25519 public key (short-authentication-string mode).
    case sasCommit(LinkBytes32)
    /// C↔H: the ephemeral X25519 public key itself.
    case sasReveal(LinkBytes32)

    // MARK: Apps

    /// C→H.
    case appsList(filter: LinkAppFilter)
    /// H→C.
    case appsItems([LinkAppInfo])
    /// C→H.
    case appsIcon(key: IconKey, pixelSize: UInt16)
    /// H→C. PNG of at most `LinkLimits.maxIconPNGBytes`.
    case appsIconData(key: IconKey, png: Data)
    /// C→H.
    case appsLaunch(bundleID: String)
    case appsActivate(bundleID: String)
    case appsQuit(bundleID: String)
    /// H→C.
    case appsChanged(change: LinkAppChange, app: LinkAppInfo)

    // MARK: Windows

    /// H→C.
    case windowCreated(LinkWindowInfo)
    case windowUpdated(LinkWindowUpdate)
    case windowDestroyed(WindowID)
    /// H→C: front-to-back order and the active window.
    case windowOrder(ids: [WindowID], active: WindowID?)
    /// C→H.
    case windowSubscribe(LinkSubscribe)
    case windowUnsubscribe(WindowID)
    case windowSetFrame(LinkSetFrame)
    case windowCommand(window: WindowID, command: LinkWindowCommand)
    /// H→C.
    case windowCapabilities(window: WindowID, capabilities: LinkWindowCapabilities)
    /// C→H: ask for a key frame of this window's stream.
    case streamKeyframe(WindowID)

    // MARK: Media (per-window streams; every message names its window so a multiplexed fallback needs no extra state)

    /// H→C.
    case videoConfig(LinkVideoConfig)
    case videoFrame(LinkVideoFrame)
    /// C→H: long-term reference frames the decoder holds.
    case videoAck(window: WindowID, ltrTokens: [UInt32])
    /// C→H: frames `firstSequence...lastSequence` (wrapping) are missing.
    case videoLost(window: WindowID, firstSequence: UInt32, lastSequence: UInt32)
    /// H→C.
    case surfaceSnapshot(LinkSurfaceSnapshot)
    case cursorShape(LinkCursorShape)
    case cursorRef(window: WindowID, id: CursorID)
    case audioConfig(LinkAudioConfig)
    case audioPacket(LinkAudioPacket)

    // MARK: Input (C→H)

    case inputPointer(LinkPointerEvent)
    case inputScroll(LinkScrollEvent)
    case inputGesture(LinkGestureEvent)
    case inputKey(LinkKeyEvent)
    /// Unicode text, at most `LinkLimits.maxTextInputBytes` UTF-8 bytes.
    case inputText(String)

    // MARK: Menus

    /// C→H.
    case menuGet(bundleID: String)
    /// H→C. At most `LinkLimits.maxMenuDepth` levels.
    case menuTree(bundleID: String, items: [LinkMenuItem])
    /// C→H: indices from the root menu to the item.
    case menuPress(bundleID: String, path: [UInt16])

    // MARK: Clipboard (both directions)

    case clipboardOffer(types: [String])
    case clipboardRequest(type: String)
    case clipboardData(type: String, data: Data)

    // MARK: Files (C→H)

    case fileBegin(LinkFileBegin)
    case fileChunk(LinkFileChunk)
    /// `sha256` is the digest of the whole file.
    case fileEnd(transfer: TransferID, sha256: LinkBytes32)

    /// The wire type of this message.
    public var type: LinkMessageType {
        switch self {
        case .hello: .hello
        case .welcome: .welcome
        case .resume: .resume
        case .snapshot: .snapshot
        case .ping: .ping
        case .pong: .pong
        case .stats: .stats
        case .status: .status
        case .approvalRequired: .approvalRequired
        case .close: .close
        case .pairProve: .pairProve
        case .pairChallenge: .pairChallenge
        case .pairOK: .pairOK
        case .pairDenied: .pairDenied
        case .sasCommit: .sasCommit
        case .sasReveal: .sasReveal
        case .appsList: .appsList
        case .appsItems: .appsItems
        case .appsIcon: .appsIcon
        case .appsIconData: .appsIconData
        case .appsLaunch: .appsLaunch
        case .appsActivate: .appsActivate
        case .appsQuit: .appsQuit
        case .appsChanged: .appsChanged
        case .windowCreated: .windowCreated
        case .windowUpdated: .windowUpdated
        case .windowDestroyed: .windowDestroyed
        case .windowOrder: .windowOrder
        case .windowSubscribe: .windowSubscribe
        case .windowUnsubscribe: .windowUnsubscribe
        case .windowSetFrame: .windowSetFrame
        case .windowCommand: .windowCommand
        case .windowCapabilities: .windowCapabilities
        case .streamKeyframe: .streamKeyframe
        case .videoConfig: .videoConfig
        case .videoFrame: .videoFrame
        case .videoAck: .videoAck
        case .videoLost: .videoLost
        case .surfaceSnapshot: .surfaceSnapshot
        case .cursorShape: .cursorShape
        case .cursorRef: .cursorRef
        case .audioConfig: .audioConfig
        case .audioPacket: .audioPacket
        case .inputPointer: .inputPointer
        case .inputScroll: .inputScroll
        case .inputGesture: .inputGesture
        case .inputKey: .inputKey
        case .inputText: .inputText
        case .menuGet: .menuGet
        case .menuTree: .menuTree
        case .menuPress: .menuPress
        case .clipboardOffer: .clipboardOffer
        case .clipboardRequest: .clipboardRequest
        case .clipboardData: .clipboardData
        case .fileBegin: .fileBegin
        case .fileChunk: .fileChunk
        case .fileEnd: .fileEnd
        }
    }
}
