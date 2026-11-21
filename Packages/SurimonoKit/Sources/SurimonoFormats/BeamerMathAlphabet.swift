import SwaTex

extension MathRenderer {
    /// Apply the public math alphabet to individual ordinary atoms. Wrapping the whole
    /// formula in a font group would lose inter-atom spacing and override explicit alphabets.
    static func sansLetter(_ atom: ParseNode, depth: Int) -> ParseNode {
        guard depth < 48 else { return atom }
        func child(_ node: ParseNode) -> ParseNode { sansLetter(node, depth: depth + 1) }
        var result = atom
        switch atom.kind {
        case .mathOrd(let text), .textOrd(let text):
            if atom.mode == .math, text.count == 1, let c = text.first, c.isASCII, c.isLetter || c.isNumber {
                result.kind = .font(font: "mathsf", body: atom)
            }
        case .ordGroup(let body, let simple): result.kind = .ordGroup(body: body.map(child), semisimple: simple)
        case .supSub(let base, let sup, let sub):
            result.kind = .supSub(base: base.map(child), sup: sup.map(child), sub: sub.map(child))
        case .genfrac(let continued, let numer, let denom, let bar, let left, let right, let size):
            result.kind = .genfrac(
                continued: continued, numer: child(numer), denom: child(denom), hasBarLine: bar, leftDelim: left,
                rightDelim: right, barSize: size)
        case .sqrt(let body, let index): result.kind = .sqrt(body: child(body), index: index.map(child))
        case .leftRight(let body, let left, let right, let color):
            result.kind = .leftRight(body: body.map(child), left: left, right: right, rightColor: color)
        case .color(let color, let body): result.kind = .color(color: color, body: body.map(child))
        case .styling(let style, let body): result.kind = .styling(style: style, body: body.map(child))
        case .sizing(let size, let body): result.kind = .sizing(size: size, body: body.map(child))
        case .overline(let body): result.kind = .overline(body: child(body))
        case .underline(let body): result.kind = .underline(body: child(body))
        case .accent(let label, let stretch, let shift, let base):
            result.kind = .accent(label: label, isStretchy: stretch, isShifty: shift, base: child(base))
        case .accentUnder(let label, let stretch, let shift, let base):
            result.kind = .accentUnder(label: label, isStretchy: stretch, isShifty: shift, base: child(base))
        case .array(var array):
            array.body = array.body.map { $0.map(child) }
            result.kind = .array(array)
        default: break
        }
        return result
    }
}
