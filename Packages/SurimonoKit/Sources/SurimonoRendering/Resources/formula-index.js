// The index print sees the same composed glyph positions as the paper, including adjusted inline math glue.
const context = document.createElement('canvas').getContext('2d');
const sources = [];
const serializer = new XMLSerializer();
const make = name => document.createElementNS('http://www.w3.org/2000/svg', name);
const paintAttributes = ['x', 'y', 'width', 'height', 'x1', 'y1', 'x2', 'y2', 'd', 'font-family', 'font-size',
    'font-weight', 'font-style', 'dominant-baseline', 'fill-rule', 'stroke-width', 'stroke-dasharray',
    'stroke-linecap', 'stroke-linejoin'];

function corners(left, top, right, bottom, matrix) {
    const points = [new DOMPoint(left, top), new DOMPoint(right, top),
        new DOMPoint(left, bottom), new DOMPoint(right, bottom)].map(p => p.matrixTransform(matrix));
    return [Math.min(...points.map(p => p.x)), Math.min(...points.map(p => p.y)),
        Math.max(...points.map(p => p.x)), Math.max(...points.map(p => p.y))];
}

function copyPaint(item, output, inverse) {
    // Only the renderer's drawing primitives are meaningful. Document HTML can imitate a formula.
    const node = make(item.localName);
    for (const name of paintAttributes) {
        if (item.hasAttribute(name)) node.setAttribute(name, item.getAttribute(name));
    }
    for (const name of ['fill', 'stroke']) {
        const color = item.getAttribute(name);
        if (color) node.setAttribute(name, /^(?:none|#[0-9a-f]+|rgba?\([\d., %]+\))$/i.test(color) ? color : 'black');
    }
    let bounds;
    if (item.localName === 'text') {
        if (!item.x.baseVal.numberOfItems || !item.y.baseVal.numberOfItems) return null;
        node.textContent = item.textContent;
        // The flow magnifies layout 32x. The SVG presentation size stays in user units.
        bounds = glyphInk(context, item, Number(item.getAttribute('font-size')));
    } else {
        const box = item.getBBox();
        const stroke = item.getAttribute('stroke');
        const pad = stroke && stroke !== 'none' ? parseFloat(item.getAttribute('stroke-width') || '1') / 2 : 0;
        bounds = [box.x - pad, box.y - pad, box.x + box.width + pad, box.y + box.height + pad];
    }
    const transform = inverse.multiply(item.getScreenCTM());
    const coefficients = ['a','b','c','d','e','f'].map(key => transform[key]).join(' ');
    if (coefficients !== '1 0 0 1 0 0') node.setAttribute('transform', 'matrix(' + coefficients + ')');
    output.append(node);
    return corners(...bounds, transform);
}

function entries(root, visit) {
    const selector = '.math.math-inline > svg[aria-label],.math.math-display > svg[aria-label]';
    const groups = new Set();
    const number = '.eqno,.latex-row-number,.latex-multline-number';
    for (const svg of root.querySelectorAll(selector)) {
        if (svg.closest(number + ',svg svg') || getComputedStyle(svg).visibility !== 'visible') continue;
        const matrix = svg.getScreenCTM(), box = svg.getBoundingClientRect();
        if (!matrix || !box.width || !box.height) continue;
        const group = svg.closest('[data-formula-group]');
        if (group && groups.has(group)) continue;
        if (group) groups.add(group);
        const rows = group ? [...group.querySelectorAll(selector)].filter(row => !row.closest(number)) : [svg];
        let source = svg.getAttribute('aria-label');
        const encoded = group?.dataset.formulaGroup ?? svg.dataset.formulaSource;
        if (encoded !== undefined) {
            try {
                const bytes = Uint8Array.from(atob(encoded), c => c.charCodeAt(0));
                source = new TextDecoder().decode(bytes);
            } catch { continue; }
        }
        const standalone = make('svg'), title = make('title');
        title.textContent = source;
        standalone.append(title);
        const labels = [], inverse = matrix.inverse();
        let left = Infinity, top = Infinity, right = -Infinity, bottom = -Infinity;
        for (const row of rows) {
            const tags = new Set((row.dataset.formulaTags || '').split(',').filter(Boolean).map(Number));
            const shapes = [...row.querySelectorAll('text,rect,path,line')].filter(el => !el.closest('defs,clipPath,foreignObject'));
            for (const [index, item] of shapes.entries()) {
                if (tags.has(index)) {
                    labels.push(item.getBoundingClientRect());
                    continue;
                }
                const ink = copyPaint(item, standalone, inverse);
                if (!ink) continue;
                left = Math.min(left, ink[0]); top = Math.min(top, ink[1]);
                right = Math.max(right, ink[2]); bottom = Math.max(bottom, ink[3]);
            }
        }
        if (!(right > left && bottom > top)) continue;
        // Half a renderer unit (about 0.5 pt at body size) protects antialiased edges.
        const width = right - left + 1, height = bottom - top + 1;
        standalone.setAttribute('viewBox', [left - 0.5, top - 0.5, width, height].join(' '));
        // A dark preview or a coloured slide must still show black ink on paper.
        const paper = make('rect');
        for (const [key, value] of Object.entries({ x: left - 0.5, y: top - 0.5, width, height, fill: 'white' })) {
            paper.setAttribute(key, value);
        }
        title.after(paper);

        const parent = group ?? svg.parentElement, line = parent.getBoundingClientRect();
        const ink = corners(left, top, right, bottom, matrix);
        let x = Math.min(line.left, box.left, ink[0]), end = Math.max(line.right, box.right, ink[2]);
        const y = Math.min(line.top, box.top, ink[1]), base = Math.max(line.bottom, box.bottom, ink[3]);
        for (const label of parent.closest('.math-block')?.querySelectorAll(number) ?? []) {
            labels.push(label.getBoundingClientRect());
        }
        for (const label of labels) {
            if (label.left >= ink[2] - 0.5) end = Math.min(end, label.left);
            if (label.right <= ink[0] + 0.5) x = Math.max(x, label.right);
        }
        const hit = new DOMRect(x, y, end - x, base - y);
        if (!(hit.width > 0 && hit.height > 0)) continue;
        const index = sources.length;
        sources.push({svg: serializer.serializeToString(standalone), formulaSource: source,
            widthFraction: width * Math.hypot(matrix.a, matrix.b) / hit.width, heightToWidth: height / width});
        visit(parent, hit, 'surimono-diagram:' + token + '/' + index);
    }
}

globalThis.surimonoFormulaIndex = {entries, sources, native() {
    const probes = [];
    entries(document, (host, box, href) => probes.push({host, box, href}));
    placePaperAnchors(probes);
}};
