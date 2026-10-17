import Foundation
import Network
import Observation

/// A TCP port on a host that tells whether a computer is reachable: Screen Sharing (5900) on the address the computer is saved with.
public struct ProbeTarget: Hashable, Sendable {
    public var host: String
    public var port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }
}

/// Whether a host answers on a TCP port.
public enum HostReachability {
    /// Opens a TCP connection and closes it at once. `true` when the connection reaches the ready state within `timeout`.
    /// A refused connection, no route and a timeout are all `false`: for the list, "does not answer" is "not available".
    public static func isReachable(_ target: ProbeTarget, timeout: Duration = .seconds(2)) async -> Bool {
        guard let port = NWEndpoint.Port(rawValue: target.port), !target.host.isEmpty else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(target.host), port: port, using: .tcp)
        let outcome = Outcome()
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        let answered = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                outcome.install(continuation)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: outcome.finish(true)
                    case .failed, .cancelled: outcome.finish(false)
                    case .waiting(let error):
                        // No route or refused: `waiting` would otherwise sit until the timeout.
                        if case .posix(let code) = error, code == .ECONNREFUSED || code == .ENETUNREACH || code == .EHOSTUNREACH {
                            outcome.finish(false)
                        }
                    default: break
                    }
                }
                connection.start(queue: .global(qos: .utility))
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) { outcome.finish(false) }
            }
        } onCancel: {
            outcome.finish(false)
        }
        connection.cancel()
        return answered
    }

    /// Resumes the continuation once, from whichever of the state handler, the timeout or a cancellation comes first.
    private final class Outcome: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?
        private var early: Bool?

        func install(_ continuation: CheckedContinuation<Bool, Never>) {
            lock.lock()
            if let early {
                lock.unlock()
                continuation.resume(returning: early)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }

        func finish(_ value: Bool) {
            lock.lock()
            if let continuation {
                self.continuation = nil
                early = value
                lock.unlock()
                continuation.resume(returning: value)
            } else {
                if early == nil { early = value }
                lock.unlock()
            }
        }
    }
}

/// Keeps a set of probe targets checked while the computer list is on screen, and says which of them answer.
@MainActor
@Observable
public final class ReachabilityMonitor {
    /// Targets that answered in the last pass.
    public private(set) var reachable: Set<ProbeTarget> = []
    /// Targets a pass has already tried at least once: before that, "not reachable" only means "not known yet".
    public private(set) var checked: Set<ProbeTarget> = []

    @ObservationIgnored private var targets: Set<ProbeTarget> = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let interval: Duration
    @ObservationIgnored private let timeout: Duration
    @ObservationIgnored private let maxConcurrent: Int
    @ObservationIgnored private let probe: @Sendable (ProbeTarget, Duration) async -> Bool
    /// Targets this returns `false` for are not probed and count as unreachable (for example a Tailscale address while Tailscale is off).
    @ObservationIgnored public var isProbeAllowed: @MainActor (ProbeTarget) -> Bool = { _ in true }

    public init(
        interval: Duration = .seconds(15), timeout: Duration = .seconds(2), maxConcurrent: Int = 8,
        probe: @escaping @Sendable (ProbeTarget, Duration) async -> Bool = { await HostReachability.isReachable($0, timeout: $1) }
    ) {
        self.interval = interval
        self.timeout = timeout
        self.maxConcurrent = max(1, maxConcurrent)
        self.probe = probe
    }

    /// The targets to keep checking. A changed set is probed again at once.
    public func setTargets(_ new: Set<ProbeTarget>) {
        guard new != targets else { return }
        targets = new
        reachable.formIntersection(new)
        checked.formIntersection(new)
        if task != nil { restart() }
    }

    public func start() {
        guard task == nil else { return }
        restart()
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    private func restart() {
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(for: self.interval)
            }
        }
    }

    /// One pass over every target, at most `maxConcurrent` at a time. A pass that was cancelled changes nothing.
    public func refresh() async {
        let wanted = targets
        let allowed = wanted.filter { isProbeAllowed($0) }
        let probe = self.probe, timeout = self.timeout
        var answered = Set<ProbeTarget>()
        var queue = Array(allowed)
        await withTaskGroup(of: (ProbeTarget, Bool).self) { group in
            var running = 0
            while !queue.isEmpty || running > 0 {
                while running < maxConcurrent, let next = queue.popLast() {
                    group.addTask { (next, await probe(next, timeout)) }
                    running += 1
                }
                if let (target, ok) = await group.next() {
                    running -= 1
                    if ok { answered.insert(target) }
                }
            }
        }
        guard !Task.isCancelled, wanted == targets else { return }
        reachable = answered
        checked.formUnion(wanted)
    }
}
