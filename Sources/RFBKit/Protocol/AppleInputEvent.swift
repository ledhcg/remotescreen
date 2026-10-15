import Foundation

/// Apple-specific event sent via message type 23 (`HandleEventMessage2` of `screensharingd`): trackpad-style smooth scrolling and
/// pinch and rotate gestures. The server forwards the payload as-is to `ScreensharingAgent`, which builds the real `CGEvent` and posts it to the Mac.
///
/// Layout read from the binary and tested on a real Mac (an AppKit window logging the `NSEvent` it received): see `docs/protocol-notes.md`
/// section 4h. All numbers are big-endian.
public enum AppleInputEvent: Equatable, Sendable {
    /// Type 11: a full `kCGEventScrollWheel` (distance in points, scroll phase, momentum phase).
    case scroll(AppleScroll)
    /// Type 3: pinch (`magnification` of `NSEvent`: a relative change, for example 0.05 zooms in a further 5%).
    case magnify(Double, phase: AppleGesturePhase, x: UInt16, y: UInt16)
    /// Type 5: rotation, in degrees (positive is counterclockwise, like `NSEvent.rotation`).
    case rotate(Double, phase: AppleGesturePhase, x: UInt16, y: UInt16)

    /// Payload version. Pinch/rotate must use version 2 (with phase): a real Mac **ignores** version 1 pinch/rotate, and no application receives them.
    var version: UInt16 {
        switch self {
        case .scroll: 1
        case .magnify, .rotate: 2
        }
    }

    var kind: UInt16 {
        switch self {
        case .scroll: 11
        case .magnify: 3
        case .rotate: 5
        }
    }

    /// Payload (the part after the 4-byte header of message 23).
    var payload: Data {
        var data = Data()
        data.appendBigEndian(version)
        data.appendBigEndian(kind)
        switch self {
        case .scroll(let scroll):
            data.append(scroll.body)
        case .magnify(let value, let phase, let x, let y), .rotate(let value, let phase, let x, let y):
            let finite = value.isFinite ? value : 0
            withUnsafeBytes(of: finite.bitPattern.bigEndian) { data.append(contentsOf: $0) }
            data.appendBigEndian(x)
            data.appendBigEndian(y)
            withUnsafeBytes(of: phase.rawValue.bigEndian) { data.append(contentsOf: $0) }
            // "Mask" (field 133): trying 0, 2, 4, 8 on a real Mac all gave the same result.
            withUnsafeBytes(of: UInt64(0)) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// `[23][flags = 0][u16 payload length][payload]`.
    var wireBytes: Data {
        let payload = payload
        var data = Data([23, 0])
        data.appendBigEndian(UInt16(payload.count))
        data.append(payload)
        return data
    }
}

/// Phase of pinch/rotate (`CGEvent` field 132), with values like the scroll phase. On a real Mac it becomes `NSEvent.phase` began, changed, ended.
public enum AppleGesturePhase: UInt64, Sendable {
    case began = 1, changed = 2, ended = 4
}

/// One trackpad-style scroll step (`kCGEventScrollWheel` with phase), coordinates in framebuffer pixels like `PointerEvent`.
public struct AppleScroll: Equatable, Sendable {
    /// `kCGScrollPhase`.
    public enum Phase: UInt32, Sendable {
        case none = 0, began = 1, changed = 2, ended = 4, cancelled = 8, mayBegin = 128
    }

    /// `kCGMomentumScrollPhase`: momentum after the finger lifts.
    public enum Momentum: UInt32, Sendable {
        case none = 0, begin = 1, `continue` = 2, end = 3
    }

    /// Scroll distance in Mac points. Positive: content moves down / right (like swiping down on a trackpad with natural scrolling).
    public var deltaX: Int32
    public var deltaY: Int32
    public var phase: Phase
    public var momentum: Momentum
    public var x: UInt16
    public var y: UInt16

    public init(deltaX: Int32, deltaY: Int32, phase: Phase, momentum: Momentum = .none, x: UInt16, y: UInt16) {
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.phase = phase
        self.momentum = momentum
        self.x = x
        self.y = y
    }

    /// Points per wheel "line": a real trackpad reports a line distance of roughly points / 10.
    static let pointsPerLine: Int32 = 10

    /// 50 bytes after the type: lines (s16 ×3), lines as 16.16 (s32 ×3), points (s32 ×3), phase, momentum phase, count, flags, x, y.
    /// Axis order in each group is horizontal, vertical, axis 3 (the order the agent reads: offset 4 → axis 2, offset 6 → axis 1).
    var body: Data {
        var data = Data()
        func s16(_ value: Int32) { data.appendBigEndian(UInt16(bitPattern: Int16(clamping: value))) }
        func s32(_ value: Int32) { data.appendBigEndian(UInt32(bitPattern: value)) }
        // The agent adds 1 to a non-zero line magnitude, so send the integer part of points / 10 (0 for small scrolls).
        s16(deltaX / Self.pointsPerLine)
        s16(deltaY / Self.pointsPerLine)
        s16(0)
        s32(Int32(clamping: Int64(deltaX) * 65_536 / Int64(Self.pointsPerLine)))
        s32(Int32(clamping: Int64(deltaY) * 65_536 / Int64(Self.pointsPerLine)))
        s32(0)
        s32(deltaX)
        s32(deltaY)
        s32(0)
        data.appendBigEndian(phase.rawValue)
        data.appendBigEndian(momentum.rawValue)
        s32(0) // consecutive scroll count: left for the agent/system to compute
        data.appendBigEndian(UInt32(1 << 1)) // bit 1: `IsContinuous` (trackpad, not a notched wheel)
        data.appendBigEndian(x)
        data.appendBigEndian(y)
        return data
    }
}
