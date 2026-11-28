import SurimonoCore
import WebKit

/// Keeps a table that is wider than its text column inside the column, so that WebKit does not shrink the whole page
/// to fit it (and cut off what the shrinking cannot reach), and keeps its short columns from breaking.
///
/// One order holds for every table, whatever its number of columns or the format it came from: a column of short
/// values (a number, a date, a short word) stays on one line; the long columns take the wrapping, down to a floor;
/// and only when the short columns and that floor do not fit is the table zoomed, alone, to the smallest type WebKit
/// prints, and past that narrowed. The DOM keeps its shape, so selectors around the table go on matching. Everything
/// else on the page keeps its size, and a document without such a table, or with tables that fit without breaking a
/// short column, is not touched.
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
    /// What the long columns keep together beside short columns kept whole: this share of the room, never more
    /// than they had. How the table shares it among them is its own, as it was before.
    static let longColumnsShare = 0.30
    /// What each long column keeps for its text, in ems, never more than it had.
    static let longColumnEms = 4.0
    /// The smallest type a table is zoomed to, in CSS pixels as laid out for the print (7.2 points on paper), measured
    /// on the table's own type size; smaller type inside its cells shrinks with it. Zooming further would mostly thin
    /// the rules, and WebKit may stop shrinking text near this size anyway, so the zoom is still measured again after
    /// each step. What is left is taken out by narrowing.
    static let minimumTextPixels = 9.0
    /// How far a table may be narrowed sideways with its short columns kept whole. At half width digits and kana are
    /// still told apart on paper (40 columns of `c40` come to 0.6); further, strokes run together, and the short
    /// columns are let wrap where they already may (spaces, hyphens, between Japanese characters) instead.
    static let minimumNarrowing = 0.5

    /// Which columns are short, and the plan for a table: how far it is zoomed and narrowed so that its short columns
    /// stay on one line and each long column keeps its floor.
    ///
    /// `tablePlan` takes the room, the table's type size in the same pixels as the room, the type size as laid out
    /// for the print (which a text scale on the root makes larger), and its shown columns, each `{short, free,
    /// width, padding, text}` in the same pixels: a short column's width on one line; a long column's width as
    /// laid out, the most padding and rules a cell of it has, and the least text width a cell of it had. A free
    /// column is a short one let wrap, and asks for nothing. Only the sums count, so the plan does not depend on how
    /// many columns there are. It returns the zoom, the narrowing left after the zoom, the width the table needs at
    /// full size, the smallest zoom (at which its type reaches `minimumTextPixels`), each column's floor for its
    /// text (0 for a short or free column), and whether the short columns may be kept whole: not when that would
    /// narrow the table past `minimumNarrowing`.
    static let planFunctions = """
        function isShortColumn(width, room) {
            return width <= \(shortColumnShare) * room;
        }
        function keepsShortColumns(narrowing) {
            return narrowing >= \(minimumNarrowing);
        }
        function tablePlan(room, fontSize, textPixels, columns) {
            let shorts = 0, longEach = 0, longWidth = 0;
            const floors = columns.map(column => {
                if (column.free) return 0;
                if (column.short) {
                    shorts += column.width;
                    return 0;
                }
                const floor = Math.min(Math.max(0, column.text), \(longColumnEms) * fontSize);
                longEach += column.padding + floor;
                longWidth += column.width;
                return floor;
            });
            const longs = Math.max(longEach, Math.min(longWidth, \(longColumnsShare) * room));
            const need = shorts + longs;
            const least = textPixels > 0 ? Math.min(1, \(minimumTextPixels) / textPixels) : 1;
            const scale = need <= room ? 1 : Math.max(least, room / need);
            const narrowing = need <= room ? 1 : Math.min(1, room / (need * scale));
            return { scale, narrowing, need, least, floors, keepsShort: keepsShortColumns(narrowing) };
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
        let script = scaleFunction + "\n" + planFunctions + "\n" + Self.script
        var arguments: [String: Any] = ["reserve": reserve, "passes": zoomPasses]
        if let width { arguments["width"] = Double(width) }
        return try await view.evaluateForPrinting(script, arguments: arguments, until: deadline) as? Bool == true
    }

    private static let script = #"""
        const root = document.documentElement;
        const prior = root.style.cssText;
        const px = value => parseFloat(value) || 0;
        // Computed styles are live, so each element's is fetched once and read again as the page changes.
        const styles = new Map();
        const styleOf = el => {
            let css = styles.get(el);
            if (!css) styles.set(el, css = getComputedStyle(el));
            return css;
        };
        const zoomOf = element => px(styleOf(element).zoom) || 1;
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
                const css = styleOf(p);
                if (/flex|grid/.test(css.display)) return null;
                if (css.display !== 'inline' && css.display !== 'contents' && px(css.width) > 0) {
                    room = Math.min(room, contentWidth(css) / ancestorZoom);
                }
                ancestorZoom *= zoomOf(p);
            }
            const css = styleOf(table);
            return { room: room - Math.max(0, sides(css, 'margin')) * zoomOf(table), zoom: ancestorZoom };
        }
        // The painted width of the grid in its parent's pixels. offsetWidth counts the outer half of a
        // collapsed rule, which the used width leaves out, and scrollWidth content that overflows the table
        // and is not clipped; both are rounded to whole pixels, so half a pixel is taken off them. The used
        // width keeps the fractions of a table that fits exactly.
        function outer(table) {
            const css = styleOf(table);
            const used = css.boxSizing === 'border-box' ? px(css.width) : 0;
            const spill = css.overflowX === 'visible' ? table.scrollWidth : 0;
            return Math.max(used, table.offsetWidth - 0.5, spill - 0.5) * zoomOf(table);
        }

        // A column of short values ("Status", a date, a short Japanese word, which can break between any two
        // characters) gets next to nothing beyond its narrowest width beside a long cell, and its words come
        // out one character a line. Every such column is kept on one line, in every table that has one that
        // wraps or that is too wide: the long columns take the wrapping, each down to its floor, and when the
        // short columns and those floors do not fit, the whole table is zoomed (`tablePlan`), never a short
        // column broken. Only a table that would have to be narrowed past `minimumNarrowing` lets its short
        // columns wrap where they already may.

        // The pieces of text in a cell, one rectangle a line of each text node (elements' own boxes would
        // swallow lines), each with the block it is set in: the cell, or a paragraph in it. While the page is
        // only read, a cell's pieces are worked out once. (A var: the script runs `fitTables` above this line.)
        var pieceCache = null;
        function textPieces(cell) {
            const known = pieceCache?.get(cell);
            if (known) return known;
            const pieces = [];
            const walker = document.createTreeWalker(cell, NodeFilter.SHOW_TEXT);
            for (let node = walker.nextNode(); node; node = walker.nextNode()) {
                if (!node.data.trim()) continue;
                let block = node.parentElement;
                while (block !== cell && styleOf(block).display === 'inline') block = block.parentElement;
                const range = document.createRange();
                range.selectNodeContents(node);
                for (const rect of range.getClientRects()) if (rect.width && rect.height) pieces.push({ rect, block });
            }
            pieceCache?.set(cell, pieces);
            return pieces;
        }
        // Inline code and the like sit a little higher or lower on the same line, so a line only starts where
        // a piece of text lies wholly below the one before.
        function lines(pieces) {
            const rects = pieces.map(piece => piece.rect).sort((a, b) => a.top - b.top);
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
        // Whether a cell's text wraps: it takes more lines than it has paragraphs, which keep a line each
        // (a Word table sets each cell's text in one).
        function wraps(cell) {
            const pieces = textPieces(cell);
            return lines(pieces) > Math.max(1, new Set(pieces.map(piece => piece.block)).size);
        }
        // How to keep a cell's text unwrapped, element by element, or null when that would change more than
        // its wrapping. Text that collapses its spaces (or keeps only line breaks) is kept with nowrap; text
        // that keeps its spaces, as a CSV cell does, with pre, which keeps them too. A line break that is kept,
        // pictures, formulas, tables, lists and other boxes leave the column alone; paragraphs do not, though a
        // paragraph whose text then runs out of its cell gives the column up (`spills`).
        function wholeLine(cell) {
            const collapses = { normal: 'collapse', nowrap: 'collapse', 'pre-line': 'preserve-breaks' };
            const changes = [];
            for (const el of [cell, ...cell.querySelectorAll('*')]) {
                const css = styleOf(el);
                if (el !== cell) {
                    if (css.display === 'none') continue;
                    if (!/^(inline|block)$/.test(css.display) || el.matches('br, img, svg, math, table, .math')) {
                        return null;
                    }
                }
                const space = css.whiteSpaceCollapse || collapses[css.whiteSpace] || 'preserve';
                const own = [...el.childNodes].some(node => node.nodeType === Node.TEXT_NODE && node.data.includes('\n'));
                if (space !== 'collapse' && own) return null;
                changes.push([el, space === 'collapse' || space === 'preserve-breaks' ? 'nowrap' : 'pre']);
            }
            return changes;
        }
        // The width a cell needs unwrapped, in its own pixels, estimated: the pieces of text of its widest
        // paragraph side by side, with the padding and rules of the cell and of the elements in it. Spaces
        // between elements and at the ends of wrapped lines are left out, so it can come out short; it only
        // picks the columns to keep, and the columns kept are measured again unwrapped. Rectangles are in the
        // page's pixels, so they are converted by the cell's own drawn and laid-out widths.
        function oneLine(cell) {
            const pieces = textPieces(cell);
            if (!pieces.length) return 0;
            const drawn = cell.getBoundingClientRect().width;
            const ratio = drawn ? cell.offsetWidth / drawn : 1;
            const runs = new Map();
            for (const { rect, block } of pieces) runs.set(block, (runs.get(block) || 0) + rect.width);
            let width = Math.max(...runs.values()) * ratio;
            for (const el of [cell, ...cell.querySelectorAll('*')]) {
                const css = styleOf(el);
                width += sides(css, 'padding') + borders(css) + (el === cell ? 0 : sides(css, 'margin'));
            }
            return width;
        }
        // The width a column takes, padding and rules included, in its table's parent's pixels.
        function columnWidth(column, zoom) {
            return column.cells.reduce((most, cell) => Math.max(most, cell.offsetWidth), 0) * zoom;
        }
        // Whether a column's text or the boxes in it now lie past the left or right edge of their cell: a
        // paragraph of fixed width kept on one line runs out of it, to the left when it reads from the right,
        // and so does text set in a cell whose own width is capped (max-width), into the next cell.
        function spills(column) {
            for (const cell of column.cells) {
                const box = cell.getBoundingClientRect();
                if (!box.width) continue;
                const rects = [
                    ...textPieces(cell).map(piece => piece.rect),
                    ...[...cell.querySelectorAll('*')].map(el => el.getBoundingClientRect()),
                ];
                if (rects.some(rect => rect.width && (rect.left < box.left - 1 || rect.right > box.right + 1))) {
                    return true;
                }
            }
            return false;
        }
        // The shown columns of a table as the plan sees them, in its parent's pixels, or null when the table's
        // columns are not simple: spanning cells (rowspan="0" spans the rest of the group) put other columns
        // under a column's place, and a fixed layout sizes its columns without their content, so a value kept
        // whole would only spill. Cells in one column can have different padding (a header's, say), so a long
        // column keeps the most padding and the least text width of its cells.
        function columnsOf(table, limit) {
            const rows = [...table.rows];
            const cells = rows.flatMap(row => [...row.cells]);
            if (!cells.length || cells.some(cell => cell.colSpan !== 1 || cell.rowSpan !== 1)) return null;
            const count = rows.reduce((most, row) => Math.max(most, row.cells.length), 0);
            if (count < 2 || styleOf(table).tableLayout === 'fixed') return null;
            const zoom = zoomOf(table);
            const columns = [];
            for (let index = 0; index < count; index++) {
                const own = rows.map(row => row.cells[index]).filter(Boolean);
                const shown = own.filter(cell => cell.offsetWidth);
                // A column with no cell shown takes no room.
                if (!shown.length) continue;
                const changes = own.map(wholeLine);
                const whole = changes.every(Boolean);
                const estimate = whole ? own.reduce((most, cell) => Math.max(most, oneLine(cell)), 0) * zoom : 0;
                const short = whole && isShortColumn(estimate, limit);
                const styles = shown.map(styleOf);
                columns.push({
                    cells: own, shown, short, free: false, estimate, changes: short ? changes.flat() : [],
                    wraps: short && own.some(wraps),
                    width: columnWidth({ cells: own }, zoom),
                    padding: Math.max(...styles.map(css => sides(css, 'padding') + borders(css))) * zoom,
                    text: Math.min(...styles.map(contentWidth)) * zoom,
                });
            }
            return columns;
        }
        // The table's type size in its parent's pixels, and as laid out for the print.
        function typeOf(item) {
            const own = px(styleOf(item.table).fontSize) * zoomOf(item.table);
            return { size: own, laidOut: own * item.place.zoom };
        }
        function planFor(item, room) {
            const type = typeOf(item);
            return tablePlan(room, type.size, type.laidOut, item.columns ?? []);
        }
        // A column's elements go back to the style attributes they had before it was kept whole.
        function restore(column) {
            for (const [el, , style] of column.saved) {
                if (style === null) el.removeAttribute('style');
                else el.setAttribute('style', style);
            }
        }

        function fitTables() {
            delete globalThis.surimonoFittedTables;
            delete globalThis.surimonoTableFitLog;
            const items = [];
            for (const table of document.querySelectorAll('table')) {
                // The outer grid owns its tracks, including nested tables. TeX graphics and slides have
                // already been measured and placed by their own scripts.
                if (table.parentElement.closest('table,svg,.latex-graphic-box,.beamer-frame') || !table.offsetWidth) continue;
                const place = roomFor(table);
                if (!place) continue;
                items.push({ table, place, wide: outer(table) > place.room + 0.5 });
            }
            pieceCache = new Map();
            for (const item of items) item.columns = columnsOf(item.table, item.place.room);
            pieceCache = null;
            // A table that fits and breaks no short column is left as it was.
            let touched = items.filter(item => item.wide || item.columns?.some(column => column.wraps));

            // A table that is zoomed keeps free pixels from the column's edge. The reserve is a length on
            // paper, so it is the same at every text scale. A block is placed from its container's start
            // edge, whatever the direction of its own cells, so the container's direction decides which edge
            // stays put. A table placed from the right keeps the reserve at its left edge as well, where an
            // overflow would widen the page too.
            function zoomable(item) {
                if (item.room !== undefined) return item.room > 0;
                item.reserved = reserve / item.place.zoom;
                item.fromRight = styleOf(item.table.parentElement).direction === 'rtl';
                item.room = item.place.room - item.reserved * (item.fromRight ? 2 : 1);
                Object.assign(item, {
                    zoom: zoomOf(item.table), scale: 1, narrowing: 1, need: 0,
                    marginRight: px(styleOf(item.table).marginRight) * zoomOf(item.table),
                });
                return item.room > 0;
            }
            // The print cuts the column's right edge back to whole points, and half of a collapsed outside
            // rule lies beyond the table's box. A table placed from the right starts at that edge, so its
            // free pixels go on the right.
            const keepRight = (item, zoom) => {
                if (item.fromRight) set(item.table, 'margin-right', (item.marginRight + item.reserved) / zoom + 'px');
            };
            // Lines may break at the table's own size, without its minimum width.
            function release(item) {
                set(item.table, 'box-sizing', 'border-box');
                set(item.table, 'min-width', '0');
                set(item.table, 'max-width', item.room / item.zoom + 'px');
                keepRight(item, item.zoom);
            }
            // Formulas and pictures keep their own lines: they are drawn, not wrapped. Short columns let wrap
            // keep breaking only where they already could.
            const drawn = 'svg, svg *, math, math *, .math, .math *';
            const atBreaks = new Set();
            // Every value is read before any is written, so styles are worked out once per step.
            function restyle(items, property, value) {
                const changes = [];
                for (const { table } of items) {
                    for (const el of [table, ...table.querySelectorAll('*')]) {
                        if (el.matches(drawn) || atBreaks.has(el)) continue;
                        const next = value(styleOf(el)[property]);
                        if (next) changes.push([el, next]);
                    }
                }
                for (const [el, next] of changes) set(el, property === 'whiteSpace' ? 'white-space' : 'overflow-wrap', next);
            }
            // Geometry is read for all tables before any is written, so the page is laid out once per pass.
            const overflowing = items => items.filter(item => (item.width = outer(item.table)) > item.room + 0.5);
            const limitOf = item => item.wide ? item.room : item.place.room;
            const shortOf = item => (item.columns ?? []).filter(column => column.short);

            const wide = touched.filter(item => item.wide);
            touched = touched.filter(item => !item.wide || zoomable(item));
            const released = wide.filter(item => item.room > 0);
            // First what stops a line from breaking in a wide table goes ('pre' keeps its spaces and line
            // breaks).
            restyle(released, 'whiteSpace', space => space === 'nowrap' ? 'normal' : space === 'pre' ? 'pre-wrap' : null);
            for (const item of released) release(item);

            // A table that would have to be narrowed past `minimumNarrowing` to keep its short columns whole
            // lets them wrap where they already may (spaces, hyphens, between Japanese characters), but never
            // inside a word. Their estimated widths decide it first, so that a large table of them is not set
            // unwrapped only to be set back; their measured widths decide it again below.
            function letWrap(column) {
                Object.assign(column, { short: false, free: true });
                if (column.saved) restore(column);
                for (const [el] of column.changes) {
                    set(el, 'overflow-wrap', 'normal');
                    atBreaks.add(el);
                }
            }
            for (const item of touched) {
                const type = typeOf(item);
                const estimated = (item.columns ?? []).map(column =>
                    column.short ? Object.assign({}, column, { width: column.estimate }) : column);
                item.plan = tablePlan(limitOf(item), type.size, type.laidOut, estimated);
            }
            for (const item of touched.filter(item => !item.plan.keepsShort)) shortOf(item).forEach(letWrap);

            // Then every short column is kept unwrapped. Each element's style attribute is kept whole as it
            // stands now, after the step above, so that going back restores exactly that, whichever
            // white-space properties it named.
            for (const column of touched.flatMap(shortOf)) {
                column.saved = column.changes.map(([el, value]) => [el, value, el.getAttribute('style')]);
                // Descendants too: a wide table's own white-space may have been set on them.
                for (const [el, value] of column.changes) set(el, 'white-space', value);
            }
            // The width a short column was estimated at can miss spaces; unwrapped, each must still be short,
            // or it wraps with the long ones as it did. offsetWidth is rounded to whole pixels. A column whose
            // text now runs out of its cells is given up too: the cell's width would not hold it on paper.
            const given = [];
            for (const item of touched) {
                const zoom = zoomOf(item.table);
                for (const column of shortOf(item)) {
                    const width = columnWidth(column, zoom);
                    if (isShortColumn(width - 0.5, limitOf(item)) && !spills(column)) column.width = width;
                    else given.push(column);
                }
            }
            for (const column of given) {
                column.short = false;
                restore(column);
            }
            // Measured, the short columns may still need too much narrowing.
            for (const item of touched) item.plan = planFor(item, limitOf(item));
            for (const item of touched.filter(item => !item.plan.keepsShort)) {
                shortOf(item).forEach(letWrap);
                item.plan = planFor(item, limitOf(item));
            }
            // Each long column keeps its floor: the table's automatic layout shares out the width as it likes,
            // so the floor is set as a minimum width. A column is as wide as the widest minimum of its cells, so
            // with separate borders one cell carries it, sized for the column's widest padding and rules, and a
            // long table is not written row by row. Collapsed borders are shared between neighbours and resolved
            // between them, so a cell's own rules do not say how much of the column they take: there every cell
            // gets the floor for its own text.
            const minimums = [];
            for (const item of touched) {
                const zoom = zoomOf(item.table), collapsed = styleOf(item.table).borderCollapse === 'collapse';
                (item.columns ?? []).forEach((column, index) => {
                    const floor = item.plan.floors[index];
                    if (!floor) return;
                    column.floor = floor / zoom;
                    for (const cell of collapsed ? column.shown : column.shown.slice(0, 1)) {
                        const css = styleOf(cell), own = sides(css, 'padding') + borders(css);
                        const box = collapsed ? column.floor + own : column.floor + column.padding / zoom;
                        minimums.push([cell, css.boxSizing === 'border-box' ? box : box - own]);
                    }
                });
            }
            for (const [cell, minimum] of minimums) set(cell, 'min-width', minimum + 'px');

            // A table that fits with its short columns whole and its long columns at their floor is done.
            // The others are zoomed, as one plan decides for every table.
            const zoomed = [];
            for (const item of touched) {
                item.unwrapped = outer(item.table);
                if (item.unwrapped <= limitOf(item) + 0.5 && item.plan.scale === 1) continue;
                if (zoomable(item)) zoomed.push(item);
            }
            for (const item of zoomed) if (!item.wide) release(item);
            for (const item of zoomed) item.plan = planFor(item, item.room);
            // Wrapped, the long cells give way; short columns are unwrapped and stay so. Breaking inside words
            // is only for tables that need it.
            function wrapLong(items) {
                restyle(overflowing(items), 'overflowWrap', wrap => wrap === 'anywhere' ? null : 'anywhere');
                const over = overflowing(items);
                for (const item of items) item.wrapped = item.width;
                return over;
            }

            // Then the table is zoomed, filling the column: a zoomed table given the whole column has its right
            // rule at the column's edge, unless the plan already knows it needs narrowing too, which keeps the
            // long columns their floor. The width is fixed in the table's own pixels, so percentage widths and
            // the layout width no longer change it.
            function zoomTable(item) {
                const zoom = item.zoom * item.scale;
                const width = Math.max(item.room / zoom, item.need / item.zoom);
                set(item.table, 'width', width + 'px');
                set(item.table, 'max-width', width + 'px');
                set(item.table, 'zoom', String(zoom));
                keepRight(item, zoom);
            }
            function zoomAll(items, over) {
                // Not every WebKit holds a table to its max-width (macOS 15 kept the author's fixed width), so
                // the width itself is set to the column even at the table's own size. Only what its contents
                // keep wider than that is zoomed further.
                const sized = items.filter(item => over.includes(item) || item.plan.scale < 1);
                for (const item of sized) {
                    item.least = item.plan.least;
                    item.scale = item.plan.scale;
                    if (item.plan.narrowing < 1) item.need = item.plan.need;
                    zoomTable(item);
                }
                over = overflowing(sized);
                for (const item of items) item.clamped = item.width;
                const stalled = [];
                for (let pass = 0; pass < passes && over.length; pass++) {
                    for (const item of over) {
                        item.last = { scale: item.scale, width: item.width };
                        item.scale = Math.max(item.least, nextScale(item.scale, item.room, item.width));
                        zoomTable(item);
                    }
                    const still = overflowing(over);
                    over = [];
                    for (const item of still) {
                        // At the smallest type, the rest is narrowed.
                        if (item.scale <= item.least) {
                            stalled.push(item);
                            continue;
                        }
                        // Text may stop shrinking before the smallest type, and spacing set in ems stops with
                        // it. A zoom that took off less than half of what it was meant to went past that point
                        // and would only thin the rules. It goes back to the zoom that would have taken off what
                        // this one did at full effect, which is where the text stopped, and no further than the
                        // last zoom.
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
                for (const item of overflowing([...stalled, ...over])) {
                    item.narrowing = item.room / item.width;
                    set(item.table, 'transform-origin', item.fromRight ? 'right top' : 'left top');
                    set(item.table, 'transform', 'scaleX(' + item.narrowing + ')');
                }
            }
            for (const item of zoomed) item.unzoomed = item.table.getAttribute('style');
            zoomAll(zoomed, wrapLong(zoomed));
            // The plan does not see everything the table takes (the gaps of separated borders, say). A table
            // narrowed past `minimumNarrowing` with short columns still kept whole goes back to how it was
            // before the zoom, lets them wrap where they already may, and is zoomed once more.
            const again = zoomed.filter(item => !keepsShortColumns(item.narrowing) && shortOf(item).length);
            for (const item of again) {
                if (item.unzoomed === null) item.table.removeAttribute('style');
                else item.table.setAttribute('style', item.unzoomed);
                Object.assign(item, { scale: 1, narrowing: 1, need: 0 });
                shortOf(item).forEach(letWrap);
            }
            for (const item of again) item.plan = planFor(item, item.room);
            if (again.length) zoomAll(again, wrapLong(again));

            // A table counts as fitted when its painted width is within its room; anything else is still
            // reported as wider than the page. Only the width is compared, not where the table sits: a table
            // moved sideways by a style of its own (relative positioning, say) is not detected here. A table
            // that fitted and had nothing kept was not changed, and is not counted. Whether each long column
            // got its floor is read back and logged, as the table's own layout gave it.
            const changed = touched.filter(item =>
                item.wide || zoomed.includes(item) || (item.columns ?? []).some(column => column.short || column.floor));
            const fitted = changed.filter(item => {
                const room = item.room ?? item.place.room;
                item.inside = outer(item.table) * (item.narrowing ?? 1) <= room + 0.5;
                item.floorsKept = (item.columns ?? []).every(column => !column.floor
                    || column.shown.every(cell => contentWidth(styleOf(cell)) >= column.floor - 0.5));
                return item.inside;
            });
            if (fitted.length) globalThis.surimonoFittedTables = new WeakSet(fitted.map(item => item.table));
            // What each step measured, for a test that fails on a WebKit it cannot run on to report.
            globalThis.surimonoTableFitLog = [...new Set([...released, ...zoomed])].map(
                ({ room, unwrapped, wrapped, clamped, scale, narrowing, inside, floorsKept }) =>
                    ({ room, unwrapped, wrapped, clamped, scale, narrowing, inside, floorsKept, devicePixelRatio }));
            return changed.length > 0;
        }
        """#
}
