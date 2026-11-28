import CoreGraphics
import Foundation
import PDFKit
import WebKit

/// WebKit puts a link's destination at the top of the target's box. A heading that is a formatting context of its own
/// (an Org heading with tags is `flow-root` around a float) and that a page break pushes onto the next page keeps the
/// top of its box on the page before, below everything drawn there, so the link took the reader a page short.
///
/// A destination moves to the top of the next page only when it can be shown to be such a case: nothing is drawn
/// below it on its page, the text of the links pointing at it names one element of the document, and the next page
/// begins with that element's text. Every other destination stays where WebKit put it, such as one at an empty answer
/// box at the foot of its page.
enum PushedDestinations {
    /// The document's links and the elements they point at, read before printing.
    struct Targets: Decodable, Sendable {
        /// Each link's text and the fragment it points at, in document order.
        var links: [[String]] = []
        /// The text that flows first in each element a link points at, keyed by the fragment as written in the link.
        var texts: [String: String] = [:]

        var isEmpty: Bool { links.isEmpty }
    }

    private static let linkLimit = 4096
    /// How much of an element's text has to begin the next page.
    private static let comparedCharacters = 12

    /// An element's text starts with what flows in it: a float (an Org heading's tags) is set apart on the page.
    static let targetScript = """
        const links = [];
        const texts = {};
        const leading = (element) => {
          let text = '';
          const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT);
          while (text.length < 200 && walker.nextNode()) {
            let set = false;
            for (let node = walker.currentNode.parentElement; node && node !== element.parentElement;
                 node = node.parentElement) {
              const style = getComputedStyle(node);
              if (style.float !== 'none' || style.position === 'absolute' || style.position === 'fixed'
                  || style.display === 'none') { set = true; break; }
            }
            if (!set) text += walker.currentNode.data;
          }
          return text.trim().slice(0, 200);
        };
        for (const link of document.querySelectorAll('a[href^="#"]')) {
          const id = link.getAttribute('href').slice(1);
          if (!id) continue;
          links.push([(link.innerText || '').slice(0, 400), id]);
          if (!Object.prototype.hasOwnProperty.call(texts, id)) {
            let target = document.getElementById(id) || document.getElementsByName(id)[0];
            if (!target) { try { target = document.getElementById(decodeURIComponent(id)); } catch (error) {} }
            texts[id] = target ? leading(target) : '';
          }
          if (links.length >= limit) break;
        }
        return JSON.stringify({ links, texts });
        """

    @MainActor static func targets(in view: WKWebView, until deadline: ContinuousClock.Instant) async throws -> Targets
    {
        do {
            let json = try await view.evaluateForPrinting(
                targetScript, arguments: ["limit": linkLimit], until: min(deadline, .now + .seconds(2)))
            guard let json = json as? String, json.utf8.count <= 4_000_000 else { return Targets() }
            return try JSONDecoder().decode(Targets.self, from: Data(json.utf8))
        } catch {
            // Without the targets no destination moves; only a cancellation stops the print.
            try Task.checkCancellation()
            return Targets()
        }
    }

    /// The pages with the pushed destinations moved. The destinations are read from a copy and rewritten in the
    /// bytes: when some of a page's link actions were replaced through PDFKit, its write of that page lost the target
    /// page of every link on it.
    static func moving(_ bytes: Data, targets: Targets) throws -> Data {
        guard !targets.isEmpty, let document = PDFDocument(data: bytes) else { return bytes }
        struct Place: Hashable {
            let page: Int
            let x: CGFloat
            let y: CGFloat
        }
        struct Link {
            let page: Int
            let slot: Int
            let zoom: CGFloat
        }
        // WebKit gives every link to one element the same destination, so the links are taken together by it.
        var groups: [Place: [Link]] = [:]
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for (slot, annotation) in page.annotations.enumerated() where annotation.type == "Link" {
                try Task.checkCancellation()
                guard let destination = (annotation.action as? PDFActionGoTo)?.destination ?? annotation.destination,
                    let target = destination.page, destination.point.y.isFinite,
                    destination.point.y != kPDFDestinationUnspecifiedValue
                else { continue }
                let targetIndex = document.index(for: target)
                guard (0..<document.pageCount - 1).contains(targetIndex) else { continue }
                let place = Place(page: targetIndex, x: destination.point.x, y: destination.point.y)
                groups[place, default: []].append(Link(page: index, slot: slot, zoom: destination.zoom))
            }
        }
        let linkTexts = targets.links.compactMap { pair -> (text: String, id: String)? in
            guard pair.count == 2 else { return nil }
            let text = normalized(pair[0])
            return text.isEmpty ? nil : (text, pair[1])
        }
        var lowestText: [Int: CGFloat] = [:]
        var lowestDrawing: [Int: CGFloat] = [:]
        var openings: [Int: String] = [:]
        var moves: [ReadingPDFNavigationWriter.Link] = []
        for (place, links) in groups.sorted(by: { ($0.key.page, -$0.key.y) < ($1.key.page, -$1.key.y) }) {
            try Task.checkCancellation()
            guard let page = document.page(at: place.page), let next = document.page(at: place.page + 1) else {
                continue
            }
            // Half a point of slack for rounding in the destination and in the boxes of what is drawn.
            let limit = min(place.y, page.bounds(for: .cropBox).maxY) - 0.5
            if lowestText[place.page] == nil { lowestText[place.page] = try Self.lowestText(on: page) }
            guard let text = lowestText[place.page], text >= limit else { continue }
            // The element the links point at, named by their text alone.
            var ids = Set<String>()
            for link in links {
                guard let source = document.page(at: link.page),
                    let text = source.selection(for: source.annotations[link.slot].bounds)?.string
                else { continue }
                let printed = normalized(text)
                guard !printed.isEmpty else { continue }
                // A link broken over lines leaves part of its text in each box.
                var named = Set(linkTexts.lazy.filter { $0.text == printed }.map(\.id))
                if named.isEmpty { named = Set(linkTexts.lazy.filter { $0.text.contains(printed) }.map(\.id)) }
                if named.count == 1 { ids.formUnion(named) }
            }
            guard ids.count == 1, let id = ids.first,
                let wanted = targets.texts[id].map({ String(normalized($0).prefix(comparedCharacters)) }),
                !wanted.isEmpty
            else { continue }
            if openings[place.page + 1] == nil {
                openings[place.page + 1] = String(normalized(next.string ?? "").prefix(comparedCharacters))
            }
            guard openings[place.page + 1]?.hasPrefix(wanted) == true else { continue }
            // Last, and once a page: a picture or a rule below the lowest text.
            if lowestDrawing[place.page] == nil {
                lowestDrawing[place.page] = Self.lowestDrawing(on: page, below: text)
            }
            guard let drawn = lowestDrawing[place.page], drawn >= limit else { continue }
            let top = CGPoint(x: place.x, y: next.bounds(for: .cropBox).maxY)
            for link in links {
                moves.append(
                    .init(
                        page: link.page, annotation: link.slot,
                        destination: .init(page: place.page + 1, point: top, zoom: link.zoom)))
            }
        }
        return try ReadingPDFNavigationWriter.repair(bytes, links: moves, bookmarks: nil)
    }

    /// The lowest point any text is drawn at on the page, or the top of its box when it has none.
    static func lowestText(on page: PDFPage) throws -> CGFloat {
        let crop = page.bounds(for: .cropBox)
        var lowest = crop.maxY
        for character in 0..<page.numberOfCharacters {
            if character.isMultiple(of: 4096) { try Task.checkCancellation() }
            let box = page.characterBounds(at: character)
            if box.width > 0, box.height > 0, box.maxY > crop.minY { lowest = min(lowest, box.minY) }
        }
        return lowest
    }

    /// The lowest point anything is drawn at on the page, given the lowest text: only the strip below it is rendered.
    static func lowestDrawing(on page: PDFPage, below text: CGFloat) -> CGFloat {
        let crop = page.bounds(for: .cropBox)
        let stripHeight = text - crop.minY
        guard stripHeight > 0 else { return text }
        let scale: CGFloat = 2
        let width = max(1, Int((crop.width * scale).rounded(.up)))
        let height = max(1, Int((stripHeight * scale).rounded(.up)))
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
            let data = context.data
        else { return crop.minY }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // The box's lower left corner lands on the bitmap's origin, so the bitmap holds the bottom of the page.
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: context)
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        // The bitmap's last row in memory is the bottom of the page.
        for row in stride(from: height - 1, through: 0, by: -1) {
            let start = row * width * 4
            for index in stride(from: start, to: start + width * 4, by: 4)
            where pixels[index] < 250 || pixels[index + 1] < 250 || pixels[index + 2] < 250 {
                return crop.minY + CGFloat(height - 1 - row) / scale
            }
        }
        return text
    }

    /// Letters and digits only, without case, as the outline compares a heading with the page's text.
    private static func normalized(_ text: String) -> String {
        let folded = text.precomposedStringWithCompatibilityMapping.folding(options: .caseInsensitive, locale: nil)
            .precomposedStringWithCanonicalMapping
        return String(
            folded.unicodeScalars.filter { $0.properties.isAlphabetic || $0.properties.numericType != nil }
                .map(Character.init))
    }
}
