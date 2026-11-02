import Foundation
import PDFKit
import SurimonoCore

@MainActor
enum PrintIssueAnchors {
    struct Preparation: Decodable {
        let previous: String?
        let issues: [PrintIssue]
    }

    // Early returns and failures in cleanup scripts must not suppress the checks or lose the paper result.
    static func following(_ script: String?, themed: Bool) -> String {
        """
        let previous = null;
        try {
          previous = await (async () => {
          \(script ?? "")
          })();
        } catch (_) {}
        let issues = [];
        try {
          issues = await (async () => {
          \(javaScript(themed: themed))
          })();
        } catch (_) {}
        return JSON.stringify({previous: typeof previous === 'string' ? previous : null, issues});
        """
    }

    static func javaScript(themed: Bool) -> String {
        """
        const issues = [];
        const targets = [];
        const visible = el => {
          if (!el.getClientRects().length) return false;
          const css = getComputedStyle(el);
          return css.visibility !== 'hidden' && css.visibility !== 'collapse' && css.display !== 'none';
        };
        const occurrences = new Map();
        function locationKey(kind, detail) {
          const group = JSON.stringify([kind, detail]);
          const occurrence = occurrences.get(group) || 0;
          occurrences.set(group, occurrence + 1);
          return JSON.stringify([kind, detail, occurrence]);
        }
        function contentWidth(el) {
          const css = getComputedStyle(el);
          const borderBox = el.getBoundingClientRect().width;
          const unscaled = el.offsetWidth;
          if (!unscaled) return 0;
          const inset = ['paddingLeft', 'paddingRight', 'borderLeftWidth', 'borderRightWidth']
            .reduce((sum, name) => sum + (Number.parseFloat(css[name]) || 0), 0);
          // DOM rectangles include zoom; CSS padding and offsetWidth do not.
          return borderBox * Math.max(0, unscaled - inset) / unscaled;
        }
        function elementKind(el) {
          return el.matches('.math-block') ? 'math' :
            ({TABLE:'table',IMG:'image',PRE:'code'})[el.tagName] || 'figure';
        }
        function add(el, kind, detail, key, element = null) {
          const id = String(issues.length);
          issues.push({id, kind, detail, element, locationKey: key});
          targets.push({el, id});
        }
        for (const el of document.querySelectorAll('img')) {
          const key = locationKey('image', [el.getAttribute('src') || '', el.getAttribute('srcset') || '']);
          if (!visible(el) || !el.complete || el.naturalWidth !== 0) continue;
          const src = el.currentSrc || el.src || '';
          if (!\(themed) && !/^(file:|surimono-local:)/i.test(src)) continue;
          add(el, 'image', src, key);
        }
        if (\(themed)) {
          const selector = 'table,img,svg,pre,figure,.math-block';
          // Count every source block, including those that fit, so changing the paper cannot renumber a problem.
          const blocks = Array.from(document.querySelectorAll(selector)).map(el => {
            const element = elementKind(el);
            return {el, element, key: locationKey('overflow', element)};
          });
          const overflowing = blocks.filter(({el}) => {
            if (!visible(el) || (el.tagName === 'IMG' && el.naturalWidth === 0)) return false;
            const container = el.parentElement;
            if (!container) return false;
            const width = Math.min(contentWidth(container), contentWidth(document.body));
            if (!width) return false;
            return el.getBoundingClientRect().width > width + 2;
          });
          for (const {el, element, key} of overflowing) {
            // Report the outer block once, rather than every SVG in an overflowing formula or figure.
            if (overflowing.some(({el: parent}) => parent !== el && parent.contains(el))) continue;
            add(el, 'overflow', '', key, element);
          }
          for (const el of document.querySelectorAll('.math-error')) {
            const detail = el.textContent || '';
            const key = locationKey('math', detail);
            if (visible(el)) add(el, 'math', detail, key);
          }
          for (const el of document.querySelectorAll('.mermaid-error')) {
            const detail = el.textContent || '';
            const key = locationKey('mermaid', detail);
            if (visible(el)) add(el, 'mermaid', detail, key);
          }
          for (const el of document.querySelectorAll('.latex-unsupported')) {
            const detail = el.textContent || '';
            const key = locationKey('latex', detail);
            if (visible(el)) add(el, 'latex', detail, key);
          }
        }
        if (!targets.length) return issues;
        const style = document.createElement('style');
        style.textContent = '.surimono-issue-anchor::before,.surimono-issue-anchor::after {content:none !important;}';
        document.head.appendChild(style);
        for (const {el, id} of targets) {
          const anchor = document.createElement('a');
          anchor.className = 'surimono-issue-anchor';
          anchor.href = 'surimono-issue:' + id;
          anchor.setAttribute('aria-hidden', 'true');
          const rules = {all:'initial',display:'block',position:'absolute',top:'auto',left:'auto',
            width:'1px',height:'1px',margin:'0',padding:'0',border:'0',background:'transparent',
            'font-size':'0','line-height':'0','pointer-events':'none'};
          for (const [name, value] of Object.entries(rules)) anchor.style.setProperty(name, value, 'important');
          if (el.tagName === 'TABLE') {
            // A static-position link in the first cell follows the table's print break without changing borders.
            const cell = el.querySelector('th,td');
            if (cell) cell.insertBefore(anchor, cell.firstChild);
          } else if (el.tagName === 'IMG' || el instanceof SVGElement) {
            // Void elements and SVG cannot contain an HTML link; an adjacent out-of-flow link shares their line.
            el.parentNode.insertBefore(anchor, el);
          } else {
            el.insertBefore(anchor, el.firstChild);
          }
        }
        return issues;
        """
    }

    static func extract(from document: PDFDocument, issues: [PrintIssue]) -> [PrintIssue] {
        var issues = issues
        let indices = Dictionary(
            issues.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { a, _ in a })
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            for annotation in page.annotations {
                let url = annotation.url ?? (annotation.action as? PDFActionURL)?.url
                guard let url, url.scheme?.lowercased() == "surimono-issue" else { continue }
                let id = String(url.absoluteString.dropFirst("surimono-issue:".count))
                let rect = annotation.bounds.intersection(page.bounds(for: .cropBox))
                if let index = indices[id], issues[index].pageNumber == nil, !rect.isNull, !rect.isEmpty {
                    issues[index].pageNumber = pageIndex + 1
                    issues[index].rect = rect
                }
                // Even unknown ids must never reach a composed sheet or an exported PDF.
                page.removeAnnotation(annotation)
            }
        }
        return PrintIssue.sorted(issues)
    }

    static func imageFailure(_ file: URL, access: LocalResourceAccess?) -> PrintIssue.ImageFailure {
        if let access, !access.permits(file) { return .folderAccess }
        do {
            return try file.checkResourceIsReachable() ? .other : .missing
        } catch {
            let error = error as NSError
            if error.domain == NSCocoaErrorDomain,
                [CocoaError.fileNoSuchFile.rawValue, CocoaError.fileReadNoSuchFile.rawValue].contains(error.code)
            {
                return .missing
            }
            if error.domain == NSCocoaErrorDomain, error.code == CocoaError.fileReadNoPermission.rawValue {
                return .folderAccess
            }
            return .other
        }
    }
}
