import CoreGraphics
import Foundation
import ImageIO
import RFBKit
import UniformTypeIdentifiers

// rfbprobe: connects to an RFB server and prints its version and the security types it offers.
// No authentication, no password sent.
//
//   rfbprobe [host] [port]                 list the security types
//   rfbprobe [host] [port] --login N [--snapshot FILE.png] [--compare-encodings | --watch SECONDS]
//                                           real login with type 2 or 30, reads RFB_USER/RFB_PASSWORD
//                                           from the environment, then prints the ServerInit info.
//                                           --compare-encodings requests a frame as Raw then ZRLE and compares pixel by pixel.
//                                           --watch runs ZRLE incremental updates for SECONDS seconds, then compares with a reference Raw frame
//   rfbprobe [host] [port] --login N --clipboard-probe SECONDS [--send-text TEXT [--send-encoding latin1|utf8|macroman]]
//                                           logs in, then reads the server's raw messages for SECONDS seconds, printing every ServerCutText
//                                           (including Extended Clipboard). Prints content only if it starts with "rfbprobe-marker",
//                                           so the user's real clipboard is never exposed. --send-text sends a ClientCutText.
//   rfbprobe [host] [port] --select N [--send-hex HEX]
//                                           selects type N, optionally sends extra raw bytes, then hex-dumps the first bytes
//                                           the server sends back (protocol exploration)

enum ProbeError: Error { case timeout }

/// Runs `operation` with a time limit. On timeout the stream must be closed first,
/// because reads through NWConnection are not cancelled with the `Task` and the group would wait forever.
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

/// Opens a new connection and logs in through `ServerInit`. Used for the second, reference connection.
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

/// Wraps a `ByteStream` and writes every byte READ (server -> client) verbatim to a file.
/// Used to verify decoding offline with an independent decoder. The file contains screen content.
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

/// Replays a stretch of server bytes recorded with `--record`, to measure pure decode time (no network).
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

/// Decodes the whole recording again and prints the timing: total, per update, and throughput.
func runReplay(path: String, width: Int, height: Int, format: PixelFormat) async {
    guard let data = FileManager.default.contents(atPath: path) else { fail("Cannot read \(path)", code: 66) }
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
        // FNV-1a of the final frame: both decoder versions must give the same value on the same recording.
        let finalPixels = await session.framebuffer.pixels
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in finalPixels { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        print(String(format: "Final frame hash (FNV-1a): %016llx", hash))
        print(String(format: "File: %.1f MiB, %d updates, %.1f million pixels (screen %dx%d)", Double(data.count) / 1_048_576, updates, Double(pixels) / 1e6, width, height))
        print(String(format: "Total decode: %.2f s  |  per update: median %.2f ms, p95 %.2f ms, max %.2f ms", seconds, percentile(0.5), percentile(0.95), sorted.last ?? 0))
        print(String(format: "Throughput: %.1f million pixels/s, %.1f MiB compressed data/s, equivalent to %.0f updates/s", Double(pixels) / 1e6 / seconds, Double(wire) / 1_048_576 / seconds, Double(updates) / seconds))
    } catch {
        fail("Replay error: \(error)", code: 3)
    }
}

/// Asks the server for each configuration (pixel format + encoding list) and prints the encoding it actually uses for the first
/// rectangle. READ-ONLY: sends no mouse or keys. Each configuration uses its own connection so state does not carry over.
func runEncodingProbe(host: String, port: UInt16, type: RFBSecurityType, credentials: RFBCredentials) async {
    let rgb565 = PixelFormat(bitsPerPixel: 16, depth: 16, isBigEndian: false, isTrueColour: true,
                             redMax: 31, greenMax: 63, blueMax: 31, redShift: 11, greenShift: 5, blueShift: 0)
    let bgr233 = PixelFormat(bitsPerPixel: 8, depth: 8, isBigEndian: false, isTrueColour: true,
                             redMax: 7, greenMax: 7, blueMax: 3, redShift: 0, greenShift: 3, blueShift: 6)
    func enc(_ values: Int32...) -> [RFBEncoding] { values.map { RFBEncoding(rawValue: $0) } }
    // Tight pseudo-encodings: JPEG quality 0...9 is -32...-23, compression level -256...-247.
    let cases: [(String, PixelFormat, [RFBEncoding])] = [
        ("baseline: ZRLE, 32-bit", .bgra8888, enc(16, 1, -239)),
        ("Tight + JPEG quality 5", .bgra8888, enc(7, -27, -253, 16, 1, -239)),
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
            guard header[0] == 0 else { print("  \(label): message type \(header[0]) instead of FramebufferUpdate"); continue }
            let rects = Int(header[2]) << 8 | Int(header[3])
            let rectHeader = try await withTimeout(seconds: 15, onTimeout: { await stream.close() }) { try await stream.read(exactly: 12) }
            func u16(_ at: Int) -> Int { Int(rectHeader[at]) << 8 | Int(rectHeader[at + 1]) }
            let encoding = Int32(bitPattern: rectHeader.subdata(in: 8..<12).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
            var line = "  \(label): \(rects) rectangles, first \(u16(4))x\(u16(6)) at (\(u16(0)),\(u16(2))), encoding \(RFBEncoding(rawValue: encoding))"

            if encoding == 0, rects == 1 {
                // A single Raw rectangle: check whether the server honours the pixel format by counting leftover bytes.
                let expected = u16(4) * u16(6) * Int(format.bitsPerPixel) / 8
                _ = try await withTimeout(seconds: 30, onTimeout: { await stream.close() }) { try await stream.read(exactly: expected) }
                let extra = try? await withTimeout(seconds: 1.5, onTimeout: { await stream.close() }) { try await stream.readSome(maxCount: 64) }
                line += (extra?.isEmpty == false) ? "  → LEFTOVER BYTES: server does NOT follow \(format.bitsPerPixel)-bit" : "  → matches \(format.bitsPerPixel) bit/pixel (\(expected / 1024) KiB)"
            }
            print(line)
        } catch {
            print("  \(label): error \(error)")
        }
    }
}

/// List of bytes written by a single read loop.
final class ByteLog: @unchecked Sendable {
    var items: [UInt8] = []
}

/// Verdict string written by a single read loop.
final class TextBox: @unchecked Sendable {
    var text: String
    init(_ text: String) { self.text = text }
}

/// Counter with a single writer (the one read loop), so no lock is needed.
final class WireCounters: @unchecked Sendable {
    var updates = 0, bytes = 0, pixels = 0
}

/// Measures the bytes the server sends in `seconds` seconds for one configuration, WITHOUT decoding: reads lengths only. Supports ZRLE and CopyRect/Cursor.
/// Runs two configurations **in parallel** so they see the same screen content.
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
                        case -239: // cursor
                            let n = w * h * Int(format.bitsPerPixel) / 8 + ((w + 7) / 8) * h
                            _ = try await stream.read(exactly: n); counters.bytes += n
                        default: throw RFBError.malformed("encoding \(encoding)")
                        }
                    }
                }
            }
        } catch {
            if ContinuousClock.now - started < .seconds(seconds) - .milliseconds(500) { print("  error mid-stream: \(error)") }
        }
        return (counters.updates, counters.bytes, counters.pixels)
    } catch {
        print("  connection error: \(error)")
        return (0, 0, 0)
    }
}

/// Compares 32-bit and 16-bit bandwidth on the same content: two connections running in parallel.
func runDepthComparison(host: String, port: UInt16, type: RFBSecurityType, credentials: RFBCredentials, seconds: Double) async {
    let rgb565 = PixelFormat(bitsPerPixel: 16, depth: 16, isBigEndian: false, isTrueColour: true,
                             redMax: 31, greenMax: 63, blueMax: 31, redShift: 11, greenShift: 5, blueShift: 0)
    async let a = measureWire(host: host, port: port, type: type, credentials: credentials, format: .bgra8888, seconds: seconds)
    async let b = measureWire(host: host, port: port, type: type, credentials: credentials, format: rgb565, seconds: seconds)
    let (full, low) = await (a, b)
    func line(_ name: String, _ r: (updates: Int, bytes: Int, pixels: Int)) {
        print(String(format: "  %@: %d updates, %.1f MiB, %.1f Mbit/s, %.1f million pixels",
                     name, r.updates, Double(r.bytes) / 1_048_576, Double(r.bytes) * 8 / 1e6 / seconds, Double(r.pixels) / 1e6))
    }
    line("32 bit", full)
    line("16 bit", low)
    if full.bytes > 0 { print(String(format: "  16-bit uses %.0f%% of the bytes of 32-bit", Double(low.bytes) / Double(full.bytes) * 100)) }
}

/// Captures three frames at once: two 32-bit frames (A, B: measure content drift between the two captures) and one 16-bit frame (C).
/// 16-bit is correct when C differs from A by no more than A differs from B, and the per-channel error is within 5-6 bit quantisation.
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
        print(String(format: "  Full frame size: 32-bit %d KiB, 16-bit %d KiB (%.0f%%)",
                     captureA.wireBytes / 1024, captureC.wireBytes / 1024, Double(captureC.wireBytes) / Double(max(captureA.wireBytes, 1)) * 100))
        _ = captureB
        print(String(format: "  A vs B (both 32-bit, measures content drift): identical %.2f%%, within ±8 %.2f%%", drift.within * 100, ab.within * 100))
        print(String(format: "  A vs C (32-bit vs 16-bit): within ±8 %.2f%%, mean error %.2f, max %d", ac.within * 100, ac.mean, ac.worst))
        print(ac.within >= ab.within - 0.02 ? "  CONCLUSION: 16-bit matches 32-bit within quantisation (no worse than content drift)" : "  CONCLUSION: 16-bit deviates MORE than content drift, needs a closer look")
    } catch {
        print("  error: \(error)")
    }
}

/// Asks whether the server supports ExtendedDesktopSize (-308) and which screens it reports. READ-ONLY: sends no SetDesktopSize.
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
            guard header[0] == 0 else { print("  message type \(header[0])"); return }
            let rects = Int(header[2]) << 8 | Int(header[3])
            print("  First update: \(rects) rectangles")
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
                        print("       screen id=\(id) x=\(v16(4)) y=\(v16(6)) w=\(v16(8)) h=\(v16(10))")
                    }
                case -223, -224: break
                case 16:
                    let length = Int(beUInt32(try await stream.read(exactly: 4)))
                    _ = try await stream.read(exactly: length)
                default:
                    print("   (stopping: cannot read past this encoding)"); return
                }
            }
        }
        await stream.close()
    } catch {
        print("  error: \(error)")
    }
}

/// At how many bytes per pixel does the server send the cursor shape (-239) when the client asks for 16-bit? The RFC says it follows the client format (2 bytes); check for real.
/// Reads the pixel part assuming 2 bytes, then checks whether the stream has leftover bytes. READ-ONLY.
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
            let verdict = TextBox("no cursor shape seen in the first 200 updates")
            try await withTimeout(seconds: 20, onTimeout: { await stream.close() }) {
                for _ in 0..<200 {
                    let header = try await stream.read(exactly: 4)
                    guard header[0] == 0 else { verdict.text = "message type \(header[0])"; return }
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
                                verdict.text = "cursor \(w)x\(h): reading \(bpp) byte/pixel gives " + (n == 0 ? "NO leftover bytes → server sends \(bpp) byte/pixel"
                                    : "\(n) LEFTOVER bytes (≈ \(w * h * (4 - bpp)) if the server sends 4 byte/pixel)")
                            } else {
                                let next = try await stream.read(exactly: 12)
                                let nw = Int(next[4]) << 8 | Int(next[5]), nx = Int(next[0]) << 8 | Int(next[1])
                                let plausible = nx + nw <= Int(info.width) && nw > 0
                                verdict.text = "cursor \(w)x\(h): after reading \(bpp) byte/pixel, the next header is " + (plausible ? "valid" : "MEANINGLESS (stream misaligned)")
                            }
                            return
                        } else { verdict.text = "encoding \(encoding) not handled by the probe"; return }
                    }
                    try await stream.write(ClientMessage.framebufferUpdateRequest(
                        incremental: true, rect: PixelRect(x: 0, y: 0, width: Int(info.width), height: Int(info.height))
                    ).wireBytes)
                }
            }
            print("  \(format.bitsPerPixel) bit: \(verdict.text)")
            await stream.close()
        } catch {
            print("  \(format.bitsPerPixel) bit: error \(error)")
        }
    }
}

/// Apple-specific message type 8 (HandleSetServerScalingMessage): [8][0][big-endian double], scale in (0, 1].
/// The server downsizes the picture for this viewer only (the Mac's screen is unchanged). See how the server reports the new size.
func runServerScalingProbe(host: String, port: UInt16, type: RFBSecurityType, credentials: RFBCredentials, scale: Double) async {
    do {
        let (stream, info) = try await connectAndLogin(host: host, port: port, type: type, credentials: credentials)
        print("  ServerInit: \(info.width)x\(info.height); requesting scale \(scale)")
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
                guard header[0] == 0 else { print("  message type \(header[0]), stopping"); return }
                let rects = Int(header[2]) << 8 | Int(header[3])
                var line = "  update \(update): \(rects) rectangles:"
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
                    default: line += " encoding \(encoding) (stopping)"; print(line); return
                    }
                }
                print(line + "  | coverage up to \(maxX)x\(maxY)")
                try await stream.write(ClientMessage.framebufferUpdateRequest(
                    incremental: true, rect: PixelRect(x: 0, y: 0, width: Int(info.width), height: Int(info.height))
                ).wireBytes)
            }
        }
        await stream.close()
    } catch {
        print("  error: \(error)")
    }
}

/// ContinuousUpdates (pseudo-encoding -313): if the server supports it, it sends an EndOfContinuousUpdates message (type 150) right after
/// SetEncodings. READ-ONLY: does not enable that mode, only checks whether the server reports support.
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
                    case 150: return // EndOfContinuousUpdates: no body
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
        print("  server message types: \(seen.items.prefix(20))")
        print(seen.items.contains(150) ? "  → ContinuousUpdates SUPPORTED (received type 150)" : "  → type 150 NOT seen: server does not report ContinuousUpdates support")
        await stream.close()
    } catch {
        print("  error: \(error)")
    }
}

/// REAL ACTIONS ON THE MAC: moves the pointer to (x, y) then sends, via message 23, a trackpad scroll (with phases and inertia), a
/// pinch and a rotation. Runs only when the machine's owner allows it, with a test window already placed there. Finally requests a 1x1 update to see whether the
/// server kept the connection (the server closes the connection if the payload is the wrong size).
func runAppleGestureTest(host: String, port: UInt16, type: RFBSecurityType, credentials: RFBCredentials, x: UInt16, y: UInt16) async {
    do {
        let (stream, _) = try await connectAndLogin(host: host, port: port, type: type, credentials: credentials)
        func send(_ message: ClientMessage) async throws { try await stream.write(message.wireBytes) }
        func pause(_ milliseconds: Int) async { try? await Task.sleep(for: .milliseconds(milliseconds)) }
        try await send(.setPixelFormat(.bgra8888))
        try await send(.pointerEvent(buttons: 0, x: x, y: y))
        await pause(400)

        print("  scroll: began, 8 changed (+12 pt), ended, 6 inertia steps")
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

        print("  pinch: began, 10 times +0.03, ended")
        try await send(.appleEvent(.magnify(0, phase: .began, x: x, y: y)))
        for _ in 0..<10 {
            await pause(16)
            try await send(.appleEvent(.magnify(0.03, phase: .changed, x: x, y: y)))
        }
        try await send(.appleEvent(.magnify(0, phase: .ended, x: x, y: y)))
        await pause(600)

        print("  rotate: began, 10 times +3°, ended")
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
        print(alive ? "  → server kept the connection after every message 23" : "  → server CLOSED the connection (payload rejected?)")
        await stream.close()
    } catch {
        print("  error: \(error)")
    }
}

/// REAL ACTIONS ON THE MAC: like `runAppleGestureTest` but the payloads come from a file, one per line `delay_ms payload_hex` (the payload is
/// the part after the 4-byte header of message 23). For trying version, phase and mask variants when reverse engineering is not enough.
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
        print("  sent \(sent) message 23; " + (alive ? "server kept the connection" : "server CLOSED the connection"))
        await stream.close()
    } catch {
        print("  error: \(error)")
    }
}

/// Counts updates over `seconds` seconds while always keeping `outstanding` requests pending (sending a new request each time an update
/// starts to arrive). No decoding, lengths only. Also measures the time from sending a request to receiving the update header.
func measureOutstanding(
    host: String, port: UInt16, type: RFBSecurityType, credentials: RFBCredentials, outstanding: Int, seconds: Double,
    serverScale: Double = 1
) async -> (updates: Int, bytes: Int) {
    do {
        let (stream, info) = try await connectAndLogin(host: host, port: port, type: type, credentials: credentials)
        let full = PixelRect(x: 0, y: 0, width: Int(info.width), height: Int(info.height))
        var first = ClientMessage.setPixelFormat(.bgra8888).wireBytes
        first.append(ClientMessage.setEncodings([.zrle, .copyRect, .desktopSize]).wireBytes) // server-side scaling needs DesktopSize; without it the server stops sending
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
                        case -223: break // DesktopSize after scaling
                        default: throw RFBError.malformed("encoding \(encoding)")
                        }
                    }
                }
            }
        } catch {
            if ContinuousClock.now - started < .seconds(seconds) - .milliseconds(500) { print("  error mid-stream (\(outstanding) requests): \(error)") }
        }
        return (counters.updates, counters.bytes)
    } catch {
        print("  connection error: \(error)")
        return (0, 0)
    }
}

/// Order of the scale command relative to the first update request: prints every message the server sends in a few seconds for each approach.
/// READ-ONLY (scaling only affects this viewer's stream).
func runScaleOrderProbe(host: String, port: UInt16, type: RFBSecurityType, credentials: RFBCredentials) async {
    enum Order: String { case scaleFirst = "scale BEFORE the first request", scaleAfter = "scale AFTER the first request", scaleAfterThenFull = "scale AFTER, then request everything again at the new size" }
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
                        guard header[0] == 0 else { log.text += " [type \(header[0])]"; return }
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
            print("  \(order.rawValue):\(log.text.isEmpty ? " NOTHING RECEIVED in 4 seconds" : String(log.text.prefix(300)))")
            await stream.close()
        } catch {
            print("  \(order.rawValue): error \(error)")
        }
    }
}

/// Collects counts of non-pixel events while observing.
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
    /// Image bytes on the wire for this capture (ZRLE counts the compressed size).
    var wireBytes: Int
}

/// Captures a full frame: declares the encodings, requests a non-incremental update, then collects the
/// updates until they cover the whole screen area.
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

// MARK: - Command-line arguments

/// Converts a hex string (whitespace allowed) into bytes.
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
            fail("--clipboard-probe needs a number of seconds from 3 to 120", code: 64)
        }
        clipboardSeconds = seconds
    } else if argument == "--send-text" {
        guard let value = rest.popFirst() else { fail("--send-text needs a string", code: 64) }
        sendText = value
    } else if argument == "--send-apple-clipboard" {
        guard let value = rest.popFirst() else { fail("--send-apple-clipboard needs a string", code: 64) }
        sendAppleClipboard = value
    } else if argument == "--clipboard-request" {
        clipboardRequest = true
    } else if argument == "--dump-clipboard" {
        guard let value = rest.popFirst() else { fail("--dump-clipboard needs a file path", code: 64) }
        dumpClipboardPath = (value as NSString).expandingTildeInPath
    } else if argument == "--autopasteboard" {
        guard let value = rest.popFirst(), let command = UInt16(value) else { fail("--autopasteboard needs a number", code: 64) }
        autoPasteboard = command
    } else if argument == "--send-encoding" {
        guard let value = rest.popFirst(), ["latin1", "utf8", "macroman"].contains(value) else {
            fail("--send-encoding needs latin1, utf8 or macroman", code: 64)
        }
        sendEncoding = value
    } else if argument == "--record" {
        guard let value = rest.popFirst() else { fail("--record needs a file path", code: 64) }
        recordPath = (value as NSString).expandingTildeInPath
    } else if argument == "--dump-frame" {
        guard let value = rest.popFirst() else { fail("--dump-frame needs a file path", code: 64) }
        dumpFramePath = (value as NSString).expandingTildeInPath
    } else if argument == "--depth16" {
        depth16 = true // used with --watch/--record and --replay: receive and decode at 16-bit
    } else if argument == "--check-depth-image" {
        depthImageCheck = true
    } else if argument == "--compare-depth" {
        guard let value = rest.popFirst(), let seconds = Double(value), (3...120).contains(seconds) else {
            fail("--compare-depth needs a number of seconds from 3 to 120", code: 64)
        }
        compareDepthSeconds = seconds
    } else if argument == "--probe-desktop-size" {
        probeDesktopSize = true
    } else if argument == "--probe-cursor" {
        probeCursor = true
    } else if argument == "--server-scale" {
        guard let value = rest.popFirst(), let scale = Double(value), scale > 0, scale <= 1 else { fail("--server-scale needs a number in (0, 1]", code: 64) }
        serverScale = scale
    } else if argument == "--probe-scale-order" {
        probeScaleOrder = true
    } else if argument == "--probe-continuous" {
        probeContinuous = true
    } else if argument == "--compare-scale" {
        guard let value = rest.popFirst(), let seconds = Double(value), (3...120).contains(seconds) else { fail("--compare-scale needs a number of seconds 3–120", code: 64) }
        compareScaleSeconds = seconds
    } else if argument == "--compare-outstanding" {
        guard let value = rest.popFirst(), let seconds = Double(value), (3...120).contains(seconds) else { fail("--compare-outstanding needs a number of seconds 3–120", code: 64) }
        compareOutstandingSeconds = seconds
    } else if argument == "--probe-encodings" {
        probeEncodings = true
    } else if argument == "--replay" {
        guard let value = rest.popFirst() else { fail("--replay needs a file path recorded with --record", code: 64) }
        replayPath = (value as NSString).expandingTildeInPath
    } else if argument == "--size" {
        guard let value = rest.popFirst(), case let parts = value.split(separator: "x"), parts.count == 2,
              let w = Int(parts[0]), let h = Int(parts[1]) else { fail("--size needs the form WIDTHxHEIGHT, for example 2560x1440", code: 64) }
        replaySize = (w, h)
    } else if argument == "--watch-raw" {
        watchRaw = true // baseline: the main connection receives Raw instead of ZRLE
    } else if argument == "--watch" {
        guard let value = rest.popFirst(), let seconds = Int(value), (3...300).contains(seconds) else {
            fail("--watch needs a number of seconds from 3 to 300", code: 64)
        }
        watchSeconds = seconds
    } else if argument == "--compare-encodings" {
        compareEncodings = true
    } else if argument == "--snapshot" {
        guard let value = rest.popFirst() else { fail("--snapshot needs a .png file path", code: 64) }
        snapshotPath = (value as NSString).expandingTildeInPath
    } else if argument == "--login" {
        guard let value = rest.popFirst(), let raw = UInt8(value) else { fail("--login needs the number 2 or 30", code: 64) }
        loginType = RFBSecurityType(rawValue: raw)
    } else if argument == "--select" {
        guard let value = rest.popFirst(), let raw = UInt8(value) else { fail("--select needs a number 0–255", code: 64) }
        selected = RFBSecurityType(rawValue: raw)
    } else if argument == "--apple-raw" {
        guard let value = rest.popFirst() else { fail("--apple-raw needs a payload file (use together with --apple-gesture-test X,Y)", code: 64) }
        appleRawPath = value
    } else if argument == "--apple-gesture-test" {
        let parts = rest.popFirst()?.split(separator: ",").compactMap { UInt16($0) } ?? []
        guard parts.count == 2 else { fail("--apple-gesture-test needs X,Y in Mac screen pixels", code: 64) }
        gestureTestPoint = (parts[0], parts[1])
    } else if argument == "--send-hex" {
        guard let value = rest.popFirst(), let bytes = parseHex(value) else { fail("--send-hex needs a valid hex string", code: 64) }
        payload = bytes
    } else {
        positional.append(argument)
    }
}
if let replayPath {
    guard let replaySize else { fail("--replay also needs --size WIDTHxHEIGHT", code: 64) }
    await runReplay(path: replayPath, width: replaySize.width, height: replaySize.height, format: depth16 ? .rgb565 : .bgra8888)
    exit(0)
}
let host = positional.first ?? "127.0.0.1"
let port = positional.count > 1 ? UInt16(positional[1]) ?? 5900 : 5900

// MARK: - Clipboard probe

let extendedClipboardEncoding: Int32 = -1_063_131_698 // 0xC0A1E5CE

func beUInt32(_ data: Data) -> UInt32 { data.reduce(0) { ($0 << 8) | UInt32($1) } }

/// Reads the server's raw messages for `seconds` seconds. Requests only Raw (no other pseudo-encoding) and only a
/// 1x1 rectangle, so every update is small and can be parsed without a decoder.
func runClipboardProbe(stream: NWByteStream, info: ServerInit, seconds: Int, sendText: String?, sendEncoding: String, autoPasteboard: UInt16?, sendRequest: Bool, sendAppleClipboard: String?, dumpPath: String?) async {
    let clock = ProbeClock()
    @Sendable func log(_ text: String) { print(String(format: "[%6.2fs] ", clock.elapsedSeconds) + text) }

    var setEncodings = Data([2, 0, 0, 2])
    for value in [Int32(0), extendedClipboardEncoding] { setEncodings.append(contentsOf: withUnsafeBytes(of: value.bigEndian) { Array($0) }) }
    @Sendable func request(incremental: Bool) -> Data { Data([3, incremental ? 1 : 0, 0, 0, 0, 0, 0, 1, 0, 1]) }

    do {
        try await stream.write(setEncodings)
        try await stream.write(request(incremental: false))
        log("Sent SetEncodings [Raw, ExtendedClipboard(0xC0A1E5CE)]")

        if let autoPasteboard {
            // Apple message type 21: `RFBAutoPasteboardMessage`, 8 bytes including the type byte; a big-endian 16-bit number at offset 2.
            let message = Data([0x15, 0, UInt8(autoPasteboard >> 8), UInt8(autoPasteboard & 0xFF), 0, 0, 0, 0])
            try await stream.write(message)
            log("Sent AutoPasteboard (type 21) command \(autoPasteboard): \(message.map { String(format: "%02x", $0) }.joined(separator: " "))")
        }

        if let sendAppleClipboard {
            let transfer = try ClipboardTransfer(text: sendAppleClipboard, token: 0x0A0B0C0D)
            try await stream.write(ClientMessage.clipboardSend(transfer).wireBytes)
            log("Sent Apple clipboard (type 31): \(transfer.uncompressedSize) bytes uncompressed, \(transfer.compressed.count) bytes compressed")
        }

        if sendRequest {
            // Apple message type 11: ClipboardRequest, 8 bytes. Byte 1 bit 0 = request only the "promise"; bytes 4-7 are the token the server echoes back.
            let message = Data([0x0b, 0, 0, 0, 0xde, 0xad, 0xbe, 0xef])
            try await stream.write(message)
            log("Sent ClipboardRequest (type 11): \(message.map { String(format: "%02x", $0) }.joined(separator: " "))")
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
            log("Sent ClientCutText \(bytes.count) bytes, encoding \(sendEncoding): \(bytes.map { String(format: "%02x", $0) }.joined(separator: " "))")
        }

        try await withTimeout(seconds: Double(seconds), onTimeout: { await stream.close() }) { () async throws -> Void in
            while true {
                let type = try await stream.read(exactly: 1)[0]
                switch type {
                case 0:
                    let header = try await stream.read(exactly: 3)
                    let count: Int = (Int(header[1]) << 8) | Int(header[2])
                    for _ in 0..<count {
                        let rect = try await stream.read(exactly: 12)
                        let width: Int = (Int(rect[4]) << 8) | Int(rect[5])
                        let height: Int = (Int(rect[6]) << 8) | Int(rect[7])
                        let encoding = Int32(bitPattern: beUInt32(rect.suffix(4)))
                        guard encoding == 0 else { log("Rectangle with encoding \(encoding): stopping because this kind was not requested"); return }
                        var remaining = width * height * 4
                        while remaining > 0 { remaining -= try await stream.read(exactly: min(remaining, 65536)).count }
                    }
                    try await stream.write(request(incremental: true))
                case 1:
                    let header = try await stream.read(exactly: 5)
                    let colours: Int = (Int(header[3]) << 8) | Int(header[4])
                    _ = try await stream.read(exactly: colours * 6)
                    log("SetColourMapEntries \(colours) entries")
                case 2:
                    log("Bell")
                case 0x1f:
                    // Apple clipboard (same format both ways): 16-byte header then a compressed payload.
                    let header = try await stream.read(exactly: 15)
                    let flags = header[1]
                    let token = header.subdata(in: 3..<7).map { String(format: "%02x", $0) }.joined()
                    let uncompressed = beUInt32(header.subdata(in: 7..<11)), payloadSize = beUInt32(header.subdata(in: 11..<15))
                    log("Apple clipboard (type 0x1f): header[1..]=\(header.map { String(format: "%02x", $0) }.joined(separator: " "))")
                    log("   flags byte2=0x\(String(flags, radix: 16)) token=\(token) uncompressed size=\(uncompressed) payload=\(payloadSize)")
                    guard payloadSize <= 1 << 20 else { log("   payload too large, stopping"); return }
                    let payload = try await stream.read(exactly: Int(payloadSize))
                    log("   payload first 32 bytes: \(payload.prefix(32).map { String(format: "%02x", $0) }.joined(separator: " "))")
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
                            log("Standard ServerCutText, \(length) bytes: \(hex)")
                            log("   as Latin-1: \(String(data: body, encoding: .isoLatin1) ?? "?") | UTF-8: \(String(data: body, encoding: .utf8) ?? "(not valid UTF-8)")")
                        } else {
                            log("Standard ServerCutText, \(length) bytes (not a marker, content not printed)")
                        }
                    } else {
                        let size = Int(-Int64(length))
                        let body = try await stream.read(exactly: size)
                        let flags = beUInt32(body.prefix(4))
                        // Explicit types: the Swift 6.1 compiler cannot type-check tuple-literal arrays combined with filter/map.
                        let actionBits: [(UInt32, String)] = [
                            (UInt32(1) << 24, "caps"), (UInt32(1) << 25, "request"), (UInt32(1) << 26, "peek"),
                            (UInt32(1) << 27, "notify"), (UInt32(1) << 28, "provide"),
                        ]
                        let formatBits: [(UInt32, String)] = [(1, "text"), (2, "rtf"), (4, "html"), (8, "dib"), (16, "files")]
                        var actions: [String] = []
                        for (bit, name) in actionBits where flags & bit != 0 { actions.append(name) }
                        var formats: [String] = []
                        for (bit, name) in formatBits where flags & bit != 0 { formats.append(name) }
                        log("EXTENDED ServerCutText \(size) bytes, flags=0x\(String(flags, radix: 16)) actions=\(actions) formats=\(formats)")
                        if actions.contains("caps") { log("   caps: \(body.map { String(format: "%02x", $0) }.joined(separator: " "))") }
                    }
                default:
                    // Apple message of unknown length. Read what is available and print only the start (only the start, to avoid exposing content).
                    var extra = Data()
                    while extra.count < 4096 {
                        let room = 4096 - extra.count
                        guard let chunk = try? await withTimeout(seconds: 1.0, onTimeout: { }, { try await stream.readSome(maxCount: room) }) else { break }
                        extra.append(chunk)
                    }
                    log("UNKNOWN message type \(type) (0x\(String(type, radix: 16))), followed by \(extra.count) bytes, first 48 bytes: \(extra.prefix(48).map { String(format: "%02x", $0) }.joined(separator: " "))")
                    return
                }
            }
        }
    } catch ProbeError.timeout {
        log("Done after \(seconds) seconds")
    } catch {
        log("Finished: \(error)")
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

// MARK: - Run

let stream = NWByteStream(host: host, port: port)

do {
    let hello = try await withTimeout(seconds: 5, onTimeout: { await stream.close() }) {
        try await stream.connect()
        return try await Handshake.readServerHello(over: stream)
    }

    print("Host:                 \(host):\(port)")
    print("Server version:       \(hello.serverVersion)")
    print("Client replied:       \(hello.negotiatedVersion)")
    print("Security types:")
    for type in hello.securityTypes { print("  - \(type)") }

    if let loginType {
        // Real login. The password is read only from the environment and is never printed.
        guard hello.securityTypes.contains(loginType) else {
            await stream.close()
            fail("\nServer does not offer type \(loginType.rawValue).", code: 65)
        }
        let environment = ProcessInfo.processInfo.environment
        let credentials = RFBCredentials(
            username: environment["RFB_USER"] ?? "", password: environment["RFB_PASSWORD"] ?? ""
        )
        guard !credentials.password.isEmpty, loginType != .appleRemoteDesktop || !credentials.username.isEmpty else {
            await stream.close()
            fail("\nSet RFB_PASSWORD (and RFB_USER for type 30) in the environment.", code: 64)
        }
        print("\nLogging in with type \(loginType), account: \(credentials.username.isEmpty ? "(not used)" : credentials.username)")

        let info = try await withTimeout(seconds: 60, onTimeout: { await stream.close() }) {
            try await Handshake.selectSecurityType(loginType, over: stream)
            try await Authenticator.authenticate(
                type: loginType, version: hello.negotiatedVersion, credentials: credentials, over: stream
            )
            return try await Handshake.performInit(shared: true, over: stream)
        }
        print("AUTHENTICATION SUCCEEDED")
        print("Desktop name:   \(info.name)")
        print("Size:           \(info.width) x \(info.height)")
        print("Pixel format:  \(info.pixelFormat)")

        if let gestureTestPoint {
            print("\nTRYING MESSAGE 23 (real actions) at \(gestureTestPoint.x),\(gestureTestPoint.y):")
            if let appleRawPath {
                await runAppleRawTest(host: host, port: port, type: loginType, credentials: credentials, path: appleRawPath, x: gestureTestPoint.x, y: gestureTestPoint.y)
            } else {
                await runAppleGestureTest(host: host, port: port, type: loginType, credentials: credentials, x: gestureTestPoint.x, y: gestureTestPoint.y)
            }
        } else if probeScaleOrder {
            print("\nScale command order (read-only):")
            await runScaleOrderProbe(host: host, port: port, type: loginType, credentials: credentials)
        } else if probeContinuous {
            print("\nProbing ContinuousUpdates (read-only):")
            await runContinuousUpdatesProbe(host: host, port: port, type: loginType, credentials: credentials)
        } else if let compareScaleSeconds {
            print("\nComparing native size, 0.92 (iPad Air 4 landscape) and 0.46 (iPhone portrait) over \(Int(compareScaleSeconds)) seconds (three parallel connections, read-only):")
            async let full = measureOutstanding(host: host, port: port, type: loginType, credentials: credentials, outstanding: 1, seconds: compareScaleSeconds)
            async let pad = measureOutstanding(host: host, port: port, type: loginType, credentials: credentials, outstanding: 1, seconds: compareScaleSeconds, serverScale: 2360.0 / 2560)
            async let phone = measureOutstanding(host: host, port: port, type: loginType, credentials: credentials, outstanding: 1, seconds: compareScaleSeconds, serverScale: 1179.0 / 2560)
            let (a, b, c) = await (full, pad, phone)
            for (label, r) in [("native size 1.00", a), ("scaled 0.92", b), ("scaled 0.46", c)] {
                print(String(format: "  %@: %.1f updates/s, %.1f Mbit/s", label, Double(r.updates) / compareScaleSeconds, Double(r.bytes) * 8 / 1e6 / compareScaleSeconds))
            }
        } else if let compareOutstandingSeconds {
            print("\nComparing one and two outstanding requests over \(Int(compareOutstandingSeconds)) seconds (two parallel connections, read-only):")
            async let one = measureOutstanding(host: host, port: port, type: loginType, credentials: credentials, outstanding: 1, seconds: compareOutstandingSeconds)
            async let two = measureOutstanding(host: host, port: port, type: loginType, credentials: credentials, outstanding: 2, seconds: compareOutstandingSeconds)
            let (a, b) = await (one, two)
            for (label, r) in [("1 request", a), ("2 requests", b)] {
                print(String(format: "  %@: %d updates (%.1f/s), %.1f Mbit/s", label, r.updates, Double(r.updates) / compareOutstandingSeconds,
                             Double(r.bytes) * 8 / 1e6 / compareOutstandingSeconds))
            }
        } else if let serverScale {
            print("\nTrying message type 8 (the server downsizes the picture, for this viewer only):")
            await runServerScalingProbe(host: host, port: port, type: loginType, credentials: credentials, scale: serverScale)
        } else if probeCursor {
            print("\nProbing the cursor shape format (read-only):")
            await runCursorFormatProbe(host: host, port: port, type: loginType, credentials: credentials)
        } else if probeDesktopSize {
            print("\nProbing ExtendedDesktopSize (read-only, does not change the resolution):")
            await runDesktopSizeProbe(host: host, port: port, type: loginType, credentials: credentials)
        } else if depthImageCheck {
            print("\nChecking 16-bit on the real server (read-only):")
            await runDepthImageCheck(host: host, port: port, type: loginType, credentials: credentials)
        } else if let compareDepthSeconds {
            print("\nComparing 32-bit and 16-bit bandwidth over \(Int(compareDepthSeconds)) seconds (two parallel connections, read-only):")
            await runDepthComparison(host: host, port: port, type: loginType, credentials: credentials, seconds: compareDepthSeconds)
        } else if probeEncodings {
            print("\nProbing encodings and pixel formats (read-only):")
            await runEncodingProbe(host: host, port: port, type: loginType, credentials: credentials)
        } else if let clipboardSeconds {
            await runClipboardProbe(stream: stream, info: info, seconds: clipboardSeconds, sendText: sendText, sendEncoding: sendEncoding, autoPasteboard: autoPasteboard, sendRequest: clipboardRequest, sendAppleClipboard: sendAppleClipboard, dumpPath: dumpClipboardPath)
        } else if let watchSeconds {
            // Verify ZRLE across MANY consecutive updates on a single zlib stream, including CopyRect and Cursor.
            // Finally compare the accumulated frame with a Raw frame taken from the second connection.
            //
            // Two things keep the measurement from disturbing itself (the screen being captured is also the screen showing the output):
            //  1. Open the reference connection BEFORE observing, so the "sharing" indicator in the menu bar appears early
            //     and is part of the updates the main connection receives.
            //  2. Take the reference frame RIGHT when time is up and print results only AFTER that, because printing to the terminal changes the screen.
            let (referenceStream, referenceInfo) = try await connectAndLogin(host: host, port: port, type: loginType, credentials: credentials)
            let reference = try RFBSession(stream: referenceStream, serverInfo: referenceInfo)
            let recorder = try recordPath.map { try RecordingByteStream(base: stream, path: $0) }
            let session = try RFBSession(stream: recorder ?? stream, serverInfo: info, pixelFormat: depth16 ? .rgb565 : .bgra8888)
            let watchEncodings: [RFBEncoding] = watchRaw ? [.raw, .copyRect, .cursor] : [.zrle, .copyRect, .cursor]
            let first = try await captureFullFrame(session, stream: stream, encodings: watchEncodings, isFirst: true)
            print("\nFirst frame (ZRLE): \(first.wireBytes / 1024) KiB in \(first.elapsed)")
            print("Observing for \(watchSeconds) seconds. Drag windows, scroll pages, type text. KEEP the screen still for the last few seconds.")

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
                // On timeout the stream is closed and the loop throws. That is the normal ending.
                // An error BEFORE the deadline is a real decoding or protocol error.
                let elapsed = ContinuousClock.now - started
                if elapsed < .seconds(watchSeconds) - .milliseconds(500) {
                    fail("\nERROR after \(elapsed) of observing: \(error)", code: 3)
                }
            }

            // Take the reference frame immediately, before printing anything.
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
                print("\nWrote \(recordedBytes / 1024) KiB of server bytes to \(recordPath)")
            }
            if let dumpFramePath { print("Saved the frame built by the Swift decoder: \(dumpFramePath) (\(liveFrame.width)x\(liveFrame.height) BGRA)") }
            let statistics = await session.statistics
            let incrementalUpdates = statistics.updateCount - 1
            let zrleBytes = statistics.payloadBytes[.zrle] ?? 0
            let rawBytes = (statistics.payloadBytes[.raw] ?? 0) - (watchRaw ? first.wireBytes : 0)
            print("\nOver \(watchSeconds) seconds: \(incrementalUpdates) incremental updates (\(String(format: "%.1f", Double(incrementalUpdates) / Double(watchSeconds)))/s)")
            print("  Receive mode: \(watchRaw ? "Raw (baseline)" : "ZRLE"). Raw: \(rawBytes / 1024) KiB, ZRLE: \((zrleBytes - (watchRaw ? 0 : first.wireBytes)) / 1024) KiB compressed. CopyRect: \((statistics.payloadBytes[.copyRect] ?? 0) / 4) rectangles.")
            print("  Cursor events: \(await log.cursorEvents). Bells: \(await log.bells).")
            if let cursor = await log.lastCursor {
                print("  Last cursor: \(cursor.width)x\(cursor.height), hotspot (\(cursor.hotspotX), \(cursor.hotspotY))")
            }

            if let difference = liveFrame.difference(from: referenceFrame) {
                let percent = Double(difference.count) / Double(Int(info.width) * Int(info.height)) * 100
                print("\nAccumulated frame compared with the reference Raw frame (second connection): \(difference.count) pixels differ (\(String(format: "%.4f", percent))%)")
                if let bounds = difference.bounds { print("  smallest differing region: \(bounds)") }
                // Where the differences concentrate: 128x128 grid cells, the busiest first (at most 8 cells).
                for cell in (liveFrame.differenceCells(from: referenceFrame) ?? []).prefix(8) {
                    print("  cell x \(cell.rect.x)..<\(cell.rect.x + cell.rect.width), y \(cell.rect.y)..<\(cell.rect.y + cell.rect.height): \(cell.count) pixels")
                }
            }
        } else if snapshotPath != nil || compareEncodings {
            let session = try RFBSession(stream: stream, serverInfo: info)
            let totalPixels = Int(info.width) * Int(info.height)

            let raw = try await captureFullFrame(session, stream: stream, encodings: [.raw], isFirst: true)
            print("\nRaw:   \(raw.rectCount) rectangles, \(raw.wireBytes / 1024) KiB on the wire, \(raw.elapsed)")
            let rawFrame = await session.framebuffer
            var finalFrame = rawFrame

            if compareEncodings {
                // Request the whole frame again with ZRLE (plus Cursor) on the same connection, then compare pixel by pixel with the Raw one.
                // If the screen is still the two must be identical; that is a check independent of the decoding code.
                let zrle = try await captureFullFrame(session, stream: stream, encodings: [.zrle, .cursor], isFirst: false)
                print("ZRLE:  \(zrle.rectCount) rectangles, \(zrle.wireBytes / 1024) KiB on the wire, \(zrle.elapsed)")
                if zrle.wireBytes > 0 {
                    print("ZRLE compression ratio versus Raw: \(String(format: "%.1f", Double(raw.wireBytes) / Double(zrle.wireBytes)))×")
                }
                let zrleFrame = await session.framebuffer
                if let difference = rawFrame.difference(from: zrleFrame) {
                    let percent = Double(difference.count) / Double(totalPixels) * 100
                    print("Raw vs ZRLE comparison: \(difference.count) pixels differ (\(String(format: "%.4f", percent))%)")
                    if let bounds = difference.bounds { print("  smallest differing region: \(bounds)") }
                }
                if let cursor = zrle.cursor {
                    print("Cursor received: \(cursor.width)x\(cursor.height), hotspot (\(cursor.hotspotX), \(cursor.hotspotY))")
                } else {
                    print("No separate cursor shape received (the server may draw the cursor into the frame).")
                }
                finalFrame = zrleFrame
            }

            if let snapshotPath {
                guard let image = finalFrame.makeCGImage() else { fail("Could not create a CGImage", code: 1) }
                try writePNG(image, to: snapshotPath)
                print("Saved: \(snapshotPath)")
            }
            await session.close()
        }
    } else if let selected {
        guard hello.securityTypes.contains(selected) else {
            await stream.close()
            fail("\nServer does not offer type \(selected.rawValue), cannot select it.", code: 65)
        }
        try await Handshake.selectSecurityType(selected, over: stream)
        if let payload {
            try await stream.write(payload)
            print("\nSent \(payload.count) bytes after selecting the type (no password included).")
        }

        // Collect every byte the server sends until 1.5 seconds of silence or the limit is reached.
        var reply = Data()
        var ending = "reached the 4096 byte limit"
        while reply.count < 4096 {
            let remaining = 4096 - reply.count
            do {
                let chunk = try await withTimeout(seconds: 1.5, onTimeout: { await stream.close() }) {
                    try await stream.readSome(maxCount: remaining)
                }
                reply.append(chunk)
            } catch ProbeError.timeout {
                ending = "server silent for 1.5 seconds"
                break
            } catch {
                ending = "connection ended (\(error))"
                break
            }
        }
        print("\nSelected type \(selected). Server returned \(reply.count) bytes (\(ending)):")
        if !reply.isEmpty { print(hexDump(reply)) }
    }
    await stream.close()
} catch ProbeError.timeout {
    fail("Timed out (5 seconds) connecting to \(host):\(port)", code: 2)
} catch {
    fail("Error: \(error)", code: 1)
}
