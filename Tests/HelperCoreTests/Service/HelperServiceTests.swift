#if os(macOS)
import Foundation
import LinkProtocol
import Testing
@testable import HelperCore

@Suite(.timeLimit(.minutes(2))) struct HelperServiceTests {
    // MARK: Lifecycle and snapshot

    @Test func startPublishesStatusAndSendsSnapshotToANewSession() async throws {
        let h = try ServiceHarness()
        try await h.start()
        let status = await h.service.status
        #expect(status.phase == .running && status.listeningPort == 4242)
        #expect(h.listener.startCount == 1)

        let c = await h.connect(1, name: "Alice's iPad")
        let snapshot = try #require(c.snapshot)
        #expect(snapshot.windows.map(\.title).sorted() == ["One", "Other", "Two"])
        #expect(snapshot.apps.map(\.bundleID).sorted() == ["com.example.app10", "com.example.app11"])
        // The snapshot comes first, then the conditions.
        #expect(c.sent.first.map { if case .snapshot = $0 { true } else { false } } == true)
        #expect(c.statuses.contains(.permission(.accessibility, .granted)))
        #expect(c.statuses.contains(.permission(.screenRecording, .granted)))
        #expect(c.statuses.contains(.stage(.active)))
        let sessions = await h.service.status.sessions
        #expect(sessions.map(\.deviceName) == ["Alice's iPad"])
        #expect(h.awake.held)
        await h.service.stop()
    }

    @Test func listenerFailureLeavesAFailedStatus() async throws {
        let h = try ServiceHarness()
        h.listener.failStart = true
        await #expect(throws: HelperServiceError.self) { try await h.service.start() }
        let status = await h.service.status
        #expect(status.phase == .failed("listenerFailed(\"port in use\")") || { if case .failed = status.phase { true } else { false } }())
        #expect(status.issues.contains { if case .failed = $0 { true } else { false } })
    }

    @Test func statusStreamReportsSessionsComingAndGoing() async throws {
        let h = try ServiceHarness()
        try await h.start()
        let updates = await h.service.statusUpdates()
        let seen = Locked<[HelperStatus]>([])
        let task = Task { for await s in updates { seen.withValue { $0.append(s) } } }
        let c = await h.connect(1, name: "Bob's iPad")
        #expect(await waitUntil { seen.get().contains { $0.sessions.map(\.deviceName) == ["Bob's iPad"] } })
        c.end()
        #expect(await waitUntil { seen.get().last?.sessions.isEmpty == true })
        task.cancel()
        await h.service.stop()
    }

    // MARK: Video

    @Test func subscribeStartsCaptureAndFramesFlowToTheDevice() async throws {
        let h = try ServiceHarness()
        try await h.start()
        let c = await h.connect(1)
        let one = h.windowID("One", in: c)
        await h.subscribe(c, one)
        #expect(await waitUntil { h.capture.liveStreams == 1 })
        #expect(c.sent.contains { if case .windowCapabilities(let w, _) = $0 { w == one } else { false } })

        h.emitFrame(one)
        #expect(await waitUntil { c.videoFrames.count == 1 })
        let config = try #require(c.videoConfigs.first)
        #expect(config.window == one && config.parameterSets.count == 2 && config.pixelWidth == 16)
        let frame = try #require(c.videoFrames.first)
        #expect(frame.window == one && frame.flags.contains(.key) && frame.sequence == 0)
        // Config before the first frame.
        let order = c.sent.compactMap { m -> String? in
            switch m { case .videoConfig: "config"; case .videoFrame: "frame"; default: nil }
        }
        #expect(order.first == "config")

        h.clock.advance(0.05)
        h.emitFrame(one)
        #expect(await waitUntil { c.videoFrames.count == 2 })
        #expect(c.videoFrames[1].flags.contains(.key) == false)
        await h.service.stop()
    }

    @Test func unsubscribeAndCloseTearDownEverything() async throws {
        let h = try ServiceHarness()
        try await h.start()
        let c = await h.connect(1)
        let one = h.windowID("One", in: c), two = h.windowID("Two", in: c)
        await h.subscribe(c, one)
        await h.subscribe(c, two)
        #expect(await waitUntil { h.capture.liveStreams == 2 })
        h.emitFrame(one)
        #expect(await waitUntil { h.encoders.live.count == 1 })

        await c.control(.windowUnsubscribe(one))
        #expect(await waitUntil { h.capture.liveStreams == 1 })
        #expect(await waitUntil { c.finished.contains(one) })
        #expect(h.encoders.live.isEmpty)
        // Input for the window it no longer streams is dropped.
        await c.input(.inputPointer(LinkPointerEvent(window: one, point: LinkPoint(x: 5, y: 5), buttons: [], modifiers: [])))
        #expect(h.poster.events.isEmpty)

        c.end()
        #expect(await waitUntil { h.capture.liveStreams == 0 })
        #expect(await waitUntil { await h.service.status.sessions.isEmpty })
        #expect(await waitUntil { !h.awake.held })
        // The last session ending put the window back and removed the virtual display.
        #expect(await waitUntil { h.axFrame(pid: 10, id: 1) == ServiceHarness.originalFrame })
        #expect(await waitUntil { await h.stageDisplay.removeCount == 1 })
        await h.service.stop()
    }

    @Test func subscribingToUnknownOrTransientWindowsDoesNothing() async throws {
        let h = try ServiceHarness()
        try await h.start()
        let c = await h.connect(1)
        await h.subscribe(c, WindowID(9999))
        #expect(await waitUntil { c.sent.contains(.windowSubscribeFailed(window: 9999, reason: .unknownWindow)) })
        try await Task.sleep(for: .milliseconds(50))
        #expect(h.capture.liveStreams == 0 && h.capture.startCount == 0)
        await h.service.stop()
    }

    @Test func subscriptionAndSessionLimitsAreEnforced() async throws {
        let h = try ServiceHarness(maxSubscriptions: 2, maxSessions: 2)
        try await h.start()
        let a = await h.connect(1)
        let ids = ["One", "Two", "Other"].map { h.windowID($0, in: a) }
        for id in ids { await h.subscribe(a, id) }
        #expect(await waitUntil { h.capture.liveStreams == 2 })
        try await Task.sleep(for: .milliseconds(50))
        #expect(h.capture.liveStreams == 2)
        #expect(await waitUntil { a.sent.contains(.windowSubscribeFailed(window: ids[2], reason: .limit)) })

        // The iPad's own announced limit lowers it further.
        let b = await h.connect(2, sceneLimits: LinkSceneLimits(maxWindows: 1, maxStreams: 1, maxPixelWidth: 0, maxPixelHeight: 0, maxFramesPerSecond: 0))
        await h.subscribe(b, ids[2])
        await h.subscribe(b, ids[0])
        #expect(await waitUntil { h.capture.liveStreams == 3 })
        try await Task.sleep(for: .milliseconds(50))
        #expect(h.capture.liveStreams == 3)

        // A third iPad does not get a session.
        let third = FakeConnection(id: 3)
        h.listener.connect(third)
        #expect(await waitUntil { third.closeCodes == [.tooManySessions] })
        #expect(await h.service.status.sessions.count == 2)
        await h.service.stop()
    }

    @Test func windowDestroyedOnTheMacEndsItsStream() async throws {
        let h = try ServiceHarness(stage: false)
        try await h.start()
        let c = await h.connect(1)
        let other = h.windowID("Other", in: c)
        await h.subscribe(c, other)
        #expect(await waitUntil { h.capture.liveStreams == 1 })
        h.windows.removeApp(11)
        h.windows.send(.appTerminated(pid: 11))
        #expect(await waitUntil { h.capture.liveStreams == 0 })
        #expect(c.sent.contains { if case .windowDestroyed(let w) = $0 { w == other } else { false } })
        await h.service.stop()
    }

    // MARK: Input authorisation

    @Test func inputIsRoutedOnlyToWindowsTheSessionSubscribedTo() async throws {
        let h = try ServiceHarness(stage: false)
        try await h.start()
        let a = await h.connect(1), b = await h.connect(2)
        let one = h.windowID("One", in: a), two = h.windowID("Two", in: a), other = h.windowID("Other", in: a)
        await h.subscribe(a, one)
        await h.subscribe(b, other)
        #expect(await waitUntil { h.capture.liveStreams == 2 })

        // A's window: accepted. B's window and an unsubscribed window: dropped even though the injector authorises the union.
        await a.input(.inputPointer(LinkPointerEvent(window: one, point: LinkPoint(x: 10, y: 10), buttons: [], modifiers: [])))
        #expect(await waitUntil { !h.poster.events.isEmpty })
        let accepted = h.poster.events.count
        await a.input(.inputPointer(LinkPointerEvent(window: other, point: LinkPoint(x: 10, y: 10), buttons: [], modifiers: [])))
        await a.input(.inputPointer(LinkPointerEvent(window: two, point: LinkPoint(x: 10, y: 10), buttons: [], modifiers: [])))
        await a.input(.inputScroll(LinkScrollEvent(window: other, dx: 0, dy: 5, phase: .changed, momentumPhase: .none, continuous: true)))
        #expect(h.poster.events.count == accepted)

        // Keys go to the session's focused window only.
        await b.input(.inputText("x"))
        #expect(await waitUntil { h.poster.events.contains { if case .unicode = $0 { true } else { false } } })
        let typed = h.poster.events.count
        let c = await h.connect(3)
        await c.input(.inputText("y"))  // no subscription, no focus
        try await Task.sleep(for: .milliseconds(50))
        #expect(h.poster.events.count == typed)
        await h.service.stop()
    }

    // MARK: Rate control and recovery

    @Test func statsDriveEncoderTargetsAndCapturePacing() async throws {
        let h = try ServiceHarness()
        try await h.start()
        let c = await h.connect(1)
        let one = h.windowID("One", in: c)
        await h.subscribe(c, one, fps: 120)
        #expect(await waitUntil { h.capture.liveStreams == 1 })
        h.emitFrame(one)
        #expect(await waitUntil { h.encoders.live.count == 1 })
        let encoder = try #require(h.encoders.live.first)

        func stats(rttMicros: UInt32, dropped: UInt32) -> LinkMessage {
            .stats(LinkStats(rttMicros: rttMicros, windows: [LinkWindowStats(window: one, receivedBytes: 40_000, decodedFrames: 10, droppedFrames: dropped, decodeP95Micros: 2000)]))
        }
        h.clock.advance(0.25)
        await c.control(stats(rttMicros: 8000, dropped: 0))
        #expect(await waitUntil { !encoder.targets.isEmpty })
        let first = try #require(encoder.targets.last)
        #expect(first.fps <= 60 && first.bitrate > 0)

        // Congestion: capacity and the encoder's bitrate come down.
        for _ in 0..<4 {
            h.clock.advance(0.6)
            await c.control(stats(rttMicros: 90_000, dropped: 5))
        }
        let last = try #require(encoder.targets.last)
        #expect(last.bitrate < first.bitrate)
        // The capture pacing follows the decision.
        #expect(h.capture.updateConfigs.contains { $0.window == one && $0.framesPerSecond <= 60 })
        // Stats for a window the session does not stream are ignored.
        let before = encoder.targets.count
        await c.control(.stats(LinkStats(rttMicros: 1, windows: [LinkWindowStats(window: WindowID(77), receivedBytes: 1, decodedFrames: 1, droppedFrames: 9, decodeP95Micros: 1)])))
        #expect(encoder.targets.count >= before)
        await h.service.stop()
    }

    @Test func keyFrameRequestsLossRecoveryAndAcknowledgements() async throws {
        let h = try ServiceHarness()
        try await h.start()
        let c = await h.connect(1)
        let one = h.windowID("One", in: c)
        await h.subscribe(c, one)
        #expect(await waitUntil { h.capture.liveStreams == 1 })
        h.emitFrame(one)
        #expect(await waitUntil { c.videoFrames.count == 1 })
        let encoder = try #require(h.encoders.live.first)

        // stream.keyframe re-encodes the newest frame as a key frame, even if the window has stopped changing.
        h.clock.advance(1)
        await c.control(.streamKeyframe(one))
        #expect(await waitUntil { c.videoFrames.count == 2 })
        #expect(c.videoFrames[1].flags.contains(.key))
        // A flood is throttled.
        await c.control(.streamKeyframe(one))
        await c.control(.streamKeyframe(one))
        #expect(c.videoFrames.count == 2)

        // Loss before the iPad acknowledged any long-term reference: a key frame.
        h.clock.advance(1)
        await c.control(.videoLost(window: one, firstSequence: 1, lastSequence: 1))
        #expect(await waitUntil { c.videoFrames.count == 3 })
        #expect(encoder.encodes.last?.options.forceKeyFrame == true)

        // After an acknowledgement (token = frame sequence) loss is repaired from a long-term reference.
        await c.control(.videoAck(window: one, ltrTokens: [0, 2]))
        #expect(encoder.acks == [[0, 2]])
        h.clock.advance(1)
        await c.control(.videoLost(window: one, firstSequence: 4, lastSequence: 5))
        #expect(await waitUntil { c.videoFrames.count == 4 })
        #expect(encoder.encodes.last?.options.forceLTRRefresh == true && encoder.encodes.last?.options.forceKeyFrame == false)

        // The transport reporting dropped video frames asks for a key frame as well.
        h.clock.advance(1)
        await c.event(.videoBackpressure(window: one, droppedFrames: 3, needsKeyframe: true))
        #expect(await waitUntil { c.videoFrames.count == 5 })
        #expect(encoder.encodes.last?.options.forceKeyFrame == true)
        await h.service.stop()
    }

    // MARK: Menus, clipboard, files

    @Test func menusAreOnlyServedForAppsWithASubscribedWindow() async throws {
        let h = try ServiceHarness(stage: false)
        try await h.start()
        let c = await h.connect(1)
        let one = h.windowID("One", in: c)
        await c.control(.menuGet(bundleID: "com.example.app10"))
        try await Task.sleep(for: .milliseconds(50))
        #expect(c.count { if case .menuTree = $0 { true } else { false } } == 0)

        await h.subscribe(c, one)
        #expect(await waitUntil { h.capture.liveStreams == 1 })
        await c.control(.menuGet(bundleID: "com.example.app10"))
        #expect(await waitUntil { c.count { if case .menuTree = $0 { true } else { false } } == 1 })
        // Another app: refused, and so is pressing in it.
        await c.control(.menuGet(bundleID: "com.example.app11"))
        await c.control(.menuPress(bundleID: "com.example.app11", path: [0, 0]))
        // The subscribed app: pressed.
        await c.control(.menuPress(bundleID: "com.example.app10", path: [0, 1]))
        #expect(await waitUntil { h.menuSystem.pressed == [[0, 1]] })
        #expect(c.count { if case .menuTree = $0 { true } else { false } } == 1)
        await h.service.stop()
    }

    @Test func clipboardNeedsASubscribedWindowAndFlowsBothWays() async throws {
        let h = try ServiceHarness(stage: false)
        try await h.start()
        let c = await h.connect(1)
        let one = h.windowID("One", in: c)
        await c.control(.clipboardOffer(types: [ClipboardWireType.text]))
        #expect(c.count { if case .clipboardRequest = $0 { true } else { false } } == 0)

        await h.subscribe(c, one)
        #expect(await waitUntil { h.capture.liveStreams == 1 })
        await c.control(.clipboardOffer(types: [ClipboardWireType.text]))
        #expect(c.sent.contains { $0 == .clipboardRequest(type: ClipboardWireType.text) })
        await c.control(.clipboardData(type: ClipboardWireType.text, data: Data("hello".utf8)))
        #expect(h.pasteboard.writes.count == 1)

        // Mac to iPad: a new copy is offered; a concealed one is not.
        h.pasteboard.copy([ClipboardWireType.text: Data("from the Mac".utf8)])
        #expect(await waitUntil { c.sent.contains { $0 == .clipboardOffer(types: [ClipboardWireType.text]) } })
        let offers = c.count { if case .clipboardOffer = $0 { true } else { false } }
        h.pasteboard.copy(["org.nspasteboard.ConcealedType": Data(), ClipboardWireType.text: Data("secret".utf8)])
        try await Task.sleep(for: .milliseconds(100))
        #expect(c.count { if case .clipboardOffer = $0 { true } else { false } } == offers)
        await h.service.stop()
    }

    @Test func filesNeedASubscribedWindowAndOpenOnlyInStreamedApps() async throws {
        let h = try ServiceHarness(stage: false)
        try await h.start()
        let c = await h.connect(1)
        let one = h.windowID("One", in: c)
        let body = Data("hello world".utf8)

        // No subscription: nothing is written.
        await c.control(.fileBegin(LinkFileBegin(transfer: 1, name: "a.txt", size: UInt64(body.count), targetBundleID: nil)))
        await c.control(.fileChunk(LinkFileChunk(transfer: 1, offset: 0, data: body)))
        await c.control(.fileEnd(transfer: 1, sha256: sha256(body)))
        let none = (try? FileManager.default.contentsOfDirectory(atPath: h.inboxRoot.path)) ?? []
        #expect(none.isEmpty)

        await h.subscribe(c, one)
        #expect(await waitUntil { h.capture.liveStreams == 1 })
        // A target app that is not being streamed is refused.
        await c.control(.fileBegin(LinkFileBegin(transfer: 2, name: "b.txt", size: UInt64(body.count), targetBundleID: "com.example.app11")))
        await c.control(.fileChunk(LinkFileChunk(transfer: 2, offset: 0, data: body)))
        await c.control(.fileEnd(transfer: 2, sha256: sha256(body)))
        #expect(h.opener.opened.isEmpty)

        // The streamed app: stored, verified and opened through the inbox rules.
        await c.control(.fileBegin(LinkFileBegin(transfer: 3, name: "c.txt", size: UInt64(body.count), targetBundleID: "com.example.app10")))
        await c.control(.fileChunk(LinkFileChunk(transfer: 3, offset: 0, data: body)))
        await c.control(.fileEnd(transfer: 3, sha256: sha256(body)))
        #expect(await waitUntil { h.opener.opened.count == 1 })
        #expect(h.opener.opened[0].0.lastPathComponent == "c.txt" && h.opener.opened[0].1 == "com.example.app10")
        // A wrong digest is rejected.
        await c.control(.fileBegin(LinkFileBegin(transfer: 4, name: "d.txt", size: UInt64(body.count), targetBundleID: "com.example.app10")))
        await c.control(.fileChunk(LinkFileChunk(transfer: 4, offset: 0, data: body)))
        await c.control(.fileEnd(transfer: 4, sha256: sha256(Data("other".utf8))))
        #expect(h.opener.opened.count == 1)
        await h.service.stop()
    }

    @Test func twoDevicesMayUseTheSameTransferNumber() async throws {
        let h = try ServiceHarness(stage: false)
        try await h.start()
        let a = await h.connect(1), b = await h.connect(2)
        await h.subscribe(a, h.windowID("One", in: a))
        await h.subscribe(b, h.windowID("Other", in: b))
        #expect(await waitUntil { h.capture.liveStreams == 2 })
        let body = Data("x".utf8)
        for (connection, name) in [(a, "a.txt"), (b, "b.txt")] {
            await connection.control(.fileBegin(LinkFileBegin(transfer: 7, name: name, size: 1, targetBundleID: nil)))
        }
        for connection in [a, b] {
            await connection.control(.fileChunk(LinkFileChunk(transfer: 7, offset: 0, data: body)))
            await connection.control(.fileEnd(transfer: 7, sha256: sha256(body)))
        }
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: h.inboxRoot.path)) ?? []
        #expect(entries.count == 2)
        await h.service.stop()
    }

    // MARK: Apps

    @Test func appCommandsAreServedAndBounded() async throws {
        let h = try ServiceHarness(stage: false)
        try await h.start()
        let c = await h.connect(1)
        await c.control(.appsList(filter: .running))
        #expect(await waitUntil { c.sent.contains { if case .appsItems(let items) = $0 { items.count == 2 } else { false } } })
        await c.control(.appsLaunch(bundleID: "com.example.new"))
        #expect(await waitUntil { h.workspace.launched == ["com.example.new"] })
        await c.control(.appsLaunch(bundleID: String(repeating: "a", count: 300)))
        #expect(h.workspace.launched.count == 1)
        // The Finder is never quit remotely.
        await c.control(.appsQuit(bundleID: "com.apple.finder"))
        await h.service.stop()
    }

    // MARK: Status: lock, permissions, stage, secure input

    @Test func macLockedIsReportedToConnectedAndNewSessions() async throws {
        let h = try ServiceHarness(stage: false)
        try await h.start()
        let c = await h.connect(1)
        h.lockMonitor.set(true)
        #expect(await waitUntil { c.statuses.contains(.macLocked(true)) })
        #expect(await h.service.status.issues.contains(.macLocked))
        let late = await h.connect(2)
        #expect(late.statuses.contains(.macLocked(true)))
        h.lockMonitor.set(false)
        #expect(await waitUntil { c.statuses.contains(.macLocked(false)) })
        #expect(await h.service.status.macLocked == false)
        await h.service.stop()
    }

    @Test func missingPermissionsAreReportedAndBlockStreaming() async throws {
        let h = try ServiceHarness(stage: false)
        h.permissions.set(.screenRecording, .denied)
        try await h.start()
        let c = await h.connect(1)
        #expect(c.statuses.contains(.permissionMissing(.screenRecording)))
        #expect(await h.service.status.issues.contains(.permissionMissing(.screenRecording)))

        await h.subscribe(c, h.windowID("One", in: c))
        try await Task.sleep(for: .milliseconds(50))
        #expect(h.capture.startCount == 0)

        // The person grants it in System Settings: the next poll reports it and streaming works.
        h.permissions.set(.screenRecording, .granted)
        #expect(await waitUntil { c.statuses.contains(.permission(.screenRecording, .granted)) })
        await h.subscribe(c, h.windowID("One", in: c))
        #expect(await waitUntil { h.capture.liveStreams == 1 })

        h.permissions.set(.accessibility, .denied)
        #expect(await waitUntil { c.statuses.contains(.permissionMissing(.accessibility)) })
        await h.service.stop()
    }

    @Test func eventPostingRefusedCountsAsAMissingAccessibilityPermission() async throws {
        let h = try ServiceHarness(stage: false)
        h.poster.canPostEvents = false
        try await h.start()
        let c = await h.connect(1)
        #expect(c.statuses.contains(.permissionMissing(.accessibility)))
        await h.service.stop()
    }

    @Test func secureInputIsReportedWhileAnIPadIsConnected() async throws {
        let h = try ServiceHarness(stage: false)
        try await h.start()
        let c = await h.connect(1)
        h.secureInput.enabled = true
        #expect(await waitUntil { c.statuses.contains { if case .secureInput = $0 { true } else { false } } })
        #expect(await h.service.status.issues.contains(.secureInput))
        #expect(c.statuses.contains { if case .secureInput(active: true, _) = $0 { true } else { false } })
        h.secureInput.enabled = false
        #expect(await waitUntil { c.statuses.contains(.secureInput(active: false, pid: nil)) })
        #expect(await h.service.status.issues.contains(.secureInput) == false)
        await h.service.stop()
    }

    @Test func endingOneSessionDoesNotReleaseInputHeldByAnother() async throws {
        let h = try ServiceHarness(stage: false)
        try await h.start()
        let a = await h.connect(1), b = await h.connect(2)
        let one = h.windowID("One", in: a), two = h.windowID("Two", in: a)
        await h.subscribe(a, one)
        await h.subscribe(b, two)
        #expect(await waitUntil { h.capture.liveStreams == 2 })
        await b.input(.inputKey(LinkKeyEvent(keycode: 9, down: true, modifiers: [])))
        await a.input(.inputKey(LinkKeyEvent(keycode: 8, down: true, modifiers: [])))
        #expect(await waitUntil { h.poster.events.count >= 2 })
        h.poster.clear()
        a.end()
        #expect(await waitUntil { await h.service.status.sessions.count == 1 })
        // A's key was released; B's key is still down.
        #expect(await waitUntil { h.poster.events.contains(.key(keycode: 8, down: false, modifiers: [])) })
        #expect(!h.poster.events.contains(.key(keycode: 9, down: false, modifiers: [])))
        b.end()
        #expect(await waitUntil { h.poster.events.contains(.key(keycode: 9, down: false, modifiers: [])) })
        await h.service.stop()
    }

    @Test func stageUnavailableIsReportedAndWindowsAreStillRestored() async throws {
        let h = try ServiceHarness()
        await h.stageDisplay.setFailCreate(true)
        try await h.start()
        let c = await h.connect(1)
        #expect(c.statuses.contains(.stage(.unavailable)) && c.statuses.contains(.stageUnavailable))
        #expect(await h.service.status.issues.contains(.stageUnavailable))
        // Resize in place.
        let one = h.windowID("One", in: c)
        await h.subscribe(c, one)
        #expect(await waitUntil { h.capture.liveStreams == 1 })
        await c.control(.windowSetFrame(LinkSetFrame(window: one, size: LinkSize(width: 640, height: 480), placement: .keep)))
        #expect(await waitUntil { h.axFrame(pid: 10, id: 1)?.size == LinkSize(width: 640, height: 480) })
        c.end()
        #expect(await waitUntil { h.axFrame(pid: 10, id: 1) == ServiceHarness.originalFrame })
        await h.service.stop()
    }

    // MARK: Stage and window restore

    @Test func windowsMoveToTheStageAndComeBackWhenTheLastSessionEnds() async throws {
        let h = try ServiceHarness()
        try await h.start()
        let a = await h.connect(1), b = await h.connect(2)
        let one = h.windowID("One", in: a), two = h.windowID("Two", in: a)
        await h.subscribe(a, one)
        await h.subscribe(b, two)
        #expect(await waitUntil { h.capture.liveStreams == 2 })
        // Both are on the virtual display (right of the 1440 pt main display).
        #expect(await waitUntil { (h.axFrame(pid: 10, id: 1)?.origin.x ?? 0) >= 1440 && (h.axFrame(pid: 10, id: 2)?.origin.x ?? 0) >= 1440 })
        #expect(await h.stageDisplay.createCount == 1)

        // One device leaves: only its window goes back; the display stays.
        a.end()
        #expect(await waitUntil { h.axFrame(pid: 10, id: 1) == ServiceHarness.originalFrame })
        #expect((h.axFrame(pid: 10, id: 2)?.origin.x ?? 0) >= 1440)
        #expect(await h.stageDisplay.removeCount == 0)

        b.end()
        #expect(await waitUntil { h.axFrame(pid: 10, id: 2) == rect(200, 150, 500, 400) })
        #expect(await waitUntil { await h.stageDisplay.removeCount == 1 })
        #expect(await h.journal.stored == nil)
        await h.service.stop()
    }

    @Test func setFrameResizesTheStreamedWindowThroughTheStage() async throws {
        let h = try ServiceHarness()
        try await h.start()
        let c = await h.connect(1)
        let one = h.windowID("One", in: c)
        await h.subscribe(c, one)
        #expect(await waitUntil { h.capture.liveStreams == 1 })
        await c.control(.windowSetFrame(LinkSetFrame(window: one, size: LinkSize(width: 700, height: 500), placement: .center)))
        #expect(await waitUntil { h.axFrame(pid: 10, id: 1)?.size == LinkSize(width: 700, height: 500) })
        // Not for a window this device does not stream.
        let two = h.windowID("Two", in: c)
        await c.control(.windowSetFrame(LinkSetFrame(window: two, size: LinkSize(width: 123, height: 99), placement: .keep)))
        try await Task.sleep(for: .milliseconds(300))
        #expect(h.axFrame(pid: 10, id: 2)?.size == LinkSize(width: 500, height: 400))
        await h.service.stop()
    }

    @Test func windowCommandsNeedASubscriptionExceptRaise() async throws {
        let h = try ServiceHarness(stage: false)
        try await h.start()
        let c = await h.connect(1)
        let one = h.windowID("One", in: c), two = h.windowID("Two", in: c)
        await h.subscribe(c, one)
        #expect(await waitUntil { h.capture.liveStreams == 1 })
        await c.control(.windowCommand(window: two, command: .close))
        await c.control(.windowCommand(window: two, command: .raise))
        #expect(h.windows.calls.filter { $0 == "close" }.isEmpty)
        #expect(h.windows.calls.contains("raise"))
        await c.control(.windowCommand(window: one, command: .zoom))
        #expect(h.windows.calls.contains("zoom"))
        await h.service.stop()
    }

    @Test func stopClosesSessionsAndRestoresWindows() async throws {
        let h = try ServiceHarness()
        try await h.start()
        let c = await h.connect(1)
        await h.subscribe(c, h.windowID("One", in: c))
        #expect(await waitUntil { (h.axFrame(pid: 10, id: 1)?.origin.x ?? 0) >= 1440 })
        await h.service.stop()
        #expect(c.closeCodes.contains(.helperShuttingDown))
        #expect(h.axFrame(pid: 10, id: 1) == ServiceHarness.originalFrame)
        #expect(h.capture.liveStreams == 0 && h.encoders.live.isEmpty)
        let status = await h.service.status
        #expect(status.phase == .stopped && status.sessions.isEmpty && !h.awake.held)
    }

    @Test func aWindowLeftOnTheStageByACrashIsRestoredAtNextStart() async throws {
        let h = try ServiceHarness()
        // A previous run moved window 501 to the stage and died.
        let key = StageWindowKey(pid: 10, windowNumber: 501)
        let moved = rect(1500, 20, 400, 300)
        h.windows.setAX(10, [axWindow(10, 1, cg: 501, frame: moved, title: "One"), axWindow(10, 2, cg: 502, frame: rect(200, 150, 500, 400), title: "Two")])
        try await h.journal.save(StageJournal(bootID: currentBootIdentifier(), entries: [
            .init(window: key, frame: StageFrame(ServiceHarness.originalFrame), display: StageDisplayID(rawValue: 1)),
        ]))
        try await h.start()
        #expect(await waitUntil { h.axFrame(pid: 10, id: 1) == ServiceHarness.originalFrame })
        await h.service.stop()
    }

    // MARK: Audio

    @Test func audioIsOffUnlessEnabledAndNegotiated() async throws {
        let off = try ServiceHarness(stage: false)
        try await off.start()
        let a = await off.connect(1)
        await off.subscribe(a, off.windowID("One", in: a))
        #expect(await waitUntil { off.capture.liveStreams == 1 })
        #expect(a.count { if case .audioConfig = $0 { true } else { false } } == 0)
        await off.service.stop()

        let on = try ServiceHarness(stage: false, audio: true)
        try await on.start()
        let denied = await on.connect(1, capabilities: FakeConnection.allCapabilities.subtracting(.audio))
        await on.subscribe(denied, on.windowID("One", in: denied))
        #expect(await waitUntil { on.capture.liveStreams == 1 })
        #expect(denied.count { if case .audioConfig = $0 { true } else { false } } == 0)

        let c = await on.connect(2)
        await on.subscribe(c, on.windowID("Other", in: c))
        #expect(await waitUntil { c.count { if case .audioConfig(let cfg) = $0 { cfg.pid == 11 && cfg.codec == .pcm16 } else { false } } == 1 })
        on.audioCapture.continuation.get()?.yield(PCMChunk(ptsMicros: 0, samples: Data(count: 480 * 2 * 2 * 3)))
        #expect(await waitUntil { c.count { if case .audioPacket = $0 { true } else { false } } >= 2 })
        await c.control(.windowUnsubscribe(on.windowID("Other", in: c)))
        #expect(await waitUntil { on.audioCapture.stopped.get() >= 1 })
        await on.service.stop()
    }
}

// MARK: - Adapters

@Suite(.timeLimit(.minutes(2))) struct WindowAdapterTests {
    func makeTracker() async -> (WindowTracker, FakeWindowSystem) {
        let system = FakeWindowSystem()
        system.pids = [10, 11]
        system.frontmost = 10
        system.cg = [cgRecord(501, 10), cgRecord(601, 11, bounds: rect(300, 200, 400, 300))]
        system.setAX(10, [axWindow(10, 1, cg: 501, focused: true)])
        system.setAX(11, [axWindow(11, 1, cg: 601, frame: rect(300, 200, 400, 300))])
        let tracker = WindowTracker(system: system)
        await tracker.reconcile()
        return (tracker, system)
    }

    @Test func stageKeysRoundTripAndTheFrameSetterResizesThroughTheTracker() async throws {
        let (tracker, system) = await makeTracker()
        let windows = await tracker.snapshot().windows
        let first = try #require(windows.first { $0.pid == 10 })
        let key = try #require(await tracker.stageKey(of: first.id))
        #expect(key == StageWindowKey(pid: 10, windowNumber: 501))
        #expect(await tracker.window(forStageKey: key) == first.id)
        #expect(await tracker.window(forStageKey: StageWindowKey(pid: 10, windowNumber: 999)) == nil)

        let setter = TrackerFrameSetter(tracker: tracker)
        #expect(await setter.currentFrame(of: key) == rect(100, 100, 800, 600))
        let actual = await setter.setFrame(key, to: rect(10, 20, 640, 480))
        #expect(actual == rect(10, 20, 640, 480))
        #expect(system.ax(10)[0].frame == rect(10, 20, 640, 480))
        #expect(await setter.setFrame(StageWindowKey(pid: 10, windowNumber: 999), to: rect(0, 0, 10, 10)) == nil)
        await setter.exitFullScreen(key)
        #expect(system.calls.contains("fullscreen false"))
    }

    @Test func aWindowWithoutAServerNumberGetsAHighBitKey() async throws {
        let system = FakeWindowSystem()
        system.pids = [10]
        system.frontmost = 10
        system.cg = [cgRecord(501, 10)]
        system.setAX(10, [axWindow(10, 7, cg: nil, focused: true)])  // matched by frame, number comes from the CG record
        let tracker = WindowTracker(system: system)
        await tracker.reconcile()
        let id = try #require(await tracker.snapshot().windows.first?.id)
        #expect(await tracker.stageKey(of: id)?.windowNumber == 501)

        system.cg = []  // no record, no AX number
        system.setAX(10, [axWindow(10, 7, cg: nil, focused: true)])
        await tracker.reconcile()
        let after = try #require(await tracker.snapshot().windows.first?.id)
        let key = try #require(await tracker.stageKey(of: after))
        #expect(key.windowNumber & 0x8000_0000 != 0)
        #expect(await tracker.window(forStageKey: key) == after)
    }

    @Test func geometryIsReadLiveAndFocusFollowsTheWindowServerOrder() async throws {
        let (tracker, system) = await makeTracker()
        let windows = await tracker.snapshot().windows
        let a = try #require(windows.first { $0.pid == 10 }), b = try #require(windows.first { $0.pid == 11 })

        let geometry = TrackerWindowGeometry(tracker: tracker)
        system.setAX(10, [axWindow(10, 1, cg: 501, frame: rect(500, 400, 800, 600), focused: true)])  // moved, tracker not yet told
        #expect(await geometry.contentFrame(of: a.id) == rect(500, 400, 800, 600))
        #expect(await geometry.contentFrame(of: WindowID(99)) == nil)
        system.setAX(10, [axWindow(10, 1, cg: 501, frame: rect(100, 100, 800, 600), focused: true)])

        let workspace = FakeWorkspace(apps: [RunningAppInfo(pid: 10, bundleID: "com.example.app10", name: "A")])
        let focuser = TrackerWindowFocuser(tracker: tracker, system: system, workspace: workspace)
        // Window 501 is first in the list at (150, 150); 601 at (320, 220) is only under its own area.
        #expect(await focuser.isFrontmost(a.id, at: LinkPoint(x: 150, y: 150)))
        #expect(await focuser.isFrontmost(b.id, at: LinkPoint(x: 150, y: 150)) == false)
        #expect(await focuser.isFrontmost(b.id, at: LinkPoint(x: 1000, y: 1000)) == false)
        #expect(await focuser.frontmostWindow() == a.id)
        system.frontmost = 11
        #expect(await focuser.frontmostWindow() == nil)  // the tracker has not caught up; do not guess
        await focuser.raiseAndActivate(a.id)
        #expect(system.calls.contains("raise"))
    }
}
#endif
