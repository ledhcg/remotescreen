#if os(macOS)
import Foundation
import LinkProtocol
@testable import HelperCore

/// A scripted `WindowSystem`: tests set the CGWindowList and accessibility state, then send the notifications (or not).
final class FakeWindowSystem: WindowSystem, @unchecked Sendable {
    private let lock = NSLock()
    private var _pids: [Int32] = []
    private var _frontmost: Int32?
    private var _cg: [CGWindowRecord] = []
    private var _ax: [Int32: [AXWindowState]] = [:]
    private var _axErrors: [Int32: WindowSystemError] = [:]
    private var _enhanced: [Int32: Bool] = [:]
    private var _calls: [String] = []
    private var _observing: Set<Int32> = []
    private var continuation: AsyncStream<WindowSystemEvent>.Continuation?

    /// Errors injected into writes.
    var failSetSize: WindowSystemError?
    var failEnhancedUIWrite: WindowSystemError?
    /// A window cannot be made larger than this (simulates an app clamping the size).
    var maxSize: LinkSize?
    var scale = 2.0

    var pids: [Int32] { get { lock.withLock { _pids } } set { lock.withLock { _pids = newValue } } }
    var frontmost: Int32? { get { lock.withLock { _frontmost } } set { lock.withLock { _frontmost = newValue } } }
    var cg: [CGWindowRecord] { get { lock.withLock { _cg } } set { lock.withLock { _cg = newValue } } }
    var calls: [String] { lock.withLock { _calls } }
    var observing: Set<Int32> { lock.withLock { _observing } }

    func setAX(_ pid: Int32, _ states: [AXWindowState]) { lock.withLock { _ax[pid] = states; _axErrors[pid] = nil } }
    func setAXError(_ pid: Int32, _ error: WindowSystemError?) { lock.withLock { _axErrors[pid] = error } }
    func removeApp(_ pid: Int32) {
        lock.withLock {
            _pids.removeAll { $0 == pid }
            _ax[pid] = nil
            _cg.removeAll { $0.pid == pid }
        }
    }
    func setEnhanced(_ pid: Int32, _ value: Bool?) { lock.withLock { _enhanced[pid] = value } }
    func enhancedValue(_ pid: Int32) -> Bool? { lock.withLock { _enhanced[pid] } }
    func ax(_ pid: Int32) -> [AXWindowState] { lock.withLock { _ax[pid] ?? [] } }

    func send(_ event: WindowSystemEvent) { _ = lock.withLock { continuation }?.yield(event) }

    private func record(_ call: String) { lock.withLock { _calls.append(call) } }

    func trackablePIDs() -> [Int32] { pids }
    func bundleID(forPID pid: Int32) -> String? { "com.example.app\(pid)" }
    func frontmostPID() -> Int32? { frontmost }
    func cgWindows() -> [CGWindowRecord] { cg }
    func backingScale(for frame: LinkRect) -> Double { scale }

    func axWindows(pid: Int32) async throws -> [AXWindowState] {
        try lock.withLock {
            if let error = _axErrors[pid] { throw error }
            return _ax[pid] ?? []
        }
    }

    func axWindow(_ token: AXWindowToken) async throws -> AXWindowState {
        try lock.withLock {
            if let error = _axErrors[token.pid] { throw error }
            guard let state = _ax[token.pid]?.first(where: { $0.token == token }) else { throw WindowSystemError.windowGone }
            return state
        }
    }

    private func mutate(_ token: AXWindowToken, _ change: (inout AXWindowState) -> Void) throws {
        try lock.withLock {
            guard var list = _ax[token.pid], let index = list.firstIndex(where: { $0.token == token }) else { throw WindowSystemError.windowGone }
            change(&list[index])
            _ax[token.pid] = list
        }
    }

    func setPosition(_ token: AXWindowToken, to point: LinkPoint) async throws {
        record("position")
        try mutate(token) { $0.frame.origin = point }
    }

    func setSize(_ token: AXWindowToken, to size: LinkSize) async throws {
        record("size")
        if let failSetSize { throw failSetSize }
        let limit = maxSize
        try mutate(token) {
            var clamped = size
            if let limit { clamped = LinkSize(width: min(size.width, limit.width), height: min(size.height, limit.height)) }
            $0.frame.size = clamped
        }
    }

    func raise(_ token: AXWindowToken) async throws { record("raise") }
    func setMinimised(_ token: AXWindowToken, _ minimised: Bool) async throws {
        record("minimise \(minimised)")
        try mutate(token) { $0.isMinimised = minimised }
    }
    func setFullScreen(_ token: AXWindowToken, _ fullScreen: Bool) async throws {
        record("fullscreen \(fullScreen)")
        try mutate(token) { $0.isFullScreen = fullScreen }
    }
    func pressClose(_ token: AXWindowToken) async throws {
        record("close")
        lock.withLock { _ax[token.pid]?.removeAll { $0.token == token } }
    }
    func pressZoom(_ token: AXWindowToken) async throws { record("zoom") }

    func enhancedUI(pid: Int32) async throws -> Bool? {
        record("get enhanced")
        return lock.withLock { _enhanced[pid] }
    }

    func setEnhancedUI(pid: Int32, _ enabled: Bool) async throws {
        record("set enhanced \(enabled)")
        if let failEnhancedUIWrite { throw failEnhancedUIWrite }
        lock.withLock { _enhanced[pid] = enabled }
    }

    func manualAccessibility(pid: Int32) async throws -> Bool? { nil }
    func setManualAccessibility(pid: Int32, _ enabled: Bool) async throws {}

    func startObserving(pid: Int32) async throws { _ = lock.withLock { _observing.insert(pid) } }
    func stopObserving(pid: Int32) async { _ = lock.withLock { _observing.remove(pid) } }

    func events() -> AsyncStream<WindowSystemEvent> {
        let (stream, continuation) = AsyncStream<WindowSystemEvent>.makeStream()
        lock.withLock { self.continuation = continuation }
        return stream
    }
}

/// Collects tracker events synchronously and can replay them into a model of what a client would hold.
final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [WindowTrackerEvent] = []
    var events: [WindowTrackerEvent] { lock.withLock { _events } }
    func append(_ event: WindowTrackerEvent) { lock.withLock { _events.append(event) } }
    func clear() { lock.withLock { _events.removeAll() } }
    /// Events and then clears them.
    func take() -> [WindowTrackerEvent] { lock.withLock { let taken = _events; _events.removeAll(); return taken } }
}

/// What an iPad would keep: applies `created`/`updated`/`destroyed`/`order` in sequence.
struct ClientModel: Equatable {
    var windows: [WindowID: LinkWindowInfo] = [:]
    var order: [WindowID] = []
    var active: WindowID?
    var version: UInt64 = 0

    mutating func apply(_ event: WindowTrackerEvent) {
        if let v = event.stateVersion {
            precondition(v > version, "state version must increase: \(v) after \(version)")
            version = v
        }
        switch event {
        case .created(let info, _): windows[info.id] = info
        case .destroyed(let id, _): windows.removeValue(forKey: id)
        case .order(let ids, let active, _): order = ids; self.active = active
        case .unresponsive: break
        case .updated(let update):
            guard var info = windows[update.id] else { return }
            if let frame = update.frame { info.frame = frame }
            if let title = update.title { info.title = title }
            if let flags = update.flags { info.flags = flags }
            if let level = update.level { info.level = level }
            if let scale = update.scale { info.scale = scale }
            windows[update.id] = info
        }
    }

    var ordered: [LinkWindowInfo] { order.compactMap { windows[$0] } }
}

func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> LinkRect { LinkRect(x: x, y: y, width: w, height: h) }

func axWindow(_ pid: Int32, _ id: UInt64, cg: UInt32?, frame: LinkRect = rect(100, 100, 800, 600), title: String = "Window",
               subrole: String = "AXStandardWindow", minimised: Bool = false, focused: Bool = false, main: Bool = false) -> AXWindowState {
    AXWindowState(token: AXWindowToken(pid: pid, id: id), cgWindowID: cg, title: title, frame: frame, subrole: subrole,
                  isMinimised: minimised, isMain: main, isFocused: focused)
}

func cgRecord(_ id: UInt32, _ pid: Int32, bounds: LinkRect = rect(100, 100, 800, 600), layer: Int = 0, onScreen: Bool = true, alpha: Double = 1) -> CGWindowRecord {
    CGWindowRecord(id: id, pid: pid, bounds: bounds, layer: layer, alpha: alpha, isOnScreen: onScreen)
}
#endif
