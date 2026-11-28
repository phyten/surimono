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

    /// A column is short when none of its cells needs more than this share of the table's room on one line.
    static let shortColumnShare = 0.30
    /// What a long column keeps beside short columns kept whole: this many ems, or its share of the room...
    static let longColumnEms = 8.0
    /// ...this share of the room, divided among the long columns, whichever is wider; never more than it had.
    static let longColumnsShare = 0.30

    /// Which columns are short, and how narrow the other columns may become when short columns are kept whole.
    static let labelFunctions = """
        function isShortColumn(width, room) {
            return width <= \(shortColumnShare) * room;
        }
        function columnFloor(before, fontSize, room, longColumns) {
            const floor = Math.max(\(longColumnEms) * fontSize, \(longColumnsShare) * room / Math.max(1, longColumns));
            return Math.min(before, floor);
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
        let script = scaleFunction + "\n" + labelFunctions + "\n" + Self.script
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

        // A column of labels ("Status", a date, a short Japanese word, which can break between any two
        // characters) gets next to nothing beyond its narrowest width beside a long cell, and its words come
        // out one character a line. Short columns where a cell wraps are kept on one line, all at once, and
        // only if the table still fits, no long column gets too narrow, and no short column starts to wrap;
        // otherwise the table is left as it was.

        // The pieces of text in a cell, one rectangle a line of each text node: elements' own boxes would
        // swallow lines.
        function textRects(cell) {
            const rects = [];
            const walker = document.createTreeWalker(cell, NodeFilter.SHOW_TEXT);
            for (let node = walker.nextNode(); node; node = walker.nextNode()) {
                if (!node.data.trim()) continue;
                const range = document.createRange();
                range.selectNodeContents(node);
                for (const rect of range.getClientRects()) if (rect.width && rect.height) rects.push(rect);
            }
            return rects;
        }
        // Inline code and the like sit a little higher or lower on the same line, so a line only starts where
        // a piece of text lies wholly below the one before.
        function lines(cell) {
            const rects = textRects(cell).sort((a, b) => a.top - b.top);
            let count = 0, bottom = -Infinity;
            for (const rect of rects) {
                if (rect.top >= bottom - 1) {
                    count++;
                    bottom = rect.bottom;
                } else {
                    bottom = Math.max(bottom, rect.bottom);
                }
            }
            return count;
        }
        // How to keep a cell's text on one line, element by element, or null when that would change more than
        // its wrapping. Text that collapses its spaces (or keeps only line breaks) is kept with nowrap; text
        // that keeps its spaces, as a CSV cell does, with pre, which keeps them too. A line break that is kept,
        // pictures, formulas, tables and blocks of any kind leave the column alone.
        function wholeLine(cell) {
            const collapses = { normal: 'collapse', nowrap: 'collapse', 'pre-line': 'preserve-breaks' };
            const changes = [];
            for (const el of [cell, ...cell.querySelectorAll('*')]) {
                const css = getComputedStyle(el);
                if (el !== cell && (css.display !== 'inline' || el.matches('br, img, svg, math, table, .math'))) {
                    return null;
                }
                const space = css.whiteSpaceCollapse || collapses[css.whiteSpace] || 'preserve';
                const own = [...el.childNodes].some(node => node.nodeType === Node.TEXT_NODE && node.data.includes('\n'));
                if (space !== 'collapse' && own) return null;
                changes.push([el, space === 'collapse' || space === 'preserve-breaks' ? 'nowrap' : 'pre']);
            }
            return changes;
        }
        // The width a cell needs on one line, in its own pixels, estimated: its pieces of text side by side, with
        // the padding and rules of the cell and of the inline elements in it. Spaces between elements and at the
        // ends of wrapped lines are left out, so it can come out short; it only picks the columns to try, and
        // the columns kept are measured again on one line. Rectangles are in the page's pixels,
        // so they are converted by the cell's own drawn and laid-out widths.
        function oneLine(cell) {
            const rects = textRects(cell);
            if (!rects.length) return 0;
            const drawn = cell.getBoundingClientRect().width;
            const ratio = drawn ? cell.offsetWidth / drawn : 1;
            let width = rects.reduce((sum, rect) => sum + rect.width, 0) * ratio;
            for (const el of [cell, ...cell.querySelectorAll('*')]) {
                const css = getComputedStyle(el);
                width += sides(css, 'padding') + borders(css) + (el === cell ? 0 : sides(css, 'margin'));
            }
            return width;
        }
        // The width of a column's content box, from any of its cells: they share it.
        // The text width a column leaves its narrowest cell: cells share the column's width, but not always
        // their padding. Content boxes, whatever box the cells size.
        function contentOf(column) {
            const shown = column.cells.filter(cell => cell.offsetWidth);
            return shown.reduce((least, cell) => Math.min(least, contentWidth(getComputedStyle(cell))), Infinity);
        }
        // The width a column takes, padding and rules included, in its table's parent's pixels.
        function columnWidth(column, zoom) {
            return column.cells.reduce((most, cell) => Math.max(most, cell.offsetWidth), 0) * zoom;
        }
        function labelPlan(item) {
            const table = item.table, rows = [...table.rows];
            const cells = rows.flatMap(row => [...row.cells]);
            // Spanning cells (rowspan="0" spans the rest of the group) put other columns under a column's place.
            if (!cells.length || cells.some(cell => cell.colSpan !== 1 || cell.rowSpan !== 1)) return null;
            const count = rows.reduce((most, row) => Math.max(most, row.cells.length), 0);
            // A fixed layout sizes its columns without their content: kept whole, a label would only spill.
            if (count < 2 || getComputedStyle(table).tableLayout === 'fixed') return null;
            const zoom = zoomOf(table);
            const columns = [];
            for (let index = 0; index < count; index++) {
                const own = rows.map(row => row.cells[index]).filter(Boolean);
                const column = { cells: own, filled: own.some(cell => cell.textContent.trim()), short: false };
                const changes = own.map(wholeLine);
                if (column.filled && changes.every(Boolean)) {
                    column.changes = changes.flat();
                    const width = own.reduce((most, cell) => Math.max(most, oneLine(cell)), 0) * zoom;
                    column.short = isShortColumn(width, item.limit);
                    column.lines = own.map(lines);
                }
                column.before = contentOf(column);
                columns.push(column);
            }
            const kept = columns.filter(column => column.short && column.lines.some(count => count > 1));
            return kept.length ? { item, columns, kept, zoom } : null;
        }
        // Each item is a table and the width it may take. Returns the tables whose short columns were kept.
        function keepLabels(items) {
            const plans = items.map(labelPlan).filter(Boolean);
            // Each element's style attribute is kept whole as it stands now, after any earlier step of TableFit,
            // so that going back restores exactly that, whichever white-space properties it named.
            for (const plan of plans) {
                plan.changed = plan.kept.flatMap(column => column.changes).map(([el, value]) =>
                    [el, value, el.getAttribute('style')]);
            }
            // Descendants too: wrapping a wide table may have set their white-space of their own.
            for (const plan of plans) for (const [el, value] of plan.changed) set(el, 'white-space', value);
            for (const plan of plans) {
                const { item, columns, zoom } = plan;
                const long = columns.filter(column => !column.short && column.filled);
                const fontSize = px(getComputedStyle(item.table).fontSize);
                // The width a kept column needs was estimated from its text, which can miss spaces; laid out on
                // one line, each must still be short. offsetWidth is rounded to whole pixels.
                plan.accepted = outer(item.table) <= item.limit + 0.5
                    && plan.kept.every(column => column.cells.every(cell => lines(cell) <= 1))
                    && plan.kept.every(column => isShortColumn(columnWidth(column, zoom) - 0.5, item.limit))
                    && long.every(column =>
                        contentOf(column) >= columnFloor(column.before, fontSize, item.limit / zoom, long.length) - 0.5)
                    && columns.filter(column => column.short && !plan.kept.includes(column))
                        .every(column => column.cells.every(cell => lines(cell) <= 1));
            }
            for (const plan of plans) {
                if (plan.accepted) continue;
                for (const [el, , style] of plan.changed) {
                    if (style === null) el.removeAttribute('style');
                    else el.setAttribute('style', style);
                }
            }
            return plans.filter(plan => plan.accepted).map(plan => plan.item.table);
        }

        function fitTables() {
            delete globalThis.surimonoFittedTables;
            delete globalThis.surimonoTableFitLog;
            const wide = [], fitting = [];
            for (const table of document.querySelectorAll('table')) {
                // The outer grid owns its tracks, including nested tables. TeX graphics and slides have
                // already been measured and placed by their own scripts.
                if (table.parentElement.closest('table,svg,.latex-graphic-box,.beamer-frame') || !table.offsetWidth) continue;
                const place = roomFor(table);
                if (!place) continue;
                if (outer(table) <= place.room + 0.5) {
                    fitting.push({ table, limit: place.room });
                    continue;
                }
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
            const labelled = keepLabels(fitting);
            if (!wide.length) {
                // Kept, a table fits on paper though it may be wider than the view that checks for overflow.
                if (labelled.length) globalThis.surimonoFittedTables = new WeakSet(labelled);
                return labelled.length > 0;
            }

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
            // Wrapped, the long cells give way; short columns beside them are kept whole when the table fits.
            // A kept table fitted already, so the tables still too wide are the same.
            labelled.push(...keepLabels(wide.map(item => ({ table: item.table, limit: item.room }))));
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
            globalThis.surimonoFittedTables = new WeakSet([...fitted.map(item => item.table), ...labelled]);
            // What each step measured, for a test that fails on a WebKit it cannot run on to report.
            globalThis.surimonoTableFitLog = wide.map(
                ({ room, unwrapped, wrapped, clamped, scale, narrowing, inside }) =>
                    ({ room, unwrapped, wrapped, clamped, scale, narrowing, inside, devicePixelRatio }));
            return true;
        }
        """#
}
