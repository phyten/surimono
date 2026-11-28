import Foundation

/// Keeping a heading on the page of the text it introduces.
///
/// WebKit's print pagination ignores `break-after: avoid`, so a heading can end a page with its text on the next one.
/// The renderer prints, reads where each heading group and the start of its text landed in the printed PDF, and
/// prints again with a page break before the groups it found apart. Nothing here predicts where WebKit breaks a page:
/// every decision follows from pages that were actually printed.
public enum HeadingKeep {
    /// What has to share the heading's page.
    public enum Follow: Equatable, Sendable {
        /// A paragraph, a list item or a definition: its first lines, or all of it when it is shorter.
        case text(requiredLines: Int)
        /// A block that keeps itself together or whose first line is enough (a table row, code, a figure caption).
        case block
        /// A picture or a diagram, whose text cannot be found in the printed text: whether anything is drawn below the
        /// heading on its page tells whether it stayed.
        case graphic
        /// A page break of the author's or of the print settings, or the end of the text, comes first.
        case none
    }

    /// Where a heading group and its text were found on the printed pages. Pages count from 0.
    public struct Facts: Equatable, Sendable {
        /// The page of the group's first character.
        public var headingFirstPage: Int?
        /// The page of the group's last character, past any heading right under the first.
        public var headingLastPage: Int?
        /// The page of the last printed text before the group, nil when there is none or it could not be placed.
        public var previousPage: Int?
        /// Whether some text comes before the group; without any, the group opens the first page.
        public var hasPreviousText: Bool
        public var follow: Follow
        public var followFirstPage: Int?
        /// The page of the last character of the text that was read for the group (at most its first part).
        public var followLastPage: Int?
        /// The lines of the following text on the heading's page, read only when its text goes on to the next page.
        public var linesOnHeadingPage: Int?
        /// Whether anything is drawn below the group on its page, read for a following graphic.
        public var drawnBelow: Bool?
        /// The height that would go to the next page with the heading, as a fraction of the text area.
        public var move: Double?
        /// The room the heading's page would have at its foot once the group goes, as a fraction of the text area.
        public var vacated: Double?
        /// The empty height at the foot of the page before the group, as a fraction of the text area.
        public var precedingSpace: Double?

        public init(
            headingFirstPage: Int?, headingLastPage: Int?, previousPage: Int?, hasPreviousText: Bool = true,
            follow: Follow, followFirstPage: Int? = nil, followLastPage: Int? = nil, linesOnHeadingPage: Int? = nil,
            drawnBelow: Bool? = nil, move: Double? = nil, vacated: Double? = nil, precedingSpace: Double? = nil
        ) {
            self.headingFirstPage = headingFirstPage
            self.headingLastPage = headingLastPage
            self.previousPage = previousPage
            self.hasPreviousText = hasPreviousText
            self.follow = follow
            self.followFirstPage = followFirstPage
            self.followLastPage = followLastPage
            self.linesOnHeadingPage = linesOnHeadingPage
            self.drawnBelow = drawnBelow
            self.move = move
            self.vacated = vacated
            self.precedingSpace = precedingSpace
        }

        /// Whether the group is the first text of its page, so that a break before it cannot help.
        var startsPage: Bool? {
            guard let headingFirstPage else { return nil }
            guard hasPreviousText else { return true }
            return previousPage.map { $0 < headingFirstPage }
        }
    }

    /// Why a group could not be judged. An unmeasured group is never taken to be together.
    public enum Unmeasured: String, Equatable, Sendable, Codable {
        /// The printed text could not be matched to the source with certainty.
        case ambiguous
        /// A graphic follows, and the page below the heading could not be read.
        case unreadable
        /// The text or the time to measure it was over its limit.
        case budget
    }

    public enum Placement: Equatable, Sendable {
        /// On the same page. `precedingSpace` is given when the group opens a page.
        case together(precedingSpace: Double?)
        /// The heading's page ends before enough of its text. `vacated` is the room its page would keep at its foot
        /// without the group: what a break before it is expected to leave.
        case separated(move: Double?, startsPage: Bool, vacated: Double? = nil)
        /// The heading has nothing after it to keep it with.
        case alone
        case unmeasured(Unmeasured)
    }

    public static func placement(of facts: Facts) -> Placement {
        guard let first = facts.headingFirstPage, let last = facts.headingLastPage else {
            return .unmeasured(.ambiguous)
        }
        let opensPage = facts.startsPage
        func together() -> Placement { .together(precedingSpace: opensPage == true ? facts.precedingSpace : nil) }
        func separated() -> Placement {
            .separated(move: facts.move, startsPage: opensPage ?? false, vacated: facts.vacated)
        }
        guard first <= last else { return .unmeasured(.ambiguous) }
        // The group itself runs over a page: a heading above another one ends the page.
        guard first == last else { return separated() }
        let required: Int
        switch facts.follow {
        case .none: return .alone
        case .graphic:
            // Whatever is drawn below the heading on its page comes after it, so the graphic did not move away.
            guard let drawnBelow = facts.drawnBelow else { return .unmeasured(.unreadable) }
            return drawnBelow ? together() : separated()
        case .block: required = 0
        case .text(let lines): required = max(1, lines)
        }
        guard let followFirst = facts.followFirstPage else { return .unmeasured(.ambiguous) }
        if followFirst > last { return separated() }
        guard followFirst == last else { return .unmeasured(.ambiguous) }
        guard required > 0 else { return together() }
        guard let followLast = facts.followLastPage else { return .unmeasured(.ambiguous) }
        // The whole of what was read (all of a short paragraph, or its first part) is on the heading's page.
        if followLast == last { return together() }
        guard let lines = facts.linesOnHeadingPage else { return .unmeasured(.ambiguous) }
        return lines >= required ? together() : separated()
    }

    public struct Limits: Equatable, Sendable {
        /// Prints after the first that the headings may ask for.
        public var extraPasses = 2
        /// The most a correction may move to the next page, as a fraction of the text area. A larger move leaves
        /// more paper empty than a heading at the foot of a page costs.
        public var maximumMove = 0.25
        /// A break the renderer added is withdrawn when the page before it ends with more room than this beyond what
        /// the break was expected to leave: the heading and its first lines would have fit there, so the break only
        /// moved the text along. (A heading before a picture that moved on by itself leaves that room anyway.)
        public var maximumPrecedingSpace = 0.25

        public init() {}
    }

    /// Why the corrections stopped.
    public enum Stop: Equatable, Sendable {
        /// The last print needs no other break.
        case settled
        /// The prints allowed for headings are spent.
        case budget
    }

    public enum Decision: Equatable, Sendable {
        /// Print again with a page break before each of these groups.
        case print(Set<Int>)
        /// Keep the last print.
        case finish(Stop)
        /// Go back to an earlier print, made with these breaks, which came out better than the last.
        case reuse(Set<Int>)
    }

    /// Chooses the breaks pass by pass, from what each print showed.
    ///
    /// A break moves everything after it, so a print can come apart again further on, and the last print allowed can
    /// show a break that left most of a page empty. Every print is scored when it is read, and the corrections end on
    /// the best print made, which is never worse than the first; of prints that score the same, the one with the
    /// fewest breaks.
    public struct Planner: Equatable, Sendable {
        public let limits: Limits
        /// The groups printed with a break before them in the last print.
        public private(set) var forced: Set<Int> = []
        /// Groups whose break did not help, or was not needed, which are not tried again.
        public private(set) var withdrawn: Set<Int> = []
        public private(set) var extraPasses = 0
        /// Why the corrections ended, once they have.
        public private(set) var stop: Stop?
        private var printed: Set<Set<Int>> = [[]]
        private var scores: [Set<Int>: Int] = [:]
        /// The room each added break was expected to leave before it.
        private var expected: [Int: Double] = [:]

        public init(limits: Limits = Limits()) { self.limits = limits }

        /// How bad a print is: each heading apart from its text, and each added break that left most of the page
        /// before it empty, which costs paper as well as a page that looks unfinished.
        func score(_ observations: [Int: Placement]) -> Int {
            var score = 0
            for (group, placement) in observations {
                switch placement {
                case .separated: score += 1
                case .together(let space?) where leftRoom(space, before: group):
                    score += 3
                default: break
                }
            }
            return score
        }

        /// Whether an added break left more room before it than it was expected to.
        func leftRoom(_ space: Double, before group: Int) -> Bool {
            forced.contains(group) && space > (expected[group] ?? 0) + limits.maximumPrecedingSpace
        }

        /// What to do after a print with the current breaks.
        public mutating func next(after observations: [Int: Placement]) -> Decision {
            scores[forced] = score(observations)
            var next = forced
            func withdraw(_ group: Int) {
                next.remove(group)
                withdrawn.insert(group)
            }
            for group in observations.keys.sorted() {
                guard let placement = observations[group] else { continue }
                switch placement {
                case .together(let space):
                    if let space, leftRoom(space, before: group) { withdraw(group) }
                case .separated(let move, let startsPage, let vacated):
                    if forced.contains(group) {
                        // Even a page of its own did not keep it together: the break only cost paper.
                        withdraw(group)
                    } else if !withdrawn.contains(group), !startsPage, let move, move <= limits.maximumMove {
                        next.insert(group)
                        expected[group] = vacated ?? move
                    }
                case .alone, .unmeasured: break
                }
            }
            guard next != forced, !printed.contains(next) else { return conclude(.settled) }
            guard extraPasses < limits.extraPasses else { return conclude(.budget) }
            extraPasses += 1
            printed.insert(next)
            forced = next
            return .print(next)
        }

        /// End on the best print that was read: the last one unless an earlier one scored lower.
        private mutating func conclude(_ reason: Stop) -> Decision {
            stop = reason
            // A print no better than another with fewer breaks only costs paper; among equals the last print stays.
            func rank(_ entry: (key: Set<Int>, value: Int)) -> (Int, Int, Int) {
                (entry.value, entry.key.count, entry.key == forced ? 0 : 1)
            }
            let best = scores.min { a, b in
                rank(a) != rank(b) ? rank(a) < rank(b) : a.key.sorted().lexicographicallyPrecedes(b.key.sorted())
            }?.key
            guard let best, best != forced else { return .finish(reason) }
            forced = best
            return .reuse(best)
        }
    }

    /// Counts for one print, for diagnostics and measurements.
    public struct Summary: Equatable, Sendable, Codable {
        public var groups = 0
        public var together = 0
        public var separated = 0
        /// Separated groups that a break cannot help: they open a page, or would move too much.
        public var uncorrectable = 0
        public var alone = 0
        public var unmeasured: [String: Int] = [:]

        public init() {}

        public init(_ placements: [Int: Placement], limits: Limits = Limits()) {
            groups = placements.count
            for placement in placements.values {
                switch placement {
                case .together: together += 1
                case .separated(let move, let startsPage, _):
                    separated += 1
                    if startsPage || move.map({ $0 > limits.maximumMove }) != false { uncorrectable += 1 }
                case .alone: alone += 1
                case .unmeasured(let reason): unmeasured[reason.rawValue, default: 0] += 1
                }
            }
        }

        public var unmeasuredCount: Int { unmeasured.values.reduce(0, +) }
    }
}
