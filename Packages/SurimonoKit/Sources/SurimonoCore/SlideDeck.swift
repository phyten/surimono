import CoreGraphics
import Foundation

/// A live web page that is a deck of slides: a set of sibling elements of one fixed size, shaped like a screen.
/// Such a page is viewed one slide to the window and prints one slide to the page.
public struct SlideDeck: Equatable, Sendable {
    /// The size of one slide in CSS pixels, before any transform of the deck.
    public var size: CGSize
    public var count: Int
    /// The 0-based index of the slide shown, or of the one most in view.
    public var currentIndex: Int
    /// The deck already scales its slides to the window itself (for example with `transform: scale`), so the app
    /// only shapes the window and leaves the page's zoom alone.
    public var scalesItself: Bool

    public init(size: CGSize, count: Int, currentIndex: Int = 0, scalesItself: Bool = false) {
        self.size = size
        self.count = count
        self.currentIndex = currentIndex
        self.scalesItself = scalesItself
    }

    /// The window shape and the fit only depend on the slide's size and whether the deck scales itself.
    public func hasSameShape(as other: SlideDeck?) -> Bool {
        guard let other else { return false }
        return size == other.size && scalesItself == other.scalesItself
    }
}

/// What the slide script measured on a page: the groups of sibling elements that share one size.
public struct SlideFacts: Codable, Equatable, Sendable {
    public struct Member: Codable, Equatable, Sendable {
        /// The layout size in CSS pixels, before transforms; for a hidden element, its computed size.
        public var width: Double
        public var height: Double
        /// The element's width and height are set as fixed lengths, not as percentages, viewport units or auto.
        public var fixed: Bool
        /// The share of the element's box that is in the viewport and not hidden, from 0 to 1.
        public var visible: Double
        /// The share of the element's box that its clipping ancestors leave showing, wherever the page is scrolled:
        /// 0 for a hidden element or one a carousel clips away, 1 for a card of a gallery below the fold.
        public var unclipped: Double
        /// The element's box in the viewport, after transforms.
        public var x: Double
        public var y: Double
        public var boxWidth: Double
        public var boxHeight: Double

        public init(
            width: Double, height: Double, fixed: Bool = true, visible: Double = 0, x: Double = 0, y: Double = 0,
            boxWidth: Double? = nil, boxHeight: Double? = nil, unclipped: Double? = nil
        ) {
            self.width = width
            self.height = height
            self.fixed = fixed
            self.visible = visible
            self.x = x
            self.y = y
            self.boxWidth = boxWidth ?? width
            self.boxHeight = boxHeight ?? height
            self.unclipped = unclipped ?? (self.boxWidth > 0 && self.boxHeight > 0 ? 1 : 0)
        }

        private enum CodingKeys: String, CodingKey {
            case width, height, fixed, visible, unclipped, x, y, boxWidth, boxHeight
        }

        public init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                width: try values.decode(Double.self, forKey: .width),
                height: try values.decode(Double.self, forKey: .height),
                fixed: try values.decode(Bool.self, forKey: .fixed),
                visible: try values.decode(Double.self, forKey: .visible),
                x: try values.decode(Double.self, forKey: .x), y: try values.decode(Double.self, forKey: .y),
                boxWidth: try values.decode(Double.self, forKey: .boxWidth),
                boxHeight: try values.decode(Double.self, forKey: .boxHeight),
                unclipped: try values.decodeIfPresent(Double.self, forKey: .unclipped))
        }
    }

    public struct Group: Codable, Equatable, Sendable {
        public var members: [Member]

        public init(members: [Member]) { self.members = members }
    }

    public var viewportWidth: Double
    public var viewportHeight: Double
    public var groups: [Group]

    public init(viewportWidth: Double, viewportHeight: Double, groups: [Group]) {
        self.viewportWidth = viewportWidth
        self.viewportHeight = viewportHeight
        self.groups = groups
    }

    public init?(json: String) {
        guard let facts = try? JSONDecoder().decode(Self.self, from: Data(json.utf8)) else { return nil }
        self = facts
    }
}

extension SlideDeck {
    /// The screen shapes a slide is made in, as width over height.
    static let aspects: [Double] = [16.0 / 9.0, 4.0 / 3.0]
    static let aspectTolerance = 0.03
    /// Smaller elements of a screen's shape are thumbnails or cards, not slides.
    static let minimumWidth = 400.0

    /// The deck the facts describe, or nil for an ordinary page. A deck is a group of at least two siblings of one
    /// fixed size, shaped like a screen, of which no two are laid out side by side (that would be a gallery). Class
    /// names and key handlers are not looked at: pages call anything a slide, and listeners cannot be seen.
    public static func detect(_ facts: SlideFacts) -> SlideDeck? {
        let decks = facts.groups.compactMap(deck(of:))
        return decks.max { lhs, rhs in
            lhs.count != rhs.count
                ? lhs.count < rhs.count : lhs.size.width * lhs.size.height < rhs.size.width * rhs.size.height
        }
    }

    public static func detect(fromJSON json: String) -> SlideDeck? {
        SlideFacts(json: json).flatMap(detect)
    }

    private static func deck(of group: SlideFacts.Group) -> SlideDeck? {
        let members = group.members
        guard members.count >= 2, let first = members.first, first.width >= minimumWidth, first.height > 0,
            members.allSatisfy(\.fixed)
        else { return nil }
        let sameSize = members.allSatisfy {
            abs($0.width - first.width) <= max(1, first.width * 0.005)
                && abs($0.height - first.height) <= max(1, first.height * 0.005)
        }
        guard sameSize else { return nil }
        let aspect = first.width / first.height
        guard aspects.contains(where: { abs(aspect - $0) / $0 <= aspectTolerance }) else { return nil }
        // Laid out side by side, a gallery stays a gallery wherever it is scrolled; a carousel clips away all but one.
        let laidOut = members.filter { $0.unclipped > 0.25 }
        for (index, member) in laidOut.enumerated() {
            for other in laidOut[(index + 1)...] where sharesRow(member, other) { return nil }
        }
        var current = 0
        for (index, member) in members.enumerated() where member.visible > members[current].visible {
            current = index
        }
        let shown = members[current]
        let scale = shown.width > 0 ? shown.boxWidth / shown.width : 1
        return SlideDeck(
            size: CGSize(width: first.width.rounded(), height: first.height.rounded()), count: members.count,
            currentIndex: current, scalesItself: abs(scale - 1) > 0.01)
    }

    /// Two boxes on one line: they overlap by more than half a slide's height vertically and not horizontally.
    private static func sharesRow(_ lhs: SlideFacts.Member, _ rhs: SlideFacts.Member) -> Bool {
        let vertical = min(lhs.y + lhs.boxHeight, rhs.y + rhs.boxHeight) - max(lhs.y, rhs.y)
        let horizontal = min(lhs.x + lhs.boxWidth, rhs.x + rhs.boxWidth) - max(lhs.x, rhs.x)
        return vertical > min(lhs.boxHeight, rhs.boxHeight) / 2 && horizontal < 1
    }
}
