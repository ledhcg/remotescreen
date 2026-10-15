#if os(macOS)
import Foundation
import LinkProtocol
import os

/// Owns one capture stream per subscribed window and turns raw OS output into events: it drops frames that are not
/// `.complete`, debounces window resizes into `update` calls, detects idle windows and restarts failed streams.
///
/// Every stream is created, updated and stopped here, so `activeStreamCount` reaching zero after the last unsubscribe is
/// the "no leaked streams" invariant.
public actor CaptureEngine {
    public struct Tuning: Sendable {
        /// Quiet period after the last size change before the stream is reconfigured.
        public var resizeDebounce: Duration = .milliseconds(150)
        /// Consecutive complete frames without dirty rects before a window counts as idle.
        public var idleFrameCount = 5
        /// No frame at all for this long also counts as idle (ScreenCaptureKit stops calling back when nothing changes).
        public var idleTimeout: Duration = .milliseconds(300)
        public var maxRestarts = 3
        public var restartBackoff: Duration = .milliseconds(250)
        public init() {}
    }

    public typealias Sleep = @Sendable (Duration) async throws -> Void

    private final class Subscription {
        var request: CaptureRequest
        var nativeSize: LinkSize
        var pendingNative: LinkSize?
        var config: CaptureStreamConfig
        var handle: (any CaptureStreamHandle)?
        var generation = 0
        var continuation: AsyncStream<CaptureEvent>.Continuation
        var pump: Task<Void, Never>?
        var rawContinuation: AsyncStream<CaptureStreamOutput>.Continuation?
        var debounceTask: Task<Void, Never>?
        var idleTask: Task<Void, Never>?
        var restartTask: Task<Void, Never>?
        var cleanFrames = 0
        var frameCounter = 0
        var isIdle = false
        var restartAttempts = 0

        init(request: CaptureRequest, nativeSize: LinkSize, config: CaptureStreamConfig, continuation: AsyncStream<CaptureEvent>.Continuation) {
            self.request = request; self.nativeSize = nativeSize; self.config = config; self.continuation = continuation
        }
    }

    private let system: any CaptureSystem
    private let tuning: Tuning
    private let sleep: Sleep
    private var subscriptions: [WindowID: Subscription] = [:]
    private var streamCount = 0
    private let log = Logger(subsystem: "com.screon.helper", category: "capture")

    public init(system: any CaptureSystem, tuning: Tuning = Tuning(), sleep: @escaping Sleep = { try await Task.sleep(for: $0) }) {
        self.system = system; self.tuning = tuning; self.sleep = sleep
    }

    /// Streams currently running in the OS (started and not yet stopped).
    public var activeStreamCount: Int { streamCount }
    public var subscribedWindows: Set<WindowID> { Set(subscriptions.keys) }

    // MARK: Subscribe

    /// Starts capturing `window`. A second subscription for the same window replaces the first.
    public func subscribe(window: WindowID, nativePixelSize: LinkSize, request: CaptureRequest) async throws -> AsyncStream<CaptureEvent> {
        await unsubscribe(window: window)
        let (events, continuation) = AsyncStream<CaptureEvent>.makeStream(bufferingPolicy: .bufferingNewest(32))
        let size = CaptureSizing.outputSize(native: nativePixelSize, request: request)
        let config = CaptureStreamConfig(window: window, outputWidth: size.width, outputHeight: size.height, framesPerSecond: request.framesPerSecond)
        let sub = Subscription(request: request, nativeSize: nativePixelSize, config: config, continuation: continuation)
        subscriptions[window] = sub
        do {
            try await startStream(window: window, sub: sub)
        } catch {
            if subscriptions[window] === sub { subscriptions[window] = nil }
            continuation.finish()
            throw error
        }
        return events
    }

    public func unsubscribe(window: WindowID) async {
        guard let sub = subscriptions.removeValue(forKey: window) else { return }
        await tearDown(sub)
        sub.continuation.finish()
    }

    public func unsubscribeAll() async {
        for window in Array(subscriptions.keys) { await unsubscribe(window: window) }
    }

    /// Changes the requested size or frame rate of a running subscription.
    public func update(window: WindowID, request: CaptureRequest) async {
        guard let sub = subscriptions[window] else { return }
        sub.request = request
        await applyConfig(window: window, sub: sub)
    }

    // MARK: Stream lifecycle

    private func startStream(window: WindowID, sub: Subscription) async throws {
        sub.generation += 1
        let generation = sub.generation
        let (raw, rawContinuation) = AsyncStream<CaptureStreamOutput>.makeStream(bufferingPolicy: .bufferingNewest(16))
        sub.rawContinuation = rawContinuation
        sub.pump?.cancel()
        sub.pump = Task { [weak self] in
            for await output in raw {
                guard let self else { return }
                await self.handle(output, window: window, generation: generation)
            }
        }
        let handle: any CaptureStreamHandle
        do {
            handle = try await system.startStream(config: sub.config, output: { rawContinuation.yield($0) })
        } catch {
            rawContinuation.finish()
            throw error
        }
        guard subscriptions[window] === sub, sub.generation == generation else {
            // Unsubscribed (or replaced) while the OS was starting the stream.
            await handle.stop()
            return
        }
        streamCount += 1
        sub.handle = handle
    }

    /// Stops everything a subscription owns. Idempotent.
    private func tearDown(_ sub: Subscription) async {
        sub.generation += 1
        sub.debounceTask?.cancel(); sub.idleTask?.cancel(); sub.restartTask?.cancel()
        sub.debounceTask = nil; sub.idleTask = nil; sub.restartTask = nil
        sub.rawContinuation?.finish(); sub.rawContinuation = nil
        sub.pump?.cancel(); sub.pump = nil
        if let handle = sub.handle {
            sub.handle = nil
            streamCount -= 1
            await handle.stop()
        }
    }

    private func applyConfig(window: WindowID, sub: Subscription) async {
        let size = CaptureSizing.outputSize(native: sub.nativeSize, request: sub.request)
        let new = CaptureStreamConfig(window: window, outputWidth: size.width, outputHeight: size.height, framesPerSecond: sub.request.framesPerSecond)
        guard new != sub.config else { return }
        sub.config = new
        guard let handle = sub.handle else { return }
        do {
            try await handle.update(new)
            if subscriptions[window] === sub { sub.continuation.yield(.resized(new)) }
        } catch {
            log.error("capture update failed for window \(window.rawValue)")
        }
    }

    // MARK: Output handling

    private func handle(_ output: CaptureStreamOutput, window: WindowID, generation: Int) async {
        guard let sub = subscriptions[window], sub.generation == generation else { return }
        switch output {
        case .frame(let frame): await handleFrame(frame, window: window, sub: sub)
        case .stopped(let error):
            guard let error else { return }
            await handleStop(error, window: window, sub: sub)
        }
    }

    private func handleFrame(_ frame: CapturedFrame, window: WindowID, sub: Subscription) async {
        let meta = frame.metadata
        // Anything but a complete frame carries no new image (idle, blank, suspended...).
        guard meta.status == .complete, frame.pixelBuffer != nil else { return }
        sub.restartAttempts = 0
        sub.frameCounter &+= 1
        armIdleTimer(window: window, sub: sub)

        let native = meta.nativePixelSize
        if native.width >= 1, native.height >= 1, native != sub.nativeSize, native != sub.pendingNative {
            scheduleResize(native, window: window, sub: sub)
        }

        if meta.dirtyRects.isEmpty {
            sub.cleanFrames += 1
            if sub.isIdle { return }
            if sub.cleanFrames >= tuning.idleFrameCount {
                sub.isIdle = true
                sub.continuation.yield(.frame(frame))
                sub.continuation.yield(.idle)
                return
            }
        } else {
            sub.cleanFrames = 0
            if sub.isIdle { sub.isIdle = false; sub.continuation.yield(.active) }
        }
        sub.continuation.yield(.frame(frame))
    }

    private func scheduleResize(_ native: LinkSize, window: WindowID, sub: Subscription) {
        sub.pendingNative = native
        sub.debounceTask?.cancel()
        let generation = sub.generation
        sub.debounceTask = Task { [weak self, sleep, delay = tuning.resizeDebounce] in
            do { try await sleep(delay) } catch { return }
            await self?.applyResize(native, window: window, generation: generation)
        }
    }

    private func applyResize(_ native: LinkSize, window: WindowID, generation: Int) async {
        guard let sub = subscriptions[window], sub.generation == generation else { return }
        sub.debounceTask = nil
        sub.nativeSize = native
        sub.pendingNative = nil
        await applyConfig(window: window, sub: sub)
    }

    /// One long-lived task per subscription (not one per frame): it re-arms while frames keep arriving.
    private func armIdleTimer(window: WindowID, sub: Subscription) {
        guard sub.idleTask == nil else { return }
        let generation = sub.generation
        sub.idleTask = Task { [weak self, sleep, timeout = tuning.idleTimeout] in
            while !Task.isCancelled {
                guard let seen = await self?.frameCounter(window: window, generation: generation) else { return }
                do { try await sleep(timeout) } catch { return }
                guard let self else { return }
                if await self.idleTimerFired(window: window, generation: generation, seen: seen) { return }
            }
        }
    }

    private func frameCounter(window: WindowID, generation: Int) -> Int? {
        guard let sub = subscriptions[window], sub.generation == generation else { return nil }
        return sub.frameCounter
    }

    /// Returns true when the timer is finished (idle declared or subscription gone).
    private func idleTimerFired(window: WindowID, generation: Int, seen: Int) -> Bool {
        guard let sub = subscriptions[window], sub.generation == generation else { return true }
        guard sub.frameCounter == seen else { return false }
        sub.idleTask = nil
        if !sub.isIdle { sub.isIdle = true; sub.continuation.yield(.idle) }
        return true
    }

    // MARK: Failure and restart

    private func handleStop(_ error: CaptureSystemError, window: WindowID, sub: Subscription) async {
        switch error.kind {
        case .permissionDenied: await fail(.permission(CaptureSizing.permissionState(for: error)), window: window, sub: sub)
        case .windowGone: await fail(.windowGone, window: window, sub: sub)
        case .stoppedByUser: await fail(.stoppedByUser, window: window, sub: sub)
        case .other: beginRestart(lastCode: error.code, window: window, sub: sub)
        }
    }

    private func fail(_ failure: CaptureFailure, window: WindowID, sub: Subscription) async {
        guard subscriptions[window] === sub else { return }
        subscriptions[window] = nil
        sub.continuation.yield(.failed(failure))
        await tearDown(sub)
        sub.continuation.finish()
    }

    private func beginRestart(lastCode: Int, window: WindowID, sub: Subscription) {
        guard sub.restartTask == nil else { return }
        // The OS already ended the stream; stop is still called (idempotent) so the handle releases everything it holds.
        let dead = sub.handle
        if dead != nil { sub.handle = nil; streamCount -= 1 }
        sub.generation += 1
        sub.idleTask?.cancel(); sub.idleTask = nil
        let generation = sub.generation
        sub.restartTask = Task { [weak self] in
            await dead?.stop()
            await self?.runRestart(window: window, generation: generation, lastCode: lastCode)
        }
    }

    private func runRestart(window: WindowID, generation: Int, lastCode: Int) async {
        var lastCode = lastCode
        while true {
            guard let sub = subscriptions[window], sub.generation == generation else { return }
            if sub.restartAttempts >= tuning.maxRestarts {
                sub.restartTask = nil
                await fail(.exhausted(lastCode: lastCode), window: window, sub: sub)
                return
            }
            sub.restartAttempts += 1
            let attempt = sub.restartAttempts
            sub.continuation.yield(.restarting(attempt: attempt))
            do { try await sleep(tuning.restartBackoff * (1 << (attempt - 1))) } catch { return }
            guard subscriptions[window] === sub, sub.generation == generation else { return }
            do {
                sub.restartTask = nil
                try await startStream(window: window, sub: sub)
                return
            } catch let error as CaptureSystemError {
                lastCode = error.code
                if error.kind != .other {
                    await handleStop(error, window: window, sub: sub)
                    return
                }
            } catch {
                lastCode = -1
            }
            // startStream bumped the generation; keep looping on the new one.
            let next = sub.generation, code = lastCode
            sub.restartTask = Task { [weak self] in
                await self?.runRestart(window: window, generation: next, lastCode: code)
            }
            return
        }
    }
}
#endif
