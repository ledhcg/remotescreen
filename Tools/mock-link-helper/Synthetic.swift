import CoreGraphics
import CoreText
import Foundation
import ImageIO
import LinkProtocol
import UniformTypeIdentifiers

/// Everything the mock "Mac" shows is made up here: apps, windows, icons, a menu, and a moving test pattern.
struct MockApp: Sendable {
    var ref: AppRef
    var bundleID: String
    var name: String
    var letter: String
    var pid: Int32
    var color: (r: UInt8, g: UInt8, b: UInt8)
    var iconKey: IconKey { IconKey(rawValue: ref.rawValue) }
}

enum Synthetic {
    static let apps: [MockApp] = [
        MockApp(ref: 1, bundleID: "com.example.notes", name: "Notes Demo", letter: "N", pid: 1001, color: (230, 160, 30)),
        MockApp(ref: 2, bundleID: "com.example.draw", name: "Draw Demo", letter: "D", pid: 1002, color: (60, 140, 230)),
        MockApp(ref: 3, bundleID: "com.example.terminal", name: "Terminal Demo", letter: "T", pid: 1003, color: (40, 170, 90)),
    ]

    static let mainDisplay = LinkDisplayInfo(id: 1, frame: LinkRect(x: 0, y: 0, width: 1440, height: 900), scale: 2)

    static func app(bundleID: String) -> MockApp? { apps.first { $0.bundleID == bundleID } }
    static func app(iconKey: IconKey) -> MockApp? { apps.first { $0.iconKey == iconKey } }

    /// Window id 4 is the transient menu surface, a child of window 1.
    static let menuSurfaceWindow = WindowID(rawValue: 4)

    static func basicWindows() -> [LinkWindowInfo] {
        let managed: LinkWindowFlags = [.onScreen, .main]
        return [
            LinkWindowInfo(
                id: 1, pid: 1001, bundleID: "com.example.notes", frame: LinkRect(x: 40, y: 40, width: 640, height: 420), scale: 2,
                title: "Document 1", flags: managed.union(.focused)),
            LinkWindowInfo(
                id: 2, pid: 1002, bundleID: "com.example.draw", frame: LinkRect(x: 120, y: 80, width: 720, height: 480), scale: 2,
                title: "Canvas 1", flags: managed),
            LinkWindowInfo(
                id: 3, pid: 1003, bundleID: "com.example.terminal", frame: LinkRect(x: 200, y: 120, width: 560, height: 360), scale: 2,
                title: "Terminal 1", flags: managed),
            LinkWindowInfo(
                id: 4, pid: 1001, bundleID: "com.example.notes", parentID: 1, kind: .transient, level: 101,
                frame: LinkRect(x: 60, y: 70, width: 160, height: 120), scale: 2, title: "Menu", flags: [.onScreen]),
        ]
    }

    static let managedCapabilities: LinkWindowCapabilities = [
        .resizable, .movable, .closable, .supportsTablet, .menuAvailable, .minimisable, .zoomable,
    ]

    static func menuTree() -> [LinkMenuItem] {
        [
            LinkMenuItem(
                title: "File",
                children: [
                    LinkMenuItem(title: "New", keyEquivalent: "n", modifiers: [.command]),
                    LinkMenuItem(title: "Open...", keyEquivalent: "o", modifiers: [.command]),
                    LinkMenuItem(title: "", isSeparator: true),
                    LinkMenuItem(title: "Close", keyEquivalent: "w", modifiers: [.command]),
                ]),
            LinkMenuItem(
                title: "Edit",
                children: [
                    LinkMenuItem(title: "Undo", keyEquivalent: "z", modifiers: [.command]),
                    LinkMenuItem(title: "Redo", enabled: false, keyEquivalent: "z", modifiers: [.command, .shift]),
                    LinkMenuItem(title: "", isSeparator: true),
                    LinkMenuItem(title: "Copy", keyEquivalent: "c", modifiers: [.command]),
                    LinkMenuItem(title: "Paste", keyEquivalent: "v", modifiers: [.command]),
                ]),
            LinkMenuItem(
                title: "View",
                children: [LinkMenuItem(title: "Show Grid", checked: true), LinkMenuItem(title: "Zoom In", keyEquivalent: "+", modifiers: [.command])]),
        ]
    }

    // MARK: Images

    /// A solid-colour PNG with one centred letter or word. Used for app icons and the transient menu surface.
    static func png(width: Int, height: Int, color: (r: UInt8, g: UInt8, b: UInt8), text: String) -> Data {
        let space = CGColorSpaceCreateDeviceRGB()
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return Data() }
        context.setFillColor(
            CGColor(
                red: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255, blue: CGFloat(color.b) / 255, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, CGFloat(min(width, height)) * (text.count > 1 ? 0.28 : 0.6), nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorFromContextAttributeName: true,
        ]
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes as [NSAttributedString.Key: Any]))
        let bounds = CTLineGetBoundsWithOptions(line, [])
        context.textPosition = CGPoint(x: (CGFloat(width) - bounds.width) / 2 - bounds.minX, y: (CGFloat(height) - bounds.height) / 2 - bounds.minY)
        CTLineDraw(line, context)
        guard let image = context.makeImage() else { return Data() }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return Data() }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return Data() }
        return data as Data
    }

    static func icon(for app: MockApp, pixelSize: Int) -> Data {
        let size = max(16, min(256, pixelSize))
        return png(width: size, height: size, color: app.color, text: app.letter)
    }

    static func menuSurfacePNG() -> Data { png(width: 320, height: 240, color: (70, 70, 80), text: "Menu") }
}

/// A moving colour-bar pattern with a visible marker where the last pointer event landed, written straight into a BGRA
/// pixel buffer.
enum PatternRenderer {
    /// ARGB, little-endian in memory as BGRA: white, yellow, cyan, green, magenta, red, blue, black.
    static let palette: [UInt32] = [
        0xFFFF_FFFF, 0xFFFF_FF00, 0xFF00_FFFF, 0xFF00_FF00, 0xFFFF_00FF, 0xFFFF_0000, 0xFF00_00FF, 0xFF00_0000,
    ]
    static let markerFill: UInt32 = 0xFFFF_5A00
    static let markerLine: UInt32 = 0xFF00_0000

    /// `marker` is in pixels from the top-left of the frame.
    static func render(
        into base: UnsafeMutableRawPointer, width: Int, height: Int, bytesPerRow: Int, frame: Int, seed: Int,
        marker: (x: Int, y: Int)?
    ) {
        let shift = (frame * 6) % max(width, 1)
        var row = [UInt32](repeating: 0, count: width)
        for x in 0..<width {
            row[x] = palette[(((x + shift) % width) * 8 / width + seed) % 8]
        }
        let stripeHeight = max(4, height / 16)
        let stripeTop = (frame * 4) % max(height, 1)
        row.withUnsafeBytes { template in
            for y in 0..<height {
                let dest = base.advanced(by: y * bytesPerRow)
                let inStripe = (y - stripeTop + height) % height < stripeHeight
                if inStripe {
                    let pixels = dest.bindMemory(to: UInt32.self, capacity: width)
                    for x in 0..<width { pixels[x] = 0xFF20_2020 }
                } else {
                    dest.copyMemory(from: template.baseAddress!, byteCount: width * 4)
                }
            }
        }
        guard let marker else { return }
        let mx = min(max(marker.x, 0), width - 1), my = min(max(marker.y, 0), height - 1)
        func put(_ x: Int, _ y: Int, _ value: UInt32) {
            guard x >= 0, y >= 0, x < width, y < height else { return }
            base.advanced(by: y * bytesPerRow).bindMemory(to: UInt32.self, capacity: width)[x] = value
        }
        for x in 0..<width { put(x, my, markerLine); put(x, my + 1, markerLine) }
        for y in 0..<height { put(mx, y, markerLine); put(mx + 1, y, markerLine) }
        for dy in -14...14 { for dx in -14...14 { put(mx + dx, my + dy, abs(dx) >= 12 || abs(dy) >= 12 ? markerLine : markerFill) } }
    }
}
