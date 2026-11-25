import CoreGraphics

/// Decides what the view mode's bands show at a given width. Labels give way first, then tools leave for the "…"
/// menu one at a time, the least used first, and the file name shrinks last. One fixed order makes the result
/// predictable at any width, and the "…" button stays put so that its popover never closes on a resize.
public enum BandLayout {
    /// The parts of the band that can give way, in their order on the band.
    public enum Item: String, Codable, CaseIterable, Hashable, Sendable {
        case formatBadge = "formatBadge"
        case pageIndicator = "pageIndicator"
        case presentation = "presentation"
        case style = "style"
        case outline = "outline"
        case layout = "layout"
        case transition = "transition"
        case zoom = "zoom"
        case thumbnails = "thumbnails"
        case floatOnTop = "floatOnTop"
        case showOnAllSpaces = "showOnAllSpaces"
        case pageTurn = "pageTurn"
        case print = "print"
        case readingDirection = "readingDirection"
        case scrollDirection = "scrollDirection"
        case paperOrientation = "paperOrientation"
        case paperSeries = "paperSeries"
        case cover = "cover"
        case selectText = "selectText"
        case alwaysShowToolbar = "alwaysShowToolbar"
        case margins = "margins"
        case printSettings = "printSettings"
        case ignoreSlides = "ignoreSlides"
        case beforePrinting = "beforePrinting"
        case viewOptions = "viewOptions"
        case saveAsFile = "saveAsFile"
        case keysAndGestures = "keysAndGestures"
        case chapter = "chapter"
        case readingSettings = "readingSettings"

        /// Tools of one group sit together, and a thin separator divides neighbouring groups. The title's parts and
        /// Print stand outside the groups.
        public var group: Int? {
            switch self {
            case .formatBadge, .pageIndicator, .pageTurn, .print, .chapter: nil
            case .presentation, .ignoreSlides: 0
            case .style, .outline, .readingSettings: 1
            case .layout, .transition, .readingDirection, .scrollDirection, .cover: 2
            case .zoom, .thumbnails, .selectText: 3
            case .floatOnTop, .showOnAllSpaces, .alwaysShowToolbar, .viewOptions: 4
            case .paperOrientation, .paperSeries, .margins: 5
            case .printSettings, .beforePrinting, .saveAsFile: 6
            case .keysAndGestures: 7
            }
        }
    }

    public enum Position: Equatable, Sendable {
        case top, bottom
    }

    /// Split, the top band names the document and prints; everything about reading it moves to the bottom band.
    public static func position(of item: Item, in arrangement: MenuArrangement) -> Position {
        guard arrangement == .split else { return .top }
        return [.formatBadge, .floatOnTop, .showOnAllSpaces, .print].contains(item) ? .top : .bottom
    }

    public enum Names: String, Sendable {
        case shown, hidden

        fileprivate func preferredForm(for item: Item, widths: Widths) -> Form {
            guard self == .hidden, widths.compact != nil else { return .full }
            switch item {
            // These display document values. In particular, a compact LaTeX badge drops recognition details.
            case .formatBadge, .pageIndicator, .zoom, .chapter: return .full
            default: return .compact
            }
        }
    }

    public enum Form: Equatable, Sendable {
        case full, withoutSuffix
        /// The icon without its label.
        case compact
    }

    /// The measured widths of one item, each including the spacing the item adds to the band.
    public struct Widths: Equatable, Sendable {
        public var full: CGFloat
        public var withoutSuffix: CGFloat?
        public var compact: CGFloat?

        public init(full: CGFloat, compact: CGFloat? = nil, withoutSuffix: CGFloat? = nil) {
            self.full = full
            self.withoutSuffix = withoutSuffix
            self.compact = compact
        }
    }

    public enum Step: Equatable, Sendable {
        case compact(Item)
        case remove(Item)
    }

    /// The order in which the band gives up room. Labels go before tools, and a tool leaves earlier the less often it
    /// is used while reading; Print, the second of the two steps to print, stays to the end. The switch between web
    /// and paper is nearly all an HTML page shows on the web, so it stays until the paper tools are gone. The window toggles
    /// are small icons whose state shows at a glance, so they stay until only Print is left.
    public static let steps: [Step] = [
        .compact(.formatBadge), .compact(.style), .compact(.transition), .compact(.presentation), .compact(.outline),
        .compact(.thumbnails), .compact(.readingSettings),
        .remove(.chapter), .remove(.readingSettings), .remove(.formatBadge), .remove(.pageIndicator), .remove(.style),
        .remove(.transition),
        .remove(.layout), .remove(.outline), .remove(.presentation), .remove(.thumbnails), .remove(.zoom),
        .remove(.floatOnTop), .remove(.showOnAllSpaces), .compact(.print),
    ]

    /// The bottom band gives way the same way, but the page indicator is its reason to be there, so it stays last.
    public static let bottomSteps: [Step] = [
        .compact(.formatBadge), .compact(.style), .compact(.transition), .compact(.presentation), .compact(.outline),
        .compact(.thumbnails), .compact(.readingSettings),
        .remove(.chapter), .remove(.readingSettings), .remove(.transition), .remove(.layout), .remove(.pageTurn),
        .remove(.style),
        .remove(.outline),
        .remove(.presentation), .remove(.thumbnails), .remove(.zoom), .remove(.pageIndicator),
    ]

    public static let scrubberMinimum: CGFloat = 120

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
    ///   - steps: The order in which this band gives up room.
    public static func plan(
        widths: [Item: Widths], fixed: CGFloat, separator: CGFloat, name: CGFloat, available: CGFloat,
        steps: [Step] = steps
    ) -> Plan {
        // The legacy entry point accepts already-spaced widths and arbitrary step lists. Keep that contract while
        // sharing the collapse engine; ordered-zone callers supply adjacency geometry through resolve instead.
        collapse(forms: widths.mapValues { _ in .full }, widths: widths, name: name, available: available, steps: steps)
        { forms in
            let groups = Set(forms.keys.compactMap(\.group)).count
            return fixed + separator * CGFloat(max(groups - 1, 0))
        }
    }

    private static func itemWidth(_ forms: [Item: Form], widths: [Item: Widths]) -> CGFloat {
        // Catalog order also makes floating-point addition deterministic across dictionary hash seeds.
        Item.allCases.reduce(0) { total, item in
            guard let form = forms[item], let width = widths[item] else { return total }
            switch form {
            case .full: return total + width.full
            case .withoutSuffix: return total + (width.withoutSuffix ?? width.full)
            case .compact: return total + (width.compact ?? width.full)
            }
        }
    }

    private static func collapse(
        forms: [Item: Form], widths: [Item: Widths], name: CGFloat, available: CGFloat, steps: [Step],
        compactBeforeName: [Item] = [],
        spacing: ([Item: Form]) -> CGFloat
    ) -> Plan {
        var forms = forms
        let reservesProgress = widths[.pageIndicator]?.withoutSuffix != nil
        if reservesProgress, itemWidth(forms, widths: widths) + spacing(forms) + name > available {
            forms[.pageIndicator] = .withoutSuffix
        }
        // Additional labels yield before the document name. Legacy callers keep their original collapse order.
        for item in compactBeforeName where itemWidth(forms, widths: widths) + spacing(forms) + name > available {
            if forms[item] == .full, widths[item]?.compact != nil { forms[item] = .compact }
        }
        var removed = Set<Item>()
        let reservedName = min(name, nameMinimum)
        func required() -> CGFloat { itemWidth(forms, widths: widths) + spacing(forms) + reservedName }
        for step in steps where required() > available {
            switch step {
            case .compact(let item):
                if forms[item] == .full, widths[item]?.withoutSuffix != nil {
                    forms[item] = .withoutSuffix
                    if required() <= available { continue }
                }
                if forms[item] != nil, widths[item]?.compact != nil { forms[item] = .compact }
            case .remove(let item):
                if item == .pageIndicator && reservesProgress { continue }
                if forms.removeValue(forKey: item) != nil { removed.insert(item) }
            }
        }
        let room = available - (required() - reservedName)
        return Plan(
            forms: forms, overflow: Item.allCases.filter(removed.contains), nameWidth: max(min(name, room), 0))
    }

    public static func resolve(
        arrangement: BandArrangement, mode: MenuArrangement, availableItems: Set<Item>,
        measurements: BandMeasurementsValue, metrics: BandMetrics, availableWidth: CGFloat, names: Names = .shown
    ) -> BandResolvedPlan {
        // Repair at this boundary too: a caller's mutable draft must never make Print disappear.
        let arrangement = BandArrangementRepair.repair(StoredBandArrangement(arrangement), for: mode).arrangement
        let availableItems = availableItems.union([.print])
        let top = resolveRow(
            leading: arrangement.topLeft, trailing: arrangement.topRight, position: .top, mode: mode,
            availableItems: availableItems, measurements: measurements, metrics: metrics,
            availableWidth: availableWidth,
            names: names
        )
        let bottom =
            mode == .split
            ? resolveRow(
                leading: arrangement.bottomLeft, trailing: arrangement.bottomRight, position: .bottom, mode: mode,
                availableItems: availableItems, measurements: measurements, metrics: metrics,
                availableWidth: availableWidth, names: names
            ) : nil
        let placed = Set(
            (arrangement.topLeft + arrangement.topRight + arrangement.bottomLeft + arrangement.bottomRight).compactMap(
                \.item))
        let shown = Set(top.forms.keys).union(bottom.map { Set($0.forms.keys) } ?? [])
        return BandResolvedPlan(
            top: top, bottom: bottom,
            overflow: Item.allCases.filter {
                placed.contains($0) && availableItems.contains($0) && !shown.contains($0)
            },
            unusedAvailable: Item.allCases.filter { arrangement.unused.contains($0) && availableItems.contains($0) })
    }

    private static func resolveRow(
        leading: [BandEntry], trailing: [BandEntry], position: Position, mode: MenuArrangement,
        availableItems: Set<Item>, measurements: BandMeasurementsValue, metrics: BandMetrics, availableWidth: CGFloat,
        names: Names
    ) -> BandRowPlan {
        let standard = BandArrangement.builtIn(for: mode, includesLegacyParts: true)
        let standardLeading = position == .top ? standard.topLeft : standard.bottomLeft
        let standardTrailing = position == .top ? standard.topRight : standard.bottomRight
        // Omitting a part (including the old hidden-Outline preference) does not change the stack structure.
        // Reordering, crossing zones or editing separators uses adjacency gaps instead of the legacy stacks.
        func follows(_ entries: [BandEntry], order: [BandEntry]) -> Bool {
            let parts = Set(entries.compactMap(\.item))
            let expected = order.filter { $0.item.map(parts.contains) ?? true }
            if expected == entries { return true }
            return availableItems.contains(.thumbnails) && !availableItems.contains(.outline)
                && expected.withBundleEntryAtContents == entries
        }
        let current = BandArrangement.standard(for: mode)
        let currentTrailing = position == .top ? current.topRight : current.bottomRight
        let standardSpacing =
            follows(leading, order: standardLeading)
            && (follows(trailing, order: standardTrailing)
                || follows(trailing, order: currentTrailing))
        let widths = Dictionary(
            uniqueKeysWithValues: (leading + trailing).compactMap(\.item).filter(availableItems.contains).map {
                ($0, measurements.items[$0] ?? Widths(full: 0))
            })
        let name = position == .top ? measurements.name : 0
        // The recovery anchor must not jump across Print when its last neighbour overflows.
        let moreDock: BandRowGeometry.MoreDock =
            position == .bottom
            ? .absent : (trailing.last(where: { $0.item != nil }) == .part(.print) ? .beforePrint : .trailing)
        // In the standard stack, a tool group's separator ends at "…". Only a separator placed directly
        // before the docked Print belongs to it when the last tool group disappears.
        var trailingForSeparators = trailing
        if standardSpacing, moreDock == .beforePrint, trailing.dropLast().last != .separator {
            trailingForSeparators.removeLast()
        }
        func geometry(_ forms: [Item: Form]) -> BandRowGeometry {
            rowGeometry(
                leading: leading.compactMap(\.item).filter { forms[$0] != nil },
                trailing: trailing.compactMap(\.item).filter { forms[$0] != nil },
                separators: visibleSeparators(in: leading, forms: forms)
                    + visibleSeparators(in: trailingForSeparators, forms: forms),
                position: position, mode: mode, metrics: metrics, standardSpacing: standardSpacing, moreDock: moreDock)
        }
        var preferredForms = Dictionary(
            uniqueKeysWithValues: widths.map { ($0.key, names.preferredForm(for: $0.key, widths: $0.value)) })
        // The preparation word yields before the slider, even when the entire row otherwise fits.
        if position == .bottom, let rail = measurements.scrubber, widths[.pageIndicator]?.withoutSuffix != nil,
            itemWidth(preferredForms, widths: widths) + geometry(preferredForms).spacingWidth + rail > availableWidth
        {
            preferredForms[.pageIndicator] = .withoutSuffix
        }
        let plan = collapse(
            forms: preferredForms, widths: widths, name: name, available: availableWidth,
            steps: physicalSteps(at: position),
            compactBeforeName: additionalCompactOrder
        ) { geometry($0).spacingWidth }
        var minimumForms: [Item: Form] = widths[.print].map { [.print: $0.compact == nil ? .full : .compact] } ?? [:]
        if widths[.pageIndicator]?.withoutSuffix != nil { minimumForms[.pageIndicator] = .withoutSuffix }
        // Only the surplus of the *unfolded* row belongs to the scrubber. A label folding must never
        // make the scrubber reappear. The ordinary spacer minimum remains as clearance for the controls.
        let resolvedGeometry = geometry(plan.forms)
        let required = itemWidth(plan.forms, widths: widths) + resolvedGeometry.spacingWidth + plan.nameWidth
        let scrubberWidth: CGFloat
        if position == .bottom, let width = measurements.scrubber, width > 0, availableWidth - required >= width,
            plan.forms == preferredForms
        {
            scrubberWidth = width
        } else {
            scrubberWidth = 0
        }
        return BandRowPlan(
            leading: leading.compactMap(\.item).filter { plan.forms[$0] != nil },
            trailing: trailing.compactMap(\.item).filter { plan.forms[$0] != nil },
            forms: plan.forms, nameWidth: plan.nameWidth,
            minimumWidth: itemWidth(minimumForms, widths: widths) + geometry(minimumForms).spacingWidth,
            geometry: resolvedGeometry, requiredWidth: required + scrubberWidth, showsScrubber: scrubberWidth > 0)
    }

    private static func physicalSteps(at position: Position) -> [Step] {
        let compact: [Step] = [
            .compact(.formatBadge), .compact(.style), .compact(.transition), .compact(.presentation),
            .compact(.outline), .compact(.thumbnails),
        ]
        let removed: [Item] =
            position == .top
            ? [
                .formatBadge, .pageIndicator, .style, .transition, .pageTurn, .layout, .outline,
                .presentation, .thumbnails, .zoom, .floatOnTop, .showOnAllSpaces,
            ]
            : [
                .formatBadge, .transition, .layout, .pageTurn, .style, .outline,
                .presentation, .thumbnails, .zoom, .floatOnTop, .showOnAllSpaces, .pageIndicator,
            ]
        let added = additionalCompactOrder
        return added.map { .compact($0) } + compact + [.remove(.chapter)] + added.map { .remove($0) }
            + removed.map { .remove($0) } + [.compact(.print)]
    }

    private static let additionalCompactOrder: [Item] = [
        .readingSettings, .keysAndGestures, .saveAsFile, .ignoreSlides, .printSettings, .margins, .paperSeries,
        .paperOrientation, .cover, .readingDirection, .scrollDirection, .alwaysShowToolbar,
        .viewOptions, .beforePrinting, .selectText,
    ]

    private static func visibleSeparators(in entries: [BandEntry], forms: [Item: Form]) -> [Item] {
        var hasPart = false
        var pending = false
        var result: [Item] = []
        for entry in entries {
            switch entry {
            case .separator:
                if hasPart { pending = true }
            case .part(let item):
                guard forms[item] != nil else { continue }
                if pending { result.append(item) }
                hasPart = true
                pending = false
            }
        }
        return result
    }

    private static func rowGeometry(
        leading: [Item], trailing: [Item], separators: [Item], position: Position, mode: MenuArrangement,
        metrics: BandMetrics, standardSpacing: Bool, moreDock: BandRowGeometry.MoreDock
    ) -> BandRowGeometry {
        var gaps: [Item: CGFloat] = [:]
        for zone in [leading, trailing] {
            for (index, item) in zone.enumerated() {
                if standardSpacing {
                    // Legacy stacks reserve a gap per item, even the first tool and when the name is hidden.
                    switch item {
                    case .formatBadge: gaps[item] = metrics.titleGap
                    case .pageIndicator: gaps[item] = mode == .split ? metrics.toolGap : metrics.titleGap
                    case .print: gaps[item] = 0
                    default: gaps[item] = metrics.toolGap
                    }
                } else if index > 0 {
                    gaps[item] =
                        separators.contains(item) || (zone[index - 1].group != nil && item.group != nil)
                        ? metrics.toolGap : metrics.outerGap
                } else {
                    gaps[item] = 0
                }
            }
        }
        if !standardSpacing, position == .top, let first = leading.first {
            // The fixed filename precedes the leading zone, including its reserved gap at narrow widths.
            gaps[first] = metrics.titleGap
        }
        // "…" follows the trailing tools (all but a Print docked after it) with a tool gap. The legacy stacks already
        // reserved it as the first tool's gap; reordered zones start at zero, so it is counted here.
        let toolsBeforeMore = moreDock == .beforePrint ? trailing.filter { $0 != .print } : trailing
        let moreGap = !standardSpacing && moreDock != .absent && !toolsBeforeMore.isEmpty ? metrics.toolGap : 0
        return BandRowGeometry(
            fixedWidth: position == .top ? metrics.topFixed : metrics.bottomFixed,
            gapsBefore: gaps, separatorsBefore: separators, separatorWidth: metrics.separator,
            moreDock: moreDock,
            usesStandardSpacing: standardSpacing, moreGap: moreGap)
    }
}
