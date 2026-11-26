import CryptoKit
import Foundation

struct SnapshotError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

var fm: FileManager { .default }
func validID(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
}
func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
func encoded<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value) + Data([10])
}
func read<T: Decodable>(_ type: T.Type, _ file: URL) throws -> T {
    try JSONDecoder().decode(type, from: Data(contentsOf: file))
}
func write(_ data: Data, _ url: URL) throws {
    if fm.fileExists(atPath: url.path), try Data(contentsOf: url) == data { return }
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
}
func pt(_ n: Double) -> Double { (n * 10).rounded() / 10 }
func normalized(_ text: String) -> String {
    text.precomposedStringWithCanonicalMapping.split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

enum Kind: String, Codable { case document, ui }
struct SnapshotCase: Codable {
    var id: String
    var kind: Kind
    var input: String?
    var arguments: [String]
    var tags: [String]
    var reference: String?

    static func parse(_ data: Data) throws -> [Self] {
        let cases = try JSONDecoder().decode([Self].self, from: data)
        var seen = Set<String>()
        // Only presentation choices belong in the manifest. Output destinations and launch actions are owned by the runner.
        let allowed = Set([
            "-theme", "-SurimonoLayout", "-SurimonoTypeface", "-SurimonoComposition", "-SurimonoCatalogueSpecimen",
            "-SurimonoMenu", "-SurimonoPopover", "-SurimonoMode", "-SurimonoFold", "-SurimonoSnapshotWelcome",
            "-SurimonoIncreaseContrast", "-SurimonoCorners", "-SurimonoSettings", "-SurimonoSettingsSize",
            "-SurimonoSettingsFormat", "-SurimonoUpdating", "-SurimonoAppearance", "-SurimonoPaperSeries",
            "-SurimonoViewLayout",
            "-SurimonoOutlineDrawer", "-SurimonoContentsTab", "-SurimonoProseFinding", "-SurimonoMenuArrangement",
            "-SurimonoBandParts", "-SurimonoBandNames", "-SurimonoBandHint", "-SurimonoBandHover",
            "-SurimonoBandCaptureWidth",
            "-SurimonoAlwaysOnTop", "-SurimonoShowsOnAllSpaces", "-SurimonoSelectText", "-SurimonoAlwaysShowToolbar",
            "-SurimonoCoverAlone", "-SurimonoSlides", "-SurimonoPresentation", "-SurimonoArrangementEditor",
            "-SurimonoScrub", "-SurimonoReadingPanel",
            "-SurimonoScrubRoom", "-SurimonoPage",
            "-SurimonoTraySize", "-SurimonoTraySheet", "-SurimonoFolderNotice", "-SurimonoPaletteJump",
        ])
        for item in cases {
            guard validID(item.id), seen.insert(item.id).inserted, item.arguments.count.isMultiple(of: 2),
                item.reference.map(validID) ?? true,
                item.input != nil || (item.kind == .ui && item.arguments.contains("-SurimonoSnapshotWelcome"))
            else { throw SnapshotError("Invalid or duplicate case: \(item.id)") }
            if let path = item.input {
                // Rendering tests and snapshot cases share the same authored slide decks.
                guard
                    path.hasPrefix("Samples/") || path.hasPrefix("Snapshots/")
                        || path.hasPrefix("Packages/SurimonoKit/Tests/SurimonoRenderingTests/Fixtures/"),
                    !path.components(separatedBy: "/").contains("..")
                else { throw SnapshotError("Invalid input: \(path)") }
            }
            for i in stride(from: 0, to: item.arguments.count, by: 2) {
                if item.arguments[i] == "-SurimonoArrangementEditor" {
                    let state = item.arguments[i + 1]
                    guard state.hasPrefix("hint:"), validID(String(state.dropFirst(5)).lowercased()) else {
                        throw SnapshotError("Expected an arrangement chip hint in \(item.id)")
                    }
                }
                guard allowed.contains(item.arguments[i]), !item.arguments[i + 1].hasPrefix("-") else {
                    throw SnapshotError("Unsupported option in \(item.id): \(item.arguments[i])")
                }
            }
        }
        return cases.sorted { $0.id < $1.id }
    }
}
func select(_ cases: [SnapshotCase], only: [String]) throws -> [SnapshotCase] {
    var ids = Set<String>()
    for token in only {
        let matches = cases.filter {
            token.hasPrefix("tag:") ? $0.tags.contains(String(token.dropFirst(4))) : $0.id == token
        }
        guard !matches.isEmpty else { throw SnapshotError("No matching case in this run: \(token)") }
        ids.formUnion(matches.map(\.id))
    }
    return cases.filter { only.isEmpty || ids.contains($0.id) }
}

struct Tolerance: Codable {
    let channel: Int
    let areaRatio: Double
    let tile: Int
    let luminance: Double
    let shiftPt: Double
    func validate() throws {
        guard (0...255).contains(channel), (0...1).contains(areaRatio), (1...128).contains(tile),
            (0...255).contains(luminance), shiftPt >= 0
        else { throw SnapshotError("Invalid tolerances") }
    }
}
struct Line: Codable, Equatable {
    let text: String
    let x, y, width, height: Double
}
struct Page: Codable, Equatable {
    var width, height: Double
    var textLeft, textTop, textWidth, textHeight: Double?
    var firstY, lastY: Double?
    var lineCount: Int
    var lines: [Line]
}
struct Document: Codable {
    var pages: [Page]
    var pageCount: Int
    var textSHA256: String
    var fonts: [String]
    var fidelity: Magnitude?
    var text: String { pages.flatMap(\.lines).map(\.text).joined(separator: "\n") + "\n" }
}

enum Status: String, Codable {
    case identical, noise, changed, unstable, unbaselined, unavailable, error
}
struct Move: Codable, Equatable {
    var text: String
    var fromPage, toPage: Int
    var dx, dy: Double
}
struct Edit: Codable {
    var operation: String
    var line: Int
    var text: String
}
struct Magnitude: Codable, Equatable {
    var pageDelta = 0
    var maxShiftPt = 0.0
    var maxBoxDeltaPt = 0.0
    var changedAreaRatio = 0.0
    var maxLuminance = 0.0
    var textEdits = 0
    var lineCountChangedPages = 0
    var repaginatedLines = 0
    var dimensionsChanged = false
    var layoutChanged = false
    var anyPixelDifference = false

    mutating func include(_ pixels: PixelMetrics) {
        anyPixelDifference = anyPixelDifference || pixels.anyDifference
        dimensionsChanged = dimensionsChanged || pixels.dimensionsChanged
        changedAreaRatio = max(changedAreaRatio, pixels.ratio)
        maxLuminance = max(maxLuminance, pixels.maxLuminance)
    }

    func classify(_ tolerance: Tolerance) -> Status {
        if pageDelta != 0 || textEdits != 0 || dimensionsChanged || lineCountChangedPages != 0 || repaginatedLines != 0
            || maxShiftPt > tolerance.shiftPt || maxBoxDeltaPt > tolerance.shiftPt
            || changedAreaRatio > tolerance.areaRatio
            || maxLuminance > tolerance.luminance
        {
            return .changed
        }
        return anyPixelDifference || layoutChanged ? .noise : .identical
    }
}

struct Comparison: Codable {
    var metrics = Magnitude()
    var moves: [Move] = []
    var edits: [Edit] = []
    var pages: [PageComparison] = []
}
struct PageComparison: Codable {
    let number: Int
    var before, current: String?
    var overlay: String?
    var pixels: PixelMetrics?
    var beforeLayout, currentLayout: Page?
}

// TeX and PDFKit can expose different subsets of the line numbers in a listing.
// A bare numeral has no textual identity across pages or between the footer and body.
private func referenceNumberMatches(_ old: Page, _ new: Page) -> [Int: Int] {
    struct Key: Hashable {
        let text: String
        let region: Int
    }
    func numbers(_ page: Page) -> [Key: [Int]] {
        var groups: [Key: [Int]] = [:]
        for (i, line) in page.lines.enumerated() where isBareNumber(line.text) {
            let center = line.y + line.height / 2
            let region = center < page.height * 0.1 ? -1 : center > page.height * 0.9 ? 1 : 0
            groups[Key(text: line.text, region: region), default: []].append(i)
        }
        return groups
    }
    let current = numbers(new)
    var matches: [Int: Int] = [:]
    for (key, before) in numbers(old) {
        guard let after = current[key] else { continue }
        func distance(_ i: Int, _ j: Int) -> Double {
            hypot(old.lines[i].x - new.lines[j].x, old.lines[i].y - new.lines[j].y)
        }
        // A listing-only digit must not consume the reference's sole table cell.
        // Requiring a mutual nearest neighbour works in either extraction order.
        var closest: [Int: Int] = [:]
        for i in before {
            closest[i] = after.min { distance(i, $0) < distance(i, $1) }
        }
        for j in after {
            if let i = before.min(by: { distance($0, j) < distance($1, j) }), closest[i] == j {
                matches[j] = i
            }
        }
    }
    return matches
}

private func isBareNumber(_ text: String) -> Bool {
    !text.isEmpty && text.unicodeScalars.allSatisfy { CharacterSet.decimalDigits.contains($0) }
}

private func comparePositions(_ old: Document, _ new: Document, texReference: Bool) -> Comparison {
    var result = Comparison()
    result.metrics.pageDelta = new.pageCount - old.pageCount
    for (a, b) in zip(old.pages, new.pages) {
        if a.width != b.width || a.height != b.height { result.metrics.dimensionsChanged = true }
        if a.lineCount != b.lineCount { result.metrics.lineCountChangedPages += 1 }
        for (x, y) in zip(
            [a.textLeft, a.textTop, a.textWidth, a.textHeight, a.firstY, a.lastY],
            [b.textLeft, b.textTop, b.textWidth, b.textHeight, b.firstY, b.lastY])
        {
            if let x, let y { result.metrics.maxBoxDeltaPt = max(result.metrics.maxBoxDeltaPt, pt(abs(x - y))) }
        }
    }
    // Match identical lines in reading order across page breaks; occurrence queues preserve repeated headers.
    var occurrences: [String: [(Int, Line)]] = [:]
    for (index, page) in old.pages.enumerated() {
        for line in page.lines where !texReference || !isBareNumber(line.text) {
            occurrences[line.text, default: []].append((index, line))
        }
    }
    var used: [String: Int] = [:]
    for (index, page) in new.pages.enumerated() {
        let numbers =
            texReference && old.pages.indices.contains(index) ? referenceNumberMatches(old.pages[index], page) : [:]
        for (j, line) in page.lines.enumerated() {
            let (previous, other): (Int, Line)
            if let i = numbers[j] {
                (previous, other) = (index, old.pages[index].lines[i])
            } else {
                let at = used[line.text, default: 0]
                guard let matches = occurrences[line.text], at < matches.count else { continue }
                used[line.text] = at + 1
                (previous, other) = matches[at]
            }
            result.metrics.maxBoxDeltaPt = max(
                result.metrics.maxBoxDeltaPt, pt(abs(line.width - other.width)), pt(abs(line.height - other.height)))
            let dx = pt(line.x - other.x)
            let dy = pt(line.y - other.y)
            if dx != 0 || dy != 0 || previous != index {
                result.moves.append(Move(text: line.text, fromPage: previous + 1, toPage: index + 1, dx: dx, dy: dy))
                if previous != index { result.metrics.repaginatedLines += 1 }
                result.metrics.maxShiftPt = max(result.metrics.maxShiftPt, pt(hypot(dx, dy)))
            }
        }
    }
    return result
}

func comparableFidelity(of approved: Document, against reference: Document) -> Magnitude? {
    guard var previous = approved.fidelity else { return nil }
    func position(_ m: Magnitude) -> (Double, Double, Int) {
        (m.maxShiftPt, m.maxBoxDeltaPt, m.repaginatedLines)
    }
    let updated = position(comparePositions(reference, approved, texReference: true).metrics)
    if updated != position(previous) {
        // Migrate a stored FIFO result only if this reference reproduces it.
        // A replaced TeX PDF must not rewrite the history of the approved run.
        let original = comparePositions(reference, approved, texReference: false).metrics
        if position(original) == position(previous) {
            (previous.maxShiftPt, previous.maxBoxDeltaPt, previous.repaginatedLines) = updated
        }
    }
    return previous
}

func compareLayout(_ old: Document, _ new: Document, texReference: Bool = false) -> Comparison {
    var result = comparePositions(old, new, texReference: texReference)
    let before = old.pages.flatMap(\.lines).map(\.text)
    let after = new.pages.flatMap(\.lines).map(\.text)
    for change in after.difference(from: before) {
        switch change {
        case .remove(let i, let text, _): result.edits.append(Edit(operation: "-", line: i + 1, text: text))
        case .insert(let i, let text, _): result.edits.append(Edit(operation: "+", line: i + 1, text: text))
        }
    }
    result.metrics.textEdits = result.edits.count
    result.metrics.layoutChanged = old.pages != new.pages
    return result
}
