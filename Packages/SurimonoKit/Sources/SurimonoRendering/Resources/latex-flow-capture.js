// A clip alone retains invisible glyphs in WebKit's PDF text stream. Index complete subtrees,
// splitting text only where a chosen cut crosses its node, before changing visibility.
const {strips, origins, unit} = surimonoFlow;
// A padded slice must not cover the ink of its neighbour with the page's own white.
// The logical paper (including any separately composed theme background) sits under all slices.
const canvas = document.createElement('style');
canvas.textContent = 'html,body{background:transparent!important}' +
    '[data-flow-hidden-marker]::before{visibility:hidden!important}';
document.body.append(canvas);
const memberships = pieces.map(() => []);
const markers = pieces.map(() => []);
const leaders = new Map();
const byStrip = new Map(), owners = [];
for (const [i, p] of pieces.entries()) {
    if (!byStrip.has(p.strip)) byStrip.set(p.strip, new Map());
    const entries = byStrip.get(p.strip);
    const key = p.start + '/' + p.end;
    // A continuation band may be captured on many pages. Its DOM nodes have a
    // single visibility owner even when the destinations and page numbers differ.
    if (!entries.has(key)) entries.set(key, {...p, index:i});
    owners.push(entries.get(key).index);
}
const range = document.createRange(), edits = [];
// Append all probes before reading geometry so a long contents does not force layout for each row.
// Measuring a long rule once avoids accumulating a rounded layout unit in every pitch.
const pitches = 128, periods = new Map();
let metrics;
function folioGlyph(field, origin) {
    const text = field.firstChild;
    if (text?.nodeType !== Node.TEXT_NODE || !text.length) return null;
    metrics ??= document.createElement('canvas').getContext('2d');
    if (!metrics) return null;
    const char = [...text.data].at(-1);
    range.setStart(text, text.length-char.length);
    range.setEnd(text, text.length);
    const r = range.getBoundingClientRect(), css = getComputedStyle(field);
    // Only the ratio of ink ascent to descent is needed. A design-sized measurement
    // keeps rounding of small canvas metrics out of the printed baseline.
    metrics.font = css.fontStyle + ' ' + css.fontWeight + ' 1000px ' + css.fontFamily;
    const m = metrics.measureText(char);
    const height = m.actualBoundingBoxAscent + m.actualBoundingBoxDescent;
    if (!(height > 0 && r.width > 0)) return null;
    return {x:((r.left+r.right)/2+scrollX)*unit-origin.x, y:((r.top+r.bottom)/2+scrollY)*unit-origin.y,
        text:char, descentFraction:m.actualBoundingBoxDescent/height};
}
for (const dots of document.querySelectorAll('nav.toc .latex-page-entry > .latex-page-leader > .latex-leader-dots')) {
    const field = dots.closest('.latex-page-entry')?.lastElementChild;
    if (!field?.matches('.latex-page-label')) continue;
    // The empty inline box has no advance. Its lower edge is on the number's last baseline.
    const period = document.createElement('span');
    period.style.cssText = `display:inline-block;vertical-align:baseline;width:calc(${pitches} * var(--latex-leader-pitch));` +
        `margin-inline-start:calc(-${pitches} * var(--latex-leader-pitch));height:var(--latex-leader-diameter)`;
    field.append(period);
    periods.set(dots, period);
}
// Quartz copies the page marks from each capture but drops its annotations. Measure the
// original anchor fragments while all columns are still visible in strip coordinates.
const hyperref = document.body.hasAttribute('data-latex-hyperref');
const destinations = new Set();
// The reader's contents is navigable even in a manuscript without hyperref.
const selector = hyperref ? 'a[href^="#"]' : 'nav.toc a[href^="#"]';
for (const strip of strips) for (const a of strip.querySelectorAll(selector))
    destinations.add(a.getAttribute('href').slice(1));
const links = hyperref || destinations.size !== 0;
for (const [id, unique] of byStrip) {
    const entries = [...unique.values()];
    const origin = origins[id].y;
    entries.sort((a,b) => a.start-b.start);
    const at = y => {
        const pos = (y + scrollY)*unit - origin;
        let lo = 0, hi = entries.length-1;
        while (lo < hi) {
            const mid = (lo+hi) >>> 1;
            if (pos < entries[mid+1].start) hi = mid; else lo = mid+1;
        }
        return entries[lo].index;
    };
    if (links || globalThis.surimonoFormulaIndex) {
        const marks = [];
        const record = (rect, ownerY, data) => marks.push({...data, start:pieces[at(ownerY)].start,
            x:(rect.left+scrollX)*unit-origins[id].x, y:(rect.top+scrollY)*unit-origin,
            width:rect.width*unit, height:rect.height*unit});
        globalThis.surimonoFormulaIndex?.entries(strips[id], (_,r,href) => record(r,(r.top+r.bottom)/2,{href}));
        if (links) for (const el of strips[id].querySelectorAll('[id],a[href]')) {
            if (destinations.has(el.id)) {
                const float = el.hasAttribute('data-latex-float-anchor') && el.closest('figure');
                let r = (float || el).getBoundingClientRect(), ownerY = r.top+.01;
                if (float) {
                    // The output routine discards a top float's leading inset. caption.sty
                    // anchors half a baseline above the part actually placed in this column.
                    const sliceTop = (origin + pieces[at(ownerY)].start) / unit - scrollY;
                    r = new DOMRect(r.x, Math.max(r.top, sliceTop) - .5 * surimonoFlow.baseline / unit, 0, 0);
                } else if (el.matches('.latex-bibliography > li')) {
                    // The leading margin can be discarded at a column break. The first glyph
                    // is owned by the new column, even if the block edge was in the old one.
                    const text = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
                    for (let n = text.nextNode(); n; n = text.nextNode()) {
                        if (!n.data.trim()) continue;
                        range.selectNodeContents(n);
                        const first = [...range.getClientRects()].find(r => r.width && r.height);
                        if (first) { r = first; ownerY = (r.top+r.bottom)/2; break; }
                    }
                }
                record(r, ownerY, {id:el.id});
            }
            const href = el.getAttribute('href');
            if (el.localName !== 'a' || !href || !/^(?:#|https?:|mailto:)/i.test(href)) continue;
            if (!hyperref && !el.matches(selector)) continue;
            for (const r of el.getClientRects()) if (r.height && r.width)
                record(r, (r.top+r.bottom)/2, {href, pageTop:el.hasAttribute('data-latex-backref')});
        }
        origins[id].linkMarks = marks;
    }
    // Quartz fills these circles on the destination page. A fine-grid WebKit capture
    // quantizes tiny repeated backgrounds and can drop almost every dash of an SVG.
    for (const dots of strips[id].querySelectorAll('.latex-leader-dots')) {
        const period = periods.get(dots);
        if (!period) continue;
        const entry = dots.closest('.latex-page-entry');
        const measure = entry.closest('nav.toc').getBoundingClientRect().left;
        range.selectNodeContents(entry.firstElementChild);
        const title = [...range.getClientRects()].filter(rect => rect.width > 0).at(-1);
        if (!title) continue;
        const r = period.getBoundingClientRect(), end = period.parentElement.getBoundingClientRect().left;
        if (!(r.width > 0 && r.height > 0)) continue;
        // TeX aligns complete leader boxes to the enclosing line's left edge. Work in
        // one coordinate system, including the actual indent and reserved pnumwidth.
        const pitch = r.width / pitches;
        const first = Math.ceil((title.right - measure) / pitch);
        const count = Math.floor((end - measure) / pitch) - first;
        if (count > 4096) continue;
        dots.style.backgroundImage = 'none';
        if (count <= 0) continue;
        const midY = (r.top + r.bottom) / 2, owner = at(midY);
        if (!leaders.has(owner)) leaders.set(owner, []);
        leaders.get(owner).push({x:(measure + first*pitch + scrollX)*unit-origins[id].x, y:(midY+scrollY)*unit-origin,
            pitch:pitch*unit, diameter:r.height*unit, count, folio:folioGlyph(period.parentElement, origins[id])});
    }
    // Print a simple Japanese Gothic heading as one justified Core Text run. Capturing
    // individually positioned browser glyphs makes PDFKit infer spaces inside the word.
    // Rich text and explicit CJK font or colour selections retain their browser paint.
    for (const label of strips[id].querySelectorAll('h2 > [data-flow-distributed],h3 > [data-flow-distributed]')) {
        const text = label.textContent, css = getComputedStyle(label);
        if (label.children.length || !/^[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}ー]{2,4}$/u.test(text) ||
            css.getPropertyValue('--latex-cjk-sans-font').trim() || !css.fontFamily.includes('Surimono JS Gothic') ||
            css.fontStyle !== 'normal' || css.color !== 'rgb(0, 0, 0)' || css.visibility !== 'visible') continue;
        const baseline = document.createElement('i');
        baseline.style.cssText = 'display:inline-block;width:0;height:0;vertical-align:baseline;padding:0;margin:0;border:0';
        label.before(baseline);
        const r = label.getBoundingClientRect(), y = (baseline.getBoundingClientRect().bottom + scrollY)*unit-origin;
        baseline.remove();
        if (!(r.width > 0 && r.height > 0)) continue;
        (origins[id].distributedHeadings ??= []).push({text, x:(r.left+scrollX)*unit-origins[id].x, y, width:r.width*unit});
        label.style.setProperty('visibility','hidden','important');
    }
    if (entries.length === 1) continue;
    const tree = document.createTreeWalker(strips[id], NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, {
        acceptNode(n) {
            if (n.nodeType === Node.TEXT_NODE) return NodeFilter.FILTER_ACCEPT;
            if (n.matches('style,template,script')) return NodeFilter.FILTER_REJECT;
            const r = n.getBoundingClientRect();
            // A verified line is indivisible. The cut can sit inside its outer leading;
            // keep its link pieces, source space and generated hyphen with the same owner.
            // An SVG owns its complete drawing even when font bounds cross a cut.
            // An HTML span inserted inside SVG text has no glyphs in WebKit.
            if (r.height && n.matches('[data-flow-latin] > .latex-line,svg')) {
                memberships[at((r.top + r.bottom) / 2)].push(n);
                return NodeFilter.FILTER_REJECT;
            }
            const index = at(r.top + 0.01);
            if (r.width && r.height && index === at(r.bottom - 0.01)) {
                memberships[index].push(n);
                return NodeFilter.FILTER_REJECT;
            }
            // A custom style can still draw its marker with li::before. None of the text
            // nodes below a split item can hide it on the other captures.
            if (n.matches('ul > li') && !['none','normal'].includes(getComputedStyle(n,'::before').content)) {
                const text = document.createTreeWalker(n, NodeFilter.SHOW_TEXT);
                let first = null;
                for (let child = text.nextNode(); child && !first; child = text.nextNode()) {
                    if (!child.textContent.trim()) continue;
                    range.selectNodeContents(child);
                    first = [...range.getClientRects()].find(rect => rect.width && rect.height);
                }
                const y = first ? (first.top + first.bottom) / 2 : r.top + .01;
                markers[at(y)].push(n);
                n.setAttribute('data-flow-hidden-marker','');
            }
            return NodeFilter.FILTER_SKIP;
        }
    });
    for (let n = tree.nextNode(); n; n = tree.nextNode()) {
        range.selectNodeContents(n);
        const rect = range.getBoundingClientRect();
        if (!rect.width || !rect.height) continue;
        const fragment = document.createDocumentFragment();
        const indexAt = i => {
            range.setStart(n, i); range.setEnd(n, i+1);
            const r = range.getBoundingClientRect();
            if (r.height) return at((r.top+r.bottom)/2);
            range.setStart(n, 0);
            const prefix = range.getBoundingClientRect();
            return at(prefix.height ? prefix.bottom-0.01 : rect.top);
        };
        for (let start = 0; start < n.length;) {
            const index = indexAt(start);
            let lo = start+1, hi = n.length;
            while (lo < hi) {
                const mid = (lo+hi) >>> 1;
                if (indexAt(mid) === index) lo = mid+1; else hi = mid;
            }
            const span = document.createElement('span');
            span.textContent = n.data.slice(start,lo);
            memberships[index].push(span); fragment.append(span);
            start = lo;
        }
        edits.push([n, fragment]);
    }
}
for (const period of periods.values()) period.remove();
for (const [n,f] of edits) n.replaceWith(f);
// A complete paragraph or list item can be moved as one box without relaying out its text.
// More complicated paint (shared borders, protruding graphics, or clipped line fragments)
// keeps the individual capture. Clipping alone would leave its text in every PDF selection.
function plainParent(el) {
    if (!el.matches('ol,ul,div,p')) return false;
    const css = getComputedStyle(el);
    return css.backgroundColor === 'rgba(0, 0, 0, 0)' && css.backgroundImage === 'none' &&
        css.boxShadow === 'none' && css.outlineStyle === 'none' && css.filter === 'none' &&
        css.overflowX === 'visible' && css.overflowY === 'visible' && css.clipPath === 'none' &&
        css.transform === 'none' && css.maskImage === 'none' &&
        ['Top','Right','Bottom','Left'].every(side => !parseFloat(css['border' + side + 'Width'])) &&
        ['::before','::after'].every(p => ['none','normal'].includes(getComputedStyle(el,p).content));
}
const movable = pieces.map((piece,i) => {
    if (!document.body.hasAttribute('data-latex-style') || origins[piece.strip].hasOverhang ||
        leaders.has(owners[i]) || owners[i] !== i || !memberships[i].length) return;
    const box = strips[piece.strip], origin = origins[piece.strip].y;
    const roots = new Set();
    for (const el of memberships[i]) {
        // Move a split paragraph's block, not its inline spans: the original shaping and
        // link rectangles then travel together. Its other owners stay hidden as before.
        const block = el.matches('span,a') && el.parentElement.matches('p') ? el.parentElement : el;
        if (!block.matches('p,h1,h2,h3,h4,h5,h6,li') || block !== el && !plainParent(block)) return;
        for (let parent = block.parentElement; parent !== box; parent = parent.parentElement) {
            if (!parent || !plainParent(parent)) return;
        }
        if (el.matches('img,svg,math,canvas,table,figure,input') ||
            el.querySelector('img,svg,math,canvas,table,figure,input,[data-flow-ink-block]')) return;
        const css = getComputedStyle(block);
        if (!(css.position === 'static' || (css.position === 'relative' && !parseFloat(css.top) && !parseFloat(css.bottom))) ||
            css.boxShadow !== 'none' || css.textShadow !== 'none' || css.filter !== 'none') return;
        // Styles may scale a small-caps heading horizontally. A vertical transform or
        // positioned descendant can put ink beyond the band measured for a text block.
        if (css.transform !== 'none') {
            const matrix = new DOMMatrixReadOnly(css.transform);
            if (!matrix.is2D || matrix.b !== 0 || matrix.c !== 0 || matrix.d !== 1 || matrix.f !== 0) return;
        }
        for (const child of [el,...el.querySelectorAll('*')]) {
            const ink = getComputedStyle(child);
            if (['absolute','fixed','sticky'].includes(ink.position) || ink.boxShadow !== 'none' ||
                ink.textShadow !== 'none' || ink.filter !== 'none' || ink.outlineStyle !== 'none' ||
                ['::before','::after'].some(p => !['none','normal'].includes(getComputedStyle(child,p).content))) return;
        }
        range.selectNodeContents(el);
        const ink = range.getBoundingClientRect(), border = el.getBoundingClientRect();
        const top = (Math.min(ink.top,border.top) + scrollY) * unit - origin;
        const end = (Math.max(ink.bottom,border.bottom) + scrollY) * unit - origin;
        if (top < piece.start - .02 || end > piece.end + .02) return;
        roots.add(block);
    }
    return roots;
});
for (const group of memberships) for (const el of group) el.classList.add('surimono-flow-hidden');
for (const box of strips) box.classList.add('surimono-flow-hidden');
let visible = [], hiddenSiblings = [], positioned = [];
surimonoFlow.show = (index, offsets = []) => {
    for (const [el,original] of positioned) {
        if (original == null) el.removeAttribute('style'); else el.setAttribute('style',original);
    }
    for (const el of hiddenSiblings) el.classList.remove('surimono-flow-hidden');
    for (const old of visible) {
        for (const li of markers[old]) li.setAttribute('data-flow-hidden-marker','');
        strips[pieces[old].strip].classList.add('surimono-flow-hidden');
        for (const el of memberships[old]) el.classList.add('surimono-flow-hidden');
    }
    visible = []; hiddenSiblings = []; positioned = [];
    const i = owners[index], box = strips[pieces[i].strip];
    let count = 1;
    const shifts = new Map();
    if (movable[index] && offsets.length > 1) {
        for (const el of movable[index]) shifts.set(el,0);
        for (; count < offsets.length; count++) {
            const roots = movable[index + count], dy = offsets[count];
            if (!roots || [...roots].some(el => shifts.has(el) && shifts.get(el) !== dy)) break;
            for (const el of roots) shifts.set(el,dy);
        }
    }
    box.classList.remove('surimono-flow-hidden');
    for (let j=0;j<count;j++) {
        const owner = owners[index+j];
        visible.push(owner);
        for (const li of markers[owner]) li.removeAttribute('data-flow-hidden-marker');
        for (const el of memberships[owner]) el.classList.remove('surimono-flow-hidden');
    }
    if (count === 1) return leaders.has(i) ? JSON.stringify(leaders.get(i)) : null;
    const zoom = Number(box.dataset.flowWidth) / parseFloat(box.style.width);
    const active = new Set(), wrappers = new Set([box]);
    for (let j=0;j<count;j++) for (const el of memberships[index+j]) {
        active.add(el);
        for (let parent=el.parentElement; parent!==box; parent=parent.parentElement) {
            active.add(parent); wrappers.add(parent);
        }
    }
    for (const [el,dy] of shifts) {
        if (dy === 0) continue;
        positioned.push([el,el.getAttribute('style')]);
        el.style.setProperty('position','relative','important');
        el.style.setProperty('top',dy / zoom + 'px','important');
    }
    // A spanning element can retain its own ink even when its text descendants are hidden.
    // Keep only the selected blocks and their unpainted ancestors in the capture.
    for (const parent of wrappers) for (const el of parent.children) {
        if (!active.has(el) && !el.classList.contains('surimono-flow-hidden')) {
            el.classList.add('surimono-flow-hidden'); hiddenSiblings.push(el);
        }
    }
    return count;
};
return JSON.stringify(origins);
