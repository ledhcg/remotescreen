import Foundation
import LinkProtocol
import Testing
@testable import WindowKit

@MainActor
final class FakeLinkPasteboard: LinkPasteboard {
    var changeCount = 1
    var typeIdentifiers: [String] = []
    var contents: [String: Data] = [:]
    var reads = 0
    var sensitiveWrites: [(String, TimeInterval)] = []
    var writes: [(String, Data)] = []

    func read(wireType: String) -> Data? { reads += 1; return contents[wireType] }

    func write(wireType: String, data: Data) {
        writes.append((wireType, data))
        contents[wireType] = data
        typeIdentifiers = [wireType]
        changeCount += 1
    }

    func writeSensitiveText(_ text: String, expiresAfter seconds: TimeInterval) {
        sensitiveWrites.append((text, seconds))
        changeCount += 1
    }

    func copy(text: String, extra: [String] = []) {
        contents[ClipboardWireTypes.text] = Data(text.utf8)
        typeIdentifiers = ["public.utf8-plain-text"] + extra
        changeCount += 1
    }
}

@MainActor
@Suite struct LinkClipboardSyncTests {
    let pasteboard = FakeLinkPasteboard()
    var sent: Sent
    var clock: Clock
    let sync: LinkClipboardSync

    @MainActor final class Sent { var messages: [LinkMessage] = [] }
    @MainActor final class Clock { var now: TimeInterval = 100 }

    init(enabled: Bool = true, rich: Bool = true) {
        let sent = Sent(), clock = Clock()
        self.sent = sent; self.clock = clock
        sync = LinkClipboardSync(pasteboard: pasteboard, isEnabled: enabled, richTypes: rich, now: { clock.now }, send: { sent.messages.append($0) })
    }

    // MARK: iPad to Mac

    @Test func offersTheTypesOnlyAndSendsContentOnlyWhenAsked() {
        pasteboard.copy(text: "hello")
        sync.sceneBecameActive()
        #expect(sent.messages == [.clipboardOffer(types: ["public.utf8-plain-text"])])
        #expect(pasteboard.reads == 0, "offering must not read the content (it would show the paste prompt)")
        sync.receive(.clipboardRequest(type: "public.utf8-plain-text"))
        #expect(sent.messages.last == .clipboardData(type: "public.utf8-plain-text", data: Data("hello".utf8)))
        #expect(pasteboard.reads == 1)
    }

    @Test func anUnchangedPasteboardIsOfferedOnce() {
        pasteboard.copy(text: "a")
        sync.sceneBecameActive()
        sync.sceneBecameActive()
        #expect(sync.pasteShortcutPressed() == false)
        #expect(sent.messages.count == 1)
        pasteboard.copy(text: "b")
        #expect(sync.pasteShortcutPressed() == true)
        #expect(sent.messages.count == 2)
    }

    @Test func concealedContentIsNeverOfferedOrSent() {
        pasteboard.copy(text: "s3cret", extra: ["org.nspasteboard.ConcealedType"])
        sync.sceneBecameActive()
        #expect(sync.pasteShortcutPressed() == false)
        sync.receive(.clipboardRequest(type: "public.utf8-plain-text"))
        #expect(sent.messages.isEmpty)
        #expect(pasteboard.reads == 0)
    }

    @Test func contentThatBecameConcealedAfterTheOfferIsNotSent() {
        pasteboard.copy(text: "a")
        sync.sceneBecameActive()
        pasteboard.typeIdentifiers.append("org.nspasteboard.TransientType")
        sync.receive(.clipboardRequest(type: "public.utf8-plain-text"))
        #expect(sent.messages.count == 1)  // only the offer
    }

    @Test func aChangedPasteboardIsNotSentForAnOldOffer() {
        pasteboard.copy(text: "first")
        sync.sceneBecameActive()
        pasteboard.copy(text: "second")
        sync.receive(.clipboardRequest(type: "public.utf8-plain-text"))
        #expect(sent.messages.count == 1)
    }

    @Test func aTypeThatWasNotOfferedIsNotServed() {
        pasteboard.copy(text: "a")
        pasteboard.contents["public.png"] = Data([1])
        sync.sceneBecameActive()
        sync.receive(.clipboardRequest(type: "public.png"))
        sync.receive(.clipboardRequest(type: "public.rtf"))
        #expect(sent.messages.count == 1)
    }

    @Test func oversizedContentIsNotSent() {
        pasteboard.copy(text: "")
        pasteboard.contents["public.utf8-plain-text"] = Data(count: LinkLimits.maxClipboardBytes + 1)
        sync.sceneBecameActive()
        sync.receive(.clipboardRequest(type: "public.utf8-plain-text"))
        #expect(sent.messages.count == 1)
    }

    @Test func richTypesNeedTheCapability() {
        let plain = LinkClipboardSyncTests(rich: false)
        plain.pasteboard.copy(text: "a", extra: ["public.html", "public.png"])
        plain.sync.sceneBecameActive()
        #expect(plain.sent.messages == [.clipboardOffer(types: ["public.utf8-plain-text"])])
        let rich = LinkClipboardSyncTests(rich: true)
        rich.pasteboard.copy(text: "a", extra: ["public.html", "public.png"])
        rich.sync.sceneBecameActive()
        #expect(rich.sent.messages == [.clipboardOffer(types: ["public.utf8-plain-text", "public.html", "public.png"])])
    }

    @Test func nothingMovesWhileSharingIsOff() {
        let off = LinkClipboardSyncTests(enabled: false)
        off.pasteboard.copy(text: "a")
        off.sync.sceneBecameActive()
        #expect(off.sync.pasteShortcutPressed() == false)
        off.sync.receive(.clipboardOffer(types: ["public.utf8-plain-text"]))
        off.sync.copyShortcutPressed()
        off.sync.receive(.clipboardOffer(types: ["public.utf8-plain-text"]))
        #expect(off.sent.messages.isEmpty)
    }

    // MARK: Mac to iPad

    @Test func aMacOfferIsNotRequestedOnItsOwn() {
        sync.receive(.clipboardOffer(types: ["public.utf8-plain-text"]))
        #expect(sent.messages.isEmpty)
        sync.receive(.clipboardData(type: "public.utf8-plain-text", data: Data("planted".utf8)))
        #expect(pasteboard.writes.isEmpty)
    }

    @Test func anOfferRightAfterCopyIsRequestedAndWritten() {
        sync.copyShortcutPressed()
        clock.now += 1
        sync.receive(.clipboardOffer(types: ["public.html", "public.utf8-plain-text"]))
        #expect(sent.messages == [.clipboardRequest(type: "public.utf8-plain-text")])
        sync.receive(.clipboardData(type: "public.utf8-plain-text", data: Data("from the Mac".utf8)))
        #expect(pasteboard.writes.count == 1)
        #expect(pasteboard.writes[0].0 == "public.utf8-plain-text")
        // What we wrote ourselves is not offered back.
        sync.sceneBecameActive()
        #expect(sent.messages.count == 1)
    }

    @Test func theCopyWindowExpires() {
        sync.copyShortcutPressed()
        clock.now += LinkClipboardSync.copyWindow + 1
        sync.receive(.clipboardOffer(types: ["public.utf8-plain-text"]))
        #expect(sent.messages.isEmpty)
    }

    @Test func aPendingOfferIsTakenUpWhenTheSceneBecomesActive() {
        sync.receive(.clipboardOffer(types: ["public.utf8-plain-text"]))
        sync.sceneBecameActive()
        #expect(sent.messages == [.clipboardRequest(type: "public.utf8-plain-text")])
        sync.sceneBecameActive()
        #expect(sent.messages.count == 1, "a pending offer is used once")
    }

    @Test func onlyTheRequestedTypeIsAcceptedAndOnlyOnce() {
        sync.copyShortcutPressed()
        sync.receive(.clipboardOffer(types: ["public.utf8-plain-text"]))
        sync.receive(.clipboardData(type: "public.html", data: Data("<b>x</b>".utf8)))
        #expect(pasteboard.writes.isEmpty)
        sync.receive(.clipboardData(type: "public.utf8-plain-text", data: Data("one".utf8)))
        sync.receive(.clipboardData(type: "public.utf8-plain-text", data: Data("two".utf8)))
        #expect(pasteboard.writes.count == 1)
    }

    @Test func dataThatIsNotWhatItClaimsIsRejected() {
        for (type, bad) in [("public.utf8-plain-text", Data([0xFF, 0xFE, 0xFD])), ("public.png", Data("not a png".utf8)), ("public.rtf", Data("plain".utf8))] {
            sync.copyShortcutPressed()
            sync.receive(.clipboardOffer(types: [type]))
            sync.receive(.clipboardData(type: type, data: bad))
        }
        sync.copyShortcutPressed()
        sync.receive(.clipboardOffer(types: ["public.utf8-plain-text"]))
        sync.receive(.clipboardData(type: "public.utf8-plain-text", data: Data()))
        sync.copyShortcutPressed()
        sync.receive(.clipboardOffer(types: ["public.utf8-plain-text"]))
        sync.receive(.clipboardData(type: "public.utf8-plain-text", data: Data(count: LinkLimits.maxClipboardBytes + 1)))
        #expect(pasteboard.writes.isEmpty)
    }

    @Test func sensitiveContentFromTheMacStaysLocalAndExpires() {
        sync.copyShortcutPressed()
        sync.receive(.clipboardOffer(types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]))
        sync.receive(.clipboardData(type: "public.utf8-plain-text", data: Data("hunter2".utf8)))
        #expect(pasteboard.writes.isEmpty)
        #expect(pasteboard.sensitiveWrites.count == 1)
        #expect(pasteboard.sensitiveWrites[0].1 == LinkClipboardSync.sensitiveLifetime)
    }

    @Test func tooManyOfferedTypesAreIgnored() {
        sync.copyShortcutPressed()
        sync.receive(.clipboardOffer(types: (0...LinkLimits.maxClipboardTypes).map { "t\($0)" } + ["public.utf8-plain-text"]))
        #expect(sent.messages.isEmpty)
    }

    @Test func resetForgetsOffersAndRequests() {
        pasteboard.copy(text: "a")
        sync.sceneBecameActive()
        sync.copyShortcutPressed()
        sync.receive(.clipboardOffer(types: ["public.utf8-plain-text"]))
        sync.reset()
        sync.receive(.clipboardData(type: "public.utf8-plain-text", data: Data("late".utf8)))
        sync.receive(.clipboardRequest(type: "public.utf8-plain-text"))
        #expect(pasteboard.writes.isEmpty)
        #expect(sent.messages.count == 2)  // the offer and the request from before the reset
    }
}
