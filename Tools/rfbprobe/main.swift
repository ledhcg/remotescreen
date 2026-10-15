import CoreGraphics
import Foundation
import ImageIO
import RFBKit
import UniformTypeIdentifiers

// rfbprobe: kết nối tới server RFB, in phiên bản và các security type nó cho phép.
// Không xác thực, không gửi mật khẩu.
//
//   rfbprobe [host] [port]                 liệt kê security type
//   rfbprobe [host] [port] --login N [--snapshot FILE.png] [--compare-encodings | --watch GIÂY]
//                                           đăng nhập thật bằng type 2 hoặc 30, đọc RFB_USER/RFB_PASSWORD
//                                           từ biến môi trường rồi in thông tin ServerInit.
//                                           --compare-encodings xin khung hình bằng Raw rồi ZRLE và so từng pixel.
//                                           --watch chạy cập nhật tăng dần ZRLE trong GIÂY giây rồi so với khung Raw tham chiếu
//   rfbprobe [host] [port] --login N --clipboard-probe GIÂY [--send-text TEXT [--send-encoding latin1|utf8|macroman]]
//                                           đăng nhập rồi GIÂY giây đọc thô message của server, in mọi ServerCutText
//                                           (kể cả Extended Clipboard). Chỉ in nội dung khi nó bắt đầu bằng "rfbprobe-marker",
//                                           để không lộ clipboard thật của người dùng. --send-text gửi một ClientCutText.
//   rfbprobe [host] [port] --select N [--send-hex HEX]
//                                           chọn type N, tùy chọn gửi thêm byte thô, rồi in hex dump những byte
//                                           đầu tiên server gửi lại (khám phá giao thức)

enum ProbeError: Error { case timeout }

/// Chạy `operation` với giới hạn thời gian. Khi hết giờ phải đóng stream trước,
/// vì đọc qua NWConnection không tự hủy theo `Task` và group sẽ chờ mãi.
func withTimeout<T: Sendable>(
    seconds: Double,
    onTimeout: @escaping @Sendable () async -> Void,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            await onTimeout()
            throw ProbeError.timeout
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw ProbeError.timeout }
        return result
    }
}

func hexDump(_ data: Data) -> String {
    stride(from: 0, to: data.count, by: 16).map { offset in
        let row = data.dropFirst(offset).prefix(16)
        let hex = row.map { String(format: "%02x", $0) }.joined(separator: " ")
        let ascii = String(row.map { (0x20..<0x7f).contains($0) ? Character(UnicodeScalar($0)) : "." })
        return String(format: "  %04x  ", offset) + hex.padding(toLength: 47, withPad: " ", startingAt: 0) + "  " + ascii
    }.joined(separator: "\n")
}

func writePNG(_ image: CGImage, to path: String) throws {
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

/// Mở một kết nối mới và đăng nhập tới hết `ServerInit`. Dùng cho kết nối tham chiếu thứ hai.
func connectAndLogin(
    host: String, port: UInt16, type: RFBSecurityType, credentials: RFBCredentials
) async throws -> (NWByteStream, ServerInit) {
    let stream = NWByteStream(host: host, port: port)
    let info = try await withTimeout(seconds: 30, onTimeout: { await stream.close() }) {
        try await stream.connect()
        let hello = try await Handshake.readServerHello(over: stream)
        try await Handshake.selectSecurityType(type, over: stream)
        try await Authenticator.authenticate(type: type, version: hello.negotiatedVersion, credentials: credentials, over: stream)
        return try await Handshake.performInit(shared: true, over: stream)
    }
    return (stream, info)
}

/// Bọc một `ByteStream` và ghi nguyên văn mọi byte ĐỌC được (server → client) ra file.
/// Dùng để kiểm chứng giải mã ngoại tuyến bằng một bộ giải mã độc lập. File chứa nội dung màn hình.
actor RecordingByteStream: ByteStream {
    private let base: any ByteStream
    private let handle: FileHandle
    private(set) var recordedBytes = 0

    init(base: any ByteStream, path: String) throws {
        guard FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        self.base = base
    }

    func read(exactly count: Int) async throws -> Data {
        let data = try await base.read(exactly: count)
        try record(data)
        return data
    }

    func readSome(maxCount: Int) async throws -> Data {
        let data = try await base.readSome(maxCount: maxCount)
        try record(data)
        return data
    }

    func write(_ data: Data) async throws {
        try await base.write(data)
    }

    func close() async {
        try? handle.close()
        await base.close()
    }

    private func record(_ data: Data) throws {
        try handle.write(contentsOf: data)
        recordedBytes += data.count
    }
}

/// Phát lại một đoạn byte server đã ghi bằng `--record`, để đo thời gian giải mã thuần (không có mạng).
actor ReplayByteStream: ByteStream {
    private let data: Data
    private var position = 0

    init(data: Data) { self.data = data }

    func read(exactly count: Int) async throws -> Data {
        guard position + count <= data.count else { throw RFBError.connectionClosed }
        defer { position += count }
        return data.subdata(in: (data.startIndex + position)..<(data.startIndex + position + count))
    }

    func readSome(maxCount: Int) async throws -> Data {
        guard position < data.count else { throw RFBError.connectionClosed }
        return try await read(exactly: min(maxCount, data.count - position))
    }

    func write(_ data: Data) async throws {}
    func close() async {}
}

/// Giải mã lại toàn bộ đoạn đã ghi và in thời gian: tổng, mỗi cập nhật, và thông lượng.
func runReplay(path: String, width: Int, height: Int, format: PixelFormat) async {
    guard let data = FileManager.default.contents(atPath: path) else { fail("Không đọc được \(path)", code: 66) }
    do {
        let session = try RFBSession(stream: ReplayByteStream(data: data), serverInfo: ServerInit(width: UInt16(width), height: UInt16(height)), pixelFormat: format)
        var durations: [Double] = []
        var updates = 0
        var pixels = 0
        let started = ContinuousClock.now
        while true {
            let t0 = ContinuousClock.now
            let event: ServerEvent
            do { event = try await session.nextEvent() } catch RFBError.connectionClosed { break }
            let elapsed = ContinuousClock.now - t0
            if case .framebufferUpdate(let dirty, _) = event {
                updates += 1
                pixels += dirty.reduce(0) { $0 + $1.width * $1.height }
                durations.append(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
            }
        }
        let total = ContinuousClock.now - started
        let seconds = Double(total.components.seconds) + Double(total.components.attoseconds) / 1e18
        let sorted = durations.sorted()
        func percentile(_ p: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
        let stats = await session.statistics
        let wire = stats.payloadBytes.values.reduce(0, +)
        // FNV-1a của khung hình cuối: hai bản bộ giải mã phải cho cùng một giá trị trên cùng đoạn ghi.
        let finalPixels = await session.framebuffer.pixels
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in finalPixels { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        print(String(format: "Băm khung hình cuối (FNV-1a): %016llx", hash))
        print(String(format: "Tệp: %.1f MiB, %d cập nhật, %.1f triệu pixel (màn hình %dx%d)", Double(data.count) / 1_048_576, updates, Double(pixels) / 1e6, width, height))
        print(String(format: "Giải mã tổng: %.2f s  |  mỗi cập nhật: trung vị %.2f ms, p95 %.2f ms, lớn nhất %.2f ms", seconds, percentile(0.5), percentile(0.95), sorted.last ?? 0))
        print(String(format: "Thông lượng: %.1f triệu pixel/s, %.1f MiB dữ liệu nén/s, tương đương %.0f cập nhật/s", Double(pixels) / 1e6 / seconds, Double(wire) / 1_048_576 / seconds, Double(updates) / seconds))
    } catch {
        fail("Lỗi phát lại: \(error)", code: 3)
    }
}

/// Hỏi server từng cấu hình (định dạng pixel + danh sách encoding) và in ra encoding mà nó thật sự dùng cho hình chữ nhật đầu
/// tiên. Chỉ ĐỌC: không gửi chuột hay phím. Mỗi cấu hình dùng một kết nối riêng để trạng thái không dính sang nhau.
func runEncodingProbe(host: String, port: UInt16, type: RFBSecurityType, credentials: RFBCredentials) async {
    let rgb565 = PixelFormat(bitsPerPixel: 16, depth: 16, isBigEndian: false, isTrueColour: true,
                             redMax: 31, greenMax: 63, blueMax: 31, redShift: 11, greenShift: 5, blueShift: 0)
    let bgr233 = PixelFormat(bitsPerPixel: 8, depth: 8, isBigEndian: false, isTrueColour: true,
                             redMax: 7, greenMax: 7, blueMax: 3, redShift: 0, greenShift: 3, blueShift: 6)
    func enc(_ values: Int32...) -> [RFBEncoding] { values.map { RFBEncoding(rawValue: $0) } }
    // Pseudo-encoding Tight: mức chất lượng JPEG 0...9 là -32...-23, mức nén -256...-247.
    let cases: [(String, PixelFormat, [RFBEncoding])] = [
        ("đối chứng: ZRLE, 32 bit", .bgra8888, enc(16, 1, -239)),
        ("Tight + JPEG chất lượng 5", .bgra8888, enc(7, -27, -253, 16, 1, -239)),
        ("Hextile", .bgra8888, enc(5, 1, -239)),
        ("Zlib", .bgra8888, enc(6, 1, -239)),
        ("RRE", .bgra8888, enc(2, 1, -239)),
        ("Raw, 16 bit RGB565", rgb565, enc(0, -239)),
        ("Raw, 8 bit BGR233", bgr233, enc(0, -239)),
        ("ZRLE, 16 bit RGB565", rgb565, enc(16, 1, -239)),
    ]
    for (label, format, encodings) in cases {
        do {
            let (stream, info) = try await connectAndLogin(host: host, port: port, type: type, credentials: credentials)
            defer { Task { await stream.close() } }
            var request = ClientMessage.setPixelFormat(format).wireBytes
            request.append(ClientMessage.setEncodings(encodings).wireBytes)
            request.append(ClientMessage.framebufferUpdateRequest(
                incremental: false, rect: PixelRect(x: 0, y: 0, width: Int(info.width), height: Int(info.height))
            ).wireBytes)
            try await stream.write(request)

            let header = try await withTimeout(seconds: 15, onTimeout: { await stream.close() }) { try await stream.read(exactly: 4) }
            guard header[0] == 0 else { print("  \(label): message loại \(header[0]) thay vì FramebufferUpdate"); continue }
            let rects = Int(header[2]) << 8 | Int(header[3])
            let rectHeader = try await withTimeout(seconds: 15, onTimeout: { await stream.close() }) { try await stream.read(exactly: 12) }
            func u16(_ at: Int) -> Int { Int(rectHeader[at]) << 8 | Int(rectHeader[at + 1]) }
            let encoding = Int32(bitPattern: rectHeader.subdata(in: 8..<12).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
            var line = "  \(label): \(rects) hình chữ nhật, đầu tiên \(u16(4))x\(u16(6)) tại (\(u16(0)),\(u16(2))), encoding \(RFBEncoding(rawValue: encoding))"

            if encoding == 0, rects == 1 {
                // Raw một hình chữ nhật: kiểm tra server có tôn trọng định dạng pixel không bằng cách đếm byte còn dư.
                let expected = u16(4) * u16(6) * Int(format.bitsPerPixel) / 8
                _ = try await withTimeout(seconds: 30, onTimeout: { await stream.close() }) { try await stream.read(exactly: expected) }
                let extra = try? await withTimeout(seconds: 1.5, onTimeout: { await stream.close() }) { try await stream.readSome(maxCount: 64) }
                line += (extra?.isEmpty == false) ? "  → CÒN DƯ BYTE: server KHÔNG theo \(format.bitsPerPixel) bit" : "  → khớp \(format.bitsPerPixel) bit/pixel (\(expected / 1024) KiB)"
            }
            print(line)
        } catch {
            print("  \(label): lỗi \(error)")
        }
    }
}

/// Danh sách byte do một vòng đọc duy nhất ghi.
final class ByteLog: @unchecked Sendable {
    var items: [UInt8] = []
}

/// Chuỗi kết luận do một vòng đọc duy nhất ghi.
final class TextBox: @unchecked Sendable {
    var text: String
    init(_ text: String) { self.text = text }
}

/// Bộ đếm một người ghi (vòng đọc duy nhất), nên không cần khóa.
final class WireCounters: @unchecked Sendable {
    var updates = 0, bytes = 0, pixels = 0
}

/// Đo số byte server gửi trong `seconds` giây cho một cấu hình, KHÔNG giải mã: chỉ đọc độ dài. Hỗ trợ ZRLE và CopyRect/Cursor.
/// Chạy hai cấu hình **song song** để cùng một nội dung màn hình.
func measureWire(
    host: String, port: UInt16, type: RFBSecurityType, credentials: RFBCredentials, format: PixelFormat, seconds: Double
) async -> (updates: Int, bytes: Int, pixels: Int) {
    do {
        let (stream, info) = try await connectAndLogin(host: host, port: port, type: type, credentials: credentials)
        let full = PixelRect(x: 0, y: 0, width: Int(info.width), height: Int(info.height))
        var first = ClientMessage.setPixelFormat(format).wireBytes
        first.append(ClientMessage.setEncodings([.zrle, .copyRect, .cursor]).wireBytes)
        first.append(ClientMessage.framebufferUpdateRequest(incremental: false, rect: full).wireBytes)
        try await stream.write(first)

        let counters = WireCounters()
        let started = ContinuousClock.now
        do {
            try await withTimeout(seconds: seconds, onTimeout: { await stream.close() }) {
                while true {
                    let header = try await stream.read(exactly: 4)
                    guard header[0] == 0 else { throw RFBError.malformed("message \(header[0])") }
                    let rects = Int(header[2]) << 8 | Int(header[3])
                    counters.updates += 1
                    counters.bytes += 4
                    try await stream.write(ClientMessage.framebufferUpdateRequest(incremental: true, rect: full).wireBytes)
                    for _ in 0..<rects {
                        let r = try await stream.read(exactly: 12)
                        let w = Int(r[4]) << 8 | Int(r[5]), h = Int(r[6]) << 8 | Int(r[7])
                        let encoding = Int32(bitPattern: r.subdata(in: 8..<12).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
                        counters.bytes += 12
                        switch encoding {
                        case 16:
                            let length = Int(beUInt32(try await stream.read(exactly: 4)))
                            _ = try await stream.read(exactly: length)
                            counters.bytes += 4 + length
                            counters.pixels += w * h
                        case 1: _ = try await stream.read(exactly: 4); counters.bytes += 4
                        case -239: // con trỏ
                            let n = w * h * Int(format.bitsPerPixel) / 8 + ((w + 7) / 8) * h
                            _ = try await stream.read(exactly: n); counters.bytes += n
                        default: throw RFBError.malformed("encoding \(encoding)")
                        }
                    }
                }
            }
        } catch {
            if ContinuousClock.now - started < .seconds(seconds) - .milliseconds(500) { print("  lỗi giữa chừng: \(error)") }
        }
        return (counters.updates, counters.bytes, counters.pixels)
    } catch {
        print("  lỗi kết nối: \(error)")
        return (0, 0, 0)
    }
}

/// So băng thông 32 bit với 16 bit trên cùng nội dung: hai kết nối chạy song song.
func runDepthComparison(host: String, port: UInt16, type: RFBSecurityType, credentials: RFBCredentials, seconds: Double) async {
    let rgb565 = PixelFormat(bitsPerPixel: 16, depth: 16, isBigEndian: false, isTrueColour: true,
                             redMax: 31, greenMax: 63, blueMax: 31, redShift: 11, greenShift: 5, blueShift: 0)
    async let a = measureWire(host: host, port: port, type: type, credentials: credentials, format: .bgra8888, seconds: seconds)
    async let b = measureWire(host: host, port: port, type: type, credentials: credentials, format: rgb565, seconds: seconds)
    let (full, low) = await (a, b)
    func line(_ name: String, _ r: (updates: Int, bytes: Int, pixels: Int)) {
        print(String(format: "  %@: %d cập nhật, %.1f MiB, %.1f Mbit/s, %.1f triệu pixel",
                     name, r.updates, Double(r.bytes) / 1_048_576, Double(r.bytes) * 8 / 1e6 / seconds, Double(r.pixels) / 1e6))
    }
    line("32 bit", full)
    line("16 bit", low)
    if full.bytes > 0 { print(String(format: "  16 bit dùng %.0f%% số byte của 32 bit", Double(low.bytes) / Double(full.bytes) * 100)) }
}

/// Chụp đồng thời ba khung: hai khung 32 bit (A, B: đo độ trôi của nội dung giữa hai lần chụp) và một khung 16 bit (C).
/// 16 bit đúng khi C khác A không nhiều hơn mức A khác B, và sai số mỗi kênh nằm trong mức lượng tử hóa 5-6 bit.
func runDepthImageCheck(host: String, port: UInt16, type: RFBSecurityType, credentials: RFBCredentials) async {
    do {
        func open(_ format: PixelFormat) async throws -> (RFBSession, NWByteStream) {
            let (stream, info) = try await connectAndLogin(host: host, port: port, type: type, credentials: credentials)
            return (try RFBSession(stream: stream, serverInfo: info, pixelFormat: format), stream)
        }
        let (a, streamA) = try await open(.bgra8888)
        let (b, streamB) = try await open(.bgra8888)
        let (c, streamC) = try await open(.rgb565)
        async let fa = captureFullFrame(a, stream: streamA, encodings: [.zrle, .copyRect, .cursor], isFirst: true)
        async let fb = captureFullFrame(b, stream: streamB, encodings: [.zrle, .copyRect, .cursor], isFirst: true)
        async let fc = captureFullFrame(c, stream: streamC, encodings: [.zrle, .copyRect, .cursor], isFirst: true)
        let (captureA, captureB, captureC) = try await (fa, fb, fc)
        let frameA = await a.framebuffer, frameB = await b.framebuffer, frameC = await c.framebuffer
        for stream in [streamA, streamB, streamC] { await stream.close() }

        func compare(_ x: Framebuffer, _ y: Framebuffer, tolerance: Int) -> (within: Double, mean: Double, worst: Int) {
            var within = 0, total = 0, sum = 0, worst = 0
            x.pixels.withUnsafeBytes { p in
                y.pixels.withUnsafeBytes { q in
                    for i in stride(from: 0, to: p.count, by: 4) {
                        let d = max(abs(Int(p[i]) - Int(q[i])), abs(Int(p[i + 1]) - Int(q[i + 1])), abs(Int(p[i + 2]) - Int(q[i + 2])))
                        total += 1; sum += d; worst = max(worst, d)
                        if d <= tolerance { within += 1 }
                    }
                }
            }
            return (Double(within) / Double(total), Double(sum) / Double(total), worst)
        }
        let drift = compare(frameA, frameB, tolerance: 0)
        let ab = compare(frameA, frameB, tolerance: 8)
        let ac = compare(frameA, frameC, tolerance: 8)
        print(String(format: "  Dung lượng khung đầy đủ: 32 bit %d KiB, 16 bit %d KiB (%.0f%%)",
                     captureA.wireBytes / 1024, captureC.wireBytes / 1024, Double(captureC.wireBytes) / Double(max(captureA.wireBytes, 1)) * 100))
        _ = captureB
        print(String(format: "  A so B (cùng 32 bit, đo độ trôi nội dung): giống hệt %.2f%%, trong ±8 là %.2f%%", drift.within * 100, ab.within * 100))
        print(String(format: "  A so C (32 bit so 16 bit): trong ±8 là %.2f%%, sai số trung bình %.2f, lớn nhất %d", ac.within * 100, ac.mean, ac.worst))
        print(ac.within >= ab.within - 0.02 ? "  KẾT LUẬN: 16 bit khớp 32 bit trong mức lượng tử hóa (không kém hơn độ trôi nội dung)" : "  KẾT LUẬN: 16 bit LỆCH nhiều hơn độ trôi nội dung, cần xem lại")
    } catch {
        print("  lỗi: \(error)")
    }
}

/// Hỏi server có hỗ trợ ExtendedDesktopSize (-308) không, và nó báo những màn hình nào. CHỈ ĐỌC: không gửi SetDesktopSize.
func runDesktopSizeProbe(host: String, port: UInt16, type: RFBSecurityType, credentials: RFBCredentials) async {
    do {
        let (stream, info) = try await connectAndLogin(host: host, port: port, type: type, credentials: credentials)
        print("  ServerInit: \(info.width)x\(info.height)")
        var request = ClientMessage.setPixelFormat(.bgra8888).wireBytes
        request.append(ClientMessage.setEncodings([.zrle, .extendedDesktopSize, .desktopSize, .lastRect]).wireBytes)
        request.append(ClientMessage.framebufferUpdateRequest(
            incremental: false, rect: PixelRect(x: 0, y: 0, width: Int(info.width), height: Int(info.height))
        ).wireBytes)
        try await stream.write(request)
        try await withTimeout(seconds: 20, onTimeout: { await stream.close() }) {
            let header = try await stream.read(exactly: 4)
            guard header[0] == 0 else { print("  message loại \(header[0])"); return }
            let rects = Int(header[2]) << 8 | Int(header[3])
            print("  Cập nhật đầu: \(rects) hình chữ nhật")
            for index in 0..<rects {
                let r = try await stream.read(exactly: 12)
                func u16(_ at: Int) -> Int { Int(r[at]) << 8 | Int(r[at + 1]) }
                let encoding = Int32(bitPattern: r.subdata(in: 8..<12).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
                print("   [\(index)] \(RFBEncoding(rawValue: encoding)) (\(encoding)) x=\(u16(0)) y=\(u16(2)) w=\(u16(4)) h=\(u16(6))")
                switch encoding {
                case -308:
                    let head = try await stream.read(exactly: 4)
                    let screens = Int(head[0])
                    for _ in 0..<screens {
                        let sc = try await stream.read(exactly: 16)
                        func v16(_ at: Int) -> Int { Int(sc[at]) << 8 | Int(sc[at + 1]) }
                        let id = sc.subdata(in: 0..<4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                        print("       màn hình id=\(id) x=\(v16(4)) y=\(v16(6)) w=\(v16(8)) h=\(v16(10))")
                    }
                case -223, -224: break
                case 16:
                    let length = Int(beUInt32(try await stream.read(exactly: 4)))
                    _ = try await stream.read(exactly: length)
                default:
                    print("   (dừng: không đọc tiếp được encoding này)"); return
                }
            }
        }
        await stream.close()
    } catch {
        print("  lỗi: \(error)")
    }
}

/// Server gửi hình con trỏ (-239) ở mấy byte mỗi pixel khi client xin 16 bit? RFC nói theo định dạng client (2 byte); kiểm thật.
/// Đọc phần pixel theo giả thuyết 2 byte rồi xem luồng còn dư không. CHỈ ĐỌC.
func runCursorFormatProbe(host: String, port: UInt16, type: RFBSecurityType, credentials: RFBCredentials) async {
    for format in [PixelFormat.bgra8888, .rgb565] {
        let bpp = Int(format.bitsPerPixel) / 8
        do {
            let (stream, info) = try await connectAndLogin(host: host, port: port, type: type, credentials: credentials)
            var request = ClientMessage.setPixelFormat(format).wireBytes
            request.append(ClientMessage.setEncodings([.zrle, .cursor]).wireBytes)
            request.append(ClientMessage.framebufferUpdateRequest(
                incremental: false, rect: PixelRect(x: 0, y: 0, width: Int(info.width), height: Int(info.height))
            ).wireBytes)
            try await stream.write(request)
            let verdict = TextBox("không thấy hình con trỏ trong 200 cập nhật đầu")
            try await withTimeout(seconds: 20, onTimeout: { await stream.close() }) {
                for _ in 0..<200 {
                    let header = try await stream.read(exactly: 4)
                    guard header[0] == 0 else { verdict.text = "message loại \(header[0])"; return }
                    let rects = Int(header[2]) << 8 | Int(header[3])
                    for index in 0..<rects {
                        let r = try await stream.read(exactly: 12)
                        let w = Int(r[4]) << 8 | Int(r[5]), h = Int(r[6]) << 8 | Int(r[7])
                        let encoding = Int32(bitPattern: r.subdata(in: 8..<12).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
                        if encoding == 16 {
                            let length = Int(beUInt32(try await stream.read(exactly: 4)))
                            _ = try await stream.read(exactly: length)
                        } else if encoding == -239 {
                            _ = try await stream.read(exactly: w * h * bpp + ((w + 7) / 8) * h)
                            let isLast = index == rects - 1
                            if isLast {
                                let extra = try? await withTimeout(seconds: 1.5, onTimeout: { await stream.close() }) { try await stream.readSome(maxCount: 1 << 20) }
                                let n = extra?.count ?? 0
                                verdict.text = "con trỏ \(w)x\(h): đọc \(bpp) byte/pixel thì " + (n == 0 ? "KHÔNG dư byte → server gửi \(bpp) byte/pixel"
                                    : "DƯ \(n) byte (≈ \(w * h * (4 - bpp)) nếu server gửi 4 byte/pixel)")
                            } else {
                                let next = try await stream.read(exactly: 12)
                                let nw = Int(next[4]) << 8 | Int(next[5]), nx = Int(next[0]) << 8 | Int(next[1])
                                let plausible = nx + nw <= Int(info.width) && nw > 0
                                verdict.text = "con trỏ \(w)x\(h): sau khi đọc \(bpp) byte/pixel, tiêu đề kế tiếp " + (plausible ? "hợp lệ" : "VÔ NGHĨA (lệch luồng)")
                            }
                            return
                        } else { verdict.text = "encoding \(encoding) chưa xử lý trong bộ dò"; return }
                    }
                    try await stream.write(ClientMessage.framebufferUpdateRequest(
                        incremental: true, rect: PixelRect(x: 0, y: 0, width: Int(info.width), height: Int(info.height))
                    ).wireBytes)
                }
            }
            print("  \(format.bitsPerPixel) bit: \(verdict.text)")
            await stream.close()
        } catch {
            print("  \(format.bitsPerPixel) bit: lỗi \(error)")
        }
    }
}

/// Message riêng của Apple loại 8 (HandleSetServerScalingMessage): [8][0][double big-endian], tỉ lệ trong (0, 1].
/// Server thu nhỏ hình cho riêng người xem này (không đổi màn hình Mac). Xem server báo cỡ mới bằng cách nào.
func runServerScalingProbe(host: String, port: UInt16, type: RFBSecurityType, credentials: RFBCredentials, scale: Double) async {
    do {
        let (stream, info) = try await connectAndLogin(host: host, port: port, type: type, credentials: credentials)
        print("  ServerInit: \(info.width)x\(info.height); xin tỉ lệ \(scale)")
        var scaling = Data([8, 0])
        withUnsafeBytes(of: scale.bitPattern.bigEndian) { scaling.append(contentsOf: $0) }
        var request = ClientMessage.setPixelFormat(.bgra8888).wireBytes
        request.append(ClientMessage.setEncodings([.zrle, .desktopSize, .extendedDesktopSize, .lastRect]).wireBytes)
        request.append(scaling)
        request.append(ClientMessage.framebufferUpdateRequest(
            incremental: false, rect: PixelRect(x: 0, y: 0, width: Int(info.width), height: Int(info.height))
        ).wireBytes)
        try await stream.write(request)
        try await withTimeout(seconds: 15, onTimeout: { await stream.close() }) {
            for update in 0..<4 {
                let header = try await stream.read(exactly: 4)
                guard header[0] == 0 else { print("  message loại \(header[0]), dừng"); return }
                let rects = Int(header[2]) << 8 | Int(header[3])
                var line = "  cập nhật \(update): \(rects) hình chữ nhật:"
                var maxX = 0, maxY = 0
                for _ in 0..<rects {
                    let r = try await stream.read(exactly: 12)
                    func u16(_ at: Int) -> Int { Int(r[at]) << 8 | Int(r[at + 1]) }
                    let encoding = Int32(bitPattern: r.subdata(in: 8..<12).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
                    maxX = max(maxX, u16(0) + u16(4)); maxY = max(maxY, u16(2) + u16(6))
                    switch encoding {
                    case 16:
                        let length = Int(beUInt32(try await stream.read(exactly: 4)))
                        _ = try await stream.read(exactly: length)
                        if rects <= 3 { line += " ZRLE \(u16(4))x\(u16(6))@(\(u16(0)),\(u16(2)))" }
                    case -223: line += " DesktopSize→\(u16(4))x\(u16(6))"
                    case -308:
                        let head = try await stream.read(exactly: 4)
                        _ = try await stream.read(exactly: Int(head[0]) * 16)
                        line += " ExtendedDesktopSize→\(u16(4))x\(u16(6))"
                    case -224: line += " LastRect"
                    default: line += " encoding \(encoding) (dừng)"; print(line); return
                    }
                }
                print(line + "  | phạm vi phủ tới \(maxX)x\(maxY)")
                try await stream.write(ClientMessage.framebufferUpdateRequest(
                    incremental: true, rect: PixelRect(x: 0, y: 0, width: Int(info.width), height: Int(info.height))
                ).wireBytes)
            }
        }
        await stream.close()
    } catch {
        print("  lỗi: \(error)")
    }
}

/// ContinuousUpdates (pseudo-encoding -313): server hỗ trợ thì gửi ngay một message EndOfContinuousUpdates (loại 150) sau
/// SetEncodings. CHỈ ĐỌC: không bật chế độ đó, chỉ xem server có báo hỗ trợ không.
func runContinuousUpdatesProbe(host: String, port: UInt16, type: RFBSecurityType, credentials: RFBCredentials) async {
    do {
        let (stream, info) = try await connectAndLogin(host: host, port: port, type: type, credentials: credentials)
        var request = ClientMessage.setPixelFormat(.bgra8888).wireBytes
        request.append(ClientMessage.setEncodings([.zrle, RFBEncoding(rawValue: -313), RFBEncoding(rawValue: -224)]).wireBytes)
        request.append(ClientMessage.framebufferUpdateRequest(
            incremental: false, rect: PixelRect(x: 0, y: 0, width: Int(info.width), height: Int(info.height))
        ).wireBytes)
        try await stream.write(request)
        let seen = ByteLog()
        do {
            try await withTimeout(seconds: 6, onTimeout: { await stream.close() }) {
                while true {
                    let kind = try await stream.read(exactly: 1)[0]
                    seen.items.append(kind)
                    switch kind {
                    case 150: return // EndOfContinuousUpdates: không có thân
                    case 0:
                        let head = try await stream.read(exactly: 3)
                        let rects = Int(head[1]) << 8 | Int(head[2])
                        for _ in 0..<rects {
                            let r = try await stream.read(exactly: 12)
                            let encoding = Int32(bitPattern: r.subdata(in: 8..<12).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
                            if encoding == 16 { _ = try await stream.read(exactly: Int(beUInt32(try await stream.read(exactly: 4)))) }
                        }
                    default: return
                    }
                }
            }
        } catch {}
        print("  message server gửi (loại): \(seen.items.prefix(20))")
        print(seen.items.contains(150) ? "  → CÓ hỗ trợ ContinuousUpdates (đã nhận loại 150)" : "  → KHÔNG thấy loại 150: server không báo hỗ trợ ContinuousUpdates")
        await stream.close()
    } catch {
        print("  lỗi: \(error)")
    }
}

/// THAO TÁC THẬT TRÊN MAC: đưa con trỏ tới (x, y) rồi gửi qua message 23 một lượt cuộn trackpad (có pha và quán tính), một lượt
/// chụm và một lượt xoay. Chỉ chạy khi chủ máy cho phép, với một cửa sổ thử đặt sẵn ở đó. Cuối cùng xin một cập nhật 1x1 để biết
/// server còn giữ kết nối (server đóng kết nối nếu payload sai cỡ).
func runAppleGestureTest(host: String, port: UInt16, type: RFBSecurityType, credentials: RFBCredentials, x: UInt16, y: UInt16) async {
    do {
        let (stream, _) = try await connectAndLogin(host: host, port: port, type: type, credentials: credentials)
        func send(_ message: ClientMessage) async throws { try await stream.write(message.wireBytes) }
        func pause(_ milliseconds: Int) async { try? await Task.sleep(for: .milliseconds(milliseconds)) }
        try await send(.setPixelFormat(.bgra8888))
        try await send(.pointerEvent(buttons: 0, x: x, y: y))
        await pause(400)

        print("  cuộn: began, 8 changed (+12 pt), ended, quán tính 6 bước")
        try await send(.appleEvent(.scroll(AppleScroll(deltaX: 0, deltaY: 0, phase: .began, x: x, y: y))))
        for _ in 0..<8 {
            await pause(16)
            try await send(.appleEvent(.scroll(AppleScroll(deltaX: 0, deltaY: 12, phase: .changed, x: x, y: y))))
        }
        try await send(.appleEvent(.scroll(AppleScroll(deltaX: 0, deltaY: 0, phase: .ended, x: x, y: y))))
        try await send(.appleEvent(.scroll(AppleScroll(deltaX: 0, deltaY: 10, phase: .none, momentum: .begin, x: x, y: y))))
        for step in [8, 6, 4, 3, 2, 1] as [Int32] {
            await pause(16)
            try await send(.appleEvent(.scroll(AppleScroll(deltaX: 0, deltaY: step, phase: .none, momentum: .continue, x: x, y: y))))
        }
        try await send(.appleEvent(.scroll(AppleScroll(deltaX: 0, deltaY: 0, phase: .none, momentum: .end, x: x, y: y))))
        await pause(600)

        print("  chụm: began, 10 lần +0,03, ended")
        try await send(.appleEvent(.magnify(0, phase: .began, x: x, y: y)))
        for _ in 0..<10 {
            await pause(16)
            try await send(.appleEvent(.magnify(0.03, phase: .changed, x: x, y: y)))
        }
        try await send(.appleEvent(.magnify(0, phase: .ended, x: x, y: y)))
        await pause(600)

        print("  xoay: began, 10 lần +3°, ended")
        try await send(.appleEvent(.rotate(0, phase: .began, x: x, y: y)))
        for _ in 0..<10 {
            await pause(16)
            try await send(.appleEvent(.rotate(3, phase: .changed, x: x, y: y)))
        }
        try await send(.appleEvent(.rotate(0, phase: .ended, x: x, y: y)))
        await pause(800)

        try await send(.framebufferUpdateRequest(incremental: false, rect: PixelRect(x: 0, y: 0, width: 1, height: 1)))
        let alive = (try? await withTimeout(seconds: 5, onTimeout: { await stream.close() }) {
            try await stream.read(exactly: 1)[0]
        }) == 0
        print(alive ? "  → server vẫn giữ kết nối sau mọi message 23" : "  → server ĐÃ ĐÓNG kết nối (payload bị từ chối?)")
        await stream.close()
    } catch {
        print("  lỗi: \(error)")
    }
}

/// THAO TÁC THẬT TRÊN MAC: như `runAppleGestureTest` nhưng payload lấy từ file, mỗi dòng `độ_trễ_ms payload_hex` (payload là
/// phần sau tiêu đề 4 byte của message 23). Để thử các biến thể phiên bản, pha, mask khi dịch ngược chưa đủ.
func runAppleRawTest(host: String, port: UInt16, type: RFBSecurityType, credentials: RFBCredentials, path: String, x: UInt16, y: UInt16) async {
    do {
        let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n")
        let (stream, _) = try await connectAndLogin(host: host, port: port, type: type, credentials: credentials)
        try await stream.write(ClientMessage.setPixelFormat(.bgra8888).wireBytes)
        try await stream.write(ClientMessage.pointerEvent(buttons: 0, x: x, y: y).wireBytes)
        try? await Task.sleep(for: .milliseconds(400))
        var sent = 0
        for line in lines where !line.hasPrefix("#") {
            let parts = line.split(separator: " ")
            guard parts.count == 2, let delay = Int(parts[0]), let payload = parseHex(String(parts[1])) else { continue }
            try? await Task.sleep(for: .milliseconds(delay))
            var message = Data([23, 0, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)])
            message.append(payload)
            try await stream.write(message)
            sent += 1
        }
        try? await Task.sleep(for: .milliseconds(800))
        try await stream.write(ClientMessage.framebufferUpdateRequest(incremental: false, rect: PixelRect(x: 0, y: 0, width: 1, height: 1)).wireBytes)
        let alive = (try? await withTimeout(seconds: 5, onTimeout: { await stream.close() }) {
            try await stream.read(exactly: 1)[0]
        }) == 0
        print("  đã gửi \(sent) message 23; " + (alive ? "server vẫn giữ kết nối" : "server ĐÃ ĐÓNG kết nối"))
        await stream.close()
    } catch {
        print("  lỗi: \(error)")
    }
}

/// Đếm cập nhật trong `seconds` giây khi luôn giữ `outstanding` yêu cầu đang chờ (gửi một yêu cầu mới mỗi khi một cập nhật
/// bắt đầu tới). Không giải mã, chỉ đọc độ dài. Kèm thời gian từ lúc gửi yêu cầu tới lúc nhận tiêu đề cập nhật.
func measureOutstanding(
    host: String, port: UInt16, type: RFBSecurityType, credentials: RFBCredentials, outstanding: Int, seconds: Double,
    serverScale: Double = 1
) async -> (updates: Int, bytes: Int) {
    do {
        let (stream, info) = try await connectAndLogin(host: host, port: port, type: type, credentials: credentials)
        let full = PixelRect(x: 0, y: 0, width: Int(info.width), height: Int(info.height))
        var first = ClientMessage.setPixelFormat(.bgra8888).wireBytes
        first.append(ClientMessage.setEncodings([.zrle, .copyRect, .desktopSize]).wireBytes) // thu nhỏ phía server cần DesktopSize, thiếu thì server ngừng gửi
        first.append(ClientMessage.framebufferUpdateRequest(incremental: false, rect: full).wireBytes)
        for _ in 1..<max(outstanding, 1) { first.append(ClientMessage.framebufferUpdateRequest(incremental: true, rect: full).wireBytes) }
        if serverScale < 1 { first.append(ClientMessage.appleServerScaling(serverScale).wireBytes) }
        try await stream.write(first)
        let counters = WireCounters()
        let started = ContinuousClock.now
        do {
            try await withTimeout(seconds: seconds, onTimeout: { await stream.close() }) {
                while true {
                    let header = try await stream.read(exactly: 4)
                    guard header[0] == 0 else { throw RFBError.malformed("message \(header[0])") }
                    counters.updates += 1
                    try await stream.write(ClientMessage.framebufferUpdateRequest(incremental: true, rect: full).wireBytes)
                    let rects = Int(header[2]) << 8 | Int(header[3])
                    for _ in 0..<rects {
                        let r = try await stream.read(exactly: 12)
                        let encoding = Int32(bitPattern: r.subdata(in: 8..<12).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
                        switch encoding {
                        case 16:
                            let length = Int(beUInt32(try await stream.read(exactly: 4)))
                            _ = try await stream.read(exactly: length)
                            counters.bytes += length
                        case 1: _ = try await stream.read(exactly: 4)
                        case -223: break // DesktopSize sau khi thu nhỏ
                        default: throw RFBError.malformed("encoding \(encoding)")
                        }
                    }
                }
            }
        } catch {
            if ContinuousClock.now - started < .seconds(seconds) - .milliseconds(500) { print("  lỗi giữa chừng (\(outstanding) yêu cầu): \(error)") }
        }
        return (counters.updates, counters.bytes)
    } catch {
        print("  lỗi kết nối: \(error)")
        return (0, 0)
    }
}

/// Thứ tự lệnh thu nhỏ so với yêu cầu cập nhật đầu tiên: in mọi message server gửi trong vài giây cho từng cách.
/// CHỈ ĐỌC (thu nhỏ chỉ ảnh hưởng luồng của người xem này).
func runScaleOrderProbe(host: String, port: UInt16, type: RFBSecurityType, credentials: RFBCredentials) async {
    enum Order: String { case scaleFirst = "thu nhỏ TRƯỚC yêu cầu đầu", scaleAfter = "thu nhỏ SAU yêu cầu đầu", scaleAfterThenFull = "thu nhỏ SAU, rồi xin lại toàn bộ ở cỡ mới" }
    for order in [Order.scaleFirst, .scaleAfter, .scaleAfterThenFull] {
        do {
            let (stream, info) = try await connectAndLogin(host: host, port: port, type: type, credentials: credentials)
            let full = PixelRect(x: 0, y: 0, width: Int(info.width), height: Int(info.height))
            let scaling = ClientMessage.appleServerScaling(0.5).wireBytes
            var first = ClientMessage.setPixelFormat(.bgra8888).wireBytes
            first.append(ClientMessage.setEncodings([.zrle, .copyRect, .desktopSize]).wireBytes)
            if order == .scaleFirst { first.append(scaling) }
            first.append(ClientMessage.framebufferUpdateRequest(incremental: false, rect: full).wireBytes)
            if order != .scaleFirst { first.append(scaling) }
            if order == .scaleAfterThenFull {
                first.append(ClientMessage.framebufferUpdateRequest(incremental: false, rect: PixelRect(x: 0, y: 0, width: 1280, height: 720)).wireBytes)
            }
            try await stream.write(first)
            let log = TextBox("")
            do {
                try await withTimeout(seconds: 4, onTimeout: { await stream.close() }) {
                    while true {
                        let header = try await stream.read(exactly: 4)
                        guard header[0] == 0 else { log.text += " [loại \(header[0])]"; return }
                        let rects = Int(header[2]) << 8 | Int(header[3])
                        var parts: [String] = []
                        for _ in 0..<rects {
                            let r = try await stream.read(exactly: 12)
                            func u16(_ at: Int) -> Int { Int(r[at]) << 8 | Int(r[at + 1]) }
                            let encoding = Int32(bitPattern: r.subdata(in: 8..<12).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
                            switch encoding {
                            case 16: _ = try await stream.read(exactly: Int(beUInt32(try await stream.read(exactly: 4)))); parts.append("ZRLE \(u16(4))x\(u16(6))")
                            case 1: _ = try await stream.read(exactly: 4); parts.append("CopyRect")
                            case -223: parts.append("DesktopSize→\(u16(4))x\(u16(6))")
                            default: parts.append("enc \(encoding)"); log.text += " {" + parts.joined(separator: ", ") + "}"; return
                            }
                        }
                        log.text += " {" + parts.joined(separator: ", ") + "}"
                        try await stream.write(ClientMessage.framebufferUpdateRequest(incremental: true, rect: full).wireBytes)
                    }
                }
            } catch {}
            print("  \(order.rawValue):\(log.text.isEmpty ? " KHÔNG NHẬN GÌ trong 4 giây" : String(log.text.prefix(300)))")
            await stream.close()
        } catch {
            print("  \(order.rawValue): lỗi \(error)")
        }
    }
}

/// Gom số liệu các sự kiện không phải pixel trong lúc quan sát.
actor WatchLog {
    private(set) var cursorEvents = 0
    private(set) var bells = 0
    private(set) var lastCursor: CursorImage?

    func record(_ event: ServerEvent) {
        switch event {
        case .framebufferUpdate(_, let cursor):
            if let cursor {
                cursorEvents += 1
                lastCursor = cursor
            }
        case .bell:
            bells += 1
        default:
            break
        }
    }
}

struct FrameCapture: Sendable {
    var rectCount: Int
    var cursor: CursorImage?
    var elapsed: Duration
    /// Số byte hình ảnh trên đường truyền của lần thu này (ZRLE tính dung lượng đã nén).
    var wireBytes: Int
}

/// Thu một khung hình đầy đủ: khai báo encoding, xin cập nhật không tăng dần, rồi gom các
/// cập nhật tới khi phủ kín diện tích màn hình.
func captureFullFrame(
    _ session: RFBSession, stream: NWByteStream, encodings: [RFBEncoding], isFirst: Bool
) async throws -> FrameCapture {
    let totalPixels = Int(session.serverInfo.width) * Int(session.serverInfo.height)
    let before = await session.statistics.payloadBytes.values.reduce(0, +)
    let started = ContinuousClock.now

    return try await withTimeout(seconds: 60, onTimeout: { await stream.close() }) {
        if isFirst {
            try await session.start(encodings: encodings)
        } else {
            try await session.send(.setEncodings(encodings))
            try await session.requestUpdate(incremental: false)
        }
        var rectCount = 0
        var covered = 0
        var cursor: CursorImage?
        while covered < totalPixels {
            if case .framebufferUpdate(let dirty, let newCursor) = try await session.nextEvent() {
                rectCount += dirty.count
                covered += dirty.reduce(0) { $0 + $1.width * $1.height }
                if let newCursor { cursor = newCursor }
            }
        }
        let after = await session.statistics.payloadBytes.values.reduce(0, +)
        return FrameCapture(rectCount: rectCount, cursor: cursor, elapsed: ContinuousClock.now - started, wireBytes: after - before)
    }
}

// MARK: - Tham số dòng lệnh

/// Đổi chuỗi hex (cho phép khoảng trắng) thành byte.
func parseHex(_ text: String) -> Data? {
    let digits = text.filter { !$0.isWhitespace }
    guard digits.count.isMultiple(of: 2) else { return nil }
    var bytes = Data()
    var index = digits.startIndex
    while index < digits.endIndex {
        let next = digits.index(index, offsetBy: 2)
        guard let byte = UInt8(digits[index..<next], radix: 16) else { return nil }
        bytes.append(byte)
        index = next
    }
    return bytes
}

var positional: [String] = []
var selected: RFBSecurityType?
var loginType: RFBSecurityType?
var snapshotPath: String?
var compareEncodings = false
var watchSeconds: Int?
var watchRaw = false
var recordPath: String?
var dumpFramePath: String?
var payload: Data?
var clipboardSeconds: Int?
var sendText: String?
var sendEncoding = "latin1"
var autoPasteboard: UInt16?
var clipboardRequest = false
var sendAppleClipboard: String?
var dumpClipboardPath: String?
var probeEncodings = false
var probeContinuous = false
var gestureTestPoint: (x: UInt16, y: UInt16)?
var appleRawPath: String?
var probeScaleOrder = false
var compareOutstandingSeconds: Double?
var compareScaleSeconds: Double?
var serverScale: Double?
var probeCursor = false
var probeDesktopSize = false
var depth16 = false
var depthImageCheck = false
var compareDepthSeconds: Double?
var replayPath: String?
var replaySize: (width: Int, height: Int)?
var rest = CommandLine.arguments.dropFirst()
while let argument = rest.popFirst() {
    if argument == "--clipboard-probe" {
        guard let value = rest.popFirst(), let seconds = Int(value), (3...120).contains(seconds) else {
            fail("--clipboard-probe cần số giây từ 3 đến 120", code: 64)
        }
        clipboardSeconds = seconds
    } else if argument == "--send-text" {
        guard let value = rest.popFirst() else { fail("--send-text cần chuỗi", code: 64) }
        sendText = value
    } else if argument == "--send-apple-clipboard" {
        guard let value = rest.popFirst() else { fail("--send-apple-clipboard cần chuỗi", code: 64) }
        sendAppleClipboard = value
    } else if argument == "--clipboard-request" {
        clipboardRequest = true
    } else if argument == "--dump-clipboard" {
        guard let value = rest.popFirst() else { fail("--dump-clipboard cần đường dẫn file", code: 64) }
        dumpClipboardPath = (value as NSString).expandingTildeInPath
    } else if argument == "--autopasteboard" {
        guard let value = rest.popFirst(), let command = UInt16(value) else { fail("--autopasteboard cần một số", code: 64) }
        autoPasteboard = command
    } else if argument == "--send-encoding" {
        guard let value = rest.popFirst(), ["latin1", "utf8", "macroman"].contains(value) else {
            fail("--send-encoding cần latin1, utf8 hoặc macroman", code: 64)
        }
        sendEncoding = value
    } else if argument == "--record" {
        guard let value = rest.popFirst() else { fail("--record cần đường dẫn file", code: 64) }
        recordPath = (value as NSString).expandingTildeInPath
    } else if argument == "--dump-frame" {
        guard let value = rest.popFirst() else { fail("--dump-frame cần đường dẫn file", code: 64) }
        dumpFramePath = (value as NSString).expandingTildeInPath
    } else if argument == "--depth16" {
        depth16 = true // dùng với --watch/--record và --replay: nhận và giải mã ở 16 bit
    } else if argument == "--check-depth-image" {
        depthImageCheck = true
    } else if argument == "--compare-depth" {
        guard let value = rest.popFirst(), let seconds = Double(value), (3...120).contains(seconds) else {
            fail("--compare-depth cần số giây từ 3 đến 120", code: 64)
        }
        compareDepthSeconds = seconds
    } else if argument == "--probe-desktop-size" {
        probeDesktopSize = true
    } else if argument == "--probe-cursor" {
        probeCursor = true
    } else if argument == "--server-scale" {
        guard let value = rest.popFirst(), let scale = Double(value), scale > 0, scale <= 1 else { fail("--server-scale cần số trong (0, 1]", code: 64) }
        serverScale = scale
    } else if argument == "--probe-scale-order" {
        probeScaleOrder = true
    } else if argument == "--probe-continuous" {
        probeContinuous = true
    } else if argument == "--compare-scale" {
        guard let value = rest.popFirst(), let seconds = Double(value), (3...120).contains(seconds) else { fail("--compare-scale cần số giây 3–120", code: 64) }
        compareScaleSeconds = seconds
    } else if argument == "--compare-outstanding" {
        guard let value = rest.popFirst(), let seconds = Double(value), (3...120).contains(seconds) else { fail("--compare-outstanding cần số giây 3–120", code: 64) }
        compareOutstandingSeconds = seconds
    } else if argument == "--probe-encodings" {
        probeEncodings = true
    } else if argument == "--replay" {
        guard let value = rest.popFirst() else { fail("--replay cần đường dẫn file đã ghi bằng --record", code: 64) }
        replayPath = (value as NSString).expandingTildeInPath
    } else if argument == "--size" {
        guard let value = rest.popFirst(), case let parts = value.split(separator: "x"), parts.count == 2,
              let w = Int(parts[0]), let h = Int(parts[1]) else { fail("--size cần dạng RỘNGxCAO, ví dụ 2560x1440", code: 64) }
        replaySize = (w, h)
    } else if argument == "--watch-raw" {
        watchRaw = true // đối chứng: kết nối chính nhận bằng Raw thay vì ZRLE
    } else if argument == "--watch" {
        guard let value = rest.popFirst(), let seconds = Int(value), (3...300).contains(seconds) else {
            fail("--watch cần số giây từ 3 đến 300", code: 64)
        }
        watchSeconds = seconds
    } else if argument == "--compare-encodings" {
        compareEncodings = true
    } else if argument == "--snapshot" {
        guard let value = rest.popFirst() else { fail("--snapshot cần đường dẫn file .png", code: 64) }
        snapshotPath = (value as NSString).expandingTildeInPath
    } else if argument == "--login" {
        guard let value = rest.popFirst(), let raw = UInt8(value) else { fail("--login cần số 2 hoặc 30", code: 64) }
        loginType = RFBSecurityType(rawValue: raw)
    } else if argument == "--select" {
        guard let value = rest.popFirst(), let raw = UInt8(value) else { fail("--select cần một số 0–255", code: 64) }
        selected = RFBSecurityType(rawValue: raw)
    } else if argument == "--apple-raw" {
        guard let value = rest.popFirst() else { fail("--apple-raw cần file payload (dùng kèm --apple-gesture-test X,Y)", code: 64) }
        appleRawPath = value
    } else if argument == "--apple-gesture-test" {
        let parts = rest.popFirst()?.split(separator: ",").compactMap { UInt16($0) } ?? []
        guard parts.count == 2 else { fail("--apple-gesture-test cần X,Y theo pixel màn hình Mac", code: 64) }
        gestureTestPoint = (parts[0], parts[1])
    } else if argument == "--send-hex" {
        guard let value = rest.popFirst(), let bytes = parseHex(value) else { fail("--send-hex cần chuỗi hex hợp lệ", code: 64) }
        payload = bytes
    } else {
        positional.append(argument)
    }
}
if let replayPath {
    guard let replaySize else { fail("--replay cần thêm --size RỘNGxCAO", code: 64) }
    await runReplay(path: replayPath, width: replaySize.width, height: replaySize.height, format: depth16 ? .rgb565 : .bgra8888)
    exit(0)
}
let host = positional.first ?? "127.0.0.1"
let port = positional.count > 1 ? UInt16(positional[1]) ?? 5900 : 5900

// MARK: - Thăm dò clipboard

let extendedClipboardEncoding: Int32 = -1_063_131_698 // 0xC0A1E5CE

func beUInt32(_ data: Data) -> UInt32 { data.reduce(0) { ($0 << 8) | UInt32($1) } }

/// Đọc thô message của server trong `seconds` giây. Chỉ xin Raw (không xin pseudo-encoding nào khác) và chỉ xin một
/// hình chữ nhật 1x1, nên mọi cập nhật đều nhỏ và phân tích được mà không cần decoder.
func runClipboardProbe(stream: NWByteStream, info: ServerInit, seconds: Int, sendText: String?, sendEncoding: String, autoPasteboard: UInt16?, sendRequest: Bool, sendAppleClipboard: String?, dumpPath: String?) async {
    let clock = ProbeClock()
    @Sendable func log(_ text: String) { print(String(format: "[%6.2fs] ", clock.elapsedSeconds) + text) }

    var setEncodings = Data([2, 0, 0, 2])
    for value in [Int32(0), extendedClipboardEncoding] { setEncodings.append(contentsOf: withUnsafeBytes(of: value.bigEndian) { Array($0) }) }
    @Sendable func request(incremental: Bool) -> Data { Data([3, incremental ? 1 : 0, 0, 0, 0, 0, 0, 1, 0, 1]) }

    do {
        try await stream.write(setEncodings)
        try await stream.write(request(incremental: false))
        log("Đã gửi SetEncodings [Raw, ExtendedClipboard(0xC0A1E5CE)]")

        if let autoPasteboard {
            // Message loại 21 của Apple: `RFBAutoPasteboardMessage`, 8 byte gồm cả byte loại; số 16-bit big-endian ở offset 2.
            let message = Data([0x15, 0, UInt8(autoPasteboard >> 8), UInt8(autoPasteboard & 0xFF), 0, 0, 0, 0])
            try await stream.write(message)
            log("Đã gửi AutoPasteboard (loại 21) lệnh \(autoPasteboard): \(message.map { String(format: "%02x", $0) }.joined(separator: " "))")
        }

        if let sendAppleClipboard {
            let transfer = try ClipboardTransfer(text: sendAppleClipboard, token: 0x0A0B0C0D)
            try await stream.write(ClientMessage.clipboardSend(transfer).wireBytes)
            log("Đã gửi clipboard Apple (loại 31): giải nén \(transfer.uncompressedSize) byte, nén \(transfer.compressed.count) byte")
        }

        if sendRequest {
            // Message loại 11 của Apple: ClipboardRequest, 8 byte. Byte 1 bit 0 = chỉ xin "promise"; byte 4-7 là mã server lặp lại.
            let message = Data([0x0b, 0, 0, 0, 0xde, 0xad, 0xbe, 0xef])
            try await stream.write(message)
            log("Đã gửi ClipboardRequest (loại 11): \(message.map { String(format: "%02x", $0) }.joined(separator: " "))")
        }

        if let sendText {
            let bytes: Data
            switch sendEncoding {
            case "utf8": bytes = Data(sendText.utf8)
            case "macroman": bytes = sendText.data(using: .macOSRoman, allowLossyConversion: true) ?? Data()
            default: bytes = sendText.data(using: .isoLatin1, allowLossyConversion: true) ?? Data()
            }
            var message = Data([6, 0, 0, 0])
            message.append(contentsOf: withUnsafeBytes(of: UInt32(bytes.count).bigEndian) { Array($0) })
            message.append(bytes)
            try await stream.write(message)
            log("Đã gửi ClientCutText \(bytes.count) byte, mã hóa \(sendEncoding): \(bytes.map { String(format: "%02x", $0) }.joined(separator: " "))")
        }

        try await withTimeout(seconds: Double(seconds), onTimeout: { await stream.close() }) {
            while true {
                let type = try await stream.read(exactly: 1)[0]
                switch type {
                case 0:
                    let header = try await stream.read(exactly: 3)
                    let count = Int(header[1]) << 8 | Int(header[2])
                    for _ in 0..<count {
                        let rect = try await stream.read(exactly: 12)
                        let width = Int(rect[4]) << 8 | Int(rect[5]), height = Int(rect[6]) << 8 | Int(rect[7])
                        let encoding = Int32(bitPattern: beUInt32(rect.suffix(4)))
                        guard encoding == 0 else { log("Hình chữ nhật encoding \(encoding): dừng vì không xin loại này"); return }
                        var remaining = width * height * 4
                        while remaining > 0 { remaining -= try await stream.read(exactly: min(remaining, 65536)).count }
                    }
                    try await stream.write(request(incremental: true))
                case 1:
                    let header = try await stream.read(exactly: 5)
                    let colours = Int(header[3]) << 8 | Int(header[4])
                    _ = try await stream.read(exactly: colours * 6)
                    log("SetColourMapEntries \(colours) mục")
                case 2:
                    log("Bell")
                case 0x1f:
                    // Clipboard của Apple (cùng định dạng hai chiều): 16 byte header rồi payload nén.
                    let header = try await stream.read(exactly: 15)
                    let flags = header[1]
                    let token = header.subdata(in: 3..<7).map { String(format: "%02x", $0) }.joined()
                    let uncompressed = beUInt32(header.subdata(in: 7..<11)), payloadSize = beUInt32(header.subdata(in: 11..<15))
                    log("Clipboard Apple (loại 0x1f): header[1..]=\(header.map { String(format: "%02x", $0) }.joined(separator: " "))")
                    log("   cờ byte2=0x\(String(flags, radix: 16)) mã=\(token) kích thước giải nén=\(uncompressed) payload=\(payloadSize)")
                    guard payloadSize <= 1 << 20 else { log("   payload quá lớn, dừng"); return }
                    let payload = try await stream.read(exactly: Int(payloadSize))
                    log("   payload 32 byte đầu: \(payload.prefix(32).map { String(format: "%02x", $0) }.joined(separator: " "))")
                    if let dumpPath { try? payload.write(to: URL(fileURLWithPath: dumpPath), options: [.atomic, .completeFileProtection]) }
                case 3:
                    _ = try await stream.read(exactly: 3)
                    let lengthBytes = try await stream.read(exactly: 4)
                    let length = Int32(bitPattern: beUInt32(lengthBytes))
                    if length >= 0 {
                        let body = try await stream.read(exactly: Int(length))
                        let marker = Data("rfbprobe-marker".utf8)
                        if body.starts(with: marker) {
                            let hex = body.map { String(format: "%02x", $0) }.joined(separator: " ")
                            log("ServerCutText chuẩn, \(length) byte: \(hex)")
                            log("   dạng Latin-1: \(String(data: body, encoding: .isoLatin1) ?? "?") | UTF-8: \(String(data: body, encoding: .utf8) ?? "(không phải UTF-8 hợp lệ)")")
                        } else {
                            log("ServerCutText chuẩn, \(length) byte (không phải marker, không in nội dung)")
                        }
                    } else {
                        let size = Int(-Int64(length))
                        let body = try await stream.read(exactly: size)
                        let flags = beUInt32(body.prefix(4))
                        let actions = [(1 << 24, "caps"), (1 << 25, "request"), (1 << 26, "peek"), (1 << 27, "notify"), (1 << 28, "provide")]
                            .filter { flags & UInt32($0.0) != 0 }.map(\.1)
                        let formats = [(1, "text"), (2, "rtf"), (4, "html"), (8, "dib"), (16, "files")]
                            .filter { flags & UInt32($0.0) != 0 }.map(\.1)
                        log("ServerCutText MỞ RỘNG \(size) byte, flags=0x\(String(flags, radix: 16)) hành động=\(actions) định dạng=\(formats)")
                        if actions.contains("caps") { log("   caps: \(body.map { String(format: "%02x", $0) }.joined(separator: " "))") }
                    }
                default:
                    // Message của Apple chưa biết độ dài. Đọc những gì đang có và in phần đầu (chỉ phần đầu, tránh lộ nội dung).
                    var extra = Data()
                    while extra.count < 4096 {
                        let room = 4096 - extra.count
                        guard let chunk = try? await withTimeout(seconds: 1.0, onTimeout: { }, { try await stream.readSome(maxCount: room) }) else { break }
                        extra.append(chunk)
                    }
                    log("Message LẠ loại \(type) (0x\(String(type, radix: 16))), theo sau \(extra.count) byte, 48 byte đầu: \(extra.prefix(48).map { String(format: "%02x", $0) }.joined(separator: " "))")
                    return
                }
            }
        }
    } catch ProbeError.timeout {
        log("Hết \(seconds) giây")
    } catch {
        log("Kết thúc: \(error)")
    }
    await stream.close()
}

final class ProbeClock: @unchecked Sendable {
    private let start = ContinuousClock.now
    var elapsedSeconds: Double {
        let d = ContinuousClock.now - start
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
}

// MARK: - Chạy

let stream = NWByteStream(host: host, port: port)

do {
    let hello = try await withTimeout(seconds: 5, onTimeout: { await stream.close() }) {
        try await stream.connect()
        return try await Handshake.readServerHello(over: stream)
    }

    print("Máy chủ:              \(host):\(port)")
    print("Phiên bản server:     \(hello.serverVersion)")
    print("Client trả lời:       \(hello.negotiatedVersion)")
    print("Security types:")
    for type in hello.securityTypes { print("  - \(type)") }

    if let loginType {
        // Đăng nhập thật. Mật khẩu chỉ đọc từ biến môi trường và không bao giờ được in ra.
        guard hello.securityTypes.contains(loginType) else {
            await stream.close()
            fail("\nServer không cung cấp type \(loginType.rawValue).", code: 65)
        }
        let environment = ProcessInfo.processInfo.environment
        let credentials = RFBCredentials(
            username: environment["RFB_USER"] ?? "", password: environment["RFB_PASSWORD"] ?? ""
        )
        guard !credentials.password.isEmpty, loginType != .appleRemoteDesktop || !credentials.username.isEmpty else {
            await stream.close()
            fail("\nCần đặt RFB_PASSWORD (và RFB_USER cho type 30) trong biến môi trường.", code: 64)
        }
        print("\nĐăng nhập bằng type \(loginType), tài khoản: \(credentials.username.isEmpty ? "(không dùng)" : credentials.username)")

        let info = try await withTimeout(seconds: 60, onTimeout: { await stream.close() }) {
            try await Handshake.selectSecurityType(loginType, over: stream)
            try await Authenticator.authenticate(
                type: loginType, version: hello.negotiatedVersion, credentials: credentials, over: stream
            )
            return try await Handshake.performInit(shared: true, over: stream)
        }
        print("XÁC THỰC THÀNH CÔNG")
        print("Tên desktop:   \(info.name)")
        print("Kích thước:    \(info.width) x \(info.height)")
        print("Pixel format:  \(info.pixelFormat)")

        if let gestureTestPoint {
            print("\nTHỬ MESSAGE 23 (thao tác thật) tại \(gestureTestPoint.x),\(gestureTestPoint.y):")
            if let appleRawPath {
                await runAppleRawTest(host: host, port: port, type: loginType, credentials: credentials, path: appleRawPath, x: gestureTestPoint.x, y: gestureTestPoint.y)
            } else {
                await runAppleGestureTest(host: host, port: port, type: loginType, credentials: credentials, x: gestureTestPoint.x, y: gestureTestPoint.y)
            }
        } else if probeScaleOrder {
            print("\nThứ tự lệnh thu nhỏ (chỉ đọc):")
            await runScaleOrderProbe(host: host, port: port, type: loginType, credentials: credentials)
        } else if probeContinuous {
            print("\nThăm dò ContinuousUpdates (chỉ đọc):")
            await runContinuousUpdatesProbe(host: host, port: port, type: loginType, credentials: credentials)
        } else if let compareScaleSeconds {
            print("\nSo cỡ gốc, 0,92 (iPad Air 4 ngang) và 0,46 (iPhone dọc) trong \(Int(compareScaleSeconds)) giây (ba kết nối song song, chỉ đọc):")
            async let full = measureOutstanding(host: host, port: port, type: loginType, credentials: credentials, outstanding: 1, seconds: compareScaleSeconds)
            async let pad = measureOutstanding(host: host, port: port, type: loginType, credentials: credentials, outstanding: 1, seconds: compareScaleSeconds, serverScale: 2360.0 / 2560)
            async let phone = measureOutstanding(host: host, port: port, type: loginType, credentials: credentials, outstanding: 1, seconds: compareScaleSeconds, serverScale: 1179.0 / 2560)
            let (a, b, c) = await (full, pad, phone)
            for (label, r) in [("cỡ gốc 1,00", a), ("thu nhỏ 0,92", b), ("thu nhỏ 0,46", c)] {
                print(String(format: "  %@: %.1f cập nhật/giây, %.1f Mbit/s", label, Double(r.updates) / compareScaleSeconds, Double(r.bytes) * 8 / 1e6 / compareScaleSeconds))
            }
        } else if let compareOutstandingSeconds {
            print("\nSo một và hai yêu cầu đang chờ trong \(Int(compareOutstandingSeconds)) giây (hai kết nối song song, chỉ đọc):")
            async let one = measureOutstanding(host: host, port: port, type: loginType, credentials: credentials, outstanding: 1, seconds: compareOutstandingSeconds)
            async let two = measureOutstanding(host: host, port: port, type: loginType, credentials: credentials, outstanding: 2, seconds: compareOutstandingSeconds)
            let (a, b) = await (one, two)
            for (label, r) in [("1 yêu cầu", a), ("2 yêu cầu", b)] {
                print(String(format: "  %@: %d cập nhật (%.1f/giây), %.1f Mbit/s", label, r.updates, Double(r.updates) / compareOutstandingSeconds,
                             Double(r.bytes) * 8 / 1e6 / compareOutstandingSeconds))
            }
        } else if let serverScale {
            print("\nThử message loại 8 (server thu nhỏ hình, chỉ cho người xem này):")
            await runServerScalingProbe(host: host, port: port, type: loginType, credentials: credentials, scale: serverScale)
        } else if probeCursor {
            print("\nThăm dò định dạng hình con trỏ (chỉ đọc):")
            await runCursorFormatProbe(host: host, port: port, type: loginType, credentials: credentials)
        } else if probeDesktopSize {
            print("\nThăm dò ExtendedDesktopSize (chỉ đọc, không đổi độ phân giải):")
            await runDesktopSizeProbe(host: host, port: port, type: loginType, credentials: credentials)
        } else if depthImageCheck {
            print("\nKiểm 16 bit trên server thật (chỉ đọc):")
            await runDepthImageCheck(host: host, port: port, type: loginType, credentials: credentials)
        } else if let compareDepthSeconds {
            print("\nSo băng thông 32 bit và 16 bit trong \(Int(compareDepthSeconds)) giây (hai kết nối song song, chỉ đọc):")
            await runDepthComparison(host: host, port: port, type: loginType, credentials: credentials, seconds: compareDepthSeconds)
        } else if probeEncodings {
            print("\nThăm dò encoding và định dạng pixel (chỉ đọc):")
            await runEncodingProbe(host: host, port: port, type: loginType, credentials: credentials)
        } else if let clipboardSeconds {
            await runClipboardProbe(stream: stream, info: info, seconds: clipboardSeconds, sendText: sendText, sendEncoding: sendEncoding, autoPasteboard: autoPasteboard, sendRequest: clipboardRequest, sendAppleClipboard: sendAppleClipboard, dumpPath: dumpClipboardPath)
        } else if let watchSeconds {
            // Kiểm chứng ZRLE qua NHIỀU cập nhật nối tiếp trên một luồng zlib duy nhất, kèm CopyRect và Cursor.
            // Cuối cùng so khung hình tích lũy với một khung Raw lấy từ kết nối thứ hai.
            //
            // Hai điều để phép đo không tự làm nhiễu chính nó (màn hình được chụp cũng là màn hình hiển thị đầu ra):
            //  1. Mở kết nối tham chiếu TRƯỚC khi quan sát, để chỉ báo "đang chia sẻ" trên thanh menu xuất hiện sớm
            //     và nằm trong các cập nhật mà kết nối chính nhận được.
            //  2. Lấy khung tham chiếu NGAY khi hết giờ và chỉ in kết quả SAU đó, vì in ra terminal làm đổi màn hình.
            let (referenceStream, referenceInfo) = try await connectAndLogin(host: host, port: port, type: loginType, credentials: credentials)
            let reference = try RFBSession(stream: referenceStream, serverInfo: referenceInfo)
            let recorder = try recordPath.map { try RecordingByteStream(base: stream, path: $0) }
            let session = try RFBSession(stream: recorder ?? stream, serverInfo: info, pixelFormat: depth16 ? .rgb565 : .bgra8888)
            let watchEncodings: [RFBEncoding] = watchRaw ? [.raw, .copyRect, .cursor] : [.zrle, .copyRect, .cursor]
            let first = try await captureFullFrame(session, stream: stream, encodings: watchEncodings, isFirst: true)
            print("\nKhung đầu (ZRLE): \(first.wireBytes / 1024) KiB trong \(first.elapsed)")
            print("Quan sát \(watchSeconds) giây. Hãy kéo cửa sổ, cuộn trang, gõ chữ. GIỮ YÊN màn hình trong vài giây cuối.")

            let log = WatchLog()
            let started = ContinuousClock.now
            do {
                try await withTimeout(seconds: Double(watchSeconds), onTimeout: { await stream.close() }) {
                    try await session.requestUpdate(incremental: true)
                    while true {
                        let event = try await session.nextEvent()
                        await log.record(event)
                        if case .framebufferUpdate = event { try await session.requestUpdate(incremental: true) }
                    }
                }
            } catch {
                // Hết giờ thì stream bị đóng và vòng lặp ném lỗi. Đó là kết thúc bình thường.
                // Lỗi xảy ra TRƯỚC giờ là lỗi giải mã hoặc giao thức thật.
                let elapsed = ContinuousClock.now - started
                if elapsed < .seconds(watchSeconds) - .milliseconds(500) {
                    fail("\nLỖI sau \(elapsed) quan sát: \(error)", code: 3)
                }
            }

            // Lấy khung tham chiếu ngay, trước khi in bất cứ thứ gì.
            _ = try await captureFullFrame(reference, stream: referenceStream, encodings: [.raw], isFirst: true)
            let liveFrame = await session.framebuffer
            let referenceFrame = await reference.framebuffer
            await reference.close()
            if let dumpFramePath {
                try Data(liveFrame.pixels).write(to: URL(fileURLWithPath: dumpFramePath), options: .completeFileProtection)
            }
            let recordedBytes = await recorder?.recordedBytes
            await recorder?.close()

            if let recordPath, let recordedBytes {
                print("\nĐã ghi \(recordedBytes / 1024) KiB byte server gửi vào \(recordPath)")
            }
            if let dumpFramePath { print("Đã lưu khung hình do decoder Swift dựng: \(dumpFramePath) (\(liveFrame.width)x\(liveFrame.height) BGRA)") }
            let statistics = await session.statistics
            let incrementalUpdates = statistics.updateCount - 1
            let zrleBytes = statistics.payloadBytes[.zrle] ?? 0
            let rawBytes = (statistics.payloadBytes[.raw] ?? 0) - (watchRaw ? first.wireBytes : 0)
            print("\nTrong \(watchSeconds) giây: \(incrementalUpdates) cập nhật tăng dần (\(String(format: "%.1f", Double(incrementalUpdates) / Double(watchSeconds)))/giây)")
            print("  Chế độ nhận: \(watchRaw ? "Raw (đối chứng)" : "ZRLE"). Raw: \(rawBytes / 1024) KiB, ZRLE: \((zrleBytes - (watchRaw ? 0 : first.wireBytes)) / 1024) KiB nén. CopyRect: \((statistics.payloadBytes[.copyRect] ?? 0) / 4) hình chữ nhật.")
            print("  Sự kiện con trỏ: \(await log.cursorEvents). Chuông: \(await log.bells).")
            if let cursor = await log.lastCursor {
                print("  Con trỏ cuối: \(cursor.width)x\(cursor.height), điểm nóng (\(cursor.hotspotX), \(cursor.hotspotY))")
            }

            if let difference = liveFrame.difference(from: referenceFrame) {
                let percent = Double(difference.count) / Double(Int(info.width) * Int(info.height)) * 100
                print("\nSo khung tích lũy với khung Raw tham chiếu (kết nối thứ hai): \(difference.count) pixel khác nhau (\(String(format: "%.4f", percent))%)")
                if let bounds = difference.bounds { print("  vùng khác biệt nhỏ nhất: \(bounds)") }
                // Khác biệt tập trung ở đâu: ô lưới 128x128, ô nhiều nhất trước (tối đa 8 ô).
                for cell in (liveFrame.differenceCells(from: referenceFrame) ?? []).prefix(8) {
                    print("  ô x \(cell.rect.x)..<\(cell.rect.x + cell.rect.width), y \(cell.rect.y)..<\(cell.rect.y + cell.rect.height): \(cell.count) pixel")
                }
            }
        } else if snapshotPath != nil || compareEncodings {
            let session = try RFBSession(stream: stream, serverInfo: info)
            let totalPixels = Int(info.width) * Int(info.height)

            let raw = try await captureFullFrame(session, stream: stream, encodings: [.raw], isFirst: true)
            print("\nRaw:   \(raw.rectCount) hình chữ nhật, \(raw.wireBytes / 1024) KiB trên đường truyền, \(raw.elapsed)")
            let rawFrame = await session.framebuffer
            var finalFrame = rawFrame

            if compareEncodings {
                // Xin lại toàn bộ khung hình bằng ZRLE (kèm Cursor) trên cùng kết nối rồi so từng pixel với bản Raw.
                // Màn hình đứng yên thì hai bản phải trùng khít, đó là phép đối chiếu độc lập với code giải mã.
                let zrle = try await captureFullFrame(session, stream: stream, encodings: [.zrle, .cursor], isFirst: false)
                print("ZRLE:  \(zrle.rectCount) hình chữ nhật, \(zrle.wireBytes / 1024) KiB trên đường truyền, \(zrle.elapsed)")
                if zrle.wireBytes > 0 {
                    print("Tỉ lệ nén ZRLE so với Raw: \(String(format: "%.1f", Double(raw.wireBytes) / Double(zrle.wireBytes)))×")
                }
                let zrleFrame = await session.framebuffer
                if let difference = rawFrame.difference(from: zrleFrame) {
                    let percent = Double(difference.count) / Double(totalPixels) * 100
                    print("So sánh Raw và ZRLE: \(difference.count) pixel khác nhau (\(String(format: "%.4f", percent))%)")
                    if let bounds = difference.bounds { print("  vùng khác biệt nhỏ nhất: \(bounds)") }
                }
                if let cursor = zrle.cursor {
                    print("Con trỏ nhận được: \(cursor.width)x\(cursor.height), điểm nóng (\(cursor.hotspotX), \(cursor.hotspotY))")
                } else {
                    print("Không nhận được hình con trỏ riêng (server có thể vẽ con trỏ vào khung hình).")
                }
                finalFrame = zrleFrame
            }

            if let snapshotPath {
                guard let image = finalFrame.makeCGImage() else { fail("Không tạo được CGImage", code: 1) }
                try writePNG(image, to: snapshotPath)
                print("Đã lưu: \(snapshotPath)")
            }
            await session.close()
        }
    } else if let selected {
        guard hello.securityTypes.contains(selected) else {
            await stream.close()
            fail("\nServer không cung cấp type \(selected.rawValue), không thể chọn.", code: 65)
        }
        try await Handshake.selectSecurityType(selected, over: stream)
        if let payload {
            try await stream.write(payload)
            print("\nĐã gửi \(payload.count) byte sau khi chọn type (không chứa mật khẩu).")
        }

        // Thu mọi byte server gửi cho tới khi im lặng 1,5 giây hoặc đạt giới hạn.
        var reply = Data()
        var ending = "đạt giới hạn 4096 byte"
        while reply.count < 4096 {
            let remaining = 4096 - reply.count
            do {
                let chunk = try await withTimeout(seconds: 1.5, onTimeout: { await stream.close() }) {
                    try await stream.readSome(maxCount: remaining)
                }
                reply.append(chunk)
            } catch ProbeError.timeout {
                ending = "server im lặng 1,5 giây"
                break
            } catch {
                ending = "kết nối kết thúc (\(error))"
                break
            }
        }
        print("\nĐã chọn type \(selected). Server trả lại \(reply.count) byte (\(ending)):")
        if !reply.isEmpty { print(hexDump(reply)) }
    }
    await stream.close()
} catch ProbeError.timeout {
    fail("Hết thời gian chờ (5 giây) khi nối \(host):\(port)", code: 2)
} catch {
    fail("Lỗi: \(error)", code: 1)
}
