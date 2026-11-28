// Read the heading groups of the printable DOM and what has to share their page. Nothing in the DOM is changed.
// The text is read as printed-fragments.js reads it, so that offsets match the glyphs of the printed PDF.
// Arguments: limit (UTF-16 units of text), milliseconds (time budget).
const end = performance.now() + milliseconds;
let units = 0, visits = 0;
const over = () => ++visits > 400000 || units > limit || performance.now() >= end;
const chunks = [], offsets = new Map(), shown = new Map();
let length = 0;
const skipped = 'script,style,template,svg,math,textarea,noscript';
function visible(element) {
    let answer = shown.get(element);
    if (answer === undefined) {
        const box = element.getBoundingClientRect();
        answer = getComputedStyle(element).visibility === 'visible' && (box.width > 0 || box.height > 0);
        shown.set(element, answer);
    }
    return answer;
}
function visit(node, depth) {
    if (over()) throw Error('budget');
    if (depth > 256) throw Error('depth');
    if (node.nodeType === Node.TEXT_NODE) {
        units += node.length;
        const value = node.data.replace(/[\s­​]/gu, '');
        if (!value.length || !node.parentElement || !visible(node.parentElement)) return;
        offsets.set(node, [length, length + value.length]);
        chunks.push(value);
        length += value.length;
        return;
    }
    if (node.nodeType !== Node.ELEMENT_NODE || node.matches(skipped)) return;
    if (getComputedStyle(node).display === 'none') return;
    for (let child = node.firstChild; child; child = child.nextSibling) visit(child, depth + 1);
}
// The first and the end offset of the text of an element, from its own text nodes in reading order. The walk stops
// once the text reaches `cap` units, so that a container holding a whole chapter costs no more than its start.
function span(element, cap = Infinity) {
    const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT);
    let first = null, last = null;
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
        const range = offsets.get(node);
        if (!range) continue;
        if (!first) first = range;
        last = range;
        if (last[1] - first[0] >= cap) break;
    }
    return first ? [first[0], last[1]] : null;
}
function afterSubtree(element) {
    let node = element;
    while (node && node !== document.body && !node.nextElementSibling) node = node.parentElement;
    return !node || node === document.body ? null : node.nextElementSibling;
}
const forcedBreaks = new Set(['page', 'left', 'right', 'recto', 'verso']);
const graphic = 'img,svg,canvas,video,picture,iframe,object,embed';
const keepItems = 'h1,h2,h3,h4,h5,h6,dt';
const leadIns = 'p.org-planning,pre.org-drawer';
function holdsText(element) {
    for (const child of element.childNodes) {
        if (child.nodeType === Node.TEXT_NODE) {
            if (offsets.has(child)) return true;
        } else if (child.nodeType === Node.ELEMENT_NODE) {
            const display = getComputedStyle(child).display;
            if (display.startsWith('inline') && display !== 'inline-block' && span(child, 1)) return true;
            if (!display.startsWith('inline')) return false;
        }
    }
    return false;
}
function eligible(heading) {
    if (!span(heading, 1)) return false;
    if (heading.closest('nav,table,figure,.paper-toc-row,[aria-hidden="true"]')) return false;
    // Inside a block that keeps together, the heading already travels with its text.
    for (let node = heading.parentElement; node && node !== document.body; node = node.parentElement) {
        if (getComputedStyle(node).breakInside.startsWith('avoid')) return false;
    }
    return true;
}
// What after the group has to share its page: [kind, start, end, lines].
function follow(cursor, group, items) {
    while (cursor) {
        if (over()) throw Error('budget');
        const style = getComputedStyle(cursor);
        if (style.display === 'none' || cursor.matches(skipped)) { cursor = afterSubtree(cursor); continue; }
        if (forcedBreaks.has(style.breakBefore) || cursor.matches('.page-break,.latex-pagebreak')) return ['none'];
        if (items.has(cursor) && !cursor.hasAttribute('data-surimono-keep')) {
            group.push(cursor);
            cursor = afterSubtree(cursor);
            continue;
        }
        if (cursor.matches(leadIns) && span(cursor, 1)) {
            group.push(cursor);
            cursor = afterSubtree(cursor);
            continue;
        }
        const text = span(cursor, 1200);
        if (!text) {
            const box = cursor.getBoundingClientRect();
            if (box.height > 0 && (cursor.matches(graphic) || cursor.querySelector(graphic))) return ['graphic'];
            cursor = afterSubtree(cursor);
            continue;
        }
        if (cursor.matches('table')) {
            // A long table may break between rows: the header and one row of data stay with the heading.
            const rows = [];
            for (const row of cursor.rows) {
                const found = span(row, 1);
                if (found) rows.push(found);
                if (rows.length > 1) break;
            }
            const row = rows[Math.min(1, rows.length - 1)] ?? text;
            return ['block', row[0], row[0] + 1];
        }
        if (cursor.matches('pre,figure,blockquote,.math-block,.mermaid-block,.graphviz-block,.plantuml-block') ||
            style.breakInside.startsWith('avoid') || /^(table|flex|grid|inline-)/.test(style.display)) {
            return ['block', text[0], text[0] + 1];
        }
        if (holdsText(cursor) || cursor.matches('p,li,dd')) {
            const lines = Math.min(5, Math.max(2, parseInt(style.orphans, 10) || 2));
            return ['text', text[0], Math.min(text[1], text[0] + 1200), lines];
        }
        cursor = cursor.firstElementChild ?? afterSubtree(cursor);
    }
    return ['none'];
}
try {
    visit(document.body, 0);
    const items = new Set([...document.body.querySelectorAll(keepItems)].filter(eligible));
    const groups = [], elements = [], consumed = new Set();
    for (const heading of document.body.querySelectorAll(keepItems)) {
        if (!items.has(heading) || consumed.has(heading)) continue;
        const group = [heading];
        const [kind, start, stop, lines] = follow(afterSubtree(heading), group, items);
        for (const member of group) consumed.add(member);
        const first = span(group[0], 1), last = span(group[group.length - 1]);
        const entry = {h: [first[0], last[1]], k: kind};
        if (start !== undefined) entry.f = [start, stop];
        if (lines !== undefined) entry.n = lines;
        groups.push(entry);
        elements.push(heading);
        if (groups.length > 8192) throw Error('budget');
    }
    globalThis.surimonoKeepGroups = elements;
    return JSON.stringify({text: chunks.join(''), groups});
} catch (error) {
    globalThis.surimonoKeepGroups = [];
    return JSON.stringify({unmeasured: String(error.message) === 'budget' ? 'budget' : 'failed'});
}
