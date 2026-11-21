import Foundation

/// Only layout knows a tabular's natural width and the decoded image dimensions.
/// Measure after resources and fonts settle and keep the scaled box in the page flow.
enum LaTeXGraphicPreparation {
    static func script(in html: String, layoutWidth: Double, layoutHeight: Double? = nil) -> String? {
        let thinSpaces = html.contains("\u{2009}")
        let graphics = html.contains(#"class="latex-graphic-box""#)
        let displays = html.contains(#"class="math math-display""#)
        let exam = html.contains("<svg data-exam-rules ")
        let letters = html.contains(#"class="latex-letter""#) ? layoutHeight : nil
        guard thinSpaces || graphics || displays || exam || letters != nil else { return nil }
        return """
            {
              const root = document.documentElement;
              const oldWidth = root.style.width;
              const zoom = parseFloat(getComputedStyle(root).zoom) || 1;
              root.style.width = (\(layoutWidth) / zoom) + 'px';
              try {
                \(thinSpaces ? tieThinSpaces : "")
                \(displays ? measureDisplays : "")
                \(graphics ? measure : "")
                \(exam ? examRules : "")
                \(letters.map { "const availableHeight = \($0) / zoom;\n" + letterGlue } ?? "")
              } finally { root.style.width = oldWidth; }
            }
            """
    }

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

    /// SwaTex reports TeX advance, ascent and depth. SVG text runs use the actual embedded
    /// fonts' metrics, which can extend past all three. Include those runs in the page flow
    /// before clipping the SVG so pagination cannot paint its overflow on the preceding sheet.
    static let measureDisplays = #"""
        for (const svg of document.querySelectorAll('body.format-latex .math-display > svg')) {
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
          Object.assign(svg.style, {display:'block', marginInline:'auto', verticalAlign:'top', overflow:'hidden'});
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
