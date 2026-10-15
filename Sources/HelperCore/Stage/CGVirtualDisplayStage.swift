#if os(macOS)
import CoreGraphics
import Foundation
import LinkProtocol
import ObjectiveC
import os

/// Virtual displays through the private `CGVirtualDisplay` classes of CoreGraphics.
///
/// The classes are looked up by name at run time and every selector is checked with `responds(to:)` first, so a macOS
/// release that renames or removes them yields `StageError.stageUnavailable` (the stage then resizes windows in place)
/// instead of a crash. No Apple code is copied: the class and property names are the behavioural interface observed through
/// the Objective-C runtime. Whether it works on 15/26/27 is spike S8 (create/remove 100x, HiDPI, capture after reconfiguration);
/// `swift test` never creates a real display.
public final class CGVirtualDisplayStage: DisplayStage, @unchecked Sendable {
    private let lock = NSLock()
    private var live: [UInt32: AnyObject] = [:]
    private var serialCounter: UInt32 = UInt32.random(in: 1...0x00FF_FFFF)
    private let log = Logger(subsystem: "app.screon.helper", category: "stage")

    static let vendorID: UInt32 = 0x5C0E
    static let productID: UInt32 = 0x0001

    public init() {}

    /// Whether the private classes and the selectors this file uses exist. Cheap; call it before offering the stage.
    public static func isAvailable() -> Bool {
        (try? resolve()) != nil
    }

    private struct Classes {
        let descriptor: NSObject.Type
        let settings: NSObject.Type
        let mode: AnyClass
        let display: AnyClass
    }

    private static func resolve() throws -> Classes {
        guard let descriptor = NSClassFromString("CGVirtualDisplayDescriptor") as? NSObject.Type,
              let settings = NSClassFromString("CGVirtualDisplaySettings") as? NSObject.Type,
              let mode = NSClassFromString("CGVirtualDisplayMode"),
              let display = NSClassFromString("CGVirtualDisplay") else {
            throw StageError.stageUnavailable("virtual display classes not found")
        }
        let required: [(AnyClass, [String])] = [
            (descriptor, ["setName:", "setMaxPixelsWide:", "setMaxPixelsHigh:", "setSizeInMillimeters:", "setProductID:",
                          "setVendorID:", "setSerialNum:", "setQueue:"]),
            (settings, ["setHiDPI:", "setModes:"]),
            (mode, ["initWithWidth:height:refreshRate:"]),
            (display, ["initWithDescriptor:", "applySettings:", "displayID"]),
        ]
        for entry in required {
            let selectors = entry.1
            for name in selectors where !entry.0.instancesRespond(to: NSSelectorFromString(name)) {
                throw StageError.stageUnavailable("selector \(name) missing")
            }
        }
        return Classes(descriptor: descriptor, settings: settings, mode: mode, display: display)
    }

    // MARK: DisplayStage

    public func createDisplay(_ spec: VirtualDisplaySpec) async throws -> StageDisplay {
        guard (320...8192).contains(spec.width), (240...8192).contains(spec.height),
              spec.refreshRate >= 1, spec.refreshRate <= 240, !spec.name.isEmpty, spec.name.utf8.count <= 64 else {
            throw StageError.invalidSpec
        }
        let classes = try Self.resolve()
        let scale = spec.hiDPI ? 2 : 1
        let pixelWidth = UInt32(spec.width * scale)
        let pixelHeight = UInt32(spec.height * scale)

        let descriptor = classes.descriptor.init()
        descriptor.setValue(spec.name, forKey: "name")
        descriptor.setValue(NSNumber(value: pixelWidth), forKey: "maxPixelsWide")
        descriptor.setValue(NSNumber(value: pixelHeight), forKey: "maxPixelsHigh")
        // About 110 pixels per inch at the logical size.
        let millimetresPerPoint = 25.4 / 110.0
        descriptor.setValue(
            NSValue(size: CGSize(width: Double(spec.width) * millimetresPerPoint, height: Double(spec.height) * millimetresPerPoint)),
            forKey: "sizeInMillimeters"
        )
        descriptor.setValue(NSNumber(value: Self.productID), forKey: "productID")
        descriptor.setValue(NSNumber(value: Self.vendorID), forKey: "vendorID")
        descriptor.setValue(NSNumber(value: nextSerial()), forKey: "serialNum")
        descriptor.setValue(DispatchQueue(label: "app.screon.helper.virtual-display"), forKey: "queue")

        guard let mode = Self.makeMode(classes.mode, width: pixelWidth, height: pixelHeight, refreshRate: spec.refreshRate) else {
            throw StageError.stageUnavailable("mode creation failed")
        }
        let settings = classes.settings.init()
        settings.setValue(NSNumber(value: spec.hiDPI ? 1 : 0), forKey: "hiDPI")
        settings.setValue([mode], forKey: "modes")

        guard let display = Self.makeDisplay(classes.display, descriptor: descriptor) else {
            throw StageError.stageUnavailable("display creation failed")
        }
        guard Self.apply(settings, to: display) else {
            throw StageError.stageUnavailable("applySettings refused")
        }
        guard let number = (display as? NSObject)?.value(forKey: "displayID") as? NSNumber, number.uint32Value != 0 else {
            throw StageError.stageUnavailable("no display id")
        }
        let id = number.uint32Value
        lock.withLock { live[id] = display }

        // The display appears in the window server a moment after creation.
        for _ in 0..<40 {
            let bounds = CGDisplayBounds(id)
            if bounds.width > 0, bounds.height > 0 {
                return StageDisplay(id: StageDisplayID(rawValue: id), frame: Self.rect(bounds), isVirtual: true)
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        lock.withLock { live[id] = nil }
        throw StageError.stageUnavailable("display did not appear")
    }

    public func removeDisplay(_ id: StageDisplayID) async throws {
        // Releasing the last reference tears the display down.
        guard lock.withLock({ live.removeValue(forKey: id.rawValue) }) != nil else { throw StageError.unknownDisplay }
    }

    public func displays() async -> [StageDisplay] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        let virtual = lock.withLock { Set(live.keys) }
        return ids.prefix(Int(count)).map {
            StageDisplay(id: StageDisplayID(rawValue: $0), frame: Self.rect(CGDisplayBounds($0)), isVirtual: virtual.contains($0))
        }
    }

    public func frame(of display: StageDisplayID) async -> LinkRect? {
        let bounds = CGDisplayBounds(display.rawValue)
        return bounds.width > 0 && bounds.height > 0 ? Self.rect(bounds) : nil
    }

    // MARK: Helpers

    private func nextSerial() -> UInt32 {
        lock.withLock { serialCounter &+= 1; return serialCounter }
    }

    private static func rect(_ bounds: CGRect) -> LinkRect {
        LinkRect(x: bounds.origin.x, y: bounds.origin.y, width: bounds.size.width, height: bounds.size.height)
    }

    /// `[[CGVirtualDisplayMode alloc] initWithWidth:height:refreshRate:]`, called through the method implementation because
    /// Swift cannot send a message with scalar arguments to a class it does not know at compile time.
    private static func makeMode(_ cls: AnyClass, width: UInt32, height: UInt32, refreshRate: Double) -> AnyObject? {
        typealias Init = @convention(c) (AnyObject, Selector, UInt32, UInt32, Double) -> Unmanaged<AnyObject>?
        guard let allocated = (cls as AnyObject).perform(NSSelectorFromString("alloc")) else { return nil }
        let selector = NSSelectorFromString("initWithWidth:height:refreshRate:")
        let object = allocated.takeUnretainedValue()
        guard let implementation = object.method(for: selector) else { return nil }
        let function = unsafeBitCast(implementation, to: Init.self)
        // `init` consumes the +1 from `alloc` and returns +1 (or nil after releasing it).
        return function(object, selector, width, height, refreshRate)?.takeRetainedValue()
    }

    private static func makeDisplay(_ cls: AnyClass, descriptor: AnyObject) -> AnyObject? {
        typealias Init = @convention(c) (AnyObject, Selector, AnyObject) -> Unmanaged<AnyObject>?
        guard let allocated = (cls as AnyObject).perform(NSSelectorFromString("alloc")) else { return nil }
        let selector = NSSelectorFromString("initWithDescriptor:")
        let object = allocated.takeUnretainedValue()
        guard let implementation = object.method(for: selector) else { return nil }
        let function = unsafeBitCast(implementation, to: Init.self)
        return function(object, selector, descriptor)?.takeRetainedValue()
    }

    private static func apply(_ settings: AnyObject, to display: AnyObject) -> Bool {
        typealias Apply = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
        let selector = NSSelectorFromString("applySettings:")
        guard let implementation = display.method(for: selector) else { return false }
        return unsafeBitCast(implementation, to: Apply.self)(display, selector, settings)
    }
}
#endif
