import Foundation

// Enum policy: every enum below is closed. A raw value this build does not know is `LinkError.malformed`, because the
// meaning of a command or phase cannot be guessed. New values arrive with a new protocol version or a capability bit.
// Bitsets (`OptionSet`) are different: unknown bits are preserved and ignored.

/// Wire type of a message (`u16`). Values at or above `0x8000` are reserved for ignorable messages and are never used here.
public enum LinkMessageType: UInt16, Sendable, CaseIterable {
    // Session
    case hello = 0x0001, welcome, resume, snapshot, ping, pong, stats, status, approvalRequired, close
    // Pairing
    case pairProve = 0x0010, pairChallenge, pairOK, pairDenied, sasCommit, sasReveal
    // Apps
    case appsList = 0x0020, appsItems, appsIcon, appsIconData, appsLaunch, appsActivate, appsQuit, appsChanged
    // Windows
    case windowCreated = 0x0030, windowUpdated, windowDestroyed, windowOrder, windowSubscribe, windowUnsubscribe,
         windowSetFrame, windowCommand, windowCapabilities, streamKeyframe
    // Media
    case videoConfig = 0x0040, videoFrame, videoAck, videoLost, surfaceSnapshot, cursorShape, cursorRef, audioConfig, audioPacket
    // Input
    case inputPointer = 0x0050, inputScroll, inputGesture, inputKey, inputText
    // Menus
    case menuGet = 0x0060, menuTree, menuPress
    // Clipboard
    case clipboardOffer = 0x0070, clipboardRequest, clipboardData
    // Files
    case fileBegin = 0x0080, fileChunk, fileEnd
}

public enum LinkAppFilter: UInt8, Sendable { case running = 0, installed, recent }
public enum LinkAppChange: UInt8, Sendable { case launched = 0, terminated, activated }
public enum LinkWindowKind: UInt8, Sendable {
    /// A normal window the user can bring to the iPad.
    case managed = 0
    /// A sheet, popover or panel tied to another window.
    case transient
}
public enum LinkQualityTier: UInt8, Sendable { case low = 0, balanced, high }
public enum LinkPlacementHint: UInt8, Sendable { case keep = 0, center, cascade }
public enum LinkWindowCommand: UInt8, Sendable { case raise = 0, close, minimise, zoom, exitFullScreen }
public enum LinkVideoCodec: UInt8, Sendable { case h264 = 0, hevc }
public enum LinkImageFormat: UInt8, Sendable { case png = 0, jpeg }
public enum LinkAudioCodec: UInt8, Sendable { case opus = 0 }
public enum LinkScrollPhase: UInt8, Sendable { case none = 0, began, changed, ended, cancelled }
public enum LinkGestureKind: UInt8, Sendable { case magnify = 0, rotate, smartMagnify, swipe }
public enum LinkGesturePhase: UInt8, Sendable { case began = 0, changed, ended, cancelled }
public enum LinkPermissionKind: UInt8, Sendable { case accessibility = 0, screenRecording, localNetwork, inputMonitoring, automation }
public enum LinkPermissionState: UInt8, Sendable { case notDetermined = 0, granted, denied }
public enum LinkStageState: UInt8, Sendable { case inactive = 0, preparing, active, unavailable }
public enum LinkPairDenyReason: UInt8, Sendable { case userDenied = 0, expired, tooManyAttempts, badProof, busy, unsupported }

/// Why a connection is being closed (`close`). Open set: unknown codes from a newer peer are carried through as-is.
public struct LinkCloseCode: RawRepresentable, Sendable, Hashable {
    public var rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public static let normal = LinkCloseCode(rawValue: 0)
    public static let versionMismatch = LinkCloseCode(rawValue: 1)
    public static let protocolViolation = LinkCloseCode(rawValue: 2)
    public static let unsupportedMessage = LinkCloseCode(rawValue: 3)
    public static let notAuthorized = LinkCloseCode(rawValue: 4)
    public static let sessionReplaced = LinkCloseCode(rawValue: 5)
    public static let helperShuttingDown = LinkCloseCode(rawValue: 6)
    public static let approvalDenied = LinkCloseCode(rawValue: 7)
    public static let internalError = LinkCloseCode(rawValue: 8)
}

public struct LinkModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public static let shift = LinkModifiers(rawValue: 1 << 0)
    public static let control = LinkModifiers(rawValue: 1 << 1)
    public static let option = LinkModifiers(rawValue: 1 << 2)
    public static let command = LinkModifiers(rawValue: 1 << 3)
    public static let capsLock = LinkModifiers(rawValue: 1 << 4)
    public static let function = LinkModifiers(rawValue: 1 << 5)
}

public struct LinkMouseButtons: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let left = LinkMouseButtons(rawValue: 1 << 0)
    public static let right = LinkMouseButtons(rawValue: 1 << 1)
    public static let middle = LinkMouseButtons(rawValue: 1 << 2)
    public static let other = LinkMouseButtons(rawValue: 1 << 3)
}

public struct LinkWindowFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let focused = LinkWindowFlags(rawValue: 1 << 0)
    public static let minimised = LinkWindowFlags(rawValue: 1 << 1)
    public static let fullScreen = LinkWindowFlags(rawValue: 1 << 2)
    public static let modal = LinkWindowFlags(rawValue: 1 << 3)
    public static let onScreen = LinkWindowFlags(rawValue: 1 << 4)
    public static let main = LinkWindowFlags(rawValue: 1 << 5)
}

/// What can be done to one window (`window.capabilities`).
public struct LinkWindowCapabilities: OptionSet, Sendable, Hashable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public static let resizable = LinkWindowCapabilities(rawValue: 1 << 0)
    public static let movable = LinkWindowCapabilities(rawValue: 1 << 1)
    public static let closable = LinkWindowCapabilities(rawValue: 1 << 2)
    public static let supportsTablet = LinkWindowCapabilities(rawValue: 1 << 3)
    public static let menuAvailable = LinkWindowCapabilities(rawValue: 1 << 4)
    public static let minimisable = LinkWindowCapabilities(rawValue: 1 << 5)
    public static let zoomable = LinkWindowCapabilities(rawValue: 1 << 6)
}

public struct LinkVideoFrameFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    /// Decodable without earlier frames.
    public static let key = LinkVideoFrameFlags(rawValue: 1 << 0)
    /// Sent to repair loss; may reference a long-term reference frame.
    public static let refresh = LinkVideoFrameFlags(rawValue: 1 << 1)
    /// Marked as a long-term reference; the client acknowledges it with `video.ack`.
    public static let ltr = LinkVideoFrameFlags(rawValue: 1 << 2)
}
