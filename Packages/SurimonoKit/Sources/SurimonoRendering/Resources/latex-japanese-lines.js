// CSS justification can expand a Japanese line, but the browser chooses its break
// before trying the shrinkable JFM glue. Resolve plain prose at its final measure;
// leave shaped inline content (ruby, links, math and explicit breaks) in the DOM.
function planJapaneseProse(source, width, indent, em, zw, measure) {
    if (!(width > 0 && zw > 0 && em > 0 && Number.isFinite(indent))) return null;
    const tokens = [];
    for (const text of labelParts(source)) {
        let kind;
        if ('「『（【〈《〔［｛'.includes(text)) kind = 'open';
        else if ('」』）】〉》〕］｝、。，．'.includes(text)) kind = 'close';
        else if (japaneseLetter.test(text)) kind = 'kanji';
        else if (/^[\p{sc=Latin}\p{M}\p{Nd}]+$/u.test(text)) kind = 'latin';
        else if (text === ' ') kind = 'space';
        else return null;
        const half = kind === 'open' || kind === 'close';
        const advance = half ? .5 * zw : kind === 'kanji' ? zw : measure(text);
        tokens.push({text, kind, advance, ja: half || kind === 'kanji'});
    }
    function glue(a, b) {
        if (a === 'space' || b === 'space') return [0, 0, 0];
        if (a === 'close' && b !== 'close' || b === 'open' && a !== 'open') return [.5 * zw, .1 * zw, .5 * zw];
        if (a === 'open' || b === 'close') return [0, 0, .01 * zw];
        if (a === 'latin' || b === 'latin') return [.25 * em, .15 * em, .06 * em];
        return [0, .1 * zw, .01 * zw];
    }
    const gaps = tokens.map((t,i) => i ? glue(tokens[i-1].kind, t.kind) : [0,0,0]);
    const lines = [];
    for (let start = 0; start < tokens.length;) {
        const target = width - (start === 0 ? indent : 0);
        let used = 0, stretch = 0, shrink = 0, best;
        for (let i = start; i < tokens.length; i++) {
            const t = tokens[i], next = tokens[i+1];
            if (i > start) { used += gaps[i][0]; stretch += gaps[i][1]; shrink += gaps[i][2]; }
            used += t.advance;
            if (used - shrink > target + .001 && best) break;
            if (next?.kind === 'space' || !canWrap(t, next, t.kind === 'space')) continue;
            const spare = target - used;
            const ratio = !next && spare >= 0 ? 0 : spare / Math.max(.001, spare < 0 ? shrink : stretch);
            if (!best || Math.abs(ratio) <= Math.abs(best.ratio)) best = {start, end:i+1, ratio};
        }
        // An over-wide word or an exceptionally narrow measure keeps native wrapping.
        if (!best || best.ratio < -1.001) break;
        lines.push(best);
        start = best.end;
    }
    return lines.at(-1)?.end === tokens.length ? {tokens, gaps, lines, zw} : null;
}

function japaneseProseLines(body) {
    const canvas = document.createElement('canvas').getContext('2d');
    if (!canvas) return;
    const contextRange = document.createRange();
    const plans = [];
    // Exhausting the optional adjustment budget leaves later prose in native
    // line boxes. It must not invalidate an otherwise printable flow.
    let remaining = 250000;
    for (const p of body.querySelectorAll('[data-flow-strip] > p:lang(ja)')) {
        const node = p.firstChild;
        if (p.childNodes.length !== 1 || node?.nodeType !== Node.TEXT_NODE || node.length > 8192
            || !/[\u3041-\u30fa\u3400-\u9fff]/.test(node.data)) continue;
        contextRange.selectNodeContents(node);
        const rects = contextRange.getClientRects();
        if (rects.length < 2 || rects[rects.length - 1].top < rects[0].bottom - .5) continue;
        const css = getComputedStyle(p);
        if (css.textAlign !== 'justify' || css.direction !== 'ltr' || css.writingMode !== 'horizontal-tb'
            || css.letterSpacing !== 'normal' && parseFloat(css.letterSpacing) !== 0) continue;
        const em = parseFloat(css.fontSize), width = parseFloat(css.width), indent = parseFloat(css.textIndent);
        if (!(width > em && Number.isFinite(indent))) continue;
        canvas.font = css.fontStyle + ' ' + css.fontWeight + ' ' + 32 * em + 'px ' + css.fontFamily;
        const zw = canvas.measureText('紙').width / 32;
        if (node.length > remaining) break;
        remaining -= node.length;
        const plan = planJapaneseProse(node.data, width, indent, em, zw, word => canvas.measureText(word).width / 32);
        if (plan) plans.push({p, ...plan});
    }
    for (const {p, tokens, gaps, lines, zw} of plans) {
        const frag = document.createDocumentFragment();
        for (const {start, end, ratio} of lines) {
            if (start) frag.append(document.createElement('br'));
            const line = document.createElement('span');
            line.style.whiteSpace = 'nowrap';
            for (let i = start; i < end;) {
                const t = tokens[i], gap = gaps[i], g = ratio < 0 ? 2 : 1;
                const span = document.createElement('span');
                let before = i === start ? 0 : gap[0] + ratio * gap[g];
                let after = 0, text = t.text;
                if (t.kind === 'open') before -= .5 * zw;
                if (t.kind === 'close') after -= .5 * zw;
                i++;
                if (t.kind === 'kanji' && i < end && tokens[i].kind === 'kanji') {
                    const tracking = ratio * gaps[i][g];
                    while (i < end && tokens[i].kind === 'kanji') text += tokens[i++].text;
                    span.style.letterSpacing = tracking + 'px';
                    after -= tracking;
                }
                if (before) span.style.marginInlineStart = before + 'px';
                if (after) span.style.marginInlineEnd = after + 'px';
                span.textContent = text;
                line.append(span);
            }
            frag.append(line);
        }
        p.style.textAutospace = 'no-autospace';
        p.style.setProperty('text-spacing-trim', 'space-all');
        p.replaceChildren(frag);
    }
}

// Use TeX's Japanese glyph depth even when the installed face has taller outlines.
// Cap measurements at one line; complex inline boxes keep the browser's own leading.
function japaneseLineDepth(el) {
    if (el.textContent.length > 4096 || el.querySelector('svg, img, ruby, sup, sub, br')) return null;
    const range = document.createRange();
    range.selectNodeContents(el);
    const rects = [...range.getClientRects()].filter(r => r.width > 0);
    if (!rects.length || rects.some(r => r.bottom < rects.at(-1).top)) return null;
    const canvas = document.createElement('canvas').getContext('2d');
    if (!canvas) return null;
    let depth = 0;
    const walk = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
    while (walk.nextNode()) {
        const n = walk.currentNode, css = getComputedStyle(n.parentElement), em = parseFloat(css.fontSize);
        canvas.font = css.fontStyle + ' ' + css.fontWeight + ' ' + 32 * em + 'px ' + css.fontFamily;
        const latin = n.data.replace(/[\u3000-\u30ff\u3400-\u9fff\uff00-\uffef]/gu,'');
        if (latin !== n.data) depth = Math.max(depth, .12 * canvas.measureText('紙').width / 32);
        depth = Math.max(depth, canvas.measureText(latin).actualBoundingBoxDescent / 32);
    }
    return Number.isFinite(depth) ? depth : null;
}
