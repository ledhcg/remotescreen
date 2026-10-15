import Foundation
import Testing
@testable import RFBKit

private let marker = "rfbprobe-marker-request đệ café"

private func realTransfer() -> ClipboardTransfer {
    ClipboardTransfer(
        token: ClipboardVectors.realServerToken, uncompressedSize: ClipboardVectors.realServerUncompressedSize,
        compressed: bytes(hex: ClipboardVectors.realServerPayload)
    )
}

@Suite("Apple clipboard: decoding the server's real payload")
struct RealPayloadTests {
    @Test func decodesTheCapturedServerPayloadIntoThreeRepresentations() throws {
        let payload = try realTransfer().decodePayload()
        #expect(payload.representations.map(\.uti) == [
            "public.utf8-plain-text", "com.apple.traditional-mac-plain-text", "public.utf16-plain-text",
        ])
        #expect(payload.text == marker, "UTF-8 must preserve đ, ệ, é")
    }

    @Test func eachRepresentationCarriesTheObservedAttributesAndBytes() throws {
        let reps = try realTransfer().decodePayload().representations
        #expect(reps[0].attributes == [
            .init(key: "com.apple.ostype", value: "utf8"),
            .init(key: "com.apple.nspboard-type", value: "NSStringPboardType"),
            .init(key: "public.mime-type", value: "text/plain;charset=utf-8"),
        ])
        #expect(reps[0].data == Data(marker.utf8))
        // MacRoman cannot represent "đệ" and "café" here so the server truncated to the leading ASCII part: 24 bytes.
        #expect(reps[1].attributes == [.init(key: "com.apple.ostype", value: "TEXT")])
        #expect(String(data: reps[1].data, encoding: .macOSRoman) == "rfbprobe-marker-request ")
        #expect(reps[2].attributes.map(\.value) == ["utxt", "text/plain;charset=utf-16"])
        #expect(reps[2].data == marker.data(using: .utf16BigEndian), "UTF-16 big-endian, no BOM")
        #expect(reps.allSatisfy { $0.flags == 0 })
    }

    /// Parsing then re-encoding must give exactly the same bytes: evidence that we understand the whole format and miss no field.
    @Test func parsingThenSerialisingReproducesTheServerBytesExactly() throws {
        let raw = try ClipboardZlib.inflate(bytes(hex: ClipboardVectors.realServerPayload), maxOutput: 1 << 20)
        #expect(raw.count == 484)
        #expect(try PasteboardPayload(serialized: raw).serialized() == raw)
    }

    @Test func theCapturedStreamIsNotClosedAndStillDecodes() throws {
        // Apple's server sends an unclosed zlib stream (Z_SYNC_FLUSH): the decoder must not require Z_STREAM_END.
        let raw = try ClipboardZlib.inflate(bytes(hex: ClipboardVectors.realServerPayload), maxOutput: 1 << 20)
        #expect(raw.count == 484)
    }
}

@Suite("Apple clipboard: independent compressor (Python)")
struct PythonVectorTests {
    @Test func decodesVietnameseTextCompressedByPythonSyncFlush() throws {
        let transfer = ClipboardTransfer(
            token: 1, uncompressedSize: ClipboardVectors.pythonUncompressedSize,
            compressed: bytes(hex: ClipboardVectors.pythonSyncFlushPayload)
        )
        #expect(try transfer.decodePayload().text == ClipboardVectors.vietnameseText)
    }

    @Test func decodesAClosedStreamToo() throws {
        let transfer = ClipboardTransfer(
            token: 1, uncompressedSize: ClipboardVectors.pythonUncompressedSize,
            compressed: bytes(hex: ClipboardVectors.pythonClosedPayload)
        )
        #expect(try transfer.decodePayload().text == ClipboardVectors.vietnameseText)
    }

    @Test func utf16RepresentationAloneAlsoGivesTheText() throws {
        var payload = try ClipboardTransfer(
            token: 1, uncompressedSize: ClipboardVectors.pythonUncompressedSize,
            compressed: bytes(hex: ClipboardVectors.pythonSyncFlushPayload)
        ).decodePayload()
        payload.representations.removeAll { $0.uti == PasteboardPayload.utf8Text }
        #expect(payload.text == ClipboardVectors.vietnameseText, "emoji outside the BMP goes through UTF-16 surrogate pairs")
    }
}

@Suite("Apple clipboard: encoding")
struct EncodingTests {
    @Test(arguments: [
        "", "a", "Hello, world", "Xin chào, Việt Nam đẹp lắm", "đệ ố ữ ặ", "dòng 1\ndòng 2\r\nTab\there", "🙂🎉 emoji", "日本語のテキスト",
        String(repeating: "ệ", count: 100_000),
    ])
    func roundTrip(text: String) throws {
        let transfer = try ClipboardTransfer(text: text, token: 7)
        #expect(try transfer.decodePayload().text == text)
        #expect(transfer.token == 7)
    }

    @Test func compressedStreamLooksLikeAppleAndIsNotClosed() throws {
        let transfer = try ClipboardTransfer(text: "xin chào")
        #expect(Array(transfer.compressed.prefix(2)) == [0x78, 0xDA], "zlib level 9 like Apple's server")
        // Decompressing with the system zlib must show an unclosed stream but with all the data.
        let raw = try ClipboardZlib.inflate(transfer.compressed, maxOutput: 1 << 20)
        #expect(raw.count == Int(transfer.uncompressedSize))
    }

    @Test func sendsUTF8AndUTF16WithTheObservedAttributes() throws {
        let payload = PasteboardPayload(text: "đ")
        #expect(payload.representations.map(\.uti) == ["public.utf8-plain-text", "public.utf16-plain-text"])
        #expect(payload.representations[0].data == Data("đ".utf8))
        #expect(payload.representations[1].data == Data([0x01, 0x11]))
    }

    @Test func wireBytesFollowTheObservedHeaderLayout() throws {
        let transfer = ClipboardTransfer(token: 0x0102_0304, flags: 1, uncompressedSize: 0x0A0B_0C0D, compressed: Data([0xAA, 0xBB, 0xCC]))
        #expect(transfer.wireBytes == Data([
            31, 0, 1, 0, // type, 0, flags, 0
            1, 2, 3, 4, // token
            0x0A, 0x0B, 0x0C, 0x0D, // uncompressed size
            0, 0, 0, 3, // compressed size
            0xAA, 0xBB, 0xCC,
        ]))
    }

    @Test func requestWireBytesMatchTheMessageThatServerAnswered() {
        // Exactly the 8 bytes that rfbprobe sent and Apple's server answered: `0b 00 00 00 de ad be ef`.
        #expect(ClientMessage.clipboardRequest(token: 0xDEAD_BEEF).wireBytes == Data([0x0B, 0, 0, 0, 0xDE, 0xAD, 0xBE, 0xEF]))
    }

    @Test func tooLargeTextIsRefusedInsteadOfBuildingAHugeMessage() {
        let huge = String(repeating: "x", count: ClipboardTransfer.maxUncompressed + 1)
        #expect(throws: RFBError.self) { try ClipboardTransfer(text: huge) }
    }
}

@Suite("Apple clipboard: corrupt or malicious data")
struct MalformedTests {
    /// Truncate the real payload at EVERY length: it must produce an error, not crash or hang.
    @Test func everyTruncationOfARealPayloadFailsCleanly() throws {
        let raw = try ClipboardZlib.inflate(bytes(hex: ClipboardVectors.realServerPayload), maxOutput: 1 << 20)
        for length in 0..<raw.count {
            #expect(throws: RFBError.self, "truncated to \(length) bytes") { try PasteboardPayload(serialized: raw.prefix(length)) }
        }
    }

    @Test func lyingLengthPrefixesAreRejected() {
        // 1 representation, UTI declares a length of 4 GiB but only a few bytes remain.
        let data = Data([0, 0, 0, 1, 0xFF, 0xFF, 0xFF, 0xFF, 0x41])
        #expect(throws: RFBError.self) { try PasteboardPayload(serialized: data) }
    }

    @Test func absurdCountsAreRejectedBeforeLooping() {
        #expect(throws: RFBError.self) { try PasteboardPayload(serialized: Data([0xFF, 0xFF, 0xFF, 0xFF])) }
        // 1 representation, empty UTI, flags 0, then 4 billion attributes.
        let data = Data([0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF])
        #expect(throws: RFBError.self) { try PasteboardPayload(serialized: data) }
    }

    @Test func nonUTF8UTIsAreRejected() {
        let data = Data([0, 0, 0, 1, 0, 0, 0, 2, 0xFF, 0xFE])
        #expect(throws: RFBError.self) { try PasteboardPayload(serialized: data) }
    }

    /// A tiny compressed input decompresses to something huge (zip bomb): stopped at the declared size.
    @Test func zipBombIsStoppedAtTheDeclaredSize() throws {
        let bomb = try ClipboardZlib.deflate(Data(count: 50_000_000)) // 50 MB of zeros compresses to a few tens of KB
        #expect(bomb.count < 100_000)
        let transfer = ClipboardTransfer(token: 0, uncompressedSize: 1_000, compressed: bomb)
        #expect(throws: RFBError.self) { try transfer.decodePayload() }
    }

    /// First line of defense: the cap must stop it RIGHT during decompression, not let 50 MB be allocated and only then compare sizes.
    @Test func inflateItselfStopsAtTheCapWithoutProducingTheWholeBomb() throws {
        let bomb = try ClipboardZlib.deflate(Data(count: 50_000_000))
        #expect(throws: RFBError.self) { try ClipboardZlib.inflate(bomb, maxOutput: 1_000) }
        // With enough room, decompress normally.
        #expect(try ClipboardZlib.inflate(bomb, maxOutput: 50_000_000).count == 50_000_000)
    }

    @Test func declaredSizeMustMatchTheRealOne() throws {
        var transfer = realTransfer()
        transfer.uncompressedSize = 483 // lower than the real size
        #expect(throws: RFBError.self) { try transfer.decodePayload() }
        transfer.uncompressedSize = 485 // higher than the real size
        #expect(throws: RFBError.self) { try transfer.decodePayload() }
    }

    @Test func declaredSizeAboveTheCapIsRefusedWithoutInflating() {
        let transfer = ClipboardTransfer(token: 0, uncompressedSize: UInt32(ClipboardTransfer.maxUncompressed) + 1, compressed: Data([0x78, 0xDA]))
        #expect(throws: RFBError.self) { try transfer.decodePayload() }
    }

    @Test func garbageCompressedDataFails() {
        #expect(throws: RFBError.self) { try ClipboardTransfer(token: 0, uncompressedSize: 10, compressed: Data(repeating: 0x55, count: 20)).decodePayload() }
    }

    /// Flip each bit of the real payload: it may or may not decode, but must never crash.
    @Test func bitFlipsNeverCrash() {
        let original = realTransfer()
        for index in stride(from: 0, to: original.compressed.count, by: 7) {
            var corrupted = original
            corrupted.compressed[corrupted.compressed.startIndex + index] ^= 0x10
            _ = try? corrupted.decodePayload()
        }
    }
}

@Suite("Apple clipboard: receiving in a session")
struct ClipboardSessionTests {
    private func serverMessage(token: UInt32, uncompressed: UInt32, payload: Data) -> [UInt8] {
        Array(ClipboardTransfer(token: token, uncompressedSize: uncompressed, compressed: payload).wireBytes)
    }

    @Test func parsesTheRealServerReplyIntoAClipboardEvent() async throws {
        let message = serverMessage(token: 0xDEAD_BEEF, uncompressed: 484, payload: bytes(hex: ClipboardVectors.realServerPayload))
        let (session, _) = try makeSession(message)
        guard case .clipboard(let transfer) = try await session.nextEvent() else { Issue.record("not a clipboard event"); return }
        #expect(transfer.token == 0xDEAD_BEEF)
        #expect(try transfer.decodePayload().text == marker)
    }

    @Test func aMessageFollowingTheClipboardIsStillReadInSync() async throws {
        // After the clipboard comes a Bell (type 2): if the read consumed too few or too many bytes, the next event would be wrong.
        let message = serverMessage(token: 1, uncompressed: 484, payload: bytes(hex: ClipboardVectors.realServerPayload)) + [2]
        let (session, _) = try makeSession(message)
        _ = try await session.nextEvent()
        guard case .bell = try await session.nextEvent() else { Issue.record("lost sync after the clipboard"); return }
    }

    @Test func oversizedHeaderIsRejectedBeforeReadingThePayload() async throws {
        var header = Data([31, 0, 0, 0, 0, 0, 0, 1])
        header.appendBigEndian(UInt32(ClipboardTransfer.maxUncompressed) + 1)
        header.appendBigEndian(UInt32(10))
        let (session, _) = try makeSession(Array(header))
        await #expect(throws: RFBError.self) { try await session.nextEvent() }

        var header2 = Data([31, 0, 0, 0, 0, 0, 0, 1])
        header2.appendBigEndian(UInt32(100))
        header2.appendBigEndian(UInt32(ClipboardTransfer.maxCompressed) + 1)
        let (session2, _) = try makeSession(Array(header2))
        await #expect(throws: RFBError.self) { try await session2.nextEvent() }
    }

    @Test func requestIsSentInOrderThroughThePostQueue() async throws {
        let (session, stream) = try makeSession([])
        session.post([.keyEvent(isDown: true, keysym: 0x63), .clipboardRequest(token: 5), .keyEvent(isDown: false, keysym: 0x63)])
        try await Task.sleep(for: .milliseconds(100))
        let expected = ClientMessage.keyEvent(isDown: true, keysym: 0x63).wireBytes
            + ClientMessage.clipboardRequest(token: 5).wireBytes
            + ClientMessage.keyEvent(isDown: false, keysym: 0x63).wireBytes
        #expect(await stream.written == expected)
    }
}

@Suite("ServerFlavor")
struct ServerFlavorTests {
    @Test func appleAdvertisesVersion889() {
        #expect(ServerFlavor(serverVersion: RFBVersion(major: 3, minor: 889)) == .apple)
    }

    @Test(arguments: [RFBVersion.v3_3, .v3_7, .v3_8, RFBVersion(major: 3, minor: 888), RFBVersion(major: 4, minor: 889)])
    func everythingElseIsStandard(version: RFBVersion) {
        #expect(ServerFlavor(serverVersion: version) == .standard)
    }
}
