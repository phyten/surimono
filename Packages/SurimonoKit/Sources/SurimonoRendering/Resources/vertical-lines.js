// Coordinates sent back to Swift are page coordinates in CSS pixels, including the reader's zoom.
const root = document.documentElement;
const body = document.body;
for (const element of [root, body]) {
    element.style.setProperty('writing-mode', 'horizontal-tb', 'important');
    element.style.setProperty('direction', 'ltr', 'important');
}
const strip = document.createElement('div');
strip.className = 'surimono-vertical';
const zoom = parseFloat(getComputedStyle(root).zoom) || 1;
strip.style.setProperty('--body-size', font + 'pt');
strip.style.setProperty('--content-width', (width / zoom) + 'px');
strip.style.setProperty('--content-height', (height / zoom) + 'px');
while (body.firstChild) strip.appendChild(body.firstChild);
body.appendChild(strip);

// Older WebKit reports DOMRects before CSS zoom. Compare a known physical length in the same coordinate system.
const probe = document.createElement('div');
probe.style.cssText = 'all:initial!important;position:absolute!important;height:100px!important';
body.appendChild(probe);
const unit = 100 * zoom / probe.getBoundingClientRect().height;
probe.remove();

// Keep additions bounded even if a short source produces a very large DOM.
const limit = 250000;
let wrappers = strip.querySelectorAll('.tcy,.upright-digit').length;
function wrapper(tag, className) {
    if (++wrappers > limit) throw new Error('Vertical layout exceeds the fragment limit');
    const element = document.createElement(tag);
    element.className = className;
    return element;
}

// The pre holding a plain-text document inherits the body's type and remains in vertical flow.
const horizontal = 'pre:not(.surimono-plain),table,figure,img,.math-block,.math-display,section.footnotes,'
    + '.mermaid-block,.graphviz-block,.plantuml-block';
for (const box of strip.querySelectorAll(horizontal)) {
    if (box.localName === 'pre') box.classList.add('vertical-code');
    if (box.parentElement.closest('.horizontal-box')) continue;
    const line = wrapper('div', 'horizontal-box-line');
    box.replaceWith(line);
    line.appendChild(box);
    box.classList.add('horizontal-box');
}
// A shoulder mark belongs to its base even at a line break. Take one whole grapheme
// so that combining marks and variation selectors stay on the same piece of paper.
const segments = new Intl.Segmenter('ja', {granularity: 'grapheme'});
for (const note of strip.querySelectorAll('sup.footnote-ref')) {
    if (note.closest('.horizontal-box')) continue;
    let base = note.previousSibling;
    const whole = '.tcy,.upright-digit,ruby,.math-inline,img,svg';
    while (base?.matches?.('a,b,code,del,em,i,mark,s,small,span,strong,sub,sup,u') && !base.matches(whole)) {
        base = base.lastChild;
    }
    if (base?.nodeType === Node.TEXT_NODE && /\S$/u.test(base.data)) {
        const last = segments.segment(base.data).containing(base.length - 1);
        if (last.index) base = base.splitText(last.index);
    } else if (!base?.matches?.(whole)) continue;
    // Keep the final glyph's formatting and link, without nesting the note link
    // inside the author's link or making a whole emphasized passage unbreakable.
    while (base.parentElement !== note.parentElement) {
        const parent = base.parentElement;
        if (!base.previousSibling) {
            base = parent;
            continue;
        }
        if (++wrappers > limit) throw new Error('Vertical layout exceeds the fragment limit');
        const tail = parent.cloneNode(false);
        tail.removeAttribute('id');
        tail.removeAttribute('name');
        parent.after(tail);
        tail.append(base);
        base = tail;
    }
    const group = wrapper('span', 'vertical-note-base');
    base.before(group);
    group.append(base, note);
}

// Shape horizontally, include ink outside the nominal math box (e.g. subscripts), then
// turn the entire SVG once. Reserve one body cell across the line, including for tall formulas.
const formulas = [...strip.querySelectorAll('.math-inline > svg')].filter(svg => !svg.closest('.horizontal-box'));
for (const svg of formulas) svg.parentElement.classList.add('vertical-inline-formula');
// Request the vertical glyphs and math faces before measuring their final advances.
strip.getBoundingClientRect();
await document.fonts.ready;
const formulaSizes = formulas.map(svg => {
    const vb = svg.viewBox.baseVal;
    if (!vb.width || !vb.height) return null;
    const ink = svg.getBBox();
    const x = Math.min(vb.x, ink.x), y = Math.min(vb.y, ink.y);
    const w = Math.max(vb.x + vb.width, ink.x + ink.width) - x;
    const h = Math.max(vb.y + vb.height, ink.y + ink.height) - y;
    const em = parseFloat(getComputedStyle(svg.parentElement).fontSize);
    const scale = Math.min(svg.width.baseVal.value / vb.width, em / h, height / zoom / w);
    return {x,y,w,h,scale};
});
formulas.forEach((svg, i) => {
    const size = formulaSizes[i];
    if (!size) {
        svg.parentElement.classList.remove('vertical-inline-formula');
        return;
    }
    const {x,y,w,h,scale} = size;
    svg.setAttribute('viewBox', [x,y,w,h].join(' '));
    svg.style.width = svg.parentElement.style.height = (w * scale) + 'px';
    svg.style.height = (h * scale) + 'px';
});
const atomic = '.horizontal-box,.vertical-inline-formula,.vertical-note-base,ruby,.tcy,svg,canvas,input,hr';
const excluded = 'style,script,template,noscript';
const heading = 'h1,h2,h3,h4,h5,h6';
// LaTeX titles and sections also use heading tags. Only the reader knows which command opened a chapter.
const latex = body.classList.contains('format-latex');
const chapter = latex ? '[data-latex-heading="chapter"],template[data-latex-break] + h2[id^="sec-"]' : 'h1';
const annotations = latex ? 'em,.kenten,.bousen' : 'em';
const breaksChapters = latex ? body.dataset.latexChapters === 'true' : booklet;

const range = document.createRange();
function paintBounds(element, box = element.getBoundingClientRect()) {
    // Orthogonal and absolutely positioned children can paint beyond their parent's border box.
    range.selectNodeContents(element);
    const ink = range.getBoundingClientRect();
    if (!ink.width || !ink.height) return box;
    if (!box.width || !box.height) return ink;
    const x = Math.min(box.left, ink.left), y = Math.min(box.top, ink.top);
    return new DOMRect(x, y, Math.max(box.right, ink.right)-x, Math.max(box.bottom, ink.bottom)-y);
}

// Measure first and then change zoom together. Interleaving reads and writes lays out the entire novel for each box.
const fits = [];
for (const box of strip.querySelectorAll(atomic)) {
    if (box.parentElement.closest(atomic)) continue;
    const rect = paintBounds(box);
    if (!rect.width || !rect.height) continue;
    const line = box.closest('.horizontal-box-line');
    const padding = line ? 2 * parseFloat(getComputedStyle(line).paddingTop) * zoom : 0;
    const scale = Math.min(width / (rect.width * unit), Math.max(1, height - padding) / (rect.height * unit));
    if (scale < 1) fits.push([box, scale * (parseFloat(getComputedStyle(box).zoom) || 1)]);
}
for (const [box, scale] of fits) box.style.zoom = scale;

// The parent flows right to left. Its block advance is the horizontal box's
// physical width, irrespective of the box's height or an orthogonal intrinsic size.
const boxes = [...strip.querySelectorAll('.horizontal-box-line > .horizontal-box')];
const widths = boxes.map(box => paintBounds(box).width * unit / zoom);
boxes.forEach((box, i) => box.parentElement.style.blockSize = widths[i] + 'px');

// A collapsible space usually already has zero advance at a soft break. Preserve that
// break opportunity if a WebKit version leaves a residual advance. Work in batches so a
// changed break can restore a gap that has moved back into the middle of the next line.
const gaps = [...strip.querySelectorAll('.aki,.v-before-open')];
function neighboringUnit(gap, forward) {
    const root = gap.closest('p,pre,li,h1,h2,h3,h4,h5,h6,blockquote') || strip;
    let n = gap;
    while (n !== root) {
        const sibling = forward ? n.nextSibling : n.previousSibling;
        if (!sibling) { n = n.parentNode; continue; }
        n = sibling;
        while (n.nodeType === Node.ELEMENT_NODE) {
            if (n.matches('br,' + excluded)) return null;
            if (n.matches(atomic + ',code')) return () => n.getBoundingClientRect();
            const child = forward ? n.firstChild : n.lastChild;
            if (!child) break;
            n = child;
        }
        if (n.nodeType === Node.TEXT_NODE && n.length) {
            const at = forward ? 0 : n.length - 1;
            return () => {
                range.setStart(n, at); range.setEnd(n, at + 1);
                return range.getBoundingClientRect();
            };
        }
    }
    return null;
}
function stabilizeEdges() {
    const edges = gaps.map(gap => [neighboringUnit(gap, false), neighboringUnit(gap, true)]);
    for (let pass = 0; gaps.length && pass < 3; ++pass) {
        const changes = [], suppressedPositions = [], unstableLines = [];
        for (const [i,gap] of gaps.entries()) {
            const a = edges[i][0]?.(), b = edges[i][1]?.();
            const edge = !a || !b || (a.width && b.width && (a.right <= b.left || b.right <= a.left));
            const suppressed = gap.classList.contains('v-edge');
            const used = suppressed || [...gap.getClientRects()].some(r => r.height > 0);
            const changed = Boolean(edge && used) !== suppressed;
            if (changed) changes.push(gap);
            if (pass === 2 && (changed || suppressed)) {
                for (const rect of [a,b]) {
                    if (!rect?.width) continue;
                    if (changed) unstableLines.push((rect.left + rect.right)/2);
                    if (suppressed) suppressedPositions.push([rect,gap]);
                }
            }
        }
        if (!changes.length) break;
        if (pass < 2) {
            for (const gap of changes) gap.classList.toggle('v-edge');
            continue;
        }
        // Restore native spacing throughout a fluctuating line, including its other end.
        // Sweep the fractional column positions once after reading all of the geometry.
        const restore = new Set(changes);
        unstableLines.sort((a,b) => a-b);
        suppressedPositions.sort(([a],[b]) => a.left-b.left);
        let line = 0;
        for (const [rect,gap] of suppressedPositions) {
            while (line < unstableLines.length && unstableLines[line] < rect.left) ++line;
            if (line < unstableLines.length && unstableLines[line] <= rect.right) restore.add(gap);
        }
        for (const gap of restore) gap.classList.remove('v-edge');
    }
}

function layoutRect(el) {
    if (el.matches('ruby,.vertical-note-base')) {
        let left = Infinity, right = -Infinity, top = Infinity, bottom = -Infinity;
        for (const child of el.childNodes) {
            if (child.matches?.('rt,rp,sup.footnote-ref')) continue;
            range.selectNodeContents(child);
            const rect = range.getBoundingClientRect();
            if (!rect.width || !rect.height) continue;
            left = Math.min(left, rect.left); right = Math.max(right, rect.right);
            top = Math.min(top, rect.top); bottom = Math.max(bottom, rect.bottom);
        }
        if (right > left) return new DOMRect(left, top, right-left, bottom-top);
    }
    return el.getBoundingClientRect();
}
// Leading space belongs between blocks. Keeping the absolute strip positions preserves it inside
// a row, while a capture that starts with a heading can begin at its text just like a body line.
function headingRight(element, rect) {
    range.selectNodeContents(element);
    const content = range.getBoundingClientRect();
    if (content.width) return Math.min(rect.right, content.right);
    const padding = parseFloat(getComputedStyle(element).paddingRight) * zoom / unit;
    return Math.max(rect.left, rect.right - padding);
}
globalThis.surimonoVerticalX = element => {
    const rect = element.getBoundingClientRect();
    const right = element.matches(heading) ? headingRight(element, rect) : rect.right;
    return (right + window.scrollX) * unit;
};
let originX, originY;
function measureLayout() {
    strip.style.left = '';
    strip.style.top = '';
    stabilizeEdges();
    const bands = [];
    originX = window.scrollX;
    const stripTop = strip.getBoundingClientRect().top;
    function add(rect, keepNext, paint = rect, rightInk = 0, chapter = false) {
        if (!rect.width || !rect.height) return;
        if (bands.length >= limit) throw new Error('Vertical layout exceeds the fragment limit');
        // Keep the line advance independent of the ink allowance, even when two neighboring
        // lines' ruby or emphasis marks overlap. Both use the same fractional CSS coordinates.
        bands.push({start: -(rect.right + originX) * unit, end: -(rect.left + originX) * unit,
            keepNext, chapter, ink: {start: -(paint.right + originX) * unit - rightInk - 1,
                end: -(paint.left + originX) * unit + 1, top: (paint.top - stripTop) * unit,
                bottom: (paint.bottom - stripTop) * unit}});
    }
    function emphasisInk(emphasis) {
        return emphasis && !emphasis.hasAttribute('data-vertical-latin')
            ? parseFloat(getComputedStyle(emphasis).fontSize) * zoom * 0.5 : 0;
    }
    const walker = document.createTreeWalker(strip, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, {
        acceptNode(n) {
            if (n.nodeType === Node.ELEMENT_NODE && n.matches(excluded)) return NodeFilter.FILTER_REJECT;
            if (n.parentElement.closest(atomic)) return NodeFilter.FILTER_REJECT;
            return NodeFilter.FILTER_ACCEPT;
        }
    });
    for (let n = walker.nextNode(); n; n = walker.nextNode()) {
        if (n.nodeType === Node.TEXT_NODE) {
            const parent = n.parentElement;
            const keep = !!parent.closest(heading);
            const extra = emphasisInk(parent.closest(annotations));
            // A plain-text book can be a single text node. Bound each temporary DOMRectList.
            for (let offset = 0; offset < n.length; offset += 32768) {
                range.setStart(n, offset);
                range.setEnd(n, Math.min(n.length, offset + 32768));
                for (const rect of range.getClientRects()) add(rect, keep, rect, extra);
            }
        } else if (n.matches(heading)) {
            // Keep the trailing space with the heading, without joining it to the next block at a shared edge.
            const rect = n.getBoundingClientRect();
            const right = headingRight(n, rect);
            const layout = new DOMRect(rect.left, rect.top, right - rect.left, rect.height);
            add(layout, true, layout, 0, breaksChapters && n.matches(chapter));
        } else if (n.matches('blockquote')) {
            const rect = n.getBoundingClientRect();
            const style = getComputedStyle(n);
            const firstLine = parseFloat(style.paddingRight) + parseFloat(style.borderRightWidth) + parseFloat(style.lineHeight);
            const reserved = Math.min(rect.width, firstLine * zoom / unit);
            add(new DOMRect(rect.right - reserved, rect.top, reserved, rect.height), false);
        } else if (n.matches(atomic)) {
            const paint = paintBounds(n);
            const layout = layoutRect(n);
            const emphasis = n.closest(annotations) || n.querySelector(latex ? 'em:not([data-vertical-latin]),.kenten,.bousen' : 'em:not([data-vertical-latin])');
            add(layout.width && layout.height ? layout : paint, !!n.closest(heading), paint, emphasisInk(emphasis));
        }
    }
    // A vertical-rl child can overflow the intrinsic strip to the left of the document.
    // WKPDFConfiguration captures positive page coordinates. Move the entire measured strip
    // before cutting; clamping individual boxes here would silently truncate the last rows.
    const shift = bands.reduce((right, band) => Math.max(right, band.ink.end, band.end), 0);
    if (shift > 0) {
        const left = strip.getBoundingClientRect().left + originX;
        strip.style.position = 'relative';
        strip.style.left = ((shift + 1) / zoom) + 'px';
        originX = window.scrollX;
        const delta = (strip.getBoundingClientRect().left + originX - left) * unit;
        for (const band of bands) {
            band.start -= delta;
            band.end -= delta;
            band.ink.start -= delta;
            band.ink.end -= delta;
        }
    }
    const topInk = bands.reduce((top, band) => Math.min(top, band.ink.top), 0);
    if (topInk < 0) {
        strip.style.position = 'relative';
        strip.style.top = ((1 - topInk) / zoom) + 'px';
    }
    originY = (strip.getBoundingClientRect().top + window.scrollY) * unit;
    return JSON.stringify({bands, originY});
}
// WebKit paints off-slice glyphs into createPDF's clipped content stream. Hide complete
// subtrees and split only text nodes crossing a cut, preserving the strip's line layout.
const indexedText = new WeakSet();
globalThis.surimonoIndexSlices = slices => {
    const cuts = slices.map((slice, i) => i+1 < slices.length ? (slice[1]+slices[i+1][0])/2 : slice[1]);
    const pages = cuts.map(() => []);
    function pageAt(x) {
        const coordinate = -(x + originX) * unit;
        let lo = 0, hi = cuts.length - 1;
        while (lo < hi) {
            const mid = (lo + hi) >>> 1;
            if (coordinate <= cuts[mid]) hi = mid;
            else lo = mid + 1;
        }
        return lo;
    }
    const replacements = [];
    const tree = document.createTreeWalker(strip, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, {
        acceptNode(n) {
            if (n.nodeType === Node.TEXT_NODE) return NodeFilter.FILTER_ACCEPT;
            if (n.matches(excluded)) return NodeFilter.FILTER_REJECT;
            const border = n.getBoundingClientRect();
            const indivisible = n.matches(atomic);
            // Measuring all descendants of a book-length paragraph is unnecessary when
            // even its border box crosses a cut: its children must be indexed separately.
            if (!indivisible && pageAt(border.left) !== pageAt(border.right)) return NodeFilter.FILTER_SKIP;
            const rect = indivisible ? layoutRect(n) : paintBounds(n, border);
            if (indivisible && rect.width) {
                pages[pageAt((rect.left + rect.right) / 2)].push(n);
                return NodeFilter.FILTER_REJECT;
            }
            const page = pageAt(rect.right);
            if (rect.width && page === pageAt(rect.left)) {
                pages[page].push(n);
                return NodeFilter.FILTER_REJECT;
            }
            return NodeFilter.FILTER_SKIP;
        }
    });
    for (let n = tree.nextNode(); n; n = tree.nextNode()) {
        range.selectNodeContents(n);
        const bounds = range.getBoundingClientRect();
        if (!bounds.width || !bounds.height) continue;
        const firstPage = pageAt(bounds.right);
        const lastPage = pageAt(bounds.left);
        function at(i) {
            range.setStart(n, i);
            range.setEnd(n, i + 1);
            const rect = range.getBoundingClientRect();
            if (rect.width && rect.height) return pageAt((rect.left + rect.right) / 2);
            // Collapsed whitespace has no position. Keep it with the preceding visible text.
            range.setStart(n, 0);
            const prefix = range.getBoundingClientRect();
            return prefix.width ? pageAt(prefix.left) : firstPage;
        }
        if (indexedText.has(n.parentElement) && at(0) === at(n.length - 1)) {
            pages[at(0)].push(n.parentElement);
            continue;
        }
        const pieces = document.createDocumentFragment();
        for (let start = 0; start < n.length;) {
            const page = start === 0 ? firstPage : at(start);
            let lo = page === lastPage ? n.length : start + 1, hi = n.length;
            while (lo < hi) {
                const mid = lo + Math.floor((hi - lo) / 2);
                if (at(mid) <= page) lo = mid + 1;
                else hi = mid;
            }
            const span = wrapper('span', '');
            span.textContent = n.data.slice(start, lo);
            indexedText.add(span);
            pages[page].push(span);
            pieces.appendChild(span);
            start = lo;
        }
        replacements.push([n, pieces]);
    }
    // Batch DOM writes after all range queries so measuring later paragraphs cannot force repeated layout.
    if (replacements.length) {
        for (const [node, pieces] of replacements) node.replaceWith(pieces);
        // Inline visibility spans normally leave shaping alone, but only the final DOM's
        // measurements may drive a capture. Re-index these persistent pieces at the new cuts.
        return measureLayout();
    }
    // The theme sampler may still inspect the full document before choosing its first capture.
    let previous;
    globalThis.surimonoCaptureSlice = index => {
        if (index >= slices.length) return null;
        if (previous) {
            for (const el of previous) el.classList.add('surimono-off-page');
        } else {
            for (const page of pages) for (const el of page) el.classList.add('surimono-off-page');
        }
        previous = pages[index];
        for (const el of previous) el.classList.remove('surimono-off-page');
        const [,,right,left,top,bottom] = slices[index];
        return [right/unit-originX, left/unit-originX, (originY+top)/unit-window.scrollY, (originY+bottom)/unit-window.scrollY];
    };
    return null;
};
const measured = measureLayout();
globalThis.surimonoFormulaIndex?.native();
return measured;
