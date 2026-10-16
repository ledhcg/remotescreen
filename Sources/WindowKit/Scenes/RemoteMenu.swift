import Foundation
import LinkProtocol

/// One line of a Mac app's menu bar as the iPad shows it. `path` is what `menu.press` takes: the index of the item in its parent's
/// `children`, from the root menu down (separators count as items, so the helper can resolve the same path in its own tree).
public struct RemoteMenuEntry: Sendable, Equatable, Identifiable {
    public var path: [UInt16]
    public var title: String
    public var enabled: Bool
    public var checked: Bool
    public var isSeparator: Bool
    public var shortcut: MenuShortcut?
    /// `nil` for an item that does something, empty for a submenu with nothing in it.
    public var children: [RemoteMenuEntry]?

    public var id: [UInt16] { path }
    public var isSubmenu: Bool { children != nil }
}

/// A Mac key equivalent translated for UIKit.
public struct MenuShortcut: Sendable, Equatable, Hashable {
    /// What `UIKeyCommand(input:)` takes: a lower-case character or one of UIKit's special strings.
    public var input: String
    public var modifiers: LinkModifiers

    /// `nil` when there is nothing UIKit can match (no key equivalent, or a control character it has no name for).
    public init?(keyEquivalent: String, modifiers: LinkModifiers) {
        guard let key = Self.input(for: keyEquivalent) else { return nil }
        self.input = key
        self.modifiers = modifiers.intersection([.shift, .control, .option, .command])
    }

    public init(input: String, modifiers: LinkModifiers) {
        self.input = input
        self.modifiers = modifiers
    }

    static func input(for equivalent: String) -> String? {
        guard equivalent.unicodeScalars.count == 1, let scalar = equivalent.unicodeScalars.first else { return nil }
        switch scalar.value {
        case 0xF700: return "UIKeyInputUpArrow"
        case 0xF701: return "UIKeyInputDownArrow"
        case 0xF702: return "UIKeyInputLeftArrow"
        case 0xF703: return "UIKeyInputRightArrow"
        case 0xF72C: return "UIKeyInputPageUp"
        case 0xF72D: return "UIKeyInputPageDown"
        case 0xF729: return "UIKeyInputHome"
        case 0xF72B: return "UIKeyInputEnd"
        case 0x1B: return "UIKeyInputEscape"
        case 0x7F, 0x08: return "\u{8}"
        case 0x0D, 0x03: return "\r"
        case 0x09: return "\t"
        case 0x20: return " "
        case 0xF704...0xF70F, 0xF710...0xF8FF: return nil  // function keys and other private-use keys: UIKit has no input string for them
        case 0...0x1F: return nil
        default: return String(equivalent).lowercased()
        }
    }
}

/// Shortcuts that belong to iPadOS or to Screon and must never be taken by a Mac menu item.
public enum ReservedShortcuts {
    public static let all: Set<MenuShortcut> = [
        // iPadOS
        MenuShortcut(input: "h", modifiers: [.command]),  // Home
        MenuShortcut(input: " ", modifiers: [.command]),  // Spotlight
        MenuShortcut(input: "\t", modifiers: [.command]),  // App switcher
        MenuShortcut(input: "`", modifiers: [.command]),  // Next window of the app
        MenuShortcut(input: "h", modifiers: [.command, .shift]),
        MenuShortcut(input: "3", modifiers: [.command, .shift]),  // Screenshots
        MenuShortcut(input: "4", modifiers: [.command, .shift]),
        MenuShortcut(input: "5", modifiers: [.command, .shift]),
        MenuShortcut(input: "a", modifiers: [.command, .shift]),  // App Library
        // Screon
        MenuShortcut(input: "l", modifiers: [.command, .option]),  // Launcher
        MenuShortcut(input: "m", modifiers: [.command, .option]),  // Menus button
        MenuShortcut(input: ",", modifiers: [.command]),  // Settings
    ]

    public static func isReserved(_ shortcut: MenuShortcut) -> Bool { all.contains(shortcut) }
}

/// What ⌘W does in a remote-window scene.
public enum CloseShortcutPolicy: String, Sendable, CaseIterable {
    /// Closes the iPad window (and, as for any iPad window, leaves the Mac window open).
    case closeIPadWindow
    /// Is sent to the Mac like any other shortcut (the Mac app decides: close the window, a tab...).
    case sendToMac

    public static let command = MenuShortcut(input: "w", modifiers: [.command])
}

public enum RemoteMenuMapper {
    /// Bounds on top of the protocol's own: a tree that is deeper or wider is cut instead of followed.
    static let maxDepth = LinkLimits.maxMenuDepth
    static let maxEntries = 2000

    public static func entries(from items: [LinkMenuItem]) -> [RemoteMenuEntry] {
        var budget = maxEntries
        return map(items, prefix: [], depth: 0, budget: &budget)
    }

    private static func map(_ items: [LinkMenuItem], prefix: [UInt16], depth: Int, budget: inout Int) -> [RemoteMenuEntry] {
        var result: [RemoteMenuEntry] = []
        for (index, item) in items.enumerated() where index <= Int(UInt16.max) {
            guard budget > 0 else { break }
            budget -= 1
            let path = prefix + [UInt16(index)]
            var children: [RemoteMenuEntry]?
            if !item.children.isEmpty, depth + 1 < maxDepth {
                children = map(item.children, prefix: path, depth: depth + 1, budget: &budget)
            }
            result.append(
                RemoteMenuEntry(
                    path: path, title: item.title, enabled: item.enabled, checked: item.checked, isSeparator: item.isSeparator,
                    shortcut: item.isSeparator ? nil : MenuShortcut(keyEquivalent: item.keyEquivalent, modifiers: item.modifiers),
                    children: children))
        }
        return result
    }

    /// The item a path points at, or `nil` when the tree has changed so that it points nowhere.
    public static func item(at path: [UInt16], in items: [LinkMenuItem]) -> LinkMenuItem? {
        var level = items
        var found: LinkMenuItem?
        for index in path {
            guard Int(index) < level.count else { return nil }
            found = level[Int(index)]
            level = found?.children ?? []
        }
        return path.isEmpty ? nil : found
    }

    public struct KeyCommand: Sendable, Equatable {
        public var path: [UInt16]
        public var title: String
        public var shortcut: MenuShortcut
    }

    /// The items whose key equivalent should reach the Mac as a `UIKeyCommand` of the focused scene: enabled, not reserved, one per
    /// shortcut (the first in menu order wins), and without ⌘W when Screon keeps it for closing the iPad window.
    public static func keyCommands(from entries: [RemoteMenuEntry], closePolicy: CloseShortcutPolicy) -> [KeyCommand] {
        var seen = Set<MenuShortcut>()
        var result: [KeyCommand] = []
        func walk(_ list: [RemoteMenuEntry]) {
            for entry in list {
                if let children = entry.children { walk(children); continue }
                guard entry.enabled, !entry.isSeparator, let shortcut = entry.shortcut, !shortcut.modifiers.isEmpty,
                      !ReservedShortcuts.isReserved(shortcut) else { continue }
                if closePolicy == .closeIPadWindow, shortcut == CloseShortcutPolicy.command { continue }
                if seen.insert(shortcut).inserted { result.append(KeyCommand(path: entry.path, title: entry.title, shortcut: shortcut)) }
            }
        }
        walk(entries)
        return result
    }

    /// Wire form of a path for a command's property list, and back. Anything that is not a short list of small numbers is refused.
    public static func decodePath(_ numbers: [Int]) -> [UInt16]? {
        guard !numbers.isEmpty, numbers.count <= maxDepth else { return nil }
        var path: [UInt16] = []
        for number in numbers {
            guard let index = UInt16(exactly: number) else { return nil }
            path.append(index)
        }
        return path
    }
}

/// Caches the menu tree of each app and says when a new one is needed.
public struct MenuTreeCache: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public var items: [LinkMenuItem]
        public var entries: [RemoteMenuEntry]
        public var receivedAt: TimeInterval
    }

    private var trees: [String: Entry] = [:]
    private var requested: [String: TimeInterval] = [:]
    /// A tree older than this is fetched again when the app takes focus or its menu opens.
    public var maxAge: TimeInterval
    /// Do not ask again for an app within this time (a reply is on its way).
    public var requestGap: TimeInterval
    public static let maxApps = 64

    public init(maxAge: TimeInterval = 20, requestGap: TimeInterval = 1) {
        self.maxAge = maxAge
        self.requestGap = requestGap
    }

    public func entry(for bundleID: String) -> Entry? { trees[bundleID] }

    /// Whether `menu.get` should be sent now. Marks the request as made.
    public mutating func shouldRequest(bundleID: String, at now: TimeInterval, force: Bool = false) -> Bool {
        if let last = requested[bundleID], now - last < requestGap { return false }
        if !force, let entry = trees[bundleID], now - entry.receivedAt < maxAge { return false }
        requested[bundleID] = now
        return true
    }

    /// Stores a tree the iPad asked for (a tree nobody asked for is ignored). Returns true when it differs from the one before, so
    /// the menus must be rebuilt.
    @discardableResult
    public mutating func receive(bundleID: String, items: [LinkMenuItem], at now: TimeInterval) -> Bool {
        guard requested[bundleID] != nil, trees[bundleID] != nil || trees.count < Self.maxApps else { return false }
        let changed = trees[bundleID]?.items != items
        if changed || trees[bundleID] == nil {
            trees[bundleID] = Entry(items: items, entries: RemoteMenuMapper.entries(from: items), receivedAt: now)
        } else {
            trees[bundleID]?.receivedAt = now
        }
        return changed
    }

    /// The connection was lost: old trees may be wrong.
    public mutating func reset() { self = MenuTreeCache(maxAge: maxAge, requestGap: requestGap) }
}

/// Which window actions the Mac window offers.
public struct WindowActionAvailability: Sendable, Equatable {
    public var canClose: Bool
    public var canMinimise: Bool
    public var canZoom: Bool
    public var canExitFullScreen: Bool
    public var canResize: Bool

    /// Without `window.capabilities` yet, nothing is hidden (the helper refuses what it cannot do).
    public init(window: WindowState?) {
        let capabilities = window?.capabilities
        canClose = capabilities?.contains(.closable) ?? true
        canMinimise = capabilities?.contains(.minimisable) ?? true
        canZoom = capabilities?.contains(.zoomable) ?? true
        canResize = capabilities?.contains(.resizable) ?? true
        canExitFullScreen = window?.info.flags.contains(.fullScreen) ?? false
    }
}
