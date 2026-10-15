import Foundation
import LinkProtocol
@testable import WindowKit

/// Deterministic generator (SplitMix64) so a failing seed can be replayed.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

func makeWindow(
    _ id: UInt32, bundle: String = "com.example.app", title: String = "Window", parent: UInt32? = nil,
    kind: LinkWindowKind = .managed, frame: LinkRect = LinkRect(x: 10, y: 20, width: 800, height: 600),
    scale: Double = 2, flags: LinkWindowFlags = []
) -> LinkWindowInfo {
    LinkWindowInfo(
        id: WindowID(id), pid: 100, bundleID: bundle, parentID: parent.map { WindowID($0) }, kind: kind,
        frame: frame, scale: scale, title: title, flags: flags
    )
}

func makeApp(_ ref: UInt32, bundle: String = "com.example.app", name: String = "Example", active: Bool = false) -> LinkAppInfo {
    LinkAppInfo(ref: AppRef(ref), bundleID: bundle, name: name, pid: 100, iconKey: IconKey(ref), isActive: active, windowCount: 0)
}

func makeSnapshot(
    version: UInt64 = 1, apps: [LinkAppInfo] = [], windows: [LinkWindowInfo] = [], active: UInt32? = nil
) -> LinkSnapshot {
    LinkSnapshot(stateVersion: version, apps: apps, windows: windows, activeWindow: active.map { WindowID($0) })
}

func workspace(_ windows: [LinkWindowInfo], apps: [LinkAppInfo] = [], version: UInt64 = 1) -> RemoteWorkspace {
    var ws = RemoteWorkspace()
    ws.apply(snapshot: makeSnapshot(version: version, apps: apps, windows: windows))
    return ws
}
