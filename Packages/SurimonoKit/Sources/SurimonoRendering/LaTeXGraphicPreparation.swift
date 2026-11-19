import Foundation

/// Only layout knows a tabular's natural width and the decoded image dimensions.
/// Measure after resources and fonts settle and keep the scaled box in the page flow.
enum LaTeXGraphicPreparation {
    static func script(in html: String, layoutWidth: Double) -> String? {
        guard html.contains(#"class="latex-graphic-box""#) else { return nil }
        return """
            {
              const root = document.documentElement;
              const oldWidth = root.style.width;
              root.style.width = (\(layoutWidth) / (parseFloat(getComputedStyle(root).zoom) || 1)) + 'px';
              try {
                \(measure)
              } finally { root.style.width = oldWidth; }
            }
            """
    }

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
