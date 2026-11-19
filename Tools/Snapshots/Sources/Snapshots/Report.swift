import Foundation

struct ScaleBaseline {
    let scale: Double
    let numeric: URL
    let visual: URL

    init(base: URL, scale: Double) throws {
        guard scale.isFinite, scale > 0 else { throw SnapshotError("Invalid main display scale") }
        self.scale = scale
        let folder = (Int(exactly: scale).map(String.init) ?? String(scale)) + "x"
        numeric = base.appendingPathComponent("baseline/" + folder)
        visual = base.appendingPathComponent(".baseline-visual/" + folder)
    }

    var hasVisual: Bool { fm.fileExists(atPath: visual.appendingPathComponent("sources.json").path) }
    var exists: Bool { hasVisual || fm.fileExists(atPath: numeric.appendingPathComponent("environment.json").path) }
}

struct CaseReport: Codable {
    let id: String
    let kind: Kind
    let tags: [String]
    var status: Status = .unbaselined
    var capture: CaptureObservation?
    var notes: [String] = []
    var regression: Comparison?
    var fidelity: Comparison?
    var previousFidelity: Magnitude?
    var trend: String?
    var referenceError: String?
    var visualSource: String?
}
struct Report: Codable {
    var cases: [CaseReport]
    var tolerances: Tolerance
    let counts: [String: Int]
    let runScale: Double
    let baselineScale: Double?
    init(cases: [CaseReport], tolerances: Tolerance, runScale: Double, baselineScale: Double?) {
        self.runScale = runScale
        self.baselineScale = baselineScale
        self.cases = cases
        self.tolerances = tolerances
        counts = Dictionary(grouping: cases, by: { $0.status.rawValue }).mapValues(\.count)
    }
    var exitCode: Int32 { baselineScale == nil ? 3 : fails ? 1 : 0 }
    var fails: Bool { cases.contains { [.changed, .unstable, .error, .unbaselined].contains($0.status) } }
}

func trend(_ old: Magnitude, _ new: Magnitude) -> String {
    func values(_ m: Magnitude) -> [Double] {
        [
            Double(abs(m.pageDelta)), m.maxShiftPt, m.maxBoxDeltaPt, m.changedAreaRatio, m.maxLuminance,
            Double(m.textEdits),
            Double(m.lineCountChangedPages), Double(m.repaginatedLines), m.dimensionsChanged ? 1 : 0,
        ]
    }
    let pairs = zip(values(old), values(new))
    let up = pairs.contains { $0 < $1 }
    let down = pairs.contains { $0 > $1 }
    return up && down ? "mixed" : up ? "worse" : down ? "better" : "unchanged"
}

private func comparison(
    item: RunCase, out: URL, oldFile: URL?, old: Document?, current: Document?,
    prefix: String, tolerance: Tolerance
) throws -> Comparison {
    let isUI = item.item.kind == .ui
    let pdf = try oldFile.flatMap { isUI ? nil : try PDFInput($0) }
    let layout = try old ?? pdf?.document()
    var result = Comparison()
    if let layout, let current { result = compareLayout(layout, current) }
    let imagesBefore = pdf?.pdf.pageCount ?? (oldFile == nil ? 0 : 1)
    let currentCount = current?.pageCount ?? 1
    if let pdf, imagesBefore != currentCount {
        // The visual ref can differ from the independently approved numeric baseline.
        result.metrics.dimensionsChanged = true
        if old == nil { result.metrics.pageDelta = currentCount - pdf.pdf.pageCount }
    }
    for i in 0..<max(layout?.pageCount ?? 0, imagesBefore, currentCount) {
        let page = try autoreleasepool {
            var page = PageComparison(number: i + 1)
            page.beforeLayout = layout.flatMap { $0.pages.indices.contains(i) ? $0.pages[i] : nil }
            page.currentLayout = current.flatMap { $0.pages.indices.contains(i) ? $0.pages[i] : nil }
            let name = isUI ? visualName(item.item, scale: item.scale) : pageFile(i)
            if i < currentCount { page.current = item.item.id + "/" + name }
            guard let oldFile, i < imagesBefore else { return page }
            let before = try pdf?.raster(i) ?? Imaging.load(oldFile)
            let baseline = prefix + "-" + pageFile(i)
            try Imaging.save(before, out.appendingPathComponent(baseline))
            page.before = item.item.id + "/" + baseline
            if i < currentCount {
                let after = try Imaging.load(out.appendingPathComponent(name))
                let (diff, overlay) = try diffPixels(before, after, tolerance)
                let overlayName = prefix + "-diff-" + pageFile(i)
                try Imaging.save(overlay, out.appendingPathComponent(overlayName))
                page.overlay = item.item.id + "/" + overlayName
                page.pixels = diff
                result.metrics.include(diff)
            }
            return page
        }
        result.pages.append(page)
    }
    return result
}

func makeReport(base: URL, dir: URL, run: Run, tolerance: Tolerance) throws -> Report {
    let baseline = try ScaleBaseline(base: base, scale: run.displayScale)
    let available = baseline.exists
    let visuals = baseline.visual
    let sources = try visualSources(visuals)
    var cases: [CaseReport] = []
    for capture in run.cases {
        let item = capture.item
        let out = dir.appendingPathComponent(item.id)
        var row = CaseReport(id: item.id, kind: item.kind, tags: item.tags, capture: capture.capture)
        if let timeouts = capture.timeouts, timeouts > 0 {
            row.notes.append(
                "Timeouts: \(timeouts), retry succeeded: \(capture.retrySucceeded == true). See run.json and timeout-sample files in the case folder."
            )
        }
        do {
            if let error = capture.error { throw SnapshotError(error) }
            if let unavailable = capture.unavailable { throw SnapshotError(unavailable) }
            let numeric = baseline.numeric.appendingPathComponent(item.id + ".json")
            let old = fm.fileExists(atPath: numeric.path) ? try read(Document.self, numeric) : nil
            if let old {
                let text = try Data(contentsOf: numeric.deletingPathExtension().appendingPathExtension("txt"))
                guard digest(text) == old.textSHA256, text == Data(old.text.utf8) else {
                    throw SnapshotError("Baseline .txt and .json differ")
                }
            }
            let current =
                item.kind == .document ? try read(Document.self, out.appendingPathComponent("document.json")) : nil
            let name = visualName(item, scale: capture.scale)
            let visual = visuals.appendingPathComponent(name)
            let exists = fm.fileExists(atPath: visual.path)
            row.visualSource = sources[name]
            row.regression = try comparison(
                item: capture, out: out, oldFile: exists ? visual : nil, old: old, current: current,
                prefix: "baseline", tolerance: tolerance)
            row.status = row.regression?.metrics.classify(tolerance) ?? .unbaselined
            if !available { row.status = .unbaselined }
            if available && item.kind == .document && old == nil {
                row.notes.append(
                    exists
                        ? "No approved numeric baseline; layout and text are from the visual reference PDF"
                        : "No approved numeric baseline")
                if row.status != .changed { row.status = .unbaselined }
            }
            if available && !exists {
                row.notes.append(
                    sources[item.id]
                        ?? "No matching visual baseline. Run make snapshots-baseline REF=<ref> or approve a reviewed run."
                )
                if item.kind == .ui { row.status = .unavailable }
            }
            if item.kind == .ui, let observation = capture.capture {
                row.notes.append(
                    "Capture: \(observation.attempts) attempts, key window: \(observation.isKeyWindow), active app: \(observation.appActive)"
                )
                if !observation.stable { row.status = .unstable }
            }
            if item.tags.contains("theme"), let current, current.pageCount != 1 {
                row.notes.append("Expected a one-page theme specimen; captured \(current.pageCount) pages")
                row.status = .changed
            }
            if let ref = item.reference {
                let url = base.appendingPathComponent("reference/latex/" + ref + ".pdf")
                if fm.fileExists(atPath: url.path) {
                    do {
                        let doc = try PDFInput(url).document()
                        row.fidelity = try comparison(
                            item: capture, out: out, oldFile: url, old: doc, current: current,
                            prefix: "reference", tolerance: tolerance)
                        row.previousFidelity = old?.fidelity
                        if let previous = row.previousFidelity, let latest = row.fidelity?.metrics {
                            row.trend = trend(previous, latest)
                        }
                    } catch { row.referenceError = String(describing: error) }
                } else {
                    row.notes.append("No real-TeX reference")
                }
            }
        } catch {
            row.status = .error
            row.notes.append(String(describing: error))
        }
        cases.append(row)
    }
    func magnitude(_ row: CaseReport) -> [Double] {
        let m = row.regression?.metrics ?? Magnitude()
        return [
            row.status == .error || row.status == .unstable
                ? 3 : row.status == .changed ? 2 : row.status == .unbaselined ? 1 : 0,
            Double(abs(m.pageDelta)), Double(m.textEdits), max(m.maxShiftPt, m.maxBoxDeltaPt), m.changedAreaRatio,
            m.maxLuminance,
        ]
    }
    cases.sort {
        let a = magnitude($0)
        let b = magnitude($1)
        return a == b ? $0.id < $1.id : b.lexicographicallyPrecedes(a)
    }
    return Report(
        cases: cases, tolerances: tolerance, runScale: run.displayScale,
        baselineScale: available ? run.displayScale : nil)
}

func visualSources(_ directory: URL) throws -> [String: String] {
    let file = directory.appendingPathComponent("sources.json")
    return fm.fileExists(atPath: file.path) ? try read([String: String].self, file) : [:]
}
func summary(_ report: Report) {
    print(
        "Run: \(report.runScale)× · baseline: "
            + (report.baselineScale.map { "\($0)×" } ?? "none for this scale; review this run before approving"))
    print("status        Δpages   max pt    area %   text ±   case / TeX fidelity")
    for row in report.cases {
        if report.baselineScale == nil && row.status == .unbaselined && row.fidelity == nil && row.referenceError == nil
        {
            continue
        }
        let m = report.baselineScale == nil ? nil : row.regression?.metrics
        let values =
            m.map {
                String(
                    format: "%+6d  %7.1f  %8.3f  %7d", $0.pageDelta, $0.maxShiftPt, $0.changedAreaRatio * 100,
                    $0.textEdits)
            } ?? "     —        —         —        —"
        let fidelity =
            row.fidelity.map {
                String(
                    format: " · TeX Δp %+d, %.1f pt, %.3f%% · %@", $0.metrics.pageDelta, $0.metrics.maxShiftPt,
                    $0.metrics.changedAreaRatio * 100, row.trend ?? "first comparison")
            } ?? ""
        let status = report.baselineScale == nil && row.status == .unbaselined ? "TeX" : row.status.rawValue
        print("\(status.padding(toLength:12,withPad:" ",startingAt:0)) \(values)   \(row.id)\(fidelity)")
    }
    print(report.counts.keys.sorted().map { "\($0) \(report.counts[$0,default:0])" }.joined(separator: " · "))
}
