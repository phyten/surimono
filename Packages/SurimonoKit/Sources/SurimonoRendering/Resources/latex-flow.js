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
const atomic = '[data-flow-ink-block],figure:not(.latex-longtable):not(.latex-listing),table:not(.latex-longtable),tr,.math-block,.tikz-block,.latex-graphic-box,img,svg,canvas,hr,input,.latex-vspace,.latex-rule,.latex-title-block';
const heading = 'h1,h2,h3,h4,h5,h6';
const boundary = '[data-latex-chapter-opening],[data-flow-ink-block],[data-latex-columns],[data-latex-spacing],[data-latex-wide],[data-latex-break],[data-latex-float],.latex-title-block,.latex-titlepage';
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
const floatSep = length('floatsep', 15), inTextSep = length('intextsep', 15);
const defaultGap = length('columnsep', 12.4533);
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
        // Paint from a raised or positioned child belongs to this box, even beyond its layout
        // height. A separate strip preserves that ink without capturing a neighbouring paragraph.
        if (node.hasAttribute('data-flow-ink-block') && !node.querySelector('[data-latex-break],[data-latex-columns],[data-latex-float]')) {
            run = null;
            append(node, parents);
            run = null;
            return;
        }
        if (node.matches(excluded)) return;
        if (node.querySelector(boundary)) {
            for (const child of [...node.childNodes]) command(child, [...parents, node]);
            return;
        }
    }
    append(node, parents);
}
function append(node, parents) {
    if (!run) {
        const box = strip(measureWidth());
        if (segment.items.at(-1)?.forced) box.dataset.flowPageStart = '';
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
if (seenNotes.size !== noteBodies.size) throw Error('Unpaired LaTeX footnote');
await Promise.all([document.fonts.ready, ...[...body.querySelectorAll('img')].map(img => img.decode().catch(() => {}))]);
// Fixed-size graphics and tables can be wider than the newly established column measure.
const fits = [];
for (const el of body.querySelectorAll('img,svg,table,.latex-graphic-box')) {
    if (el.parentElement.closest('svg,.latex-graphic-box')) continue;
    const strip = el.closest('[data-flow-strip]');
    if (!strip) continue;
    const available = strip.getBoundingClientRect().width;
    const natural = el.getBoundingClientRect().width;
    if (natural > available + 0.5) fits.push([el, available / natural * (parseFloat(getComputedStyle(el).zoom) || 1)]);
}
for (const [el, scale] of fits) el.style.zoom = scale;
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
    return {x:(r.left + scrollX)*unit, y:(r.top + scrollY)*unit, width:r.width*unit, height:r.height*unit,
        hasOverhang:!!box.querySelector('[data-flow-ink-block]')};
});
function slice(box, start, end) {
    const strip = +box.dataset.flowStrip;
    return {strip, start, end, width:origins[strip].width};
}
function whole(box) { return slice(box, 0, origins[+box.dataset.flowStrip].height); }
for (const [id, box] of pendingMeasurements) notes[id] = whole(box);
const range = document.createRange();
function lines(box) {
    const bands = [], paragraphs = new Map();
    const origin = origins[+box.dataset.flowStrip].y;
    function add(rect, el, ids = []) {
        if (!rect.width || !rect.height) return;
        budget();
        const para = el.closest('p,li,pre');
        if (para && !paragraphs.has(para)) paragraphs.set(para, paragraphs.size + 1);
        bands.push({start:Math.max(0,(rect.top + scrollY)*unit-origin),
            end:(rect.bottom + scrollY)*unit-origin, para:paragraphs.get(para) || 0,
            element:el, discard:el.matches('.latex-vspace:not([data-latex-keep-space])'), heading:!!el.closest(heading), ids});
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
            last.end = Math.max(last.end,b.end); last.heading ||= b.heading; last.discard &&= b.discard;
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
    rows.at(-1).end = Math.max(rows.at(-1).end, whole(box).end);
    return rows.map((r,i) => ({slice:slice(box,r.start,r.end), notes:[...r.ids], wide:false,
        gap:i ? Math.max(0,r.start-rows[i-1].end) : r.start, discardable:r.discard, paragraph:r.para, heading:r.heading}));
}
for (const seg of segments) {
    seg.items = seg.items.flatMap(item => {
        if (item.run) return lines(item.run);
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
return JSON.stringify({segments,notes,noteSkip,textFloatSep,floatSep,inTextSep,probes});
