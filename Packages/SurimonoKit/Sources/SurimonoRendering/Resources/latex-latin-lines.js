// Build the default trie once when the typography scripts enter this document's isolated world.
const latinEnglishHyphens = latinHyphenator(globalThis.surimonoEnglishPatterns);

// The native paginator installs an equivalent Unicode predicate for Sequoia's JavaScriptCore.
let latinNonLatinLetter = /[\p{L}&&[^\p{Script=Latin}]]/v;
let latinMeasureDescriptionGap = false;

// Older WebKit includes CSS transforms but omits CSS zoom from client rects.
// A ruler in the text's coordinate system measures their combined effect.
function latinCSSPixelsPerRect(body) {
    const ruler = document.createElement('div');
    ruler.style.cssText = 'position:absolute;width:100px!important;box-sizing:content-box;padding:0;border:0';
    body.append(ruler);
    try { return 100 / ruler.getBoundingClientRect().width; }
    finally { ruler.remove(); }
}

// All cached values are numbers, strings or plans. Never retain a flow clone, a DOM
// Range or a computed style across the paginator's reference-filling passes.
function latinCompose(body, rectToCSS = 1, restorations) {
    const rigidMath = globalThis.surimonoNextRigidMath;
    delete globalThis.surimonoNextRigidMath;
    const proofs = globalThis.surimonoMathProofs = [];
    const start = performance.now(), deadline = start + 4000;
    const summary = {qualifying:0, composed:0, fallbacks:0, paragraphs:[], milliseconds:0};
    const family = body.dataset.latexLineBreaking;
    if (!['cm','times'].includes(family) || !body.matches('.format-latex')) {
        if (globalThis.surimonoLatinDiagnostics) {
            summary.skipped = [{reason:'body class or line-breaking family', family, className:body.className}];
        }
        return summary;
    }
    const bodyStyle = getComputedStyle(body);
    const bodySize = parseFloat(bodyStyle.fontSize);
    const texPointsPerPixel = (parseFloat(bodyStyle.getPropertyValue('--tex-body')) || 10) / bodySize;
    const contextParameters = JSON.parse(body.dataset.latexContextParameters || '{}');
    const diagnostics = !!globalThis.surimonoLatinDiagnostics;
    if (diagnostics) summary.skipped = [];
    const cache = globalThis.surimonoLatinCache ??= {
        faces:new Map(), widths:new Map(), plans:new Map(), patterns:new Map()
    };
    // In text mode LaTeX's \, and \thinspace insert a fixed kern.
    const thinSpaceEm = .16667;
    const sheet = document.createElement('style');
    sheet.textContent = `
[data-flow-latin] > .latex-line { display:block; white-space:nowrap; text-indent:0; text-align:start;
    text-align-last:start; hyphens:none; -webkit-hyphens:none; }
:is(.latex-line,.latex-runin > :is(h4,h5,h6),.latex-description dt) :is(.latex-line-space-end,.latex-line-end) { display:inline-block; width:0; height:0;
    overflow:hidden; font-size:0; line-height:0; word-spacing:0; padding:0; border:0; margin:0; }
.latex-line .latex-line-hyphen::after { content:"-"; }
:is(.latex-line,.latex-runin > :is(h4,h5,h6),.latex-description dt) [data-latin-fixed] { word-spacing:0px; white-space:nowrap; }
[data-latin-fixed][data-latex-thin-space] { display:inline-block; inline-size:${thinSpaceEm}em; }
.latex-runin:has(> p[data-flow-latin]) { white-space:nowrap; text-align:start; text-align-last:start; }
.latex-runin > p[data-flow-latin] > .latex-line:first-child,
.latex-description:not(.latex-nextline) :is(dd[data-flow-latin],dd > p:first-child[data-flow-latin]) > .latex-line:first-child { display:inline; }
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
        // The PDF-safe substitute for CMU small capitals still takes cmcsc's TeX glue.
        if (family === 'surimono searchable small caps' && css.fontVariantCaps === 'small-caps' &&
            css.getPropertyValue('--tex-searchable-caps').trim()) return 'cm';
        if (family === 'surimono computer modern') return 'cm';
        if (family === 'times new roman' || family === 'times') return 'times';
        if (family === 'surimono computer modern sans') return 'sans';
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
    const gutterSelector = '.item-label,.bib-label,.latex-item-mark,.latex-symbolic-note';
    const paragraphSelector = 'p,li,dd,figcaption,figcaption[data-latex-caption-hang] > span:nth-child(2),ol.latex-alpha > li > .bib-label + span';
    function contextOf(p) {
        if (p.matches('ol.latex-alpha > li')) return null;
        if (p.matches('li,dd') && p.querySelector(':scope > :is(p,ul,ol,dl,div,blockquote)')) return null;
        const parent = p.parentElement;
        const note = p.closest('section.footnotes > ol > li');
        const bib = p.closest('ol.latex-bibliography > li');
        const definition = p.closest('dl.latex-description > div > dd');
        if (p.closest('table,header,nav,.latex-column-notice,.latex-title-block')) return null;
        if (note && (p === note || parent === note)) return 'footnote';
        if (bib && (p === bib || parent === bib)) return 'bibliography';
        if (definition && (p === definition || parent === definition)) return 'description';
        if (p.matches('figcaption[data-latex-caption-hang]')) return null;
        if (p.matches('figcaption,figcaption[data-latex-caption-hang] > span:nth-child(2)')) return 'caption';
        if (p.closest('figure,figcaption,.latex-minipage')?.matches('figure,figcaption')) return null;
        if (p.matches('ul > li,ol.latex-enumerate > li') || parent.matches('ul > li,ol.latex-enumerate > li') && p.matches('p')) return 'list';
        if (!p.matches('p')) return null;
        if (parent.matches('.abstract,.latex-front-abstract') && !p.matches('.abstract-title')) return 'abstract';
        if (parent.matches('blockquote:not([class])')) return 'quote';
        if (parent.matches('blockquote.latex-quotation')) return 'quotation';
        if (parent.matches('.latex-minipage')) return 'minipage';
        return 'body';
    }
    function excluded(p, heading, category) {
        if (category === 'body') {
            let parent = heading ? p.parentElement.parentElement : p.parentElement;
            while (parent && parent !== body && parent.matches('div[lang],div.latex-link-colors,div[data-flow-strip]')) {
                if (parent.style.textAlign || parent.hasAttribute('align')) return 'aligned container';
                parent = parent.parentElement;
            }
            if (parent !== body) return 'outside body flow';
        }
        if (p.closest('[data-flow-latin]')) return 'already composed';
        if (p.matches('.abstract-title,.latex-runin-paragraph,[align]') || p.style.textAlign && p.style.textAlign !== 'justify') return 'aligned paragraph';
        if (!/^en(?:-|$)/i.test(p.closest('[lang]')?.lang || '')) return 'language';
        // Non-printing SVG style text can dwarf the visible paragraph. Classify
        // the graphic first so its font program never consumes the prose budget.
        if (p.querySelector('br,img,ruby,table,svg:not(.math-inline svg),.latex-hspace,.latex-graphic-box,.tikz-block,style:not(.math-inline *)'))
            return 'unsupported inline';
        const css = getComputedStyle(p);
        if (!(heading ? css.display === 'inline' : ['block','list-item'].includes(css.display)) || css.direction !== 'ltr' ||
            css.writingMode !== 'horizontal-tb' || css.textAlign !== 'justify') return 'paragraph layout';
        if (css.whiteSpace !== 'normal' || css.textTransform !== 'none' ||
            !['normal','0px'].includes(css.letterSpacing)) return 'paragraph text style';
        return faceFamily(css) === family ? null : 'body font';
    }
    function noteSkip(p,reason,category) {
        if (!diagnostics) return;
        summary.skipped.push({reason, category, text:p.textContent.trim().slice(0,160),
            parent:p.parentElement.tagName.toLowerCase(), parentClass:p.parentElement.className});
        if (!summary.firstSkippedStyle && ['paragraph layout','paragraph text style','body font'].includes(reason)) {
            const css = getComputedStyle(p);
            summary.firstSkippedStyle = {reason,display:css.display,direction:css.direction,writingMode:css.writingMode,
                textAlign:css.textAlign,whiteSpace:css.whiteSpace,textTransform:css.textTransform,
                letterSpacing:css.letterSpacing,fontFamily:css.fontFamily};
        }
    }
    // MathRenderer records boundaries in paint order and em units. The final
    // field encodes TeX's medium (4 +2 -4 mu) or thick (5 +5 mu) skip.
    function mathCapacity(atom) {
        const math = atom.matches('.math-inline') ? atom : atom.firstElementChild;
        const svg = math?.querySelector(':scope.math-inline > svg:only-child[data-math-glue]');
        if (!svg) return null;
        const [header,...fields] = svg.dataset.mathGlue.split(';');
        const [count,em] = header.split(',').map(Number);
        const glyphs = [...svg.children];
        if (!ctx || glyphs.length !== count || !(em > 0 && Number.isFinite(em)) || !fields.length ||
            glyphs.some(g => !g.matches('text,rect') || g.hasAttribute('transform') || g.children.length)) return null;
        const width = svg.getBoundingClientRect().width * rectToCSS, view = svg.viewBox.baseVal;
        if (!(width > 0 && view.width > 0)) return null;
        const unit = width / view.width, cuts = [];
        let stretch = 0, shrink = 0, previous = 0;
        for (const field of fields) {
            const [index,x,mu] = field.split(',').map(Number);
            if (!Number.isInteger(index) || index <= previous || index >= glyphs.length ||
                !Number.isFinite(x) || (mu !== 4 && mu !== 5)) return null;
            previous = index;
            const plus = (mu === 4 ? 2 : 5) * em/18, minus = (mu === 4 ? 4 : 0) * em/18;
            cuts.push({index,x:x*em,end:(x+mu/18)*em,plus,minus});
            stretch += plus * unit;
            shrink += minus * unit;
        }
        // A solid fraction or accent rule can move with its atom, provided
        // none of it spans an adjustable boundary. Backgrounds are never tagged.
        for (const glyph of glyphs) {
            if (glyph.localName !== 'rect') continue;
            const x = glyph.x.baseVal.value, right = x + glyph.width.baseVal.value;
            if (cuts.some(c => x < c.end-.00001 && right > c.x+.00001)) return null;
        }
        return {original:svg,width,viewWidth:view.width,unit,cuts,stretch,shrink};
    }
    function setMathWidth(formula, ratio) {
        const {svg,math} = formula, box = svg.viewBox.baseVal;
        if (ratio < -1 && math.shrink) throw Error('math glue below floor');
        const delta = ratio * (ratio > 0 ? math.stretch : math.shrink);
        formula.expected = math.width + delta;
        if (!delta) return;
        let shift = 0, next = 0;
        const glyphs = svg.children;
        let right = -Infinity, previousRight = -Infinity;
        for (let i = 0; i < glyphs.length; i++) {
            const cut = math.cuts[next];
            if (cut?.index === i) {
                shift += ratio * (ratio > 0 ? cut.plus : cut.minus);
                previousRight = right;
                next++;
            }
            const glyph = glyphs[i], rule = glyph.localName === 'rect';
            const x = (rule ? glyph.x.baseVal.value : glyph.x.baseVal.getItem(0).value) + shift;
            if (ratio < 0) {
                // Compare actual ink across the moving boundaries. Existing
                // overlaps within a base and its scripts belong to that atom.
                let left = x, end;
                if (rule) end = x + glyph.width.baseVal.value;
                else {
                    const css = getComputedStyle(glyph);
                    ctx.font = css.fontStyle + ' ' + css.fontWeight + ' 1000px ' + css.fontFamily;
                    const ink = ctx.measureText(glyph.textContent), scale = Number(glyph.getAttribute('font-size'))/1000;
                    left -= ink.actualBoundingBoxLeft * scale;
                    end = x + ink.actualBoundingBoxRight * scale;
                }
                if (left < previousRight - 0.00001) throw Error('math ink overlap');
                right = Math.max(right,end);
            }
            if (shift) glyph.setAttribute('x',x);
        }
        // Change both lengths by the same proportion. The glyphs keep their
        // original scale, baseline, height and relative order in the PDF stream.
        svg.setAttribute('viewBox',[box.x,box.y,math.viewWidth + delta/math.unit,box.height].join(' '));
        svg.style.width = formula.expected + 'px';
    }
    // A piece points into one original text node or owns one indivisible inline object.
    // An object has a sentinel in the planner, even for textless SVGs and destinations.
    // Neither that sentinel nor the lexical copy of its punctuation enters the DOM.
    let remainingWords = 65536, remainingNodes = 131072, remainingLines = 12000;
    function tokenize(p, parameters, followsGlue, gutter, contextGlue, allowMath) {
        const words = [], leading = [];
        const fontScale = parameters.fontSizePt ? parameters.fontSizePt / faceFor(p.closest('.footnotes') || p).em : texPointsPerPixel;
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
                if (latinNonLatinLetter.test(node.data) ||
                    /[\u202a-\u202e\u2066-\u2069]/u.test(node.data)) throw mixedScript(node.data);
                for (const token of node.data.matchAll(/[ \n\t\r\f]+|\u00a0|[^ \n\t\r\f\u00a0]+/g)) {
                    const piece = {owners,face,text:token[0]};
                    if (/^[ \n\t\r\f]/.test(token[0])) pending.push(piece);
                    else if (token[0] === '\u00a0') pending.push({...piece,tie:true});
                    else add(piece,token[0]);
                }
                return;
            }
            // The reader supplies the url package's breakpoints and already wraps
            // each protected run. A WBR carries neither glyphs nor word glue.
            if (node.nodeType === Node.ELEMENT_NODE && node.matches('a.latex-url > wbr')) {
                const separator = node.previousElementSibling?.textContent.at(-1);
                const urlPenalty = separator === '-' && !el.hasAttribute('data-latex-url-hyphens') ? null :
                    separator === '-' || separator === ':' ? 500 : 700;
                add({owners,face:faceFor(el),atom:node,width:0,urlPenalty},'\ufffc');
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
                        latinNonLatinLetter.test(child.data)) throw mixedScript(child.data);
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
            const math = allowMath && node.matches('.math-inline,[data-math-punctuation]') ? mathCapacity(node) : null;
            add({owners,face,atom:node,width,math},'\ufffc' + suffix);
            if (math) {
                word.mathStretch = (word.mathStretch || 0) + math.stretch;
                word.mathShrink = (word.mathShrink || 0) + math.shrink;
            }
        }
        for (const child of p.childNodes) if (child !== gutter) visit(child,[]);
        if (word) word.after = pending;
        if (!words.length) throw Error('empty');
        if (leading.some(part=>part.tie) || word.after.some(part=>part.tie)) throw Error('edge tie');
        for (const [index,w] of words.entries()) {
            const plainText = w.runs.every(run => !run.atom && !run.owners.some(el =>
                el.matches('.long-token') || el.matches('a') && /^\w+:\/\//.test(el.textContent)));
            w.breaks = automatic => {
                const points = w.runs.filter(run => run.urlPenalty != null).map(run => ({
                    offset:run.at+1,hyphen:false,penalty:run.urlPenalty,discretionary:false
                }));
                if (!plainText || /^\w+:\/\/|www\.|@|\/\/|^10\.\d{4,9}\//i.test(w.text)) return points;
                for (const m of w.text.matchAll(/[-–—\u00ad]/g)) {
                    if (m.index + 1 < w.text.length) points.push({offset:m.index+1, hyphen:m[0] === '\u00ad'});
                }
                const letters = /^([A-Za-z]+)[.,!?:;”’"')\]]*$/.exec(w.text);
                // TeX scans letters in the same font. A comma in the surrounding
                // roman text must not prevent hyphenation of an italic title.
                const letterFace = w.runs[0].face;
                if (automatic && (index || followsGlue) && letters && w.runs.every(run =>
                    run.at >= letters[1].length || run.face.key === letterFace.key)) {
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
                const glueFamily = f.family === 'times' && contextGlue ? contextGlue : f.family;
                w.glue = latinGlue(glueFamily,f.fontStyle,+f.fontWeight,f.em,w.rawSpace,
                    controlSpace ? '' : w.text,parameters.frenchspacing,f.em * fontScale,
                    parameters.periodSpaceFactor,f.fontVariantCaps);
                // A bibliography block skip follows (and adds to) an ordinary
                // space if the source contains both. WebKit collapses their two
                // source spaces, so paint their combined glue on one separator.
                const blocks = w.after.filter(piece => piece.owners.some(el => el.hasAttribute('data-latex-newblock')));
                if (blocks.length) {
                    if (blocks.length === w.after.length &&
                        !blocks.some(piece => piece.owners.some(el => el.dataset.latexNewblock === 'space'))) w.glue = [0,0,0];
                    for (const piece of blocks) {
                        const em = piece.face.em;
                        w.glue[0] += .11*em; w.glue[1] += .33*em; w.glue[2] += .07*em;
                    }
                }
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
            if (!index && !head && indent) {
                if (indent > 0) line.style.paddingInlineStart = indent + 'px';
                else line.style.marginInlineStart = indent + 'px';
            }
            if (part.hyphen) line.dataset.flowHyphen = '';
            fragment.append(line);
            const row = {line,part,gaps:[],formulas:[],pitch};
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
                        if (run.math) row.formulas.push({svg:clone.querySelector('svg'),math:run.math});
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
                    if (w.after.length !== 1 && !w.after.some(piece => piece.owners.some(el => el.hasAttribute('data-latex-newblock'))))
                        throw Error('ambiguous collapsed space');
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
                    if (w.after.length > 1) hidden(w.after.slice(1));
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
    // WebKit trims the top and bottom of a block independently. A probe
    // with the same strut and text-box-edge measures each boundary without
    // assuming that the font's cap and baseline coincide with CSS pixels.
    function trimmedPitch(css,face,trim) {
        useProbe(face);
        probe.style.lineHeight = css.lineHeight;
        probe.style.textBoxEdge = css.textBoxEdge;
        probe.style.textBoxTrim = trim;
        probe.textContent = 'x';
        const height = probe.getBoundingClientRect().height * rectToCSS;
        probe.style.removeProperty('text-box-trim');
        probe.style.removeProperty('text-box-edge');
        return height;
    }
    function lastGlyphInset(p) {
        const tree = document.createTreeWalker(p,NodeFilter.SHOW_TEXT);
        for (let n = tree.lastChild(); n; n = tree.previousNode()) {
            const last = n.data.trimEnd().length;
            // A trailing callout can occupy a native line on its own. Its own glyph
            // supplies the same vertical reference before and after composing.
            if (!last || n.parentElement.closest('[data-latex-probe],svg')) continue;
            if (n.parentElement.closest('sup,sub') && !n.parentElement.closest('.footnote-ref')) continue;
            range.setStart(n,last-1); range.setEnd(n,last);
            return (p.getBoundingClientRect().bottom-range.getBoundingClientRect().bottom) * rectToCSS;
        }
        return null;
    }
    function runInPitch(heading,p,width) {
        // A heading has its own strut. Measure it together with ordinary body
        // text; a tall formula on a later native line must not affect this pitch.
        const block = heading.parentElement, sample = block.cloneNode(false), prose = p.cloneNode(false);
        sample.style.cssText += ';position:absolute;visibility:hidden;margin:0;box-sizing:border-box;width:'+width+'px';
        prose.textContent = 'x';
        const container = p.parentElement === block ? prose : p.parentElement.cloneNode(false);
        if (container !== prose) container.append(prose);
        sample.append(heading.cloneNode(true),container);
        block.after(sample);
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
        const record = {text, category:trial.category, fallback:reason, lines, index:trial.index, renderedLineCount:lines.length};
        if (trial.boxDiagnostics) record.boxDiagnostics = trial.boxDiagnostics;
        if (trial.gutter) record.label = trial.gutter.textContent;
        if (trial.heading) record.runInHeading = trial.heading.textContent;
        if (trial.runInGeometry) record.runInGeometry = trial.runInGeometry;
        summary.paragraphs.push(record);
        if (reason) fallbackRows.push([trial.block || trial.p, record]);
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
        if (trial.trim || trial.trimBoth) {
            if (trial.oldStyle === null) trial.p.removeAttribute('style');
            else trial.p.setAttribute('style',trial.oldStyle);
        }
    }
    function geometry(row, naturalTrial) {
        if (row.runIn) {
            // The first row shares its native inline formatting context with the
            // heading and the class's horizontal afterskip. Its line box extends
            // from the wrapper's top to the next block line, including its leading.
            const block = row.runIn.block.getBoundingClientRect();
            const bottom = row.line.nextElementSibling?.getBoundingClientRect().top ?? block.bottom;
            let width = (row.end.getBoundingClientRect().left-block.left)*rectToCSS-row.runIn.left;
            if (naturalTrial && row.runIn.headingMargin != null) {
                // On Sequoia the first glyph of a hanging term can move when the DD gains explicit lines.
                // Fit the glue to the restored position, then check the final layout against the native one.
                const head = firstGlyphRect(naturalTrial.heading);
                if (head) {
                    const offset = row.runIn.left - (head.left-block.left)*rectToCSS;
                    if (Math.abs(offset) > .1 && Math.abs(offset) <= 1) {
                        naturalTrial.headingOffset = offset;
                        width += offset;
                    }
                }
            }
            return {height:(bottom-block.top)*rectToCSS, measure:block.width*rectToCSS-row.runIn.left,width};
        }
        const r = row.line.getBoundingClientRect();
        const indent = parseFloat(row.line.style.paddingInlineStart) || 0;
        return {height:r.height * rectToCSS, measure:r.width * rectToCSS - indent,
            width:(row.end.getBoundingClientRect().left-r.left) * rectToCSS - indent};
    }
    function bibliographyMeasure(p, words, deadline) {
        const widths = new Map();
        return part => {
            const key = [part.startWord,part.startOffset,part.endWord,part.endOffset,part.hyphen].join('/');
            if (widths.has(key)) return widths.get(key);
            if (widths.size >= 64 || performance.now() > deadline) throw Error('composition budget');
            const sample = document.createElement('span');
            sample.dataset.flowLatin = '';
            sample.style.cssText = 'position:absolute;visibility:hidden;display:block;width:max-content;pointer-events:none';
            const {fragment,rows} = assemble({words,leading:[]},{lines:[part]},0,0);
            sample.append(fragment);
            p.append(sample);
            try {
                const {width} = geometry(rows[0]);
                widths.set(key,width);
                return width;
            } finally { sample.remove(); }
        };
    }
    function mixedScript(text) {
        const error = Error('mixed script');
        if (diagnostics) {
            const letter = latinNonLatinLetter.exec(text)?.[0];
            const match = letter ?? /[\u202a-\u202e\u2066-\u2069]/u.exec(text)?.[0];
            if (match) error.cause = (letter ? 'letter' : 'bidi') + ' U+' + match.codePointAt(0).toString(16);
        }
        return error;
    }
    function recordException(error) {
        if (diagnostics && !summary.firstException) {
            summary.firstException = String(error) + (error?.cause ? ' (' + error.cause + ')' : '')
                + (error?.stack ? '\n' + error.stack : '');
        }
    }
    function eachTrial(perform) {
        for (const trial of pending) {
            if (trial.reason) continue;
            try {
                if (performance.now() > deadline) throw Error('composition budget');
                perform(trial);
            } catch (error) { recordException(error); trial.reason = error.message || 'DOM measurement'; }
        }
    }
    try {
        let ordinal = 0;
        for (const p of body.querySelectorAll(paragraphSelector)) {
            const mathIndex = ordinal++, allowMath = !rigidMath?.has(mathIndex);
            const category = contextOf(p);
            if (!category) {
                if (diagnostics) noteSkip(p,'unclassified paragraph',null);
                continue;
            }
            const definition = category === 'description' ? p.closest('dd') : null;
            const term = definition?.previousElementSibling;
            const heading = term && (p === definition || p === definition.firstElementChild) &&
                getComputedStyle(term).display === 'inline' ? term : runInHeading(p);
            const exclusion = excluded(p,heading,category);
            if (exclusion) { noteSkip(p,exclusion,category); continue; }
            const gutter = p.firstChild?.matches?.(gutterSelector) ? p.firstChild : null;
            const block = heading ? heading.parentElement : p;
            const text = gutter ? [...p.childNodes].filter(n => n !== gutter).map(n => n.textContent).join('') : p.textContent;
            const index = summary.qualifying++;
            const paragraphDeadline = Math.min(deadline, performance.now()+250);
            let boxDiagnostics;
            try {
                if (text.length + (heading?.textContent.length ?? 0) > 18000 || remainingWords <= 0 || remainingNodes <= 0 ||
                    remainingLines <= 0 || performance.now() > deadline) throw Error('composition budget');
                const settings = p.closest('[data-latex-line-parameters]')?.dataset.latexLineParameters;
                const parameters = Object.assign(family === 'times' ? {tolerance:9999,emergencystretch:'3em'} : {},
                    settings ? JSON.parse(settings) : {}, contextParameters[category]);
                const contextGlue = category === 'body' ? null : body.dataset.latexContextGlue;
                const prose = tokenize(p,parameters,!!heading,gutter,contextGlue,allowMath);
                const head = heading ? tokenize(heading,parameters,false,null,contextGlue,allowMath) : null;
                const words = head ? [...head.words,...prose.words] : prose.words;
                const css = getComputedStyle(p), blockStyle = getComputedStyle(block), rect = block.getBoundingClientRect();
                const inset = ['paddingLeft','paddingRight','borderLeftWidth','borderRightWidth']
                    .reduce((sum,k) => sum + (parseFloat(blockStyle[k]) || 0),0);
                let width = rect.width * rectToCSS - inset;
                let indent = parseFloat(css.textIndent), runIn, noteGutter = 0;
                if (category === 'footnote' && parameters.paragraphIndentEm != null) {
                    // The native OL reserves the number gutter on every line. The
                    // class puts its rigid mark on the first line only; keep the
                    // OL and mark in place and let the lines use that extra measure.
                    const item = p.closest('li'), list = item.parentElement;
                    const isFirst = item === p || item.firstElementChild === p;
                    if (parameters.firstIndentEm != null) {
                        noteGutter = parseFloat(getComputedStyle(list).paddingInlineStart) || 0;
                        width += noteGutter;
                    }
                    const indentEm = isFirst ? parameters.firstIndentEm : parameters.paragraphIndentEm;
                    if (indentEm != null) indent = indentEm * faceFor(p).em;
                    if (!isFirst && p.classList.contains('latex-noindent')) indent = 0;
                }
                let gutterAdvance = 0, labelPosition;
                if (gutter) {
                    const g = getComputedStyle(gutter), r = gutter.getBoundingClientRect();
                    if (g.position !== 'absolute') {
                        gutterAdvance = r.width * rectToCSS + parseFloat(g.marginInlineStart) + parseFloat(g.marginInlineEnd);
                    }
                    range.selectNodeContents(gutter);
                    const ink = range.getBoundingClientRect();
                    labelPosition = {x:r.left-rect.left,y:r.top-rect.top,ink:ink.left-rect.left};
                }
                if (heading) {
                    const first = firstGlyphRect(p), headRect = firstGlyphRect(heading);
                    if (!first || !headRect || heading.getClientRects().length !== 1 ||
                        Math.abs(first.top-headRect.top) * rectToCSS > parseFloat(css.lineHeight)/2)
                        throw Error('wrapped run-in heading');
                    // The horizontal skip after a run-in heading or description term
                    // belongs to the class. Interior label spaces participate in justification.
                    const skip = parseFloat(getComputedStyle(definition || p).marginInlineStart);
                    head.words.at(-1).glue = [skip,0,0];
                    const left = (headRect.left-rect.left)*rectToCSS;
                    indent = left - (parseFloat(blockStyle.paddingInlineStart) || 0);
                    runIn = {block,rise:(first.top-headRect.top)*rectToCSS, left, skip};
                    // The first DD fragment starts after the native inline margin. Sequoia
                    // snaps that fragment edge even when the computed margin is fractional.
                    if (definition && latinMeasureDescriptionGap) {
                        runIn.specifiedSkip = skip;
                        runIn.headingMargin = parseFloat(getComputedStyle(heading).marginInlineStart) || 0;
                        runIn.skip = (definition.getClientRects()[0].left - heading.getBoundingClientRect().right) * rectToCSS;
                    }
                }
                const planIndent = indent + gutterAdvance;
                if (!(width > 0 && Number.isFinite(planIndent) && Math.abs(planIndent) < width)) throw Error('invalid measure');
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
                const key = JSON.stringify([category,width,planIndent,head?.words.length ?? 0,parameters,fonts,words.map(w =>
                    [w.text,!!w.noBreakAfter,...w.glue,...w.runs.map(r => [r.at,fontIDs.get(r.face.key),r.width ?? null,r.urlPenalty ?? null,r.math?.stretch,r.math?.shrink,
                        r.owners.some(el => el.matches('.long-token') || el.matches('a') && /^\w+:\/\//.test(el.textContent))])])]);
                let plan = cache.plans.get(key);
                if (plan === undefined) {
                    const exact = category === 'bibliography' ? bibliographyMeasure(p,words,paragraphDeadline) : null;
                    plan = latinBreakPlan(words,width,planIndent,parameters,exact);
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
                // The DD can have further paragraphs under the same description
                // term. Only this paragraph contributes to its native line budget.
                const originalLines = nativeLines(definition ? p : block,pitch);
                if (category === 'caption' && originalLines === 1) {
                    summary.qualifying--; noteSkip(p,'single-line caption',category); continue;
                }
                if (diagnostics && globalThis.surimonoLatinBoxDiagnostics) {
                    boxDiagnostics = {width,...(allowMath ? {} : {rigidMathForSearch:true}),indent:planIndent,parameters,nativeLines:originalLines,pass:plan?.pass ?? null,
                        originalHeight:rect.height*rectToCSS, textBoxTrim:css.textBoxTrim,
                        ratios:plan?.lines.map(l=>l.ratio) ?? [],words:words.map(w => ({
                            text:w.runs.map(r=>r.atom ? r.atom.textContent : r.text).join(''),width:w.width,
                            glue:w.glue,noBreakAfter:!!w.noBreakAfter,
                            ...(w.mathStretch ? {mathStretch:w.mathStretch,mathShrink:w.mathShrink} : {})}))};
                }
                // text-box-trim removes leading at the native paragraph boundary.
                // With end trim only, the original text block supplies that last
                // line's actual height independently of how many lines we compose.
                let firstPitch, finalPitch, finalInset, firstInset;
                if (category !== 'body' && !heading && css.textBoxTrim === 'none' && originalLines === 1 && !parseFloat(css.minBlockSize)) {
                    // A completely bold quote can have a taller native line than
                    // an upright probe. Its original single line is itself the
                    // exact reference for the height and both glyph insets.
                    const edges = ['paddingTop','paddingBottom','borderTopWidth','borderBottomWidth']
                        .reduce((sum,k) => sum + (parseFloat(css[k]) || 0),0);
                    finalPitch = rect.height*rectToCSS - edges;
                    firstInset = firstGlyph(p);
                    finalInset = lastGlyphInset(p);
                }
                if (!heading && css.textBoxTrim === 'trim-both' && originalLines) {
                    firstPitch = trimmedPitch(css,face,'trim-start');
                    finalPitch = trimmedPitch(css,face,'trim-end');
                    if (plan?.lines.length === 1) finalPitch = trimmedPitch(css,face,'trim-both');
                    firstInset = firstGlyph(p);
                    finalInset = lastGlyphInset(p);
                }
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
                for (const [i,row] of rows.entries()) {
                    row.expectedMeasure = width - (i === 0 ? indent : 0);
                    if (noteGutter) row.line.style.marginInlineStart = -noteGutter + 'px';
                }
                if (p.matches('figcaption')) {
                    // fit-content would shrink to the longest newly imposed line
                    // while measuring its natural glue. Keep the original width
                    // on the child: class trim rules can depend on figcaption:not([style]).
                    rows[0].line.style.boxSizing = 'border-box';
                    rows[0].line.style.inlineSize = width + 'px';
                }
                if (head && headContent.textContent !== heading.textContent) throw Error('content mismatch');
                if (runIn) {
                    rows[0].runIn = runIn;
                    rows[0].pitch = runInPitch(heading,p,width);
                }
                if (firstPitch !== undefined) rows[0].pitch = firstPitch;
                if (finalPitch !== undefined) rows.at(-1).pitch = finalPitch;
                if (fragment.textContent !== text) throw Error('content mismatch');
                if (gutter) {
                    // text-align-last inherits into an inline-block. Retain the native
                    // alignment of the glyph within its gutter, as well as its box.
                    const label = gutter.cloneNode(true), style = getComputedStyle(gutter);
                    label.style.textAlignLast = style.textAlignLast;
                    label.style.wordSpacing = style.wordSpacing;
                    if (noteGutter && gutter.matches('.latex-symbolic-note')) {
                        label.style.position = 'relative';
                        label.style.insetInlineStart = noteGutter - indent + parseFloat(css.textIndent) + 'px';
                    }
                    rows[0].line.prepend(label);
                    if (fragment.textContent !== p.textContent) throw Error('content mismatch');
                }
                if (performance.now() > paragraphDeadline) throw Error('composition budget');
                const initialPadding = parseFloat(css.paddingBlockStart);
                const first = css.textBoxTrim === 'trim-start' && initialPadding > 0 ? firstGlyph(p) : null;
                pending.push({p,index,mathIndex,text,category,block,gutter,labelPosition,heading,runIn,headContent,originalHeading:heading && [...heading.childNodes],
                    oldHeadingStyle:heading?.getAttribute('style'),rows,fragment,boxDiagnostics,original:[...p.childNodes],oldStyle:p.getAttribute('style'),
                    trim:first !== null, trimBoth:firstPitch !== undefined && !!css.getPropertyValue('--cm-strut-ascent'), first, firstInset, initialPadding, finalInset});
            } catch (error) {
                recordException(error);
                if (unsupported.has(error.message)) { summary.qualifying--; noteSkip(p,error.message,category); }
                else finish({index,p,category,block,gutter,heading,boxDiagnostics},text,String(error.message));
            }
        }
        // Layout in batches across the document. Alternating writes and natural-width
        // reads for every paragraph makes a hundred-page flow quadratic in WebKit.
        eachTrial(trial => {
            trial.installed = true;
            trial.p.dataset.flowLatin = '';
            if (trial.trim || trial.trimBoth) trial.p.style.setProperty('text-box-trim','none','important');
            if (trial.trimBoth) {
                // The paragraph's padding prevents trim from reaching the nested block lines.
                const first = trial.rows[0].line, last = trial.rows.at(-1).line;
                first.style.textBoxTrim = first === last ? 'trim-both' : 'trim-start';
                if (first !== last) last.style.textBoxTrim = 'trim-end';
            }
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
                const {width,measure} = geometry(row,trial);
                const last = row === trial.rows.at(-1);
                row.delta = last && width <= measure ? 0 : measure-width;
                row.axis = row.delta < 0 ? 2 : 1;
                const capacity = row.gaps.reduce((sum,g) => sum + g.glue[row.axis],0) +
                    row.formulas.reduce((sum,f) => sum + (row.axis === 1 ? f.math.stretch : f.math.shrink),0);
                if ((Math.abs(row.delta) > .03 && !capacity) || row.delta < -capacity - .00001) {
                    trial.reason = 'DOM glue capacity'; break;
                }
                row.ratio = capacity ? row.delta / capacity : 0;
            }
        });
        eachTrial(trial => {
            if (trial.headingOffset) trial.heading.style.marginInlineStart = (trial.runIn.headingMargin + trial.headingOffset) + 'px';
            if (trial.trim) trial.p.style.setProperty('padding-block-start',trial.padding+'px','important');
            for (const row of trial.rows) {
                for (const formula of row.formulas) setMathWidth(formula,row.ratio);
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
            if (trial.gutter) {
                const label = trial.p.querySelector(gutterSelector), block = trial.block.getBoundingClientRect();
                const r = label.getBoundingClientRect();
                range.selectNodeContents(label);
                const ink = range.getBoundingClientRect();
                if (Math.max(Math.abs(r.left-block.left-trial.labelPosition.x),
                    Math.abs(r.top-block.top-trial.labelPosition.y),Math.abs(ink.left-block.left-trial.labelPosition.ink)) * rectToCSS > .5) {
                    trial.reason = 'label position'; return;
                }
            }
            if (trial.runIn) {
                const head = firstGlyphRect(trial.heading), first = firstGlyphRect(trial.p);
                const block = trial.block.getBoundingClientRect();
                // Glyph ranges snap to layout pixels even at a fractional CSS
                // margin. The inline boxes enclose the actual fixed afterskip.
                const gapError = (trial.rows[0].line.getClientRects()[0].left -
                    trial.heading.getBoundingClientRect().right)*rectToCSS-trial.runIn.skip;
                const riseError = head && first ? (first.top-head.top)*rectToCSS - trial.runIn.rise : Infinity;
                const leftError = head ? (head.left-block.left)*rectToCSS - trial.runIn.left : Infinity;
                const misaligned = Math.max(Math.abs(riseError),Math.abs(leftError),Math.abs(gapError)) > .1 || !first || !head;
                if (trial.boxDiagnostics || (diagnostics && misaligned)) {
                    trial.runInGeometry = {gapError,riseError,leftError,afterSkip:trial.runIn.specifiedSkip ?? trial.runIn.skip,
                        nativeSkip:trial.runIn.skip,rectToCSS,glyphGap:runInGap(trial.p,trial.heading)};
                    if (trial.runIn.headingMargin != null) trial.runInGeometry.headingOffset = trial.headingOffset ?? 0;
                }
                if (misaligned) {
                    trial.reason = 'run-in baseline'; return;
                }
            }
            if (trial.trim && Math.abs(firstGlyph(trial.p)-trial.first) > .05 ||
                trial.firstInset != null && Math.abs(firstGlyph(trial.p)-trial.firstInset) > .06) {
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
                if (row.formulas.some(f => Math.abs(f.svg.getBoundingClientRect().width * rectToCSS - f.expected) > .02)) {
                    trial.reason = 'math width'; break;
                }
                if (Math.abs(height-row.pitch) > .06 || !Number.isFinite(row.pitch)) {
                    if (trial.boxDiagnostics) trial.boxDiagnostics.pitch = {height,expected:row.pitch,
                        row:trial.rows.indexOf(row),text:row.line.textContent,rows:trial.rows.length};
                    trial.reason = 'line pitch'; break;
                }
                if (Math.abs(row.expectedMeasure-measure) > .32 || width > measure + .32 ||
                    !last && Math.abs(measure-width) > .32) {
                    if (trial.boxDiagnostics) trial.boxDiagnostics.edge = {width,measure,expected:row.expectedMeasure};
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
                    const lineText = trial.gutter && row === trial.rows[0] ? row.line.textContent.slice(trial.gutter.textContent.length) : row.line.textContent;
                    const text = lineText.trim(), words = text.split(/\s+/);
                    trial.lines.push({text,first:words[0],last:words.at(-1),hyphen:row.part.hyphen,
                        ratio:row.ratio,measure,width,height,pitch:row.pitch,
                        minSpaceSlack:Number.isFinite(minSpaceSlack) ? minSpaceSlack : null});
                }
            }
        });
    } catch (error) {
        recordException(error);
        for (const trial of pending) trial.reason ??= 'DOM measurement';
    } finally {
        for (const trial of pending) {
            if (trial.reason) {
                if (trial.installed) rollback(trial);
            } else {
                if (restorations) restorations.push(() => rollback(trial));
                if (globalThis.surimonoCheckMathSearch && !rigidMath) {
                    for (const row of trial.rows) for (const f of row.formulas) {
                        if (f.expected !== f.math.width) proofs.push({index:trial.mathIndex,old:f.math.original,svg:f.svg});
                    }
                }
            }
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
