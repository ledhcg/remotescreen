#if os(macOS)
import Foundation
import LinkProtocol
@testable import HelperCore

/// Records events; never posts anything to the system.
final class RecordingPoster: EventPoster, @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [SyntheticEvent] = []
    var canPostEvents = true
    var supportsGestures = true

    var events: [SyntheticEvent] { lock.withLock { _events } }
    func post(_ event: SyntheticEvent) throws { lock.withLock { _events.append(event) } }
    func clear() { lock.withLock { _events.removeAll() } }
}

/// Window frames the test can change at any time.
final class FakeGeometry: WindowGeometryProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [WindowID: LinkRect] = [:]
    private var hooks: [@Sendable () -> Void] = []

    func set(_ window: WindowID, _ frame: LinkRect?) { lock.withLock { frames[window] = frame } }
    /// Runs once, the next time geometry is asked: simulates the window moving while the event is in flight.
    func onNextLookup(_ hook: @escaping @Sendable () -> Void) { lock.withLock { hooks.append(hook) } }

    func contentFrame(of window: WindowID) async -> LinkRect? {
        let hook: (@Sendable () -> Void)? = lock.withLock { hooks.isEmpty ? nil : hooks.removeFirst() }
        hook?()
        return lock.withLock { frames[window] }
    }
}

final class FakeFocuser: WindowFocuser, @unchecked Sendable {
    private let lock = NSLock()
    private var _raised: [WindowID] = []
    private var _frontmost: Set<WindowID> = []
    var raised: [WindowID] { lock.withLock { _raised } }
    func setFrontmost(_ windows: Set<WindowID>) { lock.withLock { _frontmost = windows } }

    func isFrontmost(_ window: WindowID, at point: LinkPoint) async -> Bool { lock.withLock { _frontmost.contains(window) } }
    func raiseAndActivate(_ window: WindowID) async { lock.withLock { _raised.append(window) } }
}

final class FakeSecureInput: SecureInputProbe, @unchecked Sendable {
    private let lock = NSLock()
    private var _enabled = false
    var enabled: Bool { get { lock.withLock { _enabled } } set { lock.withLock { _enabled = newValue } } }
    func isSecureInputEnabled() -> Bool { enabled }
}

final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [InputInjectorEvent] = []
    var events: [InputInjectorEvent] { lock.withLock { _events } }
    func add(_ event: InputInjectorEvent) { lock.withLock { _events.append(event) } }
}

/// A clock the test advances by hand.
final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = ContinuousClock.now
    func now() -> ContinuousClock.Instant { lock.withLock { current } }
    func advance(_ duration: Duration) { lock.withLock { current = current.advanced(by: duration) } }
}
#endif
