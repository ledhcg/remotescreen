import Foundation

// Payload encoding and decoding for every message. Layout rules: little-endian, strings `u16 length + UTF-8`, blobs
// `u32 length + bytes`, lists `u16 count + elements`, optionals `u8 0/1 + value`. Each decoder checks every count against
// its cap and the remaining bytes before looping, and ends with `finish` so trailing bytes are an error.

private typealias Limits = LinkLimits

extension LinkMessage {
    /// Encodes only the payload (no frame header). Throws instead of producing something a peer would reject.
    public func encodePayload() throws -> [UInt8] {
        var w = LinkWriter()
        switch self {
        case .hello(let m):
            guard m.protocolMin <= m.protocolMax else { throw LinkError.invalidValue("protocol range is empty") }
            w.u16(m.protocolMin); w.u16(m.protocolMax); w.u64(m.capabilities.rawValue)
            try w.string(m.deviceName, maxBytes: Limits.maxDeviceNameBytes, "deviceName")
            try Self.write(m.sceneLimits, &w)
        case .welcome(let m):
            w.u16(m.protocolVersion); w.u64(m.sessionID); w.bytes32(m.resumeToken)
            try w.string(m.macName, maxBytes: Limits.maxNameBytes, "macName")
            try w.count(m.displays.count, max: Limits.maxDisplays, "displays")
            for d in m.displays { w.u32(d.id); try w.rect(d.frame, "display frame"); try w.scale(d.scale, "display scale") }
            w.u64(m.capabilities.rawValue)
        case .resume(let m):
            w.bytes32(m.resumeToken); w.u64(m.lastStateVersion)
        case .snapshot(let m):
            w.u64(m.stateVersion)
            try w.count(m.apps.count, max: Limits.maxApps, "apps")
            for app in m.apps { try Self.write(app, &w) }
            try w.count(m.windows.count, max: Limits.maxWindowsPerSnapshot, "windows")
            for window in m.windows { try Self.write(window, &w) }
            Self.writeOptional(m.activeWindow, &w) { $1.u32($0.rawValue) }
        case .ping(let t), .pong(let t):
            w.u64(t)
        case .stats(let m):
            w.u32(m.rttMicros)
            try w.count(m.windows.count, max: Limits.maxStatsWindows, "stats windows")
            for s in m.windows {
                w.u32(s.window.rawValue); w.u64(s.receivedBytes); w.u32(s.decodedFrames); w.u32(s.droppedFrames); w.u32(s.decodeP95Micros)
            }
        case .status(let m):
            switch m {
            case .macLocked(let locked): w.u8(0); w.bool(locked)
            case .permissionMissing(let kind): w.u8(1); w.enumeration(kind)
            case .stageUnavailable: w.u8(2)
            case .secureInput(let pid): w.u8(3); Self.writeOptional(pid, &w) { $1.i32($0) }
            case .permission(let kind, let state): w.u8(4); w.enumeration(kind); w.enumeration(state)
            case .stage(let state): w.u8(5); w.enumeration(state)
            }
        case .approvalRequired, .sasConfirm:
            break
        case .close(let code, let reason):
            w.u16(code.rawValue)
            try w.string(reason, maxBytes: Limits.maxReasonBytes, "reason")
        case .pairProve(let m):
            w.bytes16(m.nonce)
            try w.string(m.deviceName, maxBytes: Limits.maxDeviceNameBytes, "deviceName")
            w.bytes32(m.ipadSPKIHash); w.bytes32(m.mac)
        case .pairChallenge(let b), .sasCommit(let b), .sasReveal(let b):
            w.bytes32(b)
        case .pairOK(let m):
            try w.string(m.macName, maxBytes: Limits.maxNameBytes, "macName")
            w.bytes32(m.helperID)
        case .pairDenied(let reason):
            w.enumeration(reason)
        case .appsList(let filter):
            w.enumeration(filter)
        case .appsItems(let apps):
            try w.count(apps.count, max: Limits.maxApps, "apps")
            for app in apps { try Self.write(app, &w) }
        case .appsIcon(let key, let pixelSize):
            guard pixelSize >= 1, pixelSize <= Limits.maxIconPixelSize else { throw LinkError.invalidValue("icon size out of range") }
            w.u32(key.rawValue); w.u16(pixelSize)
        case .appsIconData(let key, let png):
            w.u32(key.rawValue)
            try w.blob(png, maxBytes: Limits.maxIconPNGBytes, "icon PNG")
        case .appsLaunch(let id), .appsActivate(let id), .appsQuit(let id), .menuGet(let id):
            try w.string(id, maxBytes: Limits.maxBundleIDBytes, "bundleID")
        case .appsChanged(let change, let app):
            w.enumeration(change)
            try Self.write(app, &w)
        case .windowCreated(let m):
            try Self.write(m, &w)
        case .windowUpdated(let m):
            try Self.write(m, &w)
        case .windowDestroyed(let id), .windowUnsubscribe(let id), .streamKeyframe(let id):
            w.u32(id.rawValue)
        case .windowOrder(let ids, let active):
            try w.count(ids.count, max: Limits.maxWindowsInOrder, "order")
            for id in ids { w.u32(id.rawValue) }
            Self.writeOptional(active, &w) { $1.u32($0.rawValue) }
        case .windowSubscribe(let m):
            w.u32(m.window.rawValue)
            try w.pixelDimension(m.pixelWidth, "target width"); try w.pixelDimension(m.pixelHeight, "target height")
            guard m.maxFramesPerSecond >= 1, m.maxFramesPerSecond <= Limits.maxFramesPerSecond else { throw LinkError.invalidValue("fps out of range") }
            w.u16(m.maxFramesPerSecond); w.enumeration(m.quality)
        case .windowSetFrame(let m):
            w.u32(m.window.rawValue); try w.size(m.size, "frame size"); w.enumeration(m.placement)
        case .windowCommand(let window, let command):
            w.u32(window.rawValue); w.enumeration(command)
        case .windowCapabilities(let window, let caps):
            w.u32(window.rawValue); w.u16(caps.rawValue)
        case .videoConfig(let m):
            w.u32(m.window.rawValue); w.enumeration(m.codec)
            try w.count(m.parameterSets.count, max: Limits.maxParameterSets, "parameter sets")
            for set in m.parameterSets { try w.blob(set, maxBytes: Limits.maxParameterSetBytes, "parameter set") }
            try w.pixelDimension(m.pixelWidth, "pixel width"); try w.pixelDimension(m.pixelHeight, "pixel height")
            try w.rect(m.contentRect, "content rect"); try w.scale(m.scale, "scale")
        case .videoFrame(let m):
            guard !m.data.isEmpty else { throw LinkError.invalidValue("empty video frame") }
            w.u32(m.window.rawValue); w.u32(m.sequence); w.u64(m.ptsMicros); w.u8(m.flags.rawValue)
            try w.blob(m.data, maxBytes: Limits.maxVideoAccessUnitBytes, "video frame")
        case .videoAck(let window, let tokens):
            w.u32(window.rawValue)
            try w.count(tokens.count, max: Limits.maxLTRTokens, "ltr tokens")
            for t in tokens { w.u32(t) }
        case .videoLost(let window, let first, let last):
            w.u32(window.rawValue); w.u32(first); w.u32(last)
        case .surfaceSnapshot(let m):
            w.u32(m.window.rawValue); w.u32(m.id.rawValue)
            Self.writeOptional(m.parentID, &w) { $1.u32($0.rawValue) }
            try w.point(m.offset, "surface offset"); w.enumeration(m.format)
            try w.blob(m.data, maxBytes: Limits.maxSurfaceImageBytes, "surface image")
        case .cursorShape(let m):
            w.u32(m.window.rawValue); w.u32(m.id.rawValue)
            try w.point(m.hotspot, "hotspot")
            try w.blob(m.png, maxBytes: Limits.maxCursorPNGBytes, "cursor PNG")
        case .cursorRef(let window, let id):
            w.u32(window.rawValue); w.u32(id.rawValue)
        case .audioConfig(let m):
            guard (Limits.minSampleRate...Limits.maxSampleRate).contains(m.sampleRate), (1...Limits.maxAudioChannels).contains(m.channels) else {
                throw LinkError.invalidValue("audio format out of range")
            }
            w.i32(m.pid); w.enumeration(m.codec); w.u32(m.sampleRate); w.u8(m.channels); w.u32(m.frameDurationMicros)
        case .audioPacket(let m):
            w.i32(m.pid); w.u32(m.sequence); w.u64(m.ptsMicros)
            try w.blob(m.data, maxBytes: Limits.maxAudioPacketBytes, "audio packet")
        case .inputPointer(let m):
            w.u32(m.window.rawValue); try w.point(m.point, "pointer"); w.u8(m.buttons.rawValue); w.u16(m.modifiers.rawValue)
            var flags: UInt8 = 0
            if m.pressure != nil { flags |= 1 }
            if m.tilt != nil { flags |= 2 }
            w.u8(flags)
            if let pressure = m.pressure {
                guard (0...1).contains(pressure) else { throw LinkError.invalidValue("pressure out of range") }
                try w.f32(pressure, "pressure")
            }
            if let tilt = m.tilt {
                guard abs(tilt.x) <= 2 * .pi, abs(tilt.y) <= 2 * .pi else { throw LinkError.invalidValue("tilt out of range") }
                try w.f32(tilt.x, "tilt"); try w.f32(tilt.y, "tilt")
            }
        case .inputScroll(let m):
            w.u32(m.window.rawValue)
            try Self.writeDelta(m.dx, &w, "scroll dx"); try Self.writeDelta(m.dy, &w, "scroll dy")
            w.enumeration(m.phase); w.enumeration(m.momentumPhase); w.bool(m.continuous)
        case .inputGesture(let m):
            w.u32(m.window.rawValue); w.enumeration(m.kind)
            try Self.writeDelta(m.value, &w, "gesture value"); w.enumeration(m.phase)
        case .inputKey(let m):
            w.u16(m.keycode); Self.writeOptional(m.keysym, &w) { $1.u32($0) }; w.bool(m.down); w.u16(m.modifiers.rawValue)
        case .inputText(let text):
            try w.string(text, maxBytes: Limits.maxTextInputBytes, "text")
        case .menuTree(let bundleID, let items):
            try w.string(bundleID, maxBytes: Limits.maxBundleIDBytes, "bundleID")
            var total = 0
            try Self.write(items, depth: 1, total: &total, &w)
        case .menuPress(let bundleID, let path):
            try w.string(bundleID, maxBytes: Limits.maxBundleIDBytes, "bundleID")
            try w.count(path.count, max: Limits.maxMenuDepth, "menu path")
            for index in path { w.u16(index) }
        case .clipboardOffer(let types):
            try w.count(types.count, max: Limits.maxClipboardTypes, "clipboard types")
            for t in types { try w.string(t, maxBytes: Limits.maxClipboardTypeBytes, "clipboard type") }
        case .clipboardRequest(let type):
            try w.string(type, maxBytes: Limits.maxClipboardTypeBytes, "clipboard type")
        case .clipboardData(let type, let data):
            try w.string(type, maxBytes: Limits.maxClipboardTypeBytes, "clipboard type")
            try w.blob(data, maxBytes: Limits.maxClipboardBytes, "clipboard data")
        case .fileBegin(let m):
            guard m.size <= Limits.maxFileBytes else { throw LinkError.limitExceeded("file size \(m.size), limit \(Limits.maxFileBytes)") }
            w.u32(m.transfer.rawValue)
            try w.string(try LinkFileName.validated(m.name), maxBytes: Limits.maxFileNameBytes, "file name")
            w.u64(m.size)
            if let target = m.targetBundleID { w.u8(1); try w.string(target, maxBytes: Limits.maxBundleIDBytes, "targetBundleID") } else { w.u8(0) }
        case .fileChunk(let m):
            w.u32(m.transfer.rawValue); w.u64(m.offset)
            try w.blob(m.data, maxBytes: Limits.maxFileChunkBytes, "file chunk")
        case .fileEnd(let transfer, let sha256):
            w.u32(transfer.rawValue); w.bytes32(sha256)
        }
        return w.bytes
    }

    /// Decodes one payload of a known type. Throws `LinkError`, never traps, and rejects trailing bytes.
    public static func decode(type: LinkMessageType, payload: [UInt8]) throws -> LinkMessage {
        var r = LinkReader(payload)
        let message = try decode(type: type, reader: &r)
        try r.finish(String(describing: type))
        return message
    }

    private static func decode(type: LinkMessageType, reader r: inout LinkReader) throws -> LinkMessage {
        switch type {
        case .hello:
            let min = try r.u16("protocolMin"), max = try r.u16("protocolMax")
            guard min <= max else { throw LinkError.malformed("protocol range is empty") }
            return .hello(LinkHello(
                protocolMin: min, protocolMax: max, capabilities: LinkCapabilities(rawValue: try r.u64("capabilities")),
                deviceName: try r.string(maxBytes: Limits.maxDeviceNameBytes, "deviceName"), sceneLimits: try readSceneLimits(&r)
            ))
        case .welcome:
            let version = try r.u16("protocolVersion"), session = try r.u64("sessionID"), token = try r.bytes32("resumeToken")
            let name = try r.string(maxBytes: Limits.maxNameBytes, "macName")
            let n = try r.count(max: Limits.maxDisplays, minElementBytes: 44, "displays")
            var displays: [LinkDisplayInfo] = []
            displays.reserveCapacity(n)
            for _ in 0..<n { displays.append(LinkDisplayInfo(id: try r.u32("display id"), frame: try r.rect("display frame"), scale: try r.scale("display scale"))) }
            return .welcome(LinkWelcome(
                protocolVersion: version, sessionID: session, resumeToken: token, macName: name, displays: displays,
                capabilities: LinkCapabilities(rawValue: try r.u64("capabilities"))
            ))
        case .resume:
            return .resume(LinkResume(resumeToken: try r.bytes32("resumeToken"), lastStateVersion: try r.u64("lastStateVersion")))
        case .snapshot:
            let version = try r.u64("stateVersion")
            let appCount = try r.count(max: Limits.maxApps, minElementBytes: appMinBytes, "apps")
            var apps: [LinkAppInfo] = []
            apps.reserveCapacity(appCount)
            for _ in 0..<appCount { apps.append(try readApp(&r)) }
            let windowCount = try r.count(max: Limits.maxWindowsPerSnapshot, minElementBytes: windowMinBytes, "windows")
            var windows: [LinkWindowInfo] = []
            windows.reserveCapacity(windowCount)
            for _ in 0..<windowCount { windows.append(try readWindow(&r)) }
            return .snapshot(LinkSnapshot(stateVersion: version, apps: apps, windows: windows, activeWindow: try readOptional(&r) { WindowID(try $0.u32("active window")) }))
        case .ping: return .ping(timestampMicros: try r.u64("timestamp"))
        case .pong: return .pong(timestampMicros: try r.u64("timestamp"))
        case .stats:
            let rtt = try r.u32("rtt")
            let n = try r.count(max: Limits.maxStatsWindows, minElementBytes: 24, "stats windows")
            var windows: [LinkWindowStats] = []
            windows.reserveCapacity(n)
            for _ in 0..<n {
                windows.append(LinkWindowStats(
                    window: WindowID(try r.u32("window")), receivedBytes: try r.u64("receivedBytes"), decodedFrames: try r.u32("decodedFrames"),
                    droppedFrames: try r.u32("droppedFrames"), decodeP95Micros: try r.u32("decodeP95")
                ))
            }
            return .stats(LinkStats(rttMicros: rtt, windows: windows))
        case .status:
            switch try r.u8("status tag") {
            case 0: return .status(.macLocked(try r.bool("macLocked")))
            case 1: return .status(.permissionMissing(try r.enumeration(LinkPermissionKind.self, "permission kind")))
            case 2: return .status(.stageUnavailable)
            case 3: return .status(.secureInput(pid: try readOptional(&r) { try $0.i32("pid") }))
            case 4: return .status(.permission(try r.enumeration(LinkPermissionKind.self, "permission kind"), try r.enumeration(LinkPermissionState.self, "permission state")))
            case 5: return .status(.stage(try r.enumeration(LinkStageState.self, "stage state")))
            default: throw LinkError.malformed("unknown status tag")
            }
        case .approvalRequired: return .approvalRequired
        case .sasConfirm: return .sasConfirm
        case .close:
            return .close(code: LinkCloseCode(rawValue: try r.u16("code")), reason: try r.string(maxBytes: Limits.maxReasonBytes, "reason"))
        case .pairProve:
            return .pairProve(LinkPairProve(
                nonce: try r.bytes16("nonce"),
                deviceName: try r.string(maxBytes: Limits.maxDeviceNameBytes, "deviceName"),
                ipadSPKIHash: try r.bytes32("ipadSPKIHash"), mac: try r.bytes32("mac")
            ))
        case .pairChallenge: return .pairChallenge(try r.bytes32("challenge"))
        case .pairOK:
            return .pairOK(LinkPairOK(macName: try r.string(maxBytes: Limits.maxNameBytes, "macName"), helperID: try r.bytes32("helperID")))
        case .pairDenied: return .pairDenied(try r.enumeration(LinkPairDenyReason.self, "deny reason"))
        case .sasCommit: return .sasCommit(try r.bytes32("commit"))
        case .sasReveal: return .sasReveal(try r.bytes32("reveal"))
        case .appsList: return .appsList(filter: try r.enumeration(LinkAppFilter.self, "filter"))
        case .appsItems:
            let n = try r.count(max: Limits.maxApps, minElementBytes: appMinBytes, "apps")
            var apps: [LinkAppInfo] = []
            apps.reserveCapacity(n)
            for _ in 0..<n { apps.append(try readApp(&r)) }
            return .appsItems(apps)
        case .appsIcon:
            let key = IconKey(try r.u32("iconKey")), size = try r.u16("pixelSize")
            guard size >= 1, size <= Limits.maxIconPixelSize else { throw LinkError.malformed("icon size out of range") }
            return .appsIcon(key: key, pixelSize: size)
        case .appsIconData:
            return .appsIconData(key: IconKey(try r.u32("iconKey")), png: try r.blob(maxBytes: Limits.maxIconPNGBytes, "icon PNG"))
        case .appsLaunch: return .appsLaunch(bundleID: try r.string(maxBytes: Limits.maxBundleIDBytes, "bundleID"))
        case .appsActivate: return .appsActivate(bundleID: try r.string(maxBytes: Limits.maxBundleIDBytes, "bundleID"))
        case .appsQuit: return .appsQuit(bundleID: try r.string(maxBytes: Limits.maxBundleIDBytes, "bundleID"))
        case .appsChanged:
            return .appsChanged(change: try r.enumeration(LinkAppChange.self, "change"), app: try readApp(&r))
        case .windowCreated: return .windowCreated(try readWindow(&r))
        case .windowUpdated: return .windowUpdated(try readUpdate(&r))
        case .windowDestroyed: return .windowDestroyed(WindowID(try r.u32("window")))
        case .windowOrder:
            let n = try r.count(max: Limits.maxWindowsInOrder, minElementBytes: 4, "order")
            var ids: [WindowID] = []
            ids.reserveCapacity(n)
            for _ in 0..<n { ids.append(WindowID(try r.u32("window"))) }
            return .windowOrder(ids: ids, active: try readOptional(&r) { WindowID(try $0.u32("active")) })
        case .windowSubscribe:
            let window = WindowID(try r.u32("window"))
            let w = try r.pixelDimension("target width"), h = try r.pixelDimension("target height")
            let fps = try r.u16("maxFPS")
            guard fps >= 1, fps <= Limits.maxFramesPerSecond else { throw LinkError.malformed("fps out of range") }
            return .windowSubscribe(LinkSubscribe(window: window, pixelWidth: w, pixelHeight: h, maxFramesPerSecond: fps, quality: try r.enumeration(LinkQualityTier.self, "quality")))
        case .windowUnsubscribe: return .windowUnsubscribe(WindowID(try r.u32("window")))
        case .windowSetFrame:
            return .windowSetFrame(LinkSetFrame(window: WindowID(try r.u32("window")), size: try r.size("frame size"), placement: try r.enumeration(LinkPlacementHint.self, "placement")))
        case .windowCommand:
            return .windowCommand(window: WindowID(try r.u32("window")), command: try r.enumeration(LinkWindowCommand.self, "command"))
        case .windowCapabilities:
            return .windowCapabilities(window: WindowID(try r.u32("window")), capabilities: LinkWindowCapabilities(rawValue: try r.u16("capabilities")))
        case .streamKeyframe: return .streamKeyframe(WindowID(try r.u32("window")))
        case .videoConfig:
            let window = WindowID(try r.u32("window")), codec = try r.enumeration(LinkVideoCodec.self, "codec")
            let n = try r.count(max: Limits.maxParameterSets, minElementBytes: 4, "parameter sets")
            var sets: [Data] = []
            sets.reserveCapacity(n)
            for _ in 0..<n { sets.append(try r.blob(maxBytes: Limits.maxParameterSetBytes, "parameter set")) }
            return .videoConfig(LinkVideoConfig(
                window: window, codec: codec, parameterSets: sets, pixelWidth: try r.pixelDimension("pixel width"),
                pixelHeight: try r.pixelDimension("pixel height"), contentRect: try r.rect("content rect"), scale: try r.scale("scale")
            ))
        case .videoFrame:
            let window = WindowID(try r.u32("window")), seq = try r.u32("sequence"), pts = try r.u64("pts")
            let flags = LinkVideoFrameFlags(rawValue: try r.u8("flags"))
            let data = try r.blob(maxBytes: Limits.maxVideoAccessUnitBytes, "video frame")
            guard !data.isEmpty else { throw LinkError.malformed("empty video frame") }
            return .videoFrame(LinkVideoFrame(window: window, sequence: seq, ptsMicros: pts, flags: flags, data: data))
        case .videoAck:
            let window = WindowID(try r.u32("window"))
            let n = try r.count(max: Limits.maxLTRTokens, minElementBytes: 4, "ltr tokens")
            var tokens: [UInt32] = []
            tokens.reserveCapacity(n)
            for _ in 0..<n { tokens.append(try r.u32("token")) }
            return .videoAck(window: window, ltrTokens: tokens)
        case .videoLost:
            return .videoLost(window: WindowID(try r.u32("window")), firstSequence: try r.u32("first"), lastSequence: try r.u32("last"))
        case .surfaceSnapshot:
            let window = WindowID(try r.u32("window")), id = SurfaceID(try r.u32("surface"))
            let parent = try readOptional(&r) { SurfaceID(try $0.u32("parent")) }
            return .surfaceSnapshot(LinkSurfaceSnapshot(
                window: window, id: id, parentID: parent, offset: try r.point("offset"), format: try r.enumeration(LinkImageFormat.self, "format"),
                data: try r.blob(maxBytes: Limits.maxSurfaceImageBytes, "surface image")
            ))
        case .cursorShape:
            return .cursorShape(LinkCursorShape(
                window: WindowID(try r.u32("window")), id: CursorID(try r.u32("cursor")), hotspot: try r.point("hotspot"),
                png: try r.blob(maxBytes: Limits.maxCursorPNGBytes, "cursor PNG")
            ))
        case .cursorRef: return .cursorRef(window: WindowID(try r.u32("window")), id: CursorID(try r.u32("cursor")))
        case .audioConfig:
            let pid = try r.i32("pid"), codec = try r.enumeration(LinkAudioCodec.self, "codec")
            let rate = try r.u32("sampleRate"), channels = try r.u8("channels"), frame = try r.u32("frameDuration")
            guard (Limits.minSampleRate...Limits.maxSampleRate).contains(rate), (1...Limits.maxAudioChannels).contains(channels) else {
                throw LinkError.malformed("audio format out of range")
            }
            return .audioConfig(LinkAudioConfig(pid: pid, codec: codec, sampleRate: rate, channels: channels, frameDurationMicros: frame))
        case .audioPacket:
            return .audioPacket(LinkAudioPacket(
                pid: try r.i32("pid"), sequence: try r.u32("sequence"), ptsMicros: try r.u64("pts"),
                data: try r.blob(maxBytes: Limits.maxAudioPacketBytes, "audio packet")
            ))
        case .inputPointer:
            let window = WindowID(try r.u32("window")), point = try r.point("pointer")
            let buttons = LinkMouseButtons(rawValue: try r.u8("buttons")), modifiers = LinkModifiers(rawValue: try r.u16("modifiers"))
            let flags = try r.u8("pointer flags")
            guard flags & ~3 == 0 else { throw LinkError.malformed("unknown pointer flags") }
            var pressure: Float?, tilt: LinkTilt?
            if flags & 1 != 0 {
                let p = try r.f32("pressure")
                guard (0...1).contains(p) else { throw LinkError.malformed("pressure out of range") }
                pressure = p
            }
            if flags & 2 != 0 {
                let x = try r.f32("tilt"), y = try r.f32("tilt")
                guard abs(x) <= 2 * .pi, abs(y) <= 2 * .pi else { throw LinkError.malformed("tilt out of range") }
                tilt = LinkTilt(x: x, y: y)
            }
            return .inputPointer(LinkPointerEvent(window: window, point: point, buttons: buttons, modifiers: modifiers, pressure: pressure, tilt: tilt))
        case .inputScroll:
            return .inputScroll(LinkScrollEvent(
                window: WindowID(try r.u32("window")), dx: try readDelta(&r, "scroll dx"), dy: try readDelta(&r, "scroll dy"),
                phase: try r.enumeration(LinkScrollPhase.self, "phase"), momentumPhase: try r.enumeration(LinkScrollPhase.self, "momentum phase"),
                continuous: try r.bool("continuous")
            ))
        case .inputGesture:
            return .inputGesture(LinkGestureEvent(
                window: WindowID(try r.u32("window")), kind: try r.enumeration(LinkGestureKind.self, "kind"),
                value: try readDelta(&r, "gesture value"), phase: try r.enumeration(LinkGesturePhase.self, "phase")
            ))
        case .inputKey:
            return .inputKey(LinkKeyEvent(
                keycode: try r.u16("keycode"), keysym: try readOptional(&r) { try $0.u32("keysym") },
                down: try r.bool("down"), modifiers: LinkModifiers(rawValue: try r.u16("modifiers"))
            ))
        case .inputText: return .inputText(try r.string(maxBytes: Limits.maxTextInputBytes, "text"))
        case .menuGet: return .menuGet(bundleID: try r.string(maxBytes: Limits.maxBundleIDBytes, "bundleID"))
        case .menuTree:
            let bundleID = try r.string(maxBytes: Limits.maxBundleIDBytes, "bundleID")
            var total = 0
            return .menuTree(bundleID: bundleID, items: try readItems(&r, depth: 1, total: &total))
        case .menuPress:
            let bundleID = try r.string(maxBytes: Limits.maxBundleIDBytes, "bundleID")
            let n = try r.count(max: Limits.maxMenuDepth, minElementBytes: 2, "menu path")
            var path: [UInt16] = []
            for _ in 0..<n { path.append(try r.u16("menu index")) }
            return .menuPress(bundleID: bundleID, path: path)
        case .clipboardOffer:
            let n = try r.count(max: Limits.maxClipboardTypes, minElementBytes: 2, "clipboard types")
            var types: [String] = []
            types.reserveCapacity(n)
            for _ in 0..<n { types.append(try r.string(maxBytes: Limits.maxClipboardTypeBytes, "clipboard type")) }
            return .clipboardOffer(types: types)
        case .clipboardRequest: return .clipboardRequest(type: try r.string(maxBytes: Limits.maxClipboardTypeBytes, "clipboard type"))
        case .clipboardData:
            return .clipboardData(type: try r.string(maxBytes: Limits.maxClipboardTypeBytes, "clipboard type"), data: try r.blob(maxBytes: Limits.maxClipboardBytes, "clipboard data"))
        case .fileBegin:
            let transfer = TransferID(try r.u32("transfer"))
            let name = try LinkFileName.validated(try r.string(maxBytes: Limits.maxFileNameBytes, "file name"))
            let size = try r.u64("size")
            guard size <= Limits.maxFileBytes else { throw LinkError.limitExceeded("file size \(size), limit \(Limits.maxFileBytes)") }
            return .fileBegin(LinkFileBegin(transfer: transfer, name: name, size: size, targetBundleID: try readOptional(&r) { try $0.string(maxBytes: Limits.maxBundleIDBytes, "targetBundleID") }))
        case .fileChunk:
            let transfer = TransferID(try r.u32("transfer")), offset = try r.u64("offset")
            guard offset <= Limits.maxFileBytes else { throw LinkError.limitExceeded("chunk offset \(offset)") }
            return .fileChunk(LinkFileChunk(transfer: transfer, offset: offset, data: try r.blob(maxBytes: Limits.maxFileChunkBytes, "file chunk")))
        case .fileEnd:
            return .fileEnd(transfer: TransferID(try r.u32("transfer")), sha256: try r.bytes32("sha256"))
        }
    }

    // MARK: Shared pieces

    /// Smallest encoded sizes, used to reject a count that cannot fit in the payload before reserving memory.
    private static let appMinBytes = 4 + 2 + 2 + 1 + 4 + 1 + 2
    private static let windowMinBytes = 4 + 4 + 2 + 1 + 1 + 2 + 32 + 8 + 2 + 4 + 16 + 16
    private static let menuItemMinBytes = 2 + 1 + 1 + 1 + 2 + 2 + 2

    private static func writeOptional<T>(_ value: T?, _ w: inout LinkWriter, _ body: (T, inout LinkWriter) throws -> Void) rethrows {
        if let value { w.u8(1); try body(value, &w) } else { w.u8(0) }
    }

    private static func readOptional<T>(_ r: inout LinkReader, _ body: (inout LinkReader) throws -> T) throws -> T? {
        try r.bool("presence") ? try body(&r) : nil
    }

    private static func writeDelta(_ value: Double, _ w: inout LinkWriter, _ what: String) throws {
        guard abs(value) <= Limits.maxCoordinate else { throw LinkError.invalidValue("\(what) out of range") }
        try w.f64(value, what)
    }

    private static func readDelta(_ r: inout LinkReader, _ what: String) throws -> Double {
        let value = try r.f64(what)
        guard abs(value) <= Limits.maxCoordinate else { throw LinkError.malformed("\(what) out of range") }
        return value
    }

    private static func write(_ m: LinkSceneLimits, _ w: inout LinkWriter) throws {
        guard m.maxPixelWidth <= Limits.maxPixelDimension, m.maxPixelHeight <= Limits.maxPixelDimension, m.maxFramesPerSecond <= Limits.maxFramesPerSecond else {
            throw LinkError.invalidValue("scene limits out of range")
        }
        w.u16(m.maxWindows); w.u16(m.maxStreams); w.u32(m.maxPixelWidth); w.u32(m.maxPixelHeight); w.u16(m.maxFramesPerSecond)
    }

    private static func readSceneLimits(_ r: inout LinkReader) throws -> LinkSceneLimits {
        let limits = LinkSceneLimits(
            maxWindows: try r.u16("maxWindows"), maxStreams: try r.u16("maxStreams"), maxPixelWidth: try r.u32("maxPixelWidth"),
            maxPixelHeight: try r.u32("maxPixelHeight"), maxFramesPerSecond: try r.u16("maxFPS")
        )
        guard limits.maxPixelWidth <= Limits.maxPixelDimension, limits.maxPixelHeight <= Limits.maxPixelDimension, limits.maxFramesPerSecond <= Limits.maxFramesPerSecond else {
            throw LinkError.malformed("scene limits out of range")
        }
        return limits
    }

    private static func write(_ app: LinkAppInfo, _ w: inout LinkWriter) throws {
        w.u32(app.ref.rawValue)
        try w.string(app.bundleID, maxBytes: Limits.maxBundleIDBytes, "bundleID")
        try w.string(app.name, maxBytes: Limits.maxNameBytes, "app name")
        writeOptional(app.pid, &w) { $1.i32($0) }
        w.u32(app.iconKey.rawValue); w.bool(app.isActive); w.u16(app.windowCount)
    }

    private static func readApp(_ r: inout LinkReader) throws -> LinkAppInfo {
        LinkAppInfo(
            ref: AppRef(try r.u32("app")), bundleID: try r.string(maxBytes: Limits.maxBundleIDBytes, "bundleID"),
            name: try r.string(maxBytes: Limits.maxNameBytes, "app name"), pid: try readOptional(&r) { try $0.i32("pid") },
            iconKey: IconKey(try r.u32("iconKey")), isActive: try r.bool("isActive"), windowCount: try r.u16("windowCount")
        )
    }

    private static func write(_ m: LinkWindowInfo, _ w: inout LinkWriter) throws {
        w.u32(m.id.rawValue); w.i32(m.pid)
        try w.string(m.bundleID, maxBytes: Limits.maxBundleIDBytes, "bundleID")
        writeOptional(m.parentID, &w) { $1.u32($0.rawValue) }
        w.enumeration(m.kind); w.i16(m.level)
        try w.rect(m.frame, "window frame"); try w.scale(m.scale, "window scale")
        try w.string(m.title, maxBytes: Limits.maxTitleBytes, "title")
        w.u32(m.flags.rawValue)
        try w.size(m.minSize, "minSize"); try w.size(m.maxSize, "maxSize")
    }

    private static func readWindow(_ r: inout LinkReader) throws -> LinkWindowInfo {
        LinkWindowInfo(
            id: WindowID(try r.u32("window")), pid: try r.i32("pid"), bundleID: try r.string(maxBytes: Limits.maxBundleIDBytes, "bundleID"),
            parentID: try readOptional(&r) { WindowID(try $0.u32("parent")) }, kind: try r.enumeration(LinkWindowKind.self, "kind"),
            level: try r.i16("level"), frame: try r.rect("window frame"), scale: try r.scale("window scale"),
            title: try r.string(maxBytes: Limits.maxTitleBytes, "title"), flags: LinkWindowFlags(rawValue: try r.u32("flags")),
            minSize: try r.size("minSize"), maxSize: try r.size("maxSize")
        )
    }

    private static func write(_ m: LinkWindowUpdate, _ w: inout LinkWriter) throws {
        w.u32(m.id.rawValue); w.u64(m.stateVersion)
        var mask: UInt16 = 0
        if m.frame != nil { mask |= 1 << 0 }
        if m.title != nil { mask |= 1 << 1 }
        if m.flags != nil { mask |= 1 << 2 }
        if m.level != nil { mask |= 1 << 3 }
        if m.scale != nil { mask |= 1 << 4 }
        if m.minSize != nil { mask |= 1 << 5 }
        if m.maxSize != nil { mask |= 1 << 6 }
        w.u16(mask)
        if let v = m.frame { try w.rect(v, "frame") }
        if let v = m.title { try w.string(v, maxBytes: Limits.maxTitleBytes, "title") }
        if let v = m.flags { w.u32(v.rawValue) }
        if let v = m.level { w.i16(v) }
        if let v = m.scale { try w.scale(v, "scale") }
        if let v = m.minSize { try w.size(v, "minSize") }
        if let v = m.maxSize { try w.size(v, "maxSize") }
    }

    private static func readUpdate(_ r: inout LinkReader) throws -> LinkWindowUpdate {
        let id = WindowID(try r.u32("window")), version = try r.u64("stateVersion"), mask = try r.u16("changed mask")
        guard mask & ~0x7F == 0 else { throw LinkError.malformed("unknown changed-field bits") }
        var update = LinkWindowUpdate(id: id, stateVersion: version)
        if mask & (1 << 0) != 0 { update.frame = try r.rect("frame") }
        if mask & (1 << 1) != 0 { update.title = try r.string(maxBytes: Limits.maxTitleBytes, "title") }
        if mask & (1 << 2) != 0 { update.flags = LinkWindowFlags(rawValue: try r.u32("flags")) }
        if mask & (1 << 3) != 0 { update.level = try r.i16("level") }
        if mask & (1 << 4) != 0 { update.scale = try r.scale("scale") }
        if mask & (1 << 5) != 0 { update.minSize = try r.size("minSize") }
        if mask & (1 << 6) != 0 { update.maxSize = try r.size("maxSize") }
        return update
    }

    private static func write(_ items: [LinkMenuItem], depth: Int, total: inout Int, _ w: inout LinkWriter) throws {
        guard items.isEmpty || depth <= Limits.maxMenuDepth else { throw LinkError.limitExceeded("menu deeper than \(Limits.maxMenuDepth)") }
        try w.count(items.count, max: Limits.maxMenuItemsPerLevel, "menu items")
        total += items.count
        guard total <= Limits.maxMenuItemsTotal else { throw LinkError.limitExceeded("more than \(Limits.maxMenuItemsTotal) menu items") }
        for item in items {
            try w.string(item.title, maxBytes: Limits.maxMenuTitleBytes, "menu title")
            w.bool(item.enabled); w.bool(item.checked); w.bool(item.isSeparator)
            try w.string(item.keyEquivalent, maxBytes: Limits.maxKeyEquivalentBytes, "key equivalent")
            w.u16(item.modifiers.rawValue)
            try write(item.children, depth: depth + 1, total: &total, &w)
        }
    }

    private static func readItems(_ r: inout LinkReader, depth: Int, total: inout Int) throws -> [LinkMenuItem] {
        let n = try r.count(max: Limits.maxMenuItemsPerLevel, minElementBytes: menuItemMinBytes, "menu items")
        guard n == 0 || depth <= Limits.maxMenuDepth else { throw LinkError.limitExceeded("menu deeper than \(Limits.maxMenuDepth)") }
        total += n
        guard total <= Limits.maxMenuItemsTotal else { throw LinkError.limitExceeded("more than \(Limits.maxMenuItemsTotal) menu items") }
        var items: [LinkMenuItem] = []
        items.reserveCapacity(n)
        for _ in 0..<n {
            let title = try r.string(maxBytes: Limits.maxMenuTitleBytes, "menu title")
            let enabled = try r.bool("enabled"), checked = try r.bool("checked"), separator = try r.bool("separator")
            let key = try r.string(maxBytes: Limits.maxKeyEquivalentBytes, "key equivalent")
            let modifiers = LinkModifiers(rawValue: try r.u16("modifiers"))
            items.append(LinkMenuItem(
                title: title, enabled: enabled, checked: checked, isSeparator: separator, keyEquivalent: key, modifiers: modifiers,
                children: try readItems(&r, depth: depth + 1, total: &total)
            ))
        }
        return items
    }
}
