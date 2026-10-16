// Fake Mac helper for simulator end-to-end tests. Binds loopback (127.0.0.1) only. See Tools/mock-link-helper/README.md.
import Foundation
import LinkTransport

let usage = """
    Usage: mock-link-helper [options]
      --port <n>              listen port for QUIC (UDP) and TCP+TLS (default 7361; 0 picks a free port)
      --loopback-only         accepted for clarity; loopback is always on
      --bind 127.0.0.1        only loopback values are accepted
      --log <file.jsonl>      event log (pairing, subscriptions, input, commands, clipboard, files)
      --scenario <name>       basic (3 apps, 4 windows incl. a transient menu) | churn (windows come and go) | locked (macLocked status)
      --pairing <auto|qr>     auto: approve any first pairing (TEST ONLY); qr: approve only devices that prove the QR secret
      --qr-out <file>         write the pairing QR payload string to this file (also printed on stdout)
      --identity-dir <dir>    keep the mock identity and paired devices here (file-based, never the login keychain)
      --inbox-dir <dir>       where received files go (default: a temporary directory removed on exit)
      --no-quic               TCP+TLS only
      --self-test             run an in-process client against the helper and exit 0/1
    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("mock-link-helper: \(message)\n\(usage)\n".utf8))
    exit(2)
}

func parseOptions(_ arguments: [String]) -> Options {
    var options = Options()
    var iterator = arguments.makeIterator()
    func value(_ flag: String) -> String {
        guard let v = iterator.next() else { fail("\(flag) needs a value") }
        return v
    }
    while let argument = iterator.next() {
        switch argument {
        case "--port":
            guard let port = UInt16(value(argument)) else { fail("invalid port") }
            options.port = port
        case "--loopback-only": break
        case "--bind":
            let host = value(argument)
            guard ["127.0.0.1", "localhost", "::1"].contains(host) else { fail("refusing to bind \(host): only loopback is allowed") }
        case "--log": options.logPath = value(argument)
        case "--scenario":
            guard let s = Scenario(rawValue: value(argument)) else { fail("unknown scenario") }
            options.scenario = s
        case "--pairing":
            guard let p = PairingMode(rawValue: value(argument)) else { fail("unknown pairing mode") }
            options.pairing = p
        case "--qr-out": options.qrOut = value(argument)
        case "--identity-dir": options.identityDir = value(argument)
        case "--inbox-dir": options.inboxDir = value(argument)
        case "--no-quic": options.enableQUIC = false
        case "--self-test": options.selfTest = true
        case "--help", "-h":
            print(usage)
            exit(0)
        default: fail("unknown option \(argument)")
        }
    }
    return options
}

/// Resumes once on SIGINT or SIGTERM.
final class SignalWaiter: @unchecked Sendable {
    private var sources: [DispatchSourceSignal] = []
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var fired = false

    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if fired { lock.unlock(); c.resume(); return }
            continuation = c
            lock.unlock()
            for sig in [SIGINT, SIGTERM] {
                signal(sig, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
                source.setEventHandler { [self] in fire() }
                source.resume()
                sources.append(source)
            }
        }
    }

    private func fire() {
        lock.lock()
        fired = true
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume()
    }
}

func writeQR(_ qr: String, options: Options) {
    if let path = options.qrOut {
        try? Data(qr.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

func runHelper(options: Options) async -> Int32 {
    let log: JSONLLog
    do { log = try JSONLLog(path: options.logPath) } catch {
        FileHandle.standardError.write(Data("mock-link-helper: \(error)\n".utf8))
        return 1
    }
    let helper = MockHelper(options: options, log: log)
    let endpoint: LinkServerEndpoint
    do { endpoint = try await helper.start() } catch {
        FileHandle.standardError.write(Data("mock-link-helper: cannot start: \(error)\n".utf8))
        return 1
    }
    if options.pairing == .auto {
        FileHandle.standardError.write(
            Data(
                """
                ################################################################
                #  WARNING: --pairing auto approves ANY device that pairs.     #
                #  For automated tests only. Listening on 127.0.0.1 only.     #
                ################################################################

                """.utf8))
    }
    print("mock-link-helper listening on 127.0.0.1:\(endpoint.port) (scenario \(options.scenario.rawValue), pairing \(options.pairing.rawValue))")
    do {
        let qr = try await helper.pairingQRString()
        print("QR_PAYLOAD=\(qr)")
        writeQR(qr, options: options)
    } catch {
        FileHandle.standardError.write(Data("mock-link-helper: cannot issue pairing QR: \(error)\n".utf8))
    }
    fflush(stdout)

    // A pairing secret lives five minutes; keep a fresh one in the --qr-out file for long-running runs.
    let refresher = Task {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(120))
            if Task.isCancelled { return }
            if let qr = try? await helper.pairingQRString() { writeQR(qr, options: options) }
        }
    }
    await SignalWaiter().wait()
    refresher.cancel()
    print("mock-link-helper: shutting down")
    await helper.stop()
    log.close()
    return 0
}

let options = parseOptions(Array(CommandLine.arguments.dropFirst()))
if options.selfTest {
    exit(await SelfTest.run())
} else {
    exit(await runHelper(options: options))
}
