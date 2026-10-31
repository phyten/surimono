import Foundation
import PDFKit
import SurimonoCore

/// Geometry in a logical page's PDF coordinates. Never part of the document's printable content.
public struct ChangeMark: Equatable, Sendable {
    public let pageIndex: Int
    public let rect: CGRect
    public let isShort: Bool

    public init(pageIndex: Int, rect: CGRect, isShort: Bool = false) {
        self.pageIndex = pageIndex
        self.rect = rect
        self.isShort = isShort
    }

    /// Cropping joined pages can remove the margin; the bar then hugs the remaining left edge.
    /// The bar beside the block. With the text area's left edge given, every bar lines up just outside it, so a list
    /// item's bar does not sit between its bullet and its text.
    public func bar(in crop: CGRect, textLeft: CGFloat? = nil) -> CGRect {
        let height = isShort ? min(8, rect.height) : rect.height
        let x = (textLeft ?? rect.minX) - 6
        return CGRect(x: max(crop.minX, x), y: rect.maxY - height, width: 2, height: height).intersection(crop)
    }
}

@MainActor
enum ChangeMarkAnchors {
    static func javaScript(_ requests: [MarkdownMarkRequest]) -> String {
        guard !requests.isEmpty,
            let data = try? JSONEncoder().encode(requests.map(\.blockID)),
            let json = String(data: data, encoding: .utf8)
        else { return "" }
        return """
            (() => {
              const wanted = new Set(\(json));
              const style = document.createElement('style');
              style.textContent = '.surimono-change-anchor::before,.surimono-change-anchor::after { content:none !important; }';
              document.head.appendChild(style);
              const blocks = Array.from(document.querySelectorAll('[data-surimono-block]'));
              const number = value => Number.parseFloat(value) || 0;
              function makeAnchor(id) {
                const anchor = document.createElement('a');
                anchor.className = 'surimono-change-anchor';
                anchor.href = 'surimono-mark:' + id;
                anchor.setAttribute('aria-hidden', 'true');
                const rules = {all:'initial',display:'block',position:'absolute',top:'0',bottom:'0',left:'0',
                  width:'1px',height:'auto','min-height':'1px',margin:'0',padding:'0',border:'0',background:'transparent',
                  'font-size':'0','line-height':'0','pointer-events':'none'};
                for (const [name, value] of Object.entries(rules)) anchor.style.setProperty(name, value, 'important');
                return anchor;
              }
              function set(anchor, name, value) { anchor.style.setProperty(name, value, 'important'); }
              function inside(host, anchor, short = false) {
                if (getComputedStyle(host).position === 'static') host.style.setProperty('position', 'relative', 'important');
                if (short) { set(anchor, 'bottom', 'auto'); set(anchor, 'height', '8px'); }
                // Preserve the common last-child spacing rule in this disposable geometry pass.
                const last = host.lastElementChild;
                const margin = last ? getComputedStyle(last).marginBottom : null;
                host.appendChild(anchor);
                if (last) last.style.setProperty('margin-bottom', margin, 'important');
              }
              for (const block of blocks) {
                const id = block.getAttribute('data-surimono-block');
                if (!wanted.has(id)) continue;
                const anchor = makeAnchor(id);
                if (block.tagName === 'TABLE') {
                  // A table accepts rows, not an extra block child. Neither its positioning nor its cells' positioning
                  // may change: that can change collapsed-border painting in WebKit. An out-of-flow first child of a
                  // cell uses its static position, which follows that cell into the actual printed page.
                  const cell = block.querySelector('th,td');
                  if (!cell) continue;
                  const tableBox = block.getBoundingClientRect();
                  const cellBox = cell.getBoundingClientRect();
                  const css = getComputedStyle(cell);
                  set(anchor, 'top', 'auto'); set(anchor, 'bottom', 'auto'); set(anchor, 'left', 'auto');
                  set(anchor, 'height', Math.max(1, tableBox.height) + 'px');
                  set(anchor, 'margin-top', (tableBox.top - cellBox.top - number(css.borderTopWidth) - number(css.paddingTop)) + 'px');
                  set(anchor, 'margin-left', (tableBox.left - cellBox.left - number(css.borderLeftWidth) - number(css.paddingLeft)) + 'px');
                  cell.insertBefore(anchor, cell.firstChild);
                } else if (block.tagName === 'HR') {
                  // HR is a void element: its children cannot be used as printable links. Keep the rule untouched and
                  // put a short mark at the next surviving block, or the previous one at the end.
                  const index = blocks.indexOf(block);
                  const suitable = candidate => candidate.tagName !== 'HR' && candidate.tagName !== 'TABLE'
                    && !candidate.contains(block) && getComputedStyle(candidate).display !== 'contents';
                  const host = blocks.slice(index + 1).find(suitable) || blocks.slice(0, index).reverse().find(suitable);
                  if (host) {
                    inside(host, anchor, true);
                  } else {
                    // A document consisting only of rules still needs an anchor. The body's existing first child is
                    // preserved, so the rule keeps its first-child margin rule.
                    const box = block.getBoundingClientRect();
                    set(anchor, 'top', (box.top + window.scrollY) + 'px');
                    set(anchor, 'left', (box.left + window.scrollX) + 'px');
                    set(anchor, 'bottom', 'auto'); set(anchor, 'height', '1px');
                    document.body.appendChild(anchor);
                  }
                } else {
                  inside(block, anchor);
                }
              }
            })();
            """
    }

    /// Remove every private annotation, even an unknown id; none may escape into an exported PDF.
    static func extract(from document: PDFDocument, requests: [MarkdownMarkRequest]) -> [ChangeMark] {
        let short = Dictionary(requests.map { ($0.blockID, $0.isShort) }, uniquingKeysWith: { first, _ in first })
        var marks: [ChangeMark] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations {
                let url = annotation.url ?? (annotation.action as? PDFActionURL)?.url
                guard let url, url.scheme == "surimono-mark" else { continue }
                let id = String(url.absoluteString.dropFirst("surimono-mark:".count))
                let rect = annotation.bounds.intersection(page.bounds(for: .cropBox))
                if let isShort = short[id], !rect.isNull, !rect.isEmpty {
                    marks.append(ChangeMark(pageIndex: index, rect: rect, isShort: isShort))
                }
                page.removeAnnotation(annotation)
            }
        }
        return marks
    }
}
