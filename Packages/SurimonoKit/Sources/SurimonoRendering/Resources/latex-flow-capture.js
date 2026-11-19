// A clip alone retains invisible glyphs in WebKit's PDF text stream. Index complete subtrees,
// splitting text only where a chosen cut crosses its node, before changing visibility.
const {strips, origins, unit} = surimonoFlow;
// A padded slice must not cover the ink of its neighbour with the page's own white.
// The logical paper (including any separately composed theme background) sits under all slices.
const canvas = document.createElement('style');
canvas.textContent = 'html,body{background:transparent!important}';
document.body.append(canvas);
const memberships = pieces.map(() => []);
const byStrip = new Map();
for (const [i, p] of pieces.entries()) {
    if (!byStrip.has(p.strip)) byStrip.set(p.strip, []);
    byStrip.get(p.strip).push({...p, index:i});
}
const range = document.createRange(), edits = [];
for (const [id, entries] of byStrip) {
    if (entries.length === 1) continue;
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
for (const [n,f] of edits) n.replaceWith(f);
for (const group of memberships) for (const el of group) el.classList.add('surimono-flow-hidden');
for (const box of strips) box.classList.add('surimono-flow-hidden');
let previous;
surimonoFlow.show = i => {
    if (previous != null) {
        strips[pieces[previous].strip].classList.add('surimono-flow-hidden');
        for (const el of memberships[previous]) el.classList.add('surimono-flow-hidden');
    }
    strips[pieces[i].strip].classList.remove('surimono-flow-hidden');
    for (const el of memberships[i]) el.classList.remove('surimono-flow-hidden');
    previous = i;
};
return JSON.stringify(origins);
