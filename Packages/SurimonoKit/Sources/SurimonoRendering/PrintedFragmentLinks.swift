import PDFKit
import WebKit

/// WebKit prints encoded fragments as URLs and may write a named /Dest with no usable page.
/// Carry both ends through the native print or the vertical slices, then join them in the final page tree.
struct PrintedFragmentLinks: Sendable {
    let prefix: String
    var collectsDestinations = true

    /// Submit the marker script before the next required WebKit operation on the same view.
    /// Printing never waits for an optional reply. A missing or failed reply only discards
    /// private marks, including any that the script installed before it threw.
    @MainActor final class Preparation {
        private(set) var links: PrintedFragmentLinks?

        init(in view: WKWebView, source: WebPaginator.Source) {
            // Generated documents resolve their images against a directory while their paper lives at a temporary URL.
            let resourceBase: URL?
            switch source {
            case .html(_, let base): resourceBase = base
            case .snapshot: resourceBase = SnapshotSchemeHandler.rootURL
            case .sandboxed(_, let access, false):
                resourceBase = LocalResourceSchemeHandler.url(for: access.documentURL.deletingLastPathComponent())
            default: resourceBase = nil
            }
            let prefix = "surimono-fragment://\(UUID().uuidString.lowercased())/"
            links = PrintedFragmentLinks(prefix: prefix, collectsDestinations: false)
            view.callAsyncJavaScript(
                PrintedFragmentLinks.script,
                arguments: ["prefix": prefix, "resourceBase": resourceBase?.absoluteString ?? ""],
                in: nil, in: WebPaginator.preparationWorld
            ) { [weak self] reply in
                if case .success(let value) = reply, let installed = value as? Bool {
                    self?.links = installed ? PrintedFragmentLinks(prefix: prefix) : nil
                }
            }
        }
    }

    private static let script = """
        const current = document.URL.split('#')[0];
        const targets = new Map();
        let named;
        for (const link of document.querySelectorAll('a[href]')) {
          if (!(link instanceof HTMLAnchorElement) || !link.href.includes('#')) continue;
          const raw = link.getAttribute('href').trim();
          const page = link.href.split('#')[0];
          if (page !== current && !(raw.startsWith('#') && page === resourceBase)) continue;
          let id = link.hash.slice(1);
          try { id = decodeURIComponent(id); } catch {}
          let target = id ? document.getElementById(id) : document.body;
          if (!target) {
            if (!named) {
              named = new Map();
              for (const a of document.querySelectorAll('a[name]')) if (!named.has(a.name)) named.set(a.name, a);
            }
            target = named.get(id);
          }
          if (!target && id.toLowerCase() === 'top') target = document.body;
          if (!target) continue;
          let index = targets.get(target);
          if (index === undefined) {
            index = targets.size;
            targets.set(target, index);
            const mark = document.createElement('a');
            mark.href = prefix + 'target/' + index;
            mark.setAttribute('aria-hidden', 'true');
            mark.style.cssText = 'all:initial!important;position:absolute!important;display:block!important;' +
              'width:1px!important;height:1px!important;line-height:0!important;font-size:0!important;' +
              'border:0!important;padding:0!important;margin:0!important;visibility:inherit!important;background:transparent!important';
            if (target.matches('img,input,hr,br,area,embed,video,canvas,svg')) target.before(mark);
            else target.prepend(mark);
          }
          // Keep fragment-only links matching the theme's internal-link selectors.
          const marker = prefix + 'link/' + index;
          link.setAttribute('href', raw.startsWith('#') ? '#' + marker : marker);
        }
        return targets.size > 0;
        """

    private func marker(on annotation: PDFAnnotation) -> Substring? {
        guard let url = (annotation.action as? PDFActionURL)?.url ?? annotation.url else { return nil }
        // PDFKit sometimes encodes the fragment separator when it writes an opaque about:blank URL.
        let raw = url.absoluteString
        let address = url.scheme == "about" ? raw.removingPercentEncoding ?? raw : raw
        let value = address.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).last
        guard let value, value.hasPrefix(prefix) else { return nil }
        return value.dropFirst(prefix.count)
    }

    /// Navigation is optional. If the writer cannot update these bytes, use the printed pages
    /// and remove the private URLs from the live document. Drawing must then use that document.
    @MainActor static func open(_ printed: Data, links: Self?) async throws -> (
        document: PDFDocument, drawingBytes: Data?
    ) {
        if let links {
            do {
                let bytes = try await links.resolve(in: printed)
                if let document = PDFDocument(data: bytes), document.pageCount > 0 { return (document, bytes) }
            } catch {
                try Task.checkCancellation()
            }
        }
        guard let document = PDFDocument(data: printed), document.pageCount > 0 else {
            throw WebPaginator.PaginationError.emptyDocument
        }
        guard let links else { return (document, printed) }
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations where links.marker(on: annotation) != nil {
                page.removeAnnotation(annotation)
            }
        }
        return (document, nil)
    }

    /// Match the first printed occurrence of a target, including forward links and links across slices.
    @concurrent func resolve(in bytes: Data) async throws -> Data {
        typealias Writer = ReadingPDFNavigationWriter
        guard let document = PDFDocument(data: bytes) else { throw WebPaginator.PaginationError.emptyDocument }
        var targets: [Int: Writer.Destination] = [:]
        var sources: [(page: Int, annotation: Int, id: Int)] = []
        var removed: [Int: Set<Int>] = [:]
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { continue }
            for (offset, annotation) in page.annotations.enumerated() {
                guard let marker = marker(on: annotation) else { continue }
                if !collectsDestinations {
                    removed[index, default: []].insert(offset)
                    continue
                }
                if marker.hasPrefix("target/"), let id = Int(marker.dropFirst("target/".count)) {
                    if targets[id] == nil {
                        targets[id] = .init(
                            page: index, mode: "XYZ", arguments: [annotation.bounds.minX, annotation.bounds.maxY, nil])
                    }
                    removed[index, default: []].insert(offset)
                } else if marker.hasPrefix("link/"), let id = Int(marker.dropFirst("link/".count)) {
                    sources.append((index, offset, id))
                }
            }
        }
        var links: [Writer.Link] = []
        for source in sources {
            if let target = targets[source.id] {
                links.append(.init(page: source.page, annotation: source.annotation, destination: target))
            } else {
                // A hidden destination has no printed position.
                removed[source.page, default: []].insert(source.annotation)
            }
        }
        return try Writer.repair(bytes, links: links, bookmarks: nil, removingAnnotations: removed)
    }
}
