#if os(macOS)
import CoreVideo
import Foundation
@testable import HelperCore
import LinkProtocol
import Testing

final class FakeCaptureSystem: CaptureSystem, @unchecked Sendable {
    private struct State {
        var outputs: [WindowID: @Sendable (CaptureStreamOutput) -> Void] = [:]
        var started = 0
        var live = 0
        var updates: [CaptureStreamConfig] = []
        var failures: [CaptureSystemError] = []
    }
    private let state = Locked(State())

    var liveStreams: Int { state.withValue { $0.live } }
    var startCount: Int { state.withValue { $0.started } }
    var updateConfigs: [CaptureStreamConfig] { state.withValue { $0.updates } }
    func failNextStarts(_ errors: [CaptureSystemError]) { state.withValue { $0.failures = errors } }
    func failAllStarts(_ error: CaptureSystemError) { state.withValue { $0.failures = Array(repeating: error, count: 100) } }

    func startStream(config: CaptureStreamConfig, output: @escaping @Sendable (CaptureStreamOutput) -> Void) async throws -> any CaptureStreamHandle {
        let failure = state.withValue { s -> CaptureSystemError? in
            if !s.failures.isEmpty { return s.failures.removeFirst() }
            s.started += 1; s.live += 1
            s.outputs[config.window] = output
            return nil
        }
        if let failure { throw failure }
        return Handle(system: self)
    }

    func emit(_ window: WindowID, _ output: CaptureStreamOutput) {
        let o = state.withValue { $0.outputs[window] }
        o?(output)
    }

    private final class Handle: CaptureStreamHandle, @unchecked Sendable {
        let system: FakeCaptureSystem
        let stopped = Locked(false)
        init(system: FakeCaptureSystem) { self.system = system }
        func update(_ config: CaptureStreamConfig) async throws { system.state.withValue { $0.updates.append(config) } }
        func stop() async {
            let first = stopped.withValue { s -> Bool in let was = s; s = true; return !was }
            if first { system.state.withValue { $0.live -= 1 } }
        }
    }
}

private let window7: WindowID = 7
private let request = CaptureRequest(targetPixelWidth: 2000, targetPixelHeight: 2000, framesPerSecond: 60)
private let native = LinkSize(width: 1000, height: 800)
nonisolated(unsafe) private let sharedBuffer = TestPixels.colorBars(width: 16, height: 16)

private func frame(
    _ status: CaptureFrameStatus = .complete, size: LinkSize = native, dirty: Bool = true, withBuffer: Bool = true
) -> CaptureStreamOutput {
    let meta = CaptureFrameMetadata(
        status: status, contentRect: LinkRect(origin: LinkPoint(x: 0, y: 0), size: size),
        dirtyRects: dirty ? [LinkRect(x: 0, y: 0, width: 10, height: 10)] : [])
    return .frame(CapturedFrame(pixelBuffer: withBuffer ? sharedBuffer : nil, metadata: meta))
}

/// Collects events of one subscription.
private final class Collector: @unchecked Sendable {
    let events = Locked<[CaptureEvent]>([])
    var task: Task<Void, Never>?
    init(_ stream: AsyncStream<CaptureEvent>) {
        task = Task { [events] in for await e in stream { events.withValue { $0.append(e) } } }
    }
    var frames: Int { events.get().filter { if case .frame = $0 { true } else { false } }.count }
    func count(_ match: @Sendable (CaptureEvent) -> Bool) -> Int { events.get().filter(match).count }
}

@Suite struct CaptureEngineTests {
    @Test func thousandSubscriptionsLeakNothing() async throws {
        let system = FakeCaptureSystem()
        let engine = CaptureEngine(system: system)
        for i in 0..<1000 {
            let id = WindowID(UInt32(i % 5))
            _ = try await engine.subscribe(window: id, nativePixelSize: native, request: request)
            if i % 3 == 0 { await engine.unsubscribe(window: id) }
        }
        await engine.unsubscribeAll()
        #expect(await engine.activeStreamCount == 0)
        #expect(system.liveStreams == 0)
        #expect(await engine.subscribedWindows.isEmpty)
        #expect(system.startCount == 1000)
    }

    @Test func resubscribingReplacesTheStream() async throws {
        let system = FakeCaptureSystem()
        let engine = CaptureEngine(system: system)
        _ = try await engine.subscribe(window: window7, nativePixelSize: native, request: request)
        _ = try await engine.subscribe(window: window7, nativePixelSize: native, request: request)
        #expect(system.liveStreams == 1)
        #expect(await engine.activeStreamCount == 1)
        await engine.unsubscribe(window: window7)
        #expect(system.liveStreams == 0)
    }

    @Test func outputIsCappedToTargetAndNeverUpscaled() {
        let big = CaptureSizing.outputSize(native: LinkSize(width: 3000, height: 2000), request: CaptureRequest(targetPixelWidth: 1500, targetPixelHeight: 1500, framesPerSecond: 60))
        #expect(big.width == 1500 && big.height == 1000)
        let small = CaptureSizing.outputSize(native: LinkSize(width: 801, height: 601), request: request)
        #expect(small.width == 800 && small.height == 600)  // even, not upscaled
        let tiny = CaptureSizing.outputSize(native: LinkSize(width: 0, height: 0), request: request)
        #expect(tiny.width == 2 && tiny.height == 2)
    }

    @Test func nonCompleteFramesAreDropped() async throws {
        let system = FakeCaptureSystem()
        let engine = CaptureEngine(system: system, sleep: ManualSleeper().sleep)
        let events = try await engine.subscribe(window: window7, nativePixelSize: native, request: request)
        let collector = Collector(events)
        for status in [CaptureFrameStatus.idle, .blank, .suspended, .started, .stopped] { system.emit(window7, frame(status)) }
        system.emit(window7, frame(.complete, withBuffer: false))
        system.emit(window7, frame(.complete))
        #expect(await waitUntil { collector.frames == 1 })
        try await Task.sleep(for: .milliseconds(20))
        #expect(collector.frames == 1)
        await engine.unsubscribeAll()
    }

    @Test func resizeIsDebouncedIntoOneUpdate() async throws {
        let system = FakeCaptureSystem()
        let sleeper = ManualSleeper()
        let engine = CaptureEngine(system: system, sleep: sleeper.sleep)
        let events = try await engine.subscribe(window: window7, nativePixelSize: native, request: request)
        let collector = Collector(events)
        let debounce = Duration.milliseconds(150)
        for width in [1100.0, 1200, 1300] {
            system.emit(window7, frame(size: LinkSize(width: width, height: 800)))
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await waitUntil { sleeper.pendingCount(duration: debounce) >= 1 })
        #expect(system.updateConfigs.isEmpty)
        sleeper.advance(by: .milliseconds(150))
        #expect(await waitUntil { system.updateConfigs.count == 1 })
        #expect(system.updateConfigs[0].outputWidth == 1300 && system.updateConfigs[0].outputHeight == 800)
        #expect(await waitUntil { collector.count { if case .resized = $0 { true } else { false } } == 1 })
        await engine.unsubscribeAll()
    }

    @Test func windowGrowthBeyondTargetIsCappedOnUpdate() async throws {
        let system = FakeCaptureSystem()
        let sleeper = ManualSleeper()
        let engine = CaptureEngine(system: system, sleep: sleeper.sleep)
        _ = try await engine.subscribe(window: window7, nativePixelSize: native, request: CaptureRequest(targetPixelWidth: 1200, targetPixelHeight: 1200, framesPerSecond: 30))
        system.emit(window7, frame(size: LinkSize(width: 2400, height: 1600)))
        #expect(await waitUntil { sleeper.pendingCount(duration: .milliseconds(150)) >= 1 })
        sleeper.advance(by: .milliseconds(150))
        #expect(await waitUntil { system.updateConfigs.count == 1 })
        #expect(system.updateConfigs[0].outputWidth == 1200 && system.updateConfigs[0].outputHeight == 800)
        await engine.unsubscribeAll()
    }

    @Test func idleIsDetectedFromDirtyRectsAndEndsOnChange() async throws {
        let system = FakeCaptureSystem()
        let engine = CaptureEngine(system: system, sleep: ManualSleeper().sleep)
        let events = try await engine.subscribe(window: window7, nativePixelSize: native, request: request)
        let collector = Collector(events)
        for _ in 0..<4 { system.emit(window7, frame(dirty: false)) }
        #expect(await waitUntil { collector.frames == 4 })
        #expect(collector.count { if case .idle = $0 { true } else { false } } == 0)
        system.emit(window7, frame(dirty: false))
        #expect(await waitUntil { collector.count { if case .idle = $0 { true } else { false } } == 1 })
        // Further unchanged frames are not forwarded.
        system.emit(window7, frame(dirty: false))
        system.emit(window7, frame(dirty: true))
        #expect(await waitUntil { collector.count { if case .active = $0 { true } else { false } } == 1 })
        #expect(collector.frames == 6)
        await engine.unsubscribeAll()
    }

    @Test func silenceAlsoMeansIdle() async throws {
        let system = FakeCaptureSystem()
        let sleeper = ManualSleeper()
        let engine = CaptureEngine(system: system, sleep: sleeper.sleep)
        let events = try await engine.subscribe(window: window7, nativePixelSize: native, request: request)
        let collector = Collector(events)
        system.emit(window7, frame())
        #expect(await waitUntil { sleeper.pendingCount(duration: .milliseconds(300)) >= 1 })
        sleeper.advance(by: .milliseconds(300))  // first firing sees the frame arrive after arming? no: counter unchanged -> idle
        #expect(await waitUntil { collector.count { if case .idle = $0 { true } else { false } } == 1 })
        await engine.unsubscribeAll()
    }

    @Test func failedStreamRestartsWithBackoffThenGivesUp() async throws {
        let system = FakeCaptureSystem()
        let sleeper = ManualSleeper(immediate: true)
        let engine = CaptureEngine(system: system, sleep: sleeper.sleep)
        let events = try await engine.subscribe(window: window7, nativePixelSize: native, request: request)
        let collector = Collector(events)
        system.failAllStarts(CaptureSystemError(kind: .other, code: -3811))
        system.emit(window7, .stopped(CaptureSystemError(kind: .other, code: -3821)))
        #expect(await waitUntil { collector.count { if case .failed = $0 { true } else { false } } == 1 })
        let attempts = collector.events.get().compactMap { e -> Int? in if case .restarting(let n) = e { n } else { nil } }
        #expect(attempts == [1, 2, 3])
        let backoffs = sleeper.requestedDurations.filter { $0 >= .milliseconds(250) && $0 <= .seconds(1) }
        #expect(backoffs == [.milliseconds(250), .milliseconds(500), .milliseconds(1000)])
        if case .failed(let reason)? = collector.events.get().last { #expect(reason == .exhausted(lastCode: -3811)) } else { Issue.record("no failure") }
        #expect(system.liveStreams == 0)
        #expect(await engine.subscribedWindows.isEmpty)
    }

    @Test func restartSucceedsAndResetsTheAttemptCounter() async throws {
        let system = FakeCaptureSystem()
        let engine = CaptureEngine(system: system, sleep: ManualSleeper(immediate: true).sleep)
        let events = try await engine.subscribe(window: window7, nativePixelSize: native, request: request)
        let collector = Collector(events)
        for round in 1...5 {  // more rounds than maxRestarts: only possible when frames reset the counter
            system.emit(window7, .stopped(CaptureSystemError(kind: .other, code: -3821)))
            #expect(await waitUntil { system.startCount == round + 1 })
            system.emit(window7, frame())
            #expect(await waitUntil { collector.frames == round })
        }
        #expect(system.liveStreams == 1)
        await engine.unsubscribeAll()
        #expect(system.liveStreams == 0)
    }

    @Test func permissionErrorsAreReportedWithoutRestart() async throws {
        let system = FakeCaptureSystem()
        let engine = CaptureEngine(system: system, sleep: ManualSleeper(immediate: true).sleep)
        let events = try await engine.subscribe(window: window7, nativePixelSize: native, request: request)
        let collector = Collector(events)
        system.emit(window7, .stopped(CaptureSizing.classify(scStreamErrorCode: -3801)))
        #expect(await waitUntil { collector.count { if case .failed(.permission(.denied)) = $0 { true } else { false } } == 1 })
        #expect(system.startCount == 1)
        #expect(system.liveStreams == 0)
    }

    @Test func startFailureThrowsAndLeaksNothing() async {
        let system = FakeCaptureSystem()
        system.failNextStarts([CaptureSizing.classify(scStreamErrorCode: -3801)])
        let engine = CaptureEngine(system: system)
        await #expect(throws: CaptureSystemError.self) {
            _ = try await engine.subscribe(window: window7, nativePixelSize: native, request: request)
        }
        #expect(await engine.subscribedWindows.isEmpty)
        #expect(system.liveStreams == 0)
    }

    @Test func userStopAndMissingWindowAreTerminal() async throws {
        let system = FakeCaptureSystem()
        let engine = CaptureEngine(system: system, sleep: ManualSleeper(immediate: true).sleep)
        let events = try await engine.subscribe(window: window7, nativePixelSize: native, request: request)
        let collector = Collector(events)
        system.emit(window7, .stopped(CaptureSizing.classify(scStreamErrorCode: -3817)))
        #expect(await waitUntil { collector.count { if case .failed(.stoppedByUser) = $0 { true } else { false } } == 1 })
    }

    @Test func scStreamErrorCodesClassify() {
        #expect(CaptureSizing.classify(scStreamErrorCode: -3801).kind == .permissionDenied)
        #expect(CaptureSizing.classify(scStreamErrorCode: -3803).kind == .permissionDenied)
        #expect(CaptureSizing.classify(scStreamErrorCode: -3817).kind == .stoppedByUser)
        #expect(CaptureSizing.classify(scStreamErrorCode: -3815).kind == .windowGone)
        #expect(CaptureSizing.classify(scStreamErrorCode: -3821).kind == .other)
        #expect(CaptureSizing.permissionState(for: CaptureSizing.classify(scStreamErrorCode: -3801)) == .denied)
        #expect(CaptureSizing.permissionState(for: CaptureSizing.classify(scStreamErrorCode: -3811)) == .unknown)
    }
}
#endif
