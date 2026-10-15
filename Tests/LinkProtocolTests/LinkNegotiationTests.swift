import Foundation
import Testing
@testable import LinkProtocol

@Suite("Link: version negotiation and file names")
struct LinkNegotiationTests {
    @Test func picksTheHighestCommonVersion() {
        #expect(LinkVersionNegotiation.negotiate(local: 1...3, remote: 2...5) == 3)
        #expect(LinkVersionNegotiation.negotiate(local: 1...1, remote: 1...1) == 1)
        #expect(LinkVersionNegotiation.negotiate(local: 4...9, remote: 1...4) == 4)
        #expect(LinkVersionNegotiation.negotiate(local: 0...UInt16.max, remote: 7...7) == 7)
    }

    @Test func disjointRangesHaveNoVersion() {
        #expect(LinkVersionNegotiation.negotiate(local: 1...2, remote: 3...4) == nil)
        #expect(LinkVersionNegotiation.negotiate(local: 5...6, remote: 1...4) == nil)
    }

    @Test func mismatchSaysWhichSideIsOld() {
        #expect(LinkVersionNegotiation.evaluate(local: 3...4, remote: 1...2) == .remoteTooOld(remoteMax: 2))
        #expect(LinkVersionNegotiation.evaluate(local: 1...2, remote: 3...4) == .remoteTooNew(remoteMin: 3))
        #expect(LinkVersionNegotiation.evaluate(local: 1...2, remote: 2...9) == .agreed(2))
    }

    @Test func currentBuildSupportsItsOwnVersion() {
        #expect(LinkVersionNegotiation.negotiate(local: LinkProtocolVersion.supported, remote: LinkProtocolVersion.supported) == LinkProtocolVersion.current)
    }

    @Test func capabilitiesIntersectAndKeepUnknownBitsHarmless() {
        let local: LinkCapabilities = [.stage, .menus, .hevc]
        let remote: LinkCapabilities = [.menus, .hevc, .audio, LinkCapabilities(rawValue: 1 << 60)]
        #expect(LinkVersionNegotiation.negotiate(local: local, remote: remote) == [.menus, .hevc])
    }

    @Test func helloRangeIsExposed() {
        let limits = LinkSceneLimits(maxWindows: 1, maxStreams: 1, maxPixelWidth: 1, maxPixelHeight: 1, maxFramesPerSecond: 1)
        #expect(LinkHello(protocolMin: 1, protocolMax: 3, capabilities: [], deviceName: "x", sceneLimits: limits).protocolRange == 1...3)
    }

    @Test func unknownCapabilityBitsSurviveARoundTrip() throws {
        let caps = LinkCapabilities(rawValue: .max)
        let limits = LinkSceneLimits(maxWindows: 1, maxStreams: 1, maxPixelWidth: 1, maxPixelHeight: 1, maxFramesPerSecond: 1)
        let hello = LinkMessage.hello(LinkHello(protocolMin: 1, protocolMax: 1, capabilities: caps, deviceName: "x", sceneLimits: limits))
        #expect(try decodeAll([UInt8](try LinkFrameEncoder.encode(hello))) == [hello])
    }

    // MARK: File names

    @Test func plainNamesAreAccepted() throws {
        for name in ["report.pdf", "a", "Bản báo cáo.docx", "with space.txt", "multi.part.tar.gz", "日本語.txt", "~backup", String(repeating: "a", count: 255)] {
            #expect(try LinkFileName.validated(name) == name)
        }
    }

    @Test func dangerousNamesAreRejected() {
        let bad = ["", ".", "..", ".hidden", ".ssh", "../x", "a/b", "/abs", "a\\b", "c:evil", "nul\u{0}", "line\nbreak", "tab\t", "del\u{7F}",
                   "c1\u{85}", "trailing.", "trailing ", "\u{202E}fdp.exe", "iso\u{2066}late", String(repeating: "a", count: 256),
                   String(repeating: "é", count: 128)]
        for name in bad { #expect(!LinkFileName.isValid(name), "\(name.debugDescription)") }
    }

    /// Grapheme-aware `String` comparisons would let these through while the file system still sees a leading or
    /// trailing dot, or an invisible character.
    @Test func combiningMarksCannotHideADotOrSpace() {
        let bad = [".\u{301}", ".\u{301}ssh", "a.\u{301}", "a \u{301}", "\u{301}lead", "zero\u{200B}width", "bom\u{FEFF}.txt",
                   "join\u{2060}er"]
        for name in bad { #expect(!LinkFileName.isValid(name), "\(name.debugDescription)") }
        // Decomposed Vietnamese (combining marks inside the name) stays valid.
        let decomposed = "Ba\u{301}o ca\u{301}o.txt"
        #expect(LinkFileName.isValid(decomposed))
    }
}
