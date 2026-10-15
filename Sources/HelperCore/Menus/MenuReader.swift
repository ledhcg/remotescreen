#if os(macOS)
import Foundation
import LinkProtocol
import os

public enum MenuReaderError: Error, Sendable, Equatable {
    /// The path is empty, too deep or does not fit a tree this reader has sent.
    case invalidPath
    /// The menu changed since the iPad was sent its copy (index or title no longer match). Send a fresh tree.
    case stalePath
    /// The target is a separator, a submenu opener or disabled.
    case notPressable
    case system(MenuSystemError)
}

/// Reads an app's menu bar and presses items by path.
///
/// The tree is read level by level (breadth first) within the limits of `LinkLimits`: depth 6, 500 items per level,
/// 5000 items in total, titles up to 256 bytes. `press(pid:path:)` never trusts indices alone: it re-reads each level
/// live and compares index and title with the tree that was sent, so a menu that changed in between is rejected rather
/// than pressing a different item.
public actor MenuReader {
    private let system: any MenuSystem
    private let log = Logger(subsystem: "app.screon.helper", category: "menus")
    /// Trees that can be served again until a menu or title change.
    private var cache: [Int32: [LinkMenuItem]] = [:]
    /// The tree each pid's client was last given; `press` validates against it.
    private var sent: [Int32: [LinkMenuItem]] = [:]

    public init(system: any MenuSystem) { self.system = system }

    // MARK: Reading

    /// The menu tree, from the cache when it is still valid. Remembers it as the tree the client has seen.
    public func tree(pid: Int32) async throws -> [LinkMenuItem] {
        if let cached = cache[pid] {
            sent[pid] = cached
            return cached
        }
        let items = try await load(pid: pid)
        cache[pid] = items
        sent[pid] = items
        return items
    }

    private struct FlatNode {
        var info: MenuNodeInfo
        var item: LinkMenuItem
        var children: [Int] = []
    }

    private func load(pid: Int32) async throws -> [LinkMenuItem] {
        var nodes: [FlatNode] = []
        var budget = LinkLimits.maxMenuItemsTotal
        func append(_ infos: [MenuNodeInfo]) -> [Int] {
            var indices: [Int] = []
            for info in infos.prefix(LinkLimits.maxMenuItemsPerLevel) where budget > 0 {
                budget -= 1
                nodes.append(FlatNode(info: info, item: Self.convert(info)))
                indices.append(nodes.count - 1)
            }
            return indices
        }
        let top: [MenuNodeInfo]
        do { top = try await system.rootItems(pid: pid) } catch let error as MenuSystemError { throw MenuReaderError.system(error) }
        let roots = append(top)
        var level = roots
        var depth = 1
        while depth < LinkLimits.maxMenuDepth, !level.isEmpty, budget > 0 {
            var nextLevel: [Int] = []
            for index in level where nodes[index].info.hasSubmenu && !nodes[index].info.isSeparator {
                guard budget > 0 else { break }
                let infos: [MenuNodeInfo]
                do { infos = try await system.children(of: nodes[index].info.ref) } catch let error as MenuSystemError {
                    if error == .staleReference { throw MenuReaderError.stalePath }
                    // One submenu that does not answer must not hide the rest of the menu bar.
                    log.debug("A submenu could not be read: \(String(describing: error), privacy: .public)")
                    continue
                }
                let children = append(infos)
                nodes[index].children = children
                nextLevel.append(contentsOf: children)
            }
            level = nextLevel
            depth += 1
        }
        if budget == 0 { log.notice("The menu tree of pid \(pid, privacy: .public) hit the item limit.") }

        func assemble(_ index: Int) -> LinkMenuItem {
            var item = nodes[index].item
            item.children = nodes[index].children.map(assemble)
            return item
        }
        return roots.map(assemble)
    }

    /// Converts one accessibility menu item. Titles and key equivalents are bounded in UTF-8 bytes.
    static func convert(_ info: MenuNodeInfo) -> LinkMenuItem {
        if info.isSeparator { return LinkMenuItem(title: "", enabled: false, isSeparator: true) }
        let key = HelperText.bounded(info.cmdChar, maxBytes: LinkLimits.maxKeyEquivalentBytes)
        var modifiers: LinkModifiers = []
        if !key.isEmpty {
            if info.cmdModifiers & 1 != 0 { modifiers.insert(.shift) }
            if info.cmdModifiers & 2 != 0 { modifiers.insert(.option) }
            if info.cmdModifiers & 4 != 0 { modifiers.insert(.control) }
            if info.cmdModifiers & 8 == 0 { modifiers.insert(.command) }
        }
        return LinkMenuItem(
            title: HelperText.bounded(info.title, maxBytes: LinkLimits.maxMenuTitleBytes), enabled: info.isEnabled,
            checked: !info.markChar.isEmpty, keyEquivalent: key, modifiers: modifiers)
    }

    // MARK: Invalidation

    /// Forgets the cached tree of an app. The tree the client holds stays valid for `press` validation until replaced.
    public func invalidate(pid: Int32) { cache.removeValue(forKey: pid) }

    /// Wires the system's notifications: a menu opening or a title changing invalidates; a terminated app is forgotten.
    public func handle(_ event: WindowSystemEvent) {
        switch event {
        case .ax(let pid, .menuOpened), .ax(let pid, .menuClosed), .ax(let pid, .titleChanged), .ax(let pid, .focusedWindowChanged):
            invalidate(pid: pid)
        case .appTerminated(let pid):
            cache.removeValue(forKey: pid)
            sent.removeValue(forKey: pid)
        default:
            break
        }
    }

    // MARK: Pressing

    /// Presses the item at `path` (indices from the menu bar). Throws `stalePath` unless the live menu still has the same
    /// index and title at every step as the tree the client was sent.
    public func press(pid: Int32, path: [UInt16]) async throws {
        guard !path.isEmpty, path.count <= LinkLimits.maxMenuDepth else { throw MenuReaderError.invalidPath }
        guard var expected = sent[pid] else { throw MenuReaderError.stalePath }
        var live: [MenuNodeInfo]
        do { live = try await system.rootItems(pid: pid) } catch let error as MenuSystemError { throw MenuReaderError.system(error) }

        for (position, rawIndex) in path.enumerated() {
            let index = Int(rawIndex)
            guard index < expected.count, index < live.count, index < LinkLimits.maxMenuItemsPerLevel else { throw MenuReaderError.stalePath }
            let node = live[index]
            let was = expected[index]
            let liveItem = Self.convert(node)
            guard liveItem.title == was.title, liveItem.isSeparator == was.isSeparator else { throw MenuReaderError.stalePath }

            if position == path.count - 1 {
                guard !node.isSeparator, node.isEnabled, !node.hasSubmenu else { throw MenuReaderError.notPressable }
                do { try await system.press(node.ref) } catch let error as MenuSystemError {
                    throw error == .staleReference ? MenuReaderError.stalePath : MenuReaderError.system(error)
                }
                cache.removeValue(forKey: pid)
                return
            }
            guard node.hasSubmenu, !was.children.isEmpty else { throw MenuReaderError.stalePath }
            do { live = try await system.children(of: node.ref) } catch let error as MenuSystemError {
                throw error == .staleReference ? MenuReaderError.stalePath : MenuReaderError.system(error)
            }
            expected = was.children
        }
    }
}
#endif
