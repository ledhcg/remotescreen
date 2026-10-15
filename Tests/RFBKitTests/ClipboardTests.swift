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

@Suite("Clipboard Apple: giải mã payload thật của server")
struct RealPayloadTests {
    @Test func decodesTheCapturedServerPayloadIntoThreeRepresentations() throws {
        let payload = try realTransfer().decodePayload()
        #expect(payload.representations.map(\.uti) == [
            "public.utf8-plain-text", "com.apple.traditional-mac-plain-text", "public.utf16-plain-text",
        ])
        #expect(payload.text == marker, "UTF-8 phải giữ nguyên đ, ệ, é")
    }

    @Test func eachRepresentationCarriesTheObservedAttributesAndBytes() throws {
        let reps = try realTransfer().decodePayload().representations
        #expect(reps[0].attributes == [
            .init(key: "com.apple.ostype", value: "utf8"),
            .init(key: "com.apple.nspboard-type", value: "NSStringPboardType"),
            .init(key: "public.mime-type", value: "text/plain;charset=utf-8"),
        ])
        #expect(reps[0].data == Data(marker.utf8))
        // MacRoman không biểu diễn được "đệ" và "café" ở đây nên server cắt còn phần ASCII đầu: 24 byte.
        #expect(reps[1].attributes == [.init(key: "com.apple.ostype", value: "TEXT")])
        #expect(String(data: reps[1].data, encoding: .macOSRoman) == "rfbprobe-marker-request ")
        #expect(reps[2].attributes.map(\.value) == ["utxt", "text/plain;charset=utf-16"])
        #expect(reps[2].data == marker.data(using: .utf16BigEndian), "UTF-16 big-endian, không BOM")
        #expect(reps.allSatisfy { $0.flags == 0 })
    }

    /// Phân tích rồi mã hóa lại phải ra đúng từng byte: bằng chứng ta hiểu trọn định dạng, không bỏ sót trường nào.
    @Test func parsingThenSerialisingReproducesTheServerBytesExactly() throws {
        let raw = try ClipboardZlib.inflate(bytes(hex: ClipboardVectors.realServerPayload), maxOutput: 1 << 20)
        #expect(raw.count == 484)
        #expect(try PasteboardPayload(serialized: raw).serialized() == raw)
    }

    @Test func theCapturedStreamIsNotClosedAndStillDecodes() throws {
        // Server Apple gửi luồng zlib không đóng (Z_SYNC_FLUSH): bộ giải mã không được đòi Z_STREAM_END.
        let raw = try ClipboardZlib.inflate(bytes(hex: ClipboardVectors.realServerPayload), maxOutput: 1 << 20)
        #expect(raw.count == 484)
    }
}

@Suite("Clipboard Apple: bộ nén độc lập (Python)")
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
        #expect(payload.text == ClipboardVectors.vietnameseText, "emoji nằm ngoài BMP đi qua cặp thay thế UTF-16")
    }
}

@Suite("Clipboard Apple: mã hóa")
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
        #expect(Array(transfer.compressed.prefix(2)) == [0x78, 0xDA], "zlib mức 9 như server Apple")
        // Giải nén bằng zlib hệ thống phải thấy luồng chưa đóng nhưng đủ dữ liệu.
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
            31, 0, 1, 0, // loại, 0, cờ, 0
            1, 2, 3, 4, // mã
            0x0A, 0x0B, 0x0C, 0x0D, // kích thước giải nén
            0, 0, 0, 3, // kích thước nén
            0xAA, 0xBB, 0xCC,
        ]))
    }

    @Test func requestWireBytesMatchTheMessageThatServerAnswered() {
        // Đúng 8 byte mà rfbprobe đã gửi và server Apple trả lời: `0b 00 00 00 de ad be ef`.
        #expect(ClientMessage.clipboardRequest(token: 0xDEAD_BEEF).wireBytes == Data([0x0B, 0, 0, 0, 0xDE, 0xAD, 0xBE, 0xEF]))
    }

    @Test func tooLargeTextIsRefusedInsteadOfBuildingAHugeMessage() {
        let huge = String(repeating: "x", count: ClipboardTransfer.maxUncompressed + 1)
        #expect(throws: RFBError.self) { try ClipboardTransfer(text: huge) }
    }
}

@Suite("Clipboard Apple: dữ liệu hỏng hay độc hại")
struct MalformedTests {
    /// Cắt payload thật tại MỌI độ dài: phải cho lỗi, không được sập hay treo.
    @Test func everyTruncationOfARealPayloadFailsCleanly() throws {
        let raw = try ClipboardZlib.inflate(bytes(hex: ClipboardVectors.realServerPayload), maxOutput: 1 << 20)
        for length in 0..<raw.count {
            #expect(throws: RFBError.self, "cắt còn \(length) byte") { try PasteboardPayload(serialized: raw.prefix(length)) }
        }
    }

    @Test func lyingLengthPrefixesAreRejected() {
        // 1 biểu diễn, UTI khai dài 4 GiB nhưng chỉ còn vài byte.
        let data = Data([0, 0, 0, 1, 0xFF, 0xFF, 0xFF, 0xFF, 0x41])
        #expect(throws: RFBError.self) { try PasteboardPayload(serialized: data) }
    }

    @Test func absurdCountsAreRejectedBeforeLooping() {
        #expect(throws: RFBError.self) { try PasteboardPayload(serialized: Data([0xFF, 0xFF, 0xFF, 0xFF])) }
        // 1 biểu diễn, UTI rỗng, flags 0, rồi 4 tỉ thuộc tính.
        let data = Data([0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF])
        #expect(throws: RFBError.self) { try PasteboardPayload(serialized: data) }
    }

    @Test func nonUTF8UTIsAreRejected() {
        let data = Data([0, 0, 0, 1, 0, 0, 0, 2, 0xFF, 0xFE])
        #expect(throws: RFBError.self) { try PasteboardPayload(serialized: data) }
    }

    /// Dữ liệu nén bé xíu giải ra khổng lồ (zip bomb): chặn ở kích thước khai báo.
    @Test func zipBombIsStoppedAtTheDeclaredSize() throws {
        let bomb = try ClipboardZlib.deflate(Data(count: 50_000_000)) // 50 MB số 0 nén còn vài chục KB
        #expect(bomb.count < 100_000)
        let transfer = ClipboardTransfer(token: 0, uncompressedSize: 1_000, compressed: bomb)
        #expect(throws: RFBError.self) { try transfer.decodePayload() }
    }

    /// Lớp phòng thủ thứ nhất: trần phải chặn NGAY trong lúc giải nén, không để 50 MB cấp phát xong rồi mới so kích thước.
    @Test func inflateItselfStopsAtTheCapWithoutProducingTheWholeBomb() throws {
        let bomb = try ClipboardZlib.deflate(Data(count: 50_000_000))
        #expect(throws: RFBError.self) { try ClipboardZlib.inflate(bomb, maxOutput: 1_000) }
        // Đủ chỗ thì giải nén bình thường.
        #expect(try ClipboardZlib.inflate(bomb, maxOutput: 50_000_000).count == 50_000_000)
    }

    @Test func declaredSizeMustMatchTheRealOne() throws {
        var transfer = realTransfer()
        transfer.uncompressedSize = 483 // thấp hơn thật
        #expect(throws: RFBError.self) { try transfer.decodePayload() }
        transfer.uncompressedSize = 485 // cao hơn thật
        #expect(throws: RFBError.self) { try transfer.decodePayload() }
    }

    @Test func declaredSizeAboveTheCapIsRefusedWithoutInflating() {
        let transfer = ClipboardTransfer(token: 0, uncompressedSize: UInt32(ClipboardTransfer.maxUncompressed) + 1, compressed: Data([0x78, 0xDA]))
        #expect(throws: RFBError.self) { try transfer.decodePayload() }
    }

    @Test func garbageCompressedDataFails() {
        #expect(throws: RFBError.self) { try ClipboardTransfer(token: 0, uncompressedSize: 10, compressed: Data(repeating: 0x55, count: 20)).decodePayload() }
    }

    /// Lật từng bit của payload thật: có thể giải được hay không, nhưng không bao giờ sập.
    @Test func bitFlipsNeverCrash() {
        let original = realTransfer()
        for index in stride(from: 0, to: original.compressed.count, by: 7) {
            var corrupted = original
            corrupted.compressed[corrupted.compressed.startIndex + index] ^= 0x10
            _ = try? corrupted.decodePayload()
        }
    }
}

@Suite("Clipboard Apple: nhận trong phiên")
struct ClipboardSessionTests {
    private func serverMessage(token: UInt32, uncompressed: UInt32, payload: Data) -> [UInt8] {
        Array(ClipboardTransfer(token: token, uncompressedSize: uncompressed, compressed: payload).wireBytes)
    }

    @Test func parsesTheRealServerReplyIntoAClipboardEvent() async throws {
        let message = serverMessage(token: 0xDEAD_BEEF, uncompressed: 484, payload: bytes(hex: ClipboardVectors.realServerPayload))
        let (session, _) = try makeSession(message)
        guard case .clipboard(let transfer) = try await session.nextEvent() else { Issue.record("không phải sự kiện clipboard"); return }
        #expect(transfer.token == 0xDEAD_BEEF)
        #expect(try transfer.decodePayload().text == marker)
    }

    @Test func aMessageFollowingTheClipboardIsStillReadInSync() async throws {
        // Sau clipboard là một Bell (loại 2): nếu đọc thiếu hay thừa byte thì sự kiện kế tiếp sẽ sai.
        let message = serverMessage(token: 1, uncompressed: 484, payload: bytes(hex: ClipboardVectors.realServerPayload)) + [2]
        let (session, _) = try makeSession(message)
        _ = try await session.nextEvent()
        guard case .bell = try await session.nextEvent() else { Issue.record("mất đồng bộ sau clipboard"); return }
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
