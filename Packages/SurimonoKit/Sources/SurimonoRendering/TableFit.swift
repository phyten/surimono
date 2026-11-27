import SurimonoCore
import WebKit

/// Keeps a table that is wider than its text column inside the column, so that WebKit does not shrink the whole page
/// to fit it (and cut off what the shrinking cannot reach).
///
/// A wide table first loses its no-wrap rules and its minimum width and may break inside a word, at its own type size.
/// Only a table that is still too wide is zoomed, alone, until its last column and rule are inside the column. The DOM
/// keeps its shape, so selectors around the table go on matching. Everything else on the page keeps its size, and a
/// document without such a table, or with tables that fit, is not touched.
enum TableFit {
    /// Whether the document is one Surimono typesets for a theme, laid out horizontally, with a table in it. A page
    /// laid out as its author's HTML, LaTeX in its own page layout, and vertical writing (whose compositor fits boxes
    /// to its rows itself) are left as they were.
    static func applies(
        to format: DocumentFormat, flow: PrintFlow, theme: PrintTheme, latexMargins: LaTeXPageMode?, body: String
    ) -> Bool {
        format.usesPrintTheme && flow == .horizontal
            && (format != .latex || !(latexMargins ?? .style).applies(to: theme))
            && body.range(of: "<table", options: .caseInsensitive) != nil
    }

    /// The next zoom of a table: the last one narrowed by how far the table still overflows, never enlarged.
    ///
    /// The zoom has to be found by measuring again, because WebKit does not scale a zoomed table's width in
    /// proportion: text keeps a minimum size and rules snap to whole pixels.
    static let scaleFunction = """
        function nextScale(scale, room, width) {
            return scale * Math.min(1, room / width);
        }
        """

    /// CSS pixels kept free on the right of a fitted table, for the half of a collapsed outside rule that lies
    /// beyond the table's box and for rounding in the print.
    static let reserve = 2

    /// How many times a table is zoomed and measured again before the rest of its overflow is taken out by narrowing
    /// it alone (when its text has reached WebKit's minimum size).
    static let zoomPasses = 6

    /// Fits the document's wide tables at the given layout width in CSS pixels (or the view's own width); returns
    /// whether any table was changed. The changed tables keep fixed widths, so the page can be laid out at another
    /// width afterwards (the print's) and give the same tables.
    @MainActor
    @discardableResult
    static func fit(in view: WKWebView, width: CGFloat?, until deadline: ContinuousClock.Instant) async throws -> Bool {
        let script = scaleFunction + "\n" + Self.script
        var arguments: [String: Any] = ["reserve": reserve, "passes": zoomPasses]
        if let width { arguments["width"] = Double(width) }
        return try await view.evaluateForPrinting(script, arguments: arguments, until: deadline) as? Bool == true
    }

    private static let script = #"""
        const root = document.documentElement;
        const prior = root.style.cssText;
        const px = value => parseFloat(value) || 0;
        const zoomOf = element => px(getComputedStyle(element).zoom) || 1;
        const set = (el, name, value) => el.style.setProperty(name, value, 'important');
        const sides = (css, name) => px(css[name + 'Left']) + px(css[name + 'Right']);
        const borders = css => px(css.borderLeftWidth) + px(css.borderRightWidth);
        try {
            if (typeof width === 'number') {
                // The root's margin box takes the layout width, as it does in the print.
                const css = getComputedStyle(root);
                const outside = sides(css, 'margin')
                    + (css.boxSizing === 'border-box' ? 0 : sides(css, 'padding') + borders(css));
                root.style.width = Math.max(0, width / zoomOf(root) - outside) + 'px';
            }
            await document.fonts.ready;
            return fitTables();
        } finally {
            root.style.cssText = prior;
        }

        // An element's content width in its own pixels. documentElement.clientWidth is the viewport's,
        // so the root's comes from its used width, which is the content box unless it sizes its border box.
        function contentWidth(el, css) {
            if (el !== root) return el.clientWidth - sides(css, 'padding');
            const used = px(css.width);
            return css.boxSizing === 'border-box' ? used - sides(css, 'padding') - borders(css) : used;
        }
        // The width the table may take, in its parent's CSS pixels. offsetWidth and clientWidth are in each
        // element's own pixels (after its zoom, such as the text scale on the root), so each ancestor's
        // content width is converted down to the table's parent.
        function roomFor(table) {
            let room = Infinity, ancestorZoom = 1;
            for (let p = table.parentElement; p; p = p.parentElement) {
                const css = getComputedStyle(p);
                if (css.display !== 'inline' && (p === root || p.clientWidth)) {
                    room = Math.min(room, contentWidth(p, css) / ancestorZoom);
                }
                ancestorZoom *= zoomOf(p);
            }
            const css = getComputedStyle(table);
            return room - Math.max(0, sides(css, 'margin')) * zoomOf(table);
        }
        // The painted width of the grid in its parent's pixels. Overflow that is clipped draws nothing.
        function outer(table) {
            const overflow = getComputedStyle(table).overflowX === 'visible' ? table.scrollWidth : 0;
            return Math.max(table.offsetWidth, overflow) * zoomOf(table);
        }

        function fitTables() {
            const wide = [];
            for (const table of document.querySelectorAll('table')) {
                // The outer grid owns its tracks, including nested tables. TeX graphics and slides have
                // already been measured and placed by their own scripts.
                if (table.parentElement.closest('table,.latex-graphic-box,.beamer-frame') || !table.offsetWidth) continue;
                const room = roomFor(table);
                if (room <= reserve || outer(table) <= room + 0.5) continue;
                const css = getComputedStyle(table), zoom = zoomOf(table);
                wide.push({
                    table, room: room - reserve, zoom, scale: 1, narrowing: 1,
                    // A block is placed from its container's start edge, whatever the direction of its own
                    // cells, so the container's direction decides which edge stays put.
                    fromRight: getComputedStyle(table.parentElement).direction === 'rtl',
                    marginRight: px(css.marginRight) * zoom,
                });
            }
            if (!wide.length) return false;

            // The print cuts the column's right edge back to whole points, and half of a collapsed outside
            // rule lies beyond the table's box. A table placed from the right starts at that edge, so its
            // free pixels go on the right.
            const keepRight = (item, zoom) => {
                if (item.fromRight) set(item.table, 'margin-right', (item.marginRight + reserve) / zoom + 'px');
            };
            // First wrap at the table's own size, without its minimum width. Inline styles keep the author's
            // other choices; only what stops a line from breaking changes ('pre' keeps its spaces and line
            // breaks). Every value is read before any is written, so styles are worked out once.
            const changes = [];
            for (const { table } of wide) {
                for (const el of [table, ...table.querySelectorAll('*')]) {
                    const css = getComputedStyle(el);
                    const space = css.whiteSpace === 'nowrap' ? 'normal' : css.whiteSpace === 'pre' ? 'pre-wrap' : null;
                    if (space || css.overflowWrap !== 'anywhere') changes.push([el, space, css.overflowWrap]);
                }
            }
            for (const [el, space, wrap] of changes) {
                if (space) set(el, 'white-space', space);
                if (wrap !== 'anywhere') set(el, 'overflow-wrap', 'anywhere');
            }
            for (const item of wide) {
                set(item.table, 'min-width', '0');
                set(item.table, 'max-width', item.room / item.zoom + 'px');
                keepRight(item, item.zoom);
            }
            // Geometry is read for all tables before any is written, so the page is laid out once per pass.
            const overflowing = items => items.filter(item => (item.width = outer(item.table)) > item.room + 0.5);
            let over = overflowing(wide);

            // Then zoom what is still too wide, filling the column: a zoomed table given the whole column
            // has its right rule at the column's edge. The width is fixed in the table's own pixels, so
            // percentage widths and the layout width no longer change it.
            function zoomTable(item) {
                const zoom = item.zoom * item.scale;
                set(item.table, 'width', item.room / zoom + 'px');
                set(item.table, 'max-width', item.room / zoom + 'px');
                set(item.table, 'zoom', String(zoom));
                keepRight(item, zoom);
            }
            let stalled = [];
            for (let pass = 0; pass < passes && over.length; pass++) {
                for (const item of over) {
                    item.last = { scale: item.scale, width: item.width };
                    item.scale = nextScale(item.scale, item.room, item.width);
                    zoomTable(item);
                }
                const still = overflowing(over);
                over = [];
                for (const item of still) {
                    // Text stops at WebKit's minimum size, and spacing set in ems stops with it. A zoom that
                    // took off less than half of what it was meant to would only thin the rules: go back.
                    if (item.last.width - item.width < (item.last.width - item.room) / 2) {
                        item.scale = item.last.scale;
                        zoomTable(item);
                        stalled.push(item);
                    } else {
                        over.push(item);
                    }
                }
            }

            // What still overflows is narrowed alone, measured as it now stands. A transform keeps the row
            // heights, so the table still breaks between its lines across pages, and the narrowed box is
            // what counts towards the page's width. It is placed from its container's start edge.
            const narrowed = overflowing([...stalled, ...over]);
            for (const item of narrowed) {
                item.narrowing = item.room / item.width;
                set(item.table, 'transform-origin', item.fromRight ? 'right top' : 'left top');
                set(item.table, 'transform', 'scaleX(' + item.narrowing + ')');
            }

            // Only a table whose painted grid lies inside its container's content box counts as fitted;
            // anything else is still reported as wider than the page. The table's own box is measured, not
            // its container's overflow, which other content may cause.
            const fitted = wide.filter(item => paintedInside(item));
            function paintedInside(item) {
                const table = item.table, parent = table.parentElement, css = getComputedStyle(parent);
                // offsetLeft is in each element's own pixels, and measured from the offset parent's padding
                // edge, or from the page when that parent is the body. It is rounded to whole pixels, hence
                // the pixel of slack (the reserve keeps the print clear of it).
                let start = table.offsetLeft * zoomOf(table);
                if (table.offsetParent !== parent || parent === document.body) {
                    start -= parent.offsetLeft + px(css.borderLeftWidth);
                }
                start -= px(css.paddingLeft);
                const width = outer(table), painted = width * item.narrowing;
                const left = item.fromRight ? start + width - painted : start;
                return left >= -1 && left + painted <= contentWidth(parent, css) + 1;
            }
            globalThis.surimonoFittedTables = new WeakSet(fitted.map(item => item.table));
            return true;
        }
        """#
}
