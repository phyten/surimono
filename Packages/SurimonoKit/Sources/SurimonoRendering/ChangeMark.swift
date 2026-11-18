import Foundation
import PDFKit
import SurimonoCore

/// Geometry in a logical page's PDF coordinates. Never part of the document's printable content.
public struct ChangeMark: Equatable, Sendable {
    public static let defaultBackgroundHex = "#FFF2A8"
    public var backgroundHex = Self.defaultBackgroundHex
    public var textHex: String?
    var blockID = ""
    var textDrawing: ChangeTextDrawing?
    public let pageIndex: Int
    public let rect: CGRect
    public let afterBlock: Bool
    public let isShort: Bool

    public init(pageIndex: Int, rect: CGRect, isShort: Bool = false, afterBlock: Bool = false) {
        self.pageIndex = pageIndex
        self.rect = rect
        self.isShort = isShort
        self.afterBlock = afterBlock
    }

    public func highlight(in crop: CGRect) -> CGRect {
        guard isShort else { return rect.intersection(crop) }
        return CGRect(x: rect.minX, y: afterBlock ? rect.minY - 3 : rect.maxY, width: rect.width, height: 3)
            .intersection(crop)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.pageIndex == rhs.pageIndex && lhs.rect == rhs.rect && lhs.isShort == rhs.isShort
            && lhs.afterBlock == rhs.afterBlock
            && lhs.backgroundHex == rhs.backgroundHex && lhs.textHex == rhs.textHex
            && lhs.textDrawing === rhs.textDrawing
    }
}

/// Only marks can carry the alternate ink to the screen. The PDF used by output and its annotations stay clean.
@MainActor
final class ChangeTextDrawing {
    private let document: PDFDocument

    init(_ document: PDFDocument) { self.document = document }

    /// Only glyph coverage goes into the view copy. Its selectable text still comes from the original vector page.
    /// A theme's last-child rules must not change the rest of a page simply because one paragraph has a custom ink.
    func paint(_ mark: ChangeMark, clippedTo crop: CGRect, in context: CGContext) {
        guard let hex = mark.textHex, let ink = CodeColor.components(hex),
            let page = document.page(at: mark.pageIndex)?.pageRef
        else { return }
        let rect = mark.rect.intersection(crop)
        guard !rect.isEmpty, !rect.isNull else { return }
        // Tile long paragraphs so a four-pixel-per-point stencil only needs one MiB of scratch space at a time.
        let scale: CGFloat = 4
        let tileSize: CGFloat = 256
        for y in stride(from: rect.minY, to: rect.maxY, by: tileSize) {
            for x in stride(from: rect.minX, to: rect.maxX, by: tileSize) {
                let tile = CGRect(x: x, y: y, width: min(tileSize, rect.maxX - x), height: min(tileSize, rect.maxY - y))
                let width = Int(ceil(tile.width * scale))
                let height = Int(ceil(tile.height * scale))
                guard
                    let bitmap = CGContext(
                        data: nil, width: width, height: height, bitsPerComponent: 8,
                        bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                        bitmapInfo: CGImageAlphaInfo.none.rawValue)
                else { continue }
                bitmap.setFillColor(gray: 1, alpha: 1)
                bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
                bitmap.scaleBy(x: CGFloat(width) / tile.width, y: CGFloat(height) / tile.height)
                bitmap.translateBy(x: -x, y: -y)
                bitmap.drawPDFPage(page)
                guard let provider = bitmap.makeImage()?.dataProvider,
                    let mask = CGImage(
                        maskWidth: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                        bytesPerRow: width, provider: provider, decode: nil, shouldInterpolate: true)
                else { continue }
                context.saveGState()
                context.clip(to: tile, mask: mask)
                context.setFillColor(CGColor(srgbRed: ink.red, green: ink.green, blue: ink.blue, alpha: 1))
                context.fill(tile)
                context.restoreGState()
            }
        }
    }
}

@MainActor
enum ChangeMarkAnchors {
    /// A white page with only the requested glyphs in black is a reusable ink stencil, including for white ink.
    /// Install after the theme has decorated the DOM. Paint rules leave the elements and their metrics alone.
    static func textScript(_ requests: [MarkdownMarkRequest]) -> String {
        guard let data = try? JSONEncoder().encode(requests.filter { !$0.isShort }.map(\.blockID)),
            let json = String(data: data, encoding: .utf8)
        else { return "" }
        return """
            (() => {
              const ids = new Set(\(json));
              const sheet = new CSSStyleSheet();
              sheet.replaceSync(`
                *, *::before, *::after, *::marker {
                  color: white !important; -webkit-text-fill-color: white !important;
                  background-color: transparent !important; background-image: none !important;
                  border-color: transparent !important; outline-color: transparent !important;
                  box-shadow: none !important; text-shadow: none !important;
                  text-decoration-color: transparent !important; -webkit-text-stroke-color: transparent !important;
                }
                html { background: white !important; }
                img, video, canvas, iframe, object, embed, input, svg { visibility: hidden !important; }
                [data-surimono-ink], [data-surimono-ink] *, [data-surimono-ink]::marker {
                  color: black !important; -webkit-text-fill-color: black !important;
                }
                :is(.math-block, .math-inline)[data-surimono-ink] svg,
                [data-surimono-ink] :is(.math-block, .math-inline) svg { visibility: visible !important; }
              `);
              for (const el of document.querySelectorAll('[data-surimono-block]')) {
                if (ids.has(el.getAttribute('data-surimono-block'))) el.setAttribute('data-surimono-ink', '');
              }
              document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
            })();
            """
    }

    static func javaScript(_ requests: [MarkdownMarkRequest], layoutWidth: CGFloat? = nil) -> String {
        guard !requests.isEmpty,
            let data = try? JSONEncoder().encode(
                Dictionary(requests.map { ($0.blockID, $0.isShort) }, uniquingKeysWith: { first, _ in first })),
            let json = String(data: data, encoding: .utf8)
        else { return "" }
        return """
            (() => {
              const wanted = new Map(Object.entries(\(json)));
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
                  right:'0',width:'auto',height:'auto','min-height':'1px',margin:'0',padding:'0',border:'0',background:'transparent',
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
              // WebKit expands the layout viewport for print. Measure rows and line widths at that width.
              const root = document.documentElement;
              const priorWidth = root.style.width;
              const printWidth = \(layoutWidth ?? 0);
              const zoom = parseFloat(getComputedStyle(root).zoom) || 1;
              if (printWidth > 0) root.style.width = (printWidth / zoom) + 'px';
              for (const block of blocks) {
                const id = block.getAttribute('data-surimono-block');
                if (!wanted.has(id)) continue;
                const anchor = makeAnchor(id);
                if (block.tagName === 'TABLE' || block.tagName === 'TR') {
                  // A table accepts rows, not an extra block child. Neither its positioning nor its cells' positioning
                  // may change: that can change collapsed-border painting in WebKit. An out-of-flow first child of a
                  // cell uses its static position, which follows that cell into the actual printed page.
                  const cell = block.querySelector('th,td');
                  if (!cell) continue;
                  const tableBox = block.getBoundingClientRect();
                  const cellBox = cell.getBoundingClientRect();
                  const css = getComputedStyle(cell);
                  set(anchor, 'top', 'auto'); set(anchor, 'bottom', 'auto'); set(anchor, 'left', 'auto');
                  set(anchor, 'right', 'auto'); set(anchor, 'width', Math.max(1, tableBox.width / zoom) + 'px');
                  set(anchor, 'height', Math.max(1, tableBox.height / zoom) + 'px');
                  set(anchor, 'margin-top', ((tableBox.top - cellBox.top) / zoom - number(css.borderTopWidth) - number(css.paddingTop)) + 'px');
                  set(anchor, 'margin-left', ((tableBox.left - cellBox.left) / zoom - number(css.borderLeftWidth) - number(css.paddingLeft)) + 'px');
                  cell.insertBefore(anchor, cell.firstChild);
                } else if (block.matches('img,svg,br,input,video,canvas,iframe,object,embed')) {
                  // Replaced elements do not paint anchor children. Align a sibling with the box in this pass only.
                  const box = block.getBoundingClientRect();
                  set(anchor, 'top', 'auto'); set(anchor, 'bottom', 'auto');
                  set(anchor, 'left', 'auto'); set(anchor, 'right', 'auto');
                  set(anchor, 'width', Math.max(1, box.width) + 'px');
                  set(anchor, 'height', Math.max(1, box.height) + 'px');
                  block.before(anchor);
                  const position = anchor.getBoundingClientRect();
                  set(anchor, 'margin-left', (box.left - position.left) + 'px');
                  set(anchor, 'margin-top', (box.top - position.top) + 'px');
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
                    set(anchor, 'right', 'auto'); set(anchor, 'width', Math.max(1, box.width) + 'px');
                    set(anchor, 'bottom', 'auto'); set(anchor, 'height', '1px');
                    document.body.appendChild(anchor);
                  }
                } else {
                  inside(block, anchor);
                  if (block.matches('.math-block')) set(anchor, 'bottom', (-\(2 * WebPaginator.printPixelsPerPoint) / zoom) + 'px');
                  if (block.parentElement.matches('pre.surimono-plain')) {
                    const box = block.getBoundingClientRect();
                    const pre = block.parentElement.getBoundingClientRect();
                    set(anchor, 'left', ((pre.left - box.left) / zoom) + 'px');
                    set(anchor, 'right', 'auto'); set(anchor, 'width', pre.width / zoom + 'px');
                  }
                }
                if (wanted.get(id) && anchor.isConnected) {
                  const body = document.body;
                  const box = body.getBoundingClientRect();
                  const scale = body.offsetWidth ? box.width / body.offsetWidth : 1;
                  const css = getComputedStyle(body);
                  const left = body.clientLeft + number(css.paddingLeft);
                  const width = body.clientWidth - number(css.paddingLeft) - number(css.paddingRight);
                  const offset = left + (box.left - anchor.getBoundingClientRect().left) / scale;
                  set(anchor, 'margin-left', (number(getComputedStyle(anchor).marginLeft) + offset) + 'px');
                  set(anchor, 'right', 'auto'); set(anchor, 'width', width + 'px');
                }
              }
              if (printWidth > 0) root.style.width = priorWidth;
            })();
            """
    }

    private static func sameBox(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 0.25 && abs(a.maxX - b.maxX) <= 0.25
            && abs(a.minY - b.minY) <= 0.25 && abs(a.maxY - b.maxY) <= 0.25
    }

    /// Structural selectors can move the anchor's host. Check only the lines it covers in the two uncoloured PDFs.
    static func matchesCleanPage(_ mark: ChangeMark, measured: PDFDocument, clean: PDFDocument) -> Bool {
        guard let page = measured.page(at: mark.pageIndex), let original = clean.page(at: mark.pageIndex),
            page.rotation == original.rotation, page.bounds(for: .mediaBox) == original.bounds(for: .mediaBox),
            page.bounds(for: .cropBox) == original.bounds(for: .cropBox)
        else { return false }
        func lines(on page: PDFPage) -> [CGRect] {
            page.selection(for: mark.rect)?.selectionsByLine().map { $0.bounds(for: page) } ?? []
        }
        let before = lines(on: original)
        let after = lines(on: page)
        return before.count == after.count && zip(before, after).allSatisfy { sameBox($0, $1) }
    }

    static func matchingGeometry(_ clean: [ChangeMark], _ ink: [ChangeMark]) -> Set<Int> {
        struct Key: Hashable {
            let block: String
            let page: Int
            init(_ mark: ChangeMark) {
                block = mark.blockID
                page = mark.pageIndex
            }
        }
        func ordered(_ a: ChangeMark, _ b: ChangeMark) -> Bool {
            a.rect.maxY == b.rect.maxY ? a.rect.minX < b.rect.minX : a.rect.maxY > b.rect.maxY
        }
        let stencil = Dictionary(grouping: ink, by: Key.init)
        var matching = Set<Int>()
        for (key, indices) in Dictionary(grouping: clean.indices, by: { Key(clean[$0]) }) {
            guard let pieces = stencil[key], pieces.count == indices.count else { continue }
            let pairs = zip(indices.sorted { ordered(clean[$0], clean[$1]) }, pieces.sorted(by: ordered))
            for (index, piece) in pairs {
                let a = clean[index].rect
                let b = piece.rect
                if sameBox(a, b) {
                    matching.insert(index)
                }
            }
        }
        return matching
    }

    /// Remove every private annotation, even an unknown id; none may escape into an exported PDF.
    static func extract(from document: PDFDocument, requests: [MarkdownMarkRequest]) -> [ChangeMark] {
        let wanted = Dictionary(requests.map { ($0.blockID, $0) }, uniquingKeysWith: { first, _ in first })
        var deletions: [String: ChangeMark] = [:]
        var lineRuns: [String: Int] = [:]
        var marks: [ChangeMark] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            lineRuns.removeAll(keepingCapacity: true)
            for annotation in page.annotations {
                let url = annotation.url ?? (annotation.action as? PDFActionURL)?.url
                guard let url, url.scheme == "surimono-mark" else { continue }
                let id = String(url.absoluteString.dropFirst("surimono-mark:".count))
                let rect = annotation.bounds.intersection(page.bounds(for: .cropBox))
                page.removeAnnotation(annotation)
                guard let request = wanted[id], !rect.isNull, !rect.isEmpty else { continue }
                var mark = ChangeMark(
                    pageIndex: index, rect: rect, isShort: request.isShort, afterBlock: request.afterBlock)
                mark.blockID = id
                if request.isShort {
                    // A surviving neighbour can span pages. A deletion has only one insertion point.
                    if let previous = deletions[id] {
                        if request.afterBlock {
                            if index > previous.pageIndex || rect.minY < previous.rect.minY { deletions[id] = mark }
                        } else if index == previous.pageIndex, rect.maxY > previous.rect.maxY {
                            deletions[id] = mark
                        }
                    } else {
                        deletions[id] = mark
                    }
                } else if id.hasPrefix("lines-"), let position = lineRuns[id] {
                    let combined = marks[position].rect.union(rect)
                    mark = ChangeMark(pageIndex: index, rect: combined)
                    mark.blockID = id
                    marks[position] = mark
                } else {
                    if id.hasPrefix("lines-") { lineRuns[id] = marks.count }
                    marks.append(mark)
                }
            }
        }
        return marks + requests.compactMap { deletions[$0.blockID] }
    }
}
