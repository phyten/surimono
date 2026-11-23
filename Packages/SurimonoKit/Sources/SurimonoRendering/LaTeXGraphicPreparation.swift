import Foundation

/// Only layout knows a tabular's natural width and the decoded image dimensions.
/// Measure after resources and fonts settle and keep the scaled box in the page flow.
enum LaTeXGraphicPreparation {
    static func script(in html: String, layoutWidth: Double, layoutHeight: Double? = nil) -> String? {
        let thinSpaces = html.contains("\u{2009}")
        let japaneseAbstract = html.contains(#"class="latex-front-abstract" lang="ja""#)
        let bibliography = html.contains(" data-latex-bib-sample=")
        let tables = html.contains(#"class="latex-tabular"#)
        let graphics = html.contains(#"class="latex-graphic-box""#)
        let displays = html.contains(#"class="math math-display""#)
        let exam = html.contains("<svg data-exam-rules ")
        let letters = html.contains(#"class="latex-letter""#) ? layoutHeight : nil
        guard japaneseAbstract || bibliography || thinSpaces || tables || graphics || displays || exam || letters != nil
        else {
            return nil
        }
        return """
            {
              const root = document.documentElement;
              const oldWidth = root.style.width;
              const zoom = parseFloat(getComputedStyle(root).zoom) || 1;
              root.style.width = (\(layoutWidth) / zoom) + 'px';
              try {
                \(japaneseAbstract ? japaneseAbstractGlue : "")
                \(bibliography ? measureLabels : "")
                \(thinSpaces ? tieThinSpaces : "")
                \(displays ? measureDisplays : "")
                \(tables ? tableStruts : "")
                \(graphics ? measure : "")
                \(exam ? examRules : "")
                \(letters.map { "const availableHeight = \($0) / zoom;\n" + letterGlue } ?? "")
              } finally { root.style.width = oldWidth; }
            }
            """
    }

    // WebKit's implicit autospace has no text of its own. PDFKit can omit it when the
    // neighbouring CFF glyph has a large font bounding box. Paint the JFM glue on paper.
    private static let japaneseAbstractGlue = #"""
        for (const abstract of document.querySelectorAll('[data-latex-publication-grid="bilingualJournal"]:not([data-latex-local-main-font]) .latex-front-abstract[lang="ja"] p')) {
          const walker = document.createTreeWalker(abstract, NodeFilter.SHOW_TEXT);
          const nodes = [];
          for (let text = walker.nextNode(); text; text = walker.nextNode()) {
            if (!text.parentElement.closest('svg,code,.math-inline,.latex-xkanjiskip')) nodes.push(text);
          }
          for (const text of nodes) {
            const boundaries = text.data.matchAll(/(?<=[a-zA-Z0-9])(?=[\p{sc=Han}\p{sc=Hiragana}\p{sc=Katakana}])/gu);
            const parts = document.createDocumentFragment();
            let start = 0;
            for (const boundary of boundaries) {
              parts.append(text.data.slice(start, boundary.index));
              const glue = document.createElement('span');
              glue.className = 'latex-abstract-xskip';
              parts.append(glue);
              start = boundary.index;
            }
            if (start) { parts.append(text.data.slice(start)); text.replaceWith(parts); }
          }
        }
        """#

    // offsetWidth rounds small bracket advances to whole pixels. The computed
    // max-content width is in layout units even when the print view is zoomed.
    private static let measureLabels = """
        for (const list of document.querySelectorAll('ol[data-latex-bib-sample]')) {
          const sample = document.createElement('span');
          sample.style.cssText = 'position:absolute;visibility:hidden;white-space:pre;width:max-content;font:inherit';
          sample.textContent = list.dataset.latexBibSample;
          list.append(sample);
          list.style.setProperty('--latex-bib-measured', getComputedStyle(sample).width);
          sample.remove();
        }
        """

    // A text-mode thin space is a kern in TeX. The stored HTML may still use U+2009,
    // whose Unicode line-break class permits a break before the following unit.
    static let tieThinSpaces = #"""
        for (const root of [document.body, ...Array.from(document.querySelectorAll('template'), t => t.content)]) {
          const text = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
          for (let node = text.nextNode(); node; node = text.nextNode()) {
            if (node.data.includes('\u2009') && !node.parentElement?.closest('pre,code,svg,math,style,script,textarea')) {
              node.data = node.data.replaceAll('\u2009', '\u202f');
            }
          }
        }
        """#

    // letter.cls distributes spare space 3:5. In a PDF only the leading glue has to
    // participate in pagination. A full-height flex box can push its empty tail onto another sheet.
    private static let letterGlue = """
        const letters = [...document.querySelectorAll('.latex-letter')];
        for (const letter of letters) letter.style.removeProperty('--latex-letter-top-glue');
        const heights = letters.map(letter => parseFloat(getComputedStyle(letter).height));
        letters.forEach((letter, i) => {
          const glue = (availableHeight - heights[i]) * 3 / 8;
          if (glue > 0) letter.style.setProperty('--latex-letter-top-glue', glue + 'px');
        });
        """

    // A cleaders box centers an integral number of pitches. Non-scaling PDF strokes keep
    // their thickness even when a question is printed at a different column width.
    private static let examRules = """
        for (const svg of document.querySelectorAll('svg[data-exam-rules]')) {
          const path = svg.querySelector('path');
          if (!path) continue;
          const h = parseFloat(getComputedStyle(svg).height);
          const pitch = parseFloat(getComputedStyle(path).fontSize);
          const count = Math.floor(h / pitch + 1e-7);
          if (!(h > 0 && pitch > 0 && Number.isFinite(count))) continue;
          // Subpixel pitches can request more strokes than a page can resolve.
          const step = Math.max(1, Math.ceil(count / 4096));
          const inset = (h - count * pitch) / 2;
          const lines = [];
          for (let i = 1; i <= count; i += step) {
            lines.push('M0 ' + (inset + i * pitch) + ' H1');
          }
          svg.setAttribute('viewBox', '0 0 1 ' + h);
          path.setAttribute('d', lines.join(' '));
        }
        """

    static let glyphInk = """
        function glyphInk(context, glyph, userSize) {
            const css = getComputedStyle(glyph);
            context.font = css.fontStyle + ' ' + css.fontWeight + ' 1000px ' + css.fontFamily;
            const ink = context.measureText(glyph.textContent);
            const scale = (userSize ?? parseFloat(css.fontSize)) / 1000;
            const gx = glyph.x.baseVal.getItem(0).value, gy = glyph.y.baseVal.getItem(0).value;
            return [gx - scale * ink.actualBoundingBoxLeft, gy - scale * ink.actualBoundingBoxAscent,
                    gx + scale * ink.actualBoundingBoxRight, gy + scale * ink.actualBoundingBoxDescent];
        }
        """

    /// SwaTex reports TeX advance, ascent and depth. SVG text runs use the actual embedded
    /// fonts' metrics, which can extend past all three. Include those runs in the page flow
    /// before clipping the SVG so pagination cannot paint its overflow on the preceding sheet.
    static let measureDisplays = #"""
        \#(glyphInk)
        // getBBox() on SVG text measures the font cell. Canvas ink metrics use
        // the loaded outline, including delimiters extending below that cell.
        const context = document.createElement('canvas').getContext('2d');
        let clipIndex = 0;
        function encloseInk(svg, x, y, w, h) {
          let left = x, top = y, right = x + w, bottom = y + h;
          if (!context) return;
          for (const glyph of svg.querySelectorAll('text')) {
            const [l,t,r,b] = glyphInk(context,glyph);
            left = Math.min(left,l); top = Math.min(top,t);
            right = Math.max(right,r); bottom = Math.max(bottom,b);
          }
          // Quartz rounds the printed clipping edge. Leave a clear border around
          // the ink but keep the TeX baseline and WebKit's measured layout box.
          const pad = 1;
          const make = name => document.createElementNS(svg.namespaceURI, name);
          const group = make('g'), clip = make('clipPath'), rect = make('rect'), defs = make('defs');
          let id;
          do { id = 'surimono-math-ink-' + clipIndex++; } while (document.getElementById(id));
          rect.setAttribute('x', left - pad);
          rect.setAttribute('y', top - pad);
          rect.setAttribute('width', right - left + 2 * pad);
          rect.setAttribute('height', bottom - top + 2 * pad);
          clip.id = id;
          clip.append(rect);
          defs.append(clip);
          // Clip the paint group in its own user coordinates. A CSS clip on the
          // outer SVG creates a stacking context and can reorder PDF text.
          group.setAttribute('clip-path', 'url(#' + id + ')');
          while (svg.firstChild) group.append(svg.firstChild);
          svg.append(defs, group);
        }
        for (const svg of document.querySelectorAll('body.format-latex .math-display > svg')) {
          if (svg.querySelector(':scope > defs > clipPath[id^=surimono-math-ink-]')) continue;
          const box = svg.viewBox.baseVal;
          const width = svg.width.baseVal, height = svg.height.baseVal;
          // The converter writes dimensions in em (SVG_LENGTHTYPE_EMS = 3).
          if (width.unitType !== 3 || height.unitType !== 3 || !(box.width > 0 && box.height > 0)) continue;
          const ink = svg.getBBox();
          const x = Math.min(box.x, ink.x), y = Math.min(box.y, ink.y);
          const w = Math.max(box.x + box.width, ink.x + ink.width) - x;
          const h = Math.max(box.y + box.height, ink.y + ink.height) - y;
          if (!(Number.isFinite(w) && Number.isFinite(h) && w > 0 && h > 0)) continue;
          const math = svg.parentElement;
          if (math.closest('[data-latex-js-toc],[data-latex-style],[data-latex-publication-grid]')
              && svg.dataset.latexTexTop === undefined) {
            // Expanding the viewport protects the glyph ink. Save the original TeX box and
            // its baselines before verticalAlign becomes "top" for the prepared block.
            const depth = -parseFloat(svg.style.verticalAlign) / height.valueInSpecifiedUnits;
            const first = Number(math.dataset.latexFirstBaseline ?? 1 - depth);
            const last = Number(math.dataset.latexLastBaseline ?? 1 - depth);
            if (Number.isFinite(first) && Number.isFinite(last)) {
              svg.dataset.latexTexTop = box.y;
              svg.dataset.latexTexBottom = box.y + box.height;
              svg.dataset.latexTexFirst = box.y + first * box.height;
              svg.dataset.latexTexLast = box.y + last * box.height;
            }
          }
          if (w !== box.width || h !== box.height) {
            for (const label of svg.parentElement.querySelectorAll(':scope > .latex-row-number')) {
              const old = parseFloat(label.style.top);
              if (Number.isFinite(old)) label.style.top = (old * box.height + 100 * (box.y - y)) / h + '%';
            }
            svg.setAttribute('width', (width.valueInSpecifiedUnits * w / box.width) + 'em');
            svg.setAttribute('height', (height.valueInSpecifiedUnits * h / box.height) + 'em');
            svg.setAttribute('viewBox', [x,y,w,h].join(' '));
          }
          Object.assign(svg.style, {display:'block', marginInline:'auto', verticalAlign:'top', overflow:'visible'});
          encloseInk(svg,x,y,w,h);
        }
        """#

    // A simple tabular starts each row with an array strut. Preserve paragraph columns
    // and multiline cells, which establish their own line boxes.
    private static let tableStruts = #"""
        const tables = document.querySelectorAll('.latex-graphic-box table.latex-tabular, figure.latex-table > table.latex-tabular:not(.latex-longtable)');
        for (const table of tables) {
          // Journals can set a separate table pitch; their unscaled tables already use that class strut.
          if (!table.closest('.latex-graphic-box') && document.body.hasAttribute('data-latex-journal')) continue;
          const style = getComputedStyle(table);
          // CSSOM may serialize a multi-word family as a string or as unquoted identifiers.
          const family = style.fontFamily.split(',')[0].trim().replace(/^["']|["']$/g, '').toLowerCase();
          if (!table.matches(':lang(en)') || !style.getPropertyValue('--tex-pt') ||
              family !== 'surimono computer modern') continue;
          for (const cell of table.querySelectorAll(':scope > :is(tbody,thead,tfoot) > tr > :is(td,th):not([data-latex-column])')) {
            if (cell.querySelector('br,p,div,table,.latex-array-strut')) continue;
            const strut = document.createElement('span');
            strut.className = 'latex-array-strut';
            cell.prepend(strut);
          }
        }
        """#

    static let measure = #"""
        const boxes = Array.from(document.querySelectorAll('body.format-latex .latex-graphic-box'));
        // A sampler can reuse this DOM with a different font, body measure or zoom.
        for (const box of boxes) {
          const ink = box.firstElementChild;
          if (!ink) continue;
          Object.assign(box.style, {display:'inline-block', position:'relative', verticalAlign:'bottom',
            textIndent:'0', maxWidth:'none', width:'var(--latex-target-width, auto)',
            height:'var(--latex-target-height, auto)', overflow:'visible'});
          Object.assign(ink.style, {display:'inline-block', position:'static', margin:'0',
            maxWidth:'none', width:'max-content', height:'auto', transform:'none', verticalAlign:'top'});
        }
        // An outer resize must measure the already-sized inner box.
        for (const box of boxes.reverse()) {
          const ink = box.firstElementChild;
          if (!ink) continue;
          let w, h;
          const crop = box.dataset.latexCrop;
          if (crop) {
            const img = ink.firstElementChild;
            if (!img?.naturalWidth || !img.naturalHeight) continue;
            const [l,b,r,t] = crop.split(' ').map(Number);
            const intrinsic = box.dataset.latexIntrinsic?.split(' ').map(Number);
            const iw = intrinsic?.[0] || img.naturalWidth, ih = intrinsic?.[1] || img.naturalHeight;
            w = iw - l - r; h = ih - b - t;
            if (!(w > 0 && h > 0)) continue;
            Object.assign(ink.style, {position:'relative', overflow:'hidden', width:w+'px', height:h+'px'});
            Object.assign(img.style, {display:'block', position:'absolute', maxWidth:'none', maxHeight:'none',
              width:iw+'px', height:ih+'px', top:-t+'px', left:-l+'px', margin:'0'});
          } else {
            const natural = getComputedStyle(ink);
            w = parseFloat(natural.width); h = parseFloat(natural.height);
          }
          if (!(w > 0 && h > 0)) continue;
          const target = getComputedStyle(box);
          const tw = box.style.getPropertyValue('--latex-target-width') ? parseFloat(target.width) : null;
          const th = box.style.getPropertyValue('--latex-target-height') ? parseFloat(target.height) : null;
          let [sx,sy,angle] = box.dataset.latexTransform.split(' ').map(Number);
          if (tw !== null && th !== null && box.dataset.keepRatio === 'true') {
            const fit = Math.min(tw/w, th/h); sx *= fit; sy *= fit;
          } else {
            const naturalScale = crop ? (parseFloat(target.getPropertyValue('--tex-pt')) || 96/72.27)*72.27/72 : 1;
            sx *= tw !== null ? tw/w : th !== null ? th/h : naturalScale;
            sy *= th !== null ? th/h : tw !== null ? tw/w : naturalScale;
          }
          const radians = angle * Math.PI/180, cos = Math.cos(radians), sin = Math.sin(radians);
          const a = sx*cos, b = sx*sin, c = -sy*sin, d = sy*cos;
          const width = Math.abs(a*w) + Math.abs(c*h), height = Math.abs(b*w) + Math.abs(d*h);
          if (!Number.isFinite(width) || !Number.isFinite(height)) continue;
          const tx = -Math.min(0,a*w) - Math.min(0,c*h), ty = -Math.min(0,b*w) - Math.min(0,d*h);
          Object.assign(box.style, {width:width+'px', height:height+'px', overflow:'hidden'});
          Object.assign(ink.style, {position:'absolute', top:'0', left:'0', transformOrigin:'0 0',
            transform:'matrix('+[a,b,c,d,tx,ty].join(',')+')'});
        }
        """#
}
