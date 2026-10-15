import Foundation
import Testing
@testable import LinkProtocol

@Suite("Link: encode/decode round trip")
struct LinkRoundTripTests {
    @Test func samplesCoverEveryMessageType() {
        let covered = Set(Samples.all.map(\.type))
        #expect(covered == Set(LinkMessageType.allCases), "missing: \(Set(LinkMessageType.allCases).subtracting(covered))")
    }

    @Test func everyMessageRoundTrips() throws {
        for message in Samples.all {
            let bytes = try LinkFrameEncoder.encode(message)
            let decoded = try decodeAll([UInt8](bytes))
            #expect(decoded == [message], "\(message.type)")
        }
    }

    @Test func concatenatedMessagesDecodeInOrder() throws {
        var stream = Data()
        for message in Samples.all { stream.append(try LinkFrameEncoder.encode(message)) }
        #expect(try decodeAll([UInt8](stream)) == Samples.all)
    }

    @Test func byteByByteEqualsWholeBuffer() throws {
        var stream = Data()
        for message in Samples.all { stream.append(try LinkFrameEncoder.encode(message)) }
        var decoder = LinkFrameDecoder()
        var out: [LinkMessage] = []
        for byte in stream { out += try decoder.feed(Data([byte])) }
        #expect(out == Samples.all)
        #expect(decoder.bufferedByteCount == 0)
    }

    @Test func randomChunkingEqualsWholeBuffer() throws {
        var stream = Data()
        for message in Samples.all { stream.append(try LinkFrameEncoder.encode(message)) }
        var random = SplitMix64(state: 7)
        var decoder = LinkFrameDecoder()
        var out: [LinkMessage] = []
        var index = stream.startIndex
        while index < stream.endIndex {
            let end = min(stream.endIndex, index + Int.random(in: 1...97, using: &random))
            out += try decoder.feed(stream[index..<end])
            index = end
        }
        #expect(out == Samples.all)
    }

    @Test func headerIsLittleEndianTypeThenLength() throws {
        let bytes = [UInt8](try LinkFrameEncoder.encode(.ping(timestampMicros: 1)))
        #expect(bytes == [0x05, 0x00, 0x08, 0x00, 0x00, 0x00, 1, 0, 0, 0, 0, 0, 0, 0])
    }

    @Test func largestAllowedPayloadsRoundTrip() throws {
        let frame = LinkVideoFrame(window: 1, sequence: 1, ptsMicros: 1, flags: [.key], data: Data(repeating: 7, count: LinkLimits.maxVideoAccessUnitBytes))
        #expect(try decodeAll([UInt8](try LinkFrameEncoder.encode(.videoFrame(frame)))) == [.videoFrame(frame)])
        let icon = Data(repeating: 1, count: LinkLimits.maxIconPNGBytes)
        #expect(try decodeAll([UInt8](try LinkFrameEncoder.encode(.appsIconData(key: 1, png: icon)))) == [.appsIconData(key: 1, png: icon)])
        let text = String(repeating: "a", count: LinkLimits.maxTextInputBytes)
        #expect(try decodeAll([UInt8](try LinkFrameEncoder.encode(.inputText(text)))) == [.inputText(text)])
    }

    @Test func maximumMenuDepthRoundTrips() throws {
        var item = LinkMenuItem(title: "leaf")
        for _ in 1..<LinkLimits.maxMenuDepth { item = LinkMenuItem(title: "node", children: [item]) }
        let message = LinkMessage.menuTree(bundleID: "a.b", items: [item])
        #expect(try decodeAll([UInt8](try LinkFrameEncoder.encode(message))) == [message])
    }

    @Test func maximumWindowAndAppCountsRoundTrip() throws {
        let window = Samples.window
        let snapshot = LinkSnapshot(stateVersion: 1, apps: [], windows: Array(repeating: window, count: LinkLimits.maxWindowsPerSnapshot))
        #expect(try decodeAll([UInt8](try LinkFrameEncoder.encode(.snapshot(snapshot)))) == [.snapshot(snapshot)])
        let apps = Array(repeating: Samples.app, count: LinkLimits.maxApps)
        #expect(try decodeAll([UInt8](try LinkFrameEncoder.encode(.appsItems(apps)))) == [.appsItems(apps)])
    }

    // MARK: Encoder refuses what the peer would reject

    @Test func encoderRejectsOversizedAndInvalidValues() {
        func fails(_ message: LinkMessage) -> Bool { (try? LinkFrameEncoder.encode(message)) == nil }
        #expect(fails(.inputText(String(repeating: "a", count: LinkLimits.maxTextInputBytes + 1))))
        #expect(fails(.appsIconData(key: 1, png: Data(count: LinkLimits.maxIconPNGBytes + 1))))
        #expect(fails(.inputPointer(LinkPointerEvent(window: 1, point: LinkPoint(x: .nan, y: 0), buttons: [], modifiers: []))))
        #expect(fails(.inputPointer(LinkPointerEvent(window: 1, point: LinkPoint(x: 1e12, y: 0), buttons: [], modifiers: []))))
        #expect(fails(.inputPointer(LinkPointerEvent(window: 1, point: LinkPoint(x: 0, y: 0), buttons: [], modifiers: [], pressure: 2))))
        #expect(fails(.videoFrame(LinkVideoFrame(window: 1, sequence: 0, ptsMicros: 0, flags: [], data: Data()))))
        #expect(fails(.fileBegin(LinkFileBegin(transfer: 1, name: "../x", size: 1, targetBundleID: nil))))
        #expect(fails(.fileBegin(LinkFileBegin(transfer: 1, name: "x", size: LinkLimits.maxFileBytes + 1, targetBundleID: nil))))
        #expect(fails(.windowOrder(ids: Array(repeating: 1, count: LinkLimits.maxWindowsInOrder + 1), active: nil)))
        #expect(fails(.hello(LinkHello(protocolMin: 3, protocolMax: 1, capabilities: [], deviceName: "x", sceneLimits: LinkSceneLimits(maxWindows: 1, maxStreams: 1, maxPixelWidth: 1, maxPixelHeight: 1, maxFramesPerSecond: 1)))))
        #expect(fails(.menuPress(bundleID: "a", path: Array(repeating: 0, count: LinkLimits.maxMenuDepth + 1))))
        #expect(throws: LinkError.self) { try LinkBytes32(Data(count: 31)) }
    }

    @Test func encoderRejectsTooDeepAndTooBigMenus() {
        var item = LinkMenuItem(title: "leaf")
        for _ in 0..<LinkLimits.maxMenuDepth { item = LinkMenuItem(title: "node", children: [item]) }
        #expect((try? LinkFrameEncoder.encode(.menuTree(bundleID: "a", items: [item]))) == nil)
        let wide = (0..<(LinkLimits.maxMenuItemsPerLevel + 1)).map { LinkMenuItem(title: "\($0)") }
        #expect((try? LinkFrameEncoder.encode(.menuTree(bundleID: "a", items: wide))) == nil)
    }

    @Test func stringsMayContainEveryUnicodeScalarKind() throws {
        for text in ["", "ascii", "Tiếng Việt có dấu", "日本語", "emoji 🧑‍💻🇻🇳", "e\u{301}", "nul\u{0}inside"] {
            let message = LinkMessage.inputText(text)
            #expect(try decodeAll([UInt8](try LinkFrameEncoder.encode(message))) == [message])
        }
    }
}
