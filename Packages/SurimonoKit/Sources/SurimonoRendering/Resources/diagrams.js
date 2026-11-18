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
      }) : Promise.resolve().then(() => {
        // These are defaults: attributes in the user's DOT take precedence, including graph layout=.
        const defaults = {fontname: 'Helvetica, Hiragino Sans'};
        return globalThis.surimonoViz.renderString(text, {format: 'svg', engine: 'dot',
          graphAttributes: defaults, nodeAttributes: defaults, edgeAttributes: defaults});
      }),
      new Promise((_, reject) => { timer = setTimeout(() => {
        stopped = true; reject(new Error('Diagram timed out'));
      }, remaining); })
    ]);
    // A synchronous layout can occupy the JS thread; do not accept its result after the budget expired.
    if (performance.now() > deadline) { stopped = true; throw new Error('Diagram timed out'); }
    const parsed = new DOMParser().parseFromString(svgText, 'image/svg+xml');
    const svg = parsed.documentElement;
    if (svg.localName !== 'svg' || parsed.querySelector('parsererror')) throw new Error('Invalid SVG');
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
