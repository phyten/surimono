// Read the author's DOM. No attribute, node, selection, style or scroll position is changed.
// UTF-16 offsets identify text fragments in reading order, including repeated link labels.
const end = performance.now() + 100;
let visits = 0, units = 0, entries = 0;
const check = () => {
    if (++visits > 16000 || units > 384000 || entries > 4096 || performance.now() >= end)
        throw Error('Fragment measurement budget exhausted');
};
if (document.URL.length > 8192 || document.baseURI.length > 8192) return null;
const current = document.URL.split('#')[0];
const chunks = [], links = [], anchors = [], rows = [], named = new Map(), spans = new Map();
const following = new Map();
let length = 0;
function visit(node, depth, linkBoxes, rowBoxes) {
    check();
    if (depth > 128) throw Error('Fragment nesting limit');
    if (node.nodeType === Node.TEXT_NODE) {
        units += node.length;
        check();
        const value = node.data.replace(/[\s\u00ad\u200b]/gu, '');
        if (!value.length) return;
        const range = document.createRange();
        range.selectNodeContents(node);
        const box = range.getBoundingClientRect();
        if (!box.width || !box.height) return;
        // The vertical compositor hides every slice except the last after capture. Their
        // layout boxes still exist and the PDF contains the visible text from each slice.
        if (getComputedStyle(node.parentElement).visibility !== 'visible' &&
            !(vertical && node.parentElement.closest('.surimono-vertical .surimono-off-page'))) return;
        if (linkBoxes || rowBoxes) {
            for (const rect of range.getClientRects()) {
                check();
                if (!rect.width || !rect.height) continue;
                const piece = globalThis.surimonoVerticalFragment(rect);
                if (linkBoxes) linkBoxes.push(piece);
                if (rowBoxes) rowBoxes.push(piece);
            }
        }
        following.set(length, node);
        chunks.push(value);
        length += value.length;
        return;
    }
    if (node.nodeType !== Node.ELEMENT_NODE ||
        node.matches('script,style,template,svg,math,textarea,noscript') ||
        getComputedStyle(node).display === 'none') return;
    const start = length;
    const isRow = node.classList.contains('paper-toc-row');
    if (isRow && vertical) rowBoxes = [];
    let link;
    if (node instanceof HTMLAnchorElement && node.hasAttribute('href')) {
        const attribute = node.getAttribute('href');
        if (attribute.length > 8192) throw Error('Fragment URL too long');
        const raw = attribute.trim(), url = node.href;
        const hash = url.indexOf('#');
        if (hash >= 0 && (url.slice(0,hash) === current ||
            (raw.startsWith('#') && url.slice(0,hash) === resourceBase))) {
            let id = url.slice(hash+1);
            try { id = decodeURIComponent(id); } catch {}
            link = {id, start, url, end:start, top:false};
            if (vertical) link.boxes = linkBoxes = [];
            units += url.length;
            links.push(link);
            ++entries;
        }
    }
    for (let child = node.firstChild; child; child = child.nextSibling) visit(child, depth+1, linkBoxes, rowBoxes);
    if (link) link.end = length;
    if (node.id || (node instanceof HTMLAnchorElement && node.name)) {
        units += node.id.length + (node.name?.length || 0);
        check();
        spans.set(node, {start, end:length});
        if (node instanceof HTMLAnchorElement && node.name && !named.has(node.name)) named.set(node.name, node);
        ++entries;
    }
    if (isRow) { rows.push({start, end:length, boxes:rowBoxes}); ++entries; }
}
try {
    visit(document.body, 0);
    const wanted = new Set(links.map(link => link.id));
    for (const id of headingIDs) { check(); wanted.add(id); }
    for (const id of wanted) {
        check();
        const el = document.getElementById(id) || named.get(id);
        const span = spans.get(el);
        if (!span) continue;
        const text = following.get(span.start);
        if (!text) continue;
        let limit = span.end;
        const box = el.getBoundingClientRect();
        const range = document.createRange();
        const offset = text.data.search(/[^\s\u00ad\u200b]/u);
        const glyph = String.fromCodePoint(text.data.codePointAt(offset));
        range.setStart(text, offset);
        range.setEnd(text, offset + glyph.length);
        const first = range.getBoundingClientRect();
        if (span.start === limit) {
            // A Word bookmark can touch its following text. A replaced element's static
            // insertion point has no bearing on the position of its printed content.
            if (!(el instanceof HTMLAnchorElement) || !box.height ||
                Math.abs(first.left - box.left) > 1 || Math.abs(first.top - box.top) > 1) continue;
            ++limit;
        } else if (first.right < box.left || first.left > box.right ||
            first.bottom < box.top || first.top > box.bottom) {
            continue;
        }
        const anchor = {id, start:span.start, end:limit};
        if (vertical) {
            anchor.box = globalThis.surimonoVerticalFragment(first);
            anchor.glyph = glyph;
        }
        anchors.push(anchor);
    }
    for (const link of links) {
        check();
        link.top = !link.id || (link.id.toLowerCase() === 'top' &&
            !document.getElementById(link.id) && !named.has(link.id));
    }
    if (!anchors.length && !links.length && !rows.length) return null;
    return JSON.stringify({text:chunks.join(''), anchors, links, rows});
} catch { return null; }
