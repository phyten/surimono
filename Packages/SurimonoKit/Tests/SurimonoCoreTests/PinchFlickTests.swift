import Foundation
import Testing

@testable import SurimonoCore

struct PinchFlickTests {
    @Test("1秒で300%から200%へ縮めるピンチは戻らない")
    func slowPinch() {
        var detector = PinchFlickDetector()
        #expect(detector.update(timestamp: 0, zoom: 3, phase: .began) == false)
        for frame in 1...60 {
            let time = Double(frame) / 60
            #expect(detector.update(timestamp: time, zoom: 3 * pow(2.0 / 3, time), phase: .changed) == false)
        }
        #expect(detector.update(timestamp: 1, zoom: 2, phase: .ended) == false)
    }

    @Test("120msで300%から180%へ縮めると40msの記録で一度だけ戻り始める")
    func fastPinch() {
        var detector = PinchFlickDetector()
        _ = detector.update(timestamp: 0, zoom: 3, phase: .began)
        var triggers: [Int] = []
        for frame in 1...12 {
            if detector.update(timestamp: Double(frame) / 100, zoom: 3 * pow(0.6, Double(frame) / 12), phase: .changed)
            {
                triggers.append(frame)
            }
        }
        #expect(triggers == [4])
        #expect(detector.update(timestamp: 0.13, zoom: 1.5, phase: .ended) == false)
        #expect(detector.update(timestamp: 0.14, zoom: 1.2, phase: .changed) == false)
        _ = detector.update(timestamp: 1, zoom: 3, phase: .began)
        #expect(detector.update(timestamp: 1.04, zoom: 2.4, phase: .changed) == true)
    }

    @Test("速くても15%未満の小さな縮小では戻らない")
    func smallChange() {
        var detector = PinchFlickDetector()
        _ = detector.update(timestamp: 0, zoom: 3, phase: .began)
        #expect(detector.update(timestamp: 0.01, zoom: 2.56, phase: .changed) == false)
        #expect(detector.update(timestamp: 0.02, zoom: 2.55, phase: .changed) == true)
    }

    @Test("開始時が105%以下なら素早く閉じても戻らない", arguments: [1.0, 1.05])
    func startsNearFit(start: Double) {
        var detector = PinchFlickDetector()
        _ = detector.update(timestamp: 0, zoom: start, phase: .began)
        #expect(detector.update(timestamp: 0.04, zoom: start * 0.8, phase: .changed) == false)
    }

    @Test("100msより前の速い縮小を引きずらず時間窓の境界を補間する")
    func rollingWindow() {
        var detector = PinchFlickDetector()
        _ = detector.update(timestamp: 0, zoom: 3, phase: .began)
        #expect(detector.update(timestamp: 0.01, zoom: 2.6, phase: .changed) == false)
        #expect(detector.update(timestamp: 0.15, zoom: 2.5, phase: .changed) == false)
        #expect(detector.update(timestamp: 0.20, zoom: 1.9, phase: .changed) == true)
    }

    @Test("同時刻と逆順の記録では発動せずキャンセル後も次の開始まで発動しない")
    func invalidTimeAndCancellation() {
        var detector = PinchFlickDetector()
        _ = detector.update(timestamp: 1, zoom: 3, phase: .began)
        #expect(detector.update(timestamp: 1, zoom: 2, phase: .changed) == false)
        #expect(detector.update(timestamp: 0.9, zoom: 2, phase: .changed) == false)
        #expect(detector.update(timestamp: 1.01, zoom: 3, phase: .cancelled) == false)
        #expect(detector.update(timestamp: 1.02, zoom: 2, phase: .changed) == false)
    }

    @Test("ゴムの写像は100%以上を変えず100%未満では抵抗して80%を下回らない")
    func rubberBand() {
        for zoom in [1.0, 1.5, 3, 6] { #expect(PinchZoom.rubberBand(zoom) == zoom) }
        var previous = 0.8
        for step in 0...100 {
            let raw = Double(step) / 100
            let displayed = PinchZoom.rubberBand(raw)
            #expect(displayed >= 0.8 && displayed <= 1)
            #expect(displayed >= raw)
            #expect(displayed >= previous)
            previous = displayed
        }
        #expect(1 - PinchZoom.rubberBand(0.99) < 0.01)
        #expect(PinchZoom.rubberBand(0.000001) < 0.81)
    }

    @Test("ゴムの途中から新しいピンチを始めても倍率が跳ねない", arguments: [0.01, 0.3, 0.9, 1, 3])
    func rubberInverse(raw: Double) {
        let displayed = PinchZoom.rubberBand(raw)
        #expect(abs(PinchZoom.fingerZoom(for: displayed) - raw) < 0.000001)
    }

    @Test("戻る補間は始点と終点が一致し紙の両端が窓の内側に入らない", arguments: [0.0, -125, -200])
    func returnGeometry(start: Double) {
        let animation = PinchZoom.Return(startZoom: 3)
        #expect(animation.zoom(elapsed: 0) == 3)
        #expect(animation.zoom(elapsed: 0.28) == 1)
        #expect(animation.position(start: start, end: 0, zoom: 3) == start)
        #expect(animation.position(start: start, end: 0, zoom: 1) == 0)
        for frame in 0...28 {
            let zoom = animation.zoom(elapsed: Double(frame) / 100)
            let origin = animation.position(start: start, end: 0, zoom: zoom)
            #expect(origin <= 0.000001)
            #expect(origin + 100 * zoom >= 100 - 0.000001)
        }
    }

    @Test("ゴムからの戻りも単調に100%へ到着する")
    func rubberReturn() {
        let animation = PinchZoom.Return(startZoom: 0.8)
        #expect(animation.zoom(elapsed: 0) == 0.8)
        #expect(animation.zoom(elapsed: 0.14) > 0.9)
        #expect(animation.zoom(elapsed: 0.28) == 1)
        #expect(animation.position(start: 10, end: 0, zoom: 0.9) > 0)
        #expect(animation.position(start: 10, end: 0, zoom: 1) == 0)
    }
}
