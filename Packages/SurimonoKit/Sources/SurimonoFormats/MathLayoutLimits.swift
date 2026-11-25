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

    private struct Scale {
        var product = 1.0
        var minimumStyle = 1.0

        // Scripts can be laid out in a smaller local em before the engine scales the result.
        var inScript: Self { Self(product: product, minimumStyle: MathStyle.scriptScript.sizeMultiplier) }
    }

    private enum Work {
        case nodes([ParseNode], scale: Scale)
        case branches([ProofBranch], scale: Scale, depth: Int)
    }
    private var pending: [Work] = []

    static func accepts(_ nodes: [ParseNode]) -> Bool {
        var limits = Self()
        limits.push(nodes, scale: Scale())
        return limits.visit()
    }

    private mutating func push(_ nodes: [ParseNode], scale: Scale) {
        if !nodes.isEmpty { pending.append(.nodes(nodes, scale: scale)) }
    }

    private mutating func charge(_ count: Int) -> Bool {
        guard count <= remainingItems else { return false }
        remainingItems -= count
        return true
    }

    // A flat work list also handles deep accent and proof trees on a small calling thread.
    private mutating func visit() -> Bool {
        while let item = pending.popLast() {
            switch item {
            case .nodes(let nodes, let scale):
                guard charge(nodes.count) else { return false }
                for node in nodes {
                    guard inspect(node.kind, scale: scale) else { return false }
                }
            case .branches(let branches, let scale, let depth):
                guard depth <= Self.maximumProofDepth, charge(branches.count) else { return false }
                for branch in branches {
                    push(branch.conclusion, scale: scale)
                    push(branch.leftLabel ?? [], scale: scale)
                    push(branch.rightLabel ?? [], scale: scale)
                    if !branch.premises.isEmpty {
                        pending.append(.branches(branch.premises, scale: scale, depth: depth + 1))
                    }
                }
            }
        }
        return true
    }

    private mutating func inspect(_ kind: ParseNode.Kind, scale: Scale) -> Bool {
        func fits(_ size: SwaTex.Measurement?) -> Bool {
            guard let size else { return true }
            guard let em = Self.emPerUnit[size.unit] else { return false }
            return Self.fits(size.number * em, scale: scale)
        }
        switch kind {
        case .rule(let shift, let width, let height):
            return fits(shift) && fits(width) && fits(height)
        case .size(let value, _), .kern(let value):
            return fits(value)
        case .cr(_, let size), .infix(_, let size):
            return fits(size)
        case .raiseBox(let dy, let body):
            guard fits(dy) else { return false }
            push([body], scale: scale)
        case .genfrac(_, let numerator, let denominator, _, _, _, let size):
            guard fits(size) else { return false }
            push([numerator, denominator], scale: scale.inScript)
        case .includeGraphics(_, let width, let height, let totalheight, _):
            return fits(width) && fits(height) && fits(totalheight)
        case .array(let info):
            let rows = info.body.count
            guard rows <= remainingCells else { return false }
            let width = max(1, info.body.lazy.map(\.count).max() ?? 0)
            guard rows == 0 || width <= remainingCells / rows else { return false }
            remainingCells -= rows * width
            // SwaTex uses 12 pt (1.2 em) for the array's baseline skip before stretching it.
            guard Self.fits(info.arraystretch * 1.2, scale: scale), info.rowGaps.allSatisfy(fits),
                charge(info.cols?.count ?? 0)
            else { return false }
            for spec in info.cols ?? [] {
                guard Self.fits(spec.pregap ?? 0, scale: scale), Self.fits(spec.postgap ?? 0, scale: scale)
                else { return false }
            }
            for rules in info.hLinesBeforeRow {
                guard charge(rules.count) else { return false }
            }
            for row in info.body { push(row, scale: scale) }
            for case .explicit(let tag) in info.tags ?? [] { push(tag, scale: scale) }
        case .html(let attributes, let body):
            guard charge(attributes["style"]?.utf8.count ?? 0), let factor = Self.fontScale(attributes["style"]) else {
                return false
            }
            return pushScaled(body, scale: scale, factor: factor)
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
            return (1...4).contains(size)
        case .ordGroup(let body, _), .operatorName(let body, _, _, _), .text(let body, _),
            .color(_, let body), .leftRight(let body, _, _, _), .phantom(let body), .mclass(_, let body, _),
            .href(_, let body), .hbox(let body), .pmb(_, let body):
            push(body, scale: scale)
        case .op(_, _, _, _, _, _, let body):
            push(body ?? [], scale: scale)
        case .supSub(let base, let sup, let sub):
            if let base { push([base], scale: scale) }
            push([sup, sub].compactMap { $0 }, scale: scale.inScript)
        case .sqrt(let body, let label):
            push([body], scale: scale)
            if let label { push([label], scale: scale.inScript) }
        case .xArrow(_, let body, let label):
            push([body], scale: scale.inScript)
            if let label { push([label], scale: scale.inScript) }
        case .accent(_, _, _, let body), .accentUnder(_, _, _, let body), .font(_, let body),
            .overline(let body), .underline(let body), .vphantom(let body), .smash(let body, _, _),
            .environment(_, let body), .horizBrace(_, _, let body), .enclose(_, _, _, let body),
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
            push([above, below].compactMap { $0 }, scale: scale.inScript)
        case .proofTree(let tree):
            pending.append(.branches([tree], scale: scale, depth: 1))
        case .verb(let body, _):
            return charge(body.utf8.count)
        case .atom, .mathOrd, .textOrd, .opToken, .accentToken, .spacing, .colorToken, .leftRightRight, .middle,
            .internalNode, .url, .raw, .noNumber:
            break
        }
        return true
    }

    private static func fits(_ em: Double, scale: Scale) -> Bool {
        em.isFinite && abs(em) <= maximumEm / scale.product
    }

    private mutating func pushScaled(_ nodes: [ParseNode], scale: Scale, factor: Double, newStyle: Double? = nil)
        -> Bool
    {
        guard factor > 0, Self.fits(factor, scale: scale) else { return false }
        // An outer reduction happens after its child has already been laid out in local coordinates.
        push(nodes, scale: Scale(product: max(1, scale.product * factor), minimumStyle: newStyle ?? scale.minimumStyle))
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

    private static func fontScale(_ style: String?) -> Double? {
        // Match SwaTex's Character.isWhitespace exactly for cascading declarations.
        func trimmed(_ part: Substring) -> Substring {
            guard let first = part.firstIndex(where: { !$0.isWhitespace }),
                let last = part.lastIndex(where: { !$0.isWhitespace })
            else { return "" }
            return part[first...last]
        }
        var factor = 1.0
        for declaration in style?.split(separator: ";") ?? [] {
            guard let colon = declaration.firstIndex(of: ":"),
                trimmed(declaration[..<colon]).lowercased() == "font-size"
            else { continue }
            let value = trimmed(declaration[declaration.index(after: colon)...])
                .lowercased().filter { $0 != " " }
            let raw: Double?
            if value.hasSuffix("em") {
                raw = Double(value.dropLast(2))
            } else if value.hasSuffix("px") {
                raw = Double(value.dropLast(2)).map { $0 / 16 }
            } else if value.hasSuffix("%") {
                raw = Double(value.dropLast()).map { $0 / 100 }
            } else {
                raw = nil
            }
            // An unsupported CSS value clears an earlier font-size in SwaTex's style parser.
            guard let raw else {
                factor = 1
                continue
            }
            guard raw > 0, raw <= maximumEm else { return nil }
            factor = abs(raw - 1) < 0.001 ? 1 : raw
        }
        return factor
    }
}
