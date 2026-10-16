import Foundation
import Testing
@testable import LinkProtocol

@Suite("Link: malicious input")
struct LinkMaliciousInputTests {
    // MARK: Framing

    @Test func unknownMandatoryTypeIsAnError() {
        #expect(throws: LinkError.unsupportedMessage(0x7FFF)) { try decodeAll(rawFrame(type: 0x7FFF, payload: [])) }
        #expect(throws: LinkError.unsupportedMessage(0)) { try decodeAll(rawFrame(type: 0, payload: [1, 2])) }
    }

    @Test func unknownIgnorableTypeIsSkippedByLength() throws {
        let ping = try LinkFrameEncoder.encode(.ping(timestampMicros: 5))
        let stream = rawFrame(type: 0x8001, payload: [1, 2, 3]) + rawFrame(type: 0xFFFF, payload: []) + [UInt8](ping)
        #expect(try decodeAll(stream) == [.ping(timestampMicros: 5)])

        var decoder = LinkFrameDecoder()
        var out: [LinkMessage] = []
        for byte in stream { out += try decoder.feed(bytes: [byte]) }
        #expect(out == [.ping(timestampMicros: 5)])
    }

    @Test func largeIgnorablePayloadIsSkippedWithoutBuffering() throws {
        var decoder = LinkFrameDecoder()
        let header = rawFrame(type: 0x9000, length: UInt32(LinkLimits.maxIgnorablePayloadBytes), payload: [])
        #expect(try decoder.feed(bytes: header).isEmpty)
        for _ in 0..<16 { #expect(try decoder.feed(bytes: [UInt8](repeating: 0, count: 1 << 20)).isEmpty) }
        #expect(decoder.bufferedByteCount == 0)
        #expect(try decoder.feed(Data(try LinkFrameEncoder.encode(.approvalRequired))) == [.approvalRequired])
    }

    @Test func ignorableAboveCapIsRejected() {
        #expect(isLimit(frameError(rawFrame(type: 0x8000, length: UInt32(LinkLimits.maxIgnorablePayloadBytes + 1), payload: []))))
    }

    @Test func fourGiBLengthThrowsWithoutBuffering() {
        for type in [LinkMessageType.ping, .videoFrame, .clipboardData, .snapshot] {
            var decoder = LinkFrameDecoder()
            #expect(throws: LinkError.self) { try decoder.feed(bytes: rawFrame(type, length: UInt32.max, payload: [])) }
            #expect(decoder.bufferedByteCount == 0)
        }
        var decoder = LinkFrameDecoder()
        #expect(throws: LinkError.self) { try decoder.feed(bytes: rawFrame(type: 0x8000, length: UInt32.max, payload: [])) }
    }

    @Test func controlMessageAboveOneMiBIsRejectedBeforeBuffering() {
        var decoder = LinkFrameDecoder()
        let length = UInt32(LinkLimits.maxControlMessageBytes + 1)
        #expect(isLimit(captureError { try decoder.feed(bytes: rawFrame(.ping, length: length, payload: [1, 2, 3])) }))
        #expect(decoder.bufferedByteCount == 0)
    }

    @Test func perTypeCapsAreEnforcedAtTheHeader() {
        #expect(isLimit(frameError(rawFrame(.videoFrame, length: UInt32(LinkLimits.maxVideoAccessUnitBytes + 1 << 12), payload: []))))
        #expect(isLimit(frameError(rawFrame(.clipboardData, length: UInt32(LinkLimits.maxClipboardBytes + 1 << 12), payload: []))))
        #expect(isLimit(frameError(rawFrame(.fileChunk, length: UInt32(LinkLimits.maxFileChunkBytes + 1 << 12), payload: []))))
    }

    @Test func partialHeaderWaitsForMore() throws {
        var decoder = LinkFrameDecoder()
        #expect(try decoder.feed(bytes: [0x05, 0x00, 0x08]).isEmpty)
        #expect(decoder.bufferedByteCount == 3)
        #expect(try decoder.feed(bytes: [0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0]) == [.ping(timestampMicros: 1)])
    }

    @Test func decoderStaysFailedAfterAnError() throws {
        var decoder = LinkFrameDecoder()
        #expect(throws: LinkError.self) { try decoder.feed(bytes: rawFrame(type: 0x0FFF, payload: [])) }
        #expect(throws: LinkError.self) { try decoder.feed(Data(try LinkFrameEncoder.encode(.approvalRequired))) }
    }

    @Test func messageWithTrailingBytesIsMalformed() {
        #expect(isMalformed(payloadError(.approvalRequired, [0])))
        #expect(isMalformed(payloadError(.sasConfirm, [0])))
        #expect(isMalformed(payloadError(.ping, wireBytes(9))))
        #expect(isMalformed(payloadError(.windowDestroyed, wireBytes(5))))
    }

    @Test func zeroLengthPayloadsAreTruncated() {
        for type in LinkMessageType.allCases where type != .approvalRequired && type != .sasConfirm {
            let error = payloadError(type, [])
            #expect(isMalformed(error) || type == .menuTree, "\(type): \(String(describing: error))")
        }
        #expect(isMalformed(payloadError(.menuTree, [])))
    }

    @Test func everyTruncationOfEveryMessageThrowsCleanly() throws {
        for message in Samples.all {
            let payload = try message.encodePayload()
            for cut in 0..<payload.count {
                let error = payloadError(message.type, Array(payload[..<cut]))
                #expect(error != nil, "\(message.type) cut at \(cut) decoded")
            }
        }
    }

    // MARK: Strings

    @Test func stringLongerThanCapIsRejected() {
        let tooLong = wireString(String(repeating: "a", count: LinkLimits.maxBundleIDBytes + 1))
        #expect(isLimit(payloadError(.appsLaunch, tooLong)))
        #expect(isLimit(payloadError(.inputText, wireString(String(repeating: "a", count: LinkLimits.maxTextInputBytes + 1)))))
        #expect(isLimit(payloadError(.close, [0, 0] + wireString(String(repeating: "a", count: LinkLimits.maxReasonBytes + 1)))))
    }

    @Test func stringLengthBeyondPayloadIsMalformed() {
        #expect(isMalformed(payloadError(.appsLaunch, [200, 0, 65, 66])))
        #expect(isMalformed(payloadError(.inputText, [0xFF, 0x03])))
    }

    @Test func invalidUTF8IsRejected() {
        for bad: [UInt8] in [[0xC0, 0xAF], [0xFF], [0xE2, 0x82], [0xED, 0xA0, 0x80], [0xF8, 0x88, 0x80, 0x80, 0x80]] {
            #expect(isMalformed(payloadError(.inputText, [UInt8(bad.count), 0] + bad)), "\(bad)")
        }
    }

    // MARK: Numbers

    @Test func nonFiniteAndAbsurdCoordinatesAreRejected() {
        func pointer(_ x: Double, _ y: Double) -> [UInt8] {
            var w = LinkWriter()
            w.u32(1); w.u64(x.bitPattern); w.u64(y.bitPattern); w.u8(0); w.u16(0); w.u8(0)
            return w.bytes
        }
        #expect(payloadError(.inputPointer, pointer(1, 2)) == nil)
        for bad in [Double.nan, .infinity, -.infinity, 1e300, -2_000_000] {
            #expect(isMalformed(payloadError(.inputPointer, pointer(bad, 0))), "\(bad)")
            #expect(isMalformed(payloadError(.inputPointer, pointer(0, bad))), "\(bad)")
        }
    }

    @Test func nonFiniteScrollAndGestureValuesAreRejected() {
        func scroll(_ dx: Double) -> [UInt8] {
            var w = LinkWriter()
            w.u32(1); w.u64(dx.bitPattern); w.u64(0); w.u8(0); w.u8(0); w.u8(0)
            return w.bytes
        }
        #expect(payloadError(.inputScroll, scroll(1)) == nil)
        #expect(isMalformed(payloadError(.inputScroll, scroll(.nan))))
        #expect(isMalformed(payloadError(.inputScroll, scroll(.infinity))))
    }

    @Test func pencilValuesAreValidated() {
        func pointer(flags: UInt8, floats: [Float]) -> [UInt8] {
            var w = LinkWriter()
            w.u32(1); w.u64(0); w.u64(0); w.u8(0); w.u16(0); w.u8(flags)
            for f in floats { w.u32(f.bitPattern) }
            return w.bytes
        }
        #expect(payloadError(.inputPointer, pointer(flags: 3, floats: [0.5, 0.1, 0.1])) == nil)
        #expect(isMalformed(payloadError(.inputPointer, pointer(flags: 1, floats: [1.5]))))
        #expect(isMalformed(payloadError(.inputPointer, pointer(flags: 1, floats: [.nan]))))
        #expect(isMalformed(payloadError(.inputPointer, pointer(flags: 2, floats: [100, 0]))))
        #expect(isMalformed(payloadError(.inputPointer, pointer(flags: 4, floats: []))))
        #expect(isMalformed(payloadError(.inputPointer, pointer(flags: 1, floats: []))))
    }

    @Test func pairProveCarriesAnExactSizeNonce() throws {
        func prove(nonceBytes: Int, nameBytes: Int = 3, trailing: Int = 0) -> [UInt8] {
            var w = LinkWriter()
            w.raw(Data(repeating: 7, count: nonceBytes))
            w.u16(UInt16(nameBytes)); w.raw(Data(repeating: 0x61, count: nameBytes))
            w.raw(Data(repeating: 1, count: 32)); w.raw(Data(repeating: 2, count: 32))
            w.raw(Data(repeating: 0, count: trailing))
            return w.bytes
        }
        #expect(payloadError(.pairProve, prove(nonceBytes: 16)) == nil)
        // A proof from before the nonce existed (no nonce field) is malformed, never half-read.
        var old = LinkWriter()
        old.u16(3); old.raw(Data("abc".utf8)); old.raw(Data(repeating: 1, count: 32)); old.raw(Data(repeating: 2, count: 32))
        #expect(payloadError(.pairProve, old.bytes) != nil)
        #expect(payloadError(.pairProve, prove(nonceBytes: 15)) != nil)
        #expect(isMalformed(payloadError(.pairProve, prove(nonceBytes: 16, trailing: 1))))
        #expect(payloadError(.pairProve, prove(nonceBytes: 16, nameBytes: 300)) != nil)
        #expect(throws: LinkError.self) { try LinkBytes16(Data(count: 17)) }
        #expect(throws: LinkError.self) { try LinkBytes16(Data(count: 15)) }
    }

    @Test func badBooleansAndEnumsAreMalformed() {
        #expect(isMalformed(payloadError(.appsList, [9])))
        #expect(isMalformed(payloadError(.pairDenied, [200])))
        #expect(isMalformed(payloadError(.status, [9])))
        #expect(isMalformed(payloadError(.status, [0, 2])))
        #expect(isMalformed(payloadError(.windowCommand, wireBytes(4) + [77])))
        var key = LinkWriter()
        key.u16(1); key.u8(0); key.u8(5); key.u16(0)
        #expect(isMalformed(payloadError(.inputKey, key.bytes)))
    }

    @Test func pixelSizesFpsAndScaleAreBounded() {
        func subscribe(width: UInt32, height: UInt32, fps: UInt16) -> [UInt8] {
            var w = LinkWriter()
            w.u32(1); w.u32(width); w.u32(height); w.u16(fps); w.u8(1)
            return w.bytes
        }
        #expect(payloadError(.windowSubscribe, subscribe(width: 100, height: 100, fps: 60)) == nil)
        #expect(isMalformed(payloadError(.windowSubscribe, subscribe(width: 0, height: 100, fps: 60))))
        #expect(isMalformed(payloadError(.windowSubscribe, subscribe(width: .max, height: 100, fps: 60))))
        #expect(isMalformed(payloadError(.windowSubscribe, subscribe(width: 100, height: 100, fps: 0))))
        #expect(isMalformed(payloadError(.windowSubscribe, subscribe(width: 100, height: 100, fps: 1000))))
        var icon = LinkWriter()
        icon.u32(1); icon.u16(0)
        #expect(isMalformed(payloadError(.appsIcon, icon.bytes)))
        var icon2 = LinkWriter()
        icon2.u32(1); icon2.u16(LinkLimits.maxIconPixelSize + 1)
        #expect(isMalformed(payloadError(.appsIcon, icon2.bytes)))
    }

    @Test func helloWithEmptyProtocolRangeIsRejected() throws {
        var payload = try LinkMessage.hello(LinkHello(protocolMin: 1, protocolMax: 2, capabilities: [], deviceName: "x", sceneLimits: LinkSceneLimits(maxWindows: 1, maxStreams: 1, maxPixelWidth: 1, maxPixelHeight: 1, maxFramesPerSecond: 1))).encodePayload()
        payload.swapAt(0, 2) // min=2, max=1
        #expect(isMalformed(payloadError(.hello, payload)))
    }

    // MARK: Counts and lengths

    @Test func tooManyWindowsInSnapshotIsRejectedBeforeAllocating() {
        var w = LinkWriter()
        w.u64(1); w.u16(0); w.u16(UInt16(LinkLimits.maxWindowsPerSnapshot + 1))
        #expect(isLimit(payloadError(.snapshot, w.bytes)))
    }

    @Test func countLargerThanThePayloadIsMalformed() {
        var w = LinkWriter()
        w.u64(1); w.u16(0); w.u16(UInt16(LinkLimits.maxWindowsPerSnapshot)) // allowed count, but no bytes follow
        #expect(isMalformed(payloadError(.snapshot, w.bytes)))
        var apps = LinkWriter()
        apps.u16(UInt16(LinkLimits.maxApps))
        #expect(isMalformed(payloadError(.appsItems, apps.bytes)))
        #expect(isLimit(payloadError(.appsItems, [0xFF, 0xFF])))
        #expect(isLimit(payloadError(.windowOrder, [0xFF, 0xFF])))
        #expect(isLimit(payloadError(.clipboardOffer, [0xFF, 0xFF])))
        #expect(isLimit(payloadError(.videoAck, wireBytes(4) + [0xFF, 0xFF])))
        #expect(isLimit(payloadError(.menuPress, wireString("a.b") + [7, 0] + wireBytes(14))))
    }

    @Test func blobLengthsAreCappedAndCheckedAgainstTheRemainingBytes() {
        var icon = LinkWriter()
        icon.u32(1); icon.u32(UInt32(LinkLimits.maxIconPNGBytes + 1))
        #expect(isLimit(payloadError(.appsIconData, icon.bytes)))
        var lying = LinkWriter()
        lying.u32(1); lying.u32(1000)
        #expect(isMalformed(payloadError(.appsIconData, lying.bytes + [1, 2, 3])))
        var huge = LinkWriter()
        huge.u32(1); huge.u32(.max)
        #expect(isLimit(payloadError(.appsIconData, huge.bytes)))
        var clip = LinkWriter()
        clip.u16(1)
        #expect(isLimit(payloadError(.clipboardData, clip.bytes + [0x61] + [0xFF, 0xFF, 0xFF, 0xFF])))
        var frame = LinkWriter()
        frame.u32(1); frame.u32(1); frame.u64(1); frame.u8(1); frame.u32(0)
        #expect(isMalformed(payloadError(.videoFrame, frame.bytes))) // empty access unit
    }

    @Test func tooManyParameterSetsOrOversizedSetsAreRejected() {
        var w = LinkWriter()
        w.u32(1); w.u8(1); w.u16(UInt16(LinkLimits.maxParameterSets + 1))
        #expect(isLimit(payloadError(.videoConfig, w.bytes)))
        var big = LinkWriter()
        big.u32(1); big.u8(1); big.u16(1); big.u32(UInt32(LinkLimits.maxParameterSetBytes + 1))
        #expect(isLimit(payloadError(.videoConfig, big.bytes)))
    }

    // MARK: Menus

    /// A chain of single-child menu items `depth` levels deep, written iteratively (a hostile peer is not limited by our stack).
    private func menuTreePayload(depth: Int) -> [UInt8] {
        var w = LinkWriter()
        try? w.string("a.b", maxBytes: 255, "id")
        for _ in 0..<depth {
            w.u16(1)
            try? w.string("m", maxBytes: 10, "t")
            w.bool(true); w.bool(false); w.bool(false)
            try? w.string("", maxBytes: 10, "k")
            w.u16(0)
        }
        w.u16(0)
        return w.bytes
    }

    @Test func menuAtMaximumDepthDecodesAndOneDeeperIsRejected() {
        #expect(payloadError(.menuTree, menuTreePayload(depth: LinkLimits.maxMenuDepth)) == nil)
        #expect(isLimit(payloadError(.menuTree, menuTreePayload(depth: LinkLimits.maxMenuDepth + 1))))
        #expect(isLimit(payloadError(.menuTree, menuTreePayload(depth: 5000)))) // would overflow the stack if unbounded
    }

    @Test func menuLevelsAndTotalsAreBounded() {
        var w = LinkWriter()
        try? w.string("a.b", maxBytes: 255, "id")
        w.u16(UInt16(LinkLimits.maxMenuItemsPerLevel + 1))
        #expect(isLimit(payloadError(.menuTree, w.bytes)))
        var lying = LinkWriter()
        try? lying.string("a.b", maxBytes: 255, "id")
        lying.u16(UInt16(LinkLimits.maxMenuItemsPerLevel))
        #expect(isMalformed(payloadError(.menuTree, lying.bytes)))
    }

    // MARK: Files

    @Test func hostileFileNamesAreRejected() {
        func begin(_ name: String, size: UInt64 = 1) -> [UInt8] {
            var w = LinkWriter()
            w.u32(1)
            w.u16(UInt16(name.utf8.count))
            return w.bytes + Array(name.utf8) + wireBytes(0) + { var s = LinkWriter(); s.u64(size); s.u8(0); return s.bytes }()
        }
        #expect(payloadError(.fileBegin, begin("ok.txt")) == nil)
        for bad in ["../etc/passwd", "a/b", "..", ".hidden", "a\\b", "x\u{0}y", "tab\there", "", "trail.", "rtl\u{202E}gpj.exe"] {
            #expect(payloadError(.fileBegin, begin(bad)) != nil, "\(bad.debugDescription)")
        }
        #expect(isLimit(payloadError(.fileBegin, begin(String(repeating: "a", count: LinkLimits.maxFileNameBytes + 1)))))
        #expect(isLimit(payloadError(.fileBegin, begin("big.bin", size: LinkLimits.maxFileBytes + 1))))
    }

    @Test func fileChunkOffsetAndSizeAreBounded() {
        var w = LinkWriter()
        w.u32(1); w.u64(.max); w.u32(0)
        #expect(isLimit(payloadError(.fileChunk, w.bytes)))
        var big = LinkWriter()
        big.u32(1); big.u64(0); big.u32(UInt32(LinkLimits.maxFileChunkBytes + 1))
        #expect(isLimit(payloadError(.fileChunk, big.bytes)))
    }

    // MARK: Window update

    @Test func windowUpdateRejectsUnknownFieldBits() {
        var w = LinkWriter()
        w.u32(1); w.u64(1); w.u16(0x8000)
        #expect(isMalformed(payloadError(.windowUpdated, w.bytes)))
    }

    @Test func windowScaleAndSizesAreValidated() throws {
        var window = Samples.window
        window.scale = 0
        #expect((try? LinkFrameEncoder.encode(.windowCreated(window))) == nil)
        window = Samples.window
        window.frame.size.width = -1
        #expect((try? LinkFrameEncoder.encode(.windowCreated(window))) == nil)
        var good = try Samples.window.encodeWindowPayload()
        // scale lives after id(4) pid(4) bundle(2+17) parent(1+4) kind(1) level(2) frame(32)
        let scaleOffset = 4 + 4 + 2 + Samples.window.bundleID.utf8.count + 5 + 1 + 2 + 32
        for (i, b) in Double.nan.bitPattern.littleEndianBytes.enumerated() { good[scaleOffset + i] = b }
        #expect(isMalformed(payloadError(.windowCreated, good)))
    }

    // MARK: Helpers

    private func frameError(_ bytes: [UInt8]) -> LinkError? { captureError { try decodeAll(bytes) } }

    private func captureError<T>(_ body: () throws -> T) -> LinkError? {
        do { _ = try body(); return nil } catch let e as LinkError { return e } catch { return .malformed("other") }
    }
}

private extension UInt64 {
    var littleEndianBytes: [UInt8] { (0..<8).map { UInt8(truncatingIfNeeded: self >> (8 * UInt64($0))) } }
}

private extension LinkWindowInfo {
    func encodeWindowPayload() throws -> [UInt8] { try LinkMessage.windowCreated(self).encodePayload() }
}
