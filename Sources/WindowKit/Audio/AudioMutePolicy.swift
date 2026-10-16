import Foundation
import LinkProtocol

/// Which apps' audio should be silent: an app plays only while at least one of its windows is wanted by a scene that is not paused
/// (in the background). Pure, so the rule is testable without audio hardware.
public enum AudioMutePolicy {
    /// - Parameters:
    ///   - pids: apps that have an audio stream.
    ///   - workspace: where windows and their pids are known.
    ///   - subscriptions: which windows scenes want and which of them are paused.
    public static func mutedPIDs(pids: Set<Int32>, workspace: RemoteWorkspace, subscriptions: SubscriptionManager) -> Set<Int32> {
        var audible: Set<Int32> = []
        for window in subscriptions.wanted where !subscriptions.isPaused(window) {
            if let info = workspace.window(window)?.info { audible.insert(info.pid) }
        }
        return pids.subtracting(audible)
    }
}
