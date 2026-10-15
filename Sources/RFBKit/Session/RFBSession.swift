import Foundation

/// Việc server vừa báo cho client.
public enum ServerEvent: Equatable, Sendable {
    /// Framebuffer đã được cập nhật ở các vùng này. `cursor` có giá trị khi server gửi kèm hình con trỏ mới.
    case framebufferUpdate(dirty: [PixelRect], cursor: CursorImage? = nil)
    case bell
    case serverCutText(String)
    /// Clipboard của Mac theo giao thức riêng của Apple (trả lời `clipboardRequest`).
    case clipboard(ClipboardTransfer)
    /// Bảng màu server gửi. Ta luôn dùng true colour nên bỏ qua, nhưng vẫn phải đọc hết dữ liệu.
    case colourMapIgnored
    /// Clipboard của Mac lớn hơn trần nên đã bị đọc bỏ (không làm rớt phiên). `bytes` là dung lượng server khai.
    case clipboardSkipped(bytes: Int)
}

/// Loại server, quyết định giao thức clipboard dùng được.
public enum ServerFlavor: Sendable, Equatable {
    /// RFB chuẩn: `ClientCutText` / `ServerCutText`, văn bản Latin-1.
    case standard
    /// `screensharingd` của Apple (quảng bá phiên bản `003.889`): clipboard riêng, hỏi-đáp, có UTF-8.
    /// Message `ClientCutText` chuẩn của nó có xử lý nhưng bị bỏ qua trong các phiên đo được, nên không dùng.
    case apple

    public init(serverVersion: RFBVersion) {
        self = (serverVersion == RFBVersion(major: 3, minor: 889)) ? .apple : .standard
    }
}

/// Số liệu nhận được, dùng để đánh giá băng thông và hiệu quả nén.
public struct SessionStatistics: Equatable, Sendable {
    /// Số byte dữ liệu hình ảnh trên đường truyền theo từng encoding (với ZRLE là dung lượng đã nén).
    public var payloadBytes: [RFBEncoding: Int] = [:]
    /// Số byte ZRLE sau khi giải nén, để tính tỉ lệ nén.
    public var zrleInflatedBytes = 0
    public var updateCount = 0
    /// Tổng thời gian CPU giải mã pixel (không tính chờ mạng), để biết giải mã hay mạng là cổ chai.
    public var decodeTime: Duration = .zero
}

/// Phiên RFB sau khi xác thực và `ServerInit`: gửi message, nhận và giải mã cập nhật vào framebuffer.
///
/// Dùng `actor` để framebuffer chỉ bị sửa từ một nơi, và việc giải mã chạy ngoài main thread.
public actor RFBSession {
    /// Bất biến và `Sendable`, nên đọc được từ bên ngoài actor mà không cần `await`.
    public nonisolated let serverInfo: ServerInit
    public nonisolated let flavor: ServerFlavor
    /// Cách xác thực đã dùng để vào phiên này (`nil` nếu phiên được tạo không qua `RFBConnection`). Dùng để cảnh báo người dùng
    /// khi đó là mật khẩu VNC yếu hay không xác thực.
    public nonisolated let securityType: RFBSecurityType?
    /// Khi `true`, session tự xin cập nhật kế tiếp **ngay khi nhận được tiêu đề** của một cập nhật, thay vì chờ giải mã xong rồi
    /// người gọi mới xin. Server chuẩn bị khung kế trong lúc ta nhận và giải mã khung này, nên không còn khoảng chờ nối đuôi
    /// (một vòng mạng cộng thời gian giải mã) giữa hai khung. Người gọi **không** gọi `requestUpdate` nữa.
    public nonisolated let pipelinesUpdateRequests: Bool
    /// Định dạng pixel ta yêu cầu server gửi (`SetPixelFormat`). `framebuffer` luôn là BGRA 8 bit bất kể định dạng này.
    public nonisolated let wireFormat: PixelFormat
    private let wireLayout: WireLayout
    public private(set) var framebuffer: Framebuffer
    public private(set) var statistics = SessionStatistics()

    private let stream: any ByteStream
    /// Hàng đợi gửi theo thứ tự. Mỗi sự kiện chạm hay phím là một lần `post`, và một task duy nhất ghi lần lượt ra luồng,
    /// nên "nhấn" luôn tới Mac trước "nhả" dù người gọi ở luồng nào. Khi mạng nghẽn, task ghi lấy hết những gì đang chờ và
    /// bỏ các lần di chuột thừa (`OutboundCoalescer`) thay vì để chúng dồn lại làm con trỏ trên Mac trễ dần.
    private let outbound = OutboundQueue()
    /// Giải nén ZRLE, tạo khi dùng lần đầu rồi giữ suốt phiên vì luồng zlib liên tục.
    private var zrleDecoder: ZRLEDecoder?

    /// Trần độ dài văn bản clipboard nhận từ server (server của Apple cũng đóng kết nối khi vượt mức hợp lý).
    static let maxCutTextLength = 1 << 20
    /// Trần số byte đọc và cấp phát một lần cho hình chữ nhật Raw.
    static let maxRawBandBytes = 4 << 20

    public init(
        stream: any ByteStream, serverInfo: ServerInit, flavor: ServerFlavor = .standard, pipelinesUpdateRequests: Bool = false,
        pixelFormat: PixelFormat = .bgra8888, securityType: RFBSecurityType? = nil
    ) throws {
        guard let layout = pixelFormat.supportedLayout else {
            throw RFBError.malformed("định dạng pixel \(pixelFormat.bitsPerPixel) bit không được hỗ trợ")
        }
        self.stream = stream
        self.serverInfo = serverInfo
        self.flavor = flavor
        self.securityType = securityType
        self.pipelinesUpdateRequests = pipelinesUpdateRequests
        wireFormat = pixelFormat
        wireLayout = layout
        framebuffer = try Framebuffer(width: Int(serverInfo.width), height: Int(serverInfo.height))

        // Task này chỉ giữ `stream` và hàng đợi, không giữ `self`, nên không kéo dài đời của phiên. Nó kết thúc khi `close()`.
        Task { [stream, outbound] in
            var coalescer = OutboundCoalescer()
            for await _ in outbound.wakeups {
                let batch = coalescer.coalesce(outbound.takeAll())
                guard !batch.isEmpty else { continue }
                let data = batch.reduce(into: Data()) { $0.append($1.wireBytes) }
                do { try await stream.write(data) } catch { break } // luồng đã hỏng: bỏ phần còn lại
            }
        }
    }

    /// Xếp thông điệp vào hàng đợi gửi và trở về ngay (không chờ ghi xong). Gọi được từ bất kỳ luồng nào.
    /// Dùng cho thao tác người dùng (chuột, phím): giữ đúng thứ tự mà không phải tạo `Task` cho từng sự kiện.
    public nonisolated func post(_ messages: [ClientMessage]) {
        guard !messages.isEmpty else { return }
        outbound.append(messages)
    }

    public func send(_ message: ClientMessage) async throws {
        try await stream.write(message.wireBytes)
    }

    /// Đặt định dạng pixel BGRA, khai báo encoding hỗ trợ, rồi xin toàn bộ khung hình đầu tiên.
    /// Gộp ba message vào một lần ghi để tới server trong cùng một gói.
    public func start(encodings: [RFBEncoding]) async throws {
        var data = ClientMessage.setPixelFormat(wireFormat).wireBytes
        data.append(ClientMessage.setEncodings(encodings).wireBytes)
        data.append(ClientMessage.framebufferUpdateRequest(incremental: false, rect: framebuffer.bounds).wireBytes)
        try await stream.write(data)
    }

    /// Giãn cách tối thiểu giữa hai lần xin cập nhật, `nil` là không giới hạn (nhanh nhất có thể). Server chỉ gửi một cập nhật
    /// cho mỗi yêu cầu, nên giãn cách này chính là trần số khung hình mỗi giây; những thay đổi xảy ra trong lúc chờ được gộp vào
    /// cập nhật kế tiếp. Chỉ có tác dụng khi `pipelinesUpdateRequests` bật. Đổi được giữa phiên, có hiệu lực từ yêu cầu kế tiếp.
    public private(set) var minimumUpdateInterval: Duration?
    private var lastUpdateRequest: ContinuousClock.Instant?

    public func setMinimumUpdateInterval(_ interval: Duration?) {
        minimumUpdateInterval = interval
        // Một yêu cầu đang bị hoãn theo nhịp cũ: tính lại hạn theo nhịp mới, gửi ngay nếu đã quá hạn.
        guard let pending = pendingRequest, let last = previousRequest else { return }
        let due = interval.map { last + $0 } ?? last
        guard due < pending.due else { return }
        pending.task.cancel()
        pendingRequest = nil
        lastUpdateRequest = previousRequest
        schedule(at: max(due, ContinuousClock.now))
    }

    /// Yêu cầu đang hoãn (nếu có) và hạn của nó; `previousRequest` là hạn của yêu cầu trước nó, để tính lại khi nhịp đổi.
    private var pendingRequest: (task: Task<Void, Never>, due: ContinuousClock.Instant)?
    private var previousRequest: ContinuousClock.Instant?

    /// Xếp một yêu cầu cập nhật tăng dần vào hàng đợi gửi (giữ đúng thứ tự với chuột/phím), không chờ ghi xong.
    /// Nếu có giãn cách tối thiểu và chưa đủ lâu kể từ yêu cầu trước thì hoãn tới đúng lúc.
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
            do { try await Task.sleep(until: due, clock: .continuous) } catch { return } // bị hủy: đã được lên lịch lại
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

    /// Đọc đúng một message từ server và áp dụng nó.
    public func nextEvent() async throws -> ServerEvent {
        switch try await stream.readUInt8() {
        case 0: return try await readFramebufferUpdate()
        case 1: return try await readColourMap()
        case 2: return .bell
        case 3: return try await readCutText()
        case ClipboardTransfer.messageType: return try await readClipboardTransfer()
        case let type: throw RFBError.malformed("loại message của server không biết: \(type)")
        }
    }

    // MARK: - FramebufferUpdate

    private func readFramebufferUpdate() async throws -> ServerEvent {
        _ = try await stream.readUInt8() // đệm
        let rectCount = Int(try await stream.readUInt16())
        var dirty: [PixelRect] = []
        var cursor: CursorImage?
        statistics.updateCount += 1
        if pipelinesUpdateRequests { postUpdateRequest() }
        var resized = false
        // Xin lại bằng cỡ mới nếu server đổi cỡ màn hình giữa cập nhật: yêu cầu đã gửi ở trên dùng cỡ cũ.
        // Server Apple sau khi đổi cỡ (thu nhỏ phía server) chỉ gửi `DesktopSize` rồi CHỜ: không xin lại toàn bộ thì màn hình
        // đen tới khi có gì đó đổi (đo được với message loại 8). Nên xin lại KHÔNG tăng dần, ở cỡ mới.
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
                    throw RFBError.malformed("hình chữ nhật Raw \(rect) nằm ngoài framebuffer")
                }
                // Đọc theo dải hàng, mỗi dải tối đa `maxRawBandBytes`: kích thước hình chữ nhật do server tự khai, nên đọc một lần
                // cả hình có thể ép ta cấp phát hàng trăm MB (iOS sẽ giết app) chỉ bằng một thông điệp.
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
                    throw RFBError.malformed("hình chữ nhật ZRLE \(rect) nằm ngoài framebuffer")
                }
                let length = Int(try await stream.readUInt32())
                guard length <= ZRLEDecoder.maxCompressedSize(for: rect) else {
                    throw RFBError.malformed("dữ liệu ZRLE \(length) byte vượt trần cho \(rect)")
                }
                let compressed = try await stream.read(exactly: length)
                let decoder = try zrleDecoder ?? ZRLEDecoder(layout: wireLayout)
                zrleDecoder = decoder
                let clock = ContinuousClock.now
                try decoder.decode(rect: rect, compressed: compressed, into: &framebuffer)
                statistics.decodeTime += ContinuousClock.now - clock
                statistics.payloadBytes[.zrle, default: 0] += length + 4
                statistics.zrleInflatedBytes += rect.width * rect.height * 3 // ước lượng theo CPIXEL 3 byte
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
                // Pseudo-rect: rect.width/height chính là kích thước mới. Nội dung cũ bị bỏ.
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
            throw RFBError.malformed("con trỏ \(width)x\(height) quá lớn")
        }
        // RFC 6143 7.8.1: pixel con trỏ theo ĐỊNH DẠNG CỦA CLIENT (2 byte ở 16 bit), không phải luôn 4 byte. Đọc sai cỡ làm lệch
        // luồng và rớt phiên khi con trỏ đổi hình. (App không xin con trỏ riêng ở 16 bit; đây là cho đúng chuẩn với server khác.)
        let raw = try await stream.read(exactly: width * height * wireLayout.bytesPerPixel)
        let mask = try await stream.read(exactly: ((width + 7) / 8) * height)
        let pixels = wireLayout == .bgra8888 ? raw : PixelConversion.bgra(fromRGB565Bytes: raw)
        return try CursorImage(width: width, height: height, hotspotX: hotspotX, hotspotY: hotspotY, pixels: pixels, mask: mask)
    }

    // MARK: - Các message khác

    private func readColourMap() async throws -> ServerEvent {
        _ = try await stream.readUInt8() // đệm
        _ = try await stream.readUInt16() // màu đầu tiên
        let count = Int(try await stream.readUInt16())
        _ = try await stream.read(exactly: count * 6) // mỗi màu 3 thành phần × 2 byte
        return .colourMapIgnored
    }

    private func readCutText() async throws -> ServerEvent {
        _ = try await stream.read(exactly: 3) // đệm
        let length = Int(try await stream.readUInt32())
        guard length <= Self.maxCutTextLength else {
            // Biết độ dài nên đọc bỏ được: clipboard quá lớn không đáng để rớt cả phiên.
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
            // Ví dụ ⌘C một ảnh lớn trên Mac. Bỏ qua dữ liệu (không giải nén) thay vì làm rớt phiên.
            try await discard(Int(compressedSize))
            return .clipboardSkipped(bytes: Int(uncompressed))
        }
        let compressed = try await stream.read(exactly: Int(compressedSize))
        return .clipboard(ClipboardTransfer(token: token, flags: header[1], uncompressedSize: uncompressed, compressed: compressed))
    }

    /// Trần đọc bỏ: lớn hơn thì coi là server hỏng (đọc bỏ hàng GB cũng tốn hàng phút mạng).
    static let maxDiscard = 256 << 20

    /// Đọc và bỏ `count` byte theo từng đoạn, không giữ trong bộ nhớ.
    private func discard(_ count: Int) async throws {
        guard count <= Self.maxDiscard else { throw RFBError.malformed("message \(count) byte vượt trần đọc bỏ") }
        var left = count
        while left > 0 {
            let chunk = min(left, 1 << 20)
            _ = try await stream.read(exactly: chunk)
            left -= chunk
        }
    }

    public func close() async {
        outbound.close()
        await stream.close()
    }
}
