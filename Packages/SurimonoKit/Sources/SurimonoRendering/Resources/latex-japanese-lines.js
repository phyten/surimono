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
    return japaneseBreakPlan(tokens, width, indent, em, zw);
}

function japaneseBreakPlan(tokens, width, indent, em, zw, grid = false, pt = 1, fixedWesternSkip = null) {
    if (!tokens.length) return null;
    // TeX reads a decimal multiplier as a 16.16 fraction, then truncates the product to sp.
    // Even .1zw versus exactly one tenth changes fitness at the 99/100 badness boundary.
    const scaledZW = Math.round(zw * 65536 / pt);
    const partZW = fraction => Math.floor(scaledZW * Math.round(fraction * 65536) / 65536) * pt / 65536;
    const kanjiSkip = grid ? [0, partZW(.1), partZW(.05)] : null;
    const westernSkip = fixedWesternSkip || [.25 * em, .15 * em, .06 * em];
    function glue(left, right) {
        const a = left.kind, b = right.kind;
        if (grid) {
            if (a === 'mark' || b === 'mark' || a === 'tie' || b === 'tie') return [0,0,0];
            // Middle dots, colons and semicolons have a half-cell glyph with adjustable quarter-cell bearings.
            if (a === 'middle' || b === 'middle') {
                const natural = a === 'middle' && b === 'middle' ? .5 : '。．'.includes(left.text) ? .75 : .25;
                return [natural * zw, 0, .25 * zw];
            }
            // The JIS comma carries shrinkable trailing glue; a full stop's trailing half cell is rigid.
            // At a line end neither leaves trailing glue. An input newline after a stop is consumed by pTeX.
            if (a === 'close' && b !== 'close' || b === 'open' && a !== 'open')
                return [.5 * zw, 0, '。．'.includes(left.text) ? 0 : .5 * zw];
            if (a === 'space' || b === 'space' || a === 'latin' && b === 'latin') return [0,0,0];
            if (a === 'open' || b === 'close' || a === 'kanji' && b === 'kanji') return kanjiSkip;
        }
        if (a === 'space' || b === 'space') return [0, 0, 0];
        if (a === 'close' && b !== 'close' || b === 'open' && a !== 'open') return [.5 * zw, .1 * zw, .5 * zw];
        if (a === 'open' || b === 'close') return [0, 0, .01 * zw];
        if (a === 'latin' || b === 'latin') return westernSkip;
        return [0, .1 * zw, .01 * zw];
    }
    const gaps = tokens.map((t,i) => i ? glue(tokens[i-1],t) : [0,0,0]);
    if (grid) {
        const lines = japaneseParagraphBreaks(tokens, gaps, width, indent, pt);
        return lines && {tokens, gaps, lines, zw};
    }
    const lines = [];
    for (let start = 0; start < tokens.length;) {
        const target = width - (start === 0 ? indent : 0);
        let used = 0, stretch = 0, shrink = 0, best;
        for (let i = start; i < tokens.length; i++) {
            const t = tokens[i], next = tokens[i+1];
            if (i > start) { used += gaps[i][0]; stretch += gaps[i][1]; shrink += gaps[i][2]; }
            used += t.advance;
            if (used - shrink > target + .001 && best) break;
            if (next?.kind === 'space' || next?.kind === 'mark' || !canWrap(t, next, t.kind === 'space')) continue;
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

// A greedy break often leaves a two-character final line. TeX chooses the
// paragraph as a whole, penalizing the cubic badness of stretched/shrunk lines.
function japaneseParagraphBreaks(tokens, gaps, width, indent, pt) {
    const states = [[null,null,{cost:0, fitness:2},null]];
    const lastLetter = tokens.findLastIndex(t => t.kind !== 'close');
    let trials = 0;
    for (let start = 0; start < tokens.length; start++) {
        if (!states[start]) continue;
        let used = 0, stretch = 0, shrink = 0;
        const target = width - (start ? 0 : indent);
        for (let end = start + 1; end <= tokens.length; end++) {
            // Fall back to native layout for an unusually wide measure with many candidates.
            if (++trials > 100000) return null;
            const i = end - 1, t = tokens[i], next = tokens[end];
            if (i > start) { used += gaps[i][0]; stretch += gaps[i][1]; shrink += gaps[i][2]; }
            used += t.advance;
            // A break at an interword space discards that glue from the preceding line.
            const spare = target - used + (t.kind === 'space' ? t.advance : 0);
            if (-spare > shrink + .001) break;
            if (next?.kind === 'space' || next?.kind === 'mark' || !canWrap(t,next,t.kind === 'space')) continue;
            const ratio = !next && spare >= 0 ? 0 : spare / Math.max(.001,spare < 0 ? shrink : stretch);
            const badness = !next && spare >= 0 ? 0 : texBadness(spare, spare < 0 ? shrink : stretch, 65536 / pt);
            // A saturated finite-glue line is outside both journal classes' tolerance.
            if (badness === 10000) continue;
            const fitness = badness <= 12 ? 2 : ratio < 0 ? 3 : badness > 99 ? 0 : 1;
            const widow = end === lastLetter && next?.kind === 'kanji' ? 500 : 0;
            const demerits = (10 + badness) ** 2 + widow ** 2;
            states[end] ??= [];
            for (const previous of states[start]) {
                if (!previous) continue;
                const cost = previous.cost + demerits + (Math.abs(fitness - previous.fitness) > 1 ? 10000 : 0);
                // TeX visits active predecessors in source order and retains the later equal demerit.
                if (!states[end][fitness] || cost <= states[end][fitness].cost)
                    states[end][fitness] = {start,end,ratio,cost,fitness,previous};
            }
        }
    }
    if (!states[tokens.length]) return null;
    const lines = [];
    let best = states[tokens.length].filter(Boolean).reduce((a,b) => a.cost < b.cost ? a : b);
    while (best.previous) { lines.push(best); best = best.previous; }
    return lines.reverse();
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

// Treat a decimal and its nonbreaking unit as one Western run to retain its kerning and search text.
function japaneseGridTokens(source, parts, em, zw, measure) {
    const words = source.matchAll(/[・：；]|[「『（【〈《〔［｛]|[」』）】〉》〕］｝、。，．]|[\p{sc=Han}\p{sc=Hiragana}\p{sc=Katakana}ー]\p{M}*| +|[^・：；「『（【〈《〔［｛」』）】〉》〕］｝、。，．\p{sc=Han}\p{sc=Hiragana}\p{sc=Katakana}ー ]+/gu);
    for (const [text] of words) {
        const kind = '「『（【〈《〔［｛'.includes(text) ? 'open' :
            '」』）】〉》〕］｝、。，．'.includes(text) ? 'close' :
            '・：；'.includes(text) ? 'middle' : japaneseLetter.test(text) ? 'kanji' : /^ +$/.test(text) ? 'space' : text === '\u00a0' ? 'tie' : 'latin';
        const ja = kind === 'kanji' || kind === 'middle' || kind === 'open' || kind === 'close';
        const swallowed = kind === 'space' && parts.at(-1)?.kind === 'close';
        const advance = swallowed ? 0 : ja ? (kind === 'kanji' ? zw : .5 * zw) :
            kind === 'tie' ? em / 3 : measure(text);
        parts.push({text, kind, advance, ja, swallowed});
    }
}

// Set mixed Japanese prose at its column measure. Keep references, math, and
// nonbreaking quantities as the original inline nodes. Only lines and groups
// separated by JFM glue need boxes; a word or a run of kana stays one text node.
function japaneseGridParagraphs(body, bodyZW, bibliographyZW, unitsPerPixel) {
    const context = document.createElement('canvas').getContext('2d');
    if (!context || !(bodyZW > 0)) return;
    const range = document.createRange();
    const diagnostics = globalThis.surimonoCollectJapaneseBoxes ? (globalThis.surimonoJapaneseBoxes = []) : null;
    const style = getComputedStyle(body);
    const pt = parseFloat(style.getPropertyValue('--tex-pt'));
    if (!(pt > 0)) return;
    const fixed = style.getPropertyValue('--latex-xkanjiskip-pt').trim();
    const westernSkip = fixed ? fixed.split(/\s+/).map(value => Number(value) * pt) : null;
    let remaining = 250000;
    for (const p of body.querySelectorAll('[data-flow-strip] > p:lang(ja), [data-flow-strip] > :is(ul,ol.latex-enumerate,ol.latex-bibliography) > li:lang(ja)')) {
        if (!japaneseLetter.test(p.textContent) || p.textContent.length > 8192 ||
            p.matches(':has(p,div,table,br,ul,ol,pre)')) continue;
        if ((remaining -= p.textContent.length) < 0) break;
        const css = getComputedStyle(p), em = parseFloat(css.fontSize), width = parseFloat(css.width);
        const bibliography = p.matches('.latex-bibliography > li');
        const zw = bibliography ? bibliographyZW : bodyZW;
        if (css.direction !== 'ltr' || css.writingMode !== 'horizontal-tb' ||
            css.textAlign !== 'justify' || !(zw > 0 && width > 2 * zw)) continue;
        context.font = css.fontStyle + ' ' + css.fontWeight + ' ' + 32 * em + 'px ' + css.fontFamily;
        const parts = [], labels = [];
        let unsupported = false;
        for (const child of p.childNodes) {
            if (child.nodeType === Node.ELEMENT_NODE) {
                if (child.matches('.latex-item-mark,.item-label,.bib-label')) { labels.push(child); continue; }
                if (!child.matches('a,span,sup,sub,em,strong,b,i') || child.querySelector('br,table') ||
                    getComputedStyle(child).display === 'block') { unsupported = true; break; }
                const glyph = child.textContent, mark = child.matches('sup,sub');
                // A styled Japanese phrase may break inside its own shaping context.
                if (!mark && japaneseLetter.test(glyph)) { unsupported = true; break; }
                range.selectNode(child);
                // A tight note mark overhangs its box. Only its advance occupies the line measure.
                const rect = mark ? child.getBoundingClientRect() : range.getBoundingClientRect();
                parts.push({text:glyph, node:child, kind:mark ? 'mark' : 'latin', advance:rect.width * unitsPerPixel});
                continue;
            }
            if (child.nodeType !== Node.TEXT_NODE) { unsupported = true; break; }
            japaneseGridTokens(child.data, parts, em, zw, text => context.measureText(text).width / 32);
        }
        if (unsupported || labels.some(label => !label.matches('.latex-item-mark,.bib-label'))) continue;
        const indent = parseFloat(css.textIndent);
        const plan = japaneseBreakPlan(parts, width, indent, em, zw, true, pt, westernSkip);
        if (!plan) continue;
        if (diagnostics) {
            diagnostics.push({text: p.textContent, width, indent, em, zw,
                cssPerTeXPoint: pt,
                ends: plan.lines.map(line => line.end),
                tokens: parts.map((t,i) => [t.text, t.kind, t.advance, ...plan.gaps[i],
                    t.node?.className || null])});
        }
        const content = document.createDocumentFragment();
        const inlineLabel = labels.length > 0 && getComputedStyle(labels[0]).position !== 'absolute';
        if (!inlineLabel) content.append(...labels);
        for (const {start,end} of plan.lines) {
            const line = document.createElement('span');
            line.className = 'latex-grid-line';
            // A hanging label shares the first text baseline even across a column break.
            if (!start && inlineLabel) line.append(...labels);
            if (!start && indent) line.style.paddingInlineStart = indent + 'px';
            // The layout engine distributes any remaining positive glue between characters
            // in the intact run; the fixed-width JFM punctuation can surrender its half cell.
            if (end !== parts.length) line.style.textAlignLast = 'justify';
            // Native justification expands intact CJK runs. When a line must shrink, give
            // the shrink to the adjustable punctuation and Western boundaries first.
            let visibleShrink = 0, shortfall = start ? -width : indent - width;
            for (let i = start; i < end; i++) {
                if (i + 1 !== end || parts[i].kind !== 'space') shortfall += parts[i].advance;
                if (i === start) continue;
                shortfall += plan.gaps[i][0];
                if (parts[i - 1].kind === 'close' || parts[i].kind === 'open' ||
                    parts[i - 1].kind === 'middle' || parts[i].kind === 'middle' ||
                    parts[i - 1].kind === 'latin' || parts[i].kind === 'latin') visibleShrink += plan.gaps[i][2];
            }
            const squeeze = visibleShrink ? Math.min(1, Math.max(0, shortfall) / visibleShrink) : 0;
            let run = '', before = 0;
            function flush(after = 0) {
                if (!run) return;
                if (before || after) {
                    const group = document.createElement('span');
                    group.textContent = run;
                    if (before) group.style.marginInlineStart = before + 'px';
                    if (after) group.style.marginInlineEnd = after + 'px';
                    line.append(group);
                } else line.append(run);
                run = ''; before = 0;
            }
            for (let i = start; i < end; i++) {
                const t = parts[i], next = parts[i + 1];
                if (t.swallowed) {
                    // Keep the source space in textContent; the stop already supplies its advance.
                    const space = document.createElement('span');
                    space.style.cssText = 'font-size:0;line-height:0';
                    space.textContent = t.text; flush(); line.append(space);
                } else if (t.kind === 'middle') {
                    // Apply the bearings to the neighbouring runs; the punctuation stays in the original text flow.
                    flush(i === start ? 0 : -squeeze * .25 * zw);
                    line.append(t.text);
                    before = i + 1 === end ? 0 : -squeeze * .25 * zw;
                } else if (t.kind === 'latin' || t.kind === 'mark') {
                    flush();
                    const word = document.createElement('span');
                    word.style.cssText = 'display:inline-block;white-space:nowrap;text-align-last:auto;line-height:0';
                    if (i > start && parts[i - 1].kind === 'kanji' && t.kind === 'latin')
                        word.style.marginInlineStart = (plan.gaps[i][0] - squeeze * plan.gaps[i][2]) + 'px';
                    if (i + 1 < end && next.kind === 'kanji' && t.kind === 'latin')
                        word.style.marginInlineEnd = (plan.gaps[i+1][0] - squeeze * plan.gaps[i+1][2]) + 'px';
                    word.append(t.node || t.text);
                    line.append(word);
                } else {
                    if (t.kind === 'open') {
                        flush();
                        before = i === start || parts[i - 1].kind === 'open' ? -.5 * zw : -squeeze * plan.gaps[i][2];
                    }
                    run += t.text;
                    if (t.kind === 'close') {
                        const shrink = i + 1 === end || next.kind === 'close' ? 1 :
                            plan.gaps[i+1][2] / (.5 * zw) * squeeze;
                        if (shrink) flush(-.5 * zw * shrink);
                    }
                }
            }
            flush();
            content.append(line);
        }
        p.replaceChildren(content);
        p.style.textIndent = '0';
    }
}

// Use TeX's Japanese glyph depth even when the installed face has taller outlines.
// Complex inline boxes keep their own leading; a multiline caption ends at its final line.
function japaneseLineDepth(el, finalLineOnly = false) {
    if (el.textContent.length > 4096 || el.querySelector('svg, img, ruby, sup, sub, br')) return null;
    const range = document.createRange();
    range.selectNodeContents(el);
    const rects = [...range.getClientRects()].filter(r => r.width > 0);
    if (!rects.length) return null;
    const lastTop = rects.at(-1).top;
    if (!finalLineOnly && rects.some(r => r.bottom < lastTop)) return null;
    const canvas = document.createElement('canvas').getContext('2d');
    if (!canvas) return null;
    let depth = 0;
    const walk = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
    while (walk.nextNode()) {
        const n = walk.currentNode, css = getComputedStyle(n.parentElement), em = parseFloat(css.fontSize);
        canvas.font = css.fontStyle + ' ' + css.fontWeight + ' ' + 32 * em + 'px ' + css.fontFamily;
        let text = n.data;
        if (finalLineOnly) {
            range.selectNodeContents(n);
            const lines = range.getClientRects();
            if (!lines.length || lines[lines.length-1].bottom <= lastTop) continue;
            if (lines[0].bottom <= lastTop) {
                // One DOM text node can cover several lines. Only the suffix on
                // the final line contributes a descender to the caption parbox.
                let lo = 0, hi = text.length - 1;
                while (lo < hi) {
                    const mid = (lo + hi) >>> 1;
                    range.setStart(n, mid); range.setEnd(n, mid+1);
                    if (range.getBoundingClientRect().bottom <= lastTop) lo = mid+1;
                    else hi = mid;
                }
                text = text.slice(lo);
            }
        }
        const latin = text.replace(/[\u3000-\u30ff\u3400-\u9fff\uff00-\uffef]/gu,'');
        if (latin !== text) depth = Math.max(depth, .12 * canvas.measureText('紙').width / 32);
        depth = Math.max(depth, canvas.measureText(latin).actualBoundingBoxDescent / 32);
    }
    return Number.isFinite(depth) ? depth : null;
}
