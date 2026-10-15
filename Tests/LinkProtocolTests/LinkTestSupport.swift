import Foundation
@testable import LinkProtocol

/// Seeded random number generator, so any failing run can be reproduced.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// Builds a raw frame, bypassing the encoder, so tests can craft hostile input.
func rawFrame(type: UInt16, length: UInt32? = nil, payload: [UInt8]) -> [UInt8] {
    var w = LinkWriter()
    w.u16(type)
    w.u32(length ?? UInt32(payload.count))
    return w.bytes + payload
}

func rawFrame(_ type: LinkMessageType, length: UInt32? = nil, payload: [UInt8]) -> [UInt8] {
    rawFrame(type: type.rawValue, length: length, payload: payload)
}

func decodeAll(_ bytes: [UInt8]) throws -> [LinkMessage] {
    var decoder = LinkFrameDecoder()
    return try decoder.feed(bytes: bytes)
}

func payloadError(_ type: LinkMessageType, _ payload: [UInt8]) -> LinkError? {
    do {
        _ = try decodeAll(rawFrame(type, payload: payload))
        return nil
    } catch let error as LinkError {
        return error
    } catch {
        return .malformed("not a LinkError: \(error)")
    }
}

func isMalformed(_ error: LinkError?) -> Bool { if case .malformed = error { return true } else { return false } }
func isLimit(_ error: LinkError?) -> Bool { if case .limitExceeded = error { return true } else { return false } }

/// A UTF-8 string field as it appears on the wire.
func wireString(_ s: String) -> [UInt8] {
    var w = LinkWriter()
    w.u16(UInt16(s.utf8.count))
    return w.bytes + Array(s.utf8)
}

func wireBytes(_ n: Int, _ value: UInt8 = 0) -> [UInt8] { [UInt8](repeating: value, count: n) }

enum Samples {
    static let rect = LinkRect(x: 10.5, y: -20, width: 800, height: 600)
    static let app = LinkAppInfo(ref: 7, bundleID: "com.example.notes", name: "Notes", pid: 321, iconKey: 3, isActive: true, windowCount: 2)
    static let window = LinkWindowInfo(
        id: 11, pid: 321, bundleID: "com.example.notes", parentID: 4, kind: .transient, level: -1, frame: rect, scale: 2,
        title: "Shopping list", flags: [.focused, .onScreen], minSize: LinkSize(width: 200, height: 100), maxSize: LinkSize(width: 0, height: 0)
    )
    static let menu = LinkMenuItem(title: "File", children: [
        LinkMenuItem(title: "New", keyEquivalent: "n", modifiers: [.command]),
        LinkMenuItem(title: "", isSeparator: true),
        LinkMenuItem(title: "Recent", enabled: false, checked: true, children: [LinkMenuItem(title: "a.txt")]),
    ])

    /// One of every message type.
    static let all: [LinkMessage] = [
        .hello(LinkHello(protocolMin: 1, protocolMax: 2, capabilities: [.stage, .menus, .ltr], deviceName: "Alice's iPad",
                         sceneLimits: LinkSceneLimits(maxWindows: 8, maxStreams: 4, maxPixelWidth: 2732, maxPixelHeight: 2048, maxFramesPerSecond: 60))),
        .welcome(LinkWelcome(protocolVersion: 1, sessionID: 99, resumeToken: LinkBytes32(repeating: 1), macName: "mac.local",
                             displays: [LinkDisplayInfo(id: 1, frame: rect, scale: 2)], capabilities: [.hevc, .files])),
        .resume(LinkResume(resumeToken: LinkBytes32(repeating: 2), lastStateVersion: 41)),
        .snapshot(LinkSnapshot(stateVersion: 5, apps: [app], windows: [window], activeWindow: 11)),
        .ping(timestampMicros: 123_456_789),
        .pong(timestampMicros: 123_456_789),
        .stats(LinkStats(rttMicros: 4500, windows: [LinkWindowStats(window: 11, receivedBytes: 1 << 40, decodedFrames: 60, droppedFrames: 1, decodeP95Micros: 3000)])),
        .status(.macLocked(true)),
        .status(.permissionMissing(.screenRecording)),
        .status(.stageUnavailable),
        .status(.secureInput(pid: 321)),
        .status(.secureInput(pid: nil)),
        .status(.permission(.accessibility, .denied)),
        .status(.stage(.active)),
        .approvalRequired,
        .close(code: .protocolViolation, reason: "bad frame"),
        .pairProve(LinkPairProve(deviceName: "Alice's iPad", ipadSPKIHash: LinkBytes32(repeating: 3), mac: LinkBytes32(repeating: 4))),
        .pairChallenge(LinkBytes32(repeating: 5)),
        .pairOK(LinkPairOK(macName: "mac.local", helperID: LinkBytes32(repeating: 6))),
        .pairDenied(.tooManyAttempts),
        .sasCommit(LinkBytes32(repeating: 7)),
        .sasReveal(LinkBytes32(repeating: 8)),
        .appsList(filter: .recent),
        .appsItems([app, app]),
        .appsIcon(key: 3, pixelSize: 128),
        .appsIconData(key: 3, png: Data([0x89, 0x50, 0x4E, 0x47])),
        .appsLaunch(bundleID: "com.example.notes"),
        .appsActivate(bundleID: "com.example.notes"),
        .appsQuit(bundleID: "com.example.notes"),
        .appsChanged(change: .terminated, app: app),
        .windowCreated(window),
        .windowUpdated(LinkWindowUpdate(id: 11, stateVersion: 6, frame: rect, title: "Renamed", flags: [.fullScreen], level: 3, scale: 1, minSize: LinkSize(width: 1, height: 2), maxSize: LinkSize(width: 3, height: 4))),
        .windowUpdated(LinkWindowUpdate(id: 11, stateVersion: 7)),
        .windowDestroyed(11),
        .windowOrder(ids: [11, 12, 13], active: 12),
        .windowSubscribe(LinkSubscribe(window: 11, pixelWidth: 1600, pixelHeight: 1200, maxFramesPerSecond: 60, quality: .high)),
        .windowUnsubscribe(11),
        .windowSetFrame(LinkSetFrame(window: 11, size: LinkSize(width: 640, height: 480), placement: .cascade)),
        .windowCommand(window: 11, command: .exitFullScreen),
        .windowCapabilities(window: 11, capabilities: [.resizable, .closable, .menuAvailable]),
        .streamKeyframe(11),
        .videoConfig(LinkVideoConfig(window: 11, codec: .hevc, parameterSets: [Data([1, 2, 3]), Data([4, 5])], pixelWidth: 1600, pixelHeight: 1200,
                                     contentRect: LinkRect(x: 0, y: 0, width: 1600, height: 1200), scale: 2)),
        .videoFrame(LinkVideoFrame(window: 11, sequence: 9, ptsMicros: 1_000_000, flags: [.key, .ltr], data: Data([0, 0, 0, 2, 0x65, 0x88]))),
        .videoAck(window: 11, ltrTokens: [1, 2, 3]),
        .videoLost(window: 11, firstSequence: 10, lastSequence: 12),
        .surfaceSnapshot(LinkSurfaceSnapshot(window: 11, id: 2, parentID: 1, offset: LinkPoint(x: 12.5, y: 40), format: .jpeg, data: Data([0xFF, 0xD8]))),
        .surfaceSnapshot(LinkSurfaceSnapshot(window: 11, id: 3, parentID: nil, offset: LinkPoint(x: 0, y: 0), format: .png, data: Data())),
        .cursorShape(LinkCursorShape(window: 11, id: 4, hotspot: LinkPoint(x: 1, y: 2), png: Data([1, 2, 3]))),
        .cursorRef(window: 11, id: 4),
        .audioConfig(LinkAudioConfig(pid: 321, codec: .opus, sampleRate: 48_000, channels: 2, frameDurationMicros: 20_000)),
        .audioPacket(LinkAudioPacket(pid: 321, sequence: 1, ptsMicros: 20_000, data: Data([9, 9, 9]))),
        .inputPointer(LinkPointerEvent(window: 11, point: LinkPoint(x: 100.25, y: 200.75), buttons: [.left], modifiers: [.shift, .command])),
        .inputPointer(LinkPointerEvent(window: 11, point: LinkPoint(x: 1, y: 2), buttons: [], modifiers: [], pressure: 0.5, tilt: LinkTilt(x: 0.25, y: -0.5))),
        .inputScroll(LinkScrollEvent(window: 11, dx: -3.5, dy: 12, phase: .changed, momentumPhase: .none, continuous: true)),
        .inputGesture(LinkGestureEvent(window: 11, kind: .magnify, value: 0.25, phase: .began)),
        .inputKey(LinkKeyEvent(keycode: 36, keysym: 0xFF0D, down: true, modifiers: [.control])),
        .inputKey(LinkKeyEvent(keycode: 0, keysym: nil, down: false, modifiers: [])),
        .inputText("Xin chào 👋"),
        .inputText(""),
        .menuGet(bundleID: "com.example.notes"),
        .menuTree(bundleID: "com.example.notes", items: [menu]),
        .menuTree(bundleID: "com.example.notes", items: []),
        .menuPress(bundleID: "com.example.notes", path: [0, 2, 1]),
        .clipboardOffer(types: ["public.utf8-plain-text", "public.png"]),
        .clipboardRequest(type: "public.utf8-plain-text"),
        .clipboardData(type: "public.utf8-plain-text", data: Data("hello".utf8)),
        .fileBegin(LinkFileBegin(transfer: 1, name: "report.pdf", size: 4096, targetBundleID: "com.example.notes")),
        .fileBegin(LinkFileBegin(transfer: 2, name: "a.txt", size: 0, targetBundleID: nil)),
        .fileChunk(LinkFileChunk(transfer: 1, offset: 1024, data: Data([1, 2, 3, 4]))),
        .fileEnd(transfer: 1, sha256: LinkBytes32(repeating: 0xAB)),
    ]
}
