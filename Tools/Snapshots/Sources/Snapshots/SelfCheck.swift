import Foundation

// Accept only run IDs and the two pass directories produced by a self-check.
func validSelfCheckRun(_ path: String) -> Bool {
    let parts = path.components(separatedBy: "/")
    guard let id = parts.first, validID(id) else { return false }
    if parts.count == 1 { return true }
    return parts.count == 2 && id.hasPrefix("selfcheck-") && ["first", "second"].contains(parts[1])
}

struct ExactDifference: Codable, Equatable {
    let pixels: Int
    let bounds: Region?

    init(_ first: Raster, _ second: Raster) {
        var minX = Int.max
        var minY = Int.max
        var maxX = -1
        var maxY = -1
        var count = 0
        for y in 0..<max(first.height, second.height) {
            for x in 0..<max(first.width, second.width) {
                let inFirst = y < first.height && x < first.width
                let inSecond = y < second.height && x < second.width
                if !inFirst && !inSecond { continue }
                if inFirst && inSecond {
                    let i = (y * first.width + x) * 4
                    let j = (y * second.width + x) * 4
                    // Imaging decodes to opaque sRGB. The fourth byte is padding.
                    if first.bytes[i] == second.bytes[j] && first.bytes[i + 1] == second.bytes[j + 1]
                        && first.bytes[i + 2] == second.bytes[j + 2]
                    {
                        continue
                    }
                }
                count += 1
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        pixels = count
        bounds = count == 0 ? nil : Region(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}

struct ApprovedImageCheck: Codable {
    let pass: Int
    let status: Status
    let difference: ExactDifference
}

struct SelfCheckRow: Codable {
    let id: String
    var difference: ExactDifference?
    var pixelStatus: Status?
    var metrics: PixelMetrics?
    var approved: [ApprovedImageCheck] = []
    var issues: [String] = []
    var fails: Bool { !issues.isEmpty || (pixelStatus != .identical && pixelStatus != .noise) }
    var pixelLabel: String {
        pixelStatus == .noise ? "within tolerance" : pixelStatus?.rawValue ?? "no comparison"
    }

    mutating func compare(_ first: Raster, _ second: Raster, tolerance: Tolerance) throws {
        let exact = ExactDifference(first, second)
        difference = exact
        guard exact.pixels > 0 else {
            pixelStatus = .identical
            return
        }
        let (pixels, _) = try diffPixels(first, second, tolerance)
        metrics = pixels
        var magnitude = Magnitude()
        magnitude.include(pixels)
        pixelStatus = magnitude.classify(tolerance)
    }
}

func selfCheck(
    _ cases: [SnapshotCase], first: URL, second: URL, tolerance: Tolerance,
    baselineRoot: URL? = nil, forceScale: Bool = false
) throws -> [SelfCheckRow] {
    let dirs = [first, second]
    let runs = try dirs.map { try read(Run.self, $0.appendingPathComponent("run.json")) }
    guard forceScale || runs[0].displayScale == runs[1].displayScale else {
        throw SnapshotError(
            "Main display scales differ (\(runs[0].displayScale)× and \(runs[1].displayScale)×). Use FORCE_SCALE=1 for a diagnostic comparison."
        )
    }
    let baselines = try baselineRoot.map { root in
        try runs.map { try ScaleBaseline(base: root, scale: $0.displayScale) }
    }
    return cases.sorted { $0.id < $1.id }.map { item in
        var row = SelfCheckRow(id: item.id)
        do {
            var images: [Raster] = []
            var scales: [Double] = []
            for (index, run) in runs.enumerated() {
                guard let entry = run.cases.first(where: { $0.item.id == item.id }) else {
                    throw SnapshotError("pass \(index+1): missing case")
                }
                if let reason = entry.error ?? entry.unavailable ?? entry.capture?.readinessIssue {
                    row.issues.append("pass \(index+1): \(reason)")
                }
                guard let scale = entry.scale else { throw SnapshotError("pass \(index+1): missing display scale") }
                if entry.capture?.stable == false { row.issues.append("pass \(index+1): unstable") }
                scales.append(scale)
                let file = dirs[index].appendingPathComponent(item.id).appendingPathComponent(
                    visualName(item, scale: scale))
                let image = try Imaging.load(file)
                images.append(image)
                if let baseline = baselines?[index], baseline.hasVisual {
                    let approved = baseline.visual.appendingPathComponent(visualName(item, scale: scale))
                    guard fm.fileExists(atPath: approved.path) else {
                        row.issues.append("pass \(index+1): no approved image at capture scale \(scale)×")
                        continue
                    }
                    var comparison = SelfCheckRow(id: item.id)
                    try comparison.compare(Imaging.load(approved), image, tolerance: tolerance)
                    if let status = comparison.pixelStatus, let difference = comparison.difference {
                        row.approved.append(ApprovedImageCheck(pass: index + 1, status: status, difference: difference))
                        if status == .changed { row.issues.append("pass \(index+1): above baseline tolerance") }
                    }
                }
            }
            guard forceScale || scales[0] == scales[1] else { throw SnapshotError("Capture display scales differ") }
            try row.compare(images[0], images[1], tolerance: tolerance)
        } catch { row.issues.append(String(describing: error)) }
        return row
    }
}
