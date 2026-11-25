import SwaTex

/// Layout allocates rectangular grids and converts delimiter dimensions to integer SVG units.
/// Inspect the expanded AST before either operation, including for the application's print renderer.
struct MathLayoutLimits {
    static let maximumEm = 4_096.0
    static let maximumCells = 8_192
    private static let maximumProofDepth = 32
    // Also bound the linear allocations for expression lists, proof branches, text and array rules.
    private var remainingItems = 65_536
    private var remainingCells = maximumCells

    // One dense page can have thousands of marks. Count shadow copies and dashed segments
    // before SwaTex creates a display list, including marks represented by one dashed SVG stroke.
    static let maximumDrawWork = 65_536
    static let minimumScale = 1.0 / 65_536
    // Budget local and scaled extents, including intermediate boxes. At 1000 SVG units/em
    // even twice this envelope plus glyph rounding fits in a signed 32-bit coordinate.
    static let maximumExtent = 500_000.0
    private var extent = 0.0
    private var drawWork = maximumDrawWork
    // A stretchy mark clips up to three stock paths. In 0.6.0 each has at most 358
    // flattened points and clipping emits at most two commands per edge. Allow 4,096
    // commands per construction and 256 constructions per formula before layout.
    private var remainingStockPaths = 256

    private struct Path {
        var product = 1.0
        var lowerScale = 1.0
        var minimumStyle = 1.0
        var geometry = 1.0
        var copies = 1
        var depth = 0

        func growing(_ factor: Double) -> Self {
            var child = self
            child.geometry *= factor
            return child
        }

        var inScript: Self {
            var child = self
            child.lowerScale *= MathStyle.scriptScript.sizeMultiplier
            child.minimumStyle = MathStyle.scriptScript.sizeMultiplier
            return child
        }

        var repeated: Self {
            var child = self
            // A parent has already been charged for at least one visit before doubling.
            child.copies *= 2
            return child
        }
    }

    private enum Work {
        case nodes([ParseNode], scale: Path)
        case node(ParseNode, scale: Path)
        case dashes(startExtent: Double, count: Int, copies: Int)
        case branches([ProofBranch], scale: Path, depth: Int, centeredChain: Bool)
    }
    private var pending: [Work] = []

    static func accepts(_ nodes: [ParseNode]) -> Bool {
        var limits = Self()
        limits.push(nodes, scale: Path())
        return limits.visit()
    }

    private mutating func push(_ nodes: [ParseNode], scale: Path) {
        if !nodes.isEmpty {
            var child = scale
            child.depth += 1
            pending.append(.nodes(nodes, scale: child))
        }
    }

    private mutating func charge(_ count: Int) -> Bool {
        guard count <= remainingItems else { return false }
        remainingItems -= count
        return true
    }

    private mutating func draw(_ count: Int, on path: Path) -> Bool {
        guard count <= drawWork / path.copies else { return false }
        drawWork -= count * path.copies
        return true
    }

    // A sum bounds both the width of a row and the height/depth of a vertical stack.
    // Charge child contributions in ancestor coordinates, never discounting a local box.
    private mutating func addExtent(_ em: Double, on path: Path) -> Bool {
        extent += abs(em) * path.geometry
        return extent <= Self.maximumExtent
    }

    // A flat work list also handles deep accent and proof trees on a small calling thread.
    private mutating func visit() -> Bool {
        while let item = pending.popLast() {
            switch item {
            case .nodes(let nodes, let scale):
                guard scale.depth <= 96, scale.lowerScale >= Self.minimumScale, charge(nodes.count),
                    draw(nodes.count, on: scale), addExtent(8 * Double(nodes.count), on: scale)
                else { return false }
                // Finish each subtree (including its dash reservation) before charging a
                // sibling's geometry. A long kern beside a small array cannot lengthen its rules.
                for node in nodes.reversed() { pending.append(.node(node, scale: scale)) }
            case .node(let node, let scale):
                guard inspect(node.kind, scale: scale) else { return false }
            case .dashes(let start, let count, let copies):
                // The pinned vertical period is 8 × 0.04 em. Use half the period for roundoff.
                // The length includes struts, gaps, rules, labels and nested grids. Horizontal
                // dashes are a single DisplayItem but consume paint work in the SVG viewer.
                let perLine = 1 + Int(((extent - start) / 0.16).rounded(.up))
                guard count <= drawWork / copies / perLine else { return false }
                drawWork -= count * copies * perLine
            case .branches(let branches, let scale, let depth, let centeredChain):
                let start = extent
                guard depth <= Self.maximumProofDepth, charge(branches.count),
                    draw(depth * branches.count, on: scale), addExtent(8 * Double(branches.count), on: scale)
                else { return false }
                // General proof placement recenters premise extents, unions rule and label
                // extents, then translates the result. Bound the sum of absolute distances
                // through those steps. Centered unary glyph chains only add fixed gaps.
                let child = centeredChain ? scale : scale.growing(16)
                let dashed = branches.count { !$0.premises.isEmpty && $0.lineStyle == .dashed }
                if dashed > 0 {
                    pending.append(.dashes(startExtent: start, count: dashed, copies: scale.copies))
                }
                for branch in branches {
                    push(branch.conclusion, scale: child)
                    push(branch.leftLabel ?? [], scale: child)
                    push(branch.rightLabel ?? [], scale: child)
                    if !branch.premises.isEmpty {
                        pending.append(
                            .branches(branch.premises, scale: child, depth: depth + 1, centeredChain: centeredChain))
                    }
                }
            }
        }
        return true
    }

    private static func isCenteredGlyphChain(_ root: ProofBranch) -> Bool {
        var branch = root
        for _ in 0..<maximumProofDepth {
            guard branch.leftLabel == nil, branch.rightLabel == nil, branch.premises.count <= 1,
                branch.conclusion.count == 1, case .mathOrd = branch.conclusion[0].kind
            else { return false }
            guard let premise = branch.premises.first else { return true }
            branch = premise
        }
        return false
    }

    private mutating func stockPath(_ count: Int = 1, on scale: Path) -> Bool {
        guard count <= remainingStockPaths / scale.copies else { return false }
        remainingStockPaths -= count * scale.copies
        return true
    }

    private mutating func inspect(_ kind: ParseNode.Kind, scale: Path) -> Bool {
        func fits(_ size: SwaTex.Measurement?, allowance: Double = 1) -> Bool {
            guard let size else { return true }
            guard let unit = Self.emPerUnit[size.unit] else { return false }
            guard size.number == 0 || size.number.isNormal else { return false }
            let em = size.number * unit
            guard size.number == 0 || em.isNormal else { return false }
            return Self.fits(em, scale: scale) && addExtent(allowance * em, on: scale)
        }
        switch kind {
        case .rule(let shift, let width, let height):
            return fits(shift, allowance: 2) && fits(width) && fits(height)
        case .size(let value, _), .kern(let value):
            return fits(value)
        case .cr(_, let size), .infix(_, let size):
            return fits(size)
        case .raiseBox(let dy, let body):
            guard fits(dy, allowance: 2) else { return false }
            push([body], scale: scale)
        case .genfrac(_, let numerator, let denominator, _, _, _, let size):
            guard draw(14, on: scale), fits(size, allowance: 8) else { return false }
            push([numerator, denominator], scale: scale.inScript.growing(2))
        case .html, .href, .url, .includeGraphics:
            // Both link commands produce .href. Class/id/data have already lost their
            // attributes in SwaTex's expander. No CSS, links or external images in math.
            return false
        case .array(let info):
            return inspectArray(info, on: scale)
        case .sizing(let size, let body):
            guard (1...11).contains(size) else { return false }
            // layoutSizing resets its body to text style and divides by the enclosing style multiplier.
            return pushScaled(
                body, scale: scale, factor: Self.namedSizes[Int(size) - 1] / scale.minimumStyle, newStyle: 1)
        case .styling(let style, let body):
            let target: MathStyle =
                switch style {
                case .display: .display
                case .text: .text
                case .script: .script
                case .scriptscript: .scriptScript
                }
            return pushScaled(
                body, scale: scale, factor: target.sizeMultiplier / scale.minimumStyle, newStyle: target.sizeMultiplier)
        case .delimSizing(let size, _, _):
            return (1...4).contains(size) && draw(6, on: scale)
        case .leftRight(let body, _, _, _):
            // Permit the stretch pass only for direct middle atoms in a single row.
            // No child transform or stacked row can feed the measured sibling height back.
            guard body.count <= remainingItems else { return false }
            let hasMiddle = body.contains { if case .middle = $0.kind { true } else { false } }
            if hasMiddle, body.contains(where: { if case .cr = $0.kind { true } else { false } }) { return false }
            let inside = scale.growing(4)
            guard draw(12, on: scale) else { return false }
            for node in body {
                if case .middle = node.kind {
                    guard charge(1), draw(6, on: scale), addExtent(8, on: inside) else { return false }
                } else {
                    push([node], scale: inside)
                }
            }
        case .middle:
            return false
        case .pmb(_, let body):
            push(body, scale: scale.repeated)
        case .ordGroup(let body, _), .operatorName(let body, _, _, _), .text(let body, _),
            .color(_, let body), .phantom(let body), .mclass(_, let body, _),
            .hbox(let body):
            push(body, scale: scale)
        case .op(_, _, _, _, _, let name, let body):
            let length = name?.utf8.count ?? 0
            guard draw(4 + length, on: scale), addExtent(2 * Double(length), on: scale) else { return false }
            push(body ?? [], scale: scale)
        case .supSub(let base, let sup, let sub):
            if let base { push([base], scale: scale.growing(4)) }
            push([sup, sub].compactMap { $0 }, scale: scale.inScript.growing(4))
        case .sqrt(let body, let label):
            guard draw(2, on: scale) else { return false }
            push([body], scale: scale.growing(2))
            if let label { push([label], scale: scale.inScript) }
        case .xArrow(_, let body, let label):
            guard stockPath(on: scale), draw(2, on: scale) else { return false }
            push([body], scale: scale.inScript)
            if let label { push([label], scale: scale.inScript) }
        case .accent(_, _, _, let body), .accentUnder(_, _, _, let body),
            .horizBrace(_, _, let body):
            guard stockPath(on: scale), draw(6, on: scale) else { return false }
            push([body], scale: scale.growing(4))
        case .enclose(_, _, _, let body):
            guard draw(6, on: scale) else { return false }
            push([body], scale: scale.growing(4))
        case .font(_, let body),
            .overline(let body), .underline(let body), .vphantom(let body), .smash(let body, _, _),
            .environment(_, let body),
            .lap(_, let body), .vcenter(let body), .cdLabelParent(let body):
            push([body], scale: scale)
        case .mathChoice(let display, let text, let script, let scriptscript):
            for body in [display, text, script, scriptscript] { push(body, scale: scale) }
        case .tag(let body, let tag), .htmlMathML(let body, let tag):
            push(body, scale: scale)
            push(tag, scale: scale)
        case .cdLabel(_, let body):
            push([body], scale: scale.inScript)
        case .cdArrow(_, let above, let below):
            guard stockPath(2, on: scale), draw(12, on: scale) else { return false }
            push([above, below].compactMap { $0 }, scale: scale.inScript.repeated)
        case .proofTree(let tree):
            pending.append(.branches([tree], scale: scale, depth: 1, centeredChain: Self.isCenteredGlyphChain(tree)))
        case .verb(let body, _):
            return charge(body.utf8.count) && draw(body.utf8.count, on: scale)
                && addExtent(2 * Double(body.utf8.count), on: scale)
        case .atom, .mathOrd, .textOrd, .opToken:
            // Includes composite symbols built from a glyph and fixed rules/overlays.
            return draw(4, on: scale)
        case .accentToken, .spacing, .colorToken, .leftRightRight,
            .internalNode, .raw, .noNumber:
            break
        }
        return true
    }

    private mutating func inspectArray(_ info: ParseNode.ArrayInfo, on scale: Path) -> Bool {
        let rows = info.body.count
        guard rows <= remainingCells, info.rowGaps.count <= rows,
            info.hLinesBeforeRow.count <= rows + 1, (info.tags?.count ?? 0) <= rows
        else { return false }
        let width = max(1, info.body.lazy.map(\.count).max() ?? 0)
        guard rows == 0 || width <= remainingCells / rows else { return false }
        remainingCells -= rows * width
        let start = extent
        guard info.arraystretch == 0 || info.arraystretch.isNormal else { return false }
        let strut = info.arraystretch * 1.2
        guard Self.fits(strut, scale: scale), draw(rows * width, on: scale),
            addExtent((abs(strut) + 2) * Double(rows) + 4 * Double(width), on: scale),
            charge(info.cols?.count ?? 0)
        else { return false }
        for case let gap? in info.rowGaps {
            guard gap.number == 0 || gap.number.isNormal, let unit = Self.emPerUnit[gap.unit] else { return false }
            let em = gap.number * unit
            guard gap.number == 0 || em.isNormal, Self.fits(em, scale: scale), addExtent(em, on: scale) else {
                return false
            }
        }
        var dashes = 0
        for spec in info.cols ?? [] {
            let pre = spec.pregap ?? 0
            let post = spec.postgap ?? 0
            guard Self.fits(pre, scale: scale), Self.fits(post, scale: scale),
                addExtent(1 + abs(pre) + abs(post), on: scale), draw(1, on: scale)
            else { return false }
            if spec.alignType == .separator && spec.align == ":" { dashes += 1 }
        }
        for rules in info.hLinesBeforeRow {
            guard charge(rules.count), draw(rules.count, on: scale), addExtent(Double(rules.count), on: scale)
            else { return false }
            dashes += rules.count(where: { $0 })
        }
        if dashes > 0 { pending.append(.dashes(startExtent: start, count: dashes, copies: scale.copies)) }
        let body = info.isCD == true ? scale.growing(4) : scale
        for row in info.body { push(row, scale: body) }
        for case .explicit(let tag) in info.tags ?? [] { push(tag, scale: scale) }
        return true
    }

    private static func fits(_ em: Double, scale: Path) -> Bool {
        (em == 0 || em.isNormal) && abs(em) <= maximumEm / scale.product
    }

    private mutating func pushScaled(_ nodes: [ParseNode], scale: Path, factor: Double, newStyle: Double? = nil)
        -> Bool
    {
        guard factor > 0, Self.fits(factor, scale: scale) else { return false }
        // An outer reduction happens after its child has already been laid out in local coordinates.
        var child = scale
        child.product = max(1, scale.product * factor)
        child.geometry *= max(1, factor)
        child.lowerScale *= min(1, factor * scale.minimumStyle)
        child.minimumStyle = newStyle ?? scale.minimumStyle
        push(nodes, scale: child)
        return true
    }

    // Layout/EngineArrays.swift and EngineTextStyles.swift in the pinned SwaTex release.
    private static let namedSizes = [0.5, 0.6, 0.7, 0.8, 0.9, 1.0, 1.2, 1.44, 1.728, 2.074, 2.488]
    private static let emPerUnit: [String: Double] = {
        let pt = 1 / MathConstants.forSize(0).ptPerEm
        return [
            "pt": pt, "bp": pt * 803 / 800, "pc": 12 * pt, "sp": pt / 65_536,
            "mm": pt * 7_227 / 2_540, "cm": pt * 7_227 / 254, "in": pt * 72.27,
            "dd": pt * 1_238 / 1_157, "cc": pt * 14_856 / 1_157,
            "nd": pt * 685 / 642, "nc": pt * 1_370 / 107,
            "ex": MathConstants.bySize.map(\.xHeight).max() ?? 1,
            "mu": MathConstants.bySize.map(\.cssEmPerMu).max() ?? 1,
            "em": 1, "px": 1,  // SwaTex's measurementToEm uses its identity fallback for px.
        ]
    }()
}
