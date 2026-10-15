import Foundation

/// How the Mac screen is placed on the iPad/iPhone screen. The user picks it from a menu and it is remembered between app launches.
///
/// Every mode **adapts automatically** when the viewport changes size (rotation, Split View, Stage Manager): the scale is recomputed from the new size
/// on every layout pass (`ViewportGeometry.updateViewSize`), with nothing more to do.
///
/// None of them change the Mac's own resolution: Apple's server does not accept standard RFB `SetDesktopSize`, and its private message type 29
/// (`SetDisplayConfiguration`) creates a virtual display that can darken the real screen. `.device` uses message type 8 (the server shrinks the image
/// just for this viewer), see `protocol-notes.md` 4g.
public enum DisplayMode: String, CaseIterable, Sendable {
    /// Shows the whole Mac screen, shrunk to fit, with black borders if the aspect ratios differ.
    case fit
    /// Covers the whole device screen, cropping the excess at the edges; drag with two fingers to see the cropped part.
    case fill
    /// Each Mac pixel is exactly one device pixel: sharpest, no scaling; drag to see the part outside the frame.
    case native
    /// Follows the device resolution: Apple's server shrinks the Mac screen to the exact pixel size of the viewport before sending, so the image
    /// appears 1:1 (as sharp as native pixels) while still showing the whole screen, with far fewer bytes (portrait iPhone: about 1/5). Recomputed automatically on
    /// rotation. With a non-Apple server it behaves like `.fit`.
    case device

    public static let `default` = DisplayMode.fit

    /// - Parameter screenScale: device pixels per point (`UIScreen.scale`, 2 on iPad, 3 on iPhone Pro).
    public func scaleMode(screenScale: Double) -> ViewportGeometry.ScaleMode {
        switch self {
        case .fit: .fit
        case .fill: .fill
        case .native: .pixelPerfect(screenScale: screenScale)
        case .device: .fit // the server already shrank to the viewport size, so "fit" is exactly 1:1
        }
    }

    /// Scale to ask the server for: fits the viewport of `viewPixels` (device pixels) and never enlarges (at most 1).
    /// `nil` if this mode does not use server-side scaling or the size is invalid.
    public func serverScale(remote: CGSize, viewPixels: CGSize) -> Double? {
        guard self == .device, remote.width > 0, remote.height > 0, viewPixels.width > 0, viewPixels.height > 0 else { return nil }
        return min(1, viewPixels.width / remote.width, viewPixels.height / remote.height)
    }
}
