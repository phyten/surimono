// Keep the prepared tree alive: page references and diagram probes refer to those exact nodes between passes.
const original = document.body;
const body = original.cloneNode(true);
original.replaceWith(body);
globalThis.surimonoRestoreFlow = () => {
    body.replaceWith(original);
    delete globalThis.surimonoFlow;
    delete globalThis.surimonoRestoreFlow;
};
const nodes = [...body.childNodes];
// Read the theme and print-finish breaks while sibling selectors still see the original document.
const breaks = new WeakMap();
for (const el of body.querySelectorAll('h1,h2,h3,h4,h5,h6,nav,header,section,div,hr')) {
    if (el.hasAttribute('data-latex-break')) continue;
    const css = getComputedStyle(el);
    const before = ['page','always','left','right'].includes(css.breakBefore);
    const after = ['page','always','left','right'].includes(css.breakAfter);
    if (before || after) breaks.set(el, {before, after});
}
const noteBodies = new Map([...body.querySelectorAll('section.footnotes > ol > li[id]')].map(li => [li.id, li]));
const seenNotes = new Set();
const strips = [], segments = [], pendingMeasurements = [];
const excluded = 'style,script,template,noscript';
const atomic = '[data-flow-ink-block],figure:not(.latex-longtable):not(.latex-listing),table:not(.latex-longtable),tr,.math-block,.tikz-block,.latex-graphic-box,img,svg,canvas,hr,input,.latex-vspace,.latex-exam-space,.latex-rule,.latex-title-block,.latex-minipage,.latex-box-row,[data-latex-tcolorbox]:not([data-latex-breakable])';
const heading = 'h1,h2,h3,h4,h5,h6';
const boundary = '[data-latex-paged-table],[data-latex-chapter-opening],[data-flow-ink-block],[data-latex-columns],[data-latex-spacing],[data-latex-wide],[data-latex-break],[data-latex-float],.latex-title-block,.latex-titlepage';
body.style.cssText += ';margin:0!important;padding:0!important;max-width:none!important;width:auto!important';
const style = document.createElement('style');
style.textContent = `
[data-flow-strip]{display:flow-root!important;position:relative!important;margin:0!important;padding:0!important;border:0!important}
[data-flow-strip] > figure[data-latex-float]{margin-block:0!important}
[data-flow-strip] > section.footnotes{margin:0!important}
[data-flow-strip] > section.footnotes::before{display:none!important}
.surimono-flow-hidden,.surimono-flow-hidden *{visibility:hidden!important}
`;
body.replaceChildren(style);
const zoom = parseFloat(getComputedStyle(document.documentElement).zoom) || 1;
// WKPDFConfiguration cannot recover ink painted left of the document's origin. Leave a canvas
// around the measured strips, independent of their explicitly assigned column widths.
// WebKit rounds inline baselines to layout pixels, including inside atomic floats and
// listings. Lay the Japanese grid out at finer resolution and undo that enlargement
// before measuring or capturing. One PDF point still occupies the same viewport width.
const fineGrid = body.hasAttribute('data-latex-js-toc') && !!getComputedStyle(body).getPropertyValue('--js-pt').trim();
if (fineGrid) {
    body.style.setProperty('zoom', '32', 'important');
    body.style.setProperty('transform', 'scale(0.03125)', 'important');
    body.style.setProperty('transform-origin', 'top left', 'important');
}
body.style.setProperty('--latex-page-goal', bodyHeight / zoom + 'px');
const guardPixels = 2;
body.style.setProperty('padding-left', (Math.max(leftMargin, width / 2) + guardPixels) / zoom + 'px', 'important');
body.style.setProperty('padding-right', (Math.max(rightMargin, width / 2) + guardPixels) / zoom + 'px', 'important');
body.style.setProperty('padding-top', (paperHeight + guardPixels) / zoom + 'px', 'important');
body.style.setProperty('padding-bottom', (paperHeight + guardPixels) / zoom + 'px', 'important');
body.style.setProperty('width', width / zoom + 'px', 'important');
body.style.setProperty('box-sizing', 'content-box', 'important');
const probe = document.createElement('div');
body.append(probe);
probe.style.cssText = 'width:100px!important;height:1px!important';
const unit = 100 * zoom / probe.getBoundingClientRect().width;
function length(name, fallback) {
    probe.style.setProperty('width', 'var(--latex-' + name + ',' + fallback + 'px)', 'important');
    return probe.getBoundingClientRect().width * unit;
}
const noteSkip = length('skip-footins', 12), textFloatSep = length('textfloatsep', 25);
const noteRuleWidth = length('footnote-rule-width', 180);
const bigSkipShrink = length('bigskip-shrink', 0);
const floatSep = length('floatsep', 15), inTextSep = length('intextsep', 15);
const sectionTop = length('heading-topskip', 0);
const zw = fineGrid ? length('zw', 0) / zoom : 0;
const jsPoint = fineGrid ? length('js-point', 0) : 0;
const displayShrink = fineGrid ? length('display-shrink', 0) : 0;
const defaultGap = length('columnsep', 12.4533);
probe.style.setProperty('width', 'var(--tex-baseline)', 'important');
const normalPitch = fineGrid ? probe.getBoundingClientRect().width * unit / zoom : 0;
probe.remove();
const defaults = {columns:1, gap:defaultGap, rule:0, balance:false, pageNotes:false};
let segment, run;
let work = 0;
function budget(n = 1) {
    work += n;
    if (work > 250000) throw Error('LaTeX flow exceeds the fragment limit');
}
function begin(config) {
    segment = {...config, items:[]};
    segments.push(segment);
    run = null;
}
function strip(width) {
    budget();
    if (!(width > 0)) throw Error('Invalid LaTeX column width');
    const box = document.createElement('div');
    box.dataset.flowStrip = strips.length;
    // Page-margin ownership uses the requested column boundary. The DOM rounds its width to layout pixels.
    box.dataset.flowWidth = width;
    box.style.width = width / zoom + 'px';
    body.append(box);
    strips.push(box);
    return box;
}
function measureWidth() { return (width - (segment.columns - 1) * segment.gap) / segment.columns; }
function force(kind) {
    run = null;
    segment.items.push({forced:kind, notes:[], wide:false, gap:0});
}
function command(node, parents) {
    const forced = breaks.get(node);
    if (forced?.before || node.nodeType === 1 && node.hasAttribute('data-latex-chapter-opening')) force('page');
    content(node, parents);
    if (forced?.after) force('page');
}
function content(node, parents) {
    if (node.nodeType === Node.TEXT_NODE && !node.data.trim() && !run) return;
    if (node.nodeType === Node.ELEMENT_NODE) {
        if (node.matches('style')) { body.append(node); return; }
        if (node.matches('section.footnotes')) return;
        if (node.hasAttribute('data-latex-break')) {
            force(node.dataset.latexBreak);
            return;
        }
        if (node.hasAttribute('data-latex-columns') || node.hasAttribute('data-latex-spacing')) {
            const previous = segment;
            const d = node.dataset;
            begin({columns:+d.latexColumns || previous.columns, gap:d.latexGap == null ? defaultGap : +d.latexGap * 1.24533 * zoom,
                rule:Number(d.latexRule || 0) * 1.24533 * zoom, balance:node.hasAttribute('data-latex-spacing') ? previous.balance : d.latexBalance === 'true',
                pageNotes:node.hasAttribute('data-latex-spacing') ? previous.pageNotes : d.latexFootnotes === 'page'});
            if (node.tagName !== 'TEMPLATE') {
                for (const child of [...node.childNodes]) command(child, parents);
                begin(previous);
            }
            return;
        }
        if (node.hasAttribute('data-latex-float')) {
            run = null;
            const wide = node.hasAttribute('data-latex-wide') && segment.columns > 1;
            const box = strip(wide ? width : measureWidth());
            box.append(node);
            segment.items.push({box, floatKind:node.dataset.latexFloat, placement:node.dataset.latexPlacement, wide, gap:0, notes:[]});
            return;
        }
        if (node.hasAttribute('data-latex-wide') || (segment.columns > 1 && node.matches('.latex-title-block,.latex-titlepage'))) {
            const previous = segment;
            begin(defaults);
            append(node, parents);
            begin(previous);
            return;
        }
        const table = node.matches('table[data-latex-paged-table]') ? node :
            node.matches('figure.latex-longtable') && node.querySelector(':scope > table[data-latex-paged-table]');
        if (table && table.tBodies[0]?.rows.length) {
            // Keep every variant on the same column tracks. Only selected slices are copied into the PDF.
            run = null;
            append(node, parents);
            segment.items.at(-1).table = table;
            // The first or last band can double as the continuation band. Its reusable
            // sample needs a disjoint source rectangle from the page that includes it.
            for (const [flag, source, role] of [
                ['data-latex-repeat-first', table.tHead, 'data-latex-repeat-head'],
                ['data-latex-repeat-last', table.querySelector(':scope > [data-latex-last-foot]'), 'data-latex-repeat-foot']
            ]) {
                if (!table.hasAttribute(flag) || !source) continue;
                const sample = table.createTBody();
                sample.setAttribute(role, ''); sample.hidden = true;
                for (const row of source.rows) { budget(); sample.append(row.cloneNode(true)); }
                for (const el of sample.querySelectorAll('[id]')) el.removeAttribute('id');
            }
            for (const group of [...table.tBodies]) {
                if (!group.hidden) continue;
                // Collapsed borders belong to both neighbours. Separate the off-page samples
                // so a last-row rule cannot paint into the top of a continuation header.
                const spacer = document.createElement('tbody');
                const cell = spacer.insertRow().insertCell();
                cell.colSpan = Math.max(1, group.rows[0]?.cells[0]?.colSpan || 1);
                cell.style.cssText = 'height:2px;padding:0;border:0;line-height:0';
                table.insertBefore(spacer, group);
                group.hidden = false;
            }
            run = null;
            return;
        }
        // Splitting the frame away from its caption clones the figure's outer skips
        // into both strips. Keep their shared formatting context when the frame protrudes.
        if (node.matches('figure.latex-listing')) { append(node, parents); return; }
        // Paint from a raised or positioned child belongs to this box, even beyond its layout
        // height. A separate strip preserves that ink without capturing a neighbouring paragraph.
        if (node.hasAttribute('data-flow-ink-block') && !node.querySelector('[data-latex-break],[data-latex-columns],[data-latex-float]')) {
            run = null;
            append(node, parents);
            run = null;
            return;
        }
        if (node.matches(excluded)) return;
        if (!node.matches('.latex-minipage,.latex-box-row,[data-latex-tcolorbox]:not([data-latex-breakable])') && node.querySelector(boundary)) {
            for (const child of [...node.childNodes]) command(child, [...parents, node]);
            return;
        }
    }
    append(node, parents);
}
function append(node, parents) {
    if (!run) {
        const box = strip(measureWidth());
        if (!fineGrid && segment.items.at(-1)?.forced) box.dataset.flowPageStart = '';
        if (segment.items.at(-1)?.floatKind) box.dataset.flowAfterFloat = '';
        if (segment.items.at(-1)?.placement?.includes('H')) box.dataset.flowAfterPinned = '';
        run = {box, parents:[], clones:[box]};
        segment.items.push({run:box});
    }
    // Preserve language, list, and indentation wrappers on both sides of an embedded flow boundary.
    let common = 0;
    while (common < parents.length && parents[common] === run.parents[common]) common++;
    run.clones.length = common + 1;
    for (const parent of parents.slice(common)) {
        const clone = parent.cloneNode(false);
        run.clones.at(-1).append(clone);
        run.clones.push(clone);
    }
    run.parents = parents;
    run.clones.at(-1).append(node);
}
begin(defaults);
for (const node of nodes) command(node, []);
// Use the first reference's measure, even when numbers repeat in a later chapter.
const notes = {};
for (const seg of segments) {
    for (const item of seg.items) {
        const container = item.run || item.box;
        if (!container) continue;
        for (const a of container.querySelectorAll('.footnote-ref a[href^="#"]')) {
            const id = a.hash.slice(1), li = noteBodies.get(id);
            if (!li || seenNotes.has(id)) continue;
            seenNotes.add(id);
            a.dataset.flowNote = id;
            if (item.box) item.notes.push(id);
            const box = strip(seg.pageNotes || item.wide ? width : (width - (seg.columns - 1) * seg.gap) / seg.columns);
            const section = document.createElement('section'), ol = document.createElement('ol');
            section.className = 'footnotes';
            section.append(ol); ol.append(li); box.append(section);
            pendingMeasurements.push([id, box]);
        }
    }
}
// Independently captured notes need the same source baseline phase. A single grid
// cell gives each strut the same origin without stretching shorter notes to its height.
if (pendingMeasurements.length && ['article','report','book'].includes(body.dataset.latexClass)) {
    const area = document.createElement('div');
    area.style.cssText = 'display:grid;align-items:start';
    body.append(area);
    for (const [, box] of pendingMeasurements) {
        box.style.gridArea = '1 / 1';
        area.append(box);
    }
}
if (fineGrid) {
    for (const caption of body.querySelectorAll('figcaption:has(br)')) {
        if (getComputedStyle(caption).textAlign !== 'center') continue;
        const walk = document.createTreeWalker(caption, NodeFilter.SHOW_TEXT | NodeFilter.SHOW_ELEMENT);
        let last;
        const ends = [];
        for (let n = walk.nextNode(); n; n = walk.nextNode()) {
            if (n.nodeName === 'BR') { if (last) ends.push(last); last = null; }
            else if (n.nodeType === Node.TEXT_NODE && n.data.trim()) last = n;
            else if (n.matches?.('img,svg,ruby,.math-inline')) last = null;
        }
        if (last) ends.push(last);
        for (const n of ends) {
            if (!/[。、]$/u.test(n.data) || n.parentElement.closest('svg,ruby,.math-inline')) continue;
            const end = document.createElement('span');
            end.className = 'latex-caption-jfm-end';
            n.after(end);
        }
    }
    // A paragraph entirely in small type has that face's strut. A normal-size
    // parent strut would add ascent to one face and descent to the other.
    for (const p of body.querySelectorAll('p:has(> [data-latex-text-size])')) {
        if (p.childNodes.length === 1) p.style.fontSize = p.firstElementChild.style.fontSize;
        else p.dataset.flowMixedSize = '';
    }
}
if (seenNotes.size !== noteBodies.size) throw Error('Unpaired LaTeX footnote');
await Promise.all([document.fonts.ready, ...[...body.querySelectorAll('img')].map(img => img.decode().catch(() => {}))]);
// Fixed-size graphics and tables can be wider than the newly established column measure.
const fits = [];
for (const el of body.querySelectorAll('img,svg,table,.latex-graphic-box')) {
    if (el.parentElement.closest('svg,.latex-graphic-box')) continue;
    const strip = el.closest('[data-flow-strip]');
    if (!strip) continue;
    if (fineGrid && el.matches('table')) {
        const parent = el.parentElement;
        const css = getComputedStyle(parent);
        const measure = parent.getBoundingClientRect().width * unit / zoom
            - parseFloat(css.paddingLeft) - parseFloat(css.paddingRight) - parseFloat(css.borderLeftWidth) - parseFloat(css.borderRightWidth);
        if (measure > 0) el.style.setProperty('--latex-table-measure', measure + 'px');
    }
    const available = strip.getBoundingClientRect().width;
    const natural = el.getBoundingClientRect().width;
    if (natural > available + 0.5) fits.push([el, available / natural * (parseFloat(getComputedStyle(el).zoom) || 1)]);
}
for (const [el, scale] of fits) el.style.zoom = scale;
if (fineGrid) japaneseProseLines(body);
if (fineGrid && CSS.supports('text-box-trim', 'trim-both')) {
    for (const row of body.querySelectorAll('.latex-box-row')) {
        const boxes = [...row.children];
        if (boxes.length && boxes.every(box => box.matches('.latex-minipage') && box.style.verticalAlign === 'top'
            && box.firstElementChild?.matches('[data-latex-heading]') && box.lastElementChild?.matches('p'))) {
            row.dataset.flowHeadingBoxes = '';
        }
    }
    // Longtable restores the depth from before the alignment. The native caption
    // is a top-aligned parbox whose final glyph depth precedes a full baseline skip.
    for (const table of body.querySelectorAll('figure.latex-longtable:has(> figcaption:not([data-latex-caption-style]))')) {
        const cap = table.querySelector(':scope > figcaption'), prev = table.previousElementSibling;
        const depth = japaneseLineDepth(cap);
        if (depth !== null) cap.style.setProperty('--latex-last-depth', depth + 'px');
        const before = prev?.matches('p') ? japaneseLineDepth(prev) : null;
        if (before !== null) {
            prev.style.setProperty('--latex-table-prev-depth', before + 'px');
            table.nextElementSibling?.style.setProperty('--latex-table-prev-depth', before + 'px');
        }
    }
    for (const cap of body.querySelectorAll('figure[data-latex-placement="H"] > figcaption:last-child:not([data-latex-caption-style]), body[data-latex-chapters="false"] figure:is(.latex-figure,.latex-table)[data-latex-placement*="h"] > figcaption:last-child:not([data-latex-caption-style])')) {
        const depth = japaneseLineDepth(cap);
        if (depth !== null) cap.style.setProperty('--latex-last-depth', depth + 'px');
    }
}
// Ink guards can isolate neighbouring blocks in separate capture strips.
const previous = new WeakMap(), following = new WeakMap();
for (const segment of segments) for (let i = 1; i < segment.items.length; i++) {
    const left = segment.items[i-1].run?.lastElementChild, right = segment.items[i].run?.firstElementChild;
    if (left && right) { previous.set(right, left); following.set(left, right); }
}
// TeX forbids a page break between a paragraph's final line and its display,
// including when a separate strip is needed to capture overhanging formula ink.
for (const block of body.querySelectorAll('.math-block')) {
    if ((block.previousElementSibling || previous.get(block))?.matches('p')) block.dataset.flowAfterText = '';
}
if (fineGrid) measureJapaneseDisplays();

function measureJapaneseDisplays() {
    const point = jsPoint / zoom, cssPerRect = unit / zoom;
    if (!(point > 0 && normalPitch > 0 && zw > 0)) return;
    const displays = [], markers = [];
    // A zero-size inline box gives the baseline and advance of the actual last line.
    function baseline(p, atEnd) {
        const mark = document.createElement('i');
        mark.style.cssText = 'display:inline-block;width:0;height:0;padding:0;margin:0;border:0;vertical-align:baseline';
        if (atEnd) p.append(mark); else p.prepend(mark);
        markers.push(mark);
        return mark;
    }
    for (const block of body.querySelectorAll('.math-block')) {
        const math = block.querySelector(':scope > .math-display'), svg = math?.querySelector(':scope > svg');
        if (!svg) continue;
        const aligned = math.hasAttribute('data-latex-first-baseline');
        if (!aligned && !block.hasAttribute('data-latex-single-display')) continue;
        const before = block.previousElementSibling || previous.get(block);
        const next = block.nextElementSibling || following.get(block);
        const afterHeading = before?.hasAttribute('data-latex-heading'), adjacent = before?.matches('.math-block');
        if (!before || !(adjacent || afterHeading || before.matches('p')) || getComputedStyle(before).direction !== 'ltr') continue;
        if (!svg.getBoundingClientRect().height) continue;
        const normal = getComputedStyle(block.closest('[data-flow-strip]')).fontSize, css = getComputedStyle(block);
        if (css.fontSize !== normal || !afterHeading && getComputedStyle(before).fontSize !== normal) continue;
        const stretch = Number(css.getPropertyValue('--latex-stretch').trim() || 1);
        if (!(stretch > 0 && Number.isFinite(stretch))) continue;
        // The SVG generator records height and baseline offset in the same em units.
        // Their ratio survives the print zoom and does not depend on computed SVG styles.
        const heightEm = parseFloat(svg.getAttribute('height'));
        let depthRatio = aligned ? 1 - Number(math.dataset.latexLastBaseline) : -parseFloat(svg.style.verticalAlign) / heightEm;
        let ascentRatio = aligned ? Number(math.dataset.latexFirstBaseline) : 1 - depthRatio;
        let upperInk = 0, lowerInk = 0;
        if (svg.hasAttribute('data-latex-tex-top')) {
            const view = svg.viewBox.baseVal;
            ascentRatio = (Number(svg.dataset.latexTexFirst) - view.y) / view.height;
            depthRatio = (view.y + view.height - Number(svg.dataset.latexTexLast)) / view.height;
            upperInk = (Number(svg.dataset.latexTexTop) - view.y) / view.height;
            lowerInk = (view.y + view.height - Number(svg.dataset.latexTexBottom)) / view.height;
        }
        if (!(ascentRatio > 0 && Number.isFinite(ascentRatio) && depthRatio >= 0 && Number.isFinite(depthRatio))) continue;
        displays.push({block, math, before, aligned, adjacent, afterHeading, depthRatio, ascentRatio, upperInk, lowerInk,
            narrow:12 * point * stretch, pitch:normalPitch * stretch,
            after:next?.matches('p') && getComputedStyle(next).fontSize === normal ? next : null});
    }
    for (const d of displays) {
        d.block.dataset.flowDisplay = 'normal';
        // The flex item and the paragraph marker use the same HTML coordinate
        // system. SVG graphics and HTML ranges can report different zoomed bounds.
        d.edge = baseline(d.math, false);
        d.edge.style.flex = 'none';
        if (d.before.matches('p')) d.end = baseline(d.before, true);
        if (d.after) d.start = baseline(d.after, false);
    }
    const depths = new Map();
    for (const d of displays) {
        const rect = d.math.getBoundingClientRect();
        d.ascent = rect.height * cssPerRect * d.ascentRatio;
        d.depth = rect.height * cssPerRect * d.depthRatio;
        d.texAscent = d.ascent - rect.height * cssPerRect * d.upperInk;
        d.texDepth = d.depth - rect.height * cssPerRect * d.lowerInk;
        // amsmath aligns rows to the full measure. The class uses two quads
        // beyond the final glyph when choosing the ordinary equation's upper skip.
        d.short = !d.aligned && (d.adjacent || d.afterHeading ||
            (d.edge.getBoundingClientRect().left - d.end.getBoundingClientRect().right) * cssPerRect >= 20 * point);
        const skip = d.short ? 0 : 11 * point;
        d.above = d.adjacent ? Math.max(0, skip + d.narrow - d.ascent - (depths.get(d.before) || 0))
            : skip + Math.max(d.narrow, d.texAscent + .12 * zw + point) - d.ascent + (d.afterHeading ? d.pitch : 0);
        d.below = 9 * point - (d.depth - d.texDepth);
        depths.set(d.block, d.texDepth);
    }
    function applySkips(d) {
        // Ink outside the TeX box can consume all of a skip. Negative padding
        // would invalidate both sides of the CSS declaration.
        const style = d.block.style;
        style.paddingBlock = Math.max(0, d.above) + 'px ' + Math.max(0, d.below) + 'px';
        style.marginTop = d.above < 0 ? d.above + 'px' : '';
        style.marginBottom = d.below < 0 ? d.below + 'px' : '';
    }
    for (const d of displays) {
        d.block.dataset.flowDisplay = d.short ? 'short' : 'normal';
        applySkips(d);
        if (d.start) d.start.parentElement.style.setProperty('--latex-display-depth', d.depth + 'px');
    }
    // Trim and fractional font metrics vary between print engines. Reconcile the
    // two *measured* baseline distances, including the leading on the text sides.
    for (const d of displays) {
        const rect = d.math.getBoundingClientRect();
        if (d.end) {
            const actual = (rect.top - d.end.getBoundingClientRect().top) * cssPerRect + d.ascent;
            d.above += (d.short ? 0 : 11 * point) + Math.max(d.narrow, d.texAscent + .12 * zw + point) - actual;
        }
        if (d.start) {
            const actual = (d.start.getBoundingClientRect().top - rect.bottom) * cssPerRect + d.depth;
            const parskip = parseFloat(getComputedStyle(d.start.parentElement).marginTop) || 0;
            d.below += 9 * point + Math.max(d.pitch, d.texDepth + .88 * zw + point) + parskip - actual;
        }
    }
    for (const mark of markers) mark.remove();
    for (const d of displays) {
        applySkips(d);
        d.block.style.setProperty('--latex-display-bottom', Math.max(0,d.below) + d.depth + 'px');
    }
}
// WebKit positions the next baseline on a layout pixel even when the skip is fractional.
// Keep integral glue in the strip and place the remainder between vector captures.
const glueRemainders = new WeakMap(), spacers = [];
for (const segment of segments) for (const item of segment.items) {
    if (fineGrid || !item.run) continue;
    for (const el of item.run.querySelectorAll('.latex-vspace')) {
        if (el.parentElement.closest(atomic)) continue;
        const height = parseFloat(getComputedStyle(el).height);
        // A visible measurement band needs at least one pixel, including for a subpixel skip.
        const whole = Math.max(1, Math.floor(height * zoom));
        const remainder = height * zoom - whole;
        if (height > 0 && Math.abs(remainder) > 0.001) spacers.push([el, whole, remainder]);
    }
}
for (const [el, whole, remainder] of spacers) {
    el.style.height = whole / zoom + 'px';
    glueRemainders.set(el, remainder);
}
// The class gives one fil to the top and two to the bottom. Measure after wrapping:
// a long title, a second author line, or a title note reduces that shared space.
if (fineGrid && body.dataset.latexTitleLayout === 'separate') {
    for (const title of body.querySelectorAll('.latex-title-block:not(.latex-titlepage *)')) {
        const line = parseFloat(getComputedStyle(body).lineHeight) * zoom;
        const noteHeight = [...title.querySelectorAll('[data-flow-note]')].reduce((sum, a) => {
            const box = pendingMeasurements.find(([id]) => id === a.dataset.flowNote)?.[1];
            return sum + (box?.getBoundingClientRect().height || 0) * unit;
        }, 0);
        const scale = parseFloat(getComputedStyle(body).getPropertyValue('--latex-js-scale')) || 1;
        const end = line + (title.querySelector('.latex-date') ? 0 : 15 * 1.24533 * zoom * scale);
        const spare = bodyHeight - title.getBoundingClientRect().height * unit - end - noteHeight - (noteHeight ? noteSkip : 0);
        title.style.setProperty('--latex-title-fill', Math.max(0,spare) / (3 * zoom) + 'px');
    }
}
// Diagram links were installed before the reader knew each float's final measure.
for (const anchor of body.querySelectorAll('.surimono-diagram-anchor')) {
    const svg = anchor.parentElement.querySelector('svg');
    if (!svg) continue;
    for (const [key,value] of Object.entries({left:'0',top:'0',width:'1px',height:'1px'}))
        anchor.style.setProperty(key,value,'important');
    const rect = svg.getBoundingClientRect(), mark = anchor.getBoundingClientRect();
    if (!mark.width || !mark.height) continue;
    for (const [key,value] of Object.entries({left:(rect.left-mark.left)/mark.width,
        top:(rect.top-mark.top)/mark.height,width:rect.width/mark.width,height:rect.height/mark.height}))
        anchor.style.setProperty(key,value+'px','important');
}
if (globalThis.surimonoFlowMarks) surimonoFlowMarks();
const origins = strips.map(box => {
    const r = box.getBoundingClientRect();
    return {x:(r.left + scrollX)*unit, y:(r.top + scrollY)*unit, width:Number(box.dataset.flowWidth), height:r.height*unit,
        hasOverhang:!!box.querySelector('[data-flow-ink-block]')};
});
function slice(box, start, end) {
    const strip = +box.dataset.flowStrip;
    return {strip, start, end, width:origins[strip].width};
}
function whole(box) { return slice(box, 0, origins[+box.dataset.flowStrip].height); }
for (const [id, box] of pendingMeasurements) notes[id] = whole(box);
const range = document.createRange();
function tableItems(box, table) {
    const origin = origins[+box.dataset.flowStrip].y;
    function bounds(el) {
        if (!el) return null;
        const rect = el.getBoundingClientRect();
        return rect.height > 0 ? slice(box, (rect.top + scrollY) * unit - origin, (rect.bottom + scrollY) * unit - origin) : null;
    }
    const lastFoot = table.querySelector(':scope > [data-latex-last-foot]');
    const headGroup = table.querySelector(':scope > [data-latex-repeat-head]');
    const head = bounds(headGroup);
    const footGroup = table.querySelector(':scope > [data-latex-repeat-foot]');
    const foot = bounds(footGroup);
    const rows = [...table.tBodies[0].rows], items = [];
    const start = bounds(table.closest('figure.latex-longtable') || table)?.start || 0;
    const noteIDs = el => el ? [...el.querySelectorAll('[data-flow-note]')].map(n => n.dataset.flowNote) : [];
    const css = getComputedStyle(table);
    // A collapsed border straddles the row edge. An isolated capture owns its outside
    // half as well, even when an unused continuation sample follows in the source strip.
    function includeBottomRule(part, row) {
        if (!part || !row || css.borderCollapse !== 'collapse') return;
        let border = 0;
        for (const cell of row.cells) border = Math.max(border, parseFloat(getComputedStyle(cell).borderBottomWidth));
        part.end += border * zoom / 2;
    }
    if (headGroup) includeBottomRule(head, headGroup.rows[headGroup.rows.length - 1]);
    const strutDepth = .3 * parseFloat(css.lineHeight) * (Number(css.getPropertyValue('--latex-arraystretch')) || 1) * zoom;
    function breakDepth(row, size) {
        // A terminal rule is a zero-depth box below the row's strut.
        return row && Number.isFinite(strutDepth) && ![...row.cells].some(c => c.classList.contains('latex-bottom-hline') || c.style.borderBottomWidth) ?
            Math.min(strutDepth, size) : 0;
    }
    const footDepth = foot ? breakDepth(footGroup.rows[footGroup.rows.length-1], foot.end-foot.start) : 0;
    const preShrink = css.getPropertyValue('--latex-ltpre').trim() ? 0 : Math.min(start, bigSkipShrink);
    for (const [i, row] of rows.entries()) {
        budget();
        const part = bounds(row);
        if (!part) continue;
        const notes = noteIDs(row);
        if (!i) {
            part.start = start;
            notes.push(...noteIDs(table.tHead), ...noteIDs(table.previousElementSibling?.closest('figcaption')));
        }
        if (i === rows.length - 1 && lastFoot) {
            part.end = bounds(lastFoot)?.end ?? part.end;
            notes.push(...noteIDs(lastFoot));
        }
        if (i === rows.length - 1) includeBottomRule(part, lastFoot?.rows[lastFoot.rows.length - 1] || row);
        items.push({slice:part, gap:i ? 0 : start, notes, wide:false,
            tablePreShrink:i ? null : preShrink,
            // LT@start reserves ht, not ht+dp, for the foot. TeX also keeps the last row's
            // depth outside pagetotal. Both depths still paint when the page is shipped.
            tableBreakDepth:foot ? breakDepth(row, part.end-part.start) + footDepth : 0,
            repeatHead:i ? head : null, repeatFoot:i + 1 < rows.length ? foot : null});
    }
    return items;
}
function lines(box, endsPage) {
    // A title page fits on its final baseline. Its final descent can paint into the
    // margin through captureRects, just like ink from a raised box. Let long titles split.
    const title = box.children.length === 1 && box.firstElementChild;
    if (title && title.matches('.latex-titlepage:has(.latex-vfill)') && whole(box).end <= bodyHeight + .001
        && !title.querySelector('[data-flow-note]')) {
        return [{slice:whole(box), gap:0, notes:[], wide:false}];
    }
    const bands = [], paragraphs = new Map();
    const origin = origins[+box.dataset.flowStrip].y;
    function add(rect, el, ids = []) {
        if (!rect.width || !rect.height) return;
        budget();
        const para = el.closest('p,li,pre');
        if (para && !paragraphs.has(para)) paragraphs.set(para, paragraphs.size + 1);
        let end = (rect.bottom + scrollY)*unit-origin, shrinkAfter = 0;
        if (el.hasAttribute('data-flow-display') && (el.nextElementSibling || endsPage)) {
            // Below-display glue belongs to the gap before the next band. Keep the
            // usual SVG ink guard inside the capture even when that gap is discarded.
            const css = getComputedStyle(el);
            const glue = Math.max(0, parseFloat(css.paddingBottom) - .15 * parseFloat(css.fontSize)) * zoom;
            end -= glue;
            shrinkAfter = Math.min(glue, displayShrink);
        }
        // Expose the shrinkable part of the upper skip as blank space before the
        // formula. A kept heading and formula can then use it at a page boundary.
        const shrinkAbove = el.dataset.flowDisplay === 'normal'
            ? Math.min(displayShrink, parseFloat(getComputedStyle(el).paddingTop) * zoom) : 0;
        bands.push({start:Math.max(0,(rect.top + scrollY)*unit-origin) + shrinkAbove, end, shrinkAfter, shrinkAbove, para:paragraphs.get(para) || 0,
            element:el, extra:glueRemainders.get(el) || 0, discard:el.matches('.latex-vspace:not([data-latex-keep-space])'), heading:!!el.closest(heading) && !el.closest('.latex-runin:has(> p)'), ids});
    }
    const walker = document.createTreeWalker(box, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, {
        acceptNode(n) {
            if (n.parentElement.closest(atomic + ',' + excluded) || n.nodeType === 1 && n.matches(excluded))
                return NodeFilter.FILTER_REJECT;
            return NodeFilter.FILTER_ACCEPT;
        }
    });
    for (let n = walker.nextNode(); n; n = walker.nextNode()) {
        if (n.nodeType === Node.TEXT_NODE) {
            const el = n.parentElement, note = el.closest('[data-flow-note]');
            for (let offset = 0; offset < n.length; offset += 32768) {
                range.setStart(n, offset); range.setEnd(n, Math.min(n.length, offset + 32768));
                for (const r of range.getClientRects()) add(r, el, note ? [note.dataset.flowNote] : []);
            }
        } else if (n.matches(atomic + ',' + heading) || (!n.firstChild && getComputedStyle(n).position !== 'absolute')) {
            add(n.getBoundingClientRect(), n, [...n.querySelectorAll('[data-flow-note]')].map(a => a.dataset.flowNote));
        }
    }
    const rows = [];
    for (const b of bands.sort((a,b) => a.start - b.start)) {
        const last = rows.at(-1);
        if (last && b.start < last.end - 0.1) {
            if (b.end >= last.end) last.shrinkAfter = b.shrinkAfter;
            last.end = Math.max(last.end,b.end); last.extra += b.extra; last.heading ||= b.heading; last.discard &&= b.discard;
            if (!last.para) last.para = b.para;
            for (const id of b.ids) last.ids.add(id);
        } else rows.push({...b, ids:new Set(b.ids)});
    }
    if (!rows.length) {
        if (!origins[+box.dataset.flowStrip].height) return [];
        // An inline destination alone can give its anonymous paragraph a line height. The
        // strip between two forced breaks represents a location, not a page of blank ink.
        const marks = '[data-latex-page-action],[data-latex-probe],span[id]:empty,template,.latex-pagebreak';
        if (box.querySelector(marks) && !box.textContent.trim() &&
            !box.querySelector(':not(' + marks + ',p:not([style]),.latex-link-colors)')) return [];
        return [{slice:whole(box), gap:0, notes:[], wide:false}];
    }
    // Expose the first block's outside margin as discardable glue. Keep its border,
    // padding and first-line leading in the slice, including the title and chapter skips.
    let first = rows[0].element;
    while (first !== box && first.parentElement && first.parentElement !== box) first = first.parentElement;
    rows[0].start = Math.max(0, Math.min(rows[0].start, (first.getBoundingClientRect().top + scrollY)*unit-origin));
    const last = rows.at(-1);
    if (!(endsPage && last.shrinkAfter > 0)) last.end = Math.max(last.end, whole(box).end);
    return rows.map((r,i) => ({slice:slice(box,r.start,r.end), notes:[...r.ids], wide:false,
        gap:i ? Math.max(0,r.start-rows[i-1].end) : r.start, shrinkBefore:((rows[i-1]?.shrinkAfter || 0) + r.shrinkAbove) || undefined, discardable:r.discard, extraAfter:r.extra,
        topSkip:r.element.closest('[data-latex-heading="section"],[data-latex-heading="subsection"],[data-latex-heading="subsubsection"]') ? sectionTop : 0, paragraph:r.para, heading:r.heading, keepBefore:r.element.hasAttribute('data-flow-after-text') || undefined}));
}
// A TeX paragraph ends at the deepest glyph on its final line. Its HTML line box includes
// extra leading beneath that ink. Count that existing space towards intextsep when a figure
// actually lands here; deferred floats and consecutive floats retain their own full skips.
let inkContext;
function trailingLeading(box, last) {
    const p = box.lastElementChild, text = p?.lastChild;
    if (!last || !p?.matches('p') || !text) return 0;
    // A manual line break can precede the final line whose depth TeX measured.
    if (p.childNodes.length !== 1 && !(fineGrid && [...p.children].every(child => child.tagName === 'BR'))) return 0;
    if (text.nodeType !== Node.TEXT_NODE || !text.length || text.length > 32768) return 0;
    const css = getComputedStyle(p);
    if (css.writingMode !== 'horizontal-tb' || css.direction !== 'ltr' || css.textTransform !== 'none') return 0;
    inkContext ??= document.createElement('canvas').getContext('2d');
    if (!inkContext) return 0;
    const end = text.data.trimEnd().length;
    if (!end) return 0;
    range.setStart(text,end-1); range.setEnd(text,end);
    const finalY = range.getBoundingClientRect().top;
    let lo = 0, hi = end-1;
    while (lo < hi) {
        const mid = (lo+hi) >>> 1;
        range.setStart(text,mid); range.setEnd(text,mid+1);
        if (range.getBoundingClientRect().top < finalY-0.25) lo = mid+1; else hi = mid;
    }
    inkContext.font = css.fontStyle+' '+css.fontWeight+' '+css.fontSize+' '+css.fontFamily;
    const depth = inkContext.measureText(text.data.slice(lo,end)).actualBoundingBoxDescent * zoom;
    if (!Number.isFinite(depth)) return 0;
    const baseline = document.createElement('i');
    baseline.style.cssText = 'display:inline-block;width:0;height:0;vertical-align:baseline;margin:0;padding:0;border:0';
    p.append(baseline);
    const y = (baseline.getBoundingClientRect().bottom+scrollY)*unit - origins[last.strip].y;
    baseline.remove();
    return Math.max(0, Math.min(inTextSep, last.end-y-Math.max(0,depth)));
}
const bookFloats = ['memoir','scrartcl','scrreprt','scrbook'].includes(body.dataset.latexClass);
for (const seg of segments) {
    seg.items = seg.items.flatMap((item, i) => {
        if (item.table) return tableItems(item.run, item.table);
        if (item.run) {
            const next = seg.items[i+1];
            const rows = lines(item.run, next?.forced || (!next && seg === segments.at(-1)));
            // A deferred float leaves the two surrounding text strips adjacent. Measure
            // the first paragraph's missing afterheading leading at its actual size.
            const p = item.run.firstElementChild;
            if (fineGrid && rows.length && p?.matches('p') && i >= 2 && seg.items[i-1].floatKind
                && seg.items[i-2].run?.lastElementChild?.matches('[data-latex-heading]')) {
                const natural = p.getBoundingClientRect().height;
                p.dataset.flowFollowingHeading = '';
                rows[0].leadingAfterHeading = Math.max(0, (p.getBoundingClientRect().height - natural) * unit);
                // An in-text float preserves TeX's prevdepth from the preceding heading.
                // A top float instead leaves the paragraph directly after that heading.
                const float = seg.items[i-1];
                if (body.dataset.latexChapters === 'false' && float.placement?.includes('h') &&
                    strips[float.slice.strip].querySelector('figure > figcaption[style*="--latex-last-depth"]')) {
                    const depth = japaneseLineDepth(seg.items[i-2].run.lastElementChild);
                    if (depth !== null) rows[0].leadingAfterHere = Math.max(0, rows[0].leadingAfterHeading - depth * zoom);
                }
                delete p.dataset.flowFollowingHeading;
            }
            if (next?.floatKind === 'figure' && /[hH]/.test(next.placement)
                && (bookFloats || next.box.querySelector('figure > p:first-child[data-latex-rule-line]'))) {
                next.leadingBeforeHere = trailingLeading(item.run, rows.at(-1)?.slice);
            }
            if (fineGrid && next?.box && /[hH]/.test(next.placement)) {
                const previous = item.run.lastElementChild;
                if (previous?.matches('[data-latex-heading]')) {
                    const depth = japaneseLineDepth(previous);
                    if (depth !== null) next.leadingBeforeHere = -depth * zoom - (next.placement.includes('H') ? jsPoint : 0);
                } else if (next.placement.includes('H') && previous?.matches('p')) {
                    next.leadingBeforeHere = Math.max(0, trailingLeading(item.run, rows.at(-1)?.slice) - jsPoint);
                }
            }
            return rows;
        }
        if (item.box) { item.slice = whole(item.box); delete item.box; }
        return [item];
    });
}
globalThis.surimonoFlow = {strips, origins, unit};
const probes = [];
for (const a of body.querySelectorAll('[data-latex-page-target],[data-latex-probe],[data-flow-sample-place]')) {
    const box = a.closest('[data-flow-strip]');
    if (!box) continue;
    const strip = +box.dataset.flowStrip;
    probes.push({index:a.hasAttribute('data-flow-sample-place') ? -1 : Number(a.dataset.latexPageTarget ?? a.dataset.latexProbe), strip,
        position:(a.getBoundingClientRect().top + scrollY)*unit - origins[strip].y});
}
return JSON.stringify({segments,notes,noteSkip,noteRuleWidth,textFloatSep,floatSep,inTextSep,probes});
