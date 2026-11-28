import Foundation

/// A run's numbers, from its documents.
public struct CoverageSummary: Codable, Equatable, Sendable {
    public struct Count: Codable, Equatable, Sendable {
        public var name: String
        /// Papers that have it.
        public var documents: Int
        /// Times it occurs across them.
        public var occurrences: Int
    }

    public var format = DocumentRecord.format
    public var papers = 0
    public var outcomes: [String: Int] = [:]
    public var zeroNotes = 0
    public var atMostThree = 0
    public var atMostTen = 0
    public var medianNotes = 0.0
    public var medianSeconds = 0.0
    public var maximumSeconds = 0.0
    /// Notes by their key's kind (`cmd`, `env`, `file`, `math`, `limit`, `tikz`, `img`…).
    public var notesByKind: [Count] = []
    public var unknownCommands: [Count] = []
    public var unknownEnvironments: [Count] = []
    public var unreadFiles: [Count] = []
    /// Failed formulas by cause, and the commands the bounded checks had no cost for.
    public var formulaCauses: [Count] = []
    public var refusedMathCommands: [Count] = []
    /// Papers that ran out of the expansion allowance, by `limit site`, by the macro expanded last, and the
    /// commands that used the most in them.
    public var limitStops: [Count] = []
    public var limitMacros: [Count] = []
    public var limitHeaviest: [Count] = []
    /// Papers whose first formula over its own allowance stopped at a site, for a kind of reason; and the reasons in
    /// full, which name a rejected definition.
    public var mathStops: [Count] = []
    public var mathStopDetails: [Count] = []

    public init(_ records: [DocumentRecord], top: Int = 40) {
        papers = records.count
        for record in records { outcomes[record.outcome.rawValue, default: 0] += 1 }
        let ok = records.filter { $0.outcome == .ok }
        // A paper that did not finish is not a paper with no notes: it stays in the denominator only.
        let notes = ok.map(\.notes)
        zeroNotes = notes.filter { $0 == 0 }.count
        atMostThree = notes.filter { $0 <= 3 }.count
        atMostTen = notes.filter { $0 <= 10 }.count
        medianNotes = Self.median(notes.map(Double.init))
        medianSeconds = Self.median(ok.map(\.seconds))
        maximumSeconds = ok.map(\.seconds).max() ?? 0
        notesByKind = Self.tally(ok.map { $0.noteKeys.map { String($0.prefix(while: { $0 != ":" })) } }, top: nil)
        func names(_ kind: String) -> [[String]] {
            ok.map { $0.diagnostics.filter { $0.kind == kind }.map(\.name) }
        }
        unknownCommands = Self.tally(names("unknownCommand"), top: top)
        unknownEnvironments = Self.tally(names("unknownEnvironment"), top: top)
        unreadFiles = Self.tally(
            ok.map { $0.diagnostics.filter { $0.kind == "unreadFile" }.map { DocumentRecord.fileKind($0.name) } },
            top: nil)
        let formulas = ok.map { $0.diagnostics.filter { $0.kind == "formula" } }
        formulaCauses = Self.tally(formulas.map { $0.map { $0.cause ?? "unknown" } }, top: nil)
        refusedMathCommands = Self.tally(formulas.map { $0.compactMap(\.command) }, top: top)
        let stopped = ok.compactMap(\.budget).filter { $0.stop != nil }
        limitStops = Self.tally(stopped.map { [$0.stop.map { "\($0.limit) \($0.site)" } ?? ""] }, top: top)
        limitMacros = Self.tally(stopped.map { [$0.stop?.macro ?? "(none)"] }, top: top)
        limitHeaviest = Self.tally(stopped.map { $0.heaviest.prefix(3).map(\.command) }, top: top)
        let mathStopped = ok.compactMap { $0.budget?.mathStop }
        mathStops = Self.tally(
            mathStopped.map { [$0.site + ": " + ($0.detail?.components(separatedBy: " \\").first ?? "")] }, top: top)
        mathStopDetails = Self.tally(mathStopped.map { [$0.detail ?? ""] }, top: top)
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    /// Each inner array is one paper's occurrences.
    static func tally(_ papers: [[String]], top: Int?) -> [Count] {
        var documents: [String: Int] = [:]
        var occurrences: [String: Int] = [:]
        for names in papers {
            for name in Set(names) { documents[name, default: 0] += 1 }
            for name in names { occurrences[name, default: 0] += 1 }
        }
        let sorted = documents.keys.sorted {
            (documents[$0] ?? 0, occurrences[$0] ?? 0, $1) > (documents[$1] ?? 0, occurrences[$1] ?? 0, $0)
        }
        return (top.map { Array(sorted.prefix($0)) } ?? sorted).map {
            Count(name: $0, documents: documents[$0] ?? 0, occurrences: occurrences[$0] ?? 0)
        }
    }

    public var markdown: String {
        func percent(_ value: Int) -> String {
            papers == 0 ? "0" : String(format: "%.1f", Double(value) * 100 / Double(papers))
        }
        var lines = [
            "# LaTeX coverage", "",
            "| | papers | % |", "|---|---:|---:|",
            "| papers | \(papers) | |",
            "| zero notes | \(zeroNotes) | \(percent(zeroNotes)) |",
            "| at most 3 notes | \(atMostThree) | \(percent(atMostThree)) |",
            "| at most 10 notes | \(atMostTen) | \(percent(atMostTen)) |",
            "| median notes | \(Self.number(medianNotes)) | |",
            "| seconds (median / max) | \(Self.number(medianSeconds)) / \(Self.number(maximumSeconds)) | |",
        ]
        lines += outcomes.keys.sorted().map { "| outcome \($0) | \(outcomes[$0] ?? 0) | |" }
        for (title, counts) in [
            ("Notes by kind", notesByKind), ("Unknown commands", unknownCommands),
            ("Unknown environments", unknownEnvironments), ("Unread files", unreadFiles),
            ("Formula causes", formulaCauses), ("Commands the math checks refused", refusedMathCommands),
            ("Expansion limit: where it stopped", limitStops), ("Expansion limit: macro expanded last", limitMacros),
            ("Expansion limit: heaviest commands", limitHeaviest), ("Formula expansion limit", mathStops),
            ("Formula expansion limit in full", mathStopDetails),
        ] where !counts.isEmpty {
            lines += ["", "## \(title)", "", "| name | papers | occurrences |", "|---|---:|---:|"]
            lines += counts.map {
                "| `\($0.name.replacingOccurrences(of: "|", with: "\\|"))` | \($0.documents) | \($0.occurrences) |"
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }
}

/// Two runs over the same papers, side by side.
public struct CoverageComparison: Equatable, Sendable {
    public struct Change: Equatable, Sendable {
        public var id: String
        public var before: Int
        public var after: Int
    }

    public var before: CoverageSummary
    public var after: CoverageSummary
    /// Papers present in both runs whose notes went down, and up.
    public var better: [Change] = []
    public var worse: [Change] = []
    /// Papers whose outcome changed, such as from ok to timeout.
    public var outcomes: [String] = []
    /// Counted with a different `DocumentRecord.format`: the numbers do not compare.
    public var formatsDiffer: Bool

    public init(before: [DocumentRecord], after: [DocumentRecord]) {
        self.before = CoverageSummary(before)
        self.after = CoverageSummary(after)
        formatsDiffer = Set((before + after).map(\.format)).count > 1
        let earlier = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for record in after.sorted(by: { $0.id < $1.id }) {
            guard let old = earlier[record.id] else { continue }
            if old.outcome != record.outcome {
                outcomes.append("\(record.id): \(old.outcome.rawValue) → \(record.outcome.rawValue)")
            }
            guard old.outcome == .ok, record.outcome == .ok else { continue }
            let change = Change(id: record.id, before: old.notes, after: record.notes)
            if change.after < change.before { better.append(change) }
            if change.after > change.before { worse.append(change) }
        }
    }

    public var markdown: String {
        var lines =
            formatsDiffer ? ["> The runs were counted in different formats; the numbers do not compare.", ""] : []
        lines += ["| | before | after | change |", "|---|---:|---:|---:|"]
        func row(_ name: String, _ a: Double, _ b: Double) {
            let change = b - a
            lines.append(
                "| \(name) | \(CoverageSummary.number(a)) | \(CoverageSummary.number(b)) | "
                    + (change > 0 ? "+" : "") + CoverageSummary.number(change) + " |")
        }
        row("papers", Double(before.papers), Double(after.papers))
        row("zero notes", Double(before.zeroNotes), Double(after.zeroNotes))
        row("at most 3 notes", Double(before.atMostThree), Double(after.atMostThree))
        row("at most 10 notes", Double(before.atMostTen), Double(after.atMostTen))
        row("median notes", before.medianNotes, after.medianNotes)
        let kinds = Set(before.notesByKind.map(\.name) + after.notesByKind.map(\.name)).sorted()
        for kind in kinds {
            row(
                "notes: \(kind)", Double(before.notesByKind.first { $0.name == kind }?.occurrences ?? 0),
                Double(after.notesByKind.first { $0.name == kind }?.occurrences ?? 0))
        }
        lines += ["", "Better: \(better.count) papers. Worse: \(worse.count) papers."]
        for (title, changes) in [("Worse", worse), ("Better", better)] where !changes.isEmpty {
            lines += ["", "## \(title)", "", "| paper | before | after |", "|---|---:|---:|"]
            lines += changes.map { "| \($0.id) | \($0.before) | \($0.after) |" }
        }
        if !outcomes.isEmpty { lines += ["", "## Outcomes changed", ""] + outcomes.map { "- \($0)" } }
        return lines.joined(separator: "\n") + "\n"
    }
}

public enum CoverageFiles {
    public static let documents = "documents.jsonl"

    public static func write(_ records: [DocumentRecord], to folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var lines = Data()
        for record in records.sorted(by: { $0.id < $1.id }) {
            lines.append(try encoder.encode(record))
            lines.append(0x0A)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try lines.write(to: folder.appending(path: documents), options: .atomic)
        // One line per paper, for a spreadsheet or a quick diff between runs.
        let table =
            ["id,outcome,notes,seconds"]
            + records.sorted(by: { $0.id < $1.id }).map {
                "\($0.id),\($0.outcome.rawValue),\($0.notes),\(String(format: "%.2f", $0.seconds))"
            }
        try Data((table.joined(separator: "\n") + "\n").utf8).write(
            to: folder.appending(path: "notes.csv"), options: .atomic)
        let summary = CoverageSummary(records)
        encoder.outputFormatting.insert(.prettyPrinted)
        try encoder.encode(summary).write(to: folder.appending(path: "summary.json"), options: .atomic)
        try Data(summary.markdown.utf8).write(to: folder.appending(path: "summary.md"), options: .atomic)
    }

    /// A run folder, or its `documents.jsonl`.
    public static func read(_ url: URL) throws -> [DocumentRecord] {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        let file = isDirectory.boolValue ? url.appending(path: documents) : url
        let decoder = JSONDecoder()
        return try String(decoding: Data(contentsOf: file), as: UTF8.self).split(separator: "\n").map {
            try decoder.decode(DocumentRecord.self, from: Data($0.utf8))
        }
    }
}
