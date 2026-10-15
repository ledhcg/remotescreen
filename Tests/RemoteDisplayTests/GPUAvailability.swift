import Foundation
import Metal

/// Drawing tests need a real GPU. GitHub Actions has a virtual Metal device but the process traps when drawing, so the GPU suites skip themselves when
/// running on CI (the `CI` variable). Run `swift test` on a machine with a GPU to check them.
let gpuTestsAvailable: Bool =
    MTLCreateSystemDefaultDevice() != nil && ProcessInfo.processInfo.environment["CI"] == nil
