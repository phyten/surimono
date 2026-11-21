// Build the default trie once when the typography scripts enter this document's isolated world.
const latinEnglishHyphens = latinHyphenator(globalThis.surimonoEnglishPatterns);

// All cached values are numbers, strings or plans. Never retain a flow clone, a DOM
// Range or a computed style across the paginator's reference-filling passes.
function latinCompose(body, rectToCSS = 1, restorations) {
    const start = performance.now(), deadline = start + 4000;
    const summary = {qualifying:0, composed:0, fallbacks:0, paragraphs:[], milliseconds:0};
    const family = body.dataset.latexLineBreaking;
    if (!['cm','times'].includes(family) || !body.matches('.format-latex')) return summary;
    // The standard 12pt class selects a different CM design at normalsize.
    const cmBody12 = family === 'cm' && body.dataset.latexSize === '12' ? getComputedStyle(body).fontSize : null;
    const diagnostics = !!globalThis.surimonoLatinDiagnostics;
    if (diagnostics) summary.skipped = [];
    const cache = globalThis.surimonoLatinCache ??= {
        faces:new Map(), widths:new Map(), plans:new Map(), patterns:new Map()
    };
    // In text mode LaTeX's \, and \thinspace insert a fixed kern.
    const thinSpaceEm = .16667;
    const sheet = document.createElement('style');
    sheet.textContent = `
p[data-flow-latin] > .latex-line { display:block; white-space:nowrap; text-indent:0; text-align:start;
    text-align-last:start; hyphens:none; -webkit-hyphens:none; }
:is(.latex-line,.latex-runin > :is(h4,h5,h6)) :is(.latex-line-space-end,.latex-line-end) { display:inline-block; width:0; height:0;
    overflow:hidden; font-size:0; line-height:0; word-spacing:0; padding:0; border:0; margin:0; }
.latex-line .latex-line-hyphen::after { content:"-"; }
:is(.latex-line,.latex-runin > :is(h4,h5,h6)) [data-latin-fixed] { word-spacing:0px; white-space:nowrap; }
[data-latin-fixed][data-latex-thin-space] { display:inline-block; inline-size:${thinSpaceEm}em; }
.latex-runin:has(> p[data-flow-latin]) { white-space:nowrap; text-align:start; text-align-last:start; }
.latex-runin > p[data-flow-latin] > .latex-line:first-child { display:inline; }
`;
    const probe = document.createElement('span');
    probe.style.cssText = 'position:absolute;left:0;top:0;visibility:hidden;white-space:pre;display:inline-block;' +
        'width:max-content;text-indent:0;text-align:start;word-spacing:0;padding:0;border:0;margin:0;pointer-events:none';
    body.append(sheet, probe);
    const ctx = document.createElement('canvas').getContext('2d');
    const properties = ['fontFamily','fontSize','fontStyle','fontWeight','fontStretch','fontVariantCaps',
        'fontVariantLigatures','fontFeatureSettings','fontVariationSettings','fontKerning','textRendering',
        'fontOpticalSizing','fontSizeAdjust','fontVariantNumeric','fontVariantPosition'];
    const domFaces = new Map(), pitches = new Map(), range = document.createRange();
    let probeFace;
    const firstFace = css => css.fontFamily.split(',')[0].trim().replace(/^["']|["']$/g,'').toLowerCase();
    const faceFamily = css => {
        const family = firstFace(css);
        if (family === 'surimono computer modern') return 'cm';
        if (family === 'times new roman' || family === 'times') return 'times';
        if (family === 'surimono computer modern typewriter') return 'typewriter';
        return 'unknown';
    };
    function useProbe(face) {
        if (probeFace === face) return;
        for (const property of properties) probe.style[property] = face[property];
        probe.lang = face.lang;
        probeFace = face;
    }
    function domWidth(face, text) {
        useProbe(face);
        probe.textContent = text;
        return probe.getBoundingClientRect().width * rectToCSS;
    }
    function canvasWidth(face, text) {
        ctx.font = face.canvasFont;
        ctx.fontKerning = face.fontKerning;
        ctx.fontVariantCaps = face.fontVariantCaps;
        ctx.fontStretch = 'normal';
        ctx.textRendering = face.textRendering;
        if ('lang' in ctx) ctx.lang = face.lang;
        return ctx.measureText(text).width;
    }
    function faceFor(el) {
        if (domFaces.has(el)) return domFaces.get(el);
        const css = getComputedStyle(el), lang = el.closest('[lang]')?.lang || '';
        const key = JSON.stringify([...properties.map(k => css[k]), lang, rectToCSS, body.style.zoom]);
        let face = cache.faces.get(key);
        if (!face) {
            face = Object.fromEntries(properties.map(k => [k,css[k]]));
            Object.assign(face, {key, lang, family:faceFamily(css), em:parseFloat(css.fontSize),
                canvasFont:[css.fontStyle,css.fontWeight,css.fontSize,css.fontFamily].join(' ')});
            // Canvas has no general OpenType feature/variation API. Calibrate the ordinary
            // shaping path on kerned and ligated runs at the current layout precision.
            const sample = 'office AV To fi ffi small CAPS';
            face.useDOM = !ctx || !['normal','100%'].includes(css.fontStretch) ||
                css.fontVariantLigatures !== 'normal' || css.fontFeatureSettings !== 'normal' ||
                css.fontVariationSettings !== 'normal' || css.fontVariantNumeric !== 'normal' ||
                css.fontVariantPosition !== 'normal' || !['none',''].includes(css.fontSizeAdjust) ||
                Math.abs(domWidth(face,sample) - canvasWidth(face,sample)) > .04;
            face.space = domWidth(face, ' ');
            if (cache.faces.size >= 128) cache.faces.clear();
            cache.faces.set(key,face);
        }
        domFaces.set(el,face);
        return face;
    }
    function widthOf(face,text) {
        const key = face.key + '\n' + text;
        let width = cache.widths.get(key);
        if (width === undefined) {
            width = face.useDOM ? domWidth(face,text) : canvasWidth(face,text);
            if (cache.widths.size >= 20000) cache.widths.clear();
            cache.widths.set(key,width);
        }
        return width;
    }

    const inline = 'em,strong,i,b,span,a,code,sup,sub';
    const atoms = '.math-inline,.latex-nowrap,.footnote-ref,.latex-cite:not([data-latex-cite-text]),.latex-number-ref,.latex-pageref,code,sup,sub';
    const marks = '.footnote-ref,.latex-cite:not([data-latex-cite-text])';
    function runInHeading(p) {
        const head = p.previousElementSibling;
        return p.parentElement.matches('div.latex-runin') && p.parentElement.children.length === 2 &&
            head?.matches('.latex-runin-paragraph,.latex-runin-subparagraph,.latex-runin-subsubsection') && getComputedStyle(head).display === 'inline' ? head : null;
    }
    const unsupported = new Set(['mixed script','unsupported inline','unsupported inline style',
        'unsupported object','unsupported inline box','empty']);
    function excluded(p, heading) {
        let parent = heading ? p.parentElement.parentElement : p.parentElement;
        while (parent && parent !== body && parent.matches('div[lang],div.latex-link-colors,div[data-flow-strip]')) {
            if (parent.style.textAlign || parent.hasAttribute('align')) return 'aligned container';
            parent = parent.parentElement;
        }
        if (parent !== body) return 'outside body flow';
        if (p.hasAttribute('data-flow-latin')) return 'already composed';
        if (p.matches('.abstract-title,.latex-runin-paragraph,[align]') || p.style.textAlign) return 'aligned paragraph';
        if (!/^en(?:-|$)/i.test(p.closest('[lang]')?.lang || '')) return 'language';
        // Non-printing SVG style text can dwarf the visible paragraph. Classify
        // the graphic first so its font program never consumes the prose budget.
        if (p.querySelector('br,img,ruby,table,svg:not(.math-inline svg),.latex-hspace,.latex-graphic-box,.tikz-block,style:not(.math-inline *)'))
            return 'unsupported inline';
        const css = getComputedStyle(p);
        if (css.display !== (heading ? 'inline' : 'block') || css.direction !== 'ltr' ||
            css.writingMode !== 'horizontal-tb' || css.textAlign !== 'justify') return 'paragraph layout';
        if (css.whiteSpace !== 'normal' || css.textTransform !== 'none' ||
            !['normal','0px'].includes(css.letterSpacing)) return 'paragraph text style';
        return faceFamily(css) === family ? null : 'body font';
    }
    function noteSkip(p,reason) {
        if (diagnostics) summary.skipped.push({reason, text:p.textContent.trim().slice(0,160),
            parent:p.parentElement.tagName.toLowerCase(), parentClass:p.parentElement.className});
    }
    // A piece points into one original text node or owns one indivisible inline object.
    // An object has a sentinel in the planner, even for textless SVGs and destinations.
    // Neither that sentinel nor the lexical copy of its punctuation enters the DOM.
    let remainingWords = 65536, remainingNodes = 131072, remainingLines = 12000;
    function tokenize(p, parameters, followsGlue = false) {
        const words = [], leading = [];
        let word, pending = [], count = 0;
        function add(piece, text) {
            if (!word || pending.length) {
                if (--remainingWords < 0 || words.length >= 1800) throw Error('word budget');
                if (word) word.after = pending;
                else leading.push(...pending);
                word = {text:'', runs:[], after:[], glue:[0,0,0]};
                words.push(word);
                pending = [];
            }
            piece.at = word.text.length;
            piece.text = text;
            word.runs.push(piece);
            word.text += text;
        }
        function visit(node, owners) {
            if (++count > 2048 || --remainingNodes < 0 || owners.length > 64) throw Error('node budget');
            const el = node.parentElement;
            if (node.nodeType === Node.TEXT_NODE) {
                const face = faceFor(el);
                if (/[\p{L}&&[^\p{Script=Latin}]]/v.test(node.data) ||
                    /[\u202a-\u202e\u2066-\u2069]/u.test(node.data)) throw Error('mixed script');
                for (const token of node.data.matchAll(/[ \n\t\r\f]+|\u00a0|[^ \n\t\r\f\u00a0]+/g)) {
                    const piece = {owners,face,text:token[0]};
                    if (/^[ \n\t\r\f]/.test(token[0])) pending.push(piece);
                    else if (token[0] === '\u00a0') pending.push({...piece,tie:true});
                    else add(piece,token[0]);
                }
                return;
            }
            if (node.nodeType !== Node.ELEMENT_NODE || !node.matches(inline) ||
                node.matches('.latex-rule,.latex-fbox,.math-display,.theorem-head'))
                throw Error('unsupported inline');
            const css = getComputedStyle(node);
            // Disposable page-reference probes paint outside the line. Carry their
            // original href/text to the capture without charging their ink to its width.
            if (node.matches('a[data-latex-probe]') && css.position === 'absolute') {
                add({owners,face:faceFor(el),atom:node,width:0},'\ufffc');
                return;
            }
            if (css.direction !== 'ltr' || css.writingMode !== 'horizontal-tb' ||
                node.lang && !/^en(?:-|$)/i.test(node.lang) ||
                !['normal','0px'].includes(css.letterSpacing) || css.textTransform !== 'none' ||
                !['inline','inline-block'].includes(css.display) || css.position !== 'static')
                throw Error('unsupported inline style');
            const sectionNumber = node.matches('.secnum') && !p.matches('p');
            const thinSpace = node.hasAttribute('data-latex-thin-space');
            const atomic = thinSpace || sectionNumber || node.matches(atoms) || css.whiteSpace === 'nowrap' || !node.firstChild;
            if (!atomic) {
                if (css.display !== 'inline' || css.whiteSpace !== 'normal') throw Error('unsupported inline box');
                for (const child of node.childNodes) visit(child,[...owners,node]);
                return;
            }
            const descendants = document.createTreeWalker(node,NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT);
            for (let child = descendants.nextNode(); child; child = descendants.nextNode()) {
                if (++count > 2048 || --remainingNodes < 0) throw Error('node budget');
                if (child.nodeType === Node.TEXT_NODE) {
                    if (!child.parentElement.closest('.math-inline') &&
                        /[\p{L}&&[^\p{Script=Latin}]]/v.test(child.data)) throw Error('mixed script');
                } else if (!child.matches(inline) && !child.closest('.math-inline svg') ||
                    child.lang && !/^en(?:-|$)/i.test(child.lang)) throw Error('unsupported object');
            }
            const face = faceFor(node);
            // A citation or code box can already wrap across lines in the source.
            // Its measurement copy must see the same zoomed body and natural space.
            let width;
            if (thinSpace) {
                width = face.em * thinSpaceEm;
            } else if ((node.matches('.math-inline') || !/[\s\u00a0]/.test(node.textContent)) && node.getClientRects().length === 1) {
                width = node.getBoundingClientRect().width * rectToCSS;
            } else {
                useProbe(faceFor(el));
                const sample = node.cloneNode(true);
                sample.style.whiteSpace = 'nowrap';
                sample.style.wordSpacing = '0px';
                probe.replaceChildren(sample);
                width = sample.getBoundingClientRect().width * rectToCSS;
            }
            if (sectionNumber) width += parseFloat(css.marginInlineStart) + parseFloat(css.marginInlineEnd);
            if (word && node.matches(marks)) {
                for (const piece of pending) piece.tie = true;
            }
            // The reader binds punctuation following inline math to its SVG for line breaking.
            // That punctuation is still outside math in TeX and sets the following space factor.
            const suffix = node.matches('.latex-nowrap') && node.childNodes.length === 2 &&
                node.firstChild.matches?.('.math-inline') && node.lastChild.nodeType === Node.TEXT_NODE
                ? node.lastChild.data : '';
            add({owners,face,atom:node,width},'\ufffc' + suffix);
        }
        for (const child of p.childNodes) visit(child,[]);
        if (word) word.after = pending;
        if (!words.length) throw Error('empty');
        if (leading.some(part=>part.tie) || word.after.some(part=>part.tie)) throw Error('edge tie');
        for (const [index,w] of words.entries()) {
            const canHyphenate = w.runs.length === 1 && !w.runs[0].atom && !w.runs[0].owners.some(el =>
                el.matches('a.long-token,.long-token') || el.matches('a') && /^\w+:\/\//.test(el.textContent));
            w.breaks = automatic => {
                const points = [];
                if (!canHyphenate || /^\w+:\/\/|www\.|@|\/\//i.test(w.text)) return points;
                for (const m of w.text.matchAll(/[-–—\u00ad]/g)) {
                    if (m.index + 1 < w.text.length) points.push({offset:m.index+1, hyphen:m[0] === '\u00ad'});
                }
                const letters = /^([A-Za-z]+)[.,!?:;”’"')\]]*$/.exec(w.text);
                if (automatic && (index || followsGlue) && letters) {
                    let hyphenate = cache.patterns.get(parameters.hyphenation || '');
                    if (!hyphenate) {
                        hyphenate = parameters.hyphenation
                            ? latinHyphenator(globalThis.surimonoEnglishPatterns, parameters.hyphenation) : latinEnglishHyphens;
                        if (cache.patterns.size >= 32) cache.patterns.clear();
                        cache.patterns.set(parameters.hyphenation || '',hyphenate);
                    }
                    for (const offset of hyphenate(letters[1])) points.push({offset,hyphen:true});
                }
                return points;
            };
            w.fragment = (from,to,hyphen) => {
                let width = 0;
                for (const part of w.runs) {
                    const a = Math.max(from-part.at,0), b = Math.min(to-part.at,part.text.length);
                    if (a >= b) continue;
                    if (part.atom) width += part.width;
                    else width += widthOf(part.face,part.text.slice(a,b) +
                        (hyphen && to === part.at+b ? '-' : ''));
                }
                return width;
            };
            w.width = w.fragment(0,w.text.length,false);
            if (w.after.length) {
                const f = w.after[0].face;
                w.noBreakAfter = w.after.some(piece => piece.tie);
                w.rawSpace = w.after[0].text === '\u00a0' ? widthOf(f,'\u00a0') : f.space;
                const controlSpace = w.after[0].text === '\u00a0' ||
                    w.after[0].owners.some(el => el.hasAttribute('data-latex-control-space'));
                w.glue = latinGlue(f.family,f.fontStyle,+f.fontWeight,f.em,w.rawSpace,
                    controlSpace ? '' : w.text,parameters.frenchspacing,f.fontSize === cmBody12 ? 12 : 10);
            }
        }
        return {words,leading};
    }

    function assemble(source, plan, indent, pitch) {
        const fragment = document.createDocumentFragment(), rows = [], copied = new Set();
        const {words,leading,head} = source;
        const headContent = head ? document.createDocumentFragment() : null;
        const headCount = head?.words.length || 0;
        for (const [index,part] of plan.lines.entries()) {
            const line = document.createElement('span');
            line.className = 'latex-line';
            if (!index && !head && indent) line.style.paddingInlineStart = indent + 'px';
            if (part.hyphen) line.dataset.flowHyphen = '';
            fragment.append(line);
            const row = {line,part,gaps:[],pitch};
            let chain = [], copies = [line];
            function owner(owners) {
                let i = 0;
                while (i < chain.length && i < owners.length && chain[i] === owners[i]) i++;
                copies.length = i+1;
                for (const original of owners.slice(i)) {
                    const clone = original.cloneNode(false);
                    if (copied.has(original)) clone.removeAttribute('id');
                    copied.add(original);
                    copies.at(-1).append(clone);
                    copies.push(clone);
                }
                chain = owners;
                return copies.at(-1);
            }
            function write(target,text) {
                const previous = target.lastChild;
                if (previous?.nodeType === Node.TEXT_NODE) {
                    const start = previous.length;
                    previous.appendData(text);
                    return {node:previous,start};
                }
                const node = document.createTextNode(text);
                target.append(node);
                return {node,start:0};
            }
            function span(target, cls) {
                const element = document.createElement('span');
                element.className = cls;
                target.append(element);
                return element;
            }
            function hidden(pieces) {
                for (const piece of pieces) span(owner(piece.owners),'latex-line-space-end').textContent = piece.text;
            }
            if (!index && head) { copies = [headContent]; hidden(head.leading); }
            else if (!index) hidden(leading);
            for (let wi = part.startWord; wi <= part.endWord; wi++) {
                if (!index && head && wi === headCount) {
                    chain = []; copies = [line]; hidden(leading);
                }
                const w = words[wi];
                const from = wi === part.startWord ? part.startOffset : 0;
                const to = wi === part.endWord ? part.endOffset : w.text.length;
                for (const run of w.runs) {
                    const a = Math.max(from-run.at,0), b = Math.min(to-run.at,run.text.length);
                    if (a >= b) continue;
                    let target = owner(run.owners);
                    if (run.atom) {
                        const clone = run.atom.cloneNode(true);
                        clone.dataset.latinFixed = '';
                        target.append(clone);
                    } else {
                        if (run.text.includes('\u202f')) {
                            const fixed = document.createElement('span');
                            fixed.dataset.latinFixed = '';
                            target.append(fixed);
                            target = fixed;
                        }
                        write(target,run.text.slice(a,b));
                    }
                    if (part.hyphen && wi === part.endWord && to === run.at+b) {
                        span(target,'latex-line-hyphen');
                    }
                }
                if (to !== w.text.length) continue;
                if (wi === part.endWord || head && wi === headCount-1) {
                    hidden(w.after);
                } else {
                    if (w.after.length !== 1) throw Error('ambiguous collapsed space');
                    const piece = w.after[0];
                    let target = owner(piece.owners);
                    const base = w.glue[0] - w.rawSpace;
                    row.base ??= base;
                    row.baseGlue ??= w.glue;
                    let override;
                    if (base !== row.base || w.glue[1] !== row.baseGlue[1] || w.glue[2] !== row.baseGlue[2]) {
                        override = document.createElement('span');
                        override.dataset.latinGlue = '';
                        override.style.wordSpacing = base + 'px';
                        target.append(override);
                        target = override;
                    }
                    row.gaps.push({...write(target,piece.text),length:piece.text.length,glue:w.glue,base,override});
                }
            }
            row.end = span(line,'latex-line-end');
            line.style.wordSpacing = (row.base || 0) + 'px';
            rows.push(row);
        }
        return {fragment,rows,headContent};
    }
    // The conference sheets trim the first line to cap height and put the omitted
    // space into padding above it. A block line must retain its full pitch. Transfer
    // only that trim to the existing positive padding, keeping the same first glyph
    // position. A trim with no padding to absorb it stays on the native path.
    function firstGlyphRect(p) {
        const tree = document.createTreeWalker(p,NodeFilter.SHOW_TEXT);
        for (let n = tree.nextNode(); n; n = tree.nextNode()) {
            const i = n.data.search(/[^ \n\t\r\f]/);
            if (i < 0) continue;
            if (n.parentElement.closest('[data-latex-probe]')) continue;
            if (n.parentElement.closest('svg,sup,sub')) return null;
            range.setStart(n,i); range.setEnd(n,i+1);
            return range.getBoundingClientRect();
        }
        return null;
    }
    function lastGlyphInset(p) {
        const tree = document.createTreeWalker(p,NodeFilter.SHOW_TEXT);
        for (let n = tree.lastChild(); n; n = tree.previousNode()) {
            const last = n.data.trimEnd().length;
            // A closing footnote callout sits above the baseline. Use the adjacent
            // body glyph, whose inset tracks the trimmed line's actual baseline.
            if (!last || n.parentElement.closest('[data-latex-probe],svg,sup,sub')) continue;
            range.setStart(n,last-1); range.setEnd(n,last);
            return (p.getBoundingClientRect().bottom-range.getBoundingClientRect().bottom) * rectToCSS;
        }
        return null;
    }
    function runInPitch(heading,p,width) {
        // A heading has its own strut. Measure it together with ordinary body
        // text; a tall formula on a later native line must not affect this pitch.
        const sample = p.parentElement.cloneNode(false), prose = p.cloneNode(false);
        sample.style.cssText += ';position:absolute;visibility:hidden;margin:0;box-sizing:border-box;width:'+width+'px';
        prose.textContent = 'x';
        sample.append(heading.cloneNode(true),prose);
        p.parentElement.after(sample);
        try { return sample.getBoundingClientRect().height*rectToCSS; }
        finally { sample.remove(); }
    }
    function runInGap(p, heading) {
        const first = firstGlyphRect(p);
        if (!first) return NaN;
        range.selectNodeContents(heading);
        return (first.left-range.getBoundingClientRect().right) * rectToCSS;
    }
    function firstGlyph(p) {
        const rect = firstGlyphRect(p);
        return rect ? (rect.top-p.getBoundingClientRect().top) * rectToCSS : null;
    }
    const pending = [];
    const fallbackRows = [];
    function finish(trial,text,reason,lines = []) {
        if (reason) summary.fallbacks++;
        else summary.composed++;
        if (!diagnostics) return;
        const record = {text, fallback:reason, lines, index:trial.index, renderedLineCount:lines.length};
        if (trial.boxDiagnostics) record.boxDiagnostics = trial.boxDiagnostics;
        if (trial.heading) record.runInHeading = trial.heading.textContent;
        if (trial.runInGeometry) record.runInGeometry = trial.runInGeometry;
        summary.paragraphs.push(record);
        if (reason) fallbackRows.push([trial.heading ? trial.p.parentElement : trial.p, record]);
    }
    function nativeLines(p, pitch) {
        const bands = [], tree = document.createTreeWalker(p,NodeFilter.SHOW_TEXT);
        for (let n = tree.nextNode(); n; n = tree.nextNode()) {
            if (!n.data.trim() || n.parentElement.closest('svg,sub,sup,[data-latex-probe]')) continue;
            range.selectNodeContents(n);
            for (const r of range.getClientRects()) if (r.width && r.height) bands.push((r.top+r.bottom)/2);
        }
        for (const box of p.querySelectorAll('.math-inline'))
            bands.push(box.getBoundingClientRect().top+box.getBoundingClientRect().height/2);
        const tolerance = pitch / rectToCSS * .5;
        let previous = -Infinity, count = 0;
        for (const center of bands.sort((a,b) => a-b)) {
            if (center > previous+tolerance) { previous = center; count++; }
        }
        return count;
    }
    function refreshFallbacks() {
        for (const [p,record] of fallbackRows) {
            record.renderedLineCount = nativeLines(p,parseFloat(getComputedStyle(p).lineHeight));
        }
    }
    function rollback(trial) {
        trial.p.replaceChildren(...trial.original);
        trial.p.removeAttribute('data-flow-latin');
        if (trial.heading) {
            trial.heading.replaceChildren(...trial.originalHeading);
            if (trial.oldHeadingStyle === null) trial.heading.removeAttribute('style');
            else trial.heading.setAttribute('style',trial.oldHeadingStyle);
        }
        if (trial.trim) {
            if (trial.oldStyle === null) trial.p.removeAttribute('style');
            else trial.p.setAttribute('style',trial.oldStyle);
        }
    }
    function geometry(row) {
        if (row.runIn) {
            // The first row shares its native inline formatting context with the
            // heading and the class's horizontal afterskip. Its line box extends
            // from the wrapper's top to the next block line, including its leading.
            const block = row.line.closest('.latex-runin').getBoundingClientRect();
            const bottom = row.line.nextElementSibling?.getBoundingClientRect().top ?? block.bottom;
            return {height:(bottom-block.top)*rectToCSS, measure:block.width*rectToCSS-row.runIn.left,
                width:(row.end.getBoundingClientRect().left-block.left)*rectToCSS-row.runIn.left};
        }
        const r = row.line.getBoundingClientRect();
        const indent = parseFloat(row.line.style.paddingInlineStart) || 0;
        return {height:r.height * rectToCSS, measure:r.width * rectToCSS - indent,
            width:(row.end.getBoundingClientRect().left-r.left) * rectToCSS - indent};
    }
    function eachTrial(perform) {
        for (const trial of pending) {
            if (trial.reason) continue;
            try {
                if (performance.now() > deadline) throw Error('composition budget');
                perform(trial);
            } catch (error) { trial.reason = error.message || 'DOM measurement'; }
        }
    }
    try {
        for (const p of body.querySelectorAll('p')) {
            const heading = runInHeading(p);
            const exclusion = excluded(p,heading);
            if (exclusion) { noteSkip(p,exclusion); continue; }
            const index = summary.qualifying++, text = p.textContent;
            const paragraphDeadline = Math.min(deadline, performance.now()+250);
            let boxDiagnostics;
            try {
                if (text.length + (heading?.textContent.length ?? 0) > 18000 || remainingWords <= 0 || remainingNodes <= 0 ||
                    remainingLines <= 0 || performance.now() > deadline) throw Error('composition budget');
                const settings = p.dataset.latexLineParameters ?? body.dataset.latexLineParameters;
                const parameters = Object.assign(family === 'times' ? {tolerance:9999,emergencystretch:'3em'} : {},
                    settings ? JSON.parse(settings) : {});
                const prose = tokenize(p,parameters,!!heading);
                const head = heading ? tokenize(heading,parameters) : null;
                const words = head ? [...head.words,...prose.words] : prose.words;
                const block = heading ? p.parentElement : p;
                const css = getComputedStyle(p), rect = block.getBoundingClientRect();
                const inset = ['paddingLeft','paddingRight','borderLeftWidth','borderRightWidth']
                    .reduce((sum,k) => sum + (parseFloat(css[k]) || 0),0);
                const width = rect.width * rectToCSS - inset;
                let indent = parseFloat(css.textIndent), runIn;
                if (heading) {
                    const first = firstGlyphRect(p), headRect = firstGlyphRect(heading);
                    if (!first || !headRect || heading.getClientRects().length !== 1 ||
                        Math.abs(first.top-headRect.top) * rectToCSS > parseFloat(css.lineHeight)/2)
                        throw Error('wrapped run-in heading');
                    // All supported classes specify -1em with no stretch or shrink
                    // in @startsection. The native p margin carries that exact skip.
                    const skip = parseFloat(css.marginInlineStart);
                    head.words.at(-1).glue = [skip,0,0];
                    indent = (headRect.left-rect.left)*rectToCSS;
                    runIn = {rise:(first.top-headRect.top)*rectToCSS, left:indent, skip};
                }
                if (!(width > 0 && indent >= 0 && indent < width)) throw Error('invalid measure');
                if (typeof parameters.emergencystretch === 'string') {
                    useProbe(faceFor(p));
                    probe.style.width = parameters.emergencystretch;
                    parameters.emergencystretch = probe.getBoundingClientRect().width * rectToCSS;
                    probe.style.width = 'max-content';
                }
                // Equal total widths can hide different prefix/suffix advances. Keep
                // the individual shaping faces and object widths in the plan key.
                const fonts = [...new Set(words.flatMap(w => w.runs.map(r => r.face.key)))];
                const fontIDs = new Map(fonts.map((key,i) => [key,i]));
                const key = JSON.stringify([width,indent,head?.words.length ?? 0,parameters,fonts,words.map(w =>
                    [w.text,!!w.noBreakAfter,...w.glue,...w.runs.map(r => [r.at,fontIDs.get(r.face.key),r.width ?? null,
                        r.owners.some(el => el.matches('.long-token') || el.matches('a') && /^\w+:\/\//.test(el.textContent))])])]);
                let plan = cache.plans.get(key);
                if (plan === undefined) {
                    plan = latinBreakPlan(words,width,indent,parameters);
                    if (key.length <= 32768) {
                        if (cache.plans.size >= 128) cache.plans.clear();
                        cache.plans.set(key,plan);
                    }
                }
                // WebKit quantizes line heights at the current zoom; computedStyle can
                // report a fractional pitch even when each ordinary native line is integral.
                const face = faceFor(p), pitchKey = face.key + '/' + css.lineHeight;
                let pitch = pitches.get(pitchKey);
                if (pitch === undefined) {
                    useProbe(face);
                    probe.style.lineHeight = css.lineHeight;
                    probe.textContent = 'x';
                    pitch = probe.getBoundingClientRect().height * rectToCSS;
                    pitches.set(pitchKey,pitch);
                }
                const originalLines = nativeLines(block,pitch);
                if (diagnostics && globalThis.surimonoLatinBoxDiagnostics) {
                    boxDiagnostics = {width,indent,parameters,nativeLines:originalLines,pass:plan?.pass ?? null,
                        originalHeight:rect.height*rectToCSS, textBoxTrim:css.textBoxTrim,
                        ratios:plan?.lines.map(l=>l.ratio) ?? [],words:words.map(w => ({
                            text:w.runs.map(r=>r.atom ? r.atom.textContent : r.text).join(''),width:w.width,
                            glue:w.glue,noBreakAfter:!!w.noBreakAfter}))};
                }
                // text-box-trim removes leading at the native paragraph boundary.
                // With end trim only, the original text block supplies that last
                // line's actual height independently of how many lines we compose.
                let finalPitch, finalInset;
                if (!heading && css.textBoxTrim === 'trim-end' && originalLines) {
                    const blockInset = ['paddingTop','paddingBottom','borderTopWidth','borderBottomWidth']
                        .reduce((sum,k) => sum + (parseFloat(css[k]) || 0),0);
                    const last = rect.height*rectToCSS-blockInset-(originalLines-1)*pitch;
                    if (last > 0 && last <= pitch) {
                        finalInset = lastGlyphInset(p);
                        if (finalInset !== null) finalPitch = last;
                    }
                }
                if (!plan) throw Error('no feasible plan');
                if (!originalLines) throw Error('native line count unavailable');
                if (plan.lines.length > originalLines) throw Error('more lines than native');
                remainingLines -= plan.lines.length;
                if (remainingLines < 0) throw Error('line budget');
                if (head && plan.lines[0].endWord < head.words.length) throw Error('wrapped run-in heading');
                const {fragment,rows,headContent} = assemble({words,leading:prose.leading,head},plan,indent,pitch);
                if (head && headContent.textContent !== heading.textContent) throw Error('content mismatch');
                if (runIn) {
                    rows[0].runIn = runIn;
                    rows[0].pitch = runInPitch(heading,p,width);
                }
                if (finalPitch !== undefined) rows.at(-1).pitch = finalPitch;
                if (fragment.textContent !== text) throw Error('content mismatch');
                if (performance.now() > paragraphDeadline) throw Error('composition budget');
                const initialPadding = parseFloat(css.paddingBlockStart);
                const first = css.textBoxTrim === 'trim-start' && initialPadding > 0 ? firstGlyph(p) : null;
                pending.push({p,index,text,heading,runIn,headContent,originalHeading:heading && [...heading.childNodes],
                    oldHeadingStyle:heading?.getAttribute('style'),rows,fragment,boxDiagnostics,original:[...p.childNodes],oldStyle:p.getAttribute('style'),
                    trim:first !== null, first, initialPadding, finalInset});
            } catch (error) {
                if (unsupported.has(error.message)) { summary.qualifying--; noteSkip(p,error.message); }
                else finish({index,p,heading,boxDiagnostics},text,String(error.message));
            }
        }
        // Layout in batches across the document. Alternating writes and natural-width
        // reads for every paragraph makes a hundred-page flow quadratic in WebKit.
        eachTrial(trial => {
            trial.installed = true;
            trial.p.dataset.flowLatin = '';
            if (trial.trim) trial.p.style.setProperty('text-box-trim','none','important');
            if (trial.heading) {
                trial.heading.replaceChildren(trial.headContent);
                trial.heading.style.wordSpacing = trial.rows[0].line.style.wordSpacing;
            }
            trial.p.replaceChildren(trial.fragment);
        });
        eachTrial(trial => {
            if (trial.trim) {
                const first = firstGlyph(trial.p);
                const padding = trial.initialPadding - (first - trial.first);
                if (first === null || !(padding > 0 && padding <= trial.initialPadding+.02)) {
                    trial.reason = 'first baseline'; return;
                }
                trial.padding = padding;
            }
            for (const row of trial.rows) {
                const {width,measure} = geometry(row);
                const last = row === trial.rows.at(-1);
                row.delta = last && width <= measure ? 0 : measure-width;
                row.axis = row.delta < 0 ? 2 : 1;
                const capacity = row.gaps.reduce((sum,g) => sum + g.glue[row.axis],0);
                if ((Math.abs(row.delta) > .03 && !capacity) || row.delta < -capacity - .00001) {
                    trial.reason = 'DOM glue capacity'; break;
                }
                row.ratio = capacity ? row.delta / capacity : 0;
            }
        });
        eachTrial(trial => {
            if (trial.trim) trial.p.style.setProperty('padding-block-start',trial.padding+'px','important');
            for (const row of trial.rows) {
                if (!row.delta || !row.baseGlue) continue;
                row.line.style.wordSpacing = row.base + row.ratio * row.baseGlue[row.axis] + 'px';
                if (row.runIn) trial.heading.style.wordSpacing = row.line.style.wordSpacing;
                for (const g of row.gaps) {
                    if (g.override) g.override.style.wordSpacing = g.base + row.ratio * g.glue[row.axis] + 'px';
                }
            }
        });
        eachTrial(trial => {
            trial.lines = [];
            if (trial.runIn) {
                const head = firstGlyphRect(trial.heading), first = firstGlyphRect(trial.p);
                const block = trial.p.parentElement.getBoundingClientRect();
                // Glyph ranges snap to layout pixels even at a fractional CSS
                // margin. The inline boxes enclose the actual fixed afterskip.
                const gapError = (trial.rows[0].line.getClientRects()[0].left -
                    trial.heading.getBoundingClientRect().right)*rectToCSS-trial.runIn.skip;
                const riseError = head && first ? (first.top-head.top)*rectToCSS - trial.runIn.rise : Infinity;
                const leftError = head ? (head.left-block.left)*rectToCSS - trial.runIn.left : Infinity;
                if (trial.boxDiagnostics) trial.runInGeometry = {gapError,riseError,leftError,afterSkip:trial.runIn.skip,
                    glyphGap:runInGap(trial.p,trial.heading)};
                if (Math.max(Math.abs(riseError),Math.abs(leftError),Math.abs(gapError)) > .1 || !first || !head) {
                    trial.reason = 'run-in baseline'; return;
                }
            }
            if (trial.trim && Math.abs(firstGlyph(trial.p)-trial.first) > .05) {
                trial.reason = 'first baseline'; return;
            }
            if (trial.finalInset != null) {
                const inset = lastGlyphInset(trial.p);
                if (inset === null || Math.abs(inset-trial.finalInset) > .06) {
                    trial.reason = 'last baseline'; return;
                }
            }
            for (const row of trial.rows) {
                const {width,measure,height} = geometry(row);
                const last = row === trial.rows.at(-1);
                if (Math.abs(height-row.pitch) > .06 || !Number.isFinite(row.pitch)) {
                    if (trial.boxDiagnostics) trial.boxDiagnostics.pitch = {height,expected:row.pitch,
                        row:trial.rows.indexOf(row),text:row.line.textContent,rows:trial.rows.length};
                    trial.reason = 'line pitch'; break;
                }
                if (width > measure + .32 || !last && Math.abs(measure-width) > .32) {
                    trial.reason = 'right edge'; break;
                }
                // WebKit's Range rectangle of a collapsed space leaves out word-spacing, so the
                // floor cannot be read back from the DOM. The right edge above proves the spacing
                // was applied as computed: derive each space from the ratio instead.
                let minSpaceSlack = Infinity;
                for (const g of row.gaps) {
                    minSpaceSlack = Math.min(minSpaceSlack,g.glue[2] + row.ratio * g.glue[row.axis]);
                }
                if (minSpaceSlack < -.00001) { trial.reason = 'space below floor'; break; }
                if (diagnostics) {
                    const text = row.line.textContent.trim(), words = text.split(/\s+/);
                    trial.lines.push({text,first:words[0],last:words.at(-1),hyphen:row.part.hyphen,
                        ratio:row.ratio,measure,width,height,pitch:row.pitch,
                        minSpaceSlack:Number.isFinite(minSpaceSlack) ? minSpaceSlack : null});
                }
            }
        });
    } catch (error) {
        for (const trial of pending) trial.reason ??= 'DOM measurement';
    } finally {
        for (const trial of pending) {
            if (trial.reason) {
                if (trial.installed) rollback(trial);
            } else if (restorations) restorations.push(() => rollback(trial));
            finish(trial,trial.text,trial.reason || null,trial.reason ? [] : trial.lines);
        }
        probe.remove();
        if (!summary.composed) sheet.remove();
        else if (restorations) restorations.push(() => sheet.remove());
    }
    if (diagnostics) {
        summary.paragraphs.sort((a,b) => a.index-b.index);
        refreshFallbacks();
        Object.defineProperty(summary,'refreshFallbacks',{value:refreshFallbacks});
    }
    summary.milliseconds = performance.now()-start;
    return summary;
}
