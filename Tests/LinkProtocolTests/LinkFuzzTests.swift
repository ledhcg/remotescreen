import Foundation
import Testing
@testable import LinkProtocol

/// The decoder parses data from an untrusted peer. This feeds it valid messages that have been corrupted and pure noise
/// (biased toward valid headers), in random chunk sizes, and demands one thing: it never crashes. The result is either
/// decoded messages or a `LinkError`, and the decoder's buffer stays below the largest cap.
@Suite("Link: decoder fuzz")
struct LinkFuzzTests {
    private static let interestingBytes: [UInt8] = [0, 1, 2, 3, 4, 5, 7, 8, 15, 16, 31, 32, 63, 64, 127, 128, 129, 254, 255]
    private static let validFrames: [[UInt8]] = Samples.all.compactMap { try? LinkFrameEncoder.encode($0) }.map { [UInt8]($0) }
    /// Skip the multi-megabyte samples so a thousand mutations stay fast.
    private static let smallFrames = validFrames.filter { $0.count < 64 * 1024 }

    private static func mutate(_ frame: [UInt8], _ random: inout SplitMix64) -> [UInt8] {
        var bytes = frame
        for _ in 0..<Int.random(in: 1...4, using: &random) {
            switch Int.random(in: 0..<7, using: &random) {
            case 0 where !bytes.isEmpty: bytes[Int.random(in: 0..<bytes.count, using: &random)] ^= UInt8(1 << Int.random(in: 0..<8, using: &random))
            case 1 where !bytes.isEmpty: bytes[Int.random(in: 0..<bytes.count, using: &random)] = interestingBytes.randomElement(using: &random)!
            case 2 where !bytes.isEmpty: bytes.removeLast(Int.random(in: 1...bytes.count, using: &random))
            case 3: bytes.insert(UInt8.random(in: 0...255, using: &random), at: Int.random(in: 0...bytes.count, using: &random))
            case 4 where bytes.count >= 6: // rewrite the declared length with an interesting value
                let lengths: [UInt32] = [0, 1, UInt32(bytes.count), UInt32(bytes.count - 6) &+ 1, 0xFFFF, 1 << 20, (1 << 20) + 1, 0x7FFF_FFFF, .max]
                let length = lengths.randomElement(using: &random)!
                for i in 0..<4 { bytes[2 + i] = UInt8(truncatingIfNeeded: length >> (8 * UInt32(i))) }
            case 5 where bytes.count >= 2: // rewrite the type
                let types: [UInt16] = [0, 0x7FFF, 0x8000, 0xFFFF] + LinkMessageType.allCases.map(\.rawValue)
                let type = types.randomElement(using: &random)!
                bytes[0] = UInt8(truncatingIfNeeded: type); bytes[1] = UInt8(truncatingIfNeeded: type >> 8)
            default: bytes += (0..<Int.random(in: 1...16, using: &random)).map { _ in UInt8.random(in: 0...255, using: &random) }
            }
        }
        return bytes
    }

    private static func feedInChunks(_ bytes: [UInt8], _ random: inout SplitMix64) -> Bool {
        var decoder = LinkFrameDecoder()
        var index = 0
        while index < bytes.count {
            let end = min(bytes.count, index + Int.random(in: 1...64, using: &random))
            do {
                _ = try decoder.feed(bytes: Array(bytes[index..<end]))
            } catch is LinkError {
                return true
            } catch {
                return false // anything but LinkError is a bug
            }
            if decoder.bufferedByteCount > LinkLimits.maxVideoAccessUnitBytes + 4096 { return false }
            index = end
        }
        return true
    }

    @Test(arguments: [1, 2, 3, 4])
    func corruptedValidFramesNeverCrash(seed: UInt64) {
        var random = SplitMix64(state: seed)
        for iteration in 0..<1500 {
            var bytes: [UInt8] = []
            for _ in 0..<Int.random(in: 1...3, using: &random) {
                bytes += Self.mutate(Self.smallFrames.randomElement(using: &random)!, &random)
            }
            #expect(Self.feedInChunks(bytes, &random), "seed \(seed) iteration \(iteration)")
        }
    }

    @Test(arguments: [1, 2, 3, 4])
    func randomPayloadsBehindValidHeadersNeverCrash(seed: UInt64) {
        var random = SplitMix64(state: seed)
        let types = LinkMessageType.allCases
        for iteration in 0..<1500 {
            let type = types.randomElement(using: &random)!
            let payload: [UInt8] = (0..<Int.random(in: 0...300, using: &random)).map { _ in
                Bool.random(using: &random) ? Self.interestingBytes.randomElement(using: &random)! : UInt8.random(in: 0...255, using: &random)
            }
            // Either decodes or throws a LinkError; a returned message must also re-encode (decoder never yields what the encoder refuses).
            do {
                var decoder = LinkFrameDecoder()
                let messages = try decoder.feed(bytes: rawFrame(type, payload: payload))
                for message in messages { _ = try LinkFrameEncoder.encode(message) }
            } catch is LinkError {
                continue
            } catch {
                Issue.record("non-LinkError \(error), seed \(seed) iteration \(iteration)")
            }
        }
    }

    @Test(arguments: [1, 2, 3, 4])
    func pureNoiseNeverCrashes(seed: UInt64) {
        var random = SplitMix64(state: seed)
        for iteration in 0..<1500 {
            let bytes = (0..<Int.random(in: 0...400, using: &random)).map { _ in
                Bool.random(using: &random) ? Self.interestingBytes.randomElement(using: &random)! : UInt8.random(in: 0...255, using: &random)
            }
            #expect(Self.feedInChunks(bytes, &random), "seed \(seed) iteration \(iteration)")
        }
    }

    @Test(arguments: [1, 2, 3, 4])
    func chunkingNeverChangesTheResult(seed: UInt64) throws {
        var random = SplitMix64(state: seed)
        for _ in 0..<1000 {
            var bytes: [UInt8] = []
            for _ in 0..<Int.random(in: 1...4, using: &random) {
                let frame = Self.smallFrames.randomElement(using: &random)!
                bytes += Bool.random(using: &random) ? Self.mutate(frame, &random) : frame
            }
            func run(_ chunkSize: (inout SplitMix64) -> Int) -> ([LinkMessage], LinkError?) {
                var decoder = LinkFrameDecoder()
                var out: [LinkMessage] = []
                var local = SplitMix64(state: seed)
                var index = 0
                while index < bytes.count {
                    let end = min(bytes.count, index + chunkSize(&local))
                    do { out += try decoder.feed(bytes: Array(bytes[index..<end])) } catch { return (out, error as? LinkError) }
                    index = end
                }
                return (out, nil)
            }
            let whole = run { _ in .max / 2 }
            let single = run { _ in 1 }
            // A failing feed drops messages decoded earlier in the same chunk, so compare only fully successful runs and the error kind.
            if whole.1 == nil { #expect(single.1 == nil && single.0 == whole.0) } else { #expect(single.1 != nil) }
        }
    }
}
