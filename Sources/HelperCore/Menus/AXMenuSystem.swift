#if os(macOS)
import ApplicationServices
import Foundation

/// The real `MenuSystem` on the accessibility API (`kAXMenuBarAttribute` and its children). Needs the Accessibility
/// permission; exercised for real only by the opt-in smoke test and the Mac validation checklist.
public final class AXMenuSystem: MenuSystem, @unchecked Sendable {
    private let lock = NSLock()
    private var generations: [Int32: UInt64] = [:]
    private var elements: [Int32: [UInt64: AXUIElement]] = [:]
    private var nextID: UInt64 = 1
    private let queue = DispatchQueue(label: "app.screon.helper.ax-menus", qos: .userInitiated, attributes: .concurrent)

    public init() {}

    private func offload<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }

    private static func map(_ error: AXError) -> MenuSystemError {
        switch error {
        case .cannotComplete: .timeout
        case .apiDisabled: .permissionDenied
        case .invalidUIElement: .staleReference
        case .noValue, .attributeUnsupported: .noMenuBar
        default: .failed(error.rawValue)
        }
    }

    private static func copy(_ element: AXUIElement, _ attribute: String) -> (AXError, CFTypeRef?) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return (error, value)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String {
        guard case (.success, let value?) = copy(element, attribute) else { return "" }
        return value as? String ?? ""
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        guard case (.success, let value?) = copy(element, kAXChildrenAttribute) else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private func register(_ element: AXUIElement, pid: Int32, generation: UInt64) -> MenuNodeRef {
        lock.lock(); defer { lock.unlock() }
        let id = nextID
        nextID += 1
        elements[pid, default: [:]][id] = element
        return MenuNodeRef(pid: pid, generation: generation, id: id)
    }

    private func lookup(_ ref: MenuNodeRef) throws -> AXUIElement {
        lock.lock(); defer { lock.unlock() }
        guard generations[ref.pid] == ref.generation, let element = elements[ref.pid]?[ref.id] else { throw MenuSystemError.staleReference }
        return element
    }

    private func nodeInfo(_ element: AXUIElement, pid: Int32, generation: UInt64) -> MenuNodeInfo {
        let title = Self.string(element, kAXTitleAttribute)
        let cmdChar = Self.string(element, "AXMenuItemCmdChar")
        var enabled = true
        if case (.success, let value?) = Self.copy(element, kAXEnabledAttribute), CFGetTypeID(value) == CFBooleanGetTypeID() {
            enabled = CFBooleanGetValue((value as! CFBoolean))
        }
        var modifiers = 0
        if case (.success, let value?) = Self.copy(element, "AXMenuItemCmdModifiers"), let number = value as? NSNumber { modifiers = number.intValue }
        let hasSubmenu = Self.children(element).contains { Self.string($0, kAXRoleAttribute) == kAXMenuRole }
        return MenuNodeInfo(
            ref: register(element, pid: pid, generation: generation), title: title, isEnabled: enabled,
            markChar: Self.string(element, "AXMenuItemMarkChar"), cmdChar: cmdChar, cmdModifiers: modifiers,
            isSeparator: title.isEmpty && cmdChar.isEmpty && !hasSubmenu, hasSubmenu: hasSubmenu)
    }

    public func rootItems(pid: Int32) async throws -> [MenuNodeInfo] {
        guard AXIsProcessTrusted() else { throw MenuSystemError.permissionDenied }
        return try await offload { [self] in
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.5)
            let (error, bar) = Self.copy(app, kAXMenuBarAttribute)
            if error != .success { throw Self.map(error) }
            guard let bar, CFGetTypeID(bar) == AXUIElementGetTypeID() else { throw MenuSystemError.noMenuBar }
            let generation: UInt64 = lock.withLock {
                let next = (generations[pid] ?? 0) + 1
                generations[pid] = next
                elements[pid] = [:]
                return next
            }
            return Self.children((bar as! AXUIElement)).map { nodeInfo($0, pid: pid, generation: generation) }
        }
    }

    public func children(of ref: MenuNodeRef) async throws -> [MenuNodeInfo] {
        try await offload { [self] in
            let element = try lookup(ref)
            AXUIElementSetMessagingTimeout(element, 0.5)
            guard let menu = Self.children(element).first(where: { Self.string($0, kAXRoleAttribute) == kAXMenuRole }) else { return [] }
            return Self.children(menu).map { nodeInfo($0, pid: ref.pid, generation: ref.generation) }
        }
    }

    public func press(_ ref: MenuNodeRef) async throws {
        try await offload { [self] in
            let element = try lookup(ref)
            let error = AXUIElementPerformAction(element, kAXPressAction as CFString)
            if error != .success { throw Self.map(error) }
        }
    }
}
#endif
