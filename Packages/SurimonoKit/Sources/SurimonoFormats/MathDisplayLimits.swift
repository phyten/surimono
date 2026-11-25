import SwaTex

/// Check the actual boxes before SwaTex emits any marks. This catches changes to the engine's
/// choice of glyph, stock path or overlay without having to predict that choice from the AST.
struct MathDisplayLimits {
    private var remaining = MathLayoutLimits.maximumDrawWork
    private var pending: [(box: LayoutBox, scale: Double)] = []
    // Sum absolute vertical distances, including hidden content and placements. At this magnitude
    // a Double ulp is much smaller than even the smallest permitted vertical dash step.
    private var travel = 0.0

    static func accepts(_ root: LayoutBox) -> Bool {
        var limits = Self()
        guard limits.push(root, at: 1) else { return false }
        while let (box, scale) = limits.pending.popLast() {
            guard limits.inspect(box, at: scale) else { return false }
        }
        return true
    }

    private mutating func charge(_ count: Int) -> Bool {
        guard count <= remaining else { return false }
        remaining -= count
        return true
    }

    private mutating func push(_ box: LayoutBox?, at scale: Double) -> Bool {
        guard let box else { return true }
        guard charge(1), scale >= MathLayoutLimits.minimumScale, scale <= MathLayoutLimits.maximumEm,
            box.width.isFinite, abs(box.width * scale) <= MathLayoutLimits.maximumExtent,
            distance(abs(box.height) + abs(box.depth), at: scale)
        else { return false }
        pending.append((box, scale))
        return true
    }

    private mutating func distance(_ em: Double, at scale: Double) -> Bool {
        travel += abs(em) * scale
        return travel <= 0x1p26
    }

    private mutating func inspect(_ box: LayoutBox, at scale: Double) -> Bool {
        switch box.content {
        case .hbox(let children):
            for child in children where !push(child, at: scale) { return false }
        case .vbox(let children):
            for child in children {
                switch child.kind {
                case .box(let body): guard push(body, at: scale) else { return false }
                case .kern(let gap): guard distance(gap, at: scale) else { return false }
                }
            }
        case .fraction(let top, let bottom, let up, let down, _, let ts, let bs):
            return distance(abs(up) + abs(down), at: scale) && charge(1)
                && push(top, at: scale * ts) && push(bottom, at: scale * bs)
        case .supSub(let base, let sup, let sub, let up, let down, let ss, let bs, _, _, _):
            return distance(abs(up) + abs(down), at: scale)
                && push(base, at: scale) && push(sup, at: scale * ss) && push(sub, at: scale * bs)
        case .opLimits(let base, let sup, let sub, let shift, let supKern, let subKern, _, let ss, let bs):
            return distance(abs(shift) + abs(supKern) + abs(subKern), at: scale)
                && push(base, at: scale) && push(sup, at: scale * ss) && push(sub, at: scale * bs)
        case .radical(let body, let index, _, let indexScale, _, _):
            return charge(2) && push(body, at: scale) && push(index, at: scale * indexScale)
        case .accent(let base, let accent, let gap, _, _, let under):
            return distance(abs(gap) + abs(under), at: scale) && push(base, at: scale) && push(accent, at: scale)
        case .leftRight(let left, let right, let inner):
            return push(left, at: scale) && push(inner, at: scale) && push(right, at: scale)
        case .array(let array):
            guard distance(array.offset, at: scale) else { return false }
            for h in array.rowHeights where !distance(h, at: scale) { return false }
            for d in array.rowDepths where !distance(d, at: scale) { return false }
            let vertical = array.track.rules.count(where: \.isDashed)
            var horizontal = 0
            for boundary in array.hlinesBeforeRow {
                guard charge(boundary.count) else { return false }
                horizontal += boundary.count(where: { $0 })
            }
            guard charge(array.track.rules.count),
                dashes(vertical, length: box.height + box.depth, thickness: array.ruleThickness, scale: scale),
                dashes(horizontal, length: array.track.width, thickness: array.ruleThickness, scale: scale)
            else { return false }
            for row in array.cells {
                for cell in row where !push(cell, at: scale) { return false }
            }
            for tag in array.rowTags where !push(tag, at: scale) { return false }
        case .svgPath(let commands, _):
            return charge(commands.count)
        case .angl(let commands, let body):
            return charge(commands.count) && push(body, at: scale)
        case .framed(let body, _, _, _, _, _):
            return charge(5) && push(body, at: scale)
        case .scaled(let body, let factor):
            return push(body, at: scale * factor)
        case .raiseBox(let body, let offset), .underline(let body, _, let offset):
            return distance(offset, at: scale) && push(body, at: scale)
        case .overline(let body, _):
            return push(body, at: scale)
        case .proofTree(let children, let rules):
            guard charge(rules.count) else { return false }
            for rule in rules where rule.dashed {
                guard dashes(1, length: rule.width, thickness: rule.thickness, scale: scale) else { return false }
            }
            for child in children {
                guard distance(child.baselineY, at: scale), push(child.box, at: scale) else { return false }
            }
        case .rule, .glyph, .kern, .empty, .degraded:
            break
        }
        return true
    }

    private mutating func dashes(_ count: Int, length: Double, thickness: Double, scale: Double) -> Bool {
        guard count > 0 else { return true }
        let period = 8 * (thickness * scale)
        guard period.isNormal, period >= 0.25 * MathLayoutLimits.minimumScale else { return false }
        // SwaTex adds this period to an absolute y coordinate. Allow half a step for rounding
        // and one final partial segment. Check the floating result before converting to Int.
        let segments = 1 + (abs(length * scale) / (period / 2)).rounded(.up)
        guard segments <= Double(remaining / count) else { return false }
        return charge(count * Int(segments))
    }
}
