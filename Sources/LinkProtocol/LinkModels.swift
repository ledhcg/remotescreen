import Foundation

/// What the iPad can render, from `hello`. Lets the helper pick sensible stream sizes.
public struct LinkSceneLimits: Sendable, Equatable {
    public var maxWindows: UInt16
    public var maxStreams: UInt16
    public var maxPixelWidth: UInt32
    public var maxPixelHeight: UInt32
    public var maxFramesPerSecond: UInt16
    public init(maxWindows: UInt16, maxStreams: UInt16, maxPixelWidth: UInt32, maxPixelHeight: UInt32, maxFramesPerSecond: UInt16) {
        self.maxWindows = maxWindows; self.maxStreams = maxStreams
        self.maxPixelWidth = maxPixelWidth; self.maxPixelHeight = maxPixelHeight; self.maxFramesPerSecond = maxFramesPerSecond
    }
}

/// First message of a connection, in both directions. Sent inside the authenticated channel.
public struct LinkHello: Sendable, Equatable {
    public var protocolMin: UInt16
    public var protocolMax: UInt16
    public var capabilities: LinkCapabilities
    public var deviceName: String
    public var sceneLimits: LinkSceneLimits
    public init(protocolMin: UInt16, protocolMax: UInt16, capabilities: LinkCapabilities, deviceName: String, sceneLimits: LinkSceneLimits) {
        self.protocolMin = protocolMin; self.protocolMax = protocolMax; self.capabilities = capabilities
        self.deviceName = deviceName; self.sceneLimits = sceneLimits
    }
    public var protocolRange: ClosedRange<UInt16>? { protocolMin <= protocolMax ? protocolMin...protocolMax : nil }
}

/// A display of the Mac.
public struct LinkDisplayInfo: Sendable, Equatable {
    public var id: UInt32
    public var frame: LinkRect
    public var scale: Double
    public init(id: UInt32, frame: LinkRect, scale: Double) { self.id = id; self.frame = frame; self.scale = scale }
}

/// Helper's answer to `hello`.
public struct LinkWelcome: Sendable, Equatable {
    public var protocolVersion: UInt16
    public var sessionID: UInt64
    /// Opaque, single use, valid for a few minutes (see `resume`).
    public var resumeToken: LinkBytes32
    public var macName: String
    public var displays: [LinkDisplayInfo]
    public var capabilities: LinkCapabilities
    public init(protocolVersion: UInt16, sessionID: UInt64, resumeToken: LinkBytes32, macName: String, displays: [LinkDisplayInfo], capabilities: LinkCapabilities) {
        self.protocolVersion = protocolVersion; self.sessionID = sessionID; self.resumeToken = resumeToken
        self.macName = macName; self.displays = displays; self.capabilities = capabilities
    }
}

/// Sent by the iPad after a reconnect instead of starting a new session.
public struct LinkResume: Sendable, Equatable {
    public var resumeToken: LinkBytes32
    public var lastStateVersion: UInt64
    public init(resumeToken: LinkBytes32, lastStateVersion: UInt64) { self.resumeToken = resumeToken; self.lastStateVersion = lastStateVersion }
}

/// One application in `apps.items`, `snapshot` and `apps.changed`.
public struct LinkAppInfo: Sendable, Equatable {
    public var ref: AppRef
    public var bundleID: String
    public var name: String
    public var pid: Int32?
    public var iconKey: IconKey
    public var isActive: Bool
    public var windowCount: UInt16
    public init(ref: AppRef, bundleID: String, name: String, pid: Int32?, iconKey: IconKey, isActive: Bool, windowCount: UInt16) {
        self.ref = ref; self.bundleID = bundleID; self.name = name; self.pid = pid
        self.iconKey = iconKey; self.isActive = isActive; self.windowCount = windowCount
    }
}

/// A window as announced by `window.created` and `snapshot`. Frames are in Mac points.
public struct LinkWindowInfo: Sendable, Equatable {
    public var id: WindowID
    public var pid: Int32
    public var bundleID: String
    public var parentID: WindowID?
    public var kind: LinkWindowKind
    public var level: Int16
    public var frame: LinkRect
    public var scale: Double
    public var title: String
    public var flags: LinkWindowFlags
    public var minSize: LinkSize
    /// A zero component means "no maximum".
    public var maxSize: LinkSize
    public init(
        id: WindowID, pid: Int32, bundleID: String, parentID: WindowID? = nil, kind: LinkWindowKind = .managed, level: Int16 = 0,
        frame: LinkRect, scale: Double, title: String, flags: LinkWindowFlags = [],
        minSize: LinkSize = LinkSize(width: 0, height: 0), maxSize: LinkSize = LinkSize(width: 0, height: 0)
    ) {
        self.id = id; self.pid = pid; self.bundleID = bundleID; self.parentID = parentID; self.kind = kind; self.level = level
        self.frame = frame; self.scale = scale; self.title = title; self.flags = flags; self.minSize = minSize; self.maxSize = maxSize
    }
}

/// `window.updated`: only the fields that changed are present.
public struct LinkWindowUpdate: Sendable, Equatable {
    public var id: WindowID
    public var stateVersion: UInt64
    public var frame: LinkRect?
    public var title: String?
    public var flags: LinkWindowFlags?
    public var level: Int16?
    public var scale: Double?
    public var minSize: LinkSize?
    public var maxSize: LinkSize?
    public init(
        id: WindowID, stateVersion: UInt64, frame: LinkRect? = nil, title: String? = nil, flags: LinkWindowFlags? = nil,
        level: Int16? = nil, scale: Double? = nil, minSize: LinkSize? = nil, maxSize: LinkSize? = nil
    ) {
        self.id = id; self.stateVersion = stateVersion; self.frame = frame; self.title = title; self.flags = flags
        self.level = level; self.scale = scale; self.minSize = minSize; self.maxSize = maxSize
    }
}

/// Full state, replacing whatever the client had. `windows` are in front-to-back order.
public struct LinkSnapshot: Sendable, Equatable {
    public var stateVersion: UInt64
    public var apps: [LinkAppInfo]
    public var windows: [LinkWindowInfo]
    public var activeWindow: WindowID?
    public init(stateVersion: UInt64, apps: [LinkAppInfo], windows: [LinkWindowInfo], activeWindow: WindowID? = nil) {
        self.stateVersion = stateVersion; self.apps = apps; self.windows = windows; self.activeWindow = activeWindow
    }
}

/// Per-window receive statistics (iPad → helper, every 250 ms). `receivedBytes`, `decodedFrames` and `droppedFrames` are
/// DELTAS since the previous report for that window (not running totals); `decodeP95Micros` covers the same interval.
public struct LinkWindowStats: Sendable, Equatable {
    public var window: WindowID
    public var receivedBytes: UInt64
    public var decodedFrames: UInt32
    public var droppedFrames: UInt32
    public var decodeP95Micros: UInt32
    public init(window: WindowID, receivedBytes: UInt64, decodedFrames: UInt32, droppedFrames: UInt32, decodeP95Micros: UInt32) {
        self.window = window; self.receivedBytes = receivedBytes; self.decodedFrames = decodedFrames
        self.droppedFrames = droppedFrames; self.decodeP95Micros = decodeP95Micros
    }
}

public struct LinkStats: Sendable, Equatable {
    public var rttMicros: UInt32
    public var windows: [LinkWindowStats]
    public init(rttMicros: UInt32, windows: [LinkWindowStats]) { self.rttMicros = rttMicros; self.windows = windows }
}

/// Helper → iPad condition changes.
public enum LinkStatus: Sendable, Equatable {
    case macLocked(Bool)
    case permissionMissing(LinkPermissionKind)
    case stageUnavailable
    /// Secure text input became active (`active`) or ended (`!active`). `pid` is the process that holds it, or `nil` when
    /// unknown. While active, synthetic keys may be blocked. The helper sends the inactive form when it ends, so the iPad can
    /// clear its banner.
    case secureInput(active: Bool, pid: Int32?)
    case permission(LinkPermissionKind, LinkPermissionState)
    case stage(LinkStageState)
}

public struct LinkPairProve: Sendable, Equatable {
    /// The QR code's nonce: names the pairing offer this proof is for, so a wrong proof is charged to that offer only and
    /// an unknown nonce can be refused without touching any offer. Public (it is in the QR code); the secret is not sent.
    public var nonce: LinkBytes16
    public var deviceName: String
    public var ipadSPKIHash: LinkBytes32
    public var mac: LinkBytes32
    public init(nonce: LinkBytes16, deviceName: String, ipadSPKIHash: LinkBytes32, mac: LinkBytes32) {
        self.nonce = nonce; self.deviceName = deviceName; self.ipadSPKIHash = ipadSPKIHash; self.mac = mac
    }
}

public struct LinkPairOK: Sendable, Equatable {
    public var macName: String
    public var helperID: LinkBytes32
    public init(macName: String, helperID: LinkBytes32) { self.macName = macName; self.helperID = helperID }
}

public struct LinkSubscribe: Sendable, Equatable {
    public var window: WindowID
    public var pixelWidth: UInt32
    public var pixelHeight: UInt32
    public var maxFramesPerSecond: UInt16
    public var quality: LinkQualityTier
    public init(window: WindowID, pixelWidth: UInt32, pixelHeight: UInt32, maxFramesPerSecond: UInt16, quality: LinkQualityTier) {
        self.window = window; self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
        self.maxFramesPerSecond = maxFramesPerSecond; self.quality = quality
    }
}

public struct LinkSetFrame: Sendable, Equatable {
    public var window: WindowID
    public var size: LinkSize
    public var placement: LinkPlacementHint
    public init(window: WindowID, size: LinkSize, placement: LinkPlacementHint) { self.window = window; self.size = size; self.placement = placement }
}

public struct LinkVideoConfig: Sendable, Equatable {
    public var window: WindowID
    public var codec: LinkVideoCodec
    /// SPS/PPS (H.264) or VPS/SPS/PPS (HEVC), each without start code.
    public var parameterSets: [Data]
    public var pixelWidth: UInt32
    public var pixelHeight: UInt32
    /// The part of the coded frame that shows the window, in pixels.
    public var contentRect: LinkRect
    public var scale: Double
    public init(window: WindowID, codec: LinkVideoCodec, parameterSets: [Data], pixelWidth: UInt32, pixelHeight: UInt32, contentRect: LinkRect, scale: Double) {
        self.window = window; self.codec = codec; self.parameterSets = parameterSets; self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight; self.contentRect = contentRect; self.scale = scale
    }
}

public struct LinkVideoFrame: Sendable, Equatable {
    public var window: WindowID
    public var sequence: UInt32
    public var ptsMicros: UInt64
    public var flags: LinkVideoFrameFlags
    /// Length-prefixed NAL units exactly as the helper's encoder produced them. Never empty.
    public var data: Data
    public init(window: WindowID, sequence: UInt32, ptsMicros: UInt64, flags: LinkVideoFrameFlags, data: Data) {
        self.window = window; self.sequence = sequence; self.ptsMicros = ptsMicros; self.flags = flags; self.data = data
    }
}

public struct LinkSurfaceSnapshot: Sendable, Equatable {
    public var window: WindowID
    public var id: SurfaceID
    public var parentID: SurfaceID?
    /// Offset from the window's content origin, in Mac points.
    public var offset: LinkPoint
    public var format: LinkImageFormat
    public var data: Data
    public init(window: WindowID, id: SurfaceID, parentID: SurfaceID?, offset: LinkPoint, format: LinkImageFormat, data: Data) {
        self.window = window; self.id = id; self.parentID = parentID; self.offset = offset; self.format = format; self.data = data
    }
}

public struct LinkCursorShape: Sendable, Equatable {
    public var window: WindowID
    public var id: CursorID
    public var hotspot: LinkPoint
    public var png: Data
    public init(window: WindowID, id: CursorID, hotspot: LinkPoint, png: Data) { self.window = window; self.id = id; self.hotspot = hotspot; self.png = png }
}

public struct LinkAudioConfig: Sendable, Equatable {
    public var pid: Int32
    public var codec: LinkAudioCodec
    public var sampleRate: UInt32
    public var channels: UInt8
    public var frameDurationMicros: UInt32
    public init(pid: Int32, codec: LinkAudioCodec, sampleRate: UInt32, channels: UInt8, frameDurationMicros: UInt32) {
        self.pid = pid; self.codec = codec; self.sampleRate = sampleRate; self.channels = channels; self.frameDurationMicros = frameDurationMicros
    }
}

public struct LinkAudioPacket: Sendable, Equatable {
    public var pid: Int32
    public var sequence: UInt32
    public var ptsMicros: UInt64
    public var data: Data
    public init(pid: Int32, sequence: UInt32, ptsMicros: UInt64, data: Data) {
        self.pid = pid; self.sequence = sequence; self.ptsMicros = ptsMicros; self.data = data
    }
}

/// Apple Pencil tilt in radians.
public struct LinkTilt: Sendable, Equatable {
    public var x: Float
    public var y: Float
    public init(x: Float, y: Float) { self.x = x; self.y = y }
}

/// Pointer position in Mac points relative to the window's content origin. `pressure` (0...1) and `tilt` are present for Pencil.
public struct LinkPointerEvent: Sendable, Equatable {
    public var window: WindowID
    public var point: LinkPoint
    public var buttons: LinkMouseButtons
    public var modifiers: LinkModifiers
    public var pressure: Float?
    public var tilt: LinkTilt?
    public init(window: WindowID, point: LinkPoint, buttons: LinkMouseButtons, modifiers: LinkModifiers, pressure: Float? = nil, tilt: LinkTilt? = nil) {
        self.window = window; self.point = point; self.buttons = buttons; self.modifiers = modifiers; self.pressure = pressure; self.tilt = tilt
    }
}

public struct LinkScrollEvent: Sendable, Equatable {
    public var window: WindowID
    public var dx: Double
    public var dy: Double
    public var phase: LinkScrollPhase
    public var momentumPhase: LinkScrollPhase
    /// True for trackpad-style pixel scrolling, false for wheel notches.
    public var continuous: Bool
    public init(window: WindowID, dx: Double, dy: Double, phase: LinkScrollPhase, momentumPhase: LinkScrollPhase, continuous: Bool) {
        self.window = window; self.dx = dx; self.dy = dy; self.phase = phase; self.momentumPhase = momentumPhase; self.continuous = continuous
    }
}

public struct LinkGestureEvent: Sendable, Equatable {
    public var window: WindowID
    public var kind: LinkGestureKind
    public var value: Double
    public var phase: LinkGesturePhase
    public init(window: WindowID, kind: LinkGestureKind, value: Double, phase: LinkGesturePhase) {
        self.window = window; self.kind = kind; self.value = value; self.phase = phase
    }
}

public struct LinkKeyEvent: Sendable, Equatable {
    /// Hardware virtual key code, or `LinkKeyEvent.noKeycode` (0xFFFF) meaning "no Mac keycode: use `keysym`".
    public var keycode: UInt16
    /// X11-style keysym when known, for layouts the helper cannot derive from the keycode. With `noKeycode` the helper maps it
    /// to a Mac key (US layout) or types the character; an unknown non-printable keysym is dropped.
    public var keysym: UInt32?
    public var down: Bool
    public var modifiers: LinkModifiers
    /// Sentinel `keycode`: the sender has no Mac virtual key code, only a keysym.
    public static let noKeycode: UInt16 = 0xFFFF
    public init(keycode: UInt16, keysym: UInt32? = nil, down: Bool, modifiers: LinkModifiers) {
        self.keycode = keycode; self.keysym = keysym; self.down = down; self.modifiers = modifiers
    }
}

/// One menu item. A separator has `isSeparator` and an empty title.
public struct LinkMenuItem: Sendable, Equatable {
    public var title: String
    public var enabled: Bool
    public var checked: Bool
    public var isSeparator: Bool
    public var keyEquivalent: String
    public var modifiers: LinkModifiers
    public var children: [LinkMenuItem]
    public init(title: String, enabled: Bool = true, checked: Bool = false, isSeparator: Bool = false, keyEquivalent: String = "", modifiers: LinkModifiers = [], children: [LinkMenuItem] = []) {
        self.title = title; self.enabled = enabled; self.checked = checked; self.isSeparator = isSeparator
        self.keyEquivalent = keyEquivalent; self.modifiers = modifiers; self.children = children
    }
}

public struct LinkFileBegin: Sendable, Equatable {
    public var transfer: TransferID
    public var name: String
    public var size: UInt64
    public var targetBundleID: String?
    public init(transfer: TransferID, name: String, size: UInt64, targetBundleID: String?) {
        self.transfer = transfer; self.name = name; self.size = size; self.targetBundleID = targetBundleID
    }
}

public struct LinkFileChunk: Sendable, Equatable {
    public var transfer: TransferID
    public var offset: UInt64
    public var data: Data
    public init(transfer: TransferID, offset: UInt64, data: Data) { self.transfer = transfer; self.offset = offset; self.data = data }
}
