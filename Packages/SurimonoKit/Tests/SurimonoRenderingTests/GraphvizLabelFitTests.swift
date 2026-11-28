import AppKit
import SurimonoCore
import Testing

@testable import SurimonoRendering

@MainActor
@Suite(.serialized)
struct GraphvizLabelFitTests {
    /// Draws each DOT source in a Japanese Markdown page and returns what `script` reports about the diagrams.
    private func prepare(_ sources: [String], script: String) async throws -> [String: Any] {
        _ = NSApplication.shared
        let blocks = sources.map { "```dot\n\($0)\n```" }.joined(separator: "\n\n")
        let html = HTMLDocumentBuilder.build(
            fragment: MarkdownConverter.convert("図の節点の大きさを確かめるための日本語の本文です。\n\n" + blocks),
            format: .markdown, theme: PrintTheme(id: "test", name: "Test", css: "body { font-family: serif; }"))
        let result = try await WebPaginator().paginateWithResult(
            .html(html, baseURL: nil), pageSize: CGSize(width: 595, height: 842),
            margins: .uniform(millimeters: 15), allowsJavaScript: false, preparationScript: script,
            rendersDiagrams: true)
        let json = try #require(result.preparationResult)
        return try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    /// For each node label, how far its drawn text passes the node's outline (negative when it stays inside).
    /// An ellipse is measured at the text's vertical centre.
    private static let overflow = """
        const overflow = {};
        for (const node of document.querySelectorAll('.graphviz-block g.node')) {
          const outline = node.querySelector('ellipse,polygon');
          const shape = outline.getBBox();
          for (const text of node.querySelectorAll('text')) {
            const box = text.getBBox();
            let left = shape.x, right = shape.x + shape.width;
            if (outline.localName === 'ellipse') {
              const rx = shape.width / 2, ry = shape.height / 2, cx = shape.x + rx, cy = shape.y + ry;
              const dy = (box.y + box.height / 2 - cy) / ry;
              const half = rx * Math.sqrt(Math.max(0, 1 - dy * dy));
              left = cx - half; right = cx + half;
            }
            overflow[text.textContent] = Math.max(left - box.x, box.x + box.width - right);
          }
        }
        return JSON.stringify({overflow, errors: document.querySelectorAll('.diagram-error').length});
        """

    @Test("日本語の節点の文字は枠と楕円の中に収まる", .timeLimit(.minutes(1)))
    func japaneseNodesFit() async throws {
        let values = try await prepare(
            [
                #"digraph { a [shape=box label="受付窓口で記録を確認する"]; b [label="日本語の楕円の節点\n二行目の説明"]; a -> b }"#
            ], script: Self.overflow)
        #expect(values["errors"] as? Int == 0)
        let overflow = try #require(values["overflow"] as? [String: Double])
        for label in ["受付窓口で記録を確認する", "日本語の楕円の節点", "二行目の説明"] {
            let amount = try #require(overflow[label], "\(label) missing: \(overflow)")
            #expect(amount <= 0, "\(label) passes its outline by \(amount)")
        }
    }

    @Test("注釈・文字列の中の括弧やクラスターがあっても節点を広げる", .timeLimit(.minutes(1)))
    func rewritesAroundDOTSyntax() async throws {
        let source = """
            strict digraph "g{" {
              node [shape=box]
              /* } a comment with a brace */
              subgraph cluster_x { label="枠"; a [label="括弧 } を含む長い日本語の節点"] }
              b [label="二つ目の長い日本語の節点"]; // }
              a -> b
            }
            # trailing preprocessor line }
            """
        let values = try await prepare([source], script: Self.overflow)
        #expect(values["errors"] as? Int == 0)
        let overflow = try #require(values["overflow"] as? [String: Double])
        for label in ["括弧 } を含む長い日本語の節点", "二つ目の長い日本語の節点"] {
            let amount = try #require(overflow[label], "\(label) missing: \(overflow)")
            #expect(amount <= 0, "\(label) passes its outline by \(amount)")
        }
    }

    @Test("書き換えられない形の図は一回目の配置のままエラーなく描く", .timeLimit(.minutes(1)))
    func unsafeShapesStayAsDrawn() async throws {
        let sources = [
            #"digraph { a [label=<<b>太字の長い日本語の節点</b>>]; b [shape=record label="{記録|長い日本語の欄}"]; a -> b }"#,
            #"digraph { a [label="一つ目の図の長い日本語の節点"] } digraph { b }"#,
        ]
        let literal = String(decoding: try JSONSerialization.data(withJSONObject: sources), as: UTF8.self)
        // A single layout of the same source, with the same defaults, is what the page should show.
        let values = try await prepare(
            sources,
            script: """
                const widths = svg => Array.from(svg.querySelectorAll('g.node ellipse,g.node polygon'),
                  outline => outline.getAttribute('rx') ?? outline.getAttribute('points'));
                const font = {fontname: 'Helvetica'};
                const once = \(literal).map(source => widths(new DOMParser().parseFromString(
                  globalThis.surimonoViz.renderString(source, {format: 'svg', graphAttributes: {...font, overlap: 'false'},
                    nodeAttributes: font, edgeAttributes: font}), 'image/svg+xml')));
                const blocks = Array.from(document.querySelectorAll('.graphviz-block'));
                return JSON.stringify({
                  diagrams: blocks.filter(block => block.querySelector(':scope > svg')).length,
                  errors: document.querySelectorAll('.diagram-error').length,
                  drawn: blocks.map(widths), once
                });
                """)
        #expect(values["diagrams"] as? Int == 2)
        #expect(values["errors"] as? Int == 0)
        let drawn = try #require(values["drawn"] as? [[String]])
        #expect(drawn.map(\.count) == [2, 1])
        #expect(drawn == values["once"] as? [[String]])
    }

    @Test("sfdpの節点の矩形は重ならない", .timeLimit(.minutes(1)))
    func sfdpNodesDoNotOverlap() async throws {
        let nodes = (0..<25).map { #"p\#($0) [label="Group \#($0 / 5)\nMember \#($0)"];"# }.joined(separator: " ")
        let edges = (0..<25).map { "p\($0) -- p\(($0 + 1) % 25); p\($0) -- p\(($0 + 5) % 25);" }.joined(separator: " ")
        let source = "graph G { layout=sfdp; node [shape=box]; \(nodes) \(edges) }"
        let values = try await prepare(
            [source],
            script: """
                const boxes = Array.from(document.querySelectorAll('.graphviz-block g.node polygon'),
                  outline => outline.getBBox());
                let overlaps = 0;
                for (let i = 0; i < boxes.length; i++) for (let j = i + 1; j < boxes.length; j++) {
                  const a = boxes[i], b = boxes[j];
                  if (a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height) overlaps++;
                }
                return JSON.stringify({nodes: boxes.length, overlaps});
                """)
        #expect(values["nodes"] as? Int == 25)
        #expect(values["overlaps"] as? Int == 0)
    }
}
