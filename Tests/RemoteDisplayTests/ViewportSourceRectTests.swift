import CoreGraphics
import Foundation
import Testing
@testable import RemoteDisplay

@Suite("ViewportGeometry sourceRect")
struct ViewportSourceRectTests {
    private let remote = CGSize(width: 1000, height: 500)

    private func cropped(view: CGSize = CGSize(width: 800, height: 400)) -> ViewportGeometry {
        var geometry = ViewportGeometry(remoteSize: remote, viewSize: view)
        geometry.setSourceRect(CGRect(x: 200, y: 100, width: 400, height: 200))
        return geometry
    }

    @Test func defaultsToTheWholeSurfaceAndChangesNothing() {
        let geometry = ViewportGeometry(remoteSize: remote, viewSize: CGSize(width: 500, height: 500))
        #expect(geometry.sourceRect == CGRect(origin: .zero, size: remote))
        #expect(geometry.sourceUVRect == SIMD4<Float>(0, 0, 1, 1))
        #expect(geometry.scale == 0.5)
        #expect(geometry.contentRect == CGRect(x: 0, y: 125, width: 500, height: 250))
        #expect(geometry.remotePoint(forView: CGPoint(x: 250, y: 250)) == CGPoint(x: 500, y: 250))
    }

    @Test func cropScalesAndPlacesOnlyTheSourceRect() {
        let geometry = cropped()
        #expect(geometry.scale == 2) // 800 / 400
        #expect(geometry.contentRect == CGRect(x: 0, y: 0, width: 800, height: 400))
        #expect(geometry.normalizedDeviceRect == SIMD4<Float>(-1, -1, 1, 1))
        #expect(geometry.sourceUVRect == SIMD4<Float>(0.2, 0.2, 0.6, 0.6))
    }

    @Test func mappingsRoundTripWithACrop() {
        var geometry = cropped(view: CGSize(width: 600, height: 600))
        geometry.setZoom(3, around: CGPoint(x: 100, y: 200))
        geometry.pan(by: CGPoint(x: -30, y: 12))
        for remote in [CGPoint(x: 250, y: 120), CGPoint(x: 400, y: 200), CGPoint(x: 599.5, y: 299.5)] {
            let back = geometry.remotePoint(forView: geometry.viewPoint(forRemote: remote))
            #expect(abs(back.x - remote.x) < 1e-9 && abs(back.y - remote.y) < 1e-9)
        }
        #expect(geometry.viewPoint(forRemote: CGPoint(x: 200, y: 100)) == geometry.contentRect.origin)
    }

    @Test func cropEdgesMapToTheViewEdges() {
        let geometry = cropped()
        #expect(geometry.remotePoint(forView: .zero) == CGPoint(x: 200, y: 100))
        #expect(geometry.remotePoint(forView: CGPoint(x: 800, y: 400)) == CGPoint(x: 600, y: 300))
        #expect(geometry.viewPoint(forRemote: CGPoint(x: 600, y: 300)) == CGPoint(x: 800, y: 400))
    }

    @Test func remotePixelIsRestrictedToTheCrop() throws {
        let geometry = cropped()
        let first = try #require(geometry.remotePixel(forView: CGPoint(x: 0.5, y: 0.5), clamped: false))
        #expect(first.x == 200 && first.y == 100)
        let last = try #require(geometry.remotePixel(forView: CGPoint(x: 799.9, y: 399.9), clamped: false))
        #expect(last.x == 599 && last.y == 299)
        #expect(geometry.remotePixel(forView: CGPoint(x: -10, y: 50), clamped: false) == nil)
        let clamped = try #require(geometry.remotePixel(forView: CGPoint(x: -10, y: 5000), clamped: true))
        #expect(clamped.x == 200 && clamped.y == 299)
    }

    @Test func requestsOutsideTheSurfaceAreClamped() {
        var geometry = ViewportGeometry(remoteSize: remote, viewSize: CGSize(width: 500, height: 500))
        geometry.setSourceRect(CGRect(x: 900, y: 400, width: 500, height: 500))
        #expect(geometry.sourceRect == CGRect(x: 900, y: 400, width: 100, height: 100))
        geometry.setSourceRect(CGRect(x: 2000, y: 2000, width: 10, height: 10))
        #expect(geometry.sourceRect == CGRect(origin: .zero, size: remote), "no overlap: whole surface")
        geometry.setSourceRect(CGRect(x: 10, y: 10, width: 0, height: 5))
        #expect(geometry.sourceRect == CGRect(origin: .zero, size: remote), "empty: whole surface")
        geometry.setSourceRect(nil)
        #expect(geometry.sourceRect == CGRect(origin: .zero, size: remote))
    }

    @Test func shrinkingTheRemoteSizeReClipsTheCrop() {
        var geometry = cropped()
        geometry.updateRemoteSize(CGSize(width: 400, height: 300))
        #expect(geometry.sourceRect == CGRect(x: 200, y: 100, width: 200, height: 200))
    }

    @Test func zoomKeepsTheFocusPointFixedWithACrop() {
        var geometry = cropped(view: CGSize(width: 600, height: 600))
        let focus = CGPoint(x: 150, y: 220)
        let before = geometry.remotePoint(forView: focus)
        geometry.setZoom(4, around: focus)
        let after = geometry.remotePoint(forView: focus)
        #expect(abs(before.x - after.x) < 1e-9 && abs(before.y - after.y) < 1e-9)
    }

    @Test func panStaysInsideTheCroppedContent() {
        var geometry = cropped(view: CGSize(width: 400, height: 400))
        geometry.setZoom(2, around: CGPoint(x: 200, y: 200))
        geometry.pan(by: CGPoint(x: 100_000, y: 100_000))
        let rect = geometry.contentRect
        #expect(rect.minX <= 0 && rect.minY <= 0)
        geometry.pan(by: CGPoint(x: -200_000, y: -200_000))
        let far = geometry.contentRect
        #expect(far.maxX >= 400 - 1e-9 && far.maxY >= 400 - 1e-9)
    }
}
