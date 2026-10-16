#if os(macOS)
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import LinkProtocol
import os

// The real `WindowSystem`: CGWindowList for geometry, the Accessibility API for everything else.
//
// Threading: accessibility calls block until the target app answers (bounded by the 0.5 s messaging timeout), so they
// run on a concurrent utility queue, never on the tracker's actor. Observer run-loop sources live on one dedicated
// thread; their callbacks only yield `WindowSystemEvent`s into a stream, so no accessibility object crosses threads
// except inside `ElementTable`, which guards them with a lock.
//
// This type needs the Accessibility permission to do anything useful and is exercised for real only by the opt-in
// smoke test (`SCREON_AX_TESTS=1`) and the Mac validation checklist.

/// `_AXUIElementGetWindow`, a private function resolved at runtime. `nil` when this macOS does not have it; callers then
/// match windows by pid and frame.
enum PrivateAX {
    private typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private static let getWindow: GetWindow? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil }  // RTLD_DEFAULT
        return unsafeBitCast(symbol, to: GetWindow.self)
    }()

    static var isAvailable: Bool { getWindow != nil }

    static func windowNumber(of element: AXUIElement) -> UInt32? {
        guard let getWindow else { return nil }
        var id: CGWindowID = 0
        guard getWindow(element, &id) == .success, id != 0 else { return nil }
        return id
    }
}

/// Maps `AXUIElement`s to stable tokens. Equal elements get the same token for as long as the element is alive.
private final class ElementTable: @unchecked Sendable {
    private let lock = NSLock()
    private var elements: [Int32: [UInt64: AXUIElement]] = [:]
    private var nextID: UInt64 = 1

    func token(for element: AXUIElement, pid: Int32) -> AXWindowToken {
        lock.lock(); defer { lock.unlock() }
        if let existing = elements[pid]?.first(where: { CFEqual($0.value, element) }) { return AXWindowToken(pid: pid, id: existing.key) }
        let id = nextID
        nextID += 1
        elements[pid, default: [:]][id] = element
        return AXWindowToken(pid: pid, id: id)
    }

    func element(for token: AXWindowToken) -> AXUIElement? {
        lock.lock(); defer { lock.unlock() }
        return elements[token.pid]?[token.id]
    }

    func prune(pid: Int32, keep: Set<UInt64>) {
        lock.lock(); defer { lock.unlock() }
        elements[pid] = elements[pid]?.filter { keep.contains($0.key) }
    }

    func removeAll(pid: Int32) {
        lock.lock(); defer { lock.unlock() }
        elements.removeValue(forKey: pid)
    }
}

/// Fan-out of events to every `events()` stream.
private final class EventHub: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<WindowSystemEvent>.Continuation] = [:]

    func stream() -> AsyncStream<WindowSystemEvent> {
        let (stream, continuation) = AsyncStream<WindowSystemEvent>.makeStream(bufferingPolicy: .bufferingNewest(1024))
        let id = UUID()
        lock.lock(); continuations[id] = continuation; lock.unlock()
        continuation.onTermination = { [weak self] _ in
            self?.lock.lock(); self?.continuations.removeValue(forKey: id); self?.lock.unlock()
        }
        return stream
    }

    func yield(_ event: WindowSystemEvent) {
        lock.lock(); let targets = Array(continuations.values); lock.unlock()
        for continuation in targets { continuation.yield(event) }
    }
}

/// The context handed to the C callback; owned by `ObserverBox`.
private final class ObserverContext: @unchecked Sendable {
    let pid: Int32
    let hub: EventHub
    init(pid: Int32, hub: EventHub) { self.pid = pid; self.hub = hub }
}

private final class ObserverBox: @unchecked Sendable {
    let observer: AXObserver
    let context: ObserverContext
    var registeredWindows: Set<UInt64> = []
    init(observer: AXObserver, context: ObserverContext) { self.observer = observer; self.context = context }
}

private let axObserverCallback: AXObserverCallback = { _, _, notification, refcon in
    guard let refcon else { return }
    let context = Unmanaged<ObserverContext>.fromOpaque(refcon).takeUnretainedValue()
    guard let kind = AXWindowSystem.kind(of: notification as String) else { return }
    context.hub.yield(.ax(pid: context.pid, kind))
}

/// A thread that only runs a run loop, for the observer sources.
private final class RunLoopThread: Thread, @unchecked Sendable {
    private let ready = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var loop: CFRunLoop?

    override init() {
        super.init()
        name = "app.screon.helper.ax-observers"
        qualityOfService = .userInitiated
    }

    override func main() {
        let current = CFRunLoopGetCurrent()
        lock.lock(); loop = current; lock.unlock()
        // A run loop without sources returns immediately; a far-away timer keeps it alive.
        let keepAlive = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 1e9, 1e9, 0, 0) { _ in }
        CFRunLoopAddTimer(current, keepAlive, .defaultMode)
        ready.signal()
        CFRunLoopRun()
    }

    func runLoop() -> CFRunLoop {
        if !isExecuting && !isFinished { start() }
        ready.wait(); ready.signal()
        lock.lock(); defer { lock.unlock() }
        return loop!
    }
}

public final class AXWindowSystem: WindowSystem, @unchecked Sendable {
    public static let messagingTimeout: Float = 0.5

    private let table = ElementTable()
    private let hub = EventHub()
    private let queue = DispatchQueue(label: "app.screon.helper.ax", qos: .userInitiated, attributes: .concurrent)
    private let lock = NSLock()
    private var observers: [Int32: ObserverBox] = [:]
    private let thread = RunLoopThread()
    private var workspaceTokens: [NSObjectProtocol] = []
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private let log = Logger(subsystem: "app.screon.helper", category: "ax")

    public init() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), Self.messagingTimeout)
        let center = NSWorkspace.shared.notificationCenter
        let hub = self.hub
        @Sendable func pid(_ note: Notification) -> Int32? {
            (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
        }
        workspaceTokens = [
            center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: nil) { note in
                if let pid = pid(note) { hub.yield(.appLaunched(pid: pid)) }
            },
            center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: nil) { note in
                if let pid = pid(note) { hub.yield(.appTerminated(pid: pid)) }
            },
            center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil) { note in
                if let pid = pid(note) { hub.yield(.ax(pid: pid, .appActivated)) }
            },
        ]
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        for token in workspaceTokens { center.removeObserver(token) }
    }

    static func kind(of notification: String) -> AXNotificationKind? {
        switch notification {
        case kAXWindowCreatedNotification: .windowCreated
        case kAXUIElementDestroyedNotification: .windowDestroyed
        case kAXWindowMovedNotification: .windowMoved
        case kAXWindowResizedNotification: .windowResized
        case kAXWindowMiniaturizedNotification: .windowMiniaturized
        case kAXWindowDeminiaturizedNotification: .windowDeminiaturized
        case kAXTitleChangedNotification: .titleChanged
        case kAXFocusedWindowChangedNotification: .focusedWindowChanged
        case kAXApplicationActivatedNotification: .appActivated
        case kAXApplicationDeactivatedNotification: .appDeactivated
        case kAXSheetCreatedNotification: .sheetCreated
        case kAXMenuOpenedNotification: .menuOpened
        case kAXMenuClosedNotification: .menuClosed
        default: nil
        }
    }

    // MARK: Process level

    public func trackablePIDs() -> [Int32] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier > 0 && $0.processIdentifier != ownPID }
            .map(\.processIdentifier)
    }

    public func bundleID(forPID pid: Int32) -> String? { NSRunningApplication(processIdentifier: pid)?.bundleIdentifier }

    public func frontmostPID() -> Int32? { NSWorkspace.shared.frontmostApplication?.processIdentifier }

    public func cgWindows() -> [CGWindowRecord] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return [] }
        var result: [CGWindowRecord] = []
        result.reserveCapacity(list.count)
        for entry in list {
            guard let number = entry[kCGWindowNumber as String] as? UInt32, let pid = entry[kCGWindowOwnerPID as String] as? Int32,
                  let boundsDictionary = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary)
            else { continue }
            result.append(CGWindowRecord(
                id: number, pid: pid, bounds: LinkRect(x: bounds.origin.x, y: bounds.origin.y, width: bounds.width, height: bounds.height),
                layer: entry[kCGWindowLayer as String] as? Int ?? 0, alpha: entry[kCGWindowAlpha as String] as? Double ?? 1,
                isOnScreen: entry[kCGWindowIsOnscreen as String] as? Bool ?? false, name: entry[kCGWindowName as String] as? String))
        }
        return result
    }

    public func backingScale(for frame: LinkRect) -> Double {
        var count: UInt32 = 0
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetActiveDisplayList(16, &displays, &count) == .success, count > 0 else { return 2 }
        let center = CGPoint(x: frame.origin.x + frame.size.width / 2, y: frame.origin.y + frame.size.height / 2)
        let chosen = displays.prefix(Int(count)).first { CGDisplayBounds($0).contains(center) } ?? displays[0]
        guard let mode = CGDisplayCopyDisplayMode(chosen), mode.width > 0 else { return 2 }
        return Double(mode.pixelWidth) / Double(mode.width)
    }

    // MARK: Accessibility plumbing

    private func offload<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }

    private static func map(_ error: AXError) -> WindowSystemError {
        switch error {
        case .cannotComplete: .timeout
        case .apiDisabled: .permissionDenied
        case .invalidUIElement: .windowGone
        case .attributeUnsupported, .noValue, .actionUnsupported, .notImplemented: .unsupported
        default: .failed(error.rawValue)
        }
    }

    private static func check(_ error: AXError) throws {
        if error != .success { throw map(error) }
    }

    private static func appElement(_ pid: Int32) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }

    private static func copy(_ element: AXUIElement, _ attribute: String) -> (AXError, CFTypeRef?) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return (error, value)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        guard case (.success, let value?) = copy(element, attribute) else { return nil }
        return value as? String
    }

    private static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        guard case (.success, let value?) = copy(element, attribute), CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue((value as! CFBoolean))
    }

    private static func point(_ element: AXUIElement) -> CGPoint? {
        guard case (.success, let value?) = copy(element, kAXPositionAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue((value as! AXValue), .cgPoint, &point) ? point : nil
    }

    private static func size(_ element: AXUIElement) -> CGSize? {
        guard case (.success, let value?) = copy(element, kAXSizeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue((value as! AXValue), .cgSize, &size) ? size : nil
    }

    private func state(of element: AXUIElement, pid: Int32, focused: AXUIElement?) -> AXWindowState? {
        guard let origin = Self.point(element), let size = Self.size(element) else { return nil }
        let token = table.token(for: element, pid: pid)
        return AXWindowState(
            token: token, cgWindowID: PrivateAX.windowNumber(of: element), title: Self.string(element, kAXTitleAttribute) ?? "",
            frame: LinkRect(x: origin.x, y: origin.y, width: size.width, height: size.height),
            role: Self.string(element, kAXRoleAttribute) ?? "", subrole: Self.string(element, kAXSubroleAttribute) ?? "",
            isMinimised: Self.bool(element, kAXMinimizedAttribute) ?? false, isFullScreen: Self.bool(element, "AXFullScreen") ?? false,
            isMain: Self.bool(element, kAXMainAttribute) ?? false, isFocused: focused.map { CFEqual($0, element) } ?? false,
            isModal: Self.bool(element, kAXModalAttribute) ?? false)
    }

    // MARK: Reads

    public func axWindows(pid: Int32) async throws -> [AXWindowState] {
        guard AXIsProcessTrusted() else { throw WindowSystemError.permissionDenied }
        return try await offload { [self] in
            let app = Self.appElement(pid)
            let (error, value) = Self.copy(app, kAXWindowsAttribute)
            try Self.check(error)
            let windows = (value as? [AXUIElement]) ?? []
            var focused: AXUIElement?
            if case (.success, let candidate?) = Self.copy(app, kAXFocusedWindowAttribute), CFGetTypeID(candidate) == AXUIElementGetTypeID() {
                focused = (candidate as! AXUIElement)
            }
            var states: [AXWindowState] = []
            for window in windows.prefix(WindowTracker.maxManagedWindowsPerApp * 2) {
                AXUIElementSetMessagingTimeout(window, Self.messagingTimeout)
                if let state = state(of: window, pid: pid, focused: focused) {
                    states.append(state)
                    register(window: window, id: state.token.id, pid: pid)
                }
            }
            table.prune(pid: pid, keep: Set(states.map(\.token.id)))
            return states
        }
    }

    public func axWindow(_ token: AXWindowToken) async throws -> AXWindowState {
        try await offload { [self] in
            guard let element = table.element(for: token) else { throw WindowSystemError.windowGone }
            var focused: AXUIElement?
            if case (.success, let candidate?) = Self.copy(Self.appElement(token.pid), kAXFocusedWindowAttribute),
               CFGetTypeID(candidate) == AXUIElementGetTypeID() {
                focused = (candidate as! AXUIElement)
            }
            guard let state = state(of: element, pid: token.pid, focused: focused) else { throw WindowSystemError.windowGone }
            return state
        }
    }

    // MARK: Writes

    private func element(_ token: AXWindowToken) throws -> AXUIElement {
        guard let element = table.element(for: token) else { throw WindowSystemError.windowGone }
        return element
    }

    public func setPosition(_ token: AXWindowToken, to point: LinkPoint) async throws {
        try await offload { [self] in
            var cgPoint = CGPoint(x: point.x, y: point.y)
            guard let value = AXValueCreate(.cgPoint, &cgPoint) else { throw WindowSystemError.unsupported }
            try Self.check(AXUIElementSetAttributeValue(try element(token), kAXPositionAttribute as CFString, value))
        }
    }

    public func setSize(_ token: AXWindowToken, to size: LinkSize) async throws {
        try await offload { [self] in
            var cgSize = CGSize(width: size.width, height: size.height)
            guard let value = AXValueCreate(.cgSize, &cgSize) else { throw WindowSystemError.unsupported }
            try Self.check(AXUIElementSetAttributeValue(try element(token), kAXSizeAttribute as CFString, value))
        }
    }

    public func raise(_ token: AXWindowToken) async throws {
        try await offload { [self] in try Self.check(AXUIElementPerformAction(try element(token), kAXRaiseAction as CFString)) }
    }

    public func setMinimised(_ token: AXWindowToken, _ minimised: Bool) async throws {
        try await offload { [self] in
            try Self.check(AXUIElementSetAttributeValue(try element(token), kAXMinimizedAttribute as CFString, minimised as CFBoolean))
        }
    }

    public func setFullScreen(_ token: AXWindowToken, _ fullScreen: Bool) async throws {
        try await offload { [self] in
            try Self.check(AXUIElementSetAttributeValue(try element(token), "AXFullScreen" as CFString, fullScreen as CFBoolean))
        }
    }

    private func press(button attribute: String, of token: AXWindowToken) async throws {
        try await offload { [self] in
            let (error, value) = Self.copy(try element(token), attribute)
            try Self.check(error)
            guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { throw WindowSystemError.unsupported }
            try Self.check(AXUIElementPerformAction((value as! AXUIElement), kAXPressAction as CFString))
        }
    }

    public func pressClose(_ token: AXWindowToken) async throws { try await press(button: kAXCloseButtonAttribute, of: token) }
    public func pressZoom(_ token: AXWindowToken) async throws { try await press(button: kAXZoomButtonAttribute, of: token) }

    // MARK: Application attributes

    private func appFlag(_ attribute: String, pid: Int32) async throws -> Bool? {
        try await offload {
            let (error, value) = Self.copy(Self.appElement(pid), attribute)
            if error == .attributeUnsupported || error == .noValue { return nil }
            try Self.check(error)
            guard let value, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
            return CFBooleanGetValue((value as! CFBoolean))
        }
    }

    private func setAppFlag(_ attribute: String, pid: Int32, _ enabled: Bool) async throws {
        try await offload {
            try Self.check(AXUIElementSetAttributeValue(Self.appElement(pid), attribute as CFString, enabled as CFBoolean))
        }
    }

    public func enhancedUI(pid: Int32) async throws -> Bool? { try await appFlag("AXEnhancedUserInterface", pid: pid) }
    public func setEnhancedUI(pid: Int32, _ enabled: Bool) async throws { try await setAppFlag("AXEnhancedUserInterface", pid: pid, enabled) }
    public func manualAccessibility(pid: Int32) async throws -> Bool? { try await appFlag("AXManualAccessibility", pid: pid) }
    public func setManualAccessibility(pid: Int32, _ enabled: Bool) async throws { try await setAppFlag("AXManualAccessibility", pid: pid, enabled) }

    // MARK: Notifications

    public func events() -> AsyncStream<WindowSystemEvent> { hub.stream() }

    private static let appNotifications = [
        kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXApplicationActivatedNotification,
        kAXApplicationDeactivatedNotification, kAXMenuOpenedNotification, kAXMenuClosedNotification,
    ]
    private static let windowNotifications = [
        kAXUIElementDestroyedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification,
        kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification, kAXTitleChangedNotification, kAXSheetCreatedNotification,
    ]

    public func startObserving(pid: Int32) async throws {
        try await offload { [self] in
            lock.lock()
            let alreadyObserving = observers[pid] != nil
            lock.unlock()
            if alreadyObserving { return }

            var created: AXObserver?
            try Self.check(AXObserverCreate(pid, axObserverCallback, &created))
            guard let observer = created else { throw WindowSystemError.unsupported }
            let box = ObserverBox(observer: observer, context: ObserverContext(pid: pid, hub: hub))
            let refcon = Unmanaged.passUnretained(box.context).toOpaque()
            let app = Self.appElement(pid)
            for name in Self.appNotifications {
                let error = AXObserverAddNotification(observer, app, name as CFString, refcon)
                if error != .success && error != .notificationAlreadyRegistered {
                    log.debug("Observer registration failed (\(name, privacy: .public)): \(error.rawValue, privacy: .public)")
                }
            }
            CFRunLoopAddSource(thread.runLoop(), AXObserverGetRunLoopSource(observer), .defaultMode)
            lock.lock(); observers[pid] = box; lock.unlock()
        }
    }

    private func register(window: AXUIElement, id: UInt64, pid: Int32) {
        lock.lock()
        guard let box = observers[pid], box.registeredWindows.insert(id).inserted else { lock.unlock(); return }
        lock.unlock()
        let refcon = Unmanaged.passUnretained(box.context).toOpaque()
        for name in Self.windowNotifications {
            _ = AXObserverAddNotification(box.observer, window, name as CFString, refcon)
        }
    }

    public func stopObserving(pid: Int32) async {
        let box = lock.withLock { observers.removeValue(forKey: pid) }
        table.removeAll(pid: pid)
        if let box { CFRunLoopRemoveSource(thread.runLoop(), AXObserverGetRunLoopSource(box.observer), .defaultMode) }
    }
}
#endif
