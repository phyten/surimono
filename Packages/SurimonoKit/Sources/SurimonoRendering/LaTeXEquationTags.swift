import Foundation

/// TeX places an equation number beside a centred display only when the number fits.
/// Both the single-column preparation and the column flow apply the same rule at their own measure.
enum LaTeXEquationTags {
    /// Defines `surimonoFitEquationTags(root)`. It is idempotent so the flow can repeat it at column width.
    ///
    /// The rule follows TeX's display placement (The TeXbook, chapter 19): with display width `z`,
    /// formula width `w`, number width `e` and a math quad `q`, the number moves to a line of its own
    /// when `w + e + q > z`. Otherwise, when centring leaves less than `2e` beside the formula,
    /// the formula is centred in the room that remains next to the number.
    static let definition = #"""
        function surimonoFitEquationTags(root) {
          const equations = [...root.querySelectorAll('.latex-equation')].filter(eq =>
            eq.querySelector(':scope > .eqno') && eq.querySelector(':scope > .math-display > svg:only-child') &&
            !eq.querySelector('.latex-row-number'));
          for (const eq of equations) {
            eq.removeAttribute('data-latex-tag-line');
            eq.removeAttribute('data-latex-tag-room');
            eq.style.removeProperty('--latex-tag-room');
          }
          const plans = equations.map(eq => {
            const tag = eq.querySelector(':scope > .eqno');
            const math = eq.querySelector(':scope > .math-display');
            const svg = math.querySelector(':scope > svg');
            const z = math.getBoundingClientRect().width, w = svg.getBoundingClientRect().width;
            const e = tag.getBoundingClientRect().width;
            // Rectangles and the font size share the layout zoom only after scaling the em by it.
            const q = parseFloat(getComputedStyle(eq).fontSize) * (z / (math.clientWidth || z));
            const left = getComputedStyle(eq).getPropertyValue('--latex-eqno-start').trim() === '0px';
            if (!(z > 0 && w > 0 && e > 0)) return null;
            if (w + e + q > z) return {eq, line: left ? 'above' : 'below'};
            if ((z - w) / 2 < 2 * e) return {eq, room: e * (math.clientWidth || z) / z, left};
            return null;
          });
          for (const plan of plans) {
            if (!plan) continue;
            if (plan.line) plan.eq.dataset.latexTagLine = plan.line;
            else {
              plan.eq.dataset.latexTagRoom = plan.left ? 'start' : 'end';
              plan.eq.style.setProperty('--latex-tag-room', plan.room + 'px');
            }
          }
        }
        """#
}
