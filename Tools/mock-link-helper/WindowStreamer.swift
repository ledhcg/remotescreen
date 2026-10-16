import CoreVideo
import Foundation
import LinkProtocol
import LinkTransport

/// Where the last pointer event landed in each window (window points), shared by all streamers.
final class MarkerBoard: @unchecked Sendable {
    private let lock = NSLock()
    private var points: [WindowID: LinkPoint] = [:]
    func set(_ window: WindowID, _ point: LinkPoint) { lock.withLock { points[window] = point } }
    func get(_ window: WindowID) -> LinkPoint? { lock.withLock { points[window] } }
}

/// Renders and encodes one subscribed window and sends the result on that window's stream.
final class WindowStreamer: @unchecked Sendable {
    private let window: WindowID
    private let sizePoints: LinkSize
    private let pixelWidth: Int
    private let pixelHeight: Int
    private let fps: Int
    private let connection: LinkServerConnection
    private let board: MarkerBoard
    private let log: JSONLLog
    private let preferHEVC: Bool
    private let lock = NSLock()
    private var forceKey = true
    private var renderTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?

    init(
        subscription: LinkSubscribe, sizePoints: LinkSize, connection: LinkServerConnection, board: MarkerBoard, log: JSONLLog,
        preferHEVC: Bool
    ) {
        window = subscription.window
        self.sizePoints = sizePoints
        // Even dimensions in a range the encoders accept.
        pixelWidth = max(64, min(2048, Int(subscription.pixelWidth))) & ~1
        pixelHeight = max(64, min(2048, Int(subscription.pixelHeight))) & ~1
        fps = max(1, min(60, Int(subscription.maxFramesPerSecond == 0 ? 30 : subscription.maxFramesPerSecond)))
        self.connection = connection; self.board = board; self.log = log; self.preferHEVC = preferHEVC
    }

    func requestKeyframe() { lock.withLock { forceKey = true } }

    func start() {
        let (frames, continuation) = AsyncStream<EncodedFrame>.makeStream(bufferingPolicy: .bufferingNewest(8))
        let window = self.window, width = pixelWidth, height = pixelHeight, fps = self.fps
        let scale = Double(width) / max(1, sizePoints.width)
        let board = self.board, log = self.log, preferHEVC = self.preferHEVC
        let codecBox = CodecBox()
        renderTask = Task.detached { [self] in
            defer { continuation.finish() }
            let encoder: VideoEncoder
            do {
                encoder = try VideoEncoder(width: width, height: height, fps: fps, preferHEVC: preferHEVC) { continuation.yield($0) }
            } catch {
                log.write("encoder_failed", ["window": window.rawValue])
                return
            }
            codecBox.set(encoder.codec)
            defer { encoder.invalidate() }
            var buffer: CVPixelBuffer?
            guard
                CVPixelBufferCreate(
                    nil, width, height, kCVPixelFormatType_32BGRA,
                    [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &buffer) == kCVReturnSuccess, let buffer
            else { return }
            let clock = ContinuousClock()
            let interval = Duration.microseconds(1_000_000 / fps)
            var next = clock.now
            var index = 0
            while !Task.isCancelled {
                CVPixelBufferLockBaseAddress(buffer, [])
                if let base = CVPixelBufferGetBaseAddress(buffer) {
                    let marker = board.get(window).map { (x: Int($0.x * scale), y: Int($0.y * scale)) }
                    PatternRenderer.render(
                        into: base, width: width, height: height, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), frame: index,
                        seed: Int(window.rawValue), marker: marker)
                }
                CVPixelBufferUnlockBaseAddress(buffer, [])
                let force = self.lock.withLock { () -> Bool in
                    defer { self.forceKey = false }
                    return self.forceKey
                }
                encoder.encode(buffer, ptsMicros: Int64(index) * 1_000_000 / Int64(fps), forceKey: force)
                index += 1
                next += interval
                try? await clock.sleep(until: next)
            }
        }
        let connection = self.connection
        sendTask = Task.detached {
            var sequence: UInt32 = 0
            var sentConfig: [Data]?
            for await frame in frames {
                if let sets = frame.parameterSets, sets != sentConfig, let codec = codecBox.get() {
                    sentConfig = sets
                    let config = LinkVideoConfig(
                        window: window, codec: codec, parameterSets: sets, pixelWidth: UInt32(width), pixelHeight: UInt32(height),
                        contentRect: LinkRect(x: 0, y: 0, width: Double(width) / scale, height: Double(height) / scale), scale: scale)
                    try? await connection.send(.videoConfig(config))
                }
                guard sentConfig != nil else { continue }  // never send a frame the decoder cannot configure for
                let flags: LinkVideoFrameFlags = frame.isKey ? [.key] : []
                let message = LinkVideoFrame(window: window, sequence: sequence, ptsMicros: frame.ptsMicros, flags: flags, data: frame.data)
                sequence &+= 1
                try? await connection.send(.videoFrame(message))
            }
        }
    }

    func stop() async {
        renderTask?.cancel()
        await renderTask?.value
        await sendTask?.value
    }
}

private final class CodecBox: @unchecked Sendable {
    private let lock = NSLock()
    private var codec: LinkVideoCodec?
    func set(_ c: LinkVideoCodec) { lock.withLock { codec = c } }
    func get() -> LinkVideoCodec? { lock.withLock { codec } }
}
