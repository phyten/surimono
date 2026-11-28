import Foundation

/// Keeps an equation number clear of a centred display that is too wide to share its line.
/// Both the single-column preparation and the column flow apply the same rule at their own measure.
enum LaTeXEquationTags {
    /// Defines `surimonoFitEquationTags(root)`. It is idempotent so the flow can repeat it at column width.
    ///
    /// This approximates TeX's display placement (The TeXbook, chapter 19): with display width `z`,
    /// formula width `w`, number width `e` and a math quad `q`, the number moves to a line of its own
    /// when `w + e + q > z`. Otherwise, when centring leaves less than `2e` beside the formula,
    /// the formula is centred in the room that remains next to the number.
    ///
    /// It is an approximation: `w` is the drawn SVG width rather than TeX's natural box, and TeX would
    /// first try to shrink the formula's glue. It therefore applies only to a horizontal, centred display
    /// with a single number. Indented displays (mathindent, a number inset), vertical text and aligned
    /// rows with their own numbers keep the geometry their styles give them.
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
            const css = getComputedStyle(eq), mathCSS = getComputedStyle(math);
            if (!String(css.writingMode || 'horizontal-tb').startsWith('horizontal')) return null;
            if (parseFloat(mathCSS.paddingLeft) || parseFloat(mathCSS.paddingRight)) return null;
            const box = math.getBoundingClientRect(), ink = svg.getBoundingClientRect();
            const z = box.width, w = ink.width;
            const e = tag.getBoundingClientRect().width;
            if (!(z > 0 && w > 0 && e > 0)) return null;
            // An overfull display has no side gaps to compare; any other display must be centred.
            if (w < z - 0.5 && Math.abs((ink.left - box.left) - (box.right - ink.right)) > 1) return null;
            // Rectangles and the font size share the layout zoom only after scaling the em by it.
            const q = parseFloat(css.fontSize) * (z / (math.clientWidth || z));
            const left = css.getPropertyValue('--latex-eqno-start').trim() === '0px';
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
