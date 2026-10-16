import CoreGraphics
import Foundation
import Testing
@testable import InputKit

struct PencilTestSpace: RemoteCoordinateSpace {
    var remoteSize = CGSize(width: 2000, height: 1000)
    var pointsPerRemotePixel = 0.5
    func remotePixel(forView point: CGPoint, clamped: Bool) -> (x: Int, y: Int)? {
        let x = Int((point.x / pointsPerRemotePixel).rounded(.down)), y = Int((point.y / pointsPerRemotePixel).rounded(.down))
        if (0..<2000).contains(x) && (0..<1000).contains(y) { return (x, y) }
        guard clamped else { return nil }
        return (min(max(x, 0), 1999), min(max(y, 0), 999))
    }
}

@Suite("Apple Pencil samples")
struct PencilSampleTests {
    let space = PencilTestSpace()
    let sample = PencilSample(pressure: 0.6, tiltX: 0.3, tiltY: -0.2, azimuth: 1)

    private func tablet(_ x: Double, _ y: Double, _ pressure: Double) -> InputIntent {
        .tablet(at: RemotePoint(x: x, y: y), pressure: pressure, tiltX: 0.3, tiltY: -0.2)
    }

    @Test func aStrokeBecomesTabletIntentsWithPressure() {
        var mapper = TouchMapper(policy: TouchPolicy(mode: .trackpad))
        var out = mapper.handle(.pencilStroke(.press(CGPoint(x: 100, y: 150)), sample), in: space, isZoomed: false).intents
        out += mapper.handle(.pencilStroke(.move(CGPoint(x: 110, y: 150)), sample), in: space, isZoomed: false).intents
        out += mapper.handle(.pencilStroke(.release(CGPoint(x: 120, y: 150)), sample), in: space, isZoomed: false).intents
        #expect(out == [tablet(200, 300, 0.6), tablet(220, 300, 0.6), tablet(240, 300, 0)])
    }

    @Test func aTapIsHoverPressHover() {
        var mapper = TouchMapper()
        let out = mapper.handle(.pencilStroke(.click(CGPoint(x: 100, y: 150)), sample), in: space, isZoomed: false).intents
        #expect(out == [tablet(200, 300, 0), tablet(200, 300, 0.6), tablet(200, 300, 0)])
    }

    @Test func aLightTouchStillCountsAsContact() {
        var mapper = TouchMapper()
        let light = PencilSample(pressure: 0, tiltX: 0, tiltY: 0)
        let out = mapper.handle(.pencilStroke(.press(CGPoint(x: 10, y: 10)), light), in: space, isZoomed: false).intents
        guard case .tablet(_, let pressure, _, _)? = out.first else { Issue.record("no tablet intent"); return }
        #expect(pressure > 0)
    }

    @Test func rightClickKeepsItsPointerEventsAndHoverHasNoPressure() {
        var mapper = TouchMapper()
        let right = mapper.handle(.pencilStroke(.rightClick(CGPoint(x: 100, y: 150)), sample), in: space, isZoomed: false).intents
        #expect(right.count == 3)
        #expect(right.allSatisfy { if case .pointer = $0 { true } else { false } })
        let hover = mapper.handle(.pencilHover(CGPoint(x: 50, y: 50), sample), in: space, isZoomed: false).intents
        #expect(hover == [tablet(100, 100, 0)])
    }

    @Test func withoutASampleTheStrokeIsExactlyWhatItWas() {
        var plain = TouchMapper(policy: TouchPolicy(mode: .trackpad))
        let out = plain.handle(.pencil(.click(CGPoint(x: 100, y: 150))), in: space, isZoomed: false).intents
        #expect(out.allSatisfy { if case .pointer = $0 { true } else { false } })
        #expect(out.count == 3)
    }

    @Test func rfbIgnoresTabletIntents() {
        var mapper = TouchMapper()
        let output = mapper.handle(.pencilStroke(.click(CGPoint(x: 100, y: 150)), sample), in: space, isZoomed: false)
        #expect(output.messages.isEmpty)
    }

    @Test func uprightPencilHasNoTilt() {
        let upright = PencilSample(force: 1, maximumForce: 4, altitude: .pi / 2, azimuth: 0.7)
        #expect(abs(upright.tiltX) < 1e-9 && abs(upright.tiltY) < 1e-9)
        #expect(upright.pressure == 0.25)
    }

    @Test func aFlatPencilLeansAlongItsAzimuth() {
        let east = PencilSample(force: 1, maximumForce: 1, altitude: 0, azimuth: 0)
        #expect(abs(east.tiltX - .pi / 2) < 1e-9 && abs(east.tiltY) < 1e-9)
        let south = PencilSample(force: 1, maximumForce: 1, altitude: 0, azimuth: .pi / 2)
        #expect(abs(south.tiltY - .pi / 2) < 1e-9 && abs(south.tiltX) < 1e-9)
        let tilted = PencilSample(force: 1, maximumForce: 1, altitude: .pi / 4, azimuth: .pi)
        #expect(abs(tilted.tiltX + .pi / 4) < 1e-9)
    }

    @Test func nonFiniteInputsAreSafe() {
        let nan = PencilSample(force: .nan, maximumForce: .infinity, altitude: .nan, azimuth: .infinity)
        #expect(nan.pressure == 0 && nan.tiltX.isFinite && nan.tiltY.isFinite)
        let wild = PencilSample(pressure: 9, tiltX: 100, tiltY: -100)
        #expect(wild.pressure == 1 && abs(wild.tiltX) <= .pi / 2 && abs(wild.tiltY) <= .pi / 2)
        let zeroMax = PencilSample(force: 3, maximumForce: 0, altitude: 1, azimuth: 0)
        #expect(zeroMax.pressure == 0)
    }
}
