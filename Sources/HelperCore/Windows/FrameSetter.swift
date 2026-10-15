#if os(macOS)
import Foundation
import LinkProtocol

public struct FrameSetResult: Sendable, Equatable {
    public var requested: LinkRect
    /// What the window reports after the change, read back from the app.
    public var actual: LinkRect
    /// False when the app clamped or ignored the change (minimum/maximum size, full screen, or a stubborn app).
    public var isExact: Bool
}

/// Moves and resizes a window the way that works across apps (design §4.5, spike S10):
/// `AXEnhancedUserInterface` is switched off around the change and restored afterwards, even on failure; position is
/// written before and after the size, because many apps clamp the size against the old position; the result is read back.
public enum FrameSetter {
    public static let tolerance = 1.0

    public static func setFrame(
        _ target: LinkRect, of token: AXWindowToken, system: any WindowSystem
    ) async throws -> FrameSetResult {
        guard target.isValid, target.size.width >= 1, target.size.height >= 1 else { throw WindowSystemError.unsupported }
        let wasEnhanced = (try? await system.enhancedUI(pid: token.pid)) ?? nil
        if wasEnhanced == true { try? await system.setEnhancedUI(pid: token.pid, false) }
        let outcome: Result<LinkRect, Error>
        do {
            try await system.setPosition(token, to: target.origin)
            try await system.setSize(token, to: target.size)
            try await system.setPosition(token, to: target.origin)
            outcome = .success(try await system.axWindow(token).frame)
        } catch {
            outcome = .failure(error)
        }
        if wasEnhanced == true { try? await system.setEnhancedUI(pid: token.pid, true) }
        let actual = try outcome.get()
        return FrameSetResult(requested: target, actual: actual, isExact: matches(actual, target))
    }

    static func matches(_ a: LinkRect, _ b: LinkRect) -> Bool {
        abs(a.origin.x - b.origin.x) <= tolerance && abs(a.origin.y - b.origin.y) <= tolerance
            && abs(a.size.width - b.size.width) <= tolerance && abs(a.size.height - b.size.height) <= tolerance
    }
}
#endif
