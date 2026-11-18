import AppKit
import PDFKit
import SurimonoCore
import Testing

@testable import SurimonoRendering

@MainActor
struct DiagramGeometryTests {
    @Test("改ページをまたぐ図はどちらのページからも図全体の大きさで書き出す")
    func splitDiagramSize() throws {
        let geometry = try RenderingFixtures.pdf(count: 2)
        for index in 0..<2 {
            let page = try #require(geometry.page(at: index))
            let link = PDFAnnotation(
                bounds: CGRect(x: 50, y: 40, width: 100, height: 500), forType: .link, withProperties: nil)
            link.url = URL(string: "surimono-diagram:probe/0")
            page.addAnnotation(link)
        }
        let pass = DiagramGeometry.Pass(
            document: geometry, sources: [.init(svg: "<svg/>", heightToWidth: 10)], token: "probe")
        let diagrams = try pass.diagrams(transform: nil)
        #expect(diagrams.map(\.number) == [1, 1])
        #expect(diagrams.map(\.pointSize) == [CGSize(width: 100, height: 1000), CGSize(width: 100, height: 1000)])
    }

    @Test("ノートを挿入して余白を入れ替えると図の矩形も本文と一緒に移る")
    func finishedGeometry() async throws {
        var settings = RenderSettings(
            layout: .a4Duplex, theme: PrintTheme(id: "test", name: "Test", css: ""),
            preset: HTMLCleanupPreset(id: "none", name: "None"))
        settings.options.margins = PageMargins(top: 15, left: 30, bottom: 15, right: 10)
        settings.options.mirrorsMargins = true
        let preset = try #require(NotePaperPreset.preset(id: "hougan"))
        settings.notes = NotePages(isEnabled: true, placement: .spreadRight, presetID: preset.id, style: preset.style)
        let renderer = DocumentRenderer(paginateWithResult: { request in
            let clean = try RenderingFixtures.pdf(count: 2, size: request.pageSize)
            var result = WebPaginator.Result(document: clean)
            let geometry = try #require(clean.dataRepresentation().flatMap(PDFDocument.init(data:)))
            for index in 0..<2 {
                let page = try #require(geometry.page(at: index))
                let link = PDFAnnotation(
                    bounds: CGRect(x: 100, y: 300, width: 80, height: 30), forType: .link, withProperties: nil)
                link.url = URL(string: "surimono-diagram:probe/\(index)")
                page.addAnnotation(link)
            }
            result.diagramPass = .init(
                document: geometry,
                sources: [
                    .init(svg: "<svg/>", heightToWidth: 0.375), .init(svg: "<svg/>", heightToWidth: 0.375),
                ], token: "probe")
            return result
        })
        let source = DocumentSource(data: Data("本文".utf8), format: .markdown)
        let prepared = try await renderer.prepare(source, settings: settings)
        #expect(prepared.diagrams.map(\.pageIndex) == [1, 3])
        for diagram in prepared.diagrams {
            #expect(abs(diagram.rect.minX - 43.307) < 0.01)
            #expect(diagram.rect.minY == 300)
            #expect(prepared.viewDocument.page(at: diagram.pageIndex)?.annotations.isEmpty == true)
        }
    }

    @Test("図のPNGは紙の寸法の三倍で白地に描く", .timeLimit(.minutes(1)))
    func png() async throws {
        _ = NSApplication.shared
        let diagram = RenderedDiagram(
            number: 1, pageIndex: 0, rect: CGRect(x: 30, y: 40, width: 24, height: 12),
            svg: #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 8 4"><rect width="4" height="4"/></svg>"#)
        let bytes = try await WebPaginator.diagramPNG(diagram)
        let bitmap = try #require(NSBitmapImageRep(data: bytes))
        #expect(bitmap.pixelsWide == 72 && bitmap.pixelsHigh == 36)
        let ink = try #require(bitmap.colorAt(x: 10, y: 18)?.usingColorSpace(.sRGB))
        let white = try #require(bitmap.colorAt(x: 62, y: 18)?.usingColorSpace(.sRGB))
        #expect(ink.redComponent < 0.02 && ink.alphaComponent == 1)
        #expect(white.redComponent > 0.98 && white.alphaComponent == 1)
    }

    @Test("二つの図の位置と自然寸法のSVGを集めて数式と印刷用PDFを区別する", .timeLimit(.minutes(1)))
    func collectsDiagrams() async throws {
        _ = NSApplication.shared
        let markdown = """
            # 工作メモ

            ```mermaid
            flowchart LR
              A[Fold] --> B[Cut]
            ```

            $a^2+b^2=c^2$

            <div class="mermaid-block"><svg width="20" height="20"><rect width="20" height="20"/></svg></div>

            ```dot
            digraph { node [shape=box fixedsize=true width=1 height=0.5]; Proof }
            ```
            """
        let result = try await DocumentRenderer().prepare(
            DocumentSource(data: Data(markdown.utf8), format: .markdown),
            settings: RenderSettings(
                layout: .a4Single, theme: PrintTheme(id: "test", name: "Test", css: "body { font-family: serif; }"),
                preset: HTMLCleanupPreset(id: "none", name: "None")))
        #expect(result.diagrams.map(\.number) == [1, 2])
        let labels = ["Fold", "Proof"]
        for (diagram, label) in zip(result.diagrams, labels) {
            let page = try #require(result.viewDocument.page(at: diagram.pageIndex))
            #expect(page.selection(for: diagram.rect)?.string?.contains(label) == true)
            #expect(page.annotations.allSatisfy { $0.url?.scheme != "surimono-diagram" })
            let root = try #require(try XMLDocument(xmlString: diagram.svg, options: []).rootElement())
            #expect(root.localName == "svg")
            #expect(root.uri == "http://www.w3.org/2000/svg")
            #expect(root.stringValue?.contains(label) == true)
            let width = try #require(root.attribute(forName: "width")?.stringValue.flatMap(Double.init))
            let height = try #require(root.attribute(forName: "height")?.stringValue.flatMap(Double.init))
            #expect(width > 0 && height > 0)
            if label == "Proof" {
                // DOT adds a four-point margin on each side of the 72 by 36 point node.
                #expect(abs(width - 80 * 96.0 / 72) < 0.1)
                #expect(abs(height - 44 * 96.0 / 72) < 0.1)
            }
        }
        if result.diagrams.count == 2 {
            #expect(!result.diagrams[0].rect.intersects(result.diagrams[1].rect))
        }
    }
}
