import Foundation
import PDFKit
import SurimonoCore

/// Only the disposable print pass carries links. It uses the same WebKit session so diagram engines run once.
@MainActor
enum DiagramGeometry {
    static func hasBlocks(in html: String) -> Bool {
        ["mermaid-block", "graphviz-block", "plantuml-block"].contains { html.contains($0) }
    }

    /// PaperComposer draws the source crop box at the origin of a new page.
    static func redrawn(_ rect: CGRect, on page: PDFPage?, shift: CGFloat = 0) -> CGRect {
        guard let page else { return rect }
        let box = page.bounds(for: .cropBox).intersection(page.bounds(for: .mediaBox))
        return rect.offsetBy(dx: shift - box.minX, dy: -box.minY)
    }

    struct Source: Decodable {
        let svg: String
        let heightToWidth: CGFloat
    }

    @MainActor
    struct Pass {
        let document: PDFDocument
        let sources: [Source]
        let token: String

        func diagrams(transform: ((PDFDocument) throws -> PDFDocument)?) throws -> [RenderedDiagram] {
            let measured = try transform?(document) ?? document
            var diagrams: [RenderedDiagram] = []
            let prefix = "surimono-diagram:\(token)/"
            for pageIndex in 0..<measured.pageCount {
                guard let page = measured.page(at: pageIndex) else { continue }
                for link in page.annotations {
                    guard let url = link.url ?? (link.action as? PDFActionURL)?.url,
                        url.absoluteString.hasPrefix(prefix),
                        let index = Int(url.absoluteString.dropFirst(prefix.count)),
                        sources.indices.contains(index)
                    else { continue }
                    let rect = link.bounds.intersection(page.bounds(for: .cropBox))
                    if !rect.isEmpty, !rect.isNull {
                        let source = sources[index]
                        let width = link.bounds.width
                        // WebKit splits a tall link at page breaks. Its printed width still gives the scale of the
                        // complete SVG, whose DOM rectangle supplied the aspect ratio before pagination.
                        let height = width * source.heightToWidth
                        let size = CGSize(
                            width: width, height: abs(height - link.bounds.height) <= 1 ? link.bounds.height : height)
                        diagrams.append(
                            RenderedDiagram(
                                number: index + 1, pageIndex: pageIndex, rect: rect, svg: source.svg, pointSize: size))
                    }
                }
            }
            return diagrams.sorted { $0.number < $1.number }
        }
    }

    static func anchors(printWidth: CGFloat, token: String) -> String {
        """
        const rendered = globalThis.surimonoRenderedDiagrams;
        if (!rendered) return '[]';
        const diagrams = [...document.querySelectorAll('.mermaid-block > svg,.graphviz-block > svg,.plantuml-block > svg')]
          .filter(svg => rendered.has(svg));
        if (!diagrams.length) return '[]';
        const root = document.documentElement;
        const prior = root.style.cssText;
        const zoom = parseFloat(getComputedStyle(root).zoom) || 1;
        root.style.width = (\(printWidth) / zoom) + 'px';
        const sources = [];
        const style = document.createElement('style');
        style.textContent = '.surimono-diagram-anchor::before,.surimono-diagram-anchor::after{content:none!important}';
        document.head.append(style);
        for (const svg of diagrams) {
          const css = getComputedStyle(svg);
          const box = svg.getBoundingClientRect();
          if (!box.width || !box.height || css.visibility !== 'visible') continue;
          const clone = svg.cloneNode(true);
          // Percentage lengths and the print stylesheet fit the paper. A standalone SVG needs intrinsic dimensions.
          for (const axis of ['width', 'height']) {
            const length = svg[axis].baseVal;
            const size = svg.hasAttribute(axis) && length.unitType !== SVGLength.SVG_LENGTHTYPE_PERCENTAGE && length.value > 0
              ? length.value : svg.viewBox.baseVal[axis];
            clone.setAttribute(axis, size);
            clone.style.removeProperty(axis);
            clone.style.removeProperty('max-' + axis);
          }
          clone.style.fontFamily = css.fontFamily;
          clone.style.color = css.color;
          const index = sources.length;
          sources.push({svg: new XMLSerializer().serializeToString(clone), heightToWidth: box.height / box.width});
          const host = svg.parentElement;
          if (getComputedStyle(host).position === 'static') host.style.setProperty('position','relative','important');
          const anchor = document.createElement('a');
          anchor.className = 'surimono-diagram-anchor';
          anchor.href = 'surimono-diagram:\(token)/' + index;
          const rules = {all:'initial', position:'absolute',display:'block',left:'0',top:'0',
            width:'1px',height:'1px',margin:'0',padding:'0',border:'0',background:'transparent',
            'line-height':'0','font-size':'0','pointer-events':'none'};
          for (const [key, value] of Object.entries(rules)) anchor.style.setProperty(key,value,'important');
          host.append(anchor);
          const origin = anchor.getBoundingClientRect();
          if (!origin.width || !origin.height) continue;
          // A one-pixel probe includes all ancestor zoom factors, including zoom from a custom theme.
          for (const [key, value] of Object.entries({left:(box.left-origin.left)/origin.width,
            top:(box.top-origin.top)/origin.height,width:box.width/origin.width,height:box.height/origin.height})) {
            anchor.style.setProperty(key,value+'px','important');
          }
        }
        root.style.cssText = prior;
        return JSON.stringify(sources);
        """
    }
}
