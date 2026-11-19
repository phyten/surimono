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
strip.style.setProperty('--content-height', (height / zoom) + 'px');
while (body.firstChild) strip.appendChild(body.firstChild);
body.appendChild(strip);

// Older WebKit reports DOMRects before CSS zoom. Compare a known physical length in the same coordinate system.
const probe = document.createElement('div');
probe.style.cssText = 'all:initial!important;position:absolute!important;height:100px!important';
body.appendChild(probe);
const unit = 100 * zoom / probe.getBoundingClientRect().height;
probe.remove();
// The sampler looks up its chosen heading after layout in this same isolated world.
globalThis.surimonoVerticalX = element => (element.getBoundingClientRect().right + window.scrollX) * unit;

// Keep additions bounded even if a short source produces a very large DOM.
const limit = 250000;
let wrappers = 0;
function wrapper(tag, className) {
    if (++wrappers > limit) throw new Error('Vertical layout exceeds the fragment limit');
    const element = document.createElement(tag);
    element.className = className;
    return element;
}

// The pre holding a plain-text document inherits the body's type and remains in vertical flow.
for (const box of strip.querySelectorAll('pre:not(.surimono-plain),table,img')) {
    if (box.parentElement.closest('.horizontal-box')) continue;
    const line = wrapper('div', 'horizontal-box-line');
    box.replaceWith(line);
    line.appendChild(box);
    box.classList.add('horizontal-box');
}
const atomic = '.horizontal-box,svg,canvas,input,hr';
const excluded = 'style,script,template,noscript';
const heading = 'h1,h2,h3,h4,h5,h6';
const textNodes = document.createTreeWalker(strip, NodeFilter.SHOW_TEXT);
let node = textNodes.nextNode();
while (node) {
    const next = textNodes.nextNode();
    const value = node.data;
    if (!node.parentElement.closest(atomic + ',' + excluded + ',code,rt,rp') && /[0-9０-９]/.test(value)) {
        let offset = 0;
        const pieces = document.createDocumentFragment();
        for (const match of value.matchAll(/[0-9０-９]+/g)) {
            pieces.append(value.slice(offset, match.index));
            const span = wrapper('span', match[0].length <= 2 ? 'tcy' : 'upright-digits');
            span.textContent = match[0];
            pieces.append(span);
            offset = match.index + match[0].length;
        }
        if (offset) {
            pieces.append(value.slice(offset));
            node.replaceWith(pieces);
        }
    }
    node = next;
}

// Measure first and then change zoom together. Interleaving reads and writes lays out the entire novel for each box.
const fits = [];
for (const box of strip.querySelectorAll(atomic)) {
    if (box.parentElement.closest(atomic)) continue;
    const rect = box.getBoundingClientRect();
    if (!rect.width || !rect.height) continue;
    const line = box.closest('.horizontal-box-line');
    const padding = line ? 2 * parseFloat(getComputedStyle(line).paddingTop) * zoom : 0;
    const scale = Math.min(width / (rect.width * unit), Math.max(1, height - padding) / (rect.height * unit));
    if (scale < 1) fits.push([box, scale * (parseFloat(getComputedStyle(box).zoom) || 1)]);
}
for (const [box, scale] of fits) box.style.zoom = scale;

const bands = [];
const originX = window.scrollX;
function add(rect, keepNext, rightInk = 0) {
    if (!rect.width || !rect.height) return;
    if (bands.length >= limit) throw new Error('Vertical layout exceeds the fragment limit');
    // Whole pixels give the PDF capture an unambiguous edge. Leave a pixel for glyph overhang.
    bands.push({start: -Math.ceil((rect.right + originX) * unit + rightInk + 1),
        end: -Math.max(0, Math.floor((rect.left + originX) * unit - 1)), keepNext});
}
const range = document.createRange();
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
        const emphasis = parent.closest('em');
        const extra = emphasis ? parseFloat(getComputedStyle(emphasis).fontSize) * zoom * 0.5 : 0;
        // A plain-text book can be a single text node. Bound each temporary DOMRectList.
        for (let offset = 0; offset < n.length; offset += 32768) {
            range.setStart(n, offset);
            range.setEnd(n, Math.min(n.length, offset + 32768));
            for (const rect of range.getClientRects()) add(rect, keep, extra);
        }
    } else if (n.matches('ruby')) {
        // Reading marks can have an actual gap from the base. Reserve that gap on the same page too.
        range.selectNodeContents(n);
        add(range.getBoundingClientRect(), !!n.closest(heading));
    } else if (n.matches(atomic + ',.tcy,' + heading)) {
        for (const rect of n.getClientRects()) add(rect, !!n.closest(heading));
    }
}
// WebKit paints off-slice glyphs into createPDF's clipped content stream. Hide complete
// subtrees and split only text nodes crossing a cut, preserving the strip's line layout.
globalThis.surimonoIndexSlices = cuts => {
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
            const rect = n.getBoundingClientRect();
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
            pages[page].push(span);
            pieces.appendChild(span);
            start = lo;
        }
        replacements.push([n, pieces]);
    }
    // Batch DOM writes after all range queries so measuring later paragraphs cannot force repeated layout.
    for (const [node, pieces] of replacements) node.replaceWith(pieces);
    for (const page of pages) for (const el of page) el.classList.add('surimono-off-page');
    let previous = [];
    globalThis.surimonoCaptureSlice = index => {
        for (const el of previous) el.classList.add('surimono-off-page');
        previous = pages[index];
        for (const el of previous) el.classList.remove('surimono-off-page');
    };
};
return JSON.stringify(bands);
