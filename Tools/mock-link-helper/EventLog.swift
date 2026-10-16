import Foundation

/// JSON Lines event log, one object per line, flushed on every write so a verifier can read it while the helper runs.
/// Only synthetic content is ever logged (the mock has no real data).
final class JSONLLog: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: FileHandle?
    private var counts: [String: Int] = [:]
    private let started = DispatchTime.now()

    init(path: String?) throws {
        guard let path else { return }
        guard FileManager.default.createFile(atPath: path, contents: nil) else {
            throw MockError.message("cannot create log file \(path)")
        }
        handle = FileHandle(forWritingAtPath: path)
    }

    func write(_ type: String, _ fields: [String: Any] = [:]) {
        var object = fields
        object["type"] = type
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e6
        object["t_ms"] = Int(elapsed)
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        lock.withLock {
            counts[type, default: 0] += 1
            try? handle?.write(contentsOf: data)
        }
    }

    func count(_ type: String) -> Int { lock.withLock { counts[type, default: 0] } }

    func close() {
        lock.withLock {
            try? handle?.close()
            handle = nil
        }
    }
}

enum MockError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self { case .message(let m): m }
    }
}
