import Foundation

/// What a window of the app is for. The desktop role is today's whole-Mac screen; the others belong to App Mode.
/// `Codable` and `Hashable` so it can be the value of a SwiftUI `WindowGroup(for:)`.
public enum SceneRole: Codable, Hashable, Sendable {
    /// The classic full-screen view of a Mac (also the picker). The default scene.
    case desktop
    /// The classic full-screen view of one saved computer, opened from an App Mode window (for example to unlock the Mac).
    case computerDesktop(computerID: UUID)
    /// The list of a Mac's apps to open.
    case launcher(computerID: UUID)
    /// One window of a Mac app. `windowRef` is the helper's opaque identifier for that window.
    case remoteWindow(computerID: UUID, windowRef: String)

    /// The computer an App Mode scene belongs to; `nil` for the desktop.
    public var computerID: UUID? {
        switch self {
        case .desktop: nil
        case .computerDesktop(let id), .launcher(let id), .remoteWindow(let id, _): id
        }
    }
}
