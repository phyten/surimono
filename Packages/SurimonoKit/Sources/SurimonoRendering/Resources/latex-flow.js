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
const columnNotice = body.querySelector('template[data-latex-column-notice]');
const proofLines = body.dataset.latexReview === 'proofPageLines';
const conferencePage = body.hasAttribute('data-latex-style');
const publicationGrid = body.hasAttribute('data-latex-publication-grid');
const measuredGrid = conferencePage || publicationGrid;
const flushBottom = measuredGrid && !body.hasAttribute('data-latex-ragged-bottom');
// Sibling relationships are lost when adjacent floats move into separate capture strips.
for (const node of body.querySelectorAll('figure[data-latex-float] + figure[data-latex-float]')) {
    node.dataset.flowAfterFloat = '';
}
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
const boundary = '[data-latex-fil],[data-latex-paged-table],[data-latex-chapter-opening],[data-flow-ink-block],[data-latex-columns],[data-latex-spacing],[data-latex-wide],[data-latex-break],[data-latex-float],.latex-title-block,.latex-titlepage';
body.style.cssText += ';margin:0!important;padding:0!important;max-width:none!important;width:auto!important';
const style = document.createElement('style');
style.textContent = `
[data-flow-strip]{display:flow-root!important;position:relative!important;margin:0!important;padding:0!important;border:0!important}
[data-flow-strip] > figure[data-latex-float]{margin-block:0!important}
[data-flow-strip] > section.footnotes{margin:0!important}
[data-flow-strip] > section.footnotes::before{display:none!important}
[data-flow-sentence-end]{word-spacing:calc(var(--flow-space-adjust,0px) + .06em)}
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
if (fineGrid || measuredGrid) {
    let precision = 32;
    const css = getComputedStyle(body);
    if (css.getPropertyValue('--latex-integral-line-pitch').trim() === '1') {
        // WebKit floors fractional line heights even on the enlarged canvas. Put the
        // body pitch one layout unit above a whole pixel so rounding cannot shorten it.
        const pitch = parseFloat(css.lineHeight) * zoom;
        if (pitch > 0) precision = (Math.ceil(precision * pitch) + 1 / 64) / pitch;
    }
    body.style.setProperty('zoom', String(precision), 'important');
    body.style.setProperty('transform', 'scale(' + 1 / precision + ')', 'important');
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
const requestedNoteRuleWidth = getComputedStyle(body).getPropertyValue('--latex-footnote-rule-width').trim() ?
    length('footnote-rule-width', 0) : undefined;
const noteRuleThickness = publicationGrid ? length('footnote-rule-thickness', .5) : undefined;
const ruleToFirstBaseline = publicationGrid ? length('footnote-rule-to-baseline', 0) : 0;
const noteStrutDepth = measuredGrid ? .3 * length('note-pitch', 0) : undefined;
const displayToTableSkip = length('display-to-table-skip', 0);
const bigSkipShrink = length('bigskip-shrink', 0);
const floatSep = length('floatsep', 15), inTextSep = length('intextsep', 15);
const sectionTop = length('heading-topskip', 0);
const publicationZW = publicationGrid ? length('zw', 0) / zoom : 0;
const bibliographyZW = publicationZW ? length('bib-zw', 0) / zoom : 0;
const zw = fineGrid ? length('zw', 0) / zoom : 0;
const jsPoint = fineGrid ? length('js-point', 0) : 0;
const displayShrink = fineGrid ? length('display-shrink', 0) : 0;
const defaultGap = length('columnsep', 12.4533);
const publicationTopSkip = publicationGrid ? length('topskip', 0) : 0;
probe.style.setProperty('width', 'var(--tex-pt)', 'important');
const texPoint = probe.getBoundingClientRect().width * unit;
probe.style.setProperty('width', 'var(--tex-baseline)', 'important');
const baseline = probe.getBoundingClientRect().width * unit;
const normalPitch = fineGrid ? baseline / zoom : 0;
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
    if (node.nodeType === 1 && node.hasAttribute('data-latex-chapter-opening')) {
        force(body.dataset.latexBookOpening || 'page');
    } else if (forced?.before) force('page');
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
        if (node.hasAttribute('data-latex-fil')) {
            run = null;
            const glueBox = strip(measureWidth());
            glueBox.append(node);
            segment.items.push({glueBox, fil:Number(node.dataset.latexFil), filOrder:Number(node.dataset.latexFilOrder || 1),
                discardable:!node.hasAttribute('data-latex-keep-space'), notes:[], wide:false, gap:0});
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
        if (node.hasAttribute('data-latex-wide') || (segment.columns > 1 && node.matches('.latex-title-block:not([data-latex-in-column]),.latex-titlepage'))) {
            const previous = segment;
            begin(defaults);
            // A spanning title contributes its insertions to the first text column.
            if (previous.columns === 2 && !previous.pageNotes && node.querySelector('.footnote-ref a') &&
                (node.matches('.latex-title-block') || node.querySelector('.latex-title-block'))) {
                segment.titleNoteWidth = (width - previous.gap) / 2;
            }
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
// LaTeX lets an image taller than the text block run past its foot, which paper would cut off. Shrink only the
// image, keeping its aspect ratio, by what its figure exceeds the body as measured at its column width, so the
// caption keeps its size and every line, and the figure stays centred.
for (const figure of body.querySelectorAll('[data-flow-strip] figure[data-latex-float]')) {
    const images = figure.querySelectorAll('img.latex-graphic');
    if (images.length !== 1) continue;
    const excess = figure.getBoundingClientRect().height * unit - bodyHeight;
    const height = images[0].getBoundingClientRect().height * unit;
    if (excess > 0 && height > excess) {
        images[0].style.setProperty('max-height', (height - excess) / zoom + 'px', 'important');
    }
}
const hasColumnTitleNotes = segments.some(seg => seg.titleNoteWidth);
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
            const box = strip(seg.titleNoteWidth ?? (seg.pageNotes || item.wide ? width : (width - (seg.columns - 1) * seg.gap) / seg.columns));
            const section = document.createElement('section'), ol = document.createElement('ol');
            section.className = 'footnotes';
            section.append(ol); ol.append(li); box.append(section);
            pendingMeasurements.push([id, box]);
        }
    }
}
const noticeText = original.querySelector('template[data-latex-first-notice]')?.dataset.latexFirstNotice;
let columnNoticeBox;
const firstColumns = segments.find(s => s.columns === 2 && s.items.length);
if (columnNotice && (firstColumns || publicationGrid)) {
    columnNoticeBox = strip(firstColumns ? (width - firstColumns.gap) / 2 : width);
    const notice = document.createElement('div');
    notice.className = 'latex-first-notice latex-column-notice';
    notice.append(columnNotice.content.cloneNode(true));
    columnNoticeBox.append(notice);
}
let noticeBox;
if (noticeText) {
    noticeBox = strip(width);
    const notice = document.createElement('div');
    notice.className = 'latex-first-notice';
    notice.textContent = noticeText;
    noticeBox.append(notice);
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
if (body.dataset.latexLineBreaking && globalThis.surimonoComposeLatin) {
    globalThis.surimonoLatinLast = surimonoComposeLatin(body, unit / zoom);
}
// The Times TFM gives a sentence-ending space an extra .06em (fontdimen7).
// Wrap a complete final word WITH its existing space. No new character or
// word-internal boundary is introduced, so selection retains the source text.
if (conferencePage && !body.hasAttribute('data-latex-french-spacing')) {
    for (const p of body.querySelectorAll('p,li:not(:has(p))')) {
        if (p.hasAttribute('data-flow-latin') || p.closest('header,figure,table,.footnotes,.latex-column-notice,.latex-bibliography') ||
            getComputedStyle(p).textAlign !== 'justify') continue;
        const walker = document.createTreeWalker(p, NodeFilter.SHOW_TEXT);
        const edits = [];
        for (let n = walker.nextNode(); n; n = walker.nextNode()) {
            if (n.parentElement.closest('[data-flow-latin],code,kbd,pre,a,.math,svg') ||
                n.parentElement.closest('p,li') !== p) continue;
            const matches = [...n.data.matchAll(/(?:^|(?<=\s))[A-Za-z][A-Za-z’-]*[a-z]\.["'”’)]*[ \n\t]+(?=[A-Z])/g)];
            if (!matches.length) continue;
            const fragment = document.createDocumentFragment();
            let start = 0;
            for (const m of matches) {
                budget();
                fragment.append(n.data.slice(start,m.index));
                const word = document.createElement('span');
                word.dataset.flowSentenceEnd = '';
                word.textContent = m[0];
                fragment.append(word);
                start = m.index + m[0].length;
            }
            fragment.append(n.data.slice(start));
            edits.push([n, fragment]);
        }
        for (const [n, fragment] of edits) n.replaceWith(fragment);
    }
}
// TeX puts the title rules and the following column tops against the actual
// type. The fixed font descent would give bylines with and without descenders
// the same height. Keep the ordinary line boxes for wrapping/complex titles.
if (getComputedStyle(body).getPropertyValue('--latex-measure-title-ink').trim()) {
    const ctx = document.createElement('canvas').getContext('2d');
    for (const el of body.querySelectorAll('.latex-title-block h1,.latex-front-author')) {
        const name = el.matches('h1') ? el : el.querySelector(':scope > strong');
        if (!ctx || !name || name.childElementCount || !name.textContent.trim()) continue;
        const text = document.createRange();
        text.selectNodeContents(name);
        if (text.getClientRects().length !== 1) continue;
        const css = getComputedStyle(name);
        ctx.font = css.fontWeight + ' ' + (32 * parseFloat(css.fontSize)) + 'px ' + css.fontFamily;
        const ink = ctx.measureText(name.textContent);
        el.style.setProperty('--flow-ink-ascent', ink.actualBoundingBoxAscent / 32 + 'px');
        el.style.setProperty('--flow-ink-depth', Math.max(0, ink.actualBoundingBoxDescent / 32) + 'px');
        const mark = el.querySelector(':scope > sup');
        if (mark) {
            const raised = getComputedStyle(mark);
            ctx.font = raised.fontWeight + ' ' + (32 * parseFloat(raised.fontSize)) + 'px ' + raised.fontFamily;
            const ascent = ctx.measureText(mark.textContent).actualBoundingBoxAscent / 32 + parseFloat(raised.verticalAlign);
            if (Number.isFinite(ascent)) el.style.setProperty('--flow-mark-ascent', ascent + 'px');
        }
        el.dataset.flowTitleInk = '';
    }
}
const range = document.createRange();
// Browser justification stretches spaces but does not try TeX's finite interword
// shrink before wrapping. Try to save a line, or avoid hyphens at the same line count.
if (measuredGrid && getComputedStyle(body).getPropertyValue('--latex-word-shrink').trim()) {
    // The run-in heading shares the measure with its inline paragraph. Trial
    // its containing block so wrapped lines and the heading stay together.
    const preferWholeWords = !!getComputedStyle(body).getPropertyValue('--latex-prefer-whole-words').trim();
    const listText = 'li:not(:has(ul,ol,p)),li > p';
    const candidates = firstColumns ? 'p,.latex-runin,.latex-bibliography > li' : 'p';
    const paragraphs = [...body.querySelectorAll(candidates + (preferWholeWords ? ',' + listText : ''))].filter(p =>
        (!p.closest('header,figure,table,li,.footnotes,.latex-runin') ||
            preferWholeWords && p.matches(listText) && !p.closest('header,figure,table') ||
            firstColumns && (p.matches('.latex-runin,.latex-bibliography > li') || p.closest('section.footnotes'))) &&
        !p.matches('.abstract-title,[data-flow-latin]') && !p.querySelector('[data-flow-latin]') &&
        ['normal','0px'].includes(getComputedStyle(p).wordSpacing) && getComputedStyle(p).textAlign === 'justify');
    // Bound optional dictionary-break measurements across all trials. Large papers
    // still receive the ordinary height-based shrink pass after this allowance.
    let wordScanRemaining = 128 * 1024;
    function brokenWords(p) {
        if (!wordScanRemaining) return null;
        const walk = document.createTreeWalker(p,NodeFilter.SHOW_TEXT);
        let count = 0;
        for (let n=walk.nextNode(); n; n=walk.nextNode()) {
            if (n.length > wordScanRemaining) {
                wordScanRemaining = 0;
                return null;
            }
            wordScanRemaining -= n.length;
            if (n.parentElement.closest('svg,code,style')) continue;
            range.selectNodeContents(n);
            if (range.getClientRects().length > 1) count += hyphenatedLines(n,0,n.length).size;
        }
        return count;
    }
    function adjust(p, fraction) {
        if (fraction) {
            p.style.setProperty('--flow-space-adjust', 'calc(-' + fraction + ' * var(--latex-word-shrink))');
            p.style.wordSpacing = 'var(--flow-space-adjust)';
        } else {
            p.style.removeProperty('word-spacing');
            p.style.removeProperty('--flow-space-adjust');
        }
    }
    let pending = paragraphs.map(p => ({p, height:p.getBoundingClientRect().height, fraction:0,
        broken:preferWholeWords ? brokenWords(p) : 0, halfLine:parseFloat(getComputedStyle(p).lineHeight) * zoom / unit / 2}));
    for (const fraction of [.25,.5,.75,1]) {
        for (const {p} of pending) adjust(p,fraction);
        pending = pending.filter(trial => {
            const height = trial.p.getBoundingClientRect().height;
            const shorter = height <= trial.height - trial.halfLine;
            if (!preferWholeWords) return !shorter;
            // At equal line count, TeX penalizes a discretionary hyphen. Preserve
            // the smallest admissible shrink that keeps more source words whole.
            if (!shorter && (!trial.broken || height >= trial.height + trial.halfLine)) return true;
            const broken = brokenWords(trial.p);
            if (shorter || (broken !== null && broken < trial.broken)) {
                Object.assign(trial,{height,broken,fraction});
            }
            return !shorter || broken > 0;
        });
    }
    for (const {p,fraction} of pending) adjust(p,fraction);
}
globalThis.surimonoLatinLast?.refreshFallbacks?.();
// Preserve the math baseline through ink expansion: the original dimensions
// are in em, whereas the preparation pass stores the baseline in viewBox units.
function displayBaseline(svg) {
    const box = svg.viewBox.baseVal, first = Number(svg.dataset.latexTexFirst);
    const fraction = Number.isFinite(first) && box.height > 0 ? (first - box.y) / box.height :
        1 + parseFloat(svg.style.verticalAlign) / parseFloat(svg.getAttribute('height'));
    if (!Number.isFinite(fraction) || fraction < 0 || fraction > 1) return undefined;
    const rect = svg.getBoundingClientRect();
    return rect.top + rect.height * fraction;
}
if (measuredGrid) {
    const labels = [];
    for (const label of body.querySelectorAll('.latex-equation > .eqno')) {
        const svg = label.parentElement.querySelector(':scope > .math-display > svg:only-child');
        if (!svg || label.parentElement.querySelector('.latex-row-number')) continue;
        const mark = baselineProbe();
        label.prepend(mark);
        labels.push({label, svg, mark});
    }
    const shifts = labels.map(({svg, mark}) => {
        const y = displayBaseline(svg);
        return y === undefined ? 0 : (y - mark.getBoundingClientRect().top) * unit / zoom;
    });
    labels.forEach(({label, mark}, i) => {
        mark.remove();
        label.style.translate = '0 ' + shifts[i] + 'px';
    });
}
// A mixed Latin label and Japanese text can contribute different ascents and
// descents even to a trimmed list item. Use the two actual baselines rather
// than charging the fallback font's extra strut to the class's itemsep.
if (getComputedStyle(body).getPropertyValue('--latex-measure-enumerate-pitch').trim() === '1') {
    for (const list of body.querySelectorAll('ol.latex-enumerate:not(li ol)')) {
        const items = [...list.children].filter(li => li.matches('li:has(> .item-label)') &&
            !li.querySelector(':scope > :is(p,ul,ol,div,table,figure,pre,blockquote)'));
        if (!items.length) continue;
        const probes = items.map(li => {
            const head = baselineProbe(), tail = baselineProbe();
            li.querySelector(':scope > .item-label').after(head);
            li.append(tail);
            return {li,head,tail};
        });
        const metrics = probes.map(({li,head,tail}) => {
            const css = getComputedStyle(li);
            const cssY = el => el.getBoundingClientRect().top * unit / zoom;
            return {li, first:cssY(head), last:cssY(tail), top:cssY(li), pitch:parseFloat(css.lineHeight),
                margin:parseFloat(css.marginBlockStart), padding:parseFloat(css.paddingBlockStart),
                depth:.12 * parseFloat(css.fontSize) * parseFloat(css.getPropertyValue('--latex-jfm-scale'))};
        });
        for (const {head,tail} of probes) { head.remove(); tail.remove(); }
        for (const [i,m] of metrics.entries()) {
            if (i && items[i-1].nextElementSibling === m.li) {
                const delta = m.pitch + m.margin - (m.first - metrics[i-1].last);
                m.li.style.marginBlockStart = (m.margin + delta) + 'px';
            } else if (!i && list.matches('[data-flow-after-float] > ol:first-child') && Number.isFinite(m.depth)) {
                m.li.style.paddingBlockStart = Math.max(0, m.padding + m.pitch - m.depth - (m.first - m.top)) + 'px';
            }
        }
    }
}
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
// Reserve the unscaled list height in normal flow. Only its rows need the
// finer layout grid to keep a fractional baselineskip on every printed line.
const contentsZoom = Number(getComputedStyle(body).getPropertyValue('--latex-toc-layout-zoom'));
if (contentsZoom > 1) {
    const lists = [];
    for (const list of body.querySelectorAll('nav.toc > ul')) {
        if (!list.firstElementChild) continue;
        lists.push({list, width:list.getBoundingClientRect().width * unit / zoom,
            skip:getComputedStyle(list.firstElementChild).marginBlockStart});
    }
    for (const entry of lists) {
        const {list, width, skip} = entry;
        const frame = document.createElement('div');
        frame.style.cssText = 'position:relative;margin-block-start:' + skip;
        list.before(frame); frame.append(list);
        list.firstElementChild.style.marginBlockStart = '0';
        list.style.cssText += ';position:absolute;inset:0 auto auto 0;zoom:' + contentsZoom +
            ';width:' + width + 'px;transform:scale(' + (1 / contentsZoom) + ');transform-origin:top left';
        entry.frame = frame;
        // A following section measures its beforeskip from the last entry's
        // baseline. Its lower half-leading belongs to the CSS line, not to TeX.
        if (frame.parentElement.nextElementSibling?.matches('[data-latex-heading="section"]')) {
            const last = list.querySelectorAll(':scope a');
            const field = last[last.length - 1]?.querySelector('.latex-page-label');
            if (field) {
                const baseline = document.createElement('span');
                baseline.style.cssText = 'display:inline-block;width:0;height:0;vertical-align:baseline';
                field.append(baseline);
                entry.baseline = baseline;
            }
        }
    }
    const heights = lists.map(({list, baseline, width}) => {
        let rect = list.getBoundingClientRect();
        // On older WebKit the inverse transform shrinks client rects even though zoom
        // restores the painted width. All anchors and slices need the enclosing strip's
        // coordinates. Use ordinary layout only when the measured width lost that zoom.
        if (typeof checksNestedZoom !== 'undefined' && width > 1 && Math.abs(rect.width * unit / zoom * contentsZoom - width) < 1) {
            list.style.zoom = '1';
            list.style.transform = 'none';
            rect = list.getBoundingClientRect();
        }
        return (baseline ? baseline.getBoundingClientRect().bottom - rect.top : rect.height) * unit / zoom;
    });
    lists.forEach(({frame, baseline}, i) => {
        frame.style.height = heights[i] + 'px';
        baseline?.remove();
    });
}
// Set the five-cell box only after measuring the actual face and inline content.
// Keep the original text node intact so search and selection see the source title.
for (const label of body.querySelectorAll('.latex-heading-measure')) {
    const cell = document.createElement('span');
    cell.style.cssText = 'display:inline-block;width:var(--society-heading-cell,1ic);height:0';
    label.after(cell);
    if (cell.offsetWidth > 0 && label.getBoundingClientRect().width < 4.5 * cell.getBoundingClientRect().width) {
        label.dataset.flowDistributed = '';
    }
    cell.remove();
}
if (fineGrid) japaneseProseLines(body);
if (publicationZW) japaneseGridParagraphs(body, publicationZW, bibliographyZW, unit / zoom);
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
// A tall rule following an explicit line break cannot share the ordinary
// baseline grid. TeX inserts lineskip (1pt) above it; the preceding rule
// has zero depth. The browser otherwise retains a text strut below that rule.
if (conferencePage) {
    // Plain hline cells have no booktabs padding to redistribute. Raise their
    // contents as a unit, leaving the collapsed borders and column measures intact.
    for (const table of body.querySelectorAll('table.latex-tabular:not(.latex-longtable)')) {
        if (!table.querySelector(':scope > tbody > tr > [style*="border-top:"],:scope > tbody > tr > [style*="border-bottom:"]') ||
            table.querySelector('tr.latex-above-rule,tr.latex-below-rule')) continue;
        for (const row of table.rows) for (const cell of row.cells) {
            budget();
            if (!cell.childNodes.length || cell.querySelector('table,p,div,ul,ol,img,svg,.latex-rule,[data-latex-column]')) continue;
            const content = document.createElement('span');
            content.dataset.flowTableText = '';
            while (cell.firstChild) content.append(cell.firstChild);
            cell.append(content);
        }
    }
}
if (measuredGrid) {
    for (const p of body.querySelectorAll('figure > p')) {
        if (![...p.childNodes].every(n => n.nodeType === Node.TEXT_NODE ? !n.textContent.trim() :
            n.nodeType === Node.ELEMENT_NODE && n.matches('br,.latex-rule,.latex-vspace'))) continue;
        for (const space of p.querySelectorAll(':scope > br + .latex-vspace')) {
            const before = space.previousElementSibling.previousElementSibling;
            const after = space.nextElementSibling;
            if (!before?.matches('.latex-rule') || !after?.matches('.latex-rule')) continue;
            const lower = after.getBoundingClientRect(), upper = before.getBoundingClientRect();
            if (lower.height * unit <= baseline) continue;
            const specified = parseFloat(getComputedStyle(space).height);
            const gap = (lower.top - upper.bottom) * unit / zoom;
            const lineSkip = Number(getComputedStyle(p).getPropertyValue('--latex-rule-lineskip').trim() || 1);
            space.style.marginBottom = (specified + lineSkip * texPoint / zoom - gap) + 'px';
        }
        // caption.sty's strut follows the artwork itself. Discard the browser's
        // trailing half-leading only when the paragraph contains exclusively rules.
        const last = p.lastElementChild;
        if (last?.matches('.latex-rule') && p.nextElementSibling?.matches('figcaption') &&
            (publicationGrid || getComputedStyle(p).getPropertyValue('--conference-display-skip').trim())) {
            let height = (last.getBoundingClientRect().bottom - p.getBoundingClientRect().top) * unit / zoom;
            const cap = p.nextElementSibling, label = cap.querySelector('.latex-caption-label');
            if (publicationGrid && label && !cap.hasAttribute('data-latex-caption-style')) {
                // A top-aligned caption parbox takes one full baseline from the end
                // of the drawing. The browser puts only the line's ascent above it.
                const mark = baselineProbe();
                label.prepend(mark);
                const ascent = (mark.getBoundingClientRect().top - cap.getBoundingClientRect().top) * unit / zoom;
                mark.remove();
                height += Math.max(0, parseFloat(getComputedStyle(cap).lineHeight) - ascent);
            }
            p.style.height = Math.max(0, height) + 'px';
        }
    }
}
// A parbox followed by a vertical skip ends at its last line's ink depth.
function setNaturalLastDepth(box, kern = 0) {
    const depth = japaneseLineDepth(box, true);
    const walker = document.createTreeWalker(box, NodeFilter.SHOW_TEXT);
    const last = walker.lastChild();
    if (depth === null || !last?.data.trim()) return;
    const mark = baselineProbe();
    last.after(mark);
    const ascent = (mark.getBoundingClientRect().bottom - box.getBoundingClientRect().top) * unit / zoom;
    mark.remove();
    box.style.height = Math.max(0, ascent + depth + kern) + 'px';
}
if (publicationGrid) {
    // The printed title-to-body skip follows the English keyword minipage's natural depth.
    for (const keywords of body.querySelectorAll('.latex-title-block .latex-front-keywords[lang="en"]:last-child > p:last-child')) {
        setNaturalLastDepth(keywords);
    }
    for (const cap of body.querySelectorAll('figure[data-latex-float-size] > figcaption:not([data-latex-caption-style])')) {
        const label = cap.querySelector('.latex-caption-label');
        if (!label || cap.querySelector('br,svg,img,ruby')) continue;
        const css = getComputedStyle(cap), pitch = parseFloat(css.lineHeight);
        const height = cap.getBoundingClientRect().height * unit / zoom;
        const single = height < 1.5 * pitch;
        if (single) cap.dataset.flowSingleCaption = '';
        // A caption above a table starts as a natural-height hbox. Its text has
        // no half-leading before the first glyphs.
        if (single && cap.nextElementSibling?.matches('table')) {
            const baseline = baselineProbe();
            label.prepend(baseline);
            const ascent = (baseline.getBoundingClientRect().top - cap.getBoundingClientRect().top) * unit / zoom;
            baseline.remove();
            const jp = /[\u3040-\u30ff\u3400-\u9fff]/u.test(cap.textContent);
            const face = document.createElement('canvas').getContext('2d');
            if (!face) continue;
            face.font = css.fontStyle + ' ' + css.fontWeight + ' ' + 32 * parseFloat(css.fontSize) + 'px ' + css.fontFamily;
            const ink = face.measureText(cap.textContent);
            const top = jp ? .88 * face.measureText('紙').width / 32 : ink.actualBoundingBoxAscent / 32;
            cap.style.marginTop = (parseFloat(css.marginTop) + top - ascent) + 'px';
            if (css.getPropertyValue('--latex-natural-caption-depth').trim()) {
                const depth = japaneseLineDepth(cap);
                if (depth !== null) cap.style.height = (ascent + depth) + 'px';
            }
        }
        // End a bottom caption at the actual last baseline and glyph depth;
        // the separation to the next float is supplied by the page builder.
        if (!cap.nextElementSibling && !single) {
            const advance = parseFloat(css.getPropertyValue('--latex-caption-tail-adjust')) || 0;
            setNaturalLastDepth(cap, advance * texPoint / zoom);
        }
    }
}
// Ink guards can isolate neighbouring blocks in separate capture strips.
const previous = new WeakMap(), following = new WeakMap();
for (const segment of segments) for (let i = 1; i < segment.items.length; i++) {
    const left = segment.items[i-1].run?.lastElementChild, right = segment.items[i].run?.firstElementChild;
    if (left && right) { previous.set(right, left); following.set(left, right); }
}
// A shallow fleqn display occupies a text strut on the normal baseline.
// Keep tall formula ink intact and measure the strut outside the prose, since
// appending an inline marker after a composed Japanese line creates another line.
if (publicationGrid) {
    const sample = document.createElement('span'), mark = baselineProbe();
    sample.style.cssText = 'display:block;position:absolute;white-space:nowrap;inset:0 auto auto 0';
    sample.append(body.matches(':lang(ja)') ? '紙M' : 'M', mark);
    for (const block of body.querySelectorAll('.math-block')) {
        const svg = block.querySelector(':scope > .math-display > svg:only-child');
        if (!svg) continue;
        const y = displayBaseline(svg);
        if (y === undefined) continue;
        block.append(sample);
        const strut = sample.getBoundingClientRect(), baselineY = mark.getBoundingClientRect().top;
        const ink = svg.getBoundingClientRect();
        block.style.paddingTop = Math.max(0, (baselineY - strut.top - (y - ink.top)) * unit / zoom) + 'px';
        block.style.paddingBottom = Math.max(0, (strut.bottom - baselineY - (ink.bottom - y)) * unit / zoom) + 'px';
        sample.remove();
    }
}
// TeX chooses the short skips when the previous line plus two quads
// ends before the formula. Compare local coordinates across capture strips.
if (getComputedStyle(body).getPropertyValue('--conference-display-skip').trim()) {
    for (const block of body.querySelectorAll('.math-block')) {
        const before = block.previousElementSibling || previous.get(block);
        const svg = block.querySelector(':scope > .math-display > svg:only-child');
        if (!before?.matches('p') || !svg) continue;
        if (svg.parentElement.hasAttribute('data-latex-first-baseline')) continue;
        const mark = baselineProbe();
        paragraphEdge(before, true).append(mark);
        const beforeBaseline = mark.getBoundingClientRect();
        const lineEnd = beforeBaseline.right - before.getBoundingClientRect().left;
        const formulaStart = svg.getBoundingClientRect().left - block.getBoundingClientRect().left;
        mark.remove();
        if ((formulaStart - lineEnd) * unit >= 2 * parseFloat(getComputedStyle(before).fontSize) * zoom) {
            block.dataset.flowShortDisplay = '';
            // A zero short skip still leaves one baseline of interline distance.
            // The SVG's alphabetic baseline can sit above the surrounding HTML strut.
            const y = displayBaseline(svg);
            if (block.previousElementSibling === before && y !== undefined) {
                const pitch = parseFloat(getComputedStyle(before).lineHeight);
                const deficit = pitch - (y - beforeBaseline.top) * unit / zoom;
                if (deficit > 0) block.style.marginTop = deficit + 'px';
            }
        }
    }
}
// A shallow inline SVG can extend its line's descent a fraction past the body
// strut. Remove that excess from the following skip; tall displays keep their depth.
if (body.hasAttribute('data-latex-style')) {
    for (const math of body.querySelectorAll('.math-block:has(+ p) > .math-display:has(> svg:only-child)')) {
        const block = math.parentElement, p = block.nextElementSibling;
        const mark = baselineProbe(), next = baselineProbe();
        math.append(mark); paragraphEdge(p, false).prepend(next);
        const distance = (next.getBoundingClientRect().top - mark.getBoundingClientRect().top) * unit / zoom;
        mark.remove(); next.remove();
        const margin = parseFloat(getComputedStyle(block).marginBottom);
        const excess = distance - margin - parseFloat(getComputedStyle(p).lineHeight);
        if (excess > 0 && excess <= texPoint / zoom) block.style.marginBottom = Math.max(0,margin-excess) + 'px';
    }
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
        if (atEnd) paragraphEdge(p, true).append(mark); else paragraphEdge(p, false).prepend(mark);
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
// Each titlepage assigns a share of the stretchable glue above its centre list. Measure after wrapping:
// a long title, a second author line, or a title note reduces that shared space.
if (body.dataset.latexTitleLayout === 'separate') {
    for (const title of body.querySelectorAll('.latex-title-block:not(.latex-titlepage *)')) {
        const shares = parseFloat(getComputedStyle(title).getPropertyValue('--latex-title-fill-units')) || (fineGrid ? 3 : 0);
        if (!shares) continue;
        const line = parseFloat(getComputedStyle(body).lineHeight) * zoom;
        const noteHeight = [...title.querySelectorAll('[data-flow-note]')].reduce((sum, a) => {
            const box = pendingMeasurements.find(([id]) => id === a.dataset.flowNote)?.[1];
            return sum + (box?.getBoundingClientRect().height || 0) * unit;
        }, 0);
        const scale = parseFloat(getComputedStyle(body).getPropertyValue('--latex-js-scale')) || 1;
        const end = line + (title.querySelector('.latex-date') ? 0 : 15 * 1.24533 * zoom * scale);
        const spare = bodyHeight - title.getBoundingClientRect().height * unit - end - noteHeight - (noteHeight ? noteSkip : 0);
        title.style.setProperty('--latex-title-fill', Math.max(0,spare) / (shares * zoom) + 'px');
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
// A probe beside a block line would create a spurious extra line.
function paragraphEdge(p, end) {
    return p.hasAttribute('data-flow-latin') ? (end ? p.lastElementChild : p.firstElementChild) : p;
}
function baselineProbe() {
    const marker = document.createElement('i');
    marker.style.cssText = 'display:inline-block;width:0;height:0;vertical-align:baseline;padding:0;margin:0;border:0';
    return marker;
}
// A discretionary hyphen has a column-break penalty in TeX. The extra glyph
// does not belong to the source text, so detect a word crossing two line boxes.
function hyphenatedLines(node, start, end) {
    const result = new Set();
    for (const word of node.data.slice(start,end).matchAll(/[\p{Script=Latin}\u00ad]{5,}/gu)) {
        range.setStart(node,start+word.index);
        range.setEnd(node,start+word.index+word[0].length);
        const rects = range.getClientRects();
        for (let i = 1; i < rects.length; i++) {
            if (rects[i].top > rects[i-1].top + .1) result.add(rects[i-1].top);
        }
    }
    return result;
}
// Components are TeX points. Obtain the family-specific list and section definitions
// from the style sheet once; lines of the same paragraph have no adjustable glue.
const glueStyle = getComputedStyle(body);
function gluePair(name, plus, minus) {
    const values = glueStyle.getPropertyValue('--latex-glue-' + name).trim().split(/\s+/).map(Number);
    return values.length === 2 && values.every(Number.isFinite) ? values : [plus, minus];
}
const skip = {
    paragraph:gluePair('paragraph',0,0), heading:gluePair('heading',2.25,.9), runIn:gluePair('runin',2.25,.9),
    minorHeading:gluePair('minor-heading',0,0),
    sectionAfter:gluePair('section-after',1.35,.9), subsectionAfter:gluePair('subsection-after',.9,0),
    list:gluePair('list',1,2), item:gluePair('item',2,1), quote:gluePair('quote',1.5,2.5),
    bib:gluePair('bib',4,2), display:gluePair('display',2,5), shortAfter:gluePair('short-after',3,3)
};
// A displayed paragraph heading can have its own skip on both sides. Run-in
// headings share their following text line and retain their paragraph's glue.
const minorHeading = 'h5[data-latex-heading],h6[data-latex-heading]';
const glueBlocks = '.math-block,.latex-runin,h2,h3,h4,li,p' + (skip.minorHeading.some(Boolean) ? ',' + minorHeading : '');
function conferenceGlue(previous, current) {
    if (!previous || !measuredGrid || previous.para && previous.para === current.para) return [0,0];
    const a = previous.element.closest(glueBlocks), b = current.element.closest(glueBlocks);
    if (!a || !b || a === b) return [0,0];
    const sum = (x,y) => [x[0]+y[0],x[1]+y[1]];
    if (a.matches('.abstract-title') && b.closest('.abstract')) return skip.quote;
    if (a.closest('.abstract') && !b.closest('.abstract')) {
        return b.matches('h2,h3,h4') ? sum(skip.quote,skip.heading) : skip.quote;
    }
    if (b.hasAttribute('data-flow-short-display')) return [3,0];
    if (a.hasAttribute('data-flow-short-display')) return skip.shortAfter;
    if (a.matches('.math-block') || b.matches('.math-block')) return skip.display;
    const before = a.closest('li'), after = b.closest('li');
    if (before !== after) {
        const list = (after || before).parentElement;
        if (list.matches('.latex-bibliography')) return before && after ? skip.bib : skip.sectionAfter;
        if (before?.parentElement === after?.parentElement) return list.closest('li') ? [1,.5] : skip.item;
        // An outer list's topsep is in addition to the enclosing paragraph skip.
        // A zero-separation list still participates in its document's parskip stretch.
        return list.closest('li') ? [1,.5] : sum(skip.list,skip.paragraph);
    }
    if (a.matches('h2')) return sum(skip.sectionAfter,skip.paragraph);
    if (a.matches('h3,h4')) return sum(skip.subsectionAfter,skip.paragraph);
    if (a.matches(minorHeading)) return sum(skip.minorHeading,skip.paragraph);
    if (b.matches('h2,h3,h4')) return sum(skip.heading,skip.paragraph);
    if (b.matches(minorHeading)) return sum(skip.minorHeading,skip.paragraph);
    if (b.closest('.latex-runin')) return sum(skip.runIn,skip.paragraph);
    return skip.paragraph;
}
// A range rectangle includes the font descent, while TeX's column goal is the
// baseline of the last line. Measure the offset without touching the line itself.
const fontOffsets = new Map(), elementOffsets = new WeakMap();
const fontSample = document.createElement('span'), fontMark = baselineProbe();
const fontGlyph = document.createTextNode('M'), glyphRange = document.createRange();
fontSample.style.cssText = 'position:absolute;white-space:nowrap;line-height:normal';
fontSample.append(fontGlyph, fontMark);
if (measuredGrid || proofLines) body.append(fontSample);
glyphRange.selectNodeContents(fontGlyph);
function baselineOffset(el) {
    if (elementOffsets.has(el)) return elementOffsets.get(el);
    const css = getComputedStyle(el);
    const font = css.fontStyle + ' ' + css.fontWeight + ' ' + css.fontSize + ' ' + css.fontFamily;
    if (!fontOffsets.has(font)) {
        fontSample.style.font = font;
        fontOffsets.set(font, (fontMark.getBoundingClientRect().bottom - glyphRange.getBoundingClientRect().top) * unit);
    }
    const offset = fontOffsets.get(font);
    elementOffsets.set(el,offset);
    return offset;
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
    function add(rect, el, ids = [], prose = false, broken = false) {
        if (!rect.width || !rect.height) return;
        budget();
        const para = el.closest('[data-flow-latin],p,li,pre');
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
            baseline:prose && measuredGrid && !el.closest('sup,sub,svg,.math') ? (rect.top+scrollY)*unit-origin+baselineOffset(el) : undefined,
            element:el, broken, extra:glueRemainders.get(el) || 0, discard:el.matches('.latex-vspace:not([data-latex-keep-space])'), heading:!!el.closest(heading) && !el.closest('.latex-runin:has(> p)'), ids});
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
                const end = Math.min(n.length, offset + 32768);
                range.setStart(n, offset); range.setEnd(n, end);
                const rects = range.getClientRects();
                const imposed = el.closest('[data-flow-latin] > .latex-line');
                const broken = !imposed && firstColumns && flushBottom && rects.length > 1 && getComputedStyle(el).hyphens === 'auto'
                    ? hyphenatedLines(n, offset, end) : null;
                for (const r of rects) add(r, el, note ? [note.dataset.flowNote] : [], true, imposed ? imposed.hasAttribute('data-flow-hyphen') : broken?.has(r.top));
            }
        } else if (n.matches(atomic + ',' + heading) || (!n.firstChild && getComputedStyle(n).position !== 'absolute')) {
            add(n.getBoundingClientRect(), n, [...n.querySelectorAll('[data-flow-note]')].map(a => a.dataset.flowNote));
        }
    }
    const rows = [];
    for (const b of bands.sort((a,b) => a.start - b.start)) {
        const last = rows.at(-1);
        // With tight leading, adjacent lines of the same paragraph can have overlapping
        // font rectangles even where the ink is clear. Give them a common cut so the
        // widow/orphan rules can still break a long paragraph at a real line boundary.
        if (measuredGrid && b.para && last?.para === b.para && b.start < last.end &&
            last.end - b.start <= .08 * Math.min(b.end - b.start, last.end - last.start) &&
            b.start > last.start && b.end > last.end) {
            last.end = b.start = (last.end + b.start) / 2;
        }
        if (last && b.start < last.end - 0.1) {
            if (b.baseline != null) {
                last.firstBaseline = Math.min(last.firstBaseline ?? last.baseline ?? Infinity,b.baseline);
                last.baseline = Math.max(last.baseline ?? -Infinity,b.baseline);
            }
            if (b.end >= last.end) last.shrinkAfter = b.shrinkAfter;
            last.broken ||= b.broken;
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
    // The column's first baseline is governed by the class topskip, even when
    // its first text line is an abstract heading or uses the bibliography font.
    const columnTopSkip = publicationTopSkip || texPoint * (Number(body.dataset.latexSize) || 10);
    return rows.map((r,i) => {
        const [plus, minus] = conferenceGlue(rows[i-1],r);
        return {slice:slice(box,r.start,r.end), brokenAfter:r.broken || undefined,
        bottomDepth:r.baseline != null && r.end-r.baseline > 0 && r.end-r.baseline < baseline/2 ? r.end-r.baseline : undefined,
        columnTopAdjustment:r.baseline != null && !r.element.closest('header') ? columnTopSkip - ((r.firstBaseline ?? r.baseline)-r.start) : undefined, notes:[...r.ids], wide:false,
        gap:i ? Math.max(0,r.start-rows[i-1].end) : r.start, stretchBefore:flushBottom && plus ? plus * texPoint : undefined,
        shrinkBefore:((rows[i-1]?.shrinkAfter || 0) + r.shrinkAbove + minus * texPoint) || undefined, discardable:r.discard, extraAfter:r.extra,
        topSkip:r.element.closest(publicationGrid ? '[data-latex-heading="section"]' :
            '[data-latex-heading="section"],[data-latex-heading="subsection"],[data-latex-heading="subsubsection"]') ? sectionTop : 0, paragraph:r.para, heading:r.heading, keepBefore:r.element.hasAttribute('data-flow-after-text') || undefined,
        // \chapter empties the top float list of its page (\@topnum is zero there).
        opensChapter:r.heading && body.dataset.latexChapters === 'true' && !!r.element.closest('h2[id^="sec-"],[data-latex-heading="chapter"],[data-latex-chapter-opening]') || undefined};
    });
}
// A TeX paragraph ends at the deepest glyph on its final line. Its HTML line box includes
// extra leading beneath that ink. Count that existing space towards intextsep when a figure
// actually lands here; deferred floats and consecutive floats retain their own full skips.
let inkContext;
function trailingLeading(box, last) {
    const block = box.lastElementChild;
    const p = block?.matches('.latex-runin') ? block.lastElementChild : block;
    if (!last || !p?.matches('p')) return 0;
    // References and inter-script glue split a single line into several text nodes.
    // Superscripts, images and arbitrary inline styles can have independent baselines.
    const tail = paragraphEdge(p, true);
    if ([...tail.querySelectorAll('*')].some(el =>
        !el.matches('br,a.latex-number-ref,.latex-xkanjiskip,[data-latex-thin-space],[data-latin-glue],.latex-line-end,.latex-line-space-end'))) return 0;
    const css = getComputedStyle(p);
    if (css.writingMode !== 'horizontal-tb' || css.direction !== 'ltr' || css.textTransform !== 'none') return 0;
    inkContext ??= document.createElement('canvas').getContext('2d');
    if (!inkContext) return 0;
    inkContext.font = css.fontStyle+' '+css.fontWeight+' '+css.fontSize+' '+css.fontFamily;
    const walker = document.createTreeWalker(tail, NodeFilter.SHOW_TEXT);
    let finalY, depth = 0;
    for (let text = walker.lastChild(); text; text = walker.previousSibling()) {
        const end = text.data.trimEnd().length;
        if (!end) continue;
        if (end > 32768) return 0;
        range.setStart(text,end-1); range.setEnd(text,end);
        const top = range.getBoundingClientRect().top;
        finalY ??= top;
        if (top < finalY - .25) break;
        let lo = 0, hi = end - 1;
        while (lo < hi) {
            const mid = (lo+hi) >>> 1;
            range.setStart(text,mid); range.setEnd(text,mid+1);
            if (range.getBoundingClientRect().top < finalY - .25) lo = mid+1; else hi = mid;
        }
        depth = Math.max(depth, inkContext.measureText(text.data.slice(lo,end)).actualBoundingBoxDescent * zoom);
        if (lo) break;
    }
    if (finalY === undefined) return 0;
    if (!Number.isFinite(depth)) return 0;
    const baseline = document.createElement('i');
    baseline.style.cssText = 'display:inline-block;width:0;height:0;vertical-align:baseline;margin:0;padding:0;border:0';
    tail.append(baseline);
    const y = (baseline.getBoundingClientRect().bottom+scrollY)*unit - origins[last.strip].y;
    baseline.remove();
    return Math.max(0, Math.min(inTextSep, last.end-y-Math.max(0,depth)));
}
const bookFloats = ['memoir','scrartcl','scrreprt','scrbook'].includes(body.dataset.latexClass);
const usesParagraphDepth = getComputedStyle(body).getPropertyValue('--latex-here-paragraph-depth').trim() === '1';
for (const seg of segments) {
    seg.items = seg.items.flatMap((item, i) => {
        if (item.glueBox) {
            const spacer = item.glueBox.firstElementChild;
            // A negative natural skip is represented by a margin; its containing
            // strip cannot itself have negative height.
            item.gap = spacer.getBoundingClientRect().height * unit + parseFloat(getComputedStyle(spacer).marginBottom) * zoom;
            delete item.glueBox;
            return [item];
        }
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
            const hereFigure = next?.floatKind === 'figure' &&
                (bookFloats || item.run.lastElementChild?.matches('.latex-runin') || next.box.querySelector('figure > p:first-child[data-latex-rule-line]'));
            if (next?.box && /[hH]/.test(next.placement) &&
                (hereFigure || usesParagraphDepth && ['figure','table'].includes(next.floatKind))) {
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
            // The display and the float live in different strips. Preserve their intervening
            // vertical glue only when the table actually lands at this point in the text.
            if (displayToTableSkip && next?.floatKind === 'table' && /[hH]/.test(next.placement) &&
                item.run.lastElementChild?.matches('.math-block')) {
                next.leadingBeforeHere = -displayToTableSkip;
            }
            return rows;
        }
        if (item.box) {
            item.slice = whole(item.box);
            const drawing = measuredGrid && item.box.querySelector(':scope > figure > p:first-child');
            const first = drawing?.firstElementChild;
            // Inline artwork inherits an empty text strut. At the top of a page its
            // first graphic starts at the margin; internal distances stay intact.
            const graphic = '.latex-rule,img,svg,.latex-graphic-box';
            if (first?.matches(graphic) && [...drawing.childNodes].every(n =>
                n.nodeType === Node.TEXT_NODE ? !n.textContent.trim() : n.nodeType === Node.ELEMENT_NODE &&
                    n.matches(graphic + ',.latex-vspace,br'))) {
                item.topInset = Math.max(0, (first.getBoundingClientRect().top + scrollY)*unit - origins[item.slice.strip].y);
            }
            delete item.box;
        }
        return [item];
    });
}
globalThis.surimonoFlow = {strips, origins, unit, baseline};
const probes = [];
for (const a of body.querySelectorAll('[data-latex-page-target],[data-latex-probe],[data-flow-sample-place]')) {
    const box = a.closest('[data-flow-strip]');
    if (!box) continue;
    const strip = +box.dataset.flowStrip;
    probes.push({index:a.hasAttribute('data-flow-sample-place') ? -1 : Number(a.dataset.latexPageTarget ?? a.dataset.latexProbe), strip,
        position:(a.getBoundingClientRect().top + scrollY)*unit - origins[strip].y});
}
// The ruler is independent of prose. Linenumbers follow the actual wrapped text ranges.
// Measure a font's baseline against a zero-height box in an isolated sample; inserting
// markers into words of the live paragraph would change shaping and PDF selection.
const review = body.dataset.latexReview;
let reviewLines;
const columnLines = ['blueColumnLines','grayColumnLines'].includes(review);
if (review === 'textLines' || columnLines || proofLines) {
    reviewLines = strips.map(box => {
        const ys = [], origin = origins[+box.dataset.flowStrip].y;
        // A composed line has one alphabetic baseline, including when its only
        // visible content is a formula. Marks and mixed-size faces can have other
        // text-rectangle tops. Measure the line once without splitting any word.
        if (proofLines) {
            const probes = [...box.querySelectorAll('[data-flow-latin] > .latex-line')].map(line => {
                budget();
                const mark = baselineProbe();
                line.append(mark);
                return mark;
            });
            for (const mark of probes) ys.push((mark.getBoundingClientRect().bottom + scrollY) * unit - origin);
            for (const mark of probes) mark.remove();
        }
        const tree = document.createTreeWalker(box, NodeFilter.SHOW_TEXT);
        for (let n = tree.nextNode(); n; n = tree.nextNode()) {
            const el = n.parentElement;
            if (!n.data.trim() || el.closest('sup,sub,svg,style,template') || proofLines && el.closest('[data-flow-latin] > .latex-line')) continue;
            if (!proofLines && (!el.closest('p,li,h1,h2,h3,h4,h5,h6,.latex-runin') ||
                el.closest('header,.latex-title-block,.latex-column-notice,.math-block,figure,table,.footnotes') ||
                review !== 'grayColumnLines' && el.closest('.abstract-title'))) continue;
            const offset = baselineOffset(el);
            range.selectNodeContents(n);
            for (const r of range.getClientRects()) {
                budget();
                if (r.width && r.height) ys.push((r.top + scrollY) * unit - origin + offset);
            }
        }
        if (columnLines) {
            for (const math of box.querySelectorAll('.math-display')) {
                if (math.closest('figure,table,.footnotes,header,.latex-column-notice')) continue;
                const svg = math.querySelector(':scope > svg');
                if (!svg) continue;
                const rect = svg.getBoundingClientRect();
                const rowNumbers = math.querySelectorAll(':scope > .latex-row-number');
                if (rowNumbers.length) {
                    for (const label of rowNumbers) {
                        ys.push((rect.top + rect.height * parseFloat(label.style.top) / 100 + scrollY) * unit - origin);
                    }
                } else {
                    const baselineY = displayBaseline(svg);
                    if (baselineY !== undefined) ys.push((baselineY + scrollY) * unit - origin);
                }
            }
        }
        ys.sort((a,b) => a-b);
        return ys.filter((y,i) => !i || y - ys[i-1] > 1);
    });
}
// A text footer ends on the column's last baseline. Keep the descenders in the
// capture and measure their depth without inserting anything into the note.
function noteSlice(box) {
    const part = whole(box);
    if (!measuredGrid) {
        if (hasColumnTitleNotes && box.querySelector('section.footnotes')) {
            const last = box.querySelector('li > p:last-child') || box.querySelector('li');
            const text = last?.querySelector(':scope > .latex-line:last-child') || last;
            if (text) {
                const marker = baselineProbe();
                text.append(marker);
                part.noteDepth = Math.max(0, (box.getBoundingClientRect().bottom - marker.getBoundingClientRect().bottom) * unit);
                marker.remove();
            }
        }
        return part;
    }
    const walker = document.createTreeWalker(box, NodeFilter.SHOW_TEXT);
    if (ruleToFirstBaseline > 0) {
        let first = walker.nextNode();
        while (first && (!first.data.trim() || first.parentElement.closest('svg,math,sup,sub,.latex-note-mark'))) first = walker.nextNode();
        if (first) {
            // Measure the first line's alphabetic baseline, including mixed Japanese and Latin faces.
            const marker = baselineProbe();
            first.before(marker);
            part.noteRuleOffset = (marker.getBoundingClientRect().bottom - box.getBoundingClientRect().top) * unit - ruleToFirstBaseline;
            marker.remove();
        }
        walker.currentNode = box;
    }
    let node = walker.lastChild();
    while (node && (!node.data.trim() || node.parentElement.closest('svg,math,sup,sub'))) node = walker.previousNode();
    if (!node) return part;
    range.selectNodeContents(node);
    const rect = [...range.getClientRects()].filter(r => r.width && r.height).at(-1);
    if (rect) {
        const depth = (box.getBoundingClientRect().bottom - rect.top) * unit - baselineOffset(node.parentElement);
        if (depth > 0 && depth < rect.height * unit && depth < part.end) part.noteDepth = depth;
    }
    return part;
}
for (const [id, box] of pendingMeasurements) notes[id] = noteSlice(box);
const columnNoticeSlice = columnNoticeBox ? noteSlice(columnNoticeBox) : undefined;
fontSample.remove();
let floatFractions;
if (body.hasAttribute('data-latex-style')) {
    const css = getComputedStyle(body);
    const fraction = key => Number(css.getPropertyValue('--latex-' + key));
    floatFractions = {top:fraction('top-fraction'), bottom:fraction('bottom-fraction'),
        text:fraction('text-fraction'), page:fraction('float-page-fraction')};
}
// A document may replace a skip with a rigid length. Only the kits' default
// lengths carry the corresponding article glue in this measurement.
function insertionGlue(name, measured, natural, plus, minus) {
    if (publicationGrid) {
        const values = glueStyle.getPropertyValue('--latex-glue-' + name).trim().split(/\s+/).map(Number);
        if (values.length === 3 && values.every(Number.isFinite)) [natural, plus, minus] = values;
    }
    return Math.abs(measured - natural * texPoint) < .1 ? [plus * texPoint, minus * texPoint] : [0,0];
}
const [notePlus, noteMinus] = gluePair('note',4,2);
const insertions = {
    note:insertionGlue('footins', noteSkip, 9, notePlus, noteMinus),
    textFloat:insertionGlue('textfloatsep', textFloatSep, 20, 2, 4),
    float:insertionGlue('floatsep', floatSep, 12, 2, 2),
    inText:insertionGlue('floatsep', inTextSep, 12, 2, 2)
};
const glueShrink = measuredGrid ? Object.fromEntries(Object.entries(insertions).map(([k,v]) => [k,v[1]])) : undefined;
const glueStretch = flushBottom ? Object.fromEntries(Object.entries(insertions).map(([k,v]) => [k,v[0]])) : undefined;
// Journal notes are ruled across the actual column, including after a stock change.
const noteRuleWidth = publicationGrid ? (firstColumns ? (width - firstColumns.gap) / 2 : width) :
    requestedNoteRuleWidth ?? (hasColumnTitleNotes ? undefined : 180);
return JSON.stringify({mathProof:globalThis.surimonoMathProofs?.length ? true : undefined,segments,notes,glueShrink,glueStretch,floatFractions,noteSkip,noteStrutDepth,noteRuleWidth,noteRuleThickness,textFloatSep,floatSep,inTextSep,probes,review,reviewLines,
    // The journal grids set both club and widow penalties to zero, including in two-column prose.
    allowsSingleLineFragments:publicationGrid || undefined,
    // These grids choose the left column break before the right column's length is known.
    comparesColumnBreakBadness:publicationGrid || undefined,
    reviewBanner:body.dataset.latexReviewBanner, reviewCorner:body.dataset.latexReviewCorner,
    columnNotice:columnNoticeSlice, singleColumnNotice:publicationGrid && !firstColumns || undefined,
    columnNoticeLast:columnNotice?.dataset.latexColumnNotice === 'last',
    firstNotice:noticeBox ? whole(noticeBox) : undefined, firstPageExtension:noticeBox ? 2 * baseline : undefined});
