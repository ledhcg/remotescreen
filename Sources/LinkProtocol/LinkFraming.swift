import Foundation

/// Message → bytes: `u16 type | u32 length | payload`, little-endian. The control stream and every per-window video
/// stream use this same framing.
public enum LinkFrameEncoder {
    public static func encode(_ message: LinkMessage) throws -> Data {
        let payload = try message.encodePayload()
        let type = message.type
        guard let cap = LinkLimits.maxPayloadBytes(forType: type.rawValue), payload.count <= cap else {
            throw LinkError.limitExceeded("\(type) payload is \(payload.count) bytes")
        }
        var writer = LinkWriter(capacity: LinkLimits.frameHeaderBytes + payload.count)
        writer.u16(type.rawValue)
        writer.u32(UInt32(payload.count))
        var data = Data(writer.bytes)
        data.append(contentsOf: payload)
        return data
    }
}

/// Incremental bytes → messages. Feed chunks of any size (even one byte at a time); complete messages come out in order.
///
/// - The declared length is checked against the per-type cap **before** anything is buffered, so a hostile length
///   (for example 4 GiB) throws immediately and costs no memory.
/// - Unknown types at or above `0x8000` (ignorable) are skipped by length without being buffered or yielded.
/// - Unknown types below `0x8000` throw `LinkError.unsupportedMessage`.
/// - After the first error the decoder is poisoned and rethrows it; the connection must be closed.
public struct LinkFrameDecoder: Sendable {
    private var buffer: [UInt8] = []
    private var head = 0
    private var skipRemaining = 0
    private var failure: LinkError?

    public init() {}

    /// Bytes received but not yet turned into a message (headers and partial payloads). Always bounded by the largest cap.
    public var bufferedByteCount: Int { buffer.count - head }

    public mutating func feed(_ data: Data) throws -> [LinkMessage] {
        try feed(bytes: [UInt8](data))
    }

    public mutating func feed(bytes: [UInt8]) throws -> [LinkMessage] {
        if let failure { throw failure }
        do {
            return try process(bytes)
        } catch let error as LinkError {
            failure = error
            buffer = []; head = 0
            throw error
        }
    }

    private mutating func process(_ incoming: [UInt8]) throws -> [LinkMessage] {
        var messages: [LinkMessage] = []
        var input = incoming[...]

        // Finish skipping an ignorable message first.
        if skipRemaining > 0 {
            let n = min(skipRemaining, input.count)
            skipRemaining -= n
            input = input.dropFirst(n)
        }

        buffer.append(contentsOf: input)
        while true {
            if skipRemaining > 0 {
                let n = min(skipRemaining, buffer.count - head)
                skipRemaining -= n
                head += n
                if skipRemaining > 0 { break }
            }
            guard buffer.count - head >= LinkLimits.frameHeaderBytes else { break }
            let type = UInt16(buffer[head]) | UInt16(buffer[head + 1]) << 8
            var length = 0
            for i in 0..<4 { length |= Int(buffer[head + 2 + i]) << (8 * i) }

            guard let messageType = LinkMessageType(rawValue: type), let cap = LinkLimits.maxPayloadBytes(forType: type) else {
                guard type >= LinkLimits.ignorableTypeThreshold else { throw LinkError.unsupportedMessage(type) }
                guard length <= LinkLimits.maxIgnorablePayloadBytes else {
                    throw LinkError.limitExceeded("ignorable message 0x\(String(type, radix: 16)) declares \(length) bytes")
                }
                head += LinkLimits.frameHeaderBytes
                skipRemaining = length
                continue
            }
            guard length <= cap else {
                throw LinkError.limitExceeded("\(messageType) declares \(length) bytes, limit \(cap)")
            }
            let total = LinkLimits.frameHeaderBytes + length
            guard buffer.count - head >= total else { break }
            let payload = Array(buffer[(head + LinkLimits.frameHeaderBytes)..<(head + total)])
            head += total
            messages.append(try LinkMessage.decode(type: messageType, payload: payload))
        }

        if head == buffer.count {
            buffer.removeAll(keepingCapacity: true); head = 0
        } else if head > 64 * 1024 {
            buffer.removeFirst(head); head = 0
        }
        return messages
    }
}
