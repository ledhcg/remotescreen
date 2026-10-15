#if os(macOS)
import Foundation
import LinkProtocol

/// Handle of one menu element. Valid only for the generation in which it was read; every `rootItems` call starts a new
/// one, so a handle kept across menu changes cannot be pressed by accident.
public struct MenuNodeRef: Hashable, Sendable {
    public var pid: Int32
    public var generation: UInt64
    public var id: UInt64
    public init(pid: Int32, generation: UInt64, id: UInt64) { self.pid = pid; self.generation = generation; self.id = id }
}

/// One menu bar item or menu item, as the accessibility tree reports it.
public struct MenuNodeInfo: Sendable, Equatable {
    public var ref: MenuNodeRef
    public var title: String
    public var isEnabled: Bool
    /// `AXMenuItemMarkChar`: a check mark, dash or bullet when the item is on; empty otherwise.
    public var markChar: String
    /// `AXMenuItemCmdChar` and `AXMenuItemCmdModifiers` (bit 0 shift, 1 option, 2 control, 3 "no command").
    public var cmdChar: String
    public var cmdModifiers: Int
    public var isSeparator: Bool
    public var hasSubmenu: Bool
    public init(
        ref: MenuNodeRef, title: String, isEnabled: Bool = true, markChar: String = "", cmdChar: String = "", cmdModifiers: Int = 0,
        isSeparator: Bool = false, hasSubmenu: Bool = false
    ) {
        self.ref = ref; self.title = title; self.isEnabled = isEnabled; self.markChar = markChar; self.cmdChar = cmdChar
        self.cmdModifiers = cmdModifiers; self.isSeparator = isSeparator; self.hasSubmenu = hasSubmenu
    }
}

public enum MenuSystemError: Error, Sendable, Equatable {
    case timeout
    case permissionDenied
    case noMenuBar
    /// The handle belongs to an older generation, or the element is gone.
    case staleReference
    case failed(Int32)
}

/// The menu part of accessibility, as a seam.
public protocol MenuSystem: Sendable {
    /// The items of the app's menu bar (Apple menu first). Starts a new generation for this app.
    func rootItems(pid: Int32) async throws -> [MenuNodeInfo]
    /// The items of the menu that hangs off `ref` (the `AXMenu` layer is skipped).
    func children(of ref: MenuNodeRef) async throws -> [MenuNodeInfo]
    /// `AXPress` on the item.
    func press(_ ref: MenuNodeRef) async throws
}
#endif
