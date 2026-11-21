// Serialize the same page plan as the PDF. A Range cut keeps a split paragraph searchable once,
// including when a link or emphasis crosses the bottom of the column.
const {strips, origins, unit} = surimonoFlow;
const zoom = parseFloat(getComputedStyle(document.documentElement).zoom) || 1;
const px = n => n / zoom + 'px';
const range = document.createRange();
const cuts = strips.map(() => new Map());
const cursors = new WeakMap();
function boundary(box, strip, y) {
    if (cuts[strip].has(y)) return cuts[strip].get(y);
    const target = (y + origins[strip].y) / unit - scrollY;
    function first(parent) {
        // Most cuts advance through the same strip. Resume at its last intersecting child.
        const previous = cursors.get(parent);
        const start = previous && previous.target <= target ? previous.index : 0;
        for (let i = start; i < parent.childNodes.length; i++) {
            const node = parent.childNodes[i];
            if (node.nodeType !== 1 && node.nodeType !== 3) continue;
            if (node.nodeType === 1 && node.matches('style,script,template')) continue;
            range.selectNode(node);
            const rect = range.getBoundingClientRect();
            if (!rect.height || rect.bottom <= target + .01) continue;
            cursors.set(parent,{index:i,target});
            if (rect.top >= target - .01) return [parent,i];
            if (node.nodeType === 1) {
                const inner = first(node);
                if (inner) return inner;
            } else {
                // A cut may sit inside the outer leading. Assign the whole visual line by its centre.
                let lo = 0, hi = node.length;
                while (lo < hi) {
                    const mid = (lo + hi) >>> 1;
                    range.setStart(node,mid); range.setEnd(node,mid + 1);
                    const r = range.getBoundingClientRect();
                    if ((r.top + r.bottom) / 2 < target) lo = mid + 1; else hi = mid;
                }
                if (lo < node.length) return [node,lo];
            }
        }
        return null;
    }
    const result = first(box) || [box,box.childNodes.length];
    cuts[strip].set(y,result);
    return result;
}
const sheets = document.createDocumentFragment();
for (const [index,page] of pages.entries()) {
    const offset = (index % 2 === 1) !== rightBound ? versoShift : 0;
    const sheet = document.createElement('div');
    sheet.className = 'latex-export-page';
    sheet.style.cssText = 'position:relative;overflow:hidden;break-after:page;margin:0 auto';
    sheet.style.width = px(paperWidth); sheet.style.height = px(paperHeight);
    sheets.append(sheet);
    function place(tag, x, y) {
        const el = document.createElement(tag);
        el.style.cssText = 'position:absolute;margin:0;padding:0';
        el.style.left = px(left + offset + x); el.style.top = px(topMargin + y);
        sheet.append(el); return el;
    }
    for (const {slice:s, x,y,scale} of page.pieces) {
        const box = strips[s.strip];
        const a = s.start <= .01 ? [box,0] : boundary(box,s.strip,s.start);
        const b = s.end >= origins[s.strip].height - .01 ? [box,box.childNodes.length] : boundary(box,s.strip,s.end);
        range.setStart(...a); range.setEnd(...b);
        if (range.collapsed) continue;
        let children = range.cloneContents();
        let ancestor = range.commonAncestorContainer;
        if (ancestor.nodeType === 3) ancestor = ancestor.parentNode;
        while (ancestor && ancestor !== box) {
            const parent = ancestor.cloneNode(false);
            parent.append(children); children = parent; ancestor = ancestor.parentNode;
        }
        const group = place('div',x,y);
        group.style.cssText += ';display:flow-root;transform-origin:top left';
        group.style.width = px(s.width); group.style.transform = 'scale(' + scale + ')';
        group.append(children);
        if (group.firstElementChild) group.firstElementChild.style.marginBlockStart = '0';
        if (a[0].nodeType === 3 && a[1] > 0) {
            const paragraph = group.querySelector('p');
            if (paragraph) paragraph.style.textIndent = '0';
        }
    }
    for (const [x,y,w,h] of page.rules) {
        const rule = place('div',x,y);
        rule.style.width = px(w); rule.style.height = px(h); rule.style.background = 'currentColor';
        rule.setAttribute('aria-hidden','true');
    }
    for (const [i,baseline] of page.lines.entries()) {
        // Generated content keeps the margin label outside text selection and the body reading order.
        const label = place('span', -2.5 * mm, baseline);
        label.setAttribute('aria-hidden','true'); label.dataset.no = String(i+1);
        label.className = 'latex-export-line';
    }
}
const extra = Array.from(document.body.querySelectorAll('style'), s => s.cloneNode(true));
surimonoRestoreFlow();
document.body.replaceChildren(...extra,sheets);
const style = document.createElement('style');
style.textContent = 'body.format-latex[data-latex-size]{margin:0;max-width:none}' +
    '.latex-export-line{font:7pt/1 Helvetica,sans-serif;transform:translate(-100%,-.78em);user-select:none}' +
    '.latex-export-line::after{content:attr(data-no)}.latex-export-page:last-child{break-after:auto}' +
    '@page{size:' + pageWidthPT + 'pt ' + pageHeightPT + 'pt;margin:0}' +
    '@media print{html{zoom:' + (96/72/ratio*zoom) + '!important;padding:0!important}body{margin:0!important}}';
document.head.append(style);
return true;
