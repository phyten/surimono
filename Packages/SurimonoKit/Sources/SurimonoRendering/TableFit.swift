import SurimonoCore
import WebKit

/// Fits tables before printing or capturing a style sample. The vertical compositor supplies its own row width.
enum TableFit {
    static func applies(to format: DocumentFormat, theme: PrintTheme, latexMargins: LaTeXPageMode?, body: String)
        -> Bool
    {
        format.usesPrintTheme && theme.flow == .horizontal
            && (format != .latex || !(latexMargins ?? .style).applies(to: theme))
            && body.range(of: "<table", options: .caseInsensitive) != nil
    }

    // Exercise the same decision function with JavaScriptCore without starting a web process.
    static let scaleFunction = """
        function scaleToFit(room, width) {
            return Math.min(1, room / width);
        }
        """

    @MainActor
    static func fit(in view: WKWebView, until deadline: ContinuousClock.Instant)
        async throws -> Bool
    {
        try await view.evaluateForPrinting(
            "document.body.offsetWidth; await document.fonts.ready;\n" + function + "\nreturn fitTables();", until: deadline)
            as? Bool == true
    }

    static let function = "function fitTables(rowWidth) {\n" + scaleFunction + "\n" + script + "\n}"

    private static let script = #"""
        // offset/client/scroll widths are local layout units on both sides of Safari 26.4's
        // change to zoomed DOMRects. Convert each ancestor's content width to the parent's units.
        const px = value => parseFloat(value) || 0;
        const zoom = element => px(getComputedStyle(element).zoom) || 1;
        function roomFor(table) {
            let room = Infinity, ancestorZoom = 1;
            for (let p = table.parentElement; p; p = p.parentElement) {
                // A vertical strip spans the entire book. The compositor has already resolved
                // the physical width of one row in local CSS pixels.
                if (rowWidth && p.classList.contains('horizontal-box-line')) {
                    room = Math.min(room, rowWidth / ancestorZoom);
                    break;
                }
                const css = getComputedStyle(p);
                if (p === document.documentElement) {
                    room = Math.min(room, window.innerWidth / (ancestorZoom * zoom(p)));
                } else if (p.clientWidth && css.display !== 'inline') {
                    room = Math.min(room, (p.clientWidth - px(css.paddingLeft) - px(css.paddingRight)) / ancestorZoom);
                }
                ancestorZoom *= zoom(p);
            }
            const css = getComputedStyle(table);
            return room - Math.max(0, px(css.marginLeft) + px(css.marginRight)) * zoom(table);
        }
        function width(t) {
            // A rounded, clipped grid can have a scrollable area much wider than
            // its painted border in older WebKit. Only visible overflow adds ink.
            const overflow = getComputedStyle(t).overflowX === 'visible' ? t.scrollWidth : 0;
            return Math.max(t.offsetWidth, overflow) * zoom(t);
        }
        const set = (el, name, value) => el.style.setProperty(name, value, 'important');
        const wide = [];
        for (const table of document.querySelectorAll('table')) {
            // The outer grid owns its tracks, including nested tables. Explicit TeX
            // transformations already have their own measured ink and layout boxes.
            if (table.parentElement.closest('table,.latex-graphic-box,.beamer-frame') || !table.offsetWidth) continue;
            const room = roomFor(table), natural = width(table);
            if (room <= 1 || natural <= room + 0.5) continue;
            // Native printing can round the printable width down to an integer point.
            // Reserve two CSS pixels for the last stroke, only on tables that need fitting.
            wide.push({ table, room: Math.max(1, room - 2), originalZoom: zoom(table) });
        }
        if (!wide.length) return false;
        globalThis.surimonoFittedTables = new WeakSet(wide.map(item => item.table));
        for (const { table, room, originalZoom } of wide) {
            // Let automatic tracks reflow at the original type size before measuring a zoom.
            set(table, 'box-sizing', 'border-box');
            set(table, 'max-width', room / originalZoom + 'px');
            table.setAttribute('data-surimono-wrap-table', '');
            // Inline !important wins even over the scoped emergency sheet.
            for (const el of table.querySelectorAll(':is(td,th,caption)[style], :is(td,th,caption) [style]')) {
                if (el.style.getPropertyPriority('white-space') || el.style.getPropertyPriority('text-wrap-mode')) {
                    if (CSS.supports('text-wrap-mode', 'wrap')) set(el, 'text-wrap-mode', 'wrap');
                    else set(el, 'white-space', 'pre-wrap');
                }
                if (el.style.getPropertyPriority('overflow-wrap')) set(el, 'overflow-wrap', 'anywhere');
                if (el.style.getPropertyPriority('word-break')) set(el, 'word-break', 'normal');
            }
        }
        const style = document.createElement('style');
        style.textContent = `
            [data-surimono-wrap-table] :is(td,th,caption),
            [data-surimono-wrap-table] :is(td,th,caption) * {
                text-wrap-mode: wrap !important; overflow-wrap: anywhere !important; word-break: normal !important;
            }
            @supports not (text-wrap-mode: wrap) {
                [data-surimono-wrap-table] :is(td,th,caption),
                [data-surimono-wrap-table] :is(td,th,caption) * { white-space: pre-wrap !important; }
            }`;
        document.head.append(style);
        // Batch geometry reads before writes to avoid laying out the document once per table.
        function remaining(items) {
            return items.filter(item => {
                item.measured = width(item.table);
                return item.measured > item.room + 0.5;
            });
        }
        const scaled = remaining(wide);
        for (const { table, room, originalZoom, measured } of scaled) {
            // Freeze percentage tracks in the table's own units. Otherwise e.g. min-width:
            // 115% would keep taking 115% of the column at every zoom.
            const localWidth = measured / originalZoom + 'px';
            set(table, 'min-width', '0');
            set(table, 'width', localWidth);
            set(table, 'max-width', localWidth);
            set(table, 'zoom', String(originalZoom * scaleToFit(room, measured)));
        }
        // Minimum font metrics and pixel-snapped rules can still overshoot. Compress
        // the residual horizontal ink without changing the row heights used for pagination.
        for (const { table, room, measured } of remaining(scaled)) {
            const rtl = getComputedStyle(table.parentElement).direction === 'rtl';
            // The vertical compositor measures the transformed box and captures its ink directly.
            if (!rowWidth) {
                const frame = document.createElement('div');
                frame.style.cssText = 'display:block!important; overflow:clip!important; max-width:100%!important';
                table.before(frame);
                frame.append(table);
            }
            set(table, 'transform-origin', rtl ? 'right top' : 'left top');
            set(table, 'transform', 'scaleX(' + room / measured + ')');
        }
        return true;
        """#
}
