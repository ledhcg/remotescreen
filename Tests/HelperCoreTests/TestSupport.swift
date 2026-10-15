#if os(macOS)
import CoreVideo
import Foundation
@testable import HelperCore
import LinkProtocol

/// Polls `condition` until it holds or `timeout` passes. Used to synchronise with actors without fixed sleeps.
func waitUntil(timeout: Duration = .seconds(3), _ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return condition()
}

/// A tiny lock-protected value for sharing state between a test and background tasks.
final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
    func withValue<R>(_ body: (inout Value) -> R) -> R { lock.lock(); defer { lock.unlock() }; return body(&value) }
}

/// Deterministic replacement for `Task.sleep`: sleepers wake only when the test advances time (or immediately in
/// `immediate` mode, which just records the requested durations).
final class ManualSleeper: @unchecked Sendable {
    private struct Waiter { let deadline: Duration; let duration: Duration; let continuation: CheckedContinuation<Void, Error> }
    private struct State { var now: Duration = .zero; var waiters: [Int: Waiter] = [:]; var nextID = 0; var requested: [Duration] = [] }
    private let state = Locked(State())
    private let immediate: Bool

    init(immediate: Bool = false) { self.immediate = immediate }

    var requestedDurations: [Duration] { state.withValue { $0.requested } }
    func pendingCount(duration: Duration) -> Int { state.withValue { $0.waiters.values.filter { $0.duration == duration }.count } }

    func sleep(_ duration: Duration) async throws {
        let id = state.withValue { s -> Int in s.requested.append(duration); s.nextID += 1; return s.nextID }
        if immediate { try Task.checkCancellation(); await Task.yield(); return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                let cancelled = state.withValue { s -> Bool in
                    if Task.isCancelled { return true }
                    s.waiters[id] = Waiter(deadline: s.now + duration, duration: duration, continuation: c)
                    return false
                }
                if cancelled { c.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let w = state.withValue { $0.waiters.removeValue(forKey: id) }
            w?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by delta: Duration) {
        let due = state.withValue { s -> [Waiter] in
            s.now += delta
            let keys = s.waiters.filter { $0.value.deadline <= s.now }.map(\.key)
            return keys.compactMap { s.waiters.removeValue(forKey: $0) }
        }
        for w in due { w.continuation.resume() }
    }
}

enum TestPixels {
    /// A 420v (bi-planar video range) buffer filled with SMPTE-like colour bars. Dimensions must be even.
    static func colorBars(width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attrs as CFDictionary, &buffer
        ) == kCVReturnSuccess, let pb = buffer else { return nil }
        // (Y, Cb, Cr) for white, yellow, cyan, green, magenta, red, blue, black in BT.709 video range.
        let bars: [(UInt8, UInt8, UInt8)] = [
            (235, 128, 128), (219, 16, 138), (188, 154, 16), (173, 42, 26), (78, 214, 230), (63, 102, 240), (32, 240, 118), (16, 128, 128),
        ]
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        if let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
            for row in 0..<height {
                let line = y.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self)
                for x in 0..<width { line[x] = bars[x * bars.count / width].0 }
            }
        }
        if let uv = CVPixelBufferGetBaseAddressOfPlane(pb, 1) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
            for row in 0..<(height / 2) {
                let line = uv.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self)
                for x in 0..<(width / 2) {
                    let bar = bars[x * bars.count / (width / 2)]
                    line[2 * x] = bar.1; line[2 * x + 1] = bar.2
                }
            }
        }
        return pb
    }
}
#endif
