import PDFKit
import SurimonoCore

/// The front contents and the body are printed separately. Print a small URL annotation
/// at each listed heading so a row can find its body position even when prose repeats its title.
struct PaperContentsAnchors {
    private let host = UUID().uuidString.lowercased()
    private let headings: [String: Int]

    init?(facts: DocumentFacts, legacy: Bool) {
        guard facts.beamerPageSize == nil else { return nil }
        let listed = Set((facts.leadEntries ?? []).compactMap(\.id))
        var headings: [String: Int] = [:]
        for (index, heading) in facts.headings.enumerated() {
            if let id = heading.id, legacy || listed.contains(id), headings[id] == nil { headings[id] = index }
        }
        guard !headings.isEmpty else { return nil }
        self.headings = headings
    }

    func marking(_ body: String) -> String {
        var html = ""
        html.reserveCapacity(body.utf8.count)
        var remaining = headings
        HTMLScanner.forEachToken(body) { token in
            switch token {
            case .opaque(let text), .text(let text): html += text
            case .tag(let tag):
                html += tag.source
                guard !tag.isClosing, !tag.isSelfClosing, ["h1", "h2", "h3", "h4", "h5", "h6"].contains(tag.name),
                    let id = tag.attribute("id"), let index = remaining.removeValue(forKey: id)
                else { return }
                html += """
                    <a aria-hidden="true" href="surimono-contents://\(host)/\(index)" \
                    style="all:initial!important;position:absolute!important;display:block!important; \
                    width:1px!important;height:1px!important;font-size:0!important;line-height:0!important"></a>
                    """
            }
        }
        return html
    }

    @MainActor func takeDestinations(in document: PDFDocument) -> [Int: (url: URL, destination: PDFDestination)] {
        var targets: [Int: (URL, PDFDestination)] = [:]
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations {
                guard let url = (annotation.action as? PDFActionURL)?.url ?? annotation.url,
                    url.scheme == "surimono-contents", url.host == host, let heading = Int(url.lastPathComponent)
                else { continue }
                if targets[heading] == nil {
                    let box = annotation.bounds
                    targets[heading] = (url, document.destination(on: page, at: CGPoint(x: box.minX, y: box.maxY)))
                }
                page.removeAnnotation(annotation)
            }
        }
        return targets
    }
}
