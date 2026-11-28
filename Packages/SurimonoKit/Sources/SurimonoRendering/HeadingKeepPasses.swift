import Foundation
import SurimonoCore
import WebKit

/// Runs the prints that keep headings with their text on one prepared web view (`HeadingKeep`).
///
/// Every print is read before it is kept, and the pages returned are always pages that were printed from the DOM as
/// it is left: a later geometry pass that prints the same DOM again gets the same pages.
@MainActor
struct HeadingKeepPasses {
    enum Mode: Sendable {
        /// Measure the prints and report what was found, without changing the pages.
        case detect
        /// Add page breaks before groups found apart, and print again.
        case correct
    }

    /// What the headings did to one pagination, for diagnostics and measurements.
    struct Report: Sendable {
        /// The first print, before any correction.
        var initial: HeadingKeep.Summary?
        /// The print that was kept.
        var final: HeadingKeep.Summary?
        var unmeasured: HeadingKeep.Unmeasured?
        var extraPrints = 0
        var stop: HeadingKeep.Stop?
        var reused = false
        var breaks: Set<Int> = []
        /// Time spent reading the DOM and the printed PDFs, without the prints themselves.
        var measuring: Duration = .zero
        var printing: Duration = .zero
        /// The groups of the kept print that are not together, with the start of their text (tests only read it).
        var details: [String] = []
    }

    let view: WKWebView
    let mode: Mode
    /// Whether the report lists the groups that are not together (the corpus harness reads them).
    var collectsDetails = false
    let textArea: CGRect
    let deadline: ContinuousClock.Instant
    private(set) var planner = HeadingKeep.Planner()
    private(set) var report = Report()
    private var collected: HeadingKeepProbe.Collected?
    /// The summary of each print by its breaks, so that the report describes the print that is returned.
    private var summaries: [Set<Int>: HeadingKeep.Summary] = [:]

    init(view: WKWebView, mode: Mode, textArea: CGRect, deadline: ContinuousClock.Instant) {
        self.view = view
        self.mode = mode
        self.textArea = textArea
        self.deadline = deadline
    }

    /// The time one reading of the DOM or of a PDF may take.
    private static let measureBudget: Duration = .seconds(3)

    private func remaining() -> Duration { ContinuousClock.now.duration(to: deadline) }

    /// Read a print. A failure to read leaves the pages alone: it is never taken to mean that the headings are kept.
    mutating func observe(_ bytes: Data, recollect: Bool) async throws -> HeadingKeepProbe.Observation {
        let started = ContinuousClock.now
        defer { report.measuring += ContinuousClock.now - started }
        if recollect || collected == nil {
            let until = min(deadline, .now + Self.measureBudget)
            do {
                collected = try await HeadingKeepProbe.collect(in: view, until: until)
            } catch WebPaginator.PaginationError.timedOut {
                collected = nil
            }
        }
        guard let collected else { return HeadingKeepProbe.Observation(unmeasured: .ambiguous) }
        let observation = try await HeadingKeepProbe.observe(
            bytes, collected: collected, textArea: textArea, budget: min(remaining(), Self.measureBudget))
        let summary = HeadingKeep.Summary(observation.placements, limits: planner.limits)
        if report.initial == nil {
            report.initial = summary
            report.unmeasured = observation.unmeasured
        }
        report.final = summary
        summaries[planner.forced] = summary
        guard collectsDetails else { return observation }
        report.details = observation.placements.keys.sorted().compactMap { id in
            guard let placement = observation.placements[id], let groups = collected.groups,
                let text = collected.text, groups.indices.contains(id)
            else { return nil }
            if case .together = placement { return nil }
            let facts = observation.facts[id].map { f in
                "h\(f.headingFirstPage ?? -1)-\(f.headingLastPage ?? -1) p\(f.previousPage ?? -1) "
                    + "f\(f.followFirstPage ?? -1)-\(f.followLastPage ?? -1) l\(f.linesOnHeadingPage ?? -1)"
            }
            let units = text.utf16
            let start = units.index(units.startIndex, offsetBy: min(groups[id].h[0], units.count))
            let heading = String(units[start...].prefix(24)) ?? ""
            return "\(id) \(groups[id].k) \(placement) \(facts ?? "") \(heading)"
        }
        return observation
    }

    /// What to do after `observation`: the breaks to print next, or to go back to; nil keeps the last print. Applies
    /// the breaks to the DOM before returning them.
    /// - Parameters:
    ///   - mayPrint: Whether another print can follow.
    ///   - mayReuse: Whether an earlier print can be returned without printing again.
    mutating func decide(after observation: HeadingKeepProbe.Observation, mayPrint: Bool, mayReuse: Bool) async throws
        -> HeadingKeep.Decision?
    {
        guard mode == .correct, observation.unmeasured == nil else { return nil }
        var trial = planner
        let decision = trial.next(after: observation.placements)
        switch decision {
        case .finish(let stop):
            report.stop = stop
            planner = trial
            return nil
        case .print where !mayPrint, .reuse where !mayReuse && !mayPrint:
            report.stop = .budget
            return nil
        case .print(let breaks), .reuse(let breaks):
            guard
                try await HeadingKeepProbe.apply(
                    breaks, in: view, until: min(deadline, .now + Self.measureBudget))
            else {
                // The groups no longer match the DOM; keep the pages that were printed from it.
                report.stop = .settled
                return nil
            }
            planner = trial
            report.breaks = breaks
            if case .reuse = decision, mayReuse {
                report.reused = true
                report.stop = trial.stop
                report.final = summaries[breaks] ?? report.final
            } else {
                report.extraPrints += 1
            }
            return decision
        }
    }

    /// Print, read and correct until the headings settle, the prints run out, or the deadline nears.
    /// - Parameter print: Prints the DOM as it is; `true` for the first print.
    mutating func run(print: (Bool) async throws -> Data) async throws -> Data {
        var started = ContinuousClock.now
        var bytes = try await print(true)
        var lastPrint = ContinuousClock.now - started
        report.printing += lastPrint
        var printed: [Set<Int>: Data] = [[]: bytes]
        while true {
            let observation = try await observe(bytes, recollect: false)
            // A new print must fit in the time that is left, with room to read it.
            let mayPrint = remaining() > lastPrint * 2 + Self.measureBudget
            guard let decision = try await decide(after: observation, mayPrint: mayPrint, mayReuse: true) else {
                return bytes
            }
            switch decision {
            case .reuse(let breaks):
                // Every state the planner printed is kept here; were one missing, the DOM as it now is gets printed.
                guard let earlier = printed[breaks] else { return try await print(false) }
                return earlier
            case .print(let breaks):
                started = ContinuousClock.now
                bytes = try await print(false)
                lastPrint = ContinuousClock.now - started
                report.printing += lastPrint
                printed[breaks] = bytes
            case .finish:
                return bytes
            }
        }
    }
}
