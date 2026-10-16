#if os(macOS)
import CoreGraphics
import Foundation
import LinkProtocol
@preconcurrency import ScreenCaptureKit
import Testing
@testable import HelperCore

/// Crashes of Screon Helper 0.3.0 (build 4) found in its crash reports. Neither test needs a permission grant.
@Suite(.timeLimit(.minutes(2))) struct HelperCrashRegressionTests {
    /// `WindowTracker` starts observing every running app in parallel; each one asks for the observer run loop. Starting the
    /// thread twice raised an Objective-C exception and aborted the helper at launch.
    @Test func theObserverRunLoopCanBeAskedForFromManyThreadsAtOnce() {
        let thread = RunLoopThread()
        let loops = OSAllocatedUnfairLockBox()
        DispatchQueue.concurrentPerform(iterations: 64) { _ in loops.insert(ObjectIdentifier(thread.runLoop())) }
        #expect(loops.count == 1, "every caller gets the same run loop")
    }

    /// `SCStreamConfiguration.backgroundColor` is not retained. The colour must outlive the configuration, or `SCStream`
    /// copying the configuration touched freed memory and crashed the helper on every window subscription.
    @Test func theCaptureConfigurationCanBeCopiedAfterItWasBuilt() throws {
        var configurations: [SCStreamConfiguration] = []
        for _ in 0..<50 {
            autoreleasepool {
                configurations.append(ScreenCaptureKitSystem.makeConfiguration(
                    for: CaptureStreamConfig(window: 1, windowNumber: 2, outputWidth: 640, outputHeight: 480, framesPerSecond: 30)))
            }
        }
        // Churn the heap so a freed colour would be reused, then copy as SCStream does.
        for _ in 0..<2_000 { _ = CGColor(srgbRed: .random(in: 0...1), green: 0.5, blue: 0.5, alpha: 1) }
        for configuration in configurations {
            let copy = try #require(configuration.copy() as? SCStreamConfiguration)
            #expect(copy.backgroundColor.numberOfComponents >= 1)
            #expect(copy.backgroundColor.alpha == 1)
            #expect(copy.backgroundColor.components?.dropLast().allSatisfy { $0 == 0 } == true, "black")
        }
    }
}

/// A set of identifiers filled from many threads.
private final class OSAllocatedUnfairLockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var set = Set<ObjectIdentifier>()
    func insert(_ id: ObjectIdentifier) { lock.lock(); set.insert(id); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return set.count }
}
#endif
