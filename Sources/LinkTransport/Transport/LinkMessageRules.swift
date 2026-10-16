import Foundation
import LinkProtocol

/// Who may send a message, and on which stream. The receiver enforces this after decoding: a message that is valid on the
/// wire but sent by the wrong side or on the wrong stream is a protocol violation and closes the connection.
public enum LinkMessageRules {
    public enum Direction: Sendable { case clientToHelper, helperToClient, both }

    public static func direction(of type: LinkMessageType) -> Direction {
        switch type {
        case .hello, .ping, .pong, .close, .sasCommit, .sasReveal, .clipboardOffer, .clipboardRequest, .clipboardData:
            return .both
        case .welcome, .snapshot, .status, .approvalRequired, .pairChallenge, .pairOK, .pairDenied,
             .appsItems, .appsIconData, .appsChanged,
             .windowCreated, .windowUpdated, .windowDestroyed, .windowOrder, .windowCapabilities,
             .videoConfig, .videoFrame, .surfaceSnapshot, .cursorShape, .cursorRef, .audioConfig, .audioPacket, .menuTree:
            return .helperToClient
        case .resume, .stats, .pairProve, .sasConfirm, .appsList, .appsIcon, .appsLaunch, .appsActivate, .appsQuit,
             .windowSubscribe, .windowUnsubscribe, .windowSetFrame, .windowCommand, .streamKeyframe,
             .videoAck, .videoLost, .inputPointer, .inputScroll, .inputGesture, .inputKey, .inputText,
             .menuGet, .menuPress, .fileBegin, .fileChunk, .fileEnd:
            return .clientToHelper
        }
    }

    static func isInput(_ type: LinkMessageType) -> Bool {
        switch type {
        case .inputPointer, .inputScroll, .inputGesture, .inputKey, .inputText: true
        default: false
        }
    }

    static func isWindowMedia(_ type: LinkMessageType) -> Bool {
        switch type {
        case .videoConfig, .videoFrame, .surfaceSnapshot, .cursorShape, .cursorRef: true
        default: false
        }
    }

    static func isAudio(_ type: LinkMessageType) -> Bool { type == .audioConfig || type == .audioPacket }

    /// The window a media message belongs to, if it names one.
    public static func window(of message: LinkMessage) -> WindowID? {
        switch message {
        case .videoConfig(let c): c.window
        case .videoFrame(let f): f.window
        case .surfaceSnapshot(let s): s.window
        case .cursorShape(let c): c.window
        case .cursorRef(let window, _): window
        default: nil
        }
    }

    /// The stream a message must travel on.
    public static func streamKind(for message: LinkMessage) -> LinkStreamKind? {
        let type = message.type
        if isInput(type) { return .input }
        if isAudio(type) { return .audio }
        if isWindowMedia(type) { return window(of: message).map { .window($0) } }
        return .control
    }

    /// Whether `message`, arriving on `stream` from the peer, is allowed. `peerIsClient` is true on the helper side.
    static func isAllowed(_ message: LinkMessage, on stream: LinkStreamKind, peerIsClient: Bool) -> Bool {
        let type = message.type
        switch direction(of: type) {
        case .clientToHelper: guard peerIsClient else { return false }
        case .helperToClient: guard !peerIsClient else { return false }
        case .both: break
        }
        switch stream {
        case .input: return isInput(type)
        case .audio: return isAudio(type)
        case .window(let id):
            guard isWindowMedia(type) else { return false }
            return window(of: message) == id
        case .control:
            return !isInput(type) && !isWindowMedia(type) && !isAudio(type)
        }
    }
}
