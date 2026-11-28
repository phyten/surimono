import Foundation

/// What a conversion met and could not read, as data. `HTMLFragment.readingIssues` says the same in words for the
/// print check; this is for measuring a corpus without parsing those words. Asking for it does not change the
/// fragment.
public struct LaTeXConversionReport: Equatable, Sendable {
    /// In the order of `readingIssues`: files, then unknown names, style options, formulas and the expansion limit.
    public var diagnostics: [LaTeXDiagnostic] = []
    /// How much of the expansion allowance the document used, and where it ran out.
    public var budget = LaTeXBudgetUse()

    public init(diagnostics: [LaTeXDiagnostic] = [], budget: LaTeXBudgetUse = LaTeXBudgetUse()) {
        self.diagnostics = diagnostics
        self.budget = budget
    }
}

public struct LaTeXDiagnostic: Equatable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        /// `name` is the command with its backslash.
        case unknownCommand
        /// `name` is the environment.
        case unknownEnvironment
        /// A file the document names could not be read. `name` is the reference with the extension TeX adds.
        case unreadFile
        /// A note about a file that is not a failed read, such as a picture drawn from an external image.
        case fileNote
        /// `name` is the style package, `detail` the option it does not know.
        case styleOption
        /// `name` is the first 100 characters of the formula's source; `formula` says where it failed.
        case formula
        /// The document's expansion allowance ran out; `LaTeXConversionReport.budget` says where.
        case expansionLimit
    }

    public var kind: Kind
    public var name: String
    public var detail: String?
    public var formula: LaTeXFormulaFailure?

    public init(kind: Kind, name: String, detail: String? = nil, formula: LaTeXFormulaFailure? = nil) {
        self.kind = kind
        self.name = name
        self.detail = detail
        self.formula = formula
    }
}

/// The stage a formula failed at, as far as the converter can tell without changing how it typesets.
public enum LaTeXFormulaFailure: Equatable, Sendable {
    /// The document has definitions, and the bounded check refused the formula. `command` is the first token the
    /// check has no cost for, or nil when every token was known but the bound was too large.
    case boundRefused(command: String?)
    /// Without document definitions, the standalone check refused a command or a helper.
    case standaloneRefused(command: String?)
    /// SwaTex could not parse the prepared input.
    case parse(message: String)
    /// The layout or display-list limits refused it.
    case layout
    /// The math expansion allowance of the document ran out first.
    case budget
    /// None of the above: the SVG could not be finished.
    case output

    /// A stable code for tables.
    public var code: String {
        switch self {
        case .boundRefused: "bound-refused"
        case .standaloneRefused: "standalone-refused"
        case .parse: "parse"
        case .layout: "layout"
        case .budget: "budget"
        case .output: "output"
        }
    }

    /// The command named by a refusal.
    public var command: String? {
        switch self {
        case .boundRefused(let command), .standaloneRefused(let command): command
        default: nil
        }
    }
}

/// The document's expansion allowance: what it used, which limit stopped it and while reading what.
public struct LaTeXBudgetUse: Equatable, Sendable {
    public enum Limit: String, Sendable, CaseIterable {
        /// 200,000 expansions.
        case calls
        /// Two million generated characters (including input files read).
        case characters
        /// 50 million units of scanning and copying, including moving the unread tail on each insertion.
        case work
        /// The shared nesting depth or the thread's stack.
        case depth
        /// 10,000 iterations of one loop.
        case iterations
        /// 200,000 copied reference names.
        case copies
        /// The allowance for one formula's macro expansion.
        case math
    }

    public struct Stop: Equatable, Sendable {
        public var limit: Limit
        /// The reader's own step that found the limit, such as `insertExpansion(_:)`.
        public var site: String
        /// The TeX command the reader was dispatching.
        public var command: String?
        /// The user macro expanded most recently.
        public var macro: String?
        /// The input file being read, as its last path component; nil in the main file.
        public var file: String?
        /// For a formula: what its allowance refused, such as `rejected definition \foo` or `output size`.
        public var detail: String?
        public var calls: Int
        public var characters: Int
        public var work: Int
    }

    /// One TeX command's share of the allowance. Expanding a macro and moving the unread tail for it are charged to
    /// the macro; other reservations to the command being dispatched.
    public struct Charge: Equatable, Sendable {
        public var command: String
        public var calls = 0
        public var characters = 0
        public var work = 0
    }

    /// The first stop of the document's allowance.
    public var stop: Stop?
    /// The first formula whose own expansion allowance ran out.
    public var mathStop: Stop?
    public var calls = 0
    public var characters = 0
    public var work = 0
    /// The commands that used the most, by work, then characters, then calls.
    public var heaviest: [Charge] = []

    public init() {}
}

/// The ledger behind `LaTeXBudgetUse`, kept by the document while it reads.
final class LaTeXBudgetLedger {
    /// Only a report asks for the charges, so the app does not keep them.
    var chargesCommands = false
    var charges: [String: LaTeXBudgetUse.Charge] = [:]
    var stop: LaTeXBudgetUse.Stop?
    var mathStop: LaTeXBudgetUse.Stop?
    var dispatching: String?
    var macro: String?
    /// The user macro whose expansion is being reserved and inserted.
    var expanding: String?

    var payer: String { expanding ?? dispatching.map { "\\" + $0 } ?? "(reader)" }

    func charge(calls: Int = 0, characters: Int = 0, work: Int = 0) {
        guard chargesCommands else { return }
        let key = payer
        var charge = charges[key] ?? LaTeXBudgetUse.Charge(command: key)
        charge.calls += calls
        charge.characters += characters
        charge.work += work
        charges[key] = charge
    }

    func heaviest(_ count: Int) -> [LaTeXBudgetUse.Charge] {
        charges.values.sorted {
            ($0.work, $0.characters, $0.calls, $1.command) > ($1.work, $1.characters, $1.calls, $0.command)
        }.prefix(count).map { $0 }
    }
}

extension LaTeXDocument {
    /// Stops expansion for the rest of the document, keeping the first limit that did.
    func stopExpanding(_ limit: LaTeXBudgetUse.Limit, site: String = #function) {
        if budget.stop == nil { budget.stop = budgetStop(limit, site: site) }
        stopsExpanding = true
    }

    /// One formula's expansion ran out: the formula keeps its source and the document reads on.
    func stopMathExpansion(detail: String? = nil, site: String = #function) {
        if budget.mathStop == nil {
            budget.mathStop = budgetStop(.math, site: site)
            budget.mathStop?.detail = detail
        }
        mathExpansionLimitReached = true
    }

    /// Scanning and copying, charged to the command that needed it.
    func spendWork(_ units: Int) {
        expansionWork += units
        budget.charge(work: units)
    }

    private func budgetStop(_ limit: LaTeXBudgetUse.Limit, site: String) -> LaTeXBudgetUse.Stop {
        LaTeXBudgetUse.Stop(
            limit: limit, site: site, command: budget.dispatching.map { "\\" + $0 },
            macro: budget.macro.map { "\\" + $0 }, file: inputChain.last?.lastPathComponent, detail: nil,
            calls: expansions, characters: expandedCharacters, work: expansionWork)
    }

    var budgetUse: LaTeXBudgetUse {
        var use = LaTeXBudgetUse()
        use.stop = budget.stop
        use.mathStop = budget.mathStop
        use.calls = expansions
        use.characters = expandedCharacters
        use.work = expansionWork
        use.heaviest = budget.heaviest(12)
        return use
    }

    /// The reading issues as data, in their order. `issues` are `readingIssues`, whose words the diagnostics keep.
    func diagnostics(issues: [String]) -> [LaTeXDiagnostic] {
        var result: [LaTeXDiagnostic] = []
        let unread = Dictionary(readingUnreadFiles.map { ($0.issueIndex, $0) }, uniquingKeysWith: { first, _ in first })
        for index in fileIssues.indices {
            if let file = unread[index] {
                result.append(LaTeXDiagnostic(kind: .unreadFile, name: file.reference, detail: issues[index]))
            } else {
                result.append(LaTeXDiagnostic(kind: .fileNote, name: issues[index]))
            }
        }
        for name in unknownNames {
            result.append(
                LaTeXDiagnostic(kind: name.hasPrefix("\\") ? .unknownCommand : .unknownEnvironment, name: name))
        }
        if let style = classInfo.resolvedStyle {
            result += style.diagnostics.map {
                LaTeXDiagnostic(kind: .styleOption, name: style.requestedName, detail: $0)
            }
        }
        for (index, issue) in failedFormulas.enumerated() {
            let excerpt = issue.drop(while: { $0 != ":" }).dropFirst().drop(while: { $0 == " " })
            result.append(
                LaTeXDiagnostic(
                    kind: .formula, name: String(excerpt),
                    formula: index < formulaFailures.count ? formulaFailures[index] : nil))
        }
        if stopsExpanding || mathExpansionLimitReached {
            result.append(
                LaTeXDiagnostic(
                    kind: .expansionLimit, name: (budget.stop ?? budget.mathStop)?.limit.rawValue ?? "",
                    detail: (budget.stop ?? budget.mathStop)?.site))
        }
        return result
    }
}
