// A clip alone retains invisible glyphs in WebKit's PDF text stream. Index complete subtrees,
// splitting text only where a chosen cut crosses its node, before changing visibility.
const {strips, origins, unit} = surimonoFlow;
// A padded slice must not cover the ink of its neighbour with the page's own white.
// The logical paper (including any separately composed theme background) sits under all slices.
const canvas = document.createElement('style');
canvas.textContent = 'html,body{background:transparent!important}';
document.body.append(canvas);
const memberships = pieces.map(() => []);
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
const periods = new Map();
for (const dots of document.querySelectorAll('nav.toc .latex-page-entry > .latex-page-leader > .latex-leader-dots')) {
    const field = dots.closest('.latex-page-entry')?.lastElementChild;
    if (!field?.matches('.latex-page-label')) continue;
    // The empty inline box has no advance. Its lower edge is on the number's last baseline.
    const period = document.createElement('span');
    period.style.cssText = 'display:inline-block;vertical-align:baseline;width:var(--latex-leader-pitch);' +
        'margin-inline-start:calc(-1 * var(--latex-leader-pitch));height:var(--latex-leader-diameter)';
    field.append(period);
    periods.set(dots, period);
}
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
        const first = Math.ceil((title.right - measure) / r.width);
        const count = Math.floor((end - measure) / r.width) - first;
        if (count > 4096) continue;
        dots.style.backgroundImage = 'none';
        if (count <= 0) continue;
        const midY = (r.top + r.bottom) / 2, owner = at(midY);
        if (!leaders.has(owner)) leaders.set(owner, []);
        leaders.get(owner).push({x:(measure + first*r.width + scrollX)*unit-origins[id].x, y:(midY+scrollY)*unit-origin,
            width:count*r.width*unit, diameter:r.height*unit, count});
    }
    if (entries.length === 1) continue;
    const tree = document.createTreeWalker(strips[id], NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, {
        acceptNode(n) {
            if (n.nodeType === Node.TEXT_NODE) return NodeFilter.FILTER_ACCEPT;
            if (n.matches('style,template,script')) return NodeFilter.FILTER_REJECT;
            const r = n.getBoundingClientRect();
            const index = at(r.top + 0.01);
            if (r.width && r.height && index === at(r.bottom - 0.01)) {
                memberships[index].push(n);
                return NodeFilter.FILTER_REJECT;
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
for (const group of memberships) for (const el of group) el.classList.add('surimono-flow-hidden');
for (const box of strips) box.classList.add('surimono-flow-hidden');
let previous;
surimonoFlow.show = index => {
    const i = owners[index];
    if (previous != null) {
        strips[pieces[previous].strip].classList.add('surimono-flow-hidden');
        for (const el of memberships[previous]) el.classList.add('surimono-flow-hidden');
    }
    strips[pieces[i].strip].classList.remove('surimono-flow-hidden');
    for (const el of memberships[i]) el.classList.remove('surimono-flow-hidden');
    previous = i;
    return leaders.has(i) ? JSON.stringify(leaders.get(i)) : null;
};
return JSON.stringify(origins);
