// Liang's weights are maxima at inter-letter positions; an odd winner permits a break.
// Keep the shipped TeX file intact. Only its parsed representation is shared between documents.
function latinHyphenator(source, overrides = '') {
    function exceptions(text, map) {
        for (const entry of text.toLowerCase().split(/\s+/)) {
            if (!/^[a-z]+(?:-[a-z]+)*$/.test(entry)) continue;
            const word = entry.replaceAll('-', '');
            let offset = 0;
            const points = [];
            for (const letter of entry) {
                if (letter !== '-') offset++;
                else if (offset >= 2 && word.length - offset >= 3) points.push(offset);
            }
            map.set(word, points);
        }
    }
    let dictionary = latinHyphenator.dictionary;
    if (dictionary?.source !== source) {
        const clean = source.replace(/%[^\n]*/g, '');
        const patterns = clean.match(/\\patterns\s*\{([^}]*)\}/)?.[1];
        if (!patterns) throw Error('Missing Plain TeX hyphenation patterns');
        const trie = new Map(), defaults = new Map();
        for (const pattern of patterns.trim().split(/\s+/)) {
            let node = trie;
            const weights = [0];
            for (const char of pattern) {
                if (char >= '0' && char <= '9') weights[weights.length - 1] = Number(char);
                else {
                    if (!node.has(char)) node.set(char, new Map());
                    node = node.get(char);
                    weights.push(0);
                }
            }
            node.set('', weights);
        }
        exceptions(clean.match(/\\hyphenation\s*\{([^}]*)\}/)?.[1] ?? '', defaults);
        dictionary = {source, trie, defaults};
        latinHyphenator.dictionary = dictionary;
    }
    const local = new Map(), cache = new Map();
    exceptions(overrides, local);
    return value => {
        const word = value.toLowerCase();
        // TeX's hyphenation buffer holds at most 63 letters.
        if (!/^[a-z]{5,63}$/.test(word)) return [];
        const known = local.get(word) ?? dictionary.defaults.get(word) ?? cache.get(word);
        if (known) return known;
        const padded = '.' + word + '.', scores = new Uint8Array(padded.length + 1);
        for (let i = 0; i < padded.length; i++) {
            let node = dictionary.trie;
            for (let j = i; j < padded.length; j++) {
                node = node.get(padded[j]);
                if (!node) break;
                const weights = node.get('');
                if (weights) {
                    for (let k = 0; k < weights.length; k++) {
                        scores[i+k] = Math.max(scores[i+k], weights[k]);
                    }
                }
            }
        }
        const points = [];
        for (let offset = 2; offset <= word.length - 3; offset++) {
            if (scores[offset+1] % 2) points.push(offset);
        }
        if (cache.size < 8192) cache.set(word, points);
        return points;
    };
}

// TFM fontdimen 2, 3, 4 and 7, in design-size units, from TeX Live 2026 (ptftopl).
// ptmr7t, ptmb7t, ptmri7t and ptmbi7t have identical glue. Glyphs use browser metrics.
const latinFontGlue = {
    cmr5: [0.472229, 0.208338, 0.138891, 0.138891],
    cmr6: [0.416661, 0.194443, 0.129628, 0.129628],
    cmr7: [0.384923, 0.184525, 0.123016, 0.123016],
    cmr8: [0.354172, 0.177086, 0.118057, 0.118057],
    cmr9: [0.34259, 0.171295, 0.114197, 0.114197],
    cmr17: [0.3018875, 0.156731, 0.104487, 0.104487],
    cmr10: [0.333334, 0.166667, 0.111112, 0.111112],
    cmbx5: [0.516657, 0.241663, 0.161108, 0.161108],
    cmbx6: [0.468516, 0.224998, 0.149999, 0.149999],
    cmbx7: [0.434126, 0.213096, 0.142064, 0.142064],
    cmbx8: [0.408337, 0.204168, 0.136112, 0.136112],
    cmbx9: [0.39444, 0.19722, 0.13148, 0.13148],
    cmbx10: [0.383331, 0.191666, 0.127777, 0.127777],
    cmti7: [0.426989, 0.176193, 0.117462, 0.117462],
    cmti8: [0.384029, 0.164583, 0.109722, 0.109722],
    cmti9: [0.36729, 0.15741, 0.104939, 0.104939],
    cmti10: [0.357776, 0.153333, 0.1022215, 0.1022215],
    cmr12: [0.3263855, 0.163193, 0.108795, 0.108795],
    cmbx12: [0.375, 0.1875, 0.125, 0.125],
    cmti12: [0.350003, 0.150002, 0.100001, 0.100001],
    cmsl8: [0.354172, 0.177086, 0.118057, 0.118057],
    cmsl9: [0.34259, 0.171295, 0.114197, 0.114197],
    cmsl10: [0.333334, 0.166667, 0.111112, 0.111112],
    cmsl12: [0.3263855, 0.163193, 0.108795, 0.108795],
    cmbxsl10: [0.383331, 0.191666, 0.127777, 0.127777],
    cmss17: [0.313462, 0.156731, 0.104487, 0.104487],
    cmssbx10: [0.366669, 0.183334, 0.122223, 0.122223],
    cmbxti10: [0.414441, 0.176664, 0.117777, 0.117777],
    cmcsc10: [0.377774, 0.174998, 0.116666, 0.116666],
    cmtt8: [0.531258, 0.0, 0.0, 0.531258],
    cmtt9: [0.524994, 0.0, 0.0, 0.524994],
    cmtt12: [0.514584, 0.0, 0.0, 0.514584],
    cmtt10: [0.524996, 0, 0, 0.524996],
    // ntx-{Regular,Bold,Italic,BoldItalic}-tlf-t1 share these fontdimens.
    newtx: [0.25, 0.2, 0.1, 0.111],
    ptmr7t: [0.25, 0.15, 0.0599985, 0.0599985],
};
function latinGlue(family, style, weight, em, rawSpace, precedingText, french, sizePt = 10, periodSpaceFactor = 3000, caps = 'normal') {
    const face = family.split(',')[0].replace(/["']/g, '').trim().toLowerCase();
    // NFSS ladders in ot1cmr.fd, ot1cmss.fd and ot1cmtt.fd select optical designs. The
    // nearest nominal size tolerates fractional CSS font sizes at print zoom.
    const design = sizePt < 9.5 ? Math.max(5, Math.round(sizePt)) :
        sizePt < 11.475 ? 10 : sizePt < 15.84 ? 12 : 17;
    const bold = Number(weight) >= 600 || weight === 'bold';
    let metrics;
    if (face === 'surimono computer modern' || face === 'katex_main' || face === 'cm') {
        const italic = style === 'italic';
        const slanted = style.startsWith('oblique');
        const shape = bold ? (italic ? 'cmbxti' : 'cmbx') : (italic ? 'cmti' : 'cmr');
        const size = bold && italic ? 10 : italic ? Math.max(7, Math.min(12,design)) :
            bold ? Math.min(12,design) : design;
        if (!bold && !italic && caps === 'small-caps') metrics = latinFontGlue.cmcsc10;
        else if (slanted) metrics = latinFontGlue[bold ? 'cmbxsl10' : 'cmsl' + Math.max(8,Math.min(12,design))];
        else metrics = latinFontGlue[shape + size];
    } else if (face === 'sans' || face === 'surimono computer modern sans') {
        // cmss and cmssi match cmr's glue at 8–12pt; cmss17 and the bold face differ.
        metrics = bold ? latinFontGlue.cmssbx10 : design === 17 ? latinFontGlue.cmss17 : latinFontGlue['cmr' + Math.max(8,design)];
    } else if (face === 'times' || face === 'times new roman') metrics = latinFontGlue.ptmr7t;
    else if (face === 'newtx') metrics = latinFontGlue.newtx;
    else if (face === 'surimono computer modern typewriter' || face === 'typewriter')
        metrics = latinFontGlue['cmtt' + (style === 'normal' ? Math.max(8,Math.min(12,design)) : 10)];
    const [space, stretch, shrink, extra] = metrics ? metrics.map(v => v * em) :
        [rawSpace, rawSpace/2, rawSpace/3, rawSpace/3];
    // Closing quotation marks and parentheses retain the preceding character's space factor.
    const end = precedingText.replace(/['"’”\])]+$/u, '');
    const punctuation = end.slice(-1);
    let factor = 1000;
    if (!french && !/[A-Z][.!?:;,]$/.test(end)) {
        factor = ({'.':periodSpaceFactor, '?':3000, '!':3000, ':':2000, ';':1500, ',':1250})[punctuation] ?? 1000;
    }
    return [space + (factor >= 2000 ? extra : 0), stretch * factor / 1000, shrink * 1000 / factor];
}

const latinDefaults = {
    pretolerance:100, tolerance:200, hyphenpenalty:50, exhyphenpenalty:50, linepenalty:10,
    adjdemerits:10000, doublehyphendemerits:10000, finalhyphendemerits:5000, emergencystretch:0,
};
function latinDemerits(previous, fitness, badness, penalty, discretionary, final, params) {
    const base = params.linepenalty + badness;
    let value = previous.cost + (Math.abs(base) >= 10000 ? 100000000 : base * base);
    if (penalty >= 0) value += penalty * penalty;
    else if (penalty > -10000) value -= penalty * penalty;
    if (Math.abs(previous.fitness - fitness) > 1) value += params.adjdemerits;
    if (previous.discretionary) {
        if (final) value += params.finalhyphendemerits;
        else if (discretionary) value += params.doublehyphendemerits;
    }
    return value;
}

function latinBreakPlan(words, width, indent, parameters = {}, measureNatural = null) {
    if (!words.length || words.length > 4096 || !(width > 0)) return null;
    const params = {...latinDefaults, ...parameters};
    // Prefix totals include the glue following each word. The end of a line discards it.
    const advance = [0], stretch = [0], shrink = [0];
    for (const word of words) {
        const [g, plus, minus] = word.glue;
        if (![word.width, g, plus, minus].every(Number.isFinite) || g < minus || minus < 0 || plus < 0) return null;
        advance.push(advance.at(-1) + word.width + g);
        stretch.push(stretch.at(-1) + plus + (word.mathStretch || 0));
        shrink.push(shrink.at(-1) + minus + (word.mathShrink || 0));
    }

    let remaining = 150000;
    for (let pass = 1; pass <= 3; pass++) {
        const threshold = Math.min(10000, pass === 1 ? params.pretolerance : params.tolerance);
        if (threshold < 0 || (pass === 3 && !(params.emergencystretch > 0))) continue;
        const emergency = pass === 3 ? params.emergencystretch : 0;
        let active = [{word:0, offset:0, after:0, cost:0, fitness:1, discretionary:false, previous:null}];
        for (let i = 0; i < words.length && active.length; i++) {
            const word = words[i], length = word.text.length;
            // A completed prefix cannot become narrower by appending more words. Keep starts
            // within this word: shaping across its internal breaks is measured independently.
            active = active.filter(start => start.word >= i ||
                advance[i] - start.after - (shrink[i] - shrink[start.word]) <= width - (start.previous ? 0 : indent) + (measureNatural ? 1 : 0));
            if (!active.length) break;
            const points = word.breaks(pass > 1 && i > 0);
            for (const point of [...points, {offset:length, hyphen:false}]) {
                const end = point.offset, inner = end !== length, final = !inner && i === words.length - 1;
                // A TeX tie has ordinary stretch and shrink but forbids the break before that glue.
                if (!inner && !final && word.noBreakAfter) continue;
                if (inner && (end <= 0 || end > length)) continue;
                const penalty = final ? -10000 : !inner ? 0 :
                    point.penalty ?? (point.hyphen ? params.hyphenpenalty : params.exhyphenpenalty);
                const discretionary = inner && point.discretionary !== false;
                if (penalty >= 10000) continue;
                const best = [null, null, null, null];
                const prefixWidth = inner ? word.fragment(0, end, point.hyphen) : word.width;
                for (const start of active) {
                    if (--remaining < 0) return null;
                    if (start.word > i || (start.word === i && start.offset >= end)) continue;
                    const sameFragment = start.word === i && start.offset > 0;
                    const natural = sameFragment ? word.fragment(start.offset, end, point.hyphen) :
                        advance[i] - start.after + prefixWidth;
                    const measure = width - (start.previous ? 0 : indent);
                    let delta = measure - natural;
                    let minus = shrink[i] - shrink[start.word] + (word.mathShrink || 0);
                    let plus = stretch[i] - stretch[start.word] + (word.mathStretch || 0);
                    // URL penalties may split a word adjacent to a formula. Charge
                    // only the inline objects actually present in the fragment.
                    if (inner && word.mathStretch) {
                        for (const run of word.runs) if (run.math && run.at >= end) {
                            minus -= run.math.shrink; plus -= run.math.stretch;
                        }
                    }
                    if (start.offset && words[start.word].mathStretch) {
                        for (const run of words[start.word].runs) if (run.math && run.at < start.offset) {
                            minus -= run.math.shrink; plus -= run.math.stretch;
                        }
                    }
                    // Inline layout rounds adjacent advances differently from isolated
                    // boxes. Near the shrink floor, use the natural span the renderer
                    // actually lays out. The floor itself has no rounding allowance.
                    if (measureNatural && delta < 0 && Math.abs(delta + minus) <= 1) {
                        delta = measure - measureNatural({startWord:start.word,startOffset:start.offset,
                            endWord:i,endOffset:end,hyphen:point.hyphen});
                    }
                    if (delta < -minus || (!final && delta > 0 && plus <= 0)) continue;
                    const ratio = delta < 0 ? delta / minus : final || !delta ? 0 : delta / plus;
                    const badness = final && delta >= 0 ? 0 : texBadness(delta, delta < 0 ? minus : plus + emergency);
                    if (badness > threshold) continue;
                    const fitness = delta < 0 ? (badness > 12 ? 0 : 1) : badness > 99 ? 3 : badness > 12 ? 2 : 1;
                    const cost = latinDemerits(start, fitness, badness, penalty, discretionary, final, params);
                    // TeX replaces best_place on equal minimal_demerits too.
                    if (!best[fitness] || cost <= best[fitness].cost) {
                        best[fitness] = {cost, fitness, previous:start, discretionary,
                            line:{startWord:start.word, startOffset:start.offset, endWord:i, endOffset:end, hyphen:point.hyphen, ratio}};
                    }
                }
                if (final) {
                    const last = best.filter(Boolean).sort((a,b) => a.cost - b.cost)[0];
                    if (!last) break;
                    const lines = [];
                    for (let node = last; node.previous; node = node.previous) lines.push(node.line);
                    return {pass, lines:lines.reverse()};
                }
                if (penalty <= -10000) active = [];
                for (const node of best) {
                    if (!node) continue;
                    // The remainder of a hyphenated word shapes as a fresh run on the next line.
                    node.word = inner ? i : i+1;
                    node.offset = inner ? end : 0;
                    node.after = inner ? advance[i] + word.width - word.fragment(end, length, false) : advance[i+1];
                    active.push(node);
                }
            }
        }
    }
    return null;
}
