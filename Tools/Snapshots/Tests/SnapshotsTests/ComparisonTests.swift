import CoreGraphics
import Foundation
import Testing

@testable import Snapshots

private let tolerance = Tolerance(channel: 8, areaRatio: 0.0005, tile: 8, luminance: 12, shiftPt: 0.5)

@Test("閾値内の画素差をノイズと区別する")
func noise() throws {
    let a = try Raster(width: 2, height: 1, bytes: [100, 100, 100, 255, 100, 100, 100, 255])
    var b = a
    b.bytes[0] = 108
    let (m, _) = try diffPixels(a, b, tolerance)
    #expect(m.anyDifference)
    #expect(m.different == 0)
    #expect(m.regions.isEmpty)
    #expect(m.maxLuminance < 1)
    #expect(Magnitude(anyPixelDifference: true).classify(tolerance) == .noise)
    #expect(Magnitude().classify(tolerance) == .identical)
}

@Test("離れた変更を別の矩形にまとめて原寸で重ねる")
func regions() throws {
    let a = try Raster(width: 40, height: 12, bytes: .init(repeating: 255, count: 40 * 12 * 4))
    var b = a
    for (x, y) in [(7, 3), (8, 4), (37, 10)] { b.bytes[(y * 40 + x) * 4] = 0 }
    let (m, overlay) = try diffPixels(a, b, tolerance)
    #expect(m.different == 3)
    #expect(m.regions == [Region(x: 7, y: 3, width: 2, height: 2), Region(x: 37, y: 10, width: 1, height: 1)])
    #expect(m.ratio == 3.0 / 480)
    #expect(overlay.channel(37, 10, 1) == 85)
    let smaller = try Raster(width: 39, height: 12, bytes: .init(repeating: 255, count: 39 * 12 * 4))
    #expect(try diffPixels(a, smaller, tolerance).0.dimensionsChanged)
}

private func doc(_ lines: [(String, Double)]) -> Document {
    let page = Page(
        width: 80, height: 120, lineCount: lines.count,
        lines: lines.map {
            Line(text: $0.0, x: 4, y: $0.1, width: 30, height: 8)
        })
    var d = Document(pages: [page], pageCount: 1, textSHA256: "", fonts: [])
    d.textSHA256 = digest(Data(d.text.utf8))
    return d
}

@Test("同じ文が二度出ても別々に位置を照合し追加と削除を残す")
func movement() {
    let old = doc([("same", 10), ("old", 25), ("same", 40)])
    let new = doc([("same", 10), ("new", 25), ("same", 41.2)])
    let diff = compareLayout(old, new)
    #expect(diff.moves == [Move(text: "same", fromPage: 1, toPage: 1, dx: 0, dy: 1.2)])
    #expect(diff.edits.map(\.operation) == ["-", "+"])
    #expect(diff.metrics.textEdits == 2)
    #expect(diff.metrics.classify(tolerance) == .changed)
    #expect(Magnitude(maxShiftPt: 0.5, layoutChanged: true).classify(tolerance) == .noise)
    #expect(Magnitude(maxShiftPt: 0.6).classify(tolerance) == .changed)
    #expect(Magnitude(pageDelta: 1).classify(tolerance) == .changed)
    #expect(Magnitude(maxLuminance: 13).classify(tolerance) == .changed)
}

@Test("実TeXとの照合では行番号を柱や表の数字と取り違えず本文の改ページは数える")
func referenceNumbers() {
    func page(_ entries: [(String, Double, Double)]) -> Page {
        Page(
            width: 600, height: 840, lineCount: entries.count,
            lines: entries.map { Line(text: $0.0, x: $0.1, y: $0.2, width: 10, height: 9) })
    }
    let old = Document(
        pages: [page([("3", 375, 440), ("1", 295, 787), ("x = 27", 90, 750)]), page([])],
        pageCount: 2, textSHA256: "", fonts: [])
    let new = Document(
        pages: [
            page([("1", 78, 166), ("3", 78, 195), ("3", 375, 438), ("1", 295, 790)]),
            page([("x = 27", 90, 70), ("1", 78, 120)]),
        ], pageCount: 2, textSHA256: "", fonts: [])
    let result = compareLayout(old, new, texReference: true)
    #expect(
        result.moves == [
            Move(text: "3", fromPage: 1, toPage: 1, dx: 0, dy: -2),
            Move(text: "1", fromPage: 1, toPage: 1, dx: 0, dy: 3),
            Move(text: "x = 27", fromPage: 1, toPage: 2, dx: 0, dy: -680),
        ])
    #expect(result.metrics.maxShiftPt == 680 && result.metrics.repaginatedLines == 1)
    #expect(result.edits.map(\.text) == compareLayout(old, new).edits.map(\.text))
    #expect(compareLayout(new, old, texReference: true).metrics.maxShiftPt == 680)
}

@Test("参照PDFで再現する旧方式の行移動だけを換算して承認済み画像の差を保つ")
func approvedReferenceNumbers() {
    let reference = doc([("1", 116)])
    var approved = doc([("1", 30), ("1", 117)])
    var stored = compareLayout(reference, approved).metrics
    stored.changedAreaRatio = 0.02
    approved.fidelity = stored
    #expect(comparableFidelity(of: approved, against: reference)?.maxShiftPt == 1)
    #expect(comparableFidelity(of: approved, against: reference)?.changedAreaRatio == 0.02)
    #expect(comparableFidelity(of: approved, against: doc([("1", 102)])) == stored)
}

@Test("マニフェストの重複・出力引数・パス逸脱を拒む")
func manifest() throws {
    let item = SnapshotCase(id: "test", kind: .document, input: "Samples/sample.md", arguments: [], tags: ["sample"])
    let parsed = try SnapshotCase.parse(encoded([item]))
    #expect(try select(parsed, only: ["tag:sample", "test"]).count == 1)
    #expect(throws: SnapshotError.self) { try SnapshotCase.parse(encoded([item, item])) }
    var bad = item
    bad.arguments = ["-SurimonoService", "print"]
    #expect(throws: SnapshotError.self) { try SnapshotCase.parse(encoded([bad])) }
    bad.arguments = []
    bad.input = "Samples/../../private"
    #expect(throws: SnapshotError.self) { try SnapshotCase.parse(encoded([bad])) }
    #expect(throws: SnapshotError.self) { try select(parsed, only: ["missing"]) }
}

@Test("レポートの JSON は安定し忠実度の変化だけでは失敗しない")
func reportJSON() throws {
    var row = CaseReport(id: "latex-001", kind: .document, tags: ["latex"], status: .identical)
    row.fidelity = Comparison(metrics: Magnitude(pageDelta: 2))
    let report = Report(cases: [row], tolerances: tolerance, runScale: 2, baselineScale: 2)
    #expect(!report.fails)
    let first = try encoded(report)
    let next = try JSONDecoder().decode(Report.self, from: first)
    #expect(try encoded(next) == first)
    #expect(next.cases.first?.fidelity?.metrics.pageDelta == 2)
    #expect(trend(Magnitude(maxShiftPt: 3), Magnitude(maxShiftPt: 1)) == "better")
}

@Test("合成 PDF のページ寸法と色の位置を保ち、承認の前後で同じ画像になる")
func pdfLifecycle() throws {
    let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: base) }
    let dir = base.appendingPathComponent(".runs/test")
    let out = dir.appendingPathComponent("paper")
    try fm.createDirectory(at: out, withIntermediateDirectories: true)
    let file = out.appendingPathComponent("document.pdf")
    var box = CGRect(x: 0, y: 0, width: 72, height: 144)
    let context = try #require(CGContext(file as CFURL, mediaBox: &box, nil))
    context.beginPDFPage(nil)
    context.setFillColor(gray: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 108, width: 36, height: 36))
    context.endPDFPage()
    context.closePDF()
    let pdf = try PDFInput(file)
    let raster = try pdf.raster(0)
    #expect(raster.width == 100 && raster.height == 200)
    #expect(raster.channel(8, 8, 0) == 0)
    #expect(raster.channel(8, 192, 0) == 255)
    try Imaging.save(raster, out.appendingPathComponent(pageFile(0)))
    let doc = try pdf.document()
    #expect(doc.pageCount == 1 && doc.pages[0].width == 72)
    try write(try encoded(doc), out.appendingPathComponent("document.json"))
    try write(Data(doc.text.utf8), out.appendingPathComponent("document.txt"))
    try write(Data(contentsOf: file), base.appendingPathComponent("reference/latex/001.pdf"))
    let item = SnapshotCase(
        id: "paper", kind: .document, input: "Samples/sample.md", arguments: [], tags: [], reference: "001")
    let entry = RunCase(item: item)
    let run = Run(commit: "abc", dirty: false, appVersion: "1", macOS: "test", displayScale: 2, cases: [entry])
    let initial = try makeReport(base: base, dir: dir, run: run, tolerance: tolerance)
    #expect(initial.exitCode == 3 && initial.runScale == 2 && initial.baselineScale == nil)
    #expect(initial.cases[0].status == .unbaselined)
    #expect(initial.cases[0].fidelity?.metrics.pageDelta == 0)
    try promote(base: base, dir: dir, run: run, rows: [entry], report: initial, ref: nil)
    let next = try makeReport(base: base, dir: dir, run: run, tolerance: tolerance)
    #expect(next.cases[0].status == .identical)
    #expect(next.cases[0].regression?.pages[0].pixels?.different == 0)
    #expect(next.cases[0].fidelity?.pages[0].pixels?.ratio == 0)
    #expect(next.cases[0].trend == "unchanged")
    var external = run
    external.displayScale = 1
    let otherScale = try makeReport(base: base, dir: dir, run: external, tolerance: tolerance)
    #expect(otherScale.exitCode == 3 && otherScale.cases[0].previousFidelity == nil)
    #expect(otherScale.cases[0].fidelity?.pages[0].pixels?.different == 0)
    let before = try Data(contentsOf: base.appendingPathComponent("baseline/2x/paper.json"))
    try promote(base: base, dir: dir, run: external, rows: [entry], report: otherScale, ref: nil)
    #expect(try Data(contentsOf: base.appendingPathComponent("baseline/2x/paper.json")) == before)
    #expect(try makeReport(base: base, dir: dir, run: external, tolerance: tolerance).baselineScale == 1)
    #expect(fm.fileExists(atPath: base.appendingPathComponent(".baseline-visual/2x/paper.pdf").path))
    #expect(fm.fileExists(atPath: base.appendingPathComponent(".baseline-visual/1x/paper.pdf").path))
    try fm.removeItem(at: base.appendingPathComponent(".baseline-visual"))
    let portable = try makeReport(base: base, dir: dir, run: run, tolerance: tolerance)
    #expect(portable.cases[0].status == .identical)
    #expect(portable.cases[0].regression?.pages[0].before == nil)
}

@Test("UI の表示倍率が異なる画像を比較せず部分承認でも他の基準を保つ")
func scales() throws {
    let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: base) }
    let dir = base.appendingPathComponent(".runs/scale")
    let out = dir.appendingPathComponent("window")
    try fm.createDirectory(at: out, withIntermediateDirectories: true)
    let item = SnapshotCase(
        id: "window", kind: .ui, input: nil, arguments: ["-SurimonoSnapshotWelcome", "YES"], tags: ["ui"])
    var capture = RunCase(item: item, scale: 1)
    var run = Run(commit: "123", dirty: false, appVersion: "1", macOS: "test", displayScale: 1, cases: [capture])
    let pixel = try Raster(width: 1, height: 1, bytes: [50, 100, 150, 255])
    try Imaging.save(pixel, out.appendingPathComponent(visualName(item, scale: 1)))
    let first = try makeReport(base: base, dir: dir, run: run, tolerance: tolerance)
    try promote(base: base, dir: dir, run: run, rows: [capture], report: first, ref: nil)
    capture.scale = 2
    run.cases = [capture]
    try Imaging.save(pixel, out.appendingPathComponent(visualName(item, scale: 2)))
    let next = try makeReport(base: base, dir: dir, run: run, tolerance: tolerance)
    #expect(next.cases[0].status == .unavailable)
    #expect(next.cases[0].regression?.pages[0].pixels == nil)
    try promote(base: base, dir: dir, run: run, rows: [capture], report: next, ref: nil)
    for scale in [1.0, 2.0] {
        #expect(
            fm.fileExists(
                atPath: base.appendingPathComponent(".baseline-visual/1x/" + visualName(item, scale: scale)).path))
    }
}

@Test("カタログ全テーマと全サンプルに入力があり実 TeX の参照は読める")
func coverage() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let base = root.appendingPathComponent("Snapshots")
    let cases = try SnapshotCase.parse(Data(contentsOf: base.appendingPathComponent("cases.json")))
    let capabilities = try Capabilities(at: root)
    #expect(Set(cases.filter { $0.tags.contains("theme") }.map { String($0.id.dropFirst(6)) }) == capabilities.themes)
    let samples = try fm.contentsOfDirectory(
        at: root.appendingPathComponent("Samples"), includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
    #expect(
        Set(samples.map { "Samples/" + $0.lastPathComponent })
            == Set(cases.filter { $0.tags.contains("sample") }.compactMap(\.input)))
    let corpus = try read([CorpusEntry].self, base.appendingPathComponent("corpus/latex/manifest.json"))
    #expect(Set(corpus.map(\.id)) == Set(cases.compactMap(\.reference)))
    for item in cases {
        #expect(capabilities.missing(item) == nil)
        if let input = item.input { #expect(fm.fileExists(atPath: root.appendingPathComponent(input).path)) }
    }
    for url in try fm.contentsOfDirectory(
        at: base.appendingPathComponent("reference/latex"), includingPropertiesForKeys: nil)
    where url.pathExtension == "pdf" {
        let document = try PDFInput(url).document()
        #expect(document.pageCount > 0)
        #expect(!document.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}
