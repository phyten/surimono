import Foundation

public enum ClipboardTextKind: String, CaseIterable, Codable, Sendable {
    case markdown, org, html, latex, csv, asciidoc, quarto, rMarkdown, djot, textile, notebook, graphviz, plantuml, url,
        plainText
}

public struct ClipboardFormatHints: Equatable, Sendable {
    /// The app has verified that the pasteboard URL representation matches the trimmed text.
    public var hasMatchingURL: Bool
    /// Spreadsheet provenance permits a bounded table preview to stand for a truncated table.
    public var hasTabularData: Bool

    public init(hasMatchingURL: Bool = false, hasTabularData: Bool = false) {
        self.hasMatchingURL = hasMatchingURL
        self.hasTabularData = hasTabularData
    }
}

public struct ClipboardFormatSettings: Equatable, Codable, Sendable {
    public enum Mode: String, Codable, Sendable, CaseIterable {
        case askWhenUnsure, plainTextWhenUnsure, alwaysAsk, fixed
    }

    public enum Carefulness: String, Codable, Sendable, CaseIterable {
        case careful, standard, eager
    }

    public var mode: Mode
    public var carefulness: Carefulness
    /// This controls automatic opening only; every kind remains available for an explicit choice.
    public var automaticKinds: Set<ClipboardTextKind>
    public var fixedKind: ClipboardTextKind
    public static let standard = ClipboardFormatSettings()

    public init(
        mode: Mode = .askWhenUnsure, carefulness: Carefulness = .standard,
        automaticKinds: Set<ClipboardTextKind> = Set(ClipboardTextKind.allCases),
        fixedKind: ClipboardTextKind = .plainText
    ) {
        self.mode = mode
        self.carefulness = carefulness
        self.automaticKinds = automaticKinds
        self.fixedKind = fixedKind == .url ? .plainText : fixedKind
    }

    private enum CodingKeys: String, CodingKey { case mode, carefulness, automaticKinds, fixedKind }

    // Older builds must preserve usable preferences when a newer build writes unknown fields or values.
    public init(from decoder: any Decoder) throws {
        self.init()
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        mode = (try? container.decode(Mode.self, forKey: .mode)) ?? .askWhenUnsure
        carefulness = (try? container.decode(Carefulness.self, forKey: .carefulness)) ?? .standard
        fixedKind = (try? container.decode(ClipboardTextKind.self, forKey: .fixedKind)) ?? .plainText
        if fixedKind == .url { fixedKind = .plainText }
        if let values = try? container.decode([String].self, forKey: .automaticKinds) {
            let known = Set(values.compactMap(ClipboardTextKind.init(rawValue:)))
            if values.isEmpty || !known.isEmpty { automaticKinds = known }
        }
    }
}

public struct ClipboardFormatDetection: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case open(ClipboardTextKind)
        case ask(preferred: ClipboardTextKind)
    }

    public enum Evidence: Equatable, Sendable {
        case headings(Int)
        case lists(Int)
        case codeBlocks(Int)
        case tables(Int)
        case markup(Int)
        case metadata(Int)
        case links(Int)
        case document, pasteboard, incomplete, conflictingSyntax, damagedText
    }

    public enum Reason: Equatable, Sendable {
        case blank, ordinaryText, accepted, insufficientStructure, conflictingSyntax, competingFormats
        case truncated, damagedText, alwaysAsk, fixed
    }

    public struct Choice: Equatable, Sendable {
        public var kind: ClipboardTextKind
        public var confidence: Double
        public var evidence: [Evidence]
    }

    public var action: Action
    public var reason: Reason
    public var choices: [Choice]
    public var tableDelimiter: Character?
    public var analysedUnits: Int
    public var analysedLines: Int
    public var isTruncated: Bool
    // Per-call accounting avoids shared mutable instrumentation in concurrent detection.
    var scannerSteps: Int = 0
}

struct ClipboardCandidate: Sendable {
    var kind: ClipboardTextKind
    var structures = 0
    // Observations remain available for hand picking; only document claims affect automatic decisions.
    var claims = false
    // The candidate proved that its running body is configuration rather than document content.
    var envelope = false
    var accepted = true
    var sufficient = false
    var ownsStart = false
    var evidence: [ClipboardFormatDetection.Evidence] = []
    var delimiter: Character?
    var strength = 0
    var leadingProseOnly = false

    var choice: ClipboardFormatDetection.Choice {
        let confidence: Double
        if claims && structures > 0 && sufficient && accepted {
            confidence = 0.95
        } else if structures > 0 {
            confidence = accepted ? 0.65 : 0.45
        } else {
            confidence = 0
        }
        let useful = evidence.filter { value in
            switch value {
            case .headings(let n), .lists(let n), .codeBlocks(let n), .tables(let n), .markup(let n), .metadata(let n),
                .links(let n):
                return n > 0
            default: return true
            }
        }
        return .init(kind: kind, confidence: confidence, evidence: useful)
    }
}

/// Inspects a single bounded window without reading files, loading resources, or modifying the source.
public enum ClipboardFormatDetector {
    private static let textileBlock = try? NSRegularExpression(
        pattern: #"(?m)^(?:h[1-6]|bq|bc|fn[0-9]+)\. (?=\S)|^\|_\. (?=\S)"#)

    private static func looksLikeTextile(_ text: String) -> Bool {
        let prefix = String(decoding: text.utf8.prefix(8192), as: UTF8.self)
        // Markdown examples often quote several real Textile blocks inside one code fence.
        guard let textileBlock, !prefix.contains("```"), !prefix.contains("~~~") else { return false }
        let range = NSRange(prefix.startIndex..., in: prefix)
        let blocks = textileBlock.numberOfMatches(in: prefix, range: range)
        if blocks >= 2 { return true }
        // A quoted key followed by a colon also occurs in ordinary JSON. Require a Textile block alongside a link.
        return blocks == 1 && prefix.range(of: #""[^"\r\n]+":\S"#, options: .regularExpression) != nil
    }

    public static func detect(
        _ text: String, hints: ClipboardFormatHints = .init(), settings: ClipboardFormatSettings = .standard
    ) -> ClipboardFormatDetection {
        var decisive = DiagramConverter.clipboardKind(text)
        if decisive == nil, text.drop(while: { $0.isWhitespace }).first == "{",
            let root = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
            root["cells"] is [Any], NotebookConverter.version(root) != nil
        {
            decisive = .notebook
        }
        if decisive == nil, text.hasPrefix("= ") {
            let lines = text.prefix(8192).split(whereSeparator: \.isNewline)
            if lines.first.map({ $0.dropFirst(2).contains { !$0.isWhitespace } }) == true,
                lines.dropFirst().contains(where: {
                    $0.starts(with: "== ") || $0.starts(with: "[source,") || $0.starts(with: "NOTE: ")
                        || $0.range(of: #"^:[\w-]+:(?:\s|$)"#, options: .regularExpression) != nil
                        || $0 == "----" || $0 == "...."
                })
            {
                decisive = .asciidoc
            }
        }
        if decisive == nil { decisive = ComputationalMarkdown.clipboardKind(text) }
        // Djot and Markdown share their ordinary syntax. Only an explicit choice selects Djot.
        if decisive == nil, looksLikeTextile(text) { decisive = .textile }
        if let decisive {
            let enabled = settings.automaticKinds.contains(decisive)
            let selected: ClipboardTextKind =
                settings.mode == .fixed ? settings.fixedKind : (enabled ? decisive : .plainText)
            let asks = settings.mode == .alwaysAsk
            return ClipboardFormatDetection(
                action: asks ? .ask(preferred: selected) : .open(selected),
                reason: asks ? .alwaysAsk : (settings.mode == .fixed ? .fixed : (enabled ? .accepted : .ordinaryText)),
                choices: [
                    .init(kind: decisive, confidence: 0.95, evidence: [.document]),
                    .init(kind: .plainText, confidence: 0.5, evidence: []),
                ]
                    + ClipboardTextKind.allCases.filter { $0 != decisive && $0 != .plainText }.map {
                        .init(kind: $0, confidence: 0, evidence: [])
                    }, tableDelimiter: nil,
                analysedUnits: text.utf8.count, analysedLines: 0, isTruncated: false)
        }
        let window = ClipboardWindow(text)
        var work = ClipboardWork()
        var candidates = [
            ClipboardScanners.markdown(window, level: settings.carefulness, work: &work),
            ClipboardScanners.org(window, level: settings.carefulness, work: &work),
            ClipboardScanners.html(window, level: settings.carefulness, work: &work),
            ClipboardScanners.latex(window, level: settings.carefulness, work: &work),
            ClipboardScanners.csv(window, hints: hints, level: settings.carefulness, work: &work),
            ClipboardScanners.url(window, hints: hints, work: &work),
            ClipboardCandidate(kind: .quarto), ClipboardCandidate(kind: .rMarkdown),
            ClipboardCandidate(kind: .djot), ClipboardCandidate(kind: .textile), ClipboardCandidate(kind: .asciidoc),
            ClipboardCandidate(kind: .notebook),
            ClipboardCandidate(kind: .graphviz), ClipboardCandidate(kind: .plantuml),
        ]
        let hintedTable =
            hints.hasTabularData
            && candidates.contains {
                $0.kind == .csv && $0.structures > 0 && $0.accepted && $0.sufficient
            }
        if !hintedTable
            && (candidates.contains { $0.envelope } || ClipboardScanners.externalEnvelope(window, work: &work))
        {
            for index in candidates.indices {
                candidates[index].claims = false
                candidates[index].accepted = false
            }
        }
        for index in candidates.indices where candidates[index].structures > 0 {
            if window.broken { candidates[index].evidence.append(.damagedText) }
            if window.truncated { candidates[index].evidence.append(.incomplete) }
        }
        candidates.sort {
            let leftEnabled = settings.automaticKinds.contains($0.kind)
            let rightEnabled = settings.automaticKinds.contains($1.kind)
            if leftEnabled != rightEnabled { return leftEnabled }
            if $0.choice.confidence != $1.choice.confidence { return $0.choice.confidence > $1.choice.confidence }
            if $0.strength != $1.strength { return $0.strength > $1.strength }
            return $0.kind.rawValue < $1.kind.rawValue
        }
        var choices = candidates.map(\.choice)
        choices.append(.init(kind: .plainText, confidence: 0.5, evidence: []))
        if let plainIndex = choices.firstIndex(where: {
            $0.confidence < 0.5 || !settings.automaticKinds.contains($0.kind)
        }) {
            let plain = choices.removeLast()
            choices.insert(plain, at: plainIndex)
        }
        let structured = candidates.filter { $0.claims && settings.automaticKinds.contains($0.kind) }
        let accepted = structured.filter(\.accepted)
        let qualified = accepted.filter(\.sufficient)
        var reason: ClipboardFormatDetection.Reason = .ordinaryText
        var action: ClipboardFormatDetection.Action = .open(.plainText)
        if window.isBlank {
            reason = .blank
        } else if settings.mode == .fixed {
            action = .open(settings.fixedKind == .url ? .plainText : settings.fixedKind)
            reason = .fixed
        } else {
            if !structured.isEmpty || (window.truncated && window.bytes.isEmpty && !settings.automaticKinds.isEmpty) {
                if window.broken {
                    reason = .damagedText
                } else if window.truncated && !(hints.hasTabularData && qualified.contains(where: { $0.kind == .csv }))
                {
                    reason = .truncated
                } else if hints.hasTabularData, let table = qualified.first(where: { $0.kind == .csv }) {
                    reason = .accepted
                    action = .open(table.kind)
                } else if qualified.isEmpty {
                    reason = structured.contains { !$0.accepted } ? .conflictingSyntax : .insufficientStructure
                } else if structured.contains(where: { !$0.accepted && $0.ownsStart }) {
                    reason = .conflictingSyntax
                } else if accepted.count > 1 {
                    reason = .competingFormats
                } else if let best = qualified.first {
                    reason = .accepted
                    action = .open(best.kind)
                }
                if reason != .accepted && settings.mode != .plainTextWhenUnsure {
                    let prose = structured.first { $0.kind == .markdown && $0.leadingProseOnly && $0.sufficient }
                    let preferred: ClipboardTextKind =
                        reason == .competingFormats
                        ? qualified[0].kind
                        : (prose != nil && !window.broken && !window.truncated
                            && !structured.contains { $0.kind != .markdown && $0.ownsStart } ? .markdown : .plainText)
                    action = .ask(preferred: preferred)
                }
            }
            if settings.mode == .alwaysAsk {
                if case .open(let kind) = action { action = .ask(preferred: kind) }
                reason = .alwaysAsk
            }
        }
        return ClipboardFormatDetection(
            action: action, reason: reason, choices: choices,
            tableDelimiter: candidates.first(where: { $0.kind == .csv })?.delimiter,
            analysedUnits: window.units, analysedLines: window.lines.count, isTruncated: window.truncated,
            scannerSteps: work.steps)
    }
}
