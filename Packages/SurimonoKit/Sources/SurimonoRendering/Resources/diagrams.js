// Runs only in the retained surimono world, after resources have been blocked.
const deadline = performance.now() + budget;
const times = [];
// WebKit slows the timers of a page that is not on screen to one a second, and PlantUML yields through
// zero-delay timers: a document with twenty diagrams took a second for each one after the tenth. Timers with no
// delay go through a message channel instead, in this world only.
if (!globalThis.surimonoTimers) {
  globalThis.surimonoTimers = true;
  const nativeSetTimeout = globalThis.setTimeout.bind(globalThis);
  const pending = [];
  const channel = new MessageChannel();
  channel.port1.onmessage = () => pending.shift()?.();
  globalThis.setTimeout = (callback, delay, ...rest) => {
    if (delay > 0 || typeof callback !== 'function') return nativeSetTimeout(callback, delay, ...rest);
    pending.push(() => callback(...rest));
    channel.port2.postMessage(0);
    return 0;
  };
}
// PlantUML sizes every label by measuring it on a canvas outside the document, where a generic family resolves to
// WebKit's face for no language. The page's lang draws the same generic in another face (Hiragino Sans for ja),
// wider than the box around it. Naming the measured face first keeps the drawn width equal to the measured one;
// characters that face lacks still fall back through the generic, as they did on the canvas.
function nameMeasuredFaces(svg) {
  const faces = {'sans-serif': 'Helvetica', serif: 'Times', monospace: 'Courier'};
  for (const node of svg.querySelectorAll('[font-family]')) {
    const families = node.getAttribute('font-family').split(',').map(family => family.trim());
    node.setAttribute('font-family', families.map(family => {
      const face = faces[family.replace(/^['"]|['"]$/g, '').toLowerCase()];
      return face ? face + ', ' + family : family;
    }).join(', '));
  }
}
let stopped = false;
const sources = document.querySelectorAll('.graphviz-block > .diagram-source,.plantuml-block > .diagram-source');
for (const [index, source] of Array.from(sources).entries()) {
  const block = source.parentElement;
  const plant = block.classList.contains('plantuml-block');
  const started = performance.now();
  let timer;
  try {
    const text = source.textContent;
    if (new TextEncoder().encode(text).length > 200000) throw new Error('Diagram too large (200 KB maximum)');
    if (stopped || started >= deadline) throw new Error('Diagram timed out');
    const remaining = deadline - started;
    const svgText = await Promise.race([
      plant ? new Promise((resolve, reject) => {
        globalThis.surimonoPlantUML.renderToString(text.split(/\r\n|\r|\n/), resolve, reject,
          {dark: false, maxSvgSize: 8192});
      }) : Promise.resolve().then(() => renderGraphviz(text, block)),
      new Promise((_, reject) => { timer = setTimeout(() => {
        stopped = true; reject(new Error('Diagram timed out'));
      }, remaining); })
    ]);
    // A synchronous layout can occupy the JS thread; do not accept its result after the budget expired.
    if (performance.now() > deadline) { stopped = true; throw new Error('Diagram timed out'); }
    const parsed = new DOMParser().parseFromString(svgText, 'image/svg+xml');
    const svg = parsed.documentElement;
    if (svg.localName !== 'svg' || parsed.querySelector('parsererror')) throw new Error('Invalid SVG');
    if (plant) nameMeasuredFaces(svg);
    // Upstream renders syntax/include failures as successful SVG callbacks. Recognize its error-page header,
    // not arbitrary labels saying 'error', and retain the complete source beside the engine's last message.
    const labels = Array.from(svg.querySelectorAll('text')).map(node => node.textContent.trim());
    if (plant && labels[0]?.startsWith('PlantUML version ') && /^\[From .+ \(line \d+\) \]/.test(labels[1] || '')) {
      throw new Error(labels[labels.length - 1] || 'Invalid PlantUML');
    }
    // Images, HTML and executable content cannot be silently dropped from a diagram.
    if (svg.querySelector('script,foreignObject,image,style,animate,animateTransform,set')) {
      throw new Error('Unsupported external or active SVG content');
    }
    for (const node of svg.querySelectorAll('a')) node.replaceWith(...node.childNodes);
    for (const node of [svg, ...svg.querySelectorAll('*')]) {
      for (const attribute of [...node.attributes]) {
        if (/^on/i.test(attribute.name) || /href$/i.test(attribute.name) && !attribute.value.startsWith('#') ||
            /url\(\s*['"]?(?!#)/i.test(attribute.value)) {
          throw new Error('Unsupported external or active SVG content');
        }
      }
    }
    // Both engines reuse IDs in separate SVGs. Namespace them so gradients and local references stay in their diagram.
    const ids = new Map();
    for (const node of svg.querySelectorAll('[id]')) {
      const old = node.id;
      const fresh = 'surimono-diagram-' + index + '-' + old;
      ids.set(old, fresh);
      node.id = fresh;
    }
    for (const node of [svg, ...svg.querySelectorAll('*')]) {
      for (const attribute of [...node.attributes]) {
        let value = attribute.value.replace(/url\(\s*['"]?#([^)'"\s]+)['"]?\s*\)/g,
          (match, id) => ids.has(id) ? 'url(#' + ids.get(id) + ')' : match);
        if (/href$/i.test(attribute.name) && value.startsWith('#') && ids.has(value.slice(1))) {
          value = '#' + ids.get(value.slice(1));
        }
        if (value !== attribute.value) node.setAttributeNS(attribute.namespaceURI, attribute.name, value);
      }
    }
    const width = svg.width.baseVal.value || svg.viewBox.baseVal.width;
    const height = svg.height.baseVal.value || svg.viewBox.baseVal.height;
    if (!(width > 0 && height > 0)) throw new Error('Invalid SVG dimensions');
    if (!svg.hasAttribute('viewBox')) svg.setAttribute('viewBox', `0 0 ${width} ${height}`);
    // Print themes must not recolour diagrams. Bound height as well as width, without enlarging small diagrams.
    const zoom = parseFloat(getComputedStyle(document.documentElement).zoom) || 1;
    const style = getComputedStyle(block);
    const spacing = ['marginTop', 'marginBottom', 'paddingTop', 'paddingBottom', 'borderTopWidth', 'borderBottomWidth']
      .reduce((total, property) => total + (parseFloat(style[property]) || 0), 2);
    const scale = Math.min(1, Math.max(1, pageHeight / zoom - spacing) / height);
    svg.style.cssText += `;width:${width * scale}px;max-width:100%;height:auto;display:block;margin:auto;background:white;color:black;direction:ltr;letter-spacing:normal;word-spacing:normal;text-transform:none`;
    const rendered = document.importNode(svg, true);
    block.replaceChildren(rendered);
    globalThis.surimonoRenderedDiagrams?.add(rendered);
    block.classList.remove('diagram-error');
  } catch (error) {
    block.classList.add('diagram-error');
    const message = block.querySelector('.diagram-message') || document.createElement('div');
    message.className = 'diagram-message';
    message.textContent = (plant ? 'PlantUML: ' : 'Graphviz: ') + String(error?.message || error).slice(0, 1000);
    if (!message.parentNode) block.prepend(message);
  } finally {
    clearTimeout(timer);
    times.push([plant ? 1 : 0, performance.now() - started]);
  }
}
return JSON.stringify(times);

// Viz has no font files. It estimates label widths from built-in tables (Helvetica has one; a family list such as
// 'Helvetica, Hiragino Sans' falls back to Times), and counts each UTF-8 byte outside them as a space, so a Japanese
// character comes out near 0.83 em. Lay the graph out once, measure its node labels as this page draws them, and
// lay it out again with each short node padded by the difference. A graph that cannot be safely rewritten keeps its
// first layout.
function renderGraphviz(text, block) {
  // These are defaults: attributes in the user's DOT take precedence, including graph layout= and overlap=.
  // sfdp's default overlap removal needs a triangulation library that Viz is built without.
  const font = {fontname: 'Helvetica'};
  const options = {engine: 'dot', graphAttributes: {...font, overlap: 'false'}, nodeAttributes: font,
    edgeAttributes: font};
  const started = performance.now();
  const first = graphvizOutput(text, ['svg', 'json'], options);
  // The second layout takes about as long as the first; keep the first rather than run out of the document budget.
  const widened = 2 * performance.now() - started < deadline ? widenedGraph(text, first, block) : null;
  if (!widened) return first.svg;
  try {
    const second = graphvizOutput(widened, ['svg'], options).svg;
    return graphvizNodeNames(second) === graphvizNodeNames(first.svg) ? second : first.svg;
  } catch {
    return first.svg;
  }
}

function graphvizOutput(text, formats, options) {
  const result = globalThis.surimonoViz.renderFormats(text, formats, options);
  if (result.status !== 'success') {
    throw new Error(result.errors.find(error => error.level === 'error')?.message || 'render failed');
  }
  return result.output;
}

function graphvizNodeNames(svgText) {
  const svg = new DOMParser().parseFromString(svgText, 'image/svg+xml');
  return JSON.stringify(Array.from(svg.querySelectorAll('g.node > title'), title => title.textContent).sort());
}

// Returns the DOT with a margin (or, for plain nodes, a width) appended for every node whose drawn label is wider
// than Graphviz estimated, or null when nothing needs it or the source cannot be safely rewritten.
function widenedGraph(text, first, block) {
  const end = graphClosingBrace(text);
  if (end < 0) return null;
  let graph;
  try { graph = JSON.parse(first.json); } catch { return null; }
  const svg = new DOMParser().parseFromString(first.svg, 'image/svg+xml').documentElement;
  if (svg.localName !== 'svg') return null;
  // Measure inside the block, with the same inherited language and spacing overrides as the final diagram.
  const probe = document.importNode(svg, true);
  probe.style.cssText = 'position:absolute;visibility:hidden;letter-spacing:normal;word-spacing:normal;' +
    'text-transform:none';
  block.append(probe);
  const drawn = new Map();
  try {
    for (const title of probe.querySelectorAll('g.node > title')) {
      drawn.set(title.textContent, Array.from(title.parentNode.querySelectorAll('text'),
        line => line.getComputedTextLength()));
    }
  } finally {
    probe.remove();
  }
  const statements = [];
  for (const node of (graph.objects || []).slice(graph._subgraph_cnt || 0)) {
    const name = String(node.name ?? '');
    const operations = node._ldraw_ || [];
    const estimates = operations.filter(operation => operation.op === 'T').map(operation => operation.width);
    const lengths = drawn.get(name);
    const shape = String(node.shape || 'ellipse').toLowerCase();
    // Plain text labels only: HTML-like labels (formatting, tables), record fields, fixed sizes and external
    // labels are laid out by rules a margin does not follow. A backslash or line break cannot be quoted back.
    if (!lengths || !estimates.length || lengths.length !== estimates.length || /[\\\r\n]/.test(name) ||
        operations.some(operation => !['F', 'c', 'T'].includes(operation.op)) ||
        String(node.label ?? '').startsWith('<') || shape === 'record' || shape === 'mrecord' ||
        /^(true|yes|shape|[1-9])/i.test(String(node.fixedsize ?? '')) || node.xlabel) continue;
    // A little slack absorbs rounding in Graphviz's own sizes.
    const extra = Math.max(...lengths) - Math.max(...estimates) + 2;
    if (!(extra > 2.5)) continue;
    let attribute;
    if (shape === 'plain') {
      // A plain node is exactly its label, with no margin to widen.
      const width = parseFloat(node.width);
      if (!(width >= 0)) continue;
      attribute = `width="${((width * 72 + extra) / 72).toFixed(4)}"`;
    } else {
      // Graphviz pads a label by 8 by 4 points on each side unless the node sets margin (inches, x or x,y).
      let padX = 16, padY = 8;
      if (node.margin) {
        const [x, y = x] = String(node.margin).split(',').map(parseFloat);
        if (!(x >= 0 && y >= 0)) continue;
        padX = x * 144; padY = y * 144;
      }
      attribute = `margin="${((padX + extra) / 144).toFixed(4)},${(padY / 144).toFixed(4)}"`;
    }
    statements.push(`"${name.replace(/"/g, '\\"')}" [${attribute}];`);
  }
  if (!statements.length) return null;
  // Statements for existing nodes only set their attributes, keeping their subgraph membership and order.
  return text.slice(0, end) + '\n' + statements.join('\n') + '\n' + text.slice(end);
}

// The index of the brace that closes the source's one graph, skipping strings, HTML-like IDs, comments and
// preprocessor lines; -1 when there is not exactly one graph or the braces do not balance.
function graphClosingBrace(text) {
  let depth = 0, end = -1;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (c === '"') {
      // DOT's only escape inside a quoted string is \" (a doubled backslash is two characters).
      for (i++; i < text.length && text[i] !== '"'; i++) if (text[i] === '\\' && text[i + 1] === '"') i++;
      if (i >= text.length) return -1;
    } else if (c === '<') {
      let nested = 1;
      for (i++; i < text.length && nested; i++) nested += text[i] === '<' ? 1 : text[i] === '>' ? -1 : 0;
      if (nested) return -1;
      i--;
    } else if (c === '/' && text[i + 1] === '/' || c === '#' && (i === 0 || text[i - 1] === '\n')) {
      i = text.indexOf('\n', i);
      if (i < 0) break;
    } else if (c === '/' && text[i + 1] === '*') {
      i = text.indexOf('*/', i + 2);
      if (i < 0) return -1;
      i++;
    } else if (end >= 0 && !/\s/.test(c)) {
      return -1;
    } else if (c === '{') {
      depth++;
    } else if (c === '}') {
      if (--depth < 0) return -1;
      if (depth === 0) end = i;
    }
  }
  return depth === 0 ? end : -1;
}
