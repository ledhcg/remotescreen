#if os(macOS)
import CoreVideo
import CryptoKit
import Foundation
import LinkProtocol
import LinkTransport
@testable import HelperCore

// MARK: Connection and listener

final class FakeConnection: HelperConnection, @unchecked Sendable {
    private struct State {
        var sent: [LinkMessage] = []
        var finished: [WindowID] = []
        var closeCodes: [LinkCloseCode] = []
        var handler: (any HelperConnectionHandler)?
        var ended = false
        var waiter: CheckedContinuation<Void, Never>?
    }

    let info: HelperConnectionInfo
    private let state = Locked(State())

    init(
        id: UInt64, name: String = "Test iPad", capabilities: LinkCapabilities = FakeConnection.allCapabilities,
        sceneLimits: LinkSceneLimits = LinkSceneLimits(maxWindows: 0, maxStreams: 0, maxPixelWidth: 0, maxPixelHeight: 0, maxFramesPerSecond: 0)
    ) {
        info = HelperConnectionInfo(
            sessionID: id, deviceName: name, deviceID: Data([UInt8(truncatingIfNeeded: id)]), capabilities: capabilities, sceneLimits: sceneLimits)
    }

    static let allCapabilities: LinkCapabilities = [.stage, .gestures, .tablet, .clipboardRich, .files, .menus, .ltr, .hevc, .h264, .audio]

    // HelperConnection

    func send(_ message: LinkMessage) async throws {
        let ok = state.withValue { s -> Bool in
            if s.ended { return false }
            s.sent.append(message)
            return true
        }
        if !ok { throw LinkSessionError.closed }
    }

    func finishWindowStream(_ window: WindowID) async { state.withValue { $0.finished.append(window) } }

    func close(code: LinkCloseCode, reason: String) async {
        state.withValue { $0.closeCodes.append(code) }
        end()
    }

    func run(handler: any HelperConnectionHandler) async {
        state.withValue { $0.handler = handler }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withValue { s -> Bool in
                if s.ended { return true }
                s.waiter = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    // Test side

    var sent: [LinkMessage] { state.get().sent }
    var finished: [WindowID] { state.get().finished }
    var closeCodes: [LinkCloseCode] { state.get().closeCodes }
    var isEnded: Bool { state.get().ended }

    func clearSent() { state.withValue { $0.sent.removeAll() } }

    func end() {
        let (waiter, handler) = state.withValue { s -> (CheckedContinuation<Void, Never>?, (any HelperConnectionHandler)?) in
            guard !s.ended else { return (nil, nil) }
            s.ended = true
            let w = s.waiter
            s.waiter = nil
            return (w, s.handler)
        }
        Task {
            await handler?.handleEvent(.closed(reason: nil))
            waiter?.resume()
        }
    }

    private var handler: (any HelperConnectionHandler)? { state.get().handler }

    /// The service starts feeding the handler a moment after the first messages go out; messages wait for it like a real stream.
    private func readyHandler() async -> (any HelperConnectionHandler)? {
        _ = await waitUntil { self.handler != nil }
        return handler
    }

    func control(_ message: LinkMessage) async { await readyHandler()?.handleControl(message) }
    func input(_ message: LinkMessage) async { await readyHandler()?.handleInput(message) }
    func event(_ event: HelperConnectionEvent) async { await readyHandler()?.handleEvent(event) }

    func count(where match: (LinkMessage) -> Bool) -> Int { sent.filter(match).count }

    var videoFrames: [LinkVideoFrame] { sent.compactMap { if case .videoFrame(let f) = $0 { f } else { nil } } }
    var videoConfigs: [LinkVideoConfig] { sent.compactMap { if case .videoConfig(let c) = $0 { c } else { nil } } }
    var statuses: [LinkStatus] { sent.compactMap { if case .status(let s) = $0 { s } else { nil } } }
    var snapshot: LinkSnapshot? { sent.compactMap { if case .snapshot(let s) = $0 { s } else { nil } }.first }
}

final class FakeListener: HelperListener, @unchecked Sendable {
    let connections: AsyncStream<any HelperConnection>
    private let continuation: AsyncStream<any HelperConnection>.Continuation
    private let state = Locked((started: 0, stopped: 0, disconnects: [LinkCloseCode]()))
    var failStart = false

    init() {
        (connections, continuation) = AsyncStream<any HelperConnection>.makeStream()
    }

    var startCount: Int { state.get().started }
    var stopCount: Int { state.get().stopped }

    func start() async throws -> UInt16 {
        if failStart { throw HelperServiceError.listenerFailed("port in use") }
        state.withValue { $0.started += 1 }
        return 4242
    }

    func stop() async {
        state.withValue { $0.stopped += 1 }
        continuation.finish()
    }

    func disconnectAll(code: LinkCloseCode) async { state.withValue { $0.disconnects.append(code) } }

    func connect(_ connection: FakeConnection) { continuation.yield(connection) }
}

// MARK: Encoder

final class FakeEncoder: VideoEncoding, @unchecked Sendable {
    struct Encode: Equatable { var pts: UInt64; var options: EncodeOptions }

    let info = EncoderInfo(codec: .hevc, rateControl: .lowLatency, hardwareAccelerated: false, usedVideoConferencingPreset: false, longTermReferences: true)
    let events: AsyncStream<EncoderEvent>
    private let continuation: AsyncStream<EncoderEvent>.Continuation
    let settings: EncoderSettings
    private struct State {
        var encodes: [Encode] = []
        var targets: [(bitrate: Int, fps: Int)] = []
        var acks: [[UInt32]] = []
        var invalidated = false
        var sequence: UInt32 = 0
        var sentSets = false
    }
    private let state = Locked(State())

    init(settings: EncoderSettings) {
        self.settings = settings
        (events, continuation) = AsyncStream<EncoderEvent>.makeStream()
    }

    var stats: EncoderStats { EncoderStats() }
    var encodes: [Encode] { state.get().encodes }
    var targets: [(bitrate: Int, fps: Int)] { state.get().targets }
    var acks: [[UInt32]] { state.get().acks }
    var isInvalidated: Bool { state.get().invalidated }

    func encode(_ pixelBuffer: CVPixelBuffer, ptsMicros: UInt64, options: EncodeOptions) throws {
        let (needsSets, sequence, first) = state.withValue { s -> (Bool, UInt32, Bool) in
            s.encodes.append(Encode(pts: ptsMicros, options: options))
            let sets = !s.sentSets
            s.sentSets = true
            let seq = s.sequence
            s.sequence += 1
            return (sets, seq, seq == 0)
        }
        if needsSets {
            continuation.yield(.parameterSets(EncodedParameterSets(
                codec: .hevc, sets: [Data([1]), Data([2])], width: settings.width, height: settings.height)))
        }
        var flags: LinkVideoFrameFlags = []
        if first || options.forceKeyFrame { flags.insert(.key) }
        if options.forceLTRRefresh { flags.insert(.refresh) }
        continuation.yield(.frame(LinkVideoFrame(window: settings.window, sequence: sequence, ptsMicros: ptsMicros, flags: flags, data: Data([9]))))
    }

    func setTargets(bitrate: Int, framesPerSecond: Int) { state.withValue { $0.targets.append((bitrate, framesPerSecond)) } }
    func acknowledgeLongTermReferences(sequences: [UInt32]) { state.withValue { $0.acks.append(sequences) } }

    func invalidate() {
        state.withValue { $0.invalidated = true }
        continuation.finish()
    }
}

final class FakeEncoders: @unchecked Sendable {
    private let created = Locked<[FakeEncoder]>([])
    var all: [FakeEncoder] { created.get() }
    var live: [FakeEncoder] { all.filter { !$0.isInvalidated } }
    func make(_ settings: EncoderSettings) throws -> any VideoEncoding {
        let encoder = FakeEncoder(settings: settings)
        created.withValue { $0.append(encoder) }
        return encoder
    }
}

// MARK: Small seams

final class FakeLockMonitor: ScreenLockMonitor, @unchecked Sendable {
    private let locked = Locked(false)
    private let continuation = Locked<AsyncStream<Bool>.Continuation?>(nil)
    var isLocked: Bool { locked.get() }
    func changes() -> AsyncStream<Bool> {
        let (stream, c) = AsyncStream<Bool>.makeStream()
        continuation.withValue { $0 = c }
        return stream
    }
    func set(_ value: Bool) {
        locked.withValue { $0 = value }
        continuation.get()?.yield(value)
    }
}

final class FakePermissions: PermissionProbe, @unchecked Sendable {
    private let states = Locked<[LinkPermissionKind: LinkPermissionState]>([:])
    func state(of kind: LinkPermissionKind) -> LinkPermissionState { states.get()[kind] ?? .granted }
    func set(_ kind: LinkPermissionKind, _ state: LinkPermissionState) { states.withValue { $0[kind] = state } }
}

final class FakeAwake: DisplayAwakeAssertion, @unchecked Sendable {
    private let counts = Locked((acquired: 0, released: 0))
    func acquire() { counts.withValue { $0.acquired += 1 } }
    func release() { counts.withValue { $0.released += 1 } }
    var held: Bool { let c = counts.get(); return c.acquired > c.released }
}

final class ManualSeconds: @unchecked Sendable {
    private let value = Locked(1000.0)
    func now() -> Double { value.get() }
    func advance(_ seconds: Double) { value.withValue { $0 += seconds } }
}

// MARK: Harness

/// The whole service on fakes: one app with windows, a fake capture system, encoders, stage, input, menus, clipboard and inbox.
final class ServiceHarness: @unchecked Sendable {
    static let originalFrame = rect(100, 100, 800, 600)

    let listener = FakeListener()
    let windows = FakeWindowSystem()
    let workspace = FakeWorkspace()
    let capture = FakeCaptureSystem()
    let encoders = FakeEncoders()
    let poster = RecordingPoster()
    let secureInput = FakeSecureInput()
    let menuSystem: FakeMenuSystem
    let pasteboard = FakePasteboard()
    let opener = FakeOpener()
    let stageDisplay = FakeDisplayStage()
    let journal = MemoryJournal()
    let lockMonitor = FakeLockMonitor()
    let permissions = FakePermissions()
    let awake = FakeAwake()
    let clock = ManualSeconds()
    let inboxRoot: URL
    let audioCapture = FakeAudioCapture()
    let service: HelperService

    /// Two apps: pid 10 (two windows, cg 501 and 502) and pid 11 (one window, cg 601).
    init(
        stage: Bool = true, audio: Bool = false, maxSubscriptions: Int = 16, maxSessions: Int = 4,
        configure: (inout HelperServiceOptions) -> Void = { _ in }
    ) throws {
        inboxRoot = try tempDirectory().appendingPathComponent("inbox", isDirectory: true)
        menuSystem = FakeMenuSystem([
            FakeMenu(title: "File", children: [FakeMenu(title: "New"), FakeMenu(title: "Open")]),
        ])
        windows.pids = [10, 11]
        windows.frontmost = 10
        windows.cg = [
            cgRecord(501, 10, bounds: Self.originalFrame), cgRecord(502, 10, bounds: rect(200, 150, 500, 400)),
            cgRecord(601, 11, bounds: rect(300, 200, 400, 300)),
        ]
        windows.setAX(10, [
            axWindow(10, 1, cg: 501, frame: Self.originalFrame, title: "One", focused: true),
            axWindow(10, 2, cg: 502, frame: rect(200, 150, 500, 400), title: "Two"),
        ])
        windows.setAX(11, [axWindow(11, 1, cg: 601, frame: rect(300, 200, 400, 300), title: "Other")])
        workspace.setApps([
            RunningAppInfo(pid: 10, bundleID: "com.example.app10", name: "App Ten", isActive: true),
            RunningAppInfo(pid: 11, bundleID: "com.example.app11", name: "App Eleven"),
        ])

        var options = HelperServiceOptions()
        options.maxSessions = maxSessions
        options.maxSubscriptionsPerSession = maxSubscriptions
        options.stageDisplay = stage ? VirtualDisplaySpec(width: 1920, height: 1200) : nil
        options.audioEnabled = audio
        options.permissionPollInterval = .milliseconds(20)
        options.secureInputPollInterval = .milliseconds(20)
        options.clipboardPollInterval = .milliseconds(20)
        let clock = self.clock
        options.clock = { clock.now() }
        configure(&options)

        let encoders = self.encoders
        let audioCapture = self.audioCapture
        let dependencies = HelperDependencies(
            listener: listener, windowSystem: windows, workspace: workspace, installedApps: FakeInstalledSource(apps: []),
            captureSystem: capture, makeEncoder: { try encoders.make($0) }, eventPoster: poster, secureInput: secureInput,
            menuSystem: menuSystem, pasteboard: pasteboard, transcoder: FakeTranscoder(), fileOpener: opener, inboxRoot: inboxRoot,
            displayStage: stageDisplay, stageJournal: journal,
            audio: audio ? HelperAudio(capture: audioCapture, channels: 2, encode: { $0 }) : nil,
            lockMonitor: lockMonitor, permissions: permissions, awake: awake)
        service = HelperService(dependencies: dependencies, options: options)
    }

    /// Starts the service. Returns when the tracker has seen the windows.
    func start() async throws {
        try await service.start()
    }

    func connect(
        _ id: UInt64, name: String = "Test iPad", capabilities: LinkCapabilities = FakeConnection.allCapabilities,
        sceneLimits: LinkSceneLimits = LinkSceneLimits(maxWindows: 0, maxStreams: 0, maxPixelWidth: 0, maxPixelHeight: 0, maxFramesPerSecond: 0)
    ) async -> FakeConnection {
        let connection = FakeConnection(id: id, name: name, capabilities: capabilities, sceneLimits: sceneLimits)
        listener.connect(connection)
        _ = await waitUntil { connection.snapshot != nil || connection.isEnded }
        // The status messages follow the snapshot.
        _ = await waitUntil { !connection.statuses.isEmpty || connection.isEnded }
        return connection
    }

    /// Window ids by title, from the connection's snapshot.
    func windowID(_ title: String, in connection: FakeConnection) -> WindowID {
        connection.snapshot?.windows.first { $0.title == title }?.id ?? WindowID(0)
    }

    func subscribe(_ connection: FakeConnection, _ window: WindowID, fps: UInt16 = 60) async {
        await connection.control(.windowSubscribe(LinkSubscribe(window: window, pixelWidth: 2000, pixelHeight: 1500, maxFramesPerSecond: fps, quality: .high)))
    }

    func emitFrame(_ window: WindowID, dirty: Bool = true, width: Int = 16, height: Int = 16) {
        let meta = CaptureFrameMetadata(
            status: .complete, contentRect: LinkRect(x: 0, y: 0, width: Double(width), height: Double(height)),
            dirtyRects: dirty ? [LinkRect(x: 0, y: 0, width: 4, height: 4)] : [], ptsMicros: UInt64(clock.now() * 1000))
        capture.emit(window, .frame(CapturedFrame(pixelBuffer: TestPixels.colorBars(width: width, height: height), metadata: meta)))
    }

    func axFrame(pid: Int32, id: UInt64) -> LinkRect? { windows.ax(pid).first { $0.token.id == id }?.frame }
}

func sha256(_ data: Data) -> LinkBytes32 { try! LinkBytes32(Data(SHA256.hash(data: data))) }
#endif

#if os(macOS)
/// `waitUntil` for conditions that need `await` (reading actor state).
func waitUntil(timeout: Duration = .seconds(3), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return await condition()
}
#endif
