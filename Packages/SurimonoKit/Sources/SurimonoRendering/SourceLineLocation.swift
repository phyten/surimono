import PDFKit

/// The first printed row of an original line, in logical PDF page coordinates.
public struct SourceLineLocation {
    public let pageIndex: Int
    public let rect: CGRect

    // WebKit does not expose its print breaks in the screen DOM. A temporary link follows its row through printing,
    // even when the row is blank, clipped, repeated or wrapped and the gutter is hidden.
    static let preparation = """
        {
          const style = document.createElement('style');
          style.textContent = `
            .surimono-source .source-location { all: initial !important; position: absolute !important;
              display: block !important; top: 0 !important; left: 0 !important; width: 100% !important;
              height: 1lh !important; font: inherit !important; pointer-events: none !important; }
            .source-location::before, .source-location::after { content: none !important; }`;
          document.head.appendChild(style);
          let number = 0;
          for (const line of document.querySelectorAll('pre.surimono-source > code > .source-line')) {
            const anchor = document.createElement('a');
            anchor.className = 'source-location';
            anchor.href = 'surimono-source-line:' + (++number);
            anchor.setAttribute('aria-hidden', 'true');
            line.appendChild(anchor);
          }
        }
        """

    @MainActor
    static func take(from document: PDFDocument) -> (locations: [Int: Self], lastNumber: Int) {
        var lines: [Int: Self] = [:]
        var lastNumber = 0
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations {
                guard let url = annotation.url ?? (annotation.action as? PDFActionURL)?.url,
                    url.scheme == "surimono-source-line"
                else { continue }
                let rect = annotation.bounds.intersection(page.bounds(for: .cropBox))
                if let number = Int(url.absoluteString.dropFirst("surimono-source-line:".count)),
                    !rect.isNull, !rect.isEmpty, lines[number] == nil
                {
                    lines[number] = Self(pageIndex: index, rect: rect)
                    lastNumber = max(lastNumber, number)
                }
                page.removeAnnotation(annotation)
            }
        }
        return (lines, lastNumber)
    }
}
