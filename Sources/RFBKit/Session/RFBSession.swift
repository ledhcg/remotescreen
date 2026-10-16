import Foundation

/// What the server has just told the client.
public enum ServerEvent: Equatable, Sendable {
    /// The framebuffer was updated in these regions. `cursor` has a value when the server sent a new cursor image along with it.
    case framebufferUpdate(dirty: [PixelRect], cursor: CursorImage? = nil)
    case bell
    case serverCutText(String)
    /// The Mac's clipboard via Apple's own protocol (reply to `clipboardRequest`).
    case clipboard(ClipboardTransfer)
    /// Color map the server sent. We always use true colour so we ignore it, but we still have to read all the data.
    case colourMapIgnored
    /// The Mac's clipboard was larger than the cap and was therefore read and discarded (without dropping the session). `bytes` is the size the server declared.
    case clipboardSkipped(bytes: Int)
}

/// Server kind, which determines the usable clipboard protocol.
public enum ServerFlavor: Sendable, Equatable {
    /// Standard RFB: `ClientCutText` / `ServerCutText`, Latin-1 text.
    case standard
    /// Apple's `screensharingd` (advertising version `003.889`): its own clipboard, request-reply, with UTF-8.
    /// It does handle the standard `ClientCutText` message but ignored it in the sessions measured, so it is not used.
    case apple

    public init(serverVersion: RFBVersion) {
        self = (serverVersion == RFBVersion(major: 3, minor: 889)) ? .apple : .standard
    }
}

/// Received figures, used to assess bandwidth and compression efficiency.
public struct SessionStatistics: Equatable, Sendable {
    /// Bytes of image data on the wire per encoding (for ZRLE, the compressed size).
    public var payloadBytes: [RFBEncoding: Int] = [:]
    /// ZRLE bytes after decompression, for computing the compression ratio.
    public var zrleInflatedBytes = 0
    public var updateCount = 0
    /// Total CPU time spent decoding pixels (excluding network waits), to tell whether decoding or the network is the bottleneck.
    public var decodeTime: Duration = .zero
}

/// An RFB session after authentication and `ServerInit`: sends messages, receives and decodes updates into the framebuffer.
///
/// Uses an `actor` so the framebuffer is mutated from only one place, and decoding runs off the main thread.
public actor RFBSession {
    /// Immutable and `Sendable`, so it can be read from outside the actor without `await`.
    public nonisolated let serverInfo: ServerInit
    public nonisolated let flavor: ServerFlavor
    /// The authentication method used to enter this session (`nil` if the session was created without `RFBConnection`). Used to warn the user
    /// when it is a weak VNC password or no authentication.
    public nonisolated let securityType: RFBSecurityType?
    /// When `true`, the session requests the next update **as soon as it receives the header** of an update, instead of waiting until decoding finishes and
    /// the caller asks. The server prepares the next frame while we receive and decode this one, so the serial wait
    /// (one network round trip plus decode time) between two frames disappears. The caller does **not** call `requestUpdate` any more.
    public nonisolated let pipelinesUpdateRequests: Bool
    /// Pixel format we ask the server to send (`SetPixelFormat`). `framebuffer` is always 8-bit BGRA regardless of this format.
    public nonisolated let wireFormat: PixelFormat
    private let wireLayout: WireLayout
    public private(set) var framebuffer: Framebuffer
    public private(set) var statistics = SessionStatistics()

    private let stream: any ByteStream
    /// Ordered send queue. Every touch or key event is one `post`, and a single task writes them to the stream in turn,
    /// so a "press" always reaches the Mac before the "release" no matter which thread the caller is on. When the network is congested, the writer task takes everything waiting and
    /// drops redundant mouse moves (`OutboundCoalescer`) instead of letting them pile up and make the cursor on the Mac lag further and further behind.
    private let outbound = OutboundQueue()
    /// The task that writes `outbound` to the stream; `close()` lets it flush what is queued (key releases) before closing.
    private let writer: Task<Void, Never>
    /// ZRLE decompressor, created on first use then kept for the whole session because the zlib stream is continuous.
    private var zrleDecoder: ZRLEDecoder?

    /// Cap on the length of clipboard text received from the server (Apple's server also closes the connection above a reasonable size).
    static let maxCutTextLength = 1 << 20
    /// Cap on the bytes read and allocated at once for a Raw rectangle.
    static let maxRawBandBytes = 4 << 20

    public init(
        stream: any ByteStream, serverInfo: ServerInit, flavor: ServerFlavor = .standard, pipelinesUpdateRequests: Bool = false,
        pixelFormat: PixelFormat = .bgra8888, securityType: RFBSecurityType? = nil
    ) throws {
        guard let layout = pixelFormat.supportedLayout else {
            throw RFBError.malformed("pixel format of \(pixelFormat.bitsPerPixel) bits is not supported")
        }
        self.stream = stream
        self.serverInfo = serverInfo
        self.flavor = flavor
        self.securityType = securityType
        self.pipelinesUpdateRequests = pipelinesUpdateRequests
        wireFormat = pixelFormat
        wireLayout = layout
        framebuffer = try Framebuffer(width: Int(serverInfo.width), height: Int(serverInfo.height))

        // This task holds only `stream` and the queue, not `self`, so it does not extend the session's lifetime. It ends on `close()`.
        writer = Task { [stream, outbound] in
            var coalescer = OutboundCoalescer()
            for await _ in outbound.wakeups {
                let batch = coalescer.coalesce(outbound.takeAll())
                guard !batch.isEmpty else { continue }
                let data = batch.reduce(into: Data()) { $0.append($1.wireBytes) }
                do {
                    try await stream.write(data)
                } catch {
                    // The stream is broken: close it so the pending read fails too and the owner reconnects. Previously only the writer
                    // stopped, the session still looked live, update requests were never sent again and the screen froze.
                    outbound.close()
                    await stream.close()
                    break
                }
            }
        }
    }

    /// Queues a message on the send queue and returns immediately (without waiting for the write). Callable from any thread.
    /// Use it for user actions (mouse, keys): keeps the order without creating a `Task` for each event.
    public nonisolated func post(_ messages: [ClientMessage]) {
        guard !messages.isEmpty else { return }
        outbound.append(messages)
    }

    public func send(_ message: ClientMessage) async throws {
        try await stream.write(message.wireBytes)
    }

    /// Sets the BGRA pixel format, declares the supported encodings, then requests the full first frame.
    /// Merges the three messages into one write so they reach the server in the same packet.
    public func start(encodings: [RFBEncoding]) async throws {
        var data = ClientMessage.setPixelFormat(wireFormat).wireBytes
        data.append(ClientMessage.setEncodings(encodings).wireBytes)
        data.append(ClientMessage.framebufferUpdateRequest(incremental: false, rect: framebuffer.bounds).wireBytes)
        try await stream.write(data)
    }

    /// Minimum spacing between two update requests, `nil` for unlimited (as fast as possible). The server sends only one update
    /// per request, so this spacing is effectively the frames-per-second cap; changes that happen while waiting are merged into
    /// the next update. Only takes effect when `pipelinesUpdateRequests` is on. Can be changed mid-session, effective from the next request.
    public private(set) var minimumUpdateInterval: Duration?
    private var lastUpdateRequest: ContinuousClock.Instant?

    public func setMinimumUpdateInterval(_ interval: Duration?) {
        minimumUpdateInterval = interval
        // A request is deferred on the old cadence: recompute its deadline on the new cadence, send immediately if it is already overdue.
        guard let pending = pendingRequest, let last = previousRequest else { return }
        let due = interval.map { last + $0 } ?? last
        guard due < pending.due else { return }
        pending.task.cancel()
        pendingRequest = nil
        lastUpdateRequest = previousRequest
        schedule(at: max(due, ContinuousClock.now))
    }

    /// The deferred request (if any) and its deadline; `previousRequest` is the deadline of the request before it, used to recompute when the cadence changes.
    private var pendingRequest: (task: Task<Void, Never>, due: ContinuousClock.Instant)?
    private var previousRequest: ContinuousClock.Instant?

    /// Queues an incremental update request on the send queue (keeping order with mouse/keys), without waiting for the write.
    /// If there is a minimum spacing and not enough time has passed since the previous request, defers it to the right moment.
    private func postUpdateRequest() {
        let now = ContinuousClock.now
        var due = now
        if let minimumUpdateInterval, let lastUpdateRequest { due = max(now, lastUpdateRequest + minimumUpdateInterval) }
        schedule(at: due)
    }

    private func schedule(at due: ContinuousClock.Instant) {
        previousRequest = lastUpdateRequest
        lastUpdateRequest = due
        guard due > ContinuousClock.now else {
            pendingRequest = nil
            post([.framebufferUpdateRequest(incremental: true, rect: framebuffer.bounds)])
            return
        }
        let task = Task { [weak self] in
            do { try await Task.sleep(until: due, clock: .continuous) } catch { return } // cancelled: already rescheduled
            await self?.postUpdateRequestNow()
        }
        pendingRequest = (task, due)
    }

    private func postUpdateRequestNow() {
        pendingRequest = nil
        post([.framebufferUpdateRequest(incremental: true, rect: framebuffer.bounds)])
    }

    public func requestUpdate(incremental: Bool = true) async throws {
        try await send(.framebufferUpdateRequest(incremental: incremental, rect: framebuffer.bounds))
    }

    /// Reads exactly one message from the server and applies it.
    public func nextEvent() async throws -> ServerEvent {
        switch try await stream.readUInt8() {
        case 0: return try await readFramebufferUpdate()
        case 1: return try await readColourMap()
        case 2: return .bell
        case 3: return try await readCutText()
        case ClipboardTransfer.messageType: return try await readClipboardTransfer()
        case let type: throw RFBError.malformed("unknown server message type: \(type)")
        }
    }

    // MARK: - FramebufferUpdate

    private func readFramebufferUpdate() async throws -> ServerEvent {
        _ = try await stream.readUInt8() // padding
        let rectCount = Int(try await stream.readUInt16())
        var dirty: [PixelRect] = []
        var cursor: CursorImage?
        statistics.updateCount += 1
        if pipelinesUpdateRequests { postUpdateRequest() }
        var resized = false
        // Re-request with the new size if the server changed the screen size mid-update: the request already sent above used the old size.
        // After a resize (server-side downscaling), Apple's server sends only `DesktopSize` and then WAITS: without a full re-request the screen stays
        // black until something changes (measured with message type 8). So re-request NON-incrementally, at the new size.
        defer { if resized, pipelinesUpdateRequests { post([.framebufferUpdateRequest(incremental: false, rect: framebuffer.bounds)]) } }

        for _ in 0..<rectCount {
            let rect = PixelRect(
                x: Int(try await stream.readUInt16()), y: Int(try await stream.readUInt16()),
                width: Int(try await stream.readUInt16()), height: Int(try await stream.readUInt16())
            )
            let encoding = RFBEncoding(rawValue: Int32(bitPattern: try await stream.readUInt32()))

            switch encoding {
            case .raw:
                guard framebuffer.contains(rect) else {
                    throw RFBError.malformed("Raw rectangle \(rect) is outside the framebuffer")
                }
                // Read in bands of rows, each at most `maxRawBandBytes`: the rectangle size is declared by the server, so reading it all at once
                // could force us to allocate hundreds of MB (iOS would kill the app) with a single message.
                let rowBytes = rect.width * wireLayout.bytesPerPixel
                let rowsPerBand = max(1, Self.maxRawBandBytes / max(rowBytes, 1))
                var bytes = 0
                var row = 0
                repeat {
                    let rows = min(rowsPerBand, rect.height - row)
                    let band = PixelRect(x: rect.x, y: rect.y + row, width: rect.width, height: rows)
                    let raw = try await stream.read(exactly: rows * rowBytes)
                    let clock = ContinuousClock.now
                    switch wireLayout {
                    case .bgra8888: try framebuffer.write(band, bgra: raw)
                    case .rgb565: try framebuffer.writeRGB565(band, source: raw)
                    }
                    statistics.decodeTime += ContinuousClock.now - clock
                    bytes += rows * rowBytes
                    row += rows
                } while row < rect.height
                statistics.payloadBytes[.raw, default: 0] += bytes
                dirty.append(rect)

            case .zrle:
                guard framebuffer.contains(rect) else {
                    throw RFBError.malformed("ZRLE rectangle \(rect) is outside the framebuffer")
                }
                let length = Int(try await stream.readUInt32())
                guard length <= ZRLEDecoder.maxCompressedSize(for: rect) else {
                    throw RFBError.malformed("ZRLE data of \(length) bytes exceeds the cap for \(rect)")
                }
                let compressed = try await stream.read(exactly: length)
                let decoder = try zrleDecoder ?? ZRLEDecoder(layout: wireLayout)
                zrleDecoder = decoder
                let clock = ContinuousClock.now
                try decoder.decode(rect: rect, compressed: compressed, into: &framebuffer)
                statistics.decodeTime += ContinuousClock.now - clock
                statistics.payloadBytes[.zrle, default: 0] += length + 4
                statistics.zrleInflatedBytes += rect.width * rect.height * 3 // estimated from a 3-byte CPIXEL
                dirty.append(rect)

            case .copyRect:
                let sourceX = Int(try await stream.readUInt16())
                let sourceY = Int(try await stream.readUInt16())
                let source = PixelRect(x: sourceX, y: sourceY, width: rect.width, height: rect.height)
                try framebuffer.copy(from: source, toX: rect.x, y: rect.y)
                statistics.payloadBytes[.copyRect, default: 0] += 4
                dirty.append(rect)

            case .cursor:
                cursor = try await readCursor(hotspotX: rect.x, hotspotY: rect.y, width: rect.width, height: rect.height)

            case .desktopSize:
                // Pseudo-rect: rect.width/height are the new size. The old content is discarded.
                framebuffer = try Framebuffer(width: rect.width, height: rect.height)
                dirty.append(framebuffer.bounds)
                resized = true

            case .lastRect:
                return .framebufferUpdate(dirty: dirty, cursor: cursor)

            default:
                throw RFBError.unsupportedEncoding(encoding)
            }
        }
        return .framebufferUpdate(dirty: dirty, cursor: cursor)
    }

    private func readCursor(hotspotX: Int, hotspotY: Int, width: Int, height: Int) async throws -> CursorImage {
        guard width > 0, height > 0 else { return .empty }
        guard width <= CursorImage.maxDimension, height <= CursorImage.maxDimension else {
            throw RFBError.malformed("cursor \(width)x\(height) is too large")
        }
        // RFC 6143 7.8.1: cursor pixels are in the CLIENT'S FORMAT (2 bytes at 16 bit), not always 4 bytes. Reading the wrong size shifts
        // the stream and drops the session when the cursor changes shape. (The app does not request a separate cursor at 16 bit; this is for correctness with other servers.)
        let raw = try await stream.read(exactly: width * height * wireLayout.bytesPerPixel)
        let mask = try await stream.read(exactly: ((width + 7) / 8) * height)
        let pixels = wireLayout == .bgra8888 ? raw : PixelConversion.bgra(fromRGB565Bytes: raw)
        return try CursorImage(width: width, height: height, hotspotX: hotspotX, hotspotY: hotspotY, pixels: pixels, mask: mask)
    }

    // MARK: - Other messages

    private func readColourMap() async throws -> ServerEvent {
        _ = try await stream.readUInt8() // padding
        _ = try await stream.readUInt16() // first color
        let count = Int(try await stream.readUInt16())
        _ = try await stream.read(exactly: count * 6) // each color has 3 components × 2 bytes
        return .colourMapIgnored
    }

    private func readCutText() async throws -> ServerEvent {
        _ = try await stream.read(exactly: 3) // padding
        let length = Int(try await stream.readUInt32())
        guard length <= Self.maxCutTextLength else {
            // The length is known so it can be discarded: a clipboard that is too large is not worth dropping the whole session.
            try await discard(length)
            return .clipboardSkipped(bytes: length)
        }
        let bytes = try await stream.read(exactly: length)
        return .serverCutText(String(data: bytes, encoding: .isoLatin1) ?? "")
    }

    private func readClipboardTransfer() async throws -> ServerEvent {
        let header = try await stream.read(exactly: 15)
        let token = header.subdata(in: 3..<7).reduce(0) { ($0 << 8) | UInt32($1) }
        let uncompressed = header.subdata(in: 7..<11).reduce(0) { ($0 << 8) | UInt32($1) }
        let compressedSize = header.subdata(in: 11..<15).reduce(0) { ($0 << 8) | UInt32($1) }
        guard compressedSize <= UInt32(ClipboardTransfer.maxCompressed), uncompressed <= UInt32(ClipboardTransfer.maxUncompressed) else {
            // For example ⌘C on a large image on the Mac. Skip the data (without decompressing) instead of dropping the session.
            try await discard(Int(compressedSize))
            return .clipboardSkipped(bytes: Int(uncompressed))
        }
        let compressed = try await stream.read(exactly: Int(compressedSize))
        return .clipboard(ClipboardTransfer(token: token, flags: header[1], uncompressedSize: uncompressed, compressed: compressed))
    }

    /// Cap on discarding: anything larger is treated as a broken server (discarding several GB would also cost minutes of network).
    static let maxDiscard = 256 << 20

    /// Reads and discards `count` bytes in chunks, without holding them in memory.
    private func discard(_ count: Int) async throws {
        guard count <= Self.maxDiscard else { throw RFBError.malformed("message of \(count) bytes exceeds the discard cap") }
        var left = count
        while left > 0 {
            let chunk = min(left, 1 << 20)
            _ = try await stream.read(exactly: chunk)
            left -= chunk
        }
    }

    /// Closes the session. Messages already posted (typically key and button releases sent just before) still go out first, for at most
    /// `flushTimeout`, so the Mac is not left with a stuck modifier; a write that cannot finish is cut short by closing the stream.
    public func close() async {
        outbound.close()
        let stream = self.stream
        let deadline = Task {
            guard (try? await Task.sleep(for: Self.flushTimeout)) != nil else { return }
            await stream.close() // unblocks a write stuck on a dead network
        }
        await writer.value
        deadline.cancel()
        await stream.close()
    }

    static let flushTimeout = Duration.milliseconds(500)
}
