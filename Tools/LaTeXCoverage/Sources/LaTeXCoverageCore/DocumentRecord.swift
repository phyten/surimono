import Foundation

/// What reading one paper gave, as the worker writes it. Version it when a count changes meaning, so that runs
/// counted differently are not compared.
public struct DocumentRecord: Codable, Equatable, Sendable {
    public static let format = 1

    public enum Outcome: String, Codable, Sendable {
        case ok, crashed, timeout
    }

    public struct Diagnostic: Codable, Equatable, Sendable {
        /// `LaTeXDiagnostic.Kind`'s raw value.
        public var kind: String
        public var name: String
        public var detail: String?
        /// For a formula: `LaTeXFormulaFailure.code`.
        public var cause: String?
        /// For a formula refused by a check: the command it had no cost for.
        public var command: String?

        public init(kind: String, name: String, detail: String? = nil, cause: String? = nil, command: String? = nil) {
            self.kind = kind
            self.name = name
            self.detail = detail
            self.cause = cause
            self.command = command
        }
    }

    public struct Stop: Codable, Equatable, Sendable {
        public var limit: String
        public var site: String
        public var command: String?
        public var macro: String?
        public var file: String?
        public var detail: String?
        public var calls: Int
        public var characters: Int
        public var work: Int

        public init(
            limit: String, site: String, command: String?, macro: String?, file: String?, detail: String? = nil,
            calls: Int, characters: Int, work: Int
        ) {
            self.detail = detail
            self.limit = limit
            self.site = site
            self.command = command
            self.macro = macro
            self.file = file
            self.calls = calls
            self.characters = characters
            self.work = work
        }
    }

    public struct Charge: Codable, Equatable, Sendable {
        public var command: String
        public var calls: Int
        public var characters: Int
        public var work: Int

        public init(command: String, calls: Int, characters: Int, work: Int) {
            self.command = command
            self.calls = calls
            self.characters = characters
            self.work = work
        }
    }

    public struct Budget: Codable, Equatable, Sendable {
        public var stop: Stop?
        public var mathStop: Stop?
        public var calls: Int
        public var characters: Int
        public var work: Int
        public var heaviest: [Charge]

        public init(stop: Stop?, mathStop: Stop?, calls: Int, characters: Int, work: Int, heaviest: [Charge]) {
            self.stop = stop
            self.mathStop = mathStop
            self.calls = calls
            self.characters = characters
            self.work = work
            self.heaviest = heaviest
        }
    }

    public struct Read: Codable, Equatable, Sendable {
        /// Relative to the paper's folder; outside it, the name only.
        public var path: String
        public var ok: Bool

        public init(path: String, ok: Bool) {
            self.path = path
            self.ok = ok
        }
    }

    public var format = Self.format
    public var id: String
    public var group: String?
    public var year: Int?
    public var main: String
    public var outcome: Outcome
    public var seconds: Double = 0
    public var documentClass: String?
    /// `recognised`, `substituted` or `none`.
    public var recognition: String?
    public var recognisedName: String?
    public var diagnostics: [Diagnostic] = []
    public var budget: Budget?
    public var page = PageCounts()
    public var reads: [Read] = []
    public var bodyBytes = 0
    /// The tail of the worker's error output when it did not finish.
    public var failure: String?

    public init(id: String, main: String, outcome: Outcome) {
        self.id = id
        self.main = main
        self.outcome = outcome
    }

    /// The notes a reader of the print check meets, counted as the 2026-11-29 measurement counted them: one per
    /// unknown name, unread file, style option, formula and limit; pictures by their fallback reason, missing and
    /// EPS images, and unreadable beamer frames or theme once each.
    public var notes: Int { noteKeys.count }

    public var noteKeys: [String] {
        guard outcome == .ok else { return [] }
        let pictures = Set(page.pictureReasons)
        var keys: [String] = []
        for diagnostic in diagnostics {
            switch diagnostic.kind {
            case "unknownCommand": keys.append("cmd:" + diagnostic.name)
            case "unknownEnvironment": keys.append("env:" + diagnostic.name)
            case "unreadFile":
                if pictures.contains(diagnostic.detail ?? diagnostic.name) { continue }
                keys.append("file:" + Self.fileKind(diagnostic.name))
            case "fileNote":
                if pictures.contains(diagnostic.name) { continue }
                keys.append("note:file")
            case "styleOption": keys.append("option:" + (diagnostic.detail ?? ""))
            case "formula": keys.append("math")
            case "expansionLimit": keys.append("limit")
            default: keys.append("other:" + diagnostic.kind)
            }
        }
        keys += page.pictureReasons.map { "tikz:" + PageCounts.reasonKey($0) }
        keys += Array(repeating: "img:missing", count: page.imagesMissing)
        keys += Array(repeating: "img:eps", count: page.imagesEPS)
        if page.beamerUnreadableFrames > 0 { keys.append("beamer:frames") }
        if page.beamerTheme { keys.append("beamer:theme") }
        return keys
    }

    static func fileKind(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "bib": return "bib"
        case "tex": return "input"
        case "": return "other"
        default: return "other." + ext
        }
    }
}
