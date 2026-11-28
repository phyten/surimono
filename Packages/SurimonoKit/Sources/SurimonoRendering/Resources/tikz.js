// All coordinates are kept in TikZ's upward-facing plane until they enter SVG.
// Geometry uses CSS pixels, so diagram export and on-page measurement share one unit.
const cssTexPt = 96 / 72.27,
  radians = Math.PI / 180;
const ns = 'http://www.w3.org/2000/svg';
function fail(feature) {
  throw new Error(feature);
}
function number(value) {
  const n = Number(value);
  if (!Number.isFinite(n) || Math.abs(n) > 1e7) fail('dimension');
  return n;
}
function point(x, y) {
  return { x: number(x), y: number(y) };
}
function add(a, b) {
  return point(a.x + b.x, a.y + b.y);
}
function sub(a, b) {
  return point(a.x - b.x, a.y - b.y);
}
function mul(a, t) {
  return point(a.x * t, a.y * t);
}
function lerp(a, b, t) {
  return add(a, mul(sub(b, a), t));
}
function rotate(p, a) {
  const c = Math.cos(a * radians),
    s = Math.sin(a * radians);
  return point(c * p.x - s * p.y, s * p.x + c * p.y);
}
function unit(a) {
  return rotate(point(1, 0), a);
}
function angle(v) {
  return Math.atan2(v.y, v.x) / radians;
}
// PGF describes length and width at the outside of the ink. A stroked centreline
// at those coordinates would overshoot the endpoint by its front miter.
function arrowTip(kind, requested, lineWidth, pt) {
  const w = number(lineWidth),
    base = number(pt);
  const legacy = 0.28 * base + 0.3 * w;
  function tip(d, length, width, retreat, pen = 0, open = false, rounded = false) {
    if (!(length > 0 && width > 0 && retreat >= 0)) fail('arrow size');
    return {d, length: number(length), width: number(width), retreat: number(retreat), pen: number(pen), open, rounded};
  }
  if (kind === 'bar') {
    const h = 2 * base + 1.5 * w;
    return tip(`M${-w / 2} ${-h}v${2 * h}`, w || base / 100, 2 * h + w, 0.75 * w, w, true);
  }
  if (kind === 'stealth') {
    return tip(
      `M0 0L${-8 * legacy} ${4 * legacy}L${-5 * legacy} 0L${-8 * legacy} ${-4 * legacy}Z`,
      8 * legacy,
      8 * legacy,
      5 * legacy
    );
  }
  if (kind === 'latex') {
    return tip(
      `M0 0C${-2.6667 * legacy} ${0.5 * legacy} ${-7 * legacy} ${2 * legacy} ${-10 * legacy} ${3.75 * legacy}V${-3.75 * legacy}C${-7 * legacy} ${-2 * legacy} ${-2.6667 * legacy} ${-0.5 * legacy} 0 0Z`,
      10 * legacy,
      7.5 * legacy,
      9 * legacy
    );
  }
  if (kind === 'to') {
    const pen = 0.8 * w,
      t = 0.21 * base + 0.625 * w;
    const a = -3 * legacy - t,
      b = -2.75 * legacy - t,
      c = -t,
      f = 0.75 * legacy - t;
    return tip(
      `M${a} ${4 * legacy}C${b} ${2.5 * legacy} ${c} ${0.25 * legacy} ${f} 0C${c} ${-0.25 * legacy} ${b} ${-2.5 * legacy} ${a} ${-4 * legacy}`,
      t + 3 * legacy + pen / 2,
      8 * legacy + pen,
      t,
      pen,
      true,
      true
    );
  }
  const length = number(requested ?? (kind === 'To' ? 1.6 * base + 2.2 * w : 3 * base + 4.5 * w));
  if (!(length > 0)) fail('arrow length');
  if (kind === 'To') {
    const width = 2.096774 * length,
      inner = length - w,
      h = width - w,
      front = -w / 2;
    if (inner <= 0) fail('arrow length');
    return tip(
      `M${front - inner} ${0.5 * h}C${front - 0.81731 * inner} ${0.2 * h} ${front - 0.41019 * inner} ${0.05833333 * h} ${front} 0C${front - 0.41019 * inner} ${-0.05833333 * h} ${front - 0.81731 * inner} ${-0.2 * h} ${front - inner} ${-0.5 * h}`,
      length,
      width,
      w,
      w,
      true,
      true
    );
  }
  const width = 0.75 * length;
  if (kind === 'Stealth') {
    // PGF insets the centreline of this polygon so that its mitered outer edges
    // coincide with these four vertices. Filling that contour avoids stroke inflation.
    const inset = 0.325 * length;
    const pen = Math.min(w, 0.25 * (length - inset));
    const insetMiter = 0.5 * pen * Math.hypot(1, (2 * inset) / width);
    return tip(
      `M0 0L${-length} ${width / 2}L${inset - length} 0L${-length} ${-width / 2}Z`,
      length,
      width,
      length - inset - insetMiter + 0.25 * pen
    );
  }
  if (kind !== 'Latex') fail('arrow ' + kind);
  const pen = Math.min(w, length / 5),
    front = -0.5 * pen * Math.hypot(1, (3 * length) / width);
  const back = -length + pen / 2,
    inner = front - back;
  const dx = 0.3 * length,
    dy = 0.2333333 * width;
  const h = 0.5 * (width - (pen * (Math.hypot(dx, dy) + dy)) / dx);
  return tip(
    `M${front} 0C${back + 0.877192 * inner} ${0.077922 * h} ${back + 0.337381 * inner} ${0.51948 * h} ${back} ${h}V${-h}C${back + 0.337381 * inner} ${-0.51948 * h} ${back + 0.877192 * inner} ${-0.077922 * h} ${front} 0Z`,
    length,
    width,
    -back,
    pen
  );
}

// PGF's legend text cells have 2pt of padding on each side and a fixed 0.15em depth.
function legendRowHeight(lastBaseline, em, pt, symbolHeight) {
  return Math.max(lastBaseline + 0.15 * em + 4 * pt, symbolHeight);
}

function legendCellOffset(alignment, available) {
  if (alignment === 'center') return available / 2;
  if (alignment === 'right') return available;
  if (alignment === 'left') return 0;
  fail('legend cell align');
}

function svg(name, attrs = {}) {
  const el = document.createElementNS(ns, name);
  for (const [k, v] of Object.entries(attrs)) el.setAttribute(k, v);
  return el;
}
function paint(v) {
  if (typeof v !== 'string' || !/^(?:none|currentColor|black|white|#[\da-f]{3,8}|rgba?\([\d., %]+\))$/i.test(v))
    fail('color');
  return v;
}
const origins = {
  center: [0, 0],
  base: [0, 0],
  north: [0, 1],
  south: [0, -1],
  west: [-1, 0],
  east: [1, 0],
  'north east': [1, 1],
  'north west': [-1, 1],
  'south east': [1, -1],
  'south west': [-1, -1]
};
const directions = {
  above: 'north',
  below: 'south',
  left: 'west',
  right: 'east',
  'above right': 'north east',
  'above left': 'north west',
  'below right': 'south east',
  'below left': 'south west'
};
const fontScales = {
  tiny: 0.5,
  scriptsize: 0.7,
  footnotesize: 0.8,
  small: 0.9,
  normalsize: 1,
  large: 1.2,
  Large: 1.44,
  LARGE: 1.728,
  huge: 2.074,
  Huge: 2.488
};
// Heights/depths from cmr10.tfm, in em. PGF anchors use these box metrics,
// while a font outline includes optical overshoots on round capitals and digits.
function cmrExtent(text) {
  const groups = [
    ['!?bdfhkl', .69444, 0], ['()', .75, .25], [',', .10556, .19444],
    ['-:acemnorsuvwxz', .43056, 0], ['.', .10556, 0], ['0123456789', .64444, 0],
    [';gpqy', .43056, .19444], ['ABCDEFGHIJKLMNOPRSTUVWXYZ', .68333, 0],
    ['Q', .68333, .19444], ['i', .66786, 0], ['j', .66786, .19444], ['t', .61508, 0], [' ', 0, 0]
  ];
  let ascent = 0, depth = 0;
  for (const ch of text) {
    const group = groups.find(entry => entry[0].includes(ch));
    if (!group) return null;
    ascent = Math.max(ascent, group[1]);
    depth = Math.max(depth, group[2]);
  }
  return { ascent, depth };
}
function font(style, base) {
  let size = base,
    family,
    weight,
    italic;
  for (const word of String(style.font || '')
    .split(/\\|\s+/)
    .filter(Boolean)) {
    if (Object.hasOwn(fontScales, word)) size = base * fontScales[word];
    else if (word === 'bfseries') weight = 'bold';
    else if (word === 'itshape' || word === 'slshape') italic = 'italic';
    else if (word === 'ttfamily') family = 'monospace';
    else if (word === 'sffamily') family = 'sans-serif';
    else if (word === 'rmfamily') family = 'serif';
    else if (word === 'mdseries') weight = 'normal';
    else if (word === 'upshape') italic = 'normal';
    else if (word !== 'normalfont') fail('font');
  }
  return { size, family, weight, italic };
}
function length(raw, unitless, em, ex, pt) {
  if (typeof raw === 'number') return number(raw * unitless);
  const m = /^([+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:e[+-]?\d+)?)\s*(cm|mm|in|pt|bp|em|ex|px|pc)?$/i.exec(
    String(raw).trim()
  );
  if (!m) fail('length');
  const inch = pt * 72.27;
  const units = { cm: inch / 2.54, mm: inch / 25.4, in: inch, pt, bp: inch / 72, em, ex, px: 1, pc: 12 * pt };
  return number(Number(m[1]) * (m[2] ? units[m[2]] : unitless));
}
// Both emitters (MathRenderer and ThemeFonts) use this exact, data-only grammar.
let pageFaces;
function embeddedFaces() {
  if (pageFaces) return pageFaces;
  pageFaces = new Map();
  const face =
    /@font-face \{ font-family: "(KaTeX_[A-Za-z0-9]+|Surimono Computer Modern(?: Typewriter)?)"; font-weight: (normal|bold); font-style: (normal|italic); (?:unicode-range: ([U+0-9A-F, -]+); )?src: url\("(data:font\/(?:otf|ttf);base64,[A-Za-z0-9+/=]+)"\) format\("(?:opentype|truetype)"\); \}/g;
  for (const el of document.querySelectorAll('style')) {
    const css = el.textContent;
    if (css.length > 5000000 || !css.includes('@font-face')) continue;
    for (const m of css.matchAll(face)) {
      const key = [m[1], m[2], m[3]].join('/');
      if (!pageFaces.has(key))
        pageFaces.set(key, { css: m[0], family: m[1], weight: m[2], style: m[3], range: m[4], data: m[5] });
    }
  }
  return pageFaces;
}
// A template does not request its fonts. Read embedded bytes directly, since additional URL loads
// are blocked in this world. Avoid waiting on unrelated fonts or TeX tools on the user's machine.
let warmup;
const unavailableFaces = new Set();
function warmFonts() {
  if (warmup) return warmup;
  warmup = (async () => {
    if (!document.fonts || typeof FontFace === 'undefined') return;
    const pending = new Set();
    const tasks = [];
    let bytes = 0;
    for (const [key, face] of embeddedFaces()) {
      if (
        Array.from(document.fonts).some(
          (f) =>
            f.status === 'loaded' &&
            f.family.replace(/["']/g, '') === face.family &&
            f.weight === face.weight &&
            f.style === face.style
        )
      )
        continue;
      pending.add(key);
      bytes += face.data.length;
      if (pending.size > 40 || bytes > 5000000) continue;
      tasks.push(
        (async () => {
          try {
            const binary = atob(face.data.slice(face.data.indexOf(',') + 1));
            const buffer = Uint8Array.from(binary, (c) => c.charCodeAt(0));
            const options = { weight: face.weight, style: face.style };
            if (face.range) options.unicodeRange = face.range;
            const ready = await new FontFace(face.family, buffer.buffer, options).load();
            if (!unavailableFaces.has(key)) document.fonts.add(ready);
          } catch {
            unavailableFaces.add(key);
          } finally {
            pending.delete(key);
          }
        })()
      );
    }
    // A Japanese face used only in an inert template has not been requested yet.
    for (const face of document.fonts) {
      if (!/^Surimono (?:JS|J) Mincho$/.test(face.family.replace(/["']/g, '')) || face.status === 'loaded') continue;
      const key = face.family + '/' + face.weight;
      pending.add(key);
      tasks.push(face.load().catch(() => {}).finally(() => pending.delete(key)));
    }
    if (pending.size) {
      let timer;
      try {
        await Promise.race([
          Promise.all(tasks),
          new Promise((done) => {
            timer = setTimeout(done, 750);
          })
        ]);
      } finally {
        clearTimeout(timer);
        for (const key of pending) unavailableFaces.add(key);
      }
    }
  })();
  return warmup;
}
const endDocument = performance.now() + 10000;
const blocks = document.querySelectorAll('.tikz-block[data-scene]');
for (const [index, block] of blocks.entries()) {
  const scratch = document.createElement('div');
  const root = svg('svg');
  let failure = 'layout';
  try {
    const deadline = Math.min(endDocument, performance.now() + 2000);
    let work = 0;
    function check(cost = 1) {
      work += cost;
      if (work > 200000 || performance.now() > deadline) fail('layout budget');
    }
    check();
    const raw = block.dataset.scene;
    if (raw.length > 4000000) fail('scene budget');
    const scene = JSON.parse(raw);
    if (!Array.isArray(scene.items) || scene.items.length > 10000) fail('scene budget');
    await warmFonts();
    check();
    const templates = Array.from(block.children).filter((e) => e.localName === 'template');
    const css = getComputedStyle(block);
    const base = number(parseFloat(css.fontSize));
    // Class themes calibrate TeX points for WebKit's print scale. SVG export, by
    // contrast, uses the ordinary 96 CSS pixels per inch for its intrinsic size.
    const physical = parseFloat(css.getPropertyValue('--tex-pt'));
    const pt = physical > 0 ? number(physical) : cssTexPt;
    scratch.style.cssText =
      'position:absolute;left:0;top:0;visibility:hidden;pointer-events:none;line-height:normal;text-align:left;direction:ltr;writing-mode:horizontal-tb;white-space:normal;letter-spacing:normal;word-spacing:normal;text-transform:none';
    block.append(scratch);
    // DOMRects include the print zoom (and ancestor zoom). A known CSS width gives the conversion back.
    const probe = document.createElement('span');
    probe.style.cssText = 'display:inline-block;width:100px;height:1ex';
    scratch.append(probe);
    const metric = probe.getBoundingClientRect();
    const zoom = number(metric.width / 100);
    if (!zoom) fail('measurement');
    const exRatio = metric.height / zoom / base;
    probe.remove();
    function size(v, defaultUnit = pt, em = base) {
      return length(v, defaultUnit, em, em * exRatio, pt);
    }
    const definitions = svg('defs'),
      content = svg('g');
    root.append(definitions, content);
    root.style.cssText =
      'position:absolute;visibility:hidden;overflow:visible;direction:ltr;text-transform:none;letter-spacing:normal;word-spacing:normal';
    block.append(root);
    let layer = content,
      serial = 0;
    const names = new Map(),
      layers = [],
      clips = new Map(),
      usedFaces = new Set(),
      axisEdges = new Map();
    const jsFloat = block.closest('body[data-latex-js-toc] figure[data-latex-float]');
    let padding = jsFloat ? 0 : 0.5;
    const inkGuards = new Map();
    let fallbackFontMargin = 0;
    const unique = () => 'surimono-tikz-' + index + '-' + serial++;
    const attributes = new Set([
      'x',
      'y',
      'x1',
      'y1',
      'x2',
      'y2',
      'width',
      'height',
      'd',
      'viewBox',
      'fill',
      'stroke',
      'stroke-width',
      'stroke-dasharray',
      'stroke-linecap',
      'stroke-linejoin',
      'font-family',
      'font-size',
      'font-weight',
      'font-style',
      'transform',
      'opacity',
      'fill-rule',
      'text-anchor',
      'dominant-baseline'
    ]);
    function copyMath(el, depth = 0) {
      check();
      if (depth > 40 || !['svg', 'g', 'text', 'path', 'rect', 'line'].includes(el.localName)) fail('math');
      const out = svg(el.localName);
      for (const attr of el.attributes) {
        const k = attr.name,
          v = attr.value;
        // data-* attributes are reader markers for page layout (data-math-glue lets justified Latin
        // lines stretch the formula's glue). A picture label is never justified, so they are dropped
        // instead of being copied into the figure.
        if (['style', 'role', 'aria-label', 'xmlns'].includes(k) || k.startsWith('data-')) continue;
        if (!attributes.has(k) || v.length > 100000) fail('math');
        if (k === 'fill' || k === 'stroke') paint(v);
        if (k === 'font-family') {
          if (!/^KaTeX_[A-Za-z0-9]+$/.test(v)) fail('math font');
          usedFaces.add(
            [v, el.getAttribute('font-weight') || 'normal', el.getAttribute('font-style') || 'normal'].join('/')
          );
        } else if (!/^[a-zA-Z0-9 #.,()+\-]*$/.test(v)) fail('math');
        out.setAttribute(k, v);
      }
      if (el.localName === 'text') out.textContent = el.textContent;
      else for (const child of el.children) out.append(copyMath(child, depth + 1));
      return out;
    }
    const canvas = document.createElement('canvas').getContext('2d');
    if (!canvas) fail('font measurement');
    const skips = css.getPropertyValue('--latex-node-baselines').trim().split(/\s+/).map(Number);
    const baselines = Object.fromEntries(Object.keys(fontScales).map((key, index) => [key, skips[index]]));
    function labelFont(style) {
      const f = font(style, base);
      const named = String(style.font || '').split(/\\|\s+/).filter(w => Object.hasOwn(fontScales, w)).pop() || 'normalsize';
      const jfm = parseFloat(css.getPropertyValue('--latex-jfm-scale'));
      if (physical > 0 && named !== 'normalsize' && jfm !== 0.924715) {
        const probe = document.createElement('span');
        probe.style.fontSize = 'var(--latex-size-' + named + ',' + f.size + 'px)';
        scratch.append(probe);
        f.size = number(parseFloat(getComputedStyle(probe).fontSize));
        probe.remove();
      }
      const exact = baselines[named];
      const stretch = parseFloat(css.getPropertyValue('--latex-stretch')) || 1;
      f.leading = number((exact > 0 ? exact * pt : f.size * 1.2) * stretch);
      return f;
    }
    function measure(id, style) {
      const src = /^(0|[1-9]\d*)$/.test(String(id)) && templates[Number(id)];
      if (!src) fail('label');
      if (src.content.querySelector('.math-error')) fail('math');
      const box = document.createElement('div'), f = labelFont(style);
      const width = style['text width'] === undefined ? null : size(style['text width'], pt, f.size);
      box.style.cssText = 'display:block;width:max-content;margin:0;padding:0;border:0;text-indent:0';
      box.style.fontSize = f.size + 'px';
      if (f.family) box.style.fontFamily = f.family;
      if (f.weight) box.style.fontWeight = f.weight;
      if (f.italic) box.style.fontStyle = f.italic;
      box.style.color = paint(style.text || style.color || 'black');
      const japaneseSpacing = !block.matches(':lang(zh),:lang(ko)');
      scratch.append(box);
      const leaves = [];
      function walk(parent, el, depth = 0) {
        check();
        if (depth > 40) fail('label');
        if (el.nodeType === Node.TEXT_NODE) {
          leaves.push({ value: el.nodeValue.replace(/[ \t\r\n]+/gu, ' '), span: parent });
        } else if (el.localName === 'svg') {
          const formula = copyMath(el);
          const align = el.style.verticalAlign;
          if (align && !/^-?[\d.]+em$/.test(align)) fail('math baseline');
          formula.style.cssText = 'display:inline;overflow:visible;max-width:none;max-height:none;margin:0';
          if (align) formula.style.verticalAlign = align;
          parent.append(formula);
          leaves.push({ math: formula, span: parent });
        } else if (el.localName === 'br') {
          leaves.push({ value: '\n' });
        } else {
          const reference = el.localName === 'a' && el.getAttribute('href')?.startsWith('#');
          if (
            !reference &&
            !['span', 'strong', 'b', 'i', 'em', 'code', 'sup', 'sub', 'u', 'small'].includes(el.localName)
          )
            fail('label ' + el.localName);
          const out = document.createElement(reference ? 'span' : el.localName);
          // The inline reader emits these classes; arbitrary document classes could fetch styles/resources.
          for (const cls of el.classList) {
            if (!/^(?:math|math-inline|latex-(?:nowrap|sf|sc|size-[A-Za-z]+))$/.test(cls)) fail('label ' + cls);
            out.classList.add(cls);
          }
          for (const property of Array.from(el.style)) {
            if (property === 'color') out.style.color = paint(el.style.color);
            else if (property === 'font-size' && /^\d*\.?\d+em$/.test(el.style.fontSize))
              out.style.fontSize = el.style.fontSize;
            else fail('label ' + property);
          }
          parent.append(out);
          for (const child of el.childNodes) walk(out, child, depth + 1);
        }
      }
      for (const child of src.content.childNodes) walk(box, child);
      const atoms = [], group = svg('g');
      for (const run of leaves) {
        check();
        if (run.value === '\n') {
          atoms.push({ text: '\n' });
          continue;
        }
        const face = getComputedStyle(run.span);
        const em = number(parseFloat(face.fontSize));
        const keep = run.span.closest('.latex-nowrap');
        let shift = 0;
        for (let parent = run.span; parent && parent !== box; parent = parent.parentElement) {
          if (parent.localName === 'sub' || parent.localName === 'sup') {
            const parentEm = parseFloat(getComputedStyle(parent.parentElement).fontSize);
            shift += (parent.localName === 'sub' ? 0.2 : -0.4) * parentEm;
          }
        }
        if (run.math) {
          const advance = size(run.math.getAttribute('width'), 1, em);
          const height = size(run.math.getAttribute('height'), 1, em);
          const depth = -(parseFloat(run.math.style.verticalAlign) || 0) * em;
          atoms.push({ text: '', math: run.math, advance, depth, ascent: height - depth, shift, keep, face });
          continue;
        }
        check(run.value.length / 4);
        const parts = labelParts(run.value);
        const classScale = parseFloat(css.getPropertyValue('--latex-jfm-scale'));
        // Resolve the default Japanese face directly, so canvas and exported SVG
        // neither depend on CSS size-adjust nor apply the class scale twice.
        const explicitCJK = ['main', 'sans', 'mono'].some(role => {
          const family = face.getPropertyValue('--latex-cjk-' + role + '-font').trim().split(',')[0];
          return family && face.fontFamily.startsWith(family);
        });
        const defaultJFM = japaneseSpacing && classScale > 0 && !explicitCJK;
        const rawFamily = face.fontFamily.replace(/["']?Surimono (?:JS|J) Mincho["']?,?\s*/g, '');
        const cmRoman = /^["']?Surimono Computer Modern["']?(?:,|$)/.test(face.fontFamily)
          && face.fontWeight === '400' && face.fontStyle === 'normal' && face.fontVariantCaps === 'normal';
        const letterSpace = parseFloat(face.letterSpacing) || 0;
        const wordSpace = parseFloat(face.wordSpacing) || 0;
        const measurements = new Map();
        for (const text of parts) {
          check();
          let a = measurements.get(text);
          if (!a) {
            const ja = japaneseGlyph.test(text);
            const scaled = ja && defaultJFM;
            const family = scaled ? rawFamily : face.fontFamily;
            const fontSize = scaled ? em * classScale : em;
            // Large-size measurement avoids integer rounding in small glyph boxes.
            canvas.font = [face.fontStyle, face.fontVariantCaps === 'small-caps' ? 'small-caps' : 'normal',
              face.fontWeight, '256px', family].join(' ');
            const ratio = fontSize / 256;
            const m = canvas.measureText(text);
            const zw = ja ? (scaled ? fontSize : number(canvas.measureText('日').width * ratio)) : 0;
            const cm = cmRoman && !ja ? cmrExtent(text) : null;
            const ascent = scaled ? 0.88 * zw : cm ? cm.ascent * em : m.actualBoundingBoxAscent * ratio;
            const depth = scaled ? 0.12 * zw : cm ? cm.depth * em : m.actualBoundingBoxDescent * ratio;
            // Normalize a measured full em to its JFM advance; subpixel deviations
            // between shapers must not admit another character at a tight boundary.
            const glyphWidth = scaled && Math.abs(m.width - 256) < 1 ? zw : m.width * ratio;
            const advance = number(glyphWidth + letterSpace * Array.from(text).length
              + (text === ' ' ? wordSpace : 0));
            a = { text, advance, ascent: number(ascent), depth: number(depth), shift, ja, zw,
              // ltj-kinsoku.tex allows .5pt of shrink; jsclasses uses .01zw.
              shrink: classScale === 0.962216 ? 0.5 * pt : 0.01 * zw,
              noAutospace: !japaneseSpacing, keep, face, family, fontSize, run };
            measurements.set(text, a);
          }
          atoms.push(a);
        }
        for (const name of face.fontFamily.split(',').map(v => v.trim().replace(/["']/g, ''))) {
          if (name === 'Surimono Computer Modern' || name === 'Surimono Computer Modern Typewriter') {
            const weight = face.fontWeight === 'bold' || Number(face.fontWeight) >= 600 ? 'bold' : 'normal';
            const variant = face.fontStyle === 'italic' || face.fontStyle === 'oblique' ? 'italic' : 'normal';
            usedFaces.add([name, weight, variant].join('/'));
            usedFaces.add([name, 'normal', 'normal'].join('/'));
          }
        }
      }
      const label = layoutLabel(atoms, width, f.leading, style.align || (width === null ? 'center' : 'left'));
      for (const line of label.lines) {
        for (let i = 0; i < line.runs.length;) {
          check();
          const { atom: a, x } = line.runs[i++];
          const y = label.baseY + line.y + a.shift;
          if (a.math) {
            for (const [key, value] of Object.entries({ x: line.x + x, y: y - a.ascent,
              width: a.advance, height: a.ascent + a.depth })) a.math.setAttribute(key, value);
            a.math.style.cssText = 'overflow:visible';
            a.math.style.color = paint(a.face.color);
            group.append(a.math);
            continue;
          }
          // Coalesce contiguous text from the same shaped leaf; a numerical glue
          // adjustment, font change or line break always starts a new SVG run.
          let text = a.text, length = a.advance;
          while (i < line.runs.length) {
            const next = line.runs[i];
            if (next.atom.run !== a.run || next.atom.ja !== a.ja || Math.abs(next.x - x - length) > 1e-7) break;
            text += next.atom.text;
            length += next.atom.advance;
            i++;
          }
          const t = svg('text', { x: number(line.x + x), y: number(y), fill: paint(a.face.color),
            textLength: number(length), lengthAdjust: 'spacingAndGlyphs' });
          for (const key of ['fontStyle', 'fontVariantCaps', 'fontWeight', 'letterSpacing', 'wordSpacing'])
            t.style[key] = a.face[key];
          t.style.fontFamily = a.family;
          t.style.fontSize = a.fontSize + 'px';
          if (a.ja) {
            const guard = 0.4 * Math.min(base, a.fontSize);
            if (jsFloat) inkGuards.set(t, guard);
            else fallbackFontMargin = Math.max(fallbackFontMargin, guard);
          }
          if (a.run.span.closest('u')) t.style.textDecoration = 'underline';
          t.style.whiteSpace = 'pre';
          t.style.setProperty('text-autospace', 'no-autospace');
          t.textContent = text;
          group.append(t);
        }
      }
      box.remove();
      return { w: label.w, h: label.h, baseY: label.baseY, lastBaseY: label.lastBaseY, group };
    }
    const transforms = new WeakMap();
    function matrix(style) {
      if (transforms.has(style)) return transforms.get(style);
      let m = new DOMMatrix();
      for (const [k, v] of style.transforms || []) {
        check();
        if (k === 'scale') m = m.scale(number(v));
        else if (k === 'xscale') m = m.scale(number(v), 1);
        else if (k === 'yscale') m = m.scale(1, number(v));
        else if (k === 'rotate') m = m.rotate(number(v));
        else if (k === 'xshift') m = m.translate(size(v), 0);
        else if (k === 'yshift') m = m.translate(0, size(v));
        else if (k === 'shift') {
          const d = resolve(v, { ...style, transforms: [] });
          m = m.translate(d.x, d.y);
        } else fail(k);
      }
      transforms.set(style, m);
      return m;
    }
    function vector(p, style) {
      const m = matrix(style);
      return point(p.x * m.a + p.y * m.c, p.x * m.b + p.y * m.d);
    }
    function perimeter(n, dir) {
      const v = rotate(dir, -n.rot),
        w = n.w / 2 + n.sep,
        h = n.h / 2 + n.sep;
      if (!w || !h || (!v.x && !v.y)) return n.p;
      const dx = Math.abs(v.x / w),
        dy = Math.abs(v.y / h);
      const k =
        n.shape === 'diamond'
          ? dx + dy
          : n.shape === 'circle' || n.shape === 'ellipse'
            ? Math.hypot(dx, dy)
            : Math.max(dx, dy);
      return add(n.p, mul(dir, 1 / k));
    }
    function anchor(n, name = 'center') {
      if (name === 'center') return n.p;
      if (name === 'base') return add(n.p, rotate(point(0, n.base || 0), n.rot));
      if (!Object.hasOwn(origins, name)) {
        if (!/^-?\d+(?:\.\d+)?$/.test(name)) fail('anchor ' + name);
        return perimeter(n, unit(Number(name) + n.rot));
      }
      const [x, y] = origins[name];
      const corner = point(x * (n.w / 2 + n.sep), y * (n.h / 2 + n.sep));
      return perimeter(n, rotate(corner, n.rot));
    }
    function named(name) {
      const n = names.get(name);
      if (!n) fail('coordinate ' + String(name).slice(0, 80));
      return n;
    }
    function resolve(c, style, relative, depth = 0) {
      check();
      if (!c || depth > 32) fail('coordinate');
      if (c.name !== undefined) return anchor(named(c.name), c.anchor || 'center');
      if (c.calc) {
        const a = resolve(c.a, style, undefined, depth + 1),
          b = resolve(c.b, style, undefined, depth + 1);
        if (c.calc === 'lerp') return lerp(a, b, number(c.t));
        if (c.calc === 'add') return add(a, sub(b, resolve({ x: 0, y: 0 }, style)));
        if (c.calc === '|-') return point(a.x, b.y);
        if (c.calc === '-|') return point(b.x, a.y);
        fail('calc');
      }
      const m = matrix(style);
      const v = point(size(c.x, size(style.x || '1cm')), size(c.y, size(style.y || '1cm')));
      const d = point(m.a * v.x + m.c * v.y, m.b * v.x + m.d * v.y);
      if (c.relative && !relative) fail('relative coordinate');
      return add(d, c.relative ? relative : point(m.e, m.f));
    }
    const hatched = [];
    function vectorHatch(out, style) {
      const box = out.getBBox(),
        pitch = 3 * pt;
      if (!box.width || !box.height) return;
      const left = number(box.x),
        right = number(box.x + box.width);
      const top = number(box.y),
        bottom = number(box.y + box.height);
      const first = Math.floor((left + top) / pitch),
        last = Math.ceil((right + bottom) / pitch);
      if (last - first > 5000) fail('pattern budget');
      const segments = [];
      // The phase is shared by adjacent shapes. Intersect with the rectangular bounds first:
      // getBBox() includes portions outside an SVG clip on some WebKit versions.
      for (let i = first; i <= last; i++) {
        check();
        const k = i * pitch;
        const a = Math.max(left, k - bottom),
          b = Math.min(right, k - top);
        if (a < b) segments.push(`M${a} ${k - a}L${b} ${k - b}`);
      }
      const id = unique(),
        clip = svg('clipPath', {id});
      const contour = svg(out.localName);
      for (const key of ['d', 'x', 'y', 'width', 'height', 'rx', 'ry', 'cx', 'cy'])
        if (out.hasAttribute(key)) contour.setAttribute(key, out.getAttribute(key));
      clip.append(contour);
      definitions.append(clip);
      const hatch = svg('path', {
        d: segments.join(' '),
        fill: 'none',
        stroke: '#000000',
        'stroke-width': 0.4 * pt,
        'clip-path': 'url(#' + id + ')'
      });
      if (style.opacity !== undefined || style['fill opacity'] !== undefined)
        hatch.setAttribute('opacity', number((style.opacity ?? 1) * (style['fill opacity'] ?? 1)));
      out.before(hatch);
    }

    function stroke(out, style) {
      const width = size(style['line width'] || '.4pt');
      if (width < 0) fail('line width');
      if (!jsFloat) padding = Math.max(padding, width);
      else if (width && style.draw && style.draw !== 'none') inkGuards.set(out, width / 2);
      out.setAttribute('stroke', paint(style.draw || 'none'));
      out.setAttribute('fill', paint(style.fill || 'none'));
      out.setAttribute('stroke-width', width);
      if (style['line cap'])
        out.setAttribute('stroke-linecap', style['line cap'] === 'rect' ? 'square' : style['line cap']);
      if (style['line join']) out.setAttribute('stroke-linejoin', style['line join']);
      if (style.opacity !== undefined) out.setAttribute('opacity', number(style.opacity));
      if (style['fill opacity'] !== undefined) out.setAttribute('fill-opacity', number(style['fill opacity']));
      if (style.pattern) {
        if (style.pattern !== 'north east lines') fail('pattern');
        out.setAttribute('fill', 'none');
        hatched.push([out, style]);
      }
      if (style['dash pattern']) {
        const dash = String(style['dash pattern']).trim().split(/\s+/);
        if (dash.length % 2 || dash.length > 40) fail('dash pattern');
        out.setAttribute(
          'stroke-dasharray',
          dash
            .filter((_, i) => i % 2)
            .map((v) => size(v))
            .join(' ')
        );
      }
      return width;
    }
    function place(item, style, where, slope = 0, measured) {
      const f = labelFont(style);
      const label = measured || measure(item.html, style),
        shape = style.shape || 'rectangle';
      const inner = size(style['inner sep'] ?? '.3333em', pt, f.size);
      let w = label.w + 2 * inner,
        h = label.h + 2 * inner;
      if (shape === 'diamond') w = h = w + h;
      if (shape === 'ellipse') {
        w *= Math.SQRT2;
        h *= Math.SQRT2;
      }
      if (shape === 'circle') w = h = Math.hypot(w, h);
      w = Math.max(w, size(style['minimum width'] || 0), size(style['minimum size'] || 0));
      h = Math.max(h, size(style['minimum height'] || 0), size(style['minimum size'] || 0));
      if (shape === 'circle') w = h = Math.max(w, h);
      const n = {
        p: point(0, 0),
        w,
        h,
        shape,
        base: label.h / 2 - label.baseY,
        rot: number(style.rotate || 0) + slope,
        sep: size(style['outer sep'] ?? size(style['line width'] || '.4pt') / 2, 1)
      };
      let a = style.anchor || 'center';
      for (const [key, dir] of Object.entries(directions)) {
        if (!Object.hasOwn(style, key)) continue;
        const value = String(style[key] === true ? '' : style[key]).trim();
        const match = /^(?:(.*?)\s+)?of\s+([^\s]+)$/.exec(value);
        const distance = (match ? match[1] || style['node distance'] || '1cm' : value || '0pt').split(/\s+and\s+/);
        const [dx, dy] = origins[dir];
        a = Object.keys(origins).find((k) => origins[k][0] === -dx && origins[k][1] === -dy);
        if (match) {
          const [name, ref] = match[2].split('.');
          where = anchor(named(name), ref || dir);
        }
        const projection = distance.length === 1 && dx && dy && match ? Math.SQRT1_2 : 1;
        const offset = point(
          dx * size(distance[1] || distance[0]) * projection,
          dy * size(distance[0]) * projection
        );
        where = add(where, rotate(offset, match ? 0 : slope));
      }
      if (item.axisRole && !style.transforms?.length) {
        const edges = axisEdges.get(item.axisGroup) || {};
        // PGF's ticklabel cs touches the outer edges of two nodes. The scene
        // uses ink boxes for ticks/titles, so restore each node's 1/3-em inner sep.
        const labelInset = f.size * 0.3333;
        if (item.axisRole === 'labelX' && edges.y !== undefined) where = point(where.x, edges.y - labelInset);
        if (item.axisRole === 'labelY' && edges.x !== undefined) where = point(edges.x - labelInset, where.y);
      }
      n.p = sub(where, anchor(n, a));
      if ((item.axisRole === 'tickX' || item.axisRole === 'tickY') && !style.transforms?.length) {
        const edges = axisEdges.get(item.axisGroup) || {};
        for (const x of [-n.w / 2, n.w / 2])
          for (const y of [-n.h / 2, n.h / 2]) {
            const corner = add(n.p, rotate(point(x, y), n.rot));
            if (item.axisRole === 'tickX') edges.y = Math.min(edges.y ?? Infinity, corner.y - f.size * 0.3333);
            else edges.x = Math.min(edges.x ?? Infinity, corner.x - f.size * 0.3333);
          }
        axisEdges.set(item.axisGroup, edges);
      }
      const group = svg('g', { transform: 'translate(' + n.p.x + ' ' + -n.p.y + ') rotate(' + -n.rot + ')' });
      const frame =
        shape === 'circle' || shape === 'ellipse'
          ? svg('ellipse', { rx: w / 2, ry: h / 2 })
          : shape === 'diamond'
            ? svg('path', { d: 'M 0 ' + -h / 2 + ' L ' + w / 2 + ' 0 0 ' + h / 2 + ' ' + -w / 2 + ' 0 Z' })
            : svg('rect', {
                x: -w / 2,
                y: -h / 2,
                width: w,
                height: h,
                rx: Math.min(w / 2, h / 2, size(style['rounded corners'] || 0))
              });
      stroke(frame, style);
      if (jsFloat && (item.axisRole === 'tickX' || item.axisRole === 'tickY') && inner === 0) {
        // The lowered axis has already offset the tick ink from its anchor. PGF
        // includes the tick node's invisible inner separation in the picture bounds.
        inkGuards.set(frame, Math.max(inkGuards.get(frame) || 0, f.size * 0.3333));
      }
      label.group.setAttribute('transform', 'translate(' + -label.w / 2 + ' ' + -label.h / 2 + ')');
      if (style.opacity !== undefined) label.group.setAttribute('opacity', number(style.opacity));
      group.append(frame, label.group);
      if (item.name) names.set(item.name, n);
      layer.append(group);
      return group;
    }
    function path(item) {
      const s = item.style,
        parts = [],
        labels = [];
      let current, first, reference, currentCoord, lastSegment;
      function move(p) {
        parts.push({ op: 'M', p });
        current = p;
        first = p;
      }
      function line(p) {
        parts.push({ op: 'L', p });
        current = p;
      }
      function cubic(a, b, p) {
        parts.push({ op: 'C', a, b, p });
        current = p;
      }
      function close() {
        parts.push({ op: 'Z' });
        current = first;
      }
      function straight(a, b) {
        return { at: (t) => lerp(a, b, t), slope: (t) => sub(b, a) };
      }
      function curve(a, b, c, d) {
        return {
          at: (t) => lerp(lerp(lerp(a, b, t), lerp(b, c, t), t), lerp(lerp(b, c, t), lerp(c, d, t), t), t),
          slope: (t) => lerp(lerp(sub(b, a), sub(c, b), t), lerp(sub(c, b), sub(d, c), t), t)
        };
      }
      function bendControls(from, to, options) {
        const bend =
          options['bend left'] ?? (options['bend right'] === undefined ? undefined : -options['bend right']);
        if (bend === undefined && options.in === undefined && options.out === undefined) return [];
        const bearing = angle(sub(to, from));
        const out = number(options.out ?? (bend === undefined ? 0 : bearing + bend));
        const into = number(options.in ?? (bend === undefined ? 90 : bearing + 180 - bend));
        const distance = Math.hypot(to.x - from.x, to.y - from.y) * 0.3915;
        return [add(from, mul(unit(out), distance)), add(to, mul(unit(into), distance))];
      }
      function rim(coord, p, toward) {
        return coord?.name && !coord.anchor ? perimeter(named(coord.name), sub(toward, p)) : p;
      }
      function localOffsets(a, b) {
        const m = matrix(s),
          delta = sub(b, a),
          det = m.a * m.d - m.b * m.c;
        if (!det) fail('singular transform');
        return point((m.d * delta.x - m.c * delta.y) / det, (-m.b * delta.x + m.a * delta.y) / det);
      }
      function radii(op) {
        return point(size(op.rx, size(s.x || '1cm')), size(op.ry, size(s.y || '1cm')));
      }
      function arc(center, r, start, end) {
        const count = Math.ceil(Math.abs(end - start) / 90);
        if (count > 40) fail('arc');
        function delta(t) {
          return vector(point(r.x * Math.cos(t), r.y * Math.sin(t)), s);
        }
        function tang(t) {
          return vector(point(-r.x * Math.sin(t), r.y * Math.cos(t)), s);
        }
        for (let i = 0; i < count; i++) {
          const a = (start + ((end - start) * i) / count) * radians,
            b = (start + ((end - start) * (i + 1)) / count) * radians;
          const k = (4 / 3) * Math.tan((b - a) / 4),
            p = add(center, delta(a)),
            q = add(center, delta(b));
          cubic(add(p, mul(tang(a), k)), sub(q, mul(tang(b), k)), q);
        }
      }
      for (const op of item.ops) {
        check();
        if (op.op === 'node') {
          if (!current) fail('node position');
          const t = op.style.pos === undefined ? (op.segment ? 0.5 : null) : number(op.style.pos);
          const p = op.at
            ? resolve(op.at, op.style, reference)
            : t !== null && lastSegment
              ? lastSegment.at(t)
              : current;
          let rot = op.style.sloped && lastSegment ? angle(lastSegment.slope(t ?? 1)) : 0;
          if (rot > 90) rot -= 180;
          if (rot < -90) rot += 180;
          if (t !== null && !lastSegment && !op.at) fail('pos');
          labels.push(place(op, op.style, p, rot));
          continue;
        }
        const p = op.p ? resolve(op.p, s, reference) : null;
        if (op.op === 'M') {
          move(p);
          reference = op.p.relative === '+' ? reference : p;
          currentCoord = op.p;
          lastSegment = null;
          continue;
        }
        if (!current) fail('path start');
        let start = current;
        if (['L', '|-', '-|', 'C', 'to'].includes(op.op)) {
          // An unqualified node name on a connector means the border in the direction of
          // the outgoing/incoming segment. A qualified .center stays at the centre.
          const center = currentCoord?.name && !currentCoord.anchor ? anchor(named(currentCoord.name)) : start;
          const elbow = op.op === '|-' ? point(center.x, p.y) : op.op === '-|' ? point(p.x, center.y) : null;
          let a, b;
          if (op.op === 'C') {
            a = resolve(op.c1, s, reference);
            b = resolve(op.c2, s, reference);
          }
          if (op.op === 'to') [a, b] = bendControls(center, p, op.style);
          const outCorner = elbow && (elbow.x !== center.x || elbow.y !== center.y) ? elbow : p;
          const inCorner = elbow && (elbow.x !== p.x || elbow.y !== p.y) ? elbow : center;
          start = rim(currentCoord, center, a || outCorner);
          const target = rim(op.p, p, b || inCorner);
          // PGF recomputes the tangent handles between the two shortened border anchors.
          if (op.op === 'to' && a && b) [a, b] = bendControls(start, target, op.style);
          if (parts.at(-1)?.op === 'M') parts.at(-1).p = start;
          else if (Math.hypot(start.x - current.x, start.y - current.y) > 0.0001) move(start);
          if (elbow && ((elbow.x === center.x && elbow.y === center.y) || (elbow.x === p.x && elbow.y === p.y))) {
            line(target);
            lastSegment = straight(start, target);
          } else if (elbow) {
            line(elbow);
            line(target);
            const before = straight(start, elbow),
              after = straight(elbow, target);
            lastSegment = {
              at: (t) => (t < 0.5 ? before.at(t * 2) : after.at(2 * t - 1)),
              slope: (t) => (t < 0.5 ? before.slope(t) : after.slope(t))
            };
          } else if (a && b) {
            cubic(a, b, target);
            lastSegment = curve(start, a, b, target);
          } else {
            line(target);
            lastSegment = straight(start, target);
          }
          currentCoord = op.p;
        } else if (op.op === 'rectangle' || op.op === 'grid') {
          const d = localOffsets(start, p);
          const at = (x, y) => add(start, vector(point(x, y), s));
          if (op.op === 'rectangle') {
            // The rectangle closes at its own starting corner, even after a line on the same path.
            move(start);
            line(at(d.x, 0));
            line(p);
            line(at(0, d.y));
            close();
          } else {
            const sx = size(op.step, size(s.x || '1cm')),
              sy = size(op.step, size(s.y || '1cm'));
            if (!(sx > 0 && sy > 0) || Math.abs(d.x / sx) + Math.abs(d.y / sy) > 5000) fail('grid');
            const origin = localOffsets(resolve({ x: 0, y: 0 }, s), start);
            function lines(offset, end, step, draw) {
              const low = Math.min(offset, offset + end),
                high = Math.max(offset, offset + end);
              for (let i = Math.ceil(low / step); i <= Math.floor(high / step); i++) {
                check();
                draw(i * step - offset);
              }
            }
            lines(origin.x, d.x, sx, (x) => {
              move(at(x, 0));
              line(at(x, d.y));
            });
            lines(origin.y, d.y, sy, (y) => {
              move(at(0, y));
              line(at(d.x, y));
            });
          }
          move(p);
          currentCoord = op.p;
          lastSegment = null;
        } else if (op.op === 'ellipse') {
          const r = radii(op);
          move(add(start, vector(point(r.x, 0), s)));
          arc(start, r, 0, 360);
          close();
          move(start);
          currentCoord = undefined;
          lastSegment = null;
        } else if (op.op === 'arc') {
          const r = radii(op),
            a = number(op.start),
            b = number(op.end);
          const c = sub(start, vector(point(r.x * Math.cos(a * radians), r.y * Math.sin(a * radians)), s));
          arc(c, r, a, b);
          currentCoord = undefined;
          reference = current;
          lastSegment = {
            at: (t) => {
              const q = (a + (b - a) * t) * radians;
              return add(c, vector(point(r.x * Math.cos(q), r.y * Math.sin(q)), s));
            },
            slope: (t) => {
              const q = (a + (b - a) * t) * radians;
              return vector(point(-r.x * Math.sin(q) * Math.sign(b - a), r.y * Math.cos(q) * Math.sign(b - a)), s);
            }
          };
        } else if (op.op === 'Z') {
          lastSegment = straight(start, first);
          close();
          currentCoord = undefined;
        } else fail(op.op);
        if (p && op.p.relative !== '+') reference = p;
      }
      const xy = (p) => number(p.x) + ' ' + number(-p.y);
      const radius = size(s['rounded corners'] || 0);
      function eased(a, b, distance) {
        const delta = sub(b, a),
          len = Math.hypot(delta.x, delta.y);
        return len ? lerp(a, b, Math.min(0.5, distance / len)) : a;
      }
      const arrow = item.kind === 'clip' || parts.some((v) => v.op === 'Z') ? null : s.arrows;
      let tip, startInset, endInset;
      if (arrow && arrow !== '-') {
        const pen = size(s['line width'] ?? '.4pt');
        tip = arrowTip(
          arrow === '|-|' ? 'bar' : s['>'] || 'to',
          s['tip length'] === undefined ? null : size(s['tip length']),
          pen,
          pt
        );
        // Move the shaft endpoint behind the tip; leaving the end cap at the tip flattens its point.
        // Its marker refX later restores the original endpoint. Keep the endpoint tangent on a cubic.
        function shorten(start) {
          let i = start ? 0 : parts.length - 1;
          if (start) {
            while (i + 1 < parts.length && parts[i + 1].op === 'M') i++;
            i++;
          } else while (i > 0 && parts[i].op === 'M') i--;
          const edge = parts[i],
            prev = parts[i - 1];
          if (!prev || !edge || !['L', 'C'].includes(edge.op)) return 0;
          const endpoint = start ? prev : edge;
          const control = start ? 'a' : 'b';
          const toward = edge[control] ?? (start ? edge.p : prev.p);
          const v = sub(toward, endpoint.p),
            len = Math.hypot(v.x, v.y);
          if (!len) return 0;
          const distance = Math.min(tip.retreat, len * 0.49);
          const offset = mul(v, distance / len);
          endpoint.p = add(endpoint.p, offset);
          if (edge[control]) edge[control] = add(edge[control], offset);
          return distance;
        }
        if (arrow.startsWith('<') || arrow === '|-|') startInset = shorten(true);
        if (arrow.endsWith('>') || arrow === '|-|') endInset = shorten(false);
      }

      const commands = [];
      for (let i = 0; i < parts.length; ) {
        check();
        if (parts[i].op !== 'M') fail('path');
        const head = i++;
        while (i < parts.length && parts[i].op !== 'M') i++;
        if (i - head === 1) continue;
        const closed = parts[i - 1].op === 'Z';
        const end = closed ? i - 1 : i;
        const begin = parts[head].p;
        const roundStart = closed && radius && parts[head + 1]?.op === 'L' && parts[end - 1]?.op === 'L';
        commands.push('M' + xy(roundStart ? eased(begin, parts[head + 1].p, radius) : begin));
        for (let j = head + 1; j < end; j++) {
          const v = parts[j],
            next = j + 1 === end && closed ? parts[head] : parts[j + 1];
          if (v.op === 'C') commands.push('C' + xy(v.a) + ' ' + xy(v.b) + ' ' + xy(v.p));
          else if (v.op === 'L' && radius && (next?.op === 'L' || (next === parts[head] && closed))) {
            commands.push(
              'L' + xy(eased(v.p, parts[j - 1].p, radius)) + ' Q' + xy(v.p) + ' ' + xy(eased(v.p, next.p, radius))
            );
          } else if (v.op === 'L') commands.push('L' + xy(v.p));
          else fail('subpath');
        }
        if (closed) {
          if (roundStart)
            commands.push(
              'L' +
                xy(eased(begin, parts[end - 1].p, radius)) +
                ' Q' +
                xy(begin) +
                ' ' +
                xy(eased(begin, parts[head + 1].p, radius))
            );
          commands.push('Z');
        }
      }
      const drawing = svg('path', { d: commands.join(' ') });
      if (item.kind === 'clip') {
        if (labels.length) fail('clip node');
        const id = unique(),
          clip = svg('clipPath', { id });
        clip.append(drawing);
        definitions.append(clip);
        const inside = svg('g', { 'clip-path': 'url(#' + id + ')' });
        // A group's getBBox includes portions outside its clip. Record the clipping path
        // itself while it is in the layout tree, so outliers do not shrink an entire axis.
        layer.append(drawing);
        const bounds = drawing.getBBox();
        clip.append(drawing);
        clips.set(inside, bounds);
        layer.append(inside);
        layer = inside;
      } else {
        stroke(drawing, s);
        if (tip) {
          const ink = paint(s.draw || '#000000');
          function marker(inset) {
            const id = unique(),
              m = svg('marker', {
                id,
                refX: -inset,
                refY: 0,
                markerUnits: 'userSpaceOnUse',
                markerWidth: tip.length,
                markerHeight: tip.width,
                orient: 'auto-start-reverse',
                overflow: 'visible'
              });
            m.append(
              svg('path', {
                d: tip.d,
                fill: tip.open ? 'none' : ink,
                stroke: tip.pen ? ink : 'none',
                'stroke-width': tip.pen,
                'stroke-linejoin': tip.rounded ? 'round' : 'miter',
                'stroke-miterlimit': 10,
                'stroke-linecap': tip.rounded ? 'round' : arrow === '|-|' ? 'square' : 'butt'
              })
            );
            definitions.append(m);
            return 'url(#' + id + ')';
          }
          if (startInset !== undefined) drawing.setAttribute('marker-start', marker(startInset));
          if (endInset !== undefined) drawing.setAttribute('marker-end', marker(endInset));
          // SVG's default getBBox() omits markers, including the portion beyond the shortened shaft.
          const overhang = Math.max(tip.width / 2, startInset ?? 0, endInset ?? 0);
          if (jsFloat) inkGuards.set(drawing, Math.max(overhang, inkGuards.get(drawing) || 0));
          else padding = Math.max(padding, overhang);
        }

        layer.append(drawing);
        for (const node of labels) layer.append(node);
      }
    }
    function drawMatrix(item) {
      const cells = item.cells,
        rows = cells?.length,
        columns = cells?.[0]?.length;
      if (!rows || !columns || rows > 64 || columns > 64 || rows * columns > 256) fail('matrix dimensions');
      const colBounds = Array.from({ length: columns }, () => [0, 0]);
      const rowBounds = Array.from({ length: rows }, () => [0, 0]);
      const frames = [],
        style = item.cellStyle;
      const strokeEdge = style.draw === 'none' ? 0 : size(style['line width'] ?? '.4pt') / 2;
      // A matrix of nodes aligns its cells on their origins (the text baseline by default).
      // Each column and row reserves the largest extent on either side of that origin.
      for (const [r, row] of cells.entries()) {
        if (row.length !== columns) fail('matrix columns');
        for (const [c, html] of row.entries()) {
          check();
          const name = item.name + '-' + (r + 1) + '-' + (c + 1);
          const group = place({ name, html }, style, point(0, 0)),
            n = named(name);
          const halfWidth = n.w / 2 + strokeEdge,
            halfHeight = n.h / 2 + strokeEdge;
          colBounds[c][0] = Math.max(colBounds[c][0], halfWidth - n.p.x);
          colBounds[c][1] = Math.max(colBounds[c][1], halfWidth + n.p.x);
          rowBounds[r][0] = Math.max(rowBounds[r][0], halfHeight + n.p.y);
          rowBounds[r][1] = Math.max(rowBounds[r][1], halfHeight - n.p.y);
          frames.push({ group, n, r, c });
        }
      }
      function band(bounds, gap) {
        const step = size(gap);
        if (step < 0) fail('matrix separation');
        let width = 0;
        const centers = bounds.map(([before, after], i) => {
          if (i) width += step;
          const origin = number(width + before);
          width = origin + after;
          return origin;
        });
        return { width: number(width), centers };
      }
      const horizontal = band(colBounds, item.columnSep),
        vertical = band(rowBounds, item.rowSep);
      const origin = resolve(item.at || { x: 0, y: 0 }, item.style);
      // The matrix is a node of its own. Its border encloses all cells plus its inner sep and
      // can be addressed by name, while cell border anchors retain their individual outer seps.
      const frame = place(item, item.style, origin, 0, {
        group: svg('g'),
        w: horizontal.width,
        h: vertical.width,
        baseY: vertical.width / 2
      });
      layer.insertBefore(frame, frames[0].group);
      const center = named(item.name).p;
      for (const { group, n, r, c } of frames) {
        const offset = point(horizontal.centers[c] - horizontal.width / 2, vertical.width / 2 - vertical.centers[r]);
        n.p = add(n.p, add(center, offset));
        group.setAttribute('transform', 'translate(' + n.p.x + ' ' + -n.p.y + ')');
      }
    }
    function legend(item) {
      const rows = item.entries.map((e) => ({ ...e, label: measure(e.html, item.style) }));
      if (!rows.length) fail('legend');
      const group = svg('g'),
        swatch = size('0.6cm'),
        padding = 2 * pt,
        outerExtra = item.style['inner sep'] === undefined ? pt : 0,
        em = labelFont(item.style).size;
      const content = svg('g', { transform: 'translate(' + outerExtra + ' 0)' });
      group.append(content);
      const cell = Math.max(...rows.map((r) => r.label.w)), w = cell + swatch + 2 * (padding + outerExtra);
      let y = 0;
      for (const row of rows) {
        check();
        const symbolHeight = row.mark ? 2 * number(row.markSize ?? 2) * pt : row.bars ? 6 : 0;
        const h = legendRowHeight(row.label.lastBaseY, em, pt, symbolHeight),
          cy = y + h / 2,
          ink = paint(row.style.draw || '#000000');
        if (row.bars) {
          const bar = svg('rect', { x: 2, y: cy - 3, width: swatch - 4, height: 6 });
          stroke(bar, row.style);
          content.append(bar);
        } else if (!row.onlyMarks) {
          const line = svg('path', { d: 'M0 ' + cy + 'h' + swatch });
          stroke(line, row.style);
          content.append(line);
        }
        if (row.mark) {
          const r = number(row.markSize ?? 2) * pt;
          // Same outlines as PGFPlotsPlane.drawMark, in units of the mark size with y up. Only a
          // starred mark is filled, as on the plot.
          const closed = row.mark.includes('*');
          const glyph = svg('g', {
            transform: 'translate(' + swatch / 2 + ' ' + cy + ')',
            stroke: ink,
            fill: closed ? (row.markFill ? paint(row.markFill) : ink) : 'none',
            'stroke-width': size(row.style['line width'] || '.4pt')
          });
          const k = Math.SQRT1_2,
            polar = (a) => [Math.cos(a * radians), Math.sin(a * radians)];
          const segments = (...pairs) => pairs.map((pair) => ({ points: pair }));
          const shapes = {
            square: [{ points: [[-1, -1], [1, -1], [1, 1], [-1, 1]], close: true }],
            triangle: [{ points: [[0, 1.33], [-1.15, -0.665], [1.15, -0.665]], close: true }],
            diamond: [{ points: [[0, 1.3], [1, 0], [0, -1.3], [-1, 0]], close: true }],
            pentagon: [{ points: [90, 18, -54, 234, 162].map(polar), close: true }],
            x: segments([[-1, -1], [1, 1]], [[-1, 1], [1, -1]]),
            '+': segments([[-1, 0], [1, 0]], [[0, -1], [0, 1]]),
            '|': segments([[0, 1], [0, -1]]),
            '-': segments([[1, 0], [-1, 0]]),
            star: segments(...[0, 1, 2, 3, 4].map((i) => [[0, 0], polar(90 + i * 72)])),
            asterisk: segments([[0, -1], [0, 1]], [polar(30), polar(210)], [polar(-30), polar(150)]),
            otimes: segments([[-k, -k], [k, k]], [[-k, k], [k, -k]])
          };
          shapes.oplus = shapes['+'];
          const name = row.mark.length > 1 ? row.mark.replace(/\*$/, '') : row.mark;
          const circled = ['*', 'o', 'oplus', 'otimes'].includes(name);
          if (circled) glyph.append(svg('circle', { r }));
          if (name !== '*' && name !== 'o') {
            const outline = shapes[name] || fail('mark');
            const d = outline
              .map((s) => s.points.map(([x, y], i) => (i ? 'L' : 'M') + x * r + ' ' + -y * r).join('') + (s.close ? 'Z' : ''))
              .join('');
            // A line drawn over a filled circle keeps the plot's stroke and adds no fill of its own.
            glyph.append(svg('path', circled ? { d, fill: 'none' } : { d }));
          }
          content.append(glyph);
        }
        row.label.group.setAttribute(
          'transform',
          'translate(' + (swatch + padding + legendCellOffset(item.cellAlign ?? 'center', cell - row.label.w)) + ' ' + (cy - (row.label.lastBaseY + 0.15 * em) / 2) + ')'
        );
        content.append(row.label.group);
        y += h;
      }
      place(item, { 'inner sep': padding + 'px', ...item.style }, resolve(item.at, item.style), 0, {
        w,
        h: y,
        baseY: 0,
        group
      });
    }
    for (const item of scene.items) {
      check();
      if (item.kind === 'scope') {
        layers.push(layer);
      } else if (item.kind === 'endScope') {
        if (!layers.length) fail('scope');
        layer = layers.pop();
      } else if (item.kind === 'path' || item.kind === 'clip') path(item);
      else if (item.kind === 'matrix') drawMatrix(item);
      else if (item.kind === 'legend') legend(item);
      else if (item.kind === 'coordinate') {
        const p = resolve(item.at || { x: 0, y: 0 }, item.style);
        names.set(item.name, { p, w: 0, h: 0, rot: 0, sep: 0 });
      } else if (item.kind === 'node') {
        const p = resolve(item.at || { x: 0, y: 0 }, item.style);
        place(item, item.style, p);
      } else fail(item.kind);
    }
    if (layers.length) fail('scope');
    for (const [shape, style] of hatched) vectorHatch(shape, style);
    if (usedFaces.size) {
      const fonts = embeddedFaces(),
        css = [];
      for (const key of usedFaces) {
        if (unavailableFaces.has(key)) fail('font');
        if (fonts.has(key)) css.push(fonts.get(key).css);
        else if (key.startsWith('KaTeX_')) fail('math font');
      }
      if (css.length) {
        const style = svg('style');
        style.textContent = css.join('\n');
        definitions.prepend(style);
      }
    }
    function visibleBox(group, depth = 0) {
      if (depth > 64) fail('clip depth');
      let left = Infinity,
        top = Infinity,
        right = -Infinity,
        bottom = -Infinity;
      for (const child of group.children) {
        check();
        if (clips.has(child)) {
          const b = visibleBox(child, depth + 1),
            clip = clips.get(child);
          if (!b) continue;
          const x1 = Math.max(b.x, clip.x),
            y1 = Math.max(b.y, clip.y);
          const x2 = Math.min(b.x + b.width, clip.x + clip.width),
            y2 = Math.min(b.y + b.height, clip.y + clip.height);
          if (x1 > x2 || y1 > y2) continue;
          left = Math.min(left, x1);
          top = Math.min(top, y1);
          right = Math.max(right, x2);
          bottom = Math.max(bottom, y2);
        } else {
          const b = child.getBBox();
          const m = child.transform?.baseVal.consolidate()?.matrix;
          for (const x of [b.x, b.x + b.width])
            for (const y of [b.y, b.y + b.height]) {
              const p = m ? new DOMPoint(x, y).matrixTransform(m) : { x, y };
              left = Math.min(left, p.x);
              top = Math.min(top, p.y);
              right = Math.max(right, p.x);
              bottom = Math.max(bottom, p.y);
            }
        }
      }
      return right >= left ? { x: left, y: top, width: right - left, height: bottom - top } : null;
    }
    // getBBox omits stroke width. Include each pen and fallback glyph guard in
    // its own transformed, clipped group so an interior mark cannot inflate the whole figure.
    const guards = [];
    for (const [element, margin] of inkGuards) {
      check();
      if (!content.contains(element)) continue;
      const b = element.getBBox();
      const guard = svg('rect', {x:b.x-margin, y:b.y-margin, width:b.width+2*margin, height:b.height+2*margin, fill:'none'});
      if (element.hasAttribute('transform')) guard.setAttribute('transform', element.getAttribute('transform'));
      guards.push([element, guard]);
    }
    for (const [element, guard] of guards) element.after(guard);
    const box = clips.size ? visibleBox(content) : content.getBBox();
    for (const [, guard] of guards) guard.remove();
    if (!box) fail('empty picture');
    if (!box.width || !box.height) padding = Math.max(0.5, padding);
    padding += fallbackFontMargin;
    const w = number(box.width + padding * 2),
      h = number(box.height + padding * 2);
    if (!w || !h) fail('empty picture');
    root.setAttribute('viewBox', [number(box.x - padding), number(box.y - padding), w, h].join(' '));
    root.setAttribute('width', (w / pt) * (72 / 72.27) + 'pt');
    root.setAttribute('height', (h / pt) * (72 / 72.27) + 'pt');
    let spacing = 2;
    for (const k of [
      'marginTop',
      'marginBottom',
      'paddingTop',
      'paddingBottom',
      'borderTopWidth',
      'borderBottomWidth'
    ])
      spacing += parseFloat(css[k]) || 0;
    const scale = Math.min(1, Math.max(1, pageHeight / zoom - spacing) / h);
    root.style.cssText =
      'display:block;margin:auto;max-width:100%;height:auto;width:' +
      w * scale +
      'px;direction:ltr;letter-spacing:normal;word-spacing:normal;text-transform:none';
    check();
    const original = block.querySelector('.latex-unsupported')?.dataset.source;
    if (original !== undefined) block.dataset.source = original;
    block.removeAttribute('data-scene');
    block.replaceChildren(root);
    globalThis.surimonoRenderedDiagrams?.add(root);
    failure = '';
  } catch (err) {
    failure = String(err?.message || 'layout').slice(0, 100);
    const note = block.querySelector('.latex-unsupported');
    if (note) note.dataset.issue = (note.dataset.issue || note.textContent) + ' (' + failure + ')';
  } finally {
    scratch.remove();
    if (failure) root.remove();
  }
}
return 'ok';
