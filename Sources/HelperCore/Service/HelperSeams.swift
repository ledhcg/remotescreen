#if os(macOS)
import ApplicationServices
import CoreGraphics
import Foundation
import IOKit.pwr_mgt
import LinkProtocol
import os

// OS facts the service layer needs, each behind a protocol so `HelperService` is testable with fakes.

/// Whether the Mac's screen is locked (lock screen, screen saver with password, login window).
public protocol ScreenLockMonitor: Sendable {
    var isLocked: Bool { get }
    /// Emits the new state whenever it changes. One stream per call.
    func changes() -> AsyncStream<Bool>
}

/// The permissions the helper can check without prompting.
public protocol PermissionProbe: Sendable {
    /// Only `.accessibility` and `.screenRecording` are probed; other kinds report `.granted` (they are not required).
    func state(of kind: LinkPermissionKind) -> LinkPermissionState
}

/// Keeps the display awake while at least one iPad is connected (design §4.10).
public protocol DisplayAwakeAssertion: Sendable {
    func acquire()
    func release()
}

public struct NoopDisplayAwakeAssertion: DisplayAwakeAssertion {
    public init() {}
    public func acquire() {}
    public func release() {}
}

public struct AlwaysGrantedPermissions: PermissionProbe {
    public init() {}
    public func state(of kind: LinkPermissionKind) -> LinkPermissionState { .granted }
}

public struct NeverLockedMonitor: ScreenLockMonitor {
    public init() {}
    public var isLocked: Bool { false }
    public func changes() -> AsyncStream<Bool> { AsyncStream { $0.finish() } }
}

// MARK: Real implementations

public struct SystemPermissionProbe: PermissionProbe {
    public init() {}
    public func state(of kind: LinkPermissionKind) -> LinkPermissionState {
        switch kind {
        case .accessibility: AXIsProcessTrusted() ? .granted : .denied
        case .screenRecording: CGPreflightScreenCaptureAccess() ? .granted : .denied
        case .localNetwork, .inputMonitoring, .automation: .granted
        }
    }
}

/// Lock state from the window server's session dictionary and the distributed lock notifications.
public struct CGSessionLockMonitor: ScreenLockMonitor {
    public init() {}

    public var isLocked: Bool {
        guard let dictionary = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (dictionary["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    public func changes() -> AsyncStream<Bool> {
        let (stream, continuation) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(8))
        let center = DistributedNotificationCenter.default()
        let tokens: [NSObjectProtocol] = [
            ("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false),
            ("com.apple.screensaver.didstart", true), ("com.apple.screensaver.didstop", false),
        ].map { name, locked in
            center.addObserver(forName: Notification.Name(name), object: nil, queue: nil) { _ in continuation.yield(locked) }
        }
        let box = TokenBox(tokens)
        continuation.onTermination = { _ in box.remove(from: center) }
        return stream
    }

    private final class TokenBox: @unchecked Sendable {
        let tokens: [NSObjectProtocol]
        init(_ tokens: [NSObjectProtocol]) { self.tokens = tokens }
        func remove(from center: DistributedNotificationCenter) { for token in tokens { center.removeObserver(token) } }
    }
}

/// `IOPMAssertion` that prevents display sleep.
public final class IOPMDisplayAwakeAssertion: DisplayAwakeAssertion, @unchecked Sendable {
    private let lock = NSLock()
    private var assertion: IOPMAssertionID = 0
    private var held = false

    public init() {}

    public func acquire() {
        lock.withLock {
            guard !held else { return }
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Screon Helper is streaming windows" as CFString, &id)
            if result == kIOReturnSuccess { assertion = id; held = true }
        }
    }

    public func release() {
        lock.withLock {
            guard held else { return }
            IOPMAssertionRelease(assertion)
            held = false
        }
    }

    deinit { if held { IOPMAssertionRelease(assertion) } }
}
#endif
