import Foundation
import ImageIO
import Testing

@testable import Snapshots

private let limits = Tolerance(channel: 8, areaRatio: 0.0005, tile: 8, luminance: 12, shiftPt: 0.5)

@Test("撮影したPNGからキー状態と試行回数と実倍率を読み戻せる")
func pngObservation() throws {
    let canvas = try #require(
        CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let image = try #require(canvas.makeImage())
    let observation = CaptureObservation(isKeyWindow: true, appActive: true, attempts: 3, stable: true)
    let data = try observation.png(image: image, scale: 2)
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
    #expect(try CaptureObservation.read(pngProperties: properties) == observation)
    let dpi = try #require(properties[kCGImagePropertyDPIWidth as String] as? Double)
    #expect(abs(dpi - 144) < 0.1)
}

@Test("撮影情報のない従来のUIケースもそのまま読める")
func legacyCase() throws {
    let json = #"{"item":{"id":"window","kind":"ui","arguments":[],"tags":[]},"scale":2,"settingsRecords":[]}"#
    let entry = try JSONDecoder().decode(RunCase.self, from: Data(json.utf8))
    #expect(entry.scale == 2 && entry.capture == nil)
}

@Test("画面の原点や窓の移動に関わらず子窓を同じ画素に合成する")
func geometry() throws {
    let root = CGRect(x: -100.25, y: 80.25, width: 100, height: 80)
    let popup = CGRect(x: -20.25, y: 70.25, width: 50, height: 40)
    for (dx, dy) in [(0.0, 0.0), (123.25, -97.5)] {
        let frames = [root, popup].map { $0.offsetBy(dx: dx, dy: dy) }
        let layout = try #require(CaptureGeometry(root: frames[0], layers: frames, scale: 2))
        #expect(layout.size == CGSize(width: 260, height: 180))
        #expect(
            layout.destinations == [
                CGRect(x: 0, y: 0, width: 200, height: 160),
                CGRect(x: 160, y: 100, width: 100, height: 80),
            ])
    }
}

@Test("透明な角と子窓の下は不透明な灰色で子窓は親窓の手前に描かれる")
func opaqueBackdrop() throws {
    let root = CGRect(x: 0, y: 0, width: 2, height: 2)
    let popup = CGRect(x: 1, y: 0, width: 2, height: 1)
    let layout = try #require(CaptureGeometry(root: root, layers: [root, popup], scale: 1))
    let canvas = try layout.makeCanvas()
    let space = try #require(canvas.colorSpace)
    let backing = try #require(
        CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    backing.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
    backing.fill(root)
    backing.clear(CGRect(x: 0, y: 1, width: 1, height: 1))
    canvas.draw(try #require(backing.makeImage()), in: layout.destinations[0])
    backing.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
    backing.fill(root)
    canvas.draw(try #require(backing.makeImage()), in: layout.destinations[1])
    let data = try #require(canvas.makeImage()?.dataProvider?.data) as Data
    let red: [UInt8] = [255, 0, 0, 255]
    let blue: [UInt8] = [0, 0, 255, 255]
    let gray: [UInt8] = [224, 224, 224, 255]
    #expect(Array(data) == [gray, blue, blue, red, red, gray].flatMap { $0 })
}

@Test("直前の画像だけを照合し初めて連続一致した撮影で止まる")
@MainActor func stabilizes() async throws {
    var samples = [1, 2, 1, 1, 3]
    var pauses = 0
    let result = try await CaptureSequence.settle {
        samples.removeFirst()
    } matches: {
        $0 == $1
    } pause: {
        pauses += 1
    }
    #expect(result.stable && result.frame == 1 && result.attempts == 4 && pauses == 3)
}

@Test("5回一致しなければ最後の画像と不安定判定を返す")
@MainActor func exhaustsAttempts() async throws {
    var i = 0
    let result = try await CaptureSequence.settle {
        i += 1
        return i
    } matches: {
        $0 == $1
    } pause: {
    }
    #expect(!result.stable && result.frame == 5 && result.attempts == 5)
}

@Test("不安定なUIの画像差はレポートに残し承認を止める")
func unstableReport() throws {
    let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: base) }
    let dir = base.appendingPathComponent(".runs/test")
    let item = SnapshotCase(id: "window", kind: .ui, input: nil, arguments: [], tags: [])
    let output = dir.appendingPathComponent(item.id)
    let visual = base.appendingPathComponent(".baseline-visual/2x")
    for folder in [output, visual] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
    let name = visualName(item, scale: 2)
    try Imaging.save(Raster(width: 1, height: 1, bytes: [0, 0, 0, 255]), output.appendingPathComponent(name))
    try Imaging.save(Raster(width: 1, height: 1, bytes: [255, 255, 255, 255]), visual.appendingPathComponent(name))
    let capture = RunCase(
        item: item, scale: 2, capture: .init(isKeyWindow: false, appActive: false, attempts: 5, stable: false))
    let run = Run(commit: "fixture", dirty: false, appVersion: "1", macOS: "fixture", displayScale: 2, cases: [capture])
    let report = try makeReport(base: base, dir: dir, run: run, tolerance: limits)
    #expect(report.counts == ["unstable": 1] && report.fails)
    #expect(report.cases[0].regression?.metrics.changedAreaRatio == 1)
    #expect(try readBack(run).cases.first?.capture == capture.capture)
    #expect(throws: SnapshotError.self) {
        try promote(base: base, dir: dir, run: run, rows: [capture], report: report, ref: nil)
    }
}

private func readBack(_ run: Run) throws -> Run {
    try JSONDecoder().decode(Run.self, from: encoded(run))
}

@Test("自己検査は1階調の差と上下左右の欠けを画素数と外接矩形に含める")
func exactBounds() throws {
    var a = try Raster(width: 3, height: 2, bytes: Array(repeating: 255, count: 24))
    let b = a
    a.bytes[4] -= 1
    a.bytes[21] -= 1
    let diff = ExactDifference(a, b)
    #expect(diff.pixels == 2 && diff.bounds == Region(x: 1, y: 0, width: 2, height: 2))
    let narrow = try Raster(width: 2, height: 3, bytes: Array(repeating: 255, count: 24))
    let resized = ExactDifference(b, narrow)
    #expect(resized.pixels == 4 && resized.bounds == Region(x: 0, y: 0, width: 3, height: 3))
}

@Test("自己検査の保存済み撮影は通常のrunか自己検査の各巡だけを指定できる")
func savedPasses() {
    for name in ["run-a", "selfcheck-a/first", "selfcheck-a/second"] { #expect(validSelfCheckRun(name)) }
    for name in ["../first", "run-a/first", "selfcheck-a/../first", "selfcheck-a/", "/second"] {
        #expect(!validSelfCheckRun(name))
    }
}

@Test("自己検査は許容内でも生の差を残し、面積・局所輝度・画像寸法の超過を落とす")
func selfCheckThresholds() throws {
    let white = try Raster(width: 40, height: 50, bytes: Array(repeating: 255, count: 8000))
    func compare(_ current: Raster, _ tolerance: Tolerance = limits) throws -> SelfCheckRow {
        var row = SelfCheckRow(id: "window")
        try row.compare(white, current, tolerance: tolerance)
        return row
    }
    var image = white
    image.bytes[4] = 254
    let noise = try compare(image)
    #expect(noise.pixelStatus == .noise && !noise.fails && noise.metrics?.different == 0)
    #expect(noise.difference?.pixels == 1 && noise.difference?.bounds == Region(x: 1, y: 0, width: 1, height: 1))
    image.bytes[4] = 240
    #expect(try compare(image).pixelStatus == .noise)  // One pixel is exactly the allowed area.
    image.bytes[8] = 240
    #expect(try compare(image).fails)
    let local = Tolerance(channel: 8, areaRatio: 1, tile: 1, luminance: 12, shiftPt: 0.5)
    image.bytes[4] = 0
    #expect(try compare(image, local).pixelStatus == .changed)
    let smaller = try Raster(width: 40, height: 49, bytes: Array(repeating: 255, count: 7840))
    #expect(try compare(smaller).fails)
}

@Test("自己検査は非アクティブでも画素が一致すれば成功し片方の撮影漏れは失敗する")
func backgroundSelfCheck() throws {
    let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: base) }
    let first = base.appendingPathComponent("first")
    let second = base.appendingPathComponent("second")
    let item = SnapshotCase(id: "window", kind: .ui, input: nil, arguments: [], tags: [])
    let canvas = try #require(
        CGContext(
            data: nil, width: 3, height: 2, bitsPerComponent: 8, bytesPerRow: 12,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let image = try #require(canvas.makeImage())
    for (index, dir) in [first, second].enumerated() {
        let capture = CaptureObservation(
            isKeyWindow: index == 0, appActive: index == 0, attempts: 2 + index, stable: true)
        let row = RunCase(item: item, scale: 2, capture: capture)
        let run = Run(commit: "fixture", dirty: false, appVersion: "1", macOS: "fixture", displayScale: 2, cases: [row])
        let folder = dir.appendingPathComponent(item.id)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try write(try encoded(run), dir.appendingPathComponent("run.json"))
        try write(try capture.png(image: image, scale: 2), folder.appendingPathComponent(visualName(item, scale: 2)))
    }
    let result = try selfCheck([item], first: first, second: second, tolerance: limits)
    #expect(result.count == 1 && !result[0].fails && result[0].difference?.bounds == nil)
    let runFile = second.appendingPathComponent("run.json")
    var run = try read(Run.self, runFile)
    run.displayScale = 1
    try write(try encoded(run), runFile)
    #expect(throws: SnapshotError.self) { try selfCheck([item], first: first, second: second, tolerance: limits) }
    let forced = try selfCheck([item], first: first, second: second, tolerance: limits, forceScale: true)
    #expect(forced[0].pixelStatus == .identical)
    run.displayScale = 2
    try write(try encoded(run), runFile)
    let baseline = try ScaleBaseline(base: base, scale: 2)
    try write(try encoded(["window": "fixture"]), baseline.visual.appendingPathComponent("sources.json"))
    let color: [UInt8] = [255, 0, 0, 255]
    let red = Array(repeating: color, count: 6).flatMap { $0 }
    let different = try Raster(width: 3, height: 2, bytes: red)
    try Imaging.save(different, baseline.visual.appendingPathComponent(visualName(item, scale: 2)))
    let regression = try selfCheck([item], first: first, second: second, tolerance: limits, baselineRoot: base)
    #expect(regression[0].pixelStatus == .identical && regression[0].fails)
    run.cases[0].capture?.readinessIssue = "waiting for theme"
    try write(try encoded(run), runFile)
    let pending = try selfCheck([item], first: first, second: second, tolerance: limits)[0]
    #expect(pending.pixelStatus == .identical && pending.fails && pending.issues == ["pass 2: waiting for theme"])
    try fm.removeItem(at: second.appendingPathComponent(item.id))
    let missing = try selfCheck([item], first: first, second: second, tolerance: limits)[0]
    #expect(missing.pixelStatus == nil && missing.fails)
}

@Test("同じ画素なら実際のキー状態もアクティブ状態も安定判定に影響しない")
@MainActor func focusIsDiagnostic() async throws {
    let root = CGRect(x: 0, y: 0, width: 2, height: 2)
    let canvas = try #require(CaptureGeometry(root: root, layers: [root], scale: 1)).makeCanvas()
    let image = try #require(canvas.makeImage())
    let bytes = try #require(image.dataProvider?.data)
    var key = true
    let result = try await CaptureSequence.settle {
        defer { key.toggle() }
        return CaptureFrame(image: image, pixels: bytes, scale: 1, key: key, active: key, complete: true)
    } matches: {
        $0.matches($1)
    } pause: {
    }
    #expect(result.stable && result.attempts == 2 && !result.frame.key && !result.frame.active)
}

@Test("最初のタイムアウトを記録し再試行の成功を残す")
func recoveredTimeout() throws {
    var entry = RunCase(item: SnapshotCase(id: "settings", kind: .ui, input: nil, arguments: [], tags: []))
    var attempts: [Int] = []
    try retryTimeout(entry: &entry) { attempt in
        attempts.append(attempt)
        if attempt == 1 {
            throw AttemptTimeout(
                record: TimeoutRecord(readiness: "Waiting for Settings", sample: "timeout-sample.txt", diagnostic: nil),
                reason: "Timed out after 60 seconds")
        }
    }
    #expect(attempts == [1, 2] && entry.timeouts == 1 && entry.retrySucceeded == true)
    #expect(entry.timeoutDetails?.first?.readiness == "Waiting for Settings")
}

@Test("二度目のタイムアウトで失敗し、他のエラーは再試行しない")
func exhaustedTimeout() throws {
    var entry = RunCase(item: SnapshotCase(id: "settings", kind: .ui, input: nil, arguments: [], tags: []))
    #expect(throws: SnapshotError.self) {
        try retryTimeout(entry: &entry) { _ in
            throw AttemptTimeout(
                record: TimeoutRecord(readiness: nil, sample: nil, diagnostic: "no PID"), reason: "timeout")
        }
    }
    #expect(entry.timeouts == 2 && entry.retrySucceeded == false && entry.timeoutDetails?.count == 2)
    var launches = 0
    #expect(throws: SnapshotError.self) {
        try retryTimeout(entry: &entry) { _ in
            launches += 1
            throw SnapshotError("capture error")
        }
    }
    #expect(launches == 1)
}

@Test("応答を返さない描画コールバックも期限で抜け、待っていた段階を識別できる")
@MainActor func captureDeadline() async throws {
    var callback: CheckedContinuation<Void, Never>?
    defer { callback?.resume() }
    do {
        try await CaptureSequence.bounded("window image", limit: .milliseconds(20)) {
            await withCheckedContinuation { callback = $0 }
        }
        Issue.record("応答していないのに撮影が成功した")
    } catch let timeout as SnapshotDeadline {
        #expect(timeout.stage == "window image")
    }
    #expect(try await CaptureSequence.bounded("ready", limit: .seconds(1)) { 42 } == 42)
}
