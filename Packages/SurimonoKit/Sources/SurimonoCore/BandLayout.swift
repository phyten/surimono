import CoreGraphics

/// Decides what the view mode's band shows at a given width. Labels give way first, then tools leave for the "…"
/// menu one at a time, the least used first, and the file name shrinks last. One fixed order makes the result
/// predictable at any width, and the "…" button stays put so that its popover never closes on a resize.
public enum BandLayout {
    /// The parts of the band that can give way, in their order on the band.
    public enum Item: CaseIterable, Hashable, Sendable {
        case formatBadge, pageIndicator
        case presentation
        case style
        case layout, transition
        case zoom, thumbnails
        case print

        /// Tools of one group sit together, and a thin separator divides neighbouring groups. The title's parts and
        /// Print stand outside the groups.
        public var group: Int? {
            switch self {
            case .formatBadge, .pageIndicator, .print: nil
            case .presentation: 0
            case .style: 1
            case .layout, .transition: 2
            case .zoom, .thumbnails: 3
            }
        }
    }

    public enum Form: Equatable, Sendable {
        case full
        /// The icon without its label.
        case compact
    }

    /// The measured widths of one item, each including the spacing the item adds to the band.
    public struct Widths: Equatable, Sendable {
        public var full: CGFloat
        public var compact: CGFloat?

        public init(full: CGFloat, compact: CGFloat? = nil) {
            self.full = full
            self.compact = compact
        }
    }

    public enum Step: Equatable, Sendable {
        case compact(Item)
        case remove(Item)
    }

    /// The order in which the band gives up room. Labels go before tools, and a tool leaves earlier the less often it
    /// is used while reading; Print, the second of the two steps to print, stays to the end. The switch between web
    /// and paper is nearly all an HTML page shows on the web, so it stays until the paper tools are gone.
    public static let steps: [Step] = [
        .compact(.style), .compact(.transition), .compact(.presentation),
        .remove(.formatBadge), .remove(.pageIndicator), .remove(.style), .remove(.transition),
        .remove(.layout), .remove(.presentation), .remove(.thumbnails), .remove(.zoom), .compact(.print),
    ]

    /// The file name keeps this much room until every step has been taken.
    public static let nameMinimum: CGFloat = 80
    /// A name squeezed narrower than this says nothing and is left out; the "…" menu names the document instead.
    public static let nameHidingWidth: CGFloat = 24

    public struct Plan: Equatable, Sendable {
        /// The items on the band and their forms.
        public var forms: [Item: Form]
        /// The items that left the band, in band order.
        public var overflow: [Item]
        /// The room for the file name, at most its natural width.
        public var nameWidth: CGFloat

        public var showsName: Bool { nameWidth >= BandLayout.nameHidingWidth }
    }

    /// - Parameters:
    ///   - widths: The items this document shows; an item without widths has no place on the band.
    ///   - fixed: What always stays: the room for the traffic lights, the "…" button, spacing and padding.
    ///   - separator: The width of one separator between groups, with its spacing.
    ///   - name: The natural width of the file name.
    ///   - available: The width of the band.
    public static func plan(
        widths: [Item: Widths], fixed: CGFloat, separator: CGFloat, name: CGFloat, available: CGFloat
    ) -> Plan {
        var forms = widths.mapValues { _ in Form.full }
        var removed = Set<Item>()
        let reservedName = min(name, nameMinimum)

        func required() -> CGFloat {
            let items = forms.reduce(0) { total, entry in
                guard let width = widths[entry.key] else { return total }
                return total + (entry.value == .compact ? width.compact ?? width.full : width.full)
            }
            let groups = Set(forms.keys.compactMap(\.group)).count
            return fixed + reservedName + items + separator * CGFloat(max(groups - 1, 0))
        }

        for step in steps where required() > available {
            switch step {
            case .compact(let item):
                if forms[item] == .full, widths[item]?.compact != nil { forms[item] = .compact }
            case .remove(let item):
                if forms.removeValue(forKey: item) != nil { removed.insert(item) }
            }
        }
        let room = available - (required() - reservedName)
        return Plan(
            forms: forms, overflow: Item.allCases.filter(removed.contains), nameWidth: max(min(name, room), 0))
    }
}
