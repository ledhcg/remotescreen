import CoreGraphics
import Foundation
import LinkProtocol
import LinkTransport
import RemoteDisplay
import RFBKit
import WindowKit
import os

/// Where the decoded picture shows the window: the coded frame, the part of it that is the window, and its density.
struct WindowStreamLayout: Equatable, Sendable {
    /// Size of the decoded frame in pixels.
    var codedSize: CGSize
    /// The window inside the coded frame, in pixels.
    var contentRect: CGRect
    /// Pixels per Mac point.
    var scale: Double

    /// Size of the window in Mac points, the unit of input coordinates.
    var windowSize: CGSize { CGSize(width: contentRect.width / scale, height: contentRect.height / scale) }
}

/// A change to the child surfaces (menus, popovers) of a window.
enum SurfaceUpdate: Sendable {
    /// `offset` is in Mac points from the window's content origin.
    case upsert(id: SurfaceID, offset: LinkPoint, image: DecodedBGRAImage)
    case remove(SurfaceID)
}

/// Runs work on a serial queue and resumes when it is done, so a slow decode holds back the reader (and, through the bounded inbox,
/// the sender) instead of piling frames up.
private extension DispatchQueue {
    func run(_ work: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            async { work(); continuation.resume() }
        }
    }
}

/// Everything that arrives on one window's stream: the video (decoded off the main actor), child surfaces and cursor shapes.
///
/// A scene's `AppWindowView` reads the results on the main thread at display-link time; it never waits for the decoder.
final class WindowStream: @unchecked Sendable {
    /// Most child surfaces kept per window.
    static let maxSurfaces = 32
    /// Most cursor shapes remembered per window.
    static let maxCursors = 16

    let window: WindowID
    let decoder = VideoStreamDecoder()
    /// The clipboard and file transfers of the connection this window belongs to; set by the connection, read by the window view.
    @MainActor var services: AppWindowServices?

    private struct State {
        var layout: WindowStreamLayout?
        var surfaces: Set<SurfaceID> = []
        var pending: [SurfaceUpdate] = []
        var cursors: [CursorID: CursorImage] = [:]
        var cursor: CursorImage?
        var cursorVersion = 0
        var sawFrame = false
        var onWake: (@Sendable () -> Void)?
        var reader: Task<Void, Never>?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let queue: DispatchQueue
    /// Touched only on `queue`.
    private var tracker = VideoSequenceTracker()
    private let send: @Sendable (LinkMessage) -> Void
    private let statsBook: OSAllocatedUnfairLock<ConnectionStatsBook>
    private let onFirstFrame: @Sendable (WindowID) -> Void

    init(
        window: WindowID, statsBook: OSAllocatedUnfairLock<ConnectionStatsBook>,
        send: @escaping @Sendable (LinkMessage) -> Void, requestKeyframe: @escaping @Sendable (WindowID) -> Void,
        onFirstFrame: @escaping @Sendable (WindowID) -> Void
    ) {
        self.window = window
        self.statsBook = statsBook
        self.send = send
        self.onFirstFrame = onFirstFrame
        queue = DispatchQueue(label: "app.screon.link.decode.\(window.rawValue)", qos: .userInteractive)
        decoder.onNeedsKeyframe = { requestKeyframe(window) }
        decoder.onFrameAvailable = { [weak self] in self?.frameDecoded() }
    }

    deinit { shutdown() }

    // MARK: For the view (main thread)

    var layout: WindowStreamLayout? { state.withLock { $0.layout } }
    var hasFrame: Bool { state.withLock { $0.sawFrame } }

    /// Called (from any thread) when something new can be drawn. Replaces the previous handler.
    func setWakeHandler(_ handler: (@Sendable () -> Void)?) { state.withLock { $0.onWake = handler } }

    func drainSurfaceUpdates() -> [SurfaceUpdate] {
        state.withLock { state in
            defer { state.pending.removeAll(keepingCapacity: true) }
            return state.pending
        }
    }

    /// The cursor to draw and a number that changes whenever it does.
    func currentCursor() -> (version: Int, image: CursorImage?) { state.withLock { ($0.cursorVersion, $0.cursor) } }

    func counters() -> DecoderCounters {
        let stats = decoder.stats
        return DecoderCounters(decodedTotal: stats.framesDecoded, droppedTotal: stats.framesDropped, decodeP95Millis: stats.decodeP95Ms)
    }

    /// The window of a transient surface was destroyed.
    func removeSurface(_ id: SurfaceID) {
        let changed = state.withLock { state -> Bool in
            guard state.surfaces.remove(id) != nil else { return false }
            state.pending.append(.remove(id))
            return true
        }
        if changed { wake() }
    }

    // MARK: Feeding

    /// Starts reading the Mac's stream for this window. Replaces an earlier reader (the stream was reopened).
    func attach(_ inbox: LinkInbox<LinkMessage>) {
        let reader = Task.detached(priority: .userInitiated) { [weak self] in
            for await message in inbox {
                guard let self, !Task.isCancelled else { return }
                await self.queue.run { self.process(message) }
            }
        }
        let old = state.withLock { state -> Task<Void, Never>? in
            let old = state.reader
            state.reader = reader
            return old
        }
        old?.cancel()
    }

    /// The window went away or the connection ended.
    func shutdown() {
        let reader = state.withLock { state -> Task<Void, Never>? in
            defer { state.reader = nil }
            return state.reader
        }
        reader?.cancel()
        decoder.onNeedsKeyframe = nil
        decoder.onFrameAvailable = nil
        decoder.reset()
    }

    /// The scene went to the background or came back: VideoToolbox sessions do not survive the background.
    func suspend() { decoder.suspend() }
    func resume() { decoder.resume() }

    // MARK: Decode queue

    private func process(_ message: LinkMessage) {
        switch message {
        case .videoConfig(let config) where config.window == window: configure(config)
        case .videoFrame(let frame) where frame.window == window: decode(frame)
        case .surfaceSnapshot(let snapshot) where snapshot.window == window: addSurface(snapshot)
        case .cursorShape(let shape) where shape.window == window: addCursor(shape)
        case .cursorRef(let id, let cursor) where id == window: selectCursor(cursor)
        default: break // another window's message or one that has no meaning here
        }
    }

    private func configure(_ config: LinkVideoConfig) {
        let codec: VideoCodec = config.codec == .hevc ? .hevc : .h264
        let stream = VideoStreamConfig(
            codec: codec, parameterSets: config.parameterSets, nalLengthSize: 4,
            bitDepth: VideoBitDepth.bitDepth(codec: config.codec, parameterSets: config.parameterSets))
        do { try decoder.configure(stream) } catch {
            decoder.reset()
            state.withLock { $0.layout = nil }
            return
        }
        tracker.reset()
        let size = decoder.streamSize
        let coded = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        var content = CGRect(
            x: config.contentRect.origin.x, y: config.contentRect.origin.y,
            width: config.contentRect.size.width, height: config.contentRect.size.height
        ).intersection(coded)
        if content.isNull || content.width < 1 || content.height < 1 { content = coded }
        let scale = config.scale.isFinite && config.scale > 0 && config.scale <= LinkLimits.maxScale ? config.scale : 1
        let layout = WindowStreamLayout(codedSize: coded.size, contentRect: content, scale: scale)
        state.withLock { $0.layout = layout }
        wake()
    }

    private func decode(_ frame: LinkVideoFrame) {
        statsBook.withLock { $0.addReceived(window: window, bytes: frame.data.count) }
        switch tracker.observe(sequence: frame.sequence) {
        case .stale: return
        case .gap(let first, let last): send(.videoLost(window: window, firstSequence: first, lastSequence: last))
        case .inOrder: break
        }
        let unit = VideoAccessUnit(data: frame.data, ptsMicros: frame.ptsMicros, isKey: frame.flags.contains(.key))
        guard decoder.decode(unit) == .decoded else { return }
        let tokens = VideoSequenceTracker.ackTokens(for: frame.flags, sequence: frame.sequence)
        if !tokens.isEmpty { send(.videoAck(window: window, ltrTokens: tokens)) }
    }

    private func addSurface(_ snapshot: LinkSurfaceSnapshot) {
        let known = state.withLock { $0.surfaces.contains(snapshot.id) || $0.surfaces.count < Self.maxSurfaces }
        guard known, snapshot.offset.isValid, let image = BGRAImageDecoder.decode(snapshot.data, format: snapshot.format == .png ? .png : .jpeg) else { return }
        state.withLock { state in
            state.surfaces.insert(snapshot.id)
            state.pending.append(.upsert(id: snapshot.id, offset: snapshot.offset, image: image))
        }
        wake()
    }

    private func addCursor(_ shape: LinkCursorShape) {
        guard let cursor = BGRAImageDecoder.decodeCursor(shape.png, hotspotX: shape.hotspot.x, hotspotY: shape.hotspot.y) else { return }
        state.withLock { state in
            if state.cursors[shape.id] == nil, state.cursors.count >= Self.maxCursors { state.cursors.removeAll() }
            state.cursors[shape.id] = cursor
            state.cursor = cursor
            state.cursorVersion += 1
        }
        wake()
    }

    private func selectCursor(_ id: CursorID) {
        let changed = state.withLock { state -> Bool in
            guard let cursor = state.cursors[id], cursor != state.cursor else { return false }
            state.cursor = cursor
            state.cursorVersion += 1
            return true
        }
        if changed { wake() }
    }

    private func frameDecoded() {
        let first = state.withLock { state -> Bool in
            defer { state.sawFrame = true }
            return !state.sawFrame
        }
        if first { onFirstFrame(window) }
        wake()
    }

    private func wake() {
        let handler = state.withLock { $0.onWake }
        handler?()
    }
}

/// Sends `stream.keyframe` for windows whose decoder asks for one, at most twice a second per window, and never loses the last request.
final class KeyframeRequester: @unchecked Sendable {
    private struct State {
        var limiter = KeyframeRateLimiter()
        var timer: Task<Void, Never>?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let send: @Sendable (WindowID) -> Void

    init(send: @escaping @Sendable (WindowID) -> Void) { self.send = send }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func request(_ window: WindowID) {
        let decision = state.withLock { $0.limiter.request(window, now: Self.now) }
        switch decision {
        case .sendNow: send(window)
        case .deferred: scheduleFlush()
        }
    }

    func forget(_ window: WindowID) { state.withLock { $0.limiter.forget(window) } }

    func reset() {
        let timer = state.withLock { state -> Task<Void, Never>? in
            state.limiter.reset()
            defer { state.timer = nil }
            return state.timer
        }
        timer?.cancel()
    }

    private func scheduleFlush() {
        state.withLock { state in
            guard state.timer == nil, let deadline = state.limiter.nextDeadline else { return }
            let wait = max(0.01, deadline - Self.now)
            state.timer = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                self?.flush()
            }
        }
    }

    private func flush() {
        let due = state.withLock { state -> [WindowID] in
            state.timer = nil
            return state.limiter.due(now: Self.now)
        }
        for window in due { send(window) }
        if state.withLock({ $0.limiter.nextDeadline != nil }) { scheduleFlush() }
    }
}
