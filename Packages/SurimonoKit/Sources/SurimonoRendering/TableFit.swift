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

        // An element's content width in its own pixels, with its fractions: clientWidth and offsetWidth are
        // rounded to whole pixels, and two roundings could make a table that fits look a pixel too wide. The
        // used width is the content box unless the element sizes its border box.
        function contentWidth(css) {
            const used = px(css.width);
            return css.boxSizing === 'border-box' ? used - sides(css, 'padding') - borders(css) : used;
        }
        // The width the table may take, in its parent's CSS pixels, and the parent's zoom (that of the text
        // scale on the root, say). Each element's lengths are in its own pixels, so each ancestor's content
        // width is converted down to the table's parent. Inside a flex or grid container the table's room
        // depends on its neighbours, which this does not measure: null leaves such a table as it was.
        function roomFor(table) {
            let room = Infinity, ancestorZoom = 1;
            for (let p = table.parentElement; p; p = p.parentElement) {
                const css = getComputedStyle(p);
                if (/flex|grid/.test(css.display)) return null;
                if (css.display !== 'inline' && css.display !== 'contents' && px(css.width) > 0) {
                    room = Math.min(room, contentWidth(css) / ancestorZoom);
                }
                ancestorZoom *= zoomOf(p);
            }
            const css = getComputedStyle(table);
            return { room: room - Math.max(0, sides(css, 'margin')) * zoomOf(table), zoom: ancestorZoom };
        }
        // The painted width of the grid in its parent's pixels. offsetWidth counts the outer half of a
        // collapsed rule, which the used width leaves out, and scrollWidth content that overflows the table
        // and is not clipped; both are rounded to whole pixels, so half a pixel is taken off them. The used
        // width keeps the fractions of a table that fits exactly.
        function outer(table) {
            const css = getComputedStyle(table);
            const used = css.boxSizing === 'border-box' ? px(css.width) : 0;
            const spill = css.overflowX === 'visible' ? table.scrollWidth : 0;
            return Math.max(used, table.offsetWidth - 0.5, spill - 0.5) * zoomOf(table);
        }

        function fitTables() {
            delete globalThis.surimonoFittedTables;
            delete globalThis.surimonoTableFitLog;
            const wide = [];
            for (const table of document.querySelectorAll('table')) {
                // The outer grid owns its tracks, including nested tables. TeX graphics and slides have
                // already been measured and placed by their own scripts.
                if (table.parentElement.closest('table,svg,.latex-graphic-box,.beamer-frame') || !table.offsetWidth) continue;
                const place = roomFor(table);
                if (!place || outer(table) <= place.room + 0.5) continue;
                // The reserve is a length on paper, so it is the same at every text scale.
                const reserved = reserve / place.zoom;
                // A block is placed from its container's start edge, whatever the direction of its own cells,
                // so the container's direction decides which edge stays put. A table placed from the right
                // keeps the reserve at its left edge as well, where an overflow would widen the page too.
                const fromRight = getComputedStyle(table.parentElement).direction === 'rtl';
                const room = place.room - reserved * (fromRight ? 2 : 1);
                if (room <= 0) continue;
                const css = getComputedStyle(table), zoom = zoomOf(table);
                wide.push({
                    table, room, reserved, zoom, scale: 1, narrowing: 1, fromRight,
                    marginRight: px(css.marginRight) * zoom,
                });
            }
            if (!wide.length) return false;

            // The print cuts the column's right edge back to whole points, and half of a collapsed outside
            // rule lies beyond the table's box. A table placed from the right starts at that edge, so its
            // free pixels go on the right.
            const keepRight = (item, zoom) => {
                if (item.fromRight) set(item.table, 'margin-right', (item.marginRight + item.reserved) / zoom + 'px');
            };
            // Formulas and pictures keep their own lines: they are drawn, not wrapped.
            const drawn = 'svg, svg *, math, math *, .math, .math *';
            // Every value is read before any is written, so styles are worked out once per step.
            function restyle(items, property, value) {
                const changes = [];
                for (const { table } of items) {
                    for (const el of [table, ...table.querySelectorAll('*')]) {
                        if (el.matches(drawn)) continue;
                        const next = value(getComputedStyle(el)[property]);
                        if (next) changes.push([el, next]);
                    }
                }
                for (const [el, next] of changes) set(el, property === 'whiteSpace' ? 'white-space' : 'overflow-wrap', next);
            }
            // Geometry is read for all tables before any is written, so the page is laid out once per pass.
            const overflowing = items => items.filter(item => (item.width = outer(item.table)) > item.room + 0.5);

            // First let lines break at the table's own size, without its minimum width: only what stops a
            // line from breaking changes ('pre' keeps its spaces and line breaks). Breaking inside words is
            // the next step, for tables that need it.
            restyle(wide, 'whiteSpace', space => space === 'nowrap' ? 'normal' : space === 'pre' ? 'pre-wrap' : null);
            for (const item of wide) {
                set(item.table, 'box-sizing', 'border-box');
                set(item.table, 'min-width', '0');
                set(item.table, 'max-width', item.room / item.zoom + 'px');
                keepRight(item, item.zoom);
            }
            let over = overflowing(wide);
            for (const item of wide) item.unwrapped = item.width;
            restyle(over, 'overflowWrap', wrap => wrap === 'anywhere' ? null : 'anywhere');
            over = overflowing(over);

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
            for (const item of wide) item.wrapped = item.width;
            // Not every WebKit holds a table to its max-width (macOS 15 kept the author's fixed width), so
            // the width itself is first set to the column, still at the table's own size. Only what its
            // contents keep wider than that is zoomed.
            for (const item of over) zoomTable(item);
            over = overflowing(over);
            for (const item of wide) item.clamped = item.width;
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
                    // took off less than half of what it was meant to went past that point and would only
                    // thin the rules. It goes back to the zoom that would have taken off what this one did
                    // at full effect, which is where the text stopped, and no further than the last zoom.
                    if (item.last.width - item.width < (item.last.width - item.room) / 2) {
                        const reached = item.last.scale * item.width / item.last.width;
                        item.scale = Math.min(item.last.scale, Math.max(item.scale, reached));
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

            // A table counts as fitted when its painted width is within its room; anything else is still
            // reported as wider than the page. Only the width is compared, not where the table sits: a table
            // moved sideways by a style of its own (relative positioning, say) is not detected here.
            const fitted = wide.filter(item => {
                item.inside = outer(item.table) * item.narrowing <= item.room + 0.5;
                return item.inside;
            });
            globalThis.surimonoFittedTables = new WeakSet(fitted.map(item => item.table));
            // What each step measured, for a test that fails on a WebKit it cannot run on to report.
            globalThis.surimonoTableFitLog = wide.map(
                ({ room, unwrapped, wrapped, clamped, scale, narrowing, inside }) =>
                    ({ room, unwrapped, wrapped, clamped, scale, narrowing, inside, devicePixelRatio }));
            return true;
        }
        """#
}
