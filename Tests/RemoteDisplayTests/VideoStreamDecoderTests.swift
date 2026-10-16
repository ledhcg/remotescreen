import CoreVideo
import Foundation
import Metal
import Testing
@testable import RemoteDisplay

private let hevcAvailable = VideoTestEncoder.isAvailable(.hevc)
private let h264Available = VideoTestEncoder.isAvailable(.h264)

private func closeToBar(_ pixel: (y: Int, cb: Int, cr: Int), _ bar: Int, tolerance: Int = 14) -> Bool {
    let expected = VideoTestEncoder.bars[bar]
    return abs(pixel.y - Int(expected.y)) <= tolerance && abs(pixel.cb - Int(expected.cb)) <= tolerance && abs(pixel.cr - Int(expected.cr)) <= tolerance
}

private func expectBars(_ frame: DecodedVideoFrame, width: Int, sourceLocation: SourceLocation = #_sourceLocation) {
    let barWidth = width / VideoTestEncoder.bars.count
    for bar in 0..<VideoTestEncoder.bars.count {
        let pixel = ycbcr(frame.pixelBuffer, x: bar * barWidth + barWidth / 2, y: 20)
        #expect(closeToBar(pixel, bar), "bar \(bar) decoded as \(pixel)", sourceLocation: sourceLocation)
    }
}

/// Real encode -> decode round trips with VideoToolbox. They skip themselves on machines without the codec.
@Suite("Video: stream decoder")
struct VideoStreamDecoderTests {
    @Test(.enabled(if: hevcAvailable)) func decodesAnHEVCStreamToTheRightSizeAndColours() throws {
        let stream = try #require(VideoTestEncoder.encode(codec: .hevc, width: 256, height: 128, frameCount: 3))
        let decoder = VideoStreamDecoder()
        try decoder.configure(stream.config)
        #expect(decoder.streamSize.width == 256 && decoder.streamSize.height == 128)
        #expect(decoder.needsKeyframe)
        for unit in stream.units {
            #expect(decoder.decode(unit) == .decoded)
            let frame = try #require(decoder.takeLatestFrame())
            #expect(frame.width == 256 && frame.height == 128)
            #expect(CVPixelBufferGetPixelFormatType(frame.pixelBuffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
            #expect(frame.ptsMicros == unit.ptsMicros)
            expectBars(frame, width: 256)
        }
        #expect(!decoder.needsKeyframe)
        let stats = decoder.stats
        #expect(stats.framesDecoded == 3 && stats.framesDropped == 0)
        #expect(stats.decodeP50Ms > 0 && stats.decodeP95Ms >= stats.decodeP50Ms)
    }

    @Test(.enabled(if: h264Available)) func decodesAnH264Stream() throws {
        let stream = try #require(VideoTestEncoder.encode(codec: .h264, width: 256, height: 128, frameCount: 2))
        let decoder = VideoStreamDecoder()
        try decoder.configure(stream.config)
        for unit in stream.units { #expect(decoder.decode(unit) == .decoded) }
        let frame = try #require(decoder.takeLatestFrame())
        #expect(frame.width == 256 && frame.height == 128)
        expectBars(frame, width: 256)
    }

    @Test(.enabled(if: hevcAvailable)) func mailboxKeepsOnlyTheNewestFrame() throws {
        let stream = try #require(VideoTestEncoder.encode(codec: .hevc, width: 256, height: 128, frameCount: 4))
        let decoder = VideoStreamDecoder()
        try decoder.configure(stream.config)
        for unit in stream.units { #expect(decoder.decode(unit) == .decoded) }
        #expect(decoder.stats.framesDropped == 3)
        let frame = try #require(decoder.takeLatestFrame())
        #expect(frame.ptsMicros == stream.units[3].ptsMicros)
        #expect(decoder.takeLatestFrame() == nil) // taking empties the slot
    }

    @Test(.enabled(if: hevcAvailable)) func parameterSetChangeRebuildsTheSessionAndWaitsForAKeyFrame() throws {
        let first = try #require(VideoTestEncoder.encode(codec: .hevc, width: 256, height: 128, frameCount: 2))
        let second = try #require(VideoTestEncoder.encode(codec: .hevc, width: 192, height: 96, frameCount: 2))
        let decoder = VideoStreamDecoder()
        try decoder.configure(first.config)
        #expect(decoder.decode(first.units[0]) == .decoded)
        _ = decoder.takeLatestFrame()

        try decoder.configure(first.config) // same sets: nothing changes
        #expect(!decoder.needsKeyframe)

        try decoder.configure(second.config)
        #expect(decoder.streamSize.width == 192 && decoder.streamSize.height == 96)
        #expect(decoder.needsKeyframe)
        #expect(decoder.decode(second.units[1]) == .ignoredWaitingForKeyframe)
        #expect(decoder.decode(second.units[0]) == .decoded)
        let frame = try #require(decoder.takeLatestFrame())
        #expect(frame.width == 192 && frame.height == 96)
        expectBars(frame, width: 192)
        #expect(decoder.stats.sessionResets == 2)
    }

    @Test(.enabled(if: hevcAvailable)) func malformedUnitsAreRejectedAndNonKeyFramesIgnoredUntilTheNextKeyFrame() throws {
        let stream = try #require(VideoTestEncoder.encode(codec: .hevc, width: 256, height: 128, frameCount: 3))
        let decoder = VideoStreamDecoder()
        let requests = RequestCounter()
        decoder.onNeedsKeyframe = { requests.bump() }
        try decoder.configure(stream.config)
        #expect(decoder.decode(stream.units[0]) == .decoded)
        _ = decoder.takeLatestFrame()

        // A length that points past the data, then a truncated unit.
        var corrupt = stream.units[1]
        corrupt.data.replaceSubrange(0..<4, with: [0x7F, 0xFF, 0xFF, 0xFF])
        #expect(decoder.decode(corrupt) == .rejectedMalformed)
        #expect(requests.count == 1)
        #expect(decoder.needsKeyframe)

        var truncated = stream.units[2]
        truncated.data = truncated.data.prefix(truncated.data.count / 2)
        #expect(decoder.decode(truncated) == .ignoredWaitingForKeyframe) // not a key frame: ignored before anything else
        #expect(decoder.decode(stream.units[2]) == .ignoredWaitingForKeyframe)
        #expect(decoder.takeLatestFrame() == nil)
        #expect(requests.count == 3) // every ignored delta asks again, in case the first request or its answer was lost

        // The next key frame recovers (a fresh session is created for it).
        #expect(decoder.decode(stream.units[0]) == .decoded)
        #expect(!decoder.needsKeyframe)
        #expect(decoder.takeLatestFrame() != nil)
        #expect(decoder.stats.framesIgnored >= 3)
    }

    @Test(.enabled(if: hevcAvailable)) func suspendDropsEverythingAndResumeNeedsAKeyFrame() throws {
        let stream = try #require(VideoTestEncoder.encode(codec: .hevc, width: 256, height: 128, frameCount: 2))
        let decoder = VideoStreamDecoder()
        let requests = RequestCounter()
        decoder.onNeedsKeyframe = { requests.bump() }
        try decoder.configure(stream.config)
        #expect(decoder.decode(stream.units[0]) == .decoded)

        decoder.suspend()
        #expect(decoder.isSuspended)
        #expect(decoder.takeLatestFrame() == nil)
        #expect(decoder.decode(stream.units[0]) == .suspended)

        decoder.resume()
        #expect(!decoder.isSuspended && decoder.needsKeyframe)
        #expect(requests.count == 1)
        #expect(decoder.decode(stream.units[1]) == .ignoredWaitingForKeyframe)
        #expect(decoder.decode(stream.units[0]) == .decoded)
    }

    @Test func rejectsUnconfiguredAndInvalidParameterSets() {
        let decoder = VideoStreamDecoder()
        #expect(decoder.decode(VideoAccessUnit(data: Data([0, 0, 0, 1, 0x26]), ptsMicros: 0, isKey: true)) == .notConfigured)
        let garbage = VideoStreamConfig(codec: .hevc, parameterSets: [Data([0x40, 1]), Data([0x42, 1]), Data([0x44, 1])])
        #expect(throws: VideoStreamError.self) { try decoder.configure(garbage) }
        #expect(decoder.currentConfig == nil)
        #expect(throws: VideoStreamError.self) {
            try decoder.configure(VideoStreamConfig(codec: .hevc, parameterSets: [Data([0x40, 1])]))
        }
    }
}

private final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func bump() { lock.withLock { value += 1 } }
}

/// A decoded frame drawn through `VideoWindowRenderer` / the compositor, read back from a texture.
@MainActor
@Suite("Video: window renderer (real GPU)", .enabled(if: gpuTestsAvailable && hevcAvailable))
struct VideoWindowRendererTests {
    private func makeTarget(_ device: MTLDevice, width: Int, height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        return try #require(device.makeTexture(descriptor: descriptor))
    }

    private func rgb(_ texture: MTLTexture, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        var bytes = [UInt8](repeating: 0, count: 4)
        texture.getBytes(&bytes, bytesPerRow: 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        return (Int(bytes[2]), Int(bytes[1]), Int(bytes[0]))
    }

    private func decodedStream() throws -> VideoStreamDecoder {
        let stream = try #require(VideoTestEncoder.encode(codec: .hevc, width: 256, height: 128, frameCount: 1))
        let decoder = VideoStreamDecoder()
        try decoder.configure(stream.config)
        #expect(decoder.decode(stream.units[0]) == .decoded)
        return decoder
    }

    @Test func drawsADecodedFrameWithTheExpectedColours() throws {
        let renderer = try VideoWindowRenderer(device: #require(MTLCreateSystemDefaultDevice()))
        let decoder = try decodedStream()
        #expect(renderer.pull(from: decoder))
        #expect(!renderer.pull(from: decoder)) // nothing new
        #expect(renderer.frameSize.width == 256 && renderer.frameSize.height == 128)

        let geometry = ViewportGeometry(remoteSize: CGSize(width: 256, height: 128), viewSize: CGSize(width: 256, height: 128))
        let target = try makeTarget(renderer.device, width: 256, height: 128)
        renderer.render(to: target, geometry: geometry)
        let bars = [(255, 255, 255), (255, 0, 0), (0, 255, 0), (0, 0, 255)]
        for (index, expected) in bars.enumerated() {
            let got = rgb(target, index * 64 + 32, 64)
            #expect(abs(got.r - expected.0) <= 40 && abs(got.g - expected.1) <= 40 && abs(got.b - expected.2) <= 40, "bar \(index): \(got)")
        }
    }

    @Test func sourceRectShowsOnlyTheWindowContent() throws {
        let renderer = try VideoWindowRenderer(device: #require(MTLCreateSystemDefaultDevice()))
        let decoder = try decodedStream()
        renderer.pull(from: decoder)
        // The right half of the coded frame holds the green and blue bars; stretched over the view they are its left and right halves.
        var geometry = ViewportGeometry(remoteSize: CGSize(width: 256, height: 128), viewSize: CGSize(width: 128, height: 128))
        geometry.setSourceRect(CGRect(x: 128, y: 0, width: 128, height: 128))
        let target = try makeTarget(renderer.device, width: 128, height: 128)
        renderer.render(to: target, geometry: geometry)
        let left = rgb(target, 32, 64), right = rgb(target, 96, 64)
        #expect(left.g > 200 && left.r < 60 && left.b < 60, "left \(left)")
        #expect(right.b > 200 && right.r < 60 && right.g < 60, "right \(right)")
    }
}
