#if os(macOS)
import Foundation
import LinkProtocol

/// One window to place.
public struct TileRequest: Sendable, Equatable {
    public var id: StageWindowKey
    public var desired: LinkSize
    public var minimum: LinkSize
    public var maximum: LinkSize
    public init(id: StageWindowKey, desired: LinkSize, minimum: LinkSize = LinkSize(width: 1, height: 1),
                maximum: LinkSize = StageSizeLimits.unbounded.maximum) {
        self.id = id; self.desired = desired; self.minimum = minimum; self.maximum = maximum
    }
}

public struct TileResult: Sendable, Equatable {
    public var frames: [StageWindowKey: LinkRect]
    /// Windows that cannot fit even at their minimum sizes. They are not placed.
    public var overflow: [StageWindowKey]
}

/// Tiling for the stage display: shelf packing in points. Pure and deterministic.
///
/// Windows keep their request order and fill rows from left to right, top to bottom. If everything does not fit at the
/// desired size, all sizes shrink by the same factor (never below a window's minimum, never above its maximum) until it does.
/// The result has no overlaps (frames are separated by `gap`) and lies inside `bounds`.
public enum StageLayout {
    public static func tile(_ requests: [TileRequest], in bounds: LinkRect, gap: Double = 8) -> TileResult {
        guard bounds.isValid, bounds.size.width > 0, bounds.size.height > 0 else {
            return TileResult(frames: [:], overflow: requests.map(\.id))
        }
        var seen = Set<StageWindowKey>()
        let unique = requests.filter { seen.insert($0.id).inserted }

        var scale = 1.0
        while true {
            if let frames = pack(unique, scale: scale, bounds: bounds, gap: gap) {
                return TileResult(frames: frames, overflow: [])
            }
            scale -= 0.05
            if scale < 0.05 { break }
        }
        // Even the minimum sizes do not all fit: place as many as fit at minimum size, in order, and report the rest.
        var placed: [TileRequest] = []
        var frames: [StageWindowKey: LinkRect] = [:]
        var overflow: [StageWindowKey] = []
        for request in unique {
            let candidate = placed + [request]
            if let attempt = pack(candidate, scale: 0, bounds: bounds, gap: gap) {
                placed = candidate
                frames = attempt
            } else {
                overflow.append(request.id)
            }
        }
        return TileResult(frames: frames, overflow: overflow)
    }

    /// The size of a request at `scale`: the desired size times the scale, then clamped to its limits and to the bounds.
    static func size(of request: TileRequest, scale: Double, bounds: LinkRect) -> LinkSize {
        func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double { min(max(value, low), max(low, high)) }
        let width = clamp(request.desired.width * scale, request.minimum.width, min(request.maximum.width, bounds.size.width))
        let height = clamp(request.desired.height * scale, request.minimum.height, min(request.maximum.height, bounds.size.height))
        return LinkSize(width: width.rounded(.down), height: height.rounded(.down))
    }

    private static func pack(_ requests: [TileRequest], scale: Double, bounds: LinkRect, gap: Double) -> [StageWindowKey: LinkRect]? {
        var frames: [StageWindowKey: LinkRect] = [:]
        var x = 0.0
        var y = 0.0
        var rowHeight = 0.0
        for request in requests {
            let size = size(of: request, scale: scale, bounds: bounds)
            guard size.width <= bounds.size.width, size.height <= bounds.size.height else { return nil }
            if x > 0, x + size.width > bounds.size.width {
                x = 0
                y += rowHeight + gap
                rowHeight = 0
            }
            guard y + size.height <= bounds.size.height else { return nil }
            frames[request.id] = LinkRect(origin: LinkPoint(x: bounds.origin.x + x, y: bounds.origin.y + y), size: size)
            x += size.width + gap
            rowHeight = max(rowHeight, size.height)
        }
        return frames
    }
}

/// Size matching: the iPad scene's size in points becomes the window's size in Mac points, clamped to the window's limits.
public enum StageSizeMatching {
    public static func windowSize(forScene scene: LinkSize, limits: StageSizeLimits, within bounds: LinkSize? = nil) -> LinkSize {
        func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double { min(max(value, low), max(low, high)) }
        var maxWidth = limits.maximum.width
        var maxHeight = limits.maximum.height
        if let bounds {
            maxWidth = min(maxWidth, bounds.width)
            maxHeight = min(maxHeight, bounds.height)
        }
        return LinkSize(
            width: clamp(scene.width.rounded(), limits.minimum.width, maxWidth),
            height: clamp(scene.height.rounded(), limits.minimum.height, maxHeight)
        )
    }
}
#endif
