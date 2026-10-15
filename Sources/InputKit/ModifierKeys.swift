import Foundation

/// State of one modifier key on the sidebar / accessory bar, in the style of Sidecar.
public enum ModifierState: Sendable, Equatable {
    /// Not pressed.
    case up
    /// A finger rests on the key: the key is down on the Mac and released when the finger lifts (for ⌘-click, ⇧-click with the other hand).
    case held
    /// Tapped once: the key is down on the Mac and releases itself after the next action (one key, one click).
    case oneShot
    /// Tapped twice: the key stays down until tapped again.
    case locked
}

/// State machine for the modifier keys ⌃ ⌥ ⌘ ⇧. Pure (time is passed in), so it can be tested without UI.
///
/// - Finger down: press the key immediately (so hold-and-click works).
/// - Finger up: if an action happened during the hold, release; if it was a short tap, become "latched once"; if held long with
/// nothing done, release.
/// - Second tap within `doubleTapInterval` while latched: lock. Tap while latched (later than that) or while locked: release.
/// - `actionCompleted()` after each key or click: releases keys latched once; keys being held are marked as used.
public struct ModifierKeys: Sendable, Equatable {
    public static let doubleTapInterval = 0.3
    /// Holding longer than this with nothing done means lifting the finger releases the key (it does not become latched).
    public static let tapMaximumDuration = 0.4

    private struct Entry: Sendable, Equatable {
        var modifier: StickyModifier
        var state: ModifierState
        var pressedAt: Double
        var usedWhileHeld = false
        var tappedAt: Double?
        /// Locked and a finger just went down: lifting it unlocks.
        var unlocking = false
    }

    /// Keys not in the `.up` state, in the order pressed (released in reverse order).
    private var entries: [Entry] = []

    public init() {}

    public func state(of modifier: StickyModifier) -> ModifierState {
        entries.first { $0.modifier == modifier }?.state ?? .up
    }

    /// Every key currently down on the Mac, in the order pressed.
    public var active: [StickyModifier] { entries.map(\.modifier) }

    /// State of keys not in `.up`, for the UI to draw.
    public var states: [StickyModifier: ModifierState] {
        Dictionary(uniqueKeysWithValues: entries.map { ($0.modifier, $0.state) })
    }

    public mutating func touchDown(_ modifier: StickyModifier, at time: Double) -> [InputIntent] {
        guard let index = entries.firstIndex(where: { $0.modifier == modifier }) else {
            entries.append(Entry(modifier: modifier, state: .held, pressedAt: time))
            return [.key(modifier.keysym, macKeyCode: modifier.macKeyCode, isDown: true)]
        }
        switch entries[index].state {
        case .oneShot:
            if let tapped = entries[index].tappedAt, time - tapped <= Self.doubleTapInterval {
                entries[index].state = .locked // double tap: lock (the key stays down)
                entries[index].tappedAt = nil
            } else {
                entries.remove(at: index) // tap again on a latched key: drop it
                return [.key(modifier.keysym, macKeyCode: modifier.macKeyCode, isDown: false)]
            }
        case .locked:
            entries[index].unlocking = true
        case .held, .up:
            break
        }
        return []
    }

    public mutating func touchUp(_ modifier: StickyModifier, at time: Double) -> [InputIntent] {
        guard let index = entries.firstIndex(where: { $0.modifier == modifier }) else { return [] }
        let entry = entries[index]
        switch entry.state {
        case .held:
            if !entry.usedWhileHeld, time - entry.pressedAt <= Self.tapMaximumDuration {
                entries[index].state = .oneShot
                entries[index].tappedAt = time
                return []
            }
            entries.remove(at: index)
            return [.key(modifier.keysym, macKeyCode: modifier.macKeyCode, isDown: false)]
        case .locked where entry.unlocking:
            entries.remove(at: index)
            return [.key(modifier.keysym, macKeyCode: modifier.macKeyCode, isDown: false)]
        case .locked, .oneShot, .up:
            return []
        }
    }

    /// A regular key or a click has just finished: release keys latched once, and mark keys being held as used.
    public mutating func actionCompleted() -> [InputIntent] {
        var released: [InputIntent] = []
        for index in entries.indices.reversed() {
            switch entries[index].state {
            case .oneShot:
                released.append(.key(entries[index].modifier.keysym, macKeyCode: entries[index].modifier.macKeyCode, isDown: false))
                entries.remove(at: index)
            case .held:
                entries[index].usedWhileHeld = true
            case .locked, .up:
                break
            }
        }
        return released
    }

    /// Releases everything (focus loss, backgrounding, disconnect), in reverse order of pressing.
    public mutating func releaseAll() -> [InputIntent] {
        defer { entries.removeAll() }
        return entries.reversed().map { .key($0.modifier.keysym, macKeyCode: $0.modifier.macKeyCode, isDown: false) }
    }

    /// A complete tap (down then immediately up), for the accessory bar and the simulated hardware keyboard.
    public mutating func tap(_ modifier: StickyModifier, at time: Double) -> [InputIntent] {
        touchDown(modifier, at: time) + touchUp(modifier, at: time)
    }
}
