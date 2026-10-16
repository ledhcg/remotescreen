import Foundation
import LinkProtocol
import Localization
import Testing
@testable import WindowKit

@Suite("Stats deltas")
struct StatsTests {
    @Test func reportsDeltasSinceTheLastReport() {
        var accumulator = WindowStatsAccumulator()
        let id = WindowID(1)
        accumulator.addReceived(bytes: 1000)
        accumulator.addReceived(bytes: 500)
        let first = accumulator.report(window: id, decodedTotal: 10, droppedTotal: 2, decodeP95Micros: 3000)
        #expect(first.receivedBytes == 1500)
        #expect(first.decodedFrames == 10)
        #expect(first.droppedFrames == 2)
        #expect(first.decodeP95Micros == 3000)

        accumulator.addReceived(bytes: 40)
        let second = accumulator.report(window: id, decodedTotal: 25, droppedTotal: 2, decodeP95Micros: 2500)
        #expect(second.receivedBytes == 40)
        #expect(second.decodedFrames == 15)
        #expect(second.droppedFrames == 0)
    }

    @Test func aDecoderResetStartsAFreshBaseline() {
        var accumulator = WindowStatsAccumulator()
        _ = accumulator.report(window: 1, decodedTotal: 500, droppedTotal: 40, decodeP95Micros: 0)
        let after = accumulator.report(window: 1, decodedTotal: 3, droppedTotal: 0, decodeP95Micros: 0)
        #expect(after.decodedFrames == 3)
        #expect(after.droppedFrames == 0)
    }

    @Test func negativeAndAbsurdInputsStayBounded() {
        var accumulator = WindowStatsAccumulator()
        accumulator.addReceived(bytes: -5)
        accumulator.addReceived(bytes: 0)
        let report = accumulator.report(window: 1, decodedTotal: Int.max, droppedTotal: Int.max, decodeP95Micros: 0)
        #expect(report.receivedBytes == 0)
        #expect(report.decodedFrames == UInt32.max)
    }

    @Test func bookBuildsOneMessageForTheDecodedWindowsInIdOrder() {
        var book = ConnectionStatsBook()
        book.addReceived(window: 2, bytes: 200)
        book.addReceived(window: 1, bytes: 100)
        book.addReceived(window: 9, bytes: 999) // no decoder for window 9: forgotten
        let counters: [WindowID: DecoderCounters] = [
            2: DecoderCounters(decodedTotal: 6, droppedTotal: 1, decodeP95Millis: 2.5),
            1: DecoderCounters(decodedTotal: 4, droppedTotal: 0, decodeP95Millis: 0.5),
        ]
        let stats = book.makeStats(rttMicros: 7000, counters: counters)
        #expect(stats?.rttMicros == 7000)
        #expect(stats?.windows.map(\.window) == [1, 2])
        #expect(stats?.windows.map(\.receivedBytes) == [100, 200])
        #expect(stats?.windows.map(\.decodeP95Micros) == [500, 2500])

        // The second period only has what happened since.
        book.addReceived(window: 1, bytes: 10)
        let next = book.makeStats(rttMicros: 7100, counters: [
            1: DecoderCounters(decodedTotal: 10, droppedTotal: 0, decodeP95Millis: 0.5),
        ])
        #expect(next?.windows.first?.receivedBytes == 10)
        #expect(next?.windows.first?.decodedFrames == 6)
        #expect(book.makeStats(rttMicros: 0, counters: [:]) == nil)
    }

    @Test func nonFiniteDecodeTimeIsZero() {
        #expect(DecoderCounters(decodedTotal: 0, droppedTotal: 0, decodeP95Millis: .nan).p95Micros == 0)
        #expect(DecoderCounters(decodedTotal: 0, droppedTotal: 0, decodeP95Millis: .infinity).p95Micros == 0)
        #expect(DecoderCounters(decodedTotal: 0, droppedTotal: 0, decodeP95Millis: -3).p95Micros == 0)
    }
}

@Suite("Key frame rate limit")
struct KeyframeRateLimiterTests {
    @Test func atMostTwoPerSecondPerWindow() {
        var limiter = KeyframeRateLimiter(minInterval: 0.5)
        #expect(limiter.request(1, now: 10) == .sendNow)
        #expect(limiter.request(1, now: 10.1) == .deferred(until: 10.5))
        #expect(limiter.request(1, now: 10.2) == .deferred(until: 10.5)) // coalesced into the same deferred request
        #expect(limiter.request(2, now: 10.2) == .sendNow) // another window has its own budget
        #expect(limiter.due(now: 10.4).isEmpty)
        #expect(limiter.nextDeadline == 10.5)
        #expect(limiter.due(now: 10.5) == [1])
        #expect(limiter.nextDeadline == nil)
        // The deferred request counted as sent at 10.5.
        #expect(limiter.request(1, now: 10.6) == .deferred(until: 11.0))
        #expect(limiter.request(1, now: 11.0) == .sendNow)
    }

    @Test func aStormOfRequestsSendsAtMostTwoPerSecond() {
        var limiter = KeyframeRateLimiter()
        var sent = 0
        var time = 0.0
        while time < 10 {
            if limiter.request(1, now: time) == .sendNow { sent += 1 }
            sent += limiter.due(now: time).count
            time += 0.01
        }
        #expect(sent <= 21) // 10 s at 2 per second, plus the first one
        #expect(sent >= 19)
    }

    @Test func forgettingAWindowDropsItsDeferredRequest() {
        var limiter = KeyframeRateLimiter()
        _ = limiter.request(1, now: 0)
        _ = limiter.request(1, now: 0.1)
        limiter.forget(1)
        #expect(limiter.due(now: 5).isEmpty)
        #expect(limiter.request(1, now: 0.2) == .sendNow)
    }
}

@Suite("Subscriptions")
struct SubscriptionManagerTests {
    private func sub(_ id: UInt32, width: UInt32 = 1600, fps: UInt16 = 60) -> LinkSubscribe {
        LinkSubscribe(window: WindowID(id), pixelWidth: width, pixelHeight: 1000, maxFramesPerSecond: fps, quality: .balanced)
    }

    @Test func nothingIsSentBeforeTheConnectionIsUp() {
        var manager = SubscriptionManager()
        #expect(manager.subscribe(sub(1)).isEmpty)
        #expect(manager.connectionEstablished() == [.subscribe(sub(1))])
        #expect(manager.streaming == [1])
    }

    @Test func theSameSubscriptionIsNotSentTwice() {
        var manager = SubscriptionManager()
        _ = manager.connectionEstablished()
        #expect(manager.subscribe(sub(1)) == [.subscribe(sub(1))])
        #expect(manager.subscribe(sub(1)).isEmpty)
        #expect(manager.subscribe(sub(1, width: 800)) == [.subscribe(sub(1, width: 800))])
    }

    @Test func backgroundPausesAndForegroundResumes() {
        var manager = SubscriptionManager()
        _ = manager.connectionEstablished()
        _ = manager.subscribe(sub(1))
        #expect(manager.pause(1) == [.unsubscribe(1)])
        #expect(manager.pause(1).isEmpty)
        #expect(manager.isPaused(1))
        #expect(manager.streaming.isEmpty)
        // A size change while paused is remembered but not sent.
        #expect(manager.subscribe(sub(1, width: 900)).isEmpty)
        #expect(manager.resume(1) == [.subscribe(sub(1, width: 900))])
        #expect(manager.resume(1).isEmpty)
    }

    @Test func aReconnectRestoresOnlyTheVisibleWindows() {
        var manager = SubscriptionManager()
        _ = manager.connectionEstablished()
        _ = manager.subscribe(sub(1))
        _ = manager.subscribe(sub(2))
        _ = manager.subscribe(sub(3))
        _ = manager.pause(2)
        manager.connectionLost()
        #expect(manager.streaming.isEmpty)
        #expect(manager.subscribe(sub(4)).isEmpty) // wished while offline
        #expect(manager.connectionEstablished() == [.subscribe(sub(1)), .subscribe(sub(3)), .subscribe(sub(4))])
        #expect(manager.resume(2) == [.subscribe(sub(2))])
    }

    @Test func unsubscribeAndDestroyedWindows() {
        var manager = SubscriptionManager()
        _ = manager.connectionEstablished()
        _ = manager.subscribe(sub(1))
        _ = manager.subscribe(sub(2))
        #expect(manager.unsubscribe(1) == [.unsubscribe(1)])
        #expect(manager.unsubscribe(1).isEmpty)
        manager.windowDestroyed(2) // the Mac said it is gone: nothing to send
        #expect(manager.wanted.isEmpty)
        #expect(manager.connectionEstablished().isEmpty)
    }

    @Test func unsubscribeWhileDisconnectedSendsNothing() {
        var manager = SubscriptionManager()
        _ = manager.connectionEstablished()
        _ = manager.subscribe(sub(1))
        manager.connectionLost()
        #expect(manager.unsubscribe(1).isEmpty)
        #expect(manager.connectionEstablished().isEmpty)
    }
}

@Suite("Video sequence")
struct VideoSequenceTrackerTests {
    @Test func inOrderGapAndStale() {
        var tracker = VideoSequenceTracker()
        #expect(tracker.observe(sequence: 100) == .inOrder)
        #expect(tracker.observe(sequence: 101) == .inOrder)
        #expect(tracker.observe(sequence: 105) == .gap(first: 102, last: 104))
        #expect(tracker.observe(sequence: 103) == .stale)
        #expect(tracker.observe(sequence: 105) == .stale) // a repeat
        #expect(tracker.observe(sequence: 106) == .inOrder)
    }

    @Test func wrapsAroundTheEndOfTheRange() {
        var tracker = VideoSequenceTracker()
        #expect(tracker.observe(sequence: UInt32.max - 1) == .inOrder)
        #expect(tracker.observe(sequence: UInt32.max) == .inOrder)
        #expect(tracker.observe(sequence: 0) == .inOrder)
        #expect(tracker.observe(sequence: 2) == .gap(first: 1, last: 1))
        var other = VideoSequenceTracker()
        _ = other.observe(sequence: UInt32.max - 2)
        #expect(other.observe(sequence: 1) == .gap(first: UInt32.max - 1, last: 0))
    }

    @Test func resetStartsANewRun() {
        var tracker = VideoSequenceTracker()
        _ = tracker.observe(sequence: 500)
        tracker.reset()
        #expect(tracker.observe(sequence: 3) == .inOrder)
    }

    @Test func onlyKeyAndLongTermFramesAreAcknowledgedByTheirSequence() {
        #expect(VideoSequenceTracker.ackTokens(for: [.key], sequence: 7) == [7])
        #expect(VideoSequenceTracker.ackTokens(for: [.ltr], sequence: 8) == [8])
        #expect(VideoSequenceTracker.ackTokens(for: [.key, .ltr], sequence: 9) == [9])
        #expect(VideoSequenceTracker.ackTokens(for: [], sequence: 10).isEmpty)
        #expect(VideoSequenceTracker.ackTokens(for: [.refresh], sequence: 11).isEmpty)
    }
}

@Suite("Remote window status", .serialized)
struct RemoteWindowStatusTests {
    init() { Localization.forcedLanguage = "en" }

    private func connectedWorkspace() -> RemoteWorkspace {
        workspace([makeWindow(1, bundle: "com.example.app")], apps: [makeApp(1, bundle: "com.example.app")])
    }

    private func present(
        _ phase: ConnectionPhase = .connected, binding: SceneBindingState? = .bound(1), workspace: RemoteWorkspace? = nil,
        helper: HelperStatus = HelperStatus(), hasFrame: Bool = true
    ) -> RemoteWindowPresentation {
        RemoteWindowStatus.present(
            connection: phase, binding: binding, workspace: workspace ?? connectedWorkspace(), helper: helper, hasFrame: hasFrame)
    }

    @Test func aWorkingWindowShowsNothing() {
        #expect(present() == RemoteWindowPresentation())
    }

    @Test func connectionStatesComeFirst() {
        var locked = HelperStatus()
        locked.apply(.macLocked(true))
        #expect(present(.connecting, helper: locked).overlay == .connecting)
        #expect(present(.reconnecting(attempt: 2, total: 6)).overlay == .reconnecting(attempt: 2, total: 6))
        #expect(present(.reconnecting(attempt: 2, total: 6)).overlay?.title == "Reconnecting (2/6)…")
        #expect(present(.reconnecting(attempt: 1, total: 6)).overlay?.coversWindow == false)
    }

    @Test func offlineDimsTheWindowAndSaysItWillReconnect() {
        let shown = present(.waitingForNetwork).overlay
        #expect(shown == .waitingForNetwork)
        #expect(shown?.coversWindow == false)
        #expect(shown?.title == "No internet connection")
        #expect(shown?.actions == [.close])
    }

    @Test func failuresOfEveryKindHaveActions() {
        let kinds: [(ConnectionFailureKind, RemoteWindowOverlay, [RemoteWindowAction])] = [
            (.versionMismatch(.helper), .versionMismatch(.helper), [.close]),
            (.deviceRevoked, .deviceRevoked, [.pairAgain, .close]),
            (.identityChanged, .identityChanged, [.pairAgain, .close]),
            (.denied, .denied, [.retry, .close]),
            (.replaced, .replaced, [.retry, .close]),
            (.connectionLost, .connectionLost, [.retry, .close]),
            (.tailscaleNotConnected, .tailscaleNotConnected, [.retry, .close]),
            (.tailscaleTurnedOff, .tailscaleTurnedOff, [.retry, .close]),
        ]
        for (kind, overlay, actions) in kinds {
            let shown = present(.failed(kind)).overlay
            #expect(shown == overlay)
            #expect(shown?.actions == actions)
            #expect(shown?.title.isEmpty == false)
            #expect(shown?.message?.isEmpty == false)
        }
    }

    @Test func versionMismatchNamesTheSideToUpdate() {
        #expect(RemoteWindowOverlay.versionMismatch(.helper).message == "Update Screon Helper on the Mac.")
        #expect(RemoteWindowOverlay.versionMismatch(.screon).message == "Update Screon on this device.")
    }

    @Test func aClosedWindowOffersReopenAndClose() {
        let hint = WindowMatchQuery(bundleID: "com.example.app", title: "Doc", indexHint: 0)
        let shown = present(binding: .windowClosed(reopenHint: hint)).overlay
        #expect(shown == .windowClosed)
        #expect(shown?.actions == [.reopen, .close])
    }

    @Test func aWindowOfAQuitAppIsReportedAsAppQuit() {
        let hint = WindowMatchQuery(bundleID: "com.gone.app", title: "Doc", indexHint: 0)
        #expect(present(binding: .windowClosed(reopenHint: hint)).overlay == .appQuit)
    }

    @Test func aRestoringSceneWaitsForTheSnapshot() {
        let query = WindowMatchQuery(bundleID: "com.example.app", title: "Doc", indexHint: 0)
        #expect(present(binding: .restoring(query)).overlay == .lookingForWindow)
        #expect(present(binding: nil).overlay == .lookingForWindow)
    }

    @Test func aLockedMacOffersTheDesktop() {
        var helper = HelperStatus()
        helper.apply(.macLocked(true))
        let shown = present(helper: helper).overlay
        #expect(shown == .macLocked)
        #expect(shown?.actions == [.openDesktop])
        helper.apply(.macLocked(false))
        #expect(present(helper: helper).overlay == nil)
    }

    @Test func missingPermissionsAreTrackedAndNamedInAFixedOrder() {
        var helper = HelperStatus()
        helper.apply(.permissionMissing(.accessibility))
        helper.apply(.permission(.screenRecording, .denied))
        #expect(present(helper: helper).overlay == .permissionMissing(.screenRecording))
        helper.apply(.permission(.screenRecording, .granted))
        #expect(present(helper: helper).overlay == .permissionMissing(.accessibility))
        helper.apply(.permission(.accessibility, .granted))
        #expect(present(helper: helper).overlay == nil)
        for kind in [LinkPermissionKind.accessibility, .screenRecording, .localNetwork, .inputMonitoring, .automation] {
            #expect(RemoteWindowOverlay.permissionMissing(kind).message?.contains("Screon Helper") == true)
        }
    }

    @Test func noPictureYetShowsAGentleWaitingState() {
        let shown = present(hasFrame: false).overlay
        #expect(shown == .waitingForFirstFrame)
        #expect(shown?.coversWindow == false)
    }

    @Test func secureInputIsABannerOverAWorkingWindowOnly() {
        var helper = HelperStatus()
        helper.apply(.secureInput(active: true, pid: 42))
        #expect(present(helper: helper) == RemoteWindowPresentation(overlay: nil, banner: .secureInput))
        #expect(RemoteWindowBanner.secureInput.text == "Typing is blocked by a password field on the Mac")
        #expect(present(helper: helper, hasFrame: false).banner == nil)
        helper.clearSecureInput()
        #expect(present(helper: helper).banner == nil)
    }

    @Test func inactiveSecureInputClearsTheBanner() {
        var helper = HelperStatus()
        helper.apply(.secureInput(active: true, pid: 42))
        helper.apply(.secureInput(active: false, pid: nil))
        #expect(!helper.secureInput)
        #expect(helper.secureInputPID == nil)
        #expect(present(helper: helper).banner == nil)
    }

    @Test func refusedSubscriptionExplainsItselfInsteadOfWaiting() {
        var helper = HelperStatus()
        let binding = SceneBindingState.bound(WindowID(5))
        let workspace = RemoteWorkspace()
        helper.noteSubscribeFailure(window: 5, reason: .limit)
        let shown = RemoteWindowStatus.present(connection: .connected, binding: binding, workspace: workspace, helper: helper, hasFrame: false)
        #expect(shown == RemoteWindowPresentation(overlay: nil, banner: .subscribeFailed(.limit)))
        #expect(RemoteWindowBanner.subscribeFailed(.limit).text == "The Mac is already streaming as many windows as it allows.")
        helper.clearSubscribeFailure(window: 5)
        let waiting = RemoteWindowStatus.present(connection: .connected, binding: binding, workspace: workspace, helper: helper, hasFrame: false)
        #expect(waiting.overlay == .waitingForFirstFrame)
    }

    @Test func subscribeFailureTableIsBounded() {
        var helper = HelperStatus()
        for id in 0..<1000 { helper.noteSubscribeFailure(window: WindowID(rawValue: UInt32(id)), reason: .transient) }
        #expect(helper.subscribeFailures.count == HelperStatus.maxSubscribeFailures)
    }

    @Test func aNewConnectionForgetsTheOldStatus() {
        var helper = HelperStatus()
        helper.apply(.macLocked(true))
        helper.apply(.secureInput(active: true, pid: nil))
        helper.reset()
        #expect(helper == HelperStatus())
    }
}
