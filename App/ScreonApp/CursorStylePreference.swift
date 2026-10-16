import RemoteDisplay
import SwiftUI
import UIKit

extension CursorStyle {
    var title: LocalizedStringKey {
        switch self {
        case .mac: "Mac cursor"
        case .filledArrow: "Arrow"
        case .outlinedArrow: "Outlined arrow"
        case .filledArrowRays: "Arrow with click rays"
        case .outlinedArrowDots: "Outlined arrow with dots"
        case .filledArrowDashedRing: "Arrow with dashed ring"
        case .outlinedArrowDottedRing: "Outlined arrow with dotted ring"
        }
    }

    /// The menu preview: Screon's arrows as template images (tinted like the item's text), the Mac cursor as its system symbol.
    @MainActor var menuIcon: Image {
        guard let image = Self.menuImages[self] else { return Image(systemName: "cursorarrow") }
        return Image(uiImage: image)
    }

    @MainActor private static let menuImages: [CursorStyle: UIImage] = {
        var images: [CursorStyle: UIImage] = [:]
        for style in allCases {
            guard let artwork = style.artwork(.template, scale: 3) else { continue }
            let data = Data(artwork.bgra) as CFData
            guard let provider = CGDataProvider(data: data),
                  let cgImage = CGImage(
                      width: artwork.width, height: artwork.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: artwork.width * 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                      provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
                  ) else { continue }
            images[style] = UIImage(cgImage: cgImage, scale: 3, orientation: .up).withRenderingMode(.alwaysTemplate)
        }
        return images
    }()
}

/// The pointer style chosen in the session menu, shared by Screen Sharing sessions and App Mode windows.
///
/// `SessionController` persists it; App Mode windows read `current` and compare `version` on each draw tick (an integer compare,
/// no allocation in the draw path).
@MainActor
enum CursorStylePreference {
    static let key = "cursorStyle"

    static var current: CursorStyle = UserDefaults.standard.string(forKey: key).flatMap(CursorStyle.init(rawValue:)) ?? .default {
        didSet { if current != oldValue { version &+= 1 } }
    }

    private(set) static var version = 0
}
