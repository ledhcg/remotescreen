import Foundation

/// Why a pairing attempt is not admitted at all (before any proof is looked at).
public enum PairingAdmissionError: Error, Equatable {
    /// No pairing window is open on the Mac.
    case windowClosed
    /// Too many SAS sessions from this address, or in total, recently.
    case tooManySASAttempts
}

/// The pairing methods a Mac user can open a window for. QR has no window of its own: showing a QR code issues an offer
/// (`LinkServer.makePairingQRPayload`) and the offer's nonce is the admission, so it can admit nothing but a proof for that
/// offer. Only SAS needs an explicit window.
public enum PairingWindowMethod: Sendable, Equatable { case sas }

/// Helper-side gate for first-contact pairing, shared by every connection of one `LinkServer`.
///
/// - The **SAS window** is opened by the person at the Mac ("Pair without camera") and is the only time an unknown device
///   may start SAS pairing. Showing a QR code does not open it. It lasts `defaultWindow` unless told otherwise and closes
///   after one successful pairing or one denial by the Mac user.
/// - SAS sessions are limited: a six-digit code has only 10^6 values, so a man in the middle who relays one session gets one
///   guess per session. At most `maxSASAttemptsPerSource` per remote address and `maxSASAttemptsGlobal` in total per
///   `sasPeriod`. The counters live here and not in the connection, so reconnecting does not reset them.
public final class PairingAdmission: @unchecked Sendable {
    public static let defaultWindow: TimeInterval = 120
    public static let maxSASAttemptsPerSource = 3
    public static let maxSASAttemptsGlobal = 6
    public static let sasPeriod: TimeInterval = 600
    /// Remote addresses remembered for rate limiting; the oldest are forgotten beyond this.
    public static let maxTrackedSources = 256

    private let lock = NSLock()
    private let clock: LinkClock
    private var windowEnd: Date?
    private var sasGlobal: [Date] = []
    private var sasBySource: [String: [Date]] = [:]

    public init(clock: @escaping LinkClock = { Date() }) { self.clock = clock }

    /// Opens (or restarts) the window for `duration` seconds.
    public func open(duration: TimeInterval = PairingAdmission.defaultWindow) {
        let end = clock().addingTimeInterval(max(0, min(duration, 3600)))
        lock.withLock { windowEnd = end }
    }

    public func close() { lock.withLock { windowEnd = nil } }

    public var isOpen: Bool {
        lock.withLock {
            guard let end = windowEnd, end > clock() else { windowEnd = nil; return false }
            return true
        }
    }

    /// Atomically uses the window for a successful pairing: returns whether it was open, and closes it either way.
    func consumeWindow() -> Bool {
        lock.withLock {
            defer { windowEnd = nil }
            guard let end = windowEnd else { return false }
            return end > clock()
        }
    }

    /// Admits one SAS session from `source`, or throws. The attempt is counted when admitted.
    func beginSAS(source: String) throws {
        try lock.withLock {
            let now = clock()
            guard let end = windowEnd, end > now else { throw PairingAdmissionError.windowClosed }
            sasGlobal.removeAll { now.timeIntervalSince($0) >= Self.sasPeriod }
            var mine = (sasBySource[source] ?? []).filter { now.timeIntervalSince($0) < Self.sasPeriod }
            guard mine.count < Self.maxSASAttemptsPerSource, sasGlobal.count < Self.maxSASAttemptsGlobal else {
                sasBySource[source] = mine
                throw PairingAdmissionError.tooManySASAttempts
            }
            mine.append(now)
            sasGlobal.append(now)
            sasBySource[source] = mine
            if sasBySource.count > Self.maxTrackedSources {
                sasBySource = sasBySource.filter { $0.value.contains { now.timeIntervalSince($0) < Self.sasPeriod } }
                while sasBySource.count > Self.maxTrackedSources,
                      let oldest = sasBySource.min(by: { ($0.value.last ?? .distantPast) < ($1.value.last ?? .distantPast) })?.key {
                    sasBySource.removeValue(forKey: oldest)
                }
            }
        }
    }
}
