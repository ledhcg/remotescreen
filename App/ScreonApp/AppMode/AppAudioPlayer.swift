import AVFoundation
import Foundation
import LinkProtocol
import LinkTransport
import WindowKit
import os

/// Plays the per-app audio the Mac sends on the link's audio stream (`audio.config` + `audio.packet`).
///
/// Each app (pid) gets its own `AudioPlayout` (jitter buffer, drift correction) and its own `AVAudioSourceNode`; the engine mixes them.
/// Only `pcm16` is played: a stream that announces another codec is ignored and the Mac keeps playing its audio itself.
/// Muting is per app and set by the connection from which of the app's windows are on screen.
final class AppAudioPlayer: @unchecked Sendable {
    /// Most apps played at once (the helper caps it at 8 as well).
    static let maxStreams = 8
    /// Largest render the source node converts in one go; larger requests are split.
    static let maxRenderFrames = 4096

    private final class Stream {
        let pid: Int32
        let playout: AudioPlayout
        let node: AVAudioSourceNode
        var lastSequence: UInt32?
        init(pid: Int32, playout: AudioPlayout, node: AVAudioSourceNode) { self.pid = pid; self.playout = playout; self.node = node }
    }

    private struct State {
        var streams: [Int32: Stream] = [:]
        var mutedPIDs: Set<Int32> = []
        var reader: Task<Void, Never>?
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    private let engine = AVAudioEngine()
    private let log = Logger(subsystem: "app.screon", category: "audio")
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.restartEngine()
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            if raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .ended { self?.restartEngine() }
        })
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: Feeding

    /// Starts reading the audio stream. Replaces an earlier reader (the stream was reopened).
    func attach(_ inbox: LinkInbox<LinkMessage>) {
        let reader = Task.detached(priority: .userInitiated) { [weak self] in
            for await message in inbox {
                guard let self, !Task.isCancelled else { return }
                self.handle(message)
            }
        }
        let old = state.withLockUnchecked { state -> Task<Void, Never>? in
            let old = state.reader
            state.reader = reader
            return old
        }
        old?.cancel()
    }

    func shutdown() {
        let (reader, streams) = state.withLockUnchecked { state -> (Task<Void, Never>?, [Stream]) in
            defer { state.reader = nil; state.streams = [:] }
            return (state.reader, Array(state.streams.values))
        }
        reader?.cancel()
        for stream in streams { engine.detach(stream.node) }
        engine.stop()
    }

    /// Mutes or unmutes one app. Remembered for an app whose stream has not started yet.
    func setMuted(_ muted: Bool, pid: Int32) {
        let playout = state.withLockUnchecked { state -> AudioPlayout? in
            if muted { state.mutedPIDs.insert(pid) } else { state.mutedPIDs.remove(pid) }
            return state.streams[pid]?.playout
        }
        playout?.setMuted(muted)
    }

    /// Apps that currently have a stream, for the connection to decide the mute state of.
    var pids: Set<Int32> { state.withLockUnchecked { Set($0.streams.keys) } }

    /// What the person could hear go wrong, summed over apps.
    var stats: AudioPlayoutStats {
        let all = state.withLockUnchecked { $0.streams.values.map(\.playout) }
        var total = AudioPlayoutStats()
        for playout in all {
            let s = playout.stats
            total.underruns += s.underruns; total.overflows += s.overflows
            total.droppedFrames += s.droppedFrames; total.insertedFrames += s.insertedFrames; total.playedFrames += s.playedFrames
        }
        return total
    }

    // MARK: Messages

    private func handle(_ message: LinkMessage) {
        switch message {
        case .audioConfig(let config): configure(config)
        case .audioPacket(let packet): play(packet)
        default: break
        }
    }

    private func configure(_ config: LinkAudioConfig) {
        guard config.codec == .pcm16, (1...2).contains(config.channels), (8_000...96_000).contains(config.sampleRate) else {
            log.notice("audio stream ignored: unsupported format")
            return
        }
        let existing = state.withLockUnchecked { $0.streams[config.pid] }
        if let existing, existing.playout.sampleRate == Int(config.sampleRate), existing.playout.channels == Int(config.channels) {
            existing.playout.reset()
            state.withLockUnchecked { $0.streams[config.pid]?.lastSequence = nil }
            return
        }
        guard state.withLockUnchecked({ $0.streams.count < Self.maxStreams || $0.streams[config.pid] != nil }) else { return }
        guard activateSession() else { return }
        if let existing { engine.detach(existing.node) }

        let playout = AudioPlayout(sampleRate: Int(config.sampleRate), channels: Int(config.channels))
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(config.sampleRate), channels: AVAudioChannelCount(config.channels))
        else { return }
        let node = Self.makeNode(playout: playout, format: format)
        let stream = Stream(pid: config.pid, playout: playout, node: node)
        let muted = state.withLockUnchecked { state -> Bool in
            state.streams[config.pid] = stream
            return state.mutedPIDs.contains(config.pid)
        }
        playout.setMuted(muted)
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        startEngineIfNeeded()
    }

    private func play(_ packet: LinkAudioPacket) {
        guard let stream = state.withLockUnchecked({ $0.streams[packet.pid] }) else { return }
        // Wrapping comparison: drop a packet that is the same as, or older than, the last one.
        if let last = stream.lastSequence, Int32(bitPattern: packet.sequence &- last) <= 0 { return }
        stream.lastSequence = packet.sequence
        stream.playout.push(packet.data, ptsMicros: packet.ptsMicros, arrival: ProcessInfo.processInfo.systemUptime)
    }

    // MARK: Engine

    private static func makeNode(playout: AudioPlayout, format: AVAudioFormat) -> AVAudioSourceNode {
        let channels = playout.channels
        let scratch = UnsafeMutablePointer<Int16>.allocate(capacity: maxRenderFrames * channels)
        scratch.initialize(repeating: 0, count: maxRenderFrames * channels)
        let owner = ScratchOwner(scratch)  // freed with the node's render block
        return AVAudioSourceNode(format: format) { [owner] _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            var done = 0
            let total = Int(frameCount)
            while done < total {
                let n = min(total - done, maxRenderFrames)
                playout.render(into: owner.pointer, frames: n)
                for (c, buffer) in buffers.enumerated() where c < channels {
                    guard let out = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    for f in 0..<n { out[done + f] = Float(owner.pointer[f * channels + c]) / 32768 }
                }
                done += n
            }
            return noErr
        }
    }

    private final class ScratchOwner: @unchecked Sendable {
        let pointer: UnsafeMutablePointer<Int16>
        init(_ pointer: UnsafeMutablePointer<Int16>) { self.pointer = pointer }
        deinit { pointer.deallocate() }
    }

    private func activateSession() -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            return true
        } catch {
            log.notice("audio session unavailable")
            return false
        }
    }

    private func startEngineIfNeeded() {
        guard !engine.isRunning else { return }
        engine.prepare()
        do { try engine.start() } catch { log.notice("audio engine did not start") }
    }

    private func restartEngine() {
        guard !state.withLockUnchecked({ $0.streams.isEmpty }) else { return }
        _ = activateSession()
        startEngineIfNeeded()
    }
}
