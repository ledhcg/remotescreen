import CoreGraphics
import Foundation
import ImageIO
import Metal
import RFBKit

/// A picture decoded from PNG or JPEG data into premultiplied BGRA pixels.
public struct DecodedBGRAImage: Sendable, Equatable {
    public var width: Int
    public var height: Int
    /// `width * height * 4` bytes, B G R A, alpha premultiplied.
    public var bgra: [UInt8]

    public init(width: Int, height: Int, bgra: [UInt8]) {
        self.width = width
        self.height = height
        self.bgra = bgra
    }
}

/// Decodes images that come from the Mac (child surfaces, cursors). The data is hostile: the pixel size is read from the header and
/// checked against the limits BEFORE any pixel memory is allocated.
public enum BGRAImageDecoder {
    /// Largest side of a decoded image.
    public static let maxDimension = 4096
    /// Largest pixel count of a decoded image (64 MiB of BGRA).
    public static let maxPixelCount = 16 * 1024 * 1024

    /// Returns `nil` for data that is not a single readable PNG or JPEG image, or that is too big.
    public static func decode(_ data: Data, maxDimension: Int = BGRAImageDecoder.maxDimension) -> DecodedBGRAImage? {
        guard !data.isEmpty else { return nil }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              CGImageSourceGetCount(source) >= 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= maxDimension, height <= maxDimension,
              width * height <= maxPixelCount,
              let image = CGImageSourceCreateImageAtIndex(source, 0, options)
        else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { return false }
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? DecodedBGRAImage(width: width, height: height, bgra: pixels) : nil
    }

    /// A cursor from PNG data. The hotspot is clamped into the image. `nil` when the picture is unreadable or larger than a cursor may be.
    public static func decodeCursor(_ data: Data, hotspotX: Double, hotspotY: Double) -> CursorImage? {
        guard let image = decode(data, maxDimension: CursorImage.maxDimension) else { return nil }
        func clamp(_ value: Double, _ limit: Int) -> Int {
            guard value.isFinite else { return 0 }
            return min(max(Int(value.rounded()), 0), max(limit - 1, 0))
        }
        return CursorImage(
            width: image.width, height: image.height, hotspotX: clamp(hotspotX, image.width), hotspotY: clamp(hotspotY, image.height),
            bgra: image.bgra
        )
    }
}

/// A BGRA picture on the GPU for the compositor: child surfaces (menus, popovers) and anything else that arrives as a still image.
///
/// Like `FramebufferSurface` it avoids overwriting a texture the GPU may still be reading: `update` always makes a new texture, and a
/// texture lives as long as the command buffers that draw it (they keep it alive through `beginDraw`'s returned frame).
@MainActor
public final class BGRAImageSurface: SurfaceTexture {
    public let device: MTLDevice
    private var texture: MTLTexture?
    public private(set) var size: (width: Int, height: Int) = (0, 0)
    public var pixelLayout: SurfacePixelLayout { .bgra }

    public init(device: MTLDevice) { self.device = device }

    /// Replaces the picture. Returns `false` (keeping the old one) if the texture cannot be made.
    @discardableResult
    public func update(_ image: DecodedBGRAImage) -> Bool {
        guard image.width > 0, image.height > 0, image.bgra.count == image.width * image.height * 4 else { return false }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: image.width, height: image.height, mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let created = device.makeTexture(descriptor: descriptor) else { return false }
        image.bgra.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            created.replace(
                region: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0, withBytes: base, bytesPerRow: image.width * 4
            )
        }
        texture = created
        size = (image.width, image.height)
        return true
    }

    public func beginDraw(in commandBuffer: MTLCommandBuffer) -> SurfaceFrame? {
        guard let texture else { return nil }
        // The command buffer keeps the texture alive until the GPU is done, even if `update` swaps in a new one meanwhile.
        commandBuffer.addCompletedHandler { [texture] _ in _ = texture }
        return SurfaceFrame(primary: texture)
    }
}
