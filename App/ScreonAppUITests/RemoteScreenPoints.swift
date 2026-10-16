import XCTest

/// Turns Mac pixels of the remote screen into points to tap in the `screon` view.
///
/// DEBUG builds of the app append ` | rect X Y W H` to the view's accessibility value: where the Mac screen is drawn, in the view's
/// points. It is not simply centred in the view: the picture is kept clear of the status bar, notch, home indicator and rounded
/// display corners. Older builds without it fall back to the centred fit.
struct RemoteScreenPoints {
    let screen: XCUIElement
    let remote: CGSize

    /// Where the Mac screen is drawn, in the view's points.
    var contentRect: CGRect {
        let frame = screen.frame
        let value = screen.value as? String ?? ""
        if let match = value.firstMatch(of: /rect (-?[\d.]+) (-?[\d.]+) ([\d.]+) ([\d.]+)/),
           let x = Double(match.1), let y = Double(match.2), let w = Double(match.3), let h = Double(match.4) {
            return CGRect(x: x, y: y, width: w, height: h)
        }
        let scale = min(frame.width / remote.width, frame.height / remote.height)
        let size = CGSize(width: remote.width * scale, height: remote.height * scale)
        return CGRect(x: (frame.width - size.width) / 2, y: (frame.height - size.height) / 2, width: size.width, height: size.height)
    }

    /// Points per Mac pixel.
    var scale: Double { contentRect.width / remote.width }

    /// The coordinate of Mac pixel (`x`, `y`).
    func point(_ x: Double, _ y: Double) -> XCUICoordinate {
        let frame = screen.frame
        let rect = contentRect
        return screen.coordinate(withNormalizedOffset: CGVector(
            dx: (rect.minX + x * rect.width / remote.width) / frame.width,
            dy: (rect.minY + y * rect.height / remote.height) / frame.height
        ))
    }
}
