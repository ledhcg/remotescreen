#if os(macOS)
import Foundation
import LinkProtocol
import os

/// Arranges streamed windows on a virtual display (or resizes them in place), and puts everything back afterwards.
///
/// **Restore guarantee.** Before the first move or resize of a window, its original frame and display are written to the
/// journal (atomically). They are put back when the window is released, when the session ends, when the helper quits, and
/// at the next launch if the helper died without doing so (`recoverFromCrash`). Restoring twice is harmless.
public actor Stage {
    public struct ManagedWindow: Sendable, Equatable {
        public var window: WindowID
        public var key: StageWindowKey
        public var desired: LinkSize
        public var limits: StageSizeLimits
        public var original: LinkRect
        public var originalDisplay: StageDisplayID?
        /// Last frame the app reported after we set it.
        public var actual: LinkRect?
    }

    public enum ManageError: Error, Equatable {
        case windowGone
        /// The journal could not be written, so the window was left untouched.
        case journalUnavailable
        case invalidSize
    }

    private let display: any DisplayStage
    private let frames: any WindowFrameSetter
    private let journal: any StageJournalStore
    private let debounce: Duration
    private let gap: Double
    private let bootID: String
    private let sleep: @Sendable (Duration) async throws -> Void
    private let onState: @Sendable (LinkStageState) -> Void
    private let log = Logger(subsystem: "app.screon.helper", category: "stage")

    public private(set) var state: LinkStageState = .inactive
    private var stageDisplay: StageDisplay?
    private var managed: [WindowID: ManagedWindow] = [:]
    /// Insertion order, so layouts are deterministic.
    private var order: [WindowID] = []
    private var journalState: StageJournal
    private var pendingSizes: [WindowID: LinkSize] = [:]
    private var debounceTask: Task<Void, Never>?
    private var generation = 0

    public init(
        display: any DisplayStage,
        frames: any WindowFrameSetter,
        journal: any StageJournalStore,
        debounce: Duration = .milliseconds(150),
        gap: Double = 8,
        bootID: String = currentBootIdentifier(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        onState: @escaping @Sendable (LinkStageState) -> Void = { _ in }
    ) {
        self.display = display; self.frames = frames; self.journal = journal; self.debounce = debounce; self.gap = gap
        self.bootID = bootID; self.sleep = sleep; self.onState = onState
        journalState = StageJournal(bootID: bootID)
    }

    public var managedWindows: [ManagedWindow] { order.compactMap { managed[$0] } }
    public var virtualDisplay: StageDisplay? { stageDisplay }

    private func setState(_ new: LinkStageState) {
        guard new != state else { return }
        state = new
        onState(new)
    }

    // MARK: Lifecycle

    /// Starts a stage session. Anything left behind by a crashed helper is restored first. With a `spec` a virtual display is
    /// created; without one (or when that fails) windows are only resized in place.
    public func start(display spec: VirtualDisplaySpec?) async {
        await recoverFromCrash()
        guard let spec else { setState(.inactive); return }
        setState(.preparing)
        do {
            stageDisplay = try await display.createDisplay(spec)
            setState(.active)
        } catch {
            log.error("stage unavailable: \(String(describing: error), privacy: .private)")
            stageDisplay = nil
            setState(.unavailable)
        }
    }

    /// Restores every window, removes the virtual display. Safe to call repeatedly, and from a quit handler.
    public func end() async {
        await restoreAll()
        if let stageDisplay {
            self.stageDisplay = nil
            try? await display.removeDisplay(stageDisplay.id)
        }
        setState(.inactive)
    }

    /// Reads the journal left by a previous run and puts those windows back. Call at launch, before anything else touches windows.
    public func recoverFromCrash() async {
        let stored: StageJournal?
        do { stored = try await journal.load() } catch {
            log.error("stage journal unreadable: \(String(describing: error), privacy: .private)")
            try? await journal.clear()
            return
        }
        guard let stored else { return }
        let alreadyManaged = Set(managed.values.map(\.key))
        if stored.bootID == bootID {
            let displays = await display.displays()
            for entry in stored.entries where !alreadyManaged.contains(entry.window) {
                await put(entry.window, back: entry.frame.rect, display: entry.display, displays: displays)
            }
        }
        // Entries of live windows stay in the journal until they are restored by the normal path.
        journalState.entries = journalState.entries.filter { alreadyManaged.contains($0.window) }
        await persistJournal()
    }

    // MARK: Windows

    /// Starts managing a window: remembers where it was, then sizes (and on the stage, places) it.
    /// Returns the frame the window ended up with.
    @discardableResult
    public func manage(window: WindowID, key: StageWindowKey, sceneSize: LinkSize) async throws -> LinkRect {
        guard sceneSize.isValid, sceneSize.width > 0, sceneSize.height > 0 else { throw ManageError.invalidSize }
        if managed[window] != nil {
            requestSize(window: window, sceneSize: sceneSize)
            await settle()
            return managed[window]?.actual ?? managed[window]?.original ?? LinkRect(x: 0, y: 0, width: 0, height: 0)
        }
        guard let original = await frames.currentFrame(of: key) else { throw ManageError.windowGone }
        let displays = await display.displays()
        let originalDisplay = Self.display(containing: original, in: displays)?.id

        // The promise to restore must be durable before the first change.
        journalState.entries.removeAll { $0.window == key }
        journalState.entries.append(.init(window: key, frame: StageFrame(original), display: originalDisplay))
        do { try await journal.save(journalState) } catch {
            journalState.entries.removeAll { $0.window == key }
            log.error("stage journal save failed: \(String(describing: error), privacy: .private)")
            throw ManageError.journalUnavailable
        }

        let limits = await frames.sizeLimits(of: key)
        managed[window] = ManagedWindow(
            window: window, key: key,
            desired: StageSizeMatching.windowSize(forScene: sceneSize, limits: limits, within: stageDisplay?.frame.size),
            limits: limits, original: original, originalDisplay: originalDisplay, actual: nil
        )
        order.append(window)
        await layout()
        return managed[window]?.actual ?? original
    }

    /// Stops managing one window and puts it back where it was.
    public func release(window: WindowID) async {
        guard let record = managed.removeValue(forKey: window) else { return }
        order.removeAll { $0 == window }
        pendingSizes[window] = nil
        let displays = await display.displays()
        await put(record.key, back: record.original, display: record.originalDisplay, displays: displays)
        journalState.entries.removeAll { $0.window == record.key }
        await persistJournal()
        if stageDisplay != nil { await layout() }
    }

    /// Native full-screen windows cannot be moved by AX: leave full screen first.
    public func exitFullScreen(window: WindowID) async {
        guard let record = managed[window] else { return }
        await frames.exitFullScreen(record.key)
    }

    /// The iPad scene changed size. Requests are debounced (150 ms by default) and applied together.
    public func requestSize(window: WindowID, sceneSize: LinkSize) {
        guard managed[window] != nil, sceneSize.isValid, sceneSize.width > 0, sceneSize.height > 0 else { return }
        pendingSizes[window] = sceneSize
        debounceTask?.cancel()
        let wait = debounce
        let sleep = self.sleep
        debounceTask = Task { [weak self] in
            do { try await sleep(wait) } catch { return }
            await self?.flushPending()
        }
    }

    /// Waits until requested sizes have been applied. For tests and orderly shutdown.
    public func settle() async {
        while let task = debounceTask {
            await task.value
            if debounceTask == task { debounceTask = nil }
        }
    }

    private func flushPending() async {
        let sizes = pendingSizes
        pendingSizes = [:]
        for (window, size) in sizes {
            guard var record = managed[window] else { continue }
            record.desired = StageSizeMatching.windowSize(forScene: size, limits: record.limits, within: stageDisplay?.frame.size)
            managed[window] = record
        }
        if !sizes.isEmpty { await layout() }
    }

    // MARK: Layout

    private func layout() async {
        let token = generation
        if let bounds = stageDisplay?.frame {
            let requests = order.compactMap { managed[$0] }.map {
                TileRequest(id: $0.key, desired: $0.desired, minimum: $0.limits.minimum, maximum: $0.limits.maximum)
            }
            let result = StageLayout.tile(requests, in: bounds, gap: gap)
            for window in order {
                guard let record = managed[window], let target = result.frames[record.key] else { continue }
                await apply(target, to: window, token: token)
            }
        } else {
            for window in order {
                guard let record = managed[window] else { continue }
                let origin = (record.actual ?? record.original).origin
                await apply(LinkRect(origin: origin, size: record.desired), to: window, token: token)
            }
        }
    }

    private func apply(_ target: LinkRect, to window: WindowID, token: Int) async {
        guard token == generation, let record = managed[window] else { return }
        if let current = record.actual, current == target { return }
        let actual = await frames.setFrame(record.key, to: target)
        // The session may have ended while the app was busy; do not resurrect the record.
        guard token == generation, var latest = managed[window] else { return }
        latest.actual = actual
        if let actual {
            // Apps clamp requests; plan with what we got so the next layout does not overlap.
            latest.desired = actual.size
        }
        managed[window] = latest
    }

    // MARK: Restore

    /// Puts back every managed window, then empties the journal. Idempotent.
    public func restoreAll() async {
        generation += 1
        debounceTask?.cancel()
        debounceTask = nil
        pendingSizes = [:]
        let records = order.compactMap { managed[$0] }
        managed = [:]
        order = []
        if !records.isEmpty {
            let displays = await display.displays()
            for record in records {
                await put(record.key, back: record.original, display: record.originalDisplay, displays: displays)
            }
        }
        journalState.entries = []
        do { try await journal.clear() } catch { log.error("stage journal clear failed: \(String(describing: error), privacy: .private)") }
    }

    private func put(_ key: StageWindowKey, back frame: LinkRect, display preferred: StageDisplayID?, displays: [StageDisplay]) async {
        guard await frames.currentFrame(of: key) != nil else { return }
        let target = Self.fit(frame, into: displays, preferred: preferred)
        _ = await frames.setFrame(key, to: target)
    }

    private func persistJournal() async {
        do {
            if journalState.entries.isEmpty { try await journal.clear() } else { try await journal.save(journalState) }
        } catch {
            log.error("stage journal update failed: \(String(describing: error), privacy: .private)")
        }
    }

    // MARK: Geometry helpers

    static func display(containing rect: LinkRect, in displays: [StageDisplay]) -> StageDisplay? {
        let centre = LinkPoint(x: rect.origin.x + rect.size.width / 2, y: rect.origin.y + rect.size.height / 2)
        return displays.first { contains($0.frame, centre) }
    }

    static func contains(_ rect: LinkRect, _ point: LinkPoint) -> Bool {
        point.x >= rect.origin.x && point.x < rect.origin.x + rect.size.width
            && point.y >= rect.origin.y && point.y < rect.origin.y + rect.size.height
    }

    /// Keeps a saved frame if it is still on a display; otherwise moves it onto the preferred display or the first real one.
    static func fit(_ rect: LinkRect, into displays: [StageDisplay], preferred: StageDisplayID?) -> LinkRect {
        if display(containing: rect, in: displays) != nil { return rect }
        guard let target = displays.first(where: { $0.id == preferred }) ?? displays.first(where: { !$0.isVirtual }) ?? displays.first
        else { return rect }
        let width = min(rect.size.width, target.frame.size.width)
        let height = min(rect.size.height, target.frame.size.height)
        let x = min(max(rect.origin.x, target.frame.origin.x), target.frame.origin.x + target.frame.size.width - width)
        let y = min(max(rect.origin.y, target.frame.origin.y), target.frame.origin.y + target.frame.size.height - height)
        return LinkRect(x: x, y: y, width: width, height: height)
    }
}
#endif
