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
  // Measured on the canvas: these are the faces WebKit gives each generic when no language applies.
  const faces = {'sans-serif': 'Helvetica', serif: 'Times', monospace: 'Courier'};
  for (const node of svg.querySelectorAll('[font-family]')) {
    // Split at commas outside quotes. A quoted name ('serif') is a font name, not the generic.
    const families = node.getAttribute('font-family').match(/(?:"[^"]*"|'[^']*'|[^,"'])+/g) || [];
    const named = families.map(family => {
      const face = faces[family.trim().toLowerCase()];
      return face ? face + ', ' + family.trim() : family.trim();
    }).join(', ');
    if (named !== families.map(family => family.trim()).join(', ')) node.setAttribute('font-family', named);
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
      }) : Promise.resolve().then(() => renderGraphviz(text, block, index)),
      new Promise((_, reject) => { timer = setTimeout(() => {
        stopped = true; reject(new Error('Diagram timed out'));
      }, remaining); })
    ]);
    // A synchronous layout can occupy the JS thread; do not accept its result after the budget expired.
    if (performance.now() > deadline) { stopped = true; throw new Error('Diagram timed out'); }
    const svg = checkedSVG(svgText, plant, 'surimono-diagram-' + index + '-');
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

// Parses an engine's SVG and refuses anything a diagram must not carry. IDs get the prefix so that gradients and
// local references stay in their own diagram (both engines reuse IDs in separate SVGs). Runs before the SVG enters
// the document, for the measuring copy as well as the printed one.
function checkedSVG(svgText, plant, prefix) {
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
  const ids = new Map();
  for (const node of svg.querySelectorAll('[id]')) {
    const old = node.id;
    const fresh = prefix + old;
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
  return svg;
}

// Viz has no font files. It estimates label widths from built-in tables (Helvetica has one; a family list such as
// 'Helvetica, Hiragino Sans' falls back to Times), and counts each UTF-8 byte outside them as a space, so a Japanese
// character comes out near 0.83 em. Lay the graph out once, measure its node labels as this page draws them, and
// lay it out again with each short node padded by the difference. A graph that cannot be safely rewritten keeps its
// first layout.
function renderGraphviz(text, block, index) {
  // These are defaults: attributes in the user's DOT take precedence, including graph layout= and overlap=.
  // sfdp's default overlap removal needs a triangulation library that Viz is built without.
  const font = {fontname: 'Helvetica'};
  const options = {engine: 'dot', graphAttributes: {...font, overlap: 'false'}, nodeAttributes: font,
    edgeAttributes: font};
  const started = performance.now();
  const first = graphvizOutput(text, ['svg', 'json'], options);
  // The second layout takes about as long as the first. Start it only while the budget still holds one, so that a
  // correction never costs the diagram its first, complete layout.
  const layoutTime = performance.now() - started;
  const affordable = () => performance.now() + layoutTime < deadline;
  try {
    const widened = affordable() ? widenedGraph(text, first, block, index) : null;
    if (!widened || !affordable()) return first.svg;
    const second = graphvizOutput(widened, ['svg'], options).svg;
    return graphvizShape(second) === graphvizShape(first.svg) ? second : first.svg;
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

// The nodes, edges and clusters a layout drew. Appended statements may change sizes only, never this.
function graphvizShape(svgText) {
  const svg = new DOMParser().parseFromString(svgText, 'image/svg+xml');
  return JSON.stringify(Array.from(svg.querySelectorAll('g.node > title,g.edge > title,g.cluster > title'),
    title => title.parentNode.getAttribute('class') + ' ' + title.textContent).sort());
}

// Returns the DOT with a margin appended for every node whose drawn label reaches past what Graphviz estimated, or
// null when nothing needs it or the source cannot be safely rewritten.
function widenedGraph(text, first, block, index) {
  const end = graphClosingBrace(text);
  if (end < 0) return null;
  const graph = JSON.parse(first.json);
  // Measure inside the block, with the same inherited language and spacing overrides as the final diagram.
  const probe = document.importNode(checkedSVG(first.svg, false, 'surimono-measure-' + index + '-'), true);
  probe.style.cssText = 'position:absolute;visibility:hidden;letter-spacing:normal;word-spacing:normal;' +
    'text-transform:none';
  block.append(probe);
  const drawn = new Map();
  try {
    for (const title of probe.querySelectorAll('g.node > title')) {
      drawn.set(title.textContent, Array.from(title.parentNode.querySelectorAll('text'),
        line => [line.textContent, line.getComputedTextLength()]));
    }
  } finally {
    probe.remove();
  }
  const statements = [];
  for (const node of (graph.objects || []).slice(graph._subgraph_cnt || 0)) {
    const name = String(node.name ?? '');
    const operations = node._ldraw_ || [];
    const lines = operations.filter(operation => operation.op === 'T');
    const lengths = drawn.get(name);
    const shape = String(node.shape || 'ellipse').toLowerCase();
    // Plain text labels only: HTML-like labels (formatting, tables), record fields, fixed sizes and external
    // labels are laid out by rules a margin does not follow, and Graphviz sizes a plain node from its label
    // whatever its margin or width. A backslash or line break cannot be quoted back.
    if (!lengths || !lines.length || lengths.length !== lines.length || /[\\\r\n]/.test(name) ||
        lines.some((line, at) => line.text !== lengths[at][0] || !['l', 'c', 'r'].includes(line.align)) ||
        operations.some(operation => !['F', 'c', 'T'].includes(operation.op)) ||
        String(node.label ?? '').startsWith('<') || ['record', 'mrecord', 'plain'].includes(shape) ||
        /^(true|yes|shape|[1-9])/i.test(String(node.fixedsize ?? '')) || node.xlabel) continue;
    // Each line keeps its anchor (left end for \l, centre, right end for \r); compare how far the estimated and the
    // drawn lines reach on either side. The margin grows equally on both sides, so it takes the larger need.
    const reach = width => lines.map((line, at) => {
      const length = width(line, at);
      const left = line.align === 'l' ? line.pt[0] : line.align === 'r' ? line.pt[0] - length : line.pt[0] - length / 2;
      return [left, left + length];
    });
    const estimated = reach(line => line.width), measured = reach((line, at) => lengths[at][1]);
    const side = Math.max(
      Math.min(...estimated.map(([left]) => left)) - Math.min(...measured.map(([left]) => left)),
      Math.max(...measured.map(([, right]) => right)) - Math.max(...estimated.map(([, right]) => right)));
    if (!(side > 0.5)) continue;
    // Graphviz pads a label by 8 by 4 points on each side unless the node sets margin (inches, x or x,y). A point
    // of slack absorbs rounding in its own sizes.
    let padX = 8, padY = 4;
    if (node.margin) {
      const [x, y = x] = String(node.margin).split(',').map(parseFloat);
      if (!(x >= 0 && y >= 0)) continue;
      padX = x * 72; padY = y * 72;
    }
    statements.push(`"${name.replace(/"/g, '\\"')}" [margin="${((padX + side + 1) / 72).toFixed(4)},` +
      `${(padY / 72).toFixed(4)}"];`);
  }
  if (!statements.length) return null;
  // Statements for existing nodes only set their attributes, keeping their subgraph membership and order.
  return text.slice(0, end) + '\n' + statements.join('\n') + '\n' + text.slice(end);
}

// The index of the brace that closes the source's one graph, skipping strings, HTML-like IDs and comments; -1 when
// there is not exactly one graph, anything but space and comments follows it, or the braces do not balance.
function graphClosingBrace(text) {
  let depth = 0, end = -1;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (c === '/' && text[i + 1] === '/' || c === '#') {
      // The bundled Graphviz (16.1) reads # as a line comment anywhere outside a string, not only at a line start.
      i = text.indexOf('\n', i);
      if (i < 0) break;
    } else if (c === '/' && text[i + 1] === '*') {
      i = text.indexOf('*/', i + 2);
      if (i < 0) return -1;
      i++;
    } else if (end >= 0) {
      if (!/\s/.test(c)) return -1;
    } else if (c === '"') {
      // DOT's only escape inside a quoted string is \" (a doubled backslash is two characters).
      for (i++; i < text.length && text[i] !== '"'; i++) if (text[i] === '\\' && text[i + 1] === '"') i++;
      if (i >= text.length) return -1;
    } else if (c === '<') {
      let nested = 1;
      for (i++; i < text.length && nested; i++) nested += text[i] === '<' ? 1 : text[i] === '>' ? -1 : 0;
      if (nested) return -1;
      i--;
    } else if (c === '{') {
      depth++;
    } else if (c === '}') {
      if (--depth < 0) return -1;
      if (depth === 0) end = i;
    }
  }
  return depth === 0 ? end : -1;
}
