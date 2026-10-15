import Foundation

/// An iPad the Mac has paired with.
public struct PairedDevice: Sendable, Equatable, Codable {
    /// SHA-256 of the iPad certificate's SPKI.
    public var spkiHash: Data
    public var name: String
    public var pairedAt: Date
    public init(spkiHash: Data, name: String, pairedAt: Date) {
        self.spkiHash = spkiHash; self.name = name; self.pairedAt = pairedAt
    }
}

/// Helper side: the set of paired iPads. Lookups are on the connection path, so implementations must be quick.
/// A persistent implementation (a JSON file in Application Support) belongs to the helper app; the hash and name are not
/// secret, the private keys live in the Keychain.
public protocol PairedDeviceStore: Sendable {
    func device(spkiHash: Data) -> PairedDevice?
    func all() -> [PairedDevice]
    func add(_ device: PairedDevice) throws
    /// Removes the pairing. Returns whether there was one.
    @discardableResult func revoke(spkiHash: Data) throws -> Bool
}

public final class InMemoryPairedDeviceStore: PairedDeviceStore, @unchecked Sendable {
    public static let maxDevices = 64
    private let lock = NSLock()
    private var devices: [Data: PairedDevice] = [:]

    public init() {}

    public func device(spkiHash: Data) -> PairedDevice? { lock.withLock { devices[spkiHash] } }
    public func all() -> [PairedDevice] { lock.withLock { devices.values.sorted { $0.pairedAt < $1.pairedAt } } }

    public func add(_ device: PairedDevice) throws {
        try lock.withLock {
            guard devices[device.spkiHash] != nil || devices.count < Self.maxDevices else { throw PairedStoreError.full }
            devices[device.spkiHash] = device
        }
    }

    @discardableResult public func revoke(spkiHash: Data) throws -> Bool { lock.withLock { devices.removeValue(forKey: spkiHash) != nil } }
}

public enum PairedStoreError: Error, Equatable { case full }

/// A Mac the iPad has paired with, kept next to the saved computer.
public struct PairedMac: Sendable, Equatable, Codable {
    /// Identifier of the saved computer this pairing belongs to.
    public var computerID: String
    /// The pinned SPKI hash of the Mac's certificate.
    public var spkiHash: Data
    public var name: String
    public var pairedAt: Date
    public init(computerID: String, spkiHash: Data, name: String, pairedAt: Date) {
        self.computerID = computerID; self.spkiHash = spkiHash; self.name = name; self.pairedAt = pairedAt
    }
}

/// iPad side: one pinned Mac per saved computer.
public protocol PairedMacStore: Sendable {
    func mac(forComputer id: String) -> PairedMac?
    func save(_ mac: PairedMac) throws
    func remove(computerID: String)
}

public final class InMemoryPairedMacStore: PairedMacStore, @unchecked Sendable {
    private let lock = NSLock()
    private var macs: [String: PairedMac] = [:]
    public init() {}
    public func mac(forComputer id: String) -> PairedMac? { lock.withLock { macs[id] } }
    public func save(_ mac: PairedMac) throws { lock.withLock { macs[mac.computerID] = mac } }
    public func remove(computerID: String) { _ = lock.withLock { macs.removeValue(forKey: computerID) } }
}

/// What the iPad keeps to resume a session after a reconnect (the app persists this next to the saved computer, in memory
/// is enough: a token lives 10 minutes).
public struct LinkResumeCredentials: Sendable, Equatable {
    public var token: Data
    public var lastStateVersion: UInt64
    public init(token: Data, lastStateVersion: UInt64) { self.token = token; self.lastStateVersion = lastStateVersion }
}
